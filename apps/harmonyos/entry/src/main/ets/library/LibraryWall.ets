import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { RemoteImage } from '../common/RemoteImage';
import { MovieClawApi } from '../api/Endpoints';
import {
  FacetValueView,
  LibraryFacetsView,
  LibraryIndexEntryView,
  LibraryInventorySummaryView,
  LibraryItemView,
  LibraryRelaxView
} from '../api/Models';
import { JsonValue, jsonArrayValue, jsonBoolValue, jsonDoubleValue, jsonGet, jsonIntValue, jsonStringValue } from '../api/JsonValue';
import { LibraryKindMeta } from './LibraryShared';
import { LibraryPosterCell } from './LibraryShared';

/**
 * 海报墙的「窗口式」分页与排序/筛选模型（逐条对齐 iOS 端 Features/Library/LibraryWall.swift
 * 与 LibraryShared.swift 的 WallSort 部分，口径即 Web lib/wall-sort.ts、lib/library-filter.ts）。
 *
 * 墙是整份排序结果上的一个窗口 [start, start + items.length)：
 * 向下滚到底追加下一页，A–Z 跳转把窗口换成从某个 offset 开始的一页，
 * 之后向上滚到顶再把上一页补回来；轮询按已加载的页数整窗重拉。
 * 请求用序号作废：换排序/筛选后，上一轮晚到的响应不会覆盖新窗口。
 */

/** 一档排序的方向档案（Web SortDirection）：自然方向与两个方向的人话 */
export class WallSortDirection {
  readonly naturalAsc: boolean;
  readonly asc: string;
  readonly desc: string;

  constructor(naturalAsc: boolean, asc: string, desc: string) {
    this.naturalAsc = naturalAsc;
    this.asc = asc;
    this.desc = desc;
  }

  /** 反转了自然方向才带 order（与 Web orderParam 同一条规矩） */
  orderParam(reversed: boolean): string | null {
    if (!reversed) {
      return null;
    }
    return this.naturalAsc ? 'desc' : 'asc';
  }

  /** 当前方向的人话 */
  label(reversed: boolean): string {
    const ascending: boolean = this.naturalAsc !== reversed;
    return ascending ? this.asc : this.desc;
  }
}

/** 海报墙各档排序的方向档案（Web lib/wall-sort.ts SORT_DIRECTIONS） */
export class WallSortDirections {
  static of(sort: string): WallSortDirection | null {
    if (sort === 'title' || sort === 'probing') {
      return new WallSortDirection(true, 'A→Z', 'Z→A');
    }
    if (sort === 'added_at' || sort === 'release_date' || sort === 'favorited_at') {
      return new WallSortDirection(false, '旧→新', '新→旧');
    }
    if (sort === 'rating') {
      return new WallSortDirection(false, '低→高', '高→低');
    }
    if (sort === 'runtime') {
      return new WallSortDirection(true, '短→长', '长→短');
    }
    if (sort === 'size') {
      return new WallSortDirection(false, '小→大', '大→小');
    }
    if (sort === 'last_played') {
      return new WallSortDirection(false, '远→近', '近→远');
    }
    return null;
  }
}

/** 排序选择（档位 + 是否反转），按 key 存进共享单例记忆（iOS 用 UserDefaults；先进程内，后续接持久化） */
export class WallSortState {
  sort: string;
  reversed: boolean;

  constructor(sort: string, reversed: boolean) {
    this.sort = sort;
    this.reversed = reversed;
  }

  static load(key: string, fallback: WallSortState, allowed: string[]): WallSortState {
    const saved: WallSortState | undefined = WallSortPrefs.states[key];
    if (saved !== undefined && allowed.includes(saved.sort)) {
      return saved;
    }
    return fallback;
  }

  save(key: string): void {
    WallSortPrefs.states[key] = this;
  }
}

/** 排序偏好的进程内共享存储：全站共用一个键（在哪个库选了「按评分」，换个库还是按评分） */
class WallSortPrefs {
  static readonly states: Record<string, WallSortState> = {};
}

/** 排序菜单的一档 */
export class WallSortOption {
  readonly value: string;
  readonly label: string;
  readonly direction: WallSortDirection | null;

  constructor(value: string, label: string, direction: WallSortDirection | null) {
    this.value = value;
    this.label = label;
    this.direction = direction;
  }
}

// MARK: - 筛选条件

/** 筛选维度（后端维度名 + 展示名；条件 chip 行按这个顺序画） */
export class FilterDimension {
  readonly key: string;
  readonly label: string;

  constructor(key: string, label: string) {
    this.key = key;
    this.label = label;
  }
}

