"""本机配置：NAS 地址、设备令牌、机器名与并发，存在用户目录下的一个 JSON 文件里。"""

from __future__ import annotations

import json
import os
import sys

import pytest
from movieclaw_transcoder import config as config_module
from movieclaw_transcoder.config import (
    WORKER_ID_RE,
    Config,
    app_dir,
    config_path,
    default_worker_id,
    ffmpeg_env,
    load_config,
    normalize_server,
    sanitize_worker_id,
)


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("MOVIECLAW_TRANSCODER_HOME", str(tmp_path / "home"))
    monkeypatch.delenv("CUDA_CACHE_PATH", raising=False)
    monkeypatch.delenv("CUDA_CACHE_MAXSIZE", raising=False)
    return tmp_path / "home"


def test_the_home_directory_can_be_moved_for_troubleshooting(home):
    assert app_dir() == home
    assert config_path() == home / "config.json"


def test_without_overrides_the_home_follows_the_platform(monkeypatch):
    monkeypatch.delenv("MOVIECLAW_TRANSCODER_HOME", raising=False)

    if sys.platform == "win32":
        assert app_dir().name == "MovieClawTranscoder"
    else:
        assert app_dir().name == "movieclaw-transcoder"


@pytest.mark.parametrize(
    ("host", "expected"),
    [
        ("DESKTOP-ABC_1", "DESKTOP-ABC_1"),
        ("  my pc  ", "my-pc"),
        ("-leading-dash", "leading-dash"),
        ("我的电脑", "windows-worker"),  # 一个合法字符都不剩：用固定名字
        ("a" * 100, "a" * 64),
    ],
)
def test_host_names_are_turned_into_legal_worker_ids(host, expected):
    cleaned = sanitize_worker_id(host)

    assert cleaned == expected
    assert WORKER_ID_RE.fullmatch(cleaned)


def test_the_default_worker_id_is_the_legal_host_name(monkeypatch):
    monkeypatch.setattr(config_module.socket, "gethostname", lambda: "Gaming PC.local")

    assert default_worker_id() == "Gaming-PC.local"


@pytest.mark.parametrize(
    ("typed", "expected"),
    [
        ("192.168.1.5:8000", "http://192.168.1.5:8000"),
        ("http://nas:3000/", "http://nas:3000"),
        ("https://nas.example/movieclaw/", "https://nas.example/movieclaw"),
        ("  nas.local  ", "http://nas.local"),
        ("", ""),
    ],
)
def test_server_addresses_are_normalised(typed, expected):
    assert normalize_server(typed) == expected


def test_config_round_trips_through_the_file(home):
    saved = Config(
        server="http://nas:3000", token="tok", worker_id="gaming-pc", ffmpeg="C:/f.exe", max_jobs=2
    )

    saved.save()
    loaded = load_config()

    assert loaded == saved
    assert json.loads(config_path().read_text(encoding="utf-8"))["token"] == "tok"


@pytest.mark.skipif(sys.platform == "win32", reason="Windows 的文件权限由用户目录的 ACL 管")
def test_the_token_file_is_private_on_unix(home):
    Config(token="tok").save()

    assert (config_path().stat().st_mode & 0o777) == 0o600


def test_a_failed_save_never_leaves_a_half_written_config(home, monkeypatch):
    Config(server="http://nas:3000", token="old").save()

    def broken_replace(*_args):
        raise OSError("disk full")

    monkeypatch.setattr(os, "replace", broken_replace)
    with pytest.raises(OSError):
        Config(server="http://nas:3000", token="new").save()

    assert json.loads(config_path().read_text(encoding="utf-8"))["token"] == "old"


def test_every_machine_gets_its_own_installation_id_and_keeps_it(home):
    first, second = Config(), Config()
    assert first.installation_id and first.installation_id != second.installation_id

    first.save()
    assert load_config().installation_id == first.installation_id


def test_a_missing_config_is_just_the_defaults(home):
    loaded = load_config()

    assert (loaded.server, loaded.token, loaded.worker_id, loaded.max_jobs) == ("", "", "", 1)


def test_a_corrupt_config_is_just_the_defaults(home):
    config_path().parent.mkdir(parents=True)
    config_path().write_text("not json", encoding="utf-8")

    assert load_config().token == ""


def test_an_illegal_worker_id_is_dropped_and_unknown_keys_are_ignored(home):
    config_path().parent.mkdir(parents=True)
    config_path().write_text(
        json.dumps({"server": "http://nas", "worker_id": "bad name!", "future_key": 1}),
        encoding="utf-8",
    )

    loaded = load_config()

    assert loaded.server == "http://nas"
    assert loaded.worker_id == ""  # 握手会被拒的名字不能留下来


def test_ffmpeg_gets_its_own_cuda_kernel_cache(home):
    """系统默认的 JIT 缓存被别的 CUDA 程序塞满后，新编译的内核存不进去，每次起播多等 2 秒。"""
    env = ffmpeg_env()

    assert env["CUDA_CACHE_PATH"] == str(home / "cuda-cache")
    assert int(env["CUDA_CACHE_MAXSIZE"]) == 512 * 1024 * 1024


def test_a_cuda_cache_the_user_set_is_respected(home, monkeypatch):
    monkeypatch.setenv("CUDA_CACHE_PATH", "D:/my-cache")
    monkeypatch.setenv("CUDA_CACHE_MAXSIZE", "1024")

    env = ffmpeg_env()

    assert env["CUDA_CACHE_PATH"] == "D:/my-cache"
    assert env["CUDA_CACHE_MAXSIZE"] == "1024"
