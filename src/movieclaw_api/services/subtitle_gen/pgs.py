"""PGS → SRT 适配层：能力检测、轨道抽取与 ``seconv`` OCR。

轨道（``.sup``）交给 ``media_extract`` 的共享整文件抽取，与播放器同一份产物；
seconv 起在独立进程组里，停止任务或停机时随之结束（见 ``process``）。

这一层只负责把内封 PGS 变成可复用的文本中间品，不参与选源、翻译和
最终 sidecar 命名。官方 Docker 镜像按目标架构内置 Subtitle Edit 5.1 的
``seconv`` 与 Tesseract；源码直跑时也可从 ``PATH`` 或
``MOVIECLAW_SECONV_PATH`` 使用用户安装的版本。

跨平台边界在真正启动任务前完成检测：只接受 Subtitle Edit 官方提供的
Windows/Linux/macOS x64/ARM64 组合，并分别校验 ffmpeg、seconv、OCR
引擎及语言包。检测失败返回结构化中文说明，绝不等后台任务启动后才静默跳过。
这些都是部署环境的属性，进程启动时在后台探测一次并缓存（见 ``_Environment``），
预检只查表，不在请求里起子进程；改了环境需重启生效。
"""

from __future__ import annotations

import asyncio
import logging
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass, replace
from pathlib import Path
from typing import TYPE_CHECKING

from movieclaw_api.i18n.stored import reference, source_text, stored_fields
from movieclaw_api.services import media_extract
from movieclaw_api.services.subtitle_gen import process

if TYPE_CHECKING:
    from movieclaw_api.services.subtitle_gen.source import SourceCandidate
    from movieclaw_db.models import LibraryFile


logger = logging.getLogger("movieclaw_api.subtitle_gen")

PGS_CODECS = frozenset({"hdmv_pgs_subtitle", "pgs", "sup"})

_SECONV_PROBE_TIMEOUT = 10.0
_OCR_PROBE_TIMEOUT = 20.0
_EXTRACT_TIMEOUT = 180.0
_OCR_TIMEOUT = 3600.0
#: 环境只在启动时探测一次；缺组件的提示都要讲清楚装好之后怎么生效。
_RESTART_HINT = stored_fields("library.subtitleOcr.restart")

_ARCH_ALIASES = {
    "amd64": "x64",
    "x86_64": "x64",
    "aarch64": "arm64",
    "arm64": "arm64",
}
_PLATFORM_LABELS = {
    "darwin": "macOS",
    "linux": "Linux",
    "win32": "Windows",
}

# seconv 对 Tesseract 传语言码；中文需从媒体元数据的 ISO 639 写法转换成
# Tesseract 的 chi_sim/chi_tra，其他常见语言沿用三字码。
_TESSERACT_LANGUAGES = {
    "chi": "chi_sim",
    "chs": "chi_sim",
    "zho": "chi_sim",
    "cht": "chi_tra",
    "eng": "eng",
    "fre": "fra",
    "fra": "fra",
    "deu": "deu",
    "ger": "deu",
    "jpn": "jpn",
    "kor": "kor",
    "spa": "spa",
    "ita": "ita",
    "por": "por",
    "rus": "rus",
}

# PaddleOCR 的命令行语言码与 Tesseract 不同。只映射项目能明确确认的常见
# 字幕语言；未知语言宁可在预检提示，也不默认用英语产出一整部乱码字幕。
_PADDLE_LANGUAGES = {
    "chi": "ch",
    "chs": "ch",
    "zho": "ch",
    "cht": "chinese_cht",
    "eng": "en",
    "fre": "fr",
    "fra": "fr",
    "deu": "german",
    "ger": "german",
    "jpn": "japan",
    "kor": "korean",
    "spa": "es",
    "ita": "it",
    "por": "pt",
    "rus": "ru",
}

