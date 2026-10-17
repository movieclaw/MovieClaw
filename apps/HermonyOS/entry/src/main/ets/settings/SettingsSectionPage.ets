import { display, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { DeviceText, GrantText } from '../common/DeviceText';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  ApiTokenCreatedView,
  AppConfigView,
  DeviceCleanupItem,
  DeviceCleanupRequest,
  DeviceCleanupView,
  LoginDeviceView
} from '../api/Models';
import { SectionParams, SettingsCatalog, SettingsSection } from './SettingsIndexPage';
import { LogsSection } from './LogsSection';
import { MembersSection } from './MembersSection';
import { LlmProvidersSection, AiDefaultsSection } from './LlmSection';
import { WebhookSection } from './WebhookSection';
import { PushSection } from './PushSection';
import { NetworkSection } from './NetworkSection';
import { AppMaintenanceSection } from './AppMaintenanceSection';
import { McpSection } from './McpSection';
import { ScrapeSection } from './ScrapeSection';
import { PlaybackSection } from './PlaybackSection';
import { DeviceApprovalDialog } from './DeviceApprovalDialog';
import { DetailParams, DeviceGroupDef, GroupListParams } from './DeviceGroupPages';
import { SettingsSegmentChip, SettingsSwitchRow, SettingsTwoStateSegment } from '../common/SettingsControls';

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function SettingsSectionBuilder() {
  SettingsSectionPage()
}

/**
 * 设置分区页（对应 iOS `SettingsSectionView`）。
 *
 * 本轮把**设备**这一区做实（它是成员也能看的两个分区之一，且注销设备是唯一的事后止损手段）；
 * 其余分区按 iOS 的做法显示「去网页端管理」——iOS 那边是 `availableInApp == false` 的分区这么做，
 * 鸿蒙这边则是**还没做**的分区这么做，措辞上分清楚，不假装已经支持。
 */
/** 复制到系统剪贴板（模块级：`@Builder` / 静态上下文里不能用 `this`） */
function copyPlainText(text: string): void {
  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  pasteboard.getSystemPasteboard().setDataSync(data);
}

