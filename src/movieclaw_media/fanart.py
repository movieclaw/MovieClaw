"""Fanart.tv v3 API 的最小异步客户端 + 响应归一化。

Fanart.tv 是社区维护的高清图库，补 TMDB 的短板：中文片名 Logo、季海报、
无文字背景往往比 TMDB 全（设计取舍见 docs/design/image-sources.md）。

接入要点（2026-10-04 用真实 Key 实测核对）
------------------------------------------
- **查询键**：电影用 TMDB 编号（``/movies/{tmdb_id}``，IMDb 编号也认），
  剧集**只认 TVDB 编号**（``/tv/{tvdb_id}``）——TVDB 编号从 TMDB 详情的
  ``external_ids`` 里取，不需要用户配置；
- **认证**：``api-key`` **请求头**（实测与 ``api_key`` 查询参数等价）。不用查询
  参数是因为 httpx 的 INFO 日志会打出完整 URL——Key 放在查询串里就会明文进日志。
  本项目**不内置 Key**，用户首次使用时自己填一次（全站共用）；Key 无效时 Fanart
  返回 ``401 {"error":"invalid API key"}``；
- **查无此条目**：实测回 ``200 {}``（空对象），不是 404——归一化后就是一个
  空图集；404 与 ``{"status":"error"}`` 也按查无处理（历史形态，防御性兼容）；
- **响应形态**：每种图一个数组，元素是 ``{id, url, lang, likes}``（likes 是
  **字符串**），季图多一个 ``season``（数字串或 ``"all"``），另有一组
  ``*_count`` 计数字段（不用）。"无语言"有 ``""`` / ``"00"`` / ``"xx"`` 三种
  写法，一律按无文字处理；中文只有 ``zh``；
- **没有宽高字段**：Fanart 每类图是固定规格，实测海报 1000×1426、背景
  1920×1080、4K 背景（``movie4kbackground`` / ``show4kbackground``）
  3840×2160、HD Logo 800×310、SD Logo 400×155——归一化时按类型补上，供选图的
  分辨率门槛使用；
- **图床** ``assets.fanart.tv``，地址是扁平的 ``/fanart/<名字>-<哈希>.<扩展名>``
  （早年按条目分目录，现已不是）；把 ``/fanart/`` 换成 ``/preview/`` 就是官方
  缩略图（实测 4K 背景原图 3MB、缩略图 5KB，换图弹层一屏几十张只拉缩略图）。

归一化成与 TMDB images 同形的字典（``file_path`` / ``iso_639_1`` / ``width``
……），选图层（library.py）因此能把两个来源的候选放进同一套语言分档规则。
``file_path`` 是 Fanart 的**绝对 URL**——落库后与 TMDB 的相对路径共用同一列，
出图处用 ``is_absolute_image`` 区分（见 movieclaw_api.services.tmdb_images）。
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

import httpx
from aiolimiter import AsyncLimiter
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential_jitter,
)

logger = logging.getLogger("movieclaw_media.fanart")

DEFAULT_API_BASE_URL = "https://webservice.fanart.tv/v3"
# 换图弹层等处只接受这个图床上的绝对地址（防止任意 URL 经选图接口让服务端去拉）
FANART_ASSET_PREFIX = "https://assets.fanart.tv/"
# 验证 Key 用的探针条目：《搏击俱乐部》（TMDB 550），Fanart 上图多、不会下架
_PROBE_MOVIE_ID = 550

_TRANSIENT_EXCEPTIONS = (
    httpx.TimeoutException,
    httpx.ConnectError,
    httpx.ReadError,
    httpx.RemoteProtocolError,
)

# Fanart 各类图的标称宽度（官方上传规格；API 不返回宽高）
_POSTER_WIDTH = 1000
_BACKGROUND_WIDTH = 1920
_BACKGROUND_4K_WIDTH = 3840
_HD_LOGO_WIDTH = 800
_SD_LOGO_WIDTH = 400

# "无语言"的三种写法
_NO_LANGUAGE = {"", "00", "xx"}


class FanartError(Exception):
    """Fanart.tv 请求失败的基类。message 面向最终用户展示，必须是可读中文。"""


class FanartAuthError(FanartError):
    """API Key 无效或被 Fanart.tv 拒绝（HTTP 401）。"""


class FanartNetworkError(FanartError):
    """网络层面连不上 Fanart.tv（连接失败/超时/熔断）。"""


def is_absolute_image(path: str | None) -> bool:
    """图片路径是不是绝对 URL（Fanart 的图）；TMDB 的是 ``/xxx.jpg`` 相对路径。"""
    return bool(path) and path.startswith(("https://", "http://"))  # type: ignore[union-attr]


def is_fanart_asset(path: str | None) -> bool:
    """是不是 Fanart 图床上的地址（选图接口据此放行绝对 URL）。"""
    return bool(path) and path.startswith(FANART_ASSET_PREFIX)  # type: ignore[union-attr]


def fanart_preview_url(url: str) -> str:
    """原图地址 → 官方缩略图地址（``/fanart/`` → ``/preview/``）。"""
    return url.replace("/fanart/", "/preview/", 1)


@dataclass
class FanartImages:
    """一个条目在 Fanart 上的图，已归一化为 TMDB images 同形的字典列表。

    ``season_posters`` 按季号分组（``"all"`` 这种通用季图不收：它不对应
    任何具体一季，拿来顶某一季会张冠李戴）。
    """

    posters: list[dict] = field(default_factory=list)
    backdrops: list[dict] = field(default_factory=list)
    logos: list[dict] = field(default_factory=list)
    season_posters: dict[int, list[dict]] = field(default_factory=dict)

    def is_empty(self) -> bool:
        return not (self.posters or self.backdrops or self.logos or self.season_posters)


def _language(raw: object) -> str | None:
    value = str(raw or "").strip().lower()
    return None if value in _NO_LANGUAGE else value


def _likes(raw: object) -> int:
    try:
        return int(str(raw or "0").strip() or 0)
    except ValueError:
        return 0


def _image(entry: dict, width: int, height: int) -> dict | None:
    url = str(entry.get("url") or "").strip()
    if not url.startswith(("https://", "http://")):
        return None
    # Fanart 早年的地址是 http，图床早已全站 https；统一升级，避免混合内容与明文回源
    if url.startswith("http://"):
        url = "https://" + url[len("http://") :]
    return {
        "file_path": url,
        "iso_639_1": _language(entry.get("lang")),
        "width": width,
        "height": height,
        "likes": _likes(entry.get("likes")),
        "source": "fanart",
    }


def _collect(data: dict, key: str, width: int, height: int) -> list[dict]:
    images: list[dict] = []
    for entry in data.get(key) or []:
        if isinstance(entry, dict) and (image := _image(entry, width, height)) is not None:
            images.append(image)
    return images


def _logos(data: dict, hd_key: str, sd_key: str) -> list[dict]:
    """HD Logo（800 宽）全收；SD（400 宽，Fanart 早年的规格）**按语言**补位——
    只收 HD 里没有的语言。不能「有 HD 就整类丢 SD」：那会在语言分档之前就把
    只有 SD 版的中文 Logo 丢掉，违背「先看语言，再看来源」。"""
    hd = _collect(data, hd_key, _HD_LOGO_WIDTH, 310)
    hd_langs = {logo["iso_639_1"] for logo in hd}
    sd = [
        logo
        for logo in _collect(data, sd_key, _SD_LOGO_WIDTH, 155)
        if logo["iso_639_1"] not in hd_langs
    ]
    return hd + sd


def parse_movie_images(data: dict) -> FanartImages:
    """``/movies/{id}`` 响应 → 归一化图集（Logo 规则见 ``_logos``）。"""
    logos = _logos(data, "hdmovielogo", "movielogo")
    return FanartImages(
        posters=_collect(data, "movieposter", _POSTER_WIDTH, 1426),
        # 4K 背景与 1080p 背景都是候选：TMDB 背景常有 4K，Fanart 有 4K 版时同台竞争
        backdrops=_collect(data, "movie4kbackground", _BACKGROUND_4K_WIDTH, 2160)
        + _collect(data, "moviebackground", _BACKGROUND_WIDTH, 1080),
        logos=logos,
    )


def parse_tv_images(data: dict) -> FanartImages:
    """``/tv/{tvdb_id}`` 响应 → 归一化图集（Logo 规则同电影，见 ``_logos``）。"""
    logos = _logos(data, "hdtvlogo", "clearlogo")
    seasons: dict[int, list[dict]] = {}
    for entry in data.get("seasonposter") or []:
        if not isinstance(entry, dict):
            continue
        raw_season = str(entry.get("season") or "").strip()
        if not raw_season.isdigit():
            continue  # "all" 等通用季图不收
        image = _image(entry, _POSTER_WIDTH, 1426)
        if image is not None:
            seasons.setdefault(int(raw_season), []).append(image)
    return FanartImages(
        posters=_collect(data, "tvposter", _POSTER_WIDTH, 1426),
        backdrops=_collect(data, "show4kbackground", _BACKGROUND_4K_WIDTH, 2160)
        + _collect(data, "showbackground", _BACKGROUND_WIDTH, 1080),
        logos=logos,
        season_posters=seasons,
    )


class FanartClient:
    """Fanart.tv HTTP 客户端：带认证地发 GET，把错误翻译成中文异常。

    ``on_auth_failure``：Key 被拒（401）时的回调。刮削是后台批量进行的，
    API 层借它把 Key 标记为「已失效」并停用 Fanart，避免对着一把坏 Key
    每部片都打一次请求、刷一屏同样的错误日志。

    超时短、默认不重试：Fanart 是**补充**来源，档案拉取要等它返回才能选图，
    连不通时每部片多等几十秒会让整库刷新慢一个数量级。持续不通由出口层的
    熔断器兜底（连续失败后快速失败），偶发失败的条目保留现有的图。
    """

    def __init__(
        self,
        api_key: str,
        *,
        base_url: str = DEFAULT_API_BASE_URL,
        timeout: float = 8.0,
        max_attempts: int = 1,
        transport: httpx.AsyncBaseTransport | None = None,
        on_auth_failure: Callable[[], Awaitable[None]] | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._max_attempts = max(1, max_attempts)
        self._on_auth_failure = on_auth_failure
        # Key 走请求头而不是查询参数：httpx 的请求日志会打出完整 URL，放在查询串里
        # 就等于把凭据明文写进日志文件
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(timeout),
            headers={"Accept": "application/json", "api-key": api_key},
            transport=transport,
        )
        # Fanart 没公开限流数值；整库刷新时每部片一个请求，限得保守些
        self._limiter = AsyncLimiter(5, 1)

    async def movie_images(self, tmdb_id: int) -> FanartImages | None:
        """电影的图集；Fanart 上没有这部片返回 None。"""
        data = await self._get(f"movies/{tmdb_id}")
        return parse_movie_images(data) if data is not None else None

    async def tv_images(self, tvdb_id: int) -> FanartImages | None:
        """剧集的图集（按 TVDB 编号）；Fanart 上没有这部剧返回 None。"""
        data = await self._get(f"tv/{tvdb_id}")
        return parse_tv_images(data) if data is not None else None

    async def verify(self) -> None:
        """验证 Key：拉一部必有图的电影，Key 无效抛 ``FanartAuthError``。

        不触发 ``on_auth_failure``——这是用户在设置页主动验证，失败直接
        反馈到表单上，不该顺手把已保存的旧 Key 标成失效。
        """
        await self._get(f"movies/{_PROBE_MOVIE_ID}", notify_auth_failure=False)

    async def _get(self, path: str, *, notify_auth_failure: bool = True) -> dict[str, Any] | None:
        url = f"{self._base_url}/{path}"
        try:
            response = await self._request(url)
        except RuntimeError as exc:
            # 换 Key 时旧客户端被关闭，仍持有它的批量任务会撞上这个（httpx 抛的是
            # RuntimeError 而非 HTTPError）：按一次普通的取图失败处理
            raise FanartError(
                "Fanart.tv 客户端已随 Key 更换重建，本次没取到，下次刷新会恢复"
            ) from exc
        except httpx.HTTPError as exc:
            logger.warning("Fanart.tv 请求失败：%s %s（%s）", path, type(exc).__name__, exc)
            raise FanartNetworkError(
                "无法连通 Fanart.tv（webservice.fanart.tv）。所在网络可能无法直连，"
                "请到「设置 → 网络与代理」为「Fanart.tv」开启代理"
            ) from exc
        if response.status_code == 401:
            if notify_auth_failure and self._on_auth_failure is not None:
                await self._on_auth_failure()
            raise FanartAuthError(
                "Fanart.tv API Key 无效或已被撤销，请到「设置 → 刮削与整理 → 图片来源」重新填写"
            )
        if response.status_code == 404:
            return None
        if response.status_code >= 400:
            logger.warning("Fanart.tv 返回异常状态：%s -> HTTP %s", path, response.status_code)
            raise FanartError(f"Fanart.tv 返回异常状态码 {response.status_code}，请稍后重试")
        try:
            data = response.json()
        except ValueError as exc:
            raise FanartError("Fanart.tv 返回的数据无法解析，请稍后重试") from exc
        if not isinstance(data, dict):
            raise FanartError("Fanart.tv 返回的数据格式不对，请稍后重试")
        # 查无此条目时 Fanart 历史上也回过 200 + {"status":"error","error message":"Not found"}
        if str(data.get("status") or "").lower() == "error":
            return None
        return data

    async def _request(self, url: str) -> httpx.Response:
        @retry(
            stop=stop_after_attempt(self._max_attempts),
            wait=wait_exponential_jitter(initial=1, max=4, jitter=1),
            retry=retry_if_exception_type(_TRANSIENT_EXCEPTIONS),
            reraise=True,
        )
        async def _do() -> httpx.Response:
            async with self._limiter:
                return await self._client.get(url)

        return await _do()

    async def aclose(self) -> None:
        await self._client.aclose()
