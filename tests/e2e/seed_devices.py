"""Seed a disposable local database for Web/iPhone device acceptance.

Run after starting an isolated API with DATABASE_URL pointing at this database:
  python tests/e2e/seed_devices.py /tmp/movieclaw-device-summary/test.db
Login: admin / device-test-pass. Never use this on a normal instance.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import secrets
import sys
from datetime import timedelta
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from sqlalchemy.ext.asyncio import create_async_engine
from sqlmodel.ext.asyncio.session import AsyncSession

from movieclaw_db.models.base import utcnow
from movieclaw_db.models.login_device import LoginDevice


async def seed(path: Path) -> None:
    if not str(path.resolve()).startswith("/tmp/movieclaw-device-summary/") and not str(
        path.resolve()
    ).startswith("/private/tmp/movieclaw-device-summary/"):
        raise ValueError("Only the disposable device acceptance database is allowed")
    body = json.dumps({"username": "admin", "password": "device-test-pass"}).encode()
    request = Request(
        "http://127.0.0.1:8128/api/v1/auth/bootstrap",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urlopen(request) as response:
            assert response.status == 200
    except HTTPError as error:
        if error.code != 409:
            raise
    engine = create_async_engine(f"sqlite+aiosqlite:///{path}")
    async with AsyncSession(engine) as session:
        from sqlalchemy import delete

        await session.exec(delete(LoginDevice).where(LoginDevice.name.like("device-fixture-%")))
        now = utcnow()
        for kind, count in [("web", 80), ("ios", 45), ("cli", 1)]:
            for index in range(count):
                online = kind != "cli" and index < 7
                name = (
                    f"device-fixture-{'browser' if kind == 'web' else 'app'}-{index:03}"
                    if kind != "cli"
                    else "device-fixture-offline-cli"
                )
                session.add(
                    LoginDevice(
                        kind=kind,
                        name=name,
                        member_id=0,
                        token_hash=hashlib.sha256(secrets.token_bytes(32)).hexdigest(),
                        platform="macOS" if kind == "web" else "iOS" if kind == "ios" else "Linux",
                        last_seen_at=now - timedelta(seconds=index)
                        if online
                        else now - timedelta(days=index + 1),
                    )
                )
        await session.commit()
    await engine.dispose()
    print("Seeded: 80 browsers, 45 apps, one offline CLI, no players")


if __name__ == "__main__":
    asyncio.run(seed(Path(sys.argv[1])))
