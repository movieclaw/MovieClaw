"""入库的公共命名约定与共享常量（扫描 / 监听导入 / 整理共用）。

历史沿革：本模块曾承载订阅专属的"下载完成 → 硬链入库"管线
（import_completed_torrent）。架构定稿"订阅止于投递"后，搬运统一由
监听导入（library_ingest，按 info_hash 认领订阅身份）与库扫描（原地
入账）完成，工单由库存对账关闭（wanted_fulfillment），订阅专属管线
退役。这里沉淀的是三个入库引擎共用的约定：

- ``VIDEO_EXTS`` / ``STRM_EXT`` / ``SCAN_VIDEO_EXTS``：视频文件扩展名
  （入库对象）与 strm 占位文件的接纳约定；
- ``IN_PROGRESS_MARKERS``：下载器/浏览器的"未完成"标记后缀
  （扫描与监听导入的完整性检测共用）；
- ``season_from_dir`` / ``entry_dirs``：季目录与条目目录的判定——识别链
  （取片名证据）、待识别分组、条目真实删除三处必须是同一套约定，各写
  各的会出事（实测隐患：删除按"库根直接子目录"算条目目录，遇到
  ``剧集/大陆/风筝 (2017)/`` 这种分类分组层会把整个「大陆」目录删掉）；
"""

from __future__ import annotations

import re
from pathlib import Path

# 视频文件扩展名（入库对象）；其余（字幕/nfo/图片）v1 不搬运
VIDEO_EXTS = {
    ".mkv",
    ".mp4",
    ".avi",
    ".ts",
    ".m2ts",
    ".wmv",
    ".mov",
    ".flv",
    ".rmvb",
    ".mpg",
    ".mpeg",
    ".m4v",
    ".webm",
}

# strm：Kodi/Emby/Jellyfin 生态约定的"播放地址占位文件"——内容是一行
# 播放 URL 的纯文本（网盘挂载场景的标配，本地不占盘、播放时才拉流）。
# 识别与刮削全靠文件名/目录名，与普通视频一致；但文件本体没有媒体流，
# ffprobe 探测对它天然无意义（规格列留空）。
STRM_EXT = ".strm"

# 库扫描/实时监控/整理/监听导入的接纳范围 = 视频 + strm 占位。监听导入
# 对 strm 不跑 ffprobe 完整性门禁（必然失败），改为校验内容能解析出播放源。
SCAN_VIDEO_EXTS = VIDEO_EXTS | {STRM_EXT}

# 图片库的入账对象（docs/design/library-photo-kind.md 2.1）。只收浏览器能直接
# 渲染、Pillow 能直接解码的格式：HEIC/HEIF 两边都不原生支持，一期不收。
# 影视库与其他库**不收图片**——它们目录里的 jpg 是海报/剧照 sidecar，不是内容
IMAGE_EXTS = {
    ".jpg",
    ".jpeg",
    ".png",
    ".webp",
    ".gif",
    ".bmp",
    ".avif",
}

# 外挂字幕扩展名（发现对象，docs/design/jellyfin-subtitle.md §2.1）。
# 只收语义明确的文本字幕：.sub 有 MicroDVD/VobSub 歧义、.sup/.idx 是
# 图形字幕（无法转换、播放器支持参差），均不收。
SUBTITLE_EXTS = {".srt", ".ass", ".ssa", ".vtt"}
# 文件名/路径含这些标记的视频不入库（样品片段等）
_IGNORE_MARKERS = ("sample",)

# 下载器/浏览器的"未完成"标记（文件名小写后缀匹配）：qBittorrent .!qb、
# aria2 控制文件 .aria2、Chrome .crdownload、Firefox/迅雷等 .part/.td、
# BitComet .bc!、通用临时后缀。扫描器与监听导入共用（放在本模块避免
# scan ↔ ingest 的循环导入）
IN_PROGRESS_MARKERS = (
    ".!qb",
    ".part",
    ".aria2",
    ".crdownload",
    ".download",
    ".downloading",
    ".td",
    ".bc!",
    ".tmp",
    ".temp",
    ".unfinished",
)


def is_disc_dir(directory: Path) -> bool:
    """原盘目录判定：蓝光（BDMV）或 DVD（VIDEO_TS）结构。

    扫描（原盘按目录整体入账、不进内部遍历）与监听导入（入库落点避让，
    docs/design/disc-version-layout.md §3）共用同一判据——放在本模块
    避免 scan ↔ ingest 的循环导入。
    """
    return (directory / "BDMV").is_dir() or (directory / "VIDEO_TS").is_dir()


