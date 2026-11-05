"""站点季号推导（issue #1155）：TMDB 合并成一季、站点却按两季发布。

## 要解决的问题

TMDB 偶尔把**实际分两季播出**的剧登记成一条连着编号的长季。《我独自升级》
就是一例：TMDB ``tv/127532`` 只有第 1 季、25 集，而第 13–25 集其实是隔了
280 天播出的第二季。站点不认这套合并编号，照常拆成 ``S01``（12 集）/
``S02``（13 集）发布。

于是一个标着 ``S02`` 的种子在匹配内核里被判成 ``pack_seasons={2}``，
而条目只有 ``season_numbers=(1,)`` —— 两边没有交集，资源被无声丢弃。

## 推导规则

同一 TMDB 季内，相邻两集的播出日期间隔 ≥ ``SPLIT_GAP_DAYS``（90 天）就是
一次播出断档。断档把这一季切成若干 **block**；按各 block 的首播日期排序、
**跨所有季统一编号**，序号就是站点季号（从 1 开始）。

```text
TMDB S01
  block1 = E01–E12  (2024-01-07 … 2024-03-31)   站点第 1 季，偏移 0
  ── 断档 280 天 ──
  block2 = E13–E25  (2025-01-05 … 2025-03-30)   站点第 2 季，偏移 12
```

普通剧天然是**恒等映射**：TMDB S01(10) + S02(10) → 两个 block，起点分别是
(1,1) 与 (2,1)，偏移全 0。站点 ``S02`` 因此落在条目自己的 ``season_numbers``
里，消费侧**根本不会查这张表**（见 identity._derive_units 的窄启用条件）——
这是"普通剧零影响"的结构性保证。

## 守卫

- **G1**：block 必须**已开播**（首个已定档集的 ``air_date <= today``）才参与
  推导，不对未来开口——TMDB 连首播日都还没有的块，站点季号切出来也只会在
  开头那几天把映射指到还不存在的集上；
- 块保留**完整集号区间**（若干集还没播也不截断）：在播中的块如果整块丢掉，
  站点 S02 的已播单集在整季播完前一条都收不到。未播集由 ``covered_units``
  的 air_date 上限自然剔除（``_airable`` / ``_explicit_airable``）；
- **季 0（特别篇）**完全不参与——特别篇的发行季号是站点的私事，没有稳定规律。

无 ``air_date`` 的集不参与断档判定（没有日期就没有间隔可言），但如果它的
集号落在某个 block 的集号区间内，就归那个 block——TMDB 常给还没定档的集留
空日期，它们物理上属于前后两个 block 之间的那一截。

落库（:attr:`SeasonMapping.needs_mapping`）还有三道闸，保证消费侧读到的映射
可以直接用、不必各自再判：

- **站点季号撞上 TMDB 真实存在的季**（条目完整季表，含集表还空着的季）的块
  不落库——TMDB S01 中途停播 90 天以上、同时又真有 S02 时，站点 ``S02E01``
  就是 TMDB 的 S02E01，不是 S01 的后半段；
- **起点不确定**的块不落库：断档边界上夹着无日期的集时，它属于哪一块没有
  证据，后一块的偏移跟着定不下来；
- E00（先导/特辑）永远不换算（:func:`translate_unit`）。

本模块是**纯函数**：输入 ``(季, 集, 播出日期)`` 三元组，不碰数据库、不做 IO。
"""

from __future__ import annotations

from collections.abc import Collection
from dataclasses import dataclass
from datetime import date

__all__ = [
    "SNAPSHOT_KEY",
    "SPLIT_GAP_DAYS",
    "SeasonBlock",
    "SeasonMapping",
    "derive_season_mapping",
    "mapping_for_task",
    "mapping_from_json",
    "mapping_to_json",
    "translate_unit",
]

#: 播出断档阈值（天）。issue 提议值：覆盖 split-cour 约 13 周的空档（真正断档
#: 播出的两季通常停 3 个月以上）。调低会把"中途停播三周"误判成新季，调高会
#: 漏掉紧凑的 split-cour。
SPLIT_GAP_DAYS = 90

#: 在途任务冻结映射快照的键（``subscription_download_attempt.submission`` 里），
#: 见 :func:`mapping_for_task`
SNAPSHOT_KEY = "season_mapping"


