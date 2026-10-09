"""Telegram 通道驱动：填 bot token，私聊 bot 发配对码完成绑定（配对由中枢负责）。"""

from __future__ import annotations

from typing import Any

from movieclaw_channel.driver_kit import AdapterDriver
from movieclaw_channel.telegram.adapter import TelegramAdapter
from movieclaw_channel.telegram.client import TelegramClient
from movieclaw_sdk.channels import Account, Binding, BindResult, Capabilities, FormField


class TelegramDriver(AdapterDriver):
    title = "Telegram"
    description = "接入你用 @BotFather 创建的 bot"
    capabilities = Capabilities(receive=True, photo=True, max_text_len=TelegramAdapter.max_text_len)
    binding = Binding.form(
        (
            FormField(
                "token",
                "Bot Token",
                secret=True,
                placeholder="123456789:AA…",
                help="在 Telegram 里找 @BotFather 创建 bot 后获得",
            ),
        ),
        pairing="code",
        hint=(
            "在 Telegram 搜索 @BotFather 创建 bot 并复制 token；国内网络请先在「设置 → 网络」"
            "为 Telegram 开启代理。提交后私聊 bot 发送配对码，发码人即唯一可对话的用户与推送目标。"
        ),
    )

    async def validate(self, fields: dict[str, str]) -> BindResult:
        token = (fields.get("token") or "").strip()
        if len(token) < 8:
            raise ValueError("请填写 bot token")
        client = TelegramClient(token)
        try:
            me = await client.get_me()
        except Exception as exc:  # noqa: BLE001 -- 原因直接展示给用户
            raise ValueError(f"Telegram bot token 校验失败：{exc}") from exc
        finally:
            await client.aclose()
        name = str(me.get("username") or me.get("first_name") or me["id"])
        return BindResult(account_id=str(me["id"]), display_name=name, credentials={"token": token})

    def open(self, account: Account) -> tuple[Any, Any]:
        client = TelegramClient(account.credentials["token"])
        return client, TelegramAdapter(client, account.id)
