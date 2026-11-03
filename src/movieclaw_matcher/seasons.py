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

- **G1**：block 必须已播完（``end`` 那集的 ``air_date < today``）才参与推导，
  不对未来开口。TMDB 已经登记了后面的集、但还没播时，提前把站点季号切出来
  只会让映射提前生效、指到还不存在的集上；
- **季 0（特别篇）**完全不参与——特别篇的发行季号是站点的私事，没有稳定规律。

无 ``air_date`` 的集不参与断档判定（没有日期就没有间隔可言），但如果它的
集号落在某个 block 的集号区间内，就归那个 block——TMDB 常给还没定档的集留
空日期，它们物理上属于前后两个 block 之间的那一截。

本模块是**纯函数**：输入 ``(季, 集, 播出日期)`` 三元组，不碰数据库、不做 IO。
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date

__all__ = [
    "SPLIT_GAP_DAYS",
    "SeasonBlock",
    "SeasonMapping",
    "derive_season_mapping",
    "mapping_from_json",
    "mapping_to_json",
    "translate_unit",
]

#: 播出断档阈值（天）。issue 提议值：覆盖 split-cour 约 13 周的空档（真正断档
#: 播出的两季通常停 3 个月以上）。调低会把"中途停播三周"误判成新季，调高会
#: 漏掉紧凑的 split-cour。
SPLIT_GAP_DAYS = 90


@dataclass(frozen=True)
class SeasonBlock:
    """一个连续播出段：站点的一季 ↔ TMDB 某季的一段集号区间。"""

    site_season: int  # 站点季号（从 1 开始，跨季统一编号）
    season: int  # TMDB 季号
    start: int  # 起始集号（含）
    end: int  # 结束集号（含）

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
        """真正需要换算的块：``站点季号 == TMDB 季号`` 且从该季第 1 集起的块
        对消费侧毫无信息量（普通剧的每一块都是它），**落库时**把它们剔掉，
        普通剧的 ``season_mapping`` 才是 ``[]``（"算过且无需映射"）。

        推导本身仍然返回全部块——那是条目的客观事实，也是"89 天不切 /
        91 天切"这类断言能落到具体块上的前提。
        """
        return tuple(
            block
            for block in self.blocks
            if not (block.site_season == block.season and block.start == 1)
        )

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
) -> SeasonMapping:
    """从 ``media_episode`` 台账推导站点季号映射。

    :param episodes: ``(season_number, episode_number, air_date)`` 三元组，
        直接对应 ``MediaEpisode`` 的三列；顺序无关、允许重复。
    :param today: 判定"block 已播完"（G1）的基准日；缺省取 ``date.today()``。
        可注入是为了测试不受运行时钟影响。
    :return: 映射表。无法推导（没有任何已定档的集）时为空。

    推导细节：

    - 季 0 直接丢弃；
    - 同一季内按集号排序，**只有两侧都有日期**的相邻两集才可能断开：
      间隔 ≥ 90 天即一次断档；
    - 无日期的集不参与断档判定，靠集号归属到某个 block：落在某块的
      [首集, 末集] 区间内直接归它；落在两块之间的空隙时归**后一块**
      （断档发生在它之前，它属于断档之后那一季）；比所有日期都靠后的
      归最后一块，全季日期之后只有它自己时同理；
    - 每个 block 必须已播完（末个**有日期**的集 ``air_date < today``）才
      参与，未播完的整块丢弃（G1，不对未来开口）；
    - 全部 block 按首播日期排序后统一编号。**推导一律返回全部块**——那是
      条目的客观事实；恒等块在**落库时**才被 :attr:`SeasonMapping.needs_mapping`
      剔除，好让普通剧的 ``season_mapping`` 是 ``[]``。
    """
    today = today or date.today()
    by_season: dict[int, list[tuple[int, date | None]]] = {}
    for season, episode, air_date in episodes:
        if season <= 0 or episode <= 0:
            continue
        by_season.setdefault(season, []).append((episode, air_date))

    # (首播日期, 季号, 起点, 终点)：先攒成可排序元组，最后统一编号
    blocks: list[tuple[date, int, int, int]] = []
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

        # 无日期的集按集号归属（不改变分块，只扩块边界）
        for episode in undated:
            home = next(
                (chunk for chunk in chunks if chunk[0] <= episode <= chunk[1]),
                None,
            )
            if home is None:
                # 落在两块之间的空隙 → 后一块；比所有日期都靠后 → 最后一块
                home = next((chunk for chunk in chunks if chunk[0] > episode), chunks[-1])
            home[0] = min(home[0], episode)
            home[1] = max(home[1], episode)

        for start, end, first_day, last_day in chunks:
            # G1：末个有日期的集必须已经播出（严格早于今天）
            if not last_day < today:
                continue
            blocks.append((first_day, season, start, end))

    if not blocks:
        return SeasonMapping()

    blocks.sort()
    return SeasonMapping(
        blocks=tuple(
            SeasonBlock(site_season=index, season=season, start=start, end=end)
            for index, (_day, season, start, end) in enumerate(blocks, start=1)
        )
    )


def translate_unit(mapping: SeasonMapping, site_season: int, site_episode: int) -> tuple[int, int]:
    """站点 ``(季, 集)`` → TMDB ``(季, 集)``。

    季号命中 block 时按偏移平移；集号超出该块区间时**不夹紧**——站点声明的
    集数常比 TMDB 已录的多（#640），上界由调用方按 ``declared_total`` 决定
    （见 identity._derive_units）。没命中映射时原样返回。
    """
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
