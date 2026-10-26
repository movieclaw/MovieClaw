"""季集号确定性解析层（library/units.py）的测试。

这一层的存在理由就是"结果不许随 NER 模型漂移"，所以**除明确打桩的用例外，
全部断言都不依赖模型输出**：裸 E/EP 标记、显式 SxxEyy、季目录名、TMDB 台账
四条确定性通道自己就能把结论定死。模型缺席（CI 无模型文件）时同样应当全绿。
"""

from __future__ import annotations

from pathlib import Path

import pytest

import movieclaw_api.services.library.units as units_mod
from movieclaw_api.i18n.stored import source_render
from movieclaw_api.services.library.layout import explicit_episode
from movieclaw_api.services.library.units import resolve_units
from movieclaw_enrich.models import TorrentAttrs


def _fake_enrich(monkeypatch, mapping: dict[str, TorrentAttrs]):
    """按文本打桩模型通道，让"模型说了什么"在用例里可控。"""
    monkeypatch.setattr(
        units_mod, "enrich", lambda text, *_a, **_kw: mapping.get(text, TorrentAttrs())
    )


def _pack(tmp_path: Path, entry_name: str, names: list[str]) -> tuple[Path, list[Path]]:
    entry = tmp_path / entry_name
    entry.mkdir(parents=True, exist_ok=True)
    files = []
    for name in names:
        file = entry / name
        file.touch()
        files.append(file)
    return entry, files


# ---------------------------------------------------------------------------
# 裸 E/EP 标记的确定性集号（layout.explicit_episode）
# ---------------------------------------------------------------------------


def test_explicit_episode_bare_marker() -> None:
    """裸 E/EP 标记出集号：单季剧种子极常见的命名，此前只能交给模型幻觉。"""
    assert explicit_episode("Hikaru No Go.E01.2020.WEB-DL.1080p.H264.AAC-PTHweb") == 1
    assert explicit_episode("Hikaru No Go.E36.2020.WEB-DL.1080p.H264.AAC-PTHweb") == 36
    assert explicit_episode("Some Show EP12 1080p") == 12
    assert explicit_episode("Show_E7_720p") == 7
    assert explicit_episode("E01") == 1
    # E00 是先导/特辑占位，原样带出 0（与 explicit_unit 同口径）
    assert explicit_episode("Show.E00.Pilot") == 0


def test_explicit_episode_rejects_ambiguity_and_noise() -> None:
    """宁可不出结论，也不能误吃技术尾巴、年份或校验码。"""
    # 区间/合集写法解出多个不同 E 号 → 歧义，交回上层挂起而不是随手挑一个
    assert explicit_episode("Jade Royal Feast EP12-EP15 2022 1080i HDTV") is None
    # 词内片段：WEB-DL 的 E、HEVC 的 E、H264 都不得触发
    assert explicit_episode("Show.2020.WEB-DL.1080p.HEVC.H264.AAC-Group") is None
    # 动漫文件名尾部的 CRC32 校验码（前界是 `[`，不算分隔符）
    assert explicit_episode("[Group] Show - 05 [1080p][E5F1A2B3]") is None
    # 数字粘连不半吃
    assert explicit_episode("Show.E051080p") is None
    # SxxEyy 由 explicit_unit 负责，这里天然不接（E 前是数字）
    assert explicit_episode("Show.S01E02.1080p") is None


def test_explicit_episode_chinese_marker() -> None:
    """issue #996：「第N集/话」与 E01 同样确定；区间与「集团」不误吃。"""
    assert explicit_episode("海绵宝宝 第01集") == 1
    assert explicit_episode("海绵宝宝 第01话") == 1
    assert explicit_episode("某剧 第十二集 国语") == 12
    assert explicit_episode("海绵宝宝 第1季 第01-02集") is None
    assert explicit_episode("海绵宝宝 第01集-第02集") is None
    assert explicit_episode("Show.E03.第04集") is None  # 两种标记互相矛盾
    assert explicit_episode("第38集团军") is None


