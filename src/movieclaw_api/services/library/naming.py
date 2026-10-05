"""命名模板渲染器：入库/整理/投递的目录与文件名唯一来源。

docs/design/scrape-customization.md §2.3。本模块存在的理由是**命名同源**：
``标题 (年份)`` 这一套规范名此前散落在四处各自拼字符串——

- ``config.derive_save_path``（投递给下载器的 save_path）
- ``config.derive_entry_dir``（监听导入的自定义目录落点）
- ``ingest``（下载完成后的入库落名）
- ``organize``（存量整理的目标路径）

模板化之后它们**必须**全部改读本模块：任何一处继续拼字符串，用户改了模板
就会出现"投递落 A 名、整理算 B 名"，strm 回流链路（docs/design/strm-workflow.md）
当场断裂——那条链路的全部衔接机制就是两端算出同一个名字。

模板语法刻意受控（否决自由模板引擎，见设计文档 §5）：只有花括号占位符与
字面文本，数字占位符支持 ``:02d`` 补零，没有条件与过滤器语法。字段缺失时
由 ``_collapse`` 统一收缩（空括号、重复分隔符、首尾分隔符），规则确定性、
有单测，不需要用户在模板里写条件。

层级结构固定为 ``条目目录[/季目录]/文件名``，模板只描述**一段**名字：
识别链的 ``entry_dirs``、条目删除、NFO 落点都依赖这个结构假设，开放层级
自定义会让它们全部失去判据。
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from movieclaw_api.services.library.config import sanitize_folder_name

# 占位符：``{name}`` 或 ``{name:02d}``（补零仅对纯数字值生效）
_TOKEN = re.compile(r"\{(\w+)(?::0(\d)d)?\}")

# 可用占位符按可解析的上下文分组——在拿不到值的模板里放占位符只会渲染成空，
# 与其让用户事后发现名字少了一截，不如保存时就报错。
# 条目目录只能用条目身份字段：投递时就要算出 save_path，那时文件还不存在
_COMMON = frozenset(
    {"title", "original_title", "english_title", "year", "tmdb_id", "imdb_id", "douban_id"}
)
# 文件属性：入库侧来自探测/来源戳，整理侧来自台账行，两侧都经 file_attrs 格式化
_FILE_ATTRS = frozenset(
    {
        "resolution",
        "media_source",
        "release_group",
        "video_codec",
        "hdr",
        "bit_depth",
        "audio",
        "site",
        "release_name",
    }
)

ALLOWED_TOKENS: dict[str, frozenset[str]] = {
    "entry_dir": _COMMON,
    "movie_file": _COMMON | _FILE_ATTRS,
    "season_dir": _COMMON | frozenset({"season", "season_name"}),
    "episode_file": _COMMON
    | _FILE_ATTRS
    | frozenset({"season", "season_name", "episode", "episode_title"}),
}

# 片名类占位符：同一个模板里值相同的只保留第一次出现（见 _dedupe_titles）
_TITLE_TOKENS = ("title", "original_title", "english_title")
# 超长时可截短的自由文本占位符（编号、年份、规格截了会撞名或失真，不截）
_SHRINKABLE = (*_TITLE_TOKENS, "episode_title", "season_name", "release_name")
# 单段名字的字节上限。ext4/NTFS/APFS 单段上限 255 字节，留出扩展名、
# 多版本「 - 标签」后缀与字幕/剧照等附属文件后缀（.zh-Hans.forced.ass）的余量
MAX_SEGMENT_BYTES = 200
# 自由文本最多截到这么长（约 10 个汉字）：片名截没了不同影片会撞名
_SHRINK_FLOOR_BYTES = 30

# 模板字段的中文名（错误文案用，面向非开发者）
FIELD_LABELS = {
    "entry_dir": "条目目录",
    "movie_file": "电影文件名",
    "season_dir": "季目录",
    "episode_file": "剧集文件名",
}


@dataclass(frozen=True)
class NamingTemplates:
    """四个模板。默认值**逐字节等于**模板化之前的写死行为。"""

    entry_dir: str = "{title} ({year})"
    movie_file: str = "{title} ({year})"
    season_dir: str = "Season {season:02d}"
    episode_file: str = "{title} ({year}) - S{season:02d}E{episode:02d}"


DEFAULT_TEMPLATES = NamingTemplates()


# ---------------------------------------------------------------------------
# 渲染
# ---------------------------------------------------------------------------


# 一组括号（不嵌套）：占位符全空时整组丢弃，见 _drop_empty_groups
_BRACKET_GROUP = re.compile(r"[(\[【][^()\[\]【】]*[)\]】]")


def _token_value(context: Mapping[str, Any], name: str, pad: str | None) -> str:
    """占位符取值：缺失/空返回空串；值逐个过 sanitize（标题里的 ``/``
    不能凭空造出一层目录）；补零仅对纯数字生效。"""
    value = context.get(name)
    if value is None or value == "":
        return ""
    text = sanitize_folder_name(str(value))
    if pad and text.isdigit():
        text = text.zfill(int(pad))
    return text


def _drop_empty_groups(template: str, context: Mapping[str, Any]) -> str:
    """整组丢弃"占位符全空"的括号组——**含组内字面文本**。

    纯正则收尾只能删掉 ``()`` 这种空括号，删不掉 ``[tmdbid-]``：组里那截
    ``tmdbid-`` 是字面文本，占位符没值时它就成了残缺垃圾。而
    ``{title} ({year}) [tmdbid-{tmdb_id}]`` 正是 Emby/Jellyfin 最经典的
    目录写法，必须收干净。组内没有占位符的纯字面括号原样保留。
    """

    def _repl(match: re.Match[str]) -> str:
        group = match.group(0)
        tokens = _TOKEN.findall(group)
        if not tokens:
            return group
        if all(not _token_value(context, name, pad) for name, pad in tokens):
            return ""
        return group

    return _BRACKET_GROUP.sub(_repl, template)


def _collapse(text: str) -> str:
    """收尾收缩：括号内侧、重复分隔符、多余空白、首尾分隔符（幂等）。

    括号内侧单独收一道：``[{resolution} {release_group}]`` 只有分辨率有值时
    会剩下 ``[2160p ]``——整串 strip 够不着括号里面那个空格。
    """
    text = re.sub(r"([(\[【])[\s\-–]+", r"\1", text)
    text = re.sub(r"[\s\-–]+([)\]】])", r"\1", text)
    text = re.sub(r"(?:\s*-\s*){2,}", " - ", text)
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip(" -–.")


def _dedupe_titles(template: str, context: Mapping[str, Any]) -> dict[str, Any]:
    """片名类占位符去重：值与模板里更早出现的片名相同时渲染为空。

    国产片的 title 与 original_title 是同一个值，``{title} ({original_title})``
    不去重就是「风筝 (风筝)」。置空后括号组随之整组丢弃，模板里不需要条件语法。
    """
    ctx = dict(context)
    seen: set[str] = set()
    for name, pad in _TOKEN.findall(template):
        if name not in _TITLE_TOKENS:
            continue
        value = _token_value(ctx, name, pad).casefold()
        if not value:
            continue
        if value in seen:
            ctx[name] = None
        seen.add(value)
    return ctx


def _render_once(template: str, context: Mapping[str, Any]) -> str:
    text = _drop_empty_groups(template, context)
    text = _TOKEN.sub(lambda m: _token_value(context, m.group(1), m.group(2)), text)
    return sanitize_folder_name(_collapse(text))


def _cut_bytes(text: str, limit: int) -> str:
    """按 UTF-8 字节截断，不切坏多字节字符。"""
    return text.encode()[: max(limit, 0)].decode(errors="ignore")


def render(template: str, context: Mapping[str, Any]) -> str:
    """按上下文渲染一段名字（**只是一段**，不含路径分隔符）。

    三步：先整组丢弃占位符全空的括号组，再替换占位符，最后收缩并整体
    过一次 ``sanitize_folder_name``（兜住模板字面文本里的保留字符）。

    超过 ``MAX_SEGMENT_BYTES`` 时逐个截短最长的自由文本占位符（片名、集名、
    原始发布名），季集号、年份、规格保持完整——截掉 ``S01E03`` 会让多集撞名。
    截短只依赖上下文，入库与整理算出的仍是同一个名字。
    """
    ctx = _dedupe_titles(template, context)
    text = _render_once(template, ctx)
    for _ in range(len(_SHRINKABLE) * 2):
        over = len(text.encode()) - MAX_SEGMENT_BYTES
        if over <= 0:
            return text
        sizes = {n: len(_token_value(ctx, n, None).encode()) for n in _SHRINKABLE}
        name = max(sizes, key=lambda n: sizes[n])
        if sizes[name] <= _SHRINK_FLOOR_BYTES:
            break
        keep = max(sizes[name] - over, _SHRINK_FLOOR_BYTES)
        ctx[name] = _cut_bytes(_token_value(ctx, name, None), keep).strip(" .-")
        text = _render_once(template, ctx)
    # 没有可截的自由文本（模板字面文本本身就超长）或截不动：整体硬截兜底
    return sanitize_folder_name(_cut_bytes(text, MAX_SEGMENT_BYTES))


# ---------------------------------------------------------------------------
# 校验（保存时前置报错，中文文案）
# ---------------------------------------------------------------------------


def validate_template(field: str, template: str) -> str | None:
    """校验单个模板；通过返回 None，否则返回面向用户的中文错误。"""
    label = FIELD_LABELS.get(field, field)
    if not template.strip():
        return f"{label}模板不能为空"
    if "/" in template or "\\" in template:
        return f"{label}模板不能包含路径分隔符（目录层级是固定的，模板只描述一段名字）"

    allowed = ALLOWED_TOKENS[field]
    used = {m.group(1) for m in _TOKEN.finditer(template)}
    unknown = sorted(used - allowed)
    if unknown:
        return (
            f"{label}模板里有不可用的占位符：{'、'.join('{' + n + '}' for n in unknown)}"
            f"（该模板可用：{'、'.join('{' + n + '}' for n in sorted(allowed))}）"
        )

    if field in ("entry_dir", "movie_file") and not ({"title", "original_title"} & used):
        return f"{label}模板必须包含 {{title}} 或 {{original_title}}，否则不同影片会重名"
    if field == "season_dir" and "season" not in used:
        return "季目录模板必须包含 {season}，否则不同季的同集号文件会互相覆盖"
    if field == "episode_file" and not {"season", "episode"} <= used:
        return "剧集文件名模板必须包含 {season} 与 {episode}，否则同一部剧的多集会互相覆盖"
    return None


def validate_templates(templates: NamingTemplates) -> str | None:
    """校验四个模板，返回第一条错误；全部通过返回 None。"""
    for field in ALLOWED_TOKENS:
        error = validate_template(field, getattr(templates, field))
        if error is not None:
            return error
    return None


# ---------------------------------------------------------------------------
# 生效模板与上下文构造
# ---------------------------------------------------------------------------


def effective_templates(library: object | None = None) -> NamingTemplates:
    """当前生效的模板（内置默认 → 全局设置 → 库级覆盖，逐字段回落）。

    延迟导入 scrape_config：本模块被 settings 的校验器引用，模块级导入会
    绕成 settings → naming → scrape_config → settings 的环。
    """
    from movieclaw_api.services.scrape_config import effective_naming_templates

    return effective_naming_templates(library)


def item_context(item: Any) -> dict[str, Any]:
    """媒体条目 → 渲染上下文（只取模板可用的身份字段）。"""
    return {
        "title": item.title,
        "original_title": getattr(item, "original_title", None),
        "english_title": getattr(item, "english_title", None),
        "year": item.year,
        "tmdb_id": getattr(item, "tmdb_id", None),
        "imdb_id": getattr(item, "imdb_id", None),
        "douban_id": getattr(item, "douban_id", None),
    }


# 文件属性的展示写法：贴近发布名惯例（HEVC / DV / DDP 5.1），而不是探测器原值
_CODEC_LABELS = {
    "hevc": "HEVC",
    "h264": "H.264",
    "av1": "AV1",
    "vp9": "VP9",
    "mpeg2video": "MPEG-2",
    "vc1": "VC-1",
}
_HDR_LABELS = {"Dolby Vision": "DV"}
_AUDIO_CODEC_LABELS = {
    "aac": "AAC",
    "ac3": "DD",
    "eac3": "DDP",
    "truehd": "TrueHD",
    "dts": "DTS",
    "flac": "FLAC",
    "opus": "Opus",
    "mp3": "MP3",
    "lpcm": "LPCM",
}
# 只是编码内部档次的 profile 不如 codec 有信息量（与回收站音轨展示同一判断）
_GENERIC_AUDIO_PROFILES = {"lc", "main", "high", "baseline", "main 10"}
_CHANNEL_LABELS = {1: "1.0", 2: "2.0", 6: "5.1", 7: "6.1", 8: "7.1"}


def _audio_label(streams: list | None) -> str | None:
    """默认音轨（没有标默认的取第一条）→「编码 声道」，如 ``DDP 5.1`` / ``DTS-HD MA 7.1``。"""
    if not streams:
        return None
    stream = next((s for s in streams if s.get("default")), streams[0])
    codec = str(stream.get("codec") or "").lower()
    if codec.startswith("pcm_"):
        codec = "lpcm"  # pcm_s24le / pcm_bluray 等都是无压缩 PCM
    base = _AUDIO_CODEC_LABELS.get(codec, codec.upper()) if codec else None
    profile = str(stream.get("profile") or "")
    if "atmos" in profile.lower():
        name = f"{base} Atmos" if base else "Atmos"
    elif profile and profile.lower() not in _GENERIC_AUDIO_PROFILES:
        name = profile
    else:
        name = base
    layout = str(stream.get("channel_layout") or "").split("(")[0].strip()
    channels = stream.get("channels")
    if layout[:1].isdigit():
        chan = layout
    elif isinstance(channels, int):
        chan = _CHANNEL_LABELS.get(channels, f"{channels}ch")
    else:
        chan = None
    return " ".join(p for p in (name, chan) if p) or None


def file_attrs(
    *,
    resolution: str | None = None,
    media_source: str | None = None,
    release_group: str | None = None,
    video_codec: str | None = None,
    hdr: str | None = None,
    bit_depth: int | None = None,
    audio_streams: list | None = None,
    site_id: str | None = None,
    release_name: str | None = None,
) -> dict[str, Any]:
    """文件属性 → 渲染上下文。入库（探测结果 + 来源戳）与整理（台账行）
    **都必须经这里**格式化，否则同一个文件两侧算出不同的名字。

    ``{site}`` 取站点标识（hdsky / chdbits）而不是显示名：显示名带空格与
    中文、且会随站点配置调整，一变就让整库「待整理」；标识是稳定的键。
    """
    return {
        "resolution": resolution,
        "media_source": media_source,
        "release_group": release_group,
        "video_codec": _CODEC_LABELS.get(video_codec or "", (video_codec or "").upper()) or None,
        "hdr": _HDR_LABELS.get(hdr or "", hdr) or None,
        "bit_depth": f"{bit_depth}bit" if bit_depth else None,
        "audio": _audio_label(audio_streams),
        "site": site_id,
        "release_name": release_name,
    }


# ---------------------------------------------------------------------------
# 四个入口（四处调用点唯一允许的命名来源）
# ---------------------------------------------------------------------------


def entry_dir_name(
    *,
    title: str,
    year: int | None = None,
    templates: NamingTemplates | None = None,
    library: object | None = None,
    **extra: Any,
) -> str:
    """条目目录名。投递 save_path、监听导入落点、整理目标目录共用。"""
    tpl = templates or effective_templates(library)
    return render(tpl.entry_dir, {"title": title, "year": year, **extra})


def entry_dir_name_of(
    item: Any, templates: NamingTemplates | None = None, library: object | None = None
) -> str:
    """条目目录名（媒体条目版）。"""
    tpl = templates or effective_templates(library)
    return render(tpl.entry_dir, item_context(item))


def movie_file_name(
    item: Any,
    templates: NamingTemplates | None = None,
    library: object | None = None,
    **extra: Any,
) -> str:
    """电影正片文件名（不含扩展名）。"""
    tpl = templates or effective_templates(library)
    return render(tpl.movie_file, {**item_context(item), **extra})


def season_dir_name(
    season: int,
    item: Any | None = None,
    templates: NamingTemplates | None = None,
    library: object | None = None,
    season_name: str | None = None,
) -> str:
    """季目录名。``season_name`` 是 TMDB 季名（如「特别篇」），供 ``{season_name}``。"""
    tpl = templates or effective_templates(library)
    context: dict[str, Any] = dict(item_context(item)) if item is not None else {}
    context["season"] = season
    context["season_name"] = season_name
    return render(tpl.season_dir, context)


def episode_file_name(
    item: Any,
    season: int,
    episode: int,
    templates: NamingTemplates | None = None,
    library: object | None = None,
    **extra: Any,
) -> str:
    """分集文件名（不含扩展名）。"""
    tpl = templates or effective_templates(library)
    return render(
        tpl.episode_file,
        {**item_context(item), "season": season, "episode": episode, **extra},
    )


async def load_unit_names(
    session: Any, item_ids: Any
) -> tuple[dict[tuple[int, int], str], dict[tuple[int, int, int], str]]:
    """季名与集名（``{season_name}`` / ``{episode_title}`` 的取值），入库与整理共用。

    返回 ``({(条目, 季): 季名}, {(条目, 季, 集): 集名})``；空名不收录（渲染为空）。
    """
    from sqlmodel import select

    from movieclaw_db.models import MediaEpisode, MediaSeason

    ids = list(item_ids)
    if not ids:
        return {}, {}
    seasons = await session.execute(
        select(MediaSeason.media_item_id, MediaSeason.season_number, MediaSeason.name).where(
            MediaSeason.media_item_id.in_(ids)  # type: ignore[attr-defined]
        )
    )
    episodes = await session.execute(
        select(
            MediaEpisode.media_item_id,
            MediaEpisode.season_number,
            MediaEpisode.episode_number,
            MediaEpisode.name,
        ).where(MediaEpisode.media_item_id.in_(ids))  # type: ignore[attr-defined]
    )
    return (
        {(i, s): name for i, s, name in seasons.all() if name},
        {(i, s, e): name for i, s, e, name in episodes.all() if name},
    )
