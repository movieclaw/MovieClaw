import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { AppFooter } from '../common/AppFooter';
import {
  AppConfigView,
  CleanPayload,
  CleanResultView,
  DirUsageView,
  GithubTokenPayload,
  GithubTokenView,
  LibraryView,
  ScheduledTaskUpdate,
  ScheduledTaskView,
  StorageStateView,
  StorageUsageView,
  UpdateCheckView,
  UpdateProgressView
} from '../api/Models';

/** 三个页签（对应 iOS `AppMaintenanceSettingsView.Tab`） */
class AppTab {
  static readonly update: string = 'update';
  static readonly storage: string = 'storage';
  static readonly tasks: string = 'tasks';
}

/** `CleanPayload` 有必填字段，但为了可读性仍用类构造 */
class CleanBody implements CleanPayload {
  key: string = '';
  mode: string = '';
}

/** `GithubTokenPayload` 的字段可能全可选，用类绕开 */
class TokenBody implements GithubTokenPayload {
  token?: string | null;
}

/** `ScheduledTaskUpdate` 的载体（启用/周期形状，保存才落库） */
class TaskBody implements ScheduledTaskUpdate {
  enabled: boolean = true;
  trigger_type: string = 'interval';
  interval_seconds?: number | null;
  cron_expr?: string | null;
}

/**
 * 设置 → 更新与维护（对应 iOS `AppMaintenanceSettingsView` / Web `settings-view` 的 `AppSection`）。
 *
 * iOS 是三个胶囊页签，**默认停在「版本与更新」**——因为这一页的高频入口就是「有可用更新」，
 * 用户带着「来更新」的意图落地。
 *
 * 三个页签：
 * - **版本与更新**：当前版本 / 检查更新 / 更新日志 / 一键更新 / 更新进度 / GitHub Token（私有仓库要它）；
 * - **缓存管理**：磁盘与缓存占用、逐目录明细、按目录清理；
 * - **定时任务**（对应 iOS `ScheduledTasksPanel`）：每个后台任务的周期与启停——「每隔一段时间」「每天
 *   固定时刻」两种人能说清的形状，其它 cron 照样能显示与保存；「媒体库对账」在有库挂在网上时建议调到
 *   每 1 小时（只建议，一键采纳，不替用户改）。
 *
 * **没做**：回滚到历史版本、页签上的更新蓝点（要外壳常驻轮询，见 iOS 的 `ShellBadges`）。
 */
@ComponentV2
export struct AppMaintenanceSection {
  @Local private tab: string = AppTab.update;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private config: AppConfigView | null = null;

  // 版本与更新
  @Local private check: UpdateCheckView | null = null;
  @Local private checking: boolean = false;
  @Local private progress: UpdateProgressView | null = null;
  @Local private updating: boolean = false;
  @Local private showChangelog: boolean = false;
  @Local private tokenValue: string = '';
  @Local private tokenMasked: string = '';
  @Local private tokenConfigured: boolean = false;
  @Local private showToken: boolean = false;

  // 缓存管理
  @Local private storage: StorageStateView | null = null;
  @Local private cleaningKey: string = '';
  @Local private cleanMessage: string = '';

  // 定时任务
  @Local private tasks: ScheduledTaskView[] = [];
  @Local private tasksLoading: boolean = false;
  @Local private tasksError: string = '';
  @Local private anyNetwork: boolean = false;
  @Local private busyKey: string = '';
  @Local private showTaskSheet: boolean = false;
  // 编辑中的草稿（打开 sheet 时从任务拷贝）
  @Local private draftKey: string = '';
  @Local private draftEnabled: boolean = true;
  @Local private draftMode: string = 'interval';
  @Local private draftHours: number = 1;
  @Local private draftHour: number = 3;
  @Local private draftMinute: number = 0;
  @Local private draftCron: string = '';
  @Local private savingTask: boolean = false;
  @Local private draftError: string = '';

  private progressTimer: number = -1;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.stopProgressPoll();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = true;
    try {
      this.config = await api.appShow();
      await this.loadCheck();
      if (this.tab === AppTab.storage) {
        await this.loadStorage();
      }
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  private async loadCheck(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.check = await api.appUpdateCheck();
      const token: GithubTokenView = await api.appUpdateGithubTokenGet();
      this.tokenConfigured = token.configured;
      this.tokenMasked = token.masked;
    } catch (error) {
      // 检查更新失败不该让整页报错（可能就是网络不通），静默
    }
  }