def test_chinese_unit_in_multi_season_pack_keeps_its_own_season(tmp_path) -> None:
    """issue #996 实测：台账只认第 1 季时，模型通道会把「第10季 第3集」归成 S1E3。"""
    _, files = _pack(
        tmp_path,
        "海绵宝宝 国语 12季",
        ["海绵宝宝 第1季 第1集.mp4", "海绵宝宝第10季 第3集_3840x2160_H265.mp4"],
    )
    units = resolve_units(files, known_seasons={1})
    assert (units[files[0]].season, units[files[0]].episode) == (1, 1)
    assert units[files[1]].episode == 3 and units[files[1]].season != 1


# ---------------------------------------------------------------------------
# issue #185 主场景
# ---------------------------------------------------------------------------


def test_bare_episode_pack_with_single_season_ledger(tmp_path) -> None:
    """issue #185：36 集单季包全部命名为 E01..E36、无 S 季号前缀。

    修复前逐文件跑模型：解出 25 个互不相同的季号（15 个是"季号 == 集号"的
    幻觉，E10 → S10E10），整包散进不存在的季目录，其余 21 个报解析失败；
    且 torrent-ner v1/v2/v3 三个版本三种结果。现在集号由裸 E 标记确定性给出，
    季号由 TMDB 台账（只有 1 季）兜底，与模型版本无关。
    """
    entry, files = _pack(
        tmp_path,
        "Hikaru No Go 2020 WEB-DL 1080p H264 AAC-PTHweb",
        [f"Hikaru No Go.E{i:02d}.2020.WEB-DL.1080p.H264.AAC-PTHweb.mp4" for i in range(1, 37)],
    )
    units = resolve_units(files, entry_name=entry.name, known_seasons={1})
    assert [(units[f].season, units[f].episode) for f in files] == [(1, i) for i in range(1, 37)]


def test_hallucinated_season_never_reaches_disk(tmp_path, monkeypatch) -> None:
    """模型解出 TMDB 里根本不存在的季 → 季号作废、挂起等人。

    这是"绝不建出 Season 36/"的守卫本体：落盘路径直接由季号拼出，台账不点头
    就不许有结论。台账 message 里还要带上具体原因，否则用户只看到含混的
    「解析不出季号」，无从下手。

    条目有两季（台账自己定不了案），模型的 36 才会真正走到守卫面前。
    """
    _fake_enrich(
        monkeypatch,
        {"Show.Episode.Five": TorrentAttrs(seasons=[36], episodes=[5])},
    )
    _, files = _pack(tmp_path, "Show Pack", ["Show.Episode.Five.mkv"])
    unit = resolve_units(files, known_seasons={1, 2})[files[0]]
    assert unit.season is None
    assert unit.episode == 5
    assert unit.rejected_reason is not None
    assert "第 36 季" in source_render(unit.rejected_reason)


def test_model_season_outranks_single_season_ledger(tmp_path, monkeypatch) -> None:
    """模型说得出季号时压过"台账只有一季"的兜底。

    台账排在推断链最后是有代价的另一面：TMDB 元数据滞后（新季刚开播、条目
    建档后没再刷过）时，若让"只有一季"盖过文件名里明写的第二季，今天能正确
    入库的包会被整批错挂到第 1 季。台账说的是剧集结构，不是这个包装了哪一季。
    """
    _fake_enrich(
        monkeypatch,
        {"Show.第二季.第05集": TorrentAttrs(seasons=[2], episodes=[5])},
    )
    _, files = _pack(tmp_path, "Show Pack", ["Show.第二季.第05集.mkv"])
    unit = resolve_units(files, known_seasons={1, 2})[files[0]]
    assert (unit.season, unit.episode) == (2, 5)