@dataclass(frozen=True)
class SeasonBlock:
    """一个连续播出段：站点的一季 ↔ TMDB 某季的一段集号区间。"""

    site_season: int  # 站点季号（从 1 开始，跨季统一编号）
    season: int  # TMDB 季号
    start: int  # 起始集号（含）
    end: int  # 结束集号（含）
    # 起点是否可靠：断档边界上夹着无日期的集时，那几集属于前一块还是后一块
    # 无从判断，后一块的起点（也就是偏移）跟着不确定。这种块照常占一个站点
    # 季号（它确实存在、首播日也确定，后面的块不能因此前移编号），但不落库、
    # 不做换算（见 needs_mapping）
    certain: bool = True

    @property
    def offset(self) -> int:
        """站点集号 → TMDB 集号的平移量：``site_ep + offset == tmdb_ep``。"""
        return self.start - 1

    def __post_init__(self) -> None:
        if self.site_season < 1 or self.season < 1:
            raise ValueError("站点季号与 TMDB 季号都必须从 1 开始")
        if self.start < 1 or self.end < self.start:
            raise ValueError("block 的集号区间必须非空且递增")

    def to_json(self) -> dict:
        # 落库形状按 docs/design/subscription-season-split.md §6 方案 A：
        # {"number": 2, "season": 1, "start": 13, "end": 25}
        return {
            "number": self.site_season,
            "season": self.season,
            "start": self.start,
            "end": self.end,
        }

    @classmethod
    def from_json(cls, data: dict) -> SeasonBlock:
        number = data["number"] if "number" in data else data["site_season"]
        return cls(
            site_season=int(number),
            season=int(data["season"]),
            start=int(data["start"]),
            end=int(data["end"]),
        )


@dataclass(frozen=True)
class SeasonMapping:
    """一个条目的站点季号映射表（block 按站点季号升序）。"""

    blocks: tuple[SeasonBlock, ...] = ()
    # 条目完整的 TMDB 季列表（推导时才有；从 JSON 读回的映射为空集——落库前
    # 已经按它过滤过）。站点季号在这里面，就是 TMDB 真实存在的那一季
    tmdb_seasons: frozenset[int] = frozenset()

    def __bool__(self) -> bool:
        return bool(self.blocks)

    def by_site_season(self, site_season: int) -> SeasonBlock | None:
        for block in self.blocks:
            if block.site_season == site_season:
                return block
        return None

    def by_range(self, season: int, episode: int) -> SeasonBlock | None:
        """反查：TMDB 的 (季, 集) 落在哪个 block 里（分集区标注用）。"""
        for block in self.blocks:
            if block.season == season and block.start <= episode <= block.end:
                return block
        return None

    @property
    def needs_mapping(self) -> tuple[SeasonBlock, ...]:
        """真正需要换算的块：**某个 TMDB 季被切成了不止一块**时，第二块起的那些。

        判据是「这个 TMDB 季在前面已经出现过」——不是逐块比较 ``site == season``。
        两者的差别在 TMDB 季号与播出顺序不一致的剧上会暴露：那种剧按播出顺序
        编号时，每一块的 ``site`` 都与 ``season`` 错位，逐块比较会把**普通剧**
        全判成需要映射，于是 ``S01E05`` 被翻译成 ``S02E05``。

        正确的语义是「站点季号是 TMDB 季号的细化」：站点把 TMDB 的季 1 拆成
        站点 S01/S02 时，只有 S02 那块需要换算（它落在季 1 的 T13 起）；
        站点 S01 那块就是 TMDB 季 1 自己，不需要。季号顺序错位是另一回事，
        不构成映射需求——消费侧本来就只在「站点季号不在台账里」时才查表。

        推导本身仍然返回全部块——那是条目的客观事实，也是"89 天不切 /
        91 天切"这类断言能落到具体块上的前提。

        另外两类块即便是细化出来的也不落库：

        - 站点季号在 :attr:`tmdb_seasons` 里：TMDB 真有这一季，站点的 ``S02``
          说的就是它。否则 S01 中途停播、同时又有真 S02 的剧，``S02E01`` 会被
          改写成 ``S01E13`` 入库（下载核验还会给正确来源记上 content_missing）；
        - 起点不确定（:attr:`SeasonBlock.certain` 为假）：偏移定不下来，换算
          出来的集号可能整段错一位，宁可不换算。

        这两道闸放在落库这一处，而不是让匹配、入库、扫描、文件选择、下载核验
        各判一遍：它们读到的映射本来就不含这两类块，口径天然一致。
        """
        seen: set[int] = set()
        result: list[SeasonBlock] = []
        for block in self.blocks:  # 已按首播日期升序
            if (
                block.season in seen  # 这个 TMDB 季已被前面的块占过 → 细化出来的新季
                and block.site_season not in self.tmdb_seasons
                and block.certain
            ):
                result.append(block)
            seen.add(block.season)
        return tuple(result)

    def to_json(self) -> list[dict]:
        """落库形状：只写真正需要换算的块（见 :attr:`needs_mapping`）。"""
        return [block.to_json() for block in self.needs_mapping]

    def as_identity_blocks(self) -> tuple[tuple[int, int, int, int], ...]:
        """内核 ``MediaIdentity.season_blocks`` 的形状：(站点季, TMDB 季, 起, 止)。"""
        return tuple(
            (block.site_season, block.season, block.start, block.end) for block in self.blocks
        )

    @classmethod
    def from_json(cls, data: list | dict | None) -> SeasonMapping:
        """读 ``season_mapping`` 列。三种写法都接受：

        - ``None``（NULL，没算过）与 ``[]``（算过且无需映射）→ 空映射；
        - 裸列表 ``[{...}]``（本实现写入的形状，三态里的"非空"）；
        - 设计文档 §6 举例的包裹形式 ``{"site_seasons": [{...}]}``。
        """
        if isinstance(data, dict):
            data = data.get("site_seasons")
        if not data:
            return cls()
        return cls(blocks=tuple(SeasonBlock.from_json(item) for item in data))