  private async loadStorage(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.storage = await api.appStorageUsage();
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private switchTab(tab: string): void {
    if (tab === this.tab) {
      return;
    }
    this.tab = tab;
    if (tab === AppTab.storage && this.storage === null) {
      this.loadStorage();
    }
    if (tab === AppTab.tasks && this.tasks.length === 0 && !this.tasksLoading) {
      this.loadTasks();
    }
  }

  // MARK: 更新

  private async recheck(): Promise<void> {
    if (this.checking) {
      return;
    }
    this.checking = true;
    try {
      await this.loadCheck();
      this.toast('已是最新检查结果');
    } finally {
      this.checking = false;
    }
  }

  private confirmApply(): void {
    const view: UpdateCheckView | null = this.check;
    if (view === null) {
      return;
    }
    if (!view.compatible) {
      this.toast('这个版本与当前运行时要求不匹配，先升级运行时');
      return;
    }
    if (view.latest_known_bad) {
      this.getUIContext().showAlertDialog({
        title: '这个版本被标记为有问题',
        message: '服务端把它记成了「已知有问题」的版本，更新过去可能出故障。确定要继续吗？',
        primaryButton: {
          value: '先不更新',
          action: (): void => {
          }
        },
        secondaryButton: {
          value: '仍要更新',
          fontColor: Theme.danger,
          action: (): void => {
            this.applyUpdate();
          }
        }
      });
      return;
    }
    this.getUIContext().showAlertDialog({
      title: `更新到 ${view.latest_version}`,
      message: '更新会重启后端服务，正在跑的下载与扫描会中断（重新开始后会接着做）。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '开始更新',
        action: (): void => {
          this.applyUpdate();
        }
      }
    });
  }