/**
 * 海报墙筛选条件（Web lib/library-filter.ts 的 LibraryFilter）。
 * 语义：维内 OR、维间 AND。seriesKeys 没有界面控件（合集才是它的呈现形态），
 * 不计入角标、不画成条件 chip。筛选是意图不持久化，由持有它的页面自己保存。
 */
export class LibraryFilter {
  genres: number[] = [];
  countries: string[] = [];
  decades: string[] = [];
  watch: string | null = null;
  ratingGte: number | null = null;
  runtimes: string[] = [];
  languages: string[] = [];
  resolutions: string[] = [];
  hdr: boolean | null = null;
  stock: string[] = [];
  seriesKeys: string[] = [];

  /** 维度的显示顺序与叫法（十个维度一个都不能少） */
  static readonly dimensions: FilterDimension[] = [
    new FilterDimension('genres', '类型'),
    new FilterDimension('decades', '年代'),
    new FilterDimension('countries', '地区'),
    new FilterDimension('watch', '观看'),
    new FilterDimension('rating_gte', '评分'),
    new FilterDimension('runtimes', '片长'),
    new FilterDimension('languages', '语言'),
    new FilterDimension('resolutions', '画质'),
    new FilterDimension('hdr', '动态范围'),
    new FilterDimension('stock', '库存')
  ];

  /** 值拷贝：父页面改条件时一律 clone 后改，再整体替换触发刷新 */
  clone(): LibraryFilter {
    const next: LibraryFilter = new LibraryFilter();
    next.genres = this.genres.slice();
    next.countries = this.countries.slice();
    next.decades = this.decades.slice();
    next.watch = this.watch;
    next.ratingGte = this.ratingGte;
    next.runtimes = this.runtimes.slice();
    next.languages = this.languages.slice();
    next.resolutions = this.resolutions.slice();
    next.hdr = this.hdr;
    next.stock = this.stock.slice();
    next.seriesKeys = this.seriesKeys.slice();
    return next;
  }

  isEmpty(): boolean {
    return this.genres.length === 0 && this.countries.length === 0 && this.decades.length === 0
      && this.watch === null && this.ratingGte === null && this.runtimes.length === 0
      && this.languages.length === 0 && this.resolutions.length === 0 && this.hdr === null
      && this.stock.length === 0 && this.seriesKeys.length === 0;
  }

  /** 已选条件的条数（「筛选」按钮角标）；系列键不计 */
  count(): number {
    return this.genres.length + this.countries.length + this.decades.length + (this.watch === null ? 0 : 1)
      + (this.ratingGte === null ? 0 : 1) + this.runtimes.length + this.languages.length
      + this.resolutions.length + (this.hdr === null ? 0 : 1) + this.stock.length;
  }

  /** 有没有二级维度——决定要不要取全份 facet（二级的展示名只在 tier=all 里有） */
  hasSecondary(): boolean {
    return this.ratingGte !== null || this.runtimes.length > 0 || this.languages.length > 0
      || this.resolutions.length > 0 || this.hdr !== null || this.stock.length > 0;
  }

  /** 某一维已选的取值，统一成字符串（与 facet 的 value 同一种写法） */
  valuesOf(dim: string): string[] {
    if (dim === 'genres') {
      return this.genres.map((value: number): string => `${value}`);
    }
    if (dim === 'countries') {
      return this.countries;
    }
    if (dim === 'decades') {
      return this.decades;
    }
    if (dim === 'watch') {
      return this.watch === null ? [] : [this.watch];
    }
    if (dim === 'rating_gte' || dim === 'ratingGte') {
      return this.ratingGte === null ? [] : [LibraryFilter.ratingString(this.ratingGte)];
    }
    if (dim === 'runtimes') {
      return this.runtimes;
    }
    if (dim === 'languages') {
      return this.languages;
    }
    if (dim === 'resolutions') {
      return this.resolutions;
    }
    if (dim === 'hdr') {
      return this.hdr === null ? [] : [this.hdr ? '1' : '0'];
    }
    if (dim === 'stock') {
      return this.stock;
    }
    if (dim === 'series_keys' || dim === 'series_key') {
      return this.seriesKeys;
    }
    return [];
  }

  /** 勾选/取消一个取值：多值维度有则去掉无则追加；观看、评分、动态范围单值再点取消 */
  toggle(dim: string, value: string): void {
    if (dim === 'watch') {
      this.watch = this.watch === value ? null : value;
      return;
    }
    if (dim === 'rating_gte' || dim === 'ratingGte') {
      const next: number = Number(value);
      this.ratingGte = this.ratingGte === next ? null : next;
      return;
    }
    if (dim === 'hdr') {
      const next: boolean = value === '1';
      this.hdr = this.hdr === next ? null : next;
      return;
    }
    if (this.valuesOf(dim).includes(value)) {
      this.remove(dim, value);
    } else {
      this.setList(dim, this.valuesOf(dim).concat([value]));
    }
  }

