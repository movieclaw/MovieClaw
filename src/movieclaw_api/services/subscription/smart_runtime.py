"""可分别关闭智能执行、历史证据等待，或仅记录影子决策。"""

from movieclaw_api.settings.smart_subscription import (
    SmartAutomationSettings as SmartAutomationSettings,
)
from movieclaw_api.settings.store import get_setting_store


async def runtime_settings() -> SmartAutomationSettings:
    return await get_setting_store().get(SmartAutomationSettings)
