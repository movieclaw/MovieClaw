"""飞牛影视（fnOS 影视 / Trim Media）API 协议层。

对接口径与 MoviePilot 的 trimemedia 模块一致（协议经抓包确认的公开实现）：
- 服务地址以 /v 结尾（如 http://nas:5666/v），接口前缀 /api/v1（登录另有 /api/v2）；
- 每个请求带 authx 头：nonce + 毫秒时间戳 + MD5 签名（固定盐 + 路径 + nonce + 时间戳
  + MD5(body) + 固定 apikey 拼接下划线后取 MD5）；
- 登录优先 v2（密码 SHA-256 十六进制小写），服务端没有 v2 时回退 v1 明文；
- 开启设备访问码后须先 GET {根}/c/{访问码} 校验，拿到 Cookie 才能访问登录接口与图片；
- 响应统一 {code, msg, data}，code==0 才算成功。

只依赖主程序已有的 httpx 与标准库。所有方法都是纯 HTTP 封装，不做业务判断——
业务（挑哪个库、写成什么文件）在 planner 与主模块里。
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import random
import time
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import quote, urlsplit

import httpx

# 飞牛客户端公开的固定签名盐与 apikey（Web 前端内置，与 MoviePilot 实现一致）
_AUTHX_SALT = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"
_AUTHX_APIKEY = "16CCEB3D-AB42-077D-36A1-F355324E4237"

_DEFAULT_TIMEOUT = 20.0
_ITEM_PAGE_SIZE = 200

# 媒体库分类 / 条目类型（服务端字符串，未知值原样保留）
CATEGORY_MOVIE = "Movie"
CATEGORY_TV = "TV"
CATEGORY_MIX = "Mix"
CATEGORY_OTHERS = "Others"

TYPE_MOVIE = "Movie"
TYPE_TV = "TV"
TYPE_SEASON = "Season"
TYPE_EPISODE = "Episode"
TYPE_VIDEO = "Video"
TYPE_DIRECTORY = "Directory"

#: 归一化后算作「剧集」的类型（供调用方按库/条目分派电影或剧集）
TV_TYPES = {TYPE_TV, TYPE_SEASON, TYPE_EPISODE}


class TrimError(Exception):
    """飞牛接口调用失败；str(exc) 是给人看的原因。"""


class TrimAuthError(TrimError):
    """登录失败或会话失效（账号密码错、访问码错、服务不可达）。"""


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def authx_header(api_path: str, body: str | None) -> str:
    """按飞牛协议计算单次请求的 authx 头。

    api_path 须带 /v 前缀（没有就补上）；body 是 JSON 序列化后的请求正文，
    GET 请求传 None（按空串参与摘要）。
    """
    if not api_path.startswith("/v"):
        api_path = "/v" + api_path
    nonce = str(random.randint(100000, 999999))
    ts = str(int(time.time() * 1000))
    body_hash = hashlib.md5((body or "").encode("utf-8")).hexdigest()
    sign = hashlib.md5(
        "_".join([_AUTHX_SALT, api_path, nonce, ts, body_hash, _AUTHX_APIKEY]).encode("utf-8")
    ).hexdigest()
    return f"nonce={nonce}&timestamp={ts}&sign={sign}"


def standardize_base_url(url: str) -> str:
    """规整服务地址：补 scheme、去尾部斜杠；不带 /v 结尾的按 MoviePilot 口径补 /v。"""
    url = (url or "").strip()
    if not url:
        return ""
    if "://" not in url:
        url = "http://" + url
    return url.rstrip("/")


def _candidate_hosts(raw: str) -> list[str]:
    """用户填的地址 → 依次尝试的服务根（都带 /v）。

    MoviePilot 的探测口径：先按「没带 /v 就补 /v」试，再按原值试——
    用户可能填的是带 /v 的完整地址，也可能填的是设备根地址。
    """
    base = standardize_base_url(raw)
    if not base:
        return []
    if base.endswith("/v"):
        return [base]
    return [base + "/v", base]


@dataclass
class TrimLibrary:
    """一个飞牛媒体库。"""

    guid: str
    category: str
    name: str
    #: 库的实际目录（仅管理员接口返回；普通用户为空）
    dir_list: list[str] = field(default_factory=list)
    posters: list[str] = field(default_factory=list)

    @property
    def is_movie(self) -> bool:
        return self.category == CATEGORY_MOVIE

    @property
    def is_tv(self) -> bool:
        return self.category == CATEGORY_TV


@dataclass
class TrimItem:
    """一个飞牛媒体条目（列表 / 详情 / 季 / 集通用）。"""

    guid: str
    type: str | None = None
    title: str | None = None
    original_title: str | None = None
    tv_title: str | None = None
    parent_title: str | None = None
    ancestor_guid: str = ""
    overview: str | None = None
    release_date: str | None = None
    air_date: str | None = None
    vote_average: str | None = None
    tmdb_id: int | None = None
    douban_id: int | None = None
    imdb_id: str | None = None
    season_number: int | None = None
    episode_number: int | None = None
    #: 飞牛网页路径（/movie/{guid}、/tv/{guid}……），拼播放入口用
    container: str | None = None
    duration: int | None = None

    @property
    def year(self) -> int | None:
        """年份：电影取发行日期、剧与分集取首播日期的前四位。"""
        date = self.release_date if self.type == TYPE_MOVIE else self.air_date or self.release_date
        if date and len(date) >= 4 and date[:4].isdigit():
            return int(date[:4])
        return None


@dataclass
class TrimPlayLink:
    """一次播放直链请求的结果。"""

    url: str
    #: 直链要带的请求头（如 User-Agent 绑定的直链）；strm 里按 Kodi 写法带上
    headers: dict[str, str] = field(default_factory=dict)


class TrimClient:
    """飞牛影视 HTTP 客户端：会话、签名、登录与接口封装。

    用完调 close()；重新登录调 login()。线程安全不需要——插件内单任务顺序使用。
    """

    def __init__(
        self,
        raw_url: str,
        username: str,
        password: str,
        access_code: str = "",
        *,
        verify: bool | str = True,
    ) -> None:
        self._raw_url = (raw_url or "").strip()
        self._username = username or ""
        self._password = password or ""
        self._access_code = (access_code or "").strip()
        #: TLS 校验：True 校验证书（默认）、False 关闭（自签证书）、也可以直接给 CA 文件路径
        self._verify = verify
        self._host: str | None = None
        self._token: str | None = None
        self._client: httpx.AsyncClient | None = None

    # ---------------------------------------------------------------- 基础
    @property
    def host(self) -> str | None:
        """探测成功的 /v 服务根（如 http://nas:5666/v）；未连接为 None。"""
        return self._host

    @property
    def connected(self) -> bool:
        return self._host is not None and self._token is not None

    def _http(self) -> httpx.AsyncClient:
        if self._client is None:
            # 默认校验证书：走公网反代时，凭据只发给证书对得上的服务器。
            # 飞牛远程默认自签（5667），那种场景由用户在设置里显式关掉，或指定 CA 文件。
            self._client = httpx.AsyncClient(
                timeout=_DEFAULT_TIMEOUT, verify=self._verify, follow_redirects=True
            )
        return self._client

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    async def __aenter__(self) -> TrimClient:
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.close()

    async def _try_connect(self, host: str) -> None:
        """对候选根做一次版本探测，成功则记下 host（不登录）。失败抛 TrimError。"""
        url = f"{host}/api/v1/sys/version"
        headers = {
            "Accept": "application/json",
            "Referer": host,
            "authx": authx_header("/api/v1/sys/version", None),
        }
        try:
            resp = await self._http().get(url, headers=headers)
        except httpx.HTTPError as exc:
            raise TrimError(f"连不上飞牛服务（{host}）：{exc}") from exc
        data = _unwrap(resp, url)
        # 版本接口只用来确认地址可达；data 可能是 {version, mediasrvVersion}
        if not isinstance(data, dict):
            raise TrimError(f"飞牛服务版本接口返回异常（{host}）")

    async def connect(self) -> None:
        """探测服务地址（MoviePilot 口径的候选顺序），成功后记下 host。"""
        candidates = _candidate_hosts(self._raw_url)
        if not candidates:
            raise TrimError("飞牛服务地址没有填")
        last: Exception | None = None
        for host in candidates:
            try:
                await self._try_connect(host)
                self._host = host
                return
            except TrimError as exc:
                last = exc
        raise last or TrimError("飞牛服务地址探测失败")

    # ---------------------------------------------------------------- 访问码与登录
    async def _verify_access_code(self, host: str) -> None:
        """开启访问码的设备：GET {设备根}/c/{访问码} 换会话 Cookie。没填访问码跳过。"""
        if not self._access_code:
            return
        root = host[: -len("/v")] if host.endswith("/v") else host
        url = f"{root}/c/{quote(self._access_code, safe='')}"
        try:
            resp = await self._http().get(url)
        except httpx.HTTPError as exc:
            raise TrimError(f"访问码校验请求失败：{exc}") from exc
        if resp.status_code == 404:
            raise TrimAuthError("飞牛访问码校验失败（404）：请检查访问码是否正确")
        if resp.status_code >= 400:
            raise TrimAuthError(f"飞牛访问码校验失败：HTTP {resp.status_code}")

    async def login(self) -> None:
        """探测地址（如未探测）→ 校验访问码 → v2 登录（回退 v1）→ 记下 token。"""
        if self._host is None:
            await self.connect()
        host = self._host
        assert host is not None
        if not self._username or not self._password:
            raise TrimAuthError("飞牛用户名或密码没有填")
        await self._verify_access_code(host)

        password_hash = sha256_hex(self._password)
        # v2：SHA-256 摘要；服务端没有该接口（旧版）时回退 v1 明文
        v2 = await self._request(
            "POST",
            "/user/loginByPassword",
            base="/api/v2",
            data={
                "username": self._username,
                "password": password_hash,
                "app_name": "trimemedia-web",
            },
            error_cls=TrimError,
            allow_http_error=True,
        )
        if v2 is not None:
            token = v2.get("token")
            if not token:
                raise TrimAuthError("飞牛影视登录失败：服务端没有返回令牌（检查账号密码）")
            self._token = str(token)
            return
        v1 = await self._request(
            "POST",
            "/login",
            data={
                "username": self._username,
                "password": self._password,
                "app_name": "trimemedia-web",
            },
            error_cls=TrimAuthError,
        )
        token = v1.get("token")
        if not token:
            raise TrimAuthError("飞牛影视登录失败：账号、密码或服务端版本不支持")
        self._token = str(token)

    async def ensure_login(self) -> None:
        """已登录直接用；否则走一遍登录。播放链路每次现调，避免拿着过期 token。"""
        if not self.connected:
            await self.login()

    async def logout(self) -> None:
        if self.connected:
            # 登出失败不碍事：本地丢 token 即可
            with contextlib.suppress(TrimError):
                await self._request("POST", "/user/logout", error_cls=TrimError)
        self._token = None

    # ---------------------------------------------------------------- 请求核
    async def _request(
        self,
        method: str,
        api: str,
        *,
        base: str = "/api/v1",
        data: dict[str, Any] | None = None,
        params: dict[str, Any] | None = None,
        error_cls: type[Exception] = TrimError,
        allow_http_error: bool = False,
    ) -> dict[str, Any] | None:
        """发一次带 authx 签名的请求，返回 data 部分。

        - 业务失败（code != 0）：抛 error_cls；
        - HTTP 层失败：默认抛 error_cls；allow_http_error=True 时返回 None
          （给 v2 登录探测用：接口不存在 → 回退 v1）。
        """
        host = self._host
        if host is None:
            raise TrimError("尚未连接飞牛服务")
        api_path = f"{base}/{api.lstrip('/')}"
        url = f"{host}{api_path}"
        body: str | None = None
        # 签名原文：POST 用 JSON 正文；GET 用**未编码**的查询串（按插入顺序拼接）。
        # 这一点踩过坑：把 URL 编码后的查询串拿去签名会被判 invalid sign，
        # 不把查询串放进摘要同样 invalid —— 服务端要的就是 `k=v&k2=v2` 原样。
        queries_unquoted = "&".join(f"{k}={v}" for k, v in params.items()) if params else None
        headers = {
            "Accept": "application/json",
            "Referer": host,
            "authx": authx_header(api_path, queries_unquoted),
        }
        if data is not None:
            body = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
            headers["Content-Type"] = "application/json"
            headers["authx"] = authx_header(api_path, body)
        if self._token:
            headers["Authorization"] = self._token
        try:
            resp = await self._http().request(
                method, url, headers=headers, params=params, content=body
            )
        except httpx.HTTPError as exc:
            if allow_http_error:
                return None
            raise error_cls(f"请求飞牛接口失败（{api}）：{exc}") from exc
        if allow_http_error and resp.status_code == 404:
            return None  # 旧版服务端没有这个接口
        return _unwrap(resp, url, error_cls)

    # ---------------------------------------------------------------- 接口
    async def libraries(self) -> list[TrimLibrary]:
        """媒体库列表：管理员走 /mdb/list（带实际目录），普通用户走 /mediadb/list。"""
        data = await self._request("GET", "/mdb/list", error_cls=TrimAuthError)
        if data is None:
            data = await self._request("GET", "/mediadb/list", error_cls=TrimAuthError)
        libs: list[TrimLibrary] = []
        for row in data or []:
            if not isinstance(row, dict) or not row.get("guid"):
                continue
            mdb = row if "name" in row else {}
            libs.append(
                TrimLibrary(
                    guid=str(row["guid"]),
                    category=str(row.get("category") or CATEGORY_OTHERS),
                    name=str(row.get("name") or row.get("title") or ""),
                    dir_list=[str(d) for d in (mdb.get("dir_list") or row.get("dir_list") or [])],
                    posters=[str(p) for p in (row.get("posters") or [])],
                )
            )
        return libs

    async def items_page(
        self,
        library_guid: str,
        *,
        types: list[str] | None = None,
        page: int = 1,
        page_size: int = _ITEM_PAGE_SIZE,
    ) -> tuple[list[TrimItem], int | None]:
        """按库分页拉条目（只收电影 / 剧，目录交给「按条目直取」不递归）。

        返回（本页条目，总数或 None）。
        """
        body: dict[str, Any] = {
            "ancestor_guid": library_guid,
            "tags": {"type": types or [TYPE_MOVIE, TYPE_TV]},
            "exclude_grouped_video": 1,
            "sort_column": "create_time",
            "sort_type": "DESC",
            "page": page,
            "page_size": page_size,
        }
        data = await self._request("POST", "/item/list", data=body, error_cls=TrimError)
        if data is None:
            return [], None
        rows = data.get("list") or []
        total = data.get("total", data.get("total_count"))
        return [_build_item(row) for row in rows if isinstance(row, dict)], _int_or_none(total)

    async def all_items(self, library_guid: str) -> list[TrimItem]:
        """拉全一个库的条目（分页翻完为止）。条目数上万也只是几十次请求。"""
        out: list[TrimItem] = []
        page = 1
        while True:
            batch, total = await self.items_page(library_guid, page=page)
            out.extend(batch)
            if total is not None and total <= page * _ITEM_PAGE_SIZE:
                break
            if not batch:
                break  # 防御：服务端分页异常时不死循环
            page += 1
        return out

    async def tv_episodes(self, tv_guid: str) -> tuple[list[TrimItem], int]:
        """拉全一个剧的全部分集：剧 → 季 → 集（``/item/list`` 不回分集）。

        返回 ``(分集, 失败的季数)``。**失败必须让调用方知道**：把「这次没查到」
        当成「飞牛上已经没有了」，下一步就会把整季的台账标成 missing，
        一次网络抖动就能让一季播不了（评审指出的问题）。
        """
        out: list[TrimItem] = []
        failed = 0
        try:
            seasons = await self.seasons(tv_guid)
        except TrimError:
            return out, 1
        for season in seasons:
            try:
                episodes = await self.episodes(season.guid)
            except TrimError:
                failed += 1  # 个别季失败不拖垮整部剧，但要记下来
                continue
            out.extend(e for e in episodes if e.episode_number is not None)
        return out, failed

    async def item_detail(self, guid: str) -> TrimItem | None:
        """单条目详情（比列表行多容器等信息；查不到返回 None）。"""
        data = await self._request("GET", f"/item/{quote(guid, safe='')}", error_cls=TrimError)
        return _build_item(data) if isinstance(data, dict) else None

    async def seasons(self, tv_guid: str) -> list[TrimItem]:
        data = await self._request(
            "GET", f"/season/list/{quote(tv_guid, safe='')}", error_cls=TrimError
        )
        return [_build_item(row) for row in data or [] if isinstance(row, dict)]

    async def episodes(self, season_guid: str) -> list[TrimItem]:
        data = await self._request(
            "GET", f"/episode/list/{quote(season_guid, safe='')}", error_cls=TrimError
        )
        return [_build_item(row) for row in data or [] if isinstance(row, dict)]

    async def play_info(self, item_guid: str) -> dict:
        """取条目的播放信息：媒体/视频/音频/字幕各轨的 guid（POST /play/info）。

        前端口径（飞牛影视 Web 的调用方式）：body ``{item_guid}``。
        """
        data = await self._request(
            "POST", "/play/info", data={"item_guid": item_guid}, error_cls=TrimError
        )
        return data if isinstance(data, dict) else {}

    async def play_start(self, item_guid: str, info: dict) -> dict:
        """开始一次播放会话，返回 play_link 等（POST /play/play）。

        飞牛这台服务端（mediasrv 0.8.x）对本地文件只给 HLS（.m3u8 + ts 分片）
        的转码流，没有原画直出——所以远端播放要靠插件代理这串 HLS。
        """
        body = {
            "item_guid": item_guid,
            "media_guid": info.get("media_guid") or "",
            "video_guid": info.get("video_guid") or "",
            "audio_guid": info.get("audio_guid") or "",
            "subtitle_guid": info.get("subtitle_guid") or "",
        }
        data = await self._request("POST", "/play/play", data=body, error_cls=TrimError)
        return data if isinstance(data, dict) else {}

    async def open_stream(self, item_guid: str) -> tuple[str, dict[str, str]]:
        """取这个条目的 HLS 播放地址与请求头（每次现取——地址带会话与时效）。"""
        info = await self.play_info(item_guid)
        played = await self.play_start(item_guid, info)
        link = str(played.get("play_link") or "")
        if not link:
            raise TrimError("飞牛没有返回播放地址（条目可能不可播）")
        if not link.startswith("http"):
            host = self._host or ""
            # play_link 是 /v/media/... 的绝对路径
            root = host[:-2] if host.endswith("/v") else host
            link = f"{root}{link}"
        headers: dict[str, str] = {"Trim-MC-token": self._token or ""}
        if self._token:
            headers["Authorization"] = self._token
        return link, headers

    def _session_headers(self) -> dict[str, str]:
        """当前会话的取流凭证（HLS 分片转发用）。"""
        headers = {"Trim-MC-token": self._token or ""}
        if self._token:
            headers["Authorization"] = self._token
        return headers

    async def fetch_bytes(self, url: str, headers: dict[str, str]) -> tuple[bytes, str]:
        """带会话凭证取一段字节（HLS 分片、播放列表用它转发）。"""
        resp = await self._http().get(url, headers=headers)
        if resp.status_code >= 400:
            raise TrimError(f"取流失败：HTTP {resp.status_code}")
        return resp.content, resp.headers.get("content-type") or "application/octet-stream"

    async def set_play_config(self, item_guid: str, skip_opening: int, skip_ending: int) -> None:
        """写条目的「跳过片头 / 跳过片尾」秒数（POST /play/setConfigByItem）。

        落库到飞牛的 ``item_play_config(item_guid, user_guid, skip_opening, skip_ending)``，
        按当前登录用户存；飞牛播放器播放这一条时会读它并自动跳过。
        注意：传 0 不会覆盖已有值（服务端把 0 当作未设置），要清除得另想办法。
        """
        await self._request(
            "POST",
            "/play/setConfigByItem",
            data={
                "guid": item_guid,
                "skip_opening": int(skip_opening),
                "skip_ending": int(skip_ending),
            },
            error_cls=TrimError,
        )

    async def record_progress(self, item_guid: str, *, ts: int, watched: int) -> None:
        """上报观看进度（POST /play/record），ts 单位秒、watched=1 表示看完。

        服务端要求带上三条流的 guid 一起提交，缺一个就 Invalid Params。
        """
        info = await self.play_info(item_guid)
        await self._request(
            "POST",
            "/play/record",
            data={
                "item_guid": item_guid,
                "ts": int(ts),
                "watched": int(watched),
                "media_guid": info.get("media_guid") or "",
                "video_guid": info.get("video_guid") or "",
                "audio_guid": info.get("audio_guid") or "",
                "subtitle_guid": info.get("subtitle_guid") or "",
                "direct_link_audio_index": -1,
                "resolution": "",
                "bitrate": 0,
                "type": "Episode" if info.get("parent_guid") else "Movie",
                "visible": 1,
            },
            error_cls=TrimError,
        )

    async def play_link(self, video_guid: str) -> TrimPlayLink:
        """取播放直链：/play/info 拿视频轨 guid，再 /play/play 换直链。

        MoviePilot 与 trim-cli 同口径。两步中任何一步拿不到就抛 TrimError——
        播放链路是关键路径，不猜不兜底，错误原文给到播放器页面。
        """
        url, headers = await self.open_stream(video_guid)
        return TrimPlayLink(url=url, headers=headers)

    async def user_info(self) -> dict[str, Any]:
        """当前登录账号：``guid / username / is_admin / lan / last_login_time``。

        飞牛没有「会员等级 / 剩余下载额度」这类字段——实测返回就这些，
        页面别自己编概念。
        """
        data = await self._request("GET", "/user/info", error_cls=TrimError)
        return data if isinstance(data, dict) else {}

    async def users(self) -> list[dict[str, Any]]:
        """飞牛上的账号列表（管理员接口）：每个账号带可见媒体库与权限档。

        普通账号调用会失败（返回空列表），页面据此显示「需要管理员」。
        """
        try:
            data = await self._request("GET", "/manager/user/list", error_cls=TrimError)
        except TrimError:
            return []
        rows = data if isinstance(data, list) else []
        return [row for row in rows if isinstance(row, dict)]

    async def permission_template(self) -> dict[str, Any]:
        """新建账号时的默认权限模板（``media_permission`` + 可见库清单）。"""
        try:
            data = await self._request("GET", "/manager/template/permission", error_cls=TrimError)
        except TrimError:
            return {}
        return data if isinstance(data, dict) else {}

    async def test(self) -> dict[str, Any]:
        """连接测试：探测 + 登录 + 版本与服务标识，给管理页一次说清哪里配错了。"""
        await self.connect()
        await self.login()
        libs = await self.libraries()
        host = self._host or ""
        parts = urlsplit(host)
        # 服务端标识（建库的 source_config、播放定位都要用）
        server_guid = ""
        server_name = ""
        cfg = await self._request("GET", "/sys/config", error_cls=TrimError)
        if isinstance(cfg, dict):
            server_guid = str(cfg.get("server_guid") or "")
            server_name = str(cfg.get("server_name") or "")
        return {
            "ok": True,
            "host": f"{parts.scheme}://{parts.netloc}",
            "server_guid": server_guid,
            "server_name": server_name,
            "libraries": [
                {"guid": lib.guid, "name": lib.name, "category": lib.category, "dirs": lib.dir_list}
                for lib in libs
            ],
        }


