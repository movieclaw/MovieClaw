import { Formatters } from '../common/Formatters';
import { TorrentAttrs, TorrentHit } from '../api/Models';

/**
 * 站点资源搜索结果的纯前端规则（对齐 iOS `TorrentSearchLogic.swift` / Web `components/search-results.tsx`）：
 * 排序、筛选、分面计数、作品分组与各种展示标签，全部是无副作用的纯函数。
 *
 * 筛选与排序都不重新发起搜索；流式期间新到的结果实时并入当前筛选/排序视图。
 */

/** 排序键：常规 4 键 + 智能 3 键（全集优先 / 画质优先 / 免费优先） */
export enum TorrentSortKey {
  seeders = 'seeders',
  time = 'time',
  size = 'size',
  snatched = 'snatched',
  complete = 'complete',
  quality = 'quality',
  free = 'free'
}

/** 菜单「常规」分区 */
export const REGULAR_SORT_KEYS: TorrentSortKey[] = [
  TorrentSortKey.seeders,
  TorrentSortKey.time,
  TorrentSortKey.size,
  TorrentSortKey.snatched
];

/** 智能排序键按结果集构成动态出现（见 smartSortKeys） */
export const SMART_SORT_KEYS: TorrentSortKey[] = [
  TorrentSortKey.complete,
  TorrentSortKey.quality,
  TorrentSortKey.free
];

/** 排序状态：点新键 = 选中并降序，点当前键 = 翻转方向（同 iOS TorrentSort.picking） */
export class TorrentSort {
  readonly key: TorrentSortKey;
  readonly descending: boolean;

  constructor(key: TorrentSortKey, descending: boolean) {
    this.key = key;
    this.descending = descending;
  }

  static default(): TorrentSort {
    return new TorrentSort(TorrentSortKey.seeders, true);
  }

  isDefault(): boolean {
    return this.key === TorrentSortKey.seeders && this.descending;
  }

  picking(key: TorrentSortKey): TorrentSort {
    return key === this.key
      ? new TorrentSort(key, !this.descending)
      : new TorrentSort(key, true);
  }
}

/** 结果视图：分组（按作品聚合，默认）/ 列表（平铺原始种子名）/ 图览（海报墙） */
export const TORRENT_VIEW_MODES: string[] = ['group', 'list', 'poster'];

/** 筛选维度（组内多选 = 或，组间 = 且） */
export enum TorrentFilterDim {
  resolution = 'resolution',
  site = 'site',
  year = 'year',
  season = 'season',
  episode = 'episode',
  source = 'source',
  platform = 'platform',
  codec = 'codec',
  hdr = 'hdr',
  audio = 'audio',
  subtitle = 'subtitle',
  group = 'group'
}

export const ALL_FILTER_DIMS: TorrentFilterDim[] = [
  TorrentFilterDim.resolution,
  TorrentFilterDim.site,
  TorrentFilterDim.year,
  TorrentFilterDim.season,
  TorrentFilterDim.episode,
  TorrentFilterDim.source,
  TorrentFilterDim.platform,
  TorrentFilterDim.codec,
  TorrentFilterDim.hdr,
  TorrentFilterDim.audio,
  TorrentFilterDim.subtitle,
  TorrentFilterDim.group
];

/** 分辨率以外的筛选维度（筛选弹层只统计这些） */
export const SHEET_FILTER_DIMS: TorrentFilterDim[] = [
  TorrentFilterDim.site,
  TorrentFilterDim.year,
  TorrentFilterDim.season,
  TorrentFilterDim.episode,
  TorrentFilterDim.source,
  TorrentFilterDim.platform,
  TorrentFilterDim.codec,
  TorrentFilterDim.hdr,
  TorrentFilterDim.audio,
  TorrentFilterDim.subtitle,
  TorrentFilterDim.group
];

/** 当前筛选：每个维度一组已选值；toggle/removeDim 返回新实例（@Local 靠换引用触发刷新） */
export class TorrentFilters {
  private readonly selected: Map<TorrentFilterDim, Set<string>> = new Map();

  values(dim: TorrentFilterDim): Set<string> {
    return this.selected.get(dim) ?? new Set<string>();
  }

  toggle(dim: TorrentFilterDim, value: string): TorrentFilters {
    const next = this.clone();
    const current = next.selected.get(dim) ?? new Set<string>();
    const set = new Set<string>();
    current.forEach((v: string) => {
      set.add(v);
    });
    if (set.has(value)) {
      set.delete(value);
    } else {
      set.add(value);
    }
    if (set.size === 0) {
      next.selected.delete(dim);
    } else {
      next.selected.set(dim, set);
    }
    return next;
  }

  removeDim(dim: TorrentFilterDim): TorrentFilters {
    const next = this.clone();
    next.selected.delete(dim);
    return next;
  }

  clear(): TorrentFilters {
    return new TorrentFilters();
  }

  /** 弹层维度的已选数（筛选键角标） */
  sheetCount(): number {
    let count = 0;
    for (const dim of SHEET_FILTER_DIMS) {
      count += this.values(dim).size;
    }
    return count;
  }

  isActive(): boolean {
    return this.values(TorrentFilterDim.resolution).size > 0 || this.sheetCount() > 0;
  }

