"""测试全局配置：从仓库根目录的 .env 加载环境变量。

集成测试使用的真实站点 Cookie 通过环境变量传入，避免敏感凭据进入
git 历史。本地开发时复制 .env.example 为 .env 并填写即可，CI 环境
中保持环境变量为空，相关测试会自动跳过。
"""
from __future__ import annotations

import asyncio
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
_ENV_FILE = _PROJECT_ROOT / ".env"

# 测试期间产生的运行日志统一写进临时目录：create_app 会装配按天落盘的
# 日志 Handler（见 core/logging.py），不隔离的话测试会在仓库 data/logs
# 下留下日志文件。先于 .env 加载设置，测试环境始终生效。
os.environ.setdefault("LOG_DIR", tempfile.mkdtemp(prefix="movieclaw-test-logs-"))


def _resolve_ner_model_dir() -> None:
    """git worktree 里跑测试时，把 NER 模型指向主仓库的 data 目录。

    模型文件是运行期数据（不入 git，从 Release 下载到 data/models/torrent-ner），
    而 worktree 只共享代码不共享 data/——不做这层回落，enrich 的片名/季集字段
    在 worktree 里全空，库扫描/enrich 语料等一批测试会稳定失败且原因很隐蔽。
    主仓库位置由 git 公共目录（.git 所在处）推导；主仓库也没有模型时保持原状，
    由 enrich 侧照常打"请下载模型"的警告。
    """
    if os.environ.get("MOVIECLAW_NER_DIR"):
        return  # 显式指定的优先
    local = _PROJECT_ROOT / "data/models/torrent-ner"
    if (local / "model.int8.onnx").is_file():
        # 当前检出自己就有模型（主仓库常态）：写成绝对路径，
        # 免得从其他 cwd 跑 pytest 时 enrich 的相对默认路径落空
        os.environ["MOVIECLAW_NER_DIR"] = str(local)
        return
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            cwd=_PROJECT_ROOT,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return
    candidate = (_PROJECT_ROOT / common).resolve().parent / "data/models/torrent-ner"
    if (candidate / "model.int8.onnx").is_file():
        os.environ["MOVIECLAW_NER_DIR"] = str(candidate)


_resolve_ner_model_dir()


def _load_env_file(path: Path) -> None:
    """加载简单的 .env 文件，将 KEY=VALUE 注入 os.environ。

    设计要点：
    - 已存在的环境变量优先，不会被 .env 覆盖（CI/手动 export 的值更权威）；
    - 仅支持 KEY=VALUE 形式，忽略空行与 # 开头的注释；
    - 自动剥离值两端的成对单/双引号，方便粘贴含分号的 cookie 串。

    避免新增依赖（python-dotenv），保持测试侧零依赖。
    """
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        os.environ.setdefault(key, value)


_load_env_file(_ENV_FILE)


import pytest  # noqa: E402  须在环境变量装配之后导入
from pwdlib import PasswordHash  # noqa: E402
from pwdlib.hashers.argon2 import Argon2Hasher  # noqa: E402

# 业务测试只需要验证 Argon2id 的格式与认证语义，不应反复承担生产环境抵抗暴力
# 破解所需的 CPU/内存成本。生产参数另有 real_password_hash 专项测试守护。
_TEST_PASSWORD_HASH = PasswordHash(
    (Argon2Hasher(time_cost=1, memory_cost=8, parallelism=1),)
)