# 季目录名："Season 02" / "S02" / "第2季" / "第二季" / "Specials" / "特别篇"
#
# 季标记必须在名字**开头**，其后只允许"装饰"：年份、同号的中文季名、括号组、
# 分隔符。整理工具普遍把 TMDB 的季名/季播年份拼进季目录（issue #497：
# 「Season 4-第 4 季-(2007)」），全锚定的写法认不出它们，季目录就被当成条目
# 目录——片名证据变成「Season 4-第 4 季-」、年份变成季播年，连带推翻路径上
# 正确的 tmdbid 标记，一部剧按季拆成若干个认不出的条目。
# 反过来，季标记之后出现任何片名性质的文字（"Show S01 1080p"、"Season 1 -
# Pilot Arc"）都不算季目录：带片名的季包目录另由 ``pack_season`` 处理。
_SEASON_HEAD = re.compile(
    r"^\s*(?:(?:season|series)[ ._-]*(\d{1,3})|s(\d{1,3})(?![0-9a-z])"
    r"|第\s*(\d{1,3}|[一二两三四五六七八九十]{1,3})\s*季(?!度))",
    re.IGNORECASE,
)
# 季标记之后允许重复出现的同号季名（"Season 4-第 4 季"）；号码不一致视为矛盾
_SEASON_ECHO = re.compile(
    r"第\s*(\d{1,3}|[一二两三四五六七八九十]{1,3})\s*季|season[ ._-]*(\d{1,3})", re.IGNORECASE
)
# 装饰：括号组、四位年份、分隔符。剥完还有剩余即说明夹带了别的文字
_SEASON_DECOR = re.compile(
    r"[\[{(（【][^\]})）】]*[\]})）】]|(?<!\d)(?:19|20)\d{2}(?!\d)|[\s._\-–—·]+"
)
_SPECIALS_DIR = re.compile(r"^(?:specials?|特别篇|特典)$", re.IGNORECASE)

# 带片名的季包目录里的季标记（"House.M.D.S04.1080p.BluRay"、"豪斯医生 第四季"）。
# S 标记前后不能紧贴字母数字：挡住 "S04E01"（单集）与 "S1m0ne" 这类词内片段
_PACK_SEASON = re.compile(
    r"(?<![A-Za-z0-9])S(\d{1,3})(?![0-9A-Za-z])|season[ ._-]*(\d{1,3})(?!\d)"
    r"|第\s*(\d{1,3}|[一二两三四五六七八九十]{1,3})\s*季(?!度)",
    re.IGNORECASE,
)
# 多季合集的区间写法（"S01-S08"、"第一至八季"）：一个目录装了多季，不能取单一季号
_SEASON_RANGE = re.compile(r"(?i)S\d{1,3}\s*[-~]\s*S?\d{1,3}|第\S{1,3}[-~至到]\S{1,3}季")
# 条目目录的两种明确形态：路径 tmdbid 标记（与 scan._PATH_TMDBID 同一写法）
# 与「Title (Year)」惯例名。只用来判断"带片名的季包目录的父目录是不是条目"
_TMDB_TAG = re.compile(r"[\[{]\s*tmdb(?:id)?\s*[-=]\s*\d+\s*[\]}]", re.IGNORECASE)
_TITLE_YEAR = re.compile(r"^(.+?)\s*\((\d{4})\)")
_BRACKET_TAGS = re.compile(r"[\[{][^\]}]*[\]}]")

_CN_DIGITS = {
    "一": 1,
    "二": 2,
    "两": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
}

# 裸尾号集数：「走向共和01」「大宅门22」——无 SxxExx/「第N集」标记、纯靠
# 结尾数字排集的命名（央视老剧资源极常见）。紧邻的前一个字符不能是字母
# 或数字：挡住 x264/DDP5.1 这类技术尾巴；1~3 位挡住 4 位年份（Movie 2003
# 的 "003" 也因前一位是数字而不中）
_TRAILING_INDEX = re.compile(r"(?<![0-9A-Za-z])(\d{1,3})\s*$")

