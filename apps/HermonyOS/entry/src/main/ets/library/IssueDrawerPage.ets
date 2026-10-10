import { common } from '@kit.AbilityKit';
import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { HandoffCenter, runHandoff, handoffMessage, HandoffResult } from '../settings/HandoffCenter';
import { ChatParams } from '../agent/ChatPage';
import { MovieClawApi } from '../api/Endpoints';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import {
  ClaimBatchPayload,
  DiscoveredTitleDetailsView,
  DiscoveredTitleView,
  MissingFileView,
  MissingItemView,
  ReviewGroupView,
  ReviewItemView,
  TitleSearchPayload,
  UnidentifiedCandidateView,
  UnidentifiedFileView,
  UnidentifiedGroupView
} from '../api/Models';
import { AppFooter } from '../common/AppFooter';

/**
 * 三个页签各自的行数据源（LazyForEach 用）。
 *
 * 原来整页 Scroll > Column 里按页签一个圆角容器 ForEach 全量建。改成外层 List，当前页签的
 * 行进一个 ListItemGroup（保留 insetGrouped 圆角容器 + 行间分隔线），LazyForEach 只建可视区
 * 附近的行。数据源装的是**经过搜索过滤后的**数组——load / 切页签 / 搜索词变化时都要重喂
 * （见 syncIssueSources）。行内嵌套的文件小列表本就短小，保留 ForEach。
 */
class MissingRowSource implements IDataSource {
  private items: MissingItemView[] = [];
  private listeners: DataChangeListener[] = [];
  totalCount(): number { return this.items.length; }
  getData(index: number): MissingItemView { return this.items[index]; }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) { this.listeners.splice(at, 1); }
  }
  setItems(items: MissingItemView[]): void {
    this.items = items;
    for (const listener of this.listeners) { listener.onDataReloaded(); }
  }
}

class UnidentifiedRowSource implements IDataSource {
  private items: UnidentifiedGroupView[] = [];
  private listeners: DataChangeListener[] = [];
  totalCount(): number { return this.items.length; }
  getData(index: number): UnidentifiedGroupView { return this.items[index]; }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) { this.listeners.splice(at, 1); }
  }
  setItems(items: UnidentifiedGroupView[]): void {
    this.items = items;
    for (const listener of this.listeners) { listener.onDataReloaded(); }
  }
}

class ReviewRowSource implements IDataSource {
  private items: ReviewGroupView[] = [];
  private listeners: DataChangeListener[] = [];
  totalCount(): number { return this.items.length; }
  getData(index: number): ReviewGroupView { return this.items[index]; }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) { this.listeners.splice(at, 1); }
  }
  setItems(items: ReviewGroupView[]): void {
    this.items = items;
    for (const listener of this.listeners) { listener.onDataReloaded(); }
  }
}

/** 事项页签（对应 iOS `IssueTab`；取值与 Web IssueTab 一致） */
class IssueTab {
  static readonly missing: string = 'missing';
  static readonly unidentified: string = 'unidentified';
  static readonly review: string = 'review';
  static readonly ignored: string = 'ignored';
}

/** 事项抽屉的路由参数（会序列化，不要用 instanceof） */
export class IssueParams {
  readonly libraryId: number;
  readonly initialTab: string;
  /** 库是不是电影库（认领的 TMDB 引用类型由它决定：movie / tv） */
  readonly movie: boolean;

  constructor(libraryId: number, initialTab: string, movie: boolean) {
    this.libraryId = libraryId;
    this.initialTab = initialTab;
    this.movie = movie;
  }

  static of(param: Object | undefined | null): IssueParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: IssueParams = param as IssueParams;
    const id: number = raw.libraryId;
    if (!Number.isFinite(id) || id <= 0) {
      return null;
    }
    const tab: string = raw.initialTab;
    return new IssueParams(Math.floor(id),
      tab === undefined || tab === null || tab.length === 0 ? IssueTab.missing : tab,
      raw.movie === true);
  }
}

/**
 * 进入确认面板的最小信息（对应 iOS `IssueClaimSeed`）：来自候选 chip 或搜索结果，
 * 详情由确认面板异步补全。
 */
export class IssueClaimSeed {
  readonly tmdbId: number;
  readonly title: string;
  readonly year: number | null;
  readonly posterUrl: string | null;
  readonly episodeCount: number | null;
  readonly reasons: string[];

  constructor(tmdbId: number, title: string, year: number | null = null,
    posterUrl: string | null = null, episodeCount: number | null = null,
    reasons: string[] = []) {
    this.tmdbId = tmdbId;
    this.title = title;
    this.year = year;
    this.posterUrl = posterUrl;
    this.episodeCount = episodeCount;
    this.reasons = reasons;
  }

  static fromCandidate(candidate: UnidentifiedCandidateView): IssueClaimSeed {
    return new IssueClaimSeed(candidate.tmdb_id, candidate.title,
      candidate.year ?? null, null, candidate.episode_count ?? null, candidate.reasons);
  }

  /** 组名/条目名 → 搜索词：去掉 [tmdbid=…] 等标记块与尾部年份括号（同 Web searchSeedFromLabel） */
  static searchText(fromLabel: string): string {
    return fromLabel
      .replace(/[\[{][^\]}]*[\]}]/g, ' ')
      .replace(/\((?:18|19|20)\d{2}\)\s*$/, '')
      .replace(/\s+/g, ' ')
      .trim();
  }
}

/** TMDB 页面地址（「在 TMDB 打开核对」「去 TMDB 补录」） */
export class IssueTMDBLink {
  static title(movie: boolean, id: number): string {
    return `https://www.themoviedb.org/${movie ? 'movie' : 'tv'}/${id}`;
  }

