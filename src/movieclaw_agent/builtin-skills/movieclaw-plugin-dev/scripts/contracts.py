"""列出插件能用的开放契约，或查看某一个的详细结构。

    python contracts.py                 # 全部开放契约：名字、种类、版本、说明、导入写法
    python contracts.py <名字>          # 某个契约：监听器写法、载荷 / 结果 / 贡献项类型的源码
    python contracts.py <名字> --schema # 同上，但类型以 JSON Schema 给出

只有这里列出来的契约第三方插件才能用；清单 [requires] 里写的就是这些名字。
数据来自主程序代码本身（movieclaw_sdk.surface），与服务器上运行的版本一致。
"""

from __future__ import annotations

import importlib
import inspect
import json
import sys

from movieclaw_kernel import Event, RegistryKey, ServiceKey, Stability
from movieclaw_sdk.surface import MODULES, _describe

#: 监听器写法（按分发模式）
_HANDLER = {
    ("emit", "durable"): (
        "可靠事件：ctx.on(EVENT, handler, id=\"稳定id\")；async def handler(event) -> None。"
        "至少投递一次，用 ctx.delivery.event_id 去重。须 inject=(DURABLE_EVENTS,)"
    ),
    ("emit", "live"): "实时通知：ctx.on(EVENT, handler)；async def handler(payload) -> None。至多一次，重启即丢",
    ("waterfall", "live"): (
        "决策钩子（洋葱式）：async def handler(payload, next_)：result = await next_()（或 next_(新载荷)），"
        "再返回修改后的结果。不许有副作用"
    ),
    ("bail", "live"): "决策钩子（第一个说了算）：def/async def handler(payload)：返回结果表示接管，返回 None 表示不管。不许有副作用",
}


def collect() -> dict[str, tuple[str, str, object]]:
    """契约名 → (模块, 变量名, 契约对象)。"""
    found: dict[str, tuple[str, str, object]] = {}
    for module_name in MODULES:
        module = importlib.import_module(module_name)
        for var, value in vars(module).items():
            if (
                isinstance(value, (Event, RegistryKey, ServiceKey))
                and value.stability is not Stability.INTERNAL
                and value.name not in found
            ):
                found[value.name] = (module_name, var, value)
    return dict(sorted(found.items()))


def listing(contracts: dict[str, tuple[str, str, object]]) -> None:
    kinds = {"service": "服务", "registry": "注册表", "event": "事件"}
    for name, (module, var, contract) in contracts.items():
        info = _describe(contract)  # type: ignore[arg-type]
        kind = kinds.get(info["kind"], info["kind"])
        if info["kind"] == "event":
            kind = "可靠事件" if info["delivery"] == "durable" else (
                "通知" if info["mode"] == "emit" else f"钩子·{info['mode']}"
            )
        print(f"{name}  [{kind} {info['version']}]  {info['doc']}")
        print(f"    from {module} import {var}")


def _type_text(tp: object, schema: object, as_schema: bool) -> str:
    """类型的源码（带定义位置）；拿不到源码或要求 JSON Schema 时给结构。"""
    if not as_schema and inspect.isclass(tp):
        try:
            source = inspect.getsource(tp)
            where = f"{inspect.getsourcefile(tp)}:{inspect.getsourcelines(tp)[1]}"
        except (OSError, TypeError):
            pass
        else:
            return f"# {where}（引用到的其他类型在同一文件里）\n{source}"
    return json.dumps(schema, ensure_ascii=False, indent=1)


def show(name: str, contracts: dict[str, tuple[str, str, object]], as_schema: bool) -> int:
    if name not in contracts:
        close = [n for n in contracts if name in n]
        print(f"没有名为 {name} 的开放契约。" + (f"相近的：{'、'.join(close)}" if close else ""))
        return 1
    module, var, contract = contracts[name]
    info = _describe(contract)  # type: ignore[arg-type]
    print(f"{name}（{info['kind']}，版本 {info['version']}，{info['stability']}）：{info['doc']}")
    print(f"导入：from {module} import {var}")
    print(f'清单：[requires] "{name}" = "^{info["version"]}"')
    if info["kind"] == "service":
        print(f"用法：@plugin(..., inject=({var},))，apply 里 ctx.use({var})；方法见 {module} 或对应的服务实现")
    elif info["kind"] == "registry":
        print(f"用法：ctx.contribute({var}, \"<贡献 id>\", 贡献项)")
        print("贡献项类型：")
        print(_type_text(getattr(contract, "schema", None), info.get("item"), as_schema))
    else:
        print("写法：" + _HANDLER.get((info["mode"], info["delivery"]), f"{info['mode']} / {info['delivery']}"))
        print("载荷类型：")
        print(_type_text(getattr(contract, "payload", None), info.get("payload"), as_schema))
        if info.get("result") is not None:
            print("结果类型：")
            print(_type_text(getattr(contract, "result", None), info.get("result"), as_schema))
    return 0


def main(argv: list[str]) -> int:
    contracts = collect()
    if not argv:
        listing(contracts)
        return 0
    names = [a for a in argv if not a.startswith("--")]
    return show(names[0], contracts, "--schema" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