# 用户确认的是“PGS 图片里写的语言”，不是 Tesseract/Paddle 的内部参数。
# 对外统一使用项目已有的 ISO 639-2/B 风格 token，简繁中文单独保留，避免
# 通用字幕语言规范化把 ``cht`` 合并成 ``chi`` 后选错识别模型。
# 值是中文原文（落库判定的回滚值与启动日志用）；给人看的地方用 library.subtitleLanguages.* 引用
OCR_LANGUAGE_LABELS: dict[str, str] = {
    code: source_text(f"library.subtitleLanguages.{code}")
    for code in ("eng", "chs", "cht", "jpn", "kor", "fre", "ger", "spa", "ita", "por", "rus")
}

_OCR_LANGUAGE_ALIASES = {
    "en": "eng",
    "eng": "eng",
    "english": "eng",
    "chs": "chs",
    "zh-cn": "chs",
    "zh-hans": "chs",
    # i18n-ignore: language aliases parsed from track titles
    "简体": "chs",
    # i18n-ignore: language aliases parsed from track titles
    "简中": "chs",
    "cht": "cht",
    "zh-tw": "cht",
    "zh-hant": "cht",
    # i18n-ignore: language aliases parsed from track titles
    "繁体": "cht",
    # i18n-ignore: language aliases parsed from track titles
    "繁體": "cht",
    # i18n-ignore: language aliases parsed from track titles
    "繁中": "cht",
    # chi/zho/zh 不携带简繁信息；用于自动推荐时必须让用户确认。
    "chi": "chs",
    "zho": "chs",
    "zh": "chs",
    "ja": "jpn",
    "jp": "jpn",
    "jpn": "jpn",
    "ko": "kor",
    "kor": "kor",
    "fr": "fre",
    "fre": "fre",
    "fra": "fre",
    "de": "ger",
    "ger": "ger",
    "deu": "ger",
    "es": "spa",
    "spa": "spa",
    "it": "ita",
    "ita": "ita",
    "pt": "por",
    "por": "por",
    "ru": "rus",
    "rus": "rus",
}

_AMBIGUOUS_CHINESE_CODES = frozenset({"chi", "zho", "zh", "chinese"})
_UNKNOWN_LANGUAGE_CODES = frozenset({"", "und", "unk", "unknown", "none"})
_TITLE_LANGUAGE_HINTS = (
    # i18n-ignore: language aliases parsed from track titles
    (("繁体", "繁體", "繁中", "traditional chinese", "zh-hant"), "cht"),
    # i18n-ignore: language aliases parsed from track titles
    (("简体", "簡體", "简中", "簡中", "simplified chinese", "zh-hans"), "chs"),
    # i18n-ignore: language aliases parsed from track titles
    (("english", "英语", "英語"), "eng"),
    # i18n-ignore: language aliases parsed from track titles
    (("japanese", "日本語", "日语", "日語"), "jpn"),
    # i18n-ignore: language aliases parsed from track titles
    (("korean", "한국어", "韩语", "韓語"), "kor"),
    # i18n-ignore: language aliases parsed from track titles
    (("french", "français", "法语", "法語"), "fre"),
    # i18n-ignore: language aliases parsed from track titles
    (("german", "deutsch", "德语", "德語"), "ger"),
    # i18n-ignore: language aliases parsed from track titles
    (("spanish", "español", "西班牙语", "西班牙語"), "spa"),
    # i18n-ignore: language aliases parsed from track titles
    (("italian", "italiano", "意大利语", "義大利語"), "ita"),
    # i18n-ignore: language aliases parsed from track titles
    (("portuguese", "português", "葡萄牙语", "葡萄牙語"), "por"),
    # i18n-ignore: language aliases parsed from track titles
    (("russian", "русский", "俄语", "俄語"), "rus"),
)


class PgsConversionError(Exception):
    """PGS 转换失败；保留诊断引用，避免历史文本固定在某个语言。"""

    def __init__(self, message: str | dict):
        self.reference = message if isinstance(message, dict) else None
        super().__init__(message["message"] if self.reference else message)


@dataclass(frozen=True)
class Capability:
    """当前主机转换某条 PGS 的完整能力结论。"""

    available: bool
    platform: str
    architecture: str
    engine: str | None
    ocr_language: str | None
    cached: bool
    message: str
    suggestions: tuple[str, ...] = ()
    seconv_path: str | None = None
    message_ref: dict | None = None
    suggestion_refs: tuple[dict, ...] = ()


