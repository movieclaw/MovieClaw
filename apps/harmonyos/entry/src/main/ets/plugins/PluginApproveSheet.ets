import { ApiError } from '../api/ApiClient';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { Theme } from '../theme/AppTheme';
import { PluginDisplay } from './PluginsFormat';
import {
  PluginApproveBody,
  PluginOperationDetail,
  PluginPackageDependencies,
  PluginPackageDependency,
  PluginPathGrant,
  PluginPendingPackage,
  PluginPendingTheme,
  PluginPendingWeb,
  PluginsApi
} from './PluginsApi';

/**
 * 批准插件包（对应 Web `plugin-packages-section` 的批准抽屉）：
 * 把插件申请的权限逐项摆出来，主进程运行 / 给成员发通知 / 带网页 / 带主题代码
 * 这些「额外授信」必须单独打开开关才能批准——默认全关，和 Web 同一个口径。
 */
@ComponentV2
export struct PluginApproveSheet {
  @Param pending: PluginPendingPackage | null = null;
  /** 批准 / 放弃之后回调：true = 已批准 */
  @Event onDone: (approved: boolean) => void = (approved: boolean): void => {
  };

  @Local private allowInline: boolean = false;
  @Local private allowMembers: boolean = false;
  @Local private allowWeb: boolean = false;
  @Local private webNav: boolean = true;
  @Local private webMembers: boolean = false;
  @Local private allowTheme: boolean = false;
  @Local private busy: boolean = false;
  @Local private error: string = '';

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private needsInline(): boolean {
    return this.pending !== null && this.pending.runtime === 'inline';
  }

  private needsMembers(): boolean {
    return this.pending !== null && this.pending.notifies_members;
  }

  private webOf(): PluginPendingWeb | null {
    const pending: PluginPendingPackage | null = this.pending;
    if (pending === null || pending.web === undefined || pending.web === null) {
      return null;
    }
    return pending.web;
  }

  private themeOf(): PluginPendingTheme | null {
    const pending: PluginPendingPackage | null = this.pending;
    if (pending === null || pending.theme === undefined || pending.theme === null) {
      return null;
    }
    return pending.theme;
  }

  private depsOf(): PluginPackageDependencies | null {
    const pending: PluginPendingPackage | null = this.pending;
    if (pending === null || pending.dependencies === undefined || pending.dependencies === null) {
      return null;
    }
    return pending.dependencies;
  }

  private hasWeb(): boolean {
    return this.webOf() !== null;
  }

  private hasThemeCode(): boolean {
    const theme: PluginPendingTheme | null = this.themeOf();
    return theme !== null && theme.has_code;
  }

  private webEntryLabels(): string {
    const web: PluginPendingWeb | null = this.webOf();
    if (web === null) {
      return '';
    }
    const labels: string[] = [];
    for (const entry of web.entries) {
      if (entry.label.length > 0) {
        labels.push(entry.label);
      }
    }
    return labels.join('、');
  }

  private canApprove(): boolean {
    if (this.pending === null || this.busy) {
      return false;
    }
    if (this.needsInline() && !this.allowInline) {
      return false;
    }
    if (this.needsMembers() && !this.allowMembers) {
      return false;
    }
    if (this.hasWeb() && !this.allowWeb) {
      return false;
    }
    if (this.hasThemeCode() && !this.allowTheme) {
      return false;
    }
    return true;
  }

  private async approve(): Promise<void> {
    const pending: PluginPendingPackage | null = this.pending;
    if (pending === null) {
      return;
    }
    const body: PluginApproveBody = new PluginApproveBody();
    body.version = pending.version;
    body.operations = pending.operations;
    body.paths = pending.paths;
    body.allow_inline = this.allowInline;
    body.allow_member_notifications = this.allowMembers;
    const deps: PluginPackageDependencies | null = this.depsOf();
    body.dependencies = deps === null ? null : deps.lock_digest;
    body.allow_web = this.hasWeb() && this.allowWeb;
    body.web_nav = this.webNav;
    body.web_members = this.webMembers;
    body.allow_theme = this.allowTheme;
    this.busy = true;
    this.error = '';
    try {
      const result = await PluginsApi.approve(pending.id, body);
      if (result.error !== null && result.error !== undefined && result.error.length > 0) {
        this.error = result.error;
        this.busy = false;
        return;
      }
      this.busy = false;
      this.onDone(true);
    } catch (error) {
      this.error = this.messageOf(error);
      this.busy = false;
    }
  }

