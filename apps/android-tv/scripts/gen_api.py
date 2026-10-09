"""从后端路由与 Pydantic 模型生成 Android TV 端的 Kotlin 数据模型与接口函数。

思路同 apps/apple/scripts/gen_api.py：FastAPI 导出的 OpenAPI 里字段类型会丢，
所以在进程内读路由表 + Pydantic json schema。与 Apple 端不同的是**只生成白名单里的接口**
（ENDPOINTS），以及它们传递引用到的模型——TV 只用得到其中一小部分。

产物（覆盖写入，勿手改）：
  core/model/src/main/kotlin/io/movieclaw/androidtv/core/model/generated/Models.kt
  core/network/src/main/kotlin/io/movieclaw/androidtv/core/network/generated/McApi.kt

用法（在仓库根目录，用后端的虚拟环境跑）：
  .venv/bin/python apps/android-tv/scripts/gen_api.py           # 重新生成
  .venv/bin/python apps/android-tv/scripts/gen_api.py --check   # 只校验产物与后端一致（CI 用）

生成规则要点：
- 响应模型的每个字段都带默认值：可为 null 的是 ``T? = null``，其余给零值（""、0、false、空列表、
  ``X()``）。老服务端缺字段、新服务端多字段都不会让整包解码失败（McJson 开了 ignoreUnknownKeys /
  coerceInputValues）；
- 只出现在请求里的模型：必填字段没有默认值（构造时必须给），
  可选字段 ``T? = null``、为 null 时不编码，
  由后端取默认值；
- 整数一律 ``Long``（文件大小、毫秒时间戳会超 Int）；
- Literal / 枚举一律 ``String``（新增取值不会解码失败）；
- 无法静态表达的类型（多类型联合、元组、任意对象）落到 ``JsonElement``。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from fastapi import params as fastapi_params
from fastapi.routing import APIRoute
from pydantic import BaseModel, TypeAdapter
from pydantic.json_schema import GenerateJsonSchema

ROOT = Path(__file__).resolve().parents[3]
TV = ROOT / "apps/android-tv"
MODEL_OUT = TV / "core/model/src/main/kotlin/io/movieclaw/androidtv/core/model/generated/Models.kt"
API_OUT = TV / "core/network/src/main/kotlin/io/movieclaw/androidtv/core/network/generated/McApi.kt"
MODEL_PACKAGE = "io.movieclaw.androidtv.core.model.generated"
API_PACKAGE = "io.movieclaw.androidtv.core.network.generated"
API_PREFIX = "/api/v1"

#: TV 用到的接口（docs/design/androidtv-app.md §2）。
#: 找不到的会直接报错，后端改了路径能第一时间发现。
ENDPOINTS = [
    # 找服务器与登录
    "GET /health",
    "GET /auth/bootstrap",
    "POST /auth/device/login",
    "POST /auth/device/authorize",
    "POST /auth/device/token",
    "GET /auth/me",
    "DELETE /auth/devices/current",
    # 首页
    "GET /playback/up-next",
    "GET /playback/favorites",
    "GET /ui/preferences",
    "GET /libraries",
    "GET /libraries/showcase",
    "GET /libraries/kinds/{kind}/items",
    "GET /libraries/kinds/{kind}/genres",
    "GET /collections",
    "GET /collections/{collection_id}/items",
    "GET /collections/{collection_id}/series",
    # 海报墙与详情
    "GET /libraries/{library_id}/items",
    "GET /libraries/{library_id}/facets",
    "GET /libraries/{library_id}/items/{media_item_id}",
    "GET /libraries/{library_id}/items/{media_item_id}/episodes",
    "GET /people/{tmdb_person_id}",
    "GET /playback/resume",
    "GET /playback/marks",
    "POST /playback/marks",
    # 搜索
    "GET /search/library",
    # 播放
    "POST /playback/sessions",
    "POST /playback/sessions/{session_id}/ping",
    "DELETE /playback/sessions/{session_id}",
    "POST /playback/progress",
    "PUT /playback/policy",
    "GET /playback/items/{media_item_id}",
    "GET /playback/items/{media_item_id}/episodes",
    "GET /playback/files/{file_id}/trickplay",
    "POST /playback/client-log",
    "POST /playback/metrics",
    # 首页 / 详情大图区的预告片段
    "GET /reels/preview/{media_item_id}",
]

KOTLIN_KEYWORDS = {
    "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in",
    "interface", "is", "null", "object", "package", "return", "super", "this", "throw", "true",
    "try", "typealias", "typeof", "val", "var", "when", "while",
}  # fmt: skip


class ResponseSchema(GenerateJsonSchema):
    """响应口径：后端输出时带默认值的字段也总会出现，全部标记为 required（同 Apple 端）。"""

    def field_is_required(self, field, total):  # noqa: D401
        return True


# ---------------------------------------------------------------------------
# 命名
# ---------------------------------------------------------------------------


def type_name(raw: str) -> str:
    name = raw.replace("-Input", "Input").replace("-Output", "Output")
    name = re.sub(r"[^0-9A-Za-z]+", "_", name).strip("_")
    name = "".join(p[0].upper() + p[1:] for p in name.split("_") if p)
    return "T" + name if name[0].isdigit() else name


def camel(snake: str) -> str:
    parts = [p for p in re.split(r"[_\-\s.]+", snake) if p]
    if not parts:
        return "_"
    head = parts[0].lower() if parts[0].isupper() else parts[0]
    name = head[0].lower() + head[1:] + "".join(p[0].upper() + p[1:] for p in parts[1:])
    return "_" + name if name[0].isdigit() else name


def ident(name: str) -> str:
    return f"`{name}`" if name in KOTLIN_KEYWORDS else name


def ref_name(ref: str) -> str:
    return type_name(ref.split("/")[-1])


# ---------------------------------------------------------------------------
# JSON schema → Kotlin 类型
# ---------------------------------------------------------------------------


def kt_type(schema: dict) -> tuple[str, bool]:
    """返回 (Kotlin 类型, 是否可为 null)。"""
    if not schema:
        return "JsonElement", True
    if "$ref" in schema:
        return ref_name(schema["$ref"]), False
    for key in ("anyOf", "oneOf"):
        if key in schema:
            variants = schema[key]
            non_null = [v for v in variants if v.get("type") != "null"]
            nullable = len(non_null) != len(variants)
            if len(non_null) == 1:
                inner, inner_nullable = kt_type(non_null[0])
                return inner, nullable or inner_nullable
            if all(v.get("type") == "string" for v in non_null):
                return "String", nullable
            if {v.get("type") for v in non_null} <= {"integer", "number"}:
                return "Double", nullable
            return "JsonElement", True
    if "allOf" in schema and len(schema["allOf"]) == 1:
        return kt_type(schema["allOf"][0])
    if "const" in schema:
        value = schema["const"]
        return {bool: "Boolean", int: "Long", float: "Double"}.get(type(value), "String"), False
    t = schema.get("type")
    if isinstance(t, list):
        non_null = [x for x in t if x != "null"]
        if len(non_null) == 1:
            inner, _ = kt_type({**schema, "type": non_null[0]})
            return inner, len(non_null) != len(t)
        return "JsonElement", True
    simple = {"string": "String", "integer": "Long", "number": "Double", "boolean": "Boolean"}
    if t in simple:
        return simple[t], False
    if t == "null":
        return "JsonElement", True
    if t == "array":
        if "prefixItems" in schema:
            return "List<JsonElement>", False
        inner, inner_nullable = kt_type(schema.get("items", {}))
        return f"List<{nullable_of(inner, inner_nullable)}>", False
    if t == "object" or "additionalProperties" in schema:
        extra = schema.get("additionalProperties")
        if isinstance(extra, dict) and extra:
            inner, inner_nullable = kt_type(extra)
            return f"Map<String, {nullable_of(inner, inner_nullable)}>", False
        if "properties" not in schema:
            return "JsonObject", False
    if "enum" in schema:
        values = schema["enum"]
        if all(isinstance(v, str) for v in values):
            return "String", False
        if all(isinstance(v, int) for v in values):
            return "Long", False
    return "JsonElement", True


def nullable_of(typ: str, nullable: bool) -> str:
    return f"{typ}?" if nullable and typ != "JsonElement" else typ


def refs_in(node) -> set[str]:
    out: set[str] = set()
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "$ref" and isinstance(v, str):
                out.add(v.split("/")[-1])
            else:
                out |= refs_in(v)
    elif isinstance(node, list):
        for x in node:
            out |= refs_in(x)
    return out


def kdoc(text: str | None, indent: str) -> list[str]:
    lines = [line.strip() for line in (text or "").strip().splitlines() if line.strip()]
    if not lines:
        return []
    lines = [line.replace("*/", "* /") for line in lines]
    return [f"{indent}/**"] + [f"{indent} * {line}" for line in lines] + [f"{indent} */"]


class ModelWriter:
    def __init__(self, defs: dict, request_only: set[str]):
        self.defs = defs
        self.request_only = request_only
        self.kinds = {type_name(n): self._kind(s) for n, s in defs.items()}
        self.cyclic = self._cyclic_structs()

    @staticmethod
    def _kind(schema: dict) -> str:
        if "enum" in schema:
            return "string"
        return "struct" if schema.get("properties") else "object"

    def _cyclic_structs(self) -> set[str]:
        """会经由「必有的嵌套对象」绕回自己的模型：这些字段给不了 ``X()`` 默认值，改为可空。"""
        graph = {
            type_name(n): {ref_name("#/" + r) for r in refs_in(s.get("properties", {}))}
            for n, s in self.defs.items()
        }
        cyclic: set[str] = set()
        for start in graph:
            stack, seen = list(graph[start]), set()
            while stack:
                node = stack.pop()
                if node == start:
                    cyclic.add(start)
                    break
                if node not in seen:
                    seen.add(node)
                    stack.extend(graph.get(node, ()))
        return cyclic

    def zero(self, typ: str) -> str | None:
        if typ.startswith("List<"):
            return "emptyList()"
        if typ.startswith("Map<"):
            return "emptyMap()"
        simple = {
            "String": '""',
            "Long": "0",
            "Double": "0.0",
            "Boolean": "false",
            "JsonObject": "JsonObject(emptyMap())",
        }
        if typ in simple:
            return simple[typ]
        kind = self.kinds.get(typ)
        if kind == "string":
            return '""'
        if kind == "object":
            return "JsonObject(emptyMap())"
        if kind == "struct" and typ not in self.cyclic:
            return f"{typ}()"
        return None

    def write(self, raw_name: str) -> list[str]:
        name = type_name(raw_name)
        schema = self.defs[raw_name]
        lines = kdoc(schema.get("description"), "")
        if "enum" in schema:
            values = ", ".join(repr(v) for v in schema["enum"])
            return lines + [f"/** 取值：{values} */", f"typealias {name} = String"]
        props = schema.get("properties") or {}
        if not props:
            return lines + [f"typealias {name} = JsonObject"]
        request_only = raw_name in self.request_only
        required = set(schema.get("required") or [])
        lines += ["@Serializable", f"data class {name}("]
        used: set[str] = set()
        for json_key, prop in props.items():
            prop_name = camel(json_key)
            while prop_name in used:
                prop_name += "_"
            used.add(prop_name)
            typ, nullable = kt_type(prop)
            if typ == "JsonElement":
                nullable = True
            if request_only and json_key in required and not nullable:
                decl = typ
            elif nullable or (request_only and json_key not in required):
                decl = f"{typ}? = null"
            else:
                zero = self.zero(typ)
                decl = f"{typ} = {zero}" if zero is not None else f"{typ}? = null"
            lines += kdoc(prop.get("description"), "    ")
            lines.append(f'    @SerialName("{json_key}") val {ident(prop_name)}: {decl},')
        lines.append(")")
        return lines


# ---------------------------------------------------------------------------
# 路由收集（同 Apple 端：include_router 惰性挂载，路径与响应模型在「生效上下文」上）
# ---------------------------------------------------------------------------


class RouteInfo:
    def __init__(self, original: APIRoute, ctx, path: str):
        self.path = path
        self.methods = original.methods
        self.response_model = (
            getattr(ctx, "response_model", None) if ctx is not None else None
        ) or original.response_model
        self.summary = (getattr(ctx, "summary", None) if ctx is not None else None) or (
            original.summary
        )
        self.name = original.name
        self.operation_id = (
            getattr(ctx, "operation_id", None) if ctx is not None else None
        ) or original.operation_id
        self.unique_id = f"{sorted(original.methods)[0]}_{path}"
        self.dependant = original.dependant
        self.body_field = original.body_field


def unwrap_envelope(model):
    from movieclaw_api.schemas.response import ApiResponse

    if isinstance(model, type) and issubclass(model, BaseModel):
        meta = getattr(model, "__pydantic_generic_metadata__", None) or {}
        if meta.get("origin") is ApiResponse and meta.get("args"):
            return meta["args"][0], True
    return model, False


def collect(dependant, attr: str) -> list:
    out, seen = [], set()

    def walk(dep):
        for f in getattr(dep, attr):
            if f.alias not in seen:
                seen.add(f.alias)
                out.append(f)
        for sub in dep.dependencies:
            walk(sub)

    walk(dependant)
    return out


def load_routes() -> dict[str, RouteInfo]:
    from fastapi.routing import _iter_routes_with_context

    from movieclaw_api.app import create_app

    out: dict[str, RouteInfo] = {}
    for original, ctx in _iter_routes_with_context(create_app().routes):
        if not isinstance(original, APIRoute):
            continue
        path = ctx.path if ctx is not None else original.path
        # 路径参数的转换器（{account_id:path}）不属于 URL 模板：与 OpenAPI 一样只留参数名
        path = re.sub(r"\{(\w+):[^}]+\}", r"{\1}", path)
        if not path.startswith(API_PREFIX):
            continue
        for method in original.methods - {"HEAD"}:
            out[f"{method} {path[len(API_PREFIX) :]}"] = RouteInfo(original, ctx, path)
    return out


def generate() -> tuple[str, str]:
    routes = load_routes()
    missing = [e for e in ENDPOINTS if e not in routes]
    if missing:
        raise SystemExit("后端找不到这些接口（路径改了？）：\n  " + "\n  ".join(missing))

    inputs, plans = [], []
    for endpoint in ENDPOINTS:
        route = routes[endpoint]
        method = endpoint.split(" ", 1)[0]
        inner, enveloped = unwrap_envelope(route.response_model)
        resp_key = None
        if inner is not None and inner is not type(None):
            resp_key = ("resp", endpoint)
            inputs.append((resp_key, TypeAdapter(inner)))
        body = None
        if route.body_field is not None:
            info = route.body_field.field_info
            if isinstance(info, (fastapi_params.Form, fastapi_params.File)):
                raise SystemExit(f"{endpoint} 是表单上传，生成器不支持")
            body = ("body", endpoint)
            inputs.append((body, TypeAdapter(info.annotation)))
        params = []
        for kind, fields in (
            ("path", collect(route.dependant, "path_params")),
            ("query", collect(route.dependant, "query_params")),
        ):
            for f in fields:
                key = ("param", endpoint, kind, f.alias)
                inputs.append((key, TypeAdapter(f.field_info.annotation)))
                params.append((kind, f, key))
        plans.append((endpoint, route, method, enveloped, resp_key, body, params))

    resp_inputs = [(k, "validation", a) for k, a in inputs if k[0] == "resp"]
    req_inputs = [(k, "validation", a) for k, a in inputs if k[0] != "resp"]
    resp_map, resp_top = TypeAdapter.json_schemas(
        resp_inputs, ref_template="#/$defs/{model}", schema_generator=ResponseSchema
    )
    req_map, req_top = TypeAdapter.json_schemas(req_inputs, ref_template="#/$defs/{model}")
    defs = dict(resp_top.get("$defs", {}))

    # @computed_field 只出现在序列化口径里（同 Apple 端的处理）
    def all_models(cls):
        for sub in cls.__subclasses__():
            yield sub
            yield from all_models(sub)

    for cls in set(all_models(BaseModel)):
        computed = getattr(cls, "model_computed_fields", None) or {}
        target = defs.get(cls.__name__)
        if not computed or not target or "properties" not in target:
            continue
        ser_props = cls.model_json_schema(mode="serialization").get("properties", {})
        for prop in computed:
            if prop in ser_props and prop not in target["properties"]:
                target["properties"][prop] = ser_props[prop]
                target.setdefault("required", []).append(prop)

    req_defs = req_top.get("$defs", {})
    renames = {n: n + "Input" for n, s in req_defs.items() if n in defs and defs[n] != s}

    def rewrite(node):
        if isinstance(node, dict):
            return {
                k: ("#/$defs/" + renames.get(v.split("/")[-1], v.split("/")[-1]))
                if k == "$ref" and isinstance(v, str)
                else rewrite(v)
                for k, v in node.items()
            }
        if isinstance(node, list):
            return [rewrite(x) for x in node]
        return node

    request_only: set[str] = set()
    for name, schema in req_defs.items():
        target = renames.get(name, name)
        if target not in defs:
            defs[target] = rewrite(schema)
            request_only.add(target)
    key_map = {k[0]: v for k, v in resp_map.items()}
    key_map.update({k[0]: rewrite(v) for k, v in req_map.items()})

    writer = ModelWriter(defs, request_only)
    models = [
        "// 由 apps/android-tv/scripts/gen_api.py 生成，勿手改。重新生成见脚本头部说明。",
        '@file:Suppress("unused")',
        "",
        f"package {MODEL_PACKAGE}",
        "",
        "import kotlinx.serialization.SerialName",
        "import kotlinx.serialization.Serializable",
        "import kotlinx.serialization.json.JsonElement",
        "import kotlinx.serialization.json.JsonObject",
        "",
    ]
    for raw_name in sorted(defs, key=type_name):
        models += writer.write(raw_name)
        models.append("")

    api = [
        "// 由 apps/android-tv/scripts/gen_api.py 生成，勿手改。重新生成见脚本头部说明。",
        "",
        f"package {API_PACKAGE}",
        "",
        "import io.movieclaw.androidtv.core.model.McJson",
        f"import {MODEL_PACKAGE}.*",
        "import io.movieclaw.androidtv.core.network.ApiTransport",
        "import kotlinx.serialization.json.JsonElement",
        "import kotlinx.serialization.json.JsonObject",
        "import kotlinx.serialization.json.encodeToJsonElement",
        "import kotlinx.serialization.serializer",
        "",
        "/** 服务端接口（白名单见生成脚本 ENDPOINTS）。",
        " * 路径相对 `/api/v1`，信封 `{data}` 已拆掉。 */",
        "class McApi(private val transport: ApiTransport) {",
    ]
    seen: set[str] = set()
    for endpoint, route, method, enveloped, resp_key, body, params in plans:
        name = ident(camel((route.operation_id or route.unique_id).replace(".", "_")))
        while name in seen:
            name += "_"
        seen.add(name)
        sig, query = [], []
        path_expr = route.path[len(API_PREFIX) :]
        for kind, field, key in params:
            typ, nullable = kt_type(key_map[key])
            pname = ident(camel(field.alias))
            if kind == "path":
                sig.append(f"{pname}: {typ}")
                for placeholder in {field.name, field.alias}:
                    path_expr = path_expr.replace("{" + placeholder + "}", "${" + pname + "}")
            else:
                optional = nullable or not field.field_info.is_required()
                sig.append(f"{pname}: {typ}{'? = null' if optional else ''}")
                query.append((field.alias, pname, typ, optional))
        if body is not None:
            btyp, bnull = kt_type(key_map[body])
            optional_body = bnull or not route.body_field.field_info.is_required()
            sig.append(f"body: {btyp}{'? = null' if optional_body else ''}")
        if resp_key is None:
            ret = "Unit"
        else:
            rtyp, rnull = kt_type(key_map[resp_key])
            ret = nullable_of(rtyp, rnull)
        summary = (route.summary or route.name).strip().replace("*/", "* /")
        api.append(f"    /** {summary}（`{endpoint}`） */")
        api.append(f"    suspend fun {name}({', '.join(sig)}): {ret} {{")
        if not query:
            api.append("        val query = emptyList<Pair<String, String>>()")
        else:
            api.append("        val query = buildList<Pair<String, String>> {")
        for alias, pname, typ, optional in query:
            if typ.startswith("List<"):
                src = f"{pname}.orEmpty()" if optional else pname
                api.append(f'            {src}.forEach {{ add("{alias}" to it.toString()) }}')
            elif optional:
                api.append(f'            {pname}?.let {{ add("{alias}" to it.toString()) }}')
            else:
                api.append(f'            add("{alias}" to {pname}.toString())')
        if query:
            api.append("        }")
        body_expr = "null"
        if body is not None:
            body_expr = "body?.let { McJson.encodeToJsonElement(it) }"
            if not optional_body:
                body_expr = "McJson.encodeToJsonElement(body)"
        decoded = "JsonElement?" if ret == "Unit" else ret
        call = (
            f'transport.send("{method}", "{path_expr}", query, {body_expr}, '
            f"serializer<{decoded}>(), enveloped = {'true' if enveloped else 'false'})"
        )
        api.append(f"        {'' if ret == 'Unit' else 'return '}{call}")
        api.append("    }")
        api.append("")
    api[-1] = "}"
    return "\n".join(models) + "\n", "\n".join(api) + "\n"


def main() -> int:
    models, api = generate()
    if "--check" in sys.argv:
        stale = [
            p.relative_to(ROOT)
            for p, text in ((MODEL_OUT, models), (API_OUT, api))
            if not p.exists() or p.read_text(encoding="utf-8") != text
        ]
        if stale:
            print("生成物与后端不一致，请重新运行 gen_api.py：", *stale, sep="\n  ")
            return 1
        print("生成物与后端一致")
        return 0
    for path, text in ((MODEL_OUT, models), (API_OUT, api)):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    print(f"接口 {len(ENDPOINTS)} 个 → {API_OUT.relative_to(ROOT)}")
    print(f"模型 {models.count('data class ')} 个 → {MODEL_OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
