"""契约：服务键、注册表键与它们的版本 / 稳定性元数据（docs/design/plugin-kernel.md §4.2、§5）。

契约是插件之间唯一的耦合点：使用方只按键名找能力，不 import 具体实现。每个契约带
``主.次`` 版本与稳定性分级，插件在加载前按 ``requires`` 检查兼容性。
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import Any, Generic, TypeVar

T = TypeVar("T")


class Stability(StrEnum):
    """契约稳定性分级（§5.1）。"""

    INTERNAL = "internal"
    """仅内置插件可用，随时可改。"""

    EXPERIMENTAL = "experimental"
    """第三方可用，次版本内可能破坏。"""

    STABLE = "stable"
    """第三方可用，次版本只增不破。"""


@dataclass(frozen=True, order=True)
class Version:
    major: int
    minor: int

    @classmethod
    def parse(cls, text: str) -> Version:
        parts = text.strip().split(".")
        if len(parts) != 2 or not all(p.isdigit() for p in parts):
            raise ValueError(f"契约版本须为「主.次」格式：{text!r}")
        return cls(int(parts[0]), int(parts[1]))

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}"


def satisfies(requirement: str, actual: Version) -> bool:
    """``^1.2``（或 ``1.2``）= 主版本相同、次版本不低于。"""
    wanted = Version.parse(requirement.lstrip("^"))
    return actual.major == wanted.major and actual.minor >= wanted.minor


class Contract:
    """服务键、注册表键、事件的公共元数据。构造时登记进全局契约目录。"""

    kind: str = "contract"

    def __init__(
        self,
        name: str,
        *,
        version: str = "1.0",
        stability: Stability = Stability.INTERNAL,
        doc: str = "",
    ) -> None:
        if not name:
            raise ValueError("契约名不能为空")
        self.name = name
        self.version = Version.parse(version)
        self.stability = stability
        self.doc = doc
        CATALOG[name] = self

    def __repr__(self) -> str:
        return f"{type(self).__name__}({self.name!r}, v{self.version})"


#: 全局契约目录：契约名 → 契约对象。插件 ``requires`` 按名字在这里查版本。
#: 同名重复定义时后者覆盖（测试里常见），以最后一次定义为准。
CATALOG: dict[str, Contract] = {}


class ServiceKey(Contract, Generic[T]):
    """一个提供方的服务（§4.2）。``ServiceKey[Database]("db")``。"""

    kind = "service"


class RegistryKey(Contract, Generic[T]):
    """多个贡献方的注册表（§4.2）。``schema`` 可选：贡献项须是它的实例。"""

    kind = "registry"

    def __init__(
        self,
        name: str,
        *,
        version: str = "1.0",
        stability: Stability = Stability.INTERNAL,
        doc: str = "",
        schema: type | None = None,
    ) -> None:
        super().__init__(name, version=version, stability=stability, doc=doc)
        self.schema = schema


def check_requires(requires: dict[str, str], *, third_party: bool) -> str | None:
    """返回不兼容原因；兼容返回 ``None``（§5.2）。"""
    for name, requirement in requires.items():
        contract = CATALOG.get(name)
        if contract is None:
            return f"未知契约 {name}"
        if third_party and contract.stability is Stability.INTERNAL:
            return f"契约 {name} 仅供内置插件使用"
        try:
            ok = satisfies(requirement, contract.version)
        except ValueError as exc:
            return str(exc)
        if not ok:
            return f"契约 {name} 要求 {requirement}，当前为 {contract.version}"
    return None


def describe(contract: Contract) -> dict[str, Any]:
    return {
        "name": contract.name,
        "kind": contract.kind,
        "version": str(contract.version),
        "stability": contract.stability.value,
        "doc": contract.doc,
    }
