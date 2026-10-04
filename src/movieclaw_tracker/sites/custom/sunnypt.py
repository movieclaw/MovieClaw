"""SunnyPT 站点适配器（MovieClaw 版）。

基于 SunnyPT 为 MoviePilot 开放的官方 API 通道（``/api/v1/mp`` + ``X-API-Key``），
字段与端点直接参照 MoviePilot 官方适配器：
  - https://github.com/jxxghp/MoviePilot  app/modules/indexer/spider/sunnypt.py
  - https://github.com/jxxghp/MoviePilot  app/modules/indexer/parser/sunnypt.py

与网页 App 使用的 ``/api/v1`` + ``Authorization: Bearer`` 通道是两套独立的 API；
本适配器走 MoviePilot 通道（X-API-Key），因此可以直接复用 MovieClaw 的
``ApiKeyAuthProvider``（默认请求头 ``x-api-key``），认证层无需任何改动。

认证方式
--------
使用 API-Key（请求头 ``x-api-key``，见 ``ApiKeyAuthProvider``）。
在 sunnypt.top 用户面板生成 MoviePilot 专用 API Key（注意：不是网页登录用的
accessToken，也不是 tracker 的 passkey）后填入即可。

核心接口（均需带 X-API-Key，Base URL 为 https://api.sunnypt.top/api/v1/mp）：
- ``GET /categories``                 动态获取分类映射（{id, media_types}）
- ``GET /torrents``                   搜索/浏览种子（分页、media_type、分类）
- ``POST /torrents/{id}/download-token``  换取一次性下载直链，再 GET 下载 .torrent
- ``GET /profile``                    当前用户资料（流量、做种数、等级等）
- ``GET /messages``                   未读消息（本适配器未用到，仅供参考）

设计要点
--------
1. 站点仅区分 movie / tv 两层媒体类型（由 ``media_type`` 过滤）；搜索结果里
   ``media_type`` 直接映射为应用级 TorrentCategory（movie→MOVIE，tv→TV），
   其余值归 None。
2. 促销以 ``promotion`` 对象返回（``is_active`` / ``down_multiplier`` /
   ``up_multiplier`` / ``until``），仅激活时生效，否则视为普通（系数 1.0）。
3. 种子详情无官方 MP 端点（MoviePilot 官方同样未提供），因此
   ``get_torrent_detail`` 抛出 NotImplementedError。
4. 分类映射优先调 ``/categories`` 动态获取，失败时回退到 YAML 的 ``categories``
   （静态兜底）。
"""

from __future__ import annotations

import datetime
import logging
from typing import Any

from movieclaw_tracker.base import BaseSite
from movieclaw_tracker.datetime_utils import DEFAULT_SITE_TIMEZONE
from movieclaw_tracker.exceptions import TrackerAuthError, TrackerParseError
from movieclaw_tracker.models import (
    SearchQuery,
    SearchResult,
    TorrentCategory,
    TorrentDetail,
    TorrentListItem,
    TorrentListPage,
    UserProfile,
)

logger = logging.getLogger("movieclaw_tracker.sites.sunnypt")

# 每页请求数量，与 MoviePilot 官方实现一致取 100
_PAGE_SIZE = 100

# API 业务错误中「凭据/账号已不可用」的特征词（统一按小写匹配）。
# 命中即抛 TrackerAuthError 而非 TrackerParseError——让上层尽快熔断并提醒用户。
_AUTH_ERROR_KEYWORDS = (
    "invalid api key",
    "未登录",
    "停用",
    "封禁",
    "禁用",
    "unauthorized",
    "forbidden",
    "key",
)

# 应用级一级分类 → 站点媒体类型（media_type）
_MEDIA_TYPE_BY_CATEGORY: dict[TorrentCategory, str] = {
    TorrentCategory.MOVIE: "movie",
    TorrentCategory.TV: "tv",
}

# 站点媒体类型 → 应用级一级分类（解析结果时归类）
_MEDIA_TYPE_TO_CATEGORY: dict[str, TorrentCategory] = {
    "movie": TorrentCategory.MOVIE,
    "tv": TorrentCategory.TV,
}

_SIZE_UNITS = ["B", "KB", "MB", "GB", "TB", "PB"]