class _SQLiteMigrationTemplate:
    """pytest 会话内复用一份已迁移到 head 的空 SQLite。

    业务测试需要独立数据库，但不需要各自验证 64 个 Alembic revision。首个空库
    仍完整执行真实迁移并成为模板；之后的空库直接复制模板。若目标库已有内容、
    没有版本号或版本落后，则仍执行真实迁移，迁移兼容场景不会被快路径掩盖。

    run_migrations 可能从 TestClient/uvicorn 的后台事件循环调用，因此模板初始化和
    复制用线程锁串行化，不能使用绑定单一事件循环的 asyncio.Lock。
    """

    def __init__(self, migration_module) -> None:  # type: ignore[no-untyped-def]
        self._module = migration_module
        self.original = migration_module.run_migrations
        self._temp_dir = tempfile.TemporaryDirectory(prefix="movieclaw-test-db-template-")
        self._template = Path(self._temp_dir.name) / "migrated.db"
        self._head_revision: str | None = None
        self._lock = threading.Lock()

    @staticmethod
    def _sqlite_path(database_url: str) -> Path | None:
        """只加速文件型 SQLite；其他数据库与内存库保持生产迁移路径。"""
        from sqlalchemy.engine import make_url

        url = make_url(database_url)
        if url.get_backend_name() != "sqlite" or not url.database or url.database == ":memory:":
            return None
        return Path(url.database).resolve()

    @staticmethod
    def _revision(path: Path) -> str | None:
        if not path.is_file() or path.stat().st_size == 0:
            return None
        try:
            with sqlite3.connect(path) as connection:
                row = connection.execute("SELECT version_num FROM alembic_version").fetchone()
        except (OSError, sqlite3.DatabaseError):
            return None
        return str(row[0]) if row else None

    def _prepare_sync(self, target: Path) -> None:
        with self._lock:
            current_revision = self._revision(target)
            if self._head_revision is not None and current_revision == self._head_revision:
                return

            fresh = not target.exists() or target.stat().st_size == 0
            if fresh and self._head_revision is not None:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(self._template, target)
                return

            # 首个空库以及任何已有/旧版库都走真实 Alembic。直接调用同步内核，
            # 因为当前方法本身已经由 asyncio.to_thread 放在线程池中。
            self._module._upgrade_to_head()
            if fresh and self._head_revision is None:
                revision = self._revision(target)
                if revision is not None:
                    shutil.copyfile(target, self._template)
                    self._head_revision = revision

    async def run(self) -> None:
        from movieclaw_api.core.config import get_settings

        target = self._sqlite_path(get_settings().database_url)
        if target is None:
            await self.original()
            return
        await asyncio.to_thread(self._prepare_sync, target)

    def close(self) -> None:
        self._temp_dir.cleanup()


_migration_template: _SQLiteMigrationTemplate | None = None
_rebound_modules: list = []


class _AppReuse:
    """同一 worker 进程内复用 FastAPI 应用实例（按「创建期就固化的配置」缓存）。

    为什么：FastAPI 0.139 起路由状态改为懒构建——每个新应用实例第一次匹配请求时，
    要把整棵路由树逐条建依赖与 Pydantic 字段（本机约 0.3 秒/实例，CI 翻倍）。生产
    进程只付一次；测试却是每个用例 ``create_app()`` 一次，全量上千次，曾占到接口
    类测试一半以上的耗时。

    怎么复用：路由、异常处理器、OpenAPI 文档只取决于创建期配置，缓存起来；随用例
    变化的部分每次换新——

    - lifespan：按当次 settings 重建（每个用例的临时库、密钥文件都不同）；
    - 中间件：按创建时的完整清单重建实例（含 Jellyfin 路径归一化），不串状态；
    - ``dependency_overrides`` 与 ``app.state``：清空。

    重置只在每个用例第一次 ``create_app()`` 时做：同一用例里后续的调用（例如
    后端现算 spec 时内部又调了一次 create_app）拿到的是同一个正在用的实例，
    清掉它的 dependency_overrides 会让用例中途变成未登录。

    缓存键是 create_app 读进去、之后不再变的配置（APP_ENV 决定文档开关等）。
    用例往应用上加了路由（路由数变化）时整份作废、下次重新创建。需要全新实例的
    用例可直接调 ``_AppReuse.original()``。
    """

    original = None
    _cache: dict = {}
    #: 用例序号，由 pytest_runtest_setup 递增；实例记下自己最后一次重置时的序号
    generation = 0

    @classmethod
    def install(cls) -> None:
        import movieclaw_api.app as app_module

        if cls.original is not None:
            return
        cls.original = app_module.create_app
        app_module.create_app = cls.create_app

    @classmethod
    def uninstall(cls) -> None:
        import movieclaw_api.app as app_module

        if cls.original is not None:
            app_module.create_app = cls.original
            cls.original = None
        cls._cache.clear()

    @classmethod
    def create_app(cls):  # type: ignore[no-untyped-def]
        from starlette.datastructures import State

        from movieclaw_api.core.config import get_settings
        from movieclaw_api.core.logging import configure_logging
        from movieclaw_api.lifespan import build_lifespan

        settings = get_settings()
        key = (
            settings.app_env,
            settings.api_v1_prefix,
            settings.app_name,
            settings.access_log_enabled,
        )
        cached = cls._cache.get(key)
        if cached is None or len(cached[0].router.routes) != cached[1]:
            app = cls.original()
            routes, middleware = len(app.router.routes), list(app.user_middleware)
            cls._cache[key] = [app, routes, middleware, cls.generation]
            return app
        app, _, middleware, reset_at = cached
        configure_logging(settings.log_level, settings.log_dir, settings.log_retention_days)
        app.router.lifespan_context = build_lifespan(settings)
        if reset_at != cls.generation:
            cached[3] = cls.generation
            app.dependency_overrides.clear()
            app.user_middleware = list(middleware)
            app.middleware_stack = None
            app.state = State()
        return app


