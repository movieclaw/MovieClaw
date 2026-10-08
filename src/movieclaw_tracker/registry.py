from __future__ import annotations

import dataclasses
import importlib
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import yaml

from movieclaw_tracker.base import BaseSite
from movieclaw_tracker.datetime_utils import DEFAULT_SITE_TIMEZONE
from movieclaw_tracker.exceptions import SiteNotFoundError
from movieclaw_tracker.models import TorrentCategory

logger = logging.getLogger("movieclaw_tracker.registry")


# 各框架默认支持的授权类型。YAML 未显式声明 auth.supported 时按框架兜底：
# - api（如 M-Team）：只走 API-Key
# - nexusphp：既可粘 cookie，也可账号密码模拟登录
_DEFAULT_AUTH_BY_FRAMEWORK: dict[str, tuple[str, ...]] = {
    "api": ("apikey",),
    "nexusphp": ("cookie", "credential"),
}

# 合法的授权类型取值（与 movieclaw_db 的 AuthType 保持一致；此处用字符串避免
# tracker 反向依赖 db 层，保持纯领域库无外部依赖）
_VALID_AUTH_TYPES = frozenset({"cookie", "apikey", "credential"})


@dataclass(frozen=True)
class SiteConfig:
    """注册的 PT 站点完整配置。"""

    site_id: str
    display_name: str
    base_url: str
    framework: str
    site_class: type[BaseSite]
    # 网页访问域名（用户在浏览器打开的地址）。仅当与 base_url 不同才需配置：
    # API 类站点（如 M-Team）请求走 api.m-team.cc，但给用户展示的种子详情
    # 链接必须指向网页域名 tp.m-team.cc。None 表示与 base_url 相同。
    web_base_url: str | None = None
    selectors: Any | None = None
    category_map: dict[TorrentCategory, list[str]] = field(default_factory=dict)
    http2: bool = False
    timeout: float = 30.0
    max_retries: int = 3
    # 每站请求最小间隔（秒）：礼貌硬下限。None 表示未在 YAML 显式配置，
    # 由限流器回退到全局默认值；显式设了就用这个值。
    min_request_interval: float | None = None
    # 该站点支持的授权类型（供上层"可选项"展示，用户从中选一种来配置）
    # 用字符串元组，取值为 cookie / apikey / credential
    supported_auth_types: tuple[str, ...] = ()
    # 页面/API 的 naive 时间所属时区；当前全部内置站点默认使用中国标准时间。
    timezone: str = DEFAULT_SITE_TIMEZONE
    # 该站 H&R 考核要求的做种时长（小时）。站点级政策（NexusPHP 各站规则页
    # 有明示），None=未知/无考核。刷流引擎据此对 H&R 种子按真实考核时长
    # 保底保留（覆盖站点保留期设置），并允许准入明确标注 H&R 的免费种。
    hr_seed_hours: int | None = None


# ---------------------------------------------------------------------------
# 模块级注册表
# ---------------------------------------------------------------------------

_registry: dict[str, SiteConfig] = {}


def register_site(config: SiteConfig) -> None:
    """注册一个站点配置。"""
    _registry[config.site_id] = config
    logger.info("Registered site: %s (%s)", config.site_id, config.display_name)


def get_site_config(site_id: str) -> SiteConfig:
    """查找已注册的站点。不存在则抛出 SiteNotFoundError。"""
    config = _registry.get(site_id)
    if config is None:
        raise SiteNotFoundError(site_id)
    return config


def list_sites() -> list[SiteConfig]:
    """返回所有已注册站点的列表。"""
    return list(_registry.values())


# ---------------------------------------------------------------------------
# YAML 配置加载
# ---------------------------------------------------------------------------


#: 内置站点类（docs/design/plugin-phase2b.md §6）。YAML 的 ``custom_class`` 可以写短名，也兼容
#: 历史上的完整导入路径——但只认这张表里的：此前任意导入路径都能被 ``importlib`` 执行，用户数据
#: 目录里的一个 YAML 就能运行任意模块的顶层代码
BUILTIN_SITE_CLASSES: dict[str, str] = {
    "mteam": "movieclaw_tracker.sites.custom.mteam.MTeamSite",
    "sunnypt": "movieclaw_tracker.sites.custom.sunnypt.SunnyPTSite",
    "ourbits": "movieclaw_tracker.sites.custom.ourbits.OurBitsSite",
    "ttg": "movieclaw_tracker.sites.custom.ttg.TTGSite",
}