  static fresh(movie: boolean): string {
    return `https://www.themoviedb.org/${movie ? 'movie' : 'tv'}/new`;
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function IssueDrawerBuilder() {
  IssueDrawerPage()
}

/**
 * 待处理事项抽屉（对应 iOS `Features/Library/IssueDrawer.swift`）。
 *
 * 单库页上三个角标（缺失 / 未识别 / 身份复核）与 ⋯ 菜单里的「待处理」都到这里，
 * 只是初始页签不同。产品语义照 iOS：**只列需要用户行动才能推进的运行时问题**，
 * 正常运行时为空；修好后服务端自动消退，不需要「清理」。
 *
 * 刷新节奏照 iOS：30 秒一轮（父页海报墙空闲时的同一节奏）。
 *
 * **本轮先不做**：批量操作按钮、认领面板（`IssueClaimPanels` 430 行——
 * 未识别文件认领到某部作品的流程）、「放错库了」的类型不符引导、已忽略页签。
 */
@ComponentV2
export struct IssueDrawerPage {
  private navStack: NavPathStack = new NavPathStack();
  private libraryId: number = 0;
  private movie: boolean = false;
  private started: boolean = false;
  private timer: number = -1;

  @Local private tab: string = IssueTab.missing;
  @Local private query: string = '';
  @Local private missing: MissingItemView[] = [];
  @Local private unidentified: UnidentifiedGroupView[] = [];
  @Local private review: ReviewGroupView[] = [];
  @Local private ignored: UnidentifiedGroupView[] = [];
  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  /** 行级动作在跑（顶栏「全部忽略」要跟着禁用） */
  @Local private busy: boolean = false;
  /** 有没有接入模型：没接入就不渲染「交给 AI 分析」（同 iOS） */
  @Local private handoffAvailable: boolean = false;
  @Local private handoffBusy: boolean = false;
  /** 生成好的工单（会话页还没做，先把内容摊给用户看） */
  @Local private showTicket: boolean = false;
  @Local private ticketTitle: string = '';
  @Local private ticketBody: string = '';
  /** 交接起好的会话 id（用来跳会话页） */
  @Local private ticketSessionId: string = '';
  @Local private errorMessage: string = '';
  /** 四个页签的懒加载数据源 */
  private missingSource: MissingRowSource = new MissingRowSource();
  private unidentifiedSource: UnidentifiedRowSource = new UnidentifiedRowSource();
  private reviewSource: ReviewRowSource = new ReviewRowSource();
  private ignoredSource: UnidentifiedRowSource = new UnidentifiedRowSource();

  /** 把经过搜索过滤后的当前各页签数组喂给数据源；load / 切页签 / 搜索词变化时都要调 */
  private syncIssueSources(): void {
    this.missingSource.setItems(this.filteredMissing());
    this.unidentifiedSource.setItems(this.filteredUnidentified());
    this.reviewSource.setItems(this.filteredReview());
    this.ignoredSource.setItems(this.filteredIgnored());
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 取数

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const missing: MissingItemView[] = await api.libraryMissingList(this.libraryId);
      const unidentified: UnidentifiedGroupView[] =
        await api.libraryIdentificationListUnidentifiedFiles(this.libraryId);
      const review: ReviewGroupView[] =
        await api.libraryIdentificationListReviewCases(this.libraryId);
      const ignored: UnidentifiedGroupView[] =
        await api.libraryIdentificationListIgnoredFiles(this.libraryId);
      this.missing = missing;
      this.unidentified = unidentified;
      this.review = review;
      this.ignored = ignored;
      this.failed = false;
      this.errorMessage = '';
      this.syncIssueSources();
    } catch (error) {
      // 已有数据时不打扰：保留上次结果，下轮自愈（同 iOS）
      if (this.missing.length === 0 && this.unidentified.length === 0
        && this.review.length === 0 && this.ignored.length === 0) {
        this.failed = true;
        this.errorMessage = this.messageOf(error);
      }
    } finally {
      this.loading = false;
    }
  }

  private startPoll(): void {
    if (this.timer >= 0) {
      return;
    }
    this.timer = setInterval((): void => {
      this.load();
    }, 30000);
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 派生

  private keyword(): string {
    return this.query.trim().toLowerCase();
  }

  /** 缺失：按片名过滤 */
  private filteredMissing(): MissingItemView[] {
    const key: string = this.keyword();
    if (key.length === 0) {
      return this.missing;
    }
    const out: MissingItemView[] = [];
    for (const item of this.missing) {
      if (item.title.toLowerCase().indexOf(key) >= 0) {
        out.push(item);
      }
    }
    return out;
  }

  /** 未识别：按文件名过滤（任一条文件命中即保留整组） */
  private filteredUnidentified(): UnidentifiedGroupView[] {
    const key: string = this.keyword();
    if (key.length === 0) {
      return this.unidentified;
    }
    const out: UnidentifiedGroupView[] = [];
    for (const group of this.unidentified) {
      let hit: boolean = group.label.toLowerCase().indexOf(key) >= 0;
      if (!hit) {
        for (const file of group.files) {
          if (file.file_path.toLowerCase().indexOf(key) >= 0) {
            hit = true;
            break;
          }
        }
      }
      if (hit) {
        out.push(group);
      }
    }
    return out;
  }

  private filteredReview(): ReviewGroupView[] {
    const key: string = this.keyword();
    if (key.length === 0) {
      return this.review;
    }
    const out: ReviewGroupView[] = [];
    for (const group of this.review) {
      if (group.label.toLowerCase().indexOf(key) >= 0) {
        out.push(group);
      }
    }
    return out;
  }

  /** 已忽略：按组名或文件名过滤（同待识别口径） */
  private filteredIgnored(): UnidentifiedGroupView[] {
    const key: string = this.keyword();
    if (key.length === 0) {
      return this.ignored;
    }
    const out: UnidentifiedGroupView[] = [];
    for (const group of this.ignored) {
      let hit: boolean = group.label.toLowerCase().indexOf(key) >= 0;
      if (!hit) {
        for (const file of group.files) {
          if (file.file_path.toLowerCase().indexOf(key) >= 0) {
            hit = true;
            break;
          }
        }
      }
      if (hit) {
        out.push(group);
      }
    }
    return out;
  }

  private currentCount(): number {
    if (this.tab === IssueTab.missing) {
      return this.missing.length;
    }
    if (this.tab === IssueTab.unidentified) {
      let files: number = 0;
      for (const group of this.unidentified) {
        files += group.file_count;
      }
      return files;
    }
    if (this.tab === IssueTab.review) {
      return this.review.length;
    }
    let ignoredFiles: number = 0;
    for (const group of this.ignored) {
      ignoredFiles += group.file_count;
    }
    return ignoredFiles;
  }

  /** 「放错库了」的文件数：认领解决不了（TMDB 的 movie/tv 是两套 id 空间），单独给修复引导 */
  private kindMismatchFiles(): number {
    let files: number = 0;
    for (const group of this.unidentified) {
      if (group.code === 'kind_mismatch') {
        files += group.file_count;
      }
    }
    return files;
  }

  /** 页签下面那句说明（对应 iOS 的 `tab.explanation`；Web 原文照搬） */
  private explanation(): string {
    if (this.tab === IssueTab.missing) {
      return '这些条目在库里有记录，但磁盘上的文件已经不在了。补回文件后重新扫描即可恢复。';
    }
    if (this.tab === IssueTab.unidentified) {
      return '同一目录的文件聚成一组，认领一次整组生效；点候选可先核对海报简介再确认。状态标签悬停看完整原因。';
    }
    if (this.tab === IssueTab.review) {
      return '识别器升级后重新核对了这些条目，新结论与现有身份不一致。身份没有被自动改动——由你拍板：采纳新结论改挂条目，或维持现状。拍板后不再提醒。';
    }
    return '这些文件你选择过「忽略」，之后每次扫描都会直接跳过，不再占用待识别清单（磁盘文件一直都在）。识别器在持续变强，当初认不出的现在未必认不出——「恢复」即可让它重新参与识别。';
  }

  private searchPrompt(): string {
    if (this.tab === IssueTab.missing) {
      return '按片名过滤…';
    }
    return '按文件名过滤…';
  }

  // MARK: 动作

  private switchTab(tab: string): void {
    if (tab === this.tab) {
      return;
    }
    this.tab = tab;
    // 切页签清空过滤词（同 iOS）
    this.query = '';
    this.syncIssueSources();
  }

  /** 行级动作开始/结束的 busy 汇报（顶栏「全部忽略」跟着禁用） */
  private actionStarted(): void {
    this.busy = true;
  }

  private actionEnded(): void {
    this.busy = false;
  }

  /**
   * 忽略全部待识别文件（对应 iOS `ignoreAllUnidentified`）：
   * 破坏性动作先确认；只打忽略标记，绝不动磁盘。
   */
  private ignoreAll(): void {
    if (this.busy || this.unidentified.length === 0) {
      return;
    }
    let files: number = 0;
    for (const group of this.unidentified) {
      files += group.file_count;
    }
    this.getUIContext().showAlertDialog({
      title: '全部忽略',
      message: `忽略全部 ${files} 个待识别文件？\n\n之后扫描不再过问它们（不动磁盘；可在「已忽略」里恢复）。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '全部忽略',
        action: (): void => {
          this.runIgnoreAll();
        }
      }
    });
  }

  private async runIgnoreAll(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busy = true;
    try {
      await api.libraryIdentificationIgnoreAllUnidentifiedFiles({ library_id: this.libraryId });
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /**
   * 交给 AI 分析（对应 iOS `ActivityHandoffButton`）：两步——后端组装工单 → 起会话。
   * 会话页还没做，所以把工单内容摊出来给用户看（也知道自己交出去了什么）。
   */
  private async handoff(kind: string, ref: string): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.handoffBusy) {
      return;
    }
    this.handoffBusy = true;
    try {
      const result: HandoffResult = await runHandoff(api, kind, ref);
      this.ticketTitle = result.title;
      this.ticketBody = result.prompt;
      this.ticketSessionId = result.sessionId;
      this.showTicket = true;
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: handoffMessage(error) });
    } finally {
      this.handoffBusy = false;
    }
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        Row() {
          PageTopBar({ title: '待处理', onBack: (): void => {
          this.navStack.pop();
        }})
          // 右上角动作（原来挂在原生 menus 上；改自绘顶栏后要自己放）
          this.TopMenus()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        this.SearchField()
        // Scroll > Column 全量建改成 List：当前页签的行进 ListItemGroup（保留 insetGrouped
        // 圆角容器 + 行间分隔线），LazyForEach 只建可视区附近的行。
        List({ space: 10 }) {
          ListItem() {
            this.TabPicker()
          }
          ListItem() {
            Text(this.explanation())
              .fontSize(12)
              .fontColor(Theme.textMuted)
              .width('100%')
          }
          if (this.tab === IssueTab.unidentified && this.kindMismatchFiles() > 0) {
            ListItem() {
              // 「放错库了」引导（对应 iOS）：认领解决不了，给修复路径
              Text(`有 ${this.kindMismatchFiles()} 个文件的实际类型与本库不符（`
                + `${this.movie ? '剧集文件在电影库' : '电影文件在剧集库'}），认领无法解决。`
                + '个别文件放错了：把文件移到对应类型的库即可；整库类型建错了：删除本库并以正确类型重建'
                + '（删库不会动磁盘文件），重新扫描即可恢复。')
                .fontSize(12)
                .fontColor(Theme.warning)
                .width('100%')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .backgroundColor('rgba(251,191,36,0.10)')
                .borderRadius(10)
            }
          }
          this.Rows()
          ListItem() {
            AppFooter()
          }
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .cachedCount(4)
        .width('100%')
        .alignListItem(ListItemAlign.Start)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: Theme.tabBarInset })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    // iOS .navigationTitle("待处理") + inline：NavDestination 原生标题栏，去掉自绘 TopBar
    .hideTitleBar(true)
    .bindSheet($$this.showTicket, this.TicketSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: IssueParams | null = IssueParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.libraryId = params.libraryId;
        this.movie = params.movie;
        this.tab = params.initialTab;
        this.load();
        this.startPoll();
        // 有没有接入模型：没接入就整个不渲染「交给 AI 分析」（同 iOS）
        const api: MovieClawApi | null = this.api();
        if (api !== null) {
          HandoffCenter.ensureChecked(api).then((ok: boolean): void => {
            this.handoffAvailable = ok;
          });
        }
      }
    })
  }

  /** 右上角动作：交给 AI 分析（原自绘顶栏右侧按钮，移入原生标题栏）；计数胶囊一并带过来 */
  @Builder
  TopMenus() {
    Row({ space: 8 }) {
      if (this.handoffAvailable) {
        Text(this.handoffBusy ? '整理中…' : '交给 AI 分析')
          .fontSize(14)
          .fontColor(this.handoffBusy ? Theme.textFaint : Theme.accentStrong)
          .onClick(() => {
            if (!this.handoffBusy) {
              // 待处理清单这一屏对应后端的 `notice` 类型（ref 用当前页签 + 库 id 定位）
              this.handoff('notice', `${this.libraryId}-${this.tab}`);
            }
          })
      }
      if (this.tab === IssueTab.unidentified && this.unidentified.length > 0) {
        Text('全部忽略')
          .fontSize(14)
          .fontColor(this.busy ? Theme.textFaint : Theme.textMuted)
          .onClick(() => {
            this.ignoreAll();
          })
      }
      if (this.currentCount() > 0) {
        Text(`${this.currentCount()}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMuted)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor('rgba(255,255,255,0.07)')
          .borderRadius(10)
      }
    }
  }

  /** 搜索框（对应 iOS 的 `.searchable`，占位随页签变） */
  @Builder
  SearchField() {
    // 横向留白加在区块级（搜索框自身不带 margin），避免其 width('100%') 顶出屏幕右缘
    Column() {
      Search({ value: this.query, placeholder: this.searchPrompt() })
        .width('100%')
        .height(40)
        .placeholderColor(Theme.textFaint)
        .placeholderFont({ size: 15 })
        .textFont({ size: 15 })
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(20)
        .onChange((value: string): void => {
          this.query = value;
          this.syncIssueSources();
        })
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 10 })
  }

