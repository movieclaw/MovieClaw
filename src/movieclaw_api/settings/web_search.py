"""智能体网页搜索（「设置 → AI 设定 → 搜索能力接入」）。

空配置 = 不启用：运行时不注册 web_search 工具，对话行为与没这个功能时一样。
API Key 经 ``secret_fields`` 加密落库，接口只回末四位。
"""

from __future__ import annotations

from pydantic import Field, field_validator

from movieclaw_api.settings.base import SettingSchema, register_setting

WEB_SEARCH_NAMESPACE = "agent.web_search"


@register_setting(
    namespace=WEB_SEARCH_NAMESPACE,
    title="搜索能力接入",
    secret_fields=["api_key"],
)
class WebSearchSetting(SettingSchema):
    """当前只接一家供应商。``provider`` 为空表示关闭。"""

    provider: str = Field(default="", description="tavily / exa / brave；空 = 不启用")
    api_key: str = Field(default="", max_length=500, description="供应商 API Key（加密落库）")

    @field_validator("provider")
    @classmethod
    def _provider(cls, value: str) -> str:
        value = (value or "").strip().lower()
        if not value:
            return ""
        from movieclaw_agent.web_search import provider_ids

        if value not in provider_ids():
            raise ValueError("不支持的搜索供应商")
        return value

    @field_validator("api_key")
    @classmethod
    def _api_key(cls, value: str) -> str:
        return (value or "").strip()

    @property
    def configured(self) -> bool:
        return bool(self.provider and self.api_key)
