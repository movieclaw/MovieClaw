"""本机配置：NAS 地址、设备令牌、Worker 名称与并发。存在用户目录下的一个 JSON 文件里。

令牌只在配对成功的那一刻出现一次（见 ``pairing``），之后只在这里。文件放在 ``%APPDATA%`` 下，
是当前 Windows 用户私有的；类 Unix 系统上写成 0600。
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import socket
import sys
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path

#: 与服务端 ``remote_worker._WORKER_ID`` 同一条规则：超出的字符会让握手被拒
WORKER_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$")


def app_dir() -> Path:
    """配置、能力缓存、日志的目录。``MOVIECLAW_TRANSCODER_HOME`` 可整体改位置（排障、测试用）。"""
    override = os.environ.get("MOVIECLAW_TRANSCODER_HOME")
    if override:
        return Path(override)
    if sys.platform == "win32":
        return Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming") / (
            "MovieClawTranscoder"
        )
    return Path.home() / ".config" / "movieclaw-transcoder"


def ffmpeg_env() -> dict[str, str]:
    """ffmpeg 子进程的环境：给 CUDA 的 JIT 缓存一个专属目录。

    ``scale_cuda`` / ``tonemap_cuda`` 的内核以 PTX 随 ffmpeg 发行，第一次用要由驱动按这块显卡
    即时编译（约 2 秒），结果存进 CUDA 的 JIT 缓存，之后每次起 ffmpeg 直接取。系统默认的缓存
    （用户目录下 NVIDIA 的 ComputeCache，上限 256 MB）被别的程序（PyTorch、各种 CUDA 应用）
    塞满之后，新编译的结果存不进去——每次播放起播都白白多等 2 秒（实测同一条命令 2.5 秒 →
    0.5 秒）。专属目录只放本程序用到的那几个内核，几 MB，不受别人影响。用户自己设了
    ``CUDA_CACHE_PATH`` 就尊重它。"""
    env = dict(os.environ)
    env.setdefault("CUDA_CACHE_PATH", str(app_dir() / "cuda-cache"))
    env.setdefault("CUDA_CACHE_MAXSIZE", str(512 * 1024 * 1024))
    return env


def default_worker_id() -> str:
    """机器标识默认取主机名（每台机器各一个）。主机名里的非法字符换成 ``-``。"""
    return sanitize_worker_id(socket.gethostname())


def sanitize_worker_id(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.:-]", "-", name.strip()).strip("-_.:")[:64]
    return cleaned if WORKER_ID_RE.fullmatch(cleaned) else "windows-worker"


@dataclass
class Config:
    server: str = ""
    token: str = ""
    worker_id: str = ""
    ffmpeg: str = "ffmpeg"
    #: 本机想接几路并发；服务端按设备配置下发的上限为准（``worker.accepted`` / ``worker.config``）
    max_jobs: int = 1
    #: 同一台机器重新配对时替换旧凭证，而不是在「设置 → 设备」里越积越多
    installation_id: str = field(default_factory=lambda: uuid.uuid4().hex)

    def save(self, path: Path | None = None) -> None:
        target = path or config_path()
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_suffix(".tmp")
        tmp.write_text(json.dumps(asdict(self), ensure_ascii=False, indent=2), encoding="utf-8")
        with contextlib.suppress(OSError, NotImplementedError):
            tmp.chmod(0o600)
        os.replace(tmp, target)


def config_path() -> Path:
    return app_dir() / "config.json"


def load_config(path: Path | None = None) -> Config:
    target = path or config_path()
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return Config()
    known = {key: data[key] for key in Config.__dataclass_fields__ if key in data}
    config = Config(**known)
    if not WORKER_ID_RE.fullmatch(config.worker_id or ""):
        config.worker_id = ""
    return config


def normalize_server(address: str) -> str:
    """``192.168.1.5:8000`` → ``http://192.168.1.5:8000``；去掉末尾的 ``/``。"""
    text = address.strip().rstrip("/")
    if not text:
        return ""
    if "://" not in text:
        text = "http://" + text
    return text
