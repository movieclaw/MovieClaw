"""「不要的格式」判定：杜比视界 Profile 5（docs/design/avoid-dv-p5.md）。

样本全部取自真实 M-Team 种子：标题与 ``labelsNew`` 是站点原样返回的，
``P5`` 列是该种子 MediaInfo 里的 ``dvhe.05`` 或入库文件 ffprobe 的 dv_profile。
"""

from __future__ import annotations

import pytest

from movieclaw_enrich import enrich
from movieclaw_enrich.models import TorrentAttrs
from movieclaw_matcher.formats import DV_P5, is_dv_p5, matched_formats

# (标题, 站点 labelsNew, 是不是 Profile 5)
REAL_SAMPLES = [
    # ---- 有 ffprobe 真值（入库文件）----
    (
        "Obsession 2025 2160p MA WEB-DL DD+ 5.1 Atmos DV HDR H.265-BYNDR",
        ["4k", "hdr10", "DoVi"],
        False,  # P8
    ),
    (
        "Kill Bill The Whole Bloody Affair 2011 Hybrid 2160p UHD BluRay REMUX DV HDR10+ HEVC "
        "DTS-HD MA 5.1-CiNEPHiLES",
        ["中字", "4k", "hdr10+", "DoVi"],
        False,  # P7
    ),
    (
        "Mayday 2026 2160p ATVP WEB-DL DDP 5.1 Atmos DV H.265-FLUX",
        ["中字", "4k", "DoVi"],
        True,
    ),
    ("V 2026 2160p YK HQ WEB-DL H.265 DV DTS 5.1-ADWeb", ["4k", "DoVi"], True),
    (
        "Cars 2 2011 2160p UHD BluRay x265 DV HDR 6Audios TrueHD Atmos 7.1 mUHD-FRDS",
        ["中字", "4k", "中配", "hdr10", "DoVi"],
        False,  # P8
    ),
    # ---- 有 MediaInfo 真值：「WEB 源 + 只标 DV」全是 P5 ----
    ("Seinfeld S06 1994 2160p NF WEB-DL DDP5.1 DV H.265-CHDWEB", ["中字", "4k", "DoVi"], True),
    (
        "Nobody Wants This S03 2024 2160p NF WEB-DL DoVi H.265 DDP 5.1 Atmos-DepWeb",
        ["中字", "4k", "DoVi"],
        True,
    ),
    (
        "Dark Matter S02E09 2160p ATVP WEB-DL DDP5.1 Atmos DV H.265-MWeb",
        ["中字", "4k", "DoVi"],
        True,
    ),
    (
        "Cyberpunk Edgerunners S02 2026 2160p NF WEB-DL DV H.265 DDP5.1-ADWeb",
        ["中字", "4k", "DoVi"],
        True,
    ),
    (
        "Light the Dark 2026 S01 Complete 2160p IQ WEB-DL DoVi H.265 10bit DDP5.1-UBWEB",
        ["中字", "4k", "DoVi"],
        True,
    ),
    (
        "Where the Mask Ends 2026 S01E02 2160p HQ WEB-DL H.265 DV AAC 2.0-AilMWeb",
        ["中字", "4k", "中配", "DoVi"],
        True,
    ),
    (
        "Xiao Cheng Liang Fang S01E05-S01E06 2026 2160p WEB-DL DV H.265 10bit DDP 5.1-LongWeb",
        ["中字", "4k", "中配", "DoVi"],
        True,
    ),
    (
        "City of Blood S01 2026 2160p DSNP WEB-DL H.265 DV DDP 5.1 2Audio Atmos-HHWEB",
        ["中字", "4k", "DoVi"],
        True,
    ),
    ("Carrie S01 2026 2160p AMZN WEB-DL DDP 5.1 Atmos DV H.265-FLUX", ["中字", "4k", "DoVi"], True),
    ("Masterplan 2026 2160p AMZN WEB-DL DDP 5.1 DV H.265-KHN", ["中字", "4k", "DoVi"], True),
]


@pytest.mark.parametrize(("title", "labels", "expected"), REAL_SAMPLES)
def test_real_samples_by_title_and_by_site_labels_agree(title, labels, expected) -> None:
    """两条证据各自、以及叠加，都与真值一致——这是它能当过滤依据的底气。"""
    assert is_dv_p5(enrich(title)) is expected, "只凭标题"
    assert is_dv_p5(enrich(title, site_labels=labels)) is expected, "标题 + 站点标记"
    # 只凭站点标记（标题里的 DV / HDR 字样都不看）
    only_labels = TorrentAttrs(
        media_source=enrich(title).media_source, remux=enrich(title).remux, site_labels=labels
    )
    assert is_dv_p5(only_labels) is expected, "只凭站点标记"


