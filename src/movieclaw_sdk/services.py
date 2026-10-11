"""宿主导出给进程外插件的服务契约（docs/design/plugin-ipc-http.md §3）。

每个服务一个 ``Protocol`` 类，方法签名就是协议：网关按它校验参数、编码返回值（``rpc.methods``），
SDK 按它生成远程代理。插件代码不直接用这些类，而是经 ``RemoteContext`` 里的服务门面（与进程内的服务
接口同名同签名）。本模块只依赖 pydantic，进程外插件导入它很轻。
"""

from __future__ import annotations

from typing import Any, Protocol

from pydantic import BaseModel, ConfigDict

from movieclaw_sdk.agent import AgentApi
from movieclaw_sdk.ops import OperationRef


class StoredValue(BaseModel):
    model_config = ConfigDict(frozen=True)

    found: bool
    value: Any = None


class DataApi(Protocol):
    """插件数据（``PLUGIN_DATA``），作用域限定在调用方自己的条目。"""

    async def get(self, key: str, scope: str = "global") -> StoredValue: ...

    async def set(
        self, key: str, value: Any, scope: str = "global", secret: bool = False
    ) -> None: ...

    async def delete(self, key: str, scope: str = "global") -> bool: ...

    async def items(self, scope: str = "global") -> dict[str, Any]: ...

    async def scopes(self, key: str, entity: str | None = None) -> dict[str, Any]: ...


class HealthApi(Protocol):
    """插件健康（``PLUGIN_HEALTH``）。"""

    async def degraded(self, key: str, message: str, action_href: str | None = None) -> None: ...

    async def ok(self, key: str, message: str = "") -> None: ...


class CallbacksApi(Protocol):
    """回调端点的密钥（``PLUGIN_CALLBACKS``）；端点本身在就绪时声明。"""

    async def issue(self, name: str, scope: str = "plugin") -> dict[str, Any]: ...

    async def revoke(self, key_id: int) -> None: ...

    async def keys(self, name: str | None = None) -> list[dict[str, Any]]: ...


class RoutesApi(Protocol):
    """插件路由的签名链接（``PLUGIN_ROUTES``）；路由本身在就绪时声明。"""

    async def sign(
        self,
        path: str,
        params: dict[str, str] | None = None,
        expires_in: int | None = None,
        absolute: bool = False,
    ) -> str: ...


class FilesApi(Protocol):
    """按路径授权的文件（``PLUGIN_FILES``）。``open`` 返回令牌，描述符经 socketpair 递送。"""

    async def open(self, path: str, mode: str = "rb") -> str: ...

    async def stat(self, path: str) -> dict[str, Any] | None: ...

    async def listdir(self, path: str) -> list[str]: ...

    async def makedirs(self, path: str) -> None: ...

    async def rename(self, src: str, dst: str) -> None: ...

    async def remove(self, path: str) -> None: ...


class OpsApi(Protocol):
    """宿主操作（``HOST_OPS``）的目录；调用本身是直接请求 ``/api/v1``。"""

    async def operations(self) -> list[OperationRef]: ...


class NetApi(Protocol):
    """网络出口：插件自己的服务名在「网络与代理」里配的代理（可能带凭据，只回答自己的）。"""

    async def proxy(self, service: str) -> str | None: ...


class JobApi(Protocol):
    """任务处理器的上下文：只能在宿主派来的任务调用里用（按调用号找到真实的 ``JobContext``）。"""

    async def update_progress(self, progress: dict[str, Any]) -> None: ...

    async def current_progress(self) -> dict[str, Any]: ...

    async def cancel_requested(self) -> bool: ...


class ChannelsApi(Protocol):
    """通道驱动回调中枢：收到消息、保存账号状态。"""

    async def inbound(self, channel: str, account: str, message: dict[str, Any]) -> None: ...

    async def save_state(self, channel: str, account: str, patch: dict[str, Any]) -> None: ...


class SessionApi(Protocol):
    """进程生命周期：插件跑完 ``apply`` 报就绪（一次带上全部声明），或报启动失败。"""

    async def ready(
        self,
        title: str,
        listeners: list[dict[str, Any]],
        contributions: list[dict[str, Any]],
        routes: list[dict[str, Any]],
        callbacks: list[dict[str, Any]],
        serving: bool,
    ) -> None: ...

    async def failed(self, error_type: str, error_message: str) -> None: ...


class HooksApi(Protocol):
    """瀑布钩子里插件调 ``next()``：宿主替它跑下游（按调用号找到这次钩子调用）。

    ``replace`` 为真时把 ``payload`` 换给下游，否则下游拿原载荷。
    """

    async def next(self, payload: Any = None, replace: bool = False) -> Any: ...


#: 服务名 → 契约。网关只导出插件声明过的服务（``session``、``hooks``、``net``、``job``、
#: ``channels`` 总是可用）
SERVICES: dict[str, type] = {
    "session": SessionApi,
    "hooks": HooksApi,
    "data": DataApi,
    "health": HealthApi,
    "callbacks": CallbacksApi,
    "routes": RoutesApi,
    "files": FilesApi,
    "ops": OpsApi,
    "net": NetApi,
    "job": JobApi,
    "channels": ChannelsApi,
    "agent": AgentApi,
}