  /** 摘掉一个取值（条件 chip 的 ✕、放宽建议）；单值维度直接清空 */
  remove(dim: string, value: string): void {
    if (dim === 'watch') {
      this.watch = null;
      return;
    }
    if (dim === 'rating_gte' || dim === 'ratingGte') {
      this.ratingGte = null;
      return;
    }
    if (dim === 'hdr') {
      this.hdr = null;
      return;
    }
    this.setList(dim, this.valuesOf(dim).filter((item: string): boolean => item !== value));
  }

  private setList(dim: string, list: string[]): void {
    if (dim === 'genres') {
      this.genres = list.map((value: string): number => Number(value)).filter((value: number): boolean => !Number.isNaN(value));
    } else if (dim === 'countries') {
      this.countries = list;
    } else if (dim === 'decades') {
      this.decades = list;
    } else if (dim === 'runtimes') {
      this.runtimes = list;
    } else if (dim === 'languages') {
      this.languages = list;
    } else if (dim === 'resolutions') {
      this.resolutions = list;
    } else if (dim === 'stock') {
      this.stock = list;
    } else if (dim === 'series_keys' || dim === 'series_key') {
      this.seriesKeys = list;
    }
  }

  /** 评分的字符串写法：8 → "8"、8.5 → "8.5"（与 facet value 一致） */
  static ratingString(value: number): string {
    const rounded: number = Math.round(value);
    return rounded === value && Math.abs(value) < 1e9 ? `${rounded}` : `${value}`;
  }

  /** 条件的规范化键：同一组条件无论勾选顺序都得到同一个串；用于推导「当前墙正好等于哪个合集」 */
  key(): string {
    if (this.isEmpty()) {
      return '';
    }
    const parts: string[] = [];
    const c: string[] = this.countries.slice().sort();
    if (c.length > 0) {
      parts.push(`c${c.join('_')}`);
    }
    const d: string[] = this.decades.slice().sort();
    if (d.length > 0) {
      parts.push(`d${d.join('_')}`);
    }
    const g: string[] = this.genres.map((value: number): string => `${value}`).sort();
    if (g.length > 0) {
      parts.push(`g${g.join('_')}`);
    }
    if (this.hdr !== null) {
      parts.push(`hdr${this.hdr ? '1' : '0'}`);
    }
    const lang: string[] = this.languages.slice().sort();
    if (lang.length > 0) {
      parts.push(`lang${lang.join('_')}`);
    }
    if (this.ratingGte !== null) {
      parts.push(`r${LibraryFilter.ratingString(this.ratingGte)}`);
    }
    const res: string[] = this.resolutions.slice().sort();
    if (res.length > 0) {
      parts.push(`res${res.join('_')}`);
    }
    const rt: string[] = this.runtimes.slice().sort();
    if (rt.length > 0) {
      parts.push(`rt${rt.join('_')}`);
    }
    const sk: string[] = this.seriesKeys.slice().sort();
    if (sk.length > 0) {
      parts.push(`sk${sk.join('_')}`);
    }
    const st: string[] = this.stock.slice().sort();
    if (st.length > 0) {
      parts.push(`st${st.join('_')}`);
    }
    if (this.watch !== null) {
      parts.push(`w${this.watch}`);
    }
    return parts.join('.');
  }

