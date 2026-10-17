"""插件第三方依赖（docs/design/plugin-dependencies.md）：真实应用、真实接口、真实插件进程。

- 上传时校验清单的 ``[dependencies]`` 与锁文件：只给独立进程运行的插件、锁文件要在包里、
  与主程序已有的包重名一律拒绝；合规的包进入待批准区；
- 批准：依赖逐个列出，授权按锁文件哈希；同锁升级不问、改锁升级列出增删改再问；
- 安装：本机起一个包索引（HTML 页，PEP 503）供应手工打的轮子，经「设置 → 网络」的包索引地址
  下载、核对哈希、pip 离线装进依赖目录；插件进程从 ``sys.path`` 最后导入，轮子里的 ``.pth`` 不执行；
- 失败：断网、哈希不对、没有适用于本机平台的轮子，各给原因、旧版本照常运行、可重试；
- 包内 ``wheels/`` 离线安装；换平台标签（模拟主程序换 Python 版本）后后台按原锁文件重装。
"""

from __future__ import annotations

import base64
import functools
import hashlib
import io
import shutil
import socket
import textwrap
import threading
import time
import zipfile
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
from tests.api import test_plugin_packages as base
from tests.api.test_plugin_packages import MANIFEST, package, start, stored, upload
from tests.unit.test_plugin_deps_lock import ECDSA, LZ4, block, lock

from movieclaw_api.core.config import get_settings

data_dir = base.data_dir

LOCK = lock(block("lz4==4.4.4", LZ4), block("ecdsa==0.19.1", ECDSA))


def with_deps(
    *, runtime: str = "process", lock_text: str | None = LOCK, path: str = "requirements.lock"
) -> bytes:
    manifest = (
        MANIFEST.format(
            id="acme-pkg",
            version=1,
            runtime=runtime,
            sdk="^1.0",
            requires="",
            operations='"app.plugins.list"',
        )
        + f'\n[dependencies]\nlock = "{path}"\n'
    )
    files = {"requirements.lock": lock_text} if lock_text is not None else {}
    return package(manifest=manifest, files=files)


def test_a_package_with_a_valid_lock_waits_for_approval(data_dir) -> None:
    app, client = start()
    with client:
        reply = upload(client, with_deps())
        assert reply.status_code == 200, reply.text
        pending = client.get("/api/v1/app/plugins/packages").json()["data"]["pending"]
        assert [p["id"] for p in pending] == ["acme-pkg"]


BAD = {
    "inline": (with_deps(runtime="inline"), "只有独立进程运行"),
    "missing-lock": (with_deps(lock_text=None), "找不到锁文件 requirements.lock"),
    "outside": (with_deps(path="../x.lock"), "包内的相对路径"),
    "not-pinned": (with_deps(lock_text=lock(block("lz4>=4", LZ4))), "lz4 没有钉死版本"),
    "host-package": (
        with_deps(lock_text=lock(block("httpx==0.1.0", ("httpx-0.1.0-py3-none-any.whl",)))),
        "是主程序自带的包",
    ),
}


@pytest.mark.parametrize("case", sorted(BAD))
def test_bad_dependency_declarations_are_rejected_on_upload(data_dir, case) -> None:
    data, message = BAD[case]
    app, client = start()
    with client:
        reply = upload(client, data)
        assert reply.status_code == 400
        assert message in reply.json()["message"]
        assert client.get("/api/v1/app/plugins/packages").json()["data"]["pending"] == []


# ---------------------------------------------------------------------- 本机包索引
def make_wheel(name: str, version: str, *, tag: str = "py3-none-any", pth: str | None = None):
    """手工打一个轮子：``<name>/__init__.py`` 里 ``VALUE = 版本``；``pth`` 给出时带一个 .pth。"""
    dist = f"{name}-{version}.dist-info"
    files = {
        f"{name}/__init__.py": f"VALUE = {version!r}\n",
        f"{dist}/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n",
        f"{dist}/WHEEL": (
            f"Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: {tag}\n"
        ),
    }
    if pth is not None:
        files[f"{name}-startup.pth"] = pth
    record = []
    for path, content in files.items():
        raw = hashlib.sha256(content.encode()).digest()
        b64 = base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
        record.append(f"{path},sha256={b64},{len(content.encode())}")
    record.append(f"{dist}/RECORD,,")
    files[f"{dist}/RECORD"] = "\n".join(record) + "\n"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for path, content in files.items():
            archive.writestr(path, content)
    return f"{name}-{version}-{tag}.whl", buffer.getvalue()


