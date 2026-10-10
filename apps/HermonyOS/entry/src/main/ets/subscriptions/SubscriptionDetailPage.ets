import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { Formatters } from '../common/Formatters';
import { Permissions } from '../common/Permissions';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  ActivityView,
  DispatchPreviewView,
  LibraryView,
  PrepareView,
  ProgressView,
  RuleSetView,
  SearchNowView,
  SeasonOverview,
  SeasonCleanupPayload,
  SubscriptionDeleteView,
  SubscriptionDetailView,
  SubscriptionDownloadView,
  SubscriptionFollowFuturePayload,
  SubscriptionRemovalPreviewView,
  SubscriptionTargetPreviewPayload,
  SubscriptionTrackingStatePayload,
  SubscriptionUpdatePayload,
  WantedView, WantedUpgradeView } from '../api/Models';
import { JsonValue, jsonGet, jsonIntValue } from '../api/JsonValue';
import { Milestone, SubsColor, WantedLogic, WantedPresentation } from './WantedModel';
import { RuleSetText, typedSpec } from './RuleSetModel';
import { UpgradeRunParams } from './UpgradeRunPage';
import { MediaSourceAnnotationParams } from './MediaSourceAnnotationPage';
import { AppFooter } from '../common/AppFooter';

/** 订阅详情页的路由参数（路由参数会被序列化，不要用 instanceof） */
export class SubscriptionParams {
  readonly subscriptionId: number;
  /** 进入即打开洗一轮版（对应 iOS `openUpgradeRun`：媒体库「洗版」入口并轨到既有订阅） */
  readonly openUpgradeRun: boolean;

  constructor(subscriptionId: number, openUpgradeRun: boolean = false) {
    this.subscriptionId = subscriptionId;
    this.openUpgradeRun = openUpgradeRun;
  }

  static of(param: Object | undefined | null): SubscriptionParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: SubscriptionParams = param as SubscriptionParams;
    const id: number = raw.subscriptionId;
    if (!Number.isFinite(id) || id <= 0) {
      return null;
    }
    return new SubscriptionParams(Math.floor(id), raw.openUpgradeRun === true);
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function SubscriptionDetailBuilder() {
  SubscriptionDetailPage()
}

/**
 * 订阅详情页（对应 iOS `SubscriptionDetailView` / Web `subscription-inspector-view`）。
 *
 * 结构照 iOS：
 * 1. **摘要卡**：海报身份 → 配置事实（收录范围 / 自动续订 / 规则组）→ 收录进度条 → 操作区；
 * 2. **单集履历**：按季分组的「一集一条」，带状态与已下标题；
 * 3. **排查记录**：最近的活动流水。
 *
 * 刷新节奏照 iOS：**有在途投递（grabbed / downloaded）时 5 秒一轮，没有则零请求**——
 * 订阅页列表本身也在轮询，详情页不做无谓的定时拉取。
 *
 * **本轮先不做**（iOS 有、鸿蒙还没有）：「更多」管理面板（调整订阅、洗一轮版、更换规则组）、
 * 实时下载进度、取消订阅的移除预览（带删种/删文件选项）。取消订阅走的是简单确认。
 */
@ComponentV2
export struct SubscriptionDetailPage {
  private navStack: NavPathStack = new NavPathStack();
  private subscriptionId: number = 0;
  private started: boolean = false;
  /** 季的默认展开只在首载算一次（同 iOS `seasonsInitialized`）：别把用户手动收起的季再打开 */
  private seasonsInitialized: boolean = false;
  /** 预测后台刷新中：1.5 秒一轮只重取详情，最多 40 次（同 iOS `forecastPolls`） */
  private forecastTimer: number = -1;
  private forecastPolls: number = 0;
  /** 有在途投递时每 30 秒静默全量刷新（同 iOS `.polling(every: 30)`） */
  private silentTimer: number = -1;
  /** 进入即打开洗一轮版（对应 iOS `openUpgradeRun`，只消费一次） */
  private pendingUpgradeRun: boolean = false;
  private timer: number = -1;

  @Local private detail: SubscriptionDetailView | null = null;
  @Local private activities: ActivityView[] = [];
  /** 在途种子的实时下载快照（按 info_hash 找；有在途时 5 秒一轮） */
  @Local private downloads: SubscriptionDownloadView[] = [];
  /** 工单 id → 此刻仍未解决的失败活动（入库/投递失败） */
  @Local private failures: Record<string, ActivityView> = {};
  /** 展开里程碑链的工单 id（0 = 都没展开） */
  @Local private openWanted: number = 0;
  /** 排查记录是否展开（默认收起，同 iOS） */
  @Local private logOpen: boolean = false;
  /** 「更多」里的管理弹层（一个组件只能挂一个 bindSheet，用 sheetKind 分发内容） */
  @Local private showSheet: boolean = false;
  /** '' | 'adjust' | 'switch' | 'cancel' */
  @Local private sheetKind: string = '';
  @Local private sheetBusy: boolean = false;
  @Local private sheetError: string = '';
  /** 调整订阅：季勾选 + 入库库 */
  @Local private adjustSeasons: SeasonOverview[] = [];
  @Local private adjustSelected: number[] = [];
  @Local private adjustLibraryId: number = 0;
  @Local private adjustLibraries: LibraryView[] = [];
  /** 取消订阅（管理员）：移除预览 + 两个清理开关 */
  @Local private removal: SubscriptionRemovalPreviewView | null = null;
  @Local private removeTorrents: boolean = false;
  @Local private removeFiles: boolean = false;
  /** 减季后的清理追问（同 iOS `SeasonCleanupContent`） */
  @Local private cleanupSeasons: number[] = [];
  @Local private cleanupPreview: SubscriptionRemovalPreviewView | null = null;
  @Local private cleanupTorrents: boolean = false;
  @Local private cleanupFiles: boolean = false;
  /** 调整订阅里选库后的投递预检（同 iOS `DispatchPreviewNote`） */
  @Local private adjustDispatch: DispatchPreviewView | null = null;
  /** 管理员才拉：用来把「规则组」事实显示成名字而不是 #id（同 iOS，只有管理员能看到规则组） */
  @Local private ruleSets: RuleSetView[] = [];
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private busy: boolean = false;
  /** 展开的季（按季分组，默认展开第一季） */
  @Local private openSeasons: number[] = [];
  @Local private refreshing: boolean = false;

  aboutToAppear(): void {
    // 轮询由数据到位后按「有没有在途投递」决定（见 schedulePoll）
  }

  aboutToDisappear(): void {
    this.stopPoll();
    this.stopForecastPoll();
    this.stopSilentPoll();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 取数

  private async load(silent: boolean = false): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const view: SubscriptionDetailView = await api.subscriptionsGet(this.subscriptionId);
      this.detail = view;
      this.failed = false;
      this.errorMessage = '';
      this.initSeasons(view);
      this.schedulePoll();
      this.scheduleForecastPoll(view);
      // 媒体库「洗版」入口并轨：进来就直接打开洗一轮版（同 iOS `openUpgradeRun`，只消费一次）
      if (this.pendingUpgradeRun && this.canTune(view)) {
        this.pendingUpgradeRun = false;
        this.navStack.pushPathByName('upgradeRun', new UpgradeRunParams(this.subscriptionId));
      }
      if (view !== null && this.hasInFlight(view) && this.downloads.length === 0) {
        // 在途一出现就立刻拉一次实时进度（同 iOS reload 的 leading）
        this.refreshDownloads();
      }
      if (!silent) {
        this.loadActivities();
        this.loadRuleSets();
      }
    } catch (error) {
      if (this.detail === null) {
        this.failed = true;
        this.errorMessage = this.messageOf(error);
      }
    }
  }

  /** 默认展开第一季（同 iOS：只在首载时算一次，静默刷新不把用户手动收起的季重新打开） */
  private initSeasons(view: SubscriptionDetailView): void {
    if (this.seasonsInitialized) {
      return;
    }
    this.seasonsInitialized = true;
    const seasons: number[] = this.seasonNumbers(view);
    if (seasons.length > 0) {
      this.openSeasons = [seasons[0]];
    }
  }

