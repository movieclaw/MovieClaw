"""下载器适配器插件化（docs/design/downloader-adapters.md）。

- 内置两种下载器来自官方插件；第三方插件能登记新的类型，配置下载器时就能选；
- 独立进程里的适配器经代理调用：提交（含种子字节）、查询、列表、删除、限速、测试连接、关闭都走协议，
  下载器异常按原类型带回宿主；同一份连接配置复用一个适配器实例。
"""

from __future__ import annotations

import sys
import textwrap
from functools import partial

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events
from movieclaw_downloader import DownloaderConfig, DownloadRequest, create_downloader
from movieclaw_downloader.exceptions import DownloaderDeleteError
from movieclaw_downloader.models import DownloaderLimits

ADMIN = {"username": "admin", "password": "s3cret-pass"}

PLUGIN = """
from pydantic import BaseModel, Field, SecretStr

from movieclaw_sdk import plugin
from movieclaw_sdk.downloaders import (
    DOWNLOADER_ADAPTERS,
    BaseDownloader,
    DownloaderAdapter,
    DownloaderDeleteError,
    DownloaderInfo,
    DownloaderLimits,
    SubmitResult,
    TorrentBrief,
    TorrentStatus,
)

INSTANCES = []


class Memory(BaseDownloader):
    def __init__(self, config):
        super().__init__(config)
        self.torrents = {}
        self.limits = DownloaderLimits()
        INSTANCES.append(self)

    async def submit(self, request):
        info_hash = "a" * 40 if request.torrent_bytes == b"\\x00\\xffbinary" else "b" * 40
        self.torrents[info_hash] = request.save_path or "/downloads"
        return SubmitResult(info_hash=info_hash, name=f"实例 {len(INSTANCES)}")

    async def get_torrent(self, info_hash, *, include_files=True):
        if info_hash not in self.torrents:
            return None
        return TorrentStatus(
            info_hash=info_hash, name="内存种子", progress=1.0, completed=True,
            save_path=self.torrents[info_hash], files=[],
        )

    async def list_torrents(self):
        return [
            TorrentBrief(info_hash=h, name="内存种子", content_name="内存种子", completed=True)
            for h in self.torrents
        ]

    async def delete_torrent(self, info_hash, *, delete_files=False):
        if info_hash not in self.torrents:
            raise DownloaderDeleteError("下载器里没有这个任务")
        del self.torrents[info_hash]

    async def set_location(self, info_hash, save_path):
        self.torrents[info_hash] = save_path

    async def set_file_selection(self, info_hash, selected_indices):
        pass

    async def get_limits(self):
        return self.limits

    async def set_limits(self, limits):
        self.limits = limits

    async def transfer_speeds(self):
        return (1024, 2048)

    async def resume(self, info_hash):
        pass

    async def set_download_limits(self, info_hashes, limit_bytes):
        pass

    async def set_upload_limits(self, info_hashes, limit_bytes):
        pass

    async def test_connection(self):
        return DownloaderInfo(type="memory", version="1.0")

    async def close(self):
        pass


class MemoryConnection(BaseModel):
    url: str = Field(title="随便填", examples=["mem://local"])
    password: SecretStr | None = Field(None, title="令牌")


@plugin("memory-downloader", title="内存下载器")
async def apply(ctx) -> None:
    ctx.contribute(
        DOWNLOADER_ADAPTERS,
        "memory",
        DownloaderAdapter(
            type="memory", title="内存下载器", factory=Memory, connection=MemoryConnection
        ),
    )
"""


@pytest.fixture(params=["inline", "process"])
def client(request, tmp_path, monkeypatch):
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'dl.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "memory_downloader.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: memory-downloader
              local: true
              module: memory_downloader
              runtime: {request.param}
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as test_client:
        assert test_client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
        test_client.runtime = request.param  # type: ignore[attr-defined]
        yield test_client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


