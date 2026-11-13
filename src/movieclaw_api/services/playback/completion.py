"""在线上报与离线观看补传共用的服务端已看判定配置。"""

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.services.library.skip_segments import segments_for_file
from movieclaw_api.settings import PlaybackPolicySetting, get_setting_store
from movieclaw_db.models import LibraryFile
from movieclaw_playback import state as playback_state
from movieclaw_playback.state import Unit


async def completion_options(
    session: AsyncSession,
    files: list[LibraryFile],
    runtime_ms: int | None,
    *,
    file_id: int | None = None,
) -> tuple[float, int | None]:
    policy = await get_setting_store().get(PlaybackPolicySetting)
    threshold = policy.played_threshold_percent
    if not policy.played_use_outro or len(files) != 1 or not runtime_ms:
        return threshold, None
    if file_id is not None and files[0].id != file_id:
        return threshold, None
    # 复用播放下发的有效性检查：仅已启用识别的剧集库、当前文件/算法的成功结果。
    # 没有确切版本时不借用其他片源的片尾；电影、关闭、过期结果都回退百分比。
    segments = await segments_for_file(session, files[0])
    starts = [
        s["start_ms"]
        for s in segments
        if s.get("type") == "outro"
        and s.get("to_end") is True
        and 0 < s["start_ms"] < s["end_ms"] <= runtime_ms
    ]
    # to_end=False 代表片尾后还有剧情/彩蛋，不能把它当作整部已结束。
    return threshold, min(starts) if starts else None


async def completion_runtime_ms(
    session: AsyncSession, unit: Unit, files: list[LibraryFile], *, file_id: int | None
) -> int | None:
    """显式版本不在位时，只信该版本的历史片长，不借用其他版本或刮削片长。"""
    if file_id is None or any(f.id == file_id for f in files):
        selected = files if file_id is None else [f for f in files if f.id == file_id]
        return await playback_state.unit_runtime_ms(session, unit, files=selected)
    historical = await session.get(LibraryFile, file_id)
    if historical is not None and (
        historical.media_item_id, historical.season_number or 0, historical.episode_number or 0
    ) == unit and historical.duration_seconds:
        return historical.duration_seconds * 1000
    return None
