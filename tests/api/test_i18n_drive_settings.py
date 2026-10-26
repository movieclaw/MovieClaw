"""Drive configuration keeps machine state and raw upstream text across reader locales."""

from copy import deepcopy

from tests.api.test_drive_form_login import client as form_client  # noqa: F401
from tests.api.test_drives import client as scan_client  # noqa: F401


def test_form_errors_and_limit_updates_follow_each_http_request(form_client):  # noqa: F811
    client = form_client
    payload = {"backend": "open", "values": {"client_id": "app1", "client_secret": ""}}
    for locale, expected in [
        ("en", "Enter: Client Secret"),
        ("zh-Hans", "请填写：Client Secret"),
        ("en", "Enter: Client Secret"),
    ]:
        response = client.post(
            "/api/v1/drives/accounts/form", json=payload, headers={"Accept-Language": locale}
        )
        assert response.status_code == 400
        assert response.json()["message"] == expected
        assert response.json()["message_key"] == "errors.driveLogin.requiredFields"
    rejected = client.post(
        "/api/v1/drives/accounts/form",
        json={"backend": "open", "values": {"client_id": "app1", "client_secret": "wrong"}},
        headers={"Accept-Language": "en"},
    )
    assert rejected.status_code == 400
    # The plugin's unknown Chinese detail is intentionally retained.
    assert rejected.json()["message"] == "开放盘 rejected these credentials: clientSecret 不对"
    from tests.api.test_drive_form_login import SECRET, _credentials, _form_login

    created = _form_login(client, {"client_id": "app1", "client_secret": SECRET})
    assert created.status_code == 201, created.text
    account_id = created.json()["data"]["account"]["id"]
    before = _credentials(client, account_id)
    for field, value, key, english, chinese in [
        ("name", " ", "nameRequired", "Account name is required", "账号名不能为空"),
        (
            "qps",
            0,
            "invalidRate",
            "Request rate must be between 0.1 and 20 requests per second",
            "请求速率要在 0.1～20 次 / 秒之间",
        ),
        (
            "daily_budget",
            99,
            "invalidBudget",
            "Daily budget must be between 100 and 1,000,000 requests",
            "每日预算要在 100～1,000,000 次之间",
        ),
        (
            "read_slots",
            11,
            "invalidSlots",
            "Concurrent streams must be between 1 and 10",
            "同时播放数要在 1～10 之间",
        ),
    ]:
        for locale, expected in [("en", english), ("zh-Hans", chinese), ("en", english)]:
            response = client.patch(
                f"/api/v1/drives/accounts/{account_id}",
                json={field: value},
                headers={"Accept-Language": locale},
            )
            assert response.status_code == 400
            assert response.json()["message"] == expected
            assert response.json()["message_key"] == "errors.driveLogin." + key
    assert _credentials(client, account_id) == before


def test_login_snapshot_renders_owned_expiry_and_preserves_unknown_plugin_text(scan_client):  # noqa: F811
    from tests.api.test_drives import call

    from movieclaw_api.services.drives import accounts

    async def seed():
        item = accounts.LoginSession("i18n-qr", "fake", "fixture", None, expires_at=0)
        accounts._logins[item.login_id] = item
        return item

    item = call(scan_client, seed)
    for locale, message in [
        ("en", "The QR code has expired. Scan a new code."),
        ("zh-Hans", "二维码已过期，请重新扫码"),
        ("en", "The QR code has expired. Scan a new code."),
    ]:
        response = scan_client.get(
            "/api/v1/drives/logins/i18n-qr", headers={"Accept-Language": locale}
        )
        assert response.status_code == 200
        assert response.json()["data"]["status"] == "expired"
        assert response.json()["data"]["message"] == message
        assert item.message == "二维码已过期，请重新扫码"
    original = deepcopy(item.message_ref)
    assert original["message_key"] == "errors.driveLogin.qrExpired"

    async def upstream():
        item.message, item.message_ref = "上游原文，不猜译", None

    call(scan_client, upstream)
    assert (
        scan_client.get("/api/v1/drives/logins/i18n-qr", headers={"Accept-Language": "en"}).json()[
            "data"
        ]["message"]
        == "上游原文，不猜译"
    )


def test_drive_schema_is_localized_after_process_serialization_without_mutation():
    import json

    from pydantic import BaseModel, Field, SecretStr

    from movieclaw_api.api.routes.drives import _backend_view
    from movieclaw_api.i18n import use_locale
    from movieclaw_sdk import drives as dv

    class Credentials(BaseModel):
        secret: SecretStr = Field(
            title="密钥", json_schema_extra={"title_localized": {"en": "Secret"}}
        )

    class Backend(dv.DriveBackend):
        type = "fixture"
        login = dv.Login(form=Credentials)

    spec = json.loads(json.dumps(dv.backend_spec(Backend())))
    _, login = dv.spec_parts(spec)
    backend = Backend()
    backend.login = login
    original = deepcopy(login.form)
    for locale, expected in [("en", "Secret"), ("zh-Hans", "密钥"), ("en", "Secret")]:
        with use_locale(locale):
            schema = _backend_view(backend).login.form
        assert schema["properties"]["secret"]["title"] == expected
        assert schema["properties"]["secret"]["writeOnly"]
        assert login.form == original
