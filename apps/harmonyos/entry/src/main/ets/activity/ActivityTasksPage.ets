import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { Formatters } from '../common/Formatters';
import { AppModel } from '../common/AppModel';
import { AppFooter } from '../common/AppFooter';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { DownloadTaskView, JobProgressView, JobView } from '../api/Models';
import { DownloadGroup, DownloadTasks, LifecycleStep } from './ActivityFormat';

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
  /** 进行中的下载组（活动总览「进行中」段里的下载那部分；iOS 同一页时间线含这两类） */
  @Local private downloadGroups: DownloadGroup[] = [];
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private refreshing: boolean = false;
  /** 正在执行的下载动作（换种 / 删除）：按 infohash 标记，按钮跟着置灰 */
  @Local private acting: string = '';
  private started: boolean = false;
  /** 作业列表的惰加载数据源（load() 里更新内容） */
  private activeData: JobListDataSource = new JobListDataSource();

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
        // 下载任务也要取：总览的「进行中」= 下载组 + 后台作业，二级页是同一份时间线。
        // 下载器读失败不拖累作业列表：这一段空了就只显示作业
        try {
          const downloads = await api.dlTasks();
          this.downloadGroups = DownloadTasks.activeGroups(downloads.items);
        } catch (error) {
          this.downloadGroups = [];
        }
      } else {
        this.downloadGroups = [];
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

  /** 资源的操作菜单（同 iOS `DownloadTaskActionsMenu`）：换种 / 删除（可连文件一起删） */
  @Builder
  TaskActionsMenu(task: DownloadTaskView) {
    Menu() {
      if (task.can_replace && (task.downloader_id ?? null) !== null) {
        MenuItem({ content: this.acting === task.info_hash ? '正在换种…' : '立即换种', startIcon: $r('sys.symbol.arrow_2_circlepath') })
          .onClick((): void => {
            this.replaceTask(task);
          })
      }
      MenuItem({ content: '删除任务', startIcon: $r('sys.symbol.trash') })
        .contentFontColor(Theme.danger)
        .onClick((): void => {
          this.confirmDeleteTask(task, false);
        })
      MenuItem({ content: '连文件一起删除', startIcon: $r('sys.symbol.trash_fill') })
        .contentFontColor(Theme.danger)
        .onClick((): void => {
          this.confirmDeleteTask(task, true);
        })
    }
  }

  /** 换种（同 iOS `replace`）：只对能做换种、且知道下载器的任务给入口 */
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
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.acting = '';
    }
  }

  /** 删任务前问一句；「连文件一起删」不可恢复 */
  private confirmDeleteTask(task: DownloadTaskView, deleteFiles: boolean): void {
    if (this.acting.length > 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: deleteFiles ? '删除任务并删除文件？' : '删除这个下载任务？',
      message: deleteFiles ? '下载器里的任务和已经下好的文件都会被删除，无法恢复。' : '只从下载器移除任务，已经下好的文件保留。',
      primaryButton: {
        value: '不删',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: deleteFiles ? '全部删除' : '删除任务',
        fontColor: Theme.danger,
        action: (): void => {
          this.deleteTask(task, deleteFiles);
        }
      }
    });
  }

  private async deleteTask(task: DownloadTaskView, deleteFiles: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const downloaderId: number | null = task.downloader_id ?? null;
    if (api === null || downloaderId === null || this.acting.length > 0) {
      return;
    }
    this.acting = task.info_hash;
    try {
      await api.dlTorrentDelete(downloaderId, task.info_hash, deleteFiles);
      this.toast('已删除');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.acting = '';
    }
  }

  /** 「现在」时间线的处理量（同 iOS `feedProgressAmount`） */
  private jobAmount(job: JobView): string {
    const current: number | null = job.progress.current ?? null;
    const total: number | null = job.progress.total ?? null;
    if (current === null || total === null) {
      return '';
    }
    if (job.job_type === 'library.ingest') {
      return `已处理 ${Formatters.bytes(current)} / ${Formatters.bytes(total)}`;
    }
    let unit: string = '项';
    if (job.job_type === 'subtitle.generate') {
      unit = '个分块';
    } else if (job.job_type === 'library.scan') {
      unit = '个文件';
    } else if (job.job_type === 'media.metadata.refresh') {
      unit = '张图片';
    } else if (job.job_type === 'library.metadata.refresh') {
      unit = '个条目';
    }
    return `已处理 ${current} / ${total} ${unit}`;
  }

  /** 发起方与时刻（同 iOS `feedOriginLabel`）：「网页发起 · user · 9月29日 14:00 开始」 */
  private jobOriginLine(job: JobView): string {
    let origin: string = '网页发起';
    if (job.origin === 'cli') {
      origin = 'CLI 发起';
    } else if (job.origin === 'agent') {
      origin = 'Agent 发起';
    } else if (job.origin === 'scheduler' || job.origin === 'system') {
      origin = '系统自动';
    }
    const actor: string = job.actor_name ?? '';
    if (actor.length > 0) {
      origin = `${origin} · ${actor}`;
    }
    const started: string = job.started_at ?? '';
    if (started.length > 0) {
      return `${origin} · ${Formatters.dateTime(started)} 开始`;
    }
    return `${origin} · ${Formatters.dateTime(job.created_at)} 发起`;
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
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
    }
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
    'reels.clips': '片段预切',
    'library.organize': '整理媒体库文件',
    'library.transfer': '转移媒体库条目',
    'library.ingest': '自动整理入库'
  };

  /** 任务类型的显示名：内置类型用本地文案，插件任务用服务端给的名字（`job_type_label`），都没有显示原始类型（与 Web、iOS 同序） */
  private static typeLabel(job: JobView): string {
    const label: string | undefined = ActivityTasksPage.JOB_TYPE_LABELS[job.job_type];
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
    return ActivityTasksPage.typeLabel(job);
  }

  private jobSubtitle(job: JobView): string {
    const parts: string[] = [ActivityTasksPage.typeLabel(job)];
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
    .padding({ left: 12, right: 12, top: Theme.shellTopInset + 6, bottom: 6 })
  }

  @Builder
  Body() {
    if (this.loading && this.jobs.length === 0 && this.downloadGroups.length === 0) {
      Column() {
        LoadingProgress()
          .width(26)
          .height(26)
          .color(Theme.textMuted)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.errorMessage.length > 0 && this.jobs.length === 0 && this.downloadGroups.length === 0) {
      Column({ space: 10 }) {
        Text('任务列表加载失败')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text(this.errorMessage)
          .fontSize(13)
          .fontColor(Theme.textMuted)
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
      .justifyContent(FlexAlign.Center)
    } else if (this.jobs.length === 0 && this.downloadGroups.length === 0) {
      Column({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.checkmark_circle'))
          .fontSize(34)
          .fontColor([Theme.ok])
        Text(this.mode === 'active' ? '当前没有进行中的任务' : '还没有已结束的任务')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text(this.mode === 'active' ? '新任务启动后会自动出现在这里。'
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
        /*
         * 时间线（照 iOS `TaskCenterPanel.activeTimeline`）：下载组在前、独立后台作业在后，
         * 每条左侧一条时间轴（圆点 + 竖线），最后一条不再画竖线。控件全部是官方
         * List / ListItem / Progress / Circle / Text。
         */
        ForEach(this.downloadGroups, (group: DownloadGroup, index: number) => {
          ListItem() {
            this.DownloadTimelineRow(group, index === this.downloadGroups.length - 1 && this.jobs.length === 0)
          }
        }, (group: DownloadGroup) => `dl-${group.id}`)
        LazyForEach(this.activeData, (job: JobView, index: number) => {
          ListItem() {
            this.JobTimelineRow(job, index === this.activeData.totalCount() - 1)
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

  /** 小标签（「实时」/ 站点名），同 iOS `TaskTag` */
  @Builder
  TaskTag(text: string, tint: string, fill: string) {
    Text(text)
      .fontSize(10)
      .fontColor(tint)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .backgroundColor(fill)
      .borderRadius(5)
  }

  /** 下载组（按作品合并）：组头 + 每个下载资源一行过程 */
  @Builder
  DownloadTimelineRow(group: DownloadGroup, isLast: boolean) {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        Column({ space: 2 }) {
        // 认得出作品的（grouped）才画组头；未识别的资源只有一条资源行，不再重复标题
        if (group.mediaItemId !== null) {
          Row({ space: 6 }) {
            this.TaskTag('实时', Theme.info, 'rgba(127, 176, 255, 0.14)')
            Text(group.title)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          Text(`${group.kind === 'tv' ? '剧集' : '电影'} · ${group.tasks.length} 个下载资源`)
            .fontSize(11)
            .fontColor(Theme.textFaint)
        }
        ForEach(group.tasks, (task: DownloadTaskView, index: number) => {
          if (index > 0) {
            Divider().color('rgba(255, 255, 255, 0.06)').margin({ top: 1, bottom: 1 })
          }
          this.DownloadTaskLine(task)
        }, (task: DownloadTaskView) => task.id)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      // 左边框就是时间轴的竖线（随行高自动延伸）；最后一条不画
      .padding({ left: 14, bottom: 4 })
      .border({ width: { left: isLast ? 0 : 1 }, color: 'rgba(255, 255, 255, 0.12)' })
      }
      .width('100%')
      .padding({ left: 7 })
      // 圆点压在竖线正中：竖线在 x=7 处，圆点宽 14、从 0 开始，圆心正好落在线上
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(14)
          .height(14)
          .fill(group.tasks[0].state === 'downloading'
            ? 'rgba(127, 176, 255, 0.30)' : 'rgba(245, 196, 81, 0.25)')
        Circle()
          .width(8)
          .height(8)
          .fill(group.tasks[0].state === 'downloading' ? Theme.info : Theme.warn)
      }
      .width(14)
      .height(14)
      .margin({ top: 4 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
  }

  /** 一个下载资源：站点徽标 + 种子名、规格、说明、进度、速度与剩余时间（同 iOS `DownloadTaskFeedItem`） */
  @Builder
  DownloadTaskLine(task: DownloadTaskView) {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        if ((task.site_name ?? '').length > 0) {
          this.TaskTag(task.site_name ?? '', Theme.textMuted, 'rgba(255, 255, 255, 0.06)')
        }
        Text(this.downloadTaskName(task))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(16)
          .fontColor([Theme.textFaint])
          .width(22)
          .height(22)
          .bindMenu(this.TaskActionsMenu(task))
      }
      .width('100%')
      Text(DownloadTasks.taskSpecLine(task))
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .visibility(DownloadTasks.taskSpecLine(task).length > 0 ? Visibility.Visible : Visibility.None)
      if (task.state !== 'missing') {
        // 状态 + 百分比（同 iOS 进度条上方的 meta 行）
        Text(`${DownloadTasks.stateLabel(task)} · ${DownloadTasks.percentOf(task)}%`)
          .fontSize(11)
          .fontColor(DownloadTasks.taskColor(task))
        Progress({ value: DownloadTasks.percentOf(task), total: 100 })
          .color(DownloadTasks.taskColor(task))
          .width('100%')
          .height(3)
          .backgroundColor(Theme.line)
      }
      Text(DownloadTasks.taskNote(task))
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .visibility(DownloadTasks.taskNote(task).length > 0 ? Visibility.Visible : Visibility.None)
      this.LifecycleView(task)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 资源名：种子名 → 作品名 → infohash（同 iOS `DownloadTaskFeedItem` 的 title） */
  private downloadTaskName(task: DownloadTaskView): string {
    const name: string = task.name ?? '';
    if (name.length > 0) {
      return name;
    }
    const media: string = task.media_title ?? '';
    if (media.length > 0) {
      return media;
    }
    return task.info_hash;
  }

  /** 完整过程：已投递 → 下载状态 → 等待下载完成 / 等待入库 → 入库（每步一个小圆点 + 连线和两行文字） */
  @Builder
  LifecycleView(task: DownloadTaskView) {
    Column() {
      ForEach(DownloadTasks.lifecycleSteps(task), (step: LifecycleStep, index: number) => {
        Stack({ alignContent: Alignment.TopStart }) {
          Row() {
            Row({ space: 6 }) {
              Text(step.label)
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.stepLabelColor(step.tone))
              Text(step.detail)
                .fontSize(11)
                .fontColor(this.stepDetailColor(step.tone))
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: 10, bottom: 5 })
            .border({
              width: { left: DownloadTasks.lifecycleSteps(task).length - 1 === index ? 0 : 1 },
              color: 'rgba(255, 255, 255, 0.10)'
            })
          }
          .width('100%')
          .padding({ left: 4 })
          Circle()
            .width(8)
            .height(8)
            .fill(this.stepDotColor(step.tone))
            .margin({ top: 4 })
        }
        .width('100%')
      }, (step: LifecycleStep, index: number) => `${step.label}-${index}`)
    }
    .width('100%')
    .padding({ top: 3 })
  }

  private stepDotColor(tone: string): string {
    if (tone === 'done') {
      return Theme.ok;
    }
    if (tone === 'current') {
      return Theme.info;
    }
    if (tone === 'waiting') {
      return Theme.warn;
    }
    if (tone === 'attention') {
      return Theme.danger;
    }
    return 'rgba(255, 255, 255, 0.25)';
  }

  private stepLabelColor(tone: string): string {
    if (tone === 'done') {
      return Theme.textMuted;
    }
    if (tone === 'current') {
      return Theme.info;
    }
    if (tone === 'waiting') {
      return Theme.warn;
    }
    if (tone === 'attention') {
      return Theme.danger;
    }
    return Theme.textFaint;
  }

  private stepDetailColor(tone: string): string {
    if (tone === 'attention') {
      return 'rgba(255, 107, 107, 0.75)';
    }
    if (tone === 'waiting') {
      return 'rgba(245, 196, 81, 0.55)';
    }
    return Theme.textFaint;
  }

  /** 后台作业一条（同 iOS `ActiveJobFeedItem`）：标题、状态 · 百分比、说明、进度条 */
  @Builder
  JobTimelineRow(job: JobView, isLast: boolean) {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        Column({ space: 2 }) {
        Row({ space: 8 }) {
          Text(this.jobTitle(job))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (job.status !== 'cancelling') {
            Button() {
              Text('取消任务')
                .fontSize(11)
                .fontColor(Theme.textMuted)
            }
            .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(13)
            .onClick((): void => {
              this.confirmCancel(job);
            })
          }
        }
        .width('100%')
        Text(`${this.statusLabel(job.status)}${this.progressText(job).length > 0 ? ` · ${this.progressText(job)}` : ''}`)
          .fontSize(11)
          .fontColor(this.statusColor(job.status))
        Text(job.progress.message ?? '')
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .visibility((job.progress.message ?? '').length > 0 ? Visibility.Visible : Visibility.None)
        if (this.progressText(job).length > 0) {
          Progress({ value: this.progressValue(job), total: 100 })
            .width('100%')
            .height(3)
            .color(Theme.info)
            .backgroundColor(Theme.line)
        }
        Text(this.jobAmount(job))
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .visibility(this.jobAmount(job).length > 0 ? Visibility.Visible : Visibility.None)
        Text(this.jobOriginLine(job))
          .fontSize(11)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, bottom: 4 })
      .border({ width: { left: isLast ? 0 : 1 }, color: 'rgba(255, 255, 255, 0.12)' })
      }
      .width('100%')
      .padding({ left: 7 })
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(14)
          .height(14)
          .fill(job.status === 'running' ? 'rgba(127, 176, 255, 0.30)' : 'rgba(245, 196, 81, 0.25)')
        Circle()
          .width(8)
          .height(8)
          .fill(job.status === 'running' ? Theme.info : Theme.warn)
      }
      .width(14)
      .height(14)
      .margin({ top: 4 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
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
