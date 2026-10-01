from __future__ import annotations

import asyncio
import configparser
import logging
from pathlib import Path

from alembic import command
from alembic.config import Config

logger = logging.getLogger("movieclaw_db.migrations")

# 项目根目录：src/movieclaw_db/migrations.py 向上三级
_PROJECT_ROOT = Path(__file__).resolve().parents[2]
_ALEMBIC_INI = _PROJECT_ROOT / "alembic.ini"
_ALEMBIC_DIR = _PROJECT_ROOT / "alembic"


def _build_config() -> Config:
    """构造指向项目 alembic.ini 的 Config，并用绝对路径锁定脚本目录。

    用绝对路径覆盖 script_location，是为了让迁移无论从哪个工作目录启动
    （容器内 / IDE / 测试）都能找到迁移脚本。

    ini 先用 UTF-8 显式预读再注入：alembic 内部读 ini 固定按系统区域编码
    （Windows 中文系统 = GBK），而本仓库的 alembic.ini 带 UTF-8 中文注释，
    把路径直接交给 Config 会在 Windows 上 UnicodeDecodeError、应用起不来。
    预读用与 alembic 同款带插值的 ConfigParser，ini 里的其余配置
    （file_template 的 %% 转义、日志段、prepend_sys_path）语义不变。
    """
    file_config = configparser.ConfigParser({"here": _ALEMBIC_INI.parent.as_posix()})
    file_config.read(_ALEMBIC_INI, encoding="utf-8")
    cfg = Config()
    # file_config 是 memoized_property：先触发一次默认构建，再用预读结果覆写
    # 实例缓存（实例属性优先于类描述符），后续所有读取都命中 UTF-8 副本
    cfg.file_config  # noqa: B018 —— 刻意解引用以触发 memoized 构建
    cfg.__dict__["file_config"] = file_config
    cfg.set_main_option("script_location", str(_ALEMBIC_DIR))
    # alembic.ini 的 prepend_sys_path = src 是相对路径，alembic 会原样插到 sys.path 最前面，
    # 按当前工作目录解析。容器里工作目录是 /app，于是 /app/src（镜像里的旧代码）压过了
    # 应用内更新的 overlay：服务进程之后才首次导入的模块、以及继承 sys.path 的子进程
    # （片头片尾识别、video_cues）都会拿到旧代码甚至找不到模块。这里同样锁成绝对路径，
    # 指向与本文件同版的 src（% 是 ConfigParser 插值符，要转义）
    cfg.set_main_option("prepend_sys_path", str(_PROJECT_ROOT / "src").replace("%", "%%"))
    return cfg


def _upgrade_to_head() -> None:
    """同步执行 alembic upgrade head。"""
    command.upgrade(_build_config(), "head")


async def run_migrations() -> None:
    """应用启动时调用：把数据库结构升级到最新版本。

    Alembic 的命令是同步阻塞的，这里放到线程池执行，避免阻塞 FastAPI 的事件循环；
    同时也让 env.py 内部可以独立管理自己的（同步）数据库连接，互不干扰。

    对非开发者部署者的意义：升级容器镜像后首次启动会自动补齐表结构，
    无需手动敲任何 alembic 命令。
    """
    logger.info("开始执行数据库迁移（upgrade head）……")
    await asyncio.to_thread(_upgrade_to_head)
    logger.info("数据库迁移完成，结构已是最新")
