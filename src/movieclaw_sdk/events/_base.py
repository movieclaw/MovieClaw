"""事件定义的公共部分：引用类型与 ``define``（docs/design/domain-events.md §3）。"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict

from movieclaw_kernel import Event, Mode, Stability

#: 系统保留的域：插件事件以插件 id 开头，插件 id 不得与这些同名
CORE_DOMAINS = frozenset(
    {"subscription", "download", "library", "playback", "account", "agent", "system"}
)


class Frozen(BaseModel):
    model_config = ConfigDict(frozen=True)


class MediaRef(Frozen):
    """媒体条目快照。"""

    id: int
    kind: str
    """``movie`` / ``tv`` / ``other`` / ``photo`` …"""
    title: str
    original_title: str | None = None
    year: int | None = None
    tmdb_id: int | None = None
    imdb_id: str | None = None


class UnitRef(Frozen):
    """剧集的一集。电影没有单元（列表为空、单个为 ``None``），内部哨兵值不外泄。"""

    season: int
    episode: int


class FileRef(Frozen):
    """媒体库文件快照。"""

    id: int
    library_id: int | None
    season: int | None = None
    episode: int | None = None
    path: str
    original_path: str | None = None
    """在回收站里时，进回收站之前的路径。"""
    size_bytes: int | None = None


class ClientRef(Frozen):
    """上报的客户端（网页、App、Jellyfin 客户端）。"""

    name: str | None = None
    device_name: str | None = None
    device_id: str | None = None
    version: str | None = None


class EventType(Event[Any, None]):
    """系统事件：在内核事件契约上多带给人看的元数据（标题、分组），以及两个性质：

    - ``sensitive``：涉及「谁在什么时候看了什么」，插件订阅须单独批准；
    - ``high_frequency``：高频（播放进度、打开详情），只能实时订阅、Webhook 不默认勾选。
    """

    def __init__(
        self,
        name: str,
        payload: type,
        *,
        title: str,
        group: str,
        doc: str = "",
        sensitive: bool = False,
        high_frequency: bool = False,
        version: str = "1.0",
        owner: str = "core",
    ) -> None:
        super().__init__(
            name,
            Mode.EMIT,
            payload=payload,
            durable=not high_frequency,
            version=version,
            stability=Stability.EXPERIMENTAL,
            doc=doc or title,
        )
        self.title = title
        self.group = group
        self.sensitive = sensitive
        self.high_frequency = high_frequency
        self.owner = owner
        """``core`` 或插件 id。"""


_CORE: dict[str, EventType] = {}


def define(
    name: str,
    payload: type,
    *,
    title: str,
    group: str,
    doc: str = "",
    sensitive: bool = False,
    high_frequency: bool = False,
    version: str = "1.0",
) -> EventType:
    """定义一个系统事件（只给本包各域模块用；插件事件经清单声明，见 §7）。"""
    domain = name.split(".", 1)[0]
    if domain not in CORE_DOMAINS:
        raise ValueError(f"系统事件 {name} 须在保留的域里：{sorted(CORE_DOMAINS)}")
    if name in _CORE:
        raise ValueError(f"系统事件 {name} 重复定义")
    event = EventType(
        name,
        payload,
        title=title,
        group=group,
        doc=doc,
        sensitive=sensitive,
        high_frequency=high_frequency,
        version=version,
    )
    _CORE[name] = event
    return event


def core_events() -> list[EventType]:
    """全部系统事件（定义顺序）。"""
    return list(_CORE.values())
