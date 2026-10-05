"""推送配图的签名地址与 collapse_key（docs/design/cloud-push.md §6）。

通知扩展要在锁屏时下载配图，但它拿不到 App 的登录令牌（令牌在 App 自己的钥匙串里，
共享出去等于扩大了泄露面）。所以配图走带签名的地址 ``/api/v1/push/images/<签名>``：

- 签名里只有一张 TMDB 图片地址和过期时间（7 天），不需要登录凭证；
- 地址只出现在加密的推送明文里，中继和苹果看不到；泄露出去也只是一张海报；
- 复用会话签名密钥 + 独立的 salt 做域隔离（与取流签名同一做法），轮换会话密钥时一并作废。
"""

from __future__ import annotations

import time

from itsdangerous import BadSignature, URLSafeSerializer

from movieclaw_api.services.auth import get_signing_secret
from movieclaw_api.services.push import crypto

_IMAGE_SALT = "movieclaw.push.image.v1"
IMAGE_TOKEN_TTL_S = 7 * 24 * 3600
IMAGE_PATH_PREFIX = "/api/v1/push/images/"


def _tmdb_base() -> str:
    from movieclaw_api.services.network_egress import effective_tmdb_image_base_url

    return effective_tmdb_image_base_url().rstrip("/") + "/"


async def image_path(url: str | None) -> str | None:
    """给一张 TMDB 图片签一个推送用的相对路径；不是 TMDB 图片返回 None（不带图）。"""
    if not url or not url.startswith(_tmdb_base()):
        return None
    serializer = URLSafeSerializer(await get_signing_secret(), salt=_IMAGE_SALT)
    token = serializer.dumps({"u": url, "exp": int(time.time()) + IMAGE_TOKEN_TTL_S})
    return IMAGE_PATH_PREFIX + token


async def resolve_image(token: str) -> str | None:
    """验签，返回图片地址；签名不对、过期、不是 TMDB 图片都返回 None（按 404 应答）。"""
    serializer = URLSafeSerializer(await get_signing_secret(), salt=_IMAGE_SALT)
    try:
        payload = serializer.loads(token)
    except BadSignature:
        return None
    if not isinstance(payload, dict):
        return None
    url, expires = payload.get("u"), payload.get("exp")
    if not isinstance(url, str) or not isinstance(expires, int) or expires < time.time():
        return None
    # 纵深防御：即便签名密钥泄露，这个端点也只能拿来取 TMDB 图片
    return url if url.startswith(_tmdb_base()) else None


async def collapse_key() -> bytes:
    """collapse_id 用的本地密钥：第一次用时生成并加密存储，不发给任何人。"""
    from movieclaw_api.settings import PushChannelsSetting, get_setting_store

    store = get_setting_store()
    config = await store.get(PushChannelsSetting)
    if not config.collapse_key:
        config = config.model_copy(deep=True)
        config.collapse_key = crypto.new_collapse_key()
        await store.set(config)
    return crypto.b64url_decode(config.collapse_key)