class Index:
    """本机包索引：``/simple/<name>/`` 是 HTML 项目页，``/files/`` 下是轮子。"""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.wheels: dict[str, bytes] = {}
        handler = functools.partial(_QuietHandler, directory=str(root))
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/simple"

    def add(self, filename: str, data: bytes) -> str:
        self.wheels[filename] = data
        (self.root / "files").mkdir(parents=True, exist_ok=True)
        (self.root / "files" / filename).write_bytes(data)
        by_name: dict[str, list[str]] = {}
        for name in self.wheels:
            by_name.setdefault(name.split("-")[0], []).append(name)
        for name, names in by_name.items():
            page = self.root / "simple" / name / "index.html"
            page.parent.mkdir(parents=True, exist_ok=True)
            links = "".join(
                f'<a href="../../files/{n}#sha256={hashlib.sha256(self.wheels[n]).hexdigest()}">'
                f"{n}</a>\n"
                for n in names
            )
            page.write_text(f"<html><body>{links}</body></html>", encoding="utf-8")
        return hashlib.sha256(data).hexdigest()

    def close(self) -> None:
        self.server.shutdown()


class _QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args) -> None:
        pass


def lock_for(*wheels: tuple[str, bytes], wrong_hash: bool = False) -> str:
    """真实文件 → 锁文件（``wrong_hash``：#> 行与 --hash 一起写成别的内容的哈希）。"""
    blocks: dict[str, list[tuple[str, int, str]]] = {}
    for filename, data in wheels:
        digest = hashlib.sha256(b"tampered" + data if wrong_hash else data).hexdigest()
        name, version = filename.split("-")[:2]
        blocks.setdefault(f"{name}=={version}", []).append((filename, len(data), digest))
    parts = ["# python: 3.12"]
    for spec, files in blocks.items():
        parts += [f"#> {f} {size} sha256:{h}" for f, size, h in files]
        parts.append(spec + "".join(f" --hash=sha256:{h}" for _f, _s, h in files))
    return "\n".join(parts) + "\n"


def closed_port() -> str:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    return f"http://127.0.0.1:{port}/simple"


@pytest.fixture
def index(tmp_path):
    served = Index(tmp_path / "index")
    yield served
    served.close()


PLUGIN = """
import sys

from movieclaw_api.plugins.keys import HOST_OPS, PLUGIN_DATA
from movieclaw_sdk import plugin

import mcdemo  # 批准安装的第三方依赖


@plugin(
    "acme-pkg",
    title="依赖插件",
    inject=(HOST_OPS, PLUGIN_DATA),
    permissions=("app.plugins.list",),
)
async def apply(ctx) -> None:
    store = ctx.use(PLUGIN_DATA).scoped(ctx)
    loaded = {{"value": mcdemo.VALUE, "file": mcdemo.__file__, "last": sys.path[-1]}}
    await store.set("loaded", loaded)
"""


def versioned(version: int, lock_text: str, *, wheels: dict[str, bytes] | None = None) -> bytes:
    manifest = (
        MANIFEST.format(
            id="acme-pkg",
            version=version,
            runtime="process",
            sdk="^1.0",
            requires="",
            operations='"app.plugins.list"',
        )
        + '\n[dependencies]\nlock = "requirements.lock"\n'
    )
    files = {"requirements.lock": lock_text}
    files |= {f"wheels/{name}": data for name, data in (wheels or {}).items()}
    return package(version, manifest=manifest, files=files, source=textwrap.dedent(PLUGIN.format()))


def approve(client, version: int, dependencies: str | None = None):
    body = {"version": f"{version}.0.0", "operations": ["app.plugins.list"]}
    if dependencies is not None:
        body["dependencies"] = dependencies
    return client.post("/api/v1/app/plugins/packages/acme-pkg/approve", json=body)


def consent(client, data: bytes):
    """上传并按批准页给出的锁文件哈希批准。"""
    view = upload(client, data)
    assert view.status_code == 200, view.text
    deps = view.json()["data"]["dependencies"]
    return approve(client, int(view.json()["data"]["version"].split(".")[0]), deps["lock_digest"])


def set_index(client, url: str) -> None:
    current = client.get("/api/v1/network/config").json()["data"]
    payload = {k: current[k] for k in ("proxy_mode", "proxy_url", "proxy_services")}
    reply = client.put("/api/v1/network/config", json={**payload, "pypi_index_url": url})
    assert reply.status_code == 200, reply.text
    assert reply.json()["data"]["pypi_index_url"] == url


