"""豆瓣公开移动端榜单的最小异步客户端与发现页编排。

豆瓣视角只承担榜单浏览，不抓取完整详情。接口并非正式开放 API，因此请求保持
低频并使用长缓存；发现页按「布局 + 单行」提供，任一榜单失败只影响那一行
（该行接口报错，前端收起该行），不拖垮整页。
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from typing import Any

import httpx
from aiolimiter import AsyncLimiter
from parsel import Selector

from movieclaw_cache import AsyncTTLCache, CacheStore, SwrCache
from movieclaw_media.models import (
    DiscoverLayout,
    DiscoverRowStub,
    MediaCard,
    MediaCastMember,
    MediaDetail,
    MediaFacts,
    MediaKind,
    MediaRow,
    MediaSearchItem,
    MediaSource,
)

logger = logging.getLogger("movieclaw_media.douban")

# 详情页演职员条最多取多少位（与 TMDB 侧的 service._CAST_LIMIT 同口径）
_CAST_LIMIT = 16

# 角色名里的中日韩字符；以及中文角色名后面跟着的那段拉丁原文（含空格、点、
# 撇号、连字符）。只在角色名本身含中日韩字符时才裁，纯外文角色名要原样保留。
_CJK = re.compile(r"[㐀-鿿぀-ヿ가-힯]")
_LATIN_ROLE_TAIL = re.compile(r"\s+[A-Za-z][A-Za-z0-9 .'’-]*$")

DEFAULT_API_BASE_URL = "https://m.douban.com/rexxar/api/v2"
_PAGE_TTL = 6 * 60 * 60
# 完整榜单聚合中途分页失败（半截结果）时的短缓存：不能按 _PAGE_TTL 把残缺
# 榜单钉住 6 小时，但也不宜完全不缓存——冷回源要连打十几个分页请求，失败
# 往往是网络抖动，几分钟后重试通常就能补全。
_PAGE_TRUNCATED_TTL = 5 * 60
_SEARCH_TTL = 10 * 60
_DETAIL_TTL = 6 * 60 * 60
_MIN_ROW_ITEMS = 4

# 持久缓存（L2）的双 TTL：新鲜期内不碰豆瓣；可用期内先返回旧值、后台刷新；
# 超出可用期才阻塞回源。榜单天然快变、详情基本不变，故档位差一个量级。
_COLLECTION_FRESH_TTL = 6 * 60 * 60
_COLLECTION_STALE_TTL = 3 * 24 * 60 * 60
_DETAIL_FRESH_TTL = 3 * 24 * 60 * 60
_DETAIL_STALE_TTL = 30 * 24 * 60 * 60
# 无效豆瓣 ID 的负缓存：防止坏 ID 被前端重试反复打豆瓣
_DETAIL_NEGATIVE_TTL = 60 * 60


class DoubanError(Exception):
    """豆瓣榜单请求失败；错误信息可直接展示给用户。"""


class DoubanNetworkError(DoubanError):
    """网络层面无法连通豆瓣（连接失败/超时/熔断），与"豆瓣可达但返回错误"区分。"""


class DoubanNotFoundError(DoubanError):
    """请求的豆瓣资源不存在（如未开放完整浏览的榜单 ID），API 层译为 404。"""


def _translate_httpx_error(exc: Exception, what: str) -> DoubanError:
    """httpx 异常 → 豆瓣领域错误：传输层失败给网络引导，其余给通用重试提示。"""
    if isinstance(exc, httpx.TransportError):
        return DoubanNetworkError(
            f"无法连通豆瓣（{what}）。请检查服务器网络；"
            "如所在网络不通，可在「设置 → 网络」为豆瓣配置代理或反代地址"
        )
    return DoubanError(f"访问豆瓣{what}失败，请稍后重试")


class DoubanClient:
    """只访问 subject_collection 榜单接口的低频 HTTP 客户端。"""

    def __init__(
        self,
        *,
        base_url: str = DEFAULT_API_BASE_URL,
        transport: httpx.AsyncBaseTransport | None = None,
        store: CacheStore | None = None,
    ) -> None:
        # 持久缓存缓存原始响应 JSON（而非解析后的模型）：上层解析逻辑迭代时
        # 无需清缓存。store 不注入时退化为无持久缓存的直连行为。
        self._swr = SwrCache(store, "douban")
        self._client = httpx.AsyncClient(
            base_url=base_url.rstrip("/"),
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                    "AppleWebKit/605.1.15"
                ),
                "Referer": "https://m.douban.com/movie/",
            },
            timeout=20,
            follow_redirects=True,
            transport=transport,
        )
        self._limiter = AsyncLimiter(1, 1)

    async def collection(
        self, collection_id: str, *, count: int = 30, start: int = 0
    ) -> dict[str, Any]:
        """读取榜单的一段；发现页只取首批，「看全部」落地页从这里分页聚合。"""

        async def fetch() -> dict[str, Any]:
            try:
                async with self._limiter:
                    response = await self._client.get(
                        f"/subject_collection/{collection_id}/items",
                        params={"start": start, "count": count, "items_only": 1, "for_mobile": 1},
                    )
                response.raise_for_status()
                return response.json()
            except (httpx.HTTPError, ValueError) as exc:
                logger.warning("豆瓣榜单请求失败：%s（%s）", collection_id, exc)
                raise _translate_httpx_error(exc, "榜单") from exc

        # start=0 沿用旧键格式，避免升级后既有持久缓存整体失效
        key = (
            f"collection:{collection_id}:{start}:{count}"
            if start
            else f"collection:{collection_id}:{count}"
        )
        return await self._swr.get_or_fetch(
            key,
            fresh_ttl=_COLLECTION_FRESH_TTL,
            stale_ttl=_COLLECTION_STALE_TTL,
            factory=fetch,
        )

    async def search(self, keyword: str) -> list[dict[str, Any]]:
        """搜索豆瓣电影/剧集轻量候选，只解析移动搜索页明确提供的字段。"""
        try:
            async with self._limiter:
                response = await self._client.get(
                    "https://m.douban.com/search/",
                    params={"query": keyword, "type": "1002"},
                )
            response.raise_for_status()
        except httpx.HTTPError as exc:
            logger.warning("豆瓣搜索请求失败：%s（%s）", keyword, exc)
            raise _translate_httpx_error(exc, "搜索") from exc

        selector = Selector(text=response.text)
        results: list[dict[str, Any]] = []
        for node in selector.css("ul.search_results_subjects > li"):
            href = node.css('a[href^="/movie/subject/"]::attr(href)').get("")
            match = re.search(r"/subject/(\d+)/", href)
            title = (node.css("span.subject-title::text").get("") or "").strip()
            poster = node.css("img::attr(src)").get("")
            rating_text = node.css("span.rating-stars::attr(data-rating)").get("")
            if not match or not title or not poster:
                continue
            rating = round(float(rating_text) / 10, 1) if rating_text else 0.0
            # 搜索页给的是较小的 s_ratio 图，同一路径切到 m_ratio 提升卡片清晰度。
            results.append(
                {
                    "id": match.group(1),
                    "title": title,
                    "rating": rating,
                    "poster_url": poster.replace("/s_ratio_poster/", "/m_ratio_poster/"),
                }
            )
        return results

    async def detail(self, douban_id: str) -> dict[str, Any]:
        """读取豆瓣移动详情；电影路径会由豆瓣自动重定向到正确的剧集路径。"""

        async def fetch() -> dict[str, Any] | None:
            try:
                async with self._limiter:
                    response = await self._client.get(
                        f"/movie/{douban_id}", params={"for_mobile": 1}
                    )
                response.raise_for_status()
                data = response.json()
            except (httpx.HTTPError, ValueError) as exc:
                logger.warning("豆瓣详情请求失败：%s（%s）", douban_id, exc)
                raise _translate_httpx_error(exc, "详情") from exc
            # 返回 None 触发负缓存：豆瓣确认无此条目与瞬时故障（抛异常）分开对待
            if not data.get("id") or not data.get("title"):
                return None
            return data

        data = await self._swr.get_or_fetch(
            f"detail:{douban_id}",
            fresh_ttl=_DETAIL_FRESH_TTL,
            stale_ttl=_DETAIL_STALE_TTL,
            negative_ttl=_DETAIL_NEGATIVE_TTL,
            factory=fetch,
        )
        if data is None:
            raise DoubanError("豆瓣未返回有效的条目详情")
        return data

    async def celebrities(self, douban_id: str) -> dict[str, Any]:
        """读取豆瓣完整演职员表。

        详情接口（/movie/{id}）里的 actors 只有姓名，没有头像也没有角色；带头像和
        角色名的完整名单在这个独立接口里，形如 {"directors": [...], "actors": [...]}，
        每人含 avatar.{large,normal}、character、id。演职员条要出头像就必须多打这一跳。
        """

        async def fetch() -> dict[str, Any]:
            try:
                async with self._limiter:
                    response = await self._client.get(
                        f"/movie/{douban_id}/celebrities", params={"for_mobile": 1}
                    )
                response.raise_for_status()
                return response.json()
            except (httpx.HTTPError, ValueError) as exc:
                logger.warning("豆瓣演职员表请求失败：%s（%s）", douban_id, exc)
                raise _translate_httpx_error(exc, "演职员表") from exc

        # 演职员表与详情同源同频（基本不变），沿用详情档位的双 TTL
        return await self._swr.get_or_fetch(
            f"celebrities:{douban_id}",
            fresh_ttl=_DETAIL_FRESH_TTL,
            stale_ttl=_DETAIL_STALE_TTL,
            factory=fetch,
        )

    async def aclose(self) -> None:
        await self._client.aclose()


def _people_members(people: Any) -> list[MediaCastMember]:
    """豆瓣人物数组 → 结构化演职员（演职员表与详情接口的两种形态都吃）。

    豆瓣这个字段的形态不稳定：avatar 有时是字符串，有时是 {small,normal,large}
    的字典；演员的 character 常带「饰 」前缀（如「饰 老东家」），去掉前缀交给
    前端统一加，中文角色名后缀的原文（「安迪·杜佛兰 Andy Dufresne」）在窄卡片里
    只会被截断，一并去掉。导演没有 character，也复用同一转换保留头像。
    """
    members: list[MediaCastMember] = []
    for person in (people or [])[:_CAST_LIMIT]:
        if not isinstance(person, dict):
            continue
        name = (person.get("name") or "").strip()
        if not name:
            continue
        avatar = person.get("avatar") or person.get("cover_url")
        if isinstance(avatar, dict):
            avatar = avatar.get("large") or avatar.get("normal") or avatar.get("small")
        role = (person.get("character") or "").strip()
        role = role.removeprefix("饰 ").removeprefix("饰演 ").strip()
        role = _LATIN_ROLE_TAIL.sub("", role) if _CJK.search(role) else role
        members.append(
            MediaCastMember(
                name=name,
                role=role or None,
                avatar_url=avatar if isinstance(avatar, str) and avatar else None,
            )
        )
    return members


@dataclass(frozen=True)
class _Collection:
    collection_id: str
    title: str
    ranked: bool = False
    count: int = 30


# 行序参考 Netflix 的发现页编排：实时趋势（大数字排名行）打头，随后是时效性
# 内容（院线/热门），再到口碑榜，最后是常青的经典与分类榜——越靠上时效性越强。
_MOVIE_COLLECTIONS = (
    _Collection("movie_real_time_hotest", "豆瓣实时热门电影", True),
    _Collection("movie_showing", "影院热映"),
    _Collection("movie_soon", "即将上映"),
    _Collection("movie_hot_gaia", "豆瓣热门电影"),
    _Collection("movie_weekly_best", "豆瓣一周口碑电影榜", True),
    _Collection("movie_high_score", "豆瓣高分电影"),
    _Collection("movie_top250", "豆瓣电影 Top 250", True),
    _Collection("movie_classic", "经典电影"),
    _Collection("movie_scifi", "高分经典科幻片榜"),
    _Collection("movie_comedy", "高分经典喜剧片榜"),
    _Collection("movie_action", "高分经典动作片榜"),
    _Collection("movie_love", "高分经典爱情片榜"),
)
# 剧集侧同理：实时榜与全量热门在前，口碑榜居中，地区细分行随后，动画与综艺
# 垫底自成品类区。地区行使用豆瓣官方命名榜单 ID（tv_domestic 等），不再用内容
# 等价但含义不透明的 EC 自定义榜单 ID。综艺/动画条目在豆瓣侧 type 同为 tv，
# 可直接通过 _to_card 的类型过滤。
_TV_COLLECTIONS = (
    _Collection("tv_real_time_hotest", "豆瓣实时热门剧集", True),
    _Collection("tv_hot", "近期热门剧集"),
    _Collection("tv_chinese_best_weekly", "华语口碑剧集榜", True),
    _Collection("tv_global_best_weekly", "全球口碑剧集榜", True),
    _Collection("tv_domestic", "近期热门国产剧"),
    _Collection("tv_american", "近期热门美剧"),
    _Collection("tv_japanese", "近期热门日剧"),
    _Collection("tv_korean", "近期热门韩剧"),
    _Collection("tv_animation", "近期热门动画"),
    _Collection("show_domestic", "近期热门国内综艺"),
    _Collection("show_foreign", "近期热门国外综艺"),
)

# 「看全部」落地页开放的完整榜单：发现页横滚行统一只取首屏 30 条，落地页经
# full_collection 按需分页聚合到 count 上限。豆瓣多数榜单强制约 50 条/页，
# 仅 Top 250 支持单次全量返回——聚合循环按实际返回量推进，对两者自适应。
_FULL_COLLECTIONS: dict[str, tuple[_Collection, MediaKind]] = {
    "movie_top250": (
        _Collection("movie_top250", "豆瓣电影 Top 250", True, 250),
        MediaKind.MOVIE,
    ),
    "movie_high_score": (
        _Collection("movie_high_score", "豆瓣高分电影", False, 500),
        MediaKind.MOVIE,
    ),
}


class DoubanDiscoverService:
    """把豆瓣榜单转换为项目统一的发现页模型，不提供条目详情。

    发现页按「布局 + 单行」两级提供：布局是纯配置即时返回；每行独立拉取。
    豆瓣客户端限速为每秒 1 个请求，逐行接口让先就绪的行先渲染，前端不必
    等最慢的榜单——这正是豆瓣视角首访体验的关键。
    """

    def __init__(self, client: DoubanClient) -> None:
        self._client = client
        self._cache = AsyncTTLCache()

    def layout(self, kind: MediaKind) -> DiscoverLayout:
        """发现页布局：行清单来自静态配置，不触发任何豆瓣请求。"""
        specs = _MOVIE_COLLECTIONS if kind is MediaKind.MOVIE else _TV_COLLECTIONS
        return DiscoverLayout(
            has_hero=False,
            rows=[
                DiscoverRowStub(
                    id=f"douban-{spec.collection_id}", title=spec.title, ranked=spec.ranked
                )
                for spec in specs
            ],
        )

    async def discover_hero(self, kind: MediaKind) -> list[MediaCard]:
        """豆瓣视角没有 Hero 大横幅；保留方法让路由层对两个数据源同形调用。"""
        return []

    async def discover_row(self, kind: MediaKind, row_id: str) -> MediaRow | None:
        """拉取布局中的一行；row_id 不在布局里时返回 None（路由层译为 404）。"""
        specs = _MOVIE_COLLECTIONS if kind is MediaKind.MOVIE else _TV_COLLECTIONS
        spec = next((s for s in specs if f"douban-{s.collection_id}" == row_id), None)
        if spec is None:
            return None
        return await self._cache.get_or_set(
            f"douban-row:{kind.value}:{row_id}", _PAGE_TTL, lambda: self._build_row(kind, spec)
        )

    async def full_collection(self, collection_id: str) -> MediaRow:
        """返回一份「看全部」落地页的完整榜单；未开放的榜单 ID 一律 404。"""
        if collection_id not in _FULL_COLLECTIONS:
            raise DoubanNotFoundError("该榜单不存在或未开放完整浏览")
        # 缓存值是 (榜单, 是否被截断)：半截结果只短缓存，几分钟后重试补全，
        # 避免用户对着残缺榜单干等 6 小时
        row, _truncated = await self._cache.get_or_set(
            f"douban-full:{collection_id}",
            lambda value: _PAGE_TRUNCATED_TTL if value[1] else _PAGE_TTL,
            lambda: self._build_full_collection(collection_id),
        )
        return row

    async def _build_full_collection(self, collection_id: str) -> tuple[MediaRow, bool]:
        """分页聚合完整榜单，直到取满 count 上限或上游返回空页。

        每次都请求「剩余全量」，由上游按自身单页上限截断（Top 250 一次给全，
        其余榜单约 50 条/页），再按实际返回量推进游标。受全局 1 次/秒限速，
        冷缓存时 500 条约需十秒；分页各段与聚合结果都有缓存，之后即时返回。
        首页失败直接报错；后续页失败只截断，已取得的部分照常可浏览，返回值
        第二项标记是否发生截断（调用方据此改用短 TTL 缓存）。
        """
        spec, kind = _FULL_COLLECTIONS[collection_id]
        items: list[MediaCard] = []
        seen: set[str] = set()
        start = 0
        truncated = False
        while start < spec.count:
            try:
                data = await self._client.collection(
                    spec.collection_id, count=spec.count - start, start=start
                )
            except DoubanError:
                if not items:
                    raise
                logger.warning(
                    "豆瓣榜单「%s」第 %d 条起的分页失败，先返回已取得的 %d 条",
                    spec.title, start, len(items),
                )
                truncated = True
                break
            raw_items = data.get("subject_collection_items") or []
            if not raw_items:
                break
            # 榜单可能在两次分页之间发生位次变动，按 ID 去重防止重复上墙
            for raw in raw_items:
                card = self._to_card(raw, kind)
                if card is not None and card.id not in seen:
                    seen.add(card.id)
                    items.append(card)
            start += len(raw_items)
        if not items:
            raise DoubanError("豆瓣暂未返回该榜单数据，请稍后重试")
        row = MediaRow(
            id=f"douban-{spec.collection_id}",
            title=spec.title,
            ranked=spec.ranked,
            items=items,
        )
        return row, truncated

    async def search(self, keyword: str) -> list[MediaSearchItem]:
        """返回统一的轻量豆瓣搜索候选；相同关键词缓存十分钟。"""
        normalized = keyword.strip()

        async def load() -> list[MediaSearchItem]:
            results = await self._client.search(normalized)
            return [
                MediaSearchItem(source=MediaSource.DOUBAN, **result) for result in results
            ]

        return await self._cache.get_or_set(
            f"douban-search:{normalized.casefold()}", _SEARCH_TTL, load
        )

    async def media_detail(self, douban_id: str) -> MediaDetail:
        """读取并转换豆瓣详情；图片集和相似推荐缺失时保持空列表。"""
        return await self._cache.get_or_set(
            f"douban-detail:{douban_id}",
            _DETAIL_TTL,
            lambda: self._build_detail(douban_id),
        )

    async def episode_count(self, douban_id: str) -> int | None:
        """豆瓣标注的集数（剧集季条目）；没有或不是剧集时为 None。走详情持久缓存。"""
        data = await self._client.detail(douban_id)
        count = data.get("episodes_count") or data.get("webisode_count")
        try:
            number = int(count)
        except (TypeError, ValueError):
            return None
        return number if number > 0 else None

    async def _celebrity_people(self, douban_id: str) -> dict[str, Any]:
        """取带头像的导演和演员；这一跳失败只降级演职员条，不影响其余详情。"""
        try:
            return await self._client.celebrities(douban_id)
        except DoubanError as exc:
            logger.warning(
                "豆瓣演职员表不可用：%s（%s），退回详情接口里的人物信息",
                douban_id,
                exc,
            )
            return {}

    async def _build_detail(self, douban_id: str) -> MediaDetail:
        data = await self._client.detail(douban_id)
        kind = MediaKind.TV if data.get("type") == "tv" or data.get("is_tv") else MediaKind.MOVIE
        year_text = str(data.get("year") or "")
        cover = data.get("cover_url") or (data.get("pic") or {}).get("large")
        if not year_text[:4].isdigit() or not cover:
            raise DoubanError("该豆瓣条目缺少年份或海报，暂时无法展示详情")
        rating = data.get("rating") or {}
        aliases = [str(alias) for alias in data.get("aka") or [] if alias]
        original_title = data.get("original_title") or next(
            (alias for alias in aliases if alias.isascii()), data["title"]
        )
        durations = data.get("durations") or []
        episodes = data.get("episodes_count") or data.get("webisode_count")
        extent = durations[0] if kind is MediaKind.MOVIE and durations else ""
        if kind is MediaKind.TV and episodes:
            extent = f"{episodes} 集"
        card = MediaCard(
            id=str(data["id"]),
            source=MediaSource.DOUBAN,
            type=kind,
            title=data["title"],
            original_title=original_title,
            year=int(year_text[:4]),
            rating=round(float(rating.get("value") or 0), 1),
            genres=[str(genre) for genre in data.get("genres") or []][:3],
            extent=extent,
            overview=(data.get("intro") or "").strip(),
            poster_url=cover,
        )
        # 演职员优先用带头像的完整名单；该接口不可用时分别退回详情里的导演和
        # 演员信息。不能因为多打的这一跳失败就让整个详情页失败。
        celebrities = await self._celebrity_people(douban_id)
        director_credits = _people_members(
            celebrities.get("directors") or data.get("directors")
        )[:3]
        actors = celebrities.get("actors") or data.get("actors")
        pubdates = data.get("pubdate") or []
        released = data.get("release_date") or (pubdates[0] if pubdates else "")
        return MediaDetail(
            card=card,
            facts=MediaFacts(
                directors=[person.name for person in director_credits],
                director_credits=director_credits,
                cast=_people_members(actors),
                country=" / ".join(data.get("countries") or []),
                language=" / ".join(data.get("languages") or []),
                released=released,
                aliases=aliases,
                source_url=data.get("url") or data.get("sharing_url"),
            ),
        )

    async def _build_row(self, kind: MediaKind, spec: _Collection) -> MediaRow:
        data = await self._client.collection(spec.collection_id, count=spec.count)
        items = [
            card
            for raw in data.get("subject_collection_items", [])
            if (card := self._to_card(raw, kind)) is not None
        ]
        # 条目太少不值得占一行位置：清空 items，前端按「空行」统一收起
        if len(items) < _MIN_ROW_ITEMS:
            items = []
        return MediaRow(
            id=f"douban-{spec.collection_id}", title=spec.title, ranked=spec.ranked, items=items
        )

    @staticmethod
    def _to_card(raw: dict[str, Any], kind: MediaKind) -> MediaCard | None:
        """豆瓣榜单条目映射；缺少 ID、标题、年份或海报的残缺条目不上墙。"""
        raw_type = raw.get("type")
        if raw_type and raw_type != kind.value:
            return None
        item_id = raw.get("id")
        title = raw.get("title") or ""
        subtitle = raw.get("card_subtitle") or ""
        year_text = str(raw.get("year") or subtitle.split(" / ", 1)[0])
        cover = raw.get("cover") or {}
        pic = raw.get("pic") or {}
        poster = cover.get("url") or pic.get("large") or raw.get("cover_url")
        if not item_id or not title or not year_text[:4].isdigit() or not poster:
            return None
        genres = raw.get("genres") or []
        if not genres:
            # 榜单的 card_subtitle/info 依次为年份、地区、类型、导演、主演；
            # 类型段内部以空格分隔，不能把导演和演员误当成类型标签。
            parts = subtitle.split(" / ")
            genre_text = parts[2] if len(parts) > 2 else ""
            genres = genre_text.split()
        photos = raw.get("photos") or []
        backdrop = photos[0] if photos else None
        if isinstance(backdrop, dict):
            backdrop = backdrop.get("large") or backdrop.get("url")
        rating = raw.get("rating") or {}
        return MediaCard(
            id=str(item_id), source=MediaSource.DOUBAN, type=kind, title=title,
            original_title=raw.get("original_title") or title, year=int(year_text[:4]),
            rating=round(float(rating.get("value") or 0), 1), genres=genres[:3],
            overview=(raw.get("description") or raw.get("info") or subtitle).strip(),
            poster_url=poster, backdrop_url=backdrop,
        )

    async def aclose(self) -> None:
        await self._client.aclose()
