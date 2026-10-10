"""核心插件：数据库、加密、配置、网络出口、刮削偏好、HTTP 客户端、站点（plugin-kernel.md §7）。

这一组里标了 ``critical`` 的失败会中止启动：没有它们大部分功能都无法降级运行，与改造前一致。
领域模块一律在 ``apply`` 内 import——与原 lifespan 一样，避免启动期循环导入。
"""

from __future__ import annotations

import logging
from pathlib import Path

from movieclaw_api.core.logging import configure_logging
from movieclaw_api.plugins.keys import DB, EGRESS, SECRETS, SETTING_STORE, SITE_ACCESS, SITES

# 顶层 import：测试的迁移模板快路径会扫描已加载模块里的 run_migrations 并替换
from movieclaw_db.migrations import run_migrations
from movieclaw_kernel import Context, plugin

logger = logging.getLogger("movieclaw_api.plugins.core")


@plugin("core.database", title="数据库", provides=(DB,), critical=True)
async def database(ctx: Context) -> None:
    """打开应用数据库，启动时自动升级表结构；几乎所有功能都依赖它。"""
    from movieclaw_db.engine import dispose_db, init_db, refresh_query_statistics

    settings = ctx.settings
    # 先初始化引擎（会顺带创建 SQLite 文件所在目录），再执行迁移
    db = init_db(settings.database_url, echo=settings.db_echo, cache_mb=settings.db_cache_mb)

    async def close() -> None:
        # 关闭前把本轮运行期间的行数变化落进统计，下次启动直接是新的
        await refresh_query_statistics(db)
        await dispose_db()

    ctx.effect(close, label="dispose-db")
    await run_migrations()
    # 迁移之后立刻刷一次索引统计：没有它 SQLite 会挑错索引（见 refresh_query_statistics 注释）
    await refresh_query_statistics(db)
    # Alembic 的 fileConfig 会按 alembic.ini 重置 root logger（级别、Handler 全换掉），
    # 迁移一跑完就重新应用一次应用日志配置，否则迁移之后的日志全部不落盘
    configure_logging(settings.log_level, settings.log_dir, settings.log_retention_days)
    ctx.provide(DB, db)


@plugin("core.registries", title="任务与处理器注册表", critical=True)
async def registries(ctx: Context) -> None:
    """汇总各模块登记的定时任务和后台任务类型，让调度器与任务执行器知道有哪些活可干。

    把内核里的两张注册表绑定为当前生效的定时任务表与后台任务处理器表，并把事件总线交给决策钩子。

    绑定之后，调度器、执行器、定时任务接口都只认插件贡献的项；解绑（内核关闭）后回落到
    模块声明目录，命令行工具与单独驱动引擎的测试照常工作。处理器表一变就唤醒执行器，
    运行中挂上的插件贡献的新任务类型能被及时领取。决策钩子（hooks.py）同理：没绑时走默认实现。
    """
    from movieclaw_api import hooks, pipeline
    from movieclaw_api.services import jobs
    from movieclaw_api.services.library import delete_participants
    from movieclaw_scheduler import SCHEDULED_TASKS, bind_registry

    hooks.bind_bus(ctx.events)
    ctx.effect(lambda: hooks.unbind_bus(ctx.events), label="unbind-hooks")
    # 流水线槽位的步骤表（pipeline.py）：入库任务按它为插件步骤建下游任务
    ctx.effect(pipeline.bind_steps(ctx.registry(pipeline.INGEST_STEPS)), label="unbind-steps")
    # 删除参与方（library-boundary.md §3）：删除弹窗的附加选项与勾选后的后续任务
    ctx.effect(
        delete_participants.bind_participants(
            ctx.registry(delete_participants.LIBRARY_DELETE_PARTICIPANTS)
        ),
        label="unbind-delete-participants",
    )

    ctx.effect(bind_registry(ctx.registry(SCHEDULED_TASKS)), label="unbind-scheduled-tasks")
    ctx.effect(
        jobs.bind_handler_registry(ctx.registry(jobs.JOB_HANDLERS)), label="unbind-job-handlers"
    )

    def on_handlers_changed(change) -> None:
        jobs.note_job_type(change.id)
        jobs.wake_job_dispatcher()

    ctx.watch(jobs.JOB_HANDLERS, on_handlers_changed)


@plugin("core.secrets", title="凭据加密", provides=(SECRETS,), critical=True)
async def secrets(ctx: Context) -> None:
    """准备加密密钥：站点登录凭据等敏感信息都加密后才存入数据库。"""
    from movieclaw_db.crypto import init_secret_box

    settings = ctx.settings
    ctx.provide(SECRETS, init_secret_box(settings.master_key, Path(settings.secret_key_file)))


@plugin(
    "core.settings",
    title="配置存储",
    inject=(DB, SECRETS),
    provides=(SETTING_STORE,),
    critical=True,
)
async def setting_store(ctx: Context) -> None:
    """负责保存和读取系统设置，设置页里的各项配置都经由它存取。"""
    from movieclaw_api.settings import init_setting_store

    # 首次空库启动时 app_setting 表已由迁移建好，读取缺记录返回默认值（空库也能进引导页）
    ctx.provide(SETTING_STORE, init_setting_store())


