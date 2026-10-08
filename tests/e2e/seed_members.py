"""Member UI review fixtures, restricted to the disposable local acceptance database."""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

from sqlalchemy.ext.asyncio import create_async_engine
from sqlmodel import select
from sqlmodel.ext.asyncio.session import AsyncSession

from movieclaw_db.models.library import Library
from movieclaw_db.models.member import Member


async def seed(path: Path) -> None:
    if path.resolve().parent != Path("/tmp/movieclaw-device-summary").resolve():
        raise ValueError("Only the disposable acceptance database is allowed")
    engine = create_async_engine(f"sqlite+aiosqlite:///{path}")
    async with AsyncSession(engine) as session:
        for index in range(48):
            username = f"member-fixture-{index:03}"
            if (await session.exec(select(Member).where(Member.username == username))).first():
                continue
            session.add(
                Member(
                    username=username,
                    password_hash="unusable-review-fixture",
                    nickname=f"家人 {index + 1:02}"
                    if index < 47
                    else "长昵称：周末来做客的家人与朋友",
                    status="active" if index < 40 else "disabled",
                )
            )
        for name, mode in [
            ("家庭影院", "everyone"),
            ("纪录片与旅行", "everyone"),
            ("单独授权的私人收藏", "selected"),
        ]:
            if not (await session.exec(select(Library).where(Library.name == name))).first():
                session.add(Library(name=name, kind="movie", access_mode=mode, root_paths=[]))
        await session.commit()
    await engine.dispose()
    print("Seeded 48 review members and 3 libraries in the disposable database")


if __name__ == "__main__":
    asyncio.run(seed(Path(sys.argv[1])))
