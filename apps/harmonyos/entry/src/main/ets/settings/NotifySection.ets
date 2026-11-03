import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { Theme } from '../theme/AppTheme';
import { AppNavBar } from '../common/AppNavBar';
import { AppFooter } from '../common/AppFooter';
import { AppModel } from '../common/AppModel';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { SettingsSwitchRow } from '../common/SettingsControls';
import { MovieClawApi } from '../api/Endpoints';
import { NotifyPrefs } from '../notify/NotifyPrefs';
import { NotifyCenter, NotifyPollResult } from '../notify/NotifyCenter';

/**
 * 设置 → 系统通知（M1 本机差分通知；对应 Android `NotifySettingsActivity` 的开关集）。
 *
 * 这里管的是**这台设备**收不收系统通知（四类开关 + 立即检查），与「消息推送」分区
 * （im-push，微信/Telegram 等服务端通道）互不相关，所以单独一区。
 *
 * - **开关都是本机偏好**（preferences），不同步服务端——每台设备自己决定；
 * - **打开主开关**先拉系统授权弹窗（每应用只弹一次），拒绝过就指路系统设置；
 * - **打开即注册** workScheduler 延迟任务（退后台每 2 小时兜底拉起），关闭即注销；
 * - **立即检查**手动跑一轮差分（验收/调试的确定性入口）：首轮只落基线，回显给用户。
 */
@ComponentV2
export struct NotifySection {
  /** 页面级滚动器：内容铺到标题栏下面，滚动时由宿主绑定驱动渐变模糊 */
  @Param scroller: Scroller = new Scroller();
  @Local private loading: boolean = true;
  /** 主开关与四类开关（@Local 原语，开关回调里先改再异步落盘）；`enabled` 与通用属性方法撞名，改名 */
  @Local private notifyOn: boolean = false;
  @Local private download: boolean = true;
  @Local private arrival: boolean = true;
  @Local private subscription: boolean = true;
  @Local private task: boolean = true;
  /** 系统层授权状态（没授权时 publish 静默无效，页面上要如实显示） */
  @Local private granted: boolean = false;
  @Local private busy: boolean = false;

  aboutToAppear(): void {
    this.refresh();
  }

  private async refresh(): Promise<void> {
    const settings = await NotifyPrefs.load();
    this.notifyOn = settings.enabled;
    this.download = settings.download;
    this.arrival = settings.arrival;
    this.subscription = settings.subscription;
    this.task = settings.task;
    this.granted = await NotifyCenter.systemEnabled();
    this.loading = false;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 主开关：开 → 先拉系统授权；没授权就如实告知并指路，开关弹回 */
  private async onMasterToggle(on: boolean): Promise<void> {
    if (on) {
      this.busy = true;
      const granted: boolean = await NotifyCenter.requestPermission();
      this.busy = false;
      if (!granted) {
        this.granted = false;
        this.getUIContext().showAlertDialog({
          title: '还收不到通知',
          message: '系统通知没有授权。请到 系统设置 → 通知 → MovieClaw 打开「允许通知」，再回来打开这个开关。',
          primaryButton: {
            value: '知道了',
            action: (): void => {
            }
          }
        });
        return;
      }
      this.granted = true;
    }
    this.notifyOn = on;
    await NotifyPrefs.setEnabled(on);
    if (on) {
      NotifyCenter.shared().scheduleBackground();
      // 开启即跑一轮：首轮只落基线、不弹（避免刚装上就被历史状态轰炸）
      this.checkNow(false);
    } else {
      NotifyCenter.shared().cancelBackground();
    }
  }

  /** 四类开关：先改本地，四个值整批落盘（偏好里就是一排独立键） */
  private async onChannelToggle(channel: string, on: boolean): Promise<void> {
    if (channel === 'download') {
      this.download = on;
    } else if (channel === 'arrival') {
      this.arrival = on;
    } else if (channel === 'subscription') {
      this.subscription = on;
    } else {
      this.task = on;
    }
    await NotifyPrefs.setChannel(this.download, this.arrival, this.subscription, this.task);
  }

  /** 立即检查：手动跑一轮差分（结果以 toast 回显；设置页开着就是前台轮询的兜底） */
  private async checkNow(silent: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      if (!silent) {
        this.toast('还没有可用的登录会话');
      }
      return;
    }
    this.busy = true;
    try {
      const result: NotifyPollResult = await NotifyCenter.shared().pollOnce(api);
      if (!silent) {
        this.toast(this.describe(result));
      }
    } catch (error) {
      if (!silent) {
        this.toast('检查失败，稍后再试');
      }
    } finally {
      this.busy = false;
    }
  }