  /** 合集规则 → 筛选条件（Web rulesToFilter）：未知字段保守忽略 */
  static fromRules(rules: JsonValue[]): LibraryFilter {
    const filter: LibraryFilter = new LibraryFilter();
    for (const rule of rules) {
      const field: string | null = jsonStringValue(jsonGet(rule, 'field'));
      if (field === null) {
        continue;
      }
      const values: JsonValue[] = jsonArrayValue(jsonGet(rule, 'values')) ?? [];
      const strings: string[] = [];
      for (const value of values) {
        const text: string | null = jsonStringValue(value);
        if (text !== null) {
          strings.push(text);
        }
      }
      if (field === 'genres') {
        for (const value of values) {
          const id: number | null = jsonIntValue(value);
          if (id !== null) {
            filter.genres.push(id);
          }
        }
      } else if (field === 'origin_countries' || field === 'countries') {
        for (const text of strings) {
          filter.countries.push(text.toUpperCase());
        }
      } else if (field === 'decades') {
        filter.decades = filter.decades.concat(strings);
      } else if (field === 'watch') {
        filter.watch = strings.length > 0 ? strings[0] : null;
      } else if (field === 'rating_gte') {
        filter.ratingGte = values.length > 0 ? jsonDoubleValue(values[0]) : null;
      } else if (field === 'runtimes') {
        filter.runtimes = filter.runtimes.concat(strings);
      } else if (field === 'languages') {
        for (const text of strings) {
          filter.languages.push(text.toLowerCase());
        }
      } else if (field === 'resolutions') {
        filter.resolutions = filter.resolutions.concat(strings);
      } else if (field === 'hdr') {
        const raw: JsonValue | null = values.length > 0 ? values[0] : null;
        const asBool: boolean | null = jsonBoolValue(raw);
        filter.hdr = asBool !== null ? asBool : jsonStringValue(raw) === 'true';
      } else if (field === 'stock') {
        filter.stock = filter.stock.concat(strings);
      } else if (field === 'series_key') {
        filter.seriesKeys = filter.seriesKeys.concat(strings);
      }
    }
    return filter;
  }

  /** 拼接查询参数用的分项（空维度给 undefined，生成的接口函数对 undefined 不带该参数） */
  qG(): string | undefined {
    return this.genres.length === 0 ? undefined : this.genres.map((value: number): string => `${value}`).join(',');
  }

  qC(): string | undefined {
    return this.countries.length === 0 ? undefined : this.countries.join(',');
  }

  qD(): string | undefined {
    return this.decades.length === 0 ? undefined : this.decades.join(',');
  }

  qRt(): string | undefined {
    return this.runtimes.length === 0 ? undefined : this.runtimes.join(',');
  }

  qLang(): string | undefined {
    return this.languages.length === 0 ? undefined : this.languages.join(',');
  }

  qRes(): string | undefined {
    return this.resolutions.length === 0 ? undefined : this.resolutions.join(',');
  }

  qStock(): string | undefined {
    return this.stock.length === 0 ? undefined : this.stock.join(',');
  }

  qSeries(): string | undefined {
    return this.seriesKeys.length === 0 ? undefined : this.seriesKeys.join(',');
  }
  /**
   * 把筛选条件转成后端的规则数组（对应 iOS `LibraryFilter.rules`）。
   *
   * 语义是**维内 OR、维间 AND**：每一维产出一条 `{field, op: 'any_of', values}`，
   * 后端把它们 AND 起来。字段名用后端的维度名——放宽建议接口回的 `dim` 就是这套名字，
   * 所以条件 chip 与放宽建议能共用同一套增删逻辑。
   */
  rules(): JsonValue[] {
    const out: JsonValue[] = [];
    const push = (field: string, values: JsonValue[]): void => {
      if (values.length === 0) {
        return;
      }
      const rule: Record<string, JsonValue> = {};
      rule.field = field;
      rule.op = 'any_of';
      rule.values = values;
      out.push(rule);
    };
    push('genres', this.genres.map((v: number): JsonValue => v));
    push('origin_countries', this.countries.map((v: string): JsonValue => v));
    push('decades', this.decades.map((v: string): JsonValue => v));
    push('watch', this.watch !== null ? [this.watch] : []);
    push('rating_gte', this.ratingGte !== null ? [this.ratingGte] : []);
    push('runtimes', this.runtimes.map((v: string): JsonValue => v));
    push('languages', this.languages.map((v: string): JsonValue => v));
    push('resolutions', this.resolutions.map((v: string): JsonValue => v));
    push('hdr', this.hdr !== null ? [this.hdr] : []);
    push('stock', this.stock.map((v: string): JsonValue => v));
    push('series_key', this.seriesKeys.map((v: string): JsonValue => v));
    return out;
  }

}

// MARK: - 条件展开取数（墙 / 索引 / facet / 放宽建议共用同一份展开，保证口径一致）

/** 海报墙条目（GET /libraries/{id}/items 带全部筛选参数） */
export async function fetchWallItems(api: MovieClawApi, libraryId: number, filter: LibraryFilter,
  sort: string | null, order: string | null, limit: number, offset: number,
  identity?: string): Promise<LibraryItemView[]> {
  return api.libraryItemsList(libraryId, sort ?? undefined, order ?? undefined, limit, offset, identity ?? undefined,
    filter.qG(), filter.qC(), filter.qD(), filter.watch ?? undefined, filter.ratingGte ?? undefined,
    filter.qRt(), filter.qLang(), filter.qRes(), filter.hdr ?? undefined, filter.qStock(), filter.qSeries());
}

