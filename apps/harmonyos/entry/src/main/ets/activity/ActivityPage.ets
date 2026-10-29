import { AppNavBar } from '../common/AppNavBar';
import { Theme } from '../theme/AppTheme';
import { TabBarCollapse } from '../common/TabBarCollapse';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { Formatters } from '../common/Formatters';
import { AppModel } from '../common/AppModel';
import { AppFooter } from '../common/AppFooter';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { EventStream, ServerEvent, StreamHandle } from '../common/EventStream';
import { JobProgressView, JobView, JobWorkerHealthView, JobDismissAllView, PlaybackHistoryView, PlaybackLogEntryView, MediaActivityView, ActivePlaybackSessionView, ActiveFileDownloadView, PlaybackWatchStatsView, PlaybackStatsTotals, PlaybackStatsDayRow, MediaActivityTarget, DownloadTaskView, DownloadTaskSourceView } from '../api/Models';
import { ActivityTasksParams } from './ActivityTasksPage';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';
import {
  ActivityFormat,
  BoostTotals,
  DownloadGroup,
  DownloadTasks,
  TaskState,
  WatchFormat
} from './ActivityFormat';

/**
 * 活动页（管理员，对应 iOS 端 Features/Activity/ActivityView.swift）。
 *
 * iOS 那版是「一页总览」，按紧急程度自上而下：需要处理 → 正在播放 → 正在下载 → 进行中 →
 * 最近播放 → 观看统计 → 最近完成；鸿蒙这边数据自己拉（jobs 走 SSE + 15s 兜底轮询，
 * 其余段下拉刷新时同步）。各段的「查看全部」压栈到二级页（进行中/已结束、最近播放、
 * 观看统计），路由见 router_map.json 的 activityTasks / activityPlays / activityStats。
 */
@ComponentV2
export struct ActivityPage {
  /** 宿主注入的导航栈（ActivityNavHost）；二级页从这里 push */
  @Require @Param navStack: NavPathStack;
  /** 内容区滚动器（宿主 bindToScrollable 要用同一个实例驱动标题栏） */
  @Param scroller: Scroller = new Scroller();
  @Local private jobs: JobView[] = [];
  @Local private health: JobWorkerHealthView | null = null;
  @Local private failedOnce: boolean = false;
  @Local private errorMessage: string = '';
  @Local private refreshing: boolean = false;
  /** 「全部忽略」在途（同 iOS 的 bulkDismissing） */
  @Local private dismissingAll: boolean = false;
  /** 最近播放（对应 iOS 的「最近播放」段；点「查看全部」去二级页，这里先露最近几条） */
  @Local private plays: PlaybackLogEntryView[] = [];
  @Local private playsTotal: number = 0;
  /** 正在播放 / 正在下载（`playbackActivity` 快照） */
  @Local private live: MediaActivityView | null = null;
  /** 观看统计（近 7 天摘要卡） */
  @Local private stats: PlaybackWatchStatsView | null = null;
  @Local private acting: string = '';
  /** 下载器里的任务（`/downloaders/tasks`）：按作品分组进「进行中 / 需要处理」 */
  @Local private dlTasks: DownloadTaskView[] = [];
  /** 下载器源状态（异常时给提示条） */
  @Local private downloadSources: DownloadTaskSourceView[] = [];
  /** 正在处置的设备（结束播放 / 注销在途；期间其它处置按钮禁用） */
  @Local private busyDevice: string = '';

  // MARK: jobs 事件流与定时器（页面消失必须全清）
  private stream: StreamHandle | null = null;
  /** 兜底轮询（SSE 断了也保证 jobs 数据不停，15s 对齐 iOS fallbackPoll） */
  private timer: number = -1;
  /** 连发事件合并：ready/job 一次连推多条，120ms 合并为一次快照校准 */
  private debounceTimer: number = -1;
  /** 断线后 3s 重连 */
  private reconnectTimer: number = -1;
  private started: boolean = false;

  aboutToAppear(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.load();
    // jobs 走 SSE 事件驱动；兜底轮询 15s 一轮
    this.startJobsStream();
    this.timer = setInterval((): void => {
      this.loadJobs();
    }, 15000);
  }

  aboutToDisappear(): void {
    this.teardown();
  }

  /** 关流 + 清全部定时器（页面消失 / 切走）。 */
  private teardown(): void {
    if (this.stream !== null) {
      this.stream.close();
      this.stream = null;
    }
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: jobs 事件流

  /** 打开 `/jobs/stream`：ready/job 事件 → 120ms 防抖刷新 jobs 快照。 */
  private startJobsStream(): void {
    if (this.stream !== null) {
      return;
    }
    const client = AppModel.shared.client;
    if (client === null) {
      return;
    }
    const es = new EventStream(client.origin, client.getToken());
    this.stream = es.open('/jobs/stream', {}, {
      onEvent: (ev: ServerEvent): void => {
        if (ev.event === 'ready' || ev.event === 'job') {
          this.scheduleJobsRefresh();
        }
      },
      onError: (_err: ApiError): void => {
        this.onJobsStreamDown();
      },
      onEnd: (): void => {
        this.onJobsStreamDown();
      }
    });
  }

  /** 断线（含服务端主动结束）：3 秒后重连，期间兜底轮询保证数据不停。 */
  private onJobsStreamDown(): void {
    if (this.stream !== null) {
      this.stream.close();
      this.stream = null;
    }
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
    }
    this.reconnectTimer = setTimeout((): void => {
      this.reconnectTimer = -1;
      this.startJobsStream();
    }, 3000);
  }

  private scheduleJobsRefresh(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout((): void => {
      this.debounceTimer = -1;
      this.loadJobs();
    }, 120);
  }

  // MARK: 取数

  private sessions(): ActivePlaybackSessionView[] {
    const view: MediaActivityView | null = this.live;
    return view !== null ? view.sessions : [];
  }

  private downloads(): ActiveFileDownloadView[] {
    const view: MediaActivityView | null = this.live;
    return view !== null ? view.downloads : [];
  }

  private hiddenSessions(): number {
    const view: MediaActivityView | null = this.live;
    return view !== null ? view.hidden_session_count : 0;
  }

  private hiddenDownloads(): number {
    const view: MediaActivityView | null = this.live;
    return view !== null ? view.hidden_download_count : 0;
  }

