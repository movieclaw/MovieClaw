"""季集号解析的确定性层——把「单文件猜季集」换成「按批次仲裁 + 台账守卫」。

为什么需要这一层
----------------
``E01`` 这个字符串**根本不含季号**，任何模型都解不出来，只能幻觉。线上病例
（issue #185）：36 集单季包全部命名为 ``Show.E01..E36``，逐文件跑模型解出 25
个互不相同的季号，其中 15 个是「季号 == 集号」的幻觉（E10 → S10E10），整包被
散进 25 个 TMDB 里根本不存在的季目录，其余 21 个报解析失败。同一批文件在
torrent-ner v1/v2/v3 上分别错 0/2/15 个——结果完全随模型版本漂移。

三条设计原则
------------
1. **模型排在证据链最后**。季集号的确定性来源（显式 SxxEyy 标记、裸 E/EP 标记、
   季目录名、TMDB 台账）都比"对短串跑 NER"可靠得多。模型只负责前面全灭时的
   兜底，**永远不能单独决定季号**。
2. **决策粒度是批次，不是单文件**。同一个包里的文件季号必然相同——这个约束
   在单文件视角里根本看不见，于是 36 个文件各猜各的、互相矛盾也无人发觉。
   批次视角下，唯一的确定季号可以借给缺季号的同伴，发散的模型季号可以整体作废。
3. **台账是推断季号的守卫，不是确定性声明的守卫**。推断来的季号必须落在
   ``media_season`` 真实存在的季里才被采信（一次挡住所有幻觉季）；而显式标记与
   季目录名是发布组和用户的明确意图，TMDB 元数据可能滞后（新季刚开播、条目
   建档后没再刷过），不能反过来用台账否决它们——否则会把今天能正常入库的
   SxxEyy 包挡在门外。

   守卫只有这一条，是 NAS 生产数据审计的结果（6093 个真实文件消融）：季存在性
   守卫拦对 8、拦错 0；曾经并列的"集号超出该季 TMDB 宣称集数即否决"拦对 0、
   拦错 8，因为 ``media_season.episode_count`` 在真实数据里普遍滞后（《想见你》
   标 13 实为 14+、《书简阅中国》标 6 实为 12、《寻味顺德》标 3 实为 9），已按
   与 enrich v16 退役字幕否定护栏相同的标准（killed_correct 必须为 0）下线。

本模块是纯函数：不碰数据库、不做 I/O（只读路径字符串），台账由调用方查好传入。
"""

from __future__ import annotations

from collections.abc import Collection, Sequence
from dataclasses import dataclass
from pathlib import Path

from movieclaw_api.i18n.stored import reference
from movieclaw_api.services.library.layout import (
    explicit_episode,
    explicit_unit,
    pack_season,
    season_from_dir,
    trailing_index_episode,
)
from movieclaw_enrich import enrich

__all__ = ["FileUnit", "resolve_units"]


@dataclass(frozen=True)
class FileUnit:
    """单个文件的季集结论。"""

    # None = 季号求解失败，挂起等人（绝不默认第 1 季错挂）
    season: int | None
    # 0 = 无集号
    episode: int
    # 显式声明的 E00（先导/特辑占位）。与"真正解析不出集号"性质完全不同：
    # 不自动入库，也不是解析缺口；由入库层决定整批跳过还是留待人工处理
    explicit_pilot: bool = False
    # 季号被台账守卫否决时的原因（文案引用），供上层写进台账 message。缺省 None
    # 表示压根没解出季号（而不是解出了但没通过守卫）——两者对用户是不同的故事
    rejected_reason: dict | None = None


@dataclass
class _Evidence:
    """单文件的原始证据，仲裁前的中间态。"""

    episode: int
    explicit_pilot: bool
    # 确定性季号：显式 SxxEyy 标记、季目录名或季包目录名声明的，语义无歧义，
    # 不受台账守卫约束
    certain_season: int | None
    # 模型季号：去噪后的候选，须经批次共识 + 台账守卫才可能被采信
    model_season: int | None


