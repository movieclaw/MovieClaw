"""媒体库能力档案：形态 × 来源 → 一份不可变的能力声明（docs/design/library-other-kind.md 3.1）。

一个库由两个坐标定位：**形态**（``MediaKind``：movie / tv / video，描述结构）
与**身份来源**（``MediaSource``：tmdb / local，描述谁负责识别与刮削）。
两者的组合决定这个库怎么扫、怎么摆、怎么播、对外报什么类型。

为什么不按形态一个维度分叉：``video`` 单独看显得宽泛，是因为它本来就只是
半个坐标——"成人（番号）"在结构上是 ``movie`` 形态、只是来源不是 TMDB；
"动漫"是 ``tv`` 形态 + TMDB 来源、库名叫动漫。把来源做成维度之后，
将来接新来源（番号、豆瓣独有条目、Bangumi）就是本表加一行 + 一个识别策略
+ 一个刮削器，四条消费链（扫描、展示、播放、Jellyfin）不用再碰。

**所有消费方读能力位，不按枚举值分叉**：新增 ``kind == "movie"`` 这类字面
比较在评审里应被拒绝——每多一处就是将来每加一个类型要多改的一处。
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING

from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.i18n.stored import reference, render_value, source_render
from movieclaw_api.services.library.layout import IMAGE_EXTS, SCAN_VIDEO_EXTS
from movieclaw_db.models.media_item import MediaSource
from movieclaw_media.models import MediaKind

if TYPE_CHECKING:
    from movieclaw_db.models.library import Library


class IgnoreProfile(StrEnum):
    """扫描遍历的忽略口径。

    - ``SCRAPED``：影视库的全套规则——花絮/预告子目录、``-trailer`` 后缀、
      「花絮/预告片」关键词、``sample`` 子串。花絮不是独立作品，拿它们的
      文件名去 TMDB 搜必然搜出别的影片；
    - ``PLAIN``：本地内容库的口径——只挡隐藏目录、系统目录与主干精确等于
      ``sample`` 的文件。``婚礼花絮.mp4``、``clips/`` 正是家庭视频的常态，
      子串规则用在这里必伤（与 Jellyfin homevideos 库的匹配语义一致：
      精确/后缀，没有子串）。
    """

    SCRAPED = "scraped"
    PLAIN = "plain"


@dataclass(frozen=True)
class LibraryProfile:
    """一种库类型（形态 × 来源）的全部能力声明。"""

    kind: MediaKind
    source: str
    scraped: bool  # 身份来自远程数据源：走识别链、刮削、写 NFO、定时刷新
    naming: bool  # 可按命名模板整理目录与文件名
    ignore_rules: IgnoreProfile
    write_nfo: bool
    subscribable: bool  # 可作为订阅/自动路由的目标库
    jellyfin_type: str  # 条目对外报的 Jellyfin 类型：Movie / Series / Video
    jellyfin_collection: str  # 库视图的 CollectionType：movies / tvshows / homevideos / photos
    default_aspect: float  # 无主图时卡片的兜底长宽比（有主图按真实尺寸）
    # 入账对象的扩展名集合：扫描遍历与实时监听都按它过滤（影视库目录里的
    # jpg 是海报 sidecar 不是内容；图片库目录里的 mp4 同样不是）
    media_exts: frozenset[str]
    # 条目可播放：假 = 只可看（图片）。前端卡片点击/播放路由、Jellyfin 的
    # 可播放类型都读它，没有它就得回到 ``kind == "photo"`` 的字面比较
    playable: bool
    # 是否对 Jellyfin 兼容层暴露库视图与最新媒体：Infuse 不支持照片库，
    # 图片库一期不暴露（docs/design/library-photo-kind.md 2.10）
    jellyfin_exposed: bool

    @property
    def episodic(self) -> bool:
        """是否季集结构——这是形态的固有属性，不随来源变。"""
        return self.kind is MediaKind.TV

    @property
    def key(self) -> tuple[str, str]:
        return self.kind.value, self.source


_POSTER = 2 / 3
_THUMB = 16 / 9
_PHOTO = 4 / 3
_VIDEO_EXTS = frozenset(SCAN_VIDEO_EXTS)
_IMAGE_EXTS = frozenset(IMAGE_EXTS)

PROFILES: dict[tuple[str, str], LibraryProfile] = {
    (MediaKind.MOVIE.value, MediaSource.TMDB): LibraryProfile(
        kind=MediaKind.MOVIE,
        source=MediaSource.TMDB,
        scraped=True,
        naming=True,
        ignore_rules=IgnoreProfile.SCRAPED,
        write_nfo=True,
        subscribable=True,
        media_exts=_VIDEO_EXTS,
        playable=True,
        jellyfin_exposed=True,
        jellyfin_type="Movie",
        jellyfin_collection="movies",
        default_aspect=_POSTER,
    ),
    (MediaKind.TV.value, MediaSource.TMDB): LibraryProfile(
        kind=MediaKind.TV,
        source=MediaSource.TMDB,
        scraped=True,
        naming=True,
        ignore_rules=IgnoreProfile.SCRAPED,
        write_nfo=True,
        subscribable=True,
        media_exts=_VIDEO_EXTS,
        playable=True,
        jellyfin_exposed=True,
        jellyfin_type="Series",
        jellyfin_collection="tvshows",
        default_aspect=_POSTER,
    ),
    (MediaKind.VIDEO.value, MediaSource.LOCAL): LibraryProfile(
        kind=MediaKind.VIDEO,
        source=MediaSource.LOCAL,
        scraped=False,
        naming=False,
        ignore_rules=IgnoreProfile.PLAIN,
        write_nfo=False,
        subscribable=False,
        jellyfin_type="Video",
        jellyfin_collection="homevideos",
        default_aspect=_THUMB,
        media_exts=_VIDEO_EXTS,
        playable=True,
        jellyfin_exposed=True,
    ),
    (MediaKind.PHOTO.value, MediaSource.LOCAL): LibraryProfile(
        kind=MediaKind.PHOTO,
        source=MediaSource.LOCAL,
        scraped=False,
        naming=False,
        ignore_rules=IgnoreProfile.PLAIN,
        write_nfo=False,
        subscribable=False,
        jellyfin_type="Photo",
        jellyfin_collection="photos",
        default_aspect=_PHOTO,
        media_exts=_IMAGE_EXTS,
        playable=False,
        jellyfin_exposed=False,
    ),
}

def kind_reference(kind: MediaKind | str) -> dict:
    return reference(
        {
            MediaKind.MOVIE: "media.kind.movie",
            MediaKind.TV: "media.kind.tv",
            MediaKind.VIDEO: "library.kind.video",
            MediaKind.PHOTO: "library.kind.photo",
        }[MediaKind(kind)]
    )


# 形态的中文名（日志、落库文案的回滚值共用；给人看的地方用 kind_reference）
KIND_LABELS: dict[MediaKind, str] = {
    kind: source_render(kind_reference(kind)) for kind in MediaKind
}


def kind_label(kind: MediaKind | str) -> str:
    value = kind if isinstance(kind, MediaKind) else MediaKind(kind)
    return KIND_LABELS[value]


def default_source_for(kind: MediaKind | str) -> str:
    """某形态建库时的默认身份来源：影视走 TMDB，其他走本地。"""
    value = kind.value if isinstance(kind, MediaKind) else kind
    for (k, source), _profile in PROFILES.items():
        if k == value:
            return source
    raise BadRequestException(message_key="errors.library.kindUnsupported", params={"kind": value})


def profile_for(kind: MediaKind | str, source: str | None = None) -> LibraryProfile:
    """按 (形态, 来源) 取能力档案；来源缺省取该形态的默认来源。

    组合不存在时抛中文 400——这是创建库时唯一会碰到它的地方；存量库的
    组合都是本表里的行。
    """
    value = kind.value if isinstance(kind, MediaKind) else kind
    resolved_source = source or default_source_for(value)
    profile = profile_for_key(value, resolved_source)
    if profile is None:
        raise BadRequestException(
            message_key="errors.library.kindSourceUnsupported",
            params={"kind": value, "source": resolved_source},
        )
    return profile


def profile_for_key(kind: str, source: str) -> LibraryProfile | None:
    """内置档案表查不到时回落外部库源注册表（source_providers）。

    插件登记的来源自带完整能力档案，四条消费链（扫描/展示/播放/Jellyfin）
    都经 profile_for 走到这里——主线消费代码不因新来源多一行。组合两边
    都没有时返回 None，由调用方决定报错方式。
    """
    profile = PROFILES.get((kind, source))
    if profile is not None:
        return profile
    from movieclaw_api.services.library.source_providers import provider_of

    provider = provider_of(source)
    if provider is not None:
        return provider.profiles.get(kind)
    return None


def _orphan_external_profile(kind: MediaKind) -> LibraryProfile:
    """外部库源插件停用/卸载期间的兜底档案（docs：source_providers 模块注）。

    来源登记没了，库和它的台账还在：浏览与编辑不能整个 400。能力位收敛到
    最小可用的保守集——不刮削、不命名、不可订阅、不对 Jellyfin 暴露；插件
    重新启用后 profile_for 直接命中登记档案，本表不再被走到。
    """
    return LibraryProfile(
        kind=kind,
        source="",  # 由 profile_of 填实际来源；档案本身不参与登记校验
        scraped=False,
        naming=False,
        ignore_rules=IgnoreProfile.PLAIN,
        write_nfo=False,
        subscribable=False,
        jellyfin_type={"movie": "Movie", "tv": "Series", "video": "Video", "photo": "Photo"}[
            kind.value
        ],
        jellyfin_collection="homevideos" if kind.value != "photo" else "photos",
        default_aspect=_POSTER if kind is MediaKind.MOVIE else _THUMB,
        media_exts=_VIDEO_EXTS if kind is not MediaKind.PHOTO else _IMAGE_EXTS,
        playable=kind is not MediaKind.PHOTO,
        jellyfin_exposed=False,
    )


def profile_of_values(kind: str, source: str | None) -> LibraryProfile:
    """(形态, 来源) 二元组 → 能力档案：存量库的统一入口，登记缺失回落孤儿档案。

    与 ``profile_of`` 的差别只在入参形态——不需要库行、只有二元组的地方
    （抽样器的可见库投影、Jellyfin 的可见集收窄）走这里，孤儿回落语义
    完全一致：插件停用/卸载不该让任何读这条链的接口整体 400。
    """
    try:
        return profile_for(kind, source)
    except BadRequestException:
        from movieclaw_api.services.library.source_providers import is_external_source

        if is_external_source(source):
            profile = _orphan_external_profile(MediaKind(kind))
            object.__setattr__(profile, "source", source or "")
            return profile
        raise


def profile_of(library: Library) -> LibraryProfile:
    """库行 → 能力档案（存量库的 source 已由迁移回填为 tmdb）。

    外部库源在登记缺失（插件停用/卸载）时回落孤儿档案而不是 400：插件
    不可用不该让存量库的浏览、编辑与后台任务（实时监控、统计）跟着挂。
    """
    return profile_of_values(str(library.kind), library.source)


def capabilities_of(profile: LibraryProfile) -> dict:
    """导出给接口的能力位（前端按它分叉，不认字符串）。"""
    return {
        "scraped": profile.scraped,
        "episodic": profile.episodic,
        "naming": profile.naming,
        "subscribable": profile.subscribable,
        "write_nfo": profile.write_nfo,
        "default_aspect": round(profile.default_aspect, 4),
        "jellyfin_collection": profile.jellyfin_collection,
        "playable": profile.playable,
    }


def jellyfin_hidden_kinds() -> set[str]:
    """不对 Jellyfin 兼容层暴露的形态集合（库视图 / 最新媒体查询用 ``kind NOT IN``）。

    按能力位聚合而不是写死 ``"photo"``：将来某个形态改为暴露只改档案表。
    """
    return {kind for (kind, _source), profile in PROFILES.items() if not profile.jellyfin_exposed}


def library_kind_options() -> list[dict]:
    """创建库弹窗的类型选项：形态 × 来源各一项。"""
    return [
        {
            "kind": profile.kind.value,
            "source": profile.source,
            "label": render_value(kind_reference(profile.kind)),
            "capabilities": capabilities_of(profile),
        }
        for profile in PROFILES.values()
    ]