# 显式 SxxEyy 标记：场景命名里语义最强的季集声明。前界挡住词内片段
# （"XS06E01"），后界挡住数字粘连（"S02E051080p" 宁可不中，交回模型通道）
_EXPLICIT_SXXEYY = re.compile(r"(?i)(?<![0-9A-Za-z])S(\d{1,3})[ ._-]?E(\d{1,4})(?!\d)")
# NxMM 写法（Kodi/Plex/Emby 都认的 "House - 4x01 - Alone"）。季号 1~2 位、
# 集号 2~3 位且两端不贴数字：挡住 "1920x1080" 分辨率与 "x264" 编码
_EXPLICIT_NXMM = re.compile(r"(?<![0-9A-Za-z])(\d{1,2})[xX](\d{2,3})(?![0-9])")

# 裸 E/EP 集号标记（无 S 季号前缀）："Hikaru No Go.E01.2020..."、"...EP12..."。
# 单季剧的种子极常见这么命名，而这种串**在信息论上根本不含季号**——模型只能
# 幻觉（线上病例：E10 被同时标成季号与集号，整包散进 25 个不存在的季目录）。
# 集号本身却是确定的，用正则拿下来即可，季号另由证据链求解。
#
# 前界只认真正的分隔符（不是"非字母数字"）：`[` 不算界，否则动漫文件名尾部的
# CRC32 校验码 "[E5F1A2B3]" 会被读成 E5。后界挡数字粘连。可选的 P 收编 "EP01"
# 写法——28024 条金标语料实测：召回从 936 涨到 1665，误命中恒为 7 条且逐条核对
# 全是标注漏标的真集号（E204/E219/E07），真实误报为 0。允许 E 与数字间再夹一个
# 分隔符的变体已否决：会把 "…no Anata e 2022…" 的年份、"…e 2nd Season…" 的季号
# 吃成集号（误命中 7 → 22）。
_EXPLICIT_EPISODE = re.compile(r"(?:^|[ ._\-])(?:[Ee][Pp]?)(\d{1,4})(?!\d)")


def trailing_index_episode(stem: str) -> int | None:
    """裸尾号命名声明的集号；解析不出（或为 0）返回 None。

    只该在常规集号解析（SxxExx/第N集）全灭后作兜底——常规标记的语义
    强得多，兜底规则抢跑会把「S01E03.特辑2」这类名字带偏。
    """
    match = _TRAILING_INDEX.search(stem.strip())
    if match is None:
        return None
    value = int(match.group(1))
    return value if value >= 1 else None


def explicit_unit(stem: str) -> tuple[int, int] | None:
    """文件名显式 SxxEyy（或 NxMM）标记声明的 (季号, 集号)；没有该标记返回 None。

    NER 模型面向种子标题训练，对纯场景命名的单集文件名会漏抽/错标集号
    （torrent-ner-v2 把 "S06E01" 的 01 标成季号的线上病例），而显式标记的
    语义是确定的——它在时必须压过模型结果。E00（先导/特辑占位）原样返回
    (season, 0)：集号 0 在管线里是「无集号」哨兵，入库层据此识别"这是
    显式声明的第 0 集"并按占位跳过，而不是误报解析失败。
    """
    match = _EXPLICIT_SXXEYY.search(stem) or _EXPLICIT_NXMM.search(stem)
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2))


def explicit_episode(stem: str) -> int | None:
    """文件名裸 E/EP 标记声明的集号；没有该标记或标记自相矛盾时返回 None。

    只出集号、不猜季号——这正是它与 ``explicit_unit`` 的分工：``E01`` 里没有
    季号信息，硬猜就是幻觉。季号交给 ``units.resolve_units`` 的证据链。

    同一个名字里解出多个不同的 E 号（"EP01-EP04" 这类区间/合集写法）视为歧义
    返回 None：宁可交回上层挂起等人，也不从区间里随手挑一个。E00 原样返回 0，
    与 ``explicit_unit`` 同口径（0 是管线的「无集号」哨兵，上层据此按先导/
    特辑占位跳过，而不是误报解析失败）。
    """
    values = {int(match.group(1)) for match in _EXPLICIT_EPISODE.finditer(stem)}
    return values.pop() if len(values) == 1 else None


