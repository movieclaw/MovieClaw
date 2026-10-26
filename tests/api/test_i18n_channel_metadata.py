"""Declared channel metadata survives both plugin runtimes without changing source facts."""

import copy
import json
import sys
import textwrap

import pytest
from sqlalchemy import text

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_db.engine import get_database
from movieclaw_sdk import channels as ch

from .test_channels_api import make_client


def test_legacy_channel_wire_and_positional_constructors_remain_unchanged():
    class Legacy(ch.ChannelDriver):
        title = "作者原名"
        binding = ch.Binding.form((ch.FormField("token", "令牌", True, "原占位", "原说明", False),))

    assert ch.driver_spec(Legacy()) == {
        "title": "作者原名",
        "description": "",
        "capabilities": {
            "receive": True,
            "photo": False,
            "typing": False,
            "max_text_len": 2000,
            "webhook": False,
        },
        "binding": {
            "kind": "form",
            "pairing": "none",
            "hint": "",
            "fields": [
                {
                    "key": "token",
                    "label": "令牌",
                    "secret": True,
                    "placeholder": "原占位",
                    "help": "原说明",
                    "required": False,
                },
            ],
        },
    }
    state = ch.FlowState("flow", "pending", "原消息", "raw-qr", "原输入", None)
    assert ch.flow_dict(state) == {
        "flow_id": "flow",
        "status": "pending",
        "message": "原消息",
        "qr": "raw-qr",
        "input_label": "原输入",
        "result": None,
    }
    assert ch.flow_from(ch.flow_dict(state)) == state
    assert ch.spec_parts(ch.driver_spec(Legacy()))[1] == Legacy.binding


def test_localized_wire_copies_nested_maps_in_both_directions():
    class Driver(ch.ChannelDriver):
        title_localized = {"en": {"value": "Author title", "lang": "en", "dir": "ltr"}}
        description_localized = {"en": "Description"}
        binding = ch.Binding.form(
            (
                ch.FormField(
                    "key",
                    "标签",
                    label_localized={
                        "en": {"value": "Label", "lang": "en"},
                    },
                ),
            ),
            hint="提示",
            hint_localized={"en": "Hint"},
        )

    source = copy.deepcopy(ch.driver_spec(Driver()))
    wire = ch.driver_spec(Driver())
    wire["title_localized"]["en"]["value"] = "Changed"
    wire["binding"]["fields"][0]["label_localized"]["en"]["value"] = "Changed"
    assert ch.driver_spec(Driver()) == source
    inbound = json.loads(json.dumps(source))
    _, binding = ch.spec_parts(inbound)
    binding.fields[0].label_localized["en"]["value"] = "Host change"
    assert inbound == source
    state = ch.FlowState(
        "flow",
        "need_input",
        message_localized={
            "en": {"value": "Ready", "lang": "en"},
        },
        input_label_localized={"en": "Code"},
    )
    flow = ch.flow_dict(state)
    restored = ch.flow_from(flow)
    restored.message_localized["en"]["value"] = "Changed"
    assert ch.flow_dict(state) == flow
    flow["message_localized"]["en"]["value"] = "Wire change"
    assert state.message_localized["en"]["value"] == "Ready"


PLUGIN = """
from movieclaw_sdk import plugin
from movieclaw_sdk.channels import (
    IM_CHANNELS, Binding, BindResult, Capabilities,
    ChannelDriver, ChannelInputError, FlowState, FormField,
)

class Form(ChannelDriver):
    title = "作者通道"
    title_localized = {"en": {"value": "Author channel", "lang": "en", "dir": "ltr"}}
    description = "作者说明"
    description_localized = {"en": "Author description"}
    capabilities = Capabilities(receive=False)
    binding = Binding.form((FormField(
        "secret", "私有凭据", secret=True, placeholder="填写凭据", help="保留此字段",
        label_localized={"en": "Private credential"},
        placeholder_localized={"en": "Enter credential"}, help_localized={"en": "Keep this field"},
    ),), hint="作者提示", hint_localized={"en": "Author hint"})
    async def validate(self, fields):
        if fields["secret"] == "bad":
            raise ChannelInputError("凭据不正确", message_localized={"en": "Incorrect credential"})
        if fields["secret"] == "unknown":
            raise ValueError("作者未知原因")
        return BindResult("account-1", "用户名称", {"secret": fields["secret"]})

class Flow(ChannelDriver):
    title = "流程原名"
    capabilities = Capabilities(receive=False)
    binding = Binding.flow(hint="原流程提示", hint_localized={"en": "Flow hint"})
    state = FlowState("flow-1", "need_input", "等待手机输入", "https://qr.invalid/原码",
                      "手机数字", message_localized={"en": "Waiting for phone input"},
                      input_label_localized={"en": "Phone digits"})
    async def begin_flow(self, accounts):
        self.state = type(self).state
        return self.state
    async def flow_state(self, flow_id):
        return self.state
    async def flow_input(self, flow_id, value):
        if value == "missing":
            self.state = FlowState(
                flow_id, "confirmed", "不会展示", message_localized={"en": "Stale"},
            )
        elif value == "raw":
            self.state = FlowState(flow_id, "need_input", "第三方未知原文", input_label="未知输入")
        else:
            self.state = FlowState(flow_id, "confirmed", "已确认",
                result=BindResult("flow-account", "用户流程名称", {"secret": value}),
                message_localized={"en": "Confirmed"})
        return self.state

@plugin("metadata-channel", title="Metadata fixture")
async def apply(ctx):
    ctx.contribute(IM_CHANNELS, "form", Form())
    ctx.contribute(IM_CHANNELS, "flow", Flow())
"""


