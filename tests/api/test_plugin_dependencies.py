"""插件第三方依赖（docs/design/plugin-dependencies.md）：真实应用、真实接口。

上传时校验清单的 ``[dependencies]`` 与锁文件：只给独立进程运行的插件、锁文件要在包里、
与主程序已有的包重名一律拒绝；合规的包进入待批准区。
"""

from __future__ import annotations

import pytest
from tests.api import test_plugin_packages as base
from tests.api.test_plugin_packages import MANIFEST, package, start, upload
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


def approve(client, version: int, dependencies: str | None = None):
    body = {"version": f"{version}.0.0", "operations": ["app.plugins.list"]}
    if dependencies is not None:
        body["dependencies"] = dependencies
    return client.post("/api/v1/app/plugins/packages/acme-pkg/approve", json=body)


def versioned(version: int, lock_text: str) -> bytes:
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
    return package(version, manifest=manifest, files={"requirements.lock": lock_text})


def test_consent_is_given_per_lock_and_asked_again_only_when_it_changes(data_dir) -> None:
    from movieclaw_api.plugins import packages as pkg

    app, client = start()
    with client:
        # 首次安装：批准页列出依赖，不带锁文件哈希就不让装
        view = upload(client, versioned(1, LOCK)).json()["data"]
        deps = view["dependencies"]
        assert deps["needs_consent"] and deps["index_label"] == "PyPI"
        assert [(p["name"], p["native"], p["change"]) for p in deps["packages"]] == [
            ("lz4", True, "added"),
            ("ecdsa", False, "added"),
        ]
        assert deps["native"] == ["lz4"]
        refused = approve(client, 1)
        assert refused.status_code == 400
        message = refused.json()["message"]
        assert "需要下载并安装 2 个第三方包" in message and "lz4 4.4.4（含本机代码）" in message
        assert deps["lock_digest"] in message
        assert approve(client, 1, "0" * 64).status_code == 400
        reply = approve(client, 1, deps["lock_digest"])
        assert reply.status_code == 200, reply.text
        record = pkg.installed(get_settings())["acme-pkg"]
        assert record.dependencies["digest"] == deps["lock_digest"]
        assert record.dependencies["lock"] == "requirements.lock"

        # 升级、锁文件没变：不再问
        view = upload(client, versioned(2, LOCK)).json()["data"]
        assert view["dependencies"]["needs_consent"] is False
        assert {p["change"] for p in view["dependencies"]["packages"]} == {None}
        assert approve(client, 2).status_code == 200

        # 升级、锁文件变了：列出新增、升级、移除再问一次
        changed = lock(
            block("lz4==4.4.5", tuple(f.replace("4.4.4", "4.4.5") for f in LZ4)),
            block("six==1.17.0", ("six-1.17.0-py2.py3-none-any.whl",)),
        )
        view = upload(client, versioned(3, changed)).json()["data"]
        deps = view["dependencies"]
        assert deps["needs_consent"] and deps["removed"] == ["ecdsa 0.19.1"]
        rows = {p["name"]: p for p in deps["packages"]}
        assert rows["lz4"]["change"] == "changed" and rows["lz4"]["previous_version"] == "4.4.4"
        assert rows["six"]["change"] == "added"
        message = approve(client, 3).json()["message"]
        assert "新增：six 1.17.0；换版本：lz4 4.4.4 → 4.4.5；移除：ecdsa 0.19.1" in message
        assert approve(client, 3, deps["lock_digest"]).status_code == 200
        record = pkg.installed(get_settings())["acme-pkg"]
        assert record.dependencies["digest"] == deps["lock_digest"]
        assert record.previous["dependencies"]["packages"][0]["name"] == "lz4"