def test_types_come_from_plugins_and_gate_the_config(client) -> None:
    types = {t["type"]: t for t in client.get("/api/v1/downloaders/types").json()["data"]}
    assert {"qbittorrent", "transmission", "memory"} <= set(types)
    assert types["qbittorrent"]["url_label"] == "WebUI 地址"
    assert types["memory"]["title"] == "内存下载器"
    # 连接参数由插件声明：叫法、示例、不要用户名（进程内外一样）
    memory = types["memory"]
    assert memory["url_label"] == "随便填" and memory["url_placeholder"] == "mem://local"
    assert memory["needs_username"] is False
    assert set(memory["connection"]["properties"]) == {"url", "password"}
    assert memory["connection"]["properties"]["password"]["writeOnly"] is True
    assert types["transmission"]["help"] == "路径缺省时自动补全为 /transmission/rpc"

    base = {"url": "http://x", "username": None, "password": None, "save_path": None}
    created = client.post(
        "/api/v1/downloaders", json={**base, "name": "内存", "client_type": "memory"}
    )
    assert created.status_code in (200, 201), created.text
    refused = client.post(
        "/api/v1/downloaders", json={**base, "name": "未知", "client_type": "aria2"}
    )
    assert refused.status_code == 400 and "没有「aria2」这种下载器" in refused.text


def test_every_method_goes_through_the_adapter(client) -> None:
    async def scenario() -> dict:
        config = DownloaderConfig(type="memory", url="http://x")
        downloader = create_downloader(config)
        submitted = await downloader.submit(
            DownloadRequest(torrent_bytes=b"\x00\xffbinary", save_path="/data/a")
        )
        status = await downloader.get_torrent(submitted.info_hash)
        await downloader.set_location(submitted.info_hash, "/data/b")
        moved = await downloader.get_torrent(submitted.info_hash)
        listed = await downloader.list_torrents()
        await downloader.set_limits(DownloaderLimits(download_limit_bytes=1000))
        limits = await downloader.get_limits()
        speeds = await downloader.transfer_speeds()
        info = await downloader.test_connection()
        # 独立进程里同一份连接配置复用一个实例（登录态）：第二个代理看到的是同一份数据；
        # 主进程里每次都是新实例（与内置下载器一样）
        again = await create_downloader(config).get_torrent(submitted.info_hash)
        await downloader.delete_torrent(submitted.info_hash)
        try:
            await downloader.delete_torrent(submitted.info_hash)
            error = None
        except DownloaderDeleteError as exc:
            error = exc.message
        missing = await downloader.get_torrent(submitted.info_hash)
        await downloader.close()
        return {
            "hash": submitted.info_hash,
            "status": status,
            "moved": moved.save_path,
            "listed": [t.info_hash for t in listed],
            "limits": limits.download_limit_bytes,
            "speeds": speeds,
            "info": info,
            "again": again is not None,
            "error": error,
            "missing": missing,
        }

    out = call(client, scenario)
    assert out["hash"] == "a" * 40, "种子字节原样到了适配器"
    assert out["status"].completed is True and out["status"].save_path == "/data/a"
    assert out["moved"] == "/data/b"
    assert out["listed"] == ["a" * 40]
    assert out["limits"] == 1000
    assert out["speeds"] == (1024, 2048)
    assert out["info"].type == "memory"
    assert out["again"] is (client.runtime == "process")
    assert out["error"] == "下载器里没有这个任务"
    assert out["missing"] is None


def test_connection_fields_are_limited_to_the_stored_columns() -> None:
    """连接参数只能落进下载器配置已有的三栏；多出来的字段没处存，登记时就拒绝。"""
    from pydantic import BaseModel

    from movieclaw_downloader.registry import DownloaderAdapter

    class Extra(BaseModel):
        url: str
        api_secret: str = ""

    class NoUrl(BaseModel):
        password: str = ""

    for model in (Extra, NoUrl):
        with pytest.raises(ValueError, match="必须有 url"):
            DownloaderAdapter(type="x", title="X", factory=object, connection=model)  # type: ignore[arg-type]
