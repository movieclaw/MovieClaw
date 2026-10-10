"""媒体库不认识获取领域（docs/design/library-boundary.md §10）。

媒体库只经 ``services/library/acquisition.py`` 的接口向获取领域要信息、发通知；
这里钉死 ``services/library/`` 下不 import 订阅、下载、手动下载、推送的模块与表。
"""

from __future__ import annotations

import ast
from pathlib import Path

import movieclaw_api.services.library as library_pkg

FORBIDDEN_MODULES = (
    "movieclaw_api.services.subscription",
    "movieclaw_api.services.download_",
    "movieclaw_api.services.downloader",
    "movieclaw_api.services.torrent_submit",
    "movieclaw_api.services.push",
    "movieclaw_api.services.acquisition_",
    "movieclaw_api.services.manual_download",
    "movieclaw_downloader",
)
FORBIDDEN_NAMES = {
    "Subscription",
    "SubscriptionDownloadAttempt",
    "WantedItem",
    "ManualDownloadIntent",
    "DownloaderClient",
    "DownloadHint",
    "DownloadFileSource",
}


def _imports(path: Path) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
        if isinstance(node, ast.ImportFrom) and node.module:
            found.extend((node.module, alias.name) for alias in node.names)
        elif isinstance(node, ast.Import):
            found.extend((alias.name, "") for alias in node.names)
    return found


def test_library_does_not_import_the_acquisition_domain() -> None:
    root = Path(library_pkg.__file__).parent
    offenders = [
        f"{path.name}: {module} {name}".strip()
        for path in sorted(root.glob("*.py"))
        for module, name in _imports(path)
        if module.startswith(FORBIDDEN_MODULES) or name in FORBIDDEN_NAMES
    ]
    assert offenders == []
