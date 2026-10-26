"""命令行入口：``python -m movieclaw_transcoder --server http://<NAS>:3000``。

第一次运行：自检 ffmpeg → 验证 NAS 地址 → 打印配对码与批准页地址，在浏览器里核对后批准 → 令牌存本机
→ 连上 NAS 开始接单。之后直接 ``python -m movieclaw_transcoder``（参数都记在配置里）。
"""

from __future__ import annotations

import argparse
import contextlib
import logging
import logging.handlers
import shutil
import signal
import sys
import threading
import webbrowser
from collections.abc import Sequence

from . import __version__, single_instance
from .client import TranscoderClient
from .config import (
    WORKER_ID_RE,
    Config,
    app_dir,
    config_path,
    default_worker_id,
    load_config,
    normalize_server,
)
from .pairing import (
    PairingError,
    check_server,
    request_pairing,
    revoke_credential,
    wait_for_approval,
)
from .probe import FfmpegProblem, probe

log = logging.getLogger("movieclaw_transcoder")


def _setup_logging() -> None:
    log.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(message)s", "%H:%M:%S")
    if sys.stdout is not None:  # pythonw 启动时没有标准输出
        console = logging.StreamHandler(sys.stdout)
        console.setFormatter(fmt)
        log.addHandler(console)
    try:
        app_dir().mkdir(parents=True, exist_ok=True)
        file_handler = logging.handlers.RotatingFileHandler(
            app_dir() / "transcoder.log", maxBytes=1_000_000, backupCount=3, encoding="utf-8"
        )
        file_handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
        log.addHandler(file_handler)
    except OSError:
        pass


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="movieclaw_transcoder",
        description="MovieClaw 转码器（Windows）：把 NAS 的硬件转码交给这台电脑的 NVIDIA 显卡。",
    )
    parser.add_argument(
        "--server", help="NAS 地址，如 http://192.168.1.5:3000；记在配置里，只需给一次"
    )
    parser.add_argument(
        "--ffmpeg", help="ffmpeg.exe 的路径（推荐 jellyfin-ffmpeg）；缺省取配置或 PATH"
    )
    parser.add_argument("--name", help="这台机器在 NAS 里的名字（字母数字与 ._:-，默认取主机名）")
    parser.add_argument(
        "--max-jobs", type=int, choices=range(1, 5), metavar="1-4", help="并发任务数"
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help="断开配对：在 NAS 上注销本机凭证、清掉本机令牌，然后重新配对",
    )
    parser.add_argument(
        "--check", action="store_true", help="只检查 ffmpeg 与显卡能力、打印申报内容，不连接 NAS"
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    _setup_logging()
    config = load_config()
    changed = False
    if args.server:
        config.server, changed = normalize_server(args.server), True
    if args.ffmpeg:
        config.ffmpeg, changed = args.ffmpeg, True
    if args.name:
        if not WORKER_ID_RE.fullmatch(args.name):
            log.error("--name 只能含字母、数字与 ._:-，且以字母或数字开头（最长 64 位）")
            return 2
        config.worker_id, changed = args.name, True
    if args.max_jobs:
        config.max_jobs, changed = args.max_jobs, True
    if not config.worker_id:
        config.worker_id, changed = default_worker_id(), True
    if config.ffmpeg == "ffmpeg":
        config.ffmpeg = shutil.which("ffmpeg") or "ffmpeg"

    if not args.check and not single_instance.acquire():
        log.error("MovieClaw 转码器已经在这台电脑上运行了（同机只允许一个）")
        return 3

    try:
        log.info("自检 ffmpeg：%s", config.ffmpeg)
        capabilities = probe(
            config.ffmpeg,
            cache_file=app_dir() / "capabilities.json",
            log=log.info,
        )
    except FfmpegProblem as problem:
        log.error("%s", problem)
        return 2
    log.info(
        "ffmpeg %s｜编码器 %s｜硬解 %s｜滤镜 %s",
        capabilities.ffmpeg_version,
        "、".join(capabilities.encoders),
        "、".join(capabilities.hw_decoders) or "无",
        "、".join(capabilities.filters) or "无",
    )
    if args.check:
        return 0

    if not config.server:
        log.error("还没有 NAS 地址：第一次请加 --server http://<NAS 地址>:<端口>")
        return 2
    if changed:
        config.save()

    if args.reset and config.token:
        if revoke_credential(config.server, config.token):
            log.info("已在 NAS 上注销这台电脑的凭证")
        else:
            log.warning("NAS 连不上，只清了本机令牌；之后可以在网页「设置 → 设备」里手动注销")
        config.token = ""
        config.save()

    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    if hasattr(signal, "SIGBREAK"):  # 关控制台窗口 / Ctrl+Break
        signal.signal(signal.SIGBREAK, lambda *_: stop.set())  # type: ignore[attr-defined]

    if not config.token:
        problem = check_server(config.server)
        if problem is not None:
            log.error("%s", problem)
            return 2
        if not _pair(config, stop):
            return 1

    client = TranscoderClient(
        server=config.server,
        token=config.token,
        worker_id=config.worker_id,
        ffmpeg=config.ffmpeg,
        capabilities=capabilities,
        max_jobs=config.max_jobs,
        log=log.info,
        on_status=_print_status,
    )
    thread = threading.Thread(target=client.run_forever, name="control", daemon=True)
    thread.start()
    try:
        stop.wait()
    finally:
        log.info("正在退出…")
        client.stop()
        thread.join(timeout=10)
    return 0


def _pair(config: Config, stop: threading.Event) -> bool:
    try:
        request = request_pairing(config.server, config.worker_id, config.installation_id)
    except (PairingError, OSError) as exc:
        log.error("%s", exc)
        return False
    log.info("请在浏览器里打开下面的地址，核对配对码后批准（需要管理员账号）：")
    log.info("  %s", request.verification_uri_complete)
    log.info("  配对码：%s（%d 分钟内有效）", request.user_code, int(request.expires_in // 60))
    with contextlib.suppress(webbrowser.Error):
        webbrowser.open(request.verification_uri_complete)
    try:
        config.token = wait_for_approval(config.server, request, cancelled=stop.is_set)
    except PairingError as exc:
        log.error("%s", exc)
        return False
    config.save()
    log.info("配对成功，凭证已保存到 %s", config_path())
    return True


def _print_status(kind: str, **fields: object) -> None:
    if kind == "connecting":
        log.info("正在连接 NAS：%s", fields.get("server"))
    elif kind == "online":
        log.info("已连上 NAS，可以接单（并发上限 %s）", fields.get("max_jobs"))
    elif kind == "offline":
        retry = fields.get("retry_seconds") or 0
        suffix = f"；{int(retry)} 秒后重试" if retry else "；立即重连"
        log.warning("与 NAS 的连接断开：%s%s", fields.get("reason"), suffix)
        if fields.get("rejection") == "auth":
            log.warning("这台电脑的授权已失效：请加 --reset 重新配对")
        elif fields.get("rejection") == "remote_disabled":
            log.warning("请在 NAS 网页「应用 → 远程转码」里打开开关")
