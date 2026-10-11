"""通知的 IM 渠道（docs/design/cloud-push.md §5）：IM 只是一个人的一个通知渠道。

推不推、推给谁和 App 推送完全一样——偏好、静音、可见范围都在 ``notify`` 里算过了；
这里只把同一份文案写成 IM 消息，交给通道中枢发到这个人绑定的 IM 账号（群机器人也算
绑定人的）。IM 消息发出去不能原地替换，所以剧卡的进度更新不发（``notify(to_im=False)``）。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from movieclaw_api.services.push.dispatcher import Outcome

logger = logging.getLogger("movieclaw_api.push.im")


@dataclass(frozen=True)
class ImMessage:
    member_id: int
    text: str
    #: 带签名的配图相对路径（services/push/images.py），None = 纯文本
    image: str | None = None


def owners() -> set[int]:
    """有 IM 账号在运行的成员；中枢没运行时为空。"""
    from movieclaw_api.services.channel_hub import get_hub

    hub = get_hub()
    return hub.account_owners() if hub is not None else set()


def count(member_id: int) -> int:
    """这个人在运行的 IM 账号数；中枢没运行时为 0。"""
    from movieclaw_api.services.channel_hub import get_hub

    hub = get_hub()
    return hub.account_count(member_id) if hub is not None else 0


def render(member_id: int, content) -> ImMessage:  # type: ignore[no-untyped-def]
    """App 通知的标题 / 副标题 / 正文，一段一行。"""
    lines = [content.title, content.subtitle, content.body]
    return ImMessage(
        member_id=member_id,
        text="\n".join(line for line in lines if line),
        image=content.image,
    )


async def _photo(image: str | None) -> bytes | None:
    if not image:
        return None
    from movieclaw_api.services.channel_push import fetch_image
    from movieclaw_api.services.push.images import IMAGE_PATH_PREFIX, resolve_image

    url = await resolve_image(image.removeprefix(IMAGE_PATH_PREFIX))
    return await fetch_image(url) if url else None


async def deliver(messages: list[ImMessage]) -> list[Outcome]:
    """发出去：每个人一条结果（交给了几个 IM 账号）。"""
    from movieclaw_api.services.channel_hub import get_hub

    hub = get_hub()
    if hub is None or not messages:
        return []
    outcomes: list[Outcome] = []
    for message in messages:
        try:
            sent = await hub.push(
                message.text, photo=await _photo(message.image), member_id=message.member_id
            )
        except Exception:  # noqa: BLE001 -- 一个人发失败不影响别人
            logger.exception("IM 通知发送失败（已忽略）")
            sent = 0
        outcomes.append(
            Outcome(
                0,
                "IM",
                "ok" if sent else "failed",
                f"已交给 {sent} 个 IM 账号发送" if sent else "IM 账号没有推送目标，重新绑定试试",
                "im",
            )
        )
    return outcomes