@dataclass(frozen=True)
class OcrLanguageDecision:
    """PGS 识别语言的推断结论；不确定时由确认框覆盖 ``code``。"""

    code: str | None
    label: str | None
    confirmation_required: bool
    reason: str
    reason_message: dict | None = None


def language_decision(code, label, confirmation_required, reason) -> OcrLanguageDecision:
    return OcrLanguageDecision(
        code,
        label,
        confirmation_required,
        reason["message"] if isinstance(reason, dict) else reason,
        reason if isinstance(reason, dict) else None,
    )


def is_pgs_codec(codec: str | None) -> bool:
    return str(codec or "").strip().lower() in PGS_CODECS


def normalize_ocr_language(language: str | None) -> str | None:
    """把轨道/用户语言写法收敛为 OCR 对外 token；不支持时返回 ``None``。"""
    raw = str(language or "").strip().lower()
    return _OCR_LANGUAGE_ALIASES.get(raw)


def _title_language_hint(title: str | None) -> str | None:
    normalized = str(title or "").strip().casefold()
    for hints, code in _TITLE_LANGUAGE_HINTS:
        if any(hint.casefold() in normalized for hint in hints):
            return code
    return None


def infer_ocr_language(
    file: LibraryFile,
    candidate: SourceCandidate,
    original_language: str | None,
) -> OcrLanguageDecision:
    """按轨道元数据 → 轨道标题 → 影片原语言推断，异常时要求用户确认。"""
    raw_language = ""
    title = ""
    try:
        stream = (file.subtitle_streams or [])[int(candidate.key)]
        raw_language = str(stream.get("language") or "").strip()
        title = str(stream.get("title") or "").strip()
    except (IndexError, TypeError, ValueError):
        raw_language = str(candidate.language or "").strip()

    raw_key = raw_language.lower()
    metadata_code = normalize_ocr_language(raw_language)
    title_code = _title_language_hint(title)

    if metadata_code and title_code:
        if raw_key in _AMBIGUOUS_CHINESE_CODES and title_code in {"chs", "cht"}:
            return language_decision(
                title_code,
                OCR_LANGUAGE_LABELS[title_code],
                False,
                stored_fields(
                    "library.subtitleOcr.titleLanguage",
                    title=title,
                    language=reference("library.subtitleLanguages." + title_code),
                ),
            )
        if metadata_code != title_code:
            return language_decision(
                title_code,
                OCR_LANGUAGE_LABELS[title_code],
                True,
                (
                    stored_fields(
                        "library.subtitleOcr.conflictingLanguage",
                        raw=raw_language,
                        title=title,
                        language=reference("library.subtitleLanguages." + title_code),
                    )
                ),
            )
        return language_decision(
            metadata_code,
            OCR_LANGUAGE_LABELS[metadata_code],
            False,
            stored_fields(
                "library.subtitleOcr.metadataLanguage",
                language=reference("library.subtitleLanguages." + metadata_code),
            ),
        )

    if metadata_code:
        ambiguous = raw_key in _AMBIGUOUS_CHINESE_CODES
        return language_decision(
            metadata_code,
            OCR_LANGUAGE_LABELS[metadata_code],
            ambiguous,
            (
                stored_fields("library.subtitleOcr.ambiguousChinese")
                if ambiguous
                else stored_fields(
                    "library.subtitleOcr.metadataLanguage",
                    language=reference("library.subtitleLanguages." + metadata_code),
                )
            ),
        )

    if title_code:
        return language_decision(
            title_code,
            OCR_LANGUAGE_LABELS[title_code],
            False,
            stored_fields(
                "library.subtitleOcr.titleAutoLanguage",
                title=title,
                language=reference("library.subtitleLanguages." + title_code),
            ),
        )

    original_code = normalize_ocr_language(original_language)
    if original_code and raw_key in _UNKNOWN_LANGUAGE_CODES:
        return language_decision(
            original_code,
            OCR_LANGUAGE_LABELS[original_code],
            True,
            (
                stored_fields(
                    "library.subtitleOcr.originalLanguage",
                    language=reference("library.subtitleLanguages." + original_code),
                )
            ),
        )

    if raw_key not in _UNKNOWN_LANGUAGE_CODES:
        reason = stored_fields("library.subtitleOcr.unsupportedLanguage", language=raw_language)
    else:
        reason = stored_fields("library.subtitleOcr.unknownLanguage")
    return language_decision(None, None, True, reason)