#: 插件注册的站点类（名字 → 类），由插件内核的 SITE_CLASSES 注册表同步进来
_plugin_site_classes: dict[str, type[BaseSite]] = {}
#: 插件贡献的站点数据包目录（YAML），加载顺序：内置 < 数据包 < 用户目录
_data_pack_dirs: dict[str, Path] = {}


class UnknownSiteClass(ValueError):
    """``custom_class`` 引用了既不是内置、也没有插件注册的站点类。"""


def register_site_class(name: str, cls: type[BaseSite]) -> None:
    if not (isinstance(cls, type) and issubclass(cls, BaseSite)):
        raise TypeError(f"站点类 {name} 必须是 BaseSite 的子类")
    _plugin_site_classes[name] = cls


def unregister_site_class(name: str) -> None:
    _plugin_site_classes.pop(name, None)


def register_data_pack(name: str, directory: Path) -> None:
    _data_pack_dirs[name] = Path(directory)


def unregister_data_pack(name: str) -> None:
    _data_pack_dirs.pop(name, None)


def _import_class(ref: str) -> type[BaseSite]:
    """按名字取站点类：插件注册的、内置短名、内置完整路径；其他一律拒绝，不做任意导入。"""
    cls: object
    if ref in _plugin_site_classes:
        cls = _plugin_site_classes[ref]
    else:
        dotted_path = BUILTIN_SITE_CLASSES.get(ref)
        if dotted_path is None and ref in BUILTIN_SITE_CLASSES.values():
            dotted_path = ref
        if dotted_path is None:
            raise UnknownSiteClass(
                f"'{ref}' 不是内置站点类（{', '.join(sorted(BUILTIN_SITE_CLASSES))}），"
                "也没有插件注册它；custom_class 不再接受任意导入路径"
            )
        module_path, _, class_name = dotted_path.rpartition(".")
        cls = getattr(importlib.import_module(module_path), class_name)
    if not (isinstance(cls, type) and issubclass(cls, BaseSite)):
        raise UnknownSiteClass(f"'{ref}' 不是站点类（须继承 BaseSite）")
    return cls


def _parse_supported_auth_types(raw: dict[str, Any], framework: str) -> tuple[str, ...]:
    """解析站点支持的授权类型。

    优先取 YAML 的 ``auth.supported``；未声明则按 framework 兜底。
    非法取值会被过滤并告警，避免脏配置流到上层。
    """
    auth_section = raw.get("auth") or {}
    declared = auth_section.get("supported")
    if declared is None:
        return _DEFAULT_AUTH_BY_FRAMEWORK.get(framework, ())

    if not isinstance(declared, (list, tuple)):
        logger.warning(
            "站点 %s 的 auth.supported 应写成列表（如 supported: [cookie]），"
            "当前值 '%s' 格式不对，已按框架默认值处理",
            raw.get("site_id"),
            declared,
        )
        return _DEFAULT_AUTH_BY_FRAMEWORK.get(framework, ())

    result: list[str] = []
    for item in declared:
        value = str(item).lower()
        if value not in _VALID_AUTH_TYPES:
            logger.warning("站点 %s 声明了未知授权类型 '%s'，已忽略", raw.get("site_id"), value)
            continue
        result.append(value)
    return tuple(result)


def _parse_category_map(raw: dict[str, Any]) -> dict[TorrentCategory, list[str]]:
    """从 YAML 原始数据解析分类映射。"""
    raw_categories = raw.get("categories", {})
    category_map: dict[TorrentCategory, list[str]] = {}
    for key, ids in raw_categories.items():
        try:
            cat = TorrentCategory(key)
        except ValueError:
            logger.warning("Unknown category '%s' in config, skipping", key)
            continue
        category_map[cat] = [str(i) for i in ids]
    return category_map


