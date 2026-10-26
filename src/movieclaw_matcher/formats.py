"""「不要的格式」：判定一份资源是不是用户排除的格式（纯函数，无 IO）。

目前只有一个格式——**杜比视界 Profile 5**（``DV_P5``）。设计与实测证据见
docs/design/avoid-dv-p5.md。

为什么要把它从 HDR 轴的 ``DV`` 里分出来
-------------------------------------
``DV`` 是整类标记：P8 / P7 自带 HDR10 基础层，不支持杜比视界的屏幕放基础层就行；
只有 P5 没有兼容层——基础层是 IPT-PQ-c2，在读不了 RPU 的转码链路（本机核显、网页端）
上会偏绿偏紫，只能交给能处理杜比视界的转码器。想拦 P5 又不想把 P8 / P7 一起拦，
就得把它单列。

怎么判定（站点从不在标题里写 profile——M-Team 索引 26,532 条标题 0 条写了）
------------------------------------------------------------------
只有两条侧面证据，**任一条显示有 HDR10 兼容层就不拦**（错的方向是少拦，不是错拦）：

1. 命名约定：WEB 源（WEB-DL / WEBRip）只标 DV、没标任何 HDR10 兼容格式（HDR / HDR10 /
   HDR10+ / HLG / HDR Vivid）→ 单层 DV，即 P5。光盘源（Remux / 蓝光）的 DV 是 P7 / P8，
   不会是 P5；Hulu 是社区公认的例外（只标 DV 实为 P8，Radarr 的 TRaSH 规则同样排除）。
2. 站点标记（``attrs.site_labels``）：M-Team 的 ``labelsNew`` 把 ``DoVi`` 与
   ``hdr10`` / ``hdr10+`` / ``hdr`` / ``hlg`` 分开标，P5 只有 ``DoVi``。

实测（2026-10-23，M-Team 详情接口的 MediaInfo + 入库文件 ffprobe）：15 个有真值的样本——
5 个 ffprobe（P5×2 / P8×2 / P7×1）与 12 个「WEB + DV 单标」（Netflix、Apple TV+、Disney+、
爱奇艺、Amazon、国内平台，MediaInfo 里全是 ``dvhe.05``）——两条证据都 15/15 吻合。
"""

from __future__ import annotations

from collections.abc import Collection

from movieclaw_enrich.models import TorrentAttrs

# 规则组 HDR 黑名单里的取值
DV_P5 = "DV P5"

# 「有 HDR10 兼容层」的标记：标题里出现任何一个，或站点标记里出现任何一个，都说明这份 DV 不是单层
_FALLBACK_HDR_TAGS = frozenset({"HDR10", "HDR10+", "HDR", "HLG", "HDR VIVID"})
_FALLBACK_LABELS = frozenset({"hdr10", "hdr10+", "hdr", "hlg", "hdrvi"})
# 只有流媒体源才有 P5
_WEB_SOURCES = frozenset({"web-dl", "webrip"})

#: 拒绝原因：整句进活动流水，用户一眼看懂「为什么没下这一份」
FORMAT_REASONS: dict[str, str] = {
    DV_P5: "只标了 DV、没有 HDR10 兼容层的杜比视界（Profile 5），转码会偏色",
}


def is_dv_p5(attrs: TorrentAttrs) -> bool:
    """这份资源是不是杜比视界 Profile 5（按上面两条证据判定，不确定一律当作不是）。"""
    tags = {tag.upper() for tag in attrs.hdr}
    labels = {label.casefold() for label in attrs.site_labels}
    if "DV" not in tags and "dovi" not in labels:
        return False
    if tags & _FALLBACK_HDR_TAGS or labels & _FALLBACK_LABELS:
        return False
    if attrs.remux or (attrs.media_source or "").casefold() not in _WEB_SOURCES:
        return False
    return "hulu" not in {platform.casefold() for platform in attrs.platforms}


def matched_formats(attrs: TorrentAttrs, avoid: Collection[str]) -> list[str]:
    """资源命中了 ``avoid`` 里的哪些格式（顺序固定，供拒绝原因直接引用）。"""
    return [DV_P5] if DV_P5 in avoid and is_dv_p5(attrs) else []
