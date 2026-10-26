"""插件协议的 OpenAPI 文档与代码一致（docs/design/plugin-ipc-http.md §9）。

文档是非 Python 插件照着实现的依据，必须跟着契约走：改了契约就要
``python -m movieclaw_sdk.protocol_spec --write`` 刷新后一起提交。
"""

from __future__ import annotations

import inspect
import json

from movieclaw_sdk import protocol_spec, rpc
from movieclaw_sdk.runner import Runner
from movieclaw_sdk.services import SERVICES

HINT = "插件协议文档与代码不一致：运行 python -m movieclaw_sdk.protocol_spec --write 后一起提交"


def test_documents_match_the_code() -> None:
    for name, document in protocol_spec.documents().items():
        committed = json.loads((protocol_spec.DIRECTORY / name).read_text(encoding="utf-8"))
        assert committed == json.loads(protocol_spec.render(document)), f"{name}：{HINT}"


def test_every_contract_method_is_documented() -> None:
    paths = protocol_spec.gateway()["paths"]
    for service, contract in SERVICES.items():
        for method in rpc.methods(contract):
            assert f"/api/v1/plugin-runtime/{service}/{method}" in paths


def test_documented_call_kinds_are_the_ones_the_runner_handles() -> None:
    """控制服务文档里的 kind 与运行器 _handle_call 的分发表一致（listener 是监听器本身）。"""
    path = protocol_spec.control()["paths"]["/_mc/{kind}/{target}"]["post"]
    documented = set(path["parameters"][0]["schema"]["enum"])
    source = inspect.getsource(Runner._handle_call)
    handled = {kind for kind in documented - {"listener"} if f'"{kind}"' in source}
    assert documented - {"listener"} == handled