def _parse_selectors(raw: dict[str, Any], selector_cls: type) -> Any:
    """解析选择器：以框架默认值为底，用 YAML 中声明的字段覆盖。

    促销规则在 YAML 中写成字典（可读），加载时转为 tuple of tuples（不可变）。
    """
    defaults = selector_cls()
    overrides = raw.get("selectors", {})
    for rule_key in (
        "promo_download_rules",
        "promo_upload_rules",
        "login_extra_form_data",
        "login_select_defaults",
    ):
        if rule_key in overrides and isinstance(overrides[rule_key], dict):
            overrides[rule_key] = tuple(
                (key, str(value)) for key, value in overrides[rule_key].items()
            )
    for rule_key in ("promo_download_rules", "promo_upload_rules"):
        if rule_key in overrides and isinstance(overrides[rule_key], tuple):
            overrides[rule_key] = tuple((css, float(factor)) for css, factor in overrides[rule_key])
    return dataclasses.replace(defaults, **overrides) if overrides else defaults


def _load_site_yaml(
    yaml_file: Path,
    framework_defaults: dict[str, tuple[type[BaseSite], type]],
) -> SiteConfig | None:
    """加载单个站点 YAML，解析为 SiteConfig。

    任何一步失败（YAML 语法错误、custom_class 导入失败、字段非法）都只记录
    日志并返回 None，不向上抛异常——单个坏文件不能拖垮其它站点的加载，
    这对用户自定义配置目录尤其重要（用户手写 YAML 出错是常态）。
    """
    try:
        raw = yaml.safe_load(yaml_file.read_text(encoding="utf-8"))
    except Exception:
        logger.exception("站点配置文件解析失败（YAML 语法错误？）: %s", yaml_file)
        return None

    if not raw or not isinstance(raw, dict):
        logger.warning("站点配置文件为空或格式不对（应为 YAML 映射）: %s", yaml_file)
        return None

    site_id = str(raw.get("site_id", "") or "")
    if not site_id:
        logger.warning("站点配置缺少必填字段 site_id，已跳过: %s", yaml_file)
        return None

    # 整段解析都兜底：用户手写 YAML 里字段拼错、类型写错（如 selectors 键名
    # 打错、促销系数写成非数字、categories 写成列表）会抛各种异常，
    # 任何一种都只跳过这一个文件，不能拖垮其它站点的加载
    try:
        framework = raw.get("framework", "")
        category_map = _parse_category_map(raw)
        supported_auth_types = _parse_supported_auth_types(raw, framework)
        timezone = str(raw.get("timezone", DEFAULT_SITE_TIMEZONE) or "")
        # 启动时验证 IANA 时区，错误配置必须整站跳过，不能静默污染同步高水位。
        ZoneInfo(timezone)

        # 确定站点类和选择器
        # 若同时指定了 custom_class 和 framework，则：
        #   - custom_class 替换默认站点类（可继承 framework 的基类并扩展）
        #   - framework 继续负责解析 selectors，使 YAML 中的选择器覆盖正常生效
        # 若仅有 custom_class 而无 framework，selectors 为 None（自定义类自行管理）
        if "custom_class" in raw:
            try:
                site_class = _import_class(str(raw["custom_class"]))
            except UnknownSiteClass as exc:
                logger.warning(
                    "站点 %s 的 custom_class 不可用，已跳过（%s）：%s", site_id, exc, yaml_file
                )
                return None
            except Exception:
                logger.exception(
                    "站点 %s 的 custom_class '%s' 导入失败（类路径写错？），已跳过: %s",
                    site_id,
                    raw["custom_class"],
                    yaml_file,
                )
                return None
            if framework in framework_defaults:
                _, selector_cls = framework_defaults[framework]
                selectors = _parse_selectors(raw, selector_cls)
            else:
                selectors = None
        elif framework in framework_defaults:
            site_class, selector_cls = framework_defaults[framework]
            selectors = _parse_selectors(raw, selector_cls)
        else:
            logger.warning(
                "未知的 framework '%s'（支持: nexusphp），已跳过: %s", framework, yaml_file
            )
            return None

        return SiteConfig(
            site_id=site_id,
            display_name=raw.get("display_name", site_id),
            base_url=raw.get("base_url", ""),
            web_base_url=raw.get("web_base_url"),
            framework=framework,
            site_class=site_class,
            selectors=selectors,
            category_map=category_map,
            http2=raw.get("http2", False),
            timeout=raw.get("timeout", 30.0),
            max_retries=raw.get("max_retries", 3),
            min_request_interval=raw.get("min_request_interval"),
            supported_auth_types=supported_auth_types,
            timezone=timezone,
            hr_seed_hours=raw.get("hr_seed_hours"),
        )
    except Exception:
        logger.exception("站点配置文件 %s 解析失败（字段写法有误？），已跳过", yaml_file)
        return None


