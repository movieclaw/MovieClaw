"""插件参数的界面描述：JSON Schema 子集（docs/design/plugin-phase4.md §2）。

插件只写 pydantic 模型，这里把 ``model_json_schema()`` 收窄成主程序渲染器认得的子集：
顶层对象；属性只能是布尔、字符串（可带枚举）、整数、数字、字符串列表；
可选值收成 ``type: [x, "null"]``。

界面提示：敏感字段用标准关键字 ``writeOnly`` + ``format: password``
（``SecretStr``，或 ``json_schema_extra={"secret": True}``）；
多行文本用 ``x-multiline``（``json_schema_extra={"multiline": True}``）。

超出子集的模型不报错，``describe_config`` 返回原因：插件照常加载，只是界面上不提供编辑。
"""

from __future__ import annotations

from typing import Any

_SCALARS = {"boolean", "string", "integer", "number"}
_KEEP = (
    "title",
    "description",
    "default",
    "enum",
    "minLength",
    "maxLength",
    "pattern",
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "format",
    "examples",
)


class SchemaNotSupported(ValueError):
    """模型里有子集之外的类型。消息是给人看的中文，指明字段与原因。"""


def config_schema(model: type) -> dict[str, Any]:
    """pydantic 模型 → JSON Schema 子集；超出子集抛 :class:`SchemaNotSupported`。"""
    build = getattr(model, "model_json_schema", None)
    if build is None:
        raise SchemaNotSupported("配置不是 pydantic 模型")
    raw = build()
    if raw.get("type") != "object":
        raise SchemaNotSupported("配置顶层必须是对象")
    defs = raw.get("$defs", {})
    properties = {
        name: _field(name, prop, defs) for name, prop in (raw.get("properties") or {}).items()
    }
    schema: dict[str, Any] = {"type": "object", "properties": properties}
    if raw.get("title"):
        schema["title"] = raw["title"]
    required = [name for name in raw.get("required", []) if name in properties]
    if required:
        schema["required"] = required
    return schema


def describe_config(model: type | None) -> dict[str, Any] | None:
    """宿主要的配置描述：``{"schema": …}``，或超出子集时 ``{"unsupported": 原因}``；
    没有配置模型为 None。"""
    if model is None:
        return None
    try:
        return {"schema": config_schema(model)}
    except SchemaNotSupported as exc:
        return {"unsupported": str(exc)}


def secret_fields(schema: dict[str, Any]) -> set[str]:
    """敏感字段名（``writeOnly``）。"""
    return {
        name for name, prop in (schema.get("properties") or {}).items() if prop.get("writeOnly")
    }


def _field(name: str, prop: dict[str, Any], defs: dict[str, Any]) -> dict[str, Any]:
    nullable = False
    if "anyOf" in prop:
        variants = [v for v in prop["anyOf"] if v.get("type") != "null"]
        if len(variants) != 1 or len(variants) == len(prop["anyOf"]):
            raise SchemaNotSupported(f"字段 {name} 是多种类型的组合，界面编辑不支持")
        nullable = True
        # 外层的标题、说明、默认值与界面提示（secret / multiline）都要带上
        prop = {**variants[0], **{k: v for k, v in prop.items() if k != "anyOf"}}
    ref = prop.get("$ref") or ((prop.get("allOf") or [{}])[0].get("$ref"))
    if ref:
        target = defs.get(ref.rsplit("/", 1)[-1], {})
        if "enum" not in target:
            raise SchemaNotSupported(f"字段 {name} 是嵌套对象，界面编辑不支持")
        prop = {**target, **{k: v for k, v in prop.items() if k not in ("$ref", "allOf")}}
    kind = prop.get("type")
    if kind == "object":
        raise SchemaNotSupported(f"字段 {name} 是映射或嵌套对象，界面编辑不支持")
    if kind == "array":
        if (prop.get("items") or {}).get("type") != "string":
            raise SchemaNotSupported(f"字段 {name} 是非字符串列表，界面编辑只支持字符串列表")
        out: dict[str, Any] = {"type": "array", "items": {"type": "string"}}
    elif kind in _SCALARS:
        out = {"type": kind}
    else:
        raise SchemaNotSupported(f"字段 {name} 的类型（{kind or '对象'}）界面编辑不支持")
    out.update({k: prop[k] for k in _KEEP if k in prop})
    # SecretStr 生成 writeOnly + format: password；也可以在 json_schema_extra 里写 secret
    if prop.get("writeOnly") or prop.get("secret") or prop.get("format") == "password":
        out.update(writeOnly=True, format="password")
        out.pop("default", None)
    if prop.get("multiline"):
        out["x-multiline"] = True
    if nullable:
        out["type"] = [out["type"], "null"]
    return out


def connection_schema(adapter: Any) -> dict[str, Any]:
    """下载器适配器的连接参数 Schema：进程外拿到的已经是 dict，模型现转，没声明用默认模型。"""
    from movieclaw_downloader.registry import Connection

    connection = getattr(adapter, "connection", None)
    if isinstance(connection, dict):
        return connection
    return config_schema(connection or Connection)