def _runtime() -> tuple[str, str, dict | None]:
    """返回展示平台、规范架构与不兼容原因。"""
    platform_name = _PLATFORM_LABELS.get(sys.platform)
    raw_arch = platform.machine().strip().lower()
    architecture = _ARCH_ALIASES.get(raw_arch)
    if platform_name is None:
        return (
            sys.platform or stored_fields("library.subtitleOcr.unknownSystem")["message"],
            raw_arch or stored_fields("library.subtitleOcr.unknownArch")["message"],
            (stored_fields("library.subtitleOcr.unsupportedSystem")),
        )
    if architecture is None:
        return (
            platform_name,
            raw_arch or stored_fields("library.subtitleOcr.unknownArch")["message"],
            (
                stored_fields(
                    "library.subtitleOcr.unsupportedArch",
                    platform=platform_name,
                    architecture=raw_arch or reference("library.subtitleOcr.unknown"),
                )
            ),
        )
    return platform_name, architecture, None




def _resolve_seconv() -> str | None:
    override = os.environ.get("MOVIECLAW_SECONV_PATH", "").strip()
    candidates = [override] if override else []
    if sys.platform == "linux":
        candidates.append("/opt/movieclaw/seconv/seconv")
    candidates.extend(filter(None, (shutil.which("seconv"), shutil.which("seconv.exe"))))
    for candidate in candidates:
        path = Path(candidate).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def _run_probe(argv: list[str], timeout: float) -> tuple[bool, str]:
    """运行轻量健康探针；收敛各平台的启动异常和短错误文本。"""
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            creationflags=creationflags,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)
    output = (proc.stdout or proc.stderr or "").strip().replace("\n", " ")[:240]
    return proc.returncode == 0, output


