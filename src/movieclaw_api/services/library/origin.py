"""文件来源快照（docs/design/library-duplicate-files.md §2）。

回答用户在文件区最常问的一句话：**这个文件是怎么进库的**。台账早就存着
``source`` / ``site_id`` / ``torrent_id``，但它们是给机器用的键，不是给人看的
话；而"哪条监听规则、硬链还是复制、哪个下载器、是首次投递还是洗版投递、
是自动还是人工选种"这些入库现场知道的事，此前一样也没落。

设计原则与 ``trash_context`` 相同：**存展示用快照、不外键**。订阅可以取消、
监听规则可以删、种子表会滚动，快照文案永远能读。快照只有三个键，就是
文件区要显示的三样：

    {"kind": "subscription", "label": "订阅《九门》自动投递",
     "detail": "HDSky · Nine.Gates…-CHDWEB · qBittorrent · 硬链接入库"}

本模块是媒体库自己的部分：监听识别与扫描发现的构造、展示时的取值规则（``origin_of``）。
订阅投递 / 手动下载的文案，以及给旧行（``origin IS NULL``）读时推导等价快照，要读订阅与
下载的表，归获取领域（``services/acquisition_origin.py``，经
``acquisition.current().describe_origins`` 取）。
"""

from __future__ import annotations

import logging
from typing import Any

from movieclaw_api.i18n.stored import reference, source_render
from movieclaw_db.models import FileSource, LibraryFile
from movieclaw_db.models.import_watch import ImportWatch

logger = logging.getLogger("movieclaw_api.library.origin")

KIND_SUBSCRIPTION = "subscription"
KIND_MANUAL_DOWNLOAD = "manual_download"
KIND_WATCH_IMPORT = "watch_import"
KIND_SCAN = "scan"

# 扫描触发方式 → 文案键。扫描本身分不清"文件是谁放进来的"（那正是它与入库
# 管线的区别），能说的只有"哪一轮扫描第一次看见它"
_SCAN_TRIGGER_KEYS = {"manual": "scanManual", "watch": "scanWatch", "scheduled": "scanScheduled"}
_STRATEGIES = ("hardlink", "copy")


def _snapshot(kind: str, label_ref: dict, detail_ref: dict | None = None) -> dict[str, Any]:
    """落库快照：中文回滚文案由引用渲染，读者按自己的语言看引用。"""
    detail = source_render(detail_ref) if detail_ref is not None else None
    result = {"kind": kind, "label": source_render(label_ref), "detail": detail or None}
    for name, ref in (("label", label_ref), ("detail", detail_ref)):
        if ref is not None and (name != "detail" or result["detail"] is not None):
            result[f"{name}_key"] = ref["message_key"]
            result[f"{name}_params"] = ref["params"]
    return result


def _detail_reference(*parts: str | dict | None) -> dict:
    parts = [p.strip() if isinstance(p, str) else p for p in parts if p]
    return reference(
        "library.origin.detail",
        parts={
            "message_list": [p for p in parts if p],
            "separator_key": "library.origin.separator",
        },
    )


def _strategy_reference(strategy: str | None) -> dict | None:
    return reference(f"library.origin.{strategy}") if strategy in _STRATEGIES else None


# ---------------------------------------------------------------------------
# 写：监听识别 / 扫描现场的构造（订阅投递 / 手动下载的在 acquisition_origin）
# ---------------------------------------------------------------------------


def watch_import_origin(rule: ImportWatch) -> dict[str, Any]:
    """监听目录识别入库：没匹配到任何下载任务，只知道从哪个目录、怎么搬进来的。"""
    return _snapshot(
        KIND_WATCH_IMPORT,
        reference("library.origin.watchImport"),
        _detail_reference(
            rule.source_path,
            _strategy_reference(rule.strategy),
            reference("library.origin.unmatched"),
        ),
    )


def scan_origin(trigger: str) -> dict[str, Any]:
    """存量扫描发现：文件不是本系统放进来的，只记哪一轮扫描第一次看见它。

    ``trigger`` 取 manual / watch / scheduled；未知值原样写进 detail。
    """
    return _snapshot(
        KIND_SCAN,
        reference("library.origin.scan"),
        reference(
            "library.origin.scanFound",
            trigger=(
                reference(f"library.origin.{_SCAN_TRIGGER_KEYS[trigger]}")
                if trigger in _SCAN_TRIGGER_KEYS
                else trigger
            ),
        ),
    )


# ---------------------------------------------------------------------------
# 读：旧行的读时推导
# ---------------------------------------------------------------------------


def _legacy_fallback(row: LibraryFile) -> dict[str, Any]:
    """旧行的粗文案（没有获取领域、或它也推导不出时）。站点名、种子标题由获取领域推导（describe_origins）。"""
    if row.source == FileSource.SCANNED:
        return _snapshot(KIND_SCAN, reference("library.origin.scan"))
    if row.site_id or row.torrent_id:
        snapshot = _snapshot(KIND_WATCH_IMPORT, reference("library.origin.manualOrWatch"))
        snapshot["detail"] = row.site_id or None  # 站点 id 是数据，不翻译
        return snapshot
    return _snapshot(
        KIND_WATCH_IMPORT,
        reference("library.origin.legacyWatch"),
        reference("library.origin.missingTorrent"),
    )


def origin_of(row: LibraryFile, derived: dict[int, dict[str, Any]]) -> dict[str, Any]:
    """展示用：优先落库快照，其次读时推导，最后按 source 的粗文案。"""
    if row.origin:
        return row.origin
    if row.id is not None and row.id in derived:
        return derived[row.id]
    return _legacy_fallback(row)