def test_season_equals_episode_fingerprint_dropped(tmp_path, monkeypatch) -> None:
    """幻觉指纹：只有裸 E 标记，模型却把同一个数字又吐一份当季号。

    这是 issue #185 的确切形态（E10 → seasons=[10] + episodes=[10]）。台账
    缺席时也必须挡住——守卫依赖 TMDB，指纹识别不依赖任何外部信息。
    """
    _fake_enrich(
        monkeypatch,
        {"Show.E10.2020.1080p": TorrentAttrs(seasons=[10], episodes=[10])},
    )
    _, files = _pack(tmp_path, "Show Pack", ["Show.E10.2020.1080p.mkv"])
    unit = resolve_units(files)[files[0]]
    assert unit.episode == 10
    assert unit.season is None, "季号是模型把集号复读了一遍，不能采信"


# ---------------------------------------------------------------------------
# 批次仲裁
# ---------------------------------------------------------------------------


def test_certain_season_is_shared_across_batch(tmp_path) -> None:
    """批次内唯一的确定季号借给缺季号的同伴：混编包整批归位。

    单文件视角看不见"同一个包季号必然相同"这个约束，这正是逐文件解析解出
    一堆矛盾季号的根源。
    """
    _, files = _pack(
        tmp_path,
        "Show.S02.1080p.WEB-DL",
        ["Show.S02E01.1080p.mkv", "Show.E02.1080p.mkv", "Show.E03.1080p.mkv"],
    )
    units = resolve_units(files, entry_name="Show.S02.1080p.WEB-DL")
    assert [(units[f].season, units[f].episode) for f in files] == [(2, 1), (2, 2), (2, 3)]


def test_multi_season_pack_does_not_force_a_season(tmp_path) -> None:
    """确定季号在批次内有分歧（真·多季合集包）：各用各的，缺季号的挂起。

    这里绝不能"少数服从多数"——把裸 E 文件硬塞进其中一季会错挂一大片。
    """
    _, files = _pack(
        tmp_path,
        "Show.Complete.Series",
        ["Show.S01E01.mkv", "Show.S02E01.mkv", "Show.E05.mkv"],
    )
    units = resolve_units(files, entry_name="Show.Complete.Series", known_seasons={1, 2})
    assert (units[files[0]].season, units[files[0]].episode) == (1, 1)
    assert (units[files[1]].season, units[files[1]].episode) == (2, 1)
    assert units[files[2]].season is None
    assert units[files[2]].episode == 5


def test_batch_consensus_rescues_fingerprint_false_kill(tmp_path, monkeypatch) -> None:
    """幻觉指纹去噪的已知代价，以及批次共识为什么能兜住它。

    「季号 == 集号」这个指纹无法区分两种情况：模型把裸 E 数字复读成季号（幻觉），
    与文件名确实写了「第二季」而集号又恰好是 2（巧合）。去噪对后者是误杀。
    但一个季包里这种巧合最多命中一个文件，其余文件的季号照常存活并形成共识，
    被误杀的那个由共识补回——这正是把决策粒度提到批次的价值。
    """
    _fake_enrich(
        monkeypatch,
        {
            f"Show.第二季.E{i:02d}": TorrentAttrs(seasons=[2], episodes=[i])
            for i in range(1, 13)
        },
    )
    _, files = _pack(tmp_path, "Show 第二季", [f"Show.第二季.E{i:02d}.mkv" for i in range(1, 13)])
    units = resolve_units(files)
    # E02 的季号被指纹去噪误杀，但同批另外 11 个文件的共识把它补了回来
    assert [(units[f].season, units[f].episode) for f in files] == [
        (2, i) for i in range(1, 13)
    ]


def test_season_dir_is_a_certain_source(tmp_path) -> None:
    """季目录名是确定性声明：裸 E 文件躺在 Season 03/ 下即可定案，不惊动模型。"""
    _, files = _pack(tmp_path, "Show (2020)/Season 03", ["Show.E07.mkv"])
    unit = resolve_units(files)[files[0]]
    assert (unit.season, unit.episode) == (3, 7)


