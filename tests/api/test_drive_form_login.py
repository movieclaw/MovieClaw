"""网盘填表登录（cloud-storage.md §11.2、#913）。

开放平台这类网盘（123 的 Client ID / Client Secret）用一个测试内的假插件，主进程与独立进程各跑一遍：

- 插件声明的 pydantic 表单原样转成 JSON Schema 交给界面，密钥字段标成密码框、不带默认值；
- 宿主先按声明收窄（只留声明过的字段、必填项非空、去掉首尾空白），再交插件真去验一次，用插件交回的
  真实网盘用户 id 建账号；同一用户再登录更新原账号；
- 凭据不对、限流分开报，都不建账号；
- 从账号卡片上重新登录（``relogin``）时登进来的必须是同一个网盘用户；
- 令牌过期由插件在调用里拿长期密钥重新换，新令牌先落库；密钥不出现在接口返回与日志里。
"""

from __future__ import annotations

import json
import logging
import sys
import textwrap

import pytest
from fastapi.testclient import TestClient
from pydantic import BaseModel, Field, SecretStr

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events
from movieclaw_sdk import drives as dv

ADMIN = {"username": "admin", "password": "s3cret-pass"}
SECRET = "sk-very-secret-value"

PLUGIN = """
import itertools

from pydantic import BaseModel, Field, SecretStr

from movieclaw_sdk import plugin
from movieclaw_sdk.drives import (
    DRIVE_BACKENDS,
    AccountInfo,
    AuthExpired,
    Capabilities,
    DriveBackend,
    Login,
    LoginResult,
    RateLimited,
)

_tokens = itertools.count(1)


class Credentials(BaseModel):
    client_id: str = Field(title="Client ID")
    client_secret: SecretStr = Field(title="Client Secret")
    region: str = Field("cn", title="区域", description="开放平台所在区域")


def _token(creds):
    secret = creds.client_secret.get_secret_value()
    if secret == "wrong":
        raise AuthExpired("clientSecret 不对")
    if secret == "busy":
        raise RateLimited("开放平台限流，稍后再试", 5)
    return f"a{next(_tokens)}"


class OpenDrive(DriveBackend):
    type = "open"
    title = "开放盘"
    capabilities = Capabilities(writable=True, default_qps=50.0)
    login = Login(form=Credentials, hint="在开放平台申请 Client ID 与 Client Secret")

    async def login_with_form(self, values):
        creds = Credentials.model_validate(values)
        token = _token(creds)
        return LoginResult(
            user_id=f"uid-{creds.client_id}",
            display_name=f"开放盘 {creds.client_id}",
            credentials={
                "client_id": creds.client_id,
                "client_secret": creds.client_secret.get_secret_value(),
                "access_token": token,
            },
        )

    async def account_info(self, account):
        creds = account.credentials
        if creds["access_token"] == "expired":
            # 令牌过期：拿长期密钥重新换一个，交回宿主落库
            fresh = _token(Credentials.model_validate(creds))
            account.credentials = {**creds, "access_token": fresh}
        return AccountInfo(display_name="开放盘", quota_total=100, quota_used=1)


@plugin("open-drive", title="开放盘")
async def apply(ctx) -> None:
    ctx.contribute(DRIVE_BACKENDS, "open", OpenDrive())
"""


@pytest.fixture(params=["inline", "process"])
def client(request, tmp_path, monkeypatch):
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.services.drives import gateway
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'drives.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    gateway.reset_state()
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "open_drive.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: open-drive
              local: true
              module: open_drive
              runtime: {request.param}
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as test_client:
        assert test_client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
        yield test_client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def _credentials(client: TestClient, account_id: int) -> dict[str, str]:
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository

    async def load():
        async with get_database().session() as session:
            row = await DriveAccountRepository(session).get(account_id)
            return DriveAccountRepository.credentials(row)

    return client.portal.call(load)  # type: ignore[attr-defined]


def _set_credentials(client: TestClient, account_id: int, creds: dict[str, str]) -> None:
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository

    async def save():
        async with get_database().session() as session:
            await DriveAccountRepository(session).save_credentials(account_id, creds)

    client.portal.call(save)  # type: ignore[attr-defined]


def _form_login(client: TestClient, values: dict, relogin: int | None = None):
    body: dict = {"backend": "open", "values": values}
    if relogin is not None:
        body["relogin"] = relogin
    return client.post("/api/v1/drives/accounts/form", json=body)


def test_form_schema_reaches_the_ui(client) -> None:
    [backend] = client.get("/api/v1/drives/backends").json()["data"]
    login = backend["login"]
    assert login["scan"] is False and login["cookie"] is False
    form = login["form"]
    assert form["required"] == ["client_id", "client_secret"]
    props = form["properties"]
    assert list(props) == ["client_id", "client_secret", "region"]
    assert props["client_id"] == {"type": "string", "title": "Client ID"}
    # 密钥按密码框画，不带默认值
    assert props["client_secret"]["writeOnly"] is True
    assert props["client_secret"]["format"] == "password"
    assert props["region"]["default"] == "cn"


