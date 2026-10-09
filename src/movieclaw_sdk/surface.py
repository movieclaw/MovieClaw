"""开放契约的表面（docs/design/plugin-kernel.md §5.4、plugin-phase3.md §7）。

列出第三方插件能用的全部契约（实验级以上的服务、注册表、事件与决策钩子）：版本、稳定性、说明，
以及事件载荷 / 结果、注册表贡献项的结构。``surface.json`` 是随代码提交的快照，CI 比对
（``tests/kernel/test_contract_surface.py``）：结构变了版本却没变、或破坏性变化而主版本没升，构建失败。

    python -m movieclaw_sdk.surface            # 打印当前表面
    python -m movieclaw_sdk.surface --write    # 刷新快照（改了契约并已升版本时）
"""

from __future__ import annotations

import argparse
import dataclasses
import importlib
import inspect
import json
import sys
from pathlib import Path
from typing import Any

from movieclaw_kernel import Event, RegistryKey, ServiceKey, Stability
from movieclaw_kernel.contracts import Contract

SNAPSHOT = Path(__file__).with_name("surface.json")

#: 定义开放契约的模块（只从这里收集，测试里临时注册的契约不算）
MODULES = (
    "movieclaw_kernel",
    "movieclaw_api.hooks",
    "movieclaw_api.domain_events",
    "movieclaw_api.plugins.keys",
    "movieclaw_api.pipeline",
    "movieclaw_api.services.jobs",
    "movieclaw_scheduler",
)


def _schema(tp: Any) -> Any:
    """类型 → 稳定的结构描述（pydantic 模型 / 冻结 dataclass 走 JSON Schema，其余记类型名）。"""
    if tp is None:
        return None
    from pydantic import TypeAdapter

    try:
        return _structure(TypeAdapter(tp).json_schema(mode="serialization"))
    except Exception:  # noqa: BLE001 -- 含可调用对象等无法生成 JSON Schema 的结构
        if dataclasses.is_dataclass(tp):
            return {
                "dataclass": tp.__name__,
                "fields": {f.name: str(f.type) for f in dataclasses.fields(tp)},
            }
        if inspect.isclass(tp):
            # 插件要实现的基类（如通道驱动）：公开方法的签名就是契约
            methods = {
                name: str(inspect.signature(member))
                for name, member in sorted(vars(tp).items())
                if not name.startswith("_") and inspect.isfunction(member)
            }
            if methods:
                return {"class": tp.__name__, "methods": methods}
        return {"type": getattr(tp, "__name__", repr(tp))}


_PROSE = frozenset({"title", "description", "examples"})


#: 这些关键字底下是「名字 → 子结构」：名字是字段名，不能当说明删掉（字段就叫 title 很常见）
_NAMED = frozenset({"properties", "$defs", "definitions", "patternProperties"})


def _structure(schema: Any) -> Any:
    """去掉说明性内容（标题、描述、示例）：改文案不算契约变化，只比结构。"""
    if isinstance(schema, dict):
        cleaned: dict[str, Any] = {}
        for key, value in schema.items():
            if key in _PROSE:
                continue
            if key in _NAMED and isinstance(value, dict):
                cleaned[key] = {name: _structure(sub) for name, sub in value.items()}
            else:
                cleaned[key] = _structure(value)
        return cleaned
    if isinstance(schema, list):
        return [_structure(v) for v in schema]
    return schema


def _describe(contract: Contract) -> dict[str, Any]:
    item: dict[str, Any] = {
        "kind": contract.kind,
        "version": f"{contract.version.major}.{contract.version.minor}",
        "stability": contract.stability.value,
        "doc": contract.doc,
    }
    if isinstance(contract, Event):
        item.update(
            mode=contract.mode.value,
            delivery=contract.delivery.value,
            payload=_schema(contract.payload),
            result=_schema(contract.result),
        )
    elif isinstance(contract, RegistryKey):
        item["item"] = _schema(contract.schema)
    return item


def surface() -> dict[str, dict[str, Any]]:
    found: dict[str, dict[str, Any]] = {}
    for name in MODULES:
        module = importlib.import_module(name)
        for value in vars(module).values():
            if (
                isinstance(value, (Event, RegistryKey, ServiceKey))
                and value.stability is not Stability.INTERNAL
            ):
                found[value.name] = _describe(value)
    return dict(sorted(found.items()))


def dump(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="开放契约的表面")
    parser.add_argument("--write", action="store_true", help="刷新随代码提交的快照")
    args = parser.parse_args(argv)
    text = dump(surface())
    if args.write:
        SNAPSHOT.write_text(text, encoding="utf-8")
        print(f"已写入 {SNAPSHOT}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