/** A–Z 跳转索引（order 必须与取墙时同一个值，offset 才对得上） */
export async function fetchWallIndex(api: MovieClawApi, libraryId: number, filter: LibraryFilter,
  sort: string | null, order: string | null): Promise<LibraryIndexEntryView[]> {
  return api.uiLibraryItemsIndex(libraryId, sort ?? undefined, order ?? undefined, filter.qG(), filter.qC(), filter.qD(),
    filter.watch ?? undefined, filter.ratingGte ?? undefined, filter.qRt(), filter.qLang(), filter.qRes(),
    filter.hdr ?? undefined, filter.qStock(), filter.qSeries());
}

/** 筛选面板候选值与计数（allTiers=false 只算一级四维） */
export async function fetchWallFacets(api: MovieClawApi, libraryId: number, filter: LibraryFilter,
  allTiers: boolean): Promise<LibraryFacetsView> {
  return api.libraryItemsFacets(libraryId, allTiers ? 'all' : undefined, filter.qG(), filter.qC(),
    filter.qD(), filter.watch ?? undefined, filter.ratingGte ?? undefined, filter.qRt(), filter.qLang(), filter.qRes(),
    filter.hdr ?? undefined, filter.qStock(), filter.qSeries());
}

/** 筛空时的放宽建议：服务端只返回救得回内容的条件 */
export async function fetchWallRelax(api: MovieClawApi, libraryId: number,
  filter: LibraryFilter): Promise<LibraryRelaxView> {
  return api.libraryItemsRelax(libraryId, filter.qG(), filter.qC(), filter.qD(), filter.watch ?? undefined,
    filter.ratingGte ?? undefined, filter.qRt(), filter.qLang(), filter.qRes(), filter.hdr ?? undefined,
    filter.qStock(), filter.qSeries());
}

// MARK: - 窗口分页器

/** 窗口式分页器（单库页 / 合集 / 收藏共用）：load / loadPrev / jump / refresh 四件事 */
export class LibraryWallPager {
  readonly pageSize: number;
  /** null = 还没首载 */
  items: LibraryItemView[] | null = null;
  /** 窗口在整份排序里的起点 */
  start: number = 0;
  hasMore: boolean = false;
  failed: string | null = null;
  loading: boolean = false;
  private loadingPrev: boolean = false;
  private generation: number = 0;
  private fetcher: ((offset: number, limit: number) => Promise<LibraryItemView[]>) | null = null;

  constructor(pageSize: number) {
    this.pageSize = pageSize;
  }

  /** 换数据源（排序/筛选变化）：清空并从 offset 起载入第一页 */
  async reset(fetch: (offset: number, limit: number) => Promise<LibraryItemView[]>,
    offset: number): Promise<void> {
    this.fetcher = fetch;
    this.generation += 1;
    this.items = null;
    await this.jump(offset);
  }

  /** 窗口换成从 offset 开始的一页 */
  async jump(offset: number): Promise<void> {
    const fetch: ((offset: number, limit: number) => Promise<LibraryItemView[]>) | null = this.fetcher;
    if (fetch === null) {
      return;
    }
    this.generation += 1;
    const gen: number = this.generation;
    this.loading = true;
    try {
      const page: LibraryItemView[] = await fetch(offset, this.pageSize);
      if (gen !== this.generation) {
        return;
      }
      this.start = offset;
      this.items = page;
      this.hasMore = page.length >= this.pageSize;
      this.failed = null;
    } catch (error) {
      if (gen !== this.generation) {
        return;
      }
      if (this.items === null) {
        this.failed = error instanceof Error ? error.message : `${error}`;
      }
    } finally {
      if (gen === this.generation) {
        this.loading = false;
      }
    }
  }

  /** 墙尾追加一页 */
  async loadMore(): Promise<void> {
    const fetch: ((offset: number, limit: number) => Promise<LibraryItemView[]>) | null = this.fetcher;
    const current: LibraryItemView[] | null = this.items;
    if (fetch === null || !this.hasMore || this.loading || current === null) {
      return;
    }
    const gen: number = this.generation;
    this.loading = true;
    try {
      const page: LibraryItemView[] = await fetch(this.start + current.length, this.pageSize);
      if (gen !== this.generation) {
        return;
      }
      const seen: Set<number> = new Set<number>();
      for (const item of current) {
        seen.add(item.media_item_id);
      }
      const merged: LibraryItemView[] = current.slice();
      for (const item of page) {
        if (!seen.has(item.media_item_id)) {
          merged.push(item);
        }
      }
      this.items = merged;
      this.hasMore = page.length >= this.pageSize;
    } catch (error) {
      if (gen !== this.generation) {
        return;
      }
      this.hasMore = false;
    } finally {
      if (gen === this.generation) {
        this.loading = false;
      }
    }
  }

