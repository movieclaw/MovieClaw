"""安装前检查一个插件目录：用服务器同一套逻辑校验，再真的导入入口模块。

    python check_plugin.py plugins/me.hello

输出 ✓ / ⚠ / ✗。有 ✗ 时退出码为 1，必须修好再安装；⚠ 要逐条判断是否需要处理。

检查项：
1. 清单与压缩包：按 ``mclaw plugin pack`` 的规则在内存里打包，交给服务器的 ``read_archive`` 校验；
2. 兼容与权限：服务器的 ``check_compat``（SDK、契约、宿主操作是否存在、路径授权写法、id 是否被占用）；
3. 入口模块：在独立子进程里导入，找到名字等于清单 id 的 ``@plugin``，核对 inject / permissions / 用到的契约；
4. 其他：全部 .py 能编译、危险操作是否逐个列出、inline 运行、包大小。
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path

MANIFEST = "movieclaw-plugin.toml"

_problems: list[str] = []


def ok(message: str) -> None:
    print(f"✓ {message}")


def warn(message: str) -> None:
    print(f"⚠ {message}")


def fail(message: str) -> None:
    _problems.append(message)
    print(f"✗ {message}")


# ---------------------------------------------------------------------- 打包（与 mclaw plugin pack 同规则）
def _skip(rel_parts: tuple[str, ...], name: str, is_dir: bool) -> bool:
    if is_dir:
        return name in {"__pycache__", ".git", ".venv", "node_modules"} or name.startswith(".")
    return (
        name.endswith((".pyc", ".mcplugin"))
        or name == ".DS_Store"
        or name.startswith("._")
    )


def pack(directory: Path) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for root, dirs, files in os.walk(directory):
            root_path = Path(root)
            rel_root = root_path.relative_to(directory)
            dirs[:] = sorted(d for d in dirs if not _skip(rel_root.parts, d, True))
            for name in sorted(files):
                if _skip(rel_root.parts, name, False):
                    continue
                path = root_path / name
                if path.is_symlink():
                    fail(f"插件目录里不能有软链接：{path.relative_to(directory)}")
                    continue
                archive.write(path, (rel_root / name).as_posix())
    return buffer.getvalue()


# ---------------------------------------------------------------------- 子进程：导入入口模块
_PROBE = r"""
import importlib, inspect, json, sys
from pathlib import Path

directory, module_name, entry_id = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, str(Path(directory) / "vendor"))
sys.path.insert(0, directory)

from movieclaw_kernel import Event, Plugin, RegistryKey, ServiceKey, Stability

out = {"plugins": [], "error": None}
try:
    module = importlib.import_module(module_name)
except Exception as exc:  # noqa: BLE001
    import traceback
    out["error"] = "".join(traceback.format_exception(exc)[-6:])
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)

source = inspect.getsource(module)
out["future_annotations"] = "from __future__ import annotations" in source
out["mounts_routes"] = "routes.mount(" in source or ".mount(ctx" in source
out["contracts_used"] = sorted(
    {
        v.name
        for v in vars(module).values()
        if isinstance(v, (Event, RegistryKey)) and v.stability is not Stability.INTERNAL
    }
)
out["internal_used"] = sorted(
    {
        v.name
        for v in vars(module).values()
        if isinstance(v, (Event, RegistryKey, ServiceKey)) and v.stability is Stability.INTERNAL
    }
)
for value in vars(module).values():
    if isinstance(value, Plugin):
        out["plugins"].append(
            {
                "name": value.name,
                "title": value.title,
                "inject": [
                    {"name": k.name, "internal": k.stability is Stability.INTERNAL}
                    for k in value.inject
                ],
                "permissions": list(value.permissions),
                "config": value.config.__name__ if value.config else None,
            }
        )
