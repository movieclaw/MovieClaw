"""安装前检查一个插件目录：用服务器同一套逻辑校验，再真的导入入口模块。

    python check_plugin.py plugins/hello-world
    python check_plugin.py plugins/hello-world --lock   # 先按 requirements.in 生成依赖锁文件再检查

输出 ✓ / ⚠ / ✗。有 ✗ 时退出码为 1，必须修好再安装；⚠ 要逐条判断是否需要处理。

检查项：
1. 清单与压缩包：按 ``mclaw plugin pack`` 的规则在内存里打包，交给服务器的 ``read_archive`` 校验；
2. 兼容与权限：服务器的 ``check_compat``（SDK、契约、宿主操作是否存在、路径授权写法、id 是否被占用）；
3. 入口模块：在独立子进程里导入，找到名字等于清单 id 的 ``@plugin``，核对 inject / permissions / 用到的契约；
4. 其他：全部 .py 能编译、危险操作是否逐个列出、inline 运行、包大小；
5. 第三方依赖（``[dependencies] lock``）：钉死、哈希、只接受轮子、不与主程序重名，缺哪个平台的轮子；
6. 网页主题（``[theme]``）：theme.css 的规则不能漏出本主题的作用域去改内核变量、内核部件或全局元素。
"""

from __future__ import annotations

import importlib
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
                    {
                        "name": k.name,
                        "internal": k.stability is Stability.INTERNAL,
                        "kind": getattr(k, "kind", ""),
                    }
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
    make_lock = "--lock" in argv
    argv = [a for a in argv if a != "--lock"]
    if len(argv) != 1:
        print(__doc__)
        return 2
    directory = Path(argv[0])
    if not (directory / MANIFEST).is_file():
        fail(f"{directory} 下没有 {MANIFEST}")
        return 1
    if make_lock:
        from movieclaw_sdk import deps

        if deps.main(["lock", str(directory)]) != 0:
            fail("生成依赖锁文件失败（原因见上）")
            return 1

    from movieclaw_api.plugins.packages import (
        MAX_ARCHIVE_BYTES,
        PackageError,
        check_compat,
        read_archive,
    )
    from movieclaw_sdk.surface import MODULES

    # 契约在定义它的模块被导入时才登记进目录；先全部导入，否则 [requires] 会被误报为「未知契约」
    for module_name in MODULES:
        importlib.import_module(module_name)

    # 1. 清单与压缩包
    data = pack(directory)
    try:
        manifest, _archive = read_archive(data)
    except PackageError as exc:
        fail(f"清单 / 打包：{exc}")
        return 1
    plugin = manifest.plugin
    from movieclaw_api.plugins.packages import ID_RULE, is_legacy_id

    if is_legacy_id(plugin.id):
        fail(f"id「{plugin.id}」是旧格式（带点）：新插件的 id 须{ID_RULE}；清单 id 与 @plugin 的名字一起改")
        return _finish()
    web_only = not plugin.entry and plugin.runtime != "exec"
    if web_only:
        kind = "只带主题" if manifest.theme is not None else "只带网页"
        ok(f"清单合规：{plugin.id} v{plugin.version}，{kind}（没有后端代码）")
    else:
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
    if manifest.dependencies is not None:
        _check_dependencies(directory, manifest)

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

    # 回调端点：代码里登记 / 发密钥用到的端点名，须在清单 callbacks 里声明（用户批准时看得到）
    import re

    used_callbacks: set[str] = set()
    for path in sorted(directory.rglob("*.py")):
        if "__pycache__" in path.parts or "vendor" in path.relative_to(directory).parts:
            continue
        text = path.read_text("utf-8", errors="replace")
        used_callbacks |= set(
            re.findall(r"\.(?:endpoint|issue)\(\s*ctx\s*,\s*[\"']([a-z][a-z0-9-]*)[\"']", text)
        )
    declared_callbacks = set(manifest.permissions.callbacks)
    if used_callbacks - declared_callbacks:
        missing = "、".join(sorted(used_callbacks - declared_callbacks))
        fail(f"代码里用了回调端点 {missing}，清单 [permissions] callbacks 没声明（装上会启动失败）")
    elif declared_callbacks:
        ok(f"回调端点：{sorted(declared_callbacks)}（批准安装时会单独列给用户看）")
    if declared_callbacks - used_callbacks and used_callbacks:
        warn(f"清单声明了但代码里没找到的回调端点：{'、'.join(sorted(declared_callbacks - used_callbacks))}")

    # 网页（docs/design/plugin-web-pages.md）
    _check_web(directory, plugin.id, plugin.title)
    # 网页主题（docs/design/theme-plugins.md）
    _check_theme(directory, plugin.id, manifest.theme)

    # 4. 导入入口模块
    if web_only:
        return _finish()
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
    for key in match["inject"]:
        if key["kind"] == "registry":
            fail(f"inject 里写了注册表 {key['name']}：注册表在 apply 里 ctx.contribute(...)，不要写进 inject（只写进清单 [requires]）")
        elif key["kind"] == "event":
            fail(f"inject 里写了事件 / 钩子 {key['name']}：在 apply 里 ctx.on(...)，不要写进 inject（只写进清单 [requires]）")
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
    injected = {k["name"] for k in match["inject"]}
    # agent:<档位> 是调用 AI 助手的授权（经 AGENT 服务），不算宿主操作
    operations = {d for d in declared if not d.startswith("agent:")}
    agent_grants = declared - operations
    if "host-ops" in injected and not operations:
        warn("inject 了 HOST_OPS 但没有申请任何宿主操作，调用会被拒绝")
    if operations and "host-ops" not in injected:
        warn("申请了宿主操作但没有 inject HOST_OPS，拿不到调用入口")
    if agent_grants and "agent" not in injected:
        warn("申请了 agent:<档位> 但没有 inject AGENT，拿不到 AI 助手入口")
    if "agent" in injected and not agent_grants:
        warn("inject 了 AGENT 但没有申请 agent:<档位>（agent:none / agent:mclaw），调用会被拒绝")
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