  private async discard(): Promise<void> {
    const pending: PluginPendingPackage | null = this.pending;
    if (pending === null) {
      return;
    }
    this.busy = true;
    try {
      const api = AppModel.shared.api;
      if (api !== null) {
        await api.appPluginsPackagesDiscard(pending.id);
      }
      this.busy = false;
      this.onDone(false);
    } catch (error) {
      this.error = this.messageOf(error);
      this.busy = false;
    }
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          if (this.pending !== null) {
            Text('批准并安装插件包')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.text)
              .width('100%')
            Column({ space: 4 }) {
              Text(`${(this.pending as PluginPendingPackage).title}  v${(this.pending as PluginPendingPackage).version}`)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.text)
                .width('100%')
              Text((this.pending as PluginPendingPackage).description)
                .fontSize(13)
                .fontColor(Theme.textMuted)
                .width('100%')
              Text(`运行方式：${PluginDisplay.runtimeLabel((this.pending as PluginPendingPackage).runtime)}`)
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            if (this.needsInline()) {
              this.NoticeCard('主进程内运行', '这个插件要求在主进程里运行，权限与主程序相同。只有信任来源时才打开下面的开关。',
                this.allowInline, (on: boolean): void => {
                  this.allowInline = on;
                }, '允许在主进程运行')
            }

            this.OperationsCard()
            this.PathsCard()
            this.ExtrasCard()
            this.DependenciesCard()
            if (this.hasWeb()) {
              this.WebCard()
            }
            if (this.hasThemeCode()) {
              this.NoticeCard('网页主题带外框代码', '主题的外框组件代码会以使用者的身份在每个页面里运行，只有信任来源时才允许。',
                this.allowTheme, (on: boolean): void => {
                  this.allowTheme = on;
                }, '允许这个主题的代码')
            }
            if (this.error.length > 0) {
              Text(this.error)
                .fontSize(12)
                .fontColor(Theme.danger)
                .width('100%')
            }
            Row({ space: 10 }) {
              Button() {
                Text('放弃').fontSize(14).fontColor(Theme.textMuted)
              }
              .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
              .layoutWeight(1)
              .height(44)
              .borderRadius(14)
              .enabled(!this.busy)
              .onClick((): void => {
                this.discard();
              })
              Button() {
                Text(this.busy ? '处理中…' : '批准并安装').fontSize(14).fontWeight(FontWeight.Medium).fontColor(Theme.bg)
              }
              .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
              .layoutWeight(1)
              .height(44)
              .borderRadius(14)
              .opacity(this.canApprove() ? 1 : 0.4)
              .enabled(this.canApprove())
              .onClick((): void => {
                this.approve();
              })
            }
            .width('100%')
            Blank().height(12)
          } else {
            Text('没有待批准的插件包').fontSize(14).fontColor(Theme.textMuted)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  NoticeCard(title: string, hint: string, flag: boolean, onToggle: (on: boolean) => void, switchLabel: string) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.warn)
        .width('100%')
      Text(hint)
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .width('100%')
      Row({ space: 10 }) {
        Text(switchLabel)
          .fontSize(13)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: flag })
          .enabled(!this.busy)
          .onChange((on: boolean): void => {
            onToggle(on);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: 'rgba(245, 196, 81, 0.3)' })
  }

  @Builder
  OperationsCard() {
    Column({ space: 8 }) {
      Text('申请的宿主操作')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
      if ((this.pending as PluginPendingPackage).operation_details.length === 0) {
        Text('没有申请额外操作').fontSize(12).fontColor(Theme.textFaint).width('100%')
      } else {
        ForEach((this.pending as PluginPendingPackage).operation_details, (item: PluginOperationDetail) => {
          Row({ space: 8 }) {
            Circle()
              .width(5)
              .height(5)
              .fill(item.dangerous ? Theme.danger : Theme.textFaint)
            Text(`${item.summary}（${item.id}）`)
              .fontSize(12)
              .fontColor(item.dangerous ? Theme.danger : Theme.textMuted)
              .layoutWeight(1)
          }
          .width('100%')
        }, (item: PluginOperationDetail) => `op-${item.id}`)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  PathsCard() {
    Column({ space: 8 }) {
      Text('申请的目录权限')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
      if ((this.pending as PluginPendingPackage).paths.length === 0) {
        Text('没有申请目录权限').fontSize(12).fontColor(Theme.textFaint).width('100%')
      } else {
        ForEach((this.pending as PluginPendingPackage).paths, (grant: PluginPathGrant) => {
          Text(`· ${PluginDisplay.pathGrantLabel(grant)}`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .width('100%')
        }, (grant: PluginPathGrant) => `path-${grant.path}-${grant.mode}`)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  private eventTitlesText(): string {
    const pending: PluginPendingPackage | null = this.pending;
    if (pending === null) {
      return '';
    }
    const titles: string[] = [];
    for (const item of pending.events) {
      titles.push(item.title.length > 0 ? item.title : item.name);
    }
    return titles.join('、');
  }

  private depPackages(): PluginPackageDependency[] {
    const deps: PluginPackageDependencies | null = this.depsOf();
    return deps === null ? [] : deps.packages;
  }

  private depTotalText(): string {
    const deps: PluginPackageDependencies | null = this.depsOf();
    return deps === null ? '' : `${deps.packages.length} 个包 · ${Formatters.bytes(deps.total_size)}`;
  }

  private depUnavailableText(): string {
    const deps: PluginPackageDependencies | null = this.depsOf();
    return deps === null ? '' : deps.unavailable.join('、');
  }

  private hasExtras(): boolean {
    const pending: PluginPendingPackage | null = this.pending;
    if (pending === null) {
      return false;
    }
    return pending.callbacks.length > 0 || pending.events.length > 0
      || pending.sensitive_events.length > 0 || pending.notifies_members;
  }

  @Builder
  ExtrasCard() {
    Column({ space: 8 }) {
      if ((this.pending as PluginPendingPackage).callbacks.length > 0) {
        Text('开放的回调端点')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
        Text((this.pending as PluginPendingPackage).callbacks.join('、'))
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
      if ((this.pending as PluginPendingPackage).events.length > 0) {
        Text('会发出的事件')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
        Text(this.eventTitlesText())
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
      if ((this.pending as PluginPendingPackage).sensitive_events.length > 0) {
        Text('订阅的敏感事件')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
        Text((this.pending as PluginPendingPackage).sensitive_events.join('、'))
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
      if (this.needsMembers()) {
        Row({ space: 10 }) {
          Text('会给普通成员发通知（须单独确认）')
            .fontSize(13)
            .fontColor(Theme.warn)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.allowMembers })
            .enabled(!this.busy)
            .onChange((on: boolean): void => {
              this.allowMembers = on;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      if (!this.hasExtras()) {
        Text('没有回调端点、事件或敏感订阅')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  DependenciesCard() {
    if (this.depsOf() !== null) {
      Column({ space: 8 }) {
        Text('要安装的第三方依赖')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
        Text(this.depTotalText())
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
        ForEach(this.depPackages(), (item: PluginPackageDependency) => {
          Text(`· ${item.name} ${item.version}${item.native ? '（含本机代码）' : ''}`)
            .fontSize(12)
            .fontColor(item.available ? Theme.textMuted : Theme.danger)
            .width('100%')
        }, (item: PluginPackageDependency) => `dep-${item.name}-${item.version}`)
        if ((this.depsOf() as PluginPackageDependencies).unavailable.length > 0) {
          Text(`这台服务器装不了：${this.depUnavailableText()}`)
            .fontSize(12)
            .fontColor(Theme.danger)
            .width('100%')
        }
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  @Builder
  WebCard() {
    Column({ space: 8 }) {
      Text('带插件网页')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
      Text(`网页会在应用内托管，入口：${this.webEntryLabels()}`)
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
      Row({ space: 10 }) {
        Text('允许网页授信运行')
          .fontSize(13)
          .fontColor(this.allowWeb ? Theme.text : Theme.warn)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.allowWeb })
          .enabled(!this.busy)
          .onChange((on: boolean): void => {
            this.allowWeb = on;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Row({ space: 10 }) {
        Text('加到侧边栏 / 导航')
          .fontSize(13)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.webNav })
          .enabled(!this.busy)
          .onChange((on: boolean): void => {
            this.webNav = on;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Row({ space: 10 }) {
        Text('成员也能看到')
          .fontSize(13)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.webMembers })
          .enabled(!this.busy)
          .onChange((on: boolean): void => {
            this.webMembers = on;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }
}
