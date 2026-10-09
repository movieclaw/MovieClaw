"""随带插件包改名后的数据迁移（docs/design/plugin-callbacks.md §3.3）。

``channel.weixin`` 这类带点的旧 id 改成了 ``weixin-channel``。按条目 id 存的东西要跟过去：
``data/plugins.yaml`` 里的补丁、插件私有目录、插件数据、可靠事件的消费进度与死信、待处理事项。
已绑定的通道账号不用动——账号存的是通道 id（``weixin``），与插件 id 无关。

用户若装过同 id 的替换包（旧 id，代码里写死了），那个 id 下的数据归它所有，一概不动。
每一步都幂等，每次启动都跑一遍：没有旧数据时什么也不做。
"""

from __future__ import annotations

import logging
import re
from pathlib import Path

from movieclaw_api.plugins import packages
from movieclaw_api.plugins.bundled import LEGACY_IDS

logger = logging.getLogger("movieclaw_api.plugins.legacy_ids")


def _pending(settings: object) -> dict[str, str]:
    """要迁移的旧 id → 新 id：排除仍装着的旧 id 替换包。"""
    installed = set(packages.package_ids(settings))
    return {old: new for old, new in LEGACY_IDS.items() if old not in installed}


def migrate_files(settings: object) -> None:
    """启动前：``plugins.yaml`` 里的旧 id 与插件私有目录。"""
    from movieclaw_api.plugins.manifest import patch_file

    pending = _pending(settings)
    path = patch_file(settings)
    if path.is_file():
        text = path.read_text(encoding="utf-8")
        updated = text
        for old, new in pending.items():
            # 只改 id 字段的值，注释与格式原样保留
            pattern = re.compile(rf"(\bid:\s*[\"']?){re.escape(old)}([\"']?\s*(?:#.*)?$)", re.M)
            updated = pattern.sub(rf"\g<1>{new}\g<2>", updated)
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            logger.info("plugins.yaml 里随带插件包的旧 id 已改成新 id")
    data = Path(getattr(settings, "data_dir", "./data")) / "plugins" / "data"
    for old, new in pending.items():
        source, target = data / old, data / new
        if source.is_dir() and not target.exists():
            source.rename(target)
            logger.info("插件目录 %s 已改名为 %s", old, new)


async def migrate_rows(settings: object) -> None:
    """数据库就绪后：插件数据、消费进度、死信、待处理事项里的旧 id。"""
    from sqlalchemy import text

    from movieclaw_db.engine import get_database

    pending = _pending(settings)
    if not pending:
        return
    statements = (
        "UPDATE plugin_data SET entry_id = :new WHERE entry_id = :old",
        "UPDATE event_consumer SET consumer_id = :new || substr(consumer_id, length(:old) + 1)"
        " WHERE consumer_id LIKE :old_prefix",
        "UPDATE event_dead_letter SET consumer_id = :new || substr(consumer_id, length(:old) + 1)"
        " WHERE consumer_id LIKE :old_prefix",
        # plugin:<id>（启动失败）与 plugin:<id>:health:<key>（健康上报）
        "UPDATE system_notice SET dedupe_key = 'plugin:' || :new"
        " || substr(dedupe_key, length('plugin:' || :old) + 1)"
        " WHERE dedupe_key = 'plugin:' || :old OR dedupe_key LIKE 'plugin:' || :old || ':%'",
    )
    changed = 0
    try:
        async with get_database().session() as session:
            for old, new in pending.items():
                params = {"old": old, "new": new, "old_prefix": f"{old}:%"}
                for statement in statements:
                    result = await session.execute(text(statement), params)
                    changed += result.rowcount or 0
            await session.commit()
    except Exception:  # noqa: BLE001 -- 迁移失败不拦启动：随带通道不依赖这些数据，下次启动再试
        logger.warning("随带插件包旧 id 的数据迁移失败，下次启动再试", exc_info=True)
        return
    if changed:
        logger.info("随带插件包旧 id 的数据已迁移到新 id（%d 行）", changed)