  /** 墙顶还有上文时补上一页（跳转之后仍然能往上滑） */
  async loadPrevious(): Promise<void> {
    const fetch: ((offset: number, limit: number) => Promise<LibraryItemView[]>) | null = this.fetcher;
    const current: LibraryItemView[] | null = this.items;
    if (fetch === null || this.start <= 0 || this.loadingPrev || current === null) {
      return;
    }
    const gen: number = this.generation;
    this.loadingPrev = true;
    try {
      const from: number = Math.max(0, this.start - this.pageSize);
      const page: LibraryItemView[] = await fetch(from, this.start - from);
      if (gen !== this.generation || page.length === 0) {
        return;
      }
      const seen: Set<number> = new Set<number>();
      for (const item of current) {
        seen.add(item.media_item_id);
      }
      const merged: LibraryItemView[] = [];
      for (const item of page) {
        if (!seen.has(item.media_item_id)) {
          merged.push(item);
        }
      }
      this.start -= page.length;
      this.items = merged.concat(current);
    } catch (error) {
      // 上一页拉不到就保持现状
    } finally {
      this.loadingPrev = false;
    }
  }

  /** 按已加载的条数整窗重拉并整体替换（轮询 / 返回对账），失败保留旧窗口 */
  async refresh(): Promise<void> {
    const fetch: ((offset: number, limit: number) => Promise<LibraryItemView[]>) | null = this.fetcher;
    const current: LibraryItemView[] | null = this.items;
    if (fetch === null || this.loading) {
      if (this.items === null && this.fetcher !== null && !this.loading) {
        await this.jump(this.start);
      }
      return;
    }
    if (current === null) {
      return;
    }
    const gen: number = this.generation;
    const count: number = Math.max(this.pageSize, current.length);
    const origin: number = this.start;
    try {
      const rows: LibraryItemView[] = [];
      let offset: number = origin;
      while (offset < origin + count) {
        const page: LibraryItemView[] = await fetch(offset, this.pageSize);
        for (const item of page) {
          rows.push(item);
        }
        if (page.length < this.pageSize) {
          break;
        }
        offset += this.pageSize;
      }
      if (gen !== this.generation || this.loading) {
        return;
      }
      if (rows.length === 0 && origin > 0) {
        await this.jump(0);
        return;
      }
      this.items = rows;
      this.hasMore = rows.length >= count;
    } catch (error) {
      // 整窗对账失败保留旧窗口
    }
  }
}

// MARK: - 排序菜单

/** 排序菜单（每档一项，当前档再点一次翻转方向）；宿主收到回调后自己改状态 */
@Component
export struct WallSortMenu {
  options: WallSortOption[] = [];
  sort: WallSortState = new WallSortState('default', false);
  onPick: (value: string) => void = () => {
  };
  onToggleDirection: () => void = () => {
  };

  private current(): WallSortOption | null {
    for (const option of this.options) {
      if (option.value === this.sort.sort) {
        return option;
      }
    }
    return this.options.length > 0 ? this.options[0] : null;
  }

  private sortDirection(): WallSortDirection | null {
    const current: WallSortOption | null = this.current();
    return current === null ? null : current.direction;
  }

  build() {
    Row({ space: 4 }) {
      Text(this.current() === null ? '排序' : (this.current() as WallSortOption).label)
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.text)
      if (this.sortDirection() !== null) {
        SymbolGlyph(this.sort.reversed === (this.sortDirection() as WallSortDirection).naturalAsc
          ? $r('sys.symbol.arrow_down') : $r('sys.symbol.arrow_up'))
          .fontSize(13)
          .fontWeight(600)
          .fontColor([Theme.text])
      }
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(12)
        .fontWeight(600)
        .fontColor([Theme.textMuted])
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(Theme.glassFill)
    .borderRadius(20)
    .border({ width: 1, color: Theme.line })
    .bindMenu(this.SortMenu())
  }

  @Builder
  SortMenu() {
    Menu() {
      ForEach(this.options, (option: WallSortOption) => {
        MenuItem({ content: option.value === this.sort.sort && option.direction !== null
          ? `${option.label} · ${option.direction.label(this.sort.reversed)}` : option.label })
          .onClick(() => {
            if (option.value === this.sort.sort && option.direction !== null) {
              this.onToggleDirection();
            } else {
              this.onPick(option.value);
            }
          })
      }, (option: WallSortOption) => option.value)
      if (this.sortDirection() !== null) {
        MenuItem({ content: `方向：${(this.sortDirection() as WallSortDirection).label(this.sort.reversed)}` })
          .onClick(() => {
            this.onToggleDirection();
          })
      }
    }
  }
}