def _check_web(directory: Path, entry_id: str, title: str) -> None:
    """插件网页：入口、manifest 的侧边栏项、图标文件、跳主程序的链接。"""
    import json
    import re

    from movieclaw_api.services import plugin_web

    web = directory / "web"
    if not web.is_dir():
        return
    if not (web / "index.html").is_file():
        fail("有 web/ 目录但没有 web/index.html：网页的入口必须是它")
        return
    warn(
        f"带网页（装好后地址 /apps/{entry_id}）：网页会以使用它的人的身份运行，管理员打开时拥有管理员的全部权限。"
        "安装前要告诉用户并得到同意，同意后 mclaw plugin dev 加 --allow-web"
    )
    for name in plugin_web.MANIFEST_NAMES:
        raw = web / name
        if raw.is_file():
            try:
                data = json.loads(raw.read_text("utf-8"))
            except ValueError as exc:
                fail(f"web/{name} 不是合法的 JSON：{exc}")
                return
            shortcuts = data.get("shortcuts") if isinstance(data, dict) else None
            break
    else:
        data, shortcuts = None, None
        ok("没有 manifest.webmanifest：侧边栏一项，文字用插件名，图标用默认的")
    plugin = plugin_web.WebPlugin(id=entry_id, title=title, source="local", root=web, consent=None)
    manifest = plugin_web.read_manifest(plugin)
    base = plugin_web.base_path(entry_id)
    if data is not None:
        items = "、".join(
            f"「{e.label}」→ /apps/{entry_id}{('/' + e.path) if e.path else ''}" for e in manifest.entries
        )
        ok(f"侧边栏：{items}")
        if isinstance(shortcuts, list) and len(manifest.entries) - 1 < len(shortcuts):
            warn("manifest 的 shortcuts 里有地址越出了 web/（或不是相对地址），这些项不会出现在侧边栏")
    for entry in manifest.entries:
        if entry.icon and plugin_web.resolve_file(web, entry.icon[len(base) :].partition("?")[0]) is None:
            warn(f"「{entry.label}」的图标 {entry.icon[len(base) :]} 在 web/ 里找不到，会显示默认图标")
        elif entry.icon and not entry.monochrome:
            warn(
                f"「{entry.label}」的图标没标 purpose: monochrome：会按原图显示，不跟主题变色"
                "（单色线条图标标上它，侧边栏按当前文字颜色着色）"
            )
    link = re.compile(r"<a\b[^>]*\bhref=[\"'](/[^\"']*)[\"'][^>]*>", re.I)
    for path in sorted(web.rglob("*.html")):
        for match in link.finditer(path.read_text("utf-8", errors="replace")):
            href = match.group(1)
            if href.startswith("/api/") or "target=" in match.group(0):
                continue
            warn(
                f"web/{path.relative_to(web)} 里的链接 {href} 没写 target=\"_top\"："
                "跳主程序的页面要加上它；插件自己的页面用相对地址（不带开头的 /）"
            )


