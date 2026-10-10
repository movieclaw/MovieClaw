"""关键字规则：给订阅加「必须包含 / 不许包含」的关键字和额外搜索词（扩展模型 §2.3 A）。

例如「这部剧只要某字幕组」「标题必须含『国语』」「排除『抢先版』」。用到三种扩展能力：

- **决策钩子**：``subscription.candidates.filter`` 在规则集之后按关键字淘汰候选（原因写进
  订阅动态），``subscription.search.keywords`` 追加额外搜索词；
- **实体扩展字段**：每条订阅的规则存在插件数据里（作用域 ``subscription:<id>``），
  将来订阅详情里编辑的也是这份数据；
- **可靠事件**：订阅删除时清掉它的规则。

开启方式（``data/plugins.yaml``；规则的初始值写在配置里，按订阅 id）::

    - id: keyword-rules
      local: true
      config:
        rules:
          35: { require_any: [国语], exclude: [抢先版, TC], keywords: [东京三十而已 国语] }
"""

from __future__ import annotations

from pydantic import BaseModel, Field

from movieclaw_api import hooks
from movieclaw_api.domain_events import SUBSCRIPTION_DELETED, SubscriptionChanged
from movieclaw_api.plugins.keys import PLUGIN_DATA
from movieclaw_api.services.plugin_data import entity_scope
from movieclaw_kernel import DURABLE_EVENTS, Context, plugin


class Rules(BaseModel):
    require_any: list[str] = Field(default_factory=list, description="标题或副标题至少包含其一")
    exclude: list[str] = Field(default_factory=list, description="包含任何一个就淘汰")
    keywords: list[str] = Field(default_factory=list, description="额外的搜索词")


class Config(BaseModel):
    rules: dict[int, Rules] = Field(default_factory=dict, description="订阅 id → 初始规则")


RULES_KEY = "rules"


def verdict(rules: Rules, title: str, subtitle: str) -> str | None:
    """这个候选为什么要淘汰；保留返回 None。不区分大小写。"""
    text = f"{title} {subtitle}".casefold()
    for word in rules.exclude:
        if word.casefold() in text:
            return f"包含排除词「{word}」"
    if rules.require_any and not any(w.casefold() in text for w in rules.require_any):
        return f"不含必须的关键字（{'、'.join(rules.require_any)}）"
    return None


@plugin(
    "keyword-rules",
    title="关键字规则（示例）",
    inject=(PLUGIN_DATA, DURABLE_EVENTS),
    config=Config,
)
async def keyword_rules(ctx: Context[Config]) -> None:
    store = ctx.use(PLUGIN_DATA).scoped(ctx)
    # 配置里的初始规则写进订阅的扩展字段（只在还没有时写，之后以数据为准）
    for subscription_id, rules in ctx.config.rules.items():
        scope = entity_scope("subscription", subscription_id)
        if await store.get(RULES_KEY, scope=scope) is None:
            await store.set(RULES_KEY, rules.model_dump(), scope=scope)

    async def rules_for(subscription_id: int | None) -> Rules | None:
        if subscription_id is None:
            return None
        raw = await store.get(RULES_KEY, scope=entity_scope("subscription", subscription_id))
        return Rules.model_validate(raw) if raw else None

    async def filter_candidates(batch: hooks.CandidateBatch, next_) -> hooks.FilterResult:
        result = await next_()
        rules = await rules_for(batch.subscription_id)
        if rules is None:
            return result
        mine = tuple(
            hooks.Rejection(key=c.key, reason_code="keyword", reason_text=f"关键字规则：{reason}")
            for c in batch.candidates
            if (reason := verdict(rules, c.title, c.subtitle)) is not None
        )
        return hooks.FilterResult(rejected=result.rejected + mine)

    async def more_keywords(payload: hooks.Keywords, next_) -> tuple:
        keywords = await next_()
        rules = await rules_for(payload.subscription_id)
        if rules is None or not rules.keywords:
            return keywords
        # 额外搜索词排在前面：它们是用户特意加的，截断时优先保留
        return (*rules.keywords, *keywords)

    async def on_deleted(event: SubscriptionChanged) -> None:
        await store.delete(RULES_KEY, scope=entity_scope("subscription", event.subscription_id))

    ctx.on(hooks.CANDIDATES_FILTER, filter_candidates)
    ctx.on(hooks.SEARCH_KEYWORDS, more_keywords)
    ctx.on(SUBSCRIPTION_DELETED, on_deleted, id="cleanup")
