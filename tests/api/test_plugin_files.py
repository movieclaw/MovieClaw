"""插件文件接口 ``PLUGIN_FILES``（docs/design/plugin-phase3.md §6.2，C6a）。

真实应用 + 本地插件，进程内 / 进程外各跑一遍：授权的读写模式、越权路径、软链接逃逸、
媒体库别名现算、插件私有目录、经描述符读写大文件、交出文件给路由（含 Range）。
"""

from __future__ import annotations

import os
import sys
import textwrap

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events

PLUGIN = """
import asyncio

from fastapi import APIRouter

from movieclaw_api.plugins.keys import PLUGIN_FILES, PLUGIN_ROUTES
from movieclaw_sdk import plugin


@plugin("acme.files", title="文件插件", inject=(PLUGIN_FILES, PLUGIN_ROUTES))
async def apply(ctx) -> None:
    files = ctx.use(PLUGIN_FILES).scoped(ctx)
    router = APIRouter()

    async def attempt(action):
        try:
            return {"ok": True, "value": await action()}
        except PermissionError as exc:
            return {"ok": False, "error": str(exc)}

    @router.post("/write", operation_id="plugins.acme.files.write")
    async def write(path: str, text: str) -> dict:
        async def run():
            out = await files.open(path, "wb")
            with out:
                await asyncio.to_thread(out.write, text.encode())
            return len(text)

        return await attempt(run)

    @router.get("/read", operation_id="plugins.acme.files.read")
    async def read(path: str) -> dict:
        async def run():
            src = await files.open(path, "rb")
            with src:
                data = await asyncio.to_thread(src.read)
            return {"size": len(data), "head": data[:16].decode(errors="replace")}

        return await attempt(run)

    @router.get("/private", operation_id="plugins.acme.files.private")
    async def private() -> dict:
        path = files.path("plugin", "state.txt")
        out = await files.open(path, "wb")
        with out:
            await asyncio.to_thread(out.write, b"mine")
        src = await files.open(path, "rb")
        with src:
            data = await asyncio.to_thread(src.read)
        listed = await files.listdir(path.rsplit("/", 1)[0])
        return {"path": path, "data": data.decode(), "listed": listed}

    @router.get("/send", operation_id="plugins.acme.files.send")
    async def send(path: str):
        return files.response(path)

    ctx.use(PLUGIN_ROUTES).mount(ctx, router, zone="admin")
"""


@pytest.fixture(params=["inline", "process"])
def world(request, tmp_path, monkeypatch):
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.services.auth import Principal

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'files.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    for name in ("ro", "rw", "outside", "lib"):
        (tmp_path / name).mkdir()
    (tmp_path / "ro" / "readme.txt").write_text("只读的内容", encoding="utf-8")
    (tmp_path / "outside" / "secret.txt").write_text("别人的秘密", encoding="utf-8")
    (tmp_path / "rw" / "escape").symlink_to(tmp_path / "outside")
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "acme_files.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: acme.files
              local: true
              module: acme_files
              runtime: {request.param}
              paths:
                - {{ path: "{tmp_path / "ro"}", mode: read }}
                - {{ path: "{tmp_path / "rw"}", mode: rw }}
                - {{ path: library, mode: read }}
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    with TestClient(app) as client:
        assert app.state.kernel.fiber("acme.files").state.value == "active"
        yield tmp_path, client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    durable_events.reset_state()
    get_settings.cache_clear()


BASE = "/api/v1/plugins/acme.files"


def call(client, method: str, route: str, **params) -> dict:
    reply = client.request(method, f"{BASE}{route}", params=params)
    assert reply.status_code == 200, reply.text
    return reply.json()


def test_grants_are_enforced(world) -> None:
    root, client = world
    read = call(client, "GET", "/read", path=str(root / "ro" / "readme.txt"))
    assert read["ok"] and read["value"]["head"] == "只读的内容"
    # 只读授权写不了；读写授权可以写
    denied = call(client, "POST", "/write", path=str(root / "ro" / "new.txt"), text="x")
    assert not denied["ok"] and "只有读权限" in denied["error"]
    assert call(client, "POST", "/write", path=str(root / "rw" / "new.txt"), text="hello")["ok"]
    assert (root / "rw" / "new.txt").read_text() == "hello"
    # 没授权的路径、借软链接逃出去，都不行
    for path in (root / "outside" / "secret.txt", root / "rw" / "escape" / "secret.txt"):
        result = call(client, "GET", "/read", path=str(path))
        assert not result["ok"] and "没有获得访问" in result["error"]
    # 主数据库、密钥文件当然也不行
    assert not call(client, "GET", "/read", path=str(root / ".secret_key"))["ok"]


def test_library_alias_follows_the_libraries(world) -> None:
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.library_repo import LibraryRepository

    root, client = world
    (root / "lib" / "a.nfo").write_text("<movie/>", encoding="utf-8")
    assert not call(client, "GET", "/read", path=str(root / "lib" / "a.nfo"))["ok"]

    async def add_library() -> None:
        async with get_database().session() as session:
            await LibraryRepository(session).create(
                name="电影", kind="movie", root_paths=[str(root / "lib")]
            )

    client.portal.call(add_library)
    # 别名每次现算：建库之后立即可读（但 library 只批准了读）
    assert call(client, "GET", "/read", path=str(root / "lib" / "a.nfo"))["ok"]
    assert not call(client, "POST", "/write", path=str(root / "lib" / "b.nfo"), text="x")["ok"]


def test_private_dir_and_large_files(world) -> None:
    root, client = world
    private = call(client, "GET", "/private")
    assert private["data"] == "mine"
    assert private["path"] == str(root / "plugins" / "data" / "acme.files" / "state.txt")
    assert private["listed"] == ["state.txt"]
    # 大文件：进程外经描述符直接读，大小一致
    big = root / "rw" / "big.bin"
    big.write_bytes(os.urandom(5 * 1024 * 1024))
    result = call(client, "GET", "/read", path=str(big))
    assert result["ok"] and result["value"]["size"] == 5 * 1024 * 1024


def test_routes_hand_files_over_with_range(world) -> None:
    root, client = world
    movie = root / "rw" / "电影.mkv"
    movie.write_bytes(b"0123456789" * 1000)
    full = client.get(f"{BASE}/send", params={"path": str(movie)})
    assert full.status_code == 200 and full.content == movie.read_bytes()
    part = client.get(f"{BASE}/send", params={"path": str(movie)}, headers={"Range": "bytes=10-19"})
    assert part.status_code == 206 and part.content == b"0123456789"
    # 交出没授权的文件：404，不泄露内容
    leaked = client.get(f"{BASE}/send", params={"path": str(root / "outside" / "secret.txt")})
    assert leaked.status_code == 404 and "别人的秘密" not in leaked.text
