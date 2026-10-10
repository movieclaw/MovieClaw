import { Theme } from '../theme/AppTheme';
import { Formatters } from '../common/Formatters';
import { AppModel } from '../common/AppModel';
import { AppFooter } from '../common/AppFooter';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { EventStream, ServerEvent, StreamHandle } from '../common/EventStream';
import { JobProgressView, JobView, JobWorkerHealthView, JobDismissAllView, PlaybackHistoryView, PlaybackLogEntryView, MediaActivityView, ActivePlaybackSessionView, ActiveFileDownloadView, PlaybackWatchStatsView, PlaybackStatsTotals, PlaybackStatsDayRow, MediaActivityTarget } from '../api/Models';
import { ActivityTasksParams } from './ActivityTasksPage';

/** 任务列表的 LazyForEach 数据源（active/recent 两个 List 共用；只建可视区附近的行）。 */
class JobListSource implements IDataSource {
  private items: JobView[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): JobView {
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

  setJobs(items: JobView[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

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

  // MARK: jobs 事件流与定时器（页面消失必须全清）
  private stream: StreamHandle | null = null;
  /** 兜底轮询（SSE 断了也保证 jobs 数据不停，15s 对齐 iOS fallbackPoll） */
  private timer: number = -1;
  /** 连发事件合并：ready/job 一次连推多条，120ms 合并为一次快照校准 */
  private debounceTimer: number = -1;
  /** 断线后 3s 重连 */
  private reconnectTimer: number = -1;
  private activeSource: JobListSource = new JobListSource();
  private recentSource: JobListSource = new JobListSource();
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
    // 刷新两个懒加载列表的数据源
    this.activeSource.setJobs(this.active());
    this.recentSource.setJobs(this.recent());
  }

  /** 首次进入 / 下拉刷新：jobs + 其余段（最近播放 / 正在播放与下载 / 观看统计）。 */
  private async load(): Promise<void> {
    await this.loadJobs();
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

  /** 需要处理：失败的任务（对应 iOS 的 attention） */
  private attention(): JobView[] {
    return this.filterBy('failed');
  }

  /** 进行中：排队 + 运行（对应 iOS 的「正在下载 / 进行中」） */
  private active(): JobView[] {
    const out: JobView[] = [];
    for (const job of this.jobs) {
      if (job.status === 'running' || job.status === 'queued') {
        out.push(job);
      }
    }
    return out;
  }

  /** 最近完成：成功 + 已取消，按创建时间倒序取前 5 */
  private recent(): JobView[] {
    const done: JobView[] = [];
    for (const job of this.jobs) {
      if (job.status === 'succeeded' || job.status === 'cancelled') {
        done.push(job);
      }
    }
    done.sort((a: JobView, b: JobView): number => (a.created_at < b.created_at ? 1 : -1));
    return done.slice(0, 5);
  }

  private filterBy(status: string): JobView[] {
    const out: JobView[] = [];
    for (const job of this.jobs) {
      if (job.status === status) {
        out.push(job);
      }
    }
    return out;
  }

  private workerDown(): boolean {
    const health: JobWorkerHealthView | null = this.health;
    return health !== null && !health.running;
  }

  /** 顶部一行实时摘要（对应 iOS 的 activity-summary） */
  private summary(): string {
    const parts: string[] = [];
    const attention: number = this.attention().length;
    if (attention > 0) {
      parts.push(`${attention} 项需要处理`);
    }
    const active: number = this.active().length;
    if (active > 0) {
      parts.push(`${active} 个任务进行中`);
    }
    const health: JobWorkerHealthView | null = this.health;
    if (health !== null && health.oldest_queued_seconds !== null
      && health.oldest_queued_seconds !== undefined && health.oldest_queued_seconds > 60) {
      parts.push(`最久排队 ${this.duration(health.oldest_queued_seconds)}`);
    }
    return parts.length > 0 ? parts.join('  ·  ') : '一切正常';
  }

  // MARK: 动作

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
    this.getUIContext().getPromptAction().showToast({ message: message });
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
    'library.organize': '整理媒体库文件',
    'library.transfer': '转移媒体库条目',
    'library.ingest': '自动整理入库'
  };

  private static typeLabel(jobType: string): string {
    const label: string | undefined = ActivityPage.JOB_TYPE_LABELS[jobType];
    return label !== undefined ? label : jobType;
  }

  private jobTitle(job: JobView): string {
    const subject: string | null = job.subject ?? null;
    if (subject !== null && subject.length > 0) {
      return subject;
    }
    return ActivityPage.typeLabel(job.job_type);
  }

  private jobSubtitle(job: JobView): string {
    const parts: string[] = [ActivityPage.typeLabel(job.job_type)];
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

  private duration(seconds: number): string {
    if (seconds < 60) {
      return `${Math.round(seconds)} 秒`;
    }
    if (seconds < 3600) {
      return `${Math.round(seconds / 60)} 分钟`;
    }
    return `${Math.round(seconds / 360) / 10} 小时`;
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
      this.TitleBar()
      if (this.failedOnce) {
        this.ErrorState()
      } else {
        this.Content()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 标题「活动」交给宿主原生标题栏；这里只留摘要行 */
  @Builder
  TitleBar() {
    Column({ space: 2 }) {
      Text(this.summary())
        .fontSize(13)
        .fontColor(this.attention().length > 0 ? Theme.danger : Theme.textMuted)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 6, bottom: 12 })
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
  Content() {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column({ space: 24 }) {
          if (this.workerDown()) {
            this.WorkerWarning()
          }
          if (this.attention().length > 0) {
            this.AttentionSection()
          }
          /*
           * 自上而下照 iOS ActivityView：需要处理 → 正在播放 → 正在下载 → 进行中 →
           * 最近播放 → 观看统计 → 最近完成。各段显示条件独立、互不嵌套
           * （上一版把「最近播放」塞进「进行中」，结果没有进行中任务时整段消失）。
           */
      if (this.sessions().length > 0 || this.hiddenSessions() > 0) {
        this.SectionHeader('正在播放',
          this.sessions().length + this.hiddenSessions(), Theme.ok, '', (): void => {
          })
        this.SessionsList()
      }
      if (this.downloads().length > 0 || this.hiddenDownloads() > 0) {
        this.SectionHeader('正在下载',
          this.downloads().length + this.hiddenDownloads(), '', '', (): void => {
          })
        this.DownloadsList()
      }
          if (this.active().length > 0) {
            this.ActiveSection()
          }
          if (this.plays.length > 0) {
            this.SectionHeader('最近播放', this.plays.length, '', '查看全部', (): void => {
              this.navStack.pushPathByName('activityPlays', null);
            })
            this.PlaysList()
          }
          if (this.stats !== null) {
            this.SectionHeader('观看统计', 0, '', '查看全部', (): void => {
              this.navStack.pushPathByName('activityStats', null);
            })
            this.StatsCard()
          }
          if (this.recent().length > 0) {
            this.RecentSection()
          }
          if (this.attention().length === 0 && this.active().length === 0
            && this.recent().length === 0 && this.plays.length === 0
            && this.sessions().length === 0 && this.downloads().length === 0) {
            this.EmptyState()
          }
          // 页脚：品牌联合声明，复用全局 AppFooter
          AppFooter({ topSpace: 8 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 4, bottom: Theme.tabBarInset })
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
      .padding(14)
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
          .fill(tint)
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
   * 正在播放：谁、在哪台设备、看到哪、实时速率。
   *
   * **`paused` 要显出来**——一条停在 40% 不动的会话，和「正在播但用户暂停了」
   * 是两件不同的事；不区分的话用户会以为卡住了。
   */
  @Builder
  SessionsList() {
    Column() {
      ForEach(this.sessions(), (session: ActivePlaybackSessionView, index: number) => {
        Column() {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.play_circle'))
              .fontSize(20)
              .fontColor([session.paused ? Theme.textMuted : Theme.ok])
              .width(26)
            Column({ space: 3 }) {
              Text(session.media.title)
                .fontSize(15)
                .fontColor(Theme.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.sessionLine(session))
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(session.paused ? '已暂停' : `${Math.round(session.progress_percent ?? 0)}%`)
              .fontSize(12)
              .fontColor(session.paused ? Theme.textFaint : Theme.ok)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 16, right: 16, top: 11, bottom: 11 })
          if (session.progress_percent !== null && session.progress_percent !== undefined) {
            Progress({ value: session.progress_percent, total: 100 })
              .color(session.paused ? Theme.textMuted : Theme.ok)
              .width('100%')
              .height(2)
          }
          if (index < this.sessions().length - 1) {
            Divider().color(Theme.line).margin({ left: 54, right: 16 })
          }
        }
        .width('100%')
      }, (session: ActivePlaybackSessionView) => `s-${session.device_id}-${session.started_at}`)
      if (this.hiddenSessions() > 0) {
        Text(`另有 ${this.hiddenSessions()} 条（别的成员的，管理员可在设置里看全部）`)
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .padding({ left: 16, right: 16, top: 8, bottom: 10 })
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  private sessionLine(session: ActivePlaybackSessionView): string {
    const parts: string[] = [];
    if (session.member_name.length > 0) {
      parts.push(session.member_name);
    }
    const device: string = session.device_name.length > 0 ? session.device_name : session.client;
    if (device.length > 0) {
      parts.push(device);
    }
    const rate: number | null = session.rate_bytes_per_second ?? null;
    if (rate !== null && rate > 0) {
      parts.push(`${Formatters.bytes(rate)}/s`);
    }
    if (session.connections > 1) {
      parts.push(`${session.connections} 连接`);
    }
    return parts.join('  ·  ');
  }

  /** 正在下载：速率与进度 */
  @Builder
  DownloadsList() {
    Column() {
      ForEach(this.downloads(), (item: ActiveFileDownloadView, index: number) => {
        Column() {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.arrow_down'))
              .fontSize(20)
              .fontColor([Theme.info])
              .width(26)
            Column({ space: 3 }) {
              Text(item.media !== null && item.media !== undefined
                ? (item.media as MediaActivityTarget).title : item.file_name)
                .fontSize(15)
                .fontColor(Theme.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.downloadLine(item))
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(`${Math.round(item.progress_percent ?? 0)}%`)
              .fontSize(12)
              .fontColor(Theme.info)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 16, right: 16, top: 11, bottom: 11 })
          if (item.progress_percent !== null && item.progress_percent !== undefined) {
            Progress({ value: item.progress_percent, total: 100 })
              .color(Theme.info)
              .width('100%')
              .height(2)
          }
          if (index < this.downloads().length - 1) {
            Divider().color(Theme.line).margin({ left: 54, right: 16 })
          }
        }
        .width('100%')
      }, (item: ActiveFileDownloadView) => `dl-${item.device_id}-${item.file_name}`)
      if (this.hiddenDownloads() > 0) {
        Text(`另有 ${this.hiddenDownloads()} 条下载中`)
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .padding({ left: 16, right: 16, top: 8, bottom: 10 })
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  private downloadLine(item: ActiveFileDownloadView): string {
    const parts: string[] = [Formatters.bytes(item.bytes_sent) + ' / ' + Formatters.bytes(item.size_bytes)];
    if (item.rate_bytes_per_second > 0) {
      parts.push(`${Formatters.bytes(item.rate_bytes_per_second)}/s`);
    }
    if (item.member_name.length > 0) {
      parts.push(item.member_name);
    }
    return parts.join('  ·  ');
  }

  /**
   * 观看统计：活动页只露**一张近 7 天摘要卡**（对应 iOS `ActivityWeeklyWatchCard`）。
   * 大数字 = 总观看时长，右侧与上 7 天对比，下面按天画 7 根柱子（今天高亮）。
   */
  @Builder
  StatsCard() {
    if (this.stats !== null) {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('最近 7 天')
              .fontSize(12)
              .fontColor(Theme.textMuted)
            Row({ space: 4 }) {
              Text(this.weeklyHoursNum())
                .fontSize(30)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.text)
              Text(this.weeklyHoursUnit())
                .fontSize(13)
                .fontColor(Theme.textMuted)
            }
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
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
      // 整卡可点进统计二级页（对应 iOS 周卡 NavigationLink）
      .onClick(() => {
        this.navStack.pushPathByName('activityStats', null);
      })
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

  private weeklyHoursNum(): string {
    const minutes: number = this.weeklyMinutes();
    return `${Math.floor(minutes / 60)}`;
  }

  private weeklyHoursUnit(): string {
    const minutes: number = this.weeklyMinutes();
    const h: number = Math.floor(minutes / 60);
    const m: number = minutes % 60;
    if (h === 0) {
      return '分钟';
    }
    return m > 0 ? `小时 ${m} 分` : '小时';
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

  /** 最近播放：谁、在哪台设备、看了多久、看到哪 */
  @Builder
  PlaysList() {
    Column() {
      ForEach(this.plays, (entry: PlaybackLogEntryView, index: number) => {
        Column() {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.play_circle'))
              .fontSize(20)
              .fontColor([Theme.accent])
              .width(26)
            Column({ space: 3 }) {
              Text(entry.media.title)
                .fontSize(15)
                .fontColor(Theme.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.playLine(entry))
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(Formatters.relative(entry.started_at))
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 16, right: 16, top: 11, bottom: 11 })
          if (index < this.plays.length - 1) {
            Divider().color(Theme.line).margin({ left: 54, right: 16 })
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

  /** 一行说清「谁 · 哪台设备 · 看了多久 · 看完没」 */
  private playLine(entry: PlaybackLogEntryView): string {
    const parts: string[] = [];
    if (entry.member_name.length > 0) {
      parts.push(entry.member_name);
    }
    const device: string = entry.device_name.length > 0 ? entry.device_name : entry.client;
    if (device.length > 0) {
      parts.push(device);
    }
    if (entry.watched_ms > 0) {
      parts.push(`看了 ${Math.max(1, Math.round(entry.watched_ms / 60000))} 分钟`);
    }
    if (entry.completed) {
      parts.push('已看完');
    } else {
      const percent: number | null = entry.progress_percent ?? null;
      if (percent !== null && percent > 0) {
        parts.push(`${Math.round(percent)}%`);
      }
    }
    return parts.join('  ·  ');
  }

  /** 需要处理：失败任务，带重试/忽略（对应 iOS 的 attention 卡片） */
  @Builder
  AttentionSection() {
    Column({ space: 10 }) {
      this.SectionHeader('需要处理', this.attention().length, Theme.danger,
        this.attention().length > 0
          ? (this.dismissingAll ? '正在忽略…' : '全部忽略') : '',
        (): void => {
          this.confirmDismissAll();
        }, false)

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
              Text(this.acting === job.id ? '处理中…' : '重试')
                .fontSize(13)
                .fontWeight(600)
                .fontColor('#0b0d12')
                .padding({ left: 16, right: 16, top: 7, bottom: 7 })
                .backgroundColor(Theme.accent)
                .borderRadius(15)
                .onClick(() => {
                  this.retry(job);
                })
              Text('忽略')
                .fontSize(13)
                .fontColor(Theme.textMuted)
                .padding({ left: 16, right: 16, top: 7, bottom: 7 })
                .backgroundColor(Theme.glassFill)
                .borderRadius(15)
                .border({ width: 1, color: Theme.line })
                .onClick(() => {
                  this.dismiss(job);
                })
            }
            .width('100%')
            .margin({ top: 2 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
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

  /** 进行中：排队 + 运行，带进度条与取消 */
  @Builder
  ActiveSection() {
    Column({ space: 10 }) {
      this.SectionHeader('进行中', this.active().length, '', '查看全部', (): void => {
        this.navStack.pushPathByName('activityTasks', new ActivityTasksParams('active'));
      })

      // 横向留白加在区块级（列表自身不带 margin），避免列表内的 width('100%') 顶出屏幕右缘
      Column() {
        List() {
          LazyForEach(this.activeSource, (job: JobView) => {
            ListItem() {
              this.JobRow(job, true)
            }
            // 左滑取消（对应 iOS 的 swipeActions）
            .swipeAction({ end: this.CancelSwipe(job) })
          }, (job: JobView) => job.id)
        }
        .width('100%')
        // 本 SDK 的 List 没有 listStyle(insetGrouped)，用「圆角底 + 分隔线」做出同样的分组观感
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
        .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 16, endMargin: 16 })
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 最近完成（对应 iOS `ActivityFinishedJobRow`）：
   * 结果图标（宽 26）+ 标题 / 一行摘要 + 右侧相对时间；左滑撤销忽略 / 重新执行。
   */
  @Builder
  RecentSection() {
    Column({ space: 10 }) {
      this.SectionHeader('最近完成', this.recent().length, '',
        `查看全部 ${this.jobs.length} 个`, (): void => {
          this.navStack.pushPathByName('activityTasks', new ActivityTasksParams('finished'));
        })
      // 横向留白加在区块级（列表自身不带 margin），避免列表内的 width('100%') 顶出屏幕右缘
      Column() {
        List() {
          LazyForEach(this.recentSource, (job: JobView) => {
            ListItem() {
              this.FinishedRow(job)
            }
            // 左滑：被忽略的失败可撤销忽略，用户取消的可重新执行（对应 iOS finishedRow swipeActions）
            .swipeAction({ end: this.FinishedSwipe(job) })
          }, (job: JobView) => job.id)
        }
        .width('100%')
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
        .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 16, endMargin: 16 })
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 最近完成一行：结果图标 + 标题/摘要 + 相对时间（对应 iOS ActivityFinishedJobRow） */
  @Builder
  FinishedRow(job: JobView) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
        .fontSize(20)
        .fontColor([this.finishedIconColor(job)])
        .width(26)
      Column({ space: 3 }) {
        Text(this.jobTitle(job))
          .fontSize(15)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.jobSubtitle(job))
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

  private finishedIconColor(job: JobView): string {
    if (job.status === 'succeeded') {
      return Theme.ok;
    }
    return Theme.textFaint;
  }

  /** 最近完成的左滑动作（对应 iOS：失败且被忽略→撤销忽略；用户取消→重新执行） */
  @Builder
  FinishedSwipe(job: JobView) {
    Row() {
      if (job.status === 'failed' && (job.dismissed_at ?? '') !== '') {
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
      if (job.status === 'cancelled') {
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
    Text('取消')
      .fontSize(15)
      .fontColor('#ffffff')
      .textAlign(TextAlign.Center)
      .width(76)
      .height('100%')
      .backgroundColor(Theme.danger)
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
