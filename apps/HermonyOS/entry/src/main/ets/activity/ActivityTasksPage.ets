import { Theme } from '../theme/AppTheme';
import { Formatters } from '../common/Formatters';
import { AppModel } from '../common/AppModel';
import { AppFooter } from '../common/AppFooter';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { JobProgressView, JobView } from '../api/Models';

/**
 * 任务二级页（对齐 iOS `ActivityPages.ActivityTasksPage`）：
 * 「进行中」（active，`GET /jobs?active_only=true&limit=200` 的排队/运行任务，
 * 带进度与取消）或「已结束」（finished，全部终态任务按本地日期分组，
 * 失败被忽略的可撤销忽略、用户取消的可重新执行）。
 */
export class ActivityTasksParams {
  readonly mode: string;

  constructor(mode: string) {
    this.mode = mode;
  }

  static of(param: Object | undefined | null): ActivityTasksParams {
    const fallback: ActivityTasksParams = new ActivityTasksParams('active');
    if (param === undefined || param === null) {
      return fallback;
    }
    const raw: ActivityTasksParams = param as ActivityTasksParams;
    if (raw.mode === 'finished') {
      return new ActivityTasksParams('finished');
    }
    return new ActivityTasksParams('active');
  }
}

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function ActivityTasksBuilder() {
  ActivityTasksPage()
}

/** 已结束分组：一个本地日期 + 该日的任务 */
class JobDayGroup {
  readonly label: string;
  readonly jobs: JobView[];

  constructor(label: string, jobs: JobView[]) {
    this.label = label;
    this.jobs = jobs;
  }
}

