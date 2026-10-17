import { Theme } from '../theme/AppTheme';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { AppFooter } from '../common/AppFooter';
import { RemoteImage } from '../common/RemoteImage';
import { ExternalMediaLink } from '../common/ExternalMediaLink';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { EventStream, ServerEvent, StreamHandle, StreamOptions } from '../common/EventStream';
import { JsonMap, jsonArrayValue, jsonAt, jsonBoolValue, jsonGet, jsonIntValue, jsonObjectValue, jsonStringValue } from '../api/JsonValue';
import {
  DownloadSubmitPayload,
  DownloadSubmitView,
  GrabPayload,
  GrabResultView,
  ManualDownloadTargetPayload,
  ManualDownloadTargetView,
  SiteSearchStatus,
  TorrentAttrs,
  TorrentHit
} from '../api/Models';
import {
  ALL_FILTER_DIMS,
  AttrBadge,
  AttrTone,
  Promo,
  PromoKind,
  REGULAR_SORT_KEYS,
  TORRENT_VIEW_MODES,
  TorrentBucket,
  TorrentEntity,
  TorrentFacetValue,
  TorrentFilterDim,
  TorrentFilters,
  TorrentSearchLogic,
  TorrentSort,
  TorrentSortKey
} from './TorrentSearchLogic';

/** 结果行的种类（拍平进一个懒加载列表：组头 / 命中行 / 展开按钮 / 图览网格行 / 图览提示行） */
enum RowKind {
  groupHeader,
  hit,
  expand,
  grid,
  gridNote
}

/** 作品分组的组头展示数据（全部预计算，@Builder 里不声明局部变量） */
class GroupHeader {
  readonly key: string;
  readonly nameZh: string;
  readonly nameEn: string;
  readonly info: string;
  readonly count: number;
  readonly freeCount: number;
  readonly topRes: string;
  readonly hasPack: boolean;
  readonly collapsed: boolean;

  constructor(key: string, nameZh: string, nameEn: string, info: string,
    count: number, freeCount: number, topRes: string, hasPack: boolean, collapsed: boolean) {
    this.key = key;
    this.nameZh = nameZh;
    this.nameEn = nameEn;
    this.info = info;
    this.count = count;
    this.freeCount = freeCount;
    this.topRes = topRes;
    this.hasPack = hasPack;
    this.collapsed = collapsed;
  }
}

/** 懒加载列表的一行（命中行的展示字段在入列前算好） */
class ResultRow {
  readonly kind: RowKind;
  readonly key: string;
  hit: TorrentHit | null = null;
  header: GroupHeader | null = null;
  gridHits: TorrentHit[] | null = null;
  text: string = '';
  // 命中行的预计算展示字段
  specText: string = '';
  primary: string = '';
  secondary: string = '';
  yearText: string = '';
  subtitleLine: string = '';
  promos: Promo[] = [];
  badges: AttrBadge[] = [];
  badgeExtra: number = 0;
  completeText: string = '';

  constructor(kind: RowKind, key: string) {
    this.kind = kind;
    this.key = key;
  }
}

