"""Discord 通道驱动：填 bot token，私信 bot 发配对码完成绑定（配对由中枢负责）。"""

from __future__ import annotations

from typing import Any

from movieclaw_sdk.channels import (
    Account,
    AdapterDriver,
    Binding,
    BindResult,
    Capabilities,
    ChannelInputError,
    FormField,
)

from .adapter import DiscordAdapter
from .client import DiscordClient


class DiscordDriver(AdapterDriver):
    title = "Discord"
    description = "接入你在开发者后台创建的 bot"
    description_localized = {"en": "Link a bot you created in the developer portal"}
    capabilities = Capabilities(receive=True, photo=True, max_text_len=DiscordAdapter.max_text_len)
    binding = Binding.form(
        (
            FormField(
                "token",
                "Bot Token",
                secret=True,
                help="在 Discord 开发者后台创建应用 → Bot 页获得；需要打开 Message Content Intent",
                help_localized={
                    "en": (
                        "Create an application in the Discord developer portal and open "
                        "Bot to get the token. Enable Message Content Intent"
                    )
                },
            ),
        ),
        pairing="code",
        hint=(
            "在 discord.com/developers 创建应用 → Bot → Reset Token 复制；国内网络请先在"
            "「设置 → 网络」为 Discord 开启代理。提交后私信 bot 发送配对码，发码人即唯一可对话的"
            "用户与推送目标。"
        ),
        hint_localized={
            "en": (
                "Create an application at discord.com/developers, open Bot \u2192 Reset "
                "Token and copy the token. If your network requires a proxy, "
                "enable one for Discord in Settings \u2192 Network first. After "
                "submitting, send the pairing code to the bot in a private "
                "message. The sender becomes the only user who can chat with the "
                "bot and receive notifications."
            )
        },
    )

    async def validate(self, fields: dict[str, str]) -> BindResult:
        token = (fields.get("token") or "").strip()
        if len(token) < 8:
            raise ChannelInputError(
                "请填写 bot token", message_localized={"en": "Enter the bot token"}
            )
        client = DiscordClient(token)
        try:
            me = await client.get_me()
        except Exception as exc:  # noqa: BLE001 -- 原因直接展示给用户
            raise ChannelInputError(
                f"Discord bot token 校验失败：{exc}",
                message_localized={"en": f"Could not validate the Discord bot token: {exc}"},
            ) from exc
        finally:
            await client.aclose()
        name = str(me.get("username") or me["id"])
        return BindResult(account_id=str(me["id"]), display_name=name, credentials={"token": token})

    def open(self, account: Account) -> tuple[Any, Any]:
        client = DiscordClient(account.credentials["token"])
        return client, DiscordAdapter(client, account.id)