// MARK: - A–Z 跳转条

/**
 * 海报墙右侧的 A–Z 跳转条（Web WallIndexBar）：按住上下滑动选字母，松手跳到该档第一格；
 * 库里没有的字母压暗；倒序（Z→A）时字母表跟着倒过来。
 */
@Component
export struct WallIndexBar {
  entries: LibraryIndexEntryView[] = [];
  reversed: boolean = false;
  /** 视口第一格所在的档（高亮） */
  active: string | null = null;
  onJump: (offset: number) => void = () => {
  };
  @State private preview: string | null = null;
  private letters: string[] = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
    'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '#'];
  private slotHeight: number = 16;

  private slots(): string[] {
    return this.reversed ? this.letters.slice().reverse() : this.letters;
  }

  /** 某字母档在不在库里（不在的压暗、不跳） */
  private entryOf(letter: string): LibraryIndexEntryView | null {
    for (const entry of this.entries) {
      if (entry.initial === letter) {
        return entry;
      }
    }
    return null;
  }

  private letterAt(y: number): string {
    const slots: string[] = this.slots();
    const index: number = Math.min(slots.length - 1, Math.max(0, Math.floor(y / this.slotHeight)));
    return slots[index];
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Column() {
        ForEach(this.slots(), (letter: string) => {
          Text(letter)
            .fontSize(10)
            .fontWeight(600)
            .fontColor(this.entryOf(letter) === null ? 'rgba(243, 245, 249, 0.18)'
              : this.preview === letter ? '#000000'
                : letter === this.active ? Theme.text : Theme.textMuted)
            .textAlign(TextAlign.Center)
            .width(18)
            .height(this.slotHeight)
            .backgroundColor(this.entryOf(letter) === null ? Color.Transparent
              : this.preview === letter ? Theme.accentStrong
                : letter === this.active ? 'rgba(238, 242, 248, 0.35)' : Color.Transparent)
            .borderRadius(4)
        }, (letter: string) => `${letter}-${this.preview === letter ? '1' : '0'}-${letter === this.active ? '1' : '0'}`)
      }
      .alignItems(HorizontalAlign.Center)
      .width(18)
      .height(this.slotHeight * this.letters.length)

      if (this.preview !== null) {
        Row({ space: 8 }) {
          Text(this.preview ?? '')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.text)
          Text(this.entryOf(this.preview ?? '') === null ? '无作品'
            : `${(this.entryOf(this.preview ?? '') as LibraryIndexEntryView).count} 部`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor('#171a23')
        .borderRadius(12)
        .border({ width: 1, color: Theme.lineStrong })
        .translate({ x: -96, y: this.previewY() })
      }
    }
    .alignContent(Alignment.Start)
    .width(18)
    .height(this.slotHeight * this.letters.length)
    .gesture(
      PanGesture({ fingers: 1, distance: 0 })
        .onActionUpdate((event: GestureEvent) => {
          if (event.fingerList.length > 0) {
            this.preview = this.letterAt(event.fingerList[0].localY);
          }
        })
        .onActionEnd(() => {
          const letter: string | null = this.preview;
          if (letter !== null) {
            const entry: LibraryIndexEntryView | null = this.entryOf(letter);
            if (entry !== null) {
              this.onJump(entry.offset);
            }
          }
          this.preview = null;
        })
    )
  }

  /** 气泡跟手：压着的字母在条里的位置 */
  private previewY(): number {
    const letter: string | null = this.preview;
    if (letter === null) {
      return 0;
    }
    const slots: string[] = this.slots();
    const index: number = slots.indexOf(letter);
    return index * this.slotHeight - 8;
  }
}

// MARK: - 库存条目格

/** 组件默认值用的空条目（字段齐全只为过类型检查，正常不会渲染出来） */
const EMPTY_ITEM: LibraryItemView = {
  media_item_id: 0,
  kind: 'movie',
  source: 'local',
  title: '',
  primary_aspect: 0.66,
  file_count: 0,
  total_size_bytes: 0,
  seasons: [],
  episode_count: 0,
  resolutions: [],
  missing_count: 0,
  missing_episode_count: 0,
  is_favorite: false,
  probe_pending_count: 0
};

/**
 * 库存条目 → 海报格（Web InventoryCell）：缺失提示、死条目置灰、后台处理中点亮、
 * 副行按需带评分；长按看库存概况与评分。
 */
