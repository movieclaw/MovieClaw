"""插件包里的非 Python 插件（runtime = "exec"）与 Agent 权限。

见 plugin-ipc-http.md §9、plugin-agent.md §4。

只测清单与解包这一层：exec 包须给可执行文件与平台、平台不符装不上、解包保留可执行位；
插件包最高只能申请 agent:mclaw。拉起 Go 插件的端到端见 test_plugin_exec.py。
"""

from __future__ import annotations

import io
import os
import tomllib
import zipfile

import pytest

from movieclaw_api.plugins import packages as pkg


def archive(manifest: str, files: dict[str, tuple[bytes, int]] | None = None) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("movieclaw-plugin.toml", manifest)
        for name, (content, mode) in (files or {}).items():
            info = zipfile.ZipInfo(name)
            info.external_attr = mode << 16
            zf.writestr(info, content)
    return buf.getvalue()


def manifest(**plugin: str) -> str:
    fields = {"id": '"go-demo"', "title": '"示例"', "version": '"0.1.0"', **plugin}
    body = "\n".join(f"{k} = {v}" for k, v in fields.items())
    return f"[plugin]\n{body}\n\n[permissions]\noperations = []\n"


HERE = pkg.current_platform()
EXEC = {"runtime": '"exec"', "command": '"bin/bridge"', "platforms": f'["{HERE}"]'}


def test_exec_packages_need_their_executable_and_platform(tmp_path) -> None:
    with pytest.raises(pkg.PackageError, match="bin/bridge"):
        pkg.read_archive(archive(manifest(**EXEC)))
    other = {**EXEC, "platforms": '["plan9/mips"]'}
    with pytest.raises(pkg.PackageError, match=f"这台服务器是 {HERE}"):
        pkg.read_archive(archive(manifest(**other), {"bin/bridge": (b"x", 0o755)}))
    with pytest.raises(pkg.PackageError, match="platforms"):
        pkg.read_archive(archive(manifest(runtime='"exec"', command='"bin/bridge"')))
    with pytest.raises(pkg.PackageError, match="entry"):
        pkg.read_archive(archive(manifest()))  # 不是 exec 就得有入口模块

    found, opened = pkg.read_archive(archive(manifest(**EXEC), {"bin/bridge": (b"x", 0o755)}))
    assert found.plugin.runtime == "exec" and found.plugin.command == "bin/bridge"
    target = tmp_path / "0.1.0"
    pkg.extract(opened, target)
    assert os.access(target / "bin" / "bridge", os.X_OK)  # 可执行位随包保留


def test_packages_cannot_ask_for_a_full_agent() -> None:
    def check(*operations: str) -> None:
        listed = ", ".join(f'"{op}"' for op in operations)
        text = manifest(entry='"demo"').replace("operations = []", f"operations = [{listed}]")
        found = pkg.Manifest.model_validate(tomllib.loads(text))
        pkg.check_compat(found, reserved=set(), operations=set())

    check("agent:none")
    check("agent:mclaw")
    with pytest.raises(pkg.PackageError, match="agent:full"):
        check("agent:full")