  private async loadActivities(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      // 取 100 条：里程碑链要按工单回查「最新一条是不是失败活动」
      const list: ActivityView[] = await api.subscriptionsListActivities(this.subscriptionId, 100);
      this.activities = list;
      this.failures = WantedLogic.pendingFailures(list);
    } catch (error) {
      this.activities = [];
      this.failures = {};
    }
  }

  /** 在途种子的实时下载快照（纯读；无在途时不请求） */
  private async refreshDownloads(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const detail: SubscriptionDetailView | null = this.detail;
    if (api === null || detail === null || !this.hasInFlight(detail)) {
      return;
    }
    try {
      this.downloads = await api.subscriptionsListActiveDownloads(this.subscriptionId);
    } catch (error) {
      // 拿不到就先不画进度，不影响链本身
    }
  }

  /** 某工单的实时下载快照（按 info_hash 匹配） */
  private liveFor(wanted: WantedView): SubscriptionDownloadView | null {
    const hash: string | null = wanted.info_hash ?? null;
    if (hash === null || hash.length === 0) {
      return null;
    }
    if (wanted.status !== 'grabbed' && wanted.status !== 'downloaded') {
      return null;
    }
    for (const download of this.downloads) {
      if (download.info_hash === hash) {
        return download;
      }
    }
    return null;
  }

  /** 规则组清单：只有管理员会被展示「规则组」事实，所以也只有管理员去拉（同 iOS） */
  private async loadRuleSets(): Promise<void> {
    if (!this.isAdmin() || this.ruleSets.length > 0) {
      return;
    }
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.ruleSets = await api.rulesList();
    } catch (error) {
      this.ruleSets = [];
    }
  }

  private isAdmin(): boolean {
    return Permissions.fromSession(AppModel.shared.session).isAdmin;
  }

  /**
   * 有在途投递才轮询（对应 iOS：`hasInFlight` 时每 5 秒拉进度，无在途时零请求）。
   */
  private schedulePoll(): void {
    const detail: SubscriptionDetailView | null = this.detail;
    const inFlight: boolean = detail !== null && this.hasInFlight(detail);
    if (!inFlight) {
      this.stopPoll();
      return;
    }
    if (this.timer >= 0) {
      return;
    }
    this.timer = setInterval((): void => {
      this.load(true);
      this.refreshDownloads();
    }, 5000);
  }

  private stopPoll(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /** 预测后台刷新（同 iOS `.task(id: forecastPending)`）：1.5 秒只重取详情，最多 40 次 */
  private scheduleForecastPoll(view: SubscriptionDetailView): void {
    if (!view.forecast_pending) {
      this.forecastPolls = 0;
      return;
    }
    if (this.forecastTimer >= 0) {
      return;
    }
    this.forecastTimer = setInterval((): void => {
      if (this.forecastPolls >= 40) {
        this.stopForecastPoll();
        return;
      }
      this.forecastPolls++;
      const api: MovieClawApi | null = this.api();
      if (api === null) {
        return;
      }
      api.subscriptionsGet(this.subscriptionId).then((fresh: SubscriptionDetailView): void => {
        this.detail = fresh;
        if (!fresh.forecast_pending) {
          this.stopForecastPoll();
        }
      }).catch((): void => {
        // 单次失败就等下一轮
      });
    }, 1500);
  }

  private stopForecastPoll(): void {
    if (this.forecastTimer >= 0) {
      clearInterval(this.forecastTimer);
      this.forecastTimer = -1;
    }
  }

  /** 每 30 秒静默全量刷新（只在有在途投递时才真的发请求，同 iOS） */
  private startSilentPoll(): void {
    if (this.silentTimer >= 0) {
      return;
    }
    this.silentTimer = setInterval((): void => {
      const detail: SubscriptionDetailView | null = this.detail;
      if (detail !== null && this.hasInFlight(detail)) {
        this.load(true);
      }
    }, 30000);
  }

  private stopSilentPoll(): void {
    if (this.silentTimer >= 0) {
      clearInterval(this.silentTimer);
      this.silentTimer = -1;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 派生

  /** 有在途投递：抓到了或已下载但还没入库 */
  private hasInFlight(detail: SubscriptionDetailView): boolean {
    for (const wanted of detail.wanted) {
      if (wanted.status === 'grabbed' || wanted.status === 'downloaded') {
        return true;
      }
    }
    return false;
  }

  /** 按季分组的季号（降序：最新一季在最上面，特别篇 0 排最后；同 iOS `WantedBreakdown`） */
  private seasonNumbers(detail: SubscriptionDetailView): number[] {
    const seen: number[] = [];
    for (const wanted of detail.wanted) {
      if (seen.indexOf(wanted.season_number) < 0) {
        seen.push(wanted.season_number);
      }
    }
    seen.sort((a: number, b: number): number => b - a);
    return seen;
  }

  /** 一季里的集（降序：集号大的在上面） */
  private wantedOfSeason(detail: SubscriptionDetailView, season: number): WantedView[] {
    const out: WantedView[] = [];
    for (const wanted of detail.wanted) {
      if (wanted.season_number === season) {
        out.push(wanted);
      }
    }
    out.sort((a: WantedView, b: WantedView): number => b.episode_number - a.episode_number);
    return out;
  }

  /** 数字图例：一个色点 + 一句「标签 N」（同 iOS `legend`） */
  @Builder
  ProgressLegend(color: string, text: string) {
    Row({ space: 5 }) {
      Circle()
        .width(6)
        .height(6)
        .fill(color)
      Text(text)
        .fontSize(12)
        .fontColor(Theme.textMuted)
    }
    .margin({ right: 14, top: 2 })
  }

  /** 「下载中」：已抓取但还没入库的部分（同 iOS `inPipeline`） */
  private inPipeline(progress: ProgressView): number {
    const value: number = progress.grabbed - progress.imported;
    return value > 0 ? value : 0;
  }

  private percent(detail: SubscriptionDetailView): number {
    const progress: ProgressView = detail.progress;
    if (progress.total <= 0) {
      return 0;
    }
    return Math.min(100, Math.round(progress.imported * 100 / progress.total));
  }

  /**
   * 收录范围（配置事实，对齐 iOS `fact("收录范围", …)`）：电影 = 正片；剧集未勾季 = 未勾选季；
   * 否则「第 N、M 季」。「自动续订」「规则组」各自单独一列（见 summaryCard 的事实行）。
   */
  private scopeFact(detail: SubscriptionDetailView): string {
    if (detail.media.kind === 'movie') {
      return '正片';
    }
    const seasons: number[] = detail.selected_seasons;
    if (seasons.length === 0) {
      return '未勾选季';
    }
    return `第 ${seasons.map((s: number): string => `${s}`).join('、')} 季`;
  }

  /** 规则组事实：查得到就显示名字，查不到退化成 #id（同 iOS `ruleSetFact`） */
  private ruleSetFact(detail: SubscriptionDetailView): string {
    for (const rule of this.ruleSets) {
      if (rule.id === detail.rule_set_id) {
        return rule.name;
      }
    }
    return `#${detail.rule_set_id}`;
  }

  /** 状态词（同 iOS `SubscriptionStatusMeta.label`）：completed → 已收齐、paused → 已暂停、其余 → 追踪中 */
  private statusText(status: string): string {
    if (status === 'completed') {
      return '已收齐';
    }
    if (status === 'paused') {
      return '已暂停';
    }
    return '追踪中';
  }

  /**
   * 状态词（含洗版，对齐 iOS `statusLabel`）：洗版中补「洗版中（N）」；电影只有一个单元、
   * 单单元不带计数（只说「洗版中」）。
   */
  private statusLabel(detail: SubscriptionDetailView): string {
    const label: string = this.statusText(detail.status);
    const upgrading: number = detail.progress.upgrading;
    const upgradingText: string = detail.progress.total > 1 ? `洗版中（${upgrading}）` : '洗版中';
    if (detail.status === 'completed' && upgrading > 0) {
      return `已收齐 · ${upgradingText}`;
    }
    if (detail.status === 'active' && upgrading > 0 && detail.progress.wanted === 0) {
      return `${label} · ${upgradingText}`;
    }
    return label;
  }

  /** 状态点颜色（同 iOS）：已收齐=绿、已暂停=黄、追踪中=蓝 */
  private statusColor(status: string): string {
    if (status === 'completed') {
      return Theme.ok;
    }
    if (status === 'paused') {
      return Theme.warn;
    }
    return Theme.info;
  }

  // MARK: 动作

  /** 立即搜索缺的资源（对应 iOS 的「立即搜索」） */
  private async searchNow(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const view: SearchNowView = await api.subscriptionsSearchMissingResources(this.subscriptionId);
      // `reset_count` 是「跳过冷却、重新排队的缺口工单数」（模型里只有这一个字段）
      if (view.reset_count > 0) {
        this.toast(`已重新排队 ${view.reset_count} 条搜索`);
      } else {
        this.toast('没有可搜索的资源');
      }
      await this.load();
    } catch (error) {
      this.toast('发起搜索失败，请稍后再试');
    } finally {
      this.busy = false;
    }
  }

  /** 立即搜索的二次确认（文案照 iOS）：会跳过冷却并可能自动投递 */
  private confirmSearch(): void {
    const detail: SubscriptionDetailView | null = this.detail;
    if (detail === null) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: `立即搜索《${detail.media.title}》的缺失资源？`,
      message: '将跳过当前搜索冷却，重新搜索已经可以搜索的缺口。命中当前规则组的资源可能会自动提交下载。',
      primaryButton: {
        value: '返回',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '立即搜索',
        action: (): void => {
          this.searchNow();
        }
      }
    });
  }

  private async toggleFollow(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const detail: SubscriptionDetailView | null = this.detail;
    if (api === null || detail === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const payload: SubscriptionFollowFuturePayload = { enabled: !detail.follow_future };
      const updated: SubscriptionDetailView = await api.subscriptionsSetFollowFuture(this.subscriptionId, payload);
      this.detail = updated;
      this.toast(updated.follow_future ? '已打开自动续订' : '已关闭自动续订');
    } catch (error) {
      this.toast('操作失败，请稍后再试');
    } finally {
      this.busy = false;
    }
  }

  /** 取消订阅确认（文案照 iOS 成员路径）：取消键「先不」，避免和「取消订阅」两个都以「取消」开头 */
  private confirmCancel(): void {
    const detail: SubscriptionDetailView | null = this.detail;
    if (detail === null) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: `取消订阅《${detail.media.title}》？`,
      message: '将取消你的订阅关注；已经下载或入库的文件不会被删除。',
      primaryButton: {
        value: '先不',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '取消订阅',
        fontColor: Theme.danger,
        action: (): void => {
          this.cancelSubscription();
        }
      }
    });
  }

  /** 取消订阅：管理员走带移除预览的面板，成员只取消关注（对应 iOS 的 manage.remove） */
  private startRemove(): void {
    if (this.isAdmin()) {
      this.openSheet('cancel');
      return;
    }
    this.confirmCancel();
  }

  private async cancelSubscription(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busy = true;
    try {
      // 成员只取消自己的关注（同 iOS `subscriptionsUnsubscribe`）
      await api.subscriptionsUnsubscribe(this.subscriptionId);
      this.toast('已取消订阅');
      setTimeout((): void => {
        this.navStack.pop();
      }, 600);
    } catch (error) {
      this.toast('取消失败，请稍后再试');
    } finally {
      this.busy = false;
    }
  }

  /** 能否调整这条订阅（同 iOS `canTune`）：可订阅 + 是发起人/超管（后端 `can_manage`） */
  private canTune(detail: SubscriptionDetailView): boolean {
    return Permissions.fromSession(AppModel.shared.session).canSubscribe && detail.can_manage;
  }

  /** 立即搜索的显示条件（同 iOS）：可调整 + 有缺口 + 未暂停 */
  private showSearchNow(detail: SubscriptionDetailView): boolean {
    return this.canTune(detail) && detail.progress.wanted > 0 && detail.status !== 'paused';
  }

  /** 「更多」按钮的显示条件（同 iOS `showMore`）：能订阅或能管订阅 */
  private showMore(): boolean {
    const permissions: Permissions = Permissions.fromSession(AppModel.shared.session);
    return permissions.canSubscribe || permissions.isAdmin;
  }

  /** 「更多」菜单（对应 iOS `SubscriptionManageSheet`）：调整订阅 / 洗一轮版 / 自动续订 / 更换规则组 / 暂停 / 取消 */
  private moreMenuItems(detail: SubscriptionDetailView): MenuElement[] {
    const items: MenuElement[] = [];
    const permissions: Permissions = Permissions.fromSession(AppModel.shared.session);
    const canTune: boolean = this.canTune(detail);
    if (canTune) {
      items.push({
        value: '调整订阅…',
        action: (): void => {
          this.openSheet('adjust');
        }
      });
      items.push({
        value: '洗一轮版',
        action: (): void => {
          this.navStack.pushPathByName('upgradeRun', new UpgradeRunParams(this.subscriptionId));
        }
      });
      if (detail.media.kind !== 'movie') {
        items.push({
          value: detail.follow_future ? '关闭自动续订' : '开启自动续订',
          action: (): void => {
            this.toggleFollow();
          }
        });
      }
    }
    if (permissions.isAdmin) {
      items.push({
        value: '更换规则组…',
        action: (): void => {
          this.openSheet('switch');
        }
      });
    }
    if (canTune) {
      items.push({
        value: detail.status === 'paused' ? '恢复追踪' : '暂停追踪',
        action: (): void => {
          this.confirmTracking(detail);
        }
      });
    }
    if (permissions.canSubscribe) {
      items.push({
        value: '取消订阅',
        action: (): void => {
          this.startRemove();
        }
      });
    }
    return items;
  }

  // MARK: 更多里的弹层（一个组件只能挂一个 bindSheet，用 sheetKind 分发）

  private openSheet(kind: string): void {
    this.sheetKind = kind;
    this.sheetError = '';
    this.sheetBusy = false;
    if (kind === 'cancel') {
      this.removal = null;
      this.removeTorrents = false;
      this.removeFiles = false;
      this.loadRemovalPreview();
    } else if (kind === 'adjust') {
      this.loadAdjustData();
    }
    this.showSheet = true;
  }

  private closeSheet(): void {
    this.showSheet = false;
  }

  /** 调整订阅：季结构走 title-preview（幂等），库列表仅管理员 */
  private async loadAdjustData(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const detail: SubscriptionDetailView | null = this.detail;
    if (api === null || detail === null) {
      return;
    }
    this.adjustSelected = detail.selected_seasons.slice();
    this.adjustLibraryId = detail.library_id ?? 0;
    this.adjustSeasons = [];
    try {
      const payload: SubscriptionTargetPreviewPayload = {
        title_ref: `tmdb:${detail.media.kind}:${detail.media.tmdb_id}`
      };
      const preview: PrepareView = await api.uiSubscriptionsPreviewTitle(payload);
      this.adjustSeasons = preview.status === 'ready' ? preview.seasons : [];
      if (this.isAdmin()) {
        this.adjustLibraries = await api.libraryList(detail.media.kind, 'all');
      }
      this.loadAdjustDispatch();
    } catch (error) {
      this.sheetError = '加载季集与媒体库信息失败，请稍后重试';
    }
  }

  /** 调整订阅：选库即预演「下载会落到哪、能否自动入库」（同 iOS `DispatchPreviewNote(adjusting: true)`） */
  private async loadAdjustDispatch(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const detail: SubscriptionDetailView | null = this.detail;
    if (api === null || detail === null || !this.isAdmin()) {
      this.adjustDispatch = null;
      return;
    }
    this.adjustDispatch = null;
    try {
      this.adjustDispatch = await api.subscriptionsPreviewDownloadRouting(
        detail.media.kind, this.adjustLibraryId > 0 ? this.adjustLibraryId : undefined,
        detail.media.tmdb_id, detail.media.title, detail.media.year ?? undefined);
    } catch (error) {
      this.adjustDispatch = null;
    }
  }

  /** 投递预检人话（同 iOS `DispatchPreviewNote`：调整态只说监听目录、目录原样显示） */
  private adjustDispatchNote(): string {
    const preview: DispatchPreviewView | null = this.adjustDispatch;
    if (preview === null) {
      return '';
    }
    if (!preview.ok) {
      const warning: string | null = preview.warning ?? null;
      return warning !== null && warning.length > 0 ? warning : '按当前配置投递无法自动入库';
    }
    if (preview.mode === 'watch') {
      return `将投递到自动入库的监听目录 ${preview.path ?? ''}，下载完成后自动整理入库`;
    }
    const dir: string | null = preview.entry_dir ?? preview.path ?? null;
    return `将直接下载到库内目录 ${dir ?? ''}，完成后自动入账`;
  }

  private async saveAdjust(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const detail: SubscriptionDetailView | null = this.detail;
    if (api === null || detail === null || this.sheetBusy) {
      return;
    }
    this.sheetBusy = true;
    this.sheetError = '';
    try {
      const sorted: number[] = this.adjustSelected.slice();
      sorted.sort((a: number, b: number): number => a - b);
      const changed: boolean = detail.media.kind !== 'movie'
        && sorted.join(',') !== detail.selected_seasons.slice().sort(
          (a: number, b: number): number => a - b).join(',');
      // 移出范围的季（保存后的真实出域结果，不在前端推算，同 iOS）
      const dropped: number[] = changed
        ? detail.selected_seasons.filter((s: number): boolean => this.adjustSelected.indexOf(s) < 0)
        : [];
      const body: SubscriptionUpdatePayload = {
        // 电影没有季概念，不提交
        selected_seasons: detail.media.kind === 'movie' ? null : sorted,
        library_id: this.isAdmin() && this.adjustLibraryId > 0 ? this.adjustLibraryId : null
      };
      await api.subscriptionsUpdate(detail.id, body);
      // 减季且管理员：追问要不要顺手清理那一季的内容（同 iOS `SeasonCleanupContent`）
      if (dropped.length > 0 && this.isAdmin()) {
        const plan: SubscriptionRemovalPreviewView | null =
          await api.subscriptionsPreviewRemoval(detail.id, dropped);
        if (plan !== null && (plan.torrent_count > 0 || plan.library_file_count > 0)) {
          this.cleanupSeasons = dropped;
          this.cleanupPreview = plan;
          this.cleanupTorrents = false;
          this.cleanupFiles = false;
          this.sheetBusy = false;
          return;
        }
      }
      this.toast('订阅已调整');
      this.closeSheet();
      await this.load();
    } catch (error) {
      this.sheetError = this.messageOf(error);
    } finally {
      this.sheetBusy = false;
    }
  }

  /** 减季后的清理（同 iOS `SeasonCleanupContent` 的确认） */
  private async confirmSeasonCleanup(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.sheetBusy) {
      return;
    }
    this.sheetBusy = true;
    this.sheetError = '';
    try {
      const payload: SeasonCleanupPayload = {
        seasons: this.cleanupSeasons,
        delete_torrents: this.cleanupTorrents,
        delete_library_files: this.cleanupFiles
      };
      await api.subscriptionsCleanupSeasons(this.subscriptionId, payload);
      this.toast('正在后台清理，可在「任务中心」查看进度');
      this.cleanupPreview = null;
      this.closeSheet();
      await this.load();
    } catch (error) {
      this.sheetError = this.messageOf(error);
    } finally {
      this.sheetBusy = false;
    }
  }

  /** 调整订阅里「已有进度又要被移出」的季（同 iOS `droppedWithProgress`） */
  private droppedWithProgress(): number[] {
    const detail: SubscriptionDetailView | null = this.detail;
    if (detail === null || detail.media.kind === 'movie') {
      return [];
    }
    const progressed: number[] = [];
    for (const wanted of detail.wanted) {
      if (wanted.status !== 'wanted' && progressed.indexOf(wanted.season_number) < 0) {
        progressed.push(wanted.season_number);
      }
    }
    return detail.selected_seasons.filter(
      (s: number): boolean => this.adjustSelected.indexOf(s) < 0 && progressed.indexOf(s) >= 0);
  }

  private async loadRemovalPreview(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.removal = await api.subscriptionsPreviewRemoval(this.subscriptionId);
    } catch (error) {
      this.sheetError = '未能加载移除预览，请稍后重试';
    }
  }

  /** 管理员取消订阅：连带删下载任务 / 删媒体库文件（对应 iOS `confirmRemoval`） */
  private async confirmRemoval(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.sheetBusy) {
      return;
    }
    this.sheetBusy = true;
    this.sheetError = '';
    try {
      const result: SubscriptionDeleteView = await api.subscriptionsDelete(
        this.subscriptionId, this.removeTorrents, this.removeFiles);
      const jobId: string | null = result.cleanup_job_id ?? null;
      this.toast(jobId !== null && jobId.length > 0
        ? '已取消订阅，正在后台清理关联内容（可在任务中心查看进度）'
        : '已取消订阅');
      this.closeSheet();
      setTimeout((): void => {
        this.navStack.pop();
      }, 600);
    } catch (error) {
      this.sheetError = this.messageOf(error);
    } finally {
      this.sheetBusy = false;
    }
  }

  /** 规则组的条件摘要（同 iOS `RuleSetSwitchSheet`）：空 = 全不限 */
  private ruleSpecSummary(rule: RuleSetView): string {
    const chips: string[] = RuleSetText.summary(typedSpec(rule));
    return chips.length === 0 ? '全不限' : chips.join(' · ');
  }

  private async switchRule(rule: RuleSetView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const detail: SubscriptionDetailView | null = this.detail;
    if (api === null || detail === null || this.sheetBusy) {
      return;
    }
    if (rule.id === detail.rule_set_id) {
      this.closeSheet();
      return;
    }
    this.sheetBusy = true;
    this.sheetError = '';
    try {
      const body: SubscriptionUpdatePayload = { rule_set_id: rule.id };
      await api.subscriptionsUpdate(detail.id, body);
      this.toast('已更换规则组');
      this.closeSheet();
      await this.load();
    } catch (error) {
      this.sheetError = this.messageOf(error);
    } finally {
      this.sheetBusy = false;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private toggleSeason(season: number): void {
    const at: number = this.openSeasons.indexOf(season);
    if (at >= 0) {
      this.openSeasons.splice(at, 1);
    } else {
      this.openSeasons.push(season);
    }
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下会画进状态栏（压住时钟、返回键上半截点不动）
        Row() {
          // 标题照 iOS：就是影片名（`navigationTitle(detail?.media.title ?? "")`）
          PageTopBar({ title: this.detail === null
            ? ''
            : this.detail.media.title, onBack: (): void => {
          this.navStack.pop();
        }})
          // 「洗版」动作移到自绘顶栏右侧（原先是原生 menus）
          this.TopRight()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.failed) {
          this.ErrorState()
        } else if (this.detail === null) {
          this.LoadingState()
        } else {
          this.Content(this.detail as SubscriptionDetailView)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .bindSheet($$this.showSheet, this.ManageSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: SubscriptionParams | null = SubscriptionParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.subscriptionId = params.subscriptionId;
        this.pendingUpgradeRun = params.openUpgradeRun;
        this.load();
        this.startSilentPoll();
      }
    })
  }

  /** 右上角动作：洗版（仅当有可洗单元时出现）；点开独立的洗一轮版页（含选组 / 并入季 / 逐集体检报告） */
  @Builder
  TopRight() {
    if (this.upgradableCount() > 0) {
      Text('洗版')
        .fontSize(15)
        .fontColor(Theme.accentStrong)
        .padding({ left: 8, right: 8 })
        .onClick(() => {
          this.navStack.pushPathByName('upgradeRun', new UpgradeRunParams(this.subscriptionId));
        })
    }
  }

  /** 有多少个单元还能洗（`upgrade.active`）——为 0 时顶栏不出现「洗版」 */
  private upgradableCount(): number {
    const view: SubscriptionDetailView | null = this.detail;
    if (view === null) {
      return 0;
    }
    let count: number = 0;
    for (const wanted of view.wanted) {
      const upgrade: WantedUpgradeView | null = wanted.upgrade ?? null;
      if (upgrade !== null && upgrade.active) {
        count++;
      }
    }
    return count;
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(26)
        .height(26)
        .color(Theme.textMuted)
      Text('正在加载订阅详情…')
        .fontSize(14)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 12 }) {
      Text('未能加载该订阅，可能已被删除。')
        .fontSize(16)
        .fontWeight(600)
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
        .border({ width: 1, color: Theme.lineStrong })
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  Content(detail: SubscriptionDetailView) {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column({ space: 16 }) {
          this.SummaryCard(detail)
          this.SearchRoundBar()
          this.EpisodesSection(detail)
          if (this.activities.length > 0) {
            this.ActivitiesSection()
          }
          AppFooter()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        // 横向留白统一加在页面级（卡片与 section 都不再自己加 margin/padding）：
        // 卡片内用 width('100%') 的行才不会按"屏幕宽"撑开、顶到屏幕右缘
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 8, bottom: Theme.tabBarInset })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.None)
    }
    .onRefreshing(() => {
      this.load().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .height('100%')
  }

  /** 摘要卡：海报身份 → 配置事实 → 进度条 → 操作区（对应 iOS 第 1 块） */
  @Builder
  SummaryCard(detail: SubscriptionDetailView) {
    Column({ space: 14 }) {
      // 抬头：左「电影订阅 / 剧集订阅」，右状态点 + 状态词（洗版中时词里带计数）
      Row() {
        Text(detail.media.kind === 'movie' ? '电影订阅' : '剧集订阅')
          .fontSize(12)
          .fontWeight(600)
          .fontColor(Theme.accent2)
          .letterSpacing(3)
        Blank()
        Row({ space: 7 }) {
          Circle()
            .width(6)
            .height(6)
            .fill(this.statusColor(detail.status))
          Text(this.statusLabel(detail))
            .fontSize(15)
            .fontColor('rgba(255,255,255,0.65)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')

      // 海报身份：海报 + 片名（带年份）/ 原名 / 订阅于（对齐 iOS `summaryCard`）
      Row({ space: 16 }) {
        RemoteImage({
          url: ImageUrls.resolve(AppModel.origin(), detail.media.poster_url, ImageVariant.posterCard) ?? ''
        })
          .width(80)
          .aspectRatio(Theme.posterAspect)
          .backgroundColor(Theme.surface)
          .borderRadius(10)
          .clip(true)
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(detail.media.title)
              .fontSize(20)
              .fontWeight(700)
              .fontColor(Theme.text)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.mediaYear(detail) > 0) {
              Text(`${this.mediaYear(detail)}`)
                .fontSize(17)
                .fontColor('rgba(255,255,255,0.45)')
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)
          if (this.originalTitle(detail).length > 0) {
            Text(this.originalTitle(detail))
              .fontSize(15)
              .fontColor('rgba(255,255,255,0.55)')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(`订阅于 ${Formatters.dateTime(detail.created_at)}`)
            .fontSize(15)
            .fontColor('rgba(255,255,255,0.55)')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      // 配置事实：收录范围 / 自动续订（电影不显示）/ 规则组（仅管理员可见，同 iOS）
      Column() {
        Divider().color(Theme.line)
        Row({ space: 12 }) {
          this.Fact('收录范围', this.scopeFact(detail))
          if (detail.media.kind !== 'movie') {
            this.Fact('自动续订', detail.follow_future ? '已开启' : '已关闭')
          }
          if (this.isAdmin()) {
            this.Fact('规则组', this.ruleSetFact(detail))
          }
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Top)
        Divider().color(Theme.line)
      }
      .width('100%')

      // 收录进度（逐值照 iOS `ProgressStrip`）：标题行 + 三段式色条（高 6）+ 数字图例
      Column({ space: 8 }) {
        Row() {
          Text('收录进度')
            .fontSize(15)
            .fontWeight(600)
            .fontColor('rgba(255,255,255,0.85)')
          Blank()
          Text(`${detail.progress.imported} / ${detail.progress.total} ${detail.media.kind === 'movie' ? '部' : '集'}`)
            .fontSize(15)
            .fontColor('rgba(255,255,255,0.55)')
        }
        .width('100%')
        Row() {
          if (detail.progress.imported > 0) {
            Row()
              .layoutWeight(detail.progress.imported)
              .height(6)
              .backgroundColor(Theme.ok)
          }
          if (detail.progress.upgrading > 0) {
            Row()
              .layoutWeight(detail.progress.upgrading)
              .height(6)
              .backgroundColor('#5eead4')
          }
          if (detail.progress.downloaded > 0) {
            Row()
              .layoutWeight(detail.progress.downloaded)
              .height(6)
              .backgroundColor(Theme.info)
          }
          if (detail.progress.wanted > 0) {
            Row()
              .layoutWeight(detail.progress.wanted)
              .height(6)
              .backgroundColor(Theme.line)
          }
        }
        .width('100%')
        .height(6)
        .borderRadius(3)
        .clip(true)

        Flex({ wrap: FlexWrap.Wrap }) {
          this.ProgressLegend(Theme.ok, `已入库 ${detail.progress.imported}`)
          if (detail.progress.upgrading > 0) {
            this.ProgressLegend('#5eead4', `洗版中 ${detail.progress.upgrading}`)
          }
          this.ProgressLegend(Theme.info, `下载中 ${this.inPipeline(detail.progress)}`)
          this.ProgressLegend(Theme.textFaint, `缺失 ${detail.progress.wanted}`)
        }
        .width('100%')
      }
      .width('100%')

      // 操作区（同 iOS `actions`）：立即搜索 + 更多；暂停/自动续订/换组/取消都在「更多」里
      Row({ space: 8 }) {
        if (this.showSearchNow(detail)) {
          Text(this.busy ? '处理中…' : '立即搜索')
            .fontSize(15)
            .fontWeight(600)
            .fontColor('#0b0d12')
            .padding({ left: 18, right: 18, top: 9, bottom: 9 })
            .backgroundColor(Theme.accent)
            .borderRadius(18)
            .onClick(() => {
              this.confirmSearch();
            })
        }
        if (this.showMore()) {
          Text('更多')
            .fontSize(15)
            .fontColor(Theme.text)
            .padding({ left: 16, right: 16, top: 9, bottom: 9 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(18)
            .border({ width: 1, color: Theme.line })
            .bindMenu(this.moreMenuItems(detail))
        }
        Blank()
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(18)
    .border({ width: 1, color: Theme.line })
  }

  /** 配置事实一格：小字标签 + 值（等宽分栏，同 iOS `fact`） */
  @Builder
  Fact(label: string, value: string) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.textFaint)
      Text(value)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 年份取值（0 = 没有年份，不渲染） */
  private mediaYear(detail: SubscriptionDetailView): number {
    const year: number | null = detail.media.year ?? null;
    return year !== null && year > 0 ? year : 0;
  }

  /** 原名：与主标题相同（或为空）时不渲染 */
  private originalTitle(detail: SubscriptionDetailView): string {
    const raw: string = detail.media.original_title;
    return raw.length > 0 && raw !== detail.media.title ? raw : '';
  }

  /** 暂停 / 恢复追踪的二次确认（文案照 iOS）：暂停说明「已提交的下载不受影响，可随时恢复」 */
  private confirmTracking(detail: SubscriptionDetailView): void {
    const resuming: boolean = detail.status === 'paused';
    this.getUIContext().showAlertDialog({
      title: `${resuming ? '恢复' : '暂停'}《${detail.media.title}》的订阅追踪？`,
      message: resuming
        ? '恢复后会继续搜索缺失资源，并按当前规则自动投递符合条件的结果。'
        : '暂停后不会继续搜索或投递资源；已经提交的下载不受影响，可随时恢复。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: resuming ? '恢复追踪' : '暂停追踪',
        action: (): void => {
          this.setTracking(resuming ? 'active' : 'paused');
        }
      }
    });
  }

  private async setTracking(state: string): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      const body: SubscriptionTrackingStatePayload = { state: state };
      this.detail = await api.subscriptionsSetTrackingState(this.subscriptionId, body);
      this.toast(state === 'active' ? '已恢复订阅追踪' : '已暂停订阅追踪');
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  /** 按季分组的「一集一条」（对应 iOS `WantedBreakdown`；iOS 这一块没有标题，直接铺季分组） */
  @Builder
  EpisodesSection(detail: SubscriptionDetailView) {
    Column({ space: 14 }) {
      ForEach(this.seasonNumbers(detail), (season: number) => {
        Column() {
          Row({ space: 8 }) {
            SymbolGlyph(this.openSeasons.indexOf(season) >= 0
              ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
              .fontSize(14)
              .fontColor([Theme.textFaint])
            // 电影只有一个单元，季头写「正片」（同 iOS `seasonHeader`）
            Text(detail.media.kind === 'movie' ? '正片' : `第 ${season} 季`)
              .fontSize(15)
              .fontWeight(600)
              .fontColor(Theme.text)
            if (detail.media.kind !== 'movie') {
              Text(`${this.arrangedInSeason(detail, season)}/${this.wantedOfSeason(detail, season).length}`)
                .fontSize(15)
                .fontColor(Theme.textFaint)
            }
            if (this.upgradingInSeason(detail, season) > 0) {
              Text(`洗版中 ${this.upgradingInSeason(detail, season)}`)
                .fontSize(15)
                .fontColor('#5eead4')
            }
            Blank()
            // 收起态的迷你进度条：已排（非 wanted）/ 总数（同 iOS `seasonHeader`）
            if (detail.media.kind !== 'movie' && this.openSeasons.indexOf(season) < 0) {
              Stack({ alignContent: Alignment.Start }) {
                Row()
                  .width(48)
                  .height(4)
                  .backgroundColor('rgba(255,255,255,0.1)')
                  .borderRadius(2)
                Row()
                  .width(this.seasonBarWidth(detail, season))
                  .height(4)
                  .backgroundColor(this.seasonBarColor(detail, season))
                  .borderRadius(2)
              }
              .width(48)
              .height(4)
              .margin({ left: 8 })
            }
            // 管理员可对「无法确认档位」的季标注片源（同 iOS `seasonHeader` 的「标注片源」）
            if (this.canAnnotateSeason(detail, season)) {
              Text('标注片源')
                .fontSize(12)
                .fontColor(Theme.accentStrong)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor(Theme.glassFill)
                .borderRadius(8)
                .border({ width: 1, color: Theme.line })
                .onClick(() => {
                  this.navStack.pushPathByName('mediaSourceAnnotation',
                    new MediaSourceAnnotationParams(detail.media.media_item_id, season,
                      detail.media.kind === 'movie'));
                })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 11, bottom: 11 })
          .onClick(() => {
            this.toggleSeason(season);
          })

          if (this.openSeasons.indexOf(season) >= 0) {
            ForEach(this.wantedOfSeason(detail, season), (wanted: WantedView, index: number) => {
              if (index > 0) {
                Divider().color(Theme.line).margin({ left: 16, right: 16 })
              }
              this.EpisodeRow(wanted, detail.media.kind === 'movie')
            }, (wanted: WantedView) => `${wanted.id}`)
          }
        }
        .width('100%')
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      }, (season: number) => `${season}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 某一季里「已排（非 wanted）」的集数（季头迷你进度条的分子，同 iOS `arranged`） */
  private arrangedInSeason(detail: SubscriptionDetailView, season: number): number {
    let count: number = 0;
    for (const wanted of detail.wanted) {
      if (wanted.season_number === season && wanted.status !== 'wanted') {
        count++;
      }
    }
    return count;
  }

  /** 季头迷你进度条：48 宽按「已排 / 总数」比例填充（同 iOS 的 48 * arranged / items.count） */
  private seasonBarWidth(detail: SubscriptionDetailView, season: number): number {
    const total: number = this.wantedOfSeason(detail, season).length;
    if (total <= 0) {
      return 0;
    }
    return Math.max(2, 48 * this.arrangedInSeason(detail, season) / total);
  }

  /** 季头迷你进度条颜色：全排完=绿，否则=黄（同 iOS `SubsColor.ok` / `SubsColor.warn`） */
  private seasonBarColor(detail: SubscriptionDetailView, season: number): string {
    const total: number = this.wantedOfSeason(detail, season).length;
    return total > 0 && this.arrangedInSeason(detail, season) === total ? Theme.ok : Theme.warn;
  }

  /** 某一季里还在洗版的单元数（季头「洗版中 N」，同 iOS `seasonHeader`） */
  private upgradingInSeason(detail: SubscriptionDetailView, season: number): number {
    let count: number = 0;
    for (const wanted of detail.wanted) {
      if (wanted.season_number !== season) {
        continue;
      }
      const upgrade: WantedUpgradeView | null = wanted.upgrade ?? null;
      if (upgrade !== null && upgrade.active) {
        count++;
      }
    }
    return count;
  }

  /** 管理员可标注片源的季：有「无法确认档位」的单元（同 iOS `seasonHeader` 的 annotatable） */
  private canAnnotateSeason(detail: SubscriptionDetailView, season: number): boolean {
    if (!this.isAdmin()) {
      return false;
    }
    for (const wanted of detail.wanted) {
      if (wanted.season_number !== season) {
        continue;
      }
      const upgrade: WantedUpgradeView | null = wanted.upgrade ?? null;
      if (upgrade !== null && upgrade.indeterminate) {
        return true;
      }
    }
    return false;
  }

  /** 某工单此刻仍未解决的失败活动（入库失败优先在胶囊上体现） */
  private wantedFailure(wanted: WantedView): ActivityView | null {
    return WantedLogic.failureFor(this.failures, wanted.id);
  }

  /**
   * 工单展示态：入库失败是死局，胶囊自己变红（否则这一行与正常等待入库毫无区别）；
   * 其余走 `WantedLogic.presentation`。
   */
  private wantedPresentation(wanted: WantedView): WantedPresentation {
    const failure: ActivityView | null = this.wantedFailure(wanted);
    if (failure !== null && failure.type === 'import_failed') {
      return new WantedPresentation('入库失败', SubsColor.danger, failure.message);
    }
    return WantedLogic.presentation(wanted, Date.now());
  }

  /** 实时下载快照：入库失败时不看 */
  private wantedLive(wanted: WantedView): SubscriptionDownloadView | null {
    const failure: ActivityView | null = this.wantedFailure(wanted);
    if (failure !== null && failure.type === 'import_failed') {
      return null;
    }
    return this.liveFor(wanted);
  }

  private wantedChain(wanted: WantedView, isMovie: boolean): Milestone[] {
    return WantedLogic.milestones(wanted, isMovie, this.wantedLive(wanted), this.wantedFailure(wanted), Date.now());
  }

  private wantedStuck(wanted: WantedView, isMovie: boolean): number {
    return WantedLogic.stuckIndex(this.wantedChain(wanted, isMovie));
  }

  private isRowOpen(wanted: WantedView, isMovie: boolean): boolean {
    return isMovie || this.openWanted === wanted.id;
  }

  /** 一行「集号 + 胶囊」+ 说明 + 下载进度；点开（剧集）展开里程碑链 */
  @Builder
  EpisodeRow(wanted: WantedView, isMovie: boolean) {
    Column({ space: 0 }) {
      Column({ space: 6 }) {
        Row({ space: 10 }) {
          // 电影只有一个单元，行首写「正片」而不是 E01（同 iOS `WantedRow`）
          Text(isMovie ? '正片' : `E${wanted.episode_number < 10 ? '0' : ''}${wanted.episode_number}`)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .width(44)
          Blank()
          this.WantedPill(wanted, isMovie)
          if (!isMovie) {
            SymbolGlyph(this.isRowOpen(wanted, false) ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
              .fontSize(12)
              .fontColor([this.isRowOpen(wanted, false) ? Theme.textMuted : Theme.textFaint])
          }
        }
        .width('100%')
        // 说明行：有实时下载快照就说下载进度，否则说状态说明
        Text(this.wantedLive(wanted) !== null
          ? WantedLogic.downloadNote(this.wantedLive(wanted) as SubscriptionDownloadView)
          : this.wantedPresentation(wanted).note)
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .maxLines(2)
          .width('100%')
        // 实时下载进度条（state != missing 才有）
        if (this.wantedLive(wanted) !== null
          && (this.wantedLive(wanted) as SubscriptionDownloadView).progress !== null
          && (this.wantedLive(wanted) as SubscriptionDownloadView).state !== 'missing') {
          Row() {
            Row()
              .width(`${Math.round(((this.wantedLive(wanted) as SubscriptionDownloadView).progress ?? 0) * 100)}%`)
              .height(3)
              .backgroundColor(SubsColor.ok)
          }
          .width('100%')
          .height(3)
          .backgroundColor(Theme.line)
          .borderRadius(2)
          .clip(true)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .backgroundColor(this.isRowOpen(wanted, isMovie) && !isMovie ? Theme.glassFill : Color.Transparent)
      .onClick(() => {
        if (!isMovie) {
          this.openWanted = this.openWanted === wanted.id ? 0 : wanted.id;
        }
      })

      if (this.isRowOpen(wanted, isMovie)) {
        this.MilestoneChain(this.wantedChain(wanted, isMovie), this.wantedPresentation(wanted).color)
      }
    }
    .width('100%')
  }

  /** 状态胶囊：微型链（亮点指卡在第几站）+ 三字短名（同 iOS `pill`） */
  @Builder
  WantedPill(wanted: WantedView, isMovie: boolean) {
    Row({ space: 7 }) {
      Row({ space: 3 }) {
        ForEach(this.wantedChain(wanted, isMovie), (milestone: Milestone, index: number) => {
          Circle()
            .width(4.5)
            .height(4.5)
            .fill(index === this.wantedStuck(wanted, isMovie)
              ? this.wantedPresentation(wanted).color
              : (milestone.state === 'done' ? 'rgba(255,255,255,0.38)' : 'rgba(255,255,255,0.14)'))
        }, (milestone: Milestone, index: number) => `${milestone.label}-${index}`)
      }
      .width(42)
      Text(this.wantedPresentation(wanted).shortLabel())
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.wantedPresentation(wanted).color)
        .maxLines(1)
    }
    .padding({ left: 10, right: 10, top: 3, bottom: 3 })
    .backgroundColor('rgba(255,255,255,0.06)')
    .borderRadius(10)
  }

  /** 里程碑链竖轨线颜色：最后一站不画；卡点之前亮、之后暗（同 iOS `MilestoneChainView`） */
  private milestoneLineColor(chain: Milestone[], index: number): string {
    if (index >= chain.length - 1) {
      return 'rgba(0,0,0,0)';
    }
    return index < WantedLogic.stuckIndex(chain) ? 'rgba(255,255,255,0.16)' : 'rgba(255,255,255,0.07)';
  }

  /** 里程碑链：竖轨 + 节点 + 站名 + 时间列 + 说明；卡点节点染状态色（同 iOS `MilestoneChainView`） */
  @Builder
  MilestoneChain(chain: Milestone[], color: string) {
    Column({ space: 0 }) {
      ForEach(chain, (milestone: Milestone, index: number) => {
        Stack({ alignContent: Alignment.TopStart }) {
          // 内容列：左边框当竖轨线（高度跟随内容，避开百分比/权重高度的坑）
          Column({ space: 3 }) {
            Row({ space: 8 }) {
              Text(milestone.label)
                .fontSize(15)
                .fontWeight(milestone.state === 'now' || milestone.state === 'fail'
                  ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(milestone.state === 'now' || milestone.state === 'fail'
                  ? color : (milestone.state === 'done' ? 'rgba(255,255,255,0.65)' : Theme.textFaint))
              Blank()
              if (milestone.time.length > 0) {
                Text(milestone.time)
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
              }
            }
            .width('100%')
            Text(milestone.detail)
              .fontSize(15)
              .fontColor(milestone.state === 'done' ? Theme.textFaint
                : (milestone.state === 'todo' ? 'rgba(255,255,255,0.25)' : 'rgba(255,255,255,0.8)'))
              .width('100%')
            if (milestone.why.length > 0) {
              Text(milestone.why)
                .fontSize(12)
                .fontColor(SubsColor.reason)
                .width('100%')
            }
            ForEach(milestone.sources, (source: string) => {
              Text(source)
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .maxLines(2)
                .width('100%')
            }, (source: string) => source)
          }
          .width('100%')
          .padding({ left: 26, bottom: index === chain.length - 1 ? 0 : 14 })
          .border({ width: { left: 1 }, color: { left: this.milestoneLineColor(chain, index) } })

          // 节点：卡点/失败 = 空心描边，走过 = 实心，未到 = 淡描边（用 stroke，Circle+border 会画成方框）
          if (milestone.state === 'now' || milestone.state === 'fail') {
            Circle()
              .width(10)
              .height(10)
              .margin({ top: 3 })
              .fill(Color.Transparent)
              .stroke(color)
              .strokeWidth(2.5)
          } else if (milestone.state === 'done') {
            Circle().width(9).height(9).margin({ top: 4 }).fill('rgba(255,255,255,0.30)')
          } else {
            Circle()
              .width(9)
              .height(9)
              .margin({ top: 4 })
              .fill(Color.Transparent)
              .stroke('rgba(255,255,255,0.15)')
              .strokeWidth(1.5)
          }
        }
        .width('100%')
      }, (milestone: Milestone, index: number) => `${milestone.label}-${index}`)
    }
    .width('100%')
    .padding({ left: 14, right: 16, top: 12, bottom: 12 })
    .backgroundColor(Theme.glassFill)
  }

  /** 搜索轮次摘要（对应 iOS `SearchRoundBar`）：最近一轮搜索压成一行；没有记录整行不渲染 */
  private searchedActivity(): ActivityView | null {
    for (const activity of this.activities) {
      if (activity.type === 'searched') {
        return activity;
      }
    }
    return null;
  }

  private searchedMainLine(): string {
    const activity: ActivityView | null = this.searchedActivity();
    if (activity === null) {
      return '';
    }
    return `${Formatters.relative(activity.created_at)}搜了一轮`;
  }

  private searchedSubLine(): string {
    const activity: ActivityView | null = this.searchedActivity();
    if (activity === null) {
      return '';
    }
    const payload: JsonValue = activity.payload;
    const failedRaw: JsonValue | null = jsonGet(payload, 'failed');
    const failed: boolean = failedRaw !== null && failedRaw !== false && failedRaw !== 0 && failedRaw !== '';
    const results: number | null = jsonIntValue(jsonGet(payload, 'results'));
    if (results !== null && !failed) {
      const hits: number = jsonIntValue(jsonGet(payload, 'identity_hits')) ?? 0;
      const rejected: number = jsonIntValue(jsonGet(payload, 'rejected')) ?? 0;
      const dispatched: number = jsonIntValue(jsonGet(payload, 'dispatched_units')) ?? 0;
      return `${results} 结果 · 命中 ${hits} · 拒绝 ${rejected} · 投递 ${dispatched} 个单元`;
    }
    return activity.message;
  }

  @Builder
  SearchRoundBar() {
    if (this.searchedActivity() !== null) {
      Column({ space: 4 }) {
        Row({ space: 10 }) {
          Circle().width(6).height(6).fill(SubsColor.info)
          Text(this.searchedMainLine())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
        }
        Text(this.searchedSubLine())
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .backgroundColor(Theme.glassFill)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  /**
   * 排查记录（对应 iOS `ActivityLogSection`）：默认收起，展开后按时间回放系统做过的每一步——
   * 每个节点一个按类型着色的圆点 + 竖线连起来的时间轴，右侧是后端写好的中文句子与相对时间。
   */
  @Builder
  ActivitiesSection() {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Text('排查记录')
          .fontSize(15)
          .fontWeight(600)
          .fontColor('rgba(243,245,249,0.7)')
        Text(`${this.activities.length}`)
          .fontSize(15)
          .fontColor(Theme.textFaint)
        Blank()
        SymbolGlyph(this.logOpen ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .onClick(() => {
        this.logOpen = !this.logOpen;
      })

      if (this.logOpen) {
        Divider().color(Theme.line)
        Column() {
          this.ActivityTimeline()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      }
    }
    .width('100%')
    .backgroundColor(Theme.glassFill)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 时间轴：圆点定性（颜色）+ 后端写好的中文句子 + 相对时间（同 iOS `ActivityTimelineView`） */
  @Builder
  ActivityTimeline() {
    ForEach(this.activities, (item: ActivityView, index: number) => {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          Row({ space: 12 }) {
            Text(item.message)
              .fontSize(15)
              .fontColor('rgba(243,245,249,0.85)')
              .layoutWeight(1)
            Text(Formatters.relative(item.created_at))
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .padding({ left: 24, bottom: index === this.activities.length - 1 ? 0 : 16 })
        .border({ width: { left: 1 }, color: { left: this.logLineColor(index) } })

        Circle()
          .width(8)
          .height(8)
          .fill(WantedLogic.activityColor(item.type))
          .margin({ top: 6 })
      }
      .width('100%')
    }, (item: ActivityView) => `${item.id}`)
  }

  /** 时间轴的竖线：最后一站不画（透明） */
  private logLineColor(index: number): string {
    return index === this.activities.length - 1 ? 'rgba(0,0,0,0)' : 'rgba(255,255,255,0.08)';
  }

  // MARK: 「更多」弹层（bindSheet 单槽位，按 sheetKind 分发）

  private sheetTitle(): string {
    if (this.sheetKind === 'adjust') {
      return '调整订阅';
    }
    if (this.sheetKind === 'switch') {
      return '更换规则组';
    }
    return '取消订阅';
  }

  @Builder
  ManageSheet() {
    Column() {
      Row() {
        Text(this.sheetTitle())
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Blank()
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(36)
          .height(36)
          .onClick(() => {
            this.closeSheet();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 8, bottom: 8 })

      if (this.sheetError.length > 0) {
        Text(this.sheetError)
          .fontSize(13)
          .fontColor(Theme.danger)
          .padding({ left: 16, right: 16, bottom: 8 })
      }

      if (this.cleanupPreview !== null) {
        // 减季后的清理追问（同 iOS `SeasonCleanupContent`，标题/说明都换掉）
        this.SeasonCleanupSheet()
      } else if (this.sheetKind === 'adjust') {
        this.AdjustSheet()
      } else if (this.sheetKind === 'switch') {
        this.SwitchSheet()
      } else {
        this.CancelSheet()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 减季后的清理追问（同 iOS `SeasonCleanupContent`）：标题/说明换成「第 N 季已移出订阅」 */
  @Builder
  SeasonCleanupSheet() {
    Scroll() {
      Column({ space: 14 }) {
        Text(`${this.cleanupLabel()}已移出订阅`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Text(this.cleanupSubtitle())
          .fontSize(13)
          .fontColor(Theme.textMuted)
        if (this.cleanupPreview !== null) {
          Column({ space: 0 }) {
            this.CleanupToggle(
              this.cleanupTorrentLabel(),
              this.cleanupTorrentDescription(),
              (this.cleanupPreview as SubscriptionRemovalPreviewView).torrent_count > 0,
              this.cleanupTorrents,
              (this.cleanupPreview as SubscriptionRemovalPreviewView).hit_and_run_count > 0
                ? `其中 ${(this.cleanupPreview as SubscriptionRemovalPreviewView).hit_and_run_count} 个种子仍在 H&R 考核或考核状态未知，删除后可能影响站点考核。`
                : '',
              (on: boolean): void => {
                this.cleanupTorrents = on;
              })
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
            this.CleanupToggle(
              this.cleanupFileLabel(),
              this.cleanupFileDescription(),
              (this.cleanupPreview as SubscriptionRemovalPreviewView).library_file_count > 0,
              this.cleanupFiles, '',
              (on: boolean): void => {
                this.cleanupFiles = on;
              })
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })

          if ((this.cleanupPreview as SubscriptionRemovalPreviewView).retained_cross_season.length > 0) {
            Text(`另有 ${(this.cleanupPreview as SubscriptionRemovalPreviewView).retained_cross_season.length} 个跨季种子仍被保留的季使用，不会删除。`)
              .fontSize(12)
              .fontColor(Theme.info)
              .width('100%')
              .padding(12)
              .backgroundColor('rgba(127,176,255,0.10)')
              .borderRadius(12)
          }
        }
        if (this.cleanupTorrents || this.cleanupFiles) {
          Text('清理在后台进行——可以在「任务中心」查看进度和结果。')
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        Text(this.sheetBusy ? '处理中…' : `清理${this.cleanupLabel()}`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cleanupCanConfirm() ? Theme.danger : Theme.textFaint)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 14, bottom: 14 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
          .onClick(() => {
            if (this.cleanupCanConfirm()) {
              this.confirmSeasonCleanup();
            }
          })
        Text('保留内容')
          .fontSize(15)
          .fontColor(Theme.accentStrong)
          .textAlign(TextAlign.Center)
          .width('100%')
          .onClick(() => {
            this.cleanupPreview = null;
            this.closeSheet();
            this.load();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 4, bottom: Theme.tabBarInset })
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
  }

  private cleanupCanConfirm(): boolean {
    return !this.sheetBusy && (this.cleanupTorrents || this.cleanupFiles);
  }

  /** 「第 1、2 季」 */
  private cleanupLabel(): string {
    const parts: string[] = [];
    for (const season of this.cleanupSeasons) {
      parts.push(`${season}`);
    }
    return `第 ${parts.join('、')} 季`;
  }

  private cleanupSubtitle(): string {
    const title: string = this.detail === null ? '' : (this.detail as SubscriptionDetailView).media.title;
    const them: string = this.cleanupSeasons.length > 1 ? '这几季' : '这一季';
    return `《${title}》的${them}不再追了。要不要把已经下载的内容也清理掉？不清理也没关系，种子和文件都原样留着。`;
  }

  private cleanupTorrentLabel(): string {
    const preview: SubscriptionRemovalPreviewView = this.cleanupPreview as SubscriptionRemovalPreviewView;
    if (preview.torrent_count === 0) {
      return `同时删除${this.cleanupLabel()}的下载任务（没有可单独删除的任务）`;
    }
    return `同时删除${this.cleanupLabel()}的下载任务（${preview.torrent_count} 个）`;
  }

  private cleanupTorrentDescription(): string {
    const preview: SubscriptionRemovalPreviewView = this.cleanupPreview as SubscriptionRemovalPreviewView;
    return preview.torrent_count === 0
      ? '' : '从下载器移除任务，并删除下载目录里的文件，不可恢复。以后重新勾选这几季需要重新下载。';
  }

  private cleanupFileLabel(): string {
    const preview: SubscriptionRemovalPreviewView = this.cleanupPreview as SubscriptionRemovalPreviewView;
    if (preview.library_file_count === 0) {
      return `同时删除${this.cleanupLabel()}在媒体库里的资源（媒体库中没有）`;
    }
    return `同时删除${this.cleanupLabel()}在媒体库里的资源（${preview.library_file_count} 个文件 · ${Formatters.bytes(preview.library_bytes)}）`;
  }

  private cleanupFileDescription(): string {
    const preview: SubscriptionRemovalPreviewView = this.cleanupPreview as SubscriptionRemovalPreviewView;
    return preview.library_file_count === 0
      ? '' : `文件会移入媒体库回收站，${preview.recycle_retention_days} 天内可以恢复。`;
  }

  @Builder
  AdjustSheet() {
    Scroll() {
      Column({ space: 14 }) {
        Text(this.detail === null ? ''
          : `《${(this.detail as SubscriptionDetailView).media.title}》——加季会恢复或补建追踪；减季会让整季退出追踪范围，`
            + '但不会删除下载器任务、已下载文件或入库内容。')
          .fontSize(13)
          .fontColor(Theme.textMuted)
        if (this.detail !== null && (this.detail as SubscriptionDetailView).media.kind !== 'movie') {
          Column({ space: 0 }) {
            Text('选择要收录的季')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 6 })
            ForEach(this.adjustSeasons, (season: SeasonOverview) => {
              Row({ space: 12 }) {
                SymbolGlyph(this.adjustSelected.indexOf(season.season_number) >= 0
                  ? $r('sys.symbol.checkmark_square_fill') : $r('sys.symbol.square'))
                  .fontSize(20)
                  .fontColor([this.adjustSelected.indexOf(season.season_number) >= 0 ? Theme.accent : Theme.textFaint])
                Column({ space: 2 }) {
                  Text(season.season_number === 0 ? '特别篇' : `第 ${season.season_number} 季`)
                    .fontSize(15)
                    .fontColor(Theme.text)
                  Text(`${season.owned_count} / ${season.episode_count ?? 0} 集`)
                    .fontSize(12)
                    .fontColor(Theme.textMuted)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 9, bottom: 9 })
              .onClick(() => {
                this.toggleAdjustSeason(season.season_number);
              })
            }, (season: SeasonOverview) => `s-${season.season_number}`)
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
        }
        // 已有下载进度又要被移出的季：保存前先把后果说清（同 iOS `droppedWithProgress`）
        if (this.droppedWithProgress().length > 0) {
          Text(`第 ${this.droppedWithProgress().join('、')} 季已有下载进度：保存只让它退出追踪`
            + '（停止进度关联、缺失搜索与自动换源），不会动任何文件'
            + (this.isAdmin() ? '；保存后会问你要不要顺手清理这一季的内容' : ''))
            .fontSize(12)
            .fontColor(Theme.warn)
            .width('100%')
            .padding(12)
            .backgroundColor('rgba(245,196,81,0.10)')
            .borderRadius(12)
        }
        if (this.isAdmin() && this.adjustLibraries.length > 0) {
          Column({ space: 0 }) {
            Text('入库到')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 6 })
            this.LibraryRow(0, '按默认库路由')
            ForEach(this.adjustLibraries, (library: LibraryView, index: number) => {
              this.LibraryRow(library.id, library.name + (library.is_default ? '（默认）' : ''))
            }, (library: LibraryView) => `lib-${library.id}`)
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
        }
        // 投递预检脚注（同 iOS `DispatchPreviewNote`）
        if (this.adjustDispatchNote().length > 0) {
          Text(this.adjustDispatchNote())
            .fontSize(12)
            .fontColor(this.adjustDispatch !== null && !(this.adjustDispatch as DispatchPreviewView).ok
              ? Theme.warn : Theme.textMuted)
            .width('100%')
        }
        Text(this.sheetBusy ? '保存中…' : '保存调整')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.sheetBusy ? Theme.textFaint : '#0b0d12')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 14, bottom: 14 })
          .backgroundColor(this.sheetBusy ? Theme.glassFill : Theme.accent)
          .borderRadius(Theme.cardRadius)
          .onClick(() => {
            this.saveAdjust();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 4, bottom: Theme.tabBarInset })
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
  }

  @Builder
  LibraryRow(id: number, label: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(15)
        .fontColor(Theme.text)
        .layoutWeight(1)
      if (this.adjustLibraryId === id) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(16)
          .fontColor([Theme.accent])
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      this.adjustLibraryId = id;
      // 选库即重新预演投递落点（同 iOS `.task(id: libraryId)`）
      this.loadAdjustDispatch();
    })
  }

  private toggleAdjustSeason(season: number): void {
    const at: number = this.adjustSelected.indexOf(season);
    if (at >= 0) {
      this.adjustSelected.splice(at, 1);
    } else {
      this.adjustSelected.push(season);
    }
  }

  @Builder
  SwitchSheet() {
    Column() {
      Text('点选即应用，只影响之后的资源评估；已下载/已入库的内容不受影响。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .padding({ left: 16, right: 16, bottom: 8 })
      if (this.ruleSets.length === 0) {
        Text('还没有规则组。可在「设置 → 订阅规则 → 规则组」新建，或在订阅弹层里快捷新建。')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .padding(16)
      }
      Scroll() {
        Column({ space: 0 }) {
          ForEach(this.ruleSets, (rule: RuleSetView, index: number) => {
            Column() {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Text(rule.name + (rule.is_default ? '（默认）' : ''))
                    .fontSize(15)
                    .fontColor(Theme.text)
                  // 条件摘要芯片（同 iOS `RuleSetSwitchSheet`：`RuleSetText.summary` / 空=全不限）
                  Text(this.ruleSpecSummary(rule))
                    .fontSize(12)
                    .fontColor(Theme.textMuted)
                    .maxLines(2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                if (this.detail !== null && rule.id === (this.detail as SubscriptionDetailView).rule_set_id) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(16)
                    .fontColor([Theme.accent])
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 11, bottom: 11 })
              .onClick(() => {
                this.switchRule(rule);
              })
              if (index < this.ruleSets.length - 1) {
                Divider().color(Theme.line).margin({ left: 16, right: 16 })
              }
            }
            .width('100%')
          }, (rule: RuleSetView) => `rule-${rule.id}`)
        }
        .width('100%')
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
        .margin({ left: 16, right: 16 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  CancelSheet() {
    Scroll() {
      Column({ space: 14 }) {
        Text(this.detail === null ? ''
          : `取消订阅《${(this.detail as SubscriptionDetailView).media.title}》将停止追踪剩余内容。`
            + '默认只取消订阅，已经下载或入库的内容都会保留。')
          .fontSize(13)
          .fontColor(Theme.textMuted)
        if (this.removal === null) {
          Row({ space: 8 }) {
            LoadingProgress().width(16).height(16).color(Theme.textMuted)
            Text('正在加载移除预览…').fontSize(13).fontColor(Theme.textMuted)
          }
        } else {
          Column({ space: 0 }) {
            this.CleanupToggle(
              this.removalTorrentLabel(),
              this.removalTorrentDescription(),
              (this.removal as SubscriptionRemovalPreviewView).torrent_count > 0,
              this.removeTorrents,
              (this.removal as SubscriptionRemovalPreviewView).hit_and_run_count > 0
                ? `其中 ${(this.removal as SubscriptionRemovalPreviewView).hit_and_run_count} 个种子仍在 H&R 考核或考核状态未知，删除后可能影响站点考核。`
                : '',
              (on: boolean): void => {
                this.removeTorrents = on;
              })
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
            this.CleanupToggle(
              this.removalFileLabel(),
              this.removalFileDescription(),
              (this.removal as SubscriptionRemovalPreviewView).library_file_count > 0,
              this.removeFiles, '',
              (on: boolean): void => {
                this.removeFiles = on;
              })
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })

          // 保留的跨季种子提示（同 iOS `retainedCrossSeason`）
          if ((this.removal as SubscriptionRemovalPreviewView).retained_cross_season.length > 0) {
            Text(`另有 ${(this.removal as SubscriptionRemovalPreviewView).retained_cross_season.length} 个跨季种子仍被保留的季使用，不会删除。`)
              .fontSize(12)
              .fontColor(Theme.info)
              .width('100%')
              .padding(12)
              .backgroundColor('rgba(127,176,255,0.10)')
              .borderRadius(12)
          }
        }
        // 勾了清理才说明后台进行（同 iOS footer）
        if (this.removeTorrents || this.removeFiles) {
          Text('订阅会立刻取消，清理在后台进行——可以在「任务中心」查看进度和结果。')
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        Text(this.sheetBusy ? '处理中…' : '取消订阅')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.sheetBusy ? Theme.textFaint : Theme.danger)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 14, bottom: 14 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
          .onClick(() => {
            this.confirmRemoval();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 4, bottom: Theme.tabBarInset })
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
  }

  /** 清理开关的标签与说明（同 iOS `SubscriptionCancelSheet` 两个开关的文案） */
  private removalTorrentLabel(): string {
    const preview: SubscriptionRemovalPreviewView = this.removal as SubscriptionRemovalPreviewView;
    if (preview.torrent_count === 0) {
      return '同时删除相关的下载任务（没有可删除的任务）';
    }
    return `同时删除相关的下载任务（${preview.torrent_count} 个）`;
  }

  private removalTorrentDescription(): string {
    return (this.removal as SubscriptionRemovalPreviewView).torrent_count === 0
      ? '' : '从下载器移除任务，并删除下载目录里的文件，不可恢复。';
  }

  private removalFileLabel(): string {
    const preview: SubscriptionRemovalPreviewView = this.removal as SubscriptionRemovalPreviewView;
    if (preview.library_file_count === 0) {
      return '同时删除媒体库里的资源（媒体库中没有该作品）';
    }
    return `同时删除媒体库里的资源（${preview.library_file_count} 个文件 · ${Formatters.bytes(preview.library_bytes)}）`;
  }

  private removalFileDescription(): string {
    const preview: SubscriptionRemovalPreviewView = this.removal as SubscriptionRemovalPreviewView;
    return preview.library_file_count === 0
      ? '' : `文件会移入媒体库回收站，${preview.recycle_retention_days} 天内可以恢复。`;
  }

  @Builder
  CleanupToggle(label: string, description: string, enabled: boolean, value: boolean, warning: string,
    onToggle: (on: boolean) => void) {
    Column({ space: 4 }) {
      Row({ space: 12 }) {
        Text(label)
          .fontSize(14)
          .fontColor(enabled ? Theme.text : Theme.textFaint)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: value })
          .enabled(enabled)
          .selectedColor(Theme.accent)
          .onChange((on: boolean): void => {
            onToggle(on);
          })
      }
      .width('100%')
      if (description.length > 0) {
        Text(description)
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .width('100%')
      }
      if (warning.length > 0 && value) {
        Text(warning)
          .fontSize(12)
          .fontColor(Theme.warn)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
  }
}
