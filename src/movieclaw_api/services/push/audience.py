"""推送的收件人与可见性（docs/design/domain-events.md §6.1）：谁能收、点开去哪、配图。

通知引擎（engine.py）与剧卡（cards.py）共用：收件人看不到的条目一律不推，走
``assert_item_visible``（库可见范围 + 内容分级）。
"""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.services.push.images import image_path


async def principal(session: AsyncSession, member_id: int):  # type: ignore[no-untyped-def]
    """按成员 id 造一个请求主体，给可见性判定用；成员不在或停用返回 None。"""
    from movieclaw_api.services.auth import Principal
    from movieclaw_db.repositories.member_repo import MemberRepository

    if member_id == 0:
        return Principal(kind="admin", name="admin", is_admin=True)
    member = await MemberRepository(session).get(member_id)
    if member is None or member.status != "active":
        return None
    return Principal(
        kind="member", name=member.username, member_id=member.id, is_admin=False, member=member
    )


async def item_visible(session: AsyncSession, member_id: int, item_id: int) -> bool:
    from movieclaw_api.services.library.access import assert_item_visible

    who = await principal(session, member_id)
    if who is None:
        return False
    try:
        await assert_item_visible(session, who, item_id)
    except NotFoundException:
        return False
    return True


async def library_path(
    session: AsyncSession, member_id: int, item_id: int, unit: tuple[int, int] | None
) -> str | None:
    """这个人能看到的、放着这部片的库里的条目页；找不到返回 None。"""
    from movieclaw_api.services.library.access import visible_library_ids
    from movieclaw_db.models import LibraryFile

    who = await principal(session, member_id)
    if who is None:
        return None
    visible = await visible_library_ids(session, who)
    rows = await session.execute(
        select(LibraryFile.library_id).where(  # type: ignore[call-overload]
            LibraryFile.media_item_id == item_id,
            LibraryFile.library_id.is_not(None),  # type: ignore[union-attr]
        )
    )
    libraries = sorted({int(lid) for lid in rows.scalars() if lid is not None and lid in visible})
    if not libraries:
        return None
    path = f"/library/{libraries[0]}/item/{item_id}"
    if unit is not None and unit != (0, 0):
        path += f"?season={unit[0]}&episode={unit[1]}"
    return path


def subscribers(subscription_id: int):  # type: ignore[no-untyped-def]
    """订阅的人：发起人（空为管理员）+ 关注者。"""

    async def resolve(session: AsyncSession) -> set[int]:
        from movieclaw_db.models import Subscription, SubscriptionFollower

        subscription = await session.get(Subscription, subscription_id)
        if subscription is None:
            return set()
        members = {subscription.created_by_member_id or 0}
        rows = await session.execute(
            select(SubscriptionFollower.member_id).where(  # type: ignore[call-overload]
                SubscriptionFollower.subscription_id == subscription_id
            )
        )
        members.update(int(m) for m in rows.scalars())
        return members

    return resolve


def display_title(title: str, year: int | None) -> str:
    return title.strip() or (f"{year} 年的作品" if year else "一部作品")


def lazy_image(image_url: str | None):  # type: ignore[no-untyped-def]
    """配图地址签一次、给所有收件人共用（签名在后台任务里做，不占业务链路）。"""
    cache: dict[str, str | None] = {}

    async def get() -> str | None:
        if "v" not in cache:
            cache["v"] = await image_path(image_url)
        return cache["v"]

    return get