  private async applyUpdate(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.updating) {
      return;
    }
    this.updating = true;
    this.progress = null;
    try {
      this.progress = await api.appUpdateApply();
      this.startProgressPoll();
    } catch (error) {
      this.updating = false;
      this.toast(this.messageOf(error));
    }
  }

  /** 更新是后端跑的长任务，轮询进度直到落定 */
  private startProgressPoll(): void {
    this.stopProgressPoll();
    this.progressTimer = setInterval((): void => {
      this.pollProgress();
    }, 2000);
  }

  private stopProgressPoll(): void {
    if (this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  private async pollProgress(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const view: UpdateProgressView = await api.appUpdateApply();
      this.progress = view;
      const phase: string = view.phase;
      if (phase === 'done' || phase === 'failed' || phase === 'idle') {
        this.stopProgressPoll();
        this.updating = false;
        this.toast(phase === 'done' ? '更新完成' : `更新结束：${view.detail}`);
        await this.load();
      }
    } catch (error) {
      // 更新过程中后端会重启，请求失败是正常的；继续轮询
    }
  }

  private async saveToken(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const body: TokenBody = new TokenBody();
    body.token = this.tokenValue.trim();
    try {
      const view: GithubTokenView = await api.appUpdateGithubTokenPut(body);
      this.tokenConfigured = view.configured;
      this.tokenMasked = view.masked;
      this.tokenValue = '';
      this.showToken = false;
      this.toast('已保存');
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  // MARK: 缓存

  private confirmClean(dir: DirUsageView): void {
    this.getUIContext().showAlertDialog({
      title: `清理「${dir.title}」`,
      message: `会删掉这一项占用的缓存（${Formatters.bytes(dir.bytes)}）。`
        + '正在用的东西会被跳过，不影响正在进行的任务。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '清理',
        action: (): void => {
          this.clean(dir);
        }
      }
    });
  }

  private async clean(dir: DirUsageView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.cleaningKey = dir.key;
    this.cleanMessage = '';
    try {
      const body: CleanBody = new CleanBody();
      body.key = dir.key;
      body.mode = 'all';
      const result: CleanResultView = await api.appStorageClean(dir.key, body);
      this.cleanMessage = `已清理「${dir.title}」：删掉 ${result.removed} 项，`
        + `释放 ${Formatters.bytes(result.freed_bytes)}`
        + (result.skipped_busy > 0 ? `，跳过 ${result.skipped_busy} 项正在用的` : '');
      await this.loadStorage();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.cleaningKey = '';
    }
  }

  // MARK: 定时任务

  private async loadTasks(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.tasksLoading = true;
    try {
      this.tasks = await api.appTasksList();
      this.tasksError = '';
      // 库列表拿不到不影响任务列表（可能只是没权限），只当没有网络挂载
      try {
        const libs: LibraryView[] = await api.libraryList(undefined, 'all');
        let any: boolean = false;
        for (const lib of libs) {
          if (lib.network_mount) {
            any = true;
            break;
          }
        }
        this.anyNetwork = any;
      } catch (libError) {
        this.anyNetwork = false;
      }
    } catch (error) {
      this.tasksError = this.messageOf(error);
    } finally {
      this.tasksLoading = false;
    }
  }

  /** 保存单个任务；返回错误文案，空串 = 成功 */
  private async saveTask(taskKey: string, body: ScheduledTaskUpdate): Promise<string> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return '未连接服务器';
    }
    this.busyKey = taskKey;
    try {
      const updated: ScheduledTaskView = await api.appTasksUpdate(taskKey, body);
      const next: ScheduledTaskView[] = [];
      for (const t of this.tasks) {
        next.push(t.key === taskKey ? updated : t);
      }
      this.tasks = next;
      this.tasksError = '';
      return '';
    } catch (error) {
      return this.messageOf(error);
    } finally {
      this.busyKey = '';
    }
  }

  private reconcileTask(): ScheduledTaskView | null {
    for (const t of this.tasks) {
      if (t.key === 'library_reconcile') {
        return t;
      }
    }
    return null;
  }

  /** 固定时刻 = 一天一次，比一小时长；间隔超过一小时也建议（前提：有库挂在网上） */
  private suggestReconcile(task: ScheduledTaskView): boolean {
    if (!this.anyNetwork) {
      return false;
    }
    if (task.trigger_type !== 'interval') {
      return true;
    }
    return (task.interval_seconds ?? 0) > 3600;
  }

  private async applyReconcileSuggestion(task: ScheduledTaskView): Promise<void> {
    const body: TaskBody = new TaskBody();
    body.enabled = true;
    body.trigger_type = 'interval';
    body.interval_seconds = 3600;
    body.cron_expr = null;
    const err: string = await this.saveTask(task.key, body);
    if (err.length > 0) {
      this.tasksError = err;
    }
  }

  // MARK: 任务草稿

  private draftTask(): ScheduledTaskView | null {
    for (const t of this.tasks) {
      if (t.key === this.draftKey) {
        return t;
      }
    }
    return null;
  }

  private openEditor(task: ScheduledTaskView): void {
    this.draftKey = task.key;
    this.draftEnabled = task.enabled;
    const daily: number[] | null = AppMaintenanceSection.dailyTime(task.cron_expr);
    if (task.trigger_type === 'interval') {
      this.draftMode = 'interval';
    } else if (daily !== null) {
      this.draftMode = 'daily';
    } else {
      this.draftMode = 'cron';
    }
    this.draftHour = daily !== null ? daily[0] : 3;
    this.draftMinute = daily !== null ? daily[1] : 0;
    this.draftHours = Math.max(1, Math.round((task.interval_seconds ?? 3600) / 3600));
    this.draftCron = task.cron_expr ?? '';
    this.draftError = '';
    this.showTaskSheet = true;
  }

  /** 草稿 → 提交体；cron 模式空表达式返回 null（保存键置灰） */
  private buildPayload(): TaskBody | null {
    const task: ScheduledTaskView | null = this.draftTask();
    if (task === null) {
      return null;
    }
    const body: TaskBody = new TaskBody();
    body.enabled = this.draftEnabled;
    if (this.draftMode === 'interval') {
      // 仅切换启停时保留服务器的精确间隔，不把分钟/秒级周期四舍五入成小时
      const originalHours: number = Math.max(1, Math.round((task.interval_seconds ?? 3600) / 3600));
      body.trigger_type = 'interval';
      body.interval_seconds = task.trigger_type === 'interval' && this.draftHours === originalHours
        ? task.interval_seconds : this.draftHours * 3600;
      body.cron_expr = null;
    } else if (this.draftMode === 'daily') {
      body.trigger_type = 'cron';
      body.interval_seconds = null;
      body.cron_expr = `${this.draftMinute} ${this.draftHour} * * *`;
    } else {
      const cron: string = this.draftCron.trim();
      if (cron.length === 0) {
        return null;
      }
      body.trigger_type = 'cron';
      body.interval_seconds = null;
      body.cron_expr = cron;
    }
    return body;
  }

  private draftDirty(): boolean {
    const task: ScheduledTaskView | null = this.draftTask();
    const body: TaskBody | null = this.buildPayload();
    if (task === null || body === null) {
      return false;
    }
    if (body.enabled !== task.enabled || body.trigger_type !== task.trigger_type) {
      return true;
    }
    return body.trigger_type === 'interval'
      ? body.interval_seconds !== task.interval_seconds
      : body.cron_expr !== task.cron_expr;
  }

  private saveEnabled(): boolean {
    if (this.savingTask) {
      return false;
    }
    if (this.draftMode === 'cron' && this.draftCron.trim().length === 0) {
      return false;
    }
    return this.draftDirty();
  }

  private async saveDraft(): Promise<void> {
    const task: ScheduledTaskView | null = this.draftTask();
    const body: TaskBody | null = this.buildPayload();
    if (task === null || body === null || this.savingTask) {
      return;
    }
    this.savingTask = true;
    const err: string = await this.saveTask(task.key, body);
    this.savingTask = false;
    if (err.length > 0) {
      this.draftError = err;
    } else {
      this.showTaskSheet = false;
    }
  }

  /** 间隔步进旁的文案：小时数没动时显示服务器的精确周期（可能是分钟/秒级） */
  private draftIntervalLabel(): string {
    const task: ScheduledTaskView | null = this.draftTask();
    if (task !== null && task.trigger_type === 'interval') {
      const originalHours: number = Math.max(1, Math.round((task.interval_seconds ?? 3600) / 3600));
      if (this.draftHours !== originalHours) {
        return `每 ${this.draftHours} 小时`;
      }
      return AppMaintenanceSection.describe(task);
    }
    return `每 ${this.draftHours} 小时`;
  }

  private draftDate(): Date {
    return new Date(2026, 0, 1, this.draftHour, this.draftMinute, 0);
  }

  /** 「分 时 * * *」形状的 cron → 每天固定时刻 [hour, minute]；其它形状返回 null */
  private static dailyTime(cron: string | null | undefined): number[] | null {
    if (cron === null || cron === undefined || cron.length === 0) {
      return null;
    }
    const parts: string[] = cron.trim().split(/\s+/);
    if (parts.length !== 5 || parts[2] !== '*' || parts[3] !== '*' || parts[4] !== '*') {
      return null;
    }
    if (parts[0].length > 2 || parts[1].length > 2 || !/^\d+$/.test(parts[0]) || !/^\d+$/.test(parts[1])) {
      return null;
    }
    const minute: number = parseInt(parts[0], 10);
    const hour: number = parseInt(parts[1], 10);
    if (hour > 23 || minute > 59) {
      return null;
    }
    return [hour, minute];
  }

  private static two(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** 周期的人话描述（对应 iOS `SettingsSchedule.describe`） */
  private static describe(task: ScheduledTaskView): string {
    if (task.trigger_type === 'interval') {
      const seconds: number = task.interval_seconds ?? 0;
      if (seconds <= 0) {
        return '间隔未设置';
      }
      if (seconds % 3600 === 0) {
        return `每 ${seconds / 3600} 小时`;
      }
      if (seconds % 60 === 0) {
        return `每 ${seconds / 60} 分钟`;
      }
      return `每 ${seconds} 秒`;
    }
    const daily: number[] | null = AppMaintenanceSection.dailyTime(task.cron_expr);
    if (daily !== null) {
      return `每天 ${AppMaintenanceSection.two(daily[0])}:${AppMaintenanceSection.two(daily[1])}`;
    }
    if (task.cron_expr !== null && task.cron_expr !== undefined && task.cron_expr.length > 0) {
      return `cron：${task.cron_expr}`;
    }
    return '未设置';
  }

  // MARK: 视图

  build() {
    Column() {
      this.TabBar()
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在加载…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.tab === AppTab.update) {
        this.UpdateBody()
      } else if (this.tab === AppTab.tasks) {
        this.TasksBody()
      } else {
        this.StorageBody()
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showTaskSheet, this.TaskSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  @Builder
  TabBar() {
    Row({ space: 8 }) {
      this.TabChip(AppTab.update, '版本与更新')
      this.TabChip(AppTab.storage, '缓存管理')
      this.TabChip(AppTab.tasks, '定时任务')
      Blank()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 10 })
  }

  @Builder
  TabChip(tab: string, label: string) {
    Text(label)
      .fontSize(14)
      .fontColor(this.tab === tab ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.tab === tab ? Theme.accent : Theme.glassFill)
      .borderRadius(17)
      .onClick(() => {
        this.switchTab(tab);
      })
  }

  // MARK: 版本与更新

  @Builder
  UpdateBody() {
    Scroll() {
      Column({ space: 14 }) {
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage).fontSize(13).fontColor(Theme.danger).width('100%')
        }
        this.VersionCard()
        if (this.progress !== null) {
          this.ProgressCard(this.progress as UpdateProgressView)
        }
        this.TokenCard()
        AppFooter()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: Theme.tabBarInset })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  VersionCard() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('当前版本')
            .fontSize(12)
            .fontColor(Theme.textFaint)
          Text(this.check !== null ? (this.check as UpdateCheckView).current_version : '—')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.check !== null && (this.check as UpdateCheckView).update_available) {
          Text('有可用更新')
            .fontSize(11)
            .fontColor('#0b0d12')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(Theme.accent)
            .borderRadius(9)
        } else {
          Text('已是最新')
            .fontSize(12)
            .fontColor(Theme.ok)
        }
      }
      .width('100%')

      if (this.check !== null && (this.check as UpdateCheckView).update_available) {
        Column({ space: 4 }) {
          Text(`最新版本 ${(this.check as UpdateCheckView).latest_version}`)
            .fontSize(14)
            .fontColor(Theme.text)
            .width('100%')
          if ((this.check as UpdateCheckView).published_at.length > 0) {
            Text(`发布于 ${Formatters.relative((this.check as UpdateCheckView).published_at)}`)
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
          }
          if (!(this.check as UpdateCheckView).compatible) {
            Text(`需要运行时 ${(this.check as UpdateCheckView).requires_runtime}，当前不满足`)
              .fontSize(12)
              .fontColor(Theme.danger)
              .width('100%')
          }
          if ((this.check as UpdateCheckView).latest_known_bad) {
            Text('服务端把这一版标记为「已知有问题」')
              .fontSize(12)
              .fontColor(Theme.warn)
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      if (this.check !== null && (this.check as UpdateCheckView).changelog.length > 0) {
        Column({ space: 4 }) {
          Text(this.showChangelog ? '收起更新日志' : '看更新日志')
            .fontSize(13)
            .fontColor(Theme.accentStrong)
            .onClick(() => {
              this.showChangelog = !this.showChangelog;
            })
          if (this.showChangelog) {
            Text((this.check as UpdateCheckView).changelog)
              .fontSize(12)
              .fontColor(Theme.textMuted)
              .width('100%')
              .padding(10)
              .backgroundColor(Theme.surfaceRaised)
              .borderRadius(8)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      Row({ space: 10 }) {
        Text(this.checking ? '检查中…' : '检查更新')
          .fontSize(14)
          .fontColor(Theme.text)
          .padding({ left: 14, right: 14, top: 9, bottom: 9 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(16)
          .border({ width: 1, color: Theme.line })
          .onClick(() => {
            this.recheck();
          })
        if (this.check !== null && (this.check as UpdateCheckView).update_available) {
          Text(this.updating ? '更新中…' : '立即更新')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.updating ? Theme.textFaint : '#0b0d12')
            .padding({ left: 16, right: 16, top: 9, bottom: 9 })
            .backgroundColor(this.updating ? Theme.glassFill : Theme.accent)
            .borderRadius(16)
            .onClick(() => {
              if (!this.updating) {
                this.confirmApply();
              }
            })
        }
        Blank()
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 更新进度：阶段 + 百分比 + 详情 */
  @Builder
  ProgressCard(view: UpdateProgressView) {
    Column({ space: 8 }) {
      Text(this.phaseLabel(view.phase))
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.text)
        .width('100%')
      if (view.percent !== null && view.percent !== undefined) {
        Row() {
          Row()
            .width(`${Math.max(0, Math.min(100, view.percent))}%`)
            .height(4)
            .backgroundColor(Theme.accent)
            .borderRadius(2)
        }
        .width('100%')
        .height(4)
        .backgroundColor(Theme.line)
        .borderRadius(2)
        .justifyContent(FlexAlign.Start)
      }
      Text(view.detail)
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .width('100%')
      if (view.error !== null && view.error !== undefined && view.error.length > 0) {
        Text(view.error)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }
      Text('更新期间后端会重启，请求失败是正常的，稍等它自己回来。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  private phaseLabel(phase: string): string {
    if (phase === 'downloading') {
      return '正在下载';
    }
    if (phase === 'applying') {
      return '正在应用';
    }
    if (phase === 'restarting') {
      return '正在重启';
    }
    if (phase === 'done') {
      return '更新完成';
    }
    if (phase === 'failed') {
      return '更新失败';
    }
    return '更新进度';
  }

  /** GitHub Token：私有仓库 / 触发接口限流时要它 */
  @Builder
  TokenCard() {
    Column({ space: 10 }) {
      Column({ space: 3 }) {
        Text('GitHub Token')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Text(this.tokenConfigured
          ? `已配置（${this.tokenMasked}）。仓库是私有的、或老被限流时需要它。`
          : '仓库是私有的、或老被限流时需要它；公开仓库可以不填。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.showToken) {
        TextInput({ text: this.tokenValue, placeholder: 'ghp_…' })
          .width('100%')
          .height(42)
          .fontSize(14)
          .fontColor(Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((v: string): void => {
            this.tokenValue = v;
          })
        Row({ space: 10 }) {
          Text('保存')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#0b0d12')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor(Theme.accent)
            .borderRadius(15)
            .onClick(() => {
              this.saveToken();
            })
          Text('取消')
            .fontSize(14)
            .fontColor(Theme.textMuted)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .onClick(() => {
              this.showToken = false;
              this.tokenValue = '';
            })
          Blank()
        }
        .width('100%')
      } else {
        Text(this.tokenConfigured ? '更换 Token' : '填一个 Token')
          .fontSize(14)
          .fontColor(Theme.accentStrong)
          .onClick(() => {
            this.showToken = true;
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  // MARK: 缓存管理

  @Builder
  StorageBody() {
    Scroll() {
      Column({ space: 14 }) {
        if (this.cleanMessage.length > 0) {
          Text(this.cleanMessage)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
        }
        if (this.storage === null) {
          Column({ space: 10 }) {
            LoadingProgress().width(24).height(24).color(Theme.textMuted)
            Text('正在统计占用…').fontSize(13).fontColor(Theme.textFaint)
          }
          .width('100%')
          .padding({ top: 40 })
          .justifyContent(FlexAlign.Center)
        } else {
          this.UsageCard(this.storage as StorageStateView)
        }
        AppFooter()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: Theme.tabBarInset })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  UsageCard(state: StorageStateView) {
    if (state.usage === null || state.usage === undefined) {
      Column({ space: 8 }) {
        Text(state.computing ? '正在统计占用…' : '还没有统计结果')
          .fontSize(14).fontColor(Theme.textMuted)
        if (state.error !== null && state.error !== undefined && state.error.length > 0) {
          Text(state.error).fontSize(12).fontColor(Theme.danger)
        }
      }
      .width('100%')
      .padding({ top: 40 })
      .justifyContent(FlexAlign.Center)
    } else {
      this.DiskCard(state.usage as StorageUsageView)
      this.DirsCard(state.usage as StorageUsageView)
    }
  }

  @Builder
  DiskCard(view: StorageUsageView) {
    Column({ space: 10 }) {
      Text('磁盘')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')
      Row({ space: 16 }) {
        this.StatCell('总容量', Formatters.bytes(view.disk_total))
        this.StatCell('已用', Formatters.bytes(view.disk_used))
        this.StatCell('可用', Formatters.bytes(view.disk_free))
      }
      .width('100%')
      Row() {
        Row()
          .width(`${view.disk_total > 0 ? Math.round(view.disk_used * 100 / view.disk_total) : 0}%`)
          .height(4)
          .backgroundColor(Theme.accent)
          .borderRadius(2)
      }
      .width('100%')
      .height(4)
      .backgroundColor(Theme.line)
      .borderRadius(2)
      .justifyContent(FlexAlign.Start)
      Row({ space: 16 }) {
        this.StatCell('缓存', Formatters.bytes(view.cache_bytes))
        this.StatCell('数据', Formatters.bytes(view.data_bytes))
      }
      .width('100%')
      Text(`数据目录：${view.data_root}`)
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  StatCell(label: string, value: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(label)
        .fontSize(11)
        .fontColor(Theme.textFaint)
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DirsCard(view: StorageUsageView) {
    Column() {
      ForEach(view.dirs, (dir: DirUsageView, index: number) => {
        Column() {
          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text(dir.title)
                .fontSize(15)
                .fontColor(Theme.text)
              Text(`${dir.summary}  ·  ${dir.rebuild_cost}`)
                .fontSize(12)
                .fontColor(Theme.textFaint)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(this.cleaningKey === dir.key ? '清理中…' : '清理')
              .fontSize(13)
              .fontColor(dir.clearable ? Theme.danger : Theme.textFaint)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .onClick(() => {
                if (dir.clearable) {
                  this.confirmClean(dir);
                } else {
                  this.toast('这一项不能单独清理');
                }
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 16, right: 12, top: 11, bottom: 11 })
          if (index < view.dirs.length - 1) {
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
          }
        }
        .width('100%')
      }, (dir: DirUsageView) => dir.key)
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  // MARK: 定时任务

  @Builder
  TasksBody() {
    Scroll() {
      Column({ space: 14 }) {
        if (this.tasksError.length > 0) {
          Column({ space: 10 }) {
            Text(this.tasksError)
              .fontSize(13)
              .fontColor(Theme.danger)
              .width('100%')
            Text('重试')
              .fontSize(13)
              .fontColor(Theme.accentStrong)
              .onClick(() => {
                this.loadTasks();
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        if (this.reconcileTask() !== null && this.suggestReconcile(this.reconcileTask() as ScheduledTaskView)) {
          this.ReconcileCard(this.reconcileTask() as ScheduledTaskView)
        }
        if (this.tasksLoading) {
          Column({ space: 10 }) {
            LoadingProgress().width(24).height(24).color(Theme.textMuted)
            Text('正在加载…').fontSize(13).fontColor(Theme.textFaint)
          }
          .width('100%')
          .padding({ top: 40 })
          .justifyContent(FlexAlign.Center)
        } else if (this.tasks.length > 0) {
          this.TasksCard()
        }
        Text('点选任务调整周期。保存后在服务器生效，无需重启。')
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .width('100%')
        AppFooter()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: Theme.tabBarInset })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  /** 有库挂在网上且对账周期偏长时的建议卡（只建议，一键采纳） */
  @Builder
  ReconcileCard(task: ScheduledTaskView) {
    Column({ space: 10 }) {
      Text('有媒体库放在网络挂载上：实时监控收不到远端变化，新文件全靠「媒体库对账」发现。现在是'
        + AppMaintenanceSection.describe(task) + '，建议调到每 1 小时——增量对账通常只需几秒。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
        .lineHeight(19)
      Text(this.busyKey === task.key ? '调整中…' : '调到每 1 小时')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.busyKey === task.key ? Theme.textFaint : '#0b0d12')
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor(this.busyKey === task.key ? Theme.glassFill : Theme.accent)
        .borderRadius(15)
        .onClick(() => {
          if (this.busyKey.length === 0) {
            this.applyReconcileSuggestion(task);
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  TasksCard() {
    Column() {
      ForEach(this.tasks, (task: ScheduledTaskView, index: number) => {
        Column() {
          Row({ space: 12 }) {
            SymbolGlyph(task.enabled ? $r('sys.symbol.clock') : $r('sys.symbol.pause_circle'))
              .fontSize(20)
              .fontColor([task.enabled ? Theme.accent : Theme.textFaint])
            Column({ space: 3 }) {
              Text(task.title)
                .fontSize(15)
                .fontColor(Theme.text)
                .width('100%')
              Text(task.enabled ? AppMaintenanceSection.describe(task) : '已暂停')
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(13)
              .fontColor([Theme.textFaint])
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: 16, right: 12, top: 13, bottom: 13 })
          .onClick(() => {
            this.openEditor(task);
          })
          if (index < this.tasks.length - 1) {
            Divider().color(Theme.line).margin({ left: 52, right: 16 })
          }
        }
        .width('100%')
      }, (task: ScheduledTaskView) => task.key)
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 单个任务的编辑抽屉：启停 + 周期形状（间隔 / 每天固定时刻 / cron），保存才落库 */
  @Builder
  TaskSheet() {
    Column() {
      Row() {
        Text(this.draftTitle())
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(15)
          .fontColor([Theme.textMuted])
          .padding(8)
          .onClick(() => {
            this.showTaskSheet = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 12, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 16 }) {
          Row() {
            Text('启用任务')
              .fontSize(15)
              .fontColor(Theme.text)
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.draftEnabled })
              .selectedColor(Theme.accent)
              .onChange((isOn: boolean): void => {
                this.draftEnabled = isOn;
              })
          }
          .width('100%')

          Row({ space: 6 }) {
            this.ModeChip('interval', '每隔一段时间')
            this.ModeChip('daily', '每天固定时刻')
            this.ModeChip('cron', '自定义周期')
          }
          .width('100%')

          if (this.draftMode === 'interval') {
            Row({ space: 14 }) {
              Text('−')
                .fontSize(20)
                .fontColor(Theme.text)
                .width(34)
                .height(34)
                .textAlign(TextAlign.Center)
                .backgroundColor(Theme.glassFill)
                .borderRadius(17)
                .border({ width: 1, color: Theme.line })
                .onClick(() => {
                  if (this.draftHours > 1) {
                    this.draftHours--;
                  }
                })
              Text(this.draftIntervalLabel())
                .fontSize(15)
                .fontColor(Theme.text)
              Text('+')
                .fontSize(20)
                .fontColor(Theme.text)
                .width(34)
                .height(34)
                .textAlign(TextAlign.Center)
                .backgroundColor(Theme.glassFill)
                .borderRadius(17)
                .border({ width: 1, color: Theme.line })
                .onClick(() => {
                  if (this.draftHours < 168) {
                    this.draftHours++;
                  }
                })
              Blank()
            }
            .width('100%')
          } else if (this.draftMode === 'daily') {
            TimePicker({ selected: this.draftDate() })
              .useMilitaryTime(true)
              .disappearTextStyle({ color: Theme.textFaint, font: { size: 14 } })
              .textStyle({ color: Theme.textMuted, font: { size: 15 } })
              .selectedTextStyle({ color: Theme.text, font: { size: 18, weight: FontWeight.Medium } })
              .onChange((value: TimePickerResult): void => {
                this.draftHour = value.hour;
                this.draftMinute = value.minute;
              })
          } else {
            TextInput({ text: this.draftCron, placeholder: '分 时 日 月 周' })
              .width('100%')
              .height(42)
              .fontSize(14)
              .fontColor(Theme.text)
              .backgroundColor(Theme.surfaceRaised)
              .borderRadius(10)
              .padding({ left: 12, right: 12 })
              .onChange((v: string): void => {
                this.draftCron = v;
              })
          }

          Column({ space: 6 }) {
            Text(this.draftDescription())
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
            Text(`上次运行：${this.draftLastRun()}`)
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
            if (this.draftNextRun().length > 0) {
              Text(`下次运行：${this.draftNextRun()}`)
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          if (this.draftError.length > 0) {
            Text(this.draftError)
              .fontSize(13)
              .fontColor(Theme.danger)
              .width('100%')
          }

          Row() {
            Text(this.savingTask ? '保存中…' : '保存')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.saveEnabled() ? '#0b0d12' : Theme.textFaint)
              .padding({ left: 24, right: 24, top: 11, bottom: 11 })
              .backgroundColor(this.saveEnabled() ? Theme.accent : Theme.glassFill)
              .borderRadius(20)
              .onClick(() => {
                if (this.saveEnabled()) {
                  this.saveDraft();
                }
              })
            Blank()
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 20, right: 20, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Start)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  private draftTitle(): string {
    const task: ScheduledTaskView | null = this.draftTask();
    return task === null ? '' : task.title;
  }

  private draftDescription(): string {
    const task: ScheduledTaskView | null = this.draftTask();
    return task === null ? '' : task.description;
  }

  private draftLastRun(): string {
    const task: ScheduledTaskView | null = this.draftTask();
    if (task !== null && task.last_run_at !== null && task.last_run_at !== undefined && task.last_run_at.length > 0) {
      return Formatters.relative(task.last_run_at);
    }
    return '尚未运行';
  }

  private draftNextRun(): string {
    const task: ScheduledTaskView | null = this.draftTask();
    if (task === null || !task.enabled) {
      return '';
    }
    if (task.next_run_at !== null && task.next_run_at !== undefined && task.next_run_at.length > 0) {
      return Formatters.dateTime(task.next_run_at);
    }
    return '';
  }

  @Builder
  ModeChip(mode: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.draftMode === mode ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .backgroundColor(this.draftMode === mode ? Theme.accent : Theme.glassFill)
      .borderRadius(14)
      .onClick(() => {
        this.draftMode = mode;
      })
  }
}
