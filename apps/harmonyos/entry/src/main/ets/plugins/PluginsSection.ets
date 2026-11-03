import { common } from '@kit.AbilityKit';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { PluginView, PluginsView, RemovedPluginView } from '../api/Models';
import { AppModel } from '../common/AppModel';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { SettingsSegmentChip } from '../common/SettingsControls';
import { Theme } from '../theme/AppTheme';
import { PluginDetailSheet } from './PluginDetailSheet';
import { PluginApproveSheet } from './PluginApproveSheet';
import { PluginWebParams } from './PluginWebPage';
import { PluginDisplay, PluginGroup } from './PluginsFormat';
import {
  PluginInstalledPackage,
  PluginMarketInstalled,
  PluginMarketItem,
  PluginMarketOverview,
  PluginPackagesOverview,
  PluginPendingPackage,
  PluginWebApp,
  PluginWebEntry,
  PluginsApi
} from './PluginsApi';

/**
 * 「我的」页 →「插件」段（对应 Web「设置 → 插件」的主清单 + 插件市场）：
 *
 * - 已安装：安全模式、出问题的系统模块、官方插件、已卸载的官方插件（可恢复）、
 *   第三方 / 本地插件包、待批准的包（批准 / 放弃）、上传插件包、系统模块折叠清单；
 * - 插件市场：签名索引里的插件，安装 / 更新后进入待批准，再走同一套批准流程；
 * - 点任意一行 → 详情（状态、权限、事件、回调、设置）。
 *
 * 数据源：`GET /app/plugins`、`/app/plugins/packages`、`/app/plugins/market`。
 * 插件是管理员能力（与 Web 设置页同口径），段入口本身按管理员显示。
 */
@ComponentV2
export struct PluginsSection {
  /** 宿主（「我的」页）的导航栈：插件网页从这里压栈 */
  @Param navStack: NavPathStack = new NavPathStack();
  @Local private overview: PluginsView | null = null;
  @Local private packages: PluginPackagesOverview | null = null;
  @Local private market: PluginMarketOverview | null = null;
  /** 带网页的插件与侧边栏入口（`GET /ui/apps`） */
  @Local private webApps: PluginWebApp[] = [];
  /** installed | market */
  @Local private tab: string = 'installed';
  @Local private loading: boolean = true;
  @Local private marketLoading: boolean = false;
  @Local private error: string = '';
  @Local private marketError: string = '';
  /** 正在执行的动作（`switch:<id>` / `restore:<id>` / `install:<id>` …），用来禁用重复点击 */
  @Local private busyKey: string = '';
  @Local private showSystem: boolean = false;
  /** 弹层：detail | approve */
  @Local private sheetKind: string = '';
  @Local private showSheet: boolean = false;
  @Local private detailId: string = '';
  @Local private pendingTarget: PluginPendingPackage | null = null;