print(json.dumps(out, ensure_ascii=False))
"""


def probe(directory: Path, module: str, entry_id: str) -> dict:
    proc = subprocess.run(
        [sys.executable, "-c", _PROBE, str(directory.resolve()), module, entry_id],
        capture_output=True,
        text=True,
        timeout=120,
        cwd=directory,
    )
    lines = [line for line in proc.stdout.splitlines() if line.startswith("{")]
    if proc.returncode != 0 or not lines:
        return {"error": (proc.stderr or proc.stdout)[-2000:] or f"退出码 {proc.returncode}"}
    return json.loads(lines[-1])


# ---------------------------------------------------------------------- 主流程
def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__)
        return 2
    directory = Path(argv[0])
    if not (directory / MANIFEST).is_file():
        fail(f"{directory} 下没有 {MANIFEST}")
        return 1

    from movieclaw_api.plugins.packages import (
        MAX_ARCHIVE_BYTES,
        PackageError,
        check_compat,
        read_archive,
    )

    # 1. 清单与压缩包
    data = pack(directory)
    try:
        manifest, _archive = read_archive(data)
    except PackageError as exc:
        fail(f"清单 / 打包：{exc}")
        return 1
    plugin = manifest.plugin
    ok(f"清单合规：{plugin.id} v{plugin.version}，入口 {plugin.entry}，运行方式 {plugin.runtime}")
    size_kb = len(data) // 1024
    if len(data) > MAX_ARCHIVE_BYTES:
        fail(f"包大小 {size_kb} KB 超过上限")
    else:
        ok(f"包大小 {size_kb} KB")

    # 2. 兼容与权限（服务器同一套逻辑）
    try:
        from movieclaw_api.services.host_ops import _operation_index

        index = _operation_index()
    except Exception as exc:  # noqa: BLE001 -- 没有导出的 spec 时只跳过宿主操作核对
        warn(f"读不到宿主操作目录，跳过操作核对：{exc}")
        index = None
    reserved: set[str] = set()
    try:
        from movieclaw_api.plugins.manifest import BUILTIN_MANIFEST

        reserved = {e.id for e in BUILTIN_MANIFEST}
    except Exception:  # noqa: BLE001
        pass
    try:
        check_compat(manifest, reserved=reserved, operations=set(index or ()) or _any_ops(manifest))
        ok("兼容性：SDK、契约版本、宿主操作、路径授权都通过")
    except PackageError as exc:
        fail(f"兼容性：{exc}")

    try:
        from movieclaw_api.plugins.bundled import bundled_ids

        if plugin.id in bundled_ids():
            warn(f"{plugin.id} 是随应用携带的插件：装上会替换内置版本，卸载后内置版本自动回来")
    except Exception:  # noqa: BLE001
        pass

    operations = list(manifest.permissions.operations)
    if index is not None:
        dangerous = sorted(op for op in operations if not op.endswith(".*") and index.get(op) and index[op].dangerous)
        if dangerous:
            warn(f"申请了危险操作（安装前必须向用户逐个说明）：{'、'.join(dangerous)}")
        for pattern in (p for p in operations if p.endswith(".*")):
            domain = pattern[:-2]
            skipped = sorted(
                op_id for op_id, op in index.items() if op.domain == domain and op.dangerous
            )
            if skipped:
                warn(f"{pattern} 不包含该领域的危险操作（{'、'.join(skipped)}），要用须逐个列出")
    if plugin.runtime == "inline":
        warn("runtime = inline：在主进程里运行，拥有主程序的全部权限；安装须用户单独批准（mclaw 加 --allow-inline）")
    if manifest.permissions.network:
        ok("声明了需要联网（network = true）")

    # 3. 全部 .py 能编译
    bad = False
    for path in sorted(directory.rglob("*.py")):
        if "__pycache__" in path.parts:
            continue
        try:
            compile(path.read_bytes(), str(path), "exec")
        except SyntaxError as exc:
            bad = True
            fail(f"语法错误：{path.relative_to(directory)}:{exc.lineno}：{exc.msg}")
    if not bad:
        ok("全部 .py 文件语法正确")

    # 4. 导入入口模块
    result = probe(directory, plugin.entry, plugin.id)
    if result.get("error"):
        fail(f"导入入口模块 {plugin.entry} 失败：\n{result['error']}")
        return _finish()
    plugins = result.get("plugins") or []
    match = next((p for p in plugins if p["name"] == plugin.id), None)
    if match is None:
        found = "、".join(p["name"] for p in plugins) or "没有"
        fail(f"入口模块里没有名为 {plugin.id} 的 @plugin（找到：{found}）；@plugin 的名字必须与清单 id 一致")
        return _finish()
    ok(f"找到插件 {match['name']}「{match['title']}」")
    internal = [k["name"] for k in match["inject"] if k["internal"]]
    if internal:
        fail(f"inject 了内部服务 {'、'.join(internal)}：第三方插件不能用，只能用 contracts.py 列出的服务")
    if result.get("internal_used"):
        warn(f"模块里引用了内部契约 {'、'.join(result['internal_used'])}：第三方插件用不了，运行时会被拒绝")
    declared = set(operations)
    in_code = set(match["permissions"])
    if in_code != declared:
        warn(
            "@plugin(permissions=...) 与清单 permissions.operations 不一致"
            f"（代码：{sorted(in_code) or '无'}；清单：{sorted(declared) or '无'}）。"
            "实际授予以清单为准，请保持一致"
        )
    else:
        ok(f"宿主操作申请：{sorted(declared) or '无'}")
    if "host-ops" in {k["name"] for k in match["inject"]} and not declared:
        warn("inject 了 HOST_OPS 但没有申请任何宿主操作，调用会被拒绝")
    if declared and "host-ops" not in {k["name"] for k in match["inject"]}:
        warn("申请了宿主操作但没有 inject HOST_OPS，拿不到调用入口")
    used = set(result.get("contracts_used") or [])
    missing = sorted(used - set(manifest.requires))
    if missing:
        warn(f"代码用到了这些契约但清单 [requires] 没写：{'、'.join(missing)}（建议补上，版本见 contracts.py）")
    if result.get("future_annotations") and result.get("mounts_routes"):
        warn(
            "入口模块用了 from __future__ import annotations 又挂了路由：端点参数 / 返回值的类型必须在模块顶层导入，"
            "否则进程外运行时解析不了"
        )
    return _finish()


def _any_ops(manifest: object) -> set[str]:
    """读不到操作目录时，让 check_compat 的操作核对放行（只核对其他项）。"""
    return {op[:-2] + ".x" if op.endswith(".*") else op for op in manifest.permissions.operations}  # type: ignore[attr-defined]


def _finish() -> int:
    if _problems:
        print(f"\n共 {len(_problems)} 个必须修复的问题。")
        return 1
    print("\n检查通过，可以打包安装。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
