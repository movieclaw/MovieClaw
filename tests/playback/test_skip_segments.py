"""跳过片头 / 片尾的整季比对算法（movieclaw_playback.skip_segments）。

用合成指纹验证设计文档 §2 的每条规则：真片头片尾逐帧几乎一致，配乐复用只是「像」
（每帧翻 7～9 位），同一集的另一个版本不当伙伴，两个版本的片头交替出现也认得出。
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from movieclaw_playback import skip_segments as K

SD = K.HASH_SECONDS


def frames(seconds: float) -> int:
    return int(round(seconds / SD))


def noise(rng: np.random.Generator, seconds: float) -> np.ndarray:
    return rng.integers(0, 2**32, size=frames(seconds), dtype=np.uint64).astype(np.uint32)


def flip_bits(rng: np.random.Generator, hashes: np.ndarray, bits: int) -> np.ndarray:
    """每帧随机翻 ``bits`` 位：0～2 位模拟同一份音频重新编码，7～9 位模拟对白盖住的配乐。"""
    out = hashes.copy()
    for i in range(len(out)):
        for b in rng.choice(32, size=bits, replace=False):
            out[i] ^= np.uint32(1 << int(b))
    return out


def episode(
    rng: np.random.Generator,
    file_id: int,
    number: int,
    *,
    duration: float = 2700.0,
    intro: np.ndarray | None = None,
    intro_at: float = 0.0,
    outro: np.ndarray | None = None,
    outro_to_end: float = 0.0,
    extra: list[tuple[np.ndarray, float]] | None = None,
) -> K.Episode:
    """一集：片头窗 600 秒、片尾窗 420 秒的随机指纹，再把片头 / 片尾 / 额外段贴进去。"""
    bounds = K.window_bounds(duration)
    head = noise(rng, bounds["intro"][1])
    tail = noise(rng, bounds["outro"][1])
    if intro is not None:
        i = frames(intro_at)
        head[i : i + len(intro)] = flip_bits(rng, intro, 1)
    if outro is not None:
        j = len(tail) - frames(outro_to_end) - len(outro)
        tail[j : j + len(outro)] = flip_bits(rng, outro, 1)
    for seg, at in extra or []:
        i = frames(at)
        head[i : i + len(seg)] = seg
    return K.Episode(
        file_id,
        number,
        duration,
        {"intro": K.Window(head, bounds["intro"][0]), "outro": K.Window(tail, bounds["outro"][0])},
    )


def kinds(segments: list[K.Segment]) -> list[str]:
    return [s.kind for s in segments]


def test_finds_intro_and_outro_across_season_with_cold_opens() -> None:
    rng = np.random.default_rng(1)
    intro = noise(rng, 60)
    outro = noise(rng, 120)
    # 片头位置每集不同（冷开场长短不一），片尾一直放到结尾
    eps = [episode(rng, n, n, intro=intro, intro_at=30 + 20 * n, outro=outro) for n in range(1, 7)]
    result = K.detect_season(eps)
    for e in eps:
        segs = result[e.file_id]
        assert kinds(segs) == ["intro", "outro"]
        head, tail = segs
        expected = 30 + 20 * e.episode
        assert abs(head.start - expected) < 1.5 and abs(head.end - (expected + 60)) < 1.5
        assert tail.to_end
        assert abs(tail.end - e.duration) < 1.5


def test_reused_score_under_dialogue_is_rejected() -> None:
    """片中复用的配乐：几集里都「像」（每帧翻 8 位），但不是同一份音频，不认。"""
    rng = np.random.default_rng(2)
    intro = noise(rng, 45)
    score = noise(rng, 40)
    eps = []
    for n in range(1, 9):
        extra = [(flip_bits(rng, score, 5), 300.0)] if n <= 3 else None
        eps.append(episode(rng, n, n, intro=intro, extra=extra))
    result = K.detect_season(eps)
    for e in eps:
        assert kinds(result[e.file_id]) == ["intro"], result[e.file_id]


def test_alternating_intro_versions_need_whole_season() -> None:
    """两个片头版本隔集交替：每个版本只在一半的集里，靠「对得很像的伙伴 ≥2 个」认出。"""
    rng = np.random.default_rng(3)
    a, b = noise(rng, 80), noise(rng, 80)
    eps = [episode(rng, n, n, intro=a if n % 2 else b, intro_at=10.0) for n in range(1, 11)]
    result = K.detect_season(eps)
    assert all(kinds(result[e.file_id]) == ["intro"] for e in eps)


def test_sponsor_ad_and_intro_back_to_back_merge_into_one_segment() -> None:
    """冠名广告紧接着片头（中间不到 3 秒）：合成一段，一个按钮跳完。"""
    rng = np.random.default_rng(4)
    ad, intro = noise(rng, 20), noise(rng, 70)
    eps = [episode(rng, n, n, extra=[(ad, 0.0), (intro, 21.0)]) for n in range(1, 6)]
    result = K.detect_season(eps)
    for e in eps:
        (seg,) = result[e.file_id]
        assert seg.kind == "intro"
        assert seg.start < 1.5 and abs(seg.end - 91) < 1.5


def test_separate_ad_is_other_and_longest_is_intro() -> None:
    rng = np.random.default_rng(5)
    ad, intro = noise(rng, 20), noise(rng, 80)
    eps = [episode(rng, n, n, extra=[(ad, 0.0), (intro, 200.0 + 10 * n)]) for n in range(1, 6)]
    result = K.detect_season(eps)
    for e in eps:
        assert kinds(result[e.file_id]) == ["other", "intro"]


def flip_some(rng: np.random.Generator, hashes: np.ndarray, ratio: float) -> np.ndarray:
    """``ratio`` 比例的帧翻 8 位（这些帧就「不像」了），模拟对齐质量约 1 - ratio 的重复。"""
    out = hashes.copy()
    for i in rng.choice(len(out), size=int(len(out) * ratio), replace=False):
        out[i : i + 1] = flip_bits(rng, out[i : i + 1], 8)
    return out


def test_short_logo_near_start_is_found() -> None:
    """国产剧开头 4 秒各集不同的冠名广告 + 9 秒相同的许可证 / 厂标：认出 4–13 秒。

    华语剧 B E06：0–4.6 秒冠名广告只此一集，4.6–17.3 秒许可证与平台出品和其他集
    逐帧一致（对齐质量 0.97～1.0），15 秒门槛下整段漏掉。前面那几秒由服务端下发时贴到 0。
    """
    rng = np.random.default_rng(11)
    logo, intro = noise(rng, 9), noise(rng, 80)
    eps = [episode(rng, n, n, extra=[(logo, 4.0), (intro, 200.0 + 10 * n)]) for n in range(1, 7)]
    for e in eps:
        segments = K.detect_season(eps)[e.file_id]
        assert kinds(segments) == ["other", "intro"]
        assert abs(segments[0].start - 4) < 1.5 and abs(segments[0].end - 13) < 1.5


def test_short_repeat_with_mediocre_match_is_rejected() -> None:
    """开头区的短重复，只有少数几集「有点像」（剧情配乐盖着对白）：不认。"""
    rng = np.random.default_rng(12)
    score = noise(rng, 11)
    eps = [episode(rng, 1, 1, extra=[(score, 30.0)])]
    eps += [episode(rng, n, n, extra=[(flip_some(rng, score, 0.25), 30.0)]) for n in (2, 3)]
    eps += [episode(rng, n, n) for n in range(4, 9)]
    assert K.detect_season(eps)[1] == []


def test_long_candidate_needs_long_votes() -> None:
    """16 秒的剧情配乐只有一个伙伴完整对上，另一个伙伴只对上其中 10 秒：不能凑成两票。

    华语剧 F E08 28–44 秒（剧情）就是被一段 11 秒短匹配补上第二票的。放在开头区和
    片头之外，短候选本身也不成立。
    """
    rng = np.random.default_rng(13)
    score = noise(rng, 16)
    eps = [
        episode(rng, 1, 1, extra=[(score, 300.0)]),
        episode(rng, 2, 2, extra=[(score, 300.0)]),
        episode(rng, 3, 3, extra=[(score[: frames(10)], 300.0)]),
    ]
    eps += [episode(rng, n, n) for n in range(4, 7)]
    assert K.detect_season(eps)[1] == []


def test_short_ad_right_after_intro_merges_but_far_one_does_not() -> None:
    """片头后紧跟的 10 秒冠名广告并进片头；片中远离片头的 10 秒重复不认。"""
    rng = np.random.default_rng(14)
    intro, ad, far = noise(rng, 80), noise(rng, 10), noise(rng, 10)
    eps = [
        episode(rng, n, n, extra=[(intro, 100.0), (ad, 181.0), (far, 400.0)]) for n in range(1, 6)
    ]
    for e in eps:
        (seg,) = K.detect_season(eps)[e.file_id]
        assert seg.kind == "intro"
        assert abs(seg.start - 100) < 1.5 and abs(seg.end - 191) < 1.5


def _reference_shifts(lhs: np.ndarray, rhs: np.ndarray) -> set[int]:
    """v6 及以前逐帧查字典的写法，作为向量化实现的对照。"""
    left = {value: i for i, value in enumerate(lhs.tolist())}
    right = {value: i for i, value in enumerate(rhs.tolist())}
    shifts = set()
    for value, i in left.items():
        for delta in range(-K.SHIFT_TOLERANCE, K.SHIFT_TOLERANCE + 1):
            j = right.get((value + delta) & 0xFFFFFFFF)
            if j is not None:
                shifts.add(j - i)
    return shifts


@pytest.mark.parametrize("seed", range(5))
def test_vectorized_candidate_shifts_match_reference(seed) -> None:
    """向量化求交与逐帧查字典给出同一组候选位移：含重复值、相邻值和 0 / 2^32 回绕。"""
    rng = np.random.default_rng(100 + seed)
    pool = np.concatenate(
        [
            rng.integers(0, 2**32, size=300, dtype=np.uint64),
            np.array([0, 1, 2, 2**32 - 2, 2**32 - 1], dtype=np.uint64),
        ]
    ).astype(np.uint32)
    lhs = rng.choice(pool, size=800)
    rhs = rng.choice(pool, size=900)
    rhs[100:300] = lhs[400:600] + rng.integers(-2, 3, size=200).astype(np.uint32)
    got = K._candidate_shifts(K._value_index(lhs), K._value_index(rhs))
    assert got == sorted(_reference_shifts(lhs, rhs))


def test_other_versions_of_same_episode_are_not_partners() -> None:
    """同一集的两个版本处处一样：不能当伙伴，否则整段正片都会被认成「重复」。"""
    rng = np.random.default_rng(6)
    head = noise(rng, 600)
    tail = noise(rng, 420)

    def version(file_id: int) -> K.Episode:
        return K.Episode(
            file_id,
            1,
            2700.0,
            {"intro": K.Window(head.copy(), 0.0), "outro": K.Window(tail.copy(), 2280.0)},
        )

    eps = [version(1), version(2), episode(rng, 3, 2), episode(rng, 4, 3)]
    result = K.detect_season(eps)
    assert all(result[e.file_id] == [] for e in eps)


def test_fewer_than_three_episodes_gives_nothing() -> None:
    rng = np.random.default_rng(7)
    intro = noise(rng, 60)
    eps = [episode(rng, n, n, intro=intro) for n in (1, 2)]
    assert K.detect_season(eps) == {1: [], 2: []}


def test_outro_window_keeps_only_last_segment() -> None:
    """片尾窗里的固定配乐场景（深夜食堂每集都有的吃饭戏）不当片尾，只认最后一段。"""
    rng = np.random.default_rng(8)
    scene, credits = noise(rng, 50), noise(rng, 90)
    eps = []
    for n in range(1, 7):
        e = episode(rng, n, n, outro=credits)
        tail = e.windows["outro"].hashes
        tail[frames(60) : frames(60) + len(scene)] = flip_bits(rng, scene, 1)
        eps.append(e)
    result = K.detect_season(eps)
    for e in eps:
        (seg,) = result[e.file_id]
        assert seg.kind == "outro" and seg.to_end


def test_fingerprint_file_roundtrip() -> None:
    rng = np.random.default_rng(9)
    head, tail = noise(rng, 30), noise(rng, 20)
    raw = K.encode_fingerprint(
        {"size": 1, "windows": {"intro": {"start": 0.0}, "outro": {"start": 100.0}}},
        {"intro": head.astype("<u4").tobytes(), "outro": tail.astype("<u4").tobytes()},
    )
    meta, windows = K.decode_fingerprint(raw)
    assert meta["size"] == 1
    assert np.array_equal(windows["intro"].hashes, head)
    assert windows["outro"].start == 100.0 and np.array_equal(windows["outro"].hashes, tail)
    assert K.decode_fingerprint(b"garbage") is None


def test_worker_entry_point(tmp_path) -> None:
    """子进程入口：读指纹文件、算、一行 JSON 写回；读不了的文件报在 unreadable 里。"""
    rng = np.random.default_rng(10)
    intro = noise(rng, 60)
    items = []
    for n in range(1, 5):
        e = episode(rng, n, n, intro=intro, intro_at=5.0)
        path = tmp_path / f"{n}.fp"
        path.write_bytes(
            K.encode_fingerprint(
                {"windows": {k: {"start": w.start} for k, w in e.windows.items()}},
                {k: w.hashes.astype("<u4").tobytes() for k, w in e.windows.items()},
            )
        )
        items.append({"file_id": n, "episode": n, "duration": e.duration, "path": str(path)})
    items.append({"file_id": 99, "episode": 9, "duration": 2700.0, "path": str(tmp_path / "x")})
    proc = subprocess.run(
        [sys.executable, "-m", "movieclaw_playback.skip_segments"],
        input=json.dumps({"episodes": items}),
        capture_output=True,
        text=True,
        check=True,
    )
    out = json.loads(proc.stdout)
    assert out["algo_version"] == K.ALGO_VERSION
    assert out["unreadable"] == [99]
    for n in range(1, 5):
        (seg,) = out["results"][str(n)]
        assert seg["type"] == "intro" and abs(seg["start_ms"] - 5000) < 1500


def encoded_episodes(scenario: str) -> list[K.Episode]:
    """真实 AAC 视频提取的指纹：生成方法、原始剪辑边界见同目录 README。"""
    name = "fingerprints" if scenario == "aligned" else scenario
    path = Path(__file__).parent / f"fixtures/skip_segments/{name}.npz"
    with np.load(path, allow_pickle=False) as arrays:
        return [
            K.Episode(
                n,
                n,
                960.0,
                {
                    name: K.Window(arrays[f"{n}_{name}"].copy(), start)
                    for name, start in (("intro", 0.0), ("outro", 720.0))
                },
            )
            for n in range(1, 4)
        ]


@pytest.mark.parametrize("scenario", ["aligned", "shifted"])
def test_encoded_media_keeps_separate_ads_at_same_positions(scenario) -> None:
    """三个独立重复段的位置固定或整体平移，都不能只保留最长的真片头。"""
    for file_id, segments in K.detect_season(encoded_episodes(scenario)).items():
        offset = 7 * file_id if scenario == "shifted" else 0
        heads = [s for s in segments if s.kind != "outro"]
        assert kinds(heads) == ["other", "intro", "other"]
        for segment, (start, end) in zip(heads, [(5, 30), (65, 135), (180, 210)], strict=True):
            assert abs(segment.start - start - offset) < 3
            assert abs(segment.end - end - offset) < 3


@pytest.mark.parametrize("scenario", ["aligned", "shifted"])
def test_encoded_media_uses_last_outro_even_when_earlier_scene_is_longer(scenario) -> None:
    """755–825 秒是重复配乐剧情；真正片尾 920–960 秒虽短，也不能被它挤掉。"""
    for segments in K.detect_season(encoded_episodes(scenario)).values():
        tails = [s for s in segments if s.kind == "outro"]
        assert len(tails) == 1
        assert abs(tails[0].start - 920) < 3
        assert abs(tails[0].end - 960) < 3
        assert tails[0].to_end


def test_encoded_media_rejects_unique_ads_and_short_repeats() -> None:
    """各集不同的广告、相同但只有 8 秒的广告均不能成为跳过段。"""
    for segments in K.detect_season(encoded_episodes("unique")).values():
        assert kinds(segments) == ["intro", "outro"]
        assert abs(segments[0].start - 65) < 3
        assert abs(segments[0].end - 135) < 3
        assert abs(segments[1].start - 920) < 3


def nas_episodes(name: str) -> list[K.Episode]:
    """真实剧集的开头窗，原片时长和原始指纹一同保存在夹具里。"""
    path = Path(__file__).parent / f"fixtures/skip_segments/nas-{name}.npz"
    with np.load(path, allow_pickle=False) as arrays:
        return [
            K.Episode(
                n,
                n,
                float(arrays["durations"][n - 1]),
                {
                    "intro": K.Window(arrays[str(n)].copy(), 0.0),
                },
            )
            for n in range(1, 5)
        ]


def test_real_episode_short_match_does_not_borrow_long_partners_boundaries() -> None:
    """NAS日剧 C S1 前四集：第一集 125–144 秒是固定开店片头，不能漏掉。

    与第二集的匹配覆盖 0–154 秒，与第四集的匹配仅覆盖 125–144 秒。直接取两者
    边界中位数会凭空扩成 62–149 秒，再与另一个候选重叠而被丢弃；支持者只能贡献
    当前候选内的重叠区间。原始片源边界画面已核对，NPZ 是实际音轨提取的指纹。

    算法 v6 起片头窗认短段，紧接其后的 144–152 秒片名卡（「深夜食堂 第一話」，
    2026-10-04 逐 2 秒抓帧核对，156 秒才进剧情）作为贴邻短段并入，终点到 152 秒。
    """
    segments = K.detect_season(nas_episodes("diner"))[1]
    late = [s for s in segments if s.kind == "other" and s.start > 120]
    assert len(late) == 1
    assert 124 < late[0].start < 127
    assert 150 < late[0].end < 155


def test_real_quiet_intro_keeps_its_shorter_first_part() -> None:
    """英剧 A S03E03：278–301 秒已是演员署名片头，v1 只留下 305–347 秒后半段。"""
    segments = K.detect_season(nas_episodes("crown"))[3]
    first = [s for s in segments if 275 < s.start < 280]
    assert len(first) == 1 and 299 < first[0].end < 303
    assert any(302 < s.start < 307 and 344 < s.end < 349 for s in segments)


def test_real_duplicate_audio_windows_do_not_supply_independent_votes() -> None:
    """华语剧 J E02/E03 的完整十分钟开头音轨相同，不能当两份独立证据。

    E01 的 428–452 秒是公路旁人物对话，两个相同伙伴各投一票会误标可跳片段。
    真片头另有不同的 E04 支持，去掉重复票以后应继续保留四集的真实片头。
    """
    episodes = nas_episodes("reset")
    assert np.array_equal(episodes[1].windows["intro"].hashes, episodes[2].windows["intro"].hashes)
    results = K.detect_season(episodes)
    assert all(s.end < 100 for s in results[1])
    assert all(any(s.kind == "intro" and s.end > 90 for s in ss) for ss in results.values())


def test_identical_short_windows_can_be_real_opening_sequences() -> None:
    """短片的整个采样窗可能都在片头里，不能仅因窗口相同就当成错封的重复音轨。"""
    hashes = noise(np.random.default_rng(99), 30)
    episodes = [K.Episode(n, n, 120, {"intro": K.Window(hashes.copy(), 0)}) for n in range(1, 4)]
    results = K.detect_season(episodes)
    assert all(len(ss) == 1 and ss[0].kind == "intro" and ss[0].end > 28 for ss in results.values())


def nas_outro_episodes(name: str) -> list[K.Episode]:
    """保留实片取样的完整伙伴集合，避免减少集数改变多数票门槛。"""
    path = Path(__file__).parent / f"fixtures/skip_segments/nas-{name}-outro.npz"
    with np.load(path, allow_pickle=False) as arrays:
        return [
            K.Episode(
                int(n),
                int(n),
                float(arrays["durations"][i]),
                {
                    "outro": K.Window(arrays[str(n)].copy(), float(arrays["starts"][i])),
                },
            )
            for i, n in enumerate(arrays["numbers"])
        ]


def test_real_outro_does_not_fall_back_to_earlier_reused_score() -> None:
    """华语剧 A S01E01 的 2368–2385 秒是剧情中的资料画面，不是片尾。

    该处与 E11、E24 的配乐匹配较好，但两对后面还有更晚的共享段。不能在后段未过
    共识门槛时退回较早的配乐。保留 11 集比对上下文：只取命中的三集会改变多数门槛。
    """
    results = K.detect_season(nas_outro_episodes("threebody"))
    assert results[1] == []
    # 同批里的真实片尾仍能识别到文件结尾，不能用「片尾都不认」掩盖误报。
    assert len(results[10]) == 1 and results[10][0].to_end


def test_real_complete_audio_recovers_actual_credits() -> None:
    """华语剧 J E03 改用完整第二轨后的真实服务产物：片尾应在 42 分钟附近。"""
    results = K.detect_season(nas_outro_episodes("reset-complete"))
    assert len(results[3]) == 1
    tail = results[3][0]
    assert 2517 < tail.start < 2523 and 2666 < tail.end < 2672 and tail.to_end
    # 更完整的独立证据也找回 E01 的片尾前半段，而不是简单删除错误结果。
    assert len(results[1]) == 1 and 2537 < results[1][0].start < 2543


@pytest.mark.xfail(
    strict=True,
    reason="已复现未修复：片尾音乐延续进彩蛋，音频终点越过真实画面边界（见夹具 README）",
)
def test_real_outro_must_not_cover_post_credit_story() -> None:
    """日本动画 A E01：1368 秒已恢复角色剧情，不能跳到音频匹配终点 1379 秒。

    这是明确保留的失败用例，不代表修复完成。1365 秒尚有字幕，1368 秒已是角色
    在屋内的连续剧情；使用较宽的 1368 秒上界，不把抓帧精度当成精确剪辑点。
    """
    results = K.detect_season(nas_outro_episodes("spy"))
    assert all(s.end <= 1368 for s in results[1])
    # 允许证据不足时不报 E01，但不能靠禁止所有片尾掩盖误报。
    assert any(s.to_end for s in results[4])


@pytest.mark.xfail(
    strict=True,
    reason="已人工标注未修复：韩剧 A结尾配乐下仍有本集剧情，不能标成片尾",
)
@pytest.mark.parametrize("number,story", [(2, (4114.0, 4140.0)), (3, (4507.0, 4524.0))])
def test_real_outro_must_not_cover_user_labeled_story(
    number: int, story: tuple[float, float]
) -> None:
    """用户核对原片上下文后标注的剧情区间，不用识别输出反推正确答案。

    E02 68:34–69:00 全为本集剧情；E03 从视频起点 75:07 算，前 17 秒为本集
    剧情，18–36 秒为本集片段，39 秒起为下集预告。这里只约束确认不可跳的剧情。
    """
    results = K.detect_season(nas_outro_episodes("mister"))
    assert all(K._overlap((s.start, s.end), story) == 0 for s in results[number])


@pytest.mark.parametrize("cut", [1, 4, 12])
def test_truncated_fingerprint_is_invalid(cut):
    raw = K.encode_fingerprint(
        {"windows": {"intro": {"start": 0.0}}},
        {"intro": np.arange(3, dtype="<u4").tobytes()},
    )
    assert K.decode_fingerprint(raw[:-cut]) is None
