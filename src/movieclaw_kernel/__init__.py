"""movieclaw_kernel —— 插件内核（docs/design/plugin-kernel.md）。

没有特权内核：MovieClaw 自己的子系统也是挂在这里的插件。本包是叶子包，只依赖标准库，
将来原样作为插件 SDK 的核心发布。

- ``contracts``：服务键、注册表键、版本与稳定性；
- ``plugin``：``@plugin`` 声明、清单条目、补丁；
- ``context``：插件拿到的 ``ctx``；
- ``registry``：多贡献方注册表与覆盖栈；
- ``events``：三种分发模式的事件总线；
- ``kernel``：状态机、依赖驱动的启动、逆序关闭；
- ``observe``：归属、发起方与因果链、内存指标；
- ``testing``：``KernelHarness`` 与严格模式。
"""

from movieclaw_kernel.context import Context
from movieclaw_kernel.contracts import RegistryKey, ServiceKey, Stability
from movieclaw_kernel.events import (
    DURABLE_EVENTS,
    CauseChainTooLong,
    Delivery,
    DurableEventStore,
    Event,
    Mode,
)
from movieclaw_kernel.kernel import (
    KERNEL_READY,
    PLUGIN_STATE,
    Fiber,
    Kernel,
    KernelConfigError,
    KernelReady,
    KernelStartupError,
    PluginStateChanged,
    State,
)
from movieclaw_kernel.observe import (
    DeliveryInfo,
    EntryLogFilter,
    Origin,
    current_delivery,
    current_entry,
    current_origin,
)
from movieclaw_kernel.plugin import Entry, Patch, Plugin, plugin
from movieclaw_kernel.registry import ContributionConflict, Registry, RegistryChange

__all__ = [
    "DURABLE_EVENTS",
    "KERNEL_READY",
    "PLUGIN_STATE",
    "CauseChainTooLong",
    "Context",
    "ContributionConflict",
    "Delivery",
    "DeliveryInfo",
    "DurableEventStore",
    "Entry",
    "EntryLogFilter",
    "Event",
    "Fiber",
    "Kernel",
    "KernelConfigError",
    "KernelReady",
    "KernelStartupError",
    "Mode",
    "Origin",
    "Patch",
    "Plugin",
    "PluginStateChanged",
    "Registry",
    "RegistryChange",
    "RegistryKey",
    "ServiceKey",
    "Stability",
    "State",
    "current_delivery",
    "current_entry",
    "current_origin",
    "plugin",
]
