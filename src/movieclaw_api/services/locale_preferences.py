"""Language history belongs to interactive clients, independently of metadata language."""

from __future__ import annotations

import asyncio
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from movieclaw_api.i18n import current_locale
from movieclaw_api.services.auth import Principal
from movieclaw_api.settings.schemas import AdminLocaleSetting, get_ui_preferences
from movieclaw_api.settings.store import get_setting_store
from movieclaw_db.engine import get_database
from movieclaw_db.models.login_device import LoginDevice
from movieclaw_db.models.member import Member

_admin_locale_lock = asyncio.Lock()


def valid_timezone(value: str | None) -> str | None:
    if not value or len(value) > 64:
        return None
    try:
        ZoneInfo(value)
    except (ZoneInfoNotFoundError, ValueError):
        return None
    return value


async def record_request_language(principal: Principal, timezone: str | None) -> None:
    if not principal.interactive:
        return
    locale = current_locale.get()
    timezone = valid_timezone(timezone)
    device = principal.device
    device_changed = device is not None and (
        device.locale != locale or (timezone is not None and device.timezone != timezone)
    )
    member_changed = principal.member is not None and principal.member.last_locale != locale
    if device_changed or member_changed:
        async with get_database().session() as session:
            if device_changed:
                row = await session.get(LoginDevice, device.id)
                if row is not None:
                    row.locale = locale
                    if timezone is not None:
                        row.timezone = timezone
            if member_changed:
                member = await session.get(Member, principal.member_id)
                if member is not None:
                    member.last_locale = locale
            await session.commit()
    if principal.kind == "admin":
        # The first parallel requests can otherwise both insert the history namespace.
        async with _admin_locale_lock:
            store = get_setting_store()
            admin = await store.get(AdminLocaleSetting)
            if admin.last_locale != locale:
                await store.set(admin.model_copy(update={"last_locale": locale}))


async def member_locale(member_id: int) -> str:
    """For IM and background notifications; device pushes use login_device.locale instead."""
    if member_id == 0:
        preference = (await get_ui_preferences()).language
        last = (await get_setting_store().get(AdminLocaleSetting)).last_locale
    else:
        async with get_database().session() as session:
            member = await session.get(Member, member_id)
            if member is None:
                return "zh-Hans"
            preference = (member.ui_prefs or {}).get("language", "auto")
            last = member.last_locale
    return preference if preference in ("en", "zh-Hans") else last or "zh-Hans"