def _file_evidence(file: Path) -> _Evidence:
    """逐文件取证：确定性通道尽力而为，够用就不惊动模型。

    集号优先级：显式 SxxEyy → 裸 E/EP → 模型 → 裸尾号兜底（「走向共和01」）。
    季号只认两个确定性来源，模型季号单独存放待仲裁。
    """
    stem = file.stem
    unit = explicit_unit(stem)
    if unit is not None:
        # 显式 SxxEyy 语义确定，季集一次拿全，无需模型
        return _Evidence(
            episode=unit[1],
            explicit_pilot=unit[1] == 0,
            certain_season=unit[0],
            model_season=None,
        )

    bare = explicit_episode(stem)
    # 季目录名；父目录是带片名的季包（"House.M.D.S04.1080p"）时取它声明的季号
    dir_season = season_from_dir(file.parent)
    if dir_season is None:
        dir_season = pack_season(file.parent.name)
    if bare is not None and dir_season is not None:
        # 两轴都由确定性来源拿到，跳过模型（快路径）
        return _Evidence(
            episode=bare,
            explicit_pilot=bare == 0,
            certain_season=dir_season,
            model_season=None,
        )

    attrs = enrich(stem)
    episode = bare if bare is not None else (attrs.episodes[0] if attrs.episodes else 0)
    if not episode:
        # 常规集号全灭才退回裸尾号：常规标记语义强得多，兜底抢跑会把
        # 「S01E03.特辑2」这类名字带偏
        episode = trailing_index_episode(stem) or 0

    model_season = attrs.seasons[0] if attrs.seasons else None
    if model_season is not None and bare is not None and model_season == bare:
        # 幻觉指纹：文件名里只有裸 E 标记，模型却把同一个数字又吐了一份当季号
        # （E10 → seasons=[10] + episodes=[10]）。这是 issue #185 的确切形态，
        # 确定性可识别——直接作废，不让它污染后面的批次共识。
        #
        # 已知代价：区分不了"复读裸 E 数字"与"文件名确实写了第二季、集号恰好
        # 也是 2"的巧合，对后者是误杀。之所以仍然值得：一个季包里这种巧合最多
        # 命中一个文件，其余文件的季号照常存活并形成批次共识，被误杀的那个由
        # 共识补回（见 test_batch_consensus_rescues_fingerprint_false_kill）。
        # 只有"单文件、无季目录、无台账"三者同时成立时才真正丢结论——那正是
        # 库扫描逐文件走的场景，回落特别季与修复前行为一致，不构成回归。
        model_season = None

    return _Evidence(
        episode=episode,
        explicit_pilot=bare == 0,
        certain_season=dir_season,
        model_season=model_season,
    )


def _sole(values: Collection[int]) -> int | None:
    """候选恰好只有一个不同取值时返回它，否则 None（有分歧就不猜）。"""
    unique = set(values)
    return next(iter(unique)) if len(unique) == 1 else None


def resolve_units(
    files: Sequence[Path],
    *,
    entry_name: str | None = None,
    known_seasons: Collection[int] | None = None,
) -> dict[Path, FileUnit]:
    """一批文件（同一个包 / 同一个目录）的季集号。

    :param files: 同批文件的完整路径——季目录判定要用到父目录名。
    :param entry_name: 条目名/包名。缺省表示调用方没有这层上下文（库扫描按目录
        逐文件走，父目录季号已在证据里，不必再为每个文件跑一遍模型）。
    :param known_seasons: TMDB 台账里该条目真实存在的季号。给定时作为推断季号的
        守卫；``None`` 表示调用方拿不到台账，跳过守卫。
    :return: 文件路径 → 结论。
    """
    evidence = {file: _file_evidence(file) for file in files}
    certain = {e.certain_season for e in evidence.values() if e.certain_season is not None}
    # 台账里唯一的正片季（特别季 S00 不参与判定）。既是推断链的兜底，也是
    # 幻觉季被否决后的改判对象
    regular = {s for s in (known_seasons or ()) if s != 0}
    ledger_sole = _sole(regular) if regular else None

    # 批次统一季号
    batch_season: int | None = None
    reason: dict | None = None
    if len(certain) == 1:
        # 批次内唯一的确定季号借给缺季号的同伴——"S02E01 + 裸 E05 混编"这类包
        # 全批归位。确定性可传递，不必再受台账约束
        batch_season = next(iter(certain))
    elif not certain:
        # 推断链，由强到弱。三者都是"关于这个包"的证据，台账垫底不是因为它不
        # 可靠，而是因为它说的是剧集结构、不是这个包装了哪一季——只有前两者
        # 都哑火时，"这剧统共就一季"才成为可用的推断
        batch_season = (
            # 包名声明的季号：一句话管整批，比单集文件名强
            (_sole(enrich(entry_name).seasons) if entry_name else None)
            # 模型在各文件上的共识（幻觉指纹已在取证阶段去噪）
            or _sole([e.model_season for e in evidence.values() if e.model_season is not None])
            or ledger_sole
        )
        if batch_season is not None and known_seasons and batch_season not in known_seasons:
            # 台账否决幻觉季：1 季的剧推断出第 36 季，落盘就会建出 Season 36/。
            # 否决之后不是直接放弃——推断值既然已被证伪，台账里若只有一个正片季，
            # 它就是唯一可能的答案（NAS 实测《人生第二次》：模型误判第 2 季被拦下，
            # 改判台账唯一的第 1 季即为正确结果）。台账有多季才真的没法定案
            reason = reference("library.ingest.seasonRejected", season=batch_season)
            batch_season = ledger_sole
            if batch_season is not None:
                reason = None
    # len(certain) > 1 是真·多季合集包：不设批次季号，各文件用各自的，
    # 没有确定季号的那些宁可挂起，也不硬塞进其中某一季

    return {
        file: FileUnit(
            season=ev.certain_season if ev.certain_season is not None else batch_season,
            episode=ev.episode,
            explicit_pilot=ev.explicit_pilot,
            rejected_reason=None if ev.certain_season is not None else reason,
        )
        for file, ev in evidence.items()
    }
