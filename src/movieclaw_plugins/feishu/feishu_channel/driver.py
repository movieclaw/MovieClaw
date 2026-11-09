"""飞书通道驱动:群自定义机器人 Webhook,或自建应用机器人。两者都只推送。

绑定种类保持 form。旧接口 ``POST /channels/im/feishu/bindings`` 和设置页的 Webhook
表单都走 ``validate``;若改成 flow,这些调用会被中枢丢掉字段。扫码创建应用是同一张
表单上的附加入口(``Binding.scan``):设置页只提交 ``flow=1`` 时,中枢才转入 ``begin_flow``。

Webhook 凭据仍是 ``{"webhook_url", "secret"}``,旧账号不用迁移。自建应用是
``{"app_id", "app_secret", "receive_id", "receive_id_type", "domain"}``。
"""

from __future__ import annotations

from typing import Any

from movieclaw_sdk.channels import (
    Account,
    AdapterDriver,
    Binding,
    BindResult,
    Capabilities,
    ChannelInputError,
    FlowState,
    FormField,
    ReplyContext,
)

from .adapter import FeishuAdapter
from .binding import APP_DISPLAY_NAME, APP_WELCOME, FeishuBindingRegistry, raise_registration
from .client import (
    FeishuClient,
    credentials_token,
    feishu_account_id,
    normalize_webhook_url,
)
from .registration import RegistrationError

WELCOME = "🎉 MovieClaw 已接入本群，订阅投递、入库完成等事件将推送到这里。"


