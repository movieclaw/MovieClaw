"""智能自动选择的运行开关，与订阅的品质快照分离。"""

from movieclaw_api.settings.base import SettingSchema, register_setting


@register_setting(namespace="subscription.smart", title="智能订阅执行")
class SmartAutomationSettings(SettingSchema):
    enabled: bool = True
    prediction_enabled: bool = True
    shadow_only: bool = False
