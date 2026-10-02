"""播放记录在 Web 业务界面的响应模型。"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.library import LibraryItemView
from movieclaw_media.models import MediaKind


class UpNextItemView(BaseModel):
    """媒体库首页「接下来继续」的一张卡片。

    卡片指向的**永远是还没看完的那个单元**——电影是它自己，剧集是从最近播放
    那一集起往后第一个没看完的。看完的作品不出卡，所以这里没有"已看完"态。
    """

    media_item_id: int
    library_id: int
    kind: MediaKind
    title: str
    year: int | None
    poster_url: str | None
    # 海报真实宽高比（同海报墙的 primary_aspect）：其他库的本地封面多是 16:9 抓帧，
    # 缺横向剧照时前端按这个比例决定直接铺满 16:9 卡片还是模糊铺底居中完整显示
    poster_aspect: float = Field(
        default=0.6667, description="海报宽高比（同海报墙 primary_aspect）"
    )
    backdrop_url: str | None
    episode_still_url: str | None
    # 以下几项给电视首页的大图区用（docs/design/tvos-app.md §3.1）。都可为空：
    # 新版客户端连旧版服务端时缺这几个键也能照常解析。
    # 分集剧照的本地资产只存 w300 小图（一部剧几百集，存原图太占盘），手机卡片够用；
    # 电视卡片在 4K 下有 920px 宽，另给 TMDB 原图，由图片代理按需抓取并缓存
    episode_still_original_url: str | None = Field(
        default=None, description="分集剧照的 TMDB 原图（电视等大屏用）"
    )
    logo_url: str | None = Field(default=None, description="片名 Logo（透明底，本地资产优先）")
    overview: str | None = Field(
        default=None, description="简介：剧集取卡片这一集的（没有则用整部剧的），电影取影片的"
    )
    genres: list[str] | None = Field(default=None, description="类型（如「剧情」「科幻」）")
    # 季集是**卡片这一集**的，不是最近播放那一集的：卡片指向下一集时，
    # 标题、剧照、时长、详情落点都跟着走
    season_number: int
    episode_number: int
    episode_title: str | None
    # 卡片这一集**之后**还有几个没看完、且文件在位的单元——"还能接着看几集"。
    # 补齐的旧季与洗版的老集排在前面，不计入；电影恒为 0
    unwatched_ahead_count: int
    # 续播点。为 0 就是"这一集还没开过"（多半是下一集），前端据此在
    # 「继续看 · 42%」与「下一集」两种文案间选
    position_ms: int
    duration_ms: int | None
    progress_percent: int | None
    #: 卡片已经**翻过篇**了：最近播放那一集看完了，这张卡指向它之后的下一集。
    #: 前端推不出来——``position_ms == 0`` 同时意味着"下一集"和"这一集还没开过"，
    #: 两者该说的话不一样
    advanced: bool = Field(default=False, description="指向的是下一集，而不是上次那一个")
    #: 最近一次播放这部作品的时间——卡片的排序依据与"什么时候看的"那行文案
    last_played_at: datetime


class UpNextView(BaseModel):
    """「接下来继续」横排的数据载荷。"""

    items: list[UpNextItemView]


class FavoriteItemView(LibraryItemView):
    """首页「我的收藏」的一格：单库海报墙的条目视图 + 收藏上下文。

    收藏层级来自最近一次收藏的那一行：整剧两者皆 null，整季只有季号，
    单集季集都有；电影恒为 null（内部 (0,0) 哨兵不外泄）。
    """

    library_id: int = Field(description="卡片的详情落点库（同一作品跨库时取首页顺序第一个可见库）")
    favorite_season_number: int | None = None
    favorite_episode_number: int | None = None


class FavoritesView(BaseModel):
    """「我的收藏」分区的数据载荷。``total`` 是去重后的收藏作品总数，
    ``items`` 受 limit 截断——前端据此决定要不要给「展开全部」。"""

    items: list[FavoriteItemView]
    total: int


# ---------------------------------------------------------------------------
# 活动页「观看」视角（管理员运维视角，docs/design/activity.md）
# ---------------------------------------------------------------------------


class MediaActivityTarget(BaseModel):
    """播放会话 / 文件下载指向的媒体条目摘要。"""

    media_item_id: int
    # 详情页落点：同一作品跨库时取一个确定可达的库；无在位文件为 None
    library_id: int | None
    # 落点库是否在当前超管的可浏览范围内。「全部」口径下范围外记录照常出片名，
    # 但浏览类接口对范围外超管是 404，前端据此不渲染详情链接
    browsable: bool = True
    kind: MediaKind
    title: str
    year: int | None
    poster_url: str | None
    season_number: int
    episode_number: int
    episode_title: str | None


class PlaybackFileSpec(BaseModel):
    """正在播放文件的技术规格（来自 library_file 台账）。"""

    resolution: str | None
    video_codec: str | None
    hdr: str | None
    container: str | None
    bit_rate: int | None
    size_bytes: int | None


class PlaybackDeliveryView(BaseModel):
    """这台设备此刻是怎么在播的：直连原文件，还是经服务器重封装 / 转码（活动页的播放方式标识）。"""

    mode: str = Field(
        description=(
            "direct=直连原文件；remux=重封装（音视频都不重编码）；"
            "audio=只转音频（视频直通）；transcode=视频转码"
        )
    )
    label: str = Field(
        description="简短中文标识：直连 / 重封装 / 音频转码 / 硬件转码 / 软件转码 / 远程转码"
    )
    target: str | None = Field(
        default=None, description="转码输出规格，如「1080p · H.264 · 8 Mbps」；直连 / 重封装为 null"
    )
    executor: str | None = Field(
        default=None,
        description=(
            "在哪转、用什么转，如「NAS · Intel 核显（QSV）」"
            "「远程 Worker「studio」· Apple 芯片（VideoToolbox）」"
        ),
    )
    reason: str | None = Field(default=None, description="服务端为什么选这个播放方式（中文）")


class ActivePlaybackSessionView(BaseModel):
    """一台设备正在进行的播放会话。"""

    device_id: str
    # 能否「注销此设备」：只有持 Jellyfin 设备凭据的会话可以；网页播放器走
    # 登录会话，没有可撤销的设备凭据
    revocable: bool = True
    member_name: str
    client: str
    device_name: str
    client_version: str
    media: MediaActivityTarget
    position_ms: int | None
    duration_ms: int | None
    progress_percent: int | None
    paused: bool
    # local = 本地文件直连（速率可测）；remote = 网盘直链等不经过服务器的播放
    play_method: str
    rate_bytes_per_second: float | None
    bytes_sent: int | None
    connections: int
    file: PlaybackFileSpec | None
    # 播放方式：按设备在服务端有没有在跑的重封装 / 转码会话判定；
    # 网盘直链（play_method=remote）为 null。seek 重启的一瞬间会话可能正在重建，
    # 这一轮会短暂显示成直连，下一轮轮询即恢复
    delivery: PlaybackDeliveryView | None = None
    started_at: datetime
    last_report_at: datetime


class ActiveFileDownloadView(BaseModel):
    """一条正在进行的整文件下载（播放器的离线缓存）。"""

    device_id: str
    revocable: bool = True
    member_name: str
    client: str
    device_name: str
    media: MediaActivityTarget | None
    file_name: str
    size_bytes: int
    bytes_sent: int
    rate_bytes_per_second: float
    # 同一设备对同一文件的多条 Range 连接（断点续传）聚合为一条展示
    connections: int
    # 已下载到文件的哪个位置（Range 起点 + 本次已传），以及据此换算的百分比。
    # 文件大小未知时为 None，界面不画进度条而不是画一条假的。
    position_bytes: int
    progress_percent: int | None
    started_at: datetime


class MediaActivityView(BaseModel):
    """活动页「观看」视角的实时快照：正在播放与正在下载。

    历史（每场一行的播放记录）走 ``PlaybackHistoryView``，本载荷只装页面 8 秒
    轮询真正要刷新的实时部分。
    """

    sessions: list[ActivePlaybackSessionView]
    downloads: list[ActiveFileDownloadView]
    # 「我的浏览范围」口径下落在当前超管不可浏览的库里的记录：不出片名与海报，
    # 只报个数（docs/design/library-access.md 2.5）。「全部」口径恒为 0。
    hidden_session_count: int = Field(default=0, description="不在你可见范围内的正在播放数")
    hidden_download_count: int = Field(default=0, description="不在你可见范围内的正在下载数")


class PlaybackLogEntryView(BaseModel):
    """一场播放（playback_log 的一行）。"""

    id: int
    member_name: str
    media: MediaActivityTarget
    client: str
    device_name: str
    started_at: datetime
    # None = 仍在进行中（没收到停止且最后心跳还在保鲜期内）
    ended_at: datetime | None
    watched_ms: int = Field(description="实际观看时长（毫秒）")
    start_position_ms: int
    end_position_ms: int
    # 这一场结束时看到哪：分母是服务端算的片长，条目已删时为 None
    duration_ms: int | None = None
    progress_percent: int | None = None
    completed: bool = Field(description="本场是否看完")


class PlaybackHistoryView(BaseModel):
    entries: list[PlaybackLogEntryView]
    hidden_count: int = Field(default=0, description="不在你可见范围内的记录数")
    # 游标翻页：本页之后还有没有更多；有则带上下一页的游标（本页最后一行的 id）
    has_more: bool = False
    next_cursor: int | None = None


class PlaybackStatsMemberRow(BaseModel):
    member_id: int
    member_name: str
    plays: int
    watched_ms: int
    completed: int


class PlaybackStatsClientRow(BaseModel):
    client: str
    plays: int
    watched_ms: int


class PlaybackStatsDayRow(BaseModel):
    date: str = Field(description="按浏览器时区的日期 YYYY-MM-DD")
    plays: int
    watched_ms: int
    completed: int = 0
    members: int = Field(default=0, description="当天有播放的成员数")


class PlaybackStatsTitleRow(BaseModel):
    media: MediaActivityTarget
    plays: int
    watched_ms: int
    members: int = Field(default=0, description="看过这部作品的成员数")


class PlaybackStatsTotals(BaseModel):
    """一个周期的四个汇总数。"""

    plays: int = Field(description="播放场次")
    watched_ms: int = Field(description="观看总时长（毫秒）")
    completed: int = Field(description="看完的场次")
    active_members: int = Field(description="有播放的成员数")


class PlaybackStatsTierRow(BaseModel):
    """网页播放按档位的分解（直连 / 重封装 / 音频转码 / 硬件转码 / 软件转码）。"""

    tier: int
    label: str
    plays: int


class PlaybackWatchStatsView(BaseModel):
    """一段时间内的观看统计（docs/design/activity.md「观看统计」）。

    当前周期与**上一周期**成对返回：没有参照系的数字只是数据，不是洞察。
    ``by_day`` 与 ``previous_by_day`` 按天对齐（同为 days+1 行），主图把两条线画在
    同一坐标系里。``by_hour`` 是星期 × 小时的观看时长矩阵（周一为 0 行），按浏览器
    时区分桶，回答「家里什么时候有人在看」。
    """

    days: int
    current: PlaybackStatsTotals
    previous: PlaybackStatsTotals
    previous_available: bool = Field(description="上一周期有没有日志（日志刚开始记时没有）")
    by_day: list[PlaybackStatsDayRow]
    previous_by_day: list[PlaybackStatsDayRow]
    by_hour: list[list[int]] = Field(
        description="7×24 观看时长（毫秒），行=星期（0=周一），列=小时"
    )
    by_member: list[PlaybackStatsMemberRow]
    by_client: list[PlaybackStatsClientRow]
    by_tier: list[PlaybackStatsTierRow] = Field(
        description="网页播放按档位；Jellyfin 客户端恒为直连，不在内"
    )
    top_titles: list[PlaybackStatsTitleRow]
    hidden_title_count: int = Field(default=0, description="作品榜里不在你可见范围内的条数")
    favorites: list[PlaybackStatsTitleRow] = Field(
        default_factory=list,
        description="本期最受欢迎前三：看过的成员最多，并列取时长长的；与作品榜（按时长）口径不同",
    )
    previous_favorites: list[PlaybackStatsTitleRow] = Field(
        default_factory=list, description="上一周期的前三，用来标「蝉联 / 上期第 n / 新上榜」"
    )


class PlaybackHistoryClearView(BaseModel):
    """清除观看记录的结果：删掉了多少条状态与多少条播放质量指标。"""

    deleted_states: int = Field(description="删除的观看状态行数（续播点/已看/播放次数）")
    deleted_metrics: int = Field(description="删除的播放质量指标行数")


# ---------------------------------------------------------------------------
# 网页播放器：能力探测与播放决策（docs/design/web-player.md §3）
# ---------------------------------------------------------------------------


class VideoSupportIn(BaseModel):
    """前端 ``MediaCapabilities.decodingInfo()`` 的一项视频探测结果。"""

    codec: str
    max_height: int = 2160
    # decodingInfo 三态之二。canPlayType 给不出这两个信号——它分不清
    # 「能解码」和「能流畅解码」。
    smooth: bool = True
    power_efficient: bool = True


class AudioSupportIn(BaseModel):
    codec: str
    max_channels: int = 8


class ClientCapabilityIn(BaseModel):
    """客户端解码能力快照。前端探测后随决策请求上送，并缓存在 localStorage。"""

    video: list[VideoSupportIn] = []
    audio: list[AudioSupportIn] = []
    containers: list[str] = []
    hdr_passthrough: bool = False
    mse: str = "full"
    is_mobile: bool = False
    native_hls: bool = False
    #: 全解码播放器自己拉原文件（App 的自研引擎）：决策直接给档 0 原文件直连，
    #: 不逐项比对、不采样关键帧、不起 ffmpeg。只有多剪辑原盘（没有单个文件可拉）
    #: 例外，照样拼成不转码的 HLS。用户限了画质或线路不够、需要服务端压码率时
    #: 客户端不带它。
    universal: bool = False
    #: 能在本机读光盘镜像（蓝光 UDF / DVD ISO9660）：ISO 给档 0 原字节直推。
    #: 只有 App 的自研引擎申报（disc-direct-play.md）
    disc_image: bool = False
    #: 能经目录取流接口读原盘目录：多剪辑原盘给档 0 目录直推（会话的 ``stream_url``
    #: 是目录清单地址，决策带主播放列表名），NAS 不起 ffmpeg
    disc_folder: bool = False


class PlaybackDecideRequest(BaseModel):
    """一次播放决策请求。``file_id`` 与播放单元二选一——给单元时服务端会在
    该单元的全部版本文件里择优（能直通的 1080p 胜过要转码的 2160p）。"""

    file_id: int | None = None
    media_item_id: int | None = None
    season_number: int = 0
    episode_number: int = 0
    capability: ClientCapabilityIn
    # 运行期降档回路：前端播放失败后带上已失败的档位重来，服务端跳过它们。
    failed_tiers: list[int] = []
    #: 用户在播放器里点选的音轨（``embedded:<k>``）。给了就认它，服务端不再
    #: 自动换轨。**选了非默认轨会把档 0 顶成档 1**——直出时浏览器只放默认轨，
    #: 必须重封装才能把选中的那条带上。
    audio_track: str | None = None
    #: 用户选中的字幕轨（中性引用）。只在指向**内封 PGS 轨**时改变决策：
    #: 视频转码 + 字幕烧录进画面（Emby 语义，硬边界 1 的唯一例外）。
    #: None = 用观看状态里记住的轨；"off" 与文本轨都不影响视频策略。
    subtitle_track: str | None = None
    #: 用户选的画质上限（如 720）。语义是上限而非目标：源不超就照常直通，
    #: 超了才转码降下去。None = 自动。弱网救急用（§10「手动选清晰度」）。
    max_height: int | None = Field(default=None, ge=240, le=2160)
    #: 浏览器的稳定标识（与进度上报同一个值）。开会话时写进取流 token，
    #: 取流字节才能记到活动页上这台浏览器的会话名下。
    device_id: str | None = Field(default=None, max_length=128)
    #: 前端实测的下行速度（bps，传输期口径）。只在**开/重开会话**时生效，
    #: 且只对转码视频起作用：把 maxrate 压到线路装得下的水平，必要时连高度
    #: 一起降（services/playback/adaptive.py）。用户手动选了画质上限时忽略——
    #: 他的选择优先。样本不够时不带。
    downlink_bps: int | None = Field(default=None, ge=0, le=10**12)


class VideoPlanView(BaseModel):
    action: str
    codec: str | None = None
    height: int | None = None
    tone_map: bool = False
    #: 按实测带宽收紧后的码率上限（bps）；None = 只按分辨率阶梯
    bitrate_cap_bps: int | None = None
    #: 非空 = 该字幕轨被烧录进画面（用户显式选中 PGS 触发，Emby 语义的
    #: 「字幕压制」）。前端据此：不再旁挂渲染这条轨、菜单选中态指向它、
    #: 诊断面板显示「字幕压制」。
    burn_subtitle: str | None = None


class AudioPlanView(BaseModel):
    action: str
    track_ref: str | None = None
    codec: str | None = None
    channels: int | None = None
    downmix: bool = False


class AudioTrackView(BaseModel):
    """文件里的一条可选音轨。给播放器渲染音轨菜单用——只有候选列表在手，
    前端才能让用户换轨；`audio.track_ref` 说的是「这次放的是哪条」。"""

    ref: str
    codec: str | None = None
    channels: int | None = None
    language: str | None = None
    is_default: bool = False


class SubtitlePlanView(BaseModel):
    track_ref: str
    kind: str
    language: str | None = None
    is_default: bool = False
    #: 本机 AI 生成的字幕（翻译/双语）。播放器的字幕菜单据此打「AI 生成」标
    is_ai: bool = False


class PlaybackDecisionView(BaseModel):
    """决策结果的三态并集。``outcome`` 决定其余字段哪些有值。

    - ``plan``    —— 可以播，按 ``tier`` 走；
    - ``consent`` —— 需要用户同意开启软件转码（§3.6）；
    - ``rejected``—— 放不了，``reason`` / ``suggestion`` 面向用户。
    """

    outcome: str  # plan | consent | rejected

    # outcome == "plan"
    tier: int | None = None
    file_id: int | None = None
    container: str | None = None
    video: VideoPlanView | None = None
    audio: AudioPlanView | None = None
    #: 这个文件里全部可选音轨（含当前这条）。前端据此渲染音轨菜单。
    audio_tracks: list[AudioTrackView] = []
    subtitles: list[SubtitlePlanView] = []
    degraded_from: int | None = None
    #: 光盘直推的形态（disc-direct-play.md）："image" = ISO 原字节（``stream_url`` 即原文件）、
    #: "folder" = 原盘目录按文件直推（``stream_url`` 是目录清单）；普通文件为 None
    disc: str | None = None
    #: 目录直推时服务端选中的主播放列表文件名（如 ``00800.mpls``），播放器按名字选主片
    disc_playlist: str | None = None

    # outcome == "consent"
    cost_hint: str | None = None
    can_self_enable: bool | None = None
    setting_namespace: str | None = None
    setting_key: str | None = None

    # 三态共有：中文，为什么是这个结果。诊断面板与失败提示共用同一份文案。
    reason: str = ""
    # outcome == "rejected"
    suggestion: str | None = None


class PlaybackSourceView(BaseModel):
    """源文件的客观规格（台账真值），诊断面板「源 → 处理」层次的左半边。

    Emby 式面板的关键是把「源是什么」与「我们对它做了什么」摆在一起——
    只报处理结果，用户看不出「1080p H264 明明能直通为什么在转码」这类问题。
    """

    container: str | None = None
    resolution: str | None = None
    video_codec: str | None = None
    hdr: str | None = None
    #: 总码率（bps）；探测不出为 None
    bit_rate: int | None = None
    frame_rate: float | None = None
    size_bytes: int | None = None


class PlaybackStateView(BaseModel):
    """一个播放单元在当前成员名下的观看状态。续播与上报共用同一形状。"""

    position_ms: int
    played: bool
    play_count: int
    #: 服务端算出的片长（在位文件实测 > 分集刮削 > 条目刮削）；都没有为 None。
    #: 客户端拿它画进度条兜底，但**已看判定的分母始终以服务端为准**。
    duration_ms: int | None = None
    audio_track: str | None = None
    subtitle_track: str | None = None
    #: 管理员已在活动页结束了这台浏览器的播放：播放器收到后退出，不再重开
    ended_by_admin: bool = False


class PlaybackArtifactUploadView(BaseModel):
    """远程 Worker 最近一次产物上传的脱敏记录。"""

    name: str
    status: int
    received_bytes: int
    content_length: int | None = None
    transfer_encoding: str | None = None
    occurred_at_ms: int


class PlaybackDiagnosticsView(BaseModel):
    """播放器诊断面板使用的会话快照，不包含任何签名 URL 或令牌。"""

    session_state: str
    session_error: str | None = None
    processing_mode: str
    execution_location: str
    backend: str | None = None
    encoder: str | None = None
    worker_id: str | None = None
    worker_version: str | None = None
    worker_platform: str | None = None
    worker_arch: str | None = None
    ffmpeg_version: str | None = None
    worker_online: bool | None = None
    worker_last_seen_seconds: float | None = None
    job_id: str | None = None
    attempt_id: str | None = None
    job_state: str | None = None
    job_out_time_ms: int | None = None
    job_speed: str | None = None
    job_phase: str | None = None
    job_exit_code: int | None = None
    job_error: str | None = None
    job_stderr_tail: str | None = None
    head_segment: int | None = None
    highest_produced_segment: int | None = None
    requested_segment: int | None = None
    served_segment: int | None = None
    segment_wait_ms: int | None = None
    segment_status: int | None = None
    pending_segments: list[int] = Field(default_factory=list)
    #: ``failed_segments`` 只列当前播放游标之后仍可能影响播放的缺口；旧轮次
    #: 的失败记录单独返回，避免播放器已经走过后仍显示成当前卡点。
    failed_segments: list[int] = Field(default_factory=list)
    historical_failed_segments: list[int] = Field(default_factory=list)
    recent_uploads: list[PlaybackArtifactUploadView] = Field(default_factory=list)
    cache_bytes: int = 0
    total_segments: int | None = None
    #: 转码头领先播放头的秒数（闭环供片节流的输入，§A）；非 VOD 会话为 None
    lead_seconds: float | None = None
    #: 当前挂起原因（"lead" 领先过多 / "disk" 磁盘低水位）；空 = 在跑
    pause_reasons: list[str] = Field(default_factory=list)
    #: 开会话时认领到了同指纹的转码缓存（§B），以及当时可用的分片数
    cache_hit: bool = False
    cached_segments: int = 0
    #: 服务端时间线（docs/design/transcode-latency.md §2）：每条 ``t`` 是距会话创建的毫秒数，
    #: ``ev`` 是事件名（dispatch / accepted / src / put / landed / req / served / restart …，
    #: Worker 报来的带 ``w_`` 前缀），其余是事件自己的字段。不含任何地址或令牌
    timeline: list[dict[str, Any]] = Field(default_factory=list)


class PlaybackChapterMarkView(BaseModel):
    """进度条上的章节刻度（docs/design/player-feel.md §2.C1）。

    只有起点与标题：预览图由 trickplay 雪碧图负责，章节图片再塞一份会把
    起播响应撑大好几倍，而进度条上根本画不下。
    """

    start_ms: int
    title: str | None = None


class PlaybackSegmentView(BaseModel):
    """可跳过的一段（docs/design/skip-intro.md）：服务端整季比对认出来的，客户端只管用。

    - ``intro`` 片头：在区间里显示「跳过片头」，点了跳到 ``end_ms``；
    - ``outro`` 片尾：到 ``start_ms`` 就提前显示「即将播放下一集」；``to_end`` 为假时
      片尾后面还有内容（下集预告、彩蛋），按钮是「跳过片尾」；
    - ``ad`` 已确认的广告、``preview`` 已确认的预告：分别显示「跳过广告」「跳过预告」，
      手动跳到段尾；
    - ``other`` 尚未明确分类的重复段：显示「跳过此段」，不猜测为广告或片头。
    """

    type: Literal["intro", "outro", "ad", "preview", "other"]
    start_ms: int
    end_ms: int
    #: 片尾一直放到文件结尾（只有 outro 有意义）
    to_end: bool = False


class PlaybackDiscFileView(BaseModel):
    """原盘目录里可直推的一个文件（disc-direct-play.md §2.3）。"""

    #: 相对原盘根目录的路径，保留盘上实际的大小写（如 ``BDMV/STREAM/00001.M2TS``）
    path: str
    size: int
    #: 按 Range 取这个文件的地址，已带签名 token
    url: str


class PlaybackDiscListingView(BaseModel):
    """原盘目录清单：自研引擎据此在本机解析播放列表、拼接剪辑，服务端只按文件供字节。"""

    files: list[PlaybackDiscFileView]
    #: 服务端选中的主播放列表文件名（诱饵判定与台账时长同一口径）；读不出时为 None
    playlist: str | None = None


class MatroskaCuesView(BaseModel):
    """MKV 精简索引（docs/design/playback-qoe.md §9.12）：只含视频轨索引点的 Cues 元素。

    App 的播放引擎在解复用器读 SeekHead 登记的 Cues 位置时直接给这份，不必再下载原索引
    （字幕轨多的片子原索引有几百 KB 到几 MB，外网慢时要单独下好几秒）。
    索引点的数值与原文件逐位一致。"""

    #: Cues 元素在文件里的绝对位置；引擎核对它与文件头里 SeekHead 登记的位置一致才用
    offset: int
    #: 精简后的整个 Cues 元素（含元素头），base64
    data: str
    #: 原 Cues 元素多少字节（诊断用）
    original_bytes: int


class PlaybackSessionView(BaseModel):
    """开会话的结果。

    三态里只有 ``plan`` 才会真的起会话；``consent`` / ``rejected`` 原样把
    决策带回前端，由它渲染弹窗或错误说明。
    """

    decision: PlaybackDecisionView
    #: 档 0 没有会话（原文件直出），此处为 None
    session_id: str | None = None
    #: 可直接喂给 <video src> 或 hls.js 的地址，已带签名 token。
    #: 决策不是 plan 时为 None。
    stream_url: str | None = None
    #: 会话时间轴的零点在文件里的位置。**文件时间 = start_ms + currentTime**——
    #: 全前端只有这一处换算（见 ffmpeg_args 模块文档的时间轴取舍）。
    #: timeline="file" 时它退化为「建议的起播位置」：分片时间戳本身就是
    #: 文件绝对时间，currentTime 即文件时间，前端应把播放器 seek 到这里。
    start_ms: int = 0
    #: 时间轴语义：session = 旧会话相对制（流从 0 起）；file = VOD 预生成
    #: 列表（§12），播放列表覆盖全片、时间戳为文件绝对时间，seek 任意位置
    #: 不需要换会话。
    timeline: str = "session"
    #: 旁挂字幕地址（已带 token），与 decision.subtitles 一一对应。
    subtitle_urls: list[str] = []
    #: master 播放列表（带 WEBVTT 字幕组），仅 VOD 会话有。iOS 原生 HLS 用
    #: 它——字幕成为系统级字幕轨，画中画/原生全屏里由系统渲染（§12）。
    master_url: str | None = None
    #: 本次会话实际使用的硬件加速后端（vaapi / qsv / nvenc / videotoolbox）；
    #: None = 纯软件。诊断面板要靠它回答「到底有没有走显卡」——用户报「转码
    #: 很卡」时，这一项与「有没有装对驱动」是同一个问题的两面（§6.5）。
    hw_backend: str | None = None
    #: 本单元的观看状态快照。续播点已按它并入 ``start_ms``，这里整份带回是
    #: 给前端**预填时间轴与恢复字幕记忆**用的——省掉起播链路里「先问 /resume
    #: 再开会话」的一次串行往返（§6.10）。file_id 直连（无播放单元）时为 None。
    watch: PlaybackStateView | None = None
    #: 选中文件的源规格（台账真值）。诊断面板按 Emby 的「源 → 处理」层次
    #: 展示：MKV 24 Mbps → HLS、1080p H264 → 直通……（§6.5）
    source: PlaybackSourceView | None = None
    #: 进度条上的章节刻度。**合成章节（等距切分）不下发**——那是详情页凑
    #: 场景图用的，画到进度条上就是一排没有信息量的竖条。没有内嵌章节的
    #: 文件这里是空表，进度条照旧干净。
    chapters: list[PlaybackChapterMarkView] = Field(default_factory=list)
    #: 片头 / 片尾 / 其他可跳过的段（剧集库开了「识别片头片尾」且这一季识别过才有）。
    #: 新服务端恒为数组（没有就是空表，不会是 null）；声明成可空只为让 App 的生成模型
    #: 对旧服务端宽容——旧服务端没有这个字段，非可选的字段缺失会让新 App 的整个会话解码失败、
    #: 连带起不了播
    segments: list[PlaybackSegmentView] | None = Field(default_factory=list)
    #: 档 0 直出的 MKV：服务端缓存里有精简索引时随会话下发（没有就在后台生成，给下次用）
    matroska_cues: MatroskaCuesView | None = None


class PlaybackSessionRequest(PlaybackDecideRequest):
    """开会话请求：在决策请求上多一个起播位置。"""

    #: 从文件的哪个位置开始。**None = 服务端按观看状态定**：看完的从头播，
    #: 没看完的接续播点——分享出去的链接因此天然「各看各的进度」。显式给值
    #: （含 0）原样照办：seek 重开、「从头开始」都走这条路。
    start_ms: int | None = None
    #: 播放编号（docs/design/playback-qoe.md §2）：App 在用户点下时生成，断线重连、原位重开、
    #: 降级、换画质都沿用同一个。服务端据此建「已开始」的记录，并写进取流令牌
    attempt_id: str | None = Field(default=None, max_length=64)
    #: 客户端类型（ios / web），只用于播放记录分组
    client: str | None = Field(default=None, max_length=16)


class PlaybackItemView(BaseModel):
    """播放页要的条目信息，只有播放器用得上的那几样。

    播放路由只带 ``media_item_id``——它以 ``(kind, tmdb_id)`` 为锚、幂等复用，
    比库自增 id 稳定得多，分享出去的地址不会因删库重建而失效（§6.10）。库归
    属由服务端按成员可见性解析，前端只在「退出播放跳回条目页」时用到它。
    """

    media_item_id: int
    library_id: int
    #: movie / tv
    kind: str
    title: str
    year: int | None = None
    #: 海报（本地刮削资产优先、TMDB 兜底），起播前的占位画面用
    poster_url: str | None = None


# ---------------------------------------------------------------------------
# 网页播放器：观看状态（续播点、已看、轨记忆）
# ---------------------------------------------------------------------------


class PlaybackProgressRequest(BaseModel):
    """一次观看状态上报。三种事件同一入口，与 Jellyfin 的 Playing /
    Playing/Progress / Playing/Stopped 一一对应。"""

    media_item_id: int
    #: 电影恒为 (0, 0) 的哨兵单元，与台账、playback_state 的约定一致
    season_number: int = 0
    episode_number: int = 0
    event: str = "progress"  # start | progress | stop
    #: 播到文件的哪个位置。**None = 没报**（视同播到结尾标已看），与报 0
    #: （拖回开头）语义不同——别把「不知道」和「零」合并。
    position_ms: int | None = None
    #: 中性轨引用（external:<文件名> / embedded:<下标> / 字幕的 "off"）。
    #: None = 本次不报该轨，服务端保持原值不动。只报**用户亲手选的**轨：
    #: 服务端只把和默认挑选不同的当作用户的选择记下（见 apply_track_selection）。
    audio_track: str | None = None
    subtitle_track: str | None = None
    #: 正在放的版本（会话决策的 decision.file_id）。多版本时据此判断上报的轨是不是
    #: 这个版本的默认挑选；不给则按这一集的全部在位文件判断。
    file_id: int | None = None
    #: 浏览器的稳定标识（前端生成、存 localStorage），语义对齐 Jellyfin 客户端
    #: 的 DeviceId：活动页「正在播放」按它区分同一成员的不同浏览器。
    device_id: str | None = Field(default=None, max_length=128)
    #: 暂停态；None = 本次没报（实时会话保持原值）
    paused: bool | None = None


# PlaybackStateView 定义在会话模型之前（PlaybackSessionView.watch 引用它）。


# ---------------------------------------------------------------------------
# 网页端：已看 / 收藏标记（与 Jellyfin 的 UserPlayedItems / UserFavoriteItems 同一落点）
# ---------------------------------------------------------------------------


class PlaybackMarksRequest(BaseModel):
    """一次标记：目标 + 要改成什么。

    目标的表达与 Jellyfin 的 Series / Season / Episode 三级一一对应：不带季集
    = 整个条目（电影，或整剧级联到全部集）；只带季 = 整季；季集都带 = 单集。
    电影也可以像播放接口那样带哨兵 ``(0, 0)``，落到同一个单元。
    ``played`` 与 ``favorite`` 至少给一个，没给的那个保持原值。
    """

    media_item_id: int
    season_number: int | None = Field(default=None, ge=0)
    episode_number: int | None = Field(default=None, ge=0)
    played: bool | None = None
    favorite: bool | None = None
    #: 浏览器的稳定标识（同进度上报），webhook 事件的 client 字段据此归因
    device_id: str | None = Field(default=None, max_length=128)


class PlaybackMarksView(BaseModel):
    """目标在当前成员名下的已看 / 收藏状态。读接口与写接口同一形状，
    写完直接拿它刷新按钮，不必再查一次。"""

    played: bool
    is_favorite: bool
    #: 整剧 / 整季尚未看完的集数；电影与单集为 null
    unplayed_count: int | None = None


# ---------------------------------------------------------------------------
# 网页播放器：策略配置（软件转码同意链路 §3.6；独立设置页已撤，上限自动推导）
# ---------------------------------------------------------------------------


class PlaybackPolicyView(BaseModel):
    """播放策略的当前取值。字段与 PlaybackPolicySetting 一一对应。

    数字上限（并发、输出高度、缓存配额）不在这里——它们已改为按机器规格
    自动推导（services/playback/limits.py），不再是配置项。
    """

    software_transcode_enabled: bool
    #: 进度条预览缩略图的生成开关（设置页「播放」分区）。已生成的预览不受它
    #: 影响——关掉只是不再生成新的。
    trickplay_enabled: bool = True
    #: 转码产物是否保留供续播、重看复用（§B）。关闭即会话结束即删。
    transcode_cache_enabled: bool = True
    #: 实测结果而非配置项——用户改不了自己有没有显卡。前端据此说明
    #: 「无可用硬件加速，HDR 片源需要软件转码」这类结论。
    hardware_available: bool = False
    #: 探测到的硬件后端名（vaapi / qsv / nvenc / videotoolbox），无则为空
    hw_backends: list[str] = []


class PlaybackPolicyPayload(BaseModel):
    """策略保存请求。**全字段可选，None = 不动这一项**——同意弹窗只翻
    software_transcode_enabled 一个开关。"""

    software_transcode_enabled: bool | None = None
    trickplay_enabled: bool | None = None
    transcode_cache_enabled: bool | None = None


class PlaybackFontsView(BaseModel):
    """ASS 字幕依赖的内嵌字体地址（已带签名 token）。"""

    fonts: list[str] = []


class HwBackendStatusView(BaseModel):
    """一个硬件加速后端的自检结论。``detail`` 是给用户看的中文原因与修法。"""

    name: str
    label: str
    available: bool
    detail: str


class HwProbeView(BaseModel):
    """硬件加速自检结果。

    `available` 为空即「只能软件转码」——用户据此决定是去挂设备，还是接受
    软件转码的代价。
    """

    backends: list[HwBackendStatusView] = []
    hardware_available: bool = False


class TrickplayView(BaseModel):
    """进度条缩略图索引。

    `ready=false` 表示还在生成（或这部片生成不了）——前端表现为「暂无预览」，
    不影响播放。前端据 `interval_ms` 与格子尺寸算「第 t 秒在哪张图的哪一格」。
    """

    ready: bool = False
    interval_ms: int = 0
    tile_width: int = 0
    tile_height: int = 0
    columns: int = 0
    #: 每张雪碧图的行数。必须下发——少了它前端只能反推每张图的容量，
    #: 而最后一张通常没填满，反推必错。
    rows: int = 0
    count: int = 0
    sheets: list[str] = []


class PlaybackClientLogPayload(BaseModel):
    """播放器客户端事件上报：把浏览器侧的现场（MediaError 详情、播放器状态）
    落进服务端日志。iPhone 上的播放故障没有任何本地可看的控制台，服务端
    日志是唯一能拿到客户端真相的地方。"""

    event: str
    detail: dict = {}


class PlaybackMetricPayload(BaseModel):
    """一次播放结束时上报的记录。指标口径按 CTA-2066，不自创。

    带 ``attempt_id`` 的是 docs/design/playback-qoe.md 口径的收尾上报：按编号合并进服务端在
    会话接口建好的那一行，**所有结局都报**（看完、中途退出、出画前退出、失败、异常退出）。
    不带编号的是网页播放器的旧口径整行快照，原样落库。

    数值超出上下界会被夹住、列表与明细超限会被截断（记一行警告），不拒收。
    """

    library_file_id: int | None = None
    #: 最终档位；还没定档就结束记 -1
    tier: int
    degraded_from: int | None = None
    engine: str = ""
    hw_backend: str = ""
    #: 旧口径：点击播放 → 首帧（网页）。新口径看 ``first_frame_ms``
    ttff_ms: int | None = None
    rebuffer_ms: int = 0
    rebuffer_count: int = 0
    seek_count: int = 0
    dropped_frames: int | None = None
    total_frames: int | None = None
    watched_ms: int = 0

    # —— playback-qoe.md 口径 ——
    attempt_id: str | None = Field(default=None, max_length=64)
    #: watched / exited / exit_before_start / failed / abnormal_exit
    outcome: str = ""
    media_item_id: int | None = None
    season_number: int | None = None
    episode_number: int | None = None
    #: tap / auto_next / deeplink
    origin: str = ""
    #: ios / web
    client: str = ""
    #: 实验室场景名（启动参数 -mcLab）；空 = 真实使用
    lab_scenario: str = ""
    #: loopback / software / remote_bypass / server_transcode
    route: str = ""
    #: home / away / unknown
    network_class: str = ""
    #: wifi / cellular / wired / other
    interface: str = ""
    app_version: str = ""
    #: 点下 → 首帧出画 / 开始走（毫秒，已扣除 user_wait_ms）
    first_frame_ms: int | None = None
    playing_ms: int | None = None
    user_wait_ms: int = 0
    #: 最后一次错误：引擎错误类型原值、归类（network / source_missing / storage_full /
    #: decode）、阶段
    error_kind: str = ""
    error_category: str = ""
    error_stage: str = ""
    #: 逐条明细：startup / seeks / switches / interruptions / delivery / behaviors / context /
    #: resources / timeline（字段见 playback-qoe.md §3）
    detail: dict = {}
    #: 失败、异常退出或冻帧时附带的引擎日志尾巴（≤ 32 KB）
    log_tail: str = ""


class PlaybackStatsView(BaseModel):
    """播放质量汇总。样本不足时各项为 null——不编数字。

    `direct_ratio` 是**北极星指标**：档 0 + 档 1 占全部播放的比例。这一个数
    同时代表画质（没重编码）、速度（秒开）和服务器负担（不烧 GPU）。
    """

    sessions: int = 0
    direct_ratio: float | None = None
    degraded_ratio: float | None = None
    ttff_p50_ms: int | None = None
    ttff_p95_ms: int | None = None
    rebuffer_ratio: float | None = None
    dropped_ratio: float | None = None
    tier_counts: dict[int, int] = {}


class QoePercentilesView(BaseModel):
    """一组毫秒数的分位（最近秩法）。"""

    p50: int | None = None
    p90: int | None = None
    p99: int | None = None
    count: int = 0


class QoeAttemptBriefView(BaseModel):
    """一次播放的摘要（统计里的「最差 N 条」与小样本明细）。"""

    attempt_id: str | None = None
    created_at: str | None = None
    status: str | None = None
    outcome: str | None = None
    client: str | None = None
    media_item_id: int | None = None
    season_number: int | None = None
    episode_number: int | None = None
    library_file_id: int | None = None
    tier: int | None = None
    source_class: str | None = None
    route: str | None = None
    network_class: str | None = None
    first_frame_ms: int | None = None
    seek_max_ms: int | None = None
    interrupt_count: int | None = None
    error_kind: str | None = None
    avoidable_loss: bool | None = None
    misguess_count: int | None = None
    undisturbed: bool | None = None


class QoeGroupStatsView(BaseModel):
    """一组播放的体验统计。样本少于 30 条时各项为 null，改列 ``samples`` 明细——不编数字。"""

    attempts: int = 0
    reported: int = 0
    unreported: int = 0
    in_progress: int = 0
    small_sample: bool = False
    #: 北极星：无打扰播放率（只算已收尾且判定过的）
    undisturbed_rate: float | None = None
    first_frame_ms: QoePercentilesView | None = None
    seek_in_buffer_ms: QoePercentilesView | None = None
    seek_out_buffer_ms: QoePercentilesView | None = None
    interrupts_per_hour: float | None = None
    failure_rate: float | None = None
    exit_before_start_rate: float | None = None
    abnormal_exit_rate: float | None = None
    avoidable_loss_rate: float | None = None
    misguess_rate: float | None = None
    samples: list[QoeAttemptBriefView] | None = None


class QoeGroupView(QoeGroupStatsView):
    key: str
    label: str


class QoeReasonView(BaseModel):
    """打扰原因的帕累托：一种原因打扰了多少次播放。"""

    reason: str
    label: str
    count: int


class PlaybackQoeStatsView(BaseModel):
    """播放体验统计（docs/design/playback-qoe.md §5.5）：北极星、快 / 稳 / 对、打扰原因、
    最差的播放。"""

    days: int
    since: str
    include_lab: bool
    group_by: str | None = None
    overall: QoeGroupStatsView
    groups: list[QoeGroupView] = []
    reasons: list[QoeReasonView] = []
    worst: list[QoeAttemptBriefView] = []


class PlaybackAttemptView(BaseModel):
    """一次播放的完整记录与时间线（docs/design/playback-qoe.md §5.5）。"""

    attempt_id: str
    status: str
    outcome: str
    client: str
    origin: str
    lab_scenario: str
    member_id: int
    media_item_id: int | None = None
    season_number: int | None = None
    episode_number: int | None = None
    library_file_id: int | None = None
    tier: int
    degraded_from: int | None = None
    engine: str
    route: str
    source_class: str
    network_class: str
    interface: str
    app_version: str
    first_frame_ms: int | None = None
    playing_ms: int | None = None
    user_wait_ms: int
    seek_in_count: int
    seek_in_p90_ms: int | None = None
    seek_in_max_ms: int | None = None
    seek_out_count: int
    seek_out_p90_ms: int | None = None
    seek_out_max_ms: int | None = None
    rebuffer_count: int
    rebuffer_ms: int
    freeze_count: int
    freeze_ms: int
    reconnect_count: int
    reconnect_ms: int
    interrupt_count: int
    error_kind: str
    error_category: str
    error_stage: str
    avoidable_loss: bool | None = None
    misguess_count: int
    undisturbed: bool | None = None
    watched_ms: int
    created_at: str
    ended_at: str | None = None
    detail: dict = {}
    log_tail: str = ""