def _bytes_to_human(size: int) -> str:
    """把字节数转成可读字符串（如 ``25.6 GB``），仅用于展示。"""
    value = float(size)
    for unit in _SIZE_UNITS:
        if value < 1024 or unit == _SIZE_UNITS[-1]:
            return f"{value:.2f} {unit}"
        value /= 1024
    return f"{value:.2f} PB"


class SunnyPTSite(BaseSite):
    """SunnyPT 站点，基于官方 MoviePilot API（/api/v1/mp + X-API-Key）实现。"""

    def __init__(
        self,
        *,
        site_id: str,
        base_url: str,
        client: Any,
        auth_manager: Any,
        web_base_url: str | None = None,
        category_map: dict[TorrentCategory, list[str]] | None = None,
        timezone: str = DEFAULT_SITE_TIMEZONE,
    ) -> None:
        super().__init__(
            site_id=site_id,
            base_url=base_url,
            client=client,
            auth_manager=auth_manager,
            web_base_url=web_base_url,
            timezone=timezone,
        )
        # 正向映射：应用级一级分类 → 站点分类 ID 列表（搜索时下发过滤条件，静态兜底）
        self._category_map: dict[TorrentCategory, list[str]] = category_map or {}
        # 反向映射：站点分类 ID → 应用级一级分类
        self._reverse_map: dict[str, TorrentCategory] = {}
        for cate, ids in self._category_map.items():
            for cid in ids:
                self._reverse_map[str(cid)] = cate
        # 分类映射缓存（动态获取后复用）
        self._categories_cache: dict | None = None

    # -- 内部：API 调用与结果校验 ------------------------------------------

    async def _request_json(
        self,
        method: str,
        path: str,
        **kwargs: Any,
    ) -> Any:
        """调 /api/v1/mp 接口，校验业务状态后返回 ``data`` 字段。

        统一响应结构为 ``{"code": 0, "data": ..., "msg": "ok"}``。
        HTTP 200 但 code 非 0 时同样视为失败（如 API Key 失效、参数错误）。
        """
        url = self._url(path)
        request = getattr(self.client, method)
        response = await request(url, **kwargs)
        try:
            payload = response.json()
        except Exception as exc:  # noqa: BLE001 - 统一转成业务异常，便于上层展示
            raise TrackerParseError(
                "SunnyPT 接口返回内容不是合法 JSON，站点可能维护中或 API 已变更",
                details={"url": url},
            ) from exc

        code = str(payload.get("code", ""))
        if code != "0":
            raw_message = str(payload.get("msg") or "")
            details = {"url": url, "code": code}
            if any(kw in raw_message.lower() for kw in _AUTH_ERROR_KEYWORDS):
                raise TrackerAuthError(
                    f"SunnyPT 接口返回错误：{raw_message}", details=details
                )
            raise TrackerParseError(
                f"SunnyPT 接口返回错误：{raw_message}", details=details
            )
        return payload.get("data")

    # -- 分类工具 ----------------------------------------------------------

    async def _load_categories(self) -> dict[str, list[str]]:
        """动态获取站点分类映射（media_type → 分类 ID 列表），失败回退静态。"""
        if self._categories_cache is not None:
            return self._categories_cache
        try:
            data = await self._request_json("get", "/api/v1/mp/categories")
            result: dict[str, list[str]] = {"movie": [], "tv": []}
            for item in data or []:
                if not isinstance(item, dict) or item.get("id") is None:
                    continue
                cid = str(item["id"])
                for media_type in item.get("media_types") or []:
                    if media_type in result and cid not in result[media_type]:
                        result[media_type].append(cid)
            if any(result.values()):
                self._categories_cache = result
                return result
        except TrackerAuthError:
            raise
        except Exception:  # noqa: BLE001 - 分类接口失败不阻断，回退静态映射
            logger.warning("SunnyPT 获取分类接口失败，回退到静态分类映射", exc_info=True)
        # 回退：静态 category_map（movie → 其下所有分类 ID，tv 同理）
        return {
            "movie": self._category_map.get(TorrentCategory.MOVIE, []),
            "tv": self._category_map.get(TorrentCategory.TV, []),
        }

    def _resolve_category(self, media_type: str | None) -> TorrentCategory | None:
        """站点媒体类型 → 应用级一级分类。"""
        if media_type is None:
            return None
        return _MEDIA_TYPE_TO_CATEGORY.get(str(media_type))

    def _media_type_for(self, categories: list[TorrentCategory]) -> str | None:
        """请求的一级分类 → 站点媒体类型（movie/tv），无匹配返回 None。"""
        if TorrentCategory.MOVIE in categories:
            return "movie"
        if TorrentCategory.TV in categories:
            return "tv"
        return None

    # -- 时间解析 ----------------------------------------------------------

    def _parse_datetime(self, text: Any) -> datetime.datetime | None:
        """解析 SunnyPT 的时间值（ISO 字符串 / 'YYYY-MM-DD HH:MM:SS' / 秒时间戳）。"""
        if text is None or text == "":
            return None
        # 数值时间戳（秒）
        if isinstance(text, (int, float)):
            try:
                return self._to_utc(
                    datetime.datetime.fromtimestamp(float(text), tz=datetime.UTC)
                )
            except (ValueError, OverflowError, OSError):
                return None
        text = str(text).strip()
        # 优先 ISO 8601（带时区），如 "2026-01-02T15:04:05+08:00"
        if "T" in text:
            try:
                return self._to_utc(datetime.datetime.fromisoformat(text))
            except ValueError:
                pass
        # 再试常用无时区格式
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d"):
            try:
                return self._to_utc(datetime.datetime.strptime(text, fmt))
            except ValueError:
                continue
        return None

    # -- 结果解析 ----------------------------------------------------------

    def _parse_torrent(self, t: dict[str, Any]) -> TorrentListItem | None:
        """把单条 API 种子数据映射为 TorrentListItem。解析异常返回 None 跳过。"""
        try:
            torrent_id = str(t.get("id", ""))
            media_type = t.get("media_type")

            # 促销：仅激活时生效
            promotion = t.get("promotion") or {}
            promo_active = bool(promotion.get("is_active"))
            download_factor = (
                float(promotion.get("down_multiplier", 1.0)) if promo_active else 1.0
            )
            upload_factor = (
                float(promotion.get("up_multiplier", 1.0)) if promo_active else 1.0
            )
            free_deadline = (
                self._parse_datetime(promotion.get("until"))
                if promo_active and promotion.get("until")
                else None
            )

            size_bytes = int(t.get("size") or 0)

            return TorrentListItem(
                torrent_id=torrent_id,
                title=t.get("title") or "",
                subtitle=t.get("subtitle") or "",
                category=self._resolve_category(media_type),
                size=_bytes_to_human(size_bytes) if size_bytes else None,
                size_bytes=size_bytes,
                seeders=int(t.get("seeders", 0) or 0),
                leechers=int(t.get("leechers", 0) or 0),
                snatched=int(t.get("completed", 0) or 0),
                upload_time=self._parse_datetime(t.get("created_at")),
                free=download_factor == 0.0,
                free_deadline=free_deadline,
                download_volume_factor=download_factor,
                upload_volume_factor=upload_factor,
                hit_and_run=bool(t.get("hit_and_run")),
                # download_url 存种子 ID，download_torrent 据此换取下载直链
                download_url=torrent_id,
                # 详情链接给用户在浏览器打开，必须用网页域名而非 API 域名
                detail_url=f"{self.web_base_url}/torrent/{torrent_id}",
            )
        except Exception:  # noqa: BLE001 - 单条解析失败不应中断整页
            logger.warning("解析 SunnyPT 种子数据失败，已跳过该条", exc_info=True)
            return None

    async def _fetch_page(
        self,
        *,
        keyword: str | None,
        categories: list[TorrentCategory] | None,
        page: int,
    ) -> tuple[list[TorrentListItem], int | None]:
        """执行一次搜索/浏览请求，返回（种子列表，总页数）。"""
        params: dict[str, Any] = {
            "page": page,
            "page_size": _PAGE_SIZE,
            "sort": "created_at",
            "order": "desc",
        }
        if keyword:
            params["keyword"] = keyword

        requested = set(categories) if categories else set()
        media_type = self._media_type_for(list(requested))
        if media_type:
            params["media_type"] = media_type

        # 分类 ID：请求涵盖全部分类或未指定时不传（浏览全部）
        if requested and requested != set(TorrentCategory):
            category_ids: list[str] = []
            for cate in requested:
                category_ids.extend(self._category_map.get(cate, []))
            if media_type:
                dynamic = await self._load_categories()
                ids = dynamic.get(media_type) or []
                if ids:
                    category_ids = ids
            if category_ids:
                params["categories"] = ",".join(category_ids)

        data = await self._request_json("get", "/api/v1/mp/torrents", params=params)
        if not isinstance(data, dict):
            return [], None

        raw_list = data.get("items") or []
        items = [item for t in raw_list if (item := self._parse_torrent(t)) is not None]

        # MoviePilot 通道返回结构里总页数未明确，缺省时由 total / page_size 推算
        total_pages: int | None = None
        total = data.get("total")
        if isinstance(total, int) and total > 0:
            total_pages = (total + _PAGE_SIZE - 1) // _PAGE_SIZE

        return items, total_pages

    # -- BaseSite 契约实现 -------------------------------------------------

    async def list_torrents(
        self,
        *,
        categories: list[TorrentCategory] | None = None,
        page: int = 1,
    ) -> TorrentListPage:
        cats = categories if categories is not None else list(TorrentCategory)
        items, total_pages = await self._fetch_page(
            keyword=None,
            categories=cats,
            page=page,
        )
        return TorrentListPage(items=items, page=page, total_pages=total_pages)

    async def search(self, query: SearchQuery) -> SearchResult:
        items, total_pages = await self._fetch_page(
            keyword=query.keyword,
            categories=query.categories,
            page=query.page,
        )
        return SearchResult(items=items, page=query.page, total_pages=total_pages)

    async def get_torrent_detail(self, url: str) -> TorrentDetail:
        # SunnyPT 的 MoviePilot API 无种子详情端点（官方适配同样未提供）。
        # 种子详情对刷流/同步非核心，抛异常避免返回残缺数据误导上层。
        raise NotImplementedError(
            "SunnyPT 的 MoviePilot API 未提供种子详情端点，get_torrent_detail 不支持"
        )

    async def download_torrent(self, url: str) -> bytes:
        # url 为种子 ID（来自列表/搜索结果的 download_url）
        # 第一步：换取一次性下载直链
        data = await self._request_json(
            "post",
            f"/api/v1/mp/torrents/{url}/download-token",
        )
        dl_url: str | None = None
        if isinstance(data, dict):
            dl_url = data.get("download_url")
        if not dl_url:
            raise TrackerParseError(
                "SunnyPT 未返回下载直链，可能未认证或达到下载频率限制",
                details={"torrent_id": url},
            )
        # 第二步：GET 直链下载 .torrent 文件字节
        return await self.client.download(dl_url)

    async def get_user_profile(
        self,
        user_id: str | None = None,
    ) -> UserProfile:
        # API-Key 识别身份，只能查询当前登录用户，忽略 user_id 入参
        profile = await self._request_json("get", "/api/v1/mp/profile")
        if not isinstance(profile, dict):
            raise TrackerParseError("获取 SunnyPT 用户资料失败，请检查 API Key 是否有效")

        uploaded_bytes = int(profile.get("uploaded") or 0)
        downloaded_bytes = int(profile.get("downloaded") or 0)

        ratio: float | None
        try:
            ratio = float(profile.get("ratio")) if profile.get("ratio") is not None else None
        except (ValueError, TypeError):
            ratio = None

        bonus: float | None
        try:
            bonus = float(profile.get("bonus")) if profile.get("bonus") is not None else None
        except (ValueError, TypeError):
            bonus = None

        return UserProfile(
            user_id=str(profile.get("id", "")),
            username=profile.get("username") or "",
            user_class=str(profile.get("level") or profile.get("class") or ""),
            join_date=self._parse_datetime(profile.get("registered_at")),
            uploaded=_bytes_to_human(uploaded_bytes),
            uploaded_bytes=uploaded_bytes,
            downloaded=_bytes_to_human(downloaded_bytes),
            downloaded_bytes=downloaded_bytes,
            ratio=ratio,
            bonus=bonus,
            seeding_count=int(profile.get("seeding_count") or 0),
            leeching_count=int(profile.get("leeching_count") or 0),
        )
