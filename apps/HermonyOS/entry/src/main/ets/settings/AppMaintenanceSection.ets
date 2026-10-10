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
  StorageStateView,
  StorageUsageView,
  UpdateCheckView,
  UpdateProgressView
} from '../api/Models';

/** 三个页签（对应 iOS `AppMaintenanceSettingsView.Tab`） */
class AppTab {
  static readonly update: string = 'update';
  static readonly storage: string = 'storage';
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

/**
 * 设置 → 更新与维护（对应 iOS `AppMaintenanceSettingsView` / Web `settings-view` 的 `AppSection`）。
 *
 * iOS 是三个胶囊页签，**默认停在「版本与更新」**——因为这一页的高频入口就是「有可用更新」，
 * 用户带着「来更新」的意图落地。
 *
 * 本轮做前两个页签：
 * - **版本与更新**：当前版本 / 检查更新 / 更新日志 / 一键更新 / 更新进度 / GitHub Token（私有仓库要它）；
 * - **缓存管理**：磁盘与缓存占用、逐目录明细、按目录清理。
 *
 * **没做**：**定时任务**页签（`ScheduledTasksPanel`）、回滚到历史版本、以及页签上的更新蓝点
 * （要外壳常驻轮询，见 iOS 的 `ShellBadges`）。
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
      } else {
        this.StorageBody()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  TabBar() {
    Row({ space: 8 }) {
      this.TabChip(AppTab.update, '版本与更新')
      this.TabChip(AppTab.storage, '缓存管理')
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
}
