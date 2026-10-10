"""库文件的画质快照（媒体库自己的事：只看台账行与文件名）。

去重、洗版验证、工单快照回填都按这里的构造比较版本；``name_attrs`` 由调用方给（获取领域按投递记录
给出种子名解析结果时用它，否则按文件名重新解析）。
"""

from __future__ import annotations

from pathlib import Path

from movieclaw_db.models import LibraryFile
from movieclaw_enrich import enrich
from movieclaw_matcher import (
    DISC_SOURCE,
    QualitySnapshot,
    RuleSetSpec,
    build_snapshot,
    resolution_rank,
    source_tier,
)

#: 中性阶梯：不带任何规则组偏好
NEUTRAL_SPEC = RuleSetSpec()


def file_sort_key(file: LibraryFile) -> tuple[int, int, int]:
    """多版本并存时挑最优文件的排序键：分辨率位次 > 片源档 > 新入库优先。"""
    return (
        resolution_rank(file.resolution, NEUTRAL_SPEC) or 0,
        source_tier(file.media_source, False) or 0,
        file.id or 0,
    )


def snapshot_from_file(
    file: LibraryFile, name_attrs: QualitySnapshot | None, *, with_evidence: bool = False
) -> QualitySnapshot:
    """由库文件行 + 名称解析来源构造快照（§4.1 分层取值）。

    ``name_attrs`` 为空时对文件名重跑 enrich（与入库管线同一套解析器与词表），
    并用 library_file 已存的 media_source/release_group 覆盖——它们是入库时
    对**原始名称**的解析结果，比重命名后的文件名更可靠。
    probe 是否成功以"拿到过任一实测值"为据——完全失败时不冒充实测（尤其
    不能把 hdr=None 当成"测得 SDR"覆盖名称信息）。
    """
    if name_attrs is None:
        parsed = enrich(Path(file.file_path).stem)
        name_attrs = QualitySnapshot.model_validate(parsed.model_dump(exclude_defaults=True))
        if file.media_source is not None:
            name_attrs.media_source = file.media_source
        if file.release_group is not None:
            name_attrs.release_group = file.release_group
    # 原盘（BDMV / VIDEO_TS / ISO）的片源由**结构**决定，压过名称解析：
    # attempt.quality 里的 "Blu-ray"（T4）会让一个 Remux 候选被判成升级，
    # 而 Remux 正是从这张盘剥出来的——那是降级，且默认会把原盘送进回收站
    # （issue #163）。remux 一并清零：布尔位同样来自名称，不能把 T6 拉回 T5。
    #
    # 它排在人工标注之前是有意的：原盘台账行自带非空片源，进不了标注候选池
    # （source_annotation._candidate_filter 只收未知与此前人工标注的行），
    # 整个标注体系对它不适用；能撞上这一条的只有本次修复之前留下的存量标注
    # ——而那份菜单里根本没有「原盘」这个选项，用户当时选的是次优解。
    if file.is_disc():
        name_attrs = name_attrs.model_copy(update={"media_source": DISC_SOURCE, "remux": False})
    # 人工标注的片源是**权威值**：保护位的语义就是"自动名称解析不得覆盖"
    # （media-source-annotation.md），而 attempt.quality 恰恰是名称解析的产物。
    # 少这一条，任何一次快照重算都会把用户的标注静默抹回名称值，被解卡的
    # 「无法确认」单元又卡回去。remux 一并清零，与标注服务同一口径
    elif file.media_source_manual and file.media_source is not None:
        name_attrs = name_attrs.model_copy(
            update={"media_source": file.media_source, "remux": False}
        )
    probed = file.resolution is not None or file.bit_rate is not None
    snapshot = build_snapshot(
        name_attrs,
        probed=probed,
        probe_resolution=file.resolution,
        probe_hdr_label=file.hdr,
        probe_video_codec=file.video_codec,
        probe_bit_rate=file.bit_rate,
    )
    if not with_evidence:
        return snapshot
    snapshot.resolution_verified = file.resolution is not None
    if file.is_disc():
        snapshot.source_evidence = "disc"
    elif file.media_source_manual:
        snapshot.source_evidence = "manual"
    elif file.media_source and name_attrs.media_source:
        snapshot.source_evidence = (
            "consistent_declaration"
            if file.media_source.casefold() == name_attrs.media_source.casefold()
            else "conflict"
        )
    else:
        snapshot.source_evidence = "unknown"
    return snapshot
