"""飞书通道驱动：群自定义机器人 Webhook，只能推送（没有 bot 身份，不能对话）。

绑定即粘贴 Webhook 地址（可选签名密钥）：校验时发一条欢迎消息验真——地址错、签名错、
关键词拦截都在这一步暴露，用户能在群里当场看到消息落地。
"""

from __future__ import annotations

import json
from typing import Any

from movieclaw_channel.driver_kit import AdapterDriver
from movieclaw_channel.feishu.adapter import FeishuAdapter
from movieclaw_channel.feishu.client import FeishuClient, feishu_account_id, normalize_webhook_url
from movieclaw_sdk.channels import (
    Account,
    Binding,
    BindResult,
    Capabilities,
    FormField,
    ReplyContext,
)

WELCOME = "🎉 MovieClaw 已接入本群，订阅投递、入库完成等事件将推送到这里。"


def _token(credentials: dict[str, str]) -> str:
    """FeishuClient 认的凭据串（JSON：地址 + 签名密钥）。"""
    return json.dumps(
        {"webhook_url": credentials["webhook_url"], "secret": credentials.get("secret", "")}
    )


class FeishuDriver(AdapterDriver):
    title = "飞书"
    description = "粘贴群机器人 Webhook 地址，即绑即用（只推送）"
    capabilities = Capabilities(receive=False, max_text_len=FeishuAdapter.max_text_len)
    binding = Binding.form(
        (
            FormField(
                "webhook_url",
                "Webhook 地址",
                placeholder="https://open.feishu.cn/open-apis/bot/v2/hook/…",
                help="群设置 → 群机器人 → 添加自定义机器人后获得",
            ),
            FormField(
                "secret",
                "签名校验密钥",
                secret=True,
                required=False,
                help="机器人开启了「签名校验」才需要填",
            ),
        ),
        hint=(
            "在飞书群聊「设置 → 群机器人 → 添加机器人」里添加「自定义机器人」，把 Webhook 地址"
            "粘贴到下面。安全设置建议选「签名校验」并填入密钥；选「自定义关键词」的话推送文案"
            "须包含关键词才会送达。接入时会往群里发一条欢迎消息，收到即说明可用。"
        ),
    )

    async def validate(self, fields: dict[str, str]) -> BindResult:
        url = normalize_webhook_url(fields.get("webhook_url") or "")
        credentials = {"webhook_url": url, "secret": (fields.get("secret") or "").strip()}
        client = FeishuClient(_token(credentials))
        try:
            await client.send_text(WELCOME)
        except Exception as exc:  # noqa: BLE001 -- 原因直接展示给用户
            raise ValueError(f"飞书 Webhook 校验失败：{exc}") from exc
        finally:
            await client.aclose()
        return BindResult(
            account_id=feishu_account_id(url), display_name="飞书群机器人", credentials=credentials
        )

    def open(self, account: Account) -> tuple[Any, Any]:
        client = FeishuClient(_token(account.credentials))
        return client, FeishuAdapter(client, account.id)

    def push_target(self, account: Account) -> ReplyContext | None:
        # 群机器人没有绑定用户：凭据在即是推送目标
        return ReplyContext(account.channel_id, account.id, "group")
