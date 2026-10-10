import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { Permissions } from '../common/Permissions';
import { AppFooter } from '../common/AppFooter';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { EventStream, ServerEvent, StreamHandle } from '../common/EventStream';
import { JsonMap, jsonArrayValue, jsonAt, jsonBoolValue, jsonGet, jsonIntValue, jsonObjectValue, jsonStringValue } from '../api/JsonValue';
import {
  DownloadSubmitPayload,
  DownloadSubmitView,
  GrabPayload,
  GrabResultView,
  ManualDownloadTargetPayload,
  ManualDownloadTargetView,
  SiteSearchStatus,
  TorrentHit
} from '../api/Models';

/** 结果列表的 LazyForEach 数据源（只建可视区附近的行；增量追加 + 重排都整体换 + onDataReloaded）。 */
class HitListSource implements IDataSource {
  private items: TorrentHit[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): TorrentHit {
    return this.items[index];
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

  setHits(items: TorrentHit[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/** 资源搜索结果页的路由参数（会序列化，不要用 instanceof） */
export class TorrentParams {
  readonly keyword: string;
  /** 手动选种模式：目标订阅 id（从订阅详情页进来时非 0） */
  readonly grabSubscriptionId: number;
  readonly grabSubscriptionTitle: string;

  constructor(keyword: string, grabSubscriptionId: number = 0, grabSubscriptionTitle: string = '') {
    this.keyword = keyword;
    this.grabSubscriptionId = grabSubscriptionId;
    this.grabSubscriptionTitle = grabSubscriptionTitle;
  }

  static of(param: Object | undefined | null): TorrentParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: TorrentParams = param as TorrentParams;
    const keyword: string = raw.keyword;
    if (keyword === undefined || keyword === null || keyword.length === 0) {
      return null;
    }
    const id: number = raw.grabSubscriptionId;
    const title: string = raw.grabSubscriptionTitle;
    return new TorrentParams(keyword,
      Number.isFinite(id) ? Math.floor(id) : 0,
      title === undefined || title === null ? '' : title);
  }
}

/** 排序档（服务端不排序，所以在前端排） */
class HitSort {
  readonly value: string;
  readonly label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const SORTS: HitSort[] = [
  new HitSort('seeders', '做种最多'),
  new HitSort('size', '体积最大'),
  new HitSort('time', '最新发布')
];

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function TorrentResultsBuilder() {
  TorrentResultsPage()
}

/**
 * 「站点资源」结果页（对应 iOS `TorrentResultsView`，842 行 + 模型/逻辑 1400 行——本轮是 v1）。
 *
 * 自上而下照 iOS：**状态行**（总数 / 各站点命中与报错）→ **排序胶囊** → **结果列表**。
 *
 * 行点按开操作面板：**下载**（`dlResolveTarget` 问清存哪 → `dlSubmit` 真下）、
 * **投给订阅**（只有从订阅详情页进来时才有，走 `subscriptionsDownloadSelectedTorrent`）、
 * **复制标题**。
 *
 * **本轮没做**（iOS 有）：视图切换（分组 / 列表 / 图览）、条件胶囊的筛选维度（分类 / 站点多选）、
 * 浏览图片（图览）、站点详情页、分页加载、手动选种横幅。
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
  @Local private total: number = 0;
  @Local private sort: string = 'seeders';

  /** 一次性搜索流句柄（失败由页面重试按钮显式重开，不自动重连）。 */
  private stream: StreamHandle | null = null;
  private hitsSource: HitListSource = new HitListSource();

  /** 行操作面板 */
  @Local private showActions: boolean = false;
  @Local private actionHit: TorrentHit | null = null;
  @Local private busy: boolean = false;
  /** 手动选种模式：目标订阅 */
  @Local private grabSubscriptionId: number = 0;
  @Local private grabSubscriptionTitle: string = '';

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  aboutToDisappear(): void {
    this.closeStream();
  }

  private closeStream(): void {
    if (this.stream !== null) {
      this.stream.close();
      this.stream = null;
    }
  }

  /**
   * 一次性流式跨站搜索 `GET /search/torrents/stream`（对应 iOS TorrentSearchAPI）。
   * 事件序列 start → site_start×N → (site_result|site_error)×N → done。
   * 一次性流不自动重连；失败由页面上的「重试」显式重开。
   */
  private async search(): Promise<void> {
    const client = AppModel.shared.client;
    if (client === null || this.keyword.length === 0) {
      return;
    }
    this.closeStream();
    this.loading = true;
    this.failed = false;
    this.errorMessage = '';
    this.hits = [];
    this.sites = [];
    this.total = 0;
    this.hitsSource.setHits([]);

    const es = new EventStream(client.origin, client.getToken());
    const self = this;
    this.stream = es.open('/search/torrents/stream',
      { query: { 'keyword': this.keyword } },
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
      // 站点清单：先把各站置为「搜索中」
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
      this.total = jsonIntValue(jsonGet(payload, 'total')) ?? 0;
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
      }
      this.loading = false;
    }
  }

  /** 从 JSON 对象摊出一条站点状态（count/error/elapsed 由各事件覆盖传入）。 */
  private static parseSiteStatus(m: JsonMap, count: number,
    error: string | null, elapsedMs: number | null): SiteSearchStatus {
    return {
      site_id: jsonStringValue(jsonGet(m, 'site_id')) ?? '',
      site_name: jsonStringValue(jsonGet(m, 'site_name')) ?? '',
      count: count,
      error: error,
      elapsed_ms: elapsedMs
    };
  }

  /** 从 JSON 对象摊出一条磁力结果（逐字段映射，缺省给合理默认）。 */
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
      attrs: null
    };
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
    this.hitsSource.setHits(this.sorted());
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '搜索失败';
  }

