"""查一个接口长什么样：方法、地址、参数、返回字段（读服务器自带的 OpenAPI 文档）。

    python api.py library.items.list         # operationId
    python api.py library items list         # 或者 mclaw 命令（空格分隔）

写插件网页时用：网页里 fetch 的地址、查询参数名（命令行的 --res 在地址里是 res，连字符换下划线）、
返回的 data 里有哪些字段。数据为空、命令输出看不出字段时，以这里为准。
地址与参数取自服务器导出的 OpenAPI 文档（spec.json），返回字段取自接口的响应模型（文档里的响应
只剩字段名、没有类型），都在本机读，不用登录。
"""

from __future__ import annotations

import sys
from typing import Any

MAX_DEPTH = 3


def _resolve(spec: dict[str, Any], schema: dict[str, Any]) -> dict[str, Any]:
    while "$ref" in schema:
        name = schema["$ref"].rsplit("/", 1)[-1]
        schema = (spec.get("$defs") or spec["components"]["schemas"])[name]
    return schema


def _admin_only(effective: Any) -> bool:
    """路由（含所在路由组，取生效后的依赖）挂了管理员依赖：成员调用一律 403。"""
    from movieclaw_api.api.deps import require_admin, require_admin_session

    def walk(dependant: Any) -> bool:
        return any(
            d.call in (require_admin, require_admin_session) or walk(d) for d in dependant.dependencies
        )

    return walk(effective.dependant)


def _response_schema(operation_id: str) -> tuple[dict[str, Any] | None, bool]:
    """接口返回的 data 的结构：在进程里读路由表，和 iOS 生成器（apps/apple/scripts/gen_api.py）一个办法。

    用「校验」模式出 schema：本项目的模型在序列化模式下类型会丢（导出的 OpenAPI 因此也缺类型）。
    """
    import logging

    logging.disable(logging.CRITICAL)
    from fastapi.routing import APIRoute, _iter_routes_with_context
    from pydantic import TypeAdapter

    from movieclaw_api.app import create_app
    from movieclaw_api.schemas.response import ApiResponse

    for route, effective in _iter_routes_with_context(create_app().routes):
        if isinstance(route, APIRoute) and route.operation_id == operation_id:
            admin = _admin_only(effective)
            model = route.response_model
            if model is None:
                return None, admin
            meta = getattr(model, "__pydantic_generic_metadata__", None) or {}
            if meta.get("origin") is ApiResponse and meta.get("args"):
                return TypeAdapter(meta["args"][0]).json_schema(mode="validation"), admin
            return TypeAdapter(model).json_schema(mode="validation"), admin
    return None, False


def _type(spec: dict[str, Any], schema: dict[str, Any]) -> str:
    schema = _resolve(spec, schema)
    options = schema.get("anyOf") or schema.get("oneOf")
    if options:
        names = [_type(spec, o) for o in options]
        nullable = "null" in names
        names = [n for n in names if n != "null"]
        return " | ".join(names) + ("（可为 null）" if nullable else "")
    if schema.get("enum"):
        return " / ".join(map(str, schema["enum"]))
    kind = schema.get("type", "object")
    if kind == "object" and schema.get("properties") and schema.get("title"):
        return str(schema["title"])
    if kind == "array":
        return f"{_type(spec, schema.get('items', {}))}[]"
    if kind == "string" and schema.get("format"):
        return f"string（{schema['format']}）"
    return str(kind)


def _fields(spec: dict[str, Any], schema: dict[str, Any], indent: int, depth: int) -> None:
    schema = _resolve(spec, schema)
    options = [o for o in (schema.get("anyOf") or []) if _resolve(spec, o).get("type") != "null"]
    if options:
        schema = _resolve(spec, options[0])
    if schema.get("type") == "array":
        schema = _resolve(spec, schema.get("items", {}))
    for name, prop in (schema.get("properties") or {}).items():
        resolved = _resolve(spec, prop)
        note = resolved.get("description") or prop.get("description") or ""
        print(f"{'  ' * indent}{name}: {_type(spec, prop)}{('  # ' + note.splitlines()[0]) if note else ''}")
        inner = resolved
        sub = [o for o in (inner.get("anyOf") or []) if _resolve(spec, o).get("type") != "null"]
        if sub:
            inner = _resolve(spec, sub[0])
        if inner.get("type") == "array":
            inner = _resolve(spec, inner.get("items", {}))
        if inner.get("properties") and depth < MAX_DEPTH:
            _fields(spec, inner, indent + 1, depth + 1)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    wanted = argv[0] if len(argv) == 1 else ".".join(argv)
    from movieclaw_api.services.spec_catalog import load_spec

    spec = load_spec()
    for path, methods in spec["paths"].items():
        for method, op in methods.items():
            if op.get("operationId") != wanted:
                continue
            print(f"{method.upper()} {path}")
            print(op.get("summary", ""))
            params = [p for p in op.get("parameters", []) if p.get("in") in ("query", "path")]
            for p in params:
                required = "，必填" if p.get("required") else ""
                print(f"  {p['in']} 参数 {p['name']}：{_type(spec, p.get('schema', {}))}{required}")
            body = op.get("requestBody", {}).get("content", {}).get("application/json")
            if body:
                print("请求体（JSON）：")
                _fields(spec, body["schema"], 1, 1)
            data, admin = _response_schema(wanted)
            print(
                "权限：仅管理员（成员打开页面时调它会 403）"
                if admin
                else "权限：登录即可；成员还要看能力开关（订阅要「允许订阅」、搜索要「允许搜索」），不满足时 403"
            )
            if data:
                print("返回（外层是 {success, code, message, data}，下面是 data）：")
                print(f"  data: {_type(data, data)}")
                _fields(data, data, 2, 1)
            return 0
    print(f"✗ 没有 operationId 为 {wanted} 的接口；先用 mclaw <域> --help 找到命令，命令名按空格就是它")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