@ComponentV2
export struct ActivityTasksPage {
  private navStack: NavPathStack = new NavPathStack();
  /** active = 进行中；finished = 已结束 */
  @Local private mode: string = 'active';
  @Local private jobs: JobView[] = [];
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private refreshing: boolean = false;
  @Local private acting: string = '';
  private started: boolean = false;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 取数

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    if (this.jobs.length > 0) {
      // 已有数据时静默刷新，不闪骨架屏
    } else {
      this.loading = true;
    }
    this.errorMessage = '';
    try {
      if (this.mode === 'active') {
        const list = await api.jobsList(undefined, undefined, undefined, undefined, true, 200);
        this.jobs = this.activeOf(list.items);
      } else {
        const list = await api.jobsList(undefined, undefined, undefined, undefined, false, 100);
        this.jobs = this.finishedOf(list.items);
      }
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
      this.activeData.setJobs(this.jobs);
    }
  }

  /** 进行中：排队 + 运行（与总览「进行中」同口径） */
  private activeOf(items: JobView[]): JobView[] {
    const out: JobView[] = [];
    for (const job of items) {
      if (job.status === 'running' || job.status === 'queued') {
        out.push(job);
      }
    }
    out.sort((a: JobView, b: JobView): number => (a.created_at < b.created_at ? -1 : 1));
    return out;
  }

  /** 已结束：全部终态，按完成时间倒序 */
  private finishedOf(items: JobView[]): JobView[] {
    const out: JobView[] = [];
    for (const job of items) {
      if (job.status === 'succeeded' || job.status === 'cancelled' || job.status === 'failed') {
        out.push(job);
      }
    }
    out.sort((a: JobView, b: JobView): number => (this.endedAt(a) < this.endedAt(b) ? 1 : -1));
    return out;
  }

  private endedAt(job: JobView): string {
    return job.finished_at ?? job.created_at;
  }

  /** 已结束分组：今天早些时候 / 昨天 / N月N日（对应 iOS `ActivityFormat.dayLabel`） */
  private dayGroups(): JobDayGroup[] {
    const groups: JobDayGroup[] = [];
    const labels: string[] = [];
    const buckets: JobView[][] = [];
    const now: Date = new Date();
    const today: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const yesterday: Date = new Date(today.getTime() - 86400000);
    for (const job of this.jobs) {
      const date: Date = new Date(this.endedAt(job));
      if (Number.isNaN(date.getTime())) {
        continue;
      }
      const local: Date = new Date(date.getFullYear(), date.getMonth(), date.getDate());
      let label: string = '';
      if (local.getTime() === today.getTime()) {
        label = '今天早些时候';
      } else if (local.getTime() === yesterday.getTime()) {
        label = '昨天';
      } else {
        label = `${local.getMonth() + 1}月${local.getDate()}日`;
      }
      const at: number = labels.indexOf(label);
      if (at < 0) {
        labels.push(label);
        buckets.push([job]);
      } else {
        buckets[at].push(job);
      }
    }
    for (let i: number = 0; i < labels.length; i++) {
      groups.push(new JobDayGroup(labels[i], buckets[i]));
    }
    return groups;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 动作

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

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // MARK: 文案（与总览页同一套对照表）

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
    const label: string | undefined = ActivityTasksPage.JOB_TYPE_LABELS[jobType];
    return label !== undefined ? label : jobType;
  }

  private jobTitle(job: JobView): string {
    const subject: string | null = job.subject ?? null;
    if (subject !== null && subject.length > 0) {
      return subject;
    }
    return ActivityTasksPage.typeLabel(job.job_type);
  }

  private jobSubtitle(job: JobView): string {
    const parts: string[] = [ActivityTasksPage.typeLabel(job.job_type)];
    if (job.attempt > 1) {
      parts.push(`第 ${job.attempt}/${job.max_attempts} 次`);
    }
    if ((job.dismissed_at ?? '') !== '') {
      parts.push('已忽略');
    }
    return parts.join('  ·  ');
  }

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
    NavDestination() {
      Column() {
        this.TopBar()
        this.Body()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: ActivityTasksParams = ActivityTasksParams.of(ctx.pathInfo.param as Object | undefined);
      if (!this.started) {
        this.started = true;
        this.mode = params.mode;
        this.load();
      }
    })
    .onShown(() => {
      // 从总览进来后，别的页面改了任务状态（取消/重试），回来要能看到
      if (this.started) {
        this.load();
      }
    })
  }

  @Builder
  TopBar() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([Theme.text])
        .width(38)
        .height(38)
        .onClick(() => {
          this.navStack.pop();
        })
      Text(this.mode === 'active' ? '进行中' : '已结束')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
      Blank()
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: Theme.statusBarInset + 6, bottom: 6 })
  }

  @Builder
  Body() {
    if (this.loading && this.jobs.length === 0) {
      Column() {
        LoadingProgress()
          .width(26)
          .height(26)
          .color(Theme.textMuted)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.errorMessage.length > 0 && this.jobs.length === 0) {
      Column({ space: 10 }) {
        Text('任务列表加载失败')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text(this.errorMessage)
          .fontSize(13)
          .fontColor(Theme.textMuted)
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
      .justifyContent(FlexAlign.Center)
    } else if (this.jobs.length === 0) {
      Column({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.checkmark_circle'))
          .fontSize(34)
          .fontColor([Theme.ok])
        Text(this.mode === 'active' ? '当前没有进行中的任务' : '还没有已结束的任务')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text(this.mode === 'active' ? '刮削、识别、转移这些后台活儿都干完了。'
          : '跑过的任务完成后会在这里留档。')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 24, right: 24 })
    } else if (this.mode === 'active') {
      this.ActiveList()
    } else {
      this.HistoryList()
    }
  }

  /** 进行中：进度行 + 左滑取消（对应 iOS activeTimeline 的作业行） */
  @Builder
  ActiveList() {
    Refresh({ refreshing: $$this.refreshing }) {
      List() {
        LazyForEach(this.activeData, (job: JobView) => {
          ListItem() {
            this.ActiveRow(job)
          }
          .swipeAction({ end: this.CancelSwipe(job) })
        }, (job: JobView) => job.id)
        ListItem() {
          AppFooter({ topSpace: 24 })
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 16, endMargin: 16 })
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
    .onRefreshing(() => {
      this.load().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .layoutWeight(1)
  }

  /** 惰加载数据源（load() 里更新内容） */
  private activeData: JobListDataSource = new JobListDataSource();

  @Builder
  ActiveRow(job: JobView) {
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
          Text(this.progressText(job).length > 0 ? this.progressText(job) : this.statusLabel(job.status))
            .fontSize(13)
            .fontColor(this.statusColor(job.status))
        }
        .width('100%')
        Text(this.jobSubtitle(job))
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.progressText(job).length > 0) {
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

  @Builder
  CancelSwipe(job: JobView) {
    Text('取消')
      .fontSize(15)
      .fontColor('#ffffff')
      .textAlign(TextAlign.Center)
      .width(76)
      .height('100%')
      .backgroundColor(Theme.danger)
      .onClick(() => {
        this.confirmCancel(job);
      })
  }

  /** 已结束：按本地日期分组（对应 iOS TaskHistorySection，全部默认展开） */
  @Builder
  HistoryList() {
    Refresh({ refreshing: $$this.refreshing }) {
      List() {
        ForEach(this.dayGroups(), (group: JobDayGroup) => {
          ListItemGroup({ header: this.GroupHeader(group.label, group.jobs.length) }) {
            ForEach(group.jobs, (job: JobView) => {
              this.HistoryRow(job)
            }, (job: JobView) => job.id)
          }
        }, (group: JobDayGroup) => group.label)
        ListItem() {
          AppFooter({ topSpace: 24 })
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
    .onRefreshing(() => {
      this.load().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  GroupHeader(label: string, count: number) {
    Row({ space: 6 }) {
      Text(label)
        .fontSize(13)
        .fontWeight(600)
        .fontColor(Theme.textMuted)
      Text(`${count} 个`)
        .fontSize(12)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .padding({ top: 14, bottom: 6, left: 4 })
  }

  /** 已结束一行：结果图标 + 标题/摘要 + 状态 + 相对时间 */
  @Builder
  HistoryRow(job: JobView) {
    ListItem() {
      Row({ space: 12 }) {
        SymbolGlyph(job.status === 'failed' ? $r('sys.symbol.xmark_circle_fill') : $r('sys.symbol.checkmark_circle_fill'))
          .fontSize(20)
          .fontColor([job.status === 'failed' ? Theme.danger : Theme.ok])
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
        Column({ space: 2 }) {
          Text(this.statusLabel(job.status))
            .fontSize(12)
            .fontColor(this.statusColor(job.status))
          Text(Formatters.relative(this.endedAt(job)))
            .fontSize(11)
            .fontColor(Theme.textFaint)
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .margin({ bottom: 8 })
    }
    .swipeAction({ end: this.HistorySwipe(job) })
  }

  /** 左滑：被忽略的失败→撤销忽略；用户取消（非系统收口）→重新执行 */
  @Builder
  HistorySwipe(job: JobView) {
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
      if (job.status === 'cancelled' && !(job.cancel_requested_by ?? '').startsWith('system')) {
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
}

/** 任务列表的 LazyForEach 数据源 */
class JobListDataSource implements IDataSource {
  private items: JobView[] = [];
  private listeners: DataChangeListener[] = [];
  private dirty: boolean = false;

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
    // 内容没变不通知，避免 build 里每次调用都触发 onDataReloaded
    if (this.sameAs(items)) {
      return;
    }
    this.items = items;
    this.dirty = false;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  private sameAs(items: JobView[]): boolean {
    if (this.items.length !== items.length) {
      return false;
    }
    for (let i: number = 0; i < items.length; i++) {
      if (this.items[i].id !== items[i].id || this.items[i].revision !== items[i].revision) {
        return false;
      }
    }
    return true;
  }
}