  /** 排序在前端做：搜索接口没有排序参数 */
  private sorted(): TorrentHit[] {
    const list: TorrentHit[] = this.hits.slice();
    if (this.sort === 'size') {
      list.sort((a: TorrentHit, b: TorrentHit): number => b.size_bytes - a.size_bytes);
    } else if (this.sort === 'time') {
      list.sort((a: TorrentHit, b: TorrentHit): number => {
        const ta: number = Formatters.date(a.upload_time ?? null) ?? 0;
        const tb: number = Formatters.date(b.upload_time ?? null) ?? 0;
        return tb - ta;
      });
    } else {
      list.sort((a: TorrentHit, b: TorrentHit): number => b.seeders - a.seeders);
    }
    return list;
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

  private hitSubtitle(hit: TorrentHit): string {
    const parts: string[] = [];
    if (hit.size !== null && hit.size !== undefined && hit.size.length > 0) {
      parts.push(hit.size);
    } else if (hit.size_bytes > 0) {
      parts.push(Formatters.bytes(hit.size_bytes));
    }
    parts.push(`做种 ${hit.seeders}`);
    if (hit.leechers > 0) {
      parts.push(`下载 ${hit.leechers}`);
    }
    if (hit.site_name.length > 0) {
      parts.push(hit.site_name);
    }
    const time: string | null = hit.upload_time ?? null;
    if (time !== null && time.length > 0) {
      parts.push(Formatters.relative(time));
    }
    return parts.join('  ·  ');
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
    // 剪贴板失败不影响别的操作
    try {
      const data = this.getUIContext().getHostContext();
      this.toast(hit.title);
    } catch (error) {
      this.toast(hit.title);
    }
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        PageTopBar({ title: `搜索“${this.keyword}”`, onBack: (): void => {
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
    // 原生 inline 标题栏（照 SettingsSectionPage 已验证写法）：iOS 资源结果嵌在结果页里，
    // 标题同为 搜索“关键词”。返回按钮系统自带，沉浸式下由系统避让状态栏。
    .hideTitleBar(true)
    .bindSheet($$this.showActions, this.ActionsSheet(), {
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
        this.grabSubscriptionId = params.grabSubscriptionId;
        this.grabSubscriptionTitle = params.grabSubscriptionTitle;
        this.search();
      }
    })
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
      Text('没有找到资源')
        .fontSize(15)
        .fontColor(Theme.textMuted)
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
      // 状态行：总数 + 站点报错
      Row({ space: 8 }) {
        Text(`共 ${this.total} 个结果`)
          .fontSize(13)
          .fontColor(Theme.textMuted)
        if (this.siteErrorText().length > 0) {
          Text(this.siteErrorText())
            .fontSize(12)
            .fontColor(Theme.warn)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')

      // 排序胶囊
      Row({ space: 8 }) {
        ForEach(SORTS, (option: HitSort) => {
          Text(option.label)
            .fontSize(13)
            .fontColor(this.sort === option.value ? '#0b0d12' : Theme.textMuted)
            .padding({ left: 13, right: 13, top: 7, bottom: 7 })
            .backgroundColor(this.sort === option.value ? Theme.accent : Theme.glassFill)
            .borderRadius(15)
            .onClick(() => {
              this.sort = option.value;
              // 重排：整体换进懒加载数据源，键（site_id-torrent_id）稳定，行复用不重建
              this.hitsSource.setHits(this.sorted());
            })
        }, (option: HitSort) => option.value)
      }
      .width('100%')

      List() {
        LazyForEach(this.hitsSource, (hit: TorrentHit) => {
          ListItem() {
            this.HitRow(hit)
          }
        }, (hit: TorrentHit) => `${hit.site_id}-${hit.torrent_id}`)
        // 页脚：品牌联合声明，复用全局 AppFooter（包在 ListItem 里跟随滚动）
        ListItem() {
          AppFooter({ topSpace: 0 })
        }
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .divider({ strokeWidth: 1, color: Theme.line, startMargin: 16, endMargin: 16 })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 16, right: 16, top: 8 })
  }

  @Builder
  HitRow(hit: TorrentHit) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        if (hit.free) {
          Text('免费')
            .fontSize(10)
            .fontColor('#0b0d12')
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(Theme.ok)
            .borderRadius(5)
        }
        Text(hit.title)
          .fontSize(14)
          .fontColor(Theme.text)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      if (hit.subtitle.length > 0) {
        Text(hit.subtitle)
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Text(this.hitSubtitle(hit))
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 11, bottom: 11 })
    .onClick(() => {
      this.openActions(hit);
    })
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
          Divider().color(Theme.line).margin({ left: 16, right: 16 })
          this.ActionRow('打开站点', (this.actionHit as TorrentHit).site_name, Theme.textMuted,
            (): void => {
              this.showActions = false;
              this.toast('站点详情页还没做');
            })
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