  private describe(result: NotifyPollResult): string {
    if (result.skipped) {
      return result.skippedReason;
    }
    if (result.firstRun) {
      return '已记录当前状态；之后的变化才会提醒';
    }
    return result.posted > 0 ? `本轮发出 ${result.posted} 条通知` : '没有新的变化';
  }

  /**
   * 跳系统「应用通知设置」页：横幅通知、锁屏通知、桌面角标属系统层偏好，
   * 应用改不了（横幅默认关，须用户在系统设置里开——官方 FAQ 的推荐做法就是拉起这页）。
   */
  private openSystemPrefs(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    notificationManager.openNotificationSettings(context)
      .catch((): void => {
        this.toast('打不开系统通知设置');
      });
  }

  build() {
    Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在读取通知设置…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll(this.scroller) {
          Column({ space: 14 }) {
            this.StatusCard()
            this.SwitchesCard()
            this.SystemPrefsCard()
            this.CheckButton()
            Text('打开后：App 在前台每 10 分钟对一次账，退到后台由系统按电量与活跃度定时拉起'
              + '（活跃时最快每 2 小时一次）。只在有新变化时提醒，没变化不打扰。'
              + '开关只影响这台设备，不同步到服务器。')
              .fontSize(11)
              .fontColor(Theme.textFaint)
              .width('100%')
            AppFooter()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: AppNavBar.contentTop + 8, bottom: Theme.tabBarInset })
        }
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 授权状态卡：如实显示系统层开关（这是事实，不是本 App 能改的偏好） */
  @Builder
  StatusCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Circle()
          .width(8)
          .height(8)
          .fill(this.granted ? Theme.ok : Theme.warn)
        Text(this.granted ? '系统通知已授权' : '系统通知未授权')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
      }
      .width('100%')
      Text(this.granted
        ? '通过本 App 的通知会出现在通知中心和锁屏上，点按直达对应内容。'
        : '系统层的通知开关还关着，发了也收不到。打开下面的开关会先弹授权，'
        + '拒绝过的话请到 系统设置 → 通知 → MovieClaw 里开启。')
        .fontSize(12)
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

  /** 主开关 + 四类开关（四类在主开关关闭时禁用） */
  @Builder
  SwitchesCard() {
    Column({ space: 0 }) {
      SettingsSwitchRow({
        title: '系统通知',
        hint: '下载完成、新入库、今天有可看的、后台任务出问题时弹本机通知',
        value: this.notifyOn,
        disabled: this.busy,
        onToggle: (on: boolean): void => {
          this.onMasterToggle(on);
        }
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      SettingsSwitchRow({
        title: '下载完成', hint: '下载任务翻到「完成」或「失败」时提醒',
        value: this.download, disabled: !this.notifyOn,
        onToggle: (on: boolean): void => {
          this.onChannelToggle('download', on);
        }
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      SettingsSwitchRow({
        title: '新内容入库', hint: '订阅的剧集下载完入库时提醒',
        value: this.arrival, disabled: !this.notifyOn,
        onToggle: (on: boolean): void => {
          this.onChannelToggle('arrival', on);
        }
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      SettingsSwitchRow({
        title: '今天有可看的', hint: '订阅内容今天到期可看时提醒',
        value: this.subscription, disabled: !this.notifyOn,
        onToggle: (on: boolean): void => {
          this.onChannelToggle('subscription', on);
        }
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      SettingsSwitchRow({
        title: '后台任务', hint: '后台作业失败或需要人工处理时提醒',
        value: this.task, disabled: !this.notifyOn,
        onToggle: (on: boolean): void => {
          this.onChannelToggle('task', on);
        }
      })
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 「系统通知偏好」行：拉起系统设置里本应用的通知页（横幅/锁屏/角标在那里管） */
  @Builder
  SystemPrefsCard() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.bell_badge_local'))
        .fontSize(18)
        .fontColor([Theme.accent2])
        .width(26)
      Column({ space: 2 }) {
        Text('系统通知偏好')
          .fontSize(15)
          .fontColor(Theme.text)
        Text('横幅通知、锁屏通知、桌面角标在系统设置里管理，点这里直达')
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .onClick((): void => {
      this.openSystemPrefs();
    })
  }

  @Builder
  CheckButton() {
    Button() {
      Row({ space: 8 }) {
        if (this.busy) {
          LoadingProgress().width(16).height(16).color('#0b0d12')
        }
        Text(this.busy ? '正在检查…' : '立即检查')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
      }
      .justifyContent(FlexAlign.Center)
    }
    .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
    .width('100%')
    .padding({ top: 13, bottom: 13 })
    .borderRadius(Theme.cardRadius)
    .enabled(!this.busy)
    .onClick((): void => {
      this.checkNow(false);
    })
  }
}
