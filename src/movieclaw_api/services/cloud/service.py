"""MovieClaw Cloud：连接（设备授权）、续签与上报、解绑（docs/design/cloud-push.md §2）。

一个进程级单例 ``CloudService``，随应用启动、关闭：

- **未连接时不发任何请求**：没有凭证就不起续签循环；配对只在管理员点「连接」后进行。
- **配对**：配对码、``device_code`` 只在内存里（不落库、不写日志），后台按 ``interval``
  轮询；服务重启后配对作废，重新点连接即可。
- **续签**：按云端给的间隔加 ±10% 抖动；失败从 30 秒起指数退避到 1 小时。旧令牌在过期前
  照常用——令牌和实例凭证一起加密落库，重启时云端恰好连不上，推送也能撑到令牌过期。
- **结果处理**：401 说明在官网解绑了，删除本地凭证；403 版本不受支持，保留凭证照常续签
  （升级后自动恢复）；连不上、5xx、400 退避重试，令牌快过期时在待处理事项里告诉管理员。

状态的唯一事实源是配置域 ``CloudSetting``；写之前先复制一份再改，改完整体保存，
避免改了一半的对象留在配置缓存里。
"""

from __future__ import annotations

import asyncio
import contextlib
import io
import logging
import platform
import random
import time
from base64 import b64encode
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta

import qrcode
import qrcode.image.svg

from movieclaw_api import __version__
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import AppException, BadRequestException, ConflictException
from movieclaw_api.services.cloud import client
from movieclaw_api.services.cloud.client import CloudUnreachable
from movieclaw_api.settings import get_setting_store
from movieclaw_api.settings.cloud import CloudDiscovery, CloudNotice, CloudSetting
from movieclaw_db.models import utcnow

logger = logging.getLogger("movieclaw_api.cloud")

DEFAULT_CLOUD_URL = "https://api.movieclaw.io"
#: 从没拉到过发现文档、又用的是默认云端地址时，官方中继的内置地址
DEFAULT_PUSH_ENDPOINTS = ["https://push.movieclaw.io"]

_RENEW_MIN_S = 300
_RENEW_MAX_S = 24 * 3600
_BACKOFF_FIRST_S = 30
_BACKOFF_MAX_S = 3600
#: 配对轮询间隔下限（秒）：云端给的 interval 再小也不低于它，免得把云端打爆
_PAIRING_MIN_INTERVAL_S: float = 1
#: 配对成功后首次续签（带上报）的延迟（秒）：马上发一次，让官网实例详情尽快有内容
_FIRST_RENEW_DELAY_S: float = 1
#: 令牌剩不到这么久还没续上，就在待处理事项里告诉管理员
_EXPIRY_WARNING = timedelta(hours=6)
#: 官方中继拒绝令牌时提前续签，最多这么久一次（中继一直拒绝时不把云端打爆）
_FORCED_RENEW_INTERVAL_S = 300
#: 待处理事项（system_notice）里云端相关的 dedupe_key 前缀
NOTICE_PREFIX = "cloud:"


class CloudUnreachableError(AppException):
    """断开连接时云端连不上：前端据 ``code`` 问管理员要不要只断开本地。"""

    def __init__(self, message: str) -> None:
        super().__init__(status_code=409, code="CLOUD_UNREACHABLE", message=message)


@dataclass
class Pairing:
    """进行中的配对（只在内存里）。"""

    api: str
    device_code: str
    user_code: str
    verification_uri: str
    verification_uri_complete: str
    qrcode_image: str
    expires_at: datetime
    interval: float
    instance_name: str
    status: str = "pending"  # pending / denied / expired / error
    message: str | None = None


def jitter(seconds: float) -> float:
    """±10% 随机抖动：云端故障恢复时，各实例不会挤在同一刻续签。"""
    return seconds * random.uniform(0.9, 1.1)


def backoff_seconds(failures: int) -> float:
    """第 n 次连续失败后的等待：30 秒起、每次翻倍、最长 1 小时（未加抖动）。"""
    return float(min(_BACKOFF_MAX_S, _BACKOFF_FIRST_S * 2 ** max(0, failures - 1)))


