"""Start an isolated API/Web/SQLite watch-filter fixture for native UI tests.

Run with the repository's Python development environment and --directory pointing
at a disposable build directory. Stop with Ctrl-C; production data is never used.
"""

import argparse
import asyncio
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from urllib.parse import parse_qs, urlsplit

import requests

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT), str(ROOT / "src")]

from tests.e2e.test_i18n_ai_settings_browser import stack  # noqa: E402
from tests.e2e.test_library_watch_filters_browser import _seed  # noqa: E402


async def _finish_tv(database_url):
    """Every seeded TV episode becomes played: unfinished TV is empty, all TV is not."""
    from sqlalchemy import delete, select

    from movieclaw_db.engine import Database
    from movieclaw_db.models import LibraryFile, MediaItem, PlaybackState

    database = Database(database_url)
    try:
        async with database.session() as session:
            episodes = (
                await session.execute(
                    select(
                        LibraryFile.media_item_id,
                        LibraryFile.season_number,
                        LibraryFile.episode_number,
                    )
                    .join(MediaItem, MediaItem.id == LibraryFile.media_item_id)
                    .where(MediaItem.kind == "tv")
                )
            ).all()
            await session.execute(
                delete(PlaybackState).where(
                    PlaybackState.media_item_id.in_({row[0] for row in episodes})
                )
            )
            for media_item_id, season, episode in episodes:
                session.add(
                    PlaybackState(
                        member_id=0,
                        media_item_id=media_item_id,
                        season_number=season,
                        episode_number=episode,
                        played=True,
                        position_ms=0,
                    )
                )
            await session.commit()
    finally:
        await database.dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument(
        "--delay-kind-summary",
        type=float,
        default=0,
        help="Delay the first unfinished TV summary to exercise stale responses",
    )
    parser.add_argument(
        "--all-tv-watched",
        action="store_true",
        help="Mark every seeded TV episode watched so the unfinished TV wall is empty",
    )
    args = parser.parse_args()
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    if (directory / "native-watch/data/movieclaw.db").exists():
        parser.error("Use a fresh directory; an existing fixture database will not be overwritten")

    class Factory:
        def mktemp(self, _name):
            result = directory / "native-watch"
            result.mkdir()
            return result

    proxy = None
    fixture = stack.__wrapped__(Factory(), ["http://127.0.0.1:9"])
    try:
        env = next(fixture)
        api = env["api_base"]
        session = requests.Session()
        admin = {"username": "admin", "password": "native-filter-fixture-2026"}
        session.post(api + "/api/v1/auth/bootstrap", json=admin).raise_for_status()
        roots = [directory / "movies", directory / "tv"]
        for folder in roots:
            folder.mkdir()
        libraries = asyncio.run(_seed(env["database_url"], roots, 900))
        if args.all_tv_watched:
            asyncio.run(_finish_tv(env["database_url"]))
        prefs = session.get(api + "/api/v1/ui/preferences").json()["data"]
        prefs["home"]["rows"] = [
            {
                "id": f"lib:{libraries[1]}",
                "name": "Native unfinished",
                "unfinished": True,
                "sort": "title",
            },
            {
                "id": "kind:tv",
                "name": "Native kind unfinished",
                "unfinished": True,
                "sort": "title",
            },
            *[
                {"id": row, "hidden": True}
                for row in ["libraries", "genres:movie", "genres:tv", f"lib:{libraries[0]}"]
            ],
        ]
        session.put(api + "/api/v1/ui/preferences", json=prefs).raise_for_status()
        server_url = api
        if args.delay_kind_summary > 0:
            delayed = threading.Event()
            released = threading.Event()

            class Proxy(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def forward(self):
                    parsed = urlsplit(self.path)
                    if parsed.path in {
                        "/api/v1/__fixture/delayed-summary",
                        "/api/v1/__fixture/reset",
                    }:
                        self.rfile.read(int(self.headers.get("Content-Length", 0)))
                        if parsed.path.endswith("/reset"):
                            delayed.clear()
                            released.clear()
                        result = json.dumps(
                            {
                                "success": True,
                                "data": {
                                    "started": delayed.is_set(),
                                    "released": released.is_set(),
                                },
                            }
                        ).encode()
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(result)))
                        self.end_headers()
                        self.wfile.write(result)
                        return
                    if (
                        parsed.path == "/api/v1/libraries/kinds/tv"
                        and parse_qs(parsed.query).get("w") == ["unfinished"]
                        and not delayed.is_set()
                    ):
                        delayed.set()
                        time.sleep(args.delay_kind_summary)
                        released.set()
                    body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                    headers = {
                        key: value
                        for key, value in self.headers.items()
                        if key.lower()
                        not in {"host", "connection", "content-length", "accept-encoding"}
                    }
                    headers["Accept-Encoding"] = "identity"
                    response = requests.request(
                        self.command,
                        api + self.path,
                        headers=headers,
                        data=body,
                        timeout=30,
                        allow_redirects=False,
                    )
                    self.send_response(response.status_code)
                    for key, value in response.headers.items():
                        if key.lower() not in {
                            "connection",
                            "transfer-encoding",
                            "content-length",
                            "content-encoding",
                        }:
                            self.send_header(key, value)
                    self.send_header("Content-Length", str(len(response.content)))
                    self.end_headers()
                    self.wfile.write(response.content)

                do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = forward

            class FixtureServer(ThreadingHTTPServer):
                def server_bind(self):
                    # This loopback fixture needs no potentially slow reverse DNS lookup.
                    TCPServer.server_bind(self)
                    self.server_name = "localhost"
                    self.server_port = self.server_address[1]

            proxy = FixtureServer(("127.0.0.1", 0), Proxy)
            threading.Thread(target=proxy.serve_forever, daemon=True).start()
            server_url = f"http://127.0.0.1:{proxy.server_port}"
        connection = {"server": server_url, **admin, "libraries": libraries}
        (directory / "connection.json").write_text(json.dumps(connection, indent=2) + "\n")
        print(
            f"Fixture ready: {server_url}; connection.json contains local fixture settings",
            flush=True,
        )
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        if proxy is not None:
            proxy.shutdown()
            proxy.server_close()
        fixture.close()


if __name__ == "__main__":
    main()
