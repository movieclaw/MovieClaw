"""Fanart.tv 图片来源的运行时装配：凭据快照、客户端单例、Key 验证与失效处理。

产品口径（docs/design/image-sources.md）：

- **不内置 Key**：用户在第一次用 Fanart 的地方就地填一次（设置开关、库设置、
  换图弹层三个入口共用同一个表单），验证通过才保存，之后全站共用；
- **Key 是凭据**，单独存在 ``metadata.fanart`` 配置域（加密落库），接口只回
  「配没配、是否失效、末四位」，永不下发明文；
- **Key 失效**（刮削时 Fanart 回 401）：标记 ``key_invalid``、停用 Fanart 选图，
  日志写一条中文说明；刮削照常只用 TMDB。设置页据此显示「Key 已失效」，
  用户重新填一次有效 Key 即恢复。

出口：接口与图床（assets.fanart.tv，见 image_proxy 的按域名分流）都走 ``fanart``
出口标签——「设置 → 网络与代理」里单独一项「Fanart.tv」，部署者自己决定走不走
代理（默认走）。熔断也随标签独立：Fanart 连不通只让 Fanart 快速失败，不连带
TMDB/豆瓣图片下载。
"""

from __future__ import annotations

import asyncio
import functools
import logging

from movieclaw_api.settings import FanartSetting
from movieclaw_api.settings.store import get_setting_store
from movieclaw_media.fanart import FanartClient
from movieclaw_net import egress_transport

logger = logging.getLogger("movieclaw_api.fanart")

_current: FanartSetting | None = None
_client: FanartClient | None = None
_client_key: str | None = None
_invalid_lock = asyncio.Lock()
# 换 Key 后旧客户端的关闭任务：事件循环只持弱引用，不留强引用可能被中途回收
_closing: set[asyncio.Task[None]] = set()


async def load_fanart_runtime() -> None:
    """从配置域加载 Fanart 凭据快照（随刮削偏好一起在启动时加载）。"""
    global _current
    _current = await get_setting_store().get(FanartSetting)


def current_fanart_setting() -> FanartSetting:
    return _current or FanartSetting()


def fanart_key_usable() -> bool:
    """有 Key 且没被 Fanart 拒绝过——换图弹层能否展示 Fanart 候选、自动选图能否用它。"""
    setting = current_fanart_setting()
    return bool(setting.api_key) and not setting.key_invalid


def fanart_status() -> dict:
    """给前端的凭据状态：只有「配没配、是否失效、末四位」，不含明文。"""
    setting = current_fanart_setting()
    key = setting.api_key
    return {
        "configured": bool(key),
        "key_invalid": bool(key) and setting.key_invalid,
        "key_hint": key[-4:] if len(key) >= 8 else "",
    }


def _build_client(api_key: str, *, notify: bool) -> FanartClient:
    """``notify``：刮削用的客户端遇 401 回调标记失效；设置页的验证探针不回调、
    也不经熔断器（「必须真发请求」的连通性测试，见 egress_transport 约定）。

    回调绑定**这把 Key**：换 Key 的瞬间可能还有旧 Key 的请求在途，它们晚到的
    401 不能把用户刚填的新 Key 标成失效。
    """
    return FanartClient(
        api_key,
        transport=egress_transport("fanart", use_breaker=notify),
        on_auth_failure=functools.partial(mark_key_invalid, api_key) if notify else None,
    )


def get_fanart_client() -> FanartClient | None:
    """刮削用的客户端单例；Key 不可用时返回 None（调用方据此只用 TMDB）。

    Key 换了就重建（旧连接池随之关闭）——单例按 Key 绑定，换 Key 不需要重启。
    """
    global _client, _client_key
    if not fanart_key_usable():
        return None
    key = current_fanart_setting().api_key
    if _client is None or _client_key != key:
        old = _client
        _client = _build_client(key, notify=True)
        _client_key = key
        if old is not None:
            _close_later(old)
    return _client


# 换 Key 后旧客户端延迟这么久再关：整库刷新等批量任务开头就拿到了客户端引用，
# 立刻关掉会让它们的在途/后续请求撞上「client has been closed」
_RETIRE_DELAY_SECONDS = 300


def _close_later(client: FanartClient) -> None:
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return

    async def _retire() -> None:
        await asyncio.sleep(_RETIRE_DELAY_SECONDS)
        await client.aclose()

    task = loop.create_task(_retire())
    _closing.add(task)
    task.add_done_callback(_closing.discard)


async def verify_and_save_key(api_key: str) -> FanartSetting:
    """验证并保存 Key（设置页「验证并启用」）。验证不过抛 ``FanartError`` 系异常，
    原有配置保持不变——不会因为用户贴错一次就把能用的旧 Key 覆盖掉。"""
    global _current
    api_key = api_key.strip()
    probe = _build_client(api_key, notify=False)
    try:
        await probe.verify()
    finally:
        await probe.aclose()
    setting = FanartSetting(api_key=api_key, key_invalid=False)
    await get_setting_store().set(setting)
    _current = setting
    logger.info("Fanart.tv API Key 已验证并保存（末四位 %s）", api_key[-4:])
    return setting


async def mark_key_invalid(rejected_key: str) -> None:
    """刮削时 Fanart 回 401：标记 Key 失效、停用 Fanart 选图（只记一次日志）。

    整库刷新时几十个并发档案请求可能同时撞上 401，锁 + 状态判断保证只落一次库。
    ``rejected_key`` 是被拒的那把 Key：与当前保存的不一致（用户已经换了新 Key）
    就什么都不做。
    """
    global _current
    async with _invalid_lock:
        setting = current_fanart_setting()
        if not setting.api_key or setting.key_invalid or setting.api_key != rejected_key:
            return
        updated = setting.model_copy(update={"key_invalid": True})
        await get_setting_store().set(updated)
        _current = updated
    logger.warning(
        "Fanart.tv 拒绝了已保存的 API Key（HTTP 401，可能已被撤销或填错）。"
        "已暂停使用 Fanart 选图，刮削改为只用 TMDB 的图；"
        "请到「设置 → 刮削与整理 → 图片来源」重新填写 Key"
    )


def reset_fanart_runtime() -> None:
    """仅供测试：清空快照与客户端。"""
    global _current, _client, _client_key
    _current = None
    _client = None
    _client_key = None