  private clone(): TorrentFilters {
    const next = new TorrentFilters();
    this.selected.forEach((set: Set<string>, dim: TorrentFilterDim) => {
      const copy = new Set<string>();
      set.forEach((v: string) => {
        copy.add(v);
      });
      next.selected.set(dim, copy);
    });
    return next;
  }
}

/** 一个分面取值及「选中它之后会看到的条数」 */
export class TorrentFacetValue {
  readonly value: string;
  readonly count: number;

  constructor(value: string, count: number) {
    this.value = value;
    this.count = count;
  }
}

/** 作品分组的组头元数据 */
export class TorrentEntity {
  readonly key: string;
  nameZh: string = '';
  nameEn: string = '';
  year: number | null = null;
  mediaType: string = '';
  contentType: string = '';

  constructor(key: string) {
    this.key = key;
  }
}

/** 一个作品分组（key + 组内种子） */
export class TorrentBucket {
  readonly key: string;
  rows: TorrentHit[] = [];

  constructor(key: string) {
    this.key = key;
  }
}

/** 解析出的片名：中文主名 + 外文副名 */
export class ParsedName {
  readonly primary: string;
  readonly secondary: string | null;

  constructor(primary: string, secondary: string | null) {
    this.primary = primary;
    this.secondary = secondary;
  }
}

/** 图览海报左下角的季集 chip */
export class SeasonEpisodeChip {
  readonly text: string;
  readonly pack: boolean;

  constructor(text: string, pack: boolean) {
    this.text = text;
    this.pack = pack;
  }
}

/** 促销角标种类：免费 / 折扣 / 上传倍率 / H&R */
export enum PromoKind {
  free = 'free',
  discount = 'discount',
  upload = 'upload',
  hitAndRun = 'hitAndRun'
}

export class Promo {
  readonly kind: PromoKind;
  readonly text: string;

  constructor(kind: PromoKind, text: string) {
    this.kind = kind;
    this.text = text;
  }
}

/** 属性徽标的配色档 */
export enum AttrTone {
  plain = 'plain',
  season = 'season',
  content = 'content',
  remux = 'remux',
  hdr = 'hdr',
  subtitle = 'subtitle',
  audio = 'audio',
  group = 'group',
  platform = 'platform'
}

export class AttrBadge {
  readonly text: string;
  readonly tone: AttrTone;

  constructor(text: string, tone: AttrTone) {
    this.text = text;
    this.tone = tone;
  }
}

/** 排序装饰：稳定排序用（原序号 + 结果 + 排序向量） */
class SortDecorated {
  readonly index: number;
  readonly hit: TorrentHit;
  readonly vector: number[];

  constructor(index: number, hit: TorrentHit, vector: number[]) {
    this.index = index;
    this.hit = hit;
    this.vector = vector;
  }
}

export class TorrentSearchLogic {
  /** 未识别桶的聚合键（解析不出片名的种子都归这里，按原始名平铺，固定沉底） */
  static readonly UNPARSED_KEY: string = '__unparsed__';

  // MARK: 排序

  /** 剧集完整度层级：4=全集、3=整季包、2=多集、1=单集、0=无季集信息 */
  static completenessTier(a: TorrentAttrs | null): number {
    if (a === null) {
      return 0;
    }
    if (a.complete === true) {
      return 4;
    }
    if (a.seasons.length > 0 && a.episodes.length === 0) {
      return 3;
    }
    if (a.episodes.length > 1) {
      return 2;
    }
    if (a.episodes.length === 1) {
      return 1;
    }
    return 0;
  }

  /** 字符串开头的数字（"2160p" → 2160；解析不出 0） */
  static leadingNumber(s: string): number {
    let end = 0;
    while (end < s.length) {
      const code = s.charCodeAt(end);
      if (code < 48 || code > 57) {
        break;
      }
      end += 1;
    }
    if (end === 0) {
      return 0;
    }
    const n = Number(s.substring(0, end));
    return Number.isFinite(n) ? n : 0;
  }

  /** 片源档位（画质排序第二级） */
  private static readonly SOURCE_RANK: Map<string, number> = TorrentSearchLogic.rankMap([
    ['UHD Blu-ray', '7'], ['Blu-ray', '6'], ['WEB-DL', '5'], ['BDRip', '4'], ['WEBRip', '3'],
    ['HD-DVD', '3'], ['HDTV', '2'], ['HDTVRip', '2'], ['HDRip', '2'], ['TVRip', '1'],
    ['DVDRip', '1'], ['DVD', '1']
  ]);

  static uploadTimestamp(hit: TorrentHit): number {
    const raw = hit.upload_time ?? null;
    if (raw === null) {
      return Number.NEGATIVE_INFINITY;
    }
    return Formatters.date(raw) ?? Number.NEGATIVE_INFINITY;
  }

  /** 排序向量：逐级字典序比较；智能键是「主指标 → 次指标 → 做种数决胜」 */
  static sortVector(hit: TorrentHit, key: TorrentSortKey): number[] {
    const a = hit.attrs ?? null;
    switch (key) {
      case TorrentSortKey.time:
        return [TorrentSearchLogic.uploadTimestamp(hit)];
      case TorrentSortKey.size:
        return [hit.size_bytes];
      case TorrentSortKey.snatched:
        return [hit.snatched];
      case TorrentSortKey.complete:
        return [
          TorrentSearchLogic.completenessTier(a),
          a !== null ? a.seasons.length : 0,
          hit.seeders
        ];
      case TorrentSortKey.quality: {
        const resolution = a !== null ? TorrentSearchLogic.leadingNumber(a.resolution ?? '') : 0;
        const sourceRank = a !== null
          ? (TorrentSearchLogic.SOURCE_RANK.get(a.media_source ?? '') ?? 0)
          : 0;
        const remuxBonus = a !== null && a.remux ? 0.5 : 0;
        return [resolution, sourceRank + remuxBonus, hit.seeders];
      }
      case TorrentSortKey.free: {
        const promo = hit.free || hit.download_volume_factor === 0
          ? 2
          : (hit.download_volume_factor < 1 ? 1 : 0);
        return [promo, hit.hit_and_run === false ? 1 : 0, hit.seeders];
      }
      default:
        return [hit.seeders];
    }
  }