def derive_season_mapping(
    episodes: list[tuple[int, int, date | None]] | tuple[tuple[int, int, date | None], ...],
    *,
    today: date | None = None,
    seasons: Collection[int] = (),
) -> SeasonMapping:
    """从 ``media_episode`` 台账推导站点季号映射。

    :param episodes: ``(season_number, episode_number, air_date)`` 三元组，
        直接对应 ``MediaEpisode`` 的三列；顺序无关、允许重复。
    :param today: 判定"block 已播完"（G1）的基准日；缺省取 ``date.today()``。
        可注入是为了测试不受运行时钟影响。
    :param seasons: 条目完整的 TMDB 季列表，包括集表还空着的季（刚公布的
        第 2 季）。与 ``episodes`` 里出现过的季号合起来就是"TMDB 真实存在的
        季"，落库时站点季号撞上它们的块一律剔除（见 ``needs_mapping``）。
    :return: 映射表。无法推导（没有任何已定档的集）时为空。

    推导细节：

    - 季 0 直接丢弃；
    - 同一季内按集号排序，**只有两侧都有日期**的相邻两集才可能断开：
      间隔 ≥ 90 天即一次断档；
    - 无日期的集不参与断档判定，靠集号归属到某个 block：落在某块的
      [首集, 末集] 区间内直接归它；比所有日期都靠后的归最后一块。落在两块
      之间的空隙时它属于哪一块**没有证据**：后一块的起点因此不确定
      （``certain=False``），照常编号、但不落库；
    - 每个 block 必须**已开播**（首个有日期的集 ``air_date <= today``）才参与，
      未开播的整块丢弃（G1，不对未来开口）。**已开播但还没播完的块照常保留
      完整区间**——在播期间站点 S02 的已播集也要能收到，未播集由
      ``covered_units`` 的 air_date 上限剔除；
    - 全部 block 按首播日期排序后统一编号。**推导一律返回全部块**——那是
      条目的客观事实；恒等块在**落库时**才被 :attr:`SeasonMapping.needs_mapping`
      剔除，好让普通剧的 ``season_mapping`` 是 ``[]``。
    """
    today = today or date.today()
    tmdb_seasons = frozenset(seasons) | {season for season, _episode, _day in episodes}
    by_season: dict[int, list[tuple[int, date | None]]] = {}
    for season, episode, air_date in episodes:
        if season <= 0 or episode <= 0:
            continue
        by_season.setdefault(season, []).append((episode, air_date))

    # (首播日期, 季号, 起点, 终点, 起点可靠)：先攒成可排序元组，最后统一编号
    blocks: list[tuple[date, int, int, int, bool]] = []
    for season, rows in by_season.items():
        rows.sort(key=lambda row: row[0])
        dated = [(episode, day) for episode, day in rows if day is not None]
        if not dated:
            continue  # 整季无日期：既判不了断档，也过不了 G1
        undated = [episode for episode, day in rows if day is None]

        # 断档只在已定档的集之间判定：每块记 [首集, 末集, 首播日, 末播日]
        chunks: list[list] = []
        for episode, day in dated:
            if chunks and (day - chunks[-1][3]).days >= SPLIT_GAP_DAYS:
                chunks.append([episode, episode, day, day])
            elif chunks:
                chunks[-1][1] = episode
                chunks[-1][3] = day
            else:
                chunks.append([episode, episode, day, day])

        # 断档边界上夹着无日期的集：E11 三月播、E12 没有日期、E13 次年一月播，
        # E12 是前一季的收尾还是后一季的开头没有任何证据——后一块的起点（站点
        # S02E01 是 E12 还是 E13）就定不下来，换算出来可能整段错一位。这种块
        # 记为起点不确定：照常占站点季号，但不落库（必须在下面扩边界之前判）
        uncertain = {
            index + 1
            for index in range(len(chunks) - 1)
            if any(chunks[index][1] < episode < chunks[index + 1][0] for episode in undated)
        }

        # 无日期的集按集号归属（不改变分块，只扩块边界）
        for episode in undated:
            home = next(
                (chunk for chunk in chunks if chunk[0] <= episode <= chunk[1]),
                None,
            )
            if home is None:
                # 落在两块之间的空隙 → 区间上暂归后一块（该块上面已记为起点不确定，
                # 不会落库）；比所有日期都靠后 → 最后一块
                home = next((chunk for chunk in chunks if chunk[0] > episode), chunks[-1])
            home[0] = min(home[0], episode)
            home[1] = max(home[1], episode)

        for index, (start, end, first_day, _last_day) in enumerate(chunks):
            # G1：块必须**已开播**才参与（不对未来开口）。用「已开播」而不是
            # 「已播完」：在播中的块如果整块丢掉，站点 S02 的已播单集在整季
            # 播完前一条都收不到（#1155 的剧播到 E18 时订阅，S2 要等到 E19
            # 播出后才生效）。块照常保留完整区间 start..end，未播集由
            # covered_units 的 air_date 上限自然剔除（_airable/_explicit_airable）
            if not first_day <= today:
                continue
            blocks.append((first_day, season, start, end, index not in uncertain))

    if not blocks:
        return SeasonMapping(tmdb_seasons=tmdb_seasons)

    blocks.sort()
    return SeasonMapping(
        blocks=tuple(
            SeasonBlock(site_season=index, season=season, start=start, end=end, certain=certain)
            for index, (_day, season, start, end, certain) in enumerate(blocks, start=1)
        ),
        tmdb_seasons=tmdb_seasons,
    )


