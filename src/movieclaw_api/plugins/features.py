"""插件页分层：功能、官方插件、系统模块（docs/design/plugin-page-tiers.md）。

插件页只放用户能做决定的东西。每个内置插件恰好属于一层：

- ``feature``：用户能感知的可选功能。功能目录 ``FEATURES`` 里写明由哪些插件组成、叫什么、去哪设置；
- ``official``：随应用提供、能被插件包替换的（随带插件包与它们依赖的通道中枢）；
- ``system``：其余全部，插件页默认不展示，异常时才浮出。

新增内置插件默认是系统模块；要出现在「功能」里必须显式加进 ``FEATURES``——宁可少展示，
也不把内部模块误放给用户。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

Tier = Literal["feature", "official", "system"]

#: 官方插件里除随带插件包之外的成员：随带的 IM 通道都挂在这个中枢上
OFFICIAL_HUBS: tuple[str, ...] = ("channels.hub",)


@dataclass(frozen=True)
class Feature:
    key: str
    title: str
    #: 一句给用户看的说明：不出现插件 id、plugins.yaml 这类实现细节
    description: str
    #: 组成这个功能的内置插件条目 id
    entries: tuple[str, ...]
    #: 去哪里设置 / 开关它（站内路径）；没有设置页为 None
    settings_href: str | None = None


FEATURES: tuple[Feature, ...] = (
    Feature(
        "agent",
        "AI 助手",
        "在网页、App 和 IM 里用对话完成搜片、订阅、整理媒体库",
        ("agent.runs", "agent.session-index", "agent.attachments"),
        "/settings/ai",
    ),
    Feature(
        "subtitle-gen",
        "AI 字幕生成",
        "没有中文字幕时，用模型把其他语言的字幕翻译成中文外挂字幕",
        ("subtitle.gen", "subtitle.pgs-warm"),
        "/settings/ai",
    ),
    Feature(
        "ingest-watch",
        "自动入库",
        "监听下载目录，下载完成后自动整理进媒体库",
        ("library.ingest-watch",),
        "/settings/import-watch",
    ),
    Feature(
        "library-watch",
        "媒体库实时监控",
        "媒体库目录有变化时自动增量扫描；在每个媒体库的编辑里开关",
        ("library.watch",),
        "/library/manage",
    ),
    Feature(
        "boost",
        "自动刷分享率",
        "按站点规则自动下载与做种，并在上行吃紧时让路",
        ("boost", "boost.sentinel"),
        "/settings/sites",
    ),
    Feature(
        "arrivals",
        "新片到达通知",
        "媒体库有新片入库时推送通知",
        ("push.arrivals",),
        "/settings/notifications",
    ),
    Feature(
        "cloud",
        "MovieClaw Cloud",
        "把这台服务器连到你的 MovieClaw 账号，使用官方推送等云端服务",
        ("cloud", "push.channels-refresh"),
        "/settings/cloud",
    ),
    Feature(
        "jellyfin-discovery",
        "Jellyfin 局域网发现",
        "让 Infuse 等 Jellyfin 客户端在局域网里自动找到这台服务器",
        ("jellyfin.discovery",),
    ),
)

_FEATURE_OF: dict[str, str] = {entry: f.key for f in FEATURES for entry in f.entries}


def feature_of(entry_id: str) -> str | None:
    """内置插件属于哪个功能（子插件传父插件的 id）。"""
    return _FEATURE_OF.get(entry_id)


def tier_of(entry_id: str, *, bundled: set[str]) -> Tier:
    """内置插件属于哪一层。``bundled`` 是随带插件包的条目 id（可被插件包替换）。"""
    if entry_id in bundled or entry_id in OFFICIAL_HUBS:
        return "official"
    if feature_of(entry_id) is not None:
        return "feature"
    return "system"