# ---------------------------------------------------------------------------
# 守卫的边界：只管推断季号，不管确定性声明
# ---------------------------------------------------------------------------


def test_ledger_never_overrides_explicit_declaration(tmp_path) -> None:
    """显式 SxxEyy 不受台账约束：TMDB 元数据滞后不该否决发布组的明确意图。

    新季刚开播、条目建档后没再刷过元数据时，台账里可能还只有第 1 季。若拿它
    去否决 S03E01，今天能正常入库的包明天就会被挡在门外——守卫是给猜测用的，
    不是给声明用的。
    """
    _, files = _pack(tmp_path, "Show.S03.1080p", ["Show.S03E01.1080p.mkv"])
    unit = resolve_units(files, entry_name="Show.S03.1080p", known_seasons={1})[files[0]]
    assert (unit.season, unit.episode) == (3, 1)
    assert unit.rejected_reason is None


def test_vetoed_season_falls_back_to_sole_ledger_season(tmp_path, monkeypatch) -> None:
    """幻觉季被台账否决后，台账只有一个正片季时改判它，而不是直接放弃。

    NAS 实测《人生第二次》：模型把 8 个文件全判成第 2 季，条目在 TMDB 只有第 1
    季。推断值既然已被证伪，唯一存在的季就是唯一可能的答案——不改判就白白丢掉
    8 个本可正确入库的文件。
    """
    _fake_enrich(
        monkeypatch,
        {f"人生第二次 E{i:02d}": TorrentAttrs(seasons=[2]) for i in range(1, 9)},
    )
    _, files = _pack(tmp_path, "人生第二次", [f"人生第二次 E{i:02d}.mp4" for i in range(1, 9)])
    units = resolve_units(files, known_seasons={0, 1})
    assert [(units[f].season, units[f].episode) for f in files] == [(1, i) for i in range(1, 9)]
    assert all(units[f].rejected_reason is None for f in files)


def test_vetoed_season_without_unique_fallback_stays_pending(tmp_path, monkeypatch) -> None:
    """台账有多季时，被否决的推断季无处改判 → 挂起，并说明具体原因。"""
    _fake_enrich(monkeypatch, {"Show.Episode.Five": TorrentAttrs(seasons=[36], episodes=[5])})
    _, files = _pack(tmp_path, "Show Pack", ["Show.Episode.Five.mkv"])
    unit = resolve_units(files, known_seasons={1, 2})[files[0]]
    assert unit.season is None
    assert unit.rejected_reason is not None
    assert "第 36 季" in source_render(unit.rejected_reason)


def test_explicit_pilot_is_not_a_parser_gap(tmp_path) -> None:
    """显式 E00（先导/特辑占位）与"解析不出集号"性质不同，必须能被区分。

    占位按设计就不入库，重试和模型升级都改变不了结果——混为一谈会把记录
    永远钉在待处理清单里。
    """
    _, files = _pack(tmp_path, "Show.S01", ["Show.S01E00.Pilot.mkv", "Show.E00.Preview.mkv"])
    units = resolve_units(files, entry_name="Show.S01")
    for file in files:
        assert units[file].episode == 0
        assert units[file].explicit_pilot is True


@pytest.mark.parametrize("known", [None, set()])
def test_missing_ledger_skips_the_guard(tmp_path, monkeypatch, known) -> None:
    """调用方拿不到台账（库扫描逐文件走）时跳过守卫，不误伤。"""
    _fake_enrich(monkeypatch, {"Show.Chapter": TorrentAttrs(seasons=[4], episodes=[9])})
    _, files = _pack(tmp_path, "Show Pack", ["Show.Chapter.mkv"])
    unit = resolve_units(files, known_seasons=known)[files[0]]
    assert (unit.season, unit.episode) == (4, 9)
