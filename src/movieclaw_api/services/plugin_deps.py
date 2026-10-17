"""插件第三方依赖：批准页展示与授权（docs/design/plugin-dependencies.md §2）。

批准页在权限之后列出要装的包：包名、版本、这台服务器上要下载的大小、是否含本机代码、从哪个索引下载。
同意的是「这一份锁文件」（按内容哈希记在安装记录里）：升级时锁文件没变就不再问，变了列出增删改再问。
"""

from __future__ import annotations

from typing import Any

from movieclaw_sdk import deps

INDEX_LABELS = {deps.DEFAULT_INDEX: "PyPI", deps.TSINGHUA_INDEX: "PyPI 清华镜像"}


def index_url() -> str:
    """下载依赖用的包索引。"""
    return deps.DEFAULT_INDEX


def index_label(url: str) -> str:
    return INDEX_LABELS.get(url.rstrip("/"), url)


def view(lock: deps.Lock | None, approved: dict[str, Any] | None) -> dict[str, Any] | None:
    """批准页的依赖一节；``approved`` 是当前已安装版本的依赖授权（没有则全部算新增）。"""
    if lock is None:
        return None
    before = {p["name"]: p["version"] for p in (approved or {}).get("packages", [])}
    tags = deps.here_tags()
    rows: list[dict[str, Any]] = []
    for package in lock.packages:
        wheel = package.pick(tags)
        previous = before.get(package.name)
        rows.append(
            {
                "name": package.name,
                "version": package.version,
                "size": wheel.size if wheel else None,
                "native": package.native,
                "available": wheel is not None,
                "change": (
                    "added"
                    if package.name not in before
                    else ("changed" if previous != package.version else None)
                ),
                "previous_version": previous if previous != package.version else None,
            }
        )
    names = {p.name for p in lock.packages}
    url = index_url()
    return {
        "lock_digest": lock.digest,
        "packages": rows,
        "total_size": sum(r["size"] or 0 for r in rows),
        "native": [r["name"] for r in rows if r["native"]],
        "unavailable": [f"{r['name']} {r['version']}" for r in rows if not r["available"]],
        "removed": [f"{name} {version}" for name, version in before.items() if name not in names],
        "index": url,
        "index_label": index_label(url),
        "needs_consent": (approved or {}).get("digest") != lock.digest,
    }


def summary(view: dict[str, Any]) -> str:
    """一行说明：「需要下载并安装 6 个第三方包（共 4.2 MB，来自 PyPI）：…」。"""
    packages = "、".join(
        f"{r['name']} {r['version']}" + ("（含本机代码）" if r["native"] else "")
        for r in view["packages"]
    )
    size = view["total_size"] / 1024 / 1024
    return (
        f"需要下载并安装 {len(view['packages'])} 个第三方包"
        f"（共 {size:.1f} MB，来自 {view['index_label']}）：{packages}"
    )
