"""企业微信自建应用通道（回调式通道的验收插件，docs/design/plugin-callbacks.md §4.5）。

企业微信的「自建应用」收消息靠回调：用户在企业微信里给应用发消息，企业微信服务器把加密的 XML
POST 到我们给的回调地址。绑定流程：

1. 用户在企业微信管理后台建一个自建应用，记下企业 ID、AgentId、Secret；在「接收消息」里
   随机生成 Token 和 EncodingAESKey；
2. 在 MovieClaw「设置 → 消息通道」填这五项提交：插件用企业 ID + Secret 换一次 access_token 校验；
3. 中枢给这个账号发回调地址、生成配对码：用户把地址填进「接收消息」的 URL 并保存（企业微信先发一次
   GET 验证，我们解密 echostr 原样回去），再在企业微信里给应用发配对码，发码人成为绑定用户。

之后消息经回调进来（``webhook``），回复与推送走「发送应用消息」接口。整个插件只依赖 SDK
与主程序自带的 ``httpx`` / ``cryptography``；验签、解密都在这里做，宿主不碰请求体。
企业微信要求 5 秒内答复：收到消息交给中枢（排队、立即返回）就回 ``success``，AI 的回复另行发送。
"""

import base64
import hashlib
import logging
import struct
import time
import xml.etree.ElementTree as ET

import httpx

from movieclaw_sdk import net, plugin
from movieclaw_sdk.callbacks import CallbackRequest, CallbackResponse
from movieclaw_sdk.channels import (
    IM_CHANNELS,
    Account,
    Binding,
    BindResult,
    Capabilities,
    ChannelAuthError,
    ChannelDriver,
    FormField,
    InboundMessage,
    ReplyContext,
)

logger = logging.getLogger("wecom-channel")

#: 连外网的服务名 = 条目 id，按用户的代理设置走
SERVICE = "wecom-channel"
DEFAULT_API = "https://qyapi.weixin.qq.com"
#: access_token 失效的错误码：换新的再试一次
_TOKEN_EXPIRED = {40014, 42001}


# ---------------------------------------------------------------------- 加解密（企业微信回调协议）
def signature(token: str, timestamp: str, nonce: str, encrypted: str) -> str:
    return hashlib.sha1("".join(sorted([token, timestamp, nonce, encrypted])).encode()).hexdigest()


def decrypt(encrypted: str, aes_key: str, corp_id: str) -> bytes:
    """AES-256-CBC，key = Base64(EncodingAESKey + "=")，iv = key 前 16 字节。

    明文 = 16 字节随机串 + 4 字节消息长度（网络序）+ 消息 + 企业 ID；填充按 32 字节块的 PKCS#7。
    """
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    key = base64.b64decode(aes_key + "=")
    decryptor = Cipher(algorithms.AES(key), modes.CBC(key[:16])).decryptor()
    raw = decryptor.update(base64.b64decode(encrypted)) + decryptor.finalize()
    pad = raw[-1]
    if not 1 <= pad <= 32:
        raise ValueError("填充不对")
    raw = raw[:-pad]
    size = struct.unpack(">I", raw[16:20])[0]
    message, receiver = raw[20 : 20 + size], raw[20 + size :].decode()
    if receiver != corp_id:
        raise ValueError("企业 ID 对不上")
    return message


def encrypt(message: bytes, aes_key: str, corp_id: str, nonce16: bytes) -> str:
    """``decrypt`` 的逆运算（测试与回包加密用）。"""
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    key = base64.b64decode(aes_key + "=")
    raw = nonce16 + struct.pack(">I", len(message)) + message + corp_id.encode()
    pad = 32 - len(raw) % 32
    raw += bytes([pad]) * pad
    encryptor = Cipher(algorithms.AES(key), modes.CBC(key[:16])).encryptor()
    return base64.b64encode(encryptor.update(raw) + encryptor.finalize()).decode()


