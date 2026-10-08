#!/usr/bin/env python3
"""
gen_kotlin_api.py — 从 MovieClaw 服务端 OpenAPI 生成 Kotlin 数据模型(M0 脚手架版)

对标 iOS 端 scripts/gen_api.py 的思路。iOS 生成器跑在服务端 venv 里直接读
FastAPI 路由表 + Pydantic schema;本脚本先走「离线导出的 OpenAPI JSON」路线,
覆盖最常见的对象/数组/枚举/标量结构与 snake_case → camelCase 映射,
表达不了的(anyOf 组合、泛型信封、dict)统一落 kotlinx JsonElement。

用法:
  # 1) 在服务器仓库 venv 内导出 spec(或 GET /api/v1/spec,需管理员):
  python -m movieclaw_api.export_openapi > openapi.json

  # 2) 生成模型到工程:
  python scripts/gen_kotlin_api.py openapi.json \
      --package io.movieclaw.android.core.api.generated \
      --out app/src/main/java/io/movieclaw/android/core/api/generated

后续:端点函数(Retrofit 接口)目前手写在 core/api/McApi.kt;
计划移植 iOS gen_api.py 的「进程内路由表」方案后再生成端点与信封解包。
"""

import argparse
import json
import re
import sys
from pathlib import Path

RESERVED = {
    "object", "data", "name", "when", "in", "is", "fun", "val", "var", "public",
    "private", "internal", "class", "interface", "return", "if", "else", "for",
}

def pascal(name: str) -> str:
    parts = re.split(r"[^0-9a-zA-Z]+", name)
    out = "".join(p[:1].upper() + p[1:] for p in parts if p)
    return out or "Anon"

def camel(name: str) -> str:
    p = pascal(name)
    return p[:1].lower() + p[1:] if p else p

def safe_prop(name: str) -> str:
    prop = camel(name)
    if prop in RESERVED or prop[0].isdigit():
        return f"`{name}`"
    return prop