class FeishuDriver(AdapterDriver):
    title = "飞书"
    title_localized = {"en": "Feishu"}
    description = "群 Webhook 或自建应用，只推送"
    description_localized = {"en": "Group Webhook or a self-built app. Push only"}
    capabilities = Capabilities(receive=False, photo=True, max_text_len=FeishuAdapter.max_text_len)
    binding = Binding.form(
        (
            FormField(
                "webhook_url",
                "Webhook 地址",
                required=False,
                placeholder="https://open.feishu.cn/open-apis/bot/v2/hook/…",
                help="群设置 → 群机器人 → 添加自定义机器人后获得",
                help_localized={
                    "en": "Get this URL from Group settings → Group bots → Add custom bot"
                },
                label_localized={"en": "Webhook URL"},
            ),
            FormField(
                "secret",
                "签名校验密钥",
                secret=True,
                required=False,
                help="机器人开启了「签名校验」才需要填",
                help_localized={
                    "en": "Required only if the bot has signature verification enabled"
                },
                label_localized={"en": "Signature verification secret"},
            ),
            FormField(
                "app_id",
                "App ID",
                required=False,
                help=(
                    "自建应用的 App ID。可点「扫码创建应用」,或按官方流程手动创建: "
                    "https://open.feishu.cn/document/mcp_open_tools/integrating-agents-with-feishu/overview"
                ),
                help_localized={
                    "en": (
                        "App ID of the self-built app. Use Create an app by scanning, "
                        "or create it manually: "
                        "https://open.feishu.cn/document/mcp_open_tools/integrating-agents-with-feishu/overview"
                    )
                },
            ),
            FormField(
                "app_secret",
                "App Secret",
                secret=True,
                required=False,
                help="只用于换取 tenant_access_token,加密保存,不会写进日志",
                help_localized={
                    "en": (
                        "Used only to request a tenant access token. "
                        "Stored encrypted and never written to logs."
                    )
                },
            ),
            FormField(
                "receive_id",
                "推送目标",
                required=False,
                placeholder="oc_xxxxxxxx / ou_xxxxxxxx",
                help=(
                    "群 chat_id 以 oc_ 开头,用户 open_id 以 ou_ 开头。扫码创建时默认用扫码人的 "
                    "open_id。机器人需在目标群内,且应用具备发消息权限(im:message);"
                    "新应用若缺权限,欢迎消息失败,绑定不会完成。"
                ),
                help_localized={
                    "en": (
                        "A group chat_id starts with oc_. A user open_id starts with ou_. "
                        "Scanning uses the scanner's open_id unless you enter a group id here. "
                        "The bot must be in the target group and be allowed to send messages "
                        "(im:message). If a new app lacks that permission, the welcome message "
                        "fails and linking does not finish."
                    )
                },
                label_localized={"en": "Push target"},
            ),
            FormField(
                "domain",
                "域名",
                required=False,
                placeholder="feishu",
                help="留空为飞书;国际版 Lark 填 lark",
                help_localized={"en": "Leave blank for Feishu. Enter lark for Lark international"},
                label_localized={"en": "Domain"},
            ),
        ),
        scan=True,
        hint=(
            "两种接入方式任选其一。群自定义机器人:在群里添加自定义机器人,粘贴 Webhook;"
            "安全设置建议选签名校验。自建应用:填写 App ID、App Secret 与推送目标"
            "(群 chat_id 以 oc_ 开头,用户 open_id 以 ou_ 开头),或点「扫码创建应用」"
            "按飞书设备码流程一键创建,默认推给扫码人。两种方式接入时都会校验凭据并发送欢迎消息。"
            "官方创建说明: "
            "https://open.feishu.cn/document/mcp_open_tools/integrating-agents-with-feishu/overview"
        ),
        hint_localized={
            "en": (
                "Choose one method. Group custom bot: add a custom bot in the group and paste "
                "its Webhook. Signature verification is recommended. Self-built app: enter the "
                "App ID, App Secret, and a push target (a group chat_id starts with oc_, a user "
                "open_id starts with ou_), or choose Create an app by scanning. Scanning uses "
                "the device-code flow and pushes to the person who scanned unless you enter a "
                "group id. Both methods check the credentials and send a welcome message. "
                "Official guide: "
                "https://open.feishu.cn/document/mcp_open_tools/integrating-agents-with-feishu/overview"
            )
        },
    )

    def __init__(self) -> None:
        super().__init__()
        self._registry = FeishuBindingRegistry()

    async def close(self) -> None:
        """插件停止时调用:取消进行中的扫码轮询。"""
        await self._registry.close()

    async def validate(self, fields: dict[str, str]) -> BindResult:
        webhook = (fields.get("webhook_url") or "").strip()
        secret = (fields.get("secret") or "").strip()
        app_id = (fields.get("app_id") or "").strip()
        app_secret = (fields.get("app_secret") or "").strip()
        receive_id = (fields.get("receive_id") or "").strip()
        domain = (fields.get("domain") or "").strip().lower()
        webhook_filled = bool(webhook or secret)
        app_filled = bool(app_id or app_secret or receive_id or domain)
        if webhook_filled and app_filled:
            raise ChannelInputError(
                "请只选择一种接入方式:填写 Webhook,或填写自建应用凭据",
                message_localized={
                    "en": "Choose one method: a Webhook, or self-built app credentials"
                },
            )
        if not webhook_filled and not app_filled:
            raise ChannelInputError(
                "请填写 Webhook 地址,或填写自建应用的 App ID、App Secret 与推送目标",
                message_localized={
                    "en": (
                        "Enter a Webhook URL, or the self-built app's App ID, "
                        "App Secret, and push target"
                    )
                },
            )
        if webhook_filled:
            return await self._validate_webhook(webhook, secret)
        return await self._validate_app(app_id, app_secret, receive_id, domain)

    async def begin_flow(self, accounts: list[Account]) -> FlowState:
        del accounts  # 同一 app_id 再次绑定由中枢覆盖,不在这里挡
        try:
            return await self._registry.begin()
        except RegistrationError as exc:
            raise_registration(exc)

    async def flow_state(self, flow_id: str) -> FlowState:
        return self._registry.snapshot(flow_id)

    async def flow_input(self, flow_id: str, value: str) -> FlowState:
        return await self._registry.submit(flow_id, value)

    async def cancel_flow(self, flow_id: str) -> None:
        await self._registry.cancel(flow_id)

    def open(self, account: Account) -> tuple[Any, Any]:
        client = FeishuClient(credentials_token(account.credentials))
        return client, FeishuAdapter(client, account.id)

    def push_target(self, account: Account) -> ReplyContext | None:
        creds = account.credentials
        if (creds.get("webhook_url") or "").strip() or not (creds.get("app_id") or "").strip():
            return ReplyContext(account.channel_id, account.id, "group")
        return ReplyContext(
            account.channel_id, account.id, (creds.get("receive_id") or "").strip() or "group"
        )

    async def _validate_webhook(self, webhook: str, secret: str) -> BindResult:
        # 地址不合法要原样抛出,不能包进「校验失败」(设置页按这句原文提示)
        url = normalize_webhook_url(webhook)
        credentials = {"webhook_url": url, "secret": secret}
        client = FeishuClient(credentials_token(credentials))
        try:
            await client.send_text(WELCOME)
        except Exception as exc:  # noqa: BLE001 -- 原因直接展示给用户
            raise ChannelInputError(
                f"飞书 Webhook 校验失败：{exc}",
                message_localized={"en": f"Could not validate the Feishu Webhook: {exc}"},
            ) from exc
        finally:
            await client.aclose()
        return BindResult(
            account_id=feishu_account_id(url), display_name="飞书群机器人", credentials=credentials
        )

    async def _validate_app(
        self, app_id: str, app_secret: str, receive_id: str, domain: str
    ) -> BindResult:
        if domain not in ("", "feishu", "lark"):
            raise ChannelInputError(
                "域名只接受 feishu 或 lark",
                message_localized={"en": "Domain must be feishu or lark"},
            )
        if not app_id or not app_secret or not receive_id:
            raise ChannelInputError(
                "自建应用需要 App ID、App Secret,以及推送目标"
                "(群 chat_id 以 oc_ 开头,用户 open_id 以 ou_ 开头)",
                message_localized={
                    "en": (
                        "A self-built app needs an App ID, an App Secret, and a push target "
                        "(a group chat_id starts with oc_, a user open_id starts with ou_)"
                    )
                },
            )
        if receive_id.startswith("oc_"):
            receive_id_type = "chat_id"
        elif receive_id.startswith("ou_"):
            receive_id_type = "open_id"
        else:
            raise ChannelInputError(
                "推送目标需要是群 chat_id(oc_ 开头)或用户 open_id(ou_ 开头)",
                message_localized={
                    "en": (
                        "The push target must be a group chat_id (starts with oc_) "
                        "or a user open_id (starts with ou_)"
                    )
                },
            )
        credentials = {
            "app_id": app_id,
            "app_secret": app_secret,
            "receive_id": receive_id,
            "receive_id_type": receive_id_type,
            "domain": domain or "feishu",
        }
        client = FeishuClient(credentials_token(credentials))
        try:
            await client.tenant_access_token()
            await client.send_text(APP_WELCOME)
        except Exception as exc:  # noqa: BLE001 -- 原因直接展示给用户
            raise ChannelInputError(
                f"飞书应用校验失败：{exc}",
                message_localized={"en": f"Could not validate the Feishu app: {exc}"},
            ) from exc
        finally:
            await client.aclose()
        return BindResult(
            account_id=app_id,
            display_name=APP_DISPLAY_NAME,
            credentials=credentials,
            bound_user=receive_id if receive_id_type == "open_id" else None,
        )
