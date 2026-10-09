"""插件页分层与功能目录（docs/design/plugin-page-tiers.md）。

插件页只放真正的插件。不为了插件而插件：引擎的扩展能力在，但不一下子都给用户。

分层（每个内置插件恰好一层）：

- ``official``：随应用提供、能被插件包替换的（随带插件包与它们依赖的通道中枢），插件页展示；
- ``system``：其余全部（自动入库、AI 字幕这些也是——它们是 MovieClaw 本身的能力，不是插件），
  插件页默认不展示，异常时才浮出。

功能目录 ``FEATURES`` 不决定插件页展示什么，只是功能开关的目录：一个功能由哪些插件组成、叫什么、
能不能停用（``switchable``，状态管理见 ``services/plugin_features.py``）。开关在服务端与接口 / CLI
可用，网页上不出开关；功能被停用时它的设置页会提示。AI 助手（``agent.*``）是核心，不进功能目录。

可停用的功能须满足（tests/api/test_plugin_features.py 守着）：组成插件都 ``disableable``，
功能外没有插件依赖它们提供的服务；停用后它在各端的入口要么隐藏、要么明确说「已停用」。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

Tier = Literal["official", "system"]

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
    #: 去哪里设置它（站内路径）；没有设置页为 None
    settings_href: str | None = None
    #: 能不能停用（停用 = 组成插件全部不运行，运行中生效、重启保持）
    switchable: bool = False


FEATURES: tuple[Feature, ...] = (
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
        switchable=True,
    ),
    Feature(
        "library-watch",
        "媒体库实时监控",
        "媒体库目录有变化时自动增量扫描；在每个媒体库的编辑里开关",
        ("library.watch",),
        "/library/manage",
        switchable=True,
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
        switchable=True,
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
        switchable=True,
    ),
)

_FEATURE_OF: dict[str, str] = {entry: f.key for f in FEATURES for entry in f.entries}
_BY_KEY: dict[str, Feature] = {f.key: f for f in FEATURES}


def feature(key: str) -> Feature | None:
    return _BY_KEY.get(key)


def feature_of(entry_id: str) -> str | None:
    """内置插件属于哪个功能（子插件传父插件的 id）。"""
    return _FEATURE_OF.get(entry_id)


def tier_of(entry_id: str, *, bundled: set[str]) -> Tier:
    """内置插件属于哪一层。``bundled`` 是随带插件包的条目 id（可被插件包替换）。"""
    if entry_id in bundled or entry_id in OFFICIAL_HUBS:
        return "official"
    return "system"