  static sorted(hits: TorrentHit[], sort: TorrentSort): TorrentHit[] {
    const decorated: SortDecorated[] = [];
    for (let i = 0; i < hits.length; i++) {
      decorated.push(new SortDecorated(i, hits[i], TorrentSearchLogic.sortVector(hits[i], sort.key)));
    }
    decorated.sort((x: SortDecorated, y: SortDecorated): number => {
      const len = x.vector.length < y.vector.length ? x.vector.length : y.vector.length;
      for (let i = 0; i < len; i++) {
        const xv = x.vector[i];
        const yv = y.vector[i];
        if (xv !== yv) {
          // 无发布时间（-∞）升降序都垫底
          if (xv === Number.NEGATIVE_INFINITY) {
            return 1;
          }
          if (yv === Number.NEGATIVE_INFINITY) {
            return -1;
          }
          return sort.descending ? yv - xv : xv - yv;
        }
      }
      return x.index - y.index;
    });
    const out: TorrentHit[] = [];
    for (const d of decorated) {
      out.push(d.hit);
    }
    return out;
  }

  /** 智能排序键按结果集构成动态出现：剧集为主给「全集优先」，电影为主给「画质优先」，「免费优先」常驻 */
  static smartSortKeys(hits: TorrentHit[]): TorrentSortKey[] {
    let tv = 0;
    let movie = 0;
    for (const hit of hits) {
      const a = hit.attrs ?? null;
      const type = a !== null ? (a.media_type ?? null) : null;
      if (type === 'tv') {
        tv += 1;
      } else if (type === 'movie') {
        movie += 1;
      }
    }
    const typed = tv + movie;
    const keys: TorrentSortKey[] = [];
    if (typed > 0 && tv >= typed / 2) {
      keys.push(TorrentSortKey.complete);
    }
    if (typed > 0 && movie > typed / 2) {
      keys.push(TorrentSortKey.quality);
    }
    keys.push(TorrentSortKey.free);
    return keys;
  }

  // MARK: 筛选

  /** 单维度通过判定（维度未激活即通过）；过滤与分面计数共用 */
  static passes(dim: TorrentFilterDim, hit: TorrentHit, f: TorrentFilters): boolean {
    const selected = f.values(dim);
    if (selected.size === 0) {
      return true;
    }
    const a = hit.attrs ?? null;
    switch (dim) {
      case TorrentFilterDim.resolution: {
        const r = a !== null ? (a.resolution ?? null) : null;
        return r !== null && selected.has(r);
      }
      case TorrentFilterDim.site:
        return selected.has(hit.site_id);
      case TorrentFilterDim.year: {
        const year = a !== null ? (a.year ?? null) : null;
        return year !== null && selected.has(`${year}`);
      }
      case TorrentFilterDim.season: {
        if (a === null) {
          return false;
        }
        for (const s of a.seasons) {
          if (selected.has(`${s}`)) {
            return true;
          }
        }
        return false;
      }
      case TorrentFilterDim.episode: {
        if (a === null) {
          return false;
        }
        for (const e of a.episodes) {
          if (selected.has(`${e}`)) {
            return true;
          }
        }
        // 全集包视为包含任意一集
        return a.complete === true;
      }
      case TorrentFilterDim.source: {
        const source = a !== null ? (a.media_source ?? null) : null;
        const bySource = source !== null && selected.has(source);
        return bySource || (selected.has('Remux') && a !== null && a.remux);
      }
      case TorrentFilterDim.platform: {
        if (a === null) {
          return false;
        }
        for (const v of a.platforms) {
          if (selected.has(v)) {
            return true;
          }
        }
        return false;
      }
      case TorrentFilterDim.codec: {
        const codec = a !== null ? (a.video_codec ?? null) : null;
        return codec !== null && selected.has(codec);
      }
      case TorrentFilterDim.hdr: {
        if (a === null) {
          return false;
        }
        for (const v of a.hdr) {
          if (selected.has(v)) {
            return true;
          }
        }
        return false;
      }
      case TorrentFilterDim.audio: {
        if (a === null) {
          return false;
        }
        for (const v of a.audio) {
          if (selected.has(v)) {
            return true;
          }
        }
        return false;
      }
      case TorrentFilterDim.subtitle: {
        if (a === null) {
          return false;
        }
        for (const lang of a.subtitle_languages) {
          if (selected.has(lang) || TorrentSearchLogic.hasPrefixIn(lang, selected)) {
            return true;
          }
        }
        return false;
      }
      case TorrentFilterDim.group: {
        const group = a !== null ? (a.release_group ?? null) : null;
        return group !== null && selected.has(group);
      }
      default:
        return true;
    }
  }

