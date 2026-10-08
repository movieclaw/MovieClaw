"""推送分发：选通道 → 发给中继 → 处理每条结果（docs/design/cloud-push.md §3）。

- **选通道**：每台设备按 Bundle ID 在可用通道里排出候选；整批请求失败（连不上、5xx、
  401）换下一个候选，官方通道先在自己的多个地址之间切换。
- **结果**：``unregistered`` 清掉设备登记，``bad_token`` 只标记，``rate_limited`` 在
  ``retry_after`` 之前不再往这个通道发，``apns_error`` 可重试的稍后再试。
- **重试**：所有候选都失败的消息 30 秒、2 分钟后各再试一次；消息带 24 小时过期时间，
  过期的不再发。
- 推送全在后台任务里，任何异常只记日志，不影响业务链路。日志只记追踪 id、设备名和结果，
  不记内容、令牌和密钥。
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass, field
from datetime import timedelta

from movieclaw_api.services.push import channels as channel_registry
from movieclaw_api.services.push import registration, relay
from movieclaw_api.services.push.channels import Channel
from movieclaw_api.services.push.relay import RelayError
from movieclaw_db.models import utcnow

logger = logging.getLogger("movieclaw_api.push")

#: 提醒类推送的过期时间：苹果最多替我们存这么久，手机一直关机就不再送
ALERT_TTL = timedelta(hours=24)
RETRY_DELAYS = (30, 120)

#: 在飞的后台任务（只持弱引用的话任务可能中途被回收，推送无声丢失）
_tasks: set[asyncio.Task] = set()


@dataclass
class Outgoing:
    """一条要发出去的推送（已加密）。"""

    device_id: int
    device_name: str
    topic: str
    message: dict
    expires_at: int
    #: 已经试过、整批失败的通道（换下一个候选时跳过）
    failed_channels: set[str] = field(default_factory=set)

    @property
    def token(self) -> str:
        """发出时用的设备令牌（小写十六进制）。"""
        return str(self.message.get("token") or "")


@dataclass
class Outcome:
    """一条推送的最终结果（测试推送要逐台显示）。"""

    device_id: int
    device_name: str
    result: str
    message: str = ""
    channel_id: str | None = None


def build_message(
    *,
    token: str,
    topic: str,
    environment: str,
    payload: str,
    collapse_id: str | None = None,
    level: str = "active",
    relevance: float | None = None,
) -> dict:
    """中继协议的一条推送消息（第 5.2 节）。``payload`` 是加密后的明文。

    ``level`` 是打扰级别（协议 §7 的 ``interruption-level``）：passive 不带声音、不亮屏；
    ``relevance`` 是系统通知摘要里的排序分（``relevance-score``）。
    """
    message: dict = {
        "id": str(uuid.uuid4()),
        "platform": "apns",
        "token": token,
        "topic": topic,
        "environment": environment,
        "type": "alert",
        "priority": 10,
        "expires_at": int((utcnow() + ALERT_TTL).timestamp()),
        "payload": payload,
    }
    aps: dict = {} if level == "passive" else {"sound": "default"}
    if level != "active":
        aps["interruption-level"] = level
    if relevance is not None:
        aps["relevance-score"] = round(min(1.0, max(0.0, relevance)), 2)
    if aps:
        message["aps"] = aps
    if collapse_id:
        message["collapse_id"] = collapse_id
    return message


def spawn(coro) -> None:  # type: ignore[no-untyped-def]
    """起后台任务并持住强引用；没有事件循环（测试、关闭中）就跳过。"""
    try:
        task = asyncio.get_running_loop().create_task(coro)
    except RuntimeError:
        coro.close()
        logger.debug("没有运行中的事件循环，推送已跳过")
        return
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


async def deliver(items: list[Outgoing], *, attempt: int = 0) -> list[Outcome]:
    """发出一批推送，返回每条的结果。所有候选都失败的消息安排稍后重试。"""
    if not items:
        return []
    channels = await channel_registry.load_channels()
    outcomes: list[Outcome] = []
    pending = list(items)
    retry: list[Outgoing] = []
    # 每一轮按「第一个还没失败过的候选通道」分组发送；整批失败的换下一个候选再来一轮
    while pending:
        groups: dict[str, list[Outgoing]] = {}
        by_id = {c.id: c for c in channels}
        for item in pending:
            candidates = [
                c
                for c in channel_registry.route(channels, item.topic)
                if c.id not in item.failed_channels
            ]
            available = [
                c
                for c in candidates
                if not channel_registry.runtime(c.id).blocked()
                and channel_registry.runtime(c.id).device_block(item.token) is None
            ]
            if not candidates:
                if item.failed_channels:
                    retry.append(item)
                else:
                    outcomes.append(
                        Outcome(
                            item.device_id,
                            item.device_name,
                            "no_channel",
                            "没有能推这个 App 的可用通道",
                        )
                    )
                continue
            if not available:
                state = channel_registry.runtime(candidates[0].id)
                outcomes.append(
                    Outcome(
                        item.device_id,
                        item.device_name,
                        "rate_limited",
                        (state.blocked_message if state.blocked() else None)
                        or state.device_block(item.token)
                        or "今天的推送额度已经用完",
                        candidates[0].id,
                    )
                )
                continue
            groups.setdefault(available[0].id, []).append(item)
        pending = []
        for channel_id, group in groups.items():
            channel = by_id[channel_id]
            for start in range(0, len(group), channel.max_batch):
                batch = group[start : start + channel.max_batch]
                sent = await _send_batch(channel, batch)
                if sent is None:
                    for item in batch:
                        item.failed_channels.add(channel.id)
                    pending.extend(batch)
                else:
                    outcomes.extend(sent)
                    retry.extend(
                        item
                        for item, outcome in zip(batch, sent, strict=True)
                        if outcome.result == "retry"
                    )
    final = [o for o in outcomes if o.result != "retry"]
    if retry:
        if attempt < len(RETRY_DELAYS):
            for item in retry:
                item.failed_channels.clear()
            spawn(_retry_later(retry, attempt))
            final.extend(
                Outcome(i.device_id, i.device_name, "queued", "通道暂时不可用，稍后自动重试")
                for i in retry
            )
        else:
            final.extend(
                Outcome(i.device_id, i.device_name, "failed", "通道一直不可用，重试后仍没发出去")
                for i in retry
            )
    return final


async def _retry_later(items: list[Outgoing], attempt: int) -> None:
    await asyncio.sleep(RETRY_DELAYS[attempt])
    now = int(utcnow().timestamp())
    alive = [i for i in items if i.expires_at > now]
    if not alive:
        return
    try:
        results = await deliver(alive, attempt=attempt + 1)
        logger.info(
            "推送重试（第 %d 次）：%s",
            attempt + 1,
            "、".join(f"{o.device_name}={o.result}" for o in results),
        )
    except Exception:  # noqa: BLE001
        logger.exception("推送重试出错（已忽略）")


async def _send_batch(channel: Channel, batch: list[Outgoing]) -> list[Outcome] | None:
    """往一个通道发一批。整批失败返回 None（调用方换下一个候选）。"""
    state = channel_registry.runtime(channel.id)
    messages = [item.message for item in batch]
    response = None
    error: RelayError | None = None
    for url in channel.urls:
        try:
            response = await relay.push(
                url, messages, bearer=channel.bearer, lan_direct=channel.lan_direct
            )
            break
        except RelayError as exc:
            error = exc
            logger.warning("推送通道「%s」（%s）失败：%s", channel.name, url, exc.message)
            if not exc.retryable:
                break
    if response is None:
        assert error is not None
        state.record_failure(error.message, unreachable=error.network)
        if channel.kind == "official" and error.code in ("unauthorized", "forbidden"):
            # 官方中继每次都查实例状态：拒绝说明令牌失效或在官网解绑了。马上续签一次——
            # 解绑了尽快显示「已断开」，令牌失效就换新的，稍后的重试用新令牌
            from movieclaw_api.services.cloud import get_cloud_service

            get_cloud_service().request_renew()
        if error.retryable:
            return None
        return [
            Outcome(i.device_id, i.device_name, "failed", error.message, channel.id) for i in batch
        ]

    state.record_success(response.quota)
    outcomes: list[Outcome] = []
    for item, result in zip(batch, response.results, strict=True):
        outcome = await _handle_result(channel, item, result)
        outcomes.append(outcome)
        logger.info(
            "推送 %s → %s（%s）：%s",
            item.message["id"],
            item.device_name,
            channel.name,
            outcome.result,
        )
    return outcomes


async def _handle_result(channel: Channel, item: Outgoing, result: dict) -> Outcome:
    code = str(result.get("result") or "")
    message = str(result.get("message") or "")
    outcome = Outcome(item.device_id, item.device_name, code or "failed", message, channel.id)
    state = channel_registry.runtime(channel.id)
    if code == "ok":
        return outcome
    # 只动发出时用的那个令牌：发送途中 App 换了令牌重新登记，不能把新登记一起清掉
    if code == "unregistered":
        await registration.mark_unregistered(item.device_id, item.token)
    elif code == "bad_token":
        await registration.mark_problem(item.device_id, "bad_token", item.token)
    elif code == "rate_limited":
        retry_after = result.get("retry_after")
        seconds = retry_after if isinstance(retry_after, int) and retry_after > 0 else 3600
        until = utcnow() + timedelta(seconds=seconds)
        if (result.get("limit") or result.get("reason")) == "day":
            # 整台服务器当天的额度用完：这个通道到点之前不再发
            state.blocked_until = until
            state.blocked_message = message or "今天的推送额度已经用完"
        else:
            # 按设备（device_day）或别的维度的限制：只挡这台设备，家里别的设备照常收
            state.device_blocks[item.token] = (
                until,
                message or "这台设备今天的推送已达上限",
            )
    elif code == "apns_error" and result.get("retryable"):
        outcome.result = "retry"
    elif code == "topic_not_allowed":
        state.record_failure(message or "中继不推这个 App")
    else:
        logger.warning("推送 %s 被拒：%s %s", item.message["id"], code, message)
    return outcome
