"""独立进程里的网盘后端在宿主这边的代理（docs/design/cloud-storage.md §11.6）。

插件进程把后端的声明（类型、名称、能力、登录方式）交给宿主，后端本身留在插件进程；宿主登记一个
``RemoteDriveBackend``，它的每个方法经协议转给插件进程。插件进程把结果装在信封里带回：网盘错误
（限流带等待秒数）与换了的凭据（出错时也可能已经刷新过令牌）都原样还原，上层不用分两套处理。
"""

from __future__ import annotations

from typing import Any

from movieclaw_sdk import drives as dv

#: 插件进程这一层的上限（秒）；宿主调用包装另有按方法的超时，先到先算
CALL_TIMEOUT = 120.0


class RemoteDriveBackend(dv.DriveBackend):
    def __init__(self, session: Any, cid: str, spec: dict[str, Any]) -> None:
        self._session = session
        self._cid = cid
        capabilities, login = dv.spec_parts(spec)
        # 声明在基类上是类属性；代理按插件交来的声明逐个实例覆盖
        self.type = spec["type"]  # type: ignore[misc]
        self.title = spec["title"]  # type: ignore[misc]
        self.description = spec.get("description") or ""  # type: ignore[misc]
        self.accent_color = spec.get("accent_color") or ""  # type: ignore[misc]
        self.capabilities = capabilities  # type: ignore[misc]
        self.login = login  # type: ignore[misc]

    async def _call(
        self, method: str, args: dict[str, Any], account: dv.DriveAccount | None = None
    ) -> Any:
        from movieclaw_api.services.plugin_runtime import PluginProcessGone, RemoteCallError

        payload: dict[str, Any] = {"method": method, "args": args}
        if account is not None:
            payload["account"] = dv.account_dict(account)
        try:
            envelope = await self._session.call(
                self._cid, payload, timeout=CALL_TIMEOUT, kind="drive"
            )
        except PluginProcessGone as exc:
            raise dv.Transient(
                f"网盘插件 {self._session.entry_id} 没在运行，稍后会自动重试"
            ) from exc
        except RemoteCallError as exc:
            raise dv.Transient(exc.detail) from exc
        envelope = envelope or {}
        if account is not None and "credentials" in envelope:
            account.credentials = {str(k): str(v) for k, v in envelope["credentials"].items()}
        error = envelope.get("error")
        if error:
            if error.get("kind") == "ValueError":
                raise ValueError(str(error.get("message") or ""))
            raise dv.error_from(error)
        return envelope.get("value")

    async def begin_login(self, options: dict[str, str]) -> dv.LoginFlow:
        return dv.flow_from(await self._call("begin_login", {"options": options}))

    async def login_state(self, flow_id: str) -> dv.LoginFlow:
        return dv.flow_from(await self._call("login_state", {"flow_id": flow_id}))

    async def cancel_login(self, flow_id: str) -> None:
        await self._call("cancel_login", {"flow_id": flow_id})

    async def login_with_cookie(self, cookie_header: str) -> dv.LoginResult:
        return dv.result_from(
            await self._call("login_with_cookie", {"cookie_header": cookie_header})
        )

    async def account_info(self, account: dv.DriveAccount) -> dv.AccountInfo:
        return dv.info_from(await self._call("account_info", {}, account))

    async def list_dir(self, account: dv.DriveAccount, dir_id: str) -> list[dv.RemoteDir]:
        data = await self._call("list_dir", {"dir_id": dir_id}, account)
        return [dv.remote_dir_from(d) for d in data or ()]

    async def list_tree(self, account: dv.DriveAccount, dir_id: str) -> dv.RemoteTree:
        return dv.tree_from(await self._call("list_tree", {"dir_id": dir_id}, account))

    async def changes(self, account: dv.DriveAccount, cursor: str | None) -> dv.ChangePage:
        return dv.change_page_from(await self._call("changes", {"cursor": cursor}, account))

    async def stat(self, account: dv.DriveAccount, remote_id: str) -> dv.RemoteFile:
        return dv.remote_file_from(await self._call("stat", {"remote_id": remote_id}, account))

    async def direct_link(
        self, account: dv.DriveAccount, remote_id: str, user_agent: str
    ) -> dv.DirectLink:
        data = await self._call(
            "direct_link", {"remote_id": remote_id, "user_agent": user_agent}, account
        )
        return dv.link_from(data)