def _rebind(original, replacement) -> list:  # type: ignore[no-untyped-def]
    """把已导入模块里 from-import 进来的 ``original`` 一并换成 ``replacement``。

    只改 ``migrations.run_migrations`` 不够：任何在会话开始前就导入了应用的代码
    （插件、conftest 顶层 import）都会让 lifespan 模块先绑定生产入口，模板快路径
    就此悄悄失效——每次起应用真跑一遍全部 Alembic 迁移，全量慢四成且没有任何
    报错。这里扫一遍已加载模块补齐，替换不再依赖导入顺序。
    """
    rebound = []
    for module in list(sys.modules.values()):
        if module is not None and getattr(module, "run_migrations", None) is original:
            module.run_migrations = replacement
            rebound.append(module)
    return rebound


def pytest_sessionstart(session: pytest.Session) -> None:
    """替换迁移入口（含已 from-import 的副本），再装上应用实例复用。"""
    global _migration_template, _rebound_modules
    del session

    from movieclaw_db import migrations

    _migration_template = _SQLiteMigrationTemplate(migrations)
    _rebound_modules = _rebind(_migration_template.original, _migration_template.run)
    # 必须排在迁移替换之后：它会导入 lifespan，届时拿到的已是快路径
    _AppReuse.install()


def pytest_runtest_setup(item: pytest.Item) -> None:
    """新用例开始：复用的应用实例在本用例第一次 create_app 时重置一次。"""
    del item
    _AppReuse.generation += 1


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    """恢复生产入口并清理会话级 SQLite 模板。"""
    global _migration_template
    del session, exitstatus

    if _migration_template is None:
        return
    _AppReuse.uninstall()
    for module in _rebound_modules:
        module.run_migrations = _migration_template.original
    _migration_template.close()
    _migration_template = None


_SHARD_DURATIONS = Path(__file__).with_name("shard-durations.json")


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    """CI 分片：``PYTEST_SHARD=i/n`` 时只留第 i 片的测试文件（本地不设，不受影响）。

    按文件整体分配（与 ``--dist loadfile`` 同粒度，同文件用例不会拆到两台机器），
    权重取 ``tests/shard-durations.json`` 里各文件的历史耗时，按「最长的先放、
    放进当前最轻的一片」贪心装箱，几片大致同时跑完。新文件没有记录时按中位数
    估算；记录过时只会让几片略不均衡，不会漏跑——全部文件必然落在某一片里。
    刷新记录：``python scripts/update-shard-durations.py <junit.xml>``。
    排在其他插件之后执行（trylast），只给 ``-m`` 筛剩下的用例分片。
    """
    spec = os.environ.get("PYTEST_SHARD", "").strip()
    if not spec:
        return
    index, total = (int(part) for part in spec.split("/"))
    if not 1 <= index <= total:
        raise pytest.UsageError(f"PYTEST_SHARD 取值无效：{spec}（应为 i/n 且 1 ≤ i ≤ n）")

    import json
    import statistics

    by_file: dict[str, list[pytest.Item]] = {}
    for item in items:
        by_file.setdefault(item.nodeid.split("::", 1)[0], []).append(item)
    known = json.loads(_SHARD_DURATIONS.read_text(encoding="utf-8"))
    default = statistics.median(known.values()) if known else 1.0
    loads = [0.0] * total
    owner: dict[str, int] = {}
    for path in sorted(by_file, key=lambda f: (-known.get(f, default), f)):
        target = min(range(total), key=lambda k: (loads[k], k))
        loads[target] += known.get(path, default)
        owner[path] = target

    keep = [item for item in items if owner[item.nodeid.split("::", 1)[0]] == index - 1]
    dropped = [item for item in items if owner[item.nodeid.split("::", 1)[0]] != index - 1]
    if dropped:
        config.hook.pytest_deselected(items=dropped)
    items[:] = keep


