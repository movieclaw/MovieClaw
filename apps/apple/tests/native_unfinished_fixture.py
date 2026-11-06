"""Start an isolated API/Web/SQLite watch-filter fixture for native UI tests.

Run with the repository's Python development environment and --directory pointing
at a disposable build directory. Stop with Ctrl-C; production data is never used.
"""

import argparse
import asyncio
import json
import sys
import threading
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT), str(ROOT / "src")]

from tests.e2e.test_i18n_ai_settings_browser import stack  # noqa: E402
from tests.e2e.test_library_watch_filters_browser import _seed  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
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
        connection = {"server": api, **admin, "libraries": libraries}
        (directory / "connection.json").write_text(json.dumps(connection, indent=2) + "\n")
        print(f"Fixture ready: {api}; connection.json contains local fixture settings", flush=True)
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        fixture.close()


if __name__ == "__main__":
    main()