def _season_int(text: str) -> int | None:
    """季号数字：'4' / '04' / '四' / '十二' / '二十' → int；解析不了返回 None。"""
    if text.isdigit():
        return int(text)
    tens, sep, units = text.partition("十")
    if not sep:
        return _CN_DIGITS.get(text)
    if (tens and tens not in _CN_DIGITS) or (units and units not in _CN_DIGITS):
        return None
    return (_CN_DIGITS[tens] if tens else 1) * 10 + (_CN_DIGITS[units] if units else 0)


def _first_group(match: re.Match[str]) -> int | None:
    return _season_int(next(g for g in match.groups() if g is not None))


def season_from_dir(directory: Path) -> int | None:
    """目录名声明的季号（特别篇为 0）；不是季目录返回 None。

    判据见 ``_SEASON_HEAD``：季标记开头、其后只剩装饰。「Season 4-第 4 季-(2007)」
    「Season 01 (2004)」「第四季」都是第 4/1/4 季；「Season 4-第 5 季」前后
    矛盾、「Show S01 1080p」带片名，都不算。
    """
    name = directory.name.strip()
    if _SPECIALS_DIR.match(name):
        return 0
    match = _SEASON_HEAD.match(name)
    if match is None:
        return None
    season = _first_group(match)
    rest = name[match.end() :]
    for echo in _SEASON_ECHO.finditer(rest):
        if _first_group(echo) != season:
            return None
    rest = _SEASON_DECOR.sub("", _SEASON_ECHO.sub("", rest))
    return season if not rest else None


def pack_season(name: str) -> int | None:
    """带片名的季包目录名声明的季号（"House.M.D.S04.1080p"、"豪斯医生 第四季"）。

    与 ``season_from_dir`` 的分工：那个认"纯季目录"，这个认"片名 + 季标记"的
    整季包。只在名字里恰好有一个季号、且没有区间写法（"S01-S08" 是多季合集）
    时返回；单集名（"S04E01"）不算季包。它和显式 SxxEyy 一样是发布组/用户的
    明确声明，因此在季集解析里与季目录同级（见 ``units._file_evidence``）。
    """
    if _SEASON_RANGE.search(name):
        return None
    values = {_first_group(m) for m in _PACK_SEASON.finditer(name)}
    values.discard(None)
    return values.pop() if len(values) == 1 else None


def _entry_like(directory: Path) -> bool:
    """目录名明确是一个条目：带 tmdbid 标记，或符合「Title (Year)」惯例。"""
    name = directory.name
    return bool(_TMDB_TAG.search(name) or _TITLE_YEAR.match(_BRACKET_TAGS.sub(" ", name).strip()))


def entry_dirs(root: Path, file: Path) -> list[Path]:
    """库根与文件之间的各级目录，由近及远；季目录跳过（它不带片名信息）。

    ``{root}/大陆/风筝 (2017)/Season 1/x.mkv`` → ``[风筝 (2017), 大陆]``。
    第一个元素就是**条目目录**；文件直接躺在库根下、或不在库根之下时为空。

    为什么不是"库根的直接子目录"：分类分组层（大陆/欧美/日韩、按年代
    分文件夹）在真实媒体库里非常普遍，认死第一层会把分组名当条目名。

    带片名的季包目录（``豪斯医生 (2004)/House.M.D.S04.1080p/x.mkv``）同样跳过，
    但只在它的父目录**明确是条目**（tmdbid 标记或「Title (Year)」）时——父目录
    是「欧美剧」这类分组时季包目录自己就是条目。条件收得这么紧是因为条目目录
    会被「删除条目」整目录删掉：把分组目录误认成条目的代价是删光整个分组。
    """
    chain: list[Path] = []
    current = file.parent
    while current != root and current.parent != current:
        try:
            current.relative_to(root)
        except ValueError:
            break
        chain.append(current)
        current = current.parent
    dirs: list[Path] = []
    for index, directory in enumerate(chain):
        if season_from_dir(directory) is not None:
            continue
        if (
            not dirs
            and index + 1 < len(chain)
            and pack_season(directory.name) is not None
            and _entry_like(chain[index + 1])
        ):
            continue
        dirs.append(directory)
    return dirs


def entry_dir_of(roots: list[Path], file: Path) -> Path | None:
    """文件归属的条目目录（多库根版本）；不在任何根下或裸文件时为 None。"""
    for root in roots:
        try:
            file.relative_to(root)
        except ValueError:
            continue
        dirs = entry_dirs(root, file)
        return dirs[0] if dirs else None
    return None