  /** BCP 47 前缀语义：勾 zh 命中 zh / zh-Hans / zh-Hant；勾 zh-Hans 只命中简体 */
  private static hasPrefixIn(value: string, selected: Set<string>): boolean {
    let found = false;
    selected.forEach((sel: string) => {
      if (value.startsWith(`${sel}-`)) {
        found = true;
      }
    });
    return found;
  }

  static matches(hit: TorrentHit, f: TorrentFilters): boolean {
    for (const dim of ALL_FILTER_DIMS) {
      if (!TorrentSearchLogic.passes(dim, hit, f)) {
        return false;
      }
    }
    return true;
  }

  private static bump(maps: Map<TorrentFilterDim, Map<string, number>>,
    dim: TorrentFilterDim, value: string): void {
    let m = maps.get(dim) ?? null;
    if (m === null) {
      m = new Map<string, number>();
      maps.set(dim, m);
    }
    m.set(value, (m.get(value) ?? 0) + 1);
  }

  private static wantOnly(only: TorrentFilterDim | null, dim: TorrentFilterDim): boolean {
    return only === null || only === dim;
  }

  /**
   * 遍历结果集统计各维度计数。传 filters 时做「自排除」计数：某条结果只有通过了**其他所有**维度，
   * 才计入某维度的数字——每个标签上的数字始终等于「选中它之后会看到的条数」。
   */
  static facetCounts(hits: TorrentHit[],
    filters: TorrentFilters | null): Map<TorrentFilterDim, Map<string, number>> {
    const maps = new Map<TorrentFilterDim, Map<string, number>>();
    for (const hit of hits) {
      let only: TorrentFilterDim | null = null;
      if (filters !== null) {
        let failed = 0;
        for (const dim of ALL_FILTER_DIMS) {
          if (!TorrentSearchLogic.passes(dim, hit, filters)) {
            failed += 1;
            only = dim;
            if (failed > 1) {
              break;
            }
          }
        }
        if (failed > 1) {
          continue;
        }
        if (failed === 0) {
          only = null;
        }
      }
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.site)) {
        TorrentSearchLogic.bump(maps, TorrentFilterDim.site, hit.site_id);
      }
      const a = hit.attrs ?? null;
      if (a === null) {
        continue;
      }
      const year = a.year ?? null;
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.year) && year !== null) {
        TorrentSearchLogic.bump(maps, TorrentFilterDim.year, `${year}`);
      }
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.season)) {
        for (const s of a.seasons) {
          TorrentSearchLogic.bump(maps, TorrentFilterDim.season, `${s}`);
        }
      }
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.episode)) {
        for (const e of a.episodes) {
          TorrentSearchLogic.bump(maps, TorrentFilterDim.episode, `${e}`);
        }
      }
      const resolution = a.resolution ?? null;
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.resolution) && resolution !== null) {
        TorrentSearchLogic.bump(maps, TorrentFilterDim.resolution, resolution);
      }
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.source)) {
        const source = a.media_source ?? null;
        if (source !== null) {
          TorrentSearchLogic.bump(maps, TorrentFilterDim.source, source);
        }
        if (a.remux) {
          TorrentSearchLogic.bump(maps, TorrentFilterDim.source, 'Remux');
        }
      }
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.platform)) {
        for (const v of a.platforms) {
          TorrentSearchLogic.bump(maps, TorrentFilterDim.platform, v);
        }
      }
      const codec = a.video_codec ?? null;
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.codec) && codec !== null) {
        TorrentSearchLogic.bump(maps, TorrentFilterDim.codec, codec);
      }
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.hdr)) {
        for (const v of a.hdr) {
          TorrentSearchLogic.bump(maps, TorrentFilterDim.hdr, v);
        }
      }
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.audio)) {
        for (const v of a.audio) {
          TorrentSearchLogic.bump(maps, TorrentFilterDim.audio, v);
        }
      }
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.subtitle)) {
        // 「中文（不限简繁）」的计数涵盖声明了 zh-Hans / zh-Hant 的资源
        const keys = new Set<string>();
        a.subtitle_languages.forEach((lang: string) => {
          keys.add(lang);
        });
        a.subtitle_languages.forEach((lang: string) => {
          if (lang.startsWith('zh-')) {
            keys.add('zh');
          }
        });
        keys.forEach((v: string) => {
          TorrentSearchLogic.bump(maps, TorrentFilterDim.subtitle, v);
        });
      }
      const group = a.release_group ?? null;
      if (TorrentSearchLogic.wantOnly(only, TorrentFilterDim.group) && group !== null) {
        TorrentSearchLogic.bump(maps, TorrentFilterDim.group, group);
      }
    }
    return maps;
  }

  /** 全量计数定「有哪些 chip、按什么顺序排」（筛选变化时 chip 不增删、不换位），数字随筛选变化 */
  static facets(hits: TorrentHit[],
    filters: TorrentFilters): Map<TorrentFilterDim, TorrentFacetValue[]> {
    const full = TorrentSearchLogic.facetCounts(hits, null);
    const counts = filters.isActive() ? TorrentSearchLogic.facetCounts(hits, filters) : full;
    const result = new Map<TorrentFilterDim, TorrentFacetValue[]>();
    for (const dim of ALL_FILTER_DIMS) {
      const entries = full.get(dim) ?? new Map<string, number>();
      const keys: string[] = [];
      entries.forEach((_count: number, value: string) => {
        keys.push(value);
      });
      if (dim === TorrentFilterDim.year) {
        keys.sort((a: string, b: string): number => (Number(b) || 0) - (Number(a) || 0));
      } else if (dim === TorrentFilterDim.season || dim === TorrentFilterDim.episode) {
        keys.sort((a: string, b: string): number => (Number(a) || 0) - (Number(b) || 0));
      } else if (dim !== TorrentFilterDim.site) {
        keys.sort((a: string, b: string): number => {
          const ca = entries.get(a) ?? 0;
          const cb = entries.get(b) ?? 0;
          if (ca !== cb) {
            return cb - ca;
          }
          return a < b ? -1 : (a > b ? 1 : 0);
        });
        const cap = dim === TorrentFilterDim.resolution ? 8 : 50;
        while (keys.length > cap) {
          keys.pop();
        }
      }
      const dimCounts = counts.get(dim) ?? null;
      const values: TorrentFacetValue[] = [];
      for (const value of keys) {
        values.push(new TorrentFacetValue(value, dimCounts !== null ? (dimCounts.get(value) ?? 0) : 0));
      }
      result.set(dim, values);
    }
    return result;
  }

  // MARK: 作品分组

  /** 作品聚合键：解析主名（中文优先）定作品；电影按年份区分，剧集不按年拆 */
  static entityKey(hit: TorrentHit): string {
    const a = hit.attrs ?? null;
    const title = a !== null
      ? (a.titles_zh.length > 0 ? a.titles_zh[0] : (a.titles_en.length > 0 ? a.titles_en[0] : null))
      : null;
    if (title === null) {
      return TorrentSearchLogic.UNPARSED_KEY;
    }
    const type = a !== null ? (a.media_type ?? '?') : '?';
    if (type === 'tv') {
      return `tv|${title}`;
    }
    const year = a !== null ? (a.year ?? null) : null;
    return `${type}|${title}|${year !== null ? `${year}` : '?'}`;
  }

  static entities(hits: TorrentHit[]): Map<string, TorrentEntity> {
    const groups = new Map<string, TorrentEntity>();
    for (const hit of hits) {
      const key = TorrentSearchLogic.entityKey(hit);
      if (key === TorrentSearchLogic.UNPARSED_KEY) {
        continue;
      }
      let g = groups.get(key) ?? null;
      if (g === null) {
        g = new TorrentEntity(key);
        groups.set(key, g);
      }
      const a = hit.attrs ?? null;
      if (a !== null) {
        if (g.nameZh.length === 0 && a.titles_zh.length > 0) {
          g.nameZh = a.titles_zh[0];
        }
        if (g.nameEn.length === 0 && a.titles_en.length > 0) {
          g.nameEn = a.titles_en[0];
        }
        if (g.year === null) {
          g.year = a.year ?? null;
        }
        if (g.mediaType.length === 0) {
          g.mediaType = a.media_type ?? '';
        }
        if (g.contentType.length === 0) {
          g.contentType = a.content_type ?? '';
        }
      }
    }
    return groups;
  }

  /** 分组顺序 = 按当前排序遍历时各作品的首次出现序；未识别桶沉底 */
  static buckets(sortedHits: TorrentHit[]): TorrentBucket[] {
    const buckets: TorrentBucket[] = [];
    const index = new Map<string, number>();
    for (const hit of sortedHits) {
      const key = TorrentSearchLogic.entityKey(hit);
      const at = index.get(key) ?? null;
      if (at !== null) {
        buckets[at].rows.push(hit);
      } else {
        index.set(key, buckets.length);
        const bucket = new TorrentBucket(key);
        bucket.rows.push(hit);
        buckets.push(bucket);
      }
    }
    const unparsedAt = index.get(TorrentSearchLogic.UNPARSED_KEY) ?? null;
    if (unparsedAt !== null && unparsedAt !== buckets.length - 1) {
      const removed = buckets.splice(unparsedAt, 1)[0];
      buckets.push(removed);
    }
    return buckets;
  }

  static maxResolution(rows: TorrentHit[]): string | null {
    let best: string | null = null;
    let bestNum = -1;
    for (const hit of rows) {
      const a = hit.attrs ?? null;
      const r = a !== null ? (a.resolution ?? null) : null;
      if (r === null || r.length === 0) {
        continue;
      }
      const n = TorrentSearchLogic.leadingNumber(r);
      if (best === null || n > bestNum) {
        best = r;
        bestNum = n;
      }
    }
    return best;
  }

  // MARK: 展示标签

  static readonly MEDIA_TYPE_LABELS: Map<string, string> = TorrentSearchLogic.stringMap([
    ['movie', '电影'],
    ['tv', '剧集']
  ]);

  static readonly CONTENT_TYPE_LABELS: Map<string, string> = TorrentSearchLogic.stringMap([
    ['anime', '动漫'],
    ['documentary', '纪录片'],
    ['variety', '综艺'],
    ['music', '音乐']
  ]);

  private static readonly SUBTITLE_LANGUAGE_LABELS: Map<string, string> = TorrentSearchLogic.stringMap([
    ['zh', '中文字幕（未标简繁）'], ['zh-Hans', '简体中文字幕'], ['zh-Hant', '繁体中文字幕'],
    ['en', '英文字幕'], ['ja', '日文字幕'], ['ko', '韩文字幕'], ['yue', '粤语字幕']
  ]);

  static subtitleLanguageLabel(value: string): string {
    return TorrentSearchLogic.SUBTITLE_LANGUAGE_LABELS.get(value) ?? value;
  }

  private static readonly PLATFORM_LABELS: Map<string, string> = TorrentSearchLogic.stringMap([
    ['netflix', 'Netflix'], ['amazon', 'Prime Video'], ['disney_plus', 'Disney+'],
    ['hbo_max', 'HBO Max'], ['hulu', 'Hulu'], ['apple_tv_plus', 'Apple TV+'],
    ['paramount_plus', 'Paramount+'], ['peacock', 'Peacock'], ['showtime', 'Showtime'],
    ['starz', 'Starz'], ['discovery_plus', 'Discovery+'], ['crave', 'Crave'], ['stan', 'Stan'],
    ['roku', 'Roku'], ['google_tv', 'Google TV'], ['itunes', 'iTunes'],
    ['sony_core', 'Sony Pictures Core'], ['criterion', 'Criterion'], ['iqiyi', '爱奇艺'],
    ['wetv', '腾讯视频'], ['youku', '优酷'], ['mangotv', '芒果 TV'], ['bilibili', '哔哩哔哩'],
    ['viu', 'Viu'], ['nowplayer', 'Now player'], ['mytv_super', 'myTV SUPER'],
    ['hami_video', 'Hami Video'], ['line_tv', 'LINE TV'], ['kktv', 'KKTV'], ['tving', 'TVING'],
    ['wavve', 'Wavve'], ['coupang_play', 'Coupang Play'], ['kocowa', 'KOCOWA'], ['viki', 'Viki'],
    ['unext', 'U-NEXT'], ['tver', 'TVer'], ['fod', 'FOD'], ['dmm_tv', 'DMM TV'],
    ['hotstar', 'Hotstar'], ['crunchyroll', 'Crunchyroll'], ['hidive', 'HIDIVE'],
    ['abema', 'ABEMA'], ['adn', 'ADN'], ['funimation', 'Funimation'], ['vrv', 'VRV'],
    ['wakanim', 'Wakanim'], ['b_global', 'B-Global']
  ]);

  static platformLabel(id: string): string {
    return TorrentSearchLogic.PLATFORM_LABELS.get(id) ?? id;
  }

  /** 分面值的展示文案 */
  static facetLabel(dim: TorrentFilterDim, value: string, siteName: (id: string) => string): string {
    switch (dim) {
      case TorrentFilterDim.site:
        return siteName(value);
      case TorrentFilterDim.season:
        return `第${value}季`;
      case TorrentFilterDim.episode:
        return `第${value}集`;
      case TorrentFilterDim.subtitle:
        return TorrentSearchLogic.subtitleLanguageLabel(value);
      case TorrentFilterDim.platform:
        return TorrentSearchLogic.platformLabel(value);
      default:
        return value;
    }
  }

  private static readonly SUB_LANG_SHORT: Map<string, string> = TorrentSearchLogic.stringMap([
    ['zh-Hans', '简'], ['zh-Hant', '繁'], ['zh', '中'], ['en', '英'], ['ja', '日'],
    ['ko', '韩'], ['yue', '粤']
  ]);

  private static readonly AUDIO_LANG_SHORT: Map<string, string> = TorrentSearchLogic.stringMap([
    ['cmn', '国'], ['yue', '粤'], ['en', '英'], ['ja', '日'], ['ko', '韩']
  ]);

  /** 「字幕 简·繁·英［·硬］」；仅泛称时「中字」；无声明 null */
  static compactSubtitleBadge(a: TorrentAttrs): string | null {
    if (a.subtitle_languages.length === 0) {
      return null;
    }
    let hasZhVariant = false;
    for (const lang of a.subtitle_languages) {
      if (lang.startsWith('zh-')) {
        hasZhVariant = true;
        break;
      }
    }
    let langs = a.subtitle_languages.slice();
    if (hasZhVariant) {
      langs = langs.filter((lang: string): boolean => lang !== 'zh');
    }
    const hard = a.subtitle_carriers.indexOf('hardcoded') >= 0 ? '·硬' : '';
    if (langs.length === 1 && langs[0] === 'zh') {
      return `中字${hard}`;
    }
    const parts: string[] = [];
    for (const lang of langs) {
      parts.push(TorrentSearchLogic.SUB_LANG_SHORT.get(lang) ?? lang);
    }
    return `字幕 ${parts.join('·')}${hard}`;
  }

  static compactAudioBadge(a: TorrentAttrs): string | null {
    if (a.audio_languages.length === 0) {
      return null;
    }
    const parts: string[] = [];
    for (const lang of a.audio_languages) {
      parts.push(TorrentSearchLogic.AUDIO_LANG_SHORT.get(lang) ?? lang);
    }
    return `音轨 ${parts.join('·')}`;
  }

  /** S01E01-E06 / S01-S03 形式的季集标签 */
  private static numRange(nums: number[], prefix: string): string {
    if (nums.length === 0) {
      return '';
    }
    if (nums.length === 1) {
      return `${prefix}${Formatters.pad2(nums[0])}`;
    }
    return `${prefix}${Formatters.pad2(nums[0])}-${prefix}${Formatters.pad2(nums[nums.length - 1])}`;
  }

  static seasonEpLabel(a: TorrentAttrs): string | null {
    const parts: string[] = [];
    if (a.seasons.length === 1 && a.episodes.length > 0) {
      parts.push(`S${Formatters.pad2(a.seasons[0])}${TorrentSearchLogic.numRange(a.episodes, 'E')}`);
    } else {
      if (a.seasons.length > 0) {
        parts.push(TorrentSearchLogic.numRange(a.seasons, 'S'));
      }
      if (a.episodes.length > 0 && a.complete !== true) {
        parts.push(TorrentSearchLogic.numRange(a.episodes, 'E'));
      }
    }
    return parts.length === 0 ? null : parts.join(' ');
  }

  static completeLabel(a: TorrentAttrs | null): string | null {
    if (a === null || a.complete !== true) {
      return null;
    }
    const total = a.episodes_total ?? null;
    return total !== null ? `全${total}集` : '全集';
  }

  /** 连续数字用区间（1-6），不连续用顿号（1、3） */
  static formatNumList(nums: number[]): string {
    const sorted = nums.slice().sort((a: number, b: number): number => a - b);
    if (sorted.length === 0) {
      return '';
    }
    let contiguous = true;
    for (let i = 1; i < sorted.length; i++) {
      if (sorted[i] !== sorted[i - 1] + 1) {
        contiguous = false;
        break;
      }
    }
    if (sorted.length > 1 && contiguous) {
      return `${sorted[0]}-${sorted[sorted.length - 1]}`;
    }
    const parts: string[] = [];
    for (const n of sorted) {
      parts.push(`${n}`);
    }
    return parts.join('、');
  }

  /** 图览海报左下角的季集 chip；pack = 全集 / 整季包（醒目底色） */
  static seasonEpisodeChip(a: TorrentAttrs | null): SeasonEpisodeChip | null {
    if (a === null || a.media_type === 'movie') {
      return null;
    }
    const season = a.seasons.length > 0 ? `第${TorrentSearchLogic.formatNumList(a.seasons)}季` : null;
    const complete = TorrentSearchLogic.completeLabel(a);
    const episode = complete !== null
      ? complete
      : (a.episodes.length > 0 ? `第${TorrentSearchLogic.formatNumList(a.episodes)}集` : null);
    if (season === null && episode === null) {
      return null;
    }
    const pack = a.complete === true || (season !== null && a.episodes.length === 0);
    const parts: string[] = [];
    if (season !== null) {
      parts.push(season);
    }
    if (episode !== null) {
      parts.push(episode);
    }
    return new SeasonEpisodeChip(parts.join(' · '), pack);
  }

  /** 分组视图组内行：用规格摘要代替重复的片名 */
  static specSummary(a: TorrentAttrs): string | null {
    const parts: string[] = [];
    const se = TorrentSearchLogic.seasonEpLabel(a);
    if (se !== null) {
      parts.push(se);
    }
    const resolution = a.resolution ?? null;
    if (resolution !== null) {
      parts.push(resolution);
    }
    for (const p of a.platforms) {
      parts.push(TorrentSearchLogic.platformLabel(p));
    }
    const source = a.media_source ?? null;
    if (source !== null) {
      parts.push(source);
    }
    if (a.remux) {
      parts.push('Remux');
    }
    const codec = a.video_codec ?? null;
    if (codec !== null) {
      parts.push(codec);
    }
    for (const h of a.hdr) {
      parts.push(h);
    }
    const sub = TorrentSearchLogic.compactSubtitleBadge(a);
    if (sub !== null) {
      parts.push(sub);
    }
    const aud = TorrentSearchLogic.compactAudioBadge(a);
    if (aud !== null) {
      parts.push(aud);
    }
    for (const v of a.audio.slice(0, 2)) {
      parts.push(v);
    }
    const group = a.release_group ?? null;
    if (group !== null) {
      parts.push(group);
    }
    return parts.length === 0 ? null : parts.join(' · ');
  }

  /** 解析片名：中文主名 + 外文副名；解析不出返回 null（回退原始种子名） */
  static parsedName(hit: TorrentHit): ParsedName | null {
    const a = hit.attrs ?? null;
    if (a === null) {
      return null;
    }
    if (a.titles_zh.length > 0) {
      return new ParsedName(a.titles_zh[0], a.titles_en.length > 0 ? a.titles_en[0] : null);
    }
    if (a.titles_en.length > 0) {
      return new ParsedName(a.titles_en[0], null);
    }
    return null;
  }

  /** 促销角标：免费 / 折扣 / 上传倍率 / H&R */
  static promos(hit: TorrentHit): Promo[] {
    const result: Promo[] = [];
    if (hit.free || hit.download_volume_factor === 0) {
      result.push(new Promo(PromoKind.free, '免费'));
    } else if (hit.download_volume_factor < 1) {
      result.push(new Promo(PromoKind.discount, `${Math.round(hit.download_volume_factor * 100)}%`));
    }
    if (hit.upload_volume_factor > 1) {
      const factor = hit.upload_volume_factor;
      const text = factor === Math.round(factor) ? `${Math.round(factor)}` : `${factor}`;
      result.push(new Promo(PromoKind.upload, `${text}× 上传`));
    }
    if (hit.hit_and_run === true) {
      result.push(new Promo(PromoKind.hitAndRun, 'H&R'));
    }
    return result;
  }

  /** 属性徽标（最多展示 4 个，其余折叠成 +N） */
  static attrBadges(a: TorrentAttrs): AttrBadge[] {
    const chips: AttrBadge[] = [];
    const se = TorrentSearchLogic.seasonEpLabel(a);
    if (se !== null) {
      chips.push(new AttrBadge(se, AttrTone.season));
    }
    const contentType = a.content_type ?? null;
    if (contentType !== null) {
      const label = TorrentSearchLogic.CONTENT_TYPE_LABELS.get(contentType) ?? null;
      if (label !== null) {
        chips.push(new AttrBadge(label, AttrTone.content));
      }
    }
    const resolution = a.resolution ?? null;
    if (resolution !== null) {
      chips.push(new AttrBadge(resolution, AttrTone.plain));
    }
    if (a.remux) {
      chips.push(new AttrBadge('Remux', AttrTone.remux));
    }
    for (const v of a.hdr) {
      chips.push(new AttrBadge(v, AttrTone.hdr));
    }
    const sub = TorrentSearchLogic.compactSubtitleBadge(a);
    if (sub !== null) {
      chips.push(new AttrBadge(sub, AttrTone.subtitle));
    }
    const aud = TorrentSearchLogic.compactAudioBadge(a);
    if (aud !== null) {
      chips.push(new AttrBadge(aud, AttrTone.audio));
    }
    const group = a.release_group ?? null;
    if (group !== null) {
      chips.push(new AttrBadge(group, AttrTone.group));
    }
    for (const p of a.platforms) {
      chips.push(new AttrBadge(TorrentSearchLogic.platformLabel(p), AttrTone.platform));
    }
    const source = a.media_source ?? null;
    if (source !== null) {
      chips.push(new AttrBadge(source, AttrTone.plain));
    }
    const codec = a.video_codec ?? null;
    if (codec !== null) {
      chips.push(new AttrBadge(codec, AttrTone.plain));
    }
    for (const v of a.audio.slice(0, 2)) {
      chips.push(new AttrBadge(v, AttrTone.plain));
    }
    return chips;
  }

  /** 体积：站点给的字符串优先，否则按字节换算 */
  static sizeText(hit: TorrentHit): string {
    const size = hit.size ?? null;
    if (size !== null && size.length > 0) {
      return size;
    }
    if (hit.size_bytes <= 0) {
      return '';
    }
    return Formatters.bytes(hit.size_bytes);
  }

  // MARK: 文案

  static sortKeyLabel(key: string): string {
    switch (key) {
      case 'time':
        return '发布时间';
      case 'size':
        return '体积';
      case 'snatched':
        return '完成数';
      case 'complete':
        return '全集优先';
      case 'quality':
        return '画质优先';
      case 'free':
        return '免费优先';
      default:
        return '做种数';
    }
  }

  static sortKeyOf(raw: string): TorrentSortKey {
    switch (raw) {
      case 'time':
        return TorrentSortKey.time;
      case 'size':
        return TorrentSortKey.size;
      case 'snatched':
        return TorrentSortKey.snatched;
      case 'complete':
        return TorrentSortKey.complete;
      case 'quality':
        return TorrentSortKey.quality;
      case 'free':
        return TorrentSortKey.free;
      default:
        return TorrentSortKey.seeders;
    }
  }

  static dimTitle(dim: TorrentFilterDim): string {
    switch (dim) {
      case TorrentFilterDim.site:
        return '站点';
      case TorrentFilterDim.year:
        return '年份';
      case TorrentFilterDim.season:
        return '季';
      case TorrentFilterDim.episode:
        return '集';
      case TorrentFilterDim.source:
        return '片源';
      case TorrentFilterDim.platform:
        return '流媒体平台';
      case TorrentFilterDim.codec:
        return '视频编码';
      case TorrentFilterDim.hdr:
        return 'HDR';
      case TorrentFilterDim.audio:
        return '音频';
      case TorrentFilterDim.subtitle:
        return '字幕';
      case TorrentFilterDim.group:
        return '压制组';
      default:
        return '分辨率';
    }
  }

  static dimOf(raw: string): TorrentFilterDim {
    switch (raw) {
      case 'site':
        return TorrentFilterDim.site;
      case 'year':
        return TorrentFilterDim.year;
      case 'season':
        return TorrentFilterDim.season;
      case 'episode':
        return TorrentFilterDim.episode;
      case 'source':
        return TorrentFilterDim.source;
      case 'platform':
        return TorrentFilterDim.platform;
      case 'codec':
        return TorrentFilterDim.codec;
      case 'hdr':
        return TorrentFilterDim.hdr;
      case 'audio':
        return TorrentFilterDim.audio;
      case 'subtitle':
        return TorrentFilterDim.subtitle;
      case 'group':
        return TorrentFilterDim.group;
      default:
        return TorrentFilterDim.resolution;
    }
  }

  static viewModeLabel(mode: string): string {
    switch (mode) {
      case 'list':
        return '列表';
      case 'poster':
        return '图览';
      default:
        return '分组';
    }
  }

  private static stringMap(pairs: string[][]): Map<string, string> {
    const m = new Map<string, string>();
    for (const pair of pairs) {
      m.set(pair[0], pair[1]);
    }
    return m;
  }

  private static rankMap(pairs: string[][]): Map<string, number> {
    const m = new Map<string, number>();
    for (const pair of pairs) {
      m.set(pair[0], Number(pair[1]));
    }
    return m;
  }
}