@Component
export struct LibraryInventoryCell {
  item: LibraryItemView = EMPTY_ITEM;
  libraryId: number = 0;
  /** 宽版（16:9 缩略图区）时锁定 16:9 框 */
  frameAspect: number = Theme.posterAspect;
  /** 按评分排序 / 筛选时副行常显评分 */
  showRating: boolean = false;
  working: string | null = null;
  onOpen: (item: LibraryItemView) => void = () => {
  };

  private dead(): boolean {
    return this.item.file_count > 0 && this.item.missing_count >= this.item.file_count;
  }

  private ratingText(): string | null {
    const rating: number | null = this.item.rating ?? null;
    if (rating === null || rating <= 0) {
      return null;
    }
    return `★ ${rating.toFixed(1)}`;
  }

  private abnormalText(): string | null {
    if (this.dead()) {
      return '文件已全部缺失';
    }
    return this.item.missing_count > 0 ? `${this.item.missing_count} 个文件缺失` : null;
  }

  private posterUrl(): string {
    const origin: string = AppModel.shared.client !== null ? AppModel.shared.client.origin : '';
    return ImageUrls.resolve(origin, this.item.poster_url,
      ImageVariant.card(this.item.primary_aspect)) ?? '';
  }

  build() {
    Column() {
      LibraryPosterCell({
        title: this.item.title,
        year: this.item.year ?? null,
        extent: this.showRating ? this.ratingText() : null,
        url: this.posterUrl(),
        imageAspect: this.item.primary_aspect,
        frameAspect: this.frameAspect,
        favorite: this.item.is_favorite,
        dead: this.dead(),
        abnormal: this.abnormalText(),
        working: this.working,
        placeholderSymbol: LibraryKindMeta.symbol(this.item.kind)
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onOpen(this.item);
    })
    .bindContextMenu(this.InfoMenu(), ResponseType.LongPress)
  }

  /** 长按：剧集给库存概况；评分平时不显、这里给 */
  @Builder
  InfoMenu() {
    Menu() {
      if (this.item.kind === 'tv' && this.item.inventory_summary !== null && this.item.inventory_summary !== undefined) {
        MenuItem({ content: formatInventorySummary(this.item.inventory_summary) })
      }
      if (!this.showRating && this.ratingText() !== null) {
        MenuItem({ content: this.ratingText() ?? '' })
      }
    }
  }
}

/** 剧集库存概况（Web formatLibraryInventorySummary） */
export function formatInventorySummary(summary: LibraryInventorySummaryView): string {
  let episodes: string;
  if (summary.all_episodes_owned) {
    episodes = `全 ${summary.episode_count} 集`;
  } else if (summary.season_number !== null && summary.season_number !== undefined
    && summary.total_episode_count !== null && summary.total_episode_count !== undefined) {
    episodes = `${summary.episode_count}/${summary.total_episode_count} 集`;
  } else {
    episodes = `${summary.episode_count} 集`;
  }
  const season: number | null = summary.season_number ?? null;
  if (season !== null) {
    return `${season === 0 ? '特别篇' : `第 ${season} 季`} · ${episodes}`;
  }
  const seasons: string = summary.all_seasons_owned ? `全 ${summary.season_count} 季` : `共 ${summary.season_count} 季`;
  return `${seasons} · ${episodes}`;
}

/** 维度 → facet 里对应的候选表（取展示名 / 计数用） */
export function facetPool(dim: string, facets: LibraryFacetsView | null): FacetValueView[] {
  if (facets === null) {
    return [];
  }
  if (dim === 'genres') {
    return facets.genres;
  }
  if (dim === 'countries') {
    return facets.countries;
  }
  if (dim === 'decades') {
    return facets.decades;
  }
  if (dim === 'watch') {
    return facets.watch;
  }
  if (dim === 'rating_gte') {
    return facets.ratings;
  }
  if (dim === 'runtimes') {
    return facets.runtimes;
  }
  if (dim === 'languages') {
    return facets.languages;
  }
  if (dim === 'resolutions') {
    return facets.resolutions;
  }
  if (dim === 'hdr') {
    return facets.hdr;
  }
  if (dim === 'stock') {
    return facets.stock;
  }
  return [];
}

/** 取值 → 展示名：绝不把裸值印出来；查不到给省略号占位（展示名在路上）。分辨率、语言本身是人话直接印 */
export function facetLabel(dim: string, value: string, facets: LibraryFacetsView | null): string {
  const pool: FacetValueView[] = facetPool(dim, facets);
  for (const option of pool) {
    if (option.value === value) {
      return option.label;
    }
  }
  return dim === 'resolutions' || dim === 'languages' ? value : '…';
}