def _check_theme(directory: Path, theme_id: str, theme: object) -> None:
    """网页主题：theme.css 按 CSS 契约（movieclaw_sdk/theme_css.json）检查作用域。

    所有已装主题的 CSS 对每个用户都会加载（不管选的是哪个主题），所以改内核变量、内核部件、
    全局元素的规则必须挂在 ``html[data-theme="<id>"]`` 底下，否则会改坏别的主题。
    只用主题自己类名的规则（如 ``.oc-hero``、带前缀的 Tailwind 工具类）不用挂。
    """
    import re

    from movieclaw_sdk.theme import PUBLIC_PARTS, PUBLIC_VARIABLES, READONLY_VARIABLES

    if theme is None:
        return
    label, layout = theme.label, theme.layout  # type: ignore[attr-defined]
    has_js = (directory / "theme" / "index.js").is_file()
    ok(
        f"主题「{label}」：版式 {layout}，{'液态玻璃' if theme.glass else '不用玻璃'}，"  # type: ignore[attr-defined]
        + ("带外框组件（theme/index.js）" if has_js else "纯 CSS")
    )
    if has_js:
        warn(
            "带外框组件：主题代码在主程序页面里运行，拥有使用者的全部权限。"
            "安装前要告诉用户并得到同意，同意后 mclaw plugin dev 加 --allow-theme"
        )
    css = (directory / "theme" / "theme.css").read_text("utf-8", errors="replace")
    scope = re.compile(r"\[data-theme=([\"']?)" + re.escape(theme_id) + r"\1\]")
    leaks: list[str] = []
    readonly: set[str] = set()
    for chain, body in _css_rules(css):
        declared = set(re.findall(r"(?:^|;)\s*(--[\w-]+)\s*:", body))
        readonly |= declared & set(READONLY_VARIABLES)
        if any(scope.search(selector) for selector in chain[:-1]):
            continue
        for part in _split_selectors(chain[-1]):
            if scope.search(part):
                continue
            classes = {c.replace("\\", "") for c in re.findall(r"\.((?:[\w-]|\\.)+)", part)}
            # 只设自定义属性（Tailwind 的 --tw-* 初值、主题自己的变量）不算改全局元素
            properties = re.findall(r"(?:^|;)\s*([a-zA-Z][a-zA-Z-]*)\s*:", body)
            if classes & PUBLIC_PARTS:
                leaks.append(f"{part}（改了内核部件 .{'、.'.join(sorted(classes & PUBLIC_PARTS))}）")
            elif declared & (set(PUBLIC_VARIABLES) | set(READONLY_VARIABLES)):
                leaks.append(f"{part}（改了内核变量 {'、'.join(sorted(declared & set(PUBLIC_VARIABLES)))}）")
            elif not classes and properties:
                leaks.append(f"{part}（改了全局元素）")
    if leaks:
        shown = "\n    ".join(leaks[:8]) + (f"\n    ……共 {len(leaks)} 处" if len(leaks) > 8 else "")
        fail(
            f'theme/theme.css 有规则没挂在 html[data-theme="{theme_id}"] 底下，会改坏别的主题'
            f"（所有已装主题的 CSS 对每个用户都会加载）：\n    {shown}"
        )
    else:
        ok(f'theme.css 的作用域：改内核的规则都挂在 html[data-theme="{theme_id}"] 底下')
    root = re.search(r"html\[data-theme=([\"']?)" + re.escape(theme_id) + r"\1\]\s*\{([^{}]*)\}", css)
    if root:
        for name, picked in (("bg", theme.preview.bg), ("accent", theme.preview.accent)):  # type: ignore[attr-defined]
            value = re.search(rf"--{name}\s*:\s*(#[0-9a-fA-F]{{6}})\b", root.group(2))
            if value and value.group(1).lower() != picked.lower():
                warn(
                    f"清单 [theme] preview.{name} 是 {picked}，theme.css 的 --{name} 是 {value.group(1)}："
                    "外观卡片的缩略图会和实际不一样"
                )
    if readonly:
        warn(f"theme.css 写了只读变量 {'、'.join(sorted(readonly))}：它们由内核按设备实时算出，主题只读不写")


