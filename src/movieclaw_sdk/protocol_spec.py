"""插件协议的 OpenAPI 文档（docs/design/plugin-ipc-http.md §9）。

两份文档都从代码生成，``python -m movieclaw_sdk.protocol_spec --write`` 刷新，
测试守护「文档与代码一致」：

- ``protocol/gateway.json``：插件调宿主——宿主网关上的运行时接口，
  按 ``movieclaw_sdk.services`` 的契约逐个方法列出；
- ``protocol/control.json``：宿主调插件——插件要实现的控制端点、引导行与 ``--describe`` 输出的格式。

非 Python 插件照这两份文档实现即可（Go 示例见插件开发技能的 ``examples/go-a2a-bridge``）。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field, TypeAdapter

from movieclaw_sdk import rpc
from movieclaw_sdk.services import SERVICES

DIRECTORY = Path(__file__).resolve().parent / "protocol"
REF = "#/components/schemas/{model}"


class _Schemas:
    """收集各处 JSON Schema 里的 ``$defs``，统一放进 components。"""

    def __init__(self) -> None:
        self.components: dict[str, Any] = {}

    def of(self, adapter: TypeAdapter[Any]) -> dict[str, Any]:
        schema = adapter.json_schema(ref_template=REF)
        self.components.update(schema.pop("$defs", {}))
        return schema

    def model(self, cls: type[BaseModel]) -> dict[str, Any]:
        self.components[cls.__name__] = self.of(TypeAdapter(cls))
        return {"$ref": REF.format(model=cls.__name__)}


class ErrorBody(BaseModel):
    code: str = Field(
        description="错误码（如 PERMISSION_DENIED、AGENT_BUSY），两端按它还原成同一种异常"
    )
    message: str


class Bootstrap(BaseModel):
    """宿主拉起插件后往 stdin 写的一行 JSON（之后 stdin 关闭）。"""

    entry_id: str
    config: dict[str, Any] = Field(description="插件配置（清单配置叠上界面设置）")
    data_dir: str
    gateway: str = Field(description="宿主网关的 Unix 套接字路径")
    token: str = Field(description="插件令牌（Bearer），只在网关上有效")


class Describe(BaseModel):
    """``<插件> --describe`` 在 stdout 输出的最后一行 JSON。"""

    type: str = "describe"
    title: str
    inject: list[str] = Field(description="要用的服务（如 agent、plugin-routes、plugin-data）")
    permissions: list[str] = Field(description="申请的授权（宿主操作 id、agent:<档位>）")
    config: dict[str, Any] | None = Field(default=None, description="配置表单（JSON Schema 子集）")


class CallBody(BaseModel):
    payload: Any = Field(description="载荷：事件 / 钩子按契约的载荷模型，其余按各贡献项约定")
    job_id: str | None = Field(default=None, description="任务处理器：宿主侧的任务编号")
    delivery: dict[str, Any] | None = Field(default=None, description="可靠事件的投递信息")


class CallReply(BaseModel):
    """处理结果信封：插件处理失败也是 200，宿主按 ``error_kind`` / ``job`` 还原异常。"""

    ok: bool
    result: Any = None
    error: str | None = None
    error_kind: str | None = None
    job: dict[str, Any] | None = None


class Cancel(BaseModel):
    call: str = Field(description="要体面停止的调用号")


def _json(schema: dict[str, Any]) -> dict[str, Any]:
    return {"application/json": {"schema": schema}}


def gateway() -> dict[str, Any]:
    schemas = _Schemas()
    error = schemas.model(ErrorBody)
    paths: dict[str, Any] = {}
    for service, contract in sorted(SERVICES.items()):
        for name, spec in sorted(rpc.methods(contract).items()):
            properties = {p.name: schemas.of(p.adapter) for p in spec.params}
            required = [p.name for p in spec.params if p.required]
            body: dict[str, Any] = {"type": "object", "properties": properties}
            if required:
                body["required"] = required
            result = schemas.of(spec.returns) if spec.returns is not None else {"type": "null"}
            if spec.stream:
                line = {
                    "type": "object",
                    "description": "一行一个：{v: 元素}；出错以 {error: …} 结束",
                    "properties": {"v": result, "error": error},
                }
                ok = {rpc.NDJSON: {"schema": line}}
            else:
                ok = _json(result)
            paths[f"/api/v1/plugin-runtime/{service}/{name}"] = {
                "post": {
                    "operationId": f"{service}.{name}",
                    "tags": [service],
                    "summary": spec.doc or f"{service}.{name}",
                    "requestBody": {"required": True, "content": _json(body)},
                    "responses": {
                        "200": {"description": "流式" if spec.stream else "返回值", "content": ok},
                        "4XX": {
                            "description": "参数不对、没有授权、不存在",
                            "content": _json(error),
                        },
                        "5XX": {"description": "服务出错", "content": _json(error)},
                    },
                }
            }
    return {
        "openapi": "3.1.0",
        "info": {
            "title": "MovieClaw 插件网关（插件调宿主）",
            "version": "1",
            "description": (
                "HTTP/1.1 over Unix 套接字（引导行的 gateway）。"
                "每个请求带 Authorization: Bearer <token>；"
                "处理宿主调用期间发出的请求还要原样带上 X-MovieClaw-Call。"
                "宿主操作直接请求 /api/v1/… 原接口。"
            ),
        },
        "paths": paths,
        "components": {
            "schemas": dict(sorted(schemas.components.items())),
            "securitySchemes": {"plugin": {"type": "http", "scheme": "bearer"}},
        },
        "security": [{"plugin": []}],
    }


def control() -> dict[str, Any]:
    schemas = _Schemas()
    call = schemas.model(CallBody)
    reply = schemas.model(CallReply)
    cancel = schemas.model(Cancel)
    schemas.model(Bootstrap)
    schemas.model(Describe)
    header = {
        "name": rpc.CALL_HEADER,
        "in": "header",
        "required": True,
        "description": "调用号：处理这次调用期间发给网关的请求原样带上",
        "schema": {"type": "string"},
    }
    return {
        "openapi": "3.1.0",
        "info": {
            "title": "MovieClaw 插件控制服务（宿主调插件）",
            "version": "1",
            "description": (
                "插件在 --listen-fd 交来的套接字上起 HTTP/1.1 服务"
                "（只在有监听器、贡献项、回调或路由时起）；"
                "插件路由挂在同一个服务的 /api/v1/plugins/<条目 id>/… 下。"
                "超时、宿主取消 = 断开连接，插件应随之取消处理。"
                "启动：stdin 一行 Bootstrap；声明：--describe 输出 Describe；释放：SIGTERM。"
            ),
        },
        "paths": {
            "/_mc/{kind}/{target}": {
                "post": {
                    "operationId": "call",
                    "summary": "调用插件导出的一个目标",
                    "parameters": [
                        {
                            "name": "kind",
                            "in": "path",
                            "required": True,
                            "schema": {
                                "type": "string",
                                "enum": [
                                    "listener",
                                    "job",
                                    "scheduled-task",
                                    "callback",
                                    "channel",
                                    "downloader",
                                    "delete-preview",
                                ],
                            },
                        },
                        {
                            "name": "target",
                            "in": "path",
                            "required": True,
                            "description": "就绪时声明的监听器 id / 贡献项 id / 回调端点名",
                            "schema": {"type": "string"},
                        },
                        header,
                    ],
                    "requestBody": {"required": True, "content": _json(call)},
                    "responses": {"200": {"description": "结果信封", "content": _json(reply)}},
                }
            },
            "/_mc/cancel": {
                "post": {
                    "operationId": "cancel",
                    "summary": "体面停止一次调用（先置停止信号，宽限期后强制取消；原请求照常回复）",
                    "requestBody": {"required": True, "content": _json(cancel)},
                    "responses": {"200": {"description": "已收到"}},
                }
            },
        },
        "components": {"schemas": dict(sorted(schemas.components.items()))},
    }


def documents() -> dict[str, dict[str, Any]]:
    return {"gateway.json": gateway(), "control.json": control()}


def render(document: dict[str, Any]) -> str:
    return json.dumps(document, ensure_ascii=False, indent=2) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="生成插件协议的 OpenAPI 文档")
    parser.add_argument("--write", action="store_true", help="写进 movieclaw_sdk/protocol/")
    args = parser.parse_args(argv)
    for name, document in documents().items():
        if args.write:
            DIRECTORY.mkdir(exist_ok=True)
            (DIRECTORY / name).write_text(render(document), encoding="utf-8")
            print(f"已写入 {DIRECTORY / name}")
        else:
            sys.stdout.write(render(document))
    return 0


if __name__ == "__main__":
    sys.exit(main())
