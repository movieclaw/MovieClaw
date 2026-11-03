"""字幕播放领域服务（协议无关，docs/design/jellyfin-subtitle.md §3）。

三块能力，Jellyfin 兼容层与未来的网页播放器共用：

1. **轨引用中性模型**：``embedded:<k>`` / ``external:<文件名>`` / ``off``
   ——记忆与选择的通用语言。Jellyfin 的合成流序号（Index）是协议方言，
   **禁止出现在本层**，序号↔引用的换算收敛在协议层做；
2. **字幕内容服务**：读外挂字幕文件 → 编码归一（GBK/BIG5 → UTF-8）→
   按需格式转换（srt↔vtt）。乱码字幕比没字幕更劝退，编码归一是中文
   用户的核心价值，同格式直出也要过这一步（对齐真 Jellyfin 行为）；
3. **默认字幕轨选择**：外挂优先 → default 旗标 → 非 forced 完整字幕，
   forced 沉底（它是"只在说外语片段显示"的部分字幕，仅当只有它可选时
   才选中）——Jellyfin Default 模式在通配语言下的化简。

本层不 import movieclaw_jellyfin（架构守护测试有断言）。
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from pathlib import Path

from movieclaw_db.models import LibraryFile

logger = logging.getLogger("movieclaw_playback.subtitles")

# -- 轨引用中性模型 ---------------------------------------------------------

EMBEDDED_PREFIX = "embedded:"
EXTERNAL_PREFIX = "external:"
SUBTITLE_OFF = "off"  # 用户明确关闭字幕（音轨无此值）


def embedded_track(index: int) -> str:
    """内封轨引用；index 是 audio_streams / subtitle_streams 的数组下标。"""
    return f"{EMBEDDED_PREFIX}{index}"


def external_track(filename: str) -> str:
    """外挂字幕引用；filename 是台账 external_subtitles 里的文件名。"""
    return f"{EXTERNAL_PREFIX}{filename}"


def parse_embedded_track(track: str) -> int | None:
    """内封轨引用 → 数组下标；不是内封引用或格式非法返回 None。"""
    if not track.startswith(EMBEDDED_PREFIX):
        return None
    try:
        index = int(track[len(EMBEDDED_PREFIX):])
    except ValueError:
        return None
    return index if index >= 0 else None


def parse_external_track(track: str) -> str | None:
    """外挂字幕引用 → 台账文件名；不是外挂引用返回 None。"""
    if not track.startswith(EXTERNAL_PREFIX):
        return None
    filename = track[len(EXTERNAL_PREFIX):]
    return filename or None


def is_ai_generated(title: str | None) -> bool:
    """这条外挂字幕是不是本机 AI 生成的（含翻译、双语与本地语音识别）。

    判据是台账里**解析出来的 title 段**，不是整个文件名：title 只包含视频
    stem 之后的 token（``library/subtitles.py`` 的 ``parse_subtitle_tokens``），
    拿整个文件名去找 "ai" 会把片名本来就叫《A.I.》《AI》的片子全标成 AI 生成。

    命名规则见 ``subtitle_gen/tasks.py`` 的 ``_sidecar_path``：
    ``ai`` / ``ai-<语言>`` / ``ai-bilingual-<主>-<次>``，旧版是 ``<语言>.ai``
    （两者的 title 段都以 ai 打头）；本地语音识别的产物是 ``asr``
    （``_asr_sidecar_path``，时间轴与文字同样可能有偏差）。与 ``subtitle_gen/source.py`` 的
    ``_external_provenance`` 是同一套约定的两处实现——分层守护禁止本层
    import movieclaw_api，改命名规则时两边都要动。
    """
    if not title:
        return False
    marker = title.strip().lower()
    return marker in ("ai", "asr") or marker.startswith("ai-")


# -- 字幕内容服务 -----------------------------------------------------------

# 输出 MIME（对齐 Jellyfin MimeTypes 表：ass/ssa 是 text/x-ssa 不是 x-ass）
SUBTITLE_MIME = {
    "srt": "application/x-subrip",
    "vtt": "text/vtt",
    "ass": "text/x-ssa",
    "ssa": "text/x-ssa",
}

# 可互转矩阵：v1 仅 srt↔vtt。ass/ssa 不做跨格式转换（样式会整体丢失，
# 对齐真 Jellyfin"无该格式转换器即失败"的语义）
#: ass→vtt 是给画中画的降级：PiP 窗口只认原生 VTT cue，特效在小窗里本来
#: 也看不清，丢样式保文本是正确取舍。反向（vtt→ass）没有意义，不开。
#: ssa 是 ass 的前身（SSA v4 / ASS v4+），pysubs2 同样读得懂，取舍一致
#: （实测外挂 .ssa《启示》原来 404，iOS 叠加层与系统播放器都拿不到字幕）。
_CONVERTIBLE = {("srt", "vtt"), ("vtt", "srt"), ("ass", "vtt"), ("ssa", "vtt")}


class SubtitleServeError(Exception):
    """字幕无法服务（文件不在/格式不支持/解析失败）。message 面向日志，
    协议层统一按 404 应答。"""


@dataclass(frozen=True)
class SubtitleRef:
    """一次可服务的外挂字幕定位（resolve 的产物，serve 的输入）。"""

    path: Path
    format: str  # srt/ass/ssa/vtt/sup（小写；sup 是二进制位图轨，不进文本管线）


def resolve_external_subtitle(file: LibraryFile, track: str) -> SubtitleRef | None:
    """中性引用 → 可服务定位：校验台账存在并拼出绝对路径。

    只认外挂引用——内封轨在 DirectPlay 下由播放器自行解封装，服务端
    v1 不抽取（返回 None，协议层按 404 处理）。
    """
    filename = parse_external_track(track)
    if filename is None:
        return None
    for entry in file.external_subtitles or []:
        if entry.get("filename") == filename:
            fmt = str(entry.get("format") or "").lower()
            if fmt not in SUBTITLE_MIME:
                return None
            return SubtitleRef(
                path=Path(file.file_path).parent / filename, format=fmt
            )
    return None


# 高频汉字集（简繁通用字为主）：中文编码判定的打分依据——GBK/Big5 互解
# 出来的错字几乎不落在高频集内，真中文过半命中。与生产端
# movieclaw_api.services.subtitle_gen.extract 同一策略的重复实现（分层
# 守护禁止两端互相 import，subtitle-ai-translate.md §7）。
_COMMON_CJK = set(
    "的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以"
    "生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想"
    "看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但"
    "身些与高意进把法此实回二理美点月明其种声全工己话儿者向情部正名定女问力机"
    "给等几很业最间新什打便位因重被走电四第门相次东西再平真听世气信北少关并内"
    "加化由却代军产入先山五太水万市眼体别处总才场师书比住员九笑性通目华报立马"
    "命张活难神数件安表原车白应路期叫死常提感金何更反题必论字幕电影视对白话讲"
)


def _chinese_score(text: str) -> float:
    cjk = [c for c in text if "一" <= c <= "鿿"]
    if not cjk:
        return 0.0
    return sum(c in _COMMON_CJK for c in cjk) / len(cjk)


def _decode_to_utf8_text(raw: bytes, path: Path) -> str:
    """编码归一：非 UTF-8/ASCII（GBK/GB18030/BIG5 常见）统一解码为文本。

    **中文判定不信探测器排序**（有意决策）：GBK 与 Big5/CP949（韩）在短
    样本下高度歧义，charset-normalizer 的首选时常判错、中文字幕全成乱码。
    直接用 gb18030/big5hkscs 各解一遍按高频字占比打分取优（错误编码解出
    的字几乎不命中高频集）；都不像中文再退探测器（韩/日/西文编码）。

    **按行分开解**：字幕站（OpenSubtitles 一类）会往 Big5 / GBK 字幕里插一两行
    UTF-8 的推广语，整份文件于是任何一种编码都严格解不开——原先整份退回 UTF-8
    宽容解码、满屏「�」（2026-09-28 NAS 普查：15 个中文外挂字幕，含《权力的游戏》
    S01E09/E10、《盗梦空间》《功夫熊猫》）。现在本身是 UTF-8 的行照 UTF-8 解，
    其余行合起来判编码、宽容解码，个别坏字节只坏那一个字。
    UTF-16（满篇 \\x00）按行拆会切碎两字节的字符，整份交给探测器。
    全部失败退 errors="replace" 保底出字——出错的字幕也比 404 强。
    """
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        pass

    if b"\x00" not in raw:
        lines = raw.splitlines(keepends=True)
        utf8_texts = [_utf8_line(line) for line in lines]
        pairs = list(zip(lines, utf8_texts, strict=True))
        legacy = b"".join(line for line, text in pairs if text is None)
        encoding = _chinese_encoding(legacy) or _detected_encoding(legacy)
        if encoding is not None:
            return "".join(
                text if text is not None else line.decode(encoding, errors="replace")
                for line, text in pairs
            )

    encoding = _detected_encoding(raw)
    if encoding is not None:
        return raw.decode(encoding, errors="replace")
    logger.warning("字幕文件编码无法确定，已按 UTF-8 宽容解码（可能出现乱码字符）：%s", path)
    return raw.decode("utf-8", errors="replace")


def _utf8_line(line: bytes) -> str | None:
    """这一行本身是 UTF-8 就返回文本，否则 None。

    GBK / Big5 的一两个字偶尔也凑得成合法 UTF-8（解出来是拉丁、西里尔字母），
    所以非 ASCII 字符必须都落在中日韩文字、标点与全角字符里才算。
    """
    try:
        text = line.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if all(ch < "\x80" or "\u2000" <= ch <= "\u9fff" or "\uff00" <= ch <= "\uffef" for ch in text):
        return text
    return None


def _chinese_encoding(raw: bytes) -> str | None:
    """gb18030 / big5hkscs 各宽容解一遍按高频字打分；坏字节多于 2%（至少容忍 8 个）的不算。"""
    scored: list[tuple[float, str]] = []
    for encoding in ("gb18030", "big5hkscs"):
        text = raw.decode(encoding, errors="replace")
        if text.count("\ufffd") > max(8, len(text) // 50):
            continue
        scored.append((_chinese_score(text), encoding))
    if scored:
        best_score, best = max(scored)
        if best_score >= 0.25:
            return best
    return None


def _detected_encoding(raw: bytes) -> str | None:
    """不像中文时退 charset-normalizer（韩 / 日 / 西文编码）。"""
    from charset_normalizer import from_bytes

    match = from_bytes(raw).best()
    if match is None:
        return None
    try:
        raw.decode(match.encoding)
    except (UnicodeDecodeError, LookupError):
        return None
    return match.encoding


def serve_subtitle(ref: SubtitleRef, out_format: str | None) -> tuple[bytes, str]:
    """读取 → 编码归一 → 按需转格式，返回 (UTF-8 字节, Content-Type)。

    ``out_format`` 为 None/空/与源相同 → 原格式直出（仍经编码归一）；
    srt↔vtt 互转；其余组合抛 SubtitleServeError（协议层 404）。
    不做磁盘缓存：文本字幕 <1MB、解析毫秒级，现读现转（有意简化，§3.2）。
    """
    fmt = (out_format or "").lower() or ref.format
    if fmt != ref.format and (ref.format, fmt) not in _CONVERTIBLE:
        raise SubtitleServeError(
            f"不支持的字幕格式转换：{ref.format} → {fmt}（{ref.path.name}）"
        )
    try:
        raw = ref.path.read_bytes()
    except OSError as exc:
        raise SubtitleServeError(f"字幕文件无法读取：{ref.path}（{exc}）") from exc

    text = _decode_to_utf8_text(raw, ref.path)
    if fmt != ref.format:
        import pysubs2

        try:
            # 源格式已知就显式告诉 pysubs2——autodetect 对精简的 ASS 头
            # （缺 [V4+ Styles] 段）会直接认不出来
            subs = pysubs2.SSAFile.from_string(text, format_=ref.format)
            text = subs.to_string(fmt)
        except Exception as exc:  # noqa: BLE001 -- pysubs2 异常类型不穷举
            raise SubtitleServeError(
                f"字幕解析失败，无法转换为 {fmt}：{ref.path}（{exc}）"
            ) from exc
    if fmt == "vtt":
        text = apply_default_cue_line(text)
    return text.encode("utf-8"), SUBTITLE_MIME[fmt]


#: 兜底的 cue 垂直位置：顶边在渲染区 84% 处，单行底边约 89%、双行约 94%——
#: 落在 Apple/Netflix caption safe area（底部留 8~10%）。iOS 的 AVPlayer
#: （原生全屏 / 画中画）按 HLS 规范遵守 cue 的 line 设置，这是**唯一**能
#: 控制系统层字幕位置的手段——那两个表面页面 CSS 够不着，默认渲染贴底。
_DEFAULT_CUE_LINE = "line:84%"
_TIMING_ARROW = "-->"


def apply_default_cue_line(text: str) -> str:
    """给没有自带定位的 VTT cue 追加默认 line 设置。

    只动 timing 行（含 ``-->``）且行内没有任何 line 设置的 cue——字幕作者
    显式定位过的（如顶置注释轨）原样尊重。
    """
    lines = []
    for line in text.splitlines():
        if _TIMING_ARROW in line and "line:" not in line:
            lines.append(f"{line.rstrip()} {_DEFAULT_CUE_LINE}")
        else:
            lines.append(line)
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


async def serve_subtitle_async(
    ref: SubtitleRef, out_format: str | None
) -> tuple[bytes, str]:
    """线程池版（文件读取与解析都是阻塞调用）。"""
    return await asyncio.to_thread(serve_subtitle, ref, out_format)


# -- 默认字幕轨选择 ---------------------------------------------------------


def pick_default_subtitle(file: LibraryFile) -> str | None:
    """默认字幕轨（Jellyfin Default 模式在通配语言下的化简，全端共用）。

    候选排序：外挂 ↓ →（外挂内部）AI 生成 ↓ → default 旗标 ↓ → 非 forced ↓ →
    稳定序；过滤条件 ``外挂 || default || forced``，取首个；全不命中 → None
    （不自动开）。效果：装了外挂字幕就预选外挂（装了就是要看的），外挂里有
    AI 生成的字幕优先选它（产品拍板 2026-08-25：AI 字幕是为这部片现生成的，
    比随片源顺来的外挂更可能是用户想看的那条）；没有外挂则尊重内封 default
    旗标，仅当只有 forced 轨可选时才选 forced。

    现在是默认字幕的**旧规则**（2026-09-29 默认轨策略改造）：全端的默认字幕只经
    ``movieclaw_playback.track_policy`` 算（按媒体库语言、看将要放的音轨），它在没有
    库语言可比、或原声是外语而没有库语言字幕时才退回这里。别处不要直接调它。
    """
    candidates: list[tuple[bool, bool, bool, bool, int, str]] = []
    order = 0
    for k, raw in enumerate(file.subtitle_streams or []):
        track = embedded_track(k)
        candidates.append(
            (False, False, bool(raw.get("default")), bool(raw.get("forced")), order, track)
        )
        order += 1
    for entry in file.external_subtitles or []:
        filename = entry.get("filename")
        if not filename:
            continue
        track = external_track(filename)
        candidates.append(
            (
                True,
                is_ai_generated(entry.get("title")),
                bool(entry.get("default")),
                bool(entry.get("forced")),
                order,
                track,
            )
        )
        order += 1

    eligible = [c for c in candidates if c[0] or c[2] or c[3]]
    if not eligible:
        return None
    eligible.sort(key=lambda c: (not c[0], not c[1], not c[2], c[3], c[4]))
    return eligible[0][5]


def subtitle_track_exists(file: LibraryFile, track: str) -> bool:
    """中性引用当前是否仍有效（重扫/换文件后可能悬空）。"""
    k = parse_embedded_track(track)
    if k is not None:
        return k < len(file.subtitle_streams or [])
    filename = parse_external_track(track)
    if filename is not None:
        return any(
            e.get("filename") == filename for e in file.external_subtitles or []
        )
    return False
