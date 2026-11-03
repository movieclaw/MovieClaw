"""外部库源注册表（registry 契约：``library.source-providers``）。

媒体库的来源不再写死 tmdb / local：每种外部媒体服务器是一个「来源提供方」，
由插件登记进来——登记内容是一份完整的能力档案（LibraryProfile）加连接配置
的表单声明。飞牛影视是第一个这样的插件；将来 Emby / Plex 直连同一路径。

设计要点（对应 ``feat/external-library-sources-hooks`` 规划）：

- **主线只认机制不认名字**：主线不硬编码 ``fnos`` 等任何来源值。库的
  ``Library.source`` 可以是本表登记的任意值，能力档案查表（profile_for）
  查不到时回落到这里；
- **能力档案由插件自带**：扫描/展示/播放/Jellyfin 四条消费链全读能力位，
  插件给一份档案就等于在这四条链上都"长"了出来，主线消费代码零改动；
- **连接配置主线不解释**：库行上的 ``source_config``（远程地址、远程库 id
  等）由登记方定义语义，主线只透传存储。``config_schema`` 是它的 JSON
  Schema，前端据此渲染建库向导的来源专属表单。

没有插件内核时（命令行工具、单独驱动服务的测试）回落为空——与下载器
适配器注册表同一哲学。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from movieclaw_kernel import Registry, RegistryKey, Stability

if TYPE_CHECKING:
    from collections.abc import Callable

    from movieclaw_api.services.library.profile import LibraryProfile

#: 内置来源：能力档案写死在 services/library/profile.py 的 PROFILES 表里，
#: 不许插件覆盖（改 movie/tv 库的能力位是主线演进的事，不走注册表）
BUILTIN_SOURCES: frozenset[str] = frozenset({"tmdb", "local"})


@dataclass(frozen=True)
class LibrarySourceProvider:
    """一种外部库源的全部声明：叫什么、支持什么形态、长什么能力、怎么配置。"""

    source: str
    """存进 ``Library.source`` 的来源值，如 ``fnos``；全局唯一，不得撞内置来源。"""
    title: str
    """给人看的名字，如「飞牛影视」。"""
    profiles: dict[str, LibraryProfile]
    """各形态的能力档案：形态值（``movie`` / ``tv``）→ 档案。形态决定展示结构，
    来源决定身份——同一来源可以同时登记电影库与剧集库，各持一份档案（它们的
    jellyfin_type、卡片比例等必然不同）。``profile.source`` 必须等于 ``source``，
    ``profile.kind.value`` 必须等于键。档案是四条消费链的唯一事实源。
    支持哪些形态即本表的键集合。"""
    config_schema: dict = field(default_factory=dict)
    """``Library.source_config`` 的 JSON Schema（空对象 = 无来源专属配置）。
    前端建库向导据此渲染配置表单、提交时按它把关。主线不解释内容。"""
    icon: str = ""
    """库卡片/建库向导的来源标识（图标名，前端图标库的 key）。"""
    help: str = ""
    """建库向导里这一来源的一句话说明。"""

    def __post_init__(self) -> None:
        if not self.source or self.source != self.source.strip() or "/" in self.source:
            # i18n-ignore: developer validation message
            raise ValueError(f"外部库源 source 非法：{self.source!r}")
        if self.source in BUILTIN_SOURCES:
            # i18n-ignore: developer validation message
            raise ValueError(f"外部库源不得覆盖内置来源：{self.source}")
        if not self.profiles:
            # i18n-ignore: developer validation message
            raise ValueError(f"外部库源 {self.source} 至少要登记一个形态的能力档案")
        unknown = set(self.profiles) - {"movie", "tv", "video", "photo"}
        if unknown:
            # i18n-ignore: developer validation message
            raise ValueError(f"外部库源 {self.source} 支持了未知形态：{sorted(unknown)}")
        for kind, profile in self.profiles.items():
            if profile.source != self.source:
                # i18n-ignore: developer validation message
                raise ValueError(
                    # i18n-ignore: developer validation message
                    f"外部库源 {self.source} 的 {kind} 档案 source 不匹配：{profile.source}"
                )
            if profile.kind.value != kind:
                # i18n-ignore: developer validation message
                raise ValueError(
                    # i18n-ignore: developer validation message
                    f"外部库源 {self.source} 的 {kind} 档案挂到了错误的形态键上"
                    f"（档案是 {profile.kind.value}）"
                )
        if not isinstance(self.config_schema, dict):
            # i18n-ignore: developer validation message
            raise ValueError(f"外部库源 {self.source} 的 config_schema 须是 JSON Schema 对象")
        self._validate_config_schema()

    #: 建库向导支持的配置字段类型：表单按它渲染、提交时按它转换
    #: （PR #1111 审查意见 3：超出的类型没有对应的表单控件，登记时挡下）
    _SUPPORTED_CONFIG_FIELD_TYPES = frozenset({"string", "integer", "number", "boolean"})

    def _validate_config_schema(self) -> None:
        """连接配置表单声明只收支持的子集：字段类型、required 引用。"""
        schema = self.config_schema
        if not schema:
            return
        properties = schema.get("properties")
        if not isinstance(properties, dict):
            # i18n-ignore: developer validation message
            raise ValueError(
                f"外部库源 {self.source} 的 config_schema 缺少 properties 对象"
            )
        for field_name, field_schema in properties.items():
            if not isinstance(field_schema, dict) or field_schema.get("type") not in (
                self._SUPPORTED_CONFIG_FIELD_TYPES
            ):
                # i18n-ignore: developer validation message
                raise ValueError(
                    f"外部库源 {self.source} 的配置字段 {field_name!r} 类型不支持，"
                    f"只支持 {sorted(self._SUPPORTED_CONFIG_FIELD_TYPES)}"
                )
        unknown_required = set(schema.get("required", [])) - set(properties)
        if unknown_required:
            # i18n-ignore: developer validation message
            raise ValueError(
                f"外部库源 {self.source} 的 config_schema.required 引用了不存在的字段："
                f"{sorted(unknown_required)}"
            )

    @property
    def kind_support(self) -> frozenset[str]:
        """支持的形态：能力档案表的键集合。"""
        return frozenset(self.profiles)


LIBRARY_SOURCE_PROVIDERS: RegistryKey[LibrarySourceProvider] = RegistryKey(
    "library.source-providers",
    schema=LibrarySourceProvider,
    stability=Stability.EXPERIMENTAL,
    # i18n-ignore: developer registry doc
    doc="外部库源：插件登记的新库来源（能力档案 + 连接配置表单声明），新增外部媒体服务器就登记一个",
)

_bound: Registry[LibrarySourceProvider] | None = None


def bind_source_providers(registry: Registry[LibrarySourceProvider]) -> Callable[[], None]:
    global _bound
    _bound = registry

    def unbind() -> None:
        global _bound
        if _bound is registry:
            _bound = None

    return unbind


def registered_providers() -> dict[str, LibrarySourceProvider]:
    """当前登记的外部库源：来源值 → 提供方。没有插件内核时为空。

    两个插件登记了同一个来源值时直接抛错而不是静默取优先级高的那个
    （PR #1111 审查意见 5）：来源值是库行的身份锚，静默覆盖会让两个插件
    都以为这个来源是自己的，出问题时无从排查。内核的注册表观察者无法
    否决登记（异常会被吞掉记日志），所以在读端把冲突顶出来——首次消费
    即响，管理页与日志都能立刻看到是谁撞了谁。
    """
    if _bound is None:
        return {}
    providers: dict[str, LibrarySourceProvider] = {}
    for item in _bound:
        previous = providers.get(item.source)
        if previous is not None:
            raise ValueError(
                # i18n-ignore: developer validation message
                f"外部库源 {item.source!r} 被登记了两次，请卸载其中一个插件后重试"
            )
        providers[item.source] = item
    return providers


def provider_of(source: str) -> LibrarySourceProvider | None:
    """按来源值取提供方；内置来源或未登记的值返回 None。"""
    if source in BUILTIN_SOURCES:
        return None
    return registered_providers().get(source)


def known_source(source: str) -> bool:
    """来源值是否可用：内置来源，或注册表里已登记的外部来源。"""
    return source in BUILTIN_SOURCES or provider_of(source) is not None


def is_external_source(source: str | None) -> bool:
    """来源值是否属于外部库源（不在内置集合里）。

    与 ``known_source`` 的差别在插件停用/卸载的窗口期：来源不再登记，但存量
    库仍是外部库——它"没有本地根"的事实不随插件可用性变化，编辑校验据此
    放行空根，而不是逼用户给一个飞牛镜像库编造本地目录。
    """
    return source is not None and source not in BUILTIN_SOURCES
