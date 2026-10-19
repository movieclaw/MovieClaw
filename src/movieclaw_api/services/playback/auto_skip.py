"""自动跳过的个人偏好（docs/design/skip-intro.md §5），跟账号走。

- 总开关默认开：广告、预告进了区间直接跳，跳完客户端给「撤回」；
- 片头按剧学：用户在一部剧里手动点过一次「跳过片头」，这部剧以后自动跳；跳过后点「撤回」
  或学会时的提示上点「不用」，这部剧回到只给按钮。

服务端只存和下发，什么时候跳由客户端按播放位置决定。
"""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.schemas.playback import PlaybackAutoSkipView
from movieclaw_db.models import PlaybackPreference, utcnow


async def _row(session: AsyncSession, member_id: int) -> PlaybackPreference | None:
    return (
        await session.execute(
            select(PlaybackPreference).where(PlaybackPreference.member_id == member_id)
        )
    ).scalar_one_or_none()


def _intro_ids(row: PlaybackPreference | None) -> list[int]:
    if row is None or not row.auto_skip_intro_item_ids:
        return []
    return [int(i) for i in row.auto_skip_intro_item_ids if isinstance(i, int)]


async def view_for(
    session: AsyncSession, member_id: int, media_item_id: int | None
) -> PlaybackAutoSkipView:
    """这个人播这部片时的自动跳过设定。"""
    row = await _row(session, member_id)
    return PlaybackAutoSkipView(
        enabled=row.auto_skip if row is not None else True,
        intro=media_item_id is not None and media_item_id in _intro_ids(row),
    )


async def _ensure_row(session: AsyncSession, member_id: int) -> PlaybackPreference:
    row = await _row(session, member_id)
    if row is None:
        row = PlaybackPreference(member_id=member_id)
        session.add(row)
    return row


async def set_enabled(session: AsyncSession, member_id: int, enabled: bool) -> None:
    row = await _ensure_row(session, member_id)
    row.auto_skip = enabled
    row.updated_at = utcnow()
    await session.commit()


async def set_intro(
    session: AsyncSession, member_id: int, media_item_id: int, enabled: bool
) -> None:
    """记下 / 忘掉这部剧的片头自动跳。"""
    row = await _ensure_row(session, member_id)
    ids = [i for i in _intro_ids(row) if i != media_item_id]
    if enabled:
        ids.append(media_item_id)
    # JSON 列要整列换新对象，原地改列表 SQLAlchemy 看不出变化
    row.auto_skip_intro_item_ids = ids or None
    row.updated_at = utcnow()
    await session.commit()