@ComponentV2
export struct SettingsSectionPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;

  @Local private sectionId: string = '';
  @Local private model: AppModel = AppModel.shared;

  // 设备
  @Local private devices: LoginDeviceView[] = [];
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';

  /** 页面上的弹层（'rename' = 设备改名 / 'cleanup' = 清理）。**一个组件只能挂一个 `bindSheet`**，
   *  两个弹层要合并成一个按 kind 分发（实测挂两个只有最后那个生效） */
  /** 下拉刷新（同 iOS `.refreshable`） */
  @Local private refreshing: boolean = false;
  @Local private showDeviceSheet: boolean = false;
  @Local private sheetKind: string = '';
  @Local private showAll: boolean = false;
  /** 在线状态会变（转码器连上/断开、别的设备刚用过）：页面开着时 15 秒静默刷新一次（同 iOS `.polling`） */
  private pollTimer: number = -1;
  // 清理长期没用的设备
  @Local private cleanupDays: number = 90;
  @Local private cleanupPreview: DeviceCleanupItem[] = [];
  @Local private cleanupBusy: boolean = false;
  // 手工令牌
  @Local private tokenStage: string = 'idle';
  @Local private tokenName: string = '';
  @Local private tokenScope: string = 'full';
  @Local private tokenNameError: string = '';
  @Local private tokenCreating: boolean = false;
  @Local private createdToken: ApiTokenCreatedView | null = null;
  @Local private externalUrl: string = '';
  /**
   * 批准设备登录用**华为原生的自定义弹窗**（`openCustomDialog`）呈现，不是 push 出来的页面：
   * 系统负责遮罩、进出场动效、点遮罩关闭与**输入法避让**（`keyboardAvoidMode`），
   * 卡片内容由 `DeviceApprovalDialog` 画。`dialogId` 是系统给的弹窗句柄，用来主动关闭。
   */
  @Local private approvalDialogId: number = -1;

  aboutToDisappear(): void {
    this.stopPolling();
  }

  /** 15 秒静默刷新（只有设备分区需要；`loadDevices` 失败不清列表） */
  private startPolling(): void {
    this.stopPolling();
    this.pollTimer = setInterval((): void => {
      this.loadDevices(true);
    }, 15000);
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private section(): SettingsSection | null {
    return SettingsCatalog.find(this.sectionId);
  }

  private sectionTitle(): string {
    const s = this.section();
    return s !== null ? s.title : '';
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // MARK: 设备

  /**
   * 拉设备列表。`silent = true`（轮询 / 下拉刷新）时不切加载态——
   * 否则每 15 秒整页会闪一下「正在加载设备…」（用户报的「页面时不时闪一下」就是它）。
   */
  private async loadDevices(silent: boolean = false): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    if (!silent) {
      this.loading = true;
    }
    try {
      // 超管可以看全部成员的设备（iOS 的 showAll）
      this.devices = await api.authDevicesList(this.showAll && this.isAdmin() ? true : undefined);
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  private isAdmin(): boolean {
    return Permissions.fromSession(this.model.session).isAdmin;
  }

  private deviceName(device: LoginDeviceView): string {
    return device.name.length > 0 ? device.name : device.kind_label;
  }

  /** 当前这台（iOS：主页单独列「当前设备」一行，点进详情） */
  private currentDevice(): LoginDeviceView | null {
    for (const device of this.devices) {
      if (device.current) {
        return device;
      }
    }
    return null;
  }

  /** 一组里此刻在线的台数 */
  private onlineCount(group: DeviceGroupDef): number {
    let count: number = 0;
    for (const device of group.items) {
      if (DeviceText.isLive(device)) {
        count++;
      }
    }
    return count;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        PageTopBar({ title: this.sectionTitle(), onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.sectionId === 'devices') {
          this.DevicesBody()
        } else if (this.sectionId === 'playback') {
          PlaybackSection()
        } else if (this.sectionId === 'scrape') {
          ScrapeSection()
        } else if (this.sectionId === 'mcp') {
          McpSection()
        } else if (this.sectionId === 'app') {
          AppMaintenanceSection()
        } else if (this.sectionId === 'network') {
          NetworkSection({ navStack: this.navStack })
        } else if (this.sectionId === 'im-push') {
          PushSection()
        } else if (this.sectionId === 'webhook') {
          WebhookSection()
        } else if (this.sectionId === 'llm') {
          LlmProvidersSection()
        } else if (this.sectionId === 'ai') {
          AiDefaultsSection()
        } else if (this.sectionId === 'members') {
          MembersSection()
        } else if (this.sectionId === 'logs') {
          // 日志查看器自成一屏（工具栏 + 窗口 + 说明），不需要外面再包一层滚动
          LogsSection()
        } else {
          this.NotBuiltBody()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
      .bindSheet($$this.showDeviceSheet, this.DeviceSheet(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: Theme.bg
      })
      // 批准设备登录不再挂在页面上：它是**原生命令式弹窗**（`openApproval()` 拉起，
      // 见 `DeviceApprovalDialog`），所以这里只有清理设备的 sheet 绑定。
    }
    // iOS `SettingsSectionView` 用 `.navigationTitle(section.title)` + inline：返回按钮 + 居中分区标题。
    // 自绘顶栏（原生标题栏在沉浸式布局下会画进状态栏）。
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: SectionParams | null = SectionParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.sectionId = params.sectionId;
        if (this.sectionId === 'devices') {
          this.loadDevices();
          this.startPolling();
          this.loadExternalUrl();
        }
      }
    })
  }

  // MARK: 设备分组行（对应 iOS `deviceSections`：主页只列「当前设备」+ 四个固定分组行）

  /** 当前设备一行（iOS：主页单独一区，点进详情） */
  @Builder
  CurrentDeviceSection() {
    if (this.currentDevice() !== null) {
      Column({ space: 6 }) {
        Text('当前设备')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 4 })
        this.CurrentDeviceRow(this.currentDevice())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  CurrentDeviceRow(device: LoginDeviceView | null) {
    if (device !== null) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          SymbolGlyph(DeviceText.symbolOf(device.kind, device.scope))
            .fontSize(20)
            .fontColor([Theme.accent])
          Circle()
            .width(7)
            .height(7)
            .fill(Theme.ok)
            .border({ width: 1.5, color: Theme.surface })
        }
        .width(28)
        .alignSelf(ItemAlign.Center)

        Column({ space: 3 }) {
          Text(this.deviceName(device))
            .fontSize(15)
            .fontColor(Theme.text)
            .width('100%')
          Text('本机 · 正在使用')
            .fontSize(12)
            .fontColor(Theme.ok)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .padding(16)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
      .onClick((): void => {
        this.navStack.pushPathByName('deviceDetail', new DetailParams(device.id, this.showAll));
      })
    }
  }

  /** 一个分组行：图标 + 标题 + N 台设备 · N 在线 + chevron（空组也占一行，同 iOS） */
  @Builder
  GroupRow(group: DeviceGroupDef) {
    Row({ space: 12 }) {
      SymbolGlyph(group.symbol)
        .fontSize(20)
        .fontColor([Theme.textMuted])
        .width(28)
      Column({ space: 4 }) {
        Text(group.title)
          .fontSize(15)
          .fontColor(Theme.text)
          .width('100%')
        Row({ space: 8 }) {
          Text(`${group.items.length} 台设备`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
          Row({ space: 5 }) {
            if (this.onlineCount(group) > 0) {
              Circle().width(6).height(6).fill(Theme.ok)
            }
            Text(`${this.onlineCount(group)} 在线`)
              .fontSize(12)
              .fontColor(this.onlineCount(group) > 0 ? Theme.ok : Theme.textFaint)
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .onClick((): void => {
      this.navStack.pushPathByName('deviceGroup', new GroupListParams(group.id, this.showAll));
    })
  }

  /** 页面弹层内容：清理 */
  @Builder
  DeviceSheet() {
    this.CleanupSheet()
  }

  /** 清理长期没用的设备（对应 iOS `DeviceCleanupSheet`）：先 dry-run 列清单，确认后才真清 */
  @Builder
  CleanupSheet() {
    Column({ space: 14 }) {
      Text('清理长期没用的设备')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16 })
      Text(`注销超过 ${Math.round(this.cleanupDays)} 天没用过的设备；本机与还连着的转码器不会被清。`)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
      Slider({
        value: this.cleanupDays,
        min: 7,
        max: 365,
        step: 1,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .selectedColor(Theme.accent)
        .onChange((value: number, mode: SliderChangeMode): void => {
          this.cleanupDays = value;
          if (mode === SliderChangeMode.End) {
            this.previewCleanup();
          }
        })
      Row() {
        Text('7 天').fontSize(11).fontColor(Theme.textFaint)
        Blank()
        Text('365 天').fontSize(11).fontColor(Theme.textFaint)
      }
      .width('100%')

      if (this.cleanupBusy) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16).color(Theme.textFaint)
          Text('正在算…').fontSize(13).fontColor(Theme.textFaint)
        }
      } else if (this.cleanupPreview.length === 0) {
        Text('没有符合条件、可以清理的设备。')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .width('100%')
      } else {
        Text(`将注销 ${this.cleanupPreview.length} 台：`)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
        Column({ space: 4 }) {
          ForEach(this.cleanupPreview, (item: DeviceCleanupItem) => {
            Row({ space: 8 }) {
              Text(item.name)
                .fontSize(14)
                .fontColor(Theme.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (this.showAll && item.owner_nickname.length > 0) {
                Text(item.owner_nickname)
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
              }
            }
            .width('100%')
          }, (item: DeviceCleanupItem): string => `cleanup-${item.id}`)
        }
        .width('100%')
      }

      Row({ space: 10 }) {
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.text)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            this.showDeviceSheet = false;
          })
        Text(this.cleanupBusy ? '…' : '清理')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cleanupPreview.length === 0 ? Theme.textFaint : Theme.danger)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            if (!this.cleanupBusy && this.cleanupPreview.length > 0) {
              this.runCleanup();
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
    .backgroundColor(Theme.bg)
  }

  /** 手工令牌（超管）：说明 → 表单 → 一次性凭据卡（对应 iOS `manualTokenSection`） */
  @Builder
  ManualTokenSection() {
    Column({ space: 10 }) {
      Row() {
        Text('手工创建令牌')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .layoutWeight(1)
        if (this.tokenStage === 'idle') {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(12)
              .fontColor([Theme.textMuted])
            Text('创建令牌')
              .fontSize(13)
              .fontColor(Theme.textMuted)
          }
          .onClick((): void => {
            this.tokenStage = 'form';
            this.tokenName = '';
            this.tokenNameError = '';
            this.tokenScope = 'full';
          })
        }
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      Column({ space: 12 }) {
        if (this.tokenStage === 'created' && this.createdToken !== null) {
          this.TokenCreatedCard()
        } else if (this.tokenStage === 'form') {
          this.TokenForm()
        } else {
          Text('没法按下批准的环境——NAS 上的定时任务、CI、无界面容器、命令行模式的转码器——'
            + '在这里创建一枚令牌，用 MOVIECLAW_SERVER 和 MOVIECLAW_TOKEN 两个环境变量注入。'
            + '能打开浏览器的机器请直接运行 mclaw login 配对，不必走这里。')
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .width('100%')
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  TokenForm() {
    Column({ space: 10 }) {
      Text('名字')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textMuted)
        .width('100%')
      TextInput({ text: this.tokenName, placeholder: 'nas-cron' })
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .maxLength(64)
        .onChange((value: string): void => {
          this.tokenName = value;
          this.tokenNameError = '';
        })
      Text(this.tokenNameError.length > 0
        ? this.tokenNameError : '日后在上面的设备列表里就靠它认出这枚令牌、决定要不要注销。')
        .fontSize(12)
        .fontColor(this.tokenNameError.length > 0 ? Theme.danger : Theme.textFaint)
        .width('100%')

      Text('权限')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textMuted)
        .width('100%')
      SettingsTwoStateSegment({
        leftLabel: '完全权限', rightLabel: '仅限转码', leftSelected: this.tokenScope === 'full',
        onPick: (left: boolean): void => {
          this.tokenScope = left ? 'full' : 'transcode';
        }
      })

      Column({ space: 4 }) {
        Text(this.grant().title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.accent)
          .width('100%')
        Text(this.grant().body)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
      }
      .width('100%')
      .padding(12)
      .backgroundColor(Theme.accentSoft)
      .borderRadius(12)
      .border({ width: 1, color: 'rgba(205, 214, 230, 0.2)' })

      Row({ space: 10 }) {
        Text(this.tokenCreating ? '创建中…' : '创建令牌')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.tokenCreating ? Theme.textFaint : '#0b0d12')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(this.tokenCreating ? Theme.glassFill : Theme.accent)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            if (!this.tokenCreating) {
              this.createToken();
            }
          })
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.text)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            this.tokenStage = 'idle';
            this.tokenName = '';
            this.tokenScope = 'full';
            this.tokenNameError = '';
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 一次性凭据卡：明文只出现这一次，关掉要过确认 */
  @Builder
  TokenCreatedCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(16)
          .fontColor([Theme.ok])
        Column({ space: 3 }) {
          Text(`已创建「${this.createdToken !== null ? this.createdToken.name : ''}」`)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text('令牌明文只显示这一次。关掉这张卡就再也读不到，只能注销后重建。')
            .fontSize(12)
            .fontColor(Theme.warning)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Row() {
        Text(this.createdToken !== null && this.createdToken.scope === 'transcode'
          ? '填进转码器的启动参数' : '粘贴到目标环境')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMuted)
          .layoutWeight(1)
        Text('复制')
          .fontSize(13)
          .fontColor(Theme.accent)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(12)
          .onClick((): void => {
            copyPlainText(this.tokenSnippet());
            this.toast('已复制');
          })
      }
      .width('100%')

      Text(this.tokenSnippet())
        .fontSize(12)
        .fontFamily('monospace')
        .fontColor(Theme.text)
        .copyOption(CopyOptions.InApp)
        .width('100%')
        .padding(12)
        .backgroundColor('rgba(0, 0, 0, 0.28)')
        .borderRadius(12)
        .border({ width: 1, color: Theme.line })

      if (this.createdToken !== null && this.createdToken.scope === 'transcode') {
        Text('接在 movieclaw-transcoder --headless 后面即可，--worker-id、--ffmpeg 等其余参数照常。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
      if (this.externalUrl.trim().length > 0) {
        Text('地址取自「设置 → 网络」里填写的对外访问地址。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      } else {
        Text('上面这行地址取自 App 当前连接的服务器地址，只是猜测——目标机器不一定连得到。'
          + '请到「设置 → 网络」填写对外访问地址，之后这里会直接给出正确的一行。')
          .fontSize(12)
          .fontColor(Theme.warning)
          .width('100%')
      }

      Row({ space: 10 }) {
        Text('仅复制令牌')
          .fontSize(14)
          .fontColor(Theme.text)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 12, bottom: 12 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            if (this.createdToken !== null) {
              copyPlainText(this.createdToken.token);
              this.toast('已复制令牌');
            }
          })
        Text('我已保存，关闭')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 12, bottom: 12 })
          .backgroundColor(Theme.accent)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            this.dismissCreatedToken();
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 拉起原生弹窗：底部对齐（卡片贴底）、宽度随屏幕、输入法避让、点遮罩可关 */
  private openApproval(): void {
    // 宽度自适应：占满屏宽、左右各留 16vp（同 iOS 卡片 12pt 外边距的手感），不写死数字
    const screenWidthVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    const options: promptAction.CustomDialogOptions = {
      builder: (): void => {
        this.ApprovalCard();
      },
      width: Math.round(screenWidthVp - 32),
      alignment: DialogAlignment.Bottom,
      // 弹窗自带的输入法避让（全局枚举只有 DEFAULT / NONE；DEFAULT = 跟着键盘让位）
      keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
      autoCancel: true,
      maskColor: 'rgba(0,0,0,0.6)',
      backgroundColor: Theme.surfaceRaised,
      cornerRadius: Theme.cardRadius
    };
    this.getUIContext().getPromptAction().openCustomDialog(options)
      .then((id: number): void => {
        this.approvalDialogId = id;
      })
      .catch((): void => {
        this.approvalDialogId = -1;
      });
  }

  /** 关闭原生弹窗（卡片里的「取消 / 完成」走这里） */
  private closeApproval(): void {
    if (this.approvalDialogId < 0) {
      return;
    }
    this.getUIContext().getPromptAction().closeCustomDialog(this.approvalDialogId);
    this.approvalDialogId = -1;
  }

  /** 弹窗内容 */
  @Builder
  ApprovalCard() {
    DeviceApprovalDialog({
      onClose: (): void => {
        this.closeApproval();
      }
    })
  }

  /** 有没有「不是本机」的设备可清（只有本机一台时这个入口不出现，同 iOS） */
  private hasCleanableDevices(): boolean {
    for (const device of this.devices) {
      if (!device.current) {
        return true;
      }
    }
    return false;
  }

  private async loadExternalUrl(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || !this.isAdmin()) {
      return;
    }
    try {
      const config: AppConfigView = await api.appShow();
      this.externalUrl = config.external_url;
    } catch (error) {
      this.externalUrl = '';
    }
  }

  // MARK: 清理长期没用的设备

  private async previewCleanup(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.cleanupBusy = true;
    try {
      const body: DeviceCleanupRequest = {
        inactive_days: this.cleanupDays,
        all: this.showAll && this.isAdmin() ? true : null,
        dry_run: true
      };
      const view: DeviceCleanupView = await api.authDevicesCleanup(body);
      this.cleanupPreview = view.devices;
    } catch (error) {
      this.toast(this.messageOf(error));
      this.cleanupPreview = [];
    } finally {
      this.cleanupBusy = false;
    }
  }

  private async runCleanup(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.cleanupBusy = true;
    // 服务端已下线全局批量注销：同 iOS，确认后再做一次 dry_run 预览，
    // 逐台调单个注销接口；中途失败保留已完成台数
    let completed: number = 0;
    const confirmed: Set<string> = new Set<string>();
    for (const item of this.cleanupPreview) {
      confirmed.add(item.id);
    }
    try {
      const body: DeviceCleanupRequest = {
        inactive_days: this.cleanupDays,
        all: this.showAll && this.isAdmin() ? true : null,
        dry_run: true
      };
      const fresh: DeviceCleanupView = await api.authDevicesCleanup(body);
      for (const item of fresh.devices) {
        if (confirmed.has(item.id)) {
          await api.authDevicesRevoke(item.id);
          completed++;
        }
      }
      this.showDeviceSheet = false;
      this.toast(completed === 0 ? '没有仍需清理的设备' : `已清理 ${completed} 台设备`);
      await this.loadDevices();
    } catch (error) {
      if (completed > 0) {
        this.toast(`已清理 ${completed} 台，其余未完成：${this.messageOf(error)}`);
        await this.loadDevices();
      } else {
        this.toast(this.messageOf(error));
      }
    } finally {
      this.cleanupBusy = false;
    }
  }

  // MARK: 手工令牌

  private scopeLabel(): string {
    return this.tokenScope === 'transcode' ? '仅限转码' : '完全权限';
  }

  private grant(): GrantText {
    return this.tokenScope === 'transcode' ? DeviceText.transcodeManualGrant : DeviceText.manualGrant;
  }

  /** 注入地址：优先「对外访问地址」，没配就回落当前服务器并说破（同 iOS `serverAddress`） */
  private serverAddress(): string {
    let configured: string = this.externalUrl.trim();
    while (configured.endsWith('/')) {
      configured = configured.substring(0, configured.length - 1);
    }
    if (configured.length > 0) {
      return configured;
    }
    const client = AppModel.shared.client;
    let origin: string = client !== null ? client.origin : '';
    while (origin.endsWith('/')) {
      origin = origin.substring(0, origin.length - 1);
    }
    return origin;
  }

  private tokenSnippet(): string {
    const token: ApiTokenCreatedView | null = this.createdToken;
    if (token === null) {
      return '';
    }
    if (token.scope === 'transcode') {
      return `--nas-url ${this.serverAddress()} --token ${token.token}`;
    }
    return `MOVIECLAW_SERVER=${this.serverAddress()}\nMOVIECLAW_TOKEN=${token.token}`;
  }

  private async createToken(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const name: string = this.tokenName.trim();
    if (name.length === 0) {
      this.tokenNameError = '先给它起个名字，否则日后没法在列表里认出是哪台机器。';
      return;
    }
    this.tokenCreating = true;
    try {
      this.createdToken = await api.authTokensCreate({ name: name, scope: this.tokenScope });
      this.tokenStage = 'created';
      this.tokenName = '';
      this.tokenNameError = '';
      await this.loadDevices();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.tokenCreating = false;
    }
  }

  /** 关掉一次性凭据卡要过确认：明文关掉就再也读不到 */
  private dismissCreatedToken(): void {
    this.getUIContext().showAlertDialog({
      title: '关闭后就看不到这枚令牌了？',
      message: '令牌明文只显示这一次。确认你已经把它存进目标机器，或者复制到了安全的地方。',
      primaryButton: {
        value: '我已保存',
        action: (): void => {
          this.createdToken = null;
          this.tokenStage = 'idle';
          this.tokenScope = 'full';
        }
      },
      secondaryButton: {
        value: '再看看',
        action: (): void => {
        }
      }
    });
  }

  @Builder
  DevicesBody() {
    if (this.loading) {
      Column({ space: 10 }) {
        LoadingProgress().width(26).height(26).color(Theme.textMuted)
        Text('正在加载设备…').fontSize(14).fontColor(Theme.textMuted)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      Refresh({ refreshing: $$this.refreshing }) {
        Scroll() {
          Column({ space: 16 }) {
            if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .fontSize(13)
              .fontColor(Theme.danger)
              .width('100%')
          }
          // 批准新设备登录（对应 iOS 的 approvalEntry；批准本身在独立弹窗里做）
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.qrcode'))
              .fontSize(18)
              .fontColor([Theme.accent])
              .width(24)
            Column({ space: 2 }) {
              Text('批准新设备登录')
                .fontSize(15)
                .fontColor(Theme.text)
                .width('100%')
                .textAlign(TextAlign.Start)
              Text('扫码或输入 Apple TV、Mac、命令行、转码器上的配对码')
                .fontSize(12)
                .fontColor(Theme.textMuted)
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(14)
              .fontColor([Theme.textFaint])
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
          .onClick(() => {
            this.openApproval();
          })

          // 范围：原生分段（两个 Toggle.Button），同 iOS 的 segmented picker
          if (this.isAdmin()) {
            Row() {
              SettingsSegmentChip({
                label: '我的设备',
                selected: !this.showAll,
                onPick: (): void => {
                  if (this.showAll) {
                    this.showAll = false;
                    this.loadDevices();
                  }
                }
              })
              SettingsSegmentChip({
                label: '全部成员',
                selected: this.showAll,
                onPick: (): void => {
                  if (!this.showAll) {
                    this.showAll = true;
                    this.loadDevices();
                  }
                }
              })
            }
            .width('100%')
            .padding(3)
            .backgroundColor(Theme.glassFill)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
          }

          // 设备分组（对应 iOS `deviceSections`）：当前设备一行 + 四个固定分组行，
          // 点分组进列表页（DeviceGroupPages），空组也占一行
          Text(this.showAll ? '全部成员的设备' : '我的设备')
            .fontSize(13)
            .fontColor(Theme.textFaint)
            .width('100%')
            .padding({ left: 4 })

          this.CurrentDeviceSection()

          ForEach(DeviceGroupDef.make(this.devices), (group: DeviceGroupDef) => {
            this.GroupRow(group)
          }, (group: DeviceGroupDef): string => group.id)

          Text('包含在线和离线设备。点按设备可查看详情、改名或注销。')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
            .padding({ left: 4 })

          // 清理长期没用的设备（只有本机一台时不出现，同 iOS）
          if (this.hasCleanableDevices()) {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.wand_and_stars'))
                .fontSize(16)
                .fontColor([Theme.textMuted])
                .width(36)
              Text(this.showAll ? '清理全部成员长期没用的设备' : '清理长期没用的设备')
                .fontSize(15)
                .fontColor(Theme.text)
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14)
                .fontColor([Theme.textFaint])
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: Theme.line })
            .onClick((): void => {
              this.sheetKind = 'cleanup';
              this.showDeviceSheet = true;
              this.cleanupPreview = [];
              this.previewCleanup();
            })
          }

          if (this.isAdmin()) {
            this.ManualTokenSection()
          }

          Text('注销即断：它正在播的片、正在跑的转码会一并停止。这是唯一的事后止损手段。')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: Theme.tabBarInset })
      }
        .layoutWeight(1)
        // 通用属性 `align` 默认是 Center：内容比视口矮时整块会垂直居中（成员页曾因此居中显示），
        // 页面级滚动区一律显式顶对齐
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .layoutWeight(1)
      .onRefreshing((): void => {
        // 下拉刷新：静默重拉（不切加载态），完成后收起
        this.loadDevices(true).then((): void => {
          this.refreshing = false;
        }).catch((): void => {
          this.refreshing = false;
        });
      })
    }
  }

  // MARK: 未做的分区

  /**
   * 还没做的分区：**说清楚是「鸿蒙端还没做」，不假装已经支持**。
   * iOS 那边这个位置是给「App 不提供的分区」用的（`availableInApp == false`），
   * 措辞不同：它说「请在网页端管理」，这里说实话。
   */
  @Builder
  NotBuiltBody() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(30)
        .fontColor([Theme.textFaint])
      Text('这一分区鸿蒙端还在做')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(this.section() !== null ? (this.section() as SettingsSection).subtitle : '')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Text('先用网页端管理这一区，改动会同步过来。')
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }
}
