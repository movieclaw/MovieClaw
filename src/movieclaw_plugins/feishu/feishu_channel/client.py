"""飞书推送的 HTTP 客户端：群自定义机器人 Webhook，或自建应用机器人。

自定义机器人：用户在群里添加后拿到 Webhook，POST JSON 即可发消息。没有 bot 身份，
也收不到消息。凭据存在 channel_account.token（SecretBox 加密）里，JSON
``{"webhook_url": ..., "secret": ...}``；裸 URL 等价于无签名。签名按飞书口径现算：

    string_to_sign = f"{timestamp}\\n{secret}"   # 时间戳+换行+密钥整体作 HMAC 密钥
    sign = base64(hmac_sha256(key=string_to_sign, msg=b""))

自建应用：JSON ``{"app_id", "app_secret", "receive_id", "receive_id_type", "domain"}``。
用 tenant_access_token 发消息，目标是群 chat_id（oc_）或用户 open_id（ou_）。
同一份 JSON 里若同时有 webhook_url 和 app_id，仍按 Webhook 发，旧配置不用迁移。

出口走 net.http_transport("feishu")。密钥和 tenant_access_token 不写日志。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
from typing import Any
from urllib.parse import urlsplit

import httpx

from movieclaw_sdk import net
from movieclaw_sdk.channels import ChannelInputError

from .card import build_card

#: 404 = 机器人已被移除(Webhook 随之失效),对应通道层的凭据失效语义
_AUTH_ERROR_STATUS = (404,)
#: 签名校验失败:secret 不对,属凭据级错误
_SIGN_MISMATCH_CODE = 19021
#: tenant_access_token 失效,清缓存后重试一次
_STALE_TOKEN_CODES = (99991663, 99991661)
#: 发消息缺少权限。230027 见发消息接口「Lack of necessary permissions」；
#: 99991672 是 scope 不足（如未开通 im:message）。其它码按普通失败处理。
_MISSING_SEND_PERMISSION_CODES = frozenset({230027, 99991672})
#: 过期前提前刷新,避免卡在边界上用一张即将失效的令牌
_TOKEN_SKEW_S = 120

#: Webhook 只接受飞书/Lark 官方域(同时是 SSRF 防线:服务端只会 POST 到官方域)
_ALLOWED_HOST_SUFFIXES = ("feishu.cn", "larksuite.com")
_WEBHOOK_PATH_MARK = "/open-apis/bot/v2/hook/"


class FeishuApiError(Exception):
    """Webhook 或开放平台调用失败时抛出;``auth_failed`` 标记凭据级错误。"""

    def __init__(
        self,
        message: str,
        *,
        auth_failed: bool = False,
        code: int | None = None,
        missing_send_permission: bool = False,
    ) -> None:
        super().__init__(message)
        self.auth_failed = auth_failed
        self.code = code
        self.missing_send_permission = missing_send_permission


def normalize_webhook_url(raw: str) -> str:
    """校验并归一化用户粘贴的 Webhook 地址,不合法抛 ValueError。

    只接受 https 且主机为飞书/Lark 官方域、路径带机器人 hook 令牌的地址。
    """
    url = raw.strip()
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.netloc:
        raise ChannelInputError(
            "Webhook 地址不合法:需要完整的 https:// 链接",
            message_localized={"en": "Invalid Webhook URL: enter a complete https:// link"},
        )
    host = parts.hostname or ""
    if not any(host == s or host.endswith("." + s) for s in _ALLOWED_HOST_SUFFIXES):
        raise ChannelInputError(
            "Webhook 地址不合法:主机不是飞书/Lark 官方域名",
            message_localized={
                "en": "Invalid Webhook URL: the host is not an official Feishu or Lark domain"
            },
        )
    if _WEBHOOK_PATH_MARK not in parts.path or not parts.path.split(_WEBHOOK_PATH_MARK)[-1]:
        raise ChannelInputError(
            "Webhook 地址不合法:路径里找不到机器人 hook 令牌",
            message_localized={
                "en": "Invalid Webhook URL: the path does not contain a bot hook token"
            },
        )
    return url


def feishu_account_id(webhook_url: str) -> str:
    """从 Webhook 地址提取账号 id(hook 令牌):同一机器人重复接入即覆盖,不产生重复账号。"""
    return normalize_webhook_url(webhook_url).split(_WEBHOOK_PATH_MARK)[-1].rstrip("/")


def parse_credentials(token: str) -> tuple[str, str]:
    """解出 (webhook_url, secret)。token 列存 JSON;裸 URL 亦兼容(等价无签名)。"""
    try:
        data = json.loads(token)
    except ValueError:
        return token, ""
    if isinstance(data, dict) and isinstance(data.get("webhook_url"), str):
        return data["webhook_url"], str(data.get("secret") or "")
    return token, ""


def credential_kind(token: str) -> str:
    """``webhook`` 或 ``app``。两者都有时保持 Webhook,避免旧行被误判成应用。"""
    try:
        data = json.loads(token)
    except ValueError:
        return "webhook"
    if not isinstance(data, dict):
        return "webhook"
    webhook = data.get("webhook_url")
    if isinstance(webhook, str) and webhook.strip():
        return "webhook"
    app_id = data.get("app_id")
    if isinstance(app_id, str) and app_id.strip():
        return "app"
    return "webhook"


def credentials_token(credentials: dict[str, str]) -> str:
    """把账号凭据编回 FeishuClient 认的 JSON。有 Webhook 时忽略应用字段。"""
    webhook = (credentials.get("webhook_url") or "").strip()
    app_id = (credentials.get("app_id") or "").strip()
    if webhook or not app_id:
        return json.dumps(
            {
                "webhook_url": credentials.get("webhook_url", ""),
                "secret": credentials.get("secret", ""),
            }
        )
    domain = (credentials.get("domain") or "feishu").strip().lower()
    receive_id = credentials.get("receive_id", "")
    receive_id_type = credentials.get("receive_id_type") or (
        "chat_id" if receive_id.startswith("oc_") else "open_id"
    )
    return json.dumps(
        {
            "app_id": app_id,
            "app_secret": credentials.get("app_secret", ""),
            "receive_id": receive_id,
            "receive_id_type": receive_id_type,
            "domain": domain if domain in ("feishu", "lark") else "feishu",
        }
    )


def _sign(timestamp: str, secret: str) -> str:
    # 飞书的非常规口径:string_to_sign 整体作为 HMAC 密钥,消息体为空
    string_to_sign = f"{timestamp}\n{secret}"
    digest = hmac.new(string_to_sign.encode("utf-8"), digestmod=hashlib.sha256).digest()
    return base64.b64encode(digest).decode("utf-8")


def _as_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _token_ttl(expire: int) -> float:
    if expire > _TOKEN_SKEW_S:
        return float(expire - _TOKEN_SKEW_S)
    return float(max(expire, 1))


def _image_part(photo: bytes) -> tuple[str, str]:
    if photo.startswith(b"\x89PNG\r\n\x1a\n"):
        return "poster.png", "image/png"
    if photo.startswith((b"GIF87a", b"GIF89a")):
        return "poster.gif", "image/gif"
    if photo.startswith(b"RIFF") and photo[8:12] == b"WEBP":
        return "poster.webp", "image/webp"
    return "poster.jpg", "image/jpeg"


def _open_base(domain: str) -> str:
    if domain == "lark":
        return "https://open.larksuite.com"
    return "https://open.feishu.cn"


class FeishuClient:
    """一个飞书推送账号:Webhook 或自建应用(通道层单任务使用)。"""

    def __init__(self, token: str) -> None:
        self._mode = credential_kind(token)
        self._http = httpx.AsyncClient(
            transport=net.http_transport("feishu"),
            timeout=httpx.Timeout(15.0, connect=10.0),
        )
        self._access_token = ""
        self._access_deadline = 0.0
        self._webhook_url = ""
        self._secret = ""
        self._app_id = ""
        self._app_secret = ""
        self._receive_id = ""
        self._receive_id_type = "open_id"
        self._domain = "feishu"
        if self._mode == "app":
            data = json.loads(token)
            self._app_id = str(data.get("app_id") or "")
            self._app_secret = str(data.get("app_secret") or "")
            self._receive_id = str(data.get("receive_id") or "")
            kind = str(data.get("receive_id_type") or "")
            self._receive_id_type = (
                kind
                if kind in ("chat_id", "open_id")
                else ("chat_id" if self._receive_id.startswith("oc_") else "open_id")
            )
            domain = str(data.get("domain") or "feishu").lower()
            self._domain = domain if domain in ("feishu", "lark") else "feishu"
        else:
            self._webhook_url, self._secret = parse_credentials(token)

    async def aclose(self) -> None:
        await self._http.aclose()

    async def send_text(self, text: str) -> None:
        if self._mode == "app":
            await self._send_app("text", json.dumps({"text": text}, ensure_ascii=False))
            return
        await self._post_webhook({"msg_type": "text", "content": {"text": text}})

    async def send_card(self, text: str, photo: bytes | None = None) -> None:
        """发交互式卡片。应用模式会先上传海报;上传失败改发无图卡片。

        没有标题、或卡片接口拒绝时抛 ``FeishuApiError``,由适配器改发纯文本。
        Webhook 不能上传图片,只发无图卡片(仍带签名)。
        """
        image_key = None
        if self._mode == "app" and photo:
            try:
                image_key = await self.upload_image(photo)
            except FeishuApiError:
                image_key = None
        card = build_card(text, image_key)
        if card is None:
            raise FeishuApiError("消息缺少标题,无法发送卡片")
        if self._mode == "webhook":
            await self._post_webhook({"msg_type": "interactive", "card": card})
            return
        await self._send_app("interactive", json.dumps(card, ensure_ascii=False))

    async def tenant_access_token(self) -> str:
        """取应用令牌。内存缓存,过期前两分钟刷新。不写日志。"""
        now = time.monotonic()
        if self._access_token and now < self._access_deadline:
            return self._access_token
        try:
            resp = await self._http.post(
                f"{_open_base(self._domain)}/open-apis/auth/v3/tenant_access_token/internal",
                json={"app_id": self._app_id, "app_secret": self._app_secret},
            )
        except httpx.HTTPError as exc:
            raise FeishuApiError("飞书应用连接失败") from exc
        try:
            data = resp.json()
        except ValueError as exc:
            raise FeishuApiError(
                f"获取 tenant_access_token 失败(HTTP {resp.status_code},非 JSON)"
            ) from exc
        if not isinstance(data, dict):
            raise FeishuApiError(f"获取 tenant_access_token 失败(HTTP {resp.status_code})")
        token = str(data.get("tenant_access_token") or "")
        if resp.status_code != 200 or data.get("code") not in (0, None) or not token:
            detail = data.get("msg") or data.get("code") or resp.status_code
            raise FeishuApiError(
                f"获取 tenant_access_token 失败:{detail}",
                auth_failed=True,
            )
        self._access_token = token
        self._access_deadline = time.monotonic() + _token_ttl(_as_int(data.get("expire")))
        return token

    def _clear_token(self) -> None:
        self._access_token = ""
        self._access_deadline = 0.0

    async def upload_image(self, photo: bytes) -> str:
        """上传一张消息图片,返回 image_key。令牌失效时刷新后重试一次。"""
        filename, mime = _image_part(photo)
        response: httpx.Response | None = None
        for attempt in (1, 2):
            token = await self.tenant_access_token()
            try:
                response = await self._http.post(
                    f"{_open_base(self._domain)}/open-apis/im/v1/images",
                    headers={"Authorization": f"Bearer {token}"},
                    data={"image_type": "message"},
                    files={"image": (filename, photo, mime)},
                )
            except httpx.HTTPError as exc:
                raise FeishuApiError("飞书图片上传失败") from exc
            if attempt == 1 and _token_stale(response):
                self._clear_token()
                continue
            break
        assert response is not None
        data = self._body(response)
        payload = data.get("data")
        image_key = payload.get("image_key") if isinstance(payload, dict) else ""
        if not image_key:
            raise FeishuApiError("飞书图片上传未返回 image_key")
        return str(image_key)

    async def _send_app(self, msg_type: str, content: str) -> None:
        response: httpx.Response | None = None
        for attempt in (1, 2):
            token = await self.tenant_access_token()
            try:
                response = await self._http.post(
                    f"{_open_base(self._domain)}/open-apis/im/v1/messages",
                    params={"receive_id_type": self._receive_id_type},
                    headers={"Authorization": f"Bearer {token}"},
                    json={
                        "receive_id": self._receive_id,
                        "msg_type": msg_type,
                        "content": content,
                    },
                )
            except httpx.HTTPError as exc:
                raise FeishuApiError("飞书应用连接失败") from exc
            if attempt == 1 and _token_stale(response):
                self._clear_token()
                continue
            break
        assert response is not None
        self._parse(response)

    async def _post_webhook(self, payload: dict[str, Any]) -> None:
        if self._secret:
            timestamp = str(int(time.time()))
            payload["timestamp"] = timestamp
            payload["sign"] = _sign(timestamp, self._secret)
        try:
            resp = await self._http.post(self._webhook_url, json=payload)
        except httpx.HTTPError as exc:
            raise FeishuApiError(f"飞书机器人连接失败:{exc}") from exc
        self._parse(resp)

    def _body(self, resp: httpx.Response) -> dict[str, Any]:
        self._parse(resp)
        data = resp.json()
        return data if isinstance(data, dict) else {}

    def _parse(self, resp: httpx.Response) -> None:
        if resp.status_code in _AUTH_ERROR_STATUS:
            raise FeishuApiError(
                "飞书机器人不存在或已被移除,请重新创建机器人并接入", auth_failed=True
            )
        data: dict[str, Any] | None
        try:
            parsed = resp.json()
        except ValueError:
            data = None
        else:
            data = parsed if isinstance(parsed, dict) else None
        # 成功响应 {"code": 0, "msg": "success"};旧版网关用 StatusCode 同义。
        # 缺码不能当成 0:下面的 _as_int 把无法解析的值收成 0,只用于权限码判断。
        raw_code = data.get("code", data.get("StatusCode")) if data is not None else None
        code = _as_int(raw_code)
        if code in _MISSING_SEND_PERMISSION_CODES:
            raise FeishuApiError("缺少发消息权限", code=code, missing_send_permission=True)
        if resp.status_code != 200:
            raise FeishuApiError(f"飞书机器人接口异常(HTTP {resp.status_code})")
        if data is None:
            raise FeishuApiError(f"飞书机器人接口返回异常响应(HTTP {resp.status_code},非 JSON)")
        if raw_code == 0:
            return
        msg = str(data.get("msg") or data.get("StatusMessage") or raw_code)
        if raw_code == _SIGN_MISMATCH_CODE:
            raise FeishuApiError(
                "签名校验失败:机器人开启了签名校验但密钥不匹配,请解绑后重新接入并核对签名密钥",
                auth_failed=True,
                code=code,
            )
        # 飞书报文是「Key Words Not Found」(带空格):归一后比对,避免误判成普通拒收
        if "keyword" in msg.lower().replace(" ", "").replace("-", ""):
            # 「自定义关键词」安全设置:movieclaw 的推送文案无法保证含特定词,
            # 与其让后续推送静默丢失,不如在接入时就把话说明白
            raise FeishuApiError(
                "机器人开启了「自定义关键词」安全设置,推送文案未包含该关键词。"
                "建议重新创建机器人并选择「签名校验」,再填入 Webhook 地址与签名密钥",
                code=code,
            )
        raise FeishuApiError(f"飞书机器人拒收消息:{msg}", code=code or None)


def _token_stale(resp: httpx.Response) -> bool:
    if resp.status_code in (401, 403):
        return True
    try:
        data = resp.json()
    except ValueError:
        return False
    return isinstance(data, dict) and data.get("code") in _STALE_TOKEN_CODES