  /** 最近播放：只露最近几条，和 iOS 一样「历史与统计只露一小段」 */
  private async loadPlays(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const view: PlaybackHistoryView = await api.playbackHistory(3);
      this.plays = view.entries;
      this.playsTotal = view.entries.length + (view.has_more ? 1 : 0);
    } catch (error) {
      this.plays = [];
    }
  }

  /** 正在播放 / 正在下载的快照 */
  private async loadLive(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.live = await api.playbackActivity();
    } catch (error) {
      this.live = null;
    }
  }

  /** 下载器任务（与 jobs 一起撑起「需要处理 / 进行中」两段） */
  private async loadDownloads(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const list = await api.dlTasks();
      this.dlTasks = list.items;
      this.downloadSources = list.sources;
    } catch (error) {
      this.dlTasks = [];
      this.downloadSources = [];
    }
  }

  /** 观看统计：活动页只露一张 7 天摘要卡，完整统计在二级页（还没做） */
  private async loadStats(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.stats = await api.playbackStatsWatch(7);
    } catch (error) {
      this.stats = null;
    }
  }

  /** jobs + worker 健康（事件流与兜底轮询都只刷这一段，不打扰其余段）。 */
  private async loadJobs(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const list = await api.jobsList(undefined, undefined, undefined, undefined, false, 100);
      this.jobs = list.items;
      this.failedOnce = false;
      this.errorMessage = '';
    } catch (error) {
      if (this.jobs.length === 0) {
        this.failedOnce = true;
        this.errorMessage = this.messageOf(error);
      }
    }
    try {
      this.health = await api.jobsHealth();
    } catch (error) {
      this.health = null;
    }
  }

  /** 首次进入 / 下拉刷新：jobs + 其余段（最近播放 / 正在播放与下载 / 观看统计）。 */
  private async load(): Promise<void> {
    await this.loadJobs();
    await this.loadDownloads();
    // 三段补充数据：最近播放 / 正在播放与下载 / 观看统计
    await this.loadPlays();
    await this.loadLive();
    await this.loadStats();
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 派生

  /** 刷流做种：没有入库/救援语义，不进时间线、不参与计数（iOS 同口径） */
  private boostTasks(): DownloadTaskView[] {
    const out: DownloadTaskView[] = [];
    for (const task of this.dlTasks) {
      if (task.source === 'boost') {
        out.push(task);
      }
    }
    return out;
  }

  /** 可进任务时间线的下载任务（排除刷流） */
  private mediaDownloadTasks(): DownloadTaskView[] {
    return DownloadTasks.mediaTasks(this.dlTasks);
  }

  /** 需要处理的下载组（下载/入库出了问题，或关联的入库任务失败） */
  private attentionGroups(): DownloadGroup[] {
    return DownloadTasks.attentionGroups(this.dlTasks);
  }

  /** 进行中的下载组 */
  private activeGroups(): DownloadGroup[] {
    return DownloadTasks.activeGroups(this.dlTasks);
  }

  /** 需要处理：失败 / 阻塞且未被忽略的后台作业 */
  private attention(): JobView[] {
    const out: JobView[] = [];
    for (const job of this.jobs) {
      if (TaskState.needsAttention(job)) {
        out.push(job);
      }
    }
    return out;
  }

  /** 进行中：排队 / 运行 / 重试等待 / 取消中 / 等待（iOS `activeFeedJobStatuses`） */
  private active(): JobView[] {
    const out: JobView[] = [];
    for (const job of this.jobs) {
      if (TaskState.isActive(job)) {
        out.push(job);
      }
    }
    return out;
  }

  /** 最近完成：成功 + 已取消 + 被忽略的失败，按创建时间倒序取前 5 */
  private recent(): JobView[] {
    const done: JobView[] = [];
    for (const job of this.jobs) {
      if (TaskState.isHistorical(job)) {
        done.push(job);
      }
    }
    done.sort((a: JobView, b: JobView): number => (a.created_at < b.created_at ? 1 : -1));
    return done.slice(0, 5);
  }

  /** 「进行中」总计：下载组 + 后台作业（iOS `activeTotal`） */
  private activeTotal(): number {
    return this.activeGroups().length + this.active().length;
  }

  /** 「需要处理」总计：下载组 + 后台作业（iOS `attentionTotal`） */
  private attentionTotal(): number {
    return this.attentionGroups().length + this.attention().length;
  }

  /** 需要处理区在总览上最多露几条（iOS `activeLimit`） */
  private static readonly ACTIVE_LIMIT: number = 5;

  private workerDown(): boolean {
    const health: JobWorkerHealthView | null = this.health;
    return health !== null && !health.running;
  }

  /**
   * 顶部一行实时摘要（iOS `activity-summary`）：
   * 「2 项需要处理 · 1 台设备在播放 · 5 个任务进行中」，需要处理标红；
   * 什么都没有时「一切正常 · 现在没有人在看」，有任务但没人在看时补「现在没有人在看」。
   */
  private summary(): string {
    const attention: number = this.attentionTotal();
    const watching: number = this.sessions().length + this.hiddenSessions();
    const downloading: number = this.downloads().length + this.hiddenDownloads();
    const active: number = this.activeTotal();
    const parts: string[] = [];
    if (attention > 0) {
      parts.push(`${attention} 项需要处理`);
    }
    if (watching > 0) {
      parts.push(`${watching} 台设备在播放`);
    }
    if (downloading > 0) {
      parts.push(`${downloading} 台设备在下载`);
    }
    if (active > 0) {
      parts.push(`${active} 个任务进行中`);
    }
    if (parts.length === 0) {
      return '一切正常 · 现在没有人在看';
    }
    if (watching === 0) {
      parts.push('现在没有人在看');
    }
    return parts.join('  ·  ');
  }

  /** 摘要行是否要按「警示」着色（只有需要处理时才标红） */
  private summaryAlert(): boolean {
    return this.attentionTotal() > 0;
  }

  // MARK: 动作

  // MARK: 设备处置（对应 iOS `ActivityDeviceActions`）

  /**
   * 结束一台设备本次播放。可逆（再点播放即可继续），但会打断别人正在看的东西，先问一句。
   */
  private confirmEndPlayback(session: ActivePlaybackSessionView): void {
    if (this.busyDevice.length > 0) {
      return;
    }
    const label: string = WatchFormat.deviceLabel(session.client, session.device_name);
    this.getUIContext().showAlertDialog({
      title: `结束「${label}」本次播放？`,
      message: '这台设备正在进行的播放会立刻中断，一分钟内不能续播；登录凭据与观看进度都不受影响，之后重新点播放即可继续。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '结束播放',
        fontColor: Theme.danger,
        action: (): void => {
          this.endPlayback(session.device_id);
        }
      }
    });
  }

  private async endPlayback(deviceId: string): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busyDevice.length > 0) {
      return;
    }
    this.busyDevice = deviceId;
    try {
      await api.playbackActivityEnd(deviceId);
      this.toast('已结束播放');
      await this.loadLive();
    } catch (error) {
      const message: string = this.messageOf(error);
      this.toast(message.length > 0 ? message : '结束播放失败');
    } finally {
      this.busyDevice = '';
    }
  }

  /** 注销一台设备：设备要重新登录（电视上尤其麻烦），显式确认 */
  private confirmRevoke(deviceId: string, label: string): void {
    if (this.busyDevice.length > 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '注销这台设备？',
      message: `「${label}」的登录凭据会立刻失效，正在进行的播放与下载一并停止，该设备下次使用需要重新登录。\n\n已看进度、收藏这些观看记录按账号保存，不会因为注销设备而丢失。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '注销设备',
        fontColor: Theme.danger,
        action: (): void => {
          this.revokeDevice(deviceId);
        }
      }
    });
  }

  private async revokeDevice(deviceId: string): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busyDevice.length > 0) {
      return;
    }
    this.busyDevice = deviceId;
    try {
      await api.playbackDeviceRevoke(deviceId);
      this.toast('设备已注销');
      await this.loadLive();
    } catch (error) {
      const message: string = this.messageOf(error);
      this.toast(message.length > 0 ? message : '注销设备失败');
    } finally {
      this.busyDevice = '';
    }
  }

  /** 打开条目详情（有落点库且在可浏览范围内才可跳） */
  private openMedia(media: MediaActivityTarget | null | undefined): void {
    if (media === null || media === undefined || !WatchFormat.canOpenDetail(media)) {
      return;
    }
    this.navStack.pushPathByName('libraryItem',
      new ItemRouteParams(media.library_id ?? 0, media.media_item_id));
  }

  /** 播放方式胶囊底：同色 16% 透明度（颜色是 6 位 hex） */
  private tintOf(color: string): string {
    return color.length === 7 ? `${color}29` : Theme.glassFill;
  }

  // MARK: 滑动与长按

  @Builder
  EndPlaybackSwipe(session: ActivePlaybackSessionView) {
    Text('结束播放')
      .fontSize(14)
      .fontColor('#ffffff')
      .textAlign(TextAlign.Center)
      .width(96)
      .height('100%')
      .backgroundColor(Theme.danger)
      .onClick(() => {
        this.confirmEndPlayback(session);
      })
  }

  @Builder
  RevokeSwipe(item: ActiveFileDownloadView) {
    Text('注销设备')
      .fontSize(14)
      .fontColor('#ffffff')
      .textAlign(TextAlign.Center)
      .width(96)
      .height('100%')
      .backgroundColor(Theme.danger)
      .onClick(() => {
        this.confirmRevoke(item.device_id,
          WatchFormat.deviceLabel(item.client, item.device_name));
      })
  }

  /** 不可处置的行也要有占位（`swipeAction` 的 end 不能为 undefined） */
  @Builder
  NoSwipe() {
    Row()
      .width(0)
      .height('100%')
  }

  /** 正在播放的长按菜单：为什么转码 / 打开详情 / 结束播放 / 注销设备 */
  @Builder
  SessionMenu(session: ActivePlaybackSessionView) {
    Menu() {
      if (session.delivery !== null && session.delivery !== undefined
        && (session.delivery.reason ?? '').length > 0) {
        MenuItem({ content: `为什么是${session.delivery.label}` })
          .enabled(false)
        MenuItem({ content: session.delivery.reason ?? '' })
          .enabled(false)
      }
      if (WatchFormat.canOpenDetail(session.media)) {
        MenuItem({ content: '打开影片详情', startIcon: $r('sys.symbol.film') })
          .onClick(() => {
            this.openMedia(session.media);
          })
      }
      MenuItem({ content: '结束播放', startIcon: $r('sys.symbol.stop_circle') })
        .onClick(() => {
          this.confirmEndPlayback(session);
        })
      if (session.revocable) {
        MenuItem({ content: '注销此设备', startIcon: $r('sys.symbol.person_xmark') })
          .onClick(() => {
            this.confirmRevoke(session.device_id,
              WatchFormat.deviceLabel(session.client, session.device_name));
          })
      }
    }
  }

  /** 正在下载的长按菜单：注销设备（可注销的才给） */
  @Builder
  DownloadMenu(item: ActiveFileDownloadView) {
    Menu() {
      if (item.revocable) {
        MenuItem({ content: '注销此设备', startIcon: $r('sys.symbol.person_xmark') })
          .onClick(() => {
            this.confirmRevoke(item.device_id,
              WatchFormat.deviceLabel(item.client, item.device_name));
          })
      }
    }
  }

  /** 浏览范围脚注（iOS `scopeFooter`）：有被隐藏的内容才出现 */
  @Builder
  ScopeFooter(hidden: number, noun: string) {
    if (hidden > 0) {
      Text(`另有 ${hidden} ${noun}不在你的浏览范围内`)
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .padding({ left: Theme.pagePadding + 4, right: Theme.pagePadding + 4, top: 2 })
    }
  }

  /** 下载器源异常（对应 iOS `TaskSourceWarning`） */
  private downloadSourceDown(): boolean {
    for (const source of this.downloadSources) {
      if (source.status !== 'active') {
        return true;
      }
    }
    return false;
  }

  @Builder
  SourceWarning() {
    Column() {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
          .fontSize(18)
          .fontColor([Theme.warn])
        Column({ space: 2 }) {
          Text('下载器连接异常')
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.text)
          ForEach(this.downloadSources.filter((source: DownloadTaskSourceView): boolean =>
            source.status !== 'active'), (source: DownloadTaskSourceView) => {
            Text(`${source.name}：${(source.message ?? '').length > 0 ? source.message : '连接失败'}`)
              .fontSize(12)
              .fontColor(Theme.textMuted)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }, (source: DownloadTaskSourceView) => `${source.id}`)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor(Theme.glassFill)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.warn })
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  /**
   * 「全部忽略」（对应 iOS 的 `dismissAllFailed`）：一次把「需要处理」里失败的任务都忽略掉。
   *
   * 这是**批量写操作**，所以先二次确认，并把条数说清楚——用户要知道自己一次忽略了多少。
   */
  private confirmDismissAll(): void {
    const count: number = this.attention().length;
    if (count === 0 || this.dismissingAll) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '全部忽略',
      message: `把「需要处理」里的 ${count} 个失败任务都忽略掉？`
        + '忽略只是从这一屏收起来，任务本身不会被删；之后还能在「最近完成」里找到它。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '全部忽略',
        action: (): void => {
          this.dismissAllFailed();
        }
      }
    });
  }

  private async dismissAllFailed(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.dismissingAll) {
      return;
    }
    this.dismissingAll = true;
    try {
      const view: JobDismissAllView = await api.jobsDismissAll();
      this.toast(view.dismissed > 0 ? `已忽略 ${view.dismissed} 个` : '没有可忽略的');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.dismissingAll = false;
    }
  }

  private async retry(job: JobView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.acting.length > 0) {
      return;
    }
    this.acting = job.id;
    try {
      await api.jobsRetry(job.id);
      this.toast('已重试');
      await this.load();
    } catch (error) {
      this.toast('重试失败，请稍后再试');
    } finally {
      this.acting = '';
    }
  }

  private async dismiss(job: JobView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.acting.length > 0) {
      return;
    }
    this.acting = job.id;
    try {
      await api.jobsDismiss(job.id);
      await this.load();
    } catch (error) {
      this.toast('忽略失败，请稍后再试');
    } finally {
      this.acting = '';
    }
  }

  private confirmCancel(job: JobView): void {
    this.getUIContext().showAlertDialog({
      title: '取消任务',
      message: `取消「${this.jobTitle(job)}」？已经完成的部分会保留。`,
      primaryButton: {
        value: '不取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '取消任务',
        fontColor: Theme.danger,
        action: (): void => {
          this.cancel(job);
        }
      }
    });
  }

  private async cancel(job: JobView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.acting.length > 0) {
      return;
    }
    this.acting = job.id;
    try {
      await api.jobsCancel(job.id);
      this.toast('已取消');
      await this.load();
    } catch (error) {
      this.toast('取消失败，请稍后再试');
    } finally {
      this.acting = '';
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
    }
  }

  // MARK: 文案

  /**
   * 任务类型的人话名称（对照表逐条搬自 iOS `TaskCenterLogic.jobTypeLabels`）。
   *
   * **不能把 `library.skip_segments` 这种内部名直接显示给用户**——那是给日志看的，
   * 用户看到的是「识别片头片尾」。
   */
  private static readonly JOB_TYPE_LABELS: Record<string, string> = {
    'subtitle.generate': '生成 AI 字幕',
    'library.scan': '扫描媒体库',
    'library.metadata.refresh': '刷新媒体库元数据',
    'media.metadata.refresh': '刷新条目元数据',
    'library.chapter_images': '生成章节',
    'library.skip_segments': '识别片头片尾',
    'media.skip_segments': '识别片头片尾',
    'reels.clips': '片段预切',
    'library.organize': '整理媒体库文件',
    'library.transfer': '转移媒体库条目',
    'library.ingest': '自动整理入库'
  };

  /** 任务类型的显示名：内置类型用本地文案，插件任务用服务端给的名字（`job_type_label`），都没有显示原始类型（与 Web、iOS 同序） */
  private static typeLabel(job: JobView): string {
    const label: string | undefined = ActivityPage.JOB_TYPE_LABELS[job.job_type];
    if (label !== undefined) {
      return label;
    }
    const serverLabel: string = job.job_type_label ?? '';
    if (serverLabel.length > 0) {
      return serverLabel;
    }
    return job.job_type;
  }

  private jobTitle(job: JobView): string {
    const subject: string | null = job.subject ?? null;
    if (subject !== null && subject.length > 0) {
      return subject;
    }
    return ActivityPage.typeLabel(job);
  }

  private jobSubtitle(job: JobView): string {
    const parts: string[] = [ActivityPage.typeLabel(job)];
    if (job.attempt > 1) {
      parts.push(`第 ${job.attempt}/${job.max_attempts} 次`);
    }
    return parts.join('  ·  ');
  }

  /** 进度文案：优先百分比，其次 current/total，最后 message */
  private progressText(job: JobView): string {
    const progress: JobProgressView = job.progress;
    if (progress.percent !== null && progress.percent !== undefined) {
      return `${Math.round(progress.percent)}%`;
    }
    if (progress.total !== null && progress.total !== undefined && progress.total > 0) {
      const current: number = progress.current ?? 0;
      return `${current}/${progress.total}`;
    }
    return progress.message ?? '';
  }

  private progressValue(job: JobView): number {
    const progress: JobProgressView = job.progress;
    if (progress.percent !== null && progress.percent !== undefined) {
      return Math.min(100, Math.max(0, progress.percent));
    }
    if (progress.total !== null && progress.total !== undefined && progress.total > 0) {
      const current: number = progress.current ?? 0;
      return Math.min(100, Math.round(current * 100 / progress.total));
    }
    return 0;
  }

  private errorText(job: JobView): string {
    const error = job.error;
    if (error === null || error === undefined) {
      return '';
    }
    const message = error['message'];
    if (message !== undefined && message !== null) {
      return `${message}`;
    }
    const code = error['code'];
    return code !== undefined && code !== null ? `${code}` : '';
  }

  private statusLabel(status: string): string {
    if (status === 'running') {
      return '进行中';
    }
    if (status === 'queued') {
      return '排队中';
    }
    if (status === 'failed') {
      return '失败';
    }
    if (status === 'succeeded') {
      return '完成';
    }
    if (status === 'cancelled') {
      return '已取消';
    }
    return status;
  }

  private statusColor(status: string): string {
    if (status === 'failed') {
      return Theme.danger;
    }
    if (status === 'succeeded') {
      return Theme.ok;
    }
    if (status === 'running') {
      return Theme.accent;
    }
    return Theme.textFaint;
  }

  // MARK: 视图

  build() {
    Column() {
      if (this.failedOnce) {
        // 加载失败：没有滚动区可绑，摘要行固定在标题栏下方
        this.TitleBar()
        this.ErrorState()
      } else {
        this.Content()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /**
   * 实时摘要行（对应 iOS `activity-summary`）：放在滚动区最上面，
   * 顶部留白 = 标题栏高度（内容从 y=0 起，滚动时这段和标题栏一起走）。
   */
  @Builder
  TitleBar() {
    Column({ space: 2 }) {
      Text(this.summary())
        .fontSize(13)
        .fontColor(this.summaryAlert() ? Theme.danger : Theme.textMuted)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: AppNavBar.contentTop + 6 })
  }

  @Builder
  ErrorState() {
    Column({ space: 12 }) {
      Text('任务列表加载失败')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(this.errorMessage)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Button() {
        Text('重试')
          .fontSize(14)
          .fontWeight(600)
          .fontColor(Theme.accentStrong)
      }
      .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
      .padding({ left: 20, right: 20, top: 9, bottom: 9 })
      .borderRadius(18)
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
  Content() {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll(this.scroller) {
        Column({ space: 24 }) {
          // 摘要在滚动区最上面：沉浸布局下跟着内容走（标题栏收起时不留空带）
          this.TitleBar()
          if (this.workerDown()) {
            this.WorkerWarning()
          }
          if (this.downloadSourceDown()) {
            this.SourceWarning()
          }
          if (this.attentionTotal() > 0) {
            this.AttentionSection()
          }
          /*
           * 自上而下照 iOS ActivityView：需要处理 → 正在播放 → 正在下载 → 进行中 →
           * 最近播放 → 观看统计 → 最近完成。各段显示条件独立、互不嵌套
           * （上一版把「最近播放」塞进「进行中」，结果没有进行中任务时整段消失）。
           *
           * 每段（标题 + 卡片 + 脚注）包在一个 `space: 10` 的 Column 里，
           * 不然它们会各自成为外层 `space: 24` 的子节点，标题与卡片的间距变成 24，
           * 和需要处理 / 进行中 / 最近完成那几段的 10 对不上。
           */
          if (this.sessions().length > 0 || this.hiddenSessions() > 0) {
            Column({ space: 10 }) {
              this.SectionHeader('正在播放', this.sessions().length + this.hiddenSessions(),
                Theme.ok, '', (): void => {
                })
              this.SessionsList()
              this.ScopeFooter(this.hiddenSessions(), '台设备在播放的内容')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          if (this.downloads().length > 0 || this.hiddenDownloads() > 0) {
            Column({ space: 10 }) {
              this.SectionHeader('正在下载', this.downloads().length + this.hiddenDownloads(),
                '', '', (): void => {
                })
              this.DownloadsList()
              this.ScopeFooter(this.hiddenDownloads(), '条下载')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          if (this.activeTotal() > 0 || this.boostTasks().length > 0) {
            this.ActiveSection()
          }
          if (this.plays.length > 0) {
            Column({ space: 10 }) {
              this.SectionHeader('最近播放', 0, '', '查看全部', (): void => {
                this.navStack.pushPathByName('activityPlays', null);
              })
              this.PlaysList()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          if (this.stats !== null) {
            Column({ space: 10 }) {
              this.SectionHeader('观看统计', 0, '', '查看全部', (): void => {
                this.navStack.pushPathByName('activityStats', null);
              })
              this.StatsCard()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          if (this.recent().length > 0) {
            this.RecentSection()
          }
          if (this.attentionTotal() === 0 && this.activeTotal() === 0
            && this.recent().length === 0 && this.plays.length === 0
            && this.sessions().length === 0 && this.downloads().length === 0
            && this.boostTasks().length === 0) {
            this.EmptyState()
          }
          // 页脚：品牌联合声明，复用全局 AppFooter
          AppFooter({ topSpace: 8 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: Theme.tabBarInset })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.None)
      // 向下滚累计到阈值：底栏收成圆形按钮（往回滑立刻放回）
      .onDidScroll((xOffset: number, yOffset: number) => {
        TabBarCollapse.shared().onScroll(this.scroller.currentOffset().yOffset);
      })
    }
    .onRefreshing(() => {
      this.load().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    // 摘要行在本组件之上：这里必须占剩余高度，写死 100% 会把滚动区底部推出屏幕
    .layoutWeight(1)
  }

  /** worker 没在跑：队列不会有人处理，必须让人看见 */
  @Builder
  WorkerWarning() {
    // 横向留白加在区块级（卡片自身不带 margin），避免卡片内的 width('100%') 顶出屏幕右缘
    Column() {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
          .fontSize(18)
          .fontColor([Theme.warn])
        Column({ space: 2 }) {
          Text('任务执行器没有在运行')
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.text)
          Text('排队中的任务不会被处理，请在服务端检查 worker。')
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor(Theme.glassFill)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.warn })
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  /**
   * 版块头（对应 iOS `ActivitySectionHeader`）：
   * 可选色点（8×8）+ 标题 + 计数（灰、等宽）+ 右侧动作（带右箭头）。
   */
  @Builder
  SectionHeader(title: string, count: number, tint: string, trailing: string,
    onTrailing: () => void, arrow: boolean = true) {
    Row({ space: 6 }) {
      if (tint.length > 0) {
        Circle()
          .width(8)
          .height(8)
          .backgroundColor(tint)
      }
      Text(title)
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      if (count > 0) {
        Text(`${count}`)
          .fontSize(15)
          .fontColor(Theme.textFaint)
      }
      Blank()
      if (trailing.length > 0) {
        Row({ space: 3 }) {
          Text(trailing)
            .fontSize(14)
            .fontColor(Theme.textMuted)
          // 「全部忽略」这类就地动作不带右箭头，带箭头的才是「去下一页」（同 iOS）
          if (onTrailing !== null && arrow) {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(12)
              .fontColor([Theme.textMuted])
          }
        }
        .onClick(() => {
          onTrailing();
        })
      }
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 6, bottom: 6 })
  }

  /**
   * 正在播放（逐条对齐 iOS `ActivityPlaybackSessionRow`）。
   *
   * 按「在看什么 → 谁在哪看 → 怎么在播 → 看到哪」分层，每层一行、不挤不截：
   *
   *     [海报]  抓特务 2026
   *             user · Safari · iPhone
   *             [远程转码] ▶ 播放中 · 59%        ↓ 2.1 MB/s
   *             1080p · H.264 · 8 Mbps · 远程 Worker「studio」
   *             ━━━━━━━━━━━━░░░░░░░░
   *             1:23:16                 还剩 57 分钟
   *
   * **`paused` 要显出来**——一条停在 40% 不动的会话，和「正在播但用户暂停了」
   * 是两件不同的事；不区分的话用户会以为卡住了。
   */
  @Builder
  SessionsList() {
    // 横向留白加在区块级（卡片自身不带 padding/margin），所有段卡片同宽
    Column() {
      List() {
        ForEach(this.sessions(), (session: ActivePlaybackSessionView, index: number) => {
          ListItem() {
            Column() {
              Row({ space: 12 }) {
                this.MediaPoster(session.media, 48, 70)
                Column({ space: 5 }) {
                  this.MediaTitle(session.media)
                  Text(WatchFormat.metaLine([
                    session.member_name,
                    WatchFormat.deviceLabel(session.client, session.device_name)
                  ]))
                    .fontSize(12)
                    .fontColor(Theme.textMuted)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  this.SessionStatusLine(session)
                  if (WatchFormat.deliveryDetail(session.delivery) !== null) {
                    Text(WatchFormat.deliveryDetail(session.delivery) ?? '')
                      .fontSize(11)
                      .fontColor(Theme.textFaint)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  if (session.progress_percent !== null && session.progress_percent !== undefined) {
                    Progress({ value: Math.min(100, Math.max(0, session.progress_percent)), total: 100 })
                      .color(session.paused ? 'rgba(255,255,255,0.35)' : Theme.info)
                      .width('100%')
                      .height(3)
                  }
                  this.SessionClockLine(session)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .onClick(() => {
                this.openMedia(session.media);
              })
              .bindContextMenu(this.SessionMenu(session), ResponseType.LongPress)
              if (index < this.sessions().length - 1) {
                Divider().color(Theme.line).margin({ left: 76, right: 16 })
              }
            }
            .width('100%')
          }
          .width('100%')
          // 左滑「结束播放」（对应 iOS swipeActions）
          .swipeAction({ end: this.EndPlaybackSwipe(session) })
        }, (session: ActivePlaybackSessionView) => `s-${session.device_id}-${session.started_at}`)
      }
      .width('100%')
      // 整页在外层 Scroll 里：内层列表禁止自己滚，只承担左滑手势
      .enableScrollInteraction(false)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  /** 播放方式胶囊 · 播放状态 · 百分比，右侧只放一个实时传输指标 */
  @Builder
  SessionStatusLine(session: ActivePlaybackSessionView) {
    Row({ space: 6 }) {
      if (session.delivery !== null && session.delivery !== undefined) {
        Text(session.delivery.label)
          .fontSize(11)
          .fontWeight(600)
          .fontColor(WatchFormat.deliveryColor(session.delivery))
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .backgroundColor(this.tintOf(WatchFormat.deliveryColor(session.delivery)))
          .borderRadius(9)
      }
      Row({ space: 4 }) {
        SymbolGlyph(session.paused ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(10)
          .fontColor([session.paused ? Theme.textMuted : Theme.ok])
        Text(session.paused ? '已暂停' : '播放中')
          .fontSize(12)
          .fontColor(session.paused ? Theme.textMuted : Theme.ok)
      }
      if (session.progress_percent !== null && session.progress_percent !== undefined) {
        Text(`· ${Math.round(session.progress_percent)}%`)
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
      Blank()
      if (session.play_method !== 'local') {
        Text('网盘直链')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      } else if ((session.rate_bytes_per_second ?? 0) > 0) {
        Text(`↓ ${ActivityFormat.rate(session.rate_bytes_per_second ?? 0)}`)
          .fontSize(12)
          .fontColor(Theme.info)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 进度条下方：左端已看到的时刻，右端剩余时长（没有总时长时只显示已看到） */
  @Builder
  SessionClockLine(session: ActivePlaybackSessionView) {
    if (session.position_ms !== null && session.position_ms !== undefined) {
      Row() {
        Text(ActivityFormat.playClock(session.position_ms))
          .fontSize(11)
          .fontColor(Theme.textFaint)
        Blank()
        if (session.duration_ms !== null && session.duration_ms !== undefined
          && session.duration_ms > session.position_ms) {
          Text(`还剩 ${ActivityFormat.watched(session.duration_ms - session.position_ms)}`)
            .fontSize(11)
            .fontColor(Theme.textFaint)
        }
      }
      .width('100%')
    }
  }

  /** 正在下载（逐条对齐 iOS `ActivityFileDownloadRow`）：海报 + 标题 + 成员·设备 + 速率/已传/百分比 + 文件名 */
  @Builder
  DownloadsList() {
    // 横向留白加在区块级（卡片自身不带 padding/margin），所有段卡片同宽
    Column() {
      List() {
        ForEach(this.downloads(), (item: ActiveFileDownloadView, index: number) => {
          ListItem() {
            Column() {
              Row({ space: 12 }) {
                this.MediaPoster(item.media ?? null, 48, 70)
                Column({ space: 4 }) {
                  if (item.media !== null && item.media !== undefined) {
                    this.MediaTitle(item.media as MediaActivityTarget)
                  } else {
                    Text(item.file_name)
                      .fontSize(14)
                      .fontWeight(600)
                      .fontColor('rgba(243,245,249,0.9)')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  Text(WatchFormat.metaLine([
                    item.member_name,
                    WatchFormat.deviceLabel(item.client, item.device_name)
                  ]))
                    .fontSize(12)
                    .fontColor(Theme.textMuted)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Row({ space: 8 }) {
                    if (item.rate_bytes_per_second > 0) {
                      Text(ActivityFormat.rate(item.rate_bytes_per_second))
                        .fontSize(12)
                        .fontColor(Theme.info)
                    }
                    Text(ActivityFormat.bytes(item.position_bytes)
                      + (item.size_bytes > 0 ? ` / ${ActivityFormat.bytes(item.size_bytes)}` : ''))
                      .fontSize(12)
                      .fontColor(Theme.textFaint)
                    if (item.progress_percent !== null && item.progress_percent !== undefined) {
                      Text(`${Math.round(item.progress_percent)}%`)
                        .fontSize(12)
                        .fontColor(Theme.textMuted)
                    }
                  }
                  if (item.progress_percent !== null && item.progress_percent !== undefined) {
                    Progress({ value: Math.min(100, Math.max(0, item.progress_percent)), total: 100 })
                      .color(Theme.info)
                      .width('100%')
                      .height(3)
                  }
                  if (item.media !== null && item.media !== undefined) {
                    Text(item.file_name)
                      .fontSize(11)
                      .fontColor('rgba(138,147,166,0.8)')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .onClick(() => {
                this.openMedia(item.media ?? null);
              })
              .bindContextMenu(this.DownloadMenu(item), ResponseType.LongPress)
              if (index < this.downloads().length - 1) {
                Divider().color(Theme.line).margin({ left: 76, right: 16 })
              }
            }
            .width('100%')
          }
          .width('100%')
          .swipeAction({ end: item.revocable ? this.RevokeSwipe(item) : this.NoSwipe() })
        }, (item: ActiveFileDownloadView) => `dl-${item.device_id}-${item.file_name}`)
      }
      .width('100%')
      .enableScrollInteraction(false)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  /** 作品海报位：可跳详情时可点（对应 iOS `ActivityPoster`） */
  @Builder
  MediaPoster(media: MediaActivityTarget | null, posterWidth: number, posterHeight: number) {
    RemoteImage({
      url: ImageUrls.resolve(AppModel.origin(), media?.poster_url ?? null, ImageVariant.posterCard) ?? ''
    })
      .width(posterWidth)
      .height(posterHeight)
      .backgroundColor(Theme.glassFill)
      .borderRadius(8)
      .clip(true)
      .onClick(() => {
        this.openMedia(media);
      })
  }

  /**
   * 作品标题：片名 年份 SxxEyy 单集名 [仅管理]（对应 iOS `ActivityTitleText`）。
   * 用一个 `Text` 拼富文本，避免多段各自截断。
   */
  @Builder
  MediaTitle(media: MediaActivityTarget) {
    Text(this.titleParts(media))
      .fontSize(14)
      .fontWeight(600)
      .fontColor('rgba(243,245,249,0.9)')
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .onClick(() => {
        this.openMedia(media);
      })
  }

  /** 标题文本：片名 年份 SxxEyy 单集名 [仅管理] */
  private titleParts(media: MediaActivityTarget): string {
    const parts: string[] = [media.title.length === 0 ? '（条目已删除）' : media.title];
    if (media.year !== null && media.year !== undefined) {
      parts.push(`${media.year}`);
    }
    const unit: string | null = WatchFormat.unitLabel(media);
    if (unit !== null) {
      parts.push(unit);
    }
    const episodeTitle: string = media.episode_title ?? '';
    if (episodeTitle.length > 0) {
      parts.push(episodeTitle);
    }
    if (!media.browsable && (media.library_id !== null && media.library_id !== undefined)) {
      parts.push('仅管理');
    }
    return parts.join(' ');
  }

  /**
   * 观看统计：活动页只露**一张近 7 天摘要卡**（对应 iOS `ActivityWeeklyWatchCard`）。
   * 大数字 = 总观看时长，右侧与上 7 天对比，下面按天画 7 根柱子（今天高亮）。
   */
  @Builder
  StatsCard() {
    if (this.stats !== null) {
      // 横向留白加在区块级（卡片自身不带 padding/margin），所有段卡片同宽
      Column() {
        Button() {
          Column({ space: 12 }) {
            Row() {
              Column({ space: 2 }) {
                Text('最近 7 天')
                  .fontSize(12)
                  .fontColor(Theme.textMuted)
                // 「14 小时 18 分」：数字大、单位小（对应 iOS `ActivityWeeklyWatchCard.total`）
                Row({ space: 3 }) {
                  if (this.weeklyHours() > 0) {
                    Text(`${this.weeklyHours()}`)
                      .fontSize(30)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Theme.text)
                    Text('小时')
                      .fontSize(13)
                      .fontColor(Theme.textMuted)
                  }
                  if (this.weeklyRestMinutes() > 0 || this.weeklyHours() === 0) {
                    Text(`${this.weeklyRestMinutes()}`)
                      .fontSize(30)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Theme.text)
                    Text('分钟')
                      .fontSize(13)
                      .fontColor(Theme.textMuted)
                  }
                }
                .alignItems(VerticalAlign.Bottom)
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
              if (this.weeklyDeltaText().length > 0) {
                Text(this.weeklyDeltaText())
                  .fontSize(12)
                  .fontWeight(600)
                  .fontColor(this.weeklyDeltaColor())
              }
            }
            .width('100%')
          
            // 按天柱状（今天高亮，对应 iOS Chart BarMark）
            Row() {
              ForEach(this.weekDays(), (row: PlaybackStatsDayRow) => {
                Column() {
                  Column()
                    .width('72%')
                    .height(this.barHeight(row.watched_ms))
                    .borderRadius(4)
                    .backgroundColor(this.isToday(row.date) ? Theme.info : 'rgba(127, 176, 255, 0.4)')
                  Text(this.weekdayLabel(row.date))
                    .fontSize(10)
                    .fontColor(Theme.textFaint)
                    .margin({ top: 4 })
                }
                .layoutWeight(1)
                .height(84)
                .justifyContent(FlexAlign.End)
              }, (row: PlaybackStatsDayRow) => row.date)
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        }
        .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
        .padding(0)
        .clip(true)
        .borderRadius(Theme.cardRadius)
        // 整卡可点进统计二级页（对应 iOS 周卡 NavigationLink）
        .onClick(() => {
          this.navStack.pushPathByName('activityStats', null);
        })
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
  }

  /** 近 7 天的日子（服务端可能多给一天，只取最后 7 根） */
  private weekDays(): PlaybackStatsDayRow[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null) {
      return [];
    }
    return view.by_day.slice(-7);
  }

  private maxDayMs(): number {
    let max: number = 1;
    for (const row of this.weekDays()) {
      if (row.watched_ms > max) {
        max = row.watched_ms;
      }
    }
    return max;
  }

  /** 柱子高度（vp）：84 高的画区里留给柱子约 60，按当日时长占比缩放 */
  private barHeight(ms: number): number {
    if (ms <= 0) {
      return 2;
    }
    return Math.max(3, Math.round(58 * ms / this.maxDayMs()));
  }

  private isToday(date: string): boolean {
    const days: PlaybackStatsDayRow[] = this.weekDays();
    return days.length > 0 && days[days.length - 1].date === date;
  }

  /** "2026-09-26" → 「六」 */
  private weekdayLabel(date: string): string {
    const parts: string[] = date.split('-');
    if (parts.length !== 3) {
      return '';
    }
    const d: Date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
    const names: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    return names[d.getDay()];
  }

  private weeklyMinutes(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : Math.round(view.current.watched_ms / 60000);
  }

  private weeklyHours(): number {
    return Math.floor(this.weeklyMinutes() / 60);
  }

  private weeklyRestMinutes(): number {
    return this.weeklyMinutes() % 60;
  }

  /** 与上一周期对比文案；没有上一周期就返回空，别编一个「+0%」 */
  private weeklyDeltaText(): string {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null || !view.previous_available) {
      return '';
    }
    const cur: number = view.current.watched_ms;
    const prev: number = view.previous.watched_ms;
    if (prev <= 0) {
      return cur > 0 ? '比前 7 天新增' : '';
    }
    const ratio: number = Math.round((cur - prev) / prev * 100);
    if (ratio === 0) {
      return '与前 7 天持平';
    }
    return ratio > 0 ? `比前 7 天 ↑ ${ratio}%` : `比前 7 天 ↓ ${Math.abs(ratio)}%`;
  }

  private weeklyDeltaColor(): string {
    const text: string = this.weeklyDeltaText();
    if (text.startsWith('↓') || text === '与前 7 天持平') {
      return Theme.textMuted;
    }
    return Theme.ok;
  }

  /**
   * 最近播放（对应 iOS `ActivityRecentPlayRow`）：小海报 + 片名/成员·设备 + 右列「看到哪 / 相对时间」。
   * 观看进度放右列且不截断：设备名只截断它自己那一行，不会再把「看到 42%」挤没。
   */
  @Builder
  PlaysList() {
    // 横向留白加在区块级（卡片自身不带 padding/margin），所有段卡片同宽
    Column() {
      Column() {
        ForEach(this.plays, (entry: PlaybackLogEntryView, index: number) => {
          Column() {
            Row({ space: 12 }) {
              RemoteImage({
                url: ImageUrls.resolve(AppModel.origin(), entry.media.poster_url ?? null,
                  ImageVariant.posterCard) ?? ''
              })
                .width(34)
                .height(50)
                .backgroundColor(Theme.glassFill)
                .borderRadius(6)
                .clip(true)
              Column({ space: 2 }) {
                Text(this.recentPlayTitle(entry))
                  .fontSize(14)
                  .fontWeight(600)
                  .fontColor(Theme.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(WatchFormat.metaLine([
                  entry.member_name,
                  entry.device_name.length > 0 ? entry.device_name : entry.client
                ]))
                  .fontSize(12)
                  .fontColor(Theme.textMuted)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              // 结果在上（与片名同一行、字重高一档），时间在下（与副标题同一行、更淡）
              Column({ space: 2 }) {
                Text(this.recentPlayState(entry))
                  .fontSize(12)
                  .fontWeight(500)
                  .fontColor(this.recentPlayStateColor(entry))
                if ((entry.ended_at ?? '') !== '') {
                  Text(Formatters.relative(entry.started_at))
                    .fontSize(12)
                    .fontColor(Theme.textFaint)
                }
              }
              .alignItems(HorizontalAlign.End)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .onClick(() => {
              this.openMedia(entry.media);
            })
            if (index < this.plays.length - 1) {
              Divider().color(Theme.line).margin({ left: 62, right: 16 })
            }
          }
          .width('100%')
        }, (entry: PlaybackLogEntryView) => `${entry.id}`)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  /** 最近播放的标题：片名 + SxxEyy */
  private recentPlayTitle(entry: PlaybackLogEntryView): string {
    const title: string = entry.media.title.length === 0 ? '（条目已删除）' : entry.media.title;
    const unit: string | null = WatchFormat.unitLabel(entry.media);
    return unit !== null ? `${title} ${unit}` : title;
  }

  /** 右列上排：播放中 / 看完 / 看到 N% */
  private recentPlayState(entry: PlaybackLogEntryView): string {
    if ((entry.ended_at ?? '') === '') {
      return '播放中';
    }
    if (entry.completed) {
      return '看完';
    }
    const percent: number | null = entry.progress_percent ?? null;
    return percent !== null ? `看到 ${Math.round(percent)}%` : '';
  }

  private recentPlayStateColor(entry: PlaybackLogEntryView): string {
    if ((entry.ended_at ?? '') === '' || entry.completed) {
      return Theme.ok;
    }
    return Theme.textMuted;
  }

  /**
   * 需要处理（对应 iOS `TaskCenterPanel(mode: .attention)`）：
   * 有问题的下载组在上、失败的独立作业在下；每组/每张卡都带补救动作。
   */
  @Builder
  AttentionSection() {
    Column({ space: 10 }) {
      this.SectionHeader('需要处理', this.attentionTotal(), Theme.danger,
        this.attention().length > 0
          ? (this.dismissingAll ? '正在忽略…' : '全部忽略') : '',
        (): void => {
          this.confirmDismissAll();
        }, false)

      // 有问题的下载组（换种 / 删除由二级页处理，这里只报状态）
      ForEach(this.attentionGroups(), (group: DownloadGroup) => {
        Column() {
          this.DownloadGroupCard(group)
        }
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      }, (group: DownloadGroup) => group.id)

      ForEach(this.attention(), (job: JobView) => {
        // 横向留白加在区块级（卡片自身不带 margin），避免卡片内的 width('100%') 顶出屏幕右缘
        Column() {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Text(this.jobTitle(job))
                .fontSize(15)
                .fontWeight(600)
                .fontColor(Theme.text)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.statusLabel(job.status))
                .fontSize(12)
                .fontColor(Theme.danger)
            }
            .width('100%')
            Text(this.jobSubtitle(job))
              .fontSize(12)
              .fontColor(Theme.textFaint)
            if (this.errorText(job).length > 0) {
              Text(this.errorText(job))
                .fontSize(12)
                .fontColor(Theme.textMuted)
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            Row({ space: 10 }) {
              Button() {
                Text(this.acting === job.id ? '处理中…' : '重试')
                  .fontSize(13)
                  .fontWeight(600)
                  .fontColor('#0b0d12')
              }
              .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
              .padding({ left: 16, right: 16, top: 7, bottom: 7 })
              .borderRadius(15)
              .onClick(() => {
                this.retry(job);
              })
              Button() {
                Text('忽略')
                  .fontSize(13)
                  .fontColor(Theme.textMuted)
              }
              .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
              .padding({ left: 16, right: 16, top: 7, bottom: 7 })
              .borderRadius(15)
              .onClick(() => {
                this.dismiss(job);
              })
            }
            .width('100%')
            .margin({ top: 2 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
        }
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      }, (job: JobView) => job.id)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 一组下载（同一部作品的多个资源合并）的状态卡（对齐 iOS `DownloadTaskGroupCard`）。
   * 「需要处理」里这份卡片带补救动作：换种（卡住/出错时重新找源）、删除。
   */
  @Builder
  DownloadGroupCard(group: DownloadGroup) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        this.MediaPoster(this.groupMedia(group), 40, 58)
        Column({ space: 5 }) {
          Row({ space: 8 }) {
            Text(group.title)
              .fontSize(14)
              .fontWeight(600)
              .fontColor('rgba(243,245,249,0.9)')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (group.tasks.length > 1) {
              Text(`${group.tasks.length} 个资源`)
                .fontSize(11)
                .fontColor(Theme.textFaint)
            }
            Text(`${DownloadTasks.percent(group)}%`)
              .fontSize(12)
              .fontWeight(600)
              .fontColor(Theme.textMuted)
          }
          .width('100%')
          Text(DownloadTasks.statusLine(group))
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Progress({ value: Math.min(100, Math.max(0, DownloadTasks.percent(group))), total: 100 })
            .color(DownloadTasks.color(group))
            .width('100%')
            .height(3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 补救动作：单资源才给换种（多资源时不知道换哪个）；删除始终可用
      Row({ space: 10 }) {
        if (group.tasks.length === 1 && group.tasks[0].can_replace
          && (group.tasks[0].downloader_id ?? null) !== null) {
          Button() {
            Text(this.acting === group.tasks[0].info_hash ? '换种中…' : '换种')
              .fontSize(13)
              .fontWeight(600)
              .fontColor('#0b0d12')
          }
          .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .borderRadius(14)
          .onClick(() => {
            this.replaceTask(group.tasks[0]);
          })
        }
        Button() {
          Text('删除')
            .fontSize(13)
            .fontColor(Theme.danger)
        }
        .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .borderRadius(14)
        .onClick(() => {
          this.confirmDeleteTask(group);
        })
        Blank()
        Text('查看进度 ›')
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .onClick(() => {
            this.navStack.pushPathByName('activityTasks', new ActivityTasksParams('active'));
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 换种：给卡住/出错的下载换一个同品质的种子源（对应 iOS `replace`） */
  private async replaceTask(task: DownloadTaskView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const downloaderId: number | null = task.downloader_id ?? null;
    if (api === null || downloaderId === null || this.acting.length > 0) {
      return;
    }
    this.acting = task.info_hash;
    try {
      await api.dlTorrentReplace(downloaderId, task.info_hash);
      this.toast('已换新种，任务重新开始');
      await this.loadDownloads();
    } catch (error) {
      const message: string = this.messageOf(error);
      this.toast(message.length > 0 ? message : '换种失败');
    } finally {
      this.acting = '';
    }
  }

  /** 删除下载任务：先问「要不要连已下好的文件一起删」（对应 iOS 的 taskDeleteSheet） */
  private confirmDeleteTask(group: DownloadGroup): void {
    if (this.acting.length > 0) {
      return;
    }
    const task: DownloadTaskView = group.tasks[0];
    const downloaderId: number | null = task.downloader_id ?? null;
    if (downloaderId === null) {
      this.toast('这个任务没有可操作的下载器');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '从下载器里删除这个任务？',
      message: `「${group.title}」\n\n只删任务的话，已下载的文件会留在磁盘上；连同文件一起删则无法恢复。`,
      primaryButton: {
        value: '只删任务',
        action: (): void => {
          this.deleteTask(downloaderId, task.info_hash, false);
        }
      },
      secondaryButton: {
        value: '连文件一起删',
        fontColor: Theme.danger,
        action: (): void => {
          this.deleteTask(downloaderId, task.info_hash, true);
        }
      }
    });
  }

  private async deleteTask(downloaderId: number, infoHash: string, deleteFiles: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.acting.length > 0) {
      return;
    }
    this.acting = infoHash;
    try {
      await api.dlTorrentDelete(downloaderId, infoHash, deleteFiles);
      this.toast('已删除');
      await this.loadDownloads();
    } catch (error) {
      const message: string = this.messageOf(error);
      this.toast(message.length > 0 ? message : '删除失败');
    } finally {
      this.acting = '';
    }
  }

  /** 下载组代表的海报：组内第一个带 media_item_id 的任务 */
  private groupMedia(group: DownloadGroup): MediaActivityTarget | null {
    const first: DownloadTaskView = group.tasks[0];
    if (first.media_item_id === null || first.media_item_id === undefined) {
      return null;
    }
    const media: MediaActivityTarget = {
      media_item_id: first.media_item_id,
      library_id: null,
      browsable: false,
      kind: group.kind.length > 0 ? group.kind : 'movie',
      title: group.title,
      year: null,
      poster_url: group.posterUrl,
      season_number: 0,
      episode_number: 0,
      episode_title: null
    };
    return media;
  }

  /**
   * 进行中（对应 iOS `ActivityView` 的「进行中」段）：
   * 下载组（按作品合并）+ 独立作业，最多露 5 条，其余进二级页；有刷流种子时补一行汇总。
   */
  @Builder
  ActiveSection() {
    Column({ space: 10 }) {
      this.SectionHeader('进行中', this.activeTotal() > 0 ? this.activeTotal() : 0,
        '', this.activeTotal() > 0 ? '查看全部' : '', (): void => {
          this.navStack.pushPathByName('activityTasks', new ActivityTasksParams('active'));
        })

      Column() {
        Column() {
          // 下载组在前、独立作业在后（二级页时间线也是这个顺序），两者合计最多露 5 条
          ForEach(this.activeGroups().slice(0, ActivityPage.ACTIVE_LIMIT), (group: DownloadGroup) => {
            this.ActiveDownloadRow(group)
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
          }, (group: DownloadGroup) => group.id)
          ForEach(this.active().slice(0, Math.max(0,
            ActivityPage.ACTIVE_LIMIT - this.activeGroups().length)), (job: JobView) => {
            this.JobRow(job, true)
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
          }, (job: JobView) => job.id)
          if (this.boostTasks().length > 0) {
            this.BoostSummaryRow()
          }
        }
        .width('100%')
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 进行中的下载组一行（对应 iOS `ActivityActiveDownloadRow`） */
  @Builder
  ActiveDownloadRow(group: DownloadGroup) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.arrow_down'))
        .fontSize(18)
        .fontColor([DownloadTasks.color(group)])
        .width(26)
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(group.title)
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.text)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (group.tasks.length > 1) {
            Text(`${group.tasks.length} 个资源`)
              .fontSize(11)
              .fontColor(Theme.textFaint)
          }
          Text(`${DownloadTasks.percent(group)}%`)
            .fontSize(12)
            .fontWeight(600)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        Text(DownloadTasks.statusLine(group))
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Progress({ value: Math.min(100, Math.max(0, DownloadTasks.percent(group))), total: 100 })
          .color(DownloadTasks.color(group))
          .width('100%')
          .height(3)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      this.navStack.pushPathByName('activityTasks', new ActivityTasksParams('active'));
    })
  }

  /** 刷流做种汇总行（对应 iOS `ActivityBoostSummaryRow`）：N 个种子 · ↑ 速率 · 累计上传 */
  @Builder
  BoostSummaryRow() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.leaf'))
        .fontSize(18)
        .fontColor([Theme.ok])
        .width(26)
      Column({ space: 3 }) {
        Text('刷流做种')
          .fontSize(14)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text(WatchFormat.metaLine([
          `${this.boostTasks().length} 个种子`,
          `↑ ${ActivityFormat.rate(BoostTotals.of(this.boostTasks()).upSpeed)}`,
          `已上传 ${ActivityFormat.bytes(BoostTotals.of(this.boostTasks()).uploaded)}`
        ]))
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      this.navStack.pushPathByName('activityTasks', new ActivityTasksParams('active'));
    })
  }

  /**
   * 最近完成（对应 iOS `ActivityFinishedJobRow`）：
   * 结果图标（宽 26）+ 标题 / 一行摘要 + 右侧相对时间；左滑撤销忽略 / 重新执行。
   */
  @Builder
  RecentSection() {
    Column({ space: 10 }) {
      this.SectionHeader('最近完成', this.recent().length, '',
        `查看全部 ${this.recentTotal()} 个`, (): void => {
          this.navStack.pushPathByName('activityTasks', new ActivityTasksParams('finished'));
        })
      /*
       * 用 Column + ForEach 而不是 List/LazyForEach：整页在 Scroll 里，内层 List 会和外层抢滚动手势；
       * 这里最多露 5 条，不需要懒加载。
       */
      // 横向留白加在区块级（卡片自身不带 padding/margin），所有段卡片同宽
      Column() {
        List() {
          ForEach(this.recent(), (job: JobView, index: number) => {
            ListItem() {
              Column() {
                this.FinishedRow(job)
                if (index < this.recent().length - 1) {
                  Divider().color(Theme.line).margin({ left: 54, right: 16 })
                }
              }
              .width('100%')
            }
            .width('100%')
            // 左滑：被忽略的失败可撤销忽略，用户取消的可重新执行（对应 iOS finishedRow swipeActions）
            .swipeAction({ end: this.FinishedSwipe(job) })
          }, (job: JobView) => job.id)
        }
        .width('100%')
        .enableScrollInteraction(false)
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 已结束的全部条数（含被忽略的失败） */
  private recentTotal(): number {
    let total: number = 0;
    for (const job of this.jobs) {
      if (TaskState.isHistorical(job)) {
        total++;
      }
    }
    return total;
  }

  /** 最近完成一行：结果图标 + 标题/摘要 + 相对时间（对应 iOS ActivityFinishedJobRow） */
  @Builder
  FinishedRow(job: JobView) {
    Row({ space: 12 }) {
      // 成功 ✓ / 被忽略的失败（眼斜杠）/ 取消 ✕（对应 iOS `ActivityFinishedJobRow` 的三种图标）
      SymbolGlyph(this.finishedIcon(job))
        .fontSize(20)
        .fontColor([this.finishedIconColor(job)])
        .width(26)
      Column({ space: 3 }) {
        Text(this.jobTitle(job))
          .fontSize(14)
          .fontWeight(600)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.finishedSummary(job))
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(Formatters.relative(job.finished_at ?? job.created_at))
        .fontSize(12)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
  }

  /** 终态行的图标：成功 / 被忽略的失败 / 用户取消 / 系统取消 */
  private finishedIcon(job: JobView): Resource {
    if (job.status === 'succeeded') {
      return $r('sys.symbol.checkmark_circle_fill');
    }
    if (job.status === 'failed' && TaskState.isDismissed(job)) {
      return $r('sys.symbol.eye_slash');
    }
    return $r('sys.symbol.xmark_circle');
  }

  /** 终态行的一行摘要：被忽略的失败要说清楚「已忽略」，取消要区分系统收口 */
  private finishedSummary(job: JobView): string {
    if (job.status === 'failed' && TaskState.isDismissed(job)) {
      return WatchFormat.metaLine([ActivityPage.typeLabel(job), '已忽略']);
    }
    if (job.status === 'cancelled' && TaskState.isSystemCancelled(job)) {
      return WatchFormat.metaLine([ActivityPage.typeLabel(job), '系统取消']);
    }
    return this.jobSubtitle(job);
  }

  private finishedIconColor(job: JobView): string {
    return job.status === 'succeeded' ? Theme.ok : Theme.textFaint;
  }

  /** 最近完成的左滑动作（对应 iOS：失败且被忽略→撤销忽略；用户取消→重新执行，系统取消不给） */
  @Builder
  FinishedSwipe(job: JobView) {
    Row() {
      if (job.status === 'failed' && TaskState.isDismissed(job)) {
        Text('撤销忽略')
          .fontSize(14)
          .fontColor('#ffffff')
          .textAlign(TextAlign.Center)
          .width(92)
          .height('100%')
          .backgroundColor(Theme.warn)
          .onClick(() => {
            this.undismiss(job);
          })
      }
      if (job.status === 'cancelled' && !TaskState.isSystemCancelled(job)) {
        Text('重新执行')
          .fontSize(14)
          .fontColor('#ffffff')
          .textAlign(TextAlign.Center)
          .width(84)
          .height('100%')
          .backgroundColor(Theme.info)
          .onClick(() => {
            this.retry(job);
          })
      }
    }
    .height('100%')
  }

  /** 撤销忽略：被忽略的失败任务回到「需要处理」（对应 iOS undismiss） */
  private async undismiss(job: JobView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.acting.length > 0) {
      return;
    }
    this.acting = job.id;
    try {
      await api.jobsUndismiss(job.id);
      this.toast('已撤销忽略');
      await this.load();
    } catch (error) {
      this.toast('撤销忽略失败，请稍后再试');
    } finally {
      this.acting = '';
    }
  }

  /** 进行中任务行（对应 iOS `ActivityActiveJobRow`）：齿轮图标（宽 26）+ 标题行/副标题/进度条 */
  @Builder
  JobRow(job: JobView, showProgress: boolean) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(20)
        .fontColor([Theme.info])
        .width(26)
      Column({ space: 4 }) {
        Row({ space: 10 }) {
          Text(this.jobTitle(job))
            .fontSize(15)
            .fontColor(Theme.text)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.progressText(job).length > 0 && showProgress
            ? this.progressText(job) : this.statusLabel(job.status))
            .fontSize(13)
            .fontColor(this.statusColor(job.status))
        }
        .width('100%')
        Text(this.jobSubtitle(job))
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (showProgress && this.progressText(job).length > 0) {
          Progress({ value: this.progressValue(job), total: 100 })
            .width('100%')
            .height(4)
            .color(Theme.accent)
            .backgroundColor(Theme.line)
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
  }

  /** 左滑「取消」（对应 iOS 的 swipeActions + destructive 红底） */
  @Builder
  CancelSwipe(job: JobView) {
    Button() {
      Text('取消')
        .fontSize(15)
        .fontColor('#ffffff')
        .textAlign(TextAlign.Center)
    }
    .attributeModifier(new GlassButtonModifier(GlassTone.Danger))
    .padding(0)
    .width(76)
    .height('100%')
    .borderRadius(0)
    .onClick(() => {
      this.confirmCancel(job);
    })
  }

  @Builder
  EmptyState() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle'))
        .fontSize(34)
        .fontColor([Theme.ok])
      Text('没有进行中的任务')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text('刮削、识别、转移这些后台活儿都干完了。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 60 })
    .justifyContent(FlexAlign.Center)
  }
}