def _tesseract_languages(executable: str) -> tuple[set[str], str | None]:
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        proc = subprocess.run(
            [executable, "--list-langs"],
            capture_output=True,
            text=True,
            timeout=_OCR_PROBE_TIMEOUT,
            creationflags=creationflags,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return set(), str(exc)
    if proc.returncode != 0:
        # i18n-ignore: language aliases parsed from track titles
        return set(), (proc.stderr or proc.stdout or "未知错误").strip()[:240]
    lines = {line.strip() for line in proc.stdout.splitlines() if line.strip()}
    return {line for line in lines if " " not in line}, None


def _base_capability(
    *,
    available: bool,
    platform_name: str,
    architecture: str,
    message: str | dict,
    suggestions: tuple = (),
    engine: str | None = None,
    ocr_language: str | None = None,
    seconv_path: str | None = None,
    cached: bool = False,
) -> Capability:
    return Capability(
        available=available,
        platform=platform_name,
        architecture=architecture,
        engine=engine,
        ocr_language=ocr_language,
        cached=cached,
        message=message["message"] if isinstance(message, dict) else message,
        message_ref=message if isinstance(message, dict) else None,
        suggestions=tuple(
            item["message"] if isinstance(item, dict) else item for item in suggestions
        ),
        suggestion_refs=tuple(
            item if isinstance(item, dict) else {"message_key": None, "message": item}
            for item in suggestions
        ),
        seconv_path=seconv_path,
    )


@dataclass(frozen=True)
class _Environment:
    """本机 PGS 转换环境的探测快照：进程生命周期内只探测一次。

    平台架构、ffmpeg、seconv、OCR 引擎与 Tesseract 语言包都是部署时就定下的
    事实，运行期间不会变。此前每次预检都现场探测，语言需要确认时还要把 11 种
    语言逐个探一遍，一次请求串行起 24 个子进程（seconv 是 .NET 程序，NAS 上
    每次冷启动一两秒），iOS 与网页都因此撞上 20 秒超时。现在启动时在后台探测
    一次，之后按语言下结论只是查表。改了环境（装语言包、换 seconv、改
    ``MOVIECLAW_PGS_OCR_ENGINE``）需要重启 MovieClaw 才会重新检测。

    字段按探测顺序填写；前一步已判定不可用时后面的步骤不再执行，保持原来
    「能力缺失时尽早给出第一条原因」的语义。
    """

    platform_name: str
    architecture: str
    runtime_error: str | None = None
    runtime_message: dict | None = None
    ffmpeg: bool = False
    seconv_path: str | None = None
    seconv_healthy: bool = False
    seconv_detail: str = ""
    engine: str = "auto"
    paddle_path: str | None = None
    paddle_healthy: bool = False
    paddle_detail: str = ""
    tesseract_path: str | None = None
    tesseract_languages: frozenset[str] = frozenset()
    tesseract_error: str | None = None


_ENVIRONMENT: _Environment | None = None
# 预检、确认生成、后台任务都在线程池里取能力结论，可能同时撞上首次探测；
# 用锁保证只探测一次，后来者等同一份结果，而不是各自再起一批子进程。
_ENVIRONMENT_LOCK = threading.Lock()


def _probe_environment() -> _Environment:
    """（阻塞）真正起子进程探测本机环境：seconv、PaddleOCR、Tesseract 各至多一次。"""
    platform_name, architecture, runtime_message = _runtime()
    runtime_error = runtime_message["message"] if runtime_message else None
    env = _Environment(platform_name=platform_name, architecture=architecture)
    if runtime_error:
        return replace(env, runtime_error=runtime_error, runtime_message=runtime_message)
    if shutil.which("ffmpeg") is None:
        return env
    env = replace(env, ffmpeg=True)

    seconv = _resolve_seconv()
    if seconv is None:
        return env
    healthy, detail = _run_probe([seconv, "--version"], _SECONV_PROBE_TIMEOUT)
    env = replace(env, seconv_path=seconv, seconv_healthy=healthy, seconv_detail=detail)
    if not healthy:
        return env

    requested = os.environ.get("MOVIECLAW_PGS_OCR_ENGINE", "auto").strip().lower()
    env = replace(env, engine=requested)
    if requested not in {"auto", "paddle", "tesseract"}:
        return env

    if requested in {"auto", "paddle"}:
        paddle = shutil.which("paddleocr")
        if paddle is not None:
            paddle_ok, paddle_detail = _run_probe([paddle, "--help"], _OCR_PROBE_TIMEOUT)
            env = replace(
                env, paddle_path=paddle, paddle_healthy=paddle_ok, paddle_detail=paddle_detail
            )
        if requested == "paddle":
            return env

    tesseract = shutil.which("tesseract")
    if tesseract is not None:
        installed, error = _tesseract_languages(tesseract)
        env = replace(
            env,
            tesseract_path=tesseract,
            tesseract_languages=frozenset(installed),
            tesseract_error=error,
        )
    return env


def _environment() -> _Environment:
    """取本机环境快照；首次调用（通常是启动预热）才真正探测。"""
    global _ENVIRONMENT
    if _ENVIRONMENT is None:
        with _ENVIRONMENT_LOCK:
            if _ENVIRONMENT is None:
                _ENVIRONMENT = _probe_environment()
                _log_environment(_ENVIRONMENT)
    return _ENVIRONMENT


def _log_environment(env: _Environment) -> None:
    """启动日志里写一句结论：部署者不必等到点 AI 字幕才知道图片字幕能不能识别。"""
    options = [label for code, label in OCR_LANGUAGE_LABELS.items() if _decide(env, code).available]
    if options:
        logger.info("PGS 图片字幕识别自检通过，可识别：%s", "、".join(options))
    else:
        logger.info(
            "当前设备不能识别 PGS 图片字幕（只有图片字幕的片子无法生成 AI 字幕）：%s",
            _decide(env, "eng").message,
        )


def reset_capability_cache() -> None:
    """测试用：丢掉环境快照，下次取能力时重新探测。"""
    global _ENVIRONMENT
    with _ENVIRONMENT_LOCK:
        _ENVIRONMENT = None


def warm_capability() -> None:
    """（阻塞，调用方须放线程池）启动时预热环境探测，让首次预检直接命中缓存。"""
    _environment()


def detect_capability(language: str | None) -> Capability:
    """检测当前设备能否把指定语言的 PGS 转为 SRT。

    ``MOVIECLAW_PGS_OCR_ENGINE`` 可设为 ``paddle`` 或 ``tesseract``；默认
    ``auto`` 优先选择已安装且健康的 PaddleOCR，失败后再尝试 Tesseract。
    环境只在进程内探测一次（见 ``_Environment``），这里按语言查表下结论。
    """
    return _decide(_environment(), language)


def _decide(env: _Environment, language: str | None) -> Capability:
    """用环境快照回答「这种语言的 PGS 能不能转」：纯计算，不起任何子进程。"""
    platform_name, architecture = env.platform_name, env.architecture
    if env.runtime_error:
        return _base_capability(
            available=False,
            platform_name=platform_name,
            architecture=architecture,
            message=env.runtime_message or env.runtime_error,
            suggestions=(stored_fields("library.subtitleOcr.useSupportedHost"),),
        )

    if not env.ffmpeg:
        return _base_capability(
            available=False,
            platform_name=platform_name,
            architecture=architecture,
            message=stored_fields("library.subtitleOcr.ffmpegMissing"),
            suggestions=(
                stored_fields("library.subtitleOcr.installFfmpeg"),
                _RESTART_HINT,
            ),
        )

    seconv = env.seconv_path
    if seconv is None:
        return _base_capability(
            available=False,
            platform_name=platform_name,
            architecture=architecture,
            message=stored_fields(
                "library.subtitleOcr.seconvMissing",
                platform=platform_name,
                architecture=architecture,
            ),
            suggestions=(
                stored_fields("library.subtitleOcr.installSeconv"),
                stored_fields("library.subtitleOcr.seconvPath"),
                stored_fields("library.subtitleOcr.dockerSeconv"),
                _RESTART_HINT,
            ),
        )
    if not env.seconv_healthy:
        return _base_capability(
            available=False,
            platform_name=platform_name,
            architecture=architecture,
            message=stored_fields(
                "library.subtitleOcr.seconvStartFailed",
                detail=env.seconv_detail or reference("library.subtitleOcr.noVersion"),
            ),
            suggestions=(
                stored_fields("library.subtitleOcr.checkSeconv"),
                _RESTART_HINT,
            ),
            seconv_path=seconv,
        )

    raw_lang = str(language or "").strip().lower()
    lang = normalize_ocr_language(raw_lang) or raw_lang
    requested = env.engine
    if requested not in {"auto", "paddle", "tesseract"}:
        return _base_capability(
            available=False,
            platform_name=platform_name,
            architecture=architecture,
            message=(stored_fields("library.subtitleOcr.engineInvalid", engine=repr(requested))),
            suggestions=(_RESTART_HINT,),
            seconv_path=seconv,
        )

    paddle_error: dict | None = None
    if requested in {"auto", "paddle"}:
        paddle_language = _PADDLE_LANGUAGES.get(lang)
        if not paddle_language:
            paddle_error = stored_fields(
                "library.subtitleOcr.paddleLanguage",
                language=lang or reference("library.subtitleOcr.unknown"),
            )
        elif env.paddle_path is None:
            paddle_error = stored_fields("library.subtitleOcr.paddleMissing")
        elif env.paddle_healthy:
            return _base_capability(
                available=True,
                platform_name=platform_name,
                architecture=architecture,
                engine="paddle",
                ocr_language=paddle_language,
                message=(
                    stored_fields("library.subtitleOcr.paddleReady", language=paddle_language)
                ),
                seconv_path=seconv,
            )
        else:
            paddle_error = stored_fields(
                "library.subtitleOcr.paddleFailed",
                detail=env.paddle_detail or reference("library.subtitleOcr.unknownError"),
            )
        if requested == "paddle":
            return _base_capability(
                available=False,
                platform_name=platform_name,
                architecture=architecture,
                message=paddle_error,
                suggestions=(
                    stored_fields("library.subtitleOcr.installPaddle"),
                    _RESTART_HINT,
                ),
                seconv_path=seconv,
            )

    tesseract_language = _TESSERACT_LANGUAGES.get(lang)
    if not tesseract_language:
        message = stored_fields(
            "library.subtitleOcr.tesseractLanguage",
            language=lang or reference("library.subtitleOcr.unknown"),
        )
    elif env.tesseract_path is None:
        message = stored_fields("library.subtitleOcr.tesseractMissing")
    elif env.tesseract_error:
        message = stored_fields(
            "library.subtitleOcr.tesseractListFailed",
            detail=reference("library.subtitleOcr.unknownError")
            # i18n-ignore: language aliases parsed from track titles
            if env.tesseract_error == "未知错误"
            else env.tesseract_error,
        )
    elif tesseract_language not in env.tesseract_languages:
        message = stored_fields(
            "library.subtitleOcr.tesseractPackageMissing", language=tesseract_language
        )
    else:
        return _base_capability(
            available=True,
            platform_name=platform_name,
            architecture=architecture,
            engine="tesseract",
            ocr_language=tesseract_language,
            message=(
                stored_fields("library.subtitleOcr.tesseractReady", language=tesseract_language)
            ),
            seconv_path=seconv,
        )

    details = message
    if paddle_error and requested == "auto":
        details = stored_fields(
            "library.subtitleOcr.bothFailed", message=message, paddle=paddle_error
        )
    return _base_capability(
        available=False,
        platform_name=platform_name,
        architecture=architecture,
        message=details,
        suggestions=(
            stored_fields(
                "library.subtitleOcr.installLanguage",
                language=lang or reference("library.subtitleSource.unknownLanguage"),
            ),
            stored_fields("library.subtitleOcr.addText"),
            _RESTART_HINT,
        ),
        seconv_path=seconv,
    )


def available_ocr_languages() -> tuple[tuple[tuple[str, str], ...], Capability | None]:
    """返回当前设备真正可用的用户语言选项及一份代表性环境结论。

    只在语言缺失或冲突时调用。逐语言复用同一份结论，源码部署缺少部分
    traineddata 时下拉框不会给出实际不可用的选项；环境快照是缓存的，
    逐语言判断不再各自起子进程。
    """
    options: list[tuple[str, str]] = []
    first_available: Capability | None = None
    first_failure: Capability | None = None
    for code, label in OCR_LANGUAGE_LABELS.items():
        capability = detect_capability(code)
        if capability.available:
            options.append((code, label))
            if first_available is None:
                first_available = capability
        elif first_failure is None:
            first_failure = capability
    return tuple(options), first_available or first_failure


def _cache_stem(
    file: LibraryFile,
    candidate: SourceCandidate,
    source_language: str | None = None,
) -> str:
    # 语言来自媒体元数据，不能直接进入文件名；Windows 对 ``<>:\\|?*`` 等字符
    # 更严格，统一收敛为 ASCII 字母数字与连字符，保证同一缓存名跨平台可用。
    raw_language = str(source_language or candidate.language or "und").strip().lower()
    language = "".join(
        char if char.isascii() and (char.isalnum() or char == "-") else "-"
        for char in raw_language
    ).strip("-")
    language = language[:16] or "und"
    return f"{file.id}.embedded{candidate.key}.{language}.pgs"


def cached_srt_path(
    file: LibraryFile,
    candidate: SourceCandidate,
    source_language: str | None = None,
) -> Path:
    from movieclaw_api.services.subtitle_gen.extract import cache_dir

    return cache_dir() / f"{_cache_stem(file, candidate, source_language)}.srt"


def _is_fresh(path: Path, video: Path) -> bool:
    try:
        return (
            path.is_file()
            and path.stat().st_size > 0
            and path.stat().st_mtime_ns > video.stat().st_mtime_ns
        )
    except OSError:
        return False


def conversion_capability(
    file: LibraryFile,
    candidate: SourceCandidate,
    source_language: str | None = None,
) -> Capability:
    """缓存命中时无需运行时 OCR；否则执行完整设备检测。"""
    video = Path(file.file_path)
    cached = cached_srt_path(file, candidate, source_language)
    if _is_fresh(cached, video):
        platform_name, architecture, _ = _runtime()
        return _base_capability(
            available=True,
            platform_name=platform_name,
            architecture=architecture,
            engine="cache",
            ocr_language=None,
            cached=True,
            message=stored_fields("library.subtitleOcr.cacheReady"),
        )
    return detect_capability(source_language or candidate.language)


async def extract_sup(file: LibraryFile, candidate: SourceCandidate) -> Path:
    """从媒体文件抽出这条 PGS 轨（``.sup``），返回产物路径。

    走 ``media_extract`` 的共享抽取：与播放器同一份产物、同一趟通读（一个文件
    所有轨一起抽），可取消、超时按体积估。此前这里单独再跑一遍 ffmpeg，
    播放器抽过的片子要被整片再读一次，取消也停不下来。
    """
    if candidate.kind != "embedded" or not is_pgs_codec(candidate.format):
        raise PgsConversionError(stored_fields("library.subtitleOcr.invalidTrack"))
    index = int(candidate.key)
    track = await media_extract.extract_track_async(file, index)
    if track is None or track.format != "sup":
        reason = media_extract.failure_reason(file, index) or reference(
            "library.subtitleSource.detailsInLog"
        )
        raise PgsConversionError(
            stored_fields(
                "library.subtitleOcr.extractFailed",
                filename=Path(file.file_path).name,
                index=index + 1,
                reason=reason,
            )
        )
    return track.path


async def ocr_to_srt(
    file: LibraryFile,
    candidate: SourceCandidate,
    capability: Capability,
    source_language: str | None,
    sup_path: Path,
) -> Path:
    """用 seconv 把 ``.sup`` 识别成缓存 SRT；命中缓存时不重复 OCR。

    seconv 起在独立进程组里（见 ``process``）：用户停止任务或应用停机时连同
    OCR 引擎一起结束，不再等它自然跑完（最长一小时）。
    """
    video = Path(file.file_path)
    out_path = cached_srt_path(file, candidate, source_language)
    if await asyncio.to_thread(_is_fresh, out_path, video):
        return out_path
    if not capability.available or not capability.seconv_path:
        raise PgsConversionError(capability.message_ref or capability.message)
    if not capability.engine or capability.engine == "cache" or not capability.ocr_language:
        raise PgsConversionError(stored_fields("library.subtitleOcr.capabilityIncomplete"))
    try:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        temp_dir = Path(tempfile.mkdtemp(prefix="pgs-ocr-", dir=out_path.parent))
    except OSError as exc:
        raise PgsConversionError(
            stored_fields("library.subtitleOcr.tempFailed", detail=exc)
        ) from exc
    try:
        argv = [
            capability.seconv_path,
            str(sup_path),
            "subrip",
            f"--ocr-engine:{capability.engine}",
            f"--ocr-language:{capability.ocr_language}",
            f"--output-folder:{temp_dir}",
            "--overwrite",
        ]
        try:
            result = await process.run(argv, timeout=_OCR_TIMEOUT)
        except process.ProcessTimeout as exc:
            raise PgsConversionError(
                stored_fields("library.subtitleOcr.timeout", minutes=int(_OCR_TIMEOUT / 60))
            ) from exc
        except OSError as exc:
            raise PgsConversionError(
                stored_fields("library.subtitleOcr.startFailed", detail=exc)
            ) from exc
        outputs = sorted(
            path
            for path in temp_dir.iterdir()
            if path.is_file() and path.suffix.lower() == ".srt"
        )
        if result.returncode != 0 or not outputs or outputs[0].stat().st_size == 0:
            raw = result.stderr or result.stdout
            detail = raw.decode(errors="replace").strip().replace("\n", " ")
            raise PgsConversionError(
                stored_fields(
                    "library.subtitleOcr.conversionFailed",
                    detail=detail[:400] or reference("library.subtitleOcr.unknownError"),
                )
            )
        try:
            outputs[0].replace(out_path)
        except OSError as exc:
            raise PgsConversionError(
                stored_fields("library.subtitleOcr.cacheWriteFailed", path=out_path, detail=exc)
            ) from exc
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)
    return out_path
