"""Isolated external downloader for task UI checks; API, jobs and SQLite stay real."""

import os
from pathlib import Path

from tests.api import test_downloaders as fake
from tests.e2e._smart_api_launcher import app

from movieclaw_api.services import download_tasks, downloader_config
from movieclaw_downloader import TorrentBrief

ROOT = Path(os.environ["E2E_TASK_FILES"])


class Downloader(fake._FakeDownloader):
    async def delete_torrent(self, info_hash, *, delete_files=False):
        await super().delete_torrent(info_hash, delete_files=delete_files)
        if delete_files:
            (ROOT / f"{info_hash}.mkv").unlink(missing_ok=True)


download_tasks.create_downloader = Downloader
downloader_config.create_downloader = Downloader


@app.post("/__lab/task-reset")
async def reset():
    fake._delete_calls.clear()
    fake._fake_torrents[:] = [
        TorrentBrief(
            info_hash=char * 40,
            name=name,
            content_name=name,
            completed=char == "c",
            progress=0.5 if char != "c" else 1,
            size_bytes=2048,
            completed_bytes=1024 if char != "c" else 2048,
            dlspeed_bytes=512 if char != "c" else 0,
            upspeed_bytes=128,
            state="downloading" if char != "c" else "completed",
        )
        for char, name in (("a", "Raw.Show.S01"), ("b", "Raw.External.Movie"), ("c", "Raw.Boost"))
    ]
    ROOT.mkdir(exist_ok=True)
    for char in "abc":
        (ROOT / f"{char * 40}.mkv").write_bytes(b"isolated fixture data")
    return {"ok": True}


@app.get("/__lab/task-deletions")
async def deletions():
    return fake._delete_calls