class Gen:
    def __init__(self, spec: dict):
        self.spec = spec
        self.schemas = spec.get("components", {}).get("schemas", {})
        self.emitted: set[str] = set()

    def ref_name(self, ref: str) -> str:
        return pascal(ref.split("/")[-1])

    def prop_type(self, schema: dict) -> tuple[str, bool]:
        """返回 (Kotlin 类型, 是否可空)。表达不了的结构返回 JsonElement。"""
        if not isinstance(schema, dict):
            return "JsonElement", True
        if "$ref" in schema:
            return self.ref_name(schema["$ref"]), False
        if "anyOf" in schema or "oneOf" in schema:
            variants = schema.get("anyOf") or schema.get("oneOf")
            if len(variants) == 2:
                nullable = any(v.get("type") == "null" for v in variants)
                if nullable:
                    real = next(v for v in variants if v.get("type") != "null")
                    t, _ = self.prop_type(real)
                    return t, True
            return "JsonElement", True
        t = schema.get("type")
        if t == "string":
            if "enum" in schema:
                return "String", False
            fmt = schema.get("format")
            if fmt == "binary":
                return "ByteArray", False
            return "String", False
        if t == "integer":
            return ("Long", False) if schema.get("format") == "int64" else ("Int", False)
        if t == "number":
            return ("Double", False) if schema.get("format") == "double" else ("Float", False)
        if t == "boolean":
            return "Boolean", False
        if t == "array":
            item, nullable = self.prop_type(schema.get("items", {}))
            return f"List<{item}>", nullable
        return "JsonElement", True

    def default_value(self, schema: dict, kotlin_type: str, nullable: bool) -> str:
        if "default" in schema and not str(schema.get("default")).startswith("{"):
            d = schema["default"]
            if kotlin_type == "String":
                return json.dumps(d, ensure_ascii=False)
            if kotlin_type in ("Int", "Long", "Float", "Double", "Boolean"):
                if isinstance(d, bool):
                    return "true" if d else "false"
                if isinstance(d, (int, float)):
                    suffix = "f" if kotlin_type == "Float" and isinstance(d, float) else (
                        "L" if kotlin_type == "Long" else "")
                    v = repr(d)
                    if kotlin_type == "Float" and "." not in v:
                        v += ".0"
                    return v + suffix
                return json.dumps(d)
            if kotlin_type.startswith("List") and isinstance(d, list):
                return "emptyList()"
        if nullable:
            return "null"
        if kotlin_type.startswith("List"):
            return "emptyList()"
        if kotlin_type in ("Int",):
            return "0"
        if kotlin_type == "Long":
            return "0L"
        if kotlin_type == "Float":
            return "0f"
        if kotlin_type == "Double":
            return "0.0"
        if kotlin_type == "Boolean":
            return "false"
        if kotlin_type == "String":
            return '""'
        return 'throw IllegalArgumentException("missing")'

    def emit_schema(self, name: str, lines: list[str]) -> None:
        klass = pascal(name)
        if klass in self.emitted:
            return
        self.emitted.add(klass)
        schema = self.schemas.get(name)
        if (
            not isinstance(schema, dict)
            or schema.get("type") != "object"
            or "properties" not in schema
        ):
            return
        required = set(schema.get("required", []))
        body = []
        for raw_prop, prop_schema in schema["properties"].items():
            kotlin_type, nullable = self.prop_type(prop_schema)
            if kotlin_type not in ("JsonElement", "ByteArray") and "$ref" in prop_schema:
                ref = prop_schema["$ref"].split("/")[-1]
                if ref in self.schemas:
                    self.emit_schema(ref, lines)
            if (
                kotlin_type.startswith("List<")
                and kotlin_type[5:-1] in self.schemas
                and kotlin_type[5:-1] not in ("JsonElement",)
            ):
                self.emit_schema(kotlin_type[5:-1], lines)
            prop = safe_prop(raw_prop)
            nullable = nullable or raw_prop not in required
            default = self.default_value(prop_schema, kotlin_type, nullable)
            serial = f'@SerialName("{raw_prop}") ' if raw_prop != prop else ""
            body.append(
                f"    {serial}val {prop}: {kotlin_type}{'?' if nullable else ''} = {default},"
            )
        lines.append("@Serializable")
        lines.append(f"data class {klass}(")
        lines.extend(body)
        lines.append(")")
        lines.append("")

    def run(self) -> str:
        header = [
            "// 本文件由 scripts/gen_kotlin_api.py 从服务端 OpenAPI 生成,请勿手改。",
            "// 服务端 schema 变更后重新生成;生成不了的组合结构请在本文件基础上手工修正。",
            "",
            f"package {ARGS.package}",
            "",
            "import kotlinx.serialization.SerialName",
            "import kotlinx.serialization.Serializable",
            "import kotlinx.serialization.json.JsonElement",
            "",
        ]
        for name in self.schemas:
            self.emit_schema(name, header)
        return "\n".join(header)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec", help="openapi.json 路径")
    parser.add_argument("--package", default="io.movieclaw.android.core.api.generated")
    parser.add_argument("--out", required=True)
    global ARGS
    ARGS = parser.parse_args()

    spec_path = Path(ARGS.spec)
    if not spec_path.exists():
        print(f"spec 不存在: {spec_path}", file=sys.stderr)
        return 1
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    code = Gen(spec).run()
    out = Path(ARGS.out)
    out.mkdir(parents=True, exist_ok=True)
    target = out / "Models.kt"
    target.write_text(code, encoding="utf-8")
    print(
        f"已生成 {target}({len(code.splitlines())} 行,"
        f"{len(spec.get('components', {}).get('schemas', {}))} 个 schema)"
    )
    return 0


ARGS = None

if __name__ == "__main__":
    raise SystemExit(main())