@pytest.fixture(autouse=True)
def _fast_password_hash(request, monkeypatch):  # type: ignore[no-untyped-def]
    """普通测试使用低成本 Argon2id，保留协议语义并缩短重复建号/登录耗时。"""
    if request.node.get_closest_marker("real_password_hash"):
        return

    from movieclaw_api.services import auth

    monkeypatch.setattr(auth, "_password_hash", _TEST_PASSWORD_HASH)


@pytest.fixture(autouse=True)
def _mute_instant_search_kick(monkeypatch):
    """默认打桩订阅写操作触发的即时缺口搜索（fire-and-forget）。

    service 层收口后，创建/调整/恢复/缺失重下都会踢一次 search_wanted；
    单测环境没有可用站点，放任它跑会写入"搜索失败"活动、污染断言。
    需要验证搜索行为的测试请显式 ``await search_wanted()``（管线测试即如此）；
    需要验证"踢了没踢"的测试可再次 monkeypatch 覆盖本桩。
    """
    monkeypatch.setattr(
        "movieclaw_api.services.subscription.wanted_search.kick_search_soon", lambda: None
    )
    # 同理打桩后台的预测刷新：它自开会话跑在用例的事件循环上，循环随用例结束
    # 关闭后任务会变成悬空的 pending task。要验证预测的测试显式
    # ``await refresh_release_forecasts()``（预测测试即如此）。
    monkeypatch.setattr(
        "movieclaw_api.services.subscription.release_forecast.refresh_release_forecasts_soon",
        lambda media_item_ids: None,
    )


@pytest.fixture(autouse=True)
def _offline_tmdb_singleton(request, monkeypatch):
    """媒体身份层的 TmdbClient 单例在测试环境一律离线（不访问真实 TMDB）。

    背景：库路由决策（library/routing.gather_facts）等链路直接取
    ``get_tmdb_client()`` 进程级单例，测试往服务里注入的 fake client
    覆盖不到它。开发机 .env 里带 TMDB_API_KEY 时，订阅等服务级测试会
    经它发出**真实** TMDB 请求：单例连同 HTTP 连接池被创建在首个用例
    的事件循环上，循环随用例结束关闭，连接却还留在池里；之后第一个跑
    完整 lifespan 的测试在关停时 ``close_media_service()`` 去关这条
    死循环上的连接，偶发 ``RuntimeError: Event loop is closed``
    （teardown 报错，且与测试顺序/网络时机相关，极难排查）。

    这里按用例把单例换成独立的离线实例（503 快速失败，不重试）：
    既掐断单测的真实外网流量，也保证单例及其连接不跨事件循环存活。
    monkeypatch 会在用例结束时把单例槽位还原（通常是 None）。
    集成测试可能需要真实单例，跳过注入。
    """
    if request.node.get_closest_marker("integration"):
        yield
        return
    import httpx

    from movieclaw_api.services import media_discover
    from movieclaw_media.tmdb import TmdbClient

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, json={"note": "测试环境不访问真实 TMDB"})

    monkeypatch.setattr(
        media_discover,
        "_tmdb_client",
        TmdbClient("test-offline-key", transport=httpx.MockTransport(handler)),
    )
    yield


@pytest.fixture(autouse=True)
def _offline_image_proxy(monkeypatch):
    """刮削管线的图片资产下载在测试环境一律快速失败（不访问外网图床）。

    管线对单张失败本就优雅降级（字段保持 NULL、下次刷新自愈），这里只是
    把"真实网络超时"换成即时异常，保证测试快速且不依赖外网。直接构造
    ImageProxy 实例（注入 MockTransport）的专项测试不经单例，不受影响。
    """

    class _Offline:
        async def fetch(self, url: str, *, accept: str | None = None):
            raise RuntimeError("测试环境不访问外网图床")

    monkeypatch.setattr(
        "movieclaw_api.services.image_proxy.get_image_proxy", lambda: _Offline()
    )


@pytest.fixture(autouse=True)
def _fresh_pgs_capability(monkeypatch):
    """PGS 识别环境在进程内只探测一次（subtitle_gen/pgs.py 的 ``_Environment``）。

    测试逐个打桩 seconv/Tesseract 的探测结果，缓存必须按用例清空，否则前一个
    用例的环境会串进后一个。启动流程的后台预热也换成空操作：它在线程池里跑
    真实探测，用例结束后才写回缓存的话，会覆盖下一个用例打的桩。
    """
    from movieclaw_api.services.subtitle_gen import pgs

    pgs.reset_capability_cache()
    monkeypatch.setattr(pgs, "warm_capability", lambda: None)
    yield
    pgs.reset_capability_cache()