# ------------------------------------------------------------------ 辅助
def _unwrap(resp: httpx.Response, url: str, error_cls: type[Exception] = TrimError) -> Any:
    """飞牛统一响应 {code, msg, data}：code==0 返回 data；其余抛错。"""
    if resp.status_code == 401:
        raise TrimAuthError("飞牛会话已失效（401），请重新保存账号密码")
    try:
        payload = resp.json()
    except ValueError as exc:
        raise error_cls(f"飞牛接口返回的不是 JSON（HTTP {resp.status_code}）：{url}") from exc
    if not isinstance(payload, dict):
        raise error_cls(f"飞牛接口返回结构异常：{url}")
    code = payload.get("code")
    try:
        code = int(code)
    except (TypeError, ValueError):
        code = -1
    if code != 0:
        msg = str(payload.get("msg") or payload.get("message") or "未知错误")
        raise error_cls(f"飞牛接口错误（code {code}）：{msg}")
    return payload.get("data")


def _int_or_none(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _build_item(row: dict[str, Any]) -> TrimItem:
    """服务端条目字典 → TrimItem。trim_id 带 tt/tm 前缀，去前缀即 TMDB id。"""
    trim_id = row.get("trim_id")
    tmdb_id = None
    if isinstance(trim_id, str) and trim_id[:2] in ("tt", "tm"):
        tmdb_id = _int_or_none(trim_id[2:])
    return TrimItem(
        guid=str(row.get("guid") or ""),
        type=row.get("type"),
        title=row.get("title"),
        original_title=row.get("original_title"),
        tv_title=row.get("tv_title"),
        parent_title=row.get("parent_title"),
        ancestor_guid=str(row.get("ancestor_guid") or ""),
        overview=row.get("overview"),
        release_date=row.get("release_date"),
        air_date=row.get("air_date"),
        vote_average=str(row["vote_average"]) if row.get("vote_average") is not None else None,
        tmdb_id=tmdb_id,
        douban_id=_int_or_none(row.get("douban_id")),
        imdb_id=row.get("imdb_id"),
        season_number=_int_or_none(row.get("season_number")),
        episode_number=_int_or_none(row.get("episode_number")),
        container=row.get("container"),
        duration=_int_or_none(row.get("duration")),
    )
