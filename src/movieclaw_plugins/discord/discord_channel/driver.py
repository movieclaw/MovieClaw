"""Discord 通道驱动：填 bot token，私信 bot 发配对码完成绑定（配对由中枢负责）。"""

from __future__ import annotations

from typing import Any

from movieclaw_sdk.channels import (
    Account,
    AdapterDriver,
    Binding,
    BindResult,
    Capabilities,
    FormField,
)

from .adapter import DiscordAdapter
from .client import DiscordClient


class DiscordDriver(AdapterDriver):
    title = "Discord"
    description = "接入你在开发者后台创建的 bot"
    capabilities = Capabilities(receive=True, photo=True, max_text_len=DiscordAdapter.max_text_len)
    binding = Binding.form(
        (
            FormField(
                "token",
                "Bot Token",
                secret=True,
                help="在 Discord 开发者后台创建应用 → Bot 页获得；需要打开 Message Content Intent",
            ),
        ),
        pairing="code",
        hint=(
            "在 discord.com/developers 创建应用 → Bot → Reset Token 复制；国内网络请先在"
            "「设置 → 网络」为 Discord 开启代理。提交后私信 bot 发送配对码，发码人即唯一可对话的"
            "用户与推送目标。"
        ),
    )

    async def validate(self, fields: dict[str, str]) -> BindResult:
        token = (fields.get("token") or "").strip()
        if len(token) < 8:
            raise ValueError("请填写 bot token")
        client = DiscordClient(token)
        try:
            me = await client.get_me()
        except Exception as exc:  # noqa: BLE001 -- 原因直接展示给用户
            raise ValueError(f"Discord bot token 校验失败：{exc}") from exc
        finally:
            await client.aclose()
        name = str(me.get("username") or me["id"])
        return BindResult(account_id=str(me["id"]), display_name=name, credentials={"token": token})

    def open(self, account: Account) -> tuple[Any, Any]:
        client = DiscordClient(account.credentials["token"])
        return client, DiscordAdapter(client, account.id)
