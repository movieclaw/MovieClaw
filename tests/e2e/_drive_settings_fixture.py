"""Loopback-backed storage plugin for the complete drive settings browser flow."""

import os

import httpx
from pydantic import BaseModel, Field, SecretStr

from movieclaw_sdk import net, plugin
from movieclaw_sdk.drives import (
    DRIVE_BACKENDS,
    AccountInfo,
    AuthExpired,
    Capabilities,
    Choice,
    DriveBackend,
    Login,
    LoginFlow,
    LoginOption,
    LoginResult,
    RemoteDir,
    RemoteTree,
)


class Credentials(BaseModel):
    client_id: str = Field(title="Client ID")
    client_secret: SecretStr = Field(
        title="客户端密钥", json_schema_extra={"title_localized": {"en": "Client Secret"}}
    )


class FixtureDrive(DriveBackend):
    type = "fixture"
    title = "Fixture Drive"
    capabilities = Capabilities(writable=True, default_qps=1000, default_daily_budget=100000)
    login = Login(
        scan=True,
        cookie_domains=("fixture.example",),
        form=Credentials,
        options=(
            LoginOption(
                "device",
                "Sign-in device",
                (
                    Choice("mini", "Mobile app"),
                    Choice("web", "Web app", "Shares the browser sign-in"),
                ),
                "mini",
            ),
        ),
    )

    async def request(self, method, **payload):
        async with httpx.AsyncClient(
            transport=net.http_transport("drive-settings-fixture")
        ) as client:
            response = await client.post(
                os.environ["E2E_DRIVE_UPSTREAM"] + "/" + method, json=payload
            )
            data = response.json()
            if response.status_code == 401:
                raise AuthExpired(data["error"])
            response.raise_for_status()
            return data

    async def begin_login(self, options):
        return LoginFlow(**await self.request("begin", options=options))

    async def login_state(self, flow_id):
        data = await self.request("poll", flow_id=flow_id)
        if data.get("result"):
            data["result"] = LoginResult(**data["result"])
        return LoginFlow(**data)

    async def cancel_login(self, flow_id):
        await self.request("cancel", flow_id=flow_id)

    async def login_with_cookie(self, cookie_header):
        return LoginResult(**await self.request("cookie", cookie=cookie_header))

    async def login_with_form(self, values):
        return LoginResult(**await self.request("form", **values))

    async def account_info(self, account):
        return AccountInfo(**await self.request("profile", user_id=account.user_id))

    async def list_dir(self, account, dir_id):
        return [RemoteDir(**row) for row in await self.request("dirs", parent=dir_id)]

    async def list_tree(self, account, dir_id):
        await self.request("tree", parent=dir_id)
        return RemoteTree(files=())


@plugin("drive-settings-fixture", title="Fixture Drive")
async def apply(ctx):
    ctx.contribute(DRIVE_BACKENDS, "fixture", FixtureDrive())