def _qrcode_data_url(content: str) -> str:
    """二维码 SVG 的 data URL（与 IM 通道绑定同一种生成方式，前端直接 <img>）。"""
    image = qrcode.make(content, image_factory=qrcode.image.svg.SvgPathImage, box_size=12)
    buffer = io.BytesIO()
    image.save(buffer)
    return "data:image/svg+xml;base64," + b64encode(buffer.getvalue()).decode("ascii")


def _normalize_arch(machine: str) -> str:
    value = machine.lower()
    return {"x86_64": "amd64", "aarch64": "arm64"}.get(value, value)


def runtime_report_basics() -> dict:
    """续签必需的版本信息（不能关闭）。"""
    return {
        "instance_version": __version__,
        "runtime_version": f"python {platform.python_version()}",
        "os": platform.system().lower(),
        "arch": _normalize_arch(platform.machine()),
    }


class CloudService:
    """和 MovieClaw Cloud 的连接。进程级单例，见 ``get_cloud_service``。"""

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._pairing: Pairing | None = None
        self._pairing_task: asyncio.Task[None] | None = None
        self._renew_task: asyncio.Task[None] | None = None
        self._wake = asyncio.Event()
        self._closed = False
        #: 连续续签失败的次数与最近一次失败的说明（只在内存里，显示在 health 上）
        self._failures = 0
        self._last_error = ""
        #: 上一次因中继拒绝令牌而提前续签的时间（monotonic）
        self._forced_renew_at: float | None = None

    # ------------------------------------------------------------------
    # 生命周期
    # ------------------------------------------------------------------
    async def start(self) -> None:
        """应用启动：已连接就在 5–30 秒内先续签一次（离线期间可能已在官网解绑）。"""
        setting = await self.load()
        if setting.connected:
            self._ensure_renew_loop(first_delay=random.uniform(5, 30))

    async def close(self) -> None:
        self._closed = True
        for task in (self._pairing_task, self._renew_task):
            if task is not None and not task.done():
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await task
        self._pairing_task = None
        self._renew_task = None

    # ------------------------------------------------------------------
    # 状态
    # ------------------------------------------------------------------
    @staticmethod
    async def load() -> CloudSetting:
        return await get_setting_store().get(CloudSetting)

    async def _update(self, mutate: Callable[[CloudSetting], None]) -> CloudSetting:
        """复制 → 修改 → 整体保存。调用方须持有 ``self._lock``。"""
        setting = (await self.load()).model_copy(deep=True)
        mutate(setting)
        await get_setting_store().set(setting)
        return setting

    @property
    def pairing(self) -> Pairing | None:
        return self._pairing

    @property
    def failures(self) -> int:
        return self._failures

    @property
    def last_error(self) -> str:
        return self._last_error

    @staticmethod
    def cloud_url() -> str:
        return get_settings().cloud_url.strip().rstrip("/") or DEFAULT_CLOUD_URL

    def custom_cloud_url(self) -> bool:
        return self.cloud_url() != DEFAULT_CLOUD_URL

    def api_url(self, setting: CloudSetting) -> str:
        """之后的请求都用发现文档里的 api；没有就用连接时记下的，再没有就用云端地址。"""
        if setting.discovery and setting.discovery.api:
            return setting.discovery.api
        return setting.api_url or self.cloud_url()

    def push_endpoints(self, setting: CloudSetting) -> list[str]:
        """官方中继的地址（按优先级）。"""
        if setting.discovery and setting.discovery.push_endpoints:
            return list(setting.discovery.push_endpoints)
        return list(DEFAULT_PUSH_ENDPOINTS) if not self.custom_cloud_url() else []

    @staticmethod
    def token_valid(setting: CloudSetting) -> bool:
        return bool(
            setting.access_token
            and setting.token_expires_at is not None
            and setting.token_expires_at > utcnow()
        )

    def official_bearer(self, setting: CloudSetting) -> str | None:
        """官方中继可用时返回令牌：已连接、有 push 权限、令牌未过期、版本受支持。"""
        if (
            setting.connected
            and "push" in setting.scopes
            and not setting.unsupported_message
            and self.token_valid(setting)
        ):
            return setting.access_token
        return None

    def health(self, setting: CloudSetting) -> tuple[str, str | None]:
        """已连接时的健康状况：(ok / unreachable / expired / unsupported, 说明)。"""
        if setting.unsupported_message:
            return "unsupported", setting.unsupported_message
        if not self.token_valid(setting):
            reason = f"（{self._last_error}）" if self._last_error else ""
            return (
                "expired",
                f"连不上 MovieClaw Cloud{reason}，令牌已经过期，官方推送暂停。"
                "云端恢复后会自动续上；也可以检查网络或代理设置后点「立即同步」。",
            )
        if self._failures:
            assert setting.token_expires_at is not None
            hours = max(0, int((setting.token_expires_at - utcnow()).total_seconds() // 3600))
            return (
                "unreachable",
                f"最近一次同步失败：{self._last_error or '连不上 MovieClaw Cloud'}。"
                f"推送不受影响，还能维持约 {hours} 小时，期间会自动重试。",
            )
        return "ok", None

    # ------------------------------------------------------------------
    # 连接（RFC 8628 设备授权）
    # ------------------------------------------------------------------
    async def _discover(self) -> CloudDiscovery:
        """拉发现文档并缓存；拉不到时用缓存，从没拉到过就报错。"""
        try:
            discovery = await client.fetch_discovery(self.cloud_url())
        except CloudUnreachable:
            cached = (await self.load()).discovery
            if cached and cached.api:
                return cached
            raise
        await self._update(lambda s: setattr(s, "discovery", discovery))
        return discovery

    async def start_pairing(self, instance_name: str | None) -> Pairing:
        """开始连接：申请配对码，后台轮询。已连接时 409。"""
        async with self._lock:
            setting = await self.load()
            if setting.connected:
                raise ConflictException("这台服务器已经连接到 MovieClaw 账号，要换账号请先断开")
            name = (instance_name or "").strip() or await self.default_instance_name()
            if len(name) > 64:
                raise BadRequestException("服务器名称最长 64 个字")
            await self._stop_pairing()
            try:
                discovery = await self._discover()
                reply = await client.request_device_code(discovery.api, instance_name=name)
            except CloudUnreachable as exc:
                raise CloudUnreachableError(
                    f"{exc}。请检查这台服务器能不能上网，"
                    "或在「设置 → 网络」里让 MovieClaw Cloud 走代理"
                ) from exc
            if reply.status == 429:
                raise BadRequestException("申请配对码太频繁，请稍后再试")
            body = reply.body
            if reply.status != 200 or not body.get("device_code") or not body.get("user_code"):
                raise BadRequestException(
                    reply.message or f"MovieClaw Cloud 拒绝了连接请求（HTTP {reply.status}）"
                )
            complete = str(body.get("verification_uri_complete") or body.get("verification_uri"))
            pairing = Pairing(
                api=discovery.api,
                device_code=str(body["device_code"]),
                user_code=str(body["user_code"]),
                verification_uri=str(body.get("verification_uri") or complete),
                verification_uri_complete=complete,
                qrcode_image=_qrcode_data_url(complete),
                expires_at=utcnow() + timedelta(seconds=int(body.get("expires_in") or 600)),
                interval=max(_PAIRING_MIN_INTERVAL_S, int(body.get("interval") or 5)),
                instance_name=name,
            )
            self._pairing = pairing
            self._pairing_task = asyncio.get_running_loop().create_task(self._poll(pairing))
            logger.info(
                "开始连接 MovieClaw Cloud：配对码 %s，服务器名「%s」", pairing.user_code, name
            )
            return pairing

    async def cancel_pairing(self) -> None:
        async with self._lock:
            await self._stop_pairing()

    async def _stop_pairing(self) -> None:
        task, self._pairing_task = self._pairing_task, None
        self._pairing = None
        if task is not None and not task.done() and task is not asyncio.current_task():
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task

    @staticmethod
    async def default_instance_name() -> str:
        """连接时默认的服务器名称：Jellyfin 兼容层对播放器展示的服务器名。"""
        from movieclaw_api.settings.schemas import get_jellyfin_compat

        return (await get_jellyfin_compat()).server_name.strip() or "MovieClaw"

    async def _poll(self, pairing: Pairing) -> None:
        """按间隔轮询认领结果，直到批准、拒绝、过期或被取消。"""
        interval = pairing.interval
        try:
            while True:
                await asyncio.sleep(interval)
                if utcnow() >= pairing.expires_at:
                    pairing.status, pairing.message = "expired", "配对码已过期，请重新获取"
                    return
                try:
                    reply = await client.poll_token(pairing.api, device_code=pairing.device_code)
                except CloudUnreachable as exc:
                    pairing.message = f"{exc}，正在重试…"
                    continue
                if reply.status == 200:
                    await self._complete_pairing(pairing, reply.body)
                    return
                error = reply.code
                if error == "authorization_pending":
                    pairing.message = None
                    continue
                if error == "slow_down":
                    # RFC 8628 §3.5：之后一直用加了 5 秒的间隔
                    interval += 5
                    continue
                if not error or reply.status == 429:
                    # 不是云端的答复（网关、CDN 返回的限流或拦截页）：当作暂时连不上，接着轮询
                    pairing.message = (
                        f"MovieClaw Cloud 暂时不可用（HTTP {reply.status}），正在重试…"
                    )
                    if reply.status == 429:
                        interval += 5
                    continue
                if error == "access_denied":
                    pairing.status = "denied"
                    pairing.message = "这次连接在 movieclaw.io 上被拒绝了"
                elif error == "expired_token":
                    pairing.status, pairing.message = "expired", "配对码已过期，请重新获取"
                else:
                    pairing.status = "error"
                    pairing.message = reply.message or "配对失败，请重新获取配对码"
                logger.info(
                    "连接 MovieClaw Cloud 未完成：%s（%s）", pairing.status, error or reply.status
                )
                return
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 -- 轮询出错只结束这一次配对，不能拖垮应用
            logger.exception("连接 MovieClaw Cloud 时出错")
            pairing.status, pairing.message = "error", "配对出错了，请重新获取配对码"

    async def _complete_pairing(self, pairing: Pairing, data: dict) -> None:
        if not (
            data.get("instance_id") and data.get("instance_secret") and data.get("access_token")
        ):
            pairing.status, pairing.message = (
                "error",
                "MovieClaw Cloud 返回的凭证不完整，请重新获取配对码",
            )
            return
        now = utcnow()

        def apply(s: CloudSetting) -> None:
            s.instance_id = str(data["instance_id"])
            s.instance_secret = str(data["instance_secret"])
            s.instance_name = pairing.instance_name
            s.api_url = pairing.api
            s.connected_at = now
            account = data.get("account") if isinstance(data.get("account"), dict) else {}
            s.account_display = str(account.get("display") or "")
            s.notices, s.dismissed_notice_ids = [], []
            s.unsupported_message = ""
            s.last_disconnect_reason = s.last_disconnect_message = ""
            s.last_disconnect_at = None
            _apply_grant(s, data, now)

        async with self._lock:
            if self._pairing is not pairing:
                return  # 管理员在这期间取消或重新开始了配对
            await self._update(apply)
            self._pairing = None
            self._pairing_task = None
            self._failures, self._last_error = 0, ""
        _reset_official_channel()
        logger.info("已连接到 MovieClaw Cloud：实例 %s", data["instance_id"])
        await _resolve_cloud_notices()
        # 马上续签一次，把上报发上去（官网实例详情才有内容）
        self._ensure_renew_loop(first_delay=_FIRST_RENEW_DELAY_S)
        # 官方中继的能力快照（鉴权方式、能推的 App）也马上拉一次，不等半小时一轮的检查
        from movieclaw_api.services.push.channels import refresh_official_info

        with contextlib.suppress(Exception):
            await refresh_official_info()

    # ------------------------------------------------------------------
    # 续签与上报
    # ------------------------------------------------------------------
    def _ensure_renew_loop(self, *, first_delay: float, wake: bool = True) -> None:
        """续签循环没在跑就起一个；在跑且 ``wake`` 为真时让它马上续签一次。"""
        if self._closed:
            return
        if self._renew_task is not None and not self._renew_task.done():
            if wake:
                self._wake.set()
            return
        self._renew_task = asyncio.get_running_loop().create_task(self._renew_loop(first_delay))

    async def _renew_loop(self, delay: float) -> None:
        while not self._closed:
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self._wake.wait(), timeout=delay)
            self._wake.clear()
            try:
                outcome = await self.renew_once()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 -- 续签出错不能让循环退出
                logger.exception("续签 MovieClaw Cloud 时出错")
                outcome = "failed"
            if outcome == "disconnected":
                return
            setting = await self.load()
            if outcome == "failed":
                delay = jitter(backoff_seconds(self._failures))
            else:
                delay = jitter(min(_RENEW_MAX_S, max(_RENEW_MIN_S, setting.renew_interval)))

    async def renew_once(self) -> str:
        """续签并上报一次。返回 ok / unsupported / failed / disconnected。"""
        async with self._lock:
            setting = await self.load()
            if not setting.connected:
                return "disconnected"
            # 发现文档顺带刷新（拉不到用缓存，不影响续签）
            with contextlib.suppress(CloudUnreachable):
                await self._discover()
                setting = await self.load()
            # 例行检查官方中继：中继据此记下这台服务器在线；连不上时上报给云端。结果先存下，
            # 这次续签失败也不丢
            from movieclaw_api.services.push.channels import check_official

            check = await check_official(setting)
            setting = await self._update(lambda s: setattr(s, "relay_check", check))
            report = await build_report(setting)
            try:
                reply = await client.renew(
                    self.api_url(setting), instance_secret=setting.instance_secret, report=report
                )
            except CloudUnreachable as exc:
                return await self._renew_failed(setting, str(exc))

            if (
                reply.status == 200
                and reply.body.get("success")
                and isinstance(reply.body.get("data"), dict)
            ):
                data = reply.body["data"]
                now = utcnow()
                limits_changed = isinstance(data.get("limits"), dict) and (
                    data["limits"] != setting.limits
                )

                def apply(s: CloudSetting) -> None:
                    _apply_grant(s, data, now)
                    account = data.get("account") if isinstance(data.get("account"), dict) else {}
                    if account.get("display"):
                        s.account_display = str(account["display"])
                    s.notices = [
                        CloudNotice.model_validate(n)
                        for n in data.get("notices") or []
                        if isinstance(n, dict) and n.get("id")
                    ]
                    s.unsupported_message = ""
                    s.last_report, s.last_report_at = report, now

                await self._update(apply)
                self._failures, self._last_error = 0, ""
                logger.info("已续签 MovieClaw Cloud")
                if limits_changed:
                    # 云端调了额度（比如管理员给这台服务器加了额度）：之前因额度用完的封锁
                    # 解除，下一条推送以中继的答复为准，不用等到 UTC 零点
                    from movieclaw_api.services.push import channels

                    channels.runtime(channels.OFFICIAL_ID).clear_blocks()
                await _resolve_cloud_notices()
                return "ok"

            if reply.status == 401 and reply.code in ("UNAUTHORIZED", "INSTANCE_REVOKED"):
                # 只认云端自己的答复：网关、代理返回的 401 不能让管理员重新配对
                message = reply.message or "这台服务器已经和 MovieClaw 账号断开"
                await self._drop_credentials(reason="revoked", message=message)
                logger.warning(
                    "MovieClaw Cloud 说这台服务器已解绑（%s），已删除本地凭证", reply.code
                )
                await _raise_notice(
                    "revoked",
                    severity="warning",
                    title="这台服务器已和 MovieClaw Cloud 断开",
                    message=(
                        f"{message}。手机上的官方推送已停止；"
                        "要继续使用，请在「设置 → MovieClaw Cloud」重新连接。"
                    ),
                )
                return "disconnected"

            if reply.status == 403 and reply.code == "VERSION_UNSUPPORTED":
                message = reply.message or "这个版本已不再受 MovieClaw 官方推送支持，请升级"

                def mark(s: CloudSetting) -> None:
                    s.unsupported_message = message
                    s.last_report, s.last_report_at = report, utcnow()

                await self._update(mark)
                self._failures, self._last_error = 0, ""
                logger.warning("MovieClaw Cloud：%s", message)
                await _raise_notice(
                    "version",
                    severity="error",
                    title="官方推送已暂停：需要升级",
                    message=f"{message}。升级后会自动恢复，不用重新连接。",
                )
                return "unsupported"

            detail = reply.message or f"HTTP {reply.status}"
            return await self._renew_failed(setting, f"MovieClaw Cloud 拒绝了续签：{detail}")

    async def _renew_failed(self, setting: CloudSetting, error: str) -> str:
        """续签失败：记下原因；令牌快过期了就告诉管理员。调用方持有锁。"""
        self._failures += 1
        self._last_error = error
        logger.warning("续签 MovieClaw Cloud 失败（第 %d 次）：%s", self._failures, error)
        expires = setting.token_expires_at
        if expires is None or expires - utcnow() < _EXPIRY_WARNING:
            expired = expires is None or expires <= utcnow()
            await _raise_notice(
                "unreachable",
                severity="error" if expired else "warning",
                title="连不上 MovieClaw Cloud",
                message=(
                    f"{error}。"
                    + (
                        "令牌已经过期，官方推送暂停；"
                        if expired
                        else "令牌快要过期，过期后官方推送会暂停；"
                    )
                    + "请检查这台服务器能不能上网，或在「设置 → 网络」里让 MovieClaw Cloud 走代理。"
                ),
            )
        return "failed"

    def request_renew(self) -> None:
        """官方中继拒绝了令牌：不等下一个整点，马上在后台续签一次（5 分钟内最多一次）。

        中继每次推送都查实例状态：在官网解绑后，续签会拿到 401 并显示「已断开」；
        只是令牌失效的话，续签换到新令牌，推送的重试就能接上。
        """
        if self._closed or self._renew_task is None or self._renew_task.done():
            return  # 没在续签（未连接）就不用管
        now = time.monotonic()
        if (
            self._forced_renew_at is not None
            and now - self._forced_renew_at < _FORCED_RENEW_INTERVAL_S
        ):
            return
        self._forced_renew_at = now
        logger.info("官方推送中继拒绝了令牌，提前续签一次")
        # 错开几秒到半分钟：中继配置出错时所有实例同时被拒，不能同一时刻一起去续签
        asyncio.get_running_loop().call_later(random.uniform(1, 30), self._wake.set)

    async def renew_now(self) -> None:
        """管理员点「立即同步」：在请求里同步续签一次，结果反映在 health 上。"""
        setting = await self.load()
        if not setting.connected:
            raise BadRequestException("这台服务器还没有连接到 MovieClaw 账号")
        outcome = await self.renew_once()
        if outcome != "disconnected":
            # 循环在跑就按它原来的节奏走（不再唤醒，免得连着续签两次）；没在跑才补起一个
            self._ensure_renew_loop(first_delay=jitter(setting.renew_interval), wake=False)

    # ------------------------------------------------------------------
    # 断开
    # ------------------------------------------------------------------
    async def disconnect(self, *, force: bool) -> None:
        async with self._lock:
            setting = await self.load()
            if not setting.connected:
                await self._stop_pairing()
                return
            try:
                reply = await client.unbind(
                    self.api_url(setting), instance_secret=setting.instance_secret
                )
                if reply.status not in (200, 401):
                    raise CloudUnreachable(reply.message or f"HTTP {reply.status}")
            except CloudUnreachable as exc:
                if not force:
                    raise CloudUnreachableError(
                        f"{exc}。仍要断开的话，这台服务器在 movieclaw.io 上还会显示为已连接，"
                        "请到官网把它也删掉"
                    ) from exc
                logger.warning("云端连不上，只删除了本地凭证：%s", exc)
            await self._drop_credentials(reason="", message="")
        task, self._renew_task = self._renew_task, None
        if task is not None and not task.done():
            task.cancel()
        await _resolve_cloud_notices()
        logger.info("已断开 MovieClaw Cloud")

    async def _drop_credentials(self, *, reason: str, message: str) -> None:
        """删除本地凭证，回到未连接。保留统计开关和发现文档缓存。调用方持有锁。"""
        now = utcnow()

        def apply(s: CloudSetting) -> None:
            kept_stats, kept_discovery = s.report_stats, s.discovery
            fresh = CloudSetting(report_stats=kept_stats, discovery=kept_discovery)
            for name in CloudSetting.model_fields:
                setattr(s, name, getattr(fresh, name))
            s.last_disconnect_reason = reason
            s.last_disconnect_message = message
            s.last_disconnect_at = now if reason else None

        await self._update(apply)
        self._failures, self._last_error = 0, ""
        _reset_official_channel()

    # ------------------------------------------------------------------
    # 其他设置
    # ------------------------------------------------------------------
    async def set_report_stats(self, enabled: bool) -> None:
        async with self._lock:
            await self._update(lambda s: setattr(s, "report_stats", enabled))

    async def dismiss_notice(self, notice_id: str) -> None:
        async with self._lock:

            def apply(s: CloudSetting) -> None:
                if notice_id not in s.dismissed_notice_ids:
                    s.dismissed_notice_ids.append(notice_id)

            await self._update(apply)


def _apply_grant(setting: CloudSetting, data: dict, now: datetime) -> None:
    """认领和续签响应里共有的部分：令牌、权限、限额、能力、续签间隔。"""
    setting.access_token = str(data.get("access_token") or setting.access_token)
    expires_in = data.get("expires_in")
    if isinstance(expires_in, int) and expires_in > 0:
        # 按「现在 + 有效期」算，不信对方给的绝对时间：两边时钟不一定对得上
        setting.token_expires_at = now + timedelta(seconds=expires_in)
    scopes = data.get("scopes")
    if isinstance(scopes, list):
        setting.scopes = [str(s) for s in scopes]
    elif isinstance(data.get("scope"), str):
        setting.scopes = data["scope"].split()
    if isinstance(data.get("capabilities"), list):
        setting.capabilities = [str(c) for c in data["capabilities"]]
    if isinstance(data.get("limits"), dict):
        setting.limits = {str(k): int(v) for k, v in data["limits"].items() if isinstance(v, int)}
    if isinstance(data.get("renew_interval"), int):
        setting.renew_interval = data["renew_interval"]
    setting.last_renew_at = now


def _reset_official_channel() -> None:
    """断开或重新连接：官方通道的运行期状态（额度、封锁、最近的错误）属于上一次连接，清掉。"""
    from movieclaw_api.services.push import channels

    channels.reset_runtime(channels.OFFICIAL_ID)


async def build_report(setting: CloudSetting) -> dict:
    """续签时的上报：版本信息必报；统计开关打开时再报设备数和中继连通情况。"""
    report = runtime_report_basics()
    if not setting.report_stats:
        return report
    from movieclaw_api.services.push.channels import relay_report
    from movieclaw_api.services.push.registration import device_counts

    # 没有设备也照报（空列表）：不报会被官网当成「关了统计」
    report["devices"] = await device_counts()
    relay = relay_report(setting.relay_check)
    if relay is not None:
        report["relay"] = relay
    return report


async def _raise_notice(key: str, *, severity: str, title: str, message: str) -> None:
    from movieclaw_api.services.system_notice import upsert_notice
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import NoticeSeverity

    try:
        async with get_database().session() as session:
            await upsert_notice(
                session,
                dedupe_key=f"{NOTICE_PREFIX}{key}",
                severity=NoticeSeverity(severity),
                source="cloud",
                title=title,
                message=message,
            )
    except Exception:  # noqa: BLE001 -- 告警写不进去不影响连接本身
        logger.exception("写入 MovieClaw Cloud 的待处理事项失败")


async def _resolve_cloud_notices() -> None:
    from movieclaw_api.services.system_notice import resolve_notices
    from movieclaw_db.engine import get_database

    try:
        async with get_database().session() as session:
            await resolve_notices(session, prefix=NOTICE_PREFIX)
    except Exception:  # noqa: BLE001
        logger.exception("消退 MovieClaw Cloud 的待处理事项失败")


_service: CloudService | None = None


def get_cloud_service() -> CloudService:
    """进程级单例；未初始化（测试、启动早期）时现建一个，不起任何后台任务。"""
    global _service
    if _service is None:
        _service = CloudService()
    return _service


async def init_cloud_service() -> CloudService:
    service = get_cloud_service()
    await service.start()
    return service


async def close_cloud_service() -> None:
    global _service
    if _service is not None:
        await _service.close()
        _service = None