@plugin(
    "core.egress",
    title="网络出口",
    inject=(SETTING_STORE,),
    provides=(EGRESS,),
    critical=True,
)
async def egress(ctx: Context) -> None:
    """按「网络与代理」设置，为系统的对外请求选择直连或走代理。"""
    from movieclaw_api.services.network_egress import load_network_egress

    # 须在任何出网客户端首次构造前生效
    ctx.provide(EGRESS, await load_network_egress())


@plugin("core.scrape-runtime", title="刮削与发现偏好", inject=(SETTING_STORE,), critical=True)
async def scrape_runtime(ctx: Context) -> None:
    """启动时载入刮削偏好（语言优先级、选图、院线地区），供元数据刮削和发现页使用。"""
    from movieclaw_api.services.scrape_config import load_scrape_runtime

    # 语言优先级、选图偏好、院线地区：须在刮削管线与发现页服务首次使用前生效
    await load_scrape_runtime()


@plugin("core.http-clients", title="共享 HTTP 客户端", inject=(EGRESS,), reloadable=True)
async def http_clients(ctx: Context) -> None:
    """管理发现页与图片代理共用的网络连接，关闭应用时统一释放。

    发现页服务与图片代理的客户端是懒建的单例，这里只负责在关闭时释放。

    激活得早，因此释放得晚：Agent、站点等用到它们的子系统都先于它停下。
    """
    from movieclaw_api.services.image_proxy import close_image_proxy
    from movieclaw_api.services.media_discover import close_media_service

    ctx.effect(close_image_proxy, label="close-image-proxy")
    ctx.effect(close_media_service, label="close-media-service")


@plugin("tracker.sites", title="站点目录", provides=(SITES,), critical=True)
async def sites(ctx: Context) -> None:
    """加载 PT 站点目录（内置、插件提供和用户自定义的站点配置），决定系统支持哪些站点。"""
    import movieclaw_tracker
    from movieclaw_api.plugins.keys import SITE_CLASSES, SITE_DATA_PACKS
    from movieclaw_tracker import load_all_sites
    from movieclaw_tracker import registry as site_registry

    def reload() -> None:
        # 内置 sites/configs < 插件数据包 < 用户目录 data/site-configs（同 site_id 后者覆盖）
        load_all_sites(ctx.settings.site_configs_dir)

    # 插件贡献的站点类与站点数据包（docs/design/plugin-phase2b.md §6）：随插件挂上 / 卸下
    # 重载站点目录。YAML 的 custom_class 只认内置站点类与这里注册的类，不再做任意导入
    def on_class(change) -> None:
        if change.kind == "added":
            site_registry.register_site_class(change.id, change.item)
        else:
            site_registry.unregister_site_class(change.id)
        reload()

    def on_pack(change) -> None:
        if change.kind == "added":
            site_registry.register_data_pack(change.id, Path(change.item))
        else:
            site_registry.unregister_data_pack(change.id)
        reload()

    ctx.watch(SITE_CLASSES, on_class)
    ctx.watch(SITE_DATA_PACKS, on_pack)
    reload()
    ctx.provide(SITES, movieclaw_tracker)


@plugin(
    "tracker.site-access",
    title="站点访问",
    inject=(SITES, EGRESS, DB),
    provides=(SITE_ACCESS,),
    critical=True,
)
async def site_access(ctx: Context) -> None:
    """维护各 PT 站点的登录会话，供种子同步、搜索和下载复用，不必每次操作都重新登录。"""
    from movieclaw_api.services.site_access import init_site_access

    # 进程级单例，持有每站已认证的共享客户端；须在调度器之前（种子同步任务依赖它）
    manager = init_site_access()
    ctx.effect(manager.aclose, label="close-site-clients")
    ctx.provide(SITE_ACCESS, manager)


@plugin("selfheal.credentials", title="凭据状态自愈", inject=(DB, SECRETS), reloadable=True)
async def selfheal_credentials(ctx: Context) -> None:
    """启动时复位上次卡在「验证中」的站点与 AI 模型配置，并加密遗留的明文站点凭据。

    重启自愈：清理上次遗留的「验证中」状态；存量明文凭据一次性加密（均幂等）。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.credential_repo import CredentialRepository
    from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository

    async with get_database().session() as session:
        count = await CredentialRepository(session).reset_stale_verifying()
        if count:
            logger.info("已重置 %d 条卡在验证中的站点配置为待验证", count)
        count = await LlmProviderRepository(session).reset_stale_verifying()
        if count:
            logger.info("已重置 %d 个卡在验证中的 LLM 供应商实例为待验证", count)
    # 加密内核上线前落库的明文站点凭据转为密文。读取侧兼容明文，失败不应影响其他自愈
    try:
        async with get_database().session() as session:
            count = await CredentialRepository(session).encrypt_plaintext_secrets()
        if count:
            logger.info("已将 %d 条存量明文站点凭据加密落库", count)
    except Exception:
        logger.exception("存量站点凭据加密迁移失败，将在下次启动时重试")