@pytest.fixture(params=["inline", "process"])
def world(request, tmp_path, monkeypatch):
    for name, value in {
        "DATABASE_URL": f"sqlite+aiosqlite:///{tmp_path / 'channels.db'}",
        "SECRET_KEY_FILE": str(tmp_path / ".secret_key"),
        "SITE_CONFIGS_DIR": str(tmp_path / "sites"),
        "MOVIECLAW_DATA_DIR": str(tmp_path),
        "SCHEDULER_ENABLED": "false",
    }.items():
        monkeypatch.setenv(name, value)
    get_settings.cache_clear()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins/metadata_channel.py").write_text(textwrap.dedent(PLUGIN))
    (tmp_path / "plugins.yaml").write_text(
        "- id: metadata-channel\n  local: true\n  module: metadata_channel\n"
        f"  runtime: {request.param}\n"
    )
    yield request.param
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    get_settings.cache_clear()


def test_real_plugin_metadata_and_flow_are_projected_for_each_reader(world):
    with make_client() as client:
        assert client.app.state.kernel.fiber("metadata-channel").state.value == "active"

        def data(path, language):
            response = client.get(path, headers={"Accept-Language": language})
            assert response.status_code == 200, response.text
            return response.json()["data"]

        def channels(language):
            return {
                c["id"].split(":")[-1]: c
                for c in data("/api/v1/channels", language)["channels"]
                if c["entry_id"] == "metadata-channel"
            }

        en, zh, again = [channels(locale) for locale in ("en", "zh-Hans", "en")]
        assert en == again
        assert en["form"]["id"] == zh["form"]["id"]
        assert en["form"]["title"] == "Author channel"
        assert en["form"]["description"] == "Author description"
        assert en["form"]["binding"]["hint"] == "Author hint"
        field = en["form"]["binding"]["fields"][0]
        assert field == {
            "key": "secret",
            "label": "Private credential",
            "secret": True,
            "placeholder": "Enter credential",
            "help": "Keep this field",
            "required": True,
        }
        assert zh["form"]["title"] == "作者通道"
        assert zh["form"]["binding"]["fields"][0]["label"] == "私有凭据"
        assert en["flow"]["title"] == zh["flow"]["title"] == "流程原名"

        for value, english, chinese in [
            ("bad", "Incorrect credential", "凭据不正确"),
            ("unknown", "作者未知原因", "作者未知原因"),
        ]:
            for locale, expected in [("en", english), ("zh-Hans", chinese), ("en", english)]:
                invalid = client.post(
                    "/api/v1/channels/bindings",
                    json={
                        "channel_id": en["form"]["id"],
                        "fields": {"secret": value},
                    },
                    headers={"Accept-Language": locale},
                )
                assert invalid.status_code == 400, invalid.text
                assert invalid.json()["message"] == expected

        response = client.post(
            "/api/v1/channels/bindings",
            json={
                "channel_id": en["flow"]["id"],
            },
            headers={"Accept-Language": "en"},
        )
        assert response.status_code == 201, response.text
        path = "/api/v1/channels/bindings/" + response.json()["data"]["binding_id"]
        snapshots = [data(path, locale) for locale in ("en", "zh-Hans", "en")]
        assert snapshots[0] == snapshots[2]
        assert snapshots[0]["message"] == "Waiting for phone input"
        assert snapshots[1]["message"] == "等待手机输入"
        assert snapshots[0]["input_label"] == "Phone digits"
        assert snapshots[1]["input_label"] == "手机数字"
        assert snapshots[0]["qr"] == snapshots[1]["qr"] == "https://qr.invalid/原码"
        assert snapshots[0]["qr_image"] == snapshots[1]["qr_image"]
        assert "message_ref" not in snapshots[0]

        client.post(path + "/input", json={"value": "raw"})
        assert data(path, "en")["message"] == "第三方未知原文"
        assert data(path, "en")["input_label"] == "未知输入"
        done = client.post(
            path + "/input", json={"value": "原始凭据"}, headers={"Accept-Language": "en"}
        )
        assert done.status_code == 200, done.text
        assert done.json()["data"]["message"] == "Confirmed"
        assert data(path, "zh-Hans")["message"] == "已确认"
        assert done.json()["data"]["input_label"] is None
        assert done.json()["data"]["account"]["display_name"] == "用户流程名称"

        async def stored():
            async with get_database().session() as session:
                return (await session.execute(text("SELECT * FROM channel_account"))).all()

        before = client.portal.call(stored)
        for locale in ("en", "zh-Hans", "en"):
            data(path, locale)
            channels(locale)
        assert client.portal.call(stored) == before
        assert "原始凭据" not in repr(before)

        second = client.post("/api/v1/channels/bindings", json={"channel_id": en["flow"]["id"]})
        path2 = "/api/v1/channels/bindings/" + second.json()["data"]["binding_id"]
        client.post(path2 + "/input", json={"value": "missing"})
        assert data(path2, "en")["message"] == "The linking result is missing. Start again"
        assert data(path2, "zh-Hans")["message"] == "绑定结果缺失，请重新发起"
        assert data(path2, "en")["status"] == "failed"
