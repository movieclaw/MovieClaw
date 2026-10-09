"""内置服务键（docs/design/plugin-kernel.md §7）。

集中在这里，一眼看全系统有哪些服务。第一阶段全部是 ``INTERNAL`` 契约：只供内置插件使用，
随时可改；第二阶段逐个评估后再升为 ``EXPERIMENTAL`` 对外开放。

存量代码仍经 ``get_database()`` 这类模块级单例取用（不改调用点）；服务键主要用来表达
插件之间的依赖、驱动启动顺序与级联释放，新代码优先经 ``ctx.use`` 取。
"""

from __future__ import annotations

from typing import Any

from movieclaw_kernel import RegistryKey, ServiceKey, Stability

DB: ServiceKey[Any] = ServiceKey("db", doc="数据库引擎（迁移完成后提供）")
SECRETS: ServiceKey[Any] = ServiceKey("secrets", doc="凭据加解密器")
SETTING_STORE: ServiceKey[Any] = ServiceKey("setting-store", doc="配置存储")
EGRESS: ServiceKey[Any] = ServiceKey("egress", doc="网络出口（代理路由、镜像地址）")
SITES: ServiceKey[Any] = ServiceKey("sites", doc="站点目录（内置 + 用户自定义）")
SITE_ACCESS: ServiceKey[Any] = ServiceKey("site-access", doc="站点访问管理器（已认证的共享客户端）")
AGENT_RUNS: ServiceKey[Any] = ServiceKey("agent-runs", doc="Agent 运行注册表")
SCHEDULER: ServiceKey[Any] = ServiceKey("scheduler", doc="定时任务调度器")
CLOUD: ServiceKey[Any] = ServiceKey("cloud", doc="MovieClaw Cloud 连接")
PUSH_HUB: ServiceKey[Any] = ServiceKey("push-hub", doc="推送事件中枢")
JOBS: ServiceKey[Any] = ServiceKey("jobs", doc="持久化后台任务执行器")
REMOTE_WORKERS: ServiceKey[Any] = ServiceKey("remote-workers", doc="远程转码 Worker 注册表")

# ---- 开放给第三方插件的服务（实验级，docs/design/plugin-phase2a.md）----
HOST_OPS: ServiceKey[Any] = ServiceKey(
    "host-ops",
    stability=Stability.EXPERIMENTAL,
    doc="宿主操作：插件以自己的身份调用本进程的 OpenAPI 操作（按操作授权）",
)
PLUGIN_DATA: ServiceKey[Any] = ServiceKey(
    "plugin-data",
    stability=Stability.EXPERIMENTAL,
    doc="插件数据：插件自己的状态与挂在实体上的扩展字段（只能读写自己的）",
)
PLUGIN_HEALTH: ServiceKey[Any] = ServiceKey(
    "plugin-health",
    stability=Stability.EXPERIMENTAL,
    doc="插件健康：常驻任务报告降级 / 恢复，降级进系统通知与诊断",
)
SITE_CLASSES: RegistryKey[Any] = RegistryKey(
    "site-classes",
    stability=Stability.EXPERIMENTAL,
    doc="站点类：插件贡献 BaseSite 子类，站点 YAML 的 custom_class 按贡献 id 引用",
)
SITE_DATA_PACKS: RegistryKey[Any] = RegistryKey(
    "site-data-packs",
    stability=Stability.EXPERIMENTAL,
    doc="站点数据包：插件贡献一个站点 YAML 目录（优先级：内置 < 数据包 < 用户目录）",
)
PLUGIN_FILES: ServiceKey[Any] = ServiceKey(
    "plugin-files",
    stability=Stability.EXPERIMENTAL,
    doc="插件文件：按用户批准的路径授权读写文件（进程外插件经描述符传递），交出文件给路由",
)
PLUGIN_ROUTES: ServiceKey[Any] = ServiceKey(
    "plugin-routes",
    stability=Stability.EXPERIMENTAL,
    doc="插件路由：挂到 /api/v1/plugins/<条目 id>（管理员 / 成员 / 验签公开三区），签发签名链接",
)