def row(client) -> dict:
    data = client.get("/api/v1/app/plugins/packages").json()["data"]
    return {p["id"]: p for p in data["installed"]}["acme-pkg"]


# ---------------------------------------------------------------------- 授权
def test_consent_is_given_per_lock_and_asked_again_only_when_it_changes(data_dir, index) -> None:
    from movieclaw_api.plugins import packages as pkg

    v100 = make_wheel("mcdemo", "1.0.0")
    v110 = make_wheel("mcdemo", "1.1.0")
    extra = make_wheel("mcextra", "0.1.0")
    native = make_wheel("mcnative", "2.0.0", tag="cp312-cp312-manylinux_2_17_x86_64")
    for wheel in (v100, v110, extra):
        index.add(*wheel)
    first = lock_for(v100, extra)
    app, client = start()
    with client:
        set_index(client, index.url)
        # 首次安装：批准页列出依赖，不带锁文件哈希就不让装
        view = upload(client, versioned(1, first)).json()["data"]
        deps = view["dependencies"]
        assert deps["needs_consent"] and deps["index"] == index.url
        assert [(p["name"], p["native"], p["change"]) for p in deps["packages"]] == [
            ("mcdemo", False, "added"),
            ("mcextra", False, "added"),
        ]
        refused = approve(client, 1)
        assert refused.status_code == 400
        message = refused.json()["message"]
        assert "需要下载并安装 2 个第三方包" in message and "mcdemo 1.0.0、mcextra 0.1.0" in message
        assert deps["lock_digest"] in message
        assert approve(client, 1, "0" * 64).status_code == 400
        reply = approve(client, 1, deps["lock_digest"])
        assert reply.status_code == 200, reply.text
        assert reply.json()["data"]["status"] == "active"
        record = pkg.installed(get_settings())["acme-pkg"]
        assert record.dependencies["digest"] == deps["lock_digest"]

        # 升级、锁文件没变：不再问
        view = upload(client, versioned(2, first)).json()["data"]
        assert view["dependencies"]["needs_consent"] is False
        assert {p["change"] for p in view["dependencies"]["packages"]} == {None}
        assert approve(client, 2).json()["data"]["status"] == "active"

        # 升级、锁文件变了：列出新增、换版本、移除再问一次；含本机代码的标出
        changed = lock_for(v110, native)
        view = upload(client, versioned(3, changed)).json()["data"]
        deps = view["dependencies"]
        assert deps["needs_consent"] and deps["removed"] == ["mcextra 0.1.0"]
        rows = {p["name"]: p for p in deps["packages"]}
        assert rows["mcdemo"]["change"] == "changed"
        assert rows["mcdemo"]["previous_version"] == "1.0.0"
        assert rows["mcnative"]["change"] == "added" and rows["mcnative"]["native"]
        message = approve(client, 3).json()["message"]
        assert "新增：mcnative 2.0.0；换版本：mcdemo 1.0.0 → 1.1.0；移除：mcextra 0.1.0" in message
        assert "mcnative 2.0.0（含本机代码）" in message