def translate_unit(
    mapping: SeasonMapping | None, site_season: int, site_episode: int
) -> tuple[int, int]:
    """站点 ``(季, 集)`` → TMDB ``(季, 集)``；所有消费侧都经这一处换算。

    季号命中 block 时按偏移平移；集号超出该块区间时**不夹紧**——站点声明的
    集数常比 TMDB 已录的多（#640），上界由调用方按 ``declared_total`` 决定
    （见 identity._derive_units）。没命中映射时原样返回。

    **E00 永远不换算**：站点 ``S02E00`` 是站点第 2 季的先导/特辑，TMDB 里它
    多半在第 0 季、集号对不上；平移成 ``(1, 12)`` 会把特辑当成正片第 12 集
    入库、下载、核验。原样返回 ``(2, 0)``，下游按"集号为 0"的既有规则处理
    （入库看 ``explicit_pilot``、严格文件选择不选）。
    """
    if mapping is None or site_episode <= 0:
        return site_season, site_episode
    block = mapping.by_site_season(site_season)
    if block is None:
        return site_season, site_episode
    return block.season, site_episode + block.offset


def mapping_from_json(data: list | None) -> SeasonMapping:
    """``media_item.season_mapping`` JSON → :class:`SeasonMapping`。

    ``NULL``/``[]`` 都读成空映射（"没算过"与"算过且无需映射"在匹配语义上等价，
    都表示"不要换算"）。
    """
    return SeasonMapping.from_json(data)


def mapping_to_json(mapping: SeasonMapping) -> list[dict]:
    """:class:`SeasonMapping` → 可落 JSON 列的字典列表。"""
    return mapping.to_json()


def mapping_for_task(submission: dict | None, current: list | dict | None) -> SeasonMapping:
    """在途任务该用哪份映射解释种子里的文件名。

    投递时把当时用的映射原样冻结进任务（``submission[SNAPSHOT_KEY]``），之后
    的核验、逐集进度、提交恢复、整包扩选都读这一份：下载期间元数据刷新改了
    映射，同一个 ``S02E01.mkv`` 也不会一会儿是 E13、一会儿是别的集，进而被
    误判缺失、给来源记上 content_missing。没有快照（快照上线前的任务、没有
    台账的投递）才退回条目当前的映射 ``current``。
    """
    payload = submission or {}
    if SNAPSHOT_KEY in payload:
        return SeasonMapping.from_json(payload[SNAPSHOT_KEY])
    return SeasonMapping.from_json(current)
