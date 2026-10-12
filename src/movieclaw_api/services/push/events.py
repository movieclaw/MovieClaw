"""订阅类推送的旧产生函数（迁移中，P2 改为发 ``subscription.*`` 事件后删除）。"""

from __future__ import annotations

import functools
import logging

logger = logging.getLogger("movieclaw_api.push.events")


def _never_raise(func):  # type: ignore[no-untyped-def]
    """产生点在业务链路上：推送这边出任何错都只记日志，不能把业务打断。"""

    @functools.wraps(func)
    def wrapper(*args, **kwargs):  # type: ignore[no-untyped-def]
        try:
            func(*args, **kwargs)
        except Exception:  # noqa: BLE001
            logger.exception("准备 App 推送失败（已忽略）")

    return wrapper


# ----------------------------------------------------------------------
# 订阅类事件：只投事件，合并与文案在推送事件中枢里做（hub.py、cards.py）
# ----------------------------------------------------------------------


def _units(units: list[tuple[int, int]]) -> tuple[tuple[int, int], ...]:
    return tuple((int(s), int(e)) for s, e in units)


@_never_raise
def imported(*, subscription_id: int, item_id: int, units: list[tuple[int, int]]) -> None:
    """订阅的这几集整理进媒体库了：进这部剧的卡（cards.py）。"""
    from movieclaw_api.services.push.hub import Imported, emit

    emit(Imported(subscription_id=subscription_id, item_id=item_id, units=_units(units)))


@_never_raise
def download_started(
    *,
    subscription_id: int,
    item_id: int,
    units: list[tuple[int, int]],
    detail: str,
    upgrade: bool,
    skip_member_id: int | None = None,
) -> None:
    """订阅找到资源、交给下载器了。``skip_member_id``：手动选种时点下载的人，不推给他。"""
    from movieclaw_api.services.push.hub import Started, emit

    emit(
        Started(
            subscription_id=subscription_id,
            item_id=item_id,
            units=_units(units),
            detail=detail,
            upgrade=upgrade,
            skip_member_id=skip_member_id,
        )
    )


@_never_raise
def upgraded(
    *,
    subscription_id: int,
    item_id: int,
    unit: tuple[int, int],
    old_label: str,
    new_label: str,
) -> None:
    """订阅的一集换成了更好的版本（同一个订阅一分钟内的合成一条，cards.py）。"""
    from movieclaw_api.services.push.hub import Upgraded, emit

    emit(
        Upgraded(
            subscription_id=subscription_id,
            item_id=item_id,
            unit=(int(unit[0]), int(unit[1])),
            old_label=old_label,
            new_label=new_label,
        )
    )
