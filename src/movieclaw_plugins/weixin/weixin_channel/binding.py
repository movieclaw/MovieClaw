"""微信扫码绑定状态机(Web 化)。

与 CLI 场景(openclaw 从 stdin 读配对码)不同,这里面向 Web 设置页:

- ``begin()`` 拿二维码并启动后台轮询任务,立即返回 challenge;
- 后台任务对 iLink 做长轮询(单次最长 35s),把最新状态写进 challenge;
- **前端 poll 的接口只读内存快照,毫秒级返回**——绝不把前端请求穿透到
  iLink 长轮询上;
- ``need_verify_code`` 状态时前端弹输入框,``submit_verify_code()`` 置码并
  唤醒后台任务带码重查;
- ``confirmed`` 前先执行 ``on_confirmed`` 回调(落库凭据 + 热启动收发循环),
  回调成功才对外呈现 confirmed——前端看到完成时通道已经活了。

状态机(对外呈现的 status):
    pending → scanned → confirmed
            ↘ need_verify_code ↗(码错重入 need_verify_code)
    pending → already_bound / expired / failed(终态)
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

from .client import DEFAULT_BASE_URL, fetch_qrcode, poll_qr_status

logger = logging.getLogger("movieclaw_plugins.weixin.binding")

#: 一次绑定 challenge 的总时限(超时置 expired)
_CHALLENGE_TTL_S = 5 * 60
#: 二维码过期自动刷新的最大次数
_MAX_QR_REFRESH = 3
#: 相邻两次状态轮询的间隔(服务端本身长轮询,这里只是节流)
_POLL_INTERVAL_S = 1.0

_TERMINAL_STATUSES = {"confirmed", "already_bound", "expired", "failed"}


@dataclass(frozen=True, slots=True)
class BindingResult:
    """扫码确认后服务端签发的凭据。"""

    bot_id: str
    bot_token: str
    #: 扫码人的微信用户 id(写入白名单:谁扫码谁才能对话)
    user_id: str
    #: 服务端指定的就近接入地址(空则用默认)
    base_url: str


@dataclass(slots=True)
class BindingChallenge:
    """一次绑定流程的全部状态(内存态,进程重启即失效)。"""

    challenge_id: str
    status: str = "pending"
    qrcode_url: str = ""
    #: 面向用户的中文提示(配对码错误、失败原因等)
    message: str = "请用手机微信扫描二维码"
    result: BindingResult | None = None
    # ---- 以下为内部字段 ----
    qrcode: str = ""
    poll_base_url: str = DEFAULT_BASE_URL
    verify_code: str | None = None
    code_event: asyncio.Event = field(default_factory=asyncio.Event)
    started_at: float = field(default_factory=time.monotonic)
    task: asyncio.Task[None] | None = None


class WeixinBindingRegistry:
    """绑定 challenge 注册表(进程级单例,由 API 服务层持有)。"""

    def __init__(
        self,
        *,
        on_confirmed: Callable[[BindingResult], Awaitable[None]],
        get_local_tokens: Callable[[], Awaitable[list[str]]],
    ) -> None:
        self._on_confirmed = on_confirmed
        self._get_local_tokens = get_local_tokens
        self._challenges: dict[str, BindingChallenge] = {}

    # ------------------------------------------------------------------
    # 对外操作(API 层调用)
    # ------------------------------------------------------------------
    async def begin(self) -> BindingChallenge:
        """发起绑定:取二维码、启动后台轮询任务,立即返回。

        单飞:同一时刻只保留一个进行中的绑定流程。反复进入绑定页/重复点击
        「新增绑定」会终止旧流程,避免孤儿轮询任务在后台空转 5 分钟。
        """
        self._purge_expired()
        for old in self._challenges.values():
            if old.status not in _TERMINAL_STATUSES:
                old.status = "expired"
                old.message = "已发起新的绑定,本流程终止"
                if old.task is not None and not old.task.done():
                    old.task.cancel()
        tokens = await self._get_local_tokens()
        qr = await fetch_qrcode(DEFAULT_BASE_URL, tokens)
        qrcode = str(qr.get("qrcode") or "")
        qrcode_url = str(qr.get("qrcode_img_content") or "")
        if not qrcode or not qrcode_url:
            raise RuntimeError("获取微信二维码失败:服务端未返回二维码内容")

        challenge = BindingChallenge(
            challenge_id=uuid.uuid4().hex[:16], qrcode=qrcode, qrcode_url=qrcode_url
        )
        challenge.task = asyncio.create_task(
            self._drive(challenge), name=f"weixin-binding-{challenge.challenge_id}"
        )
        self._challenges[challenge.challenge_id] = challenge
        logger.info("微信绑定已发起 challenge=%s", challenge.challenge_id)
        return challenge

    def get(self, challenge_id: str) -> BindingChallenge | None:
        return self._challenges.get(challenge_id)

    def submit_verify_code(self, challenge_id: str, code: str) -> bool:
        """提交手机上显示的配对数字;challenge 不存在或已终态返回 False。"""
        challenge = self._challenges.get(challenge_id)
        if challenge is None or challenge.status in _TERMINAL_STATUSES:
            return False
        challenge.verify_code = code.strip()
        challenge.code_event.set()
        return True

    async def close(self) -> None:
        for challenge in self._challenges.values():
            if challenge.task and not challenge.task.done():
                challenge.task.cancel()

    # ------------------------------------------------------------------
    # 后台状态机
    # ------------------------------------------------------------------
    async def _drive(self, ch: BindingChallenge) -> None:
        """轮询 iLink 扫码状态直到终态或超时。"""
        deadline = ch.started_at + _CHALLENGE_TTL_S
        qr_refresh_count = 0
        try:
            while time.monotonic() < deadline:
                resp = await poll_qr_status(ch.poll_base_url, ch.qrcode, ch.verify_code)
                status = str(resp.get("status") or "wait")

                if status == "wait":
                    pass
                elif status == "scaned":
                    # 带码轮询后回到 scaned = 配对码正确,清除暂存
                    ch.verify_code = None
                    ch.status = "scanned"
                    ch.message = "已扫码,请在手机上确认"
                elif status == "need_verifycode":
                    rejected = ch.verify_code is not None
                    ch.verify_code = None
                    ch.status = "need_verify_code"
                    ch.message = (
                        "配对码不正确,请重新输入" if rejected else "请输入手机微信上显示的数字"
                    )
                    ch.code_event.clear()
                    # 等用户在网页上输入配对码(或整体超时)
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        await asyncio.wait_for(ch.code_event.wait(), timeout=remaining)
                    except TimeoutError:
                        break
                    ch.status = "scanned"
                    ch.message = "正在校验配对码…"
                    continue  # 立即带码重查
                elif status == "verify_code_blocked":
                    ch.status = "failed"
                    ch.message = "配对码错误次数过多,请稍后重新发起绑定"
                    return
                elif status == "expired":
                    qr_refresh_count += 1
                    if qr_refresh_count > _MAX_QR_REFRESH:
                        ch.status = "expired"
                        ch.message = "二维码多次过期,请重新发起绑定"
                        return
                    tokens = await self._get_local_tokens()
                    qr = await fetch_qrcode(DEFAULT_BASE_URL, tokens)
                    ch.qrcode = str(qr.get("qrcode") or "")
                    ch.qrcode_url = str(qr.get("qrcode_img_content") or "")
                    ch.status = "pending"
                    ch.message = "二维码已刷新,请重新扫描"
                    logger.info(
                        "绑定二维码已刷新(%d/%d) challenge=%s",
                        qr_refresh_count,
                        _MAX_QR_REFRESH,
                        ch.challenge_id,
                    )
                elif status == "scaned_but_redirect":
                    # IDC 就近调度:切换后续轮询主机
                    host = str(resp.get("redirect_host") or "")
                    if host:
                        ch.poll_base_url = f"https://{host}"
                        logger.info("绑定轮询已重定向到 %s", host)
                elif status == "binded_redirect":
                    ch.status = "already_bound"
                    ch.message = "该微信已绑定过本实例,无需重复绑定"
                    return
                elif status == "confirmed":
                    bot_id = str(resp.get("ilink_bot_id") or "")
                    bot_token = str(resp.get("bot_token") or "")
                    if not bot_id or not bot_token:
                        ch.status = "failed"
                        ch.message = "绑定失败:服务端未返回完整凭据"
                        return
                    result = BindingResult(
                        bot_id=bot_id,
                        bot_token=bot_token,
                        user_id=str(resp.get("ilink_user_id") or ""),
                        base_url=str(resp.get("baseurl") or "") or DEFAULT_BASE_URL,
                    )
                    # 先落库并热启动收发循环,成功后才对外呈现 confirmed
                    try:
                        await self._on_confirmed(result)
                    except Exception:
                        logger.exception("绑定确认回调失败 challenge=%s", ch.challenge_id)
                        ch.status = "failed"
                        ch.message = "绑定成功但保存/启动失败,请查看日志后重试"
                        return
                    ch.result = result
                    ch.status = "confirmed"
                    ch.message = "绑定完成,微信通道已启动"
                    logger.info("微信绑定完成 bot=%s", bot_id)
                    return
                else:
                    logger.warning("未知扫码状态 %s,按等待处理", status)

                await asyncio.sleep(_POLL_INTERVAL_S)

            ch.status = "expired"
            ch.message = "绑定超时,请重新发起"
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("绑定状态机异常 challenge=%s", ch.challenge_id)
            ch.status = "failed"
            ch.message = "绑定过程出错,请重试(详情见日志)"

    def _purge_expired(self) -> None:
        """清掉已终态且超过 TTL 的历史 challenge,防止内存泄漏。"""
        now = time.monotonic()
        for cid in list(self._challenges):
            ch = self._challenges[cid]
            if now - ch.started_at > _CHALLENGE_TTL_S and ch.status in _TERMINAL_STATUSES:
                del self._challenges[cid]
