"""插件回调端点契约（docs/design/plugin-callbacks.md §4）。

外部平台（企业微信、GitHub、Slack……）按插件交出去的地址调进来::

    <外部访问地址>/api/v1/hooks/<条目 id>/<端点名>/<密钥>[/<子路径>]

宿主管地址、路由、请求体与频率限制、剥掉 MovieClaw 自己的登录 Cookie；**不验签、不解析请求体**，
请求原样交给插件，插件的答复原样回给平台。各平台的验签由插件自己做::

    from movieclaw_sdk.callbacks import PLUGIN_CALLBACKS, CallbackRequest, CallbackResponse

    @plugin("wecom-channel", title="企业微信", inject=(PLUGIN_CALLBACKS,))
    async def apply(ctx):
        callbacks = ctx.use(PLUGIN_CALLBACKS)

        async def on_message(req: CallbackRequest) -> CallbackResponse:
            if not verify(req):                       # 平台的签名，插件自己验
                return CallbackResponse(status=403)
            return CallbackResponse.text("success")

        callbacks.endpoint(ctx, "callback", on_message, methods=("GET", "POST"))
        issued = await callbacks.issue(ctx, "callback")   # 发一把密钥，issued.url 交给用户

插件包要在清单里声明端点名：``[permissions] callbacks = ["callback"]``，
批准安装时单独列给用户看。
处理函数要在几秒内答复（默认 10 秒超时）；耗时工作交给后台任务（``job-handlers``）
后立即返回。
"""

from __future__ import annotations

import base64
import json
import re
from dataclasses import dataclass, field
from typing import Any, Protocol

from movieclaw_kernel import ServiceKey, Stability

#: 端点名：小写字母开头，字母、数字、连字符，最多 32 位
NAME = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
#: 默认的请求体上限（字节）；登记端点时可以调小
MAX_BODY = 1024 * 1024
#: 处理函数的默认超时（秒）
TIMEOUT = 10.0


@dataclass(frozen=True)
class CallbackRequest:
    """外部平台发来的一次请求（原样）。"""

    method: str
    endpoint: str
    #: 地址里密钥之后的部分（不含开头的 /），没有就是空串
    subpath: str = ""
    query: tuple[tuple[str, str], ...] = ()
    headers: tuple[tuple[str, str], ...] = ()
    body: bytes = b""
    #: 这把密钥登记的归属：``plugin`` / ``account:<通道>:<账号>`` / ``entity:<类型>:<id>``
    scope: str = "plugin"
    #: 密钥的记录 id（作废、换地址时用）
    key_id: int = 0

    def header(self, name: str) -> str | None:
        """取一个请求头（不分大小写）。"""
        lowered = name.lower()
        return next((v for k, v in self.headers if k.lower() == lowered), None)

    def param(self, name: str) -> str | None:
        """取一个查询参数（多值时取第一个）。"""
        return next((v for k, v in self.query if k == name), None)

    def text(self, encoding: str = "utf-8") -> str:
        return self.body.decode(encoding, "replace")

    def json(self) -> Any:
        return json.loads(self.body or b"null")


@dataclass(frozen=True)
class CallbackResponse:
    """插件给平台的答复（原样回出去）。"""

    status: int = 200
    body: bytes = b""
    headers: dict[str, str] = field(default_factory=dict)

    @classmethod
    def text(cls, content: str, status: int = 200) -> CallbackResponse:
        return cls(status, content.encode(), {"Content-Type": "text/plain; charset=utf-8"})

    @classmethod
    def json(cls, data: Any, status: int = 200) -> CallbackResponse:
        body = json.dumps(data, ensure_ascii=False).encode()
        return cls(status, body, {"Content-Type": "application/json"})


@dataclass(frozen=True)
class Issued:
    """发出去的一把密钥。"""

    id: int
    endpoint: str
    scope: str
    #: 完整地址：没配外部访问地址时只有路径（``/api/v1/hooks/…``），要提醒用户先配
    url: str
    #: 是否带上了外部访问地址
    absolute: bool


class Callbacks(Protocol):
    """``ctx.use(PLUGIN_CALLBACKS)`` 拿到的服务。"""

    def endpoint(
        self,
        ctx: Any,
        name: str,
        handler: Any,
        *,
        methods: tuple[str, ...] = ("POST",),
        max_body: int = MAX_BODY,
    ) -> None:
        """登记端点的处理函数（``async def handler(req) -> CallbackResponse``）。

        插件卸下时自动撤销。
        """
        ...

    async def issue(self, ctx: Any, name: str, *, scope: str = "plugin") -> Issued:
        """给端点发一把新密钥，返回地址。"""
        ...

    async def revoke(self, ctx: Any, key_id: int) -> None:
        """作废一把密钥（地址立即失效）。"""
        ...

    async def keys(self, ctx: Any, name: str | None = None) -> list[Issued]:
        """本插件还有效的密钥（地址里的密钥打码）。"""
        ...


PLUGIN_CALLBACKS: ServiceKey[Callbacks] = ServiceKey(
    "plugin-callbacks",
    stability=Stability.EXPERIMENTAL,
    doc="插件回调端点：外部平台能直接调进来的地址，请求原样交给插件（plugin-callbacks.md §4）",
)


# ---------------------------------------------------------------------- 协议（进程外运行）
def request_dict(req: CallbackRequest) -> dict[str, Any]:
    return {
        "method": req.method,
        "endpoint": req.endpoint,
        "subpath": req.subpath,
        "query": [list(p) for p in req.query],
        "headers": [list(p) for p in req.headers],
        "body": base64.b64encode(req.body).decode("ascii"),
        "scope": req.scope,
        "key_id": req.key_id,
    }


def request_from_dict(data: dict[str, Any]) -> CallbackRequest:
    return CallbackRequest(
        method=data["method"],
        endpoint=data["endpoint"],
        subpath=data.get("subpath", ""),
        query=tuple((k, v) for k, v in data.get("query", [])),
        headers=tuple((k, v) for k, v in data.get("headers", [])),
        body=base64.b64decode(data.get("body", "")),
        scope=data.get("scope", "plugin"),
        key_id=int(data.get("key_id", 0)),
    )


def response_dict(resp: CallbackResponse) -> dict[str, Any]:
    return {
        "status": resp.status,
        "body": base64.b64encode(resp.body).decode("ascii"),
        "headers": dict(resp.headers),
    }


def response_from_dict(data: dict[str, Any]) -> CallbackResponse:
    return CallbackResponse(
        status=int(data.get("status", 200)),
        body=base64.b64decode(data.get("body", "")),
        headers=dict(data.get("headers") or {}),
    )


def issued_dict(issued: Issued) -> dict[str, Any]:
    return {
        "id": issued.id,
        "endpoint": issued.endpoint,
        "scope": issued.scope,
        "url": issued.url,
        "absolute": issued.absolute,
    }


def issued_from_dict(data: dict[str, Any]) -> Issued:
    return Issued(
        id=int(data["id"]),
        endpoint=data["endpoint"],
        scope=data["scope"],
        url=data["url"],
        absolute=bool(data["absolute"]),
    )