  /**
   * 工单面板：把后端组装的诊断工单摊给用户看。
   * **会话页还没做**，所以这里先让用户知道「交出去了什么」，而不是静默起一个他看不到的会话。
   */
  @Builder
  TicketSheet() {
    Column({ space: 12 }) {
      Row() {
        Text(this.ticketTitle)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(36)
          .height(36)
          .onClick(() => {
            this.showTicket = false;
          })
      }
      .width('100%')
      .padding({ top: 10 })
      Text('会话已建好，内容就是下面这份工单（由后端带着现场自检组装，不是前端拼的）。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
      Scroll() {
        Text(this.ticketBody)
          .fontSize(13)
          .fontColor(Theme.text)
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(10)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      Text(this.ticketSessionId.length > 0 ? '打开会话' : '会话没建起来')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(this.ticketSessionId.length > 0 ? '#0b0d12' : Theme.textFaint)
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 13, bottom: 13 })
        .backgroundColor(this.ticketSessionId.length > 0 ? Theme.accent : Theme.glassFill)
        .borderRadius(Theme.cardRadius)
        .onClick(() => {
          if (this.ticketSessionId.length > 0) {
            this.showTicket = false;
            this.navStack.pushPathByName('chat', new ChatParams(this.ticketSessionId));
          }
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor(Theme.bg)
  }

  /** 页签：缺失 N / 待识别 N / 身份复核 N / 已忽略 N（计数为 0 时不带数字） */
  @Builder
  TabPicker() {
    Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row }) {
      this.TabChip(IssueTab.missing, '缺失', this.missing.length)
      this.TabChip(IssueTab.unidentified, '待识别', this.unidentifiedFileTotal())
      this.TabChip(IssueTab.review, '身份复核', this.review.length)
      this.TabChip(IssueTab.ignored, '已忽略', this.ignoredFileTotal())
    }
    .width('100%')
  }

  @Builder
  TabChip(tab: string, label: string, count: number) {
    Text(count > 0 ? `${label} ${count}` : label)
      .fontSize(14)
      .fontColor(this.tab === tab ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.tab === tab ? Theme.accent : Theme.glassFill)
      .borderRadius(16)
      .onClick(() => {
        this.switchTab(tab);
      })
  }

  private unidentifiedFileTotal(): number {
    let files: number = 0;
    for (const group of this.unidentified) {
      files += group.file_count;
    }
    return files;
  }

  private ignoredFileTotal(): number {
    let files: number = 0;
    for (const group of this.ignored) {
      files += group.file_count;
    }
    return files;
  }

  @Builder
  Rows() {
    if (this.loading) {
      ListItem() {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(24)
            .height(24)
            .color(Theme.textMuted)
          Text('正在加载…')
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .padding({ top: 60 })
        .justifyContent(FlexAlign.Center)
      }
    } else if (this.failed) {
      ListItem() {
        Column({ space: 12 }) {
          Text('待处理清单加载失败')
            .fontSize(15)
            .fontColor(Theme.text)
          Text(this.errorMessage)
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .textAlign(TextAlign.Center)
          Text('重试')
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.accentStrong)
            .padding({ left: 20, right: 20, top: 9, bottom: 9 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(18)
            .onClick(() => {
              this.load();
            })
        }
        .width('100%')
        .padding({ top: 60 })
        .justifyContent(FlexAlign.Center)
      }
    } else if (this.tab === IssueTab.missing) {
      this.MissingRows()
    } else if (this.tab === IssueTab.unidentified) {
      this.UnidentifiedRows()
    } else if (this.tab === IssueTab.review) {
      this.ReviewRows()
    } else {
      this.IgnoredRows()
    }
  }

  /** 缺失：一部作品一条，下面挂它缺的文件 */
  @Builder
  MissingRows() {
    if (this.filteredMissing().length === 0) {
      ListItem() {
        this.EmptyState('没有缺失的文件')
      }
    } else {
      // 一个圆角容器 + 行间分隔线（insetGrouped）
      ListItemGroup() {
        LazyForEach(this.missingSource, (item: MissingItemView, index: number) => {
          ListItem() {
            // ListItem 只允许一个子组件：卡片 + 行间分隔线包进同一个外层 Column
            Column() {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  Text(item.title)
                    .fontSize(15)
                    .fontWeight(600)
                    .fontColor(Theme.text)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${item.files.length} 个文件`)
                    .fontSize(12)
                    .fontColor(Theme.danger)
                }
                .width('100%')
                ForEach(item.files, (file: MissingFileView) => {
                  Row({ space: 8 }) {
                    Text(file.file_path)
                      .fontSize(12)
                      .fontColor(Theme.textMuted)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(Formatters.bytes(file.size_bytes))
                      .fontSize(12)
                      .fontColor(Theme.textFaint)
                  }
                  .width('100%')
                }, (file: MissingFileView) => `${file.id}`)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(14)
              if (index < this.filteredMissing().length - 1) {
                Divider().color(Theme.line).margin({ left: 16, right: 16 })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }, (item: MissingItemView) => `${item.media_item_id}`)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  /** 未识别：一组一条；组内是认领的完整流程（候选 → 确认 / 搜索） */
  @Builder
  UnidentifiedRows() {
    if (this.filteredUnidentified().length === 0) {
      ListItem() {
        this.EmptyState('没有待识别的文件')
      }
    } else {
      ListItemGroup() {
        LazyForEach(this.unidentifiedSource, (group: UnidentifiedGroupView) => {
          ListItem() {
            UnidentifiedGroupRow({
              group: group,
              movie: this.movie,
              libraryId: this.libraryId,
              onChanged: (): Promise<void> => this.load(),
              onBusyChanged: (busy: boolean): void => {
                if (busy) {
                  this.actionStarted();
                } else {
                  this.actionEnded();
                }
              }
            })
          }
        }, (group: UnidentifiedGroupView) => `${group.key}-${group.file_count}`)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  /** 身份复核：现身份 vs 新识别结论并排对比，采纳或维持一键拍板（整组生效） */
  @Builder
  ReviewRows() {
    if (this.filteredReview().length === 0) {
      ListItem() {
        this.EmptyState('没有待复核的识别结果')
      }
    } else {
      ListItemGroup() {
        LazyForEach(this.reviewSource, (group: ReviewGroupView) => {
          ListItem() {
            ReviewGroupRow({
              group: group,
              onChanged: (): Promise<void> => this.load(),
              onBusyChanged: (busy: boolean): void => {
                if (busy) {
                  this.actionStarted();
                } else {
                  this.actionEnded();
                }
              }
            })
          }
        }, (group: ReviewGroupView) => `${group.key}-${group.file_count}`)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  /** 已忽略：只有一个动作「恢复」——归档视图不该再摆认领/搜索那一套 */
  @Builder
  IgnoredRows() {
    if (this.filteredIgnored().length === 0) {
      ListItem() {
        this.EmptyState('没有已忽略的文件')
      }
    } else {
      ListItemGroup() {
        LazyForEach(this.ignoredSource, (group: UnidentifiedGroupView) => {
          ListItem() {
            IgnoredGroupRow({
              group: group,
              onChanged: (): Promise<void> => this.load(),
              onBusyChanged: (busy: boolean): void => {
                if (busy) {
                  this.actionStarted();
                } else {
                  this.actionEnded();
                }
              }
            })
          }
        }, (group: UnidentifiedGroupView) => `${group.key}-${group.file_count}`)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  @Builder
  EmptyState(message: string) {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle'))
        .fontSize(30)
        .fontColor([Theme.ok])
      Text(message)
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text('这里只列需要你处理的运行时问题，修复后会自动消失。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 60 })
    .justifyContent(FlexAlign.Center)
  }
}

// MARK: - 待识别组（认领流程）

/**
 * 一个待识别组（对应 iOS `IssueUnidentifiedGroupRow`）：
 * 头行是谁 + 次要动作（⋯）；状态、多大、主动作（重扫 / 搜索）；
 * 候选 chips 点一下进详情确认面板，再点收起；no_match 给 TMDB 补录引导。
 */
@ComponentV2
struct UnidentifiedGroupRow {
  @Require @Param group: UnidentifiedGroupView;
  @Require @Param movie: boolean;
  @Require @Param libraryId: number;
  /** 行级动作完成后刷新整页（对应 iOS onChanged） */
  @Require @Param onChanged: () => Promise<void>;
  @Require @Param onBusyChanged: (busy: boolean) => void;

  @Local private busy: boolean = false;
  @Local private errorMessage: string = '';
  @Local private expanded: boolean = false;
  /** ''=无面板；'search'=搜索；'confirm'=确认（对应 iOS IssueClaimPanelState） */
  @Local private panelMode: string = '';
  @Local private panelSeed: IssueClaimSeed | null = null;
  @Local private showsReason: boolean = false;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  /** 行内的动作执行：忙碌态汇报 + 行内错误（同 Web 每行自带 error 文案，不弹全局提示） */
  private async issueRun(work: () => Promise<void>): Promise<void> {
    this.busy = true;
    this.onBusyChanged(true);
    this.errorMessage = '';
    try {
      await work();
      await this.onChanged();
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.busy = false;
      this.onBusyChanged(false);
    }
  }

  // MARK: 动作

  /** 认领：整组文件挂到该 TMDB 条目 */
  private async claim(seed: IssueClaimSeed): Promise<void> {
    const ref: string = `tmdb:${this.movie ? 'movie' : 'tv'}:${seed.tmdbId}`;
    const fileIds: number[] = [];
    for (const file of this.group.files) {
      fileIds.push(file.id);
    }
    const payload: ClaimBatchPayload = { file_ids: fileIds, title_ref: ref };
    await this.issueRun(async (): Promise<void> => {
      const api: MovieClawApi | null = this.api();
      if (api === null) {
        return;
      }
      await api.libraryIdentificationAssignFilesToTitle(payload);
    });
  }

  /** TMDB 不可达有确定解法：重新扫描 */
  private async rescan(): Promise<void> {
    const libraryId: number = this.group.library_id;
    await this.issueRun(async (): Promise<void> => {
      const api: MovieClawApi | null = this.api();
      if (api === null) {
        return;
      }
      await api.libraryScanStart(libraryId);
    });
  }

  /** 忽略整组（破坏性：多文件先确认；只打标记不动磁盘） */
  private ignoreGroup(): void {
    if (this.busy) {
      return;
    }
    const run = async (): Promise<void> => {
      const fileIds: number[] = [];
      for (const file of this.group.files) {
        fileIds.push(file.id);
      }
      await this.issueRun(async (): Promise<void> => {
        const api: MovieClawApi | null = this.api();
        if (api === null) {
          return;
        }
        for (const id of fileIds) {
          await api.libraryIdentificationIgnoreFile(id);
        }
      });
    };
    if (this.group.file_count > 1) {
      this.getUIContext().showAlertDialog({
        title: '全部忽略',
        message: `忽略「${this.group.label}」的全部 ${this.group.file_count} 个文件？\n\n`
          + '之后扫描不再过问（不动磁盘；可在「已忽略」里恢复）。适合自录、花絮这类 TMDB 本就不会有条目的内容'
          + '——只是暂时认不出的建议先搜索认领。',
        primaryButton: {
          value: '取消',
          action: (): void => {
          }
        },
        secondaryButton: {
          value: '全部忽略',
          action: (): void => {
            run();
          }
        }
      });
    } else {
      run();
    }
  }

  private openUrl(url: string): void {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    context.openLink(url).catch((): void => {
      this.toast('打不开链接');
    });
  }

  // MARK: 派生

  /** 状态标签（对应 iOS IssueStatusBadge.meta；旧数据没有 code 时按有无候选粗分） */
  private statusLabel(): string {
    const code: string = this.group.code ?? '';
    if (code === 'tmdb_unreachable') {
      return 'TMDB 不可达';
    }
    if (code === 'kind_mismatch') {
      return '放错库了';
    }
    if (code === 'ambiguous') {
      return `${this.group.candidates.length} 个候选待定`;
    }
    if (code === 'no_match') {
      return 'TMDB 无匹配';
    }
    if (code === 'unparsable') {
      return '认不出片名';
    }
    return this.group.candidates.length === 0 ? 'TMDB 无匹配' : `${this.group.candidates.length} 个候选待定`;
  }

  private statusWarn(): boolean {
    const code: string = this.group.code ?? '';
    return code === 'tmdb_unreachable' || code === 'kind_mismatch';
  }

  // MARK: 视图

  build() {
    Column({ space: 6 }) {
      // 头行：是谁 + 次要动作（⋯）
      Row({ space: 8 }) {
        Text(this.group.label)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.MoreMenu()
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 状态、多大、主动作
      Row({ space: 8 }) {
        this.StatusBadge()
        Text(`${this.group.file_count} 个 · ${Formatters.bytes(this.group.total_size_bytes)}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
        Blank()
        // TMDB 不可达有确定解法，直接给按钮；其余给搜索入口
        if (this.group.code === 'tmdb_unreachable') {
          Text(this.busy ? '扫描中…' : '重新扫描')
            .fontSize(13)
            .fontColor(this.busy ? Theme.textFaint : Theme.accentStrong)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(14)
            .onClick(() => {
              if (!this.busy) {
                this.rescan();
              }
            })
        } else {
          Text('搜索')
            .fontSize(13)
            .fontColor(this.panelMode === 'search' ? Theme.accentStrong : Theme.textMuted)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor(this.panelMode === 'search' ? Theme.accentSoft : Theme.glassFill)
            .borderRadius(14)
            .onClick(() => {
              if (this.busy) {
                return;
              }
              if (this.panelMode === 'search') {
                this.panelMode = '';
              } else {
                this.panelMode = 'search';
                this.panelSeed = null;
              }
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // no_match 的两条真实出口：等扫描自动重试，或自己去 TMDB 补录
      if (this.group.code === 'no_match') {
        Column({ space: 2 }) {
          Text('每次扫描会自动重试识别。TMDB 是社区维护的数据库，确认缺这个条目可以')
            .fontSize(12)
            .fontColor(Theme.textFaint)
          Text('去 TMDB 补录该条目 ↗')
            .fontSize(12)
            .fontColor(Theme.accent)
            .decoration({ type: TextDecorationType.Underline })
            .onClick(() => {
              this.openUrl(IssueTMDBLink.fresh(this.movie));
            })
          Text('，收录后回来搜索认领；自录、花絮这类本就不会有条目的内容用「忽略」即可。')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      if (this.group.candidates.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row }) {
          ForEach(this.group.candidates, (candidate: UnidentifiedCandidateView) => {
            this.CandidateChip(candidate)
          }, (candidate: UnidentifiedCandidateView) => `${candidate.tmdb_id}`)
        }
        .width('100%')
      }

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }

      if (this.panelMode === 'search') {
        IssueClaimSearchPanel({
          movie: this.movie,
          initialQuery: IssueClaimSeed.searchText(this.group.label),
          onPick: (seed: IssueClaimSeed): void => {
            this.panelMode = 'confirm';
            this.panelSeed = seed;
          }
        })
      } else if (this.panelMode === 'confirm' && this.panelSeed !== null) {
        IssueClaimConfirmPanel({
          seed: this.panelSeed,
          movie: this.movie,
          fileCount: this.group.file_count,
          busy: this.busy,
          onConfirm: (): void => {
            const seed: IssueClaimSeed | null = this.panelSeed;
            if (seed !== null) {
              this.claim(seed);
            }
          },
          onCancel: (): void => {
            this.panelMode = '';
            this.panelSeed = null;
          }
        })
      }

      if (this.expanded) {
        this.FileList()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
  }

  /** 状态徽章：点一下弹完整原因（Web 悬停看原因的触屏等价） */
  @Builder
  StatusBadge() {
    Text(this.statusLabel())
      .fontSize(12)
      .fontColor(this.statusWarn() ? Theme.warning : Theme.textMuted)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .backgroundColor(this.statusWarn() ? 'rgba(251,191,36,0.16)' : 'rgba(255,255,255,0.07)')
      .borderRadius(6)
      .onClick(() => {
        if (this.group.reason !== null && this.group.reason !== undefined) {
          this.showsReason = !this.showsReason;
        }
      })
      .bindPopup(this.showsReason, {
        message: this.group.reason ?? '',
        placement: Placement.Bottom,
        onStateChange: (state: PopupStateChangeParam): void => {
          if (!state.isVisible) {
            this.showsReason = false;
          }
        }
      })
  }

  /** 候选 chip：点一下进详情确认面板，不直接认领；再点同一个收起 */
  @Builder
  CandidateChip(candidate: UnidentifiedCandidateView) {
    Row({ space: 6 }) {
      Text(candidate.year !== null && candidate.year !== undefined
        ? `${candidate.title} (${candidate.year})` : candidate.title)
        .fontSize(14)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (candidate.episode_count !== null && candidate.episode_count !== undefined
        && candidate.episode_count > 0) {
        Text(`${candidate.episode_count} 集`)
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
    }
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .margin({ right: 6, bottom: 6 })
    .backgroundColor(this.panelSeed !== null && this.panelSeed.tmdbId === candidate.tmdb_id
      ? 'rgba(205,214,230,0.28)' : 'rgba(205,214,230,0.12)')
    .borderRadius(8)
    .border({
      width: 1,
      color: this.panelSeed !== null && this.panelSeed.tmdbId === candidate.tmdb_id
        ? Theme.accent : 'rgba(205,214,230,0.4)'
    })
    .opacity(this.busy ? 0.4 : 1)
    .onClick(() => {
      if (this.busy) {
        return;
      }
      if (this.panelSeed !== null && this.panelSeed.tmdbId === candidate.tmdb_id) {
        this.panelMode = '';
        this.panelSeed = null;
        return;
      }
      this.panelMode = 'confirm';
      this.panelSeed = IssueClaimSeed.fromCandidate(candidate);
    })
  }

  /** 次要动作（查看文件 / 忽略）收进 ⋯，不跟主动作抢视线 */
  @Builder
  MoreMenu() {
    Row({ space: 2 }) {
      Text('⋯')
        .fontSize(16)
        .fontColor(Theme.textMuted)
        .width(30)
        .height(26)
        .textAlign(TextAlign.Center)
    }
    .backgroundColor(Theme.glassFill)
    .borderRadius(13)
    .onClick(() => {
      this.getUIContext().showAlertDialog({
        title: this.group.label,
        message: this.group.file_count > 1 ? '查看这组文件，或忽略整组。' : '查看该文件，或忽略。',
        primaryButton: {
          value: '取消',
          action: (): void => {
          }
        },
        secondaryButton: {
          value: this.expanded ? '收起文件' : '查看文件',
          action: (): void => {
            this.expanded = !this.expanded;
          }
        }
      });
    })
    .bindMenu([
      {
        value: this.expanded ? '收起文件' : '查看文件',
        action: (): void => {
          this.expanded = !this.expanded;
        }
      },
      {
        value: '忽略',
        action: (): void => {
          this.ignoreGroup();
        }
      }
    ])
  }

  /** 展开的文件清单（等宽小字，中间省略，可复制） */
  @Builder
  FileList() {
    Column({ space: 4 }) {
      Divider().color(Theme.line)
      ForEach(this.group.files, (file: UnidentifiedFileView) => {
        Text(file.file_path)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
      }, (file: UnidentifiedFileView) => `${file.id}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 4 })
  }
}

// MARK: - 认领确认面板

/**
 * 认领确认面板（对应 iOS `IssueClaimConfirmPanel`）：
 * 海报 + 简介 + 季数 + 演职员，看清楚是谁再点认领。
 * 详情加载失败不挡认领（给出「在 TMDB 打开核对」兜底）。
 */
@ComponentV2
struct IssueClaimConfirmPanel {
  @Require @Param seed: IssueClaimSeed;
  @Require @Param movie: boolean;
  @Require @Param fileCount: number;
  @Require @Param busy: boolean;
  @Require @Param onConfirm: () => void;
  @Require @Param onCancel: () => void;

  @Local private detail: DiscoveredTitleDetailsView | null = null;
  @Local private failed: boolean = false;

  aboutToAppear(): void {
    this.loadDetail();
  }

  private async loadDetail(): Promise<void> {
    this.detail = null;
    this.failed = false;
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      this.failed = true;
      return;
    }
    const ref: string = `tmdb:${this.movie ? 'movie' : 'tv'}:${this.seed.tmdbId}`;
    try {
      this.detail = await api.discoverGetTitleDetails(ref);
    } catch (error) {
      this.failed = true;
    }
  }

  private posterUrl(): string {
    const fromDetail: string = this.detail !== null && this.detail.title.poster_url.length > 0
      ? this.detail.title.poster_url : '';
    const raw: string = fromDetail.length > 0 ? fromDetail : (this.seed.posterUrl ?? '');
    return ImageUrls.resolve(AppModel.origin(), raw, null) ?? '';
  }

  /** 片名 · 年份 · 规模 · 对应季集数 · 评分 */
  private headlineMeta(): string {
    const parts: string[] = [];
    const year: number | null = this.detail !== null
      ? (this.detail.title.release_year ?? null) : this.seed.year;
    if (year !== null && year !== undefined) {
      parts.push(`${year}`);
    }
    if (this.detail !== null && this.detail.title.extent_label.length > 0) {
      parts.push(this.detail.title.extent_label);
    }
    if (this.seed.episodeCount !== null && this.seed.episodeCount > 0) {
      parts.push(`对应季 ${this.seed.episodeCount} 集`);
    }
    return parts.join('  ');
  }

  /** 「导演 a / b · 主演 c / d / e / f」 */
  private credits(): string {
    if (this.detail === null) {
      return '';
    }
    const parts: string[] = [];
    if (this.detail.metadata.directors.length > 0) {
      parts.push(`导演 ${this.detail.metadata.directors.slice(0, 2).join(' / ')}`);
    }
    if (this.detail.metadata.cast.length > 0) {
      const names: string[] = [];
      for (const member of this.detail.metadata.cast.slice(0, 4)) {
        names.push(member.name);
      }
      parts.push(`主演 ${names.join(' / ')}`);
    }
    return parts.join(' · ');
  }

  private openUrl(url: string): void {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    context.openLink(url).catch((): void => {
      this.getUIContext().getPromptAction().showToast({ message: '打不开链接' });
    });
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Column() {
          RemoteImage({ url: this.posterUrl() })
        }
        .width(70)
        .height(104)
        .borderRadius(8)
        .clip(true)

        Column({ space: 4 }) {
          Text(this.detail !== null ? this.detail.title.title : this.seed.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.headlineMeta().length > 0
            || (this.detail !== null && this.detail.title.provider_rating > 0)) {
            Row({ space: 8 }) {
              Text(this.headlineMeta())
                .fontSize(14)
                .fontColor(Theme.textMuted)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.detail !== null && this.detail.title.provider_rating > 0) {
                Text(`★ ${this.detail.title.provider_rating.toFixed(1)}`)
                  .fontSize(14)
                  .fontColor(Theme.warning)
              }
            }
            .width('100%')
          }
          if (this.seed.reasons.length > 0) {
            Text(`与本地文件的佐证：${this.seed.reasons.join('、')}`)
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.detail !== null && this.detail.title.overview.length > 0) {
            Text(this.detail.title.overview)
              .fontSize(12)
              .fontColor(Theme.textMuted)
              .lineHeight(17)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          } else if (this.failed) {
            Text('详情加载失败（不影响认领，可打开 TMDB 页面核对）')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          } else if (this.detail === null) {
            Text('正在加载详情…')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          if (this.credits().length > 0) {
            Text(this.credits())
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Divider().color(Theme.line)

      Row({ space: 8 }) {
        Text('在 TMDB 打开核对 ↗')
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .onClick(() => {
            this.openUrl(IssueTMDBLink.title(this.movie, this.seed.tmdbId));
          })
        Blank()
        if (this.movie && this.fileCount > 1) {
          Text('整组视为同一部片的多个版本')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .textAlign(TextAlign.End)
        }
      }
      .width('100%')

      Row({ space: 8 }) {
        Blank()
        Text('取消')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(16)
          .onClick(() => {
            this.onCancel();
          })
        Text(this.fileCount > 1 ? `认领全部 ${this.fileCount} 个文件` : '认领')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(Theme.accent)
          .borderRadius(16)
          .opacity(this.busy ? 0.5 : 1)
          .onClick(() => {
            if (!this.busy) {
              this.onConfirm();
            }
          })
      }
      .width('100%')
    }
    .padding(12)
    .backgroundColor('rgba(255,255,255,0.03)')
    .borderRadius(12)
    .border({ width: 1, color: Theme.line })
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// MARK: - TMDB 搜索面板

/**
 * TMDB 搜索面板（对应 iOS `IssueClaimSearchPanel`）：
 * 候选全不对时按片名自己检索（比手抄 TMDB ID 体面）。
 * 输入预填从组名剥出的片名；直接粘一串数字则按 ID 进确认面板。
 */
@ComponentV2
struct IssueClaimSearchPanel {
  @Require @Param movie: boolean;
  @Require @Param initialQuery: string;
  @Require @Param onPick: (seed: IssueClaimSeed) => void;

  @Local private query: string = '';
  @Local private results: DiscoveredTitleView[] | null = null;
  @Local private searching: boolean = false;
  @Local private errorMessage: string = '';
  @Local private started: boolean = false;

  aboutToAppear(): void {
    if (!this.started) {
      this.started = true;
      this.query = this.initialQuery;
    }
  }

  private trimmed(): string {
    return this.query.trim();
  }

  /** 输入是一串数字：按 TMDB ID 直接进确认面板 */
  private idOnly(): boolean {
    return /^\d{1,10}$/.test(this.trimmed());
  }

  private openUrl(url: string): void {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    context.openLink(url).catch((): void => {
      this.getUIContext().getPromptAction().showToast({ message: '打不开链接' });
    });
  }

  private async search(): Promise<void> {
    const q: string = this.trimmed();
    if (q.length === 0 || this.searching || this.idOnly()) {
      return;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.searching = true;
    this.errorMessage = '';
    try {
      const payload: TitleSearchPayload = { query: q, provider: 'tmdb', save_history: false };
      const view = await api.searchTitles(payload);
      // multi 搜索混排两种类型，认领只关心本库的类型
      const kind: string = this.movie ? 'movie' : 'tv';
      const hits: DiscoveredTitleView[] = [];
      for (const item of view.titles) {
        if (item.media_type === kind) {
          hits.push(item);
        }
      }
      this.results = hits;
    } catch (error) {
      this.results = null;
      if (error instanceof ApiError) {
        this.errorMessage = error.message.length > 0 ? error.message : `搜索失败（${error.status}）`;
      } else {
        this.errorMessage = '搜索失败';
      }
    } finally {
      this.searching = false;
    }
  }

  private posterUrl(item: DiscoveredTitleView): string {
    return ImageUrls.resolve(AppModel.origin(), item.poster_url, null) ?? '';
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ placeholder: '片名关键词，或直接粘 TMDB ID', text: this.query })
          .fontSize(14)
          .fontColor(Theme.text)
          .placeholderColor(Theme.textFaint)
          .placeholderFont({ size: 14 })
          .padding({ left: 10, right: 10 })
          .height(36)
          .layoutWeight(1)
          .backgroundColor('rgba(255,255,255,0.04)')
          .borderRadius(8)
          .border({ width: 1, color: Theme.line })
          .onChange((value: string): void => {
            this.query = value;
          })
          .onSubmit(() => {
            this.search();
          })
        if (this.idOnly()) {
          Text('查看该 ID')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#0b0d12')
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(Theme.accent)
            .borderRadius(16)
            .onClick(() => {
              const id: number = Number(this.trimmed());
              if (Number.isFinite(id)) {
                this.onPick(new IssueClaimSeed(id, `TMDB #${this.trimmed()}`));
              }
            })
        } else {
          Text(this.searching ? '搜索中…' : '搜索')
            .fontSize(14)
            .fontColor(this.searching || this.trimmed().length === 0 ? Theme.textFaint : Theme.textMuted)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(16)
            .onClick(() => {
              this.search();
            })
        }
      }
      .width('100%')

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }
      if (this.results !== null && this.results.length === 0 && this.errorMessage.length === 0) {
        Column({ space: 4 }) {
          Text(`没有找到${this.movie ? '电影' : '剧集'}结果，换个关键词试试`
            + '（TMDB 对中文名支持有限时可试英文/原名）。确认 TMDB 没收录的话，可以')
            .fontSize(12)
            .fontColor(Theme.textMuted)
          Text('去 TMDB 补录该条目 ↗')
            .fontSize(12)
            .fontColor(Theme.accent)
            .decoration({ type: TextDecorationType.Underline })
            .onClick(() => {
              this.openUrl(IssueTMDBLink.fresh(this.movie));
            })
          Text('——它是维基式社区库，收录后回来搜索或粘 ID 即可认领')
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      if (this.results !== null && this.results.length > 0) {
        Column({ space: 2 }) {
          ForEach(this.results, (item: DiscoveredTitleView) => {
            this.ResultRow(item)
          }, (item: DiscoveredTitleView) => item.title_ref)
        }
        .width('100%')
      }
    }
    .padding(12)
    .backgroundColor('rgba(255,255,255,0.03)')
    .borderRadius(12)
    .border({ width: 1, color: Theme.line })
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ResultRow(item: DiscoveredTitleView) {
    Row({ space: 10 }) {
      Column() {
        RemoteImage({ url: this.posterUrl(item) })
      }
      .width(32)
      .height(48)
      .borderRadius(4)
      .clip(true)
      Row({ space: 6 }) {
        Text(item.title)
          .fontSize(14)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.release_year !== null && item.release_year !== undefined) {
          Text(`${item.release_year}`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
      }
      .layoutWeight(1)
      if (item.provider_rating > 0) {
        Text(`★ ${item.provider_rating.toFixed(1)}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .borderRadius(8)
    .onClick(() => {
      const id: number = Number(item.external_id);
      if (Number.isFinite(id)) {
        this.onPick(new IssueClaimSeed(id, item.title, item.release_year ?? null,
          item.poster_url.length > 0 ? item.poster_url : null));
      }
    })
  }
}

// MARK: - 身份复核组

/**
 * 身份复核组（对应 iOS `IssueReviewGroupRow`）：
 * 现身份 vs 新识别结论并排对比，采纳或维持一键拍板（整组生效）。
 */
@ComponentV2
struct ReviewGroupRow {
  @Require @Param group: ReviewGroupView;
  @Require @Param onChanged: () => Promise<void>;
  @Require @Param onBusyChanged: (busy: boolean) => void;

  @Local private busy: boolean = false;
  @Local private errorMessage: string = '';

  /** 新识别结论的强调色（Web #c4b5fd） */
  private static readonly suggestionTint: string = '#c4b5fd';

  private async resolve(accept: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.onBusyChanged(true);
    this.errorMessage = '';
    try {
      const api: MovieClawApi | null = AppModel.shared.api;
      if (api !== null) {
        await api.libraryIdentificationResolveReview({
          file_ids: this.group.file_ids,
          decision: accept ? 'accept_suggestion' : 'keep_current'
        });
      }
      await this.onChanged();
    } catch (error) {
      if (error instanceof ApiError) {
        this.errorMessage = error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
      } else {
        this.errorMessage = '操作失败';
      }
    } finally {
      this.busy = false;
      this.onBusyChanged(false);
    }
  }

  private posterUrl(raw: string | null | undefined): string {
    return ImageUrls.resolve(AppModel.origin(), raw, null) ?? '';
  }

  build() {
    Column({ space: 10 }) {
      Column({ space: 2 }) {
        Text(this.group.label)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${this.group.file_count} 个文件 · ${Formatters.bytes(this.group.total_size_bytes)}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // 两个身份并排：看清是谁 vs 该是谁
      Row({ space: 8 }) {
        this.ReviewSide(this.group.current, false)
        Text('→')
          .fontSize(20)
          .fontColor(Theme.textFaint)
        this.ReviewSide(this.group.suggestion, true)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 8 }) {
        Text(this.busy ? '处理中…' : '采纳新结论')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(ReviewGroupRow.suggestionTint)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor('rgba(196,181,253,0.14)')
          .borderRadius(16)
          .onClick(() => {
            this.resolve(true);
          })
        Text(this.busy ? '' : '维持现状')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(16)
          .onClick(() => {
            this.resolve(false);
          })
      }
      .width('100%')

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
  }

  @Builder
  ReviewSide(info: ReviewItemView, suggestion: boolean) {
    Row({ space: 8 }) {
      Column() {
        RemoteImage({ url: this.posterUrl(info.poster_url) })
      }
      .width(36)
      .height(54)
      .borderRadius(6)
      .clip(true)
      Column({ space: 1 }) {
        Text(suggestion ? '新识别结论' : '现身份')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textFaint)
        Text(info.year !== null && info.year !== undefined
          ? `${info.title} (${info.year})` : info.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(suggestion ? ReviewGroupRow.suggestionTint : Theme.text)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (info.tmdb_id !== null && info.tmdb_id !== undefined) {
          Text(`tmdb ${info.tmdb_id}`)
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .alignItems(VerticalAlign.Top)
  }
}

// MARK: - 已忽略组

/**
 * 已忽略组（对应 iOS `IssueIgnoredGroupRow`）：
 * 只有一个动作「恢复」——归档视图不该再摆认领/搜索那一套。
 */
@ComponentV2
struct IgnoredGroupRow {
  @Require @Param group: UnidentifiedGroupView;
  @Require @Param onChanged: () => Promise<void>;
  @Require @Param onBusyChanged: (busy: boolean) => void;

  @Local private busy: boolean = false;
  @Local private errorMessage: string = '';
  @Local private expanded: boolean = false;

  private async restore(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.onBusyChanged(true);
    this.errorMessage = '';
    try {
      const api: MovieClawApi | null = AppModel.shared.api;
      if (api !== null) {
        const fileIds: number[] = [];
        for (const file of this.group.files) {
          fileIds.push(file.id);
        }
        await api.libraryIdentificationRestoreFiles({ file_ids: fileIds });
      }
      await this.onChanged();
    } catch (error) {
      if (error instanceof ApiError) {
        this.errorMessage = error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
      } else {
        this.errorMessage = '操作失败';
      }
    } finally {
      this.busy = false;
      this.onBusyChanged(false);
    }
  }

  build() {
    Column({ space: 6 }) {
      Text(this.group.label)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Row({ space: 10 }) {
        Text(`${this.group.file_count} 个文件 · ${Formatters.bytes(this.group.total_size_bytes)}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
        Blank()
        if (this.group.file_count > 1) {
          Text(this.expanded ? '收起文件' : '查看文件')
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .onClick(() => {
              this.expanded = !this.expanded;
            })
        }
        Text(this.busy ? '恢复中…' : '恢复')
          .fontSize(13)
          .fontColor(this.busy ? Theme.textFaint : Theme.accentStrong)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(14)
          .onClick(() => {
            this.restore();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }

      if (this.expanded) {
        Column({ space: 4 }) {
          Divider().color(Theme.line)
          ForEach(this.group.files, (file: UnidentifiedFileView) => {
            Text(file.file_path)
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .copyOption(CopyOptions.LocalDevice)
              .width('100%')
          }, (file: UnidentifiedFileView) => `${file.id}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .opacity(0.75)
  }
}