  aboutToAppear(): void {
    this.load();
  }

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

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      this.loading = false;
      return;
    }
    if (this.overview === null) {
      this.loading = true;
    }
    try {
      this.overview = await api.appPluginsList();
      this.error = '';
    } catch (error) {
      this.error = this.messageOf(error);
    }
    try {
      this.packages = await PluginsApi.packages();
    } catch (error) {
      // 旧服务端没有插件包接口：只展示内置插件
      this.packages = null;
    }
    try {
      this.webApps = await PluginsApi.webApps();
    } catch (error) {
      // 旧服务端没有插件网页：不展示这一块
      this.webApps = [];
    }
    this.loading = false;
  }

  private loadMarket(): void {
    if (this.market !== null) {
      return;
    }
    this.marketLoading = true;
    this.marketError = '';
    PluginsApi.market().then((value: PluginMarketOverview): void => {
      this.market = value;
      this.marketLoading = false;
    }).catch((error: Object): void => {
      this.marketError = this.messageOf(error);
      this.marketLoading = false;
    });
  }

  private refreshMarket(): void {
    this.marketLoading = true;
    this.marketError = '';
    PluginsApi.refreshMarket().then((value: PluginMarketOverview): void => {
      this.market = value;
      this.marketLoading = false;
    }).catch((error: Object): void => {
      this.marketError = this.messageOf(error);
      this.marketLoading = false;
    });
  }

  private switchTab(next: string): void {
    this.tab = next;
    if (next === 'market') {
      this.loadMarket();
    }
  }

  private plugins(): PluginView[] {
    return this.overview === null ? [] : this.overview.plugins;
  }

  private official(): PluginView[] {
    return PluginDisplay.officialPlugins(this.plugins());
  }

  private systemModules(): PluginView[] {
    return PluginDisplay.systemModules(this.plugins());
  }

  /** 出问题的系统模块：平时看不到它们，出问题浮到最上面 */
  private problemModules(): PluginView[] {
    const out: PluginView[] = [];
    for (const item of this.systemModules()) {
      if (PluginDisplay.needsAttention(item)) {
        out.push(item);
      }
    }
    return out;
  }

  private removed(): RemovedPluginView[] {
    return this.overview === null ? [] : this.overview.removed;
  }

  private installedPackages(): PluginInstalledPackage[] {
    return this.packages === null ? [] : this.packages.installed;
  }

  /** 本地插件（data/plugins.yaml 里开启的本机代码）：不在插件包接口里，只在插件清单里 */
  private localPlugins(): PluginView[] {
    const out: PluginView[] = [];
    for (const item of this.plugins()) {
      if (item.source === 'local') {
        out.push(item);
      }
    }
    return out;
  }

  /** 本地插件运行方式概况（主进程内 = 与主程序同权限） */
  private localRuntimeNote(): string {
    const locals: PluginView[] = this.localPlugins();
    let inline: number = 0;
    for (const item of locals) {
      if (item.runtime !== 'process') {
        inline += 1;
      }
    }
    const processCount: number = locals.length - inline;
    const parts: string[] = [];
    if (processCount > 0) {
      parts.push(`${processCount} 个独立进程运行`);
    }
    if (inline > 0) {
      parts.push(`${inline} 个在主进程内运行（与主程序同权限）`);
    }
    return parts.join('，');
  }

  private pendingPackages(): PluginPendingPackage[] {
    return this.packages === null ? [] : this.packages.pending;
  }

  private safeModeActive(): boolean {
    return this.overview !== null && this.overview.safe_mode.active;
  }

  private safeModeForcedByEnv(): boolean {
    return this.overview !== null && this.overview.safe_mode.forced === 'env';
  }

  private openDetail(id: string): void {
    this.detailId = id;
    this.sheetKind = 'detail';
    this.showSheet = true;
  }

  private hasWebPages(): boolean {
    for (const app of this.webApps) {
      if (app.entries.length > 0) {
        return true;
      }
    }
    return false;
  }

  /** 插件网页在应用内打开：页面走自定义 scheme 代理（见 `PluginWebPage`） */
  private openWebPage(app: PluginWebApp, entry: PluginWebEntry): void {
    this.navStack.pushPathByName('pluginWeb',
      new PluginWebParams(app.id, entry.label, app.base, entry.path));
  }

  private openApprove(item: PluginPendingPackage): void {
    this.pendingTarget = item;
    this.sheetKind = 'approve';
    this.showSheet = true;
  }

  private closeSheet(): void {
    this.showSheet = false;
  }

  private async togglePlugin(plugin: PluginView, enabled: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyKey = `switch:${plugin.id}`;
    try {
      await api.appPluginsSwitch(plugin.id, { enabled: enabled });
      this.toast(enabled ? '已启用' : '已停用');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyKey = '';
    }
  }

  private async restoreRemoved(item: RemovedPluginView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyKey = `restore:${item.id}`;
    try {
      await api.appPluginsBundledRestore(item.id);
      this.toast(`已恢复「${item.title}」`);
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyKey = '';
    }
  }

  private async exitSafeMode(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyKey = 'safe-mode';
    try {
      await api.appPluginsSafeModeExit();
      this.toast('已退出安全模式');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyKey = '';
    }
  }

  private async uploadPackage(): Promise<void> {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    let uri: string = '';
    try {
      uri = await PluginsApi.pickPackage(context);
    } catch (error) {
      this.toast('打开文件选择器失败');
      return;
    }
    if (uri.length === 0) {
      return;
    }
    this.busyKey = 'upload';
    try {
      await PluginsApi.upload(uri);
      this.toast('已上传，等待批准');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyKey = '';
    }
  }

  private async discardPending(item: PluginPendingPackage): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyKey = `discard:${item.id}`;
    try {
      await api.appPluginsPackagesDiscard(item.id);
      this.toast('已放弃这个插件包');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyKey = '';
    }
  }

  private confirm(title: string, message: string, confirmTitle: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      this.getUIContext().showAlertDialog({
        title: title,
        message: message,
        primaryButton: {
          value: confirmTitle,
          action: (): void => {
            resolve(true);
          }
        },
        secondaryButton: {
          value: '取消',
          action: (): void => {
            resolve(false);
          }
        },
        cancel: (): void => {
          resolve(false);
        }
      });
    });
  }

  /** 从市场安装某版：服务器下载核对 → 待批准 → 打开批准弹层 */
  private async installFromMarket(item: PluginMarketItem): Promise<void> {
    const version: string = item.update !== null && item.update !== undefined && item.update.length > 0
      ? item.update
      : (item.recommended ?? '');
    if (version.length === 0) {
      return;
    }
    const action: string = item.installed !== null && item.installed !== undefined ? '更新' : '安装';
    const ok: boolean = await this.confirm(`${action}「${item.name}」？`,
      `将从市场获取 v${version}，等你在下一步批准权限后才会加载。`, `${action}并批准`);
    if (!ok) {
      return;
    }
    this.busyKey = `install:${item.id}`;
    try {
      const pending: PluginPendingPackage = await PluginsApi.installFromMarket(item.id, version);
      this.busyKey = '';
      this.openApprove(pending);
    } catch (error) {
      this.toast(this.messageOf(error));
      this.busyKey = '';
    }
  }

  // MARK: 视图

  build() {
    Column({ space: 12 }) {
      Row() {
        SettingsSegmentChip({
          label: '已安装',
          selected: this.tab === 'installed',
          onPick: (): void => {
            this.switchTab('installed');
          }
        })
        SettingsSegmentChip({
          label: this.market !== null && this.market.updates > 0 ? `插件市场 ${this.market.updates}` : '插件市场',
          selected: this.tab === 'market',
          onPick: (): void => {
            this.switchTab('market');
          }
        })
      }
      .width('100%')
      .padding(3)
      .backgroundColor(Theme.glassFill)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })

      if (this.tab === 'market') {
        this.MarketContent()
      } else {
        this.InstalledContent()
      }
    }
    .width('100%')
    .padding({ top: 4 })
    .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  @Builder
  SheetContent() {
    if (this.sheetKind === 'detail') {
      PluginDetailSheet({
        pluginId: this.detailId,
        onChanged: (): void => {
          this.load();
        },
        onExit: (): void => {
          this.showSheet = false;
          this.load();
        }
      })
    } else {
      PluginApproveSheet({
        pending: this.pendingTarget,
        onDone: (approved: boolean): void => {
          this.showSheet = false;
          this.toast(approved ? '插件已安装' : '已放弃这个插件包');
          this.load();
          if (this.tab === 'market') {
            this.market = null;
            this.loadMarket();
          }
        }
      })
    }
  }

  @Builder
  InstalledContent() {
    if (this.loading) {
      Column({ space: 8 }) {
        LoadingProgress().width(22).height(22).color(Theme.textMuted)
        Text('正在读取插件…').fontSize(13).fontColor(Theme.textFaint)
      }
      .width('100%')
      .padding({ top: 30, bottom: 30 })
    } else if (this.error.length > 0) {
      Column({ space: 8 }) {
        Text('无法读取插件').fontSize(15).fontColor(Theme.text)
        Text(this.error).fontSize(13).fontColor(Theme.textMuted).textAlign(TextAlign.Center)
        Text('点击重试')
          .fontSize(13)
          .fontColor(Theme.accentStrong)
          .onClick((): void => {
            this.load();
          })
      }
      .width('100%')
      .padding(20)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    } else {
      if (this.safeModeActive()) {
        this.SafeModeCard()
      }
      if (this.problemModules().length > 0) {
        this.ProblemsCard()
      }
      if (this.official().length > 0) {
        this.OfficialCard()
      }
      if (this.hasWebPages()) {
        this.WebPagesCard()
      }
      if (this.removed().length > 0) {
        this.RemovedCard()
      }
      if (this.installedPackages().length > 0) {
        this.PackagesCard()
      }
      if (this.localPlugins().length > 0) {
        this.LocalCard()
      }
      if (this.pendingPackages().length > 0) {
        this.PendingCard()
      }
      this.UploadCard()
      if (this.systemModules().length > 0) {
        this.SystemCard()
      }
    }
  }

  @Builder
  CardTitle(title: string, hint: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')
        .textAlign(TextAlign.Start)
      if (hint.length > 0) {
        Text(hint)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 12, bottom: 6 })
  }

  @Builder
  SafeModeCard() {
    Column({ space: 8 }) {
      Text('插件安全模式')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.warn)
        .width('100%')
      Text(`${(this.overview as PluginsView).safe_mode.reason}；本次跳过：`
        + `${(this.overview as PluginsView).safe_mode.skipped.join('、')}`)
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .width('100%')
      Text(this.safeModeForcedByEnv()
        ? '这是由环境变量强制开启的，需要在服务端改回来才能退出。'
        : '插件没能带着上次的配置稳定运行，本次启动先跳过了它们。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
      if (!this.safeModeForcedByEnv()) {
        Button() {
          Text(this.busyKey === 'safe-mode' ? '正在退出…' : '退出安全模式')
            .fontSize(13)
            .fontColor(Theme.bg)
        }
        .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .borderRadius(13)
        .onClick((): void => {
          this.exitSafeMode();
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: 'rgba(245, 196, 81, 0.3)' })
  }

  @Builder
  ProblemsCard() {
    Column({ space: 8 }) {
      Text(`有 ${this.problemModules().length} 个系统模块异常`)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.warn)
        .width('100%')
      ForEach(this.problemModules(), (plugin: PluginView) => {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(plugin.title)
              .fontSize(13)
              .fontColor(Theme.text)
              .width('100%')
            Text(PluginDisplay.detailText(plugin))
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .onClick((): void => {
          this.openDetail(plugin.id);
        })
      }, (plugin: PluginView) => `problem-${plugin.id}`)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: 'rgba(245, 196, 81, 0.3)' })
  }

  @Builder
  OfficialCard() {
    Column({ space: 0 }) {
      this.CardTitle('官方插件', '随应用提供，可由插件包替换')
      ForEach(this.official(), (plugin: PluginView) => {
        this.PluginRow(plugin)
      }, (plugin: PluginView) => `official-${plugin.id}`)
    }
    .width('100%')
    .padding({ bottom: 4 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  PluginRow(plugin: PluginView) {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text(plugin.title)
            .fontSize(14)
            .fontColor(Theme.text)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(PluginDisplay.detailText(plugin))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(PluginDisplay.stateLabel(PluginDisplay.displayState(plugin)))
          .fontSize(11)
          .fontColor(PluginDisplay.stateTone(PluginDisplay.displayState(plugin)))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor('rgba(255, 255, 255, 0.06)')
          .borderRadius(10)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, top: 9, bottom: 9 })
      Divider().color(Theme.line).margin({ left: 14, right: 14 })
    }
    .width('100%')
    .onClick((): void => {
      this.openDetail(plugin.id);
    })
  }

  @Builder
  WebPagesCard() {
    Column({ space: 0 }) {
      this.CardTitle('插件网页', '插件自带的页面，在应用内打开')
      ForEach(this.webApps, (app: PluginWebApp) => {
        ForEach(app.entries, (entry: PluginWebEntry) => {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(entry.label)
                .fontSize(14)
                .fontColor(Theme.text)
                .width('100%')
                .textAlign(TextAlign.Start)
              Text(app.name)
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(13)
              .fontColor([Theme.textFaint])
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: 14, right: 14, top: 9, bottom: 9 })
          .onClick((): void => {
            this.openWebPage(app, entry);
          })
        }, (entry: PluginWebEntry) => `web-${app.id}-${entry.path}-${entry.label}`)
      }, (app: PluginWebApp) => `webapp-${app.id}`)
    }
    .width('100%')
    .padding({ bottom: 4 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  RemovedCard() {
    Column({ space: 0 }) {
      this.CardTitle('已卸载的官方插件', '代码随应用携带，随时能恢复')
      ForEach(this.removed(), (item: RemovedPluginView) => {
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(item.title)
              .fontSize(14)
              .fontColor(Theme.text)
              .width('100%')
            Text(item.description.length > 0 ? item.description : '已卸载')
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button() {
            Text(this.busyKey === `restore:${item.id}` ? '恢复中…' : '恢复')
              .fontSize(12)
              .fontColor(Theme.text)
          }
          .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(12)
          .enabled(this.busyKey.length === 0)
          .onClick((): void => {
            this.restoreRemoved(item);
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 14, right: 14, top: 9, bottom: 9 })
      }, (item: RemovedPluginView) => `removed-${item.id}`)
    }
    .width('100%')
    .padding({ bottom: 4 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  PackagesCard() {
    Column({ space: 0 }) {
      this.CardTitle('插件包', '从市场或上传安装的第三方插件，批准后加载')
      ForEach(this.installedPackages(), (item: PluginInstalledPackage) => {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Row({ space: 6 }) {
              Text(item.title)
                .fontSize(14)
                .fontColor(Theme.text)
              if (item.replaces_builtin) {
                Text('替换随带版本')
                  .fontSize(10)
                  .fontColor(Theme.textFaint)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .backgroundColor('rgba(255,255,255,0.06)')
                  .borderRadius(8)
              }
            }
            .width('100%')
            Text(PluginDisplay.packageDetail(item))
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (item.error !== null && item.error !== undefined && item.error.length > 0) {
              Text(item.error)
                .fontSize(12)
                .fontColor(Theme.danger)
                .width('100%')
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text(PluginDisplay.stateLabel(item.state))
            .fontSize(11)
            .fontColor(PluginDisplay.stateTone(item.state))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor('rgba(255, 255, 255, 0.06)')
            .borderRadius(10)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 14, right: 14, top: 9, bottom: 9 })
        .onClick((): void => {
          this.openDetail(item.id);
        })
      }, (item: PluginInstalledPackage) => `pkg-${item.id}-${item.version}`)
    }
    .width('100%')
    .padding({ bottom: 4 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 本地插件：data/plugins.yaml 里开启的本机代码，只能去服务端配置里装卸，这里只读展示 */
  @Builder
  LocalCard() {
    Column({ space: 0 }) {
      this.CardTitle('本地插件', '在 data/plugins.yaml 里开启；装卸要改服务端配置')
      if (this.localRuntimeNote().length > 0) {
        Text(this.localRuntimeNote())
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 6 })
      }
      ForEach(this.localPlugins(), (plugin: PluginView) => {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(plugin.title)
              .fontSize(14)
              .fontColor(Theme.text)
              .width('100%')
              .textAlign(TextAlign.Start)
            Text(`${plugin.id} · ${PluginDisplay.runtimeLabel(plugin.runtime)}`)
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
              .textAlign(TextAlign.Start)
            if (plugin.state === 'failed' && plugin.error !== null && plugin.error !== undefined
              && plugin.error.length > 0) {
              Text(plugin.error)
                .fontSize(12)
                .fontColor(Theme.danger)
                .width('100%')
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text(PluginDisplay.stateLabel(plugin.state))
            .fontSize(11)
            .fontColor(PluginDisplay.stateTone(plugin.state))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor('rgba(255, 255, 255, 0.06)')
            .borderRadius(10)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 14, right: 14, top: 9, bottom: 9 })
        .onClick((): void => {
          this.openDetail(plugin.id);
        })
      }, (plugin: PluginView) => `local-${plugin.id}`)
    }
    .width('100%')
    .padding({ bottom: 4 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  PendingCard() {
    Column({ space: 0 }) {
      this.CardTitle('待批准', '批准后才会加载；权限逐项列在批准页')
      ForEach(this.pendingPackages(), (item: PluginPendingPackage) => {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(item.title)
              .fontSize(14)
              .fontColor(Theme.text)
              .layoutWeight(1)
            Text(`v${item.version}`)
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          .width('100%')
          Text(item.description)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 8 }) {
            Button() {
              Text('批准…').fontSize(12).fontColor(Theme.bg)
            }
            .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(12)
            .onClick((): void => {
              this.openApprove(item);
            })
            Button() {
              Text('放弃').fontSize(12).fontColor(Theme.textMuted)
            }
            .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(12)
            .enabled(this.busyKey.length === 0)
            .onClick((): void => {
              this.discardPending(item);
            })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 9, bottom: 9 })
      }, (item: PluginPendingPackage) => `pending-${item.id}`)
    }
    .width('100%')
    .padding({ bottom: 4 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  UploadCard() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text('上传插件包')
          .fontSize(14)
          .fontColor(Theme.text)
          .width('100%')
        Text('选一个 .mcplugin 文件，上传后进入待批准')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button() {
        Text(this.busyKey === 'upload' ? '上传中…' : '选择文件')
          .fontSize(13)
          .fontColor(Theme.text)
      }
      .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(13)
      .enabled(this.busyKey.length === 0)
      .onClick((): void => {
        this.uploadPackage();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  SystemCard() {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Circle()
          .width(6)
          .height(6)
          .fill(this.problemModules().length > 0 ? Theme.warn : Theme.ok)
        Text(`系统模块 · ${PluginDisplay.summary(this.systemModules())}`)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .layoutWeight(1)
        Text(this.showSystem ? '收起' : '查看')
          .fontSize(12)
          .fontColor(Theme.textFaint)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([Theme.textFaint])
          .rotate({ angle: this.showSystem ? 90 : 0 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding(14)
      .onClick((): void => {
        this.showSystem = !this.showSystem;
      })
      if (this.showSystem) {
        Divider().color(Theme.line).margin({ left: 14, right: 14 })
        Text('应用运行所需；平时不展示，出问题才浮到上面。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 4 })
        ForEach(this.groupedModules(), (group: PluginGroup) => {
          Text(group.label)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 2 })
          ForEach(group.plugins, (plugin: PluginView) => {
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text(plugin.title)
                  .fontSize(13)
                  .fontColor(Theme.text)
                  .width('100%')
                Text(PluginDisplay.detailText(plugin))
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Text(PluginDisplay.stateLabel(PluginDisplay.displayState(plugin)))
                .fontSize(10)
                .fontColor(PluginDisplay.stateTone(PluginDisplay.displayState(plugin)))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .onClick((): void => {
              this.openDetail(plugin.id);
            })
          }, (plugin: PluginView) => `module-${plugin.id}`)
        }, (group: PluginGroup) => `group-${group.label}`)
        Blank().height(6)
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  private groupedModules(): PluginGroup[] {
    return PluginDisplay.groupBuiltins(this.systemModules(),
      this.overview === null ? [] : this.overview.groups);
  }

  // MARK: 插件市场

  @Builder
  MarketContent() {
    if (this.marketLoading && this.market === null) {
      Column({ space: 8 }) {
        LoadingProgress().width(22).height(22).color(Theme.textMuted)
        Text('正在读取插件市场…').fontSize(13).fontColor(Theme.textFaint)
      }
      .width('100%')
      .padding({ top: 30, bottom: 30 })
    } else if (this.marketError.length > 0 && this.market === null) {
      Column({ space: 8 }) {
        Text('无法读取插件市场').fontSize(15).fontColor(Theme.text)
        Text(this.marketError).fontSize(13).fontColor(Theme.textMuted).textAlign(TextAlign.Center)
        Text('点击重试')
          .fontSize(13)
          .fontColor(Theme.accentStrong)
          .onClick((): void => {
            this.marketError = '';
            this.loadMarket();
          })
      }
      .width('100%')
      .padding(20)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    } else if (this.market !== null) {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text((this.market as PluginMarketOverview).source.repository ?? (this.market as PluginMarketOverview).source.url)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${(this.market as PluginMarketOverview).source.signed ? '已签名' : '未签名'} · `
            + `更新于 ${(this.market as PluginMarketOverview).source.checked_at}`
            + ((this.market as PluginMarketOverview).updates > 0
              ? ` · ${(this.market as PluginMarketOverview).updates} 个可更新` : ''))
            .fontSize(11)
            .fontColor(Theme.textFaint)
            .width('100%')
          if ((this.market as PluginMarketOverview).source.error !== null
            && (this.market as PluginMarketOverview).source.error !== undefined) {
            Text(`最近一次检查失败：${(this.market as PluginMarketOverview).source.error}`)
              .fontSize(11)
              .fontColor(Theme.warn)
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button() {
          Text(this.marketLoading ? '检查中…' : '检查更新')
            .fontSize(12)
            .fontColor(Theme.text)
        }
        .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(12)
        .enabled(!this.marketLoading)
        .onClick((): void => {
          this.refreshMarket();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding(14)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })

      if (this.marketError.length > 0) {
        Text(this.marketError)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }

      Column({ space: 0 }) {
        ForEach((this.market as PluginMarketOverview).plugins, (item: PluginMarketItem) => {
          this.MarketRow(item)
        }, (item: PluginMarketItem) => `market-${item.id}-${item.latest ?? ''}`)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  @Builder
  MarketRow(item: PluginMarketItem) {
    Column({ space: 4 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(item.name)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
            if (item.installed !== null && item.installed !== undefined) {
              Text(`已装 v${(item.installed as PluginMarketInstalled).version}`)
                .fontSize(10)
                .fontColor(Theme.textFaint)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor('rgba(255,255,255,0.06)')
                .borderRadius(8)
            }
            if (item.update !== null && item.update !== undefined && item.update.length > 0) {
              Text(`可更新到 v${item.update}`)
                .fontSize(10)
                .fontColor(Theme.ok)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor('rgba(74, 222, 128, 0.12)')
                .borderRadius(8)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          Text(item.summary)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item.blocked !== null && item.blocked !== undefined && item.blocked.length > 0) {
            Text(item.blocked)
              .fontSize(11)
              .fontColor(Theme.warn)
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        this.MarketAction(item)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, top: 9, bottom: 9 })
    }
    .width('100%')
  }

  @Builder
  MarketAction(item: PluginMarketItem) {
    if (item.blocked !== null && item.blocked !== undefined && item.blocked.length > 0) {
      Text('不可用').fontSize(11).fontColor(Theme.textFaint)
    } else if (item.installed !== null && item.installed !== undefined
      && (item.update === null || item.update === undefined || item.update.length === 0)) {
      Text('已安装').fontSize(11).fontColor(Theme.textFaint)
    } else if (item.recommended !== null && item.recommended !== undefined && item.recommended.length > 0) {
      Button() {
        Text(this.busyKey === `install:${item.id}` ? '获取中…'
          : (item.installed !== null && item.installed !== undefined ? '更新' : '安装'))
          .fontSize(12)
          .fontColor(Theme.bg)
      }
      .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(12)
      .enabled(this.busyKey.length === 0)
      .onClick((): void => {
        this.installFromMarket(item);
      })
    } else {
      Text('暂无可用版本').fontSize(11).fontColor(Theme.textFaint)
    }
  }
}
