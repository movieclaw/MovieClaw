"""插件通用设置的存储（docs/design/plugin-phase4.md §3）。

存在数据目录的 ``plugins/settings/<插件 id>.json``，敏感字段经 SecretBox 加密。
不进数据库：不需要迁移（带迁移的部署无法回退到旧版本），
且与 ``plugins.yaml``、插件启动记录同在数据目录、一起备份。

内核加载插件时经 :func:`overlay` 把这里的值叠到清单配置（本地插件的 ``plugins.yaml``）上，
界面保存的优先。
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

logger = logging.getLogger("movieclaw_api.plugins")

SETTINGS_DIR = Path("plugins") / "settings"


def _path(settings: Any, entry_id: str) -> Path:
    if not entry_id or "/" in entry_id or "\\" in entry_id or entry_id.startswith("."):
        raise ValueError(f"插件 id 不能用作文件名：{entry_id!r}")
    return Path(getattr(settings, "data_dir", "./data")) / SETTINGS_DIR / f"{entry_id}.json"


def _box(settings: Any):  # type: ignore[no-untyped-def]
    from movieclaw_db.crypto import init_secret_box

    # 幂等：已初始化就返回现有实例。插件加载顺序不保证核心插件先跑，这里不能假设它已初始化
    return init_secret_box(settings.master_key, Path(settings.secret_key_file))


def read(settings: Any, entry_id: str) -> dict[str, Any]:
    """界面保存过的设置（敏感字段已解密）；没保存过为空。文件坏了记日志、按没保存处理。"""
    try:
        path = _path(settings, entry_id)
    except ValueError:
        return {}  # 不能当文件名的 id 不可能存过设置；报错留给插件自己的校验
    try:
        stored = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        logger.warning("插件 %s 的设置文件读不出来，按未设置处理：%s", entry_id, exc)
        return {}
    values = dict(stored.get("values") or {})
    secrets = stored.get("secrets") or {}
    if secrets:
        box = _box(settings)
        for name, token in secrets.items():
            values[name] = box.decrypt(token)
    return values


def write(settings: Any, entry_id: str, values: dict[str, Any], secret_names: set[str]) -> None:
    """整份写入（原子替换）。``secret_names`` 里的字段加密存放，值为 None 的敏感字段不存。"""
    box = _box(settings) if secret_names else None
    plain = {k: v for k, v in values.items() if k not in secret_names}
    secrets = {
        k: box.encrypt(str(v))  # type: ignore[union-attr]
        for k, v in values.items()
        if k in secret_names and v is not None
    }
    path = _path(settings, entry_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(
        json.dumps({"values": plain, "secrets": secrets}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    os.replace(tmp, path)


def snapshot(settings: Any, entry_id: str) -> bytes | None:
    """当前文件的原样内容（保存失败时恢复用）；没有文件为 None。"""
    try:
        return _path(settings, entry_id).read_bytes()
    except FileNotFoundError:
        return None


def restore(settings: Any, entry_id: str, content: bytes | None) -> None:
    path = _path(settings, entry_id)
    if content is None:
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def overlay(settings: Any):  # type: ignore[no-untyped-def]
    """给内核的配置覆盖函数：条目 id → 界面保存的设置。"""
    return lambda entry_id: read(settings, entry_id)