def test_form_login_creates_the_account_with_the_real_user_id(client, caplog) -> None:
    caplog.set_level(logging.DEBUG)
    created = _form_login(
        client, {"client_id": " app1 ", "client_secret": f"{SECRET}\n", "region": "cn"}
    )
    assert created.status_code == 201, created.text
    data = created.json()["data"]
    account = data["account"]
    assert data["status"] == "confirmed" and data["created"] is True
    assert account["name"] == "开放盘 app1"
    assert account["login_method"] == "form" and account["login_detail"] is None
    # 首尾空白去掉了（粘贴密钥常带换行）；登录后读资料没换令牌
    creds = _credentials(client, account["id"])
    assert creds["client_id"] == "app1" and creds["client_secret"] == SECRET
    assert creds["access_token"].startswith("a")

    # 同一个网盘用户再填一次：更新原账号，不新建
    again = _form_login(client, {"client_id": "app1", "client_secret": SECRET})
    assert again.status_code == 201, again.text
    assert again.json()["data"]["created"] is False
    assert again.json()["data"]["account"]["id"] == account["id"]
    assert len(client.get("/api/v1/drives/accounts").json()["data"]) == 1

    # 密钥不出现在任何接口返回与主进程日志里
    listed = json.dumps(client.get("/api/v1/drives/accounts").json())
    assert SECRET not in listed and SECRET not in created.text
    assert all(SECRET not in r.getMessage() for r in caplog.records)


def test_form_values_are_checked_before_the_plugin(client) -> None:
    missing = _form_login(client, {"client_id": "app1", "client_secret": "  "})
    assert missing.status_code == 400 and "请填写：Client Secret" in missing.text
    unknown = _form_login(client, {"client_id": "app1", "client_secret": "x", "token": "t"})
    assert unknown.status_code == 400 and "没有这些字段：token" in unknown.text
    wrong = _form_login(client, {"client_id": "app1", "client_secret": "wrong"})
    assert wrong.status_code == 400 and "开放盘没认这组凭据：clientSecret 不对" in wrong.text
    # 限流不是凭据不对：原样报限流
    busy = _form_login(client, {"client_id": "app1", "client_secret": "busy"})
    assert busy.status_code == 400 and "开放平台限流" in busy.text and "没认" not in busy.text
    assert client.get("/api/v1/drives/accounts").json()["data"] == []
    nope = client.post(
        "/api/v1/drives/accounts/form", json={"backend": "nope", "values": {"client_id": "x"}}
    )
    assert nope.status_code == 409


def test_relogin_must_be_the_same_drive_user(client) -> None:
    first = _form_login(client, {"client_id": "app1", "client_secret": SECRET})
    account_id = first.json()["data"]["account"]["id"]

    other = _form_login(client, {"client_id": "app2", "client_secret": SECRET}, relogin=account_id)
    assert other.status_code == 400
    assert "登录的是另一个账号（开放盘 app2），不是「开放盘 app1」" in other.text
    assert len(client.get("/api/v1/drives/accounts").json()["data"]) == 1

    rotated = {"client_id": "app1", "client_secret": "rotated"}
    same = _form_login(client, rotated, relogin=account_id)
    assert same.status_code == 201, same.text
    assert same.json()["data"]["account"]["id"] == account_id
    assert _credentials(client, account_id)["client_secret"] == "rotated"

    gone = _form_login(client, {"client_id": "app1", "client_secret": SECRET}, relogin=9999)
    assert gone.status_code == 400 and "已经不在了" in gone.text


def test_expired_token_is_renewed_with_the_long_lived_secret(client) -> None:
    created = _form_login(client, {"client_id": "app1", "client_secret": SECRET})
    account_id = created.json()["data"]["account"]["id"]
    creds = _credentials(client, account_id)
    _set_credentials(client, account_id, {**creds, "access_token": "expired"})

    refreshed = client.post(f"/api/v1/drives/accounts/{account_id}/refresh")
    assert refreshed.status_code == 200, refreshed.text
    renewed = _credentials(client, account_id)
    assert renewed["access_token"] not in ("expired", creds["access_token"])
    assert renewed["client_secret"] == SECRET
    assert refreshed.json()["data"]["status"] == "ok"


class _Form(BaseModel):
    app_id: str = Field(title="App ID")
    secret: SecretStr = Field(title="密钥")


class _Nested(BaseModel):
    extra: dict[str, str]


def test_form_schema_survives_the_process_boundary() -> None:
    class Backend(dv.DriveBackend):
        type = "x"
        title = "X"
        login = dv.Login(form=_Form)

    spec = dv.backend_spec(Backend())
    schema = spec["login"]["form"]
    assert schema["properties"]["secret"]["writeOnly"] is True
    # 宿主这边拿到的是 dict，原样还原
    _caps, login = dv.spec_parts(json.loads(json.dumps(spec)))
    assert dv.form_schema(login) == schema
    assert dv.form_schema(dv.Login()) is None


def test_unrenderable_form_does_not_break_the_backend_list() -> None:
    from movieclaw_api.api.routes.drives import _backend_view

    class Backend(dv.DriveBackend):
        type = "bad"
        title = "坏表单"
        login = dv.Login(form=_Nested)

    view = _backend_view(Backend())
    assert view.login.form is None and view.title == "坏表单"