/** 结果列表的 LazyForEach 数据源（整体换 + onDataReloaded） */
class ResultRowSource implements IDataSource {
  private rows: ResultRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): ResultRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  setRows(rows: ResultRow[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/** 资源搜索结果页的路由参数（会序列化，不要用 instanceof） */
export class TorrentParams {
  /** 搜索词；空 = 浏览模式（按分类拉各站种子列表页，不写历史） */
  readonly keyword: string;
  /** 同搜词（详情页带来的英文名/原名）：每站与主词一起搜、按种子合并；浏览模式忽略 */
  readonly alsoKeywords: string[];
  /** 手动选种模式：目标订阅 id（从订阅详情页进来时非 0） */
  readonly grabSubscriptionId: number;
  readonly grabSubscriptionTitle: string;
  /** 搜索范围的展示名（分类中文名/预设名）：标题与历史用；空 = 全部 */
  readonly label: string;
  /** 分类组合（空 = 不限分类） */
  readonly categories: string[];
  /** 站点子集（空 = 全部可用站点） */
  readonly siteIds: string[];
  /** 结果页图览模式的初始值（自定义预设可设定） */
  readonly posterMode: boolean;
  /** 无痕搜索：不写入搜索历史 */
  readonly skipHistory: boolean;

  constructor(keyword: string, alsoKeywords: string[] = [], grabSubscriptionId: number = 0,
    grabSubscriptionTitle: string = '', label: string = '', categories: string[] = [],
    siteIds: string[] = [], posterMode: boolean = false, skipHistory: boolean = false) {
    this.keyword = keyword;
    this.alsoKeywords = alsoKeywords;
    this.grabSubscriptionId = grabSubscriptionId;
    this.grabSubscriptionTitle = grabSubscriptionTitle;
    this.label = label;
    this.categories = categories;
    this.siteIds = siteIds;
    this.posterMode = posterMode;
    this.skipHistory = skipHistory;
  }

  static of(param: Object | undefined | null): TorrentParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: TorrentParams = param as TorrentParams;
    const keyword: string = raw.keyword === undefined || raw.keyword === null ? '' : raw.keyword;
    const also: string[] = TorrentParams.sanitizeAlso(raw.alsoKeywords);
    const id: number = raw.grabSubscriptionId;
    const title: string = raw.grabSubscriptionTitle;
    return new TorrentParams(keyword, also,
      Number.isFinite(id) ? Math.floor(id) : 0,
      title === undefined || title === null ? '' : title,
      raw.label === undefined || raw.label === null ? '' : raw.label,
      TorrentParams.sanitizeStrings(raw.categories),
      TorrentParams.sanitizeStrings(raw.siteIds),
      raw.posterMode === true,
      raw.skipHistory === true);
  }

  /** 路由参数里的同搜词防御性清洗：只留非空字符串 */
  private static sanitizeAlso(raw: string[] | undefined | null): string[] {
    return TorrentParams.sanitizeStrings(raw);
  }

  private static sanitizeStrings(raw: string[] | undefined | null): string[] {
    const words: string[] = [];
    if (raw === undefined || raw === null) {
      return words;
    }
    for (let i = 0; i < raw.length; i++) {
      const word: string | undefined = raw[i];
      if (typeof word === 'string' && word.trim().length > 0) {
        words.push(word);
      }
    }
    return words;
  }
}

/** 排序胶囊：菜单分「常规 / 智能」，点当前项翻转升降序（同 iOS TorrentViewModeMenu 旁的排序菜单） */
@ComponentV2
struct TorrentSortChip {
  @Param sortKey: string = 'seeders';
  @Param descending: boolean = true;
  @Param smartKeys: string[] = [];
  @Event onPick: (key: string) => void = (_key: string): void => {
  };

  private isDefault(): boolean {
    return this.sortKey === 'seeders' && this.descending;
  }

  private itemText(key: string): string {
    const suffix: string = key === this.sortKey ? (this.descending ? ' ↓' : ' ↑') : '';
    return `${TorrentSearchLogic.sortKeyLabel(key)}${suffix}`;
  }

  build() {
    Text(`${TorrentSearchLogic.sortKeyLabel(this.sortKey)}${this.descending ? ' ↓' : ' ↑'}`)
      .fontSize(12)
      .fontWeight(this.isDefault() ? FontWeight.Normal : FontWeight.Medium)
      .fontColor(this.isDefault() ? Theme.textMuted : Theme.text)
      .maxLines(1)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(this.isDefault() ? Theme.glassFill : Theme.glassFillHover)
      .borderRadius(15)
      .bindMenu(this.SortMenuContent)
  }

  @Builder
  SortMenuContent() {
    Menu() {
      MenuItemGroup({ header: '常规' }) {
        ForEach(REGULAR_SORT_KEYS, (key: TorrentSortKey) => {
          MenuItem({ content: this.itemText(key) })
            .onClick(() => {
              this.onPick(key);
            })
        }, (key: TorrentSortKey) => key)
      }
      if (this.smartKeys.length > 0) {
        MenuItemGroup({ header: '智能' }) {
          ForEach(this.smartKeys, (key: string) => {
            MenuItem({ content: this.itemText(key) })
              .onClick(() => {
                this.onPick(key);
              })
          }, (key: string) => key)
        }
      }
    }
  }
}

/** 一个筛选维度的胶囊：菜单里每个取值一行（副标题是命中条数），组内多选 = 或；已启用时多一项「移除此条件」 */
@ComponentV2
struct TorrentDimChip {
  @Param title: string = '';
  @Param summary: string = '';
  @Param labels: string[] = [];
  @Param selectedFlags: boolean[] = [];
  @Event onToggleIndex: (index: number) => void = (_index: number): void => {
  };
  @Event onRemove: () => void = (): void => {
  };

  private hasSelection(): boolean {
    for (const flag of this.selectedFlags) {
      if (flag) {
        return true;
      }
    }
    return false;
  }

  build() {
    Text(this.summary.length > 0 ? this.summary : this.title)
      .fontSize(12)
      .fontWeight(this.summary.length > 0 ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.summary.length > 0 ? Theme.text : Theme.textMuted)
      .maxLines(1)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(this.summary.length > 0 ? Theme.glassFillHover : Theme.glassFill)
      .borderRadius(15)
      .bindMenu(this.DimMenuContent)
  }

  @Builder
  DimMenuContent() {
    Menu() {
      ForEach(this.labels, (label: string, index: number) => {
        MenuItem({ content: this.selectedFlags[index] === true ? `✓ ${label}` : label })
          .onClick(() => {
            this.onToggleIndex(index);
          })
      }, (label: string, index: number) => `${index}-${label}`)
      if (this.hasSelection()) {
        MenuItem({ content: '移除此条件' })
          .onClick(() => {
            this.onRemove();
          })
      }
    }
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function TorrentResultsBuilder() {
  TorrentResultsPage()
}

/**
 * 「站点资源」结果页（对应 iOS `TorrentResultsView` + `TorrentSearchModel` + `TorrentSearchLogic`）。
 *
 * 自上而下：手动选种横幅 → 状态行（计数 / 站点聚合 chip）→ 视图切换（分组 / 列表 / 图览）→
 * 条件胶囊行（排序 + 各筛选维度）→ 进度条 → 结果。
 * 筛选/排序/视图全部是纯前端重算（不重新发起搜索），流式期间新到结果实时并入。
 * 行点按打开操作面板：下载 / 投给订阅 / 复制标题。加载更多以 page+1 重发一次流，全站去重追加。
 */
@ComponentV2
export struct TorrentResultsPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;

  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private keyword: string = '';
  @Local private hits: TorrentHit[] = [];
  @Local private sites: SiteSearchStatus[] = [];

  // 条件状态（筛选/排序/视图，全部前端重算）
  @Local private sortKey: TorrentSortKey = TorrentSortKey.seeders;
  @Local private sortDescending: boolean = true;
  @Local private viewMode: string = 'group';
  @Local private filters: TorrentFilters = new TorrentFilters();
  @Local private filteredCount: number = 0;
  @Local private page: number = 1;
  @Local private exhausted: boolean = false;
  @Local private loadingMore: boolean = false;
  @Local private collapsedGroups: Set<string> = new Set<string>();
  @Local private expandedGroups: Set<string> = new Set<string>();
  @Local private showSitesSheet: boolean = false;

  /** 一次性搜索流句柄（失败由页面重试按钮显式重开，不自动重连）。 */
  private stream: StreamHandle | null = null;
  private moreStream: StreamHandle | null = null;
  private rowSource: ResultRowSource = new ResultRowSource();
  /** 派生数据缓存（rebuildRows 时统一重算，胶囊菜单/组头直接读缓存） */
  private facetsCache: Map<TorrentFilterDim, TorrentFacetValue[]> = new Map();
  private entitiesCache: Map<string, TorrentEntity> = new Map();
  private smartKeysCache: TorrentSortKey[] = [TorrentSortKey.free];

  /** 行操作面板 */
  @Local private showActions: boolean = false;
  @Local private actionHit: TorrentHit | null = null;
  @Local private busy: boolean = false;
  /** 手动选种模式：目标订阅 */
  @Local private grabSubscriptionId: number = 0;
  @Local private grabSubscriptionTitle: string = '';
  /** 同搜词（详情页带来的英文名/原名）：每站与主词一起搜、按种子合并 */
  @Local private alsoKeywords: string[] = [];
  /** 实际同搜的词：以后端回显为准（去重后可能比 alsoKeywords 少），页头写「另含」 */
  @Local private alsoSearched: string[] = [];
  /** 搜索范围：展示名（分类中文名/预设名，标题与历史回显用）；空 = 全部分类 */
  @Local private scopeLabel: string = '';
  /** 范围的分类组合与站点子集（空 = 不限 / 全部站点） */
  @Local private scopeCategories: string[] = [];
  @Local private scopeSiteIds: string[] = [];
  /** 发起搜索时的图览模式偏好（自定义预设可设定），随请求发给后端写进历史 */
  @Local private scopePosterMode: boolean = false;
  /** 无痕搜索：本次搜索不写入历史（自定义预设可设定） */
  @Local private skipHistory: boolean = false;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  /**
   * 流式搜索的请求参数（同 iOS `SearchScope.queryItems`）：
   * keyword + 范围（label/categories/sites）+ no_history/poster_mode + 同搜词 + 分页（page>1 才带）。
   * keyword 留空即浏览模式（后端改拉各站种子列表页，且不写历史）。
   */
  private streamParams(page: number): StreamOptions {
    const query: Record<string, string> = { 'keyword': this.keyword };
    if (this.scopeLabel.length > 0) {
      query['label'] = this.scopeLabel;
    }
    if (this.skipHistory) {
      query['no_history'] = 'true';
    }
    if (this.scopePosterMode) {
      query['poster_mode'] = 'true';
    }
    if (page > 1) {
      query['page'] = `${page}`;
    }
    const repeated: Record<string, string[]> = {};
    if (this.alsoKeywords.length > 0) {
      repeated['also_keywords'] = this.alsoKeywords;
    }
    if (this.scopeCategories.length > 0) {
      repeated['categories'] = this.scopeCategories;
    }
    if (this.scopeSiteIds.length > 0) {
      repeated['sites'] = this.scopeSiteIds;
    }
    return { query: query, repeatedQuery: repeated };
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  aboutToDisappear(): void {
    this.closeStream();
    this.closeMoreStream();
  }

  private closeStream(): void {
    if (this.stream !== null) {
      this.stream.close();
      this.stream = null;
    }
  }

  private closeMoreStream(): void {
    if (this.moreStream !== null) {
      this.moreStream.close();
      this.moreStream = null;
    }
  }

  /**
   * 一次性流式跨站搜索 `GET /search/torrents/stream`（对应 iOS TorrentSearchAPI）。
   * 事件序列 start → site_start×N → (site_result|site_error)×N → done。
   * keyword 留空 = 浏览模式：按范围拉各站种子列表页（最新发布在前），不写历史。
   */
  private async search(): Promise<void> {
    const client = AppModel.shared.client;
    if (client === null) {
      return;
    }
    this.closeStream();
    this.loading = true;
    this.failed = false;
    this.errorMessage = '';
    this.hits = [];
    this.sites = [];
    this.alsoSearched = [];
    this.filters = new TorrentFilters();
    this.collapsedGroups = new Set<string>();
    this.expandedGroups = new Set<string>();
    this.page = 1;
    this.exhausted = false;
    this.loadingMore = false;
    this.rebuildRows();

    const es = new EventStream(client.origin, client.getToken());
    const self = this;
    this.stream = es.open('/search/torrents/stream',
      this.streamParams(0),
      {
        onEvent: (ev: ServerEvent): void => {
          self.onStreamEvent(ev);
        },
        onError: (err: ApiError): void => {
          self.loading = false;
          self.failed = true;
          self.errorMessage = self.messageOf(err);
        },
        onEnd: (): void => {
          self.loading = false;
        }
      });
  }

  /** 按 SSE 事件名分发；payload 字段照 iOS TorrentSearchAPI。 */
  private onStreamEvent(ev: ServerEvent): void {
    let payload: JsonMap;
    try {
      payload = JSON.parse(ev.data) as JsonMap;
    } catch (e) {
      return;
    }

    if (ev.event === 'start') {
      // 站点清单：先把各站置为「搜索中」；同搜词以后端回显为准（旧服务端没有该字段）
      const alsoRaw = jsonArrayValue(jsonGet(payload, 'also_keywords'));
      if (alsoRaw !== null) {
        const words: string[] = [];
        for (let i = 0; i < alsoRaw.length; i++) {
          const w = jsonStringValue(jsonAt(alsoRaw, i));
          if (w !== null) {
            words.push(w);
          }
        }
        this.alsoSearched = words;
      }
      const arr = jsonArrayValue(jsonGet(payload, 'sites'));
      if (arr !== null) {
        const built: SiteSearchStatus[] = [];
        for (let i = 0; i < arr.length; i++) {
          const m = jsonObjectValue(jsonAt(arr, i));
          if (m !== null) {
            built.push(TorrentResultsPage.parseSiteStatus(m, 0, null, null));
          }
        }
        this.sites = built;
      }
    } else if (ev.event === 'site_start') {
      this.upsertSite(TorrentResultsPage.parseSiteStatus(payload, 0, null, null));
    } else if (ev.event === 'site_result') {
      const count: number = jsonIntValue(jsonGet(payload, 'count')) ?? 0;
      const elapsedMs: number | null = jsonIntValue(jsonGet(payload, 'elapsed_ms'));
      const items = jsonArrayValue(jsonGet(payload, 'items'));
      if (items !== null) {
        const hits: TorrentHit[] = [];
        for (let i = 0; i < items.length; i++) {
          const m = jsonObjectValue(jsonAt(items, i));
          if (m !== null) {
            hits.push(TorrentResultsPage.parseHit(m));
          }
        }
        this.appendHits(hits);
      }
      this.upsertSite(TorrentResultsPage.parseSiteStatus(payload, count, null, elapsedMs));
    } else if (ev.event === 'site_error') {
      const err: string = jsonStringValue(jsonGet(payload, 'error')) ?? '';
      const elapsedMs: number | null = jsonIntValue(jsonGet(payload, 'elapsed_ms'));
      this.upsertSite(TorrentResultsPage.parseSiteStatus(payload, 0, err, elapsedMs));
    } else if (ev.event === 'done') {
      const sitesArr = jsonArrayValue(jsonGet(payload, 'sites'));
      if (sitesArr !== null) {
        const built: SiteSearchStatus[] = [];
        for (let i = 0; i < sitesArr.length; i++) {
          const m = jsonObjectValue(jsonAt(sitesArr, i));
          if (m !== null) {
            built.push(TorrentResultsPage.parseSiteStatus(
              m,
              jsonIntValue(jsonGet(m, 'count')) ?? 0,
              jsonStringValue(jsonGet(m, 'error')),
              jsonIntValue(jsonGet(m, 'elapsed_ms'))));
          }
        }
        this.sites = built;
        // 各站都明确说没有下一页（失败或说不准的站不算）→ 不再显示「加载更多」
        let allNoMore = built.length > 0;
        for (const s of built) {
          if ((s.error ?? null) !== null || s.has_more !== false) {
            allNoMore = false;
            break;
          }
        }
        if (allNoMore) {
          this.exhausted = true;
        }
      }
      this.loading = false;
      this.rebuildRows();
    }
  }

  /** 从 JSON 对象摊出一条站点状态（count/error/elapsed 由各事件覆盖传入，has_more 总是从对象里读）。 */
  private static parseSiteStatus(m: JsonMap, count: number,
    error: string | null, elapsedMs: number | null): SiteSearchStatus {
    return {
      site_id: jsonStringValue(jsonGet(m, 'site_id')) ?? '',
      site_name: jsonStringValue(jsonGet(m, 'site_name')) ?? '',
      count: count,
      error: error,
      elapsed_ms: elapsedMs,
      has_more: jsonBoolValue(jsonGet(m, 'has_more'))
    };
  }

  /** 从 JSON 对象摊出一条磁力结果（逐字段映射，缺省给合理默认；attrs 是全量解析）。 */
  private static parseHit(m: JsonMap): TorrentHit {
    const imagesRaw = jsonArrayValue(jsonGet(m, 'image_urls'));
    const imageUrls: string[] = [];
    if (imagesRaw !== null) {
      for (let i = 0; i < imagesRaw.length; i++) {
        const s = jsonStringValue(jsonAt(imagesRaw, i));
        if (s !== null) {
          imageUrls.push(s);
        }
      }
    }
    const attrsRaw = jsonObjectValue(jsonGet(m, 'attrs'));
    return {
      torrent_id: jsonStringValue(jsonGet(m, 'torrent_id')) ?? '',
      title: jsonStringValue(jsonGet(m, 'title')) ?? '',
      subtitle: jsonStringValue(jsonGet(m, 'subtitle')) ?? '',
      category: null,
      site_category_id: jsonStringValue(jsonGet(m, 'site_category_id')),
      site_category_name: jsonStringValue(jsonGet(m, 'site_category_name')),
      size: jsonStringValue(jsonGet(m, 'size')),
      size_bytes: jsonIntValue(jsonGet(m, 'size_bytes')) ?? 0,
      seeders: jsonIntValue(jsonGet(m, 'seeders')) ?? 0,
      leechers: jsonIntValue(jsonGet(m, 'leechers')) ?? 0,
      snatched: jsonIntValue(jsonGet(m, 'snatched')) ?? 0,
      upload_time: jsonStringValue(jsonGet(m, 'upload_time')),
      uploader: jsonStringValue(jsonGet(m, 'uploader')) ?? '',
      poster_url: jsonStringValue(jsonGet(m, 'poster_url')),
      image_urls: imageUrls,
      free: jsonBoolValue(jsonGet(m, 'free')) ?? false,
      free_deadline: jsonStringValue(jsonGet(m, 'free_deadline')),
      download_volume_factor: jsonIntValue(jsonGet(m, 'download_volume_factor')) ?? 1,
      upload_volume_factor: jsonIntValue(jsonGet(m, 'upload_volume_factor')) ?? 1,
      hit_and_run: jsonBoolValue(jsonGet(m, 'hit_and_run')),
      detail_url: jsonStringValue(jsonGet(m, 'detail_url')),
      download_url: jsonStringValue(jsonGet(m, 'download_url')),
      site_id: jsonStringValue(jsonGet(m, 'site_id')) ?? '',
      site_name: jsonStringValue(jsonGet(m, 'site_name')) ?? '',
      attrs: attrsRaw === null ? null : TorrentResultsPage.parseAttrs(attrsRaw)
    };
  }

  /** 种子结构化属性（分辨率/季集/字幕/平台等，服务端随种子一起下发） */
  private static parseAttrs(m: JsonMap): TorrentAttrs {
    return {
      media_type: jsonStringValue(jsonGet(m, 'media_type')),
      content_type: jsonStringValue(jsonGet(m, 'content_type')),
      titles_zh: TorrentResultsPage.parseStrings(m, 'titles_zh'),
      titles_en: TorrentResultsPage.parseStrings(m, 'titles_en'),
      title_candidates: TorrentResultsPage.parseStrings(m, 'title_candidates'),
      year: jsonIntValue(jsonGet(m, 'year')),
      seasons: TorrentResultsPage.parseNumbers(m, 'seasons'),
      episodes: TorrentResultsPage.parseNumbers(m, 'episodes'),
      episodes_total: jsonIntValue(jsonGet(m, 'episodes_total')),
      complete: jsonBoolValue(jsonGet(m, 'complete')),
      resolution: jsonStringValue(jsonGet(m, 'resolution')),
      video_codec: jsonStringValue(jsonGet(m, 'video_codec')),
      hdr: TorrentResultsPage.parseStrings(m, 'hdr'),
      media_source: jsonStringValue(jsonGet(m, 'media_source')),
      remux: jsonBoolValue(jsonGet(m, 'remux')) ?? false,
      audio: TorrentResultsPage.parseStrings(m, 'audio'),
      subtitle_languages: TorrentResultsPage.parseStrings(m, 'subtitle_languages'),
      subtitle_carriers: TorrentResultsPage.parseStrings(m, 'subtitle_carriers'),
      audio_languages: TorrentResultsPage.parseStrings(m, 'audio_languages'),
      platforms: TorrentResultsPage.parseStrings(m, 'platforms'),
      release_group: jsonStringValue(jsonGet(m, 'release_group'))
    };
  }

  private static parseStrings(m: JsonMap, key: string): string[] {
    const out: string[] = [];
    const raw = jsonArrayValue(jsonGet(m, key));
    if (raw === null) {
      return out;
    }
    for (let i = 0; i < raw.length; i++) {
      const s = jsonStringValue(jsonAt(raw, i));
      if (s !== null) {
        out.push(s);
      }
    }
    return out;
  }

  private static parseNumbers(m: JsonMap, key: string): number[] {
    const out: number[] = [];
    const raw = jsonArrayValue(jsonGet(m, key));
    if (raw === null) {
      return out;
    }
    for (let i = 0; i < raw.length; i++) {
      const n = jsonIntValue(jsonAt(raw, i));
      if (n !== null) {
        out.push(n);
      }
    }
    return out;
  }

  private upsertSite(s: SiteSearchStatus): void {
    const list: SiteSearchStatus[] = this.sites.slice();
    let replaced: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].site_id === s.site_id) {
        list[i] = s;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      list.push(s);
    }
    this.sites = list;
  }

  private appendHits(items: TorrentHit[]): void {
    if (items.length === 0) {
      return;
    }
    const list: TorrentHit[] = this.hits.slice();
    for (const h of items) {
      list.push(h);
    }
    this.hits = list;
    this.rebuildRows();
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '搜索失败';
  }

  // MARK: 派生数据（筛选 → 排序 → 分面 → 作品分组 → 智能排序键 → 行模型）

  /** 结果或条件变化时统一重算派生数据并重建行模型（对应 iOS TorrentSearchModel.recompute） */
  private rebuildRows(): void {
    const sort = new TorrentSort(this.sortKey, this.sortDescending);
    const filtered: TorrentHit[] = [];
    for (const hit of this.hits) {
      if (TorrentSearchLogic.matches(hit, this.filters)) {
        filtered.push(hit);
      }
    }
    this.filteredCount = filtered.length;
    const sorted = TorrentSearchLogic.sorted(filtered, sort);
    this.facetsCache = TorrentSearchLogic.facets(this.hits, this.filters);
    this.entitiesCache = TorrentSearchLogic.entities(this.hits);
    this.smartKeysCache = TorrentSearchLogic.smartSortKeys(this.hits);

    const rows: ResultRow[] = [];
    if (this.viewMode === 'poster') {
      const withPoster: TorrentHit[] = [];
      const withoutPoster: TorrentHit[] = [];
      for (const hit of sorted) {
        if ((hit.poster_url ?? '') !== '') {
          withPoster.push(hit);
        } else {
          withoutPoster.push(hit);
        }
      }
      for (let i = 0; i < withPoster.length; i += 2) {
        const row = new ResultRow(RowKind.grid, `grid-${i}`);
        row.gridHits = withPoster.slice(i, i + 2);
        rows.push(row);
      }
      if (withoutPoster.length > 0) {
        if (withPoster.length > 0) {
          const note = new ResultRow(RowKind.gridNote, 'grid-note');
          note.text = `以下 ${withoutPoster.length} 条结果没有海报，按列表展示`;
          rows.push(note);
        }
        for (const hit of withoutPoster) {
          rows.push(this.makeHitRow(hit, false, false, 'p-'));
        }
      }
    } else if (this.viewMode === 'group' && this.entitiesCache.size >= 2) {
      const buckets = TorrentSearchLogic.buckets(sorted);
      for (const bucket of buckets) {
        rows.push(this.makeHeaderRow(bucket));
        const collapsed = this.collapsedGroups.has(bucket.key);
        if (!collapsed) {
          const cap = 4;
          const expanded = this.expandedGroups.has(bucket.key);
          const shown = expanded || bucket.rows.length <= cap ? bucket.rows : bucket.rows.slice(0, cap);
          for (const hit of shown) {
            rows.push(this.makeHitRow(hit, true, false, `g-${bucket.key}-`));
          }
          if (!expanded && bucket.rows.length > cap) {
            const exp = new ResultRow(RowKind.expand, `e-${bucket.key}`);
            exp.text = `展开其余 ${bucket.rows.length - cap} 个版本 ▾`;
            rows.push(exp);
          }
        }
      }
    } else {
      for (const hit of sorted) {
        rows.push(this.makeHitRow(hit, false, this.viewMode === 'list', 'l-'));
      }
    }
    this.rowSource.setRows(rows);
  }

  /** 一条命中行：展示字段全部预计算（解析片名/规格摘要/徽标/副标题行） */
  private makeHitRow(hit: TorrentHit, grouped: boolean, rawTitles: boolean,
    keyPrefix: string): ResultRow {
    const row = new ResultRow(RowKind.hit, `${keyPrefix}${hit.site_id}-${hit.torrent_id}`);
    row.hit = hit;
    const name = rawTitles ? null : TorrentSearchLogic.parsedName(hit);
    const specRow = grouped && name !== null;
    if (specRow) {
      const a = hit.attrs ?? null;
      row.specText = a !== null ? (TorrentSearchLogic.specSummary(a) ?? hit.title) : hit.title;
    } else if (name !== null) {
      row.primary = name.primary;
      row.secondary = name.secondary ?? '';
      row.yearText = this.parsedYear(hit);
    }
    const parts: string[] = [];
    if (name === null && hit.subtitle.length > 0) {
      parts.push(hit.subtitle);
    }
    const category = hit.site_category_name ?? null;
    if (category !== null && category.length > 0) {
      parts.push(category);
    }
    row.subtitleLine = parts.join('  ·  ');
    row.completeText = TorrentSearchLogic.completeLabel(hit.attrs ?? null) ?? '';
    row.promos = TorrentSearchLogic.promos(hit);
    const a2 = hit.attrs ?? null;
    if (a2 !== null && !specRow) {
      const all = TorrentSearchLogic.attrBadges(a2);
      row.badges = all.slice(0, 4);
      row.badgeExtra = all.length > 4 ? all.length - 4 : 0;
    }
    return row;
  }

  /** 作品分组组头：片名中英文 + 年份/类型/题材 + 版本数、最高分辨率、全集包、免费数 */
  private makeHeaderRow(bucket: TorrentBucket): ResultRow {
    const entity = this.entitiesCache.get(bucket.key) ?? null;
    let freeCount = 0;
    for (const h of bucket.rows) {
      if (h.free || h.download_volume_factor === 0) {
        freeCount += 1;
      }
    }
    const topRes = TorrentSearchLogic.maxResolution(bucket.rows) ?? '';
    let hasPack = false;
    for (const h of bucket.rows) {
      const a = h.attrs ?? null;
      if (a !== null && a.complete === true) {
        hasPack = true;
        break;
      }
    }
    const infoParts: string[] = [];
    if (entity !== null) {
      if (entity.year !== null) {
        infoParts.push(`${entity.year}`);
      }
      if (entity.mediaType.length > 0) {
        infoParts.push(TorrentSearchLogic.MEDIA_TYPE_LABELS.get(entity.mediaType) ?? entity.mediaType);
      }
      if (entity.contentType.length > 0) {
        infoParts.push(TorrentSearchLogic.CONTENT_TYPE_LABELS.get(entity.contentType) ?? entity.contentType);
      }
    } else {
      infoParts.push('按原始名展示');
    }
    const header = new GroupHeader(
      bucket.key,
      entity !== null ? entity.nameZh : '',
      entity !== null ? entity.nameEn : '',
      infoParts.join(' · '),
      bucket.rows.length,
      freeCount,
      topRes,
      hasPack,
      this.collapsedGroups.has(bucket.key));
    const row = new ResultRow(RowKind.groupHeader, `h-${bucket.key}`);
    row.header = header;
    return row;
  }

  // MARK: 条件胶囊的数据源

  /** 本次结果里出现过的维度（或已选了值的维度）：按固定顺序列胶囊 */
  private chipDimStrings(): string[] {
    const out: string[] = [];
    for (const dim of ALL_FILTER_DIMS) {
      if (this.dimValues(dim).length > 0 || this.filters.values(dim).size > 0) {
        out.push(dim);
      }
    }
    return out;
  }

  /** 一个维度的分面取值（站点维度只列成功返回的站点，顺序同站点状态） */
  private dimValues(dim: TorrentFilterDim): TorrentFacetValue[] {
    if (dim === TorrentFilterDim.site) {
      const counts = this.facetsCache.get(TorrentFilterDim.site) ?? [];
      const map = new Map<string, number>();
      for (const f of counts) {
        map.set(f.value, f.count);
      }
      const result: TorrentFacetValue[] = [];
      for (const site of this.okSites()) {
        result.push(new TorrentFacetValue(site.site_id, map.get(site.site_id) ?? 0));
      }
      return result;
    }
    return this.facetsCache.get(dim) ?? [];
  }

  /** 胶囊上的所选值：一两个直接写名字，多了写「首个等 N 个」 */
  private chipSummary(dim: TorrentFilterDim): string {
    const selected = this.filters.values(dim);
    if (selected.size === 0) {
      return '';
    }
    const labels: string[] = [];
    selected.forEach((v: string) => {
      labels.push(TorrentSearchLogic.facetLabel(dim, v, (id: string): string => this.siteNameOf(id)));
    });
    labels.sort();
    if (labels.length <= 2) {
      return labels.join('、');
    }
    return `${labels[0]}等 ${labels.length} 个`;
  }

  private dimLabels(dim: TorrentFilterDim): string[] {
    const out: string[] = [];
    for (const facet of this.dimValues(dim)) {
      out.push(`${TorrentSearchLogic.facetLabel(dim, facet.value, (id: string): string => this.siteNameOf(id))}（${facet.count} 条）`);
    }
    return out;
  }

  private dimFlags(dim: TorrentFilterDim): boolean[] {
    const selected = this.filters.values(dim);
    const out: boolean[] = [];
    for (const facet of this.dimValues(dim)) {
      out.push(selected.has(facet.value));
    }
    return out;
  }

  private toggleDim(dim: TorrentFilterDim, index: number): void {
    const values = this.dimValues(dim);
    if (index < 0 || index >= values.length) {
      return;
    }
    this.filters = this.filters.toggle(dim, values[index].value);
    this.rebuildRows();
  }

  private removeDim(dim: TorrentFilterDim): void {
    this.filters = this.filters.removeDim(dim);
    this.rebuildRows();
  }

  private pickSort(raw: string): void {
    const key = TorrentSearchLogic.sortKeyOf(raw);
    if (key === this.sortKey) {
      this.sortDescending = !this.sortDescending;
    } else {
      this.sortKey = key;
      this.sortDescending = true;
    }
    this.rebuildRows();
  }

  private smartKeyStrings(): string[] {
    const out: string[] = [];
    for (const key of this.smartKeysCache) {
      out.push(key);
    }
    return out;
  }

  private toggleCollapse(key: string): void {
    const next = new Set<string>();
    this.collapsedGroups.forEach((k: string) => {
      next.add(k);
    });
    if (next.has(key)) {
      next.delete(key);
    } else {
      next.add(key);
    }
    this.collapsedGroups = next;
    this.rebuildRows();
  }

  private expandGroup(key: string): void {
    const next = new Set<string>();
    this.expandedGroups.forEach((k: string) => {
      next.add(k);
    });
    next.add(key);
    this.expandedGroups = next;
    this.rebuildRows();
  }

  // MARK: 站点状态

  private siteNameOf(id: string): string {
    for (const site of this.sites) {
      if (site.site_id === id) {
        return site.site_name;
      }
    }
    return id;
  }

  private siteFailed(site: SiteSearchStatus): boolean {
    return (site.error ?? null) !== null;
  }

  private siteSettled(site: SiteSearchStatus): boolean {
    return (site.error ?? null) !== null || (site.elapsed_ms ?? null) !== null;
  }

  private failedSiteCount(): number {
    let count = 0;
    for (const site of this.sites) {
      if (this.siteFailed(site)) {
        count += 1;
      }
    }
    return count;
  }

  private settledSiteCount(): number {
    let count = 0;
    for (const site of this.sites) {
      if (this.siteSettled(site)) {
        count += 1;
      }
    }
    return count;
  }

  private okSites(): SiteSearchStatus[] {
    const out: SiteSearchStatus[] = [];
    for (const site of this.sites) {
      if (!this.siteFailed(site) && (!this.loading || this.siteSettled(site))) {
        out.push(site);
      }
    }
    return out;
  }

  private siteDotColor(site: SiteSearchStatus): string {
    if (this.siteFailed(site)) {
      return Theme.danger;
    }
    if (this.loading && !this.siteSettled(site)) {
      return Theme.accent;
    }
    return Theme.ok;
  }

  private siteStateText(site: SiteSearchStatus): string {
    if (this.siteFailed(site)) {
      const err = site.error ?? '失败';
      return err.length > 30 ? `${err.substring(0, 30)}…` : err;
    }
    if (this.loading && !this.siteSettled(site)) {
      return '搜索中';
    }
    const elapsed = site.elapsed_ms ?? null;
    const elapsedText = elapsed !== null ? ` · ${(elapsed / 1000).toFixed(1)} 秒` : '';
    return `${site.count} 条${elapsedText}`;
  }

  /** 站点状态：有报错的站点要显出来，否则用户会奇怪「怎么少了一个站的」 */
  private siteErrorText(): string {
    const broken: string[] = [];
    for (const site of this.sites) {
      if (site.error !== null && site.error !== undefined && site.error.length > 0) {
        broken.push(site.site_name);
      }
    }
    return broken.length === 0 ? '' : `${broken.join('、')} 没返回结果`;
  }

  // MARK: 海报卡辅助

  private parsedYear(hit: TorrentHit): string {
    const a = hit.attrs ?? null;
    const year = a !== null ? (a.year ?? null) : null;
    return year !== null ? `${year}` : '';
  }

  private posterTitle(hit: TorrentHit): string {
    const name = TorrentSearchLogic.parsedName(hit);
    return name === null ? hit.title : name.primary;
  }

  private posterHasName(hit: TorrentHit): boolean {
    return TorrentSearchLogic.parsedName(hit) !== null;
  }

  private posterSpec(hit: TorrentHit): string {
    const parts: string[] = [];
    const a = hit.attrs ?? null;
    const resolution = a !== null ? (a.resolution ?? null) : null;
    if (resolution !== null) {
      parts.push(resolution);
    }
    const size = TorrentSearchLogic.sizeText(hit);
    if (size.length > 0) {
      parts.push(size);
    }
    return parts.join(' · ');
  }

  private posterMeta(hit: TorrentHit): string {
    const time = hit.upload_time ?? null;
    const relative = time !== null ? Formatters.relative(time) : '';
    return relative.length > 0 ? `${hit.site_name} · ${relative}` : hit.site_name;
  }

  private posterImageCount(hit: TorrentHit): number {
    const poster = (hit.poster_url ?? '') !== '' ? 1 : 0;
    return poster + hit.image_urls.length;
  }

  private seasonChipText(hit: TorrentHit): string {
    const chip = TorrentSearchLogic.seasonEpisodeChip(hit.attrs ?? null);
    return chip === null ? '' : chip.text;
  }

  private seasonChipPack(hit: TorrentHit): boolean {
    const chip = TorrentSearchLogic.seasonEpisodeChip(hit.attrs ?? null);
    return chip === null ? false : chip.pack;
  }

  private static seederTone(n: number): string {
    if (n === 0) {
      return '#ff9999';
    }
    if (n < 5) {
      return Theme.warning;
    }
    if (n >= 100) {
      return Theme.ok;
    }
    return '#78d194';
  }

  private static toneColor(tone: AttrTone): string {
    switch (tone) {
      case AttrTone.season:
        return Theme.accent2;
      case AttrTone.content:
        return '#f0b5d9';
      case AttrTone.remux:
        return '#99c7ff';
      case AttrTone.hdr:
        return '#c7a6ff';
      case AttrTone.subtitle:
        return '#7de3b8';
      case AttrTone.audio:
        return '#ffd189';
      case AttrTone.group:
        return Theme.accent;
      case AttrTone.platform:
        return '#8fd9ff';
      default:
        return Theme.textMuted;
    }
  }

  /** 促销角标配色（solid = 图览海报上的实底版本） */
  private static promoFg(kind: PromoKind, solid: boolean): string {
    switch (kind) {
      case PromoKind.free:
        return solid ? '#052e17' : '#78d194';
      case PromoKind.discount:
        return solid ? '#ffffff' : '#99c7ff';
      case PromoKind.upload:
        return solid ? '#ffffff' : '#c7a6ff';
      default:
        return solid ? '#3b2600' : Theme.warning;
    }
  }

  private static promoBg(kind: PromoKind, solid: boolean): string {
    switch (kind) {
      case PromoKind.free:
        return solid ? 'rgba(74, 222, 128, 0.9)' : 'rgba(74, 222, 128, 0.15)';
      case PromoKind.discount:
        return solid ? 'rgba(127, 176, 255, 0.85)' : 'rgba(127, 176, 255, 0.15)';
      case PromoKind.upload:
        return solid ? 'rgba(199, 145, 255, 0.85)' : 'rgba(199, 145, 255, 0.15)';
      default:
        return solid ? 'rgba(245, 158, 11, 0.9)' : 'rgba(245, 196, 81, 0.15)';
    }
  }

  // MARK: 加载更多

  /** 以 page+1 重发一次全范围流，新结果去重后追加；全部站点都没带来新条目 → 到底 */
  private loadMore(): void {
    if (this.loadingMore || this.exhausted || this.loading) {
      return;
    }
    const client = AppModel.shared.client;
    if (client === null) {
      return;
    }
    this.closeMoreStream();
    const next: number = this.page + 1;
    this.loadingMore = true;
    const seen: Set<string> = new Set<string>();
    for (const h of this.hits) {
      seen.add(`${h.site_id}/${h.torrent_id}`);
    }
    let added = 0;
    let lastPage = false;
    let hadError = false;
    const self = this;
    const es = new EventStream(client.origin, client.getToken());
    this.moreStream = es.open('/search/torrents/stream',
      this.streamParams(next),
      {
        onEvent: (ev: ServerEvent): void => {
          let payload: JsonMap;
          try {
            payload = JSON.parse(ev.data) as JsonMap;
          } catch (e) {
            return;
          }
          if (ev.event === 'site_result') {
            const items = jsonArrayValue(jsonGet(payload, 'items'));
            if (items === null) {
              return;
            }
            const fresh: TorrentHit[] = [];
            for (let i = 0; i < items.length; i++) {
              const m = jsonObjectValue(jsonAt(items, i));
              if (m === null) {
                continue;
              }
              const hit = TorrentResultsPage.parseHit(m);
              const key = `${hit.site_id}/${hit.torrent_id}`;
              if (!seen.has(key)) {
                seen.add(key);
                fresh.push(hit);
              }
            }
            if (fresh.length > 0) {
              added += fresh.length;
              self.appendHits(fresh);
            }
          } else if (ev.event === 'done') {
            const sitesArr = jsonArrayValue(jsonGet(payload, 'sites'));
            let allNoMore = sitesArr !== null && sitesArr.length > 0;
            if (allNoMore && sitesArr !== null) {
              for (let i = 0; i < sitesArr.length; i++) {
                const m = jsonObjectValue(jsonAt(sitesArr, i));
                if (m === null) {
                  allNoMore = false;
                  break;
                }
                const err = jsonStringValue(jsonGet(m, 'error'));
                const more = jsonBoolValue(jsonGet(m, 'has_more'));
                if (err !== null || more !== false) {
                  allNoMore = false;
                  break;
                }
              }
            }
            lastPage = allNoMore;
          }
        },
        onError: (err: ApiError): void => {
          hadError = true;
          self.toast(self.messageOf(err));
        },
        onEnd: (): void => {
          self.loadingMore = false;
          self.closeMoreStream();
          if (!hadError) {
            self.page = next;
            if (added === 0 || lastPage) {
              self.exhausted = true;
            }
          }
        }
      });
  }

  // MARK: 动作

  private openActions(hit: TorrentHit): void {
    this.actionHit = hit;
    this.showActions = true;
  }

  /** 下载：先问「存哪」（后端解析目标），用户确认后再提交 */
  private async download(hit: TorrentHit): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const payload: ManualDownloadTargetPayload = {
        title: hit.title,
        subtitle: hit.subtitle.length > 0 ? hit.subtitle : null
      };
      const target: ManualDownloadTargetView = await api.dlResolveTarget(payload);
      this.showActions = false;
      const where: string = target.library_name !== null && target.library_name !== undefined
        && target.library_name.length > 0 ? target.library_name : (target.path ?? '默认位置');
      this.confirmSubmit(hit, target, where);
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  private confirmSubmit(hit: TorrentHit, target: ManualDownloadTargetView, where: string): void {
    this.getUIContext().showAlertDialog({
      title: '下载这个资源',
      message: `${hit.title}\n\n会存到「${where}」。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '下载',
        action: (): void => {
          this.submit(hit, target);
        }
      }
    });
  }

  private async submit(hit: TorrentHit, target: ManualDownloadTargetView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const url: string | null = hit.download_url ?? null;
    if (url === null || url.length === 0) {
      this.toast('这个资源没有可用的下载地址');
      return;
    }
    try {
      const payload: DownloadSubmitPayload = {
        site_id: hit.site_id,
        download_url: url,
        torrent_id: hit.torrent_id,
        library_id: target.library_id ?? null,
        title: hit.title,
        save_path: target.path ?? null
      };
      const result: DownloadSubmitView = await api.dlSubmit(payload);
      this.toast(result.already_exists
        ? '该种子已在下载器中，未重复添加'
        : `已提交给「${result.downloader_name}」`);
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  /** 投给订阅：把选中的种子交给指定订阅（订阅详情页的「手动选种」走这条） */
  private async grabToSubscription(hit: TorrentHit): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.grabSubscriptionId <= 0) {
      return;
    }
    this.busy = true;
    try {
      const payload: GrabPayload = {
        site_id: hit.site_id,
        torrent_id: hit.torrent_id,
        title: hit.title,
        subtitle: hit.subtitle.length > 0 ? hit.subtitle : null,
        download_url: hit.download_url ?? null,
        size_bytes: hit.size_bytes,
        seeders: hit.seeders,
        is_free: hit.free
      };
      const result: GrabResultView = await api.subscriptionsDownloadSelectedTorrent(
        this.grabSubscriptionId, payload);
      this.showActions = false;
      this.toast('已投给订阅');
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  private copyTitle(hit: TorrentHit): void {
    this.showActions = false;
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, hit.title);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.toast('已复制标题');
    } catch (error) {
      this.toast('复制失败，请重试');
    }
  }

  /** 种子的站点详情链接；空 = 没有「查看详情」 */
  private detailUrlOf(hit: TorrentHit): string {
    const url: string | null = hit.detail_url ?? null;
    return url === null ? '' : url;
  }

  /** 打开种子的站点详情页（外链交给系统处理，同 iOS TorrentActions 的「查看详情」） */
  private openDetailUrl(hit: TorrentHit): void {
    const address: string = this.detailUrlOf(hit);
    if (address.length === 0) {
      this.toast('这个资源没有详情链接');
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ExternalMediaLink.open(context, address, (): void => {
      this.toast('打不开详情页');
    });
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        PageTopBar({ title: this.pageTitle(), onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.failed) {
          this.ErrorState()
        } else if (this.loading && this.hits.length === 0 && this.sites.length === 0) {
          // 还没收到 start（站点清单）/任何结果：整屏转圈
          this.LoadingState()
        } else if (!this.loading && this.hits.length === 0) {
          this.EmptyState()
        } else {
          // 已开始流式：边收边出结果
          this.Content()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .bindSheet($$this.showActions, this.ActionsSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
    .bindSheet($$this.showSitesSheet, this.SitesSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: TorrentParams | null = TorrentParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.keyword = params.keyword;
        this.alsoKeywords = params.alsoKeywords;
        this.grabSubscriptionId = params.grabSubscriptionId;
        this.grabSubscriptionTitle = params.grabSubscriptionTitle;
        this.scopeLabel = params.label;
        this.scopeCategories = params.categories;
        this.scopeSiteIds = params.siteIds;
        this.scopePosterMode = params.posterMode;
        this.skipHistory = params.skipHistory;
        // 预设设定的图览模式：结果页默认以图墙展示（可临时切换，同 iOS）
        if (params.posterMode) {
          this.viewMode = 'poster';
        }
        this.search();
      }
    })
  }

  /** 页面标题：搜索写搜索词；浏览模式（空词）写范围名（「浏览 · 电影」/「浏览最新资源」） */
  private pageTitle(): string {
    if (this.keyword.length > 0) {
      return `搜索“${this.keyword}”`;
    }
    return this.scopeLabel.length > 0 ? `浏览 · ${this.scopeLabel}` : '浏览最新资源';
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress().width(24).height(24).color(Theme.textMuted)
      Text('正在各站点搜索…').fontSize(13).fontColor(Theme.textFaint)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 10 }) {
      Text('资源搜索失败').fontSize(15).fontColor(Theme.text)
      Text(this.errorMessage).fontSize(13).fontColor(Theme.textMuted).textAlign(TextAlign.Center)
      Text('重试').fontSize(14).fontColor(Theme.accentStrong).onClick(() => {
        this.search();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyState() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(28)
        .fontColor([Theme.textFaint])
      Text('没有找到匹配的资源')
        .fontSize(15)
        .fontColor(Theme.textMuted)
      if (this.sites.length === 0) {
        Text('当前没有「已启用且验证通过」的站点，请先在设置里配置站点。')
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
      }
      if (this.siteErrorText().length > 0) {
        Text(this.siteErrorText())
          .fontSize(12)
          .fontColor(Theme.warn)
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  Content() {
    Column({ space: 10 }) {
      // 手动选种横幅（对应 iOS 的 grab-banner）
      if (this.grabSubscriptionId > 0) {
        Text(`手动选种：投给「${this.grabSubscriptionTitle}」`)
          .fontSize(13)
          .fontColor(Theme.accentStrong)
          .width('100%')
          .padding(12)
          .backgroundColor('rgba(251, 191, 36, 0.08)')
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: 'rgba(251, 191, 36, 0.35)' })
      }
      this.StatusHeader()
      if (this.sites.length > 0) {
        this.ConditionChips()
      }
      if (!this.loading && this.hits.length > 0 && this.filteredCount === 0) {
        Column({ space: 6 }) {
          Text('没有符合筛选条件的结果').fontSize(15).fontColor(Theme.text)
          Text('放宽或清除顶部的筛选条件试试。').fontSize(13).fontColor(Theme.textMuted)
        }
        .width('100%')
        .layoutWeight(1)
        .padding(24)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List() {
          LazyForEach(this.rowSource, (row: ResultRow) => {
            ListItem() {
              this.RowContent(row)
            }
          }, (row: ResultRow) => row.key)
          // 加载更多：以 page+1 重发一次流，全站去重追加（对应 iOS loadMore）
          if (!this.loading && !this.exhausted && this.hits.length > 0) {
            ListItem() {
              Text(this.loadingMore ? '正在加载…' : `加载更多（第 ${this.page + 1} 页）`)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.accentStrong)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 12 })
                .onClick(() => {
                  this.loadMore();
                })
            }
          }
          if (this.exhausted && this.page > 1 && this.hits.length > 0) {
            ListItem() {
              Text(`已加载全部 ${this.page} 页结果`)
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
            }
          }
          // 页脚：品牌联合声明，复用全局 AppFooter（包在 ListItem 里跟随滚动）
          ListItem() {
            AppFooter({ topSpace: 0 })
          }
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 16, right: 16, top: 8 })
  }

  /** 结果状态行：左边条数，右边站点聚合 chip（点开逐站详情）；同搜词与视图切换 */
  @Builder
  StatusHeader() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        if (this.loading) {
          Circle({ width: 6, height: 6 }).fill(Theme.accent)
          Text(`已找到 ${this.hits.length} 条`)
            .fontSize(13)
            .fontColor(Theme.textMuted)
        } else {
          Text(this.filters.isActive()
            ? `筛选后 ${this.filteredCount} / 共 ${this.hits.length} 条`
            : `共 ${this.hits.length} 条结果`)
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
        Blank()
        if (this.sites.length > 0) {
          Row({ space: 6 }) {
            Circle({ width: 6, height: 6 })
              .fill(this.loading ? Theme.accent : (this.failedSiteCount() > 0 ? Theme.danger : Theme.ok))
            if (this.loading) {
              Text(`${this.settledSiteCount()}/${this.sites.length} 站点`)
                .fontSize(11)
                .fontColor(Theme.textMuted)
            } else {
              Text(`${this.sites.length} 站点`)
                .fontSize(11)
                .fontColor(Theme.textMuted)
              if (this.failedSiteCount() > 0) {
                Text(`· ${this.failedSiteCount()} 失败`)
                  .fontSize(11)
                  .fontColor(Theme.danger)
              }
            }
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(13)
          .onClick(() => {
            this.showSitesSheet = true;
          })
        }
      }
      .width('100%')

      if (this.alsoSearched.length > 0) {
        Text(`另含 ${this.alsoSearched.join(' · ')}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // 视图切换（iOS 在顶栏右上角的 TorrentViewModeMenu）：分组 / 列表 / 图览
      Row({ space: 6 }) {
        Blank()
        ForEach(TORRENT_VIEW_MODES, (mode: string) => {
          Text(TorrentSearchLogic.viewModeLabel(mode))
            .fontSize(12)
            .fontColor(this.viewMode === mode ? Theme.text : Theme.textMuted)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(this.viewMode === mode ? Theme.accentSoft : Theme.glassFill)
            .borderRadius(13)
            .onClick(() => {
              this.viewMode = mode;
              this.rebuildRows();
            })
        }, (mode: string) => mode)
      }
      .width('100%')

      // 站点数已知：按已结束站点比例推进（起步 6%）
      if (this.loading && this.sites.length > 0) {
        Progress({
          value: Math.max(6, this.settledSiteCount() / this.sites.length * 100),
          total: 100,
          type: ProgressType.Linear
        })
          .color(Theme.accent)
          .backgroundColor('rgba(255, 255, 255, 0.07)')
          .height(2)
          .width('100%')
      }
    }
    .width('100%')
  }

  /** 条件胶囊：一排玻璃胶囊——排序在前，其后按固定顺序列本次结果里出现过的维度；有筛选时最左边钉一颗「清空」 */
  @Builder
  ConditionChips() {
    Row({ space: 8 }) {
      if (this.filters.isActive()) {
        Text('✕ 清空')
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .padding({ left: 11, right: 11, top: 7, bottom: 7 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(15)
          .onClick(() => {
            this.filters = this.filters.clear();
            this.rebuildRows();
          })
      }
      Scroll() {
        Row({ space: 8 }) {
          TorrentSortChip({
            sortKey: this.sortKey,
            descending: this.sortDescending,
            smartKeys: this.smartKeyStrings(),
            onPick: (key: string): void => {
              this.pickSort(key);
            }
          })
          ForEach(this.chipDimStrings(), (dimRaw: string) => {
            TorrentDimChip({
              title: TorrentSearchLogic.dimTitle(TorrentSearchLogic.dimOf(dimRaw)),
              summary: this.chipSummary(TorrentSearchLogic.dimOf(dimRaw)),
              labels: this.dimLabels(TorrentSearchLogic.dimOf(dimRaw)),
              selectedFlags: this.dimFlags(TorrentSearchLogic.dimOf(dimRaw)),
              onToggleIndex: (index: number): void => {
                this.toggleDim(TorrentSearchLogic.dimOf(dimRaw), index);
              },
              onRemove: (): void => {
                this.removeDim(TorrentSearchLogic.dimOf(dimRaw));
              }
            })
          }, (dimRaw: string) => dimRaw)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Start)
    }
    .width('100%')
  }

  /** 行内容分发（懒加载列表的一行按种类渲染） */
  @Builder
  RowContent(row: ResultRow) {
    if (row.kind === RowKind.groupHeader && row.header !== null) {
      this.GroupHeaderRow(row.header)
    } else if (row.kind === RowKind.hit && row.hit !== null) {
      this.HitRow(row.hit, row)
    } else if (row.kind === RowKind.grid && row.gridHits !== null) {
      this.GridRow(row.gridHits)
    } else if (row.kind === RowKind.expand) {
      Text(row.text)
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .margin({ left: 14, top: 2, bottom: 2 })
        .onClick(() => {
          this.expandGroup(row.key.substring(2));
        })
    } else if (row.kind === RowKind.gridNote) {
      Text(row.text)
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .width('100%')
        .padding({ top: 8 })
    }
  }

  /** 作品分组组头：可折叠；组头带版本数/最高分辨率/全集包/免费数标签 */
  @Builder
  GroupHeaderRow(header: GroupHeader) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([Theme.textFaint])
          .rotate({ angle: header.collapsed ? 0 : 90 })
        Text(header.nameZh.length > 0 ? header.nameZh : (header.nameEn.length > 0 ? header.nameEn : '未识别'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .maxLines(1)
          .flexShrink(1)
        if (header.nameZh.length > 0 && header.nameEn.length > 0) {
          Text(header.nameEn)
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .flexShrink(1)
        }
        if (header.info.length > 0) {
          Text(header.info)
            .fontSize(13)
            .fontColor(Theme.textFaint)
            .maxLines(1)
        }
      }
      .width('100%')
      Row({ space: 6 }) {
        this.Tag(`${header.count} 个版本`, Theme.textMuted, Theme.glassFill)
        if (header.topRes.length > 0) {
          this.Tag(`最高 ${header.topRes}`, Theme.accent2, Theme.glassFill)
        }
        if (header.hasPack) {
          this.Tag('全集包', '#99c7ff', 'rgba(127, 176, 255, 0.16)')
        }
        if (header.freeCount > 0) {
          this.Tag(`${header.freeCount} 个免费`, '#78d194', 'rgba(74, 222, 128, 0.15)')
        }
      }
      .margin({ left: 18 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10 })
    .onClick(() => {
      this.toggleCollapse(header.key);
    })
  }

  /** 列表 / 分组里的一条种子：解析片名（或原始名）、副标题行、徽标流、体积·做种/下载·发布时间 */
  @Builder
  HitRow(hit: TorrentHit, row: ResultRow) {
    Column({ space: 6 }) {
      // 标题区：分组视图用规格摘要代替重复片名；列表视图直接展示原始种子名
      if (row.specText.length > 0) {
        Text(row.specText)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      } else if (row.primary.length > 0) {
        Row({ space: 6 }) {
          Text(row.primary)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(1)
            .flexShrink(1)
          if (row.secondary.length > 0) {
            Text(row.secondary)
              .fontSize(11)
              .fontColor(Theme.textMuted)
              .maxLines(1)
              .flexShrink(1)
          }
          if (row.yearText.length > 0) {
            Text(row.yearText)
              .fontSize(11)
              .fontColor(Theme.textFaint)
          }
        }
        .width('100%')
      } else {
        Text(hit.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      if (row.subtitleLine.length > 0) {
        Text(row.subtitleLine)
          .fontSize(11)
          .fontColor(Theme.textMuted)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // 徽标流：站点、全集、促销、属性（最多 4 个，其余折叠成 +N）
      Flex({ wrap: FlexWrap.Wrap }) {
        this.Tag(hit.site_name, Theme.accent2, 'rgba(159, 176, 201, 0.10)')
        if (row.completeText.length > 0) {
          this.Tag(row.completeText, '#99c7ff', 'rgba(127, 176, 255, 0.16)')
        }
        ForEach(row.promos, (promo: Promo) => {
          this.Tag(promo.text, TorrentResultsPage.promoFg(promo.kind, false),
            TorrentResultsPage.promoBg(promo.kind, false))
        }, (promo: Promo) => `${promo.kind}-${promo.text}`)
        ForEach(row.badges, (badge: AttrBadge) => {
          this.Tag(badge.text, TorrentResultsPage.toneColor(badge.tone), Theme.glassFill)
        }, (badge: AttrBadge) => `${badge.tone}-${badge.text}`)
        if (row.badgeExtra > 0) {
          this.Tag(`+${row.badgeExtra}`, Theme.textFaint, 'rgba(0, 0, 0, 0)')
        }
      }
      .width('100%')

      // 指标行：体积 · 做种（0 红、<5 黄、≥100 亮绿）· 下载 · 完成数 · 相对时间
      Row({ space: 10 }) {
        if (TorrentSearchLogic.sizeText(hit).length > 0) {
          Text(TorrentSearchLogic.sizeText(hit))
            .fontSize(11)
            .fontColor(Theme.textMuted)
        }
        Text(`↑ ${hit.seeders}`)
          .fontSize(11)
          .fontColor(TorrentResultsPage.seederTone(hit.seeders))
        Text(`↓ ${hit.leechers}`)
          .fontSize(11)
          .fontColor(Theme.textFaint)
        if (hit.snatched > 0) {
          Text(`完成 ${hit.snatched}`)
            .fontSize(11)
            .fontColor(Theme.textMuted)
        }
        Blank()
        if ((hit.upload_time ?? '') !== '') {
          Text(Formatters.relative(hit.upload_time ?? null))
            .fontSize(11)
            .fontColor(Theme.textMuted)
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor('rgba(16, 18, 25, 0.82)')
    .borderRadius(16)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.06)' })
    .onClick(() => {
      this.openActions(hit);
    })
  }

  /** 图览模式的一行网格（两张海报卡并排） */
  @Builder
  GridRow(hits: TorrentHit[]) {
    Row({ space: 12 }) {
      ForEach(hits, (hit: TorrentHit) => {
        Column() {
          this.PosterCard(hit)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }, (hit: TorrentHit) => `${hit.site_id}-${hit.torrent_id}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 图览模式的海报卡：海报 + 促销角标 + 季集 chip + 底部文字信息 */
  @Builder
  PosterCard(hit: TorrentHit) {
    Column({ space: 0 }) {
      Stack() {
        RemoteImage({ url: hit.poster_url ?? '' })
          .width('100%')
          .height('100%')
        Column() {
        }
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['rgba(255, 255, 255, 0.05)', 0], ['rgba(0, 0, 0, 0.4)', 1]]
        })
        if ((hit.poster_url ?? '') === '') {
          Text(hit.site_name)
            .fontSize(11)
            .fontColor(Theme.textFaint)
        }
      }
      .width('100%')
      .aspectRatio(0.667)
      .borderRadius(12)
      .clip(true)
      .overlay(this.PosterPromos(hit), { align: Alignment.TopStart })
      .overlay(this.PosterCount(hit), { align: Alignment.TopEnd })
      .overlay(this.PosterSeasonChip(hit), { align: Alignment.BottomStart })
      .onClick(() => {
        this.openActions(hit);
      })

      Column({ space: 2 }) {
        Row({ space: 4 }) {
          Text(this.posterTitle(hit))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.posterHasName(hit) ? Theme.text : Theme.textMuted)
            .maxLines(1)
            .flexShrink(1)
          if (this.posterHasName(hit) && this.parsedYear(hit).length > 0) {
            Text(this.parsedYear(hit))
              .fontSize(11)
              .fontColor(Theme.textMuted)
          }
        }
        .width('100%')
        if (this.posterSpec(hit).length > 0) {
          Text(this.posterSpec(hit))
            .fontSize(11)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .width('100%')
        }
        Row({ space: 4 }) {
          Text(this.posterMeta(hit))
            .fontSize(10)
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .layoutWeight(1)
          Text(`↑${hit.seeders}`)
            .fontSize(10)
            .fontColor('#78d194')
          Text(`↓${hit.leechers}`)
            .fontSize(10)
            .fontColor('#e0c29e')
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 4, right: 4, top: 6 })
      .onClick(() => {
        this.openActions(hit);
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 海报左上角的促销角标（实底版本） */
  @Builder
  PosterPromos(hit: TorrentHit) {
    Column({ space: 4 }) {
      ForEach(TorrentSearchLogic.promos(hit), (promo: Promo) => {
        this.Tag(promo.text, TorrentResultsPage.promoFg(promo.kind, true),
          TorrentResultsPage.promoBg(promo.kind, true))
      }, (promo: Promo) => `${promo.kind}-${promo.text}`)
    }
    .alignItems(HorizontalAlign.Start)
    .padding(6)
  }

  /** 海报右上角的图片数 */
  @Builder
  PosterCount(hit: TorrentHit) {
    if (this.posterImageCount(hit) > 0) {
      Text(`${this.posterImageCount(hit)} 图`)
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor('#ffffff')
        .padding({ left: 5, right: 5, top: 2, bottom: 2 })
        .backgroundColor('rgba(0, 0, 0, 0.6)')
        .borderRadius(9)
        .margin(6)
    }
  }

  /** 海报左下角的季集 chip；pack（全集 / 整季包）用醒目底色 */
  @Builder
  PosterSeasonChip(hit: TorrentHit) {
    if (this.seasonChipText(hit).length > 0) {
      Text(this.seasonChipText(hit))
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.seasonChipPack(hit) ? '#ffffff' : '#99c7ff')
        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
        .backgroundColor(this.seasonChipPack(hit) ? 'rgba(59, 130, 246, 0.85)' : 'rgba(0, 0, 0, 0.7)')
        .borderRadius(6)
        .margin(6)
    }
  }

  /** 小标签（徽标/组头标签共用） */
  @Builder
  Tag(text: string, fg: string, bg: string) {
    Text(text)
      .fontSize(10)
      .fontColor(fg)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .backgroundColor(bg)
      .borderRadius(5)
      .margin({ right: 4, bottom: 4 })
  }

  /** 站点状态弹层：逐站进度/结果数/失败原因 */
  @Builder
  SitesSheet() {
    Column({ space: 12 }) {
      Row() {
        Blank()
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(40)
          .height(40)
          .onClick(() => {
            this.showSitesSheet = false;
          })
      }
      .width('100%')

      Text('站点状态')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')

      ForEach(this.sites, (site: SiteSearchStatus) => {
        Row({ space: 8 }) {
          Circle({ width: 6, height: 6 }).fill(this.siteDotColor(site))
          Text(site.site_name)
            .fontSize(14)
            .fontColor(Theme.text)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.siteStateText(site))
            .fontSize(12)
            .fontColor(this.siteFailed(site) ? Theme.danger : Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
      }, (site: SiteSearchStatus) => `${site.site_id}-${site.count}-${site.error ?? ''}`)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(Theme.bg)
  }

  /** 行操作面板（对应 iOS `TorrentActions` 的弹出菜单） */
  @Builder
  ActionsSheet() {
    Column({ space: 12 }) {
      Row() {
        Blank()
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(40)
          .height(40)
          .onClick(() => {
            this.showActions = false;
          })
      }
      .width('100%')

      if (this.actionHit !== null) {
        Text((this.actionHit as TorrentHit).title)
          .fontSize(14)
          .fontColor(Theme.text)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Column({ space: 0 }) {
          this.ActionRow('下载', '交给下载器，先问清存到哪',
            this.busy ? Theme.textFaint : Theme.accentStrong, (): void => {
              this.download(this.actionHit as TorrentHit);
            })
          if (this.grabSubscriptionId > 0) {
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
            this.ActionRow('投给订阅', `交给「${this.grabSubscriptionTitle}」`,
              Theme.accentStrong, (): void => {
                this.grabToSubscription(this.actionHit as TorrentHit);
              })
          }
          Divider().color(Theme.line).margin({ left: 16, right: 16 })
          this.ActionRow('复制标题', '长按可选中复制', Theme.text, (): void => {
            this.copyTitle(this.actionHit as TorrentHit);
          })
          if (this.detailUrlOf(this.actionHit as TorrentHit).length > 0) {
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
            this.ActionRow('查看详情', (this.actionHit as TorrentHit).site_name, Theme.textMuted,
              (): void => {
                this.showActions = false;
                this.openDetailUrl(this.actionHit as TorrentHit);
              })
          }
        }
        .width('100%')
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(Theme.bg)
  }

  @Builder
  ActionRow(title: string, subtitle: string, color: string, onTap: () => void) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(16)
          .fontColor(color)
        Text(subtitle)
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .onClick(() => {
      onTap();
    })
  }
}
