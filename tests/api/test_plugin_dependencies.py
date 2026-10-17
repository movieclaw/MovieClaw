"""插件第三方依赖（docs/design/plugin-dependencies.md）：真实应用、真实接口。

上传时校验清单的 ``[dependencies]`` 与锁文件：只给独立进程运行的插件、锁文件要在包里、
与主程序已有的包重名一律拒绝；合规的包进入待批准区。
"""

from __future__ import annotations

import pytest
from tests.api import test_plugin_packages as base
from tests.api.test_plugin_packages import MANIFEST, package, start, upload
from tests.unit.test_plugin_deps_lock import ECDSA, LZ4, block, lock

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