def _load_configs_dir(
    configs_dir: Path,
    framework_defaults: dict[str, tuple[type[BaseSite], type]],
    *,
    is_user_dir: bool = False,
) -> None:
    """扫描目录下所有 *.yaml（下划线开头的模板文件除外）并注册。"""
    for yaml_file in sorted(configs_dir.glob("*.yaml")):
        if yaml_file.name.startswith("_"):
            continue
        config = _load_site_yaml(yaml_file, framework_defaults)
        if config is None:
            continue
        if is_user_dir and config.site_id in _registry:
            logger.info("用户自定义配置覆盖内置站点: %s（来自 %s）", config.site_id, yaml_file)
        register_site(config)


def _ensure_user_configs_dir(user_dir: Path) -> None:
    """确保用户自定义站点目录存在，并播种模板文件方便用户上手。

    模板文件名以下划线开头，加载时会被跳过，仅作参考；已存在则不覆盖
    （用户可能改过它）。目录创建失败（如只读挂载）只告警，不阻断启动。
    """
    try:
        user_dir.mkdir(parents=True, exist_ok=True)
        template = user_dir / "_template.yaml"
        if not template.exists():
            builtin_template = Path(__file__).parent / "sites" / "configs" / "_template.yaml"
            template.write_text(builtin_template.read_text(encoding="utf-8"), encoding="utf-8")
    except OSError:
        logger.warning("无法创建用户站点配置目录（磁盘只读或无权限？）: %s", user_dir)


def load_all_sites(user_configs_dir: str | Path | None = None) -> None:
    """加载并注册所有站点配置（每次调用先清空注册表再全量重建，可重复调用）。

    两级加载，后者覆盖前者（按 site_id）：

    1. **内置目录** ``sites/configs/*.yaml`` —— 随代码/镜像分发，容器更新会被覆盖。
    2. **用户自定义目录** ``user_configs_dir``（可选）—— 部署时放在 data/ 卷下
       （API 层默认 ``data/site-configs/``），容器更新不丢。用户可在这里：
       - 新增自己适配的站点（复制 ``_template.yaml`` 改写即可，重启后生效）；
       - 用相同 site_id 覆盖内置站点的配置（如某站改版后自行修选择器）。
    """
    from movieclaw_tracker.frameworks.nexusphp import NexusPHPSite
    from movieclaw_tracker.selectors import NexusPHPSelectors

    framework_defaults: dict[str, tuple[type[BaseSite], type]] = {
        "nexusphp": (NexusPHPSite, NexusPHPSelectors),
    }

    _registry.clear()

    configs_dir = Path(__file__).parent / "sites" / "configs"
    if configs_dir.exists():
        _load_configs_dir(configs_dir, framework_defaults)
    else:
        logger.warning("Site configs directory not found: %s", configs_dir)

    for pack, pack_dir in sorted(_data_pack_dirs.items()):
        if pack_dir.is_dir():
            _load_configs_dir(pack_dir, framework_defaults, is_user_dir=True)
        else:
            logger.warning("站点数据包 %s 的目录不存在：%s", pack, pack_dir)

    if user_configs_dir is not None:
        user_dir = Path(user_configs_dir)
        _ensure_user_configs_dir(user_dir)
        if user_dir.is_dir():
            _load_configs_dir(user_dir, framework_defaults, is_user_dir=True)