@pytest.mark.parametrize(
    ("attrs", "expected", "why"),
    [
        ({"hdr": ["DV"], "media_source": "WEB-DL"}, True, "WEB-DL 只标 DV"),
        ({"hdr": ["DV"], "media_source": "WEBRip"}, True, "WEBRip 只标 DV"),
        ({"hdr": [], "media_source": "WEB-DL"}, False, "没有杜比视界"),
        ({"hdr": ["HDR10"], "media_source": "WEB-DL"}, False, "只有 HDR10"),
        ({"hdr": ["DV", "HDR10"], "media_source": "WEB-DL"}, False, "DV + HDR10 是 P8"),
        ({"hdr": ["DV", "HDR10+"], "media_source": "WEB-DL"}, False, "DV + HDR10+"),
        ({"hdr": ["DV", "HDR"], "media_source": "WEB-DL"}, False, "泛指 HDR 也算兼容层"),
        ({"hdr": ["DV", "HLG"], "media_source": "WEB-DL"}, False, "DV + HLG（P8.4）"),
        ({"hdr": ["DV", "HDR Vivid"], "media_source": "WEB-DL"}, False, "DV + HDR Vivid"),
        ({"hdr": ["DV"], "media_source": "UHD Blu-ray"}, False, "光盘源的 DV 是 P7/P8"),
        ({"hdr": ["DV"], "media_source": "Blu-ray"}, False, "蓝光"),
        ({"hdr": ["DV"], "media_source": "WEB-DL", "remux": True}, False, "Remux"),
        ({"hdr": ["DV"], "media_source": "HDTV"}, False, "电视录制不是流媒体源"),
        ({"hdr": ["DV"]}, False, "片源未知不猜（三态铁律）"),
        (
            {"hdr": ["DV"], "media_source": "WEB-DL", "platforms": ["hulu"]},
            False,
            "Hulu 是公认例外：标 DV 实为 P8",
        ),
        (
            {"hdr": ["DV"], "media_source": "WEB-DL", "platforms": ["netflix"]},
            True,
            "别的平台照旧",
        ),
        # 站点标记补标题的缺口：标题没写 DV，站点标了 DoVi
        ({"media_source": "WEB-DL", "site_labels": ["DoVi"]}, True, "标题漏标 DV，站点标了"),
        ({"media_source": "WEB-DL", "site_labels": ["dovi", "4k"]}, True, "标记大小写不敏感"),
        # 站点标记纠正标题的误判：标题只写 DV，站点同时标了 HDR10
        (
            {"hdr": ["DV"], "media_source": "WEB-DL", "site_labels": ["DoVi", "hdr10"]},
            False,
            "站点说有 HDR10 兼容层",
        ),
        (
            {"hdr": ["DV"], "media_source": "WEB-DL", "site_labels": ["DoVi", "hdr10+"]},
            False,
            "站点说有 HDR10+",
        ),
        # 反过来：标题写了 HDR 而站点没标 —— 任一条显示有兼容层就不拦
        (
            {"hdr": ["DV", "HDR10"], "media_source": "WEB-DL", "site_labels": ["DoVi"]},
            False,
            "标题说有兼容层",
        ),
        ({"media_source": "WEB-DL", "site_labels": ["中字", "4k"]}, False, "站点没标 DoVi"),
    ],
)
def test_judgement_table(attrs, expected, why) -> None:
    assert is_dv_p5(TorrentAttrs(**attrs)) is expected, why


def test_matched_formats_only_when_the_user_avoids_it() -> None:
    p5 = TorrentAttrs(hdr=["DV"], media_source="WEB-DL")
    assert matched_formats(p5, [DV_P5]) == [DV_P5]
    assert matched_formats(p5, []) == []
    assert matched_formats(p5, ["DV"]) == [], "「DV」整类是 HDR 轴自己的事，不在这里判"
    assert matched_formats(TorrentAttrs(hdr=["DV", "HDR10"], media_source="WEB-DL"), [DV_P5]) == []


def test_site_labels_are_cleaned_and_only_stored_when_present() -> None:
    assert enrich("X 2160p WEB-DL").site_labels == []
    attrs = enrich("X 2160p WEB-DL", site_labels=[" 中字 ", "4k", "4k", "", "DoVi"])
    assert attrs.site_labels == ["中字", "4k", "DoVi"]
    # 没有站点标记的行，落库的 attrs 不会多出一个空键（存量行与新行逐字相同）
    assert "site_labels" not in enrich("X 2160p WEB-DL").model_dump(exclude_defaults=True)
    many = enrich("X", site_labels=[f"l{i}" for i in range(40)])
    assert len(many.site_labels) == 16
    assert len(enrich("X", site_labels=["a" * 100]).site_labels[0]) == 32
