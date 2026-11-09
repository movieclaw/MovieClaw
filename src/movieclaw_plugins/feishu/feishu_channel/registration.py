"""飞书「一键创建智能体应用」的设备码流程（RFC 8628）。

公开协议：POST https://accounts.feishu.cn/oauth/v1/app/registration
（国际版 Lark 为 https://accounts.larksuite.com），表单字段只使用文档里的这几项：

- ``action=init``：``supported_auth_methods`` 须含 ``client_secret``
- ``action=begin``：``archetype=PersonalAgent``、``auth_method=client_secret``、
  ``request_user_info=open_id``
- ``action=poll``：``device_code``

总是从飞书账号域发起。轮询看到 ``user_info.tenant_brand=lark`` 时切到 Lark 域立刻再查一次，
切域那一次响应里的凭据丢掉。``client_secret`` / ``device_code`` 不写日志。
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any

import httpx

from movieclaw_sdk import net

_FEISHU_ACCOUNTS = "https://accounts.feishu.cn"
_LARK_ACCOUNTS = "https://accounts.larksuite.com"
_PATH = "/oauth/v1/app/registration"
_DEFAULT_INTERVAL_S = 5
_DEFAULT_EXPIRE_S = 600
_MAX_INTERVAL_S = 60


class RegistrationError(Exception):
    """init / begin 失败。``code`` 对应 binding._BINDING_MESSAGES 的键，不携带响应正文。"""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass
class DeviceFlow:
    """begin 的结果。``qr`` 是服务端返回的 ``verification_uri_complete``，原样给用户扫。"""

    device_code: str
    qr: str
    user_code: str
    interval: int
    expire_in: int


@dataclass
class PollOutcome:
    """一次 poll 的结论。``__repr__`` 不包含 client_secret。"""

    status: str
    interval: int
    domain: str = "feishu"
    client_id: str = ""
    client_secret: str = ""
    open_id: str = ""
    message: str = ""

    def __repr__(self) -> str:
        return (
            f"PollOutcome(status={self.status!r}, domain={self.domain!r}, "
            f"interval={self.interval!r})"
        )


def _accounts_base(domain: str) -> str:
    return _LARK_ACCOUNTS if domain == "lark" else _FEISHU_ACCOUNTS


def _positive(value: Any, default: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return number if number > 0 else default


class RegistrationSession:
    """一次设备码注册。``http`` 传入时由本对象在 ``aclose`` 里关掉。"""

    def __init__(self, http: httpx.AsyncClient | None = None) -> None:
        self._http = http or httpx.AsyncClient(
            transport=net.http_transport("feishu"),
            timeout=httpx.Timeout(10.0),
        )
        self.domain = "feishu"
        self.device_code = ""
        self.user_code = ""
        self.qr = ""
        self.interval = _DEFAULT_INTERVAL_S
        self.deadline = 0.0
        self.switched = False

    async def aclose(self) -> None:
        await self._http.aclose()

    async def start(self) -> DeviceFlow:
        """init → begin。失败抛 ``RegistrationError``，不留下半开的轮询。"""
        init = await self._post("feishu", {"action": "init"})
        methods = init.get("supported_auth_methods")
        if init.get("error") or not isinstance(methods, list) or "client_secret" not in methods:
            code = "unsupported" if not init.get("error") else "error"
            if isinstance(methods, list) and "client_secret" not in methods:
                code = "unsupported"
            raise RegistrationError(code)
        begin = await self._post(
            "feishu",
            {
                "action": "begin",
                "archetype": "PersonalAgent",
                "auth_method": "client_secret",
                "request_user_info": "open_id",
            },
        )
        device_code = str(begin.get("device_code") or "")
        qr = str(begin.get("verification_uri_complete") or "")
        if begin.get("error") or not device_code or not qr:
            raise RegistrationError("error")
        expire_in = _positive(begin.get("expire_in"), 0)
        if expire_in <= 0:
            expire_in = _positive(begin.get("expires_in"), _DEFAULT_EXPIRE_S)
        self.device_code = device_code
        self.user_code = str(begin.get("user_code") or "")
        self.qr = qr
        self.interval = _positive(begin.get("interval"), _DEFAULT_INTERVAL_S)
        self.deadline = time.monotonic() + expire_in
        self.domain = "feishu"
        self.switched = False
        return DeviceFlow(
            device_code=device_code,
            qr=qr,
            user_code=self.user_code,
            interval=self.interval,
            expire_in=expire_in,
        )

    async def poll_once(self) -> PollOutcome:
        """查一次。网络错误、非 JSON 视为尚未授权，由调用方按 interval 再等。"""
        if time.monotonic() >= self.deadline:
            return PollOutcome(status="expired", interval=self.interval, domain=self.domain)
        try:
            data = await self._post(
                self.domain, {"action": "poll", "device_code": self.device_code}
            )
        except RegistrationError:
            return PollOutcome(status="pending", interval=self.interval, domain=self.domain)
        if not self.switched and self.domain == "feishu" and _tenant_brand(data) == "lark":
            # 切域响应里即使带了凭据也不采用，立刻改到 Lark 域再查
            self.domain = "lark"
            self.switched = True
            return await self.poll_once()
        return self._outcome(data)

    def _outcome(self, data: dict[str, Any]) -> PollOutcome:
        error = str(data.get("error") or "")
        if not error:
            client_id = str(data.get("client_id") or "")
            client_secret = str(data.get("client_secret") or "")
            if client_id and client_secret:
                return PollOutcome(
                    status="success",
                    interval=self.interval,
                    domain=self.domain,
                    client_id=client_id,
                    client_secret=client_secret,
                    open_id=_open_id(data),
                )
            return PollOutcome(status="pending", interval=self.interval, domain=self.domain)
        if error == "authorization_pending":
            return PollOutcome(status="pending", interval=self.interval, domain=self.domain)
        if error == "slow_down":
            self.interval = min(self.interval + 5, _MAX_INTERVAL_S)
            return PollOutcome(status="pending", interval=self.interval, domain=self.domain)
        if error == "access_denied":
            return PollOutcome(status="denied", interval=self.interval, domain=self.domain)
        if error in ("expired_token", "invalid_grant"):
            return PollOutcome(status="expired", interval=self.interval, domain=self.domain)
        message = str(data.get("error_description") or error)
        return PollOutcome(
            status="error", interval=self.interval, domain=self.domain, message=message
        )

    async def _post(self, domain: str, form: dict[str, str]) -> dict[str, Any]:
        url = _accounts_base(domain) + _PATH
        try:
            resp = await self._http.post(url, data=form)
        except httpx.HTTPError as exc:
            raise RegistrationError("error") from exc
        try:
            data = resp.json()
        except ValueError as exc:
            raise RegistrationError("error") from exc
        if not isinstance(data, dict):
            raise RegistrationError("error")
        return data


def _tenant_brand(data: dict[str, Any]) -> str:
    info = data.get("user_info")
    if not isinstance(info, dict):
        return ""
    return str(info.get("tenant_brand") or "")


def _open_id(data: dict[str, Any]) -> str:
    info = data.get("user_info")
    if not isinstance(info, dict):
        return ""
    return str(info.get("open_id") or "")