def _css_rules(css: str) -> list[tuple[list[str], str]]:
    """粗解析 CSS：每条普通规则给出（外层到本层的选择器链，声明文本）。

    跳过 @keyframes / @font-face / @property 之类的内部块；@media / @supports / @layer 只是容器。
    嵌套规则（CSS nesting）的选择器链带上外层选择器，用来判断作用域。
    """
    import re

    css = re.sub(r"/\*[\s\S]*?\*/", "", css)
    opaque = ("@keyframes", "@-webkit-keyframes", "@font-face", "@property", "@counter-style", "@page")
    stack: list[str] = []
    rules: list[tuple[list[str], str]] = []
    buf: list[str] = []
    i = 0
    while i < len(css):
        ch = css[i]
        if ch == "\\":
            buf.append(css[i : i + 2])
            i += 2
            continue
        if ch in "\"'":
            end = css.find(ch, i + 1)
            end = len(css) - 1 if end < 0 else end
            buf.append(css[i : end + 1])
            i = end + 1
            continue
        if ch == "{":
            stack.append("".join(buf).rpartition(";")[2].strip())
            buf = []
        elif ch == "}":
            body = "".join(buf)
            buf = []
            prelude = stack.pop() if stack else ""
            if prelude and not prelude.startswith("@") and not any(p.startswith(opaque) for p in stack):
                rules.append(([p for p in stack if not p.startswith("@")] + [prelude], body))
        else:
            buf.append(ch)
        i += 1
    return rules


def _split_selectors(selector: str) -> list[str]:
    """按顶层逗号拆选择器列表（括号、方括号、转义里的逗号不算）。"""
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    i = 0
    while i < len(selector):
        ch = selector[i]
        if ch == "\\":
            current.append(selector[i : i + 2])
            i += 2
            continue
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
        i += 1
    parts.append("".join(current).strip())
    return [p for p in parts if p]


def _check_dependencies(directory: Path, manifest: object) -> None:
    """锁文件已由 read_archive 校验过（钉死、哈希、只轮子、与本机主程序重名）；这里补平台覆盖。"""
    from movieclaw_sdk import deps

    lock = deps.parse_lock((directory / manifest.dependencies.lock).read_text("utf-8"))  # type: ignore[attr-defined]
    native = [p.name for p in lock.packages if p.native]
    tags = deps.target_tags("linux/amd64", lock.python or "3.12")
    total = sum(w.size or 0 for w in (p.pick(tags) for p in lock.packages) if w)
    ok(
        f"第三方依赖：{len(lock.packages)} 个包，linux/amd64 上约 {total / 1024 / 1024:.1f} MB"
        + (f"，含本机代码：{'、'.join(native)}" if native else "，全部是纯 Python")
        + "（批准安装时会逐个列给用户看）"
    )
    for target, lacking in deps.missing_platforms(lock, lock.python or "3.12").items():
        warn(f"依赖没有 {target} 的轮子：{'、'.join(lacking)}（装到这个平台会失败）")


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
