"""规则组服务：默认组懒种子、CRUD、"被引用禁删"语义与按适用范围选组。

规则组是纯参数包（movieclaw_matcher.RuleSetSpec 定 schema），本服务只负责
校验与持久化；判断逻辑在匹配内核。修改规则组只影响之后的评估、不追溯已
grabbed 的工单——这一条不需要任何机制，天然成立。

适用范围（docs/design/rule-set-scope.md）：规则组可声明"适用于什么作品"
（``match_rules``，与媒体库收藏范围同构，外加 ``kind`` 电影/剧集字段）。新订阅
未显式指定规则组时由 ``pick`` 自动选组，三条铁律与库路由一致：

- 只决定默认值：订阅弹窗预选、用户可改；已有订阅的挂靠永远不动；
- 永不失败：没命中、元数据拿不到都落默认规则组；
- 全程可解释：``RuleSetPick.reason`` 是可直接展示的整句中文。

只写 ``kind`` 一个条件的规则组就是"该类型的默认组"——按类型分默认不需要
第二套机制。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import (
    BadRequestException,
    ConflictException,
    NotFoundException,
)
from movieclaw_api.i18n.stored import stored_fields
from movieclaw_api.services.library.profile import kind_reference
from movieclaw_api.services.library.routing import (
    RoutingFacts,
    evaluate,
    hit_part_references,
    validate_match_rules,
)
from movieclaw_db.models import RuleSet
from movieclaw_db.repositories import RuleSetRepository
from movieclaw_matcher import RuleSetSpec

logger = logging.getLogger("movieclaw_api.rule_sets")

_DEFAULT_NAME_KEY = "subscription.rules.defaultName"


def rule_set_name_reference(row: RuleSet) -> str | dict:
    return (
        {"message_key": _DEFAULT_NAME_KEY, "message_params": {}}
        if row.name_key == _DEFAULT_NAME_KEY
        else row.name
    )


# 懒种子默认组的安全预设：只收 1080p 及以上（顺序即偏好）、排除零做种死种。
# 此前是"全不限"（spec={}），新用户第一批抓到的可能是低清枪版或没人做种的
# 死种——对家用场景太危险。只影响首次创建；已有部署的默认组（无论是否被
# 用户改过）一律不动。
_DEFAULT_SPEC = {"resolutions": ["2160p", "1080p"], "min_seeders": 1}

# 适用范围里的作品类型字段（其余字段复用媒体库收藏范围的求值与校验）
_KIND_FIELD = "kind"
_KINDS = ("movie", "tv")


def validate_scope(raw: list | None) -> list[dict]:
    """适用范围的写入侧校验：``kind`` 条件单独校验，其余交给库收藏范围的校验。

    ``kind`` 同时勾了电影和剧集等于不限类型，直接丢掉这条条件——否则它会
    白白抬高特异性（条件条数），让一个"不限类型"的组压过真正更具体的组。
    """
    if not raw:
        return []
    if not isinstance(raw, list) or not all(isinstance(r, dict) for r in raw):
        raise BadRequestException(message_key="errors.ruleSets.scopeListRequired")
    kind_rules = [r for r in raw if r.get("field") == _KIND_FIELD]
    if len(kind_rules) > 1:
        raise BadRequestException(message_key="errors.ruleSets.scopeFieldDuplicate")
    cleaned: list[dict] = []
    if kind_rules:
        rule = kind_rules[0]
        if rule.get("op", "any_of") != "any_of":
            raise BadRequestException(message_key="errors.ruleSets.scopeOperator")
        values = rule.get("values")
        if not isinstance(values, list) or not values:
            raise BadRequestException(message_key="errors.ruleSets.scopeKindRequired")
        if not all(v in _KINDS for v in values):
            raise BadRequestException(message_key="errors.ruleSets.scopeKindInvalid")
        kinds = sorted(set(values))
        if len(kinds) < len(_KINDS):
            cleaned.append({"field": _KIND_FIELD, "op": "any_of", "values": kinds})
    rest = [r for r in raw if r.get("field") != _KIND_FIELD]
    return cleaned + validate_match_rules(rest, scope="applicability")


def scope_matches(rules: list, kind: str, facts: RoutingFacts | None) -> bool:
    """适用范围是否命中作品：条件间 AND；空声明不命中。

    ``kind`` 永远已知，所以只写了类型的组即使元数据拿不到也能命中；
    其余条件沿用库路由的保守语义（事实缺失/未知字段一律不命中）。
    """
    if not rules:
        return False
    rest = [r for r in rules if not (isinstance(r, dict) and r.get("field") == _KIND_FIELD)]
    for rule in rules:
        if (
            isinstance(rule, dict)
            and rule.get("field") == _KIND_FIELD
            and kind not in (rule.get("values") or [])
        ):
            return False
    return not rest or evaluate(rest, facts)


@dataclass(frozen=True)
class RuleSetPick:
    """一次自动选组的结论（订阅创建与弹窗预检共用）。"""

    rule_set: RuleSet
    matched: bool  # True=命中某组的适用范围；False=默认规则组兜底
    reason: str  # 可直接展示的中文理由
    reason_message: dict | None = None


def _pick_reason_message(kind: str, row: RuleSet, facts: RoutingFacts | None) -> dict:
    parts = [
        kind_reference(kind) if kind in _KINDS else kind
        for rule in row.match_rules
        if rule.get("field") == _KIND_FIELD
    ]
    if facts is not None:
        parts += hit_part_references(kind, row.match_rules, facts)
    return stored_fields(
        "subscription.ruleRoute.matched",
        name=rule_set_name_reference(row),
        details={"message_list": parts, "separator_key": "common.list.separator"},
    )


class RuleSetService:
    def __init__(self, session: AsyncSession) -> None:
        self._repo = RuleSetRepository(session)

    async def ensure_default(self) -> RuleSet:
        """取默认规则组，不存在则懒种子一个安全预设的（幂等）。

        放在服务层而非迁移里做 seed：迁移保持纯 DDL，且名字/形态想改时
        不用动历史迁移。
        """
        existing = await self._repo.get_default()
        if existing is not None:
            return existing
        row = await self._repo.save(
            RuleSet(
                name=stored_fields("subscription.rules.defaultName")["message"],
                name_key=_DEFAULT_NAME_KEY,
                is_default=True,
                spec=dict(_DEFAULT_SPEC),
            )
        )
        logger.info("已创建默认规则组（1080p 及以上、做种数 ≥1），新订阅未指定规则组时使用它")
        return row

    async def list_all(self) -> list[RuleSet]:
        await self.ensure_default()
        return await self._repo.list_all()

    async def reference_counts(self) -> dict[int, int]:
        """{rule_set_id: 引用它的订阅数}，未被引用的组不在结果里。"""
        return await self._repo.reference_counts()

    async def count_references(self, rule_set_id: int) -> int:
        return await self._repo.count_references(rule_set_id)

    async def get(self, rule_set_id: int) -> RuleSet:
        row = await self._repo.get(rule_set_id)
        if row is None:
            raise NotFoundException(
                message_key="errors.ruleSets.missing", params={"id": rule_set_id}
            )
        return row

    async def pick(self, kind: str, facts: RoutingFacts | None) -> RuleSetPick:
        """按适用范围给新订阅选规则组；都不命中落默认组。永不抛出业务异常。

        多组同时命中时条件条数多者赢（越具体越优先），打平取创建更早的——
        与媒体库路由的特异性口径一致。
        """
        rows = await self.list_all()
        hits = [r for r in rows if scope_matches(r.match_rules, kind, facts)]
        if hits:
            best = sorted(hits, key=lambda r: (-len(r.match_rules), r.id))[0]
            message = _pick_reason_message(kind, best, facts)
            return RuleSetPick(
                rule_set=best, matched=True, reason=message["message"], reason_message=message
            )
        default = await self.ensure_default()
        declared = any(r.match_rules for r in rows)
        if facts is None and declared:
            message = stored_fields(
                "subscription.ruleRoute.metadataDefault", name=rule_set_name_reference(default)
            )
        elif declared:
            message = stored_fields(
                "subscription.ruleRoute.unmatchedDefault", name=rule_set_name_reference(default)
            )
        else:
            message = stored_fields(
                "subscription.ruleRoute.defaultGroup", name=rule_set_name_reference(default)
            )
        return RuleSetPick(
            rule_set=default, matched=False, reason=message["message"], reason_message=message
        )

    async def create(self, name: str, spec: dict, match_rules: list | None = None) -> RuleSet:
        cleaned = self._validate(name, spec)
        scope = validate_scope(match_rules)
        try:
            return await self._repo.save(
                RuleSet(name=name.strip(), spec=cleaned, match_rules=scope)
            )
        except IntegrityError as exc:
            # 名称撞唯一约束：给可读中文错误，而不是让 500 裸奔到前端
            await self._repo.rollback()
            raise ConflictException(
                message_key="errors.ruleSets.nameInUse", params={"name": name.strip()}
            ) from exc

    async def update(
        self, rule_set_id: int, *, name: str, spec: dict, match_rules: list | None = None
    ) -> RuleSet:
        """更新规则组。``match_rules`` 为 None 表示不改适用范围（老客户端/CLI
        只改 spec 时不会把已配的适用范围清空）；传 [] 才是清空。"""
        row = await self.get(rule_set_id)
        # rollback 会使 ORM 对象过期，异常分支不能再读 row.name——先落到局部变量
        new_name = name.strip() or row.name
        if new_name != row.name:
            row.name_key = None
        row.name = new_name
        row.spec = self._validate(new_name, spec)
        if match_rules is not None:
            row.match_rules = validate_scope(match_rules)
        try:
            return await self._repo.save(row)
        except IntegrityError as exc:
            await self._repo.rollback()
            raise ConflictException(
                message_key="errors.ruleSets.nameInUse", params={"name": new_name}
            ) from exc

    async def set_default(self, rule_set_id: int) -> RuleSet:
        """把默认标记转移到指定组：新订阅未指定规则组时用它。幂等。

        只换"谁是默认"，不改任何订阅的挂靠——已有订阅继续用各自的组。
        """
        row = await self.get(rule_set_id)
        if row.is_default:
            return row
        row = await self._repo.set_default(row)
        logger.info("默认规则组已切换为「%s」", row.name)
        return row

    async def delete(self, rule_set_id: int) -> None:
        """删除规则组。默认组与被订阅引用的组禁删（显式报错优于隐式改挂靠）。"""
        row = await self.get(rule_set_id)
        if row.is_default:
            raise BadRequestException(message_key="errors.ruleSets.defaultDelete")
        references = await self._repo.count_references(rule_set_id)
        if references > 0:
            raise ConflictException(
                message_key="errors.ruleSets.inUse", params={"name": row.name, "count": references}
            )
        await self._repo.delete(row)
        logger.info("规则组「%s」已删除", row.name)

    @staticmethod
    def _validate(name: str, spec: dict) -> dict:
        """经 RuleSetSpec 校验并规整（未知字段忽略、类型收敛），存精简形态。

        未知字段被静默忽略是 pydantic 默认行为，也是刻意保留的兼容策略：
        新版本加字段（如 dv）后回退旧版本，旧代码读到新字段不会报错。
        """
        if not name.strip():
            raise BadRequestException(message_key="errors.ruleSets.nameRequired")
        try:
            parsed = RuleSetSpec.model_validate(spec)
        except ValueError as exc:
            raise BadRequestException(
                message_key="errors.ruleSets.invalidSpec", params={"error": exc}
            ) from exc
        return parsed.model_dump(exclude_defaults=True, mode="json")