# ---------------------------------------------------------------------- 驱动
class WecomDriver(ChannelDriver):
    title = "企业微信"
    description = (
        "企业微信自建应用：在企业微信里和 MovieClaw 对话、接收推送（需要外网能访问的地址）"
    )
    capabilities = Capabilities(receive=True, webhook=True, max_text_len=2000)
    binding = Binding.form(
        (
            FormField("corp_id", "企业 ID", help="管理后台「我的企业」最下面"),
            FormField("agent_id", "AgentId", help="自建应用详情页"),
            FormField("secret", "Secret", secret=True, help="自建应用详情页"),
            FormField("token", "Token", secret=True, help="应用的「接收消息」里随机生成"),
            FormField(
                "aes_key", "EncodingAESKey", secret=True, help="应用的「接收消息」里随机生成"
            ),
            FormField(
                "api_base",
                "接口地址（私有化部署才填）",
                placeholder=DEFAULT_API,
                help="一般留空",
                required=False,
            ),
        ),
        pairing="code",
        hint="提交后会给出回调地址：填到应用「接收消息」的 URL 里保存，再在企业微信里给应用发配对码",
    )

    def __init__(self) -> None:
        #: 账号 id → (access_token, 过期时刻)
        self._tokens: dict[str, tuple[str, float]] = {}

    # ---- 绑定
    async def validate(self, fields: dict[str, str]) -> BindResult:
        creds = {
            k: (fields.get(k) or "").strip()
            for k in ("corp_id", "agent_id", "secret", "token", "aes_key")
        }
        missing = [k for k, v in creds.items() if not v]
        if missing:
            raise ValueError(f"缺少：{'、'.join(missing)}")
        if len(creds["aes_key"]) != 43:
            raise ValueError("EncodingAESKey 应是 43 位")
        creds["api_base"] = (fields.get("api_base") or "").strip().rstrip("/") or DEFAULT_API
        await self._fetch_token(creds)  # 企业 ID + Secret 不对会在这里报出来
        return BindResult(
            account_id=f"{creds['corp_id']}-{creds['agent_id']}",
            display_name=f"企业微信应用 {creds['agent_id']}",
            credentials=creds,
        )

    # ---- 收消息：回调
    async def run(self, account: Account) -> None:
        await account.stopping.wait()  # 消息经回调进来，这里只守着账号的生命周期

    async def webhook(self, account: Account, request: CallbackRequest) -> CallbackResponse:
        creds = account.credentials
        timestamp = request.param("timestamp") or ""
        nonce = request.param("nonce") or ""
        given = request.param("msg_signature") or ""
        if request.method == "GET":  # 保存回调 URL 时企业微信来验证
            echostr = request.param("echostr") or ""
            if signature(creds["token"], timestamp, nonce, echostr) != given:
                return CallbackResponse(status=403)
            return CallbackResponse.text(
                decrypt(echostr, creds["aes_key"], creds["corp_id"]).decode()
            )
        try:
            encrypted = ET.fromstring(request.body).findtext("Encrypt") or ""
        except ET.ParseError:
            return CallbackResponse(status=400)
        if signature(creds["token"], timestamp, nonce, encrypted) != given:
            return CallbackResponse(status=403)
        message = ET.fromstring(decrypt(encrypted, creds["aes_key"], creds["corp_id"]))
        if message.findtext("MsgType") == "text":
            user = message.findtext("FromUserName") or ""
            await account.inbound(
                InboundMessage(
                    channel_id=account.channel_id,
                    account_id=account.id,
                    user_id=user,
                    text=message.findtext("Content") or "",
                    reply=ReplyContext(account.channel_id, account.id, user),
                    provider_message_id=message.findtext("MsgId") or "",
                    timestamp_ms=int(message.findtext("CreateTime") or "0") * 1000,
                )
            )
        return CallbackResponse.text("success")

    # ---- 发消息：应用消息接口
    async def send(self, account: Account, reply: ReplyContext, text: str) -> None:
        creds = account.credentials
        body = {
            "touser": reply.user_id,
            "msgtype": "text",
            "agentid": int(creds["agent_id"]),
            "text": {"content": text},
        }
        for attempt in range(2):
            token = await self._token(account)
            data = await self._post(creds, "/cgi-bin/message/send", token, body)
            code = data.get("errcode", 0)
            if code == 0:
                return
            if code in _TOKEN_EXPIRED and attempt == 0:
                self._tokens.pop(account.id, None)
                continue
            if code in (40001, 60020):  # Secret 不对、服务器 IP 不在企业可信 IP 里
                raise ChannelAuthError(f"企业微信拒绝发送：{data.get('errmsg')}（{code}）")
            raise RuntimeError(f"企业微信发送失败：{data.get('errmsg')}（{code}）")

    # ---- 接口
    async def _token(self, account: Account) -> str:
        cached = self._tokens.get(account.id)
        if cached and cached[1] > time.time():
            return cached[0]
        token, expires_in = await self._fetch_token(account.credentials)
        self._tokens[account.id] = (token, time.time() + max(60, expires_in - 300))
        return token

    async def _fetch_token(self, creds: dict[str, str]) -> tuple[str, int]:
        async with httpx.AsyncClient(transport=net.http_transport(SERVICE), timeout=15) as client:
            resp = await client.get(
                f"{creds.get('api_base') or DEFAULT_API}/cgi-bin/gettoken",
                params={"corpid": creds["corp_id"], "corpsecret": creds["secret"]},
            )
        data = resp.json()
        if data.get("errcode", 0) != 0:
            raise ValueError(
                f"企业 ID 或 Secret 不对：{data.get('errmsg')}（{data.get('errcode')}）"
            )
        return data["access_token"], int(data.get("expires_in") or 7200)

    async def _post(self, creds: dict[str, str], path: str, token: str, body: dict) -> dict:
        async with httpx.AsyncClient(transport=net.http_transport(SERVICE), timeout=15) as client:
            resp = await client.post(
                f"{creds.get('api_base') or DEFAULT_API}{path}",
                params={"access_token": token},
                json=body,
            )
        return resp.json()


@plugin("wecom-channel", title="企业微信自建应用")
async def apply(ctx) -> None:
    ctx.contribute(IM_CHANNELS, "wecom", WecomDriver())