# ---------------------------------------------------------------------- 安装与加载
def test_install_load_failures_offline_wheels_and_reinstall(data_dir, index, monkeypatch) -> None:
    from movieclaw_api.services import plugin_deps

    marker = data_dir / "pth-ran"
    v100 = make_wheel("mcdemo", "1.0.0", pth=f"import os; open({str(marker)!r}, 'w').close()\n")
    v110 = make_wheel("mcdemo", "1.1.0")
    extra = make_wheel("mcextra", "0.1.0")
    for wheel in (v100, v110, extra):
        index.add(*wheel)
    deps_root = data_dir / "plugins" / "deps"
    offline = closed_port()
    app, client = start()
    with client:
        # 断网：连不上包索引 → 不装、写明原因，待批准的包留着
        set_index(client, offline)
        reply = consent(client, versioned(1, lock_for(v100)))
        assert reply.status_code == 400
        assert "连不上包索引" in reply.json()["message"] and "待批准区" in reply.json()["message"]
        assert app.state.kernel.fiber("acme-pkg") is None
        pending = client.get("/api/v1/app/plugins/packages").json()["data"]["pending"]
        assert pending[0]["dependency_progress"]["phase"] == "failed"
        # 网络好了：重新批准即重试，装上并从依赖目录导入
        set_index(client, index.url)
        digest = pending[0]["dependencies"]["lock_digest"]
        reply = approve(client, 1, digest)
        assert reply.json()["data"]["status"] == "active", reply.text
        loaded = stored(client)
        target = plugin_deps.target_dir(get_settings(), digest)
        assert loaded["value"] == "1.0.0"
        assert Path(loaded["file"]).is_relative_to(target) and loaded["last"] == str(target)
        assert target.name.startswith(digest[:16]) and (target / ".complete").is_file()
        assert (target / "mcdemo-startup.pth").is_file() and not marker.exists()  # .pth 不执行
        assert (deps_root / ".cache" / hashlib.sha256(v100[1]).hexdigest() / v100[0]).is_file()
        assert row(client)["dependencies"] == {"packages": ["mcdemo 1.0.0"], "progress": None}

        # 哈希不对：下载到的文件与锁文件不符 → 丢弃、不装，v1 照常运行
        reply = consent(client, versioned(2, lock_for(v110, wrong_hash=True)))
        assert reply.status_code == 400 and "哈希不对" in reply.json()["message"]
        tampered = hashlib.sha256(b"tampered" + v110[1]).hexdigest()
        assert not (deps_root / ".cache" / tampered).exists()  # 丢弃，不留空目录
        assert stored(client)["value"] == "1.0.0" and row(client)["version"] == "1.0.0"
        client.delete("/api/v1/app/plugins/packages/acme-pkg/pending")

        # 没有适用于本机平台的轮子：不联网直接拒绝
        windows = make_wheel("mcdemo", "1.1.0", tag="cp312-cp312-win_amd64")
        reply = consent(client, versioned(3, lock_for(windows)))
        assert reply.status_code == 400
        assert (
            "没有适用于这台服务器" in reply.json()["message"]
            and "mcdemo 1.1.0" in reply.json()["message"]
        )
        client.delete("/api/v1/app/plugins/packages/acme-pkg/pending")

        # 包内 wheels/：断网也装得上
        set_index(client, offline)
        reply = consent(client, versioned(4, lock_for(v110), wheels=dict([v110])))
        assert reply.json()["data"]["status"] == "active", reply.text
        assert stored(client)["value"] == "1.1.0"

        # 只保留当前版与上一版引用的依赖目录
        set_index(client, index.url)
        assert (
            consent(client, versioned(5, lock_for(v110, extra))).json()["data"]["status"]
            == "active"
        )
        dirs = sorted(p.name for p in deps_root.iterdir() if p.name != ".cache")
        assert len(dirs) == 2 and not any(d.startswith(digest[:16]) for d in dirs)
        assert not (deps_root / ".cache" / hashlib.sha256(v100[1]).hexdigest()).exists()
        # 之后两次启动都在断网下进行（设置落库，启动即生效）
        set_index(client, offline)

    # 主程序换了 Python 版本（平台标签变了）：启动时后台按原锁文件重装，不再问；轮子用缓存
    monkeypatch.setattr(plugin_deps, "platform_tag", lambda: "cp399-test_platform")
    app, client = start()
    with client:
        wait_active(app)
        assert stored(client)["value"] == "1.1.0"
        assert (deps_root / next(p.name for p in deps_root.iterdir() if "cp399" in p.name)).is_dir()

    # 缓存也没了又断网：后台重装失败，插件不挂载、写明原因；网络好了点「重试」
    monkeypatch.setattr(plugin_deps, "platform_tag", lambda: "cp398-test_platform")
    shutil.rmtree(deps_root / ".cache")
    app, client = start()
    with client:
        progress = wait_progress(client, "failed")
        assert "连不上包索引" in progress["error"]
        assert app.state.kernel.fiber("acme-pkg") is None
        set_index(client, index.url)
        reply = client.post("/api/v1/app/plugins/packages/acme-pkg/dependencies/retry")
        assert reply.status_code == 200, reply.text
        assert reply.json()["data"]["state"] == "active"
        assert row(client)["dependencies"]["progress"] is None
        assert stored(client)["value"] == "1.1.0"


def wait_active(app, timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        fiber = app.state.kernel.fiber("acme-pkg")
        if fiber is not None and fiber.state.value == "active":
            return
        time.sleep(0.2)
    raise AssertionError("依赖重装后插件没有挂上")


def wait_progress(client, phase: str, timeout: float = 30.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        progress = row(client)["dependencies"]["progress"]
        if progress and progress["phase"] == phase:
            return progress
        time.sleep(0.2)
    raise AssertionError(f"依赖安装进度没有到 {phase}")
