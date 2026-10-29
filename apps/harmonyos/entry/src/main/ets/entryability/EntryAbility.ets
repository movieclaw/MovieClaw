import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppModel } from '../common/AppModel';
import { TokenVault } from '../common/TokenVault';
import { SavedServers } from '../common/SavedServers';
import { AppIconStore } from '../common/AppIcon';
import { ServerRoutes } from '../common/ServerRoutes';
import { TabBarStyle } from '../common/TabBarStyle';
import { WindowInsets } from '../common/WindowInsets';
import { ShareRouter, slugFromWantUri } from '../common/ShareLinks';
import { ShareLocalProgress } from '../share/ShareProgress';
import { PlayerPrefs } from '../player/PlayerPrefs';
import { OfflineDisk } from '../offline/OfflineDisk';
import { OfflineDownloader } from '../offline/OfflineDownloader';
import { NotifyPrefs } from '../notify/NotifyPrefs';
import { NotifyCenter } from '../notify/NotifyCenter';
import { NotifyRouter } from '../notify/NotifyRouter';
import { AgentAIConsent } from '../agent/AgentAIConsent';
import { DevConfig } from '../common/DevConfig';
import { Theme } from '../theme/AppTheme';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // App 全局深色（对应 iOS/Web 的暗色基调），不跟随系统外观
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    // 会话偏好存储尽早初始化；异步加载不阻塞首帧
    AppModel.shared.initStore(this.context);
    // 多服务器 × 多账号的两块存储（对应 iOS 的 TokenVault 钥匙串 + SavedServers）：
    // 令牌进系统关键资产，服务器/账号快照进偏好。同样异步、不阻塞首帧，
    // 用到时各自 await 自己的 open 信号（见 TokenVault.init / SavedServers.init）。
    TokenVault.init(this.context);
    SavedServers.init(this.context);
    // 应用内图标选择（设置 → 图标；独立偏好文件）
    AppIconStore.init(this.context);
    // 双地址选路的上次结论（冷启动先用上次的地址，登录后 configure 再核实）
    ServerRoutes.init(this.context);
    // 底部页签栏样式：悬浮胶囊 / 经典贴底栏（设置里切换，同 movieclaw_ui 偏好文件）
    TabBarStyle.init(this.context);
    // 第一次发给 AI 前的同意记录（同 movieclaw_ui 偏好文件）
    AgentAIConsent.init(this.context);
    // 分享访客的本机续播进度（独立偏好文件）
    ShareLocalProgress.init(this.context);
    // 播放器的本机偏好：画质记忆 + 字幕样式（独立偏好文件）
    PlayerPrefs.init(this.context);
    // 离线下载的存档根目录与下载器（长时任务申请要 UIAbilityContext）
    OfflineDisk.init(this.context);
    OfflineDownloader.shared.activate(this.context);
    // 系统通知（M1 本机差分）：偏好先就位（点按参数、WorkExtension 进程都要读它），
    // NotifyCenter 记下包名（wantAgent 拉回本 Ability 用）
    NotifyPrefs.init(this.context);
    NotifyCenter.shared().init();
    this.captureShareLink(want);
    this.captureNotifyTap(want);
    hilog.info(DOMAIN, 'MovieClaw', '%{public}s', 'Ability onCreate');
  }

  /** App 已在跑时又点了一条分享链接（深链 / 二维码） */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.captureShareLink(want);
    this.captureNotifyTap(want);
  }

  /**
   * 系统通知点按进来：want 参数里带 `mcTab`（activity / subscriptions）与可选的
   * `mcRoute`（`item/{库}/{条目}` / `subscription/{订阅id}`），是 NotifyCenter 发通知时
   * 塞进 wantAgent 的。解析完交给 NotifyRouter，主界面就绪后由 MainTabsPage 消费落点。
   */
  private captureNotifyTap(want: Want): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return;
    }
    const rawTab: Object | undefined = params['mcTab'];
    if (rawTab === undefined || rawTab === null) {
      return;
    }
    const tab: string = `${rawTab}`;
    if (tab.length === 0) {
      return;
    }
    let route: string = '';
    const rawRoute: Object | undefined = params['mcRoute'];
    if (rawRoute !== undefined && rawRoute !== null) {
      route = `${rawRoute}`;
    }
    hilog.info(DOMAIN, 'MovieClaw', '通知点按 tab=%{public}s route=%{public}s', tab, route);
    NotifyRouter.shared().handOff(tab, route);
  }

  /**
   * 从 want 里认分享链接：`uri` 是 `https://host/s/{slug}`（浏览器/扫码打开），
   * 测试也可以直接塞 `parameters.shareSlug`。主界面就绪后由 MainTabsPage 消费。
   */
  private captureShareLink(want: Want): void {
    const uri: string = want.uri ?? '';
    let slug: string = uri.length > 0 ? slugFromWantUri(uri) : '';
    const params: Record<string, Object> | undefined = want.parameters;
    if (slug.length === 0 && params !== undefined) {
      const raw: Object | undefined = params['shareSlug'];
      if (raw !== undefined && raw !== null) {
        slug = `${raw}`;
      }
    }
    if (slug.length > 0) {
      hilog.info(DOMAIN, 'MovieClaw', '分享深链 slug=%{public}s', slug);
      ShareRouter.shared().handOff(slug);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 车机（car）走独立的 1260×600 vp 宽屏界面；手机/平板/PC 维持原入口。
    const isCar: boolean = deviceInfo.deviceType === 'car';
    // 智慧屏（TV）走独立的 Apple TV 风格界面；手机/平板/PC 维持原入口。
    // DevConfig.forceTvMode 供无 TV 真机时在模拟器/设备上强制走 TV 界面调试。
    const isTv: boolean = deviceInfo.deviceType === 'tv' || DevConfig.forceTvMode;
    const entryPage: string = isCar ? 'car/CarIndex' : (isTv ? 'tv/TvIndex' : 'pages/Index');
    windowStage.loadContent(entryPage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'MovieClaw', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'MovieClaw', '%{public}s', 'Succeeded in loading the content.');
      if (isCar || isTv) {
        // 车机 / TV 无状态栏/手势条避让问题，只统一窗口底色为深色
        windowStage.getMainWindow().then((mainWindow: window.Window): void => {
          mainWindow.setWindowBackgroundColor('#000000');
        }).catch((error: Object): void => {
          hilog.warn(DOMAIN, 'MovieClaw', 'Car/TV setWindowBackgroundColor 失败：%{public}s', `${error}`)
        });
        return;
      }
      EntryAbility.applyImmersiveLayout(windowStage);
    });
  }

  /**
   * 沉浸式布局：窗口铺满整屏，内容压到状态栏与底部导航条下面。
   *
   * 之前没做这一步，底部一直有一条铺不过去的黑带（系统留白）——用户明确要求去掉。
   * 代价是**系统不再替我们避让**，所以顺手把两个避让区高度记进 `WindowInsets`，
   * 页面用 `Theme.tabBarInset` 之类的地方按它留白（见 common/WindowInsets.ets）。
   */
  private static applyImmersiveLayout(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((mainWindow: window.Window): void => {
      /*
       * **窗口底色与 App 页面同色（纯黑）**：状态栏/手势条区域露出的是窗口背景，
       * 系统默认是暗灰，压在纯黑页面上就是一条割裂的灰带。
       * 拉成同色后通知栏与页面浑然一体——这就是「沉浸式通知栏」。
       */
      mainWindow.setWindowBackgroundColor(Theme.bg);
      /*
       * **窗口必须铺满整屏**（沉浸式通知栏的前提）：`expandSafeArea` 只能把组件
       * 扩进**窗口内**的避让区——`false` 时窗口内容区本身就从状态栏下面开始，
       * 状态栏区域归系统（只露窗口底色），任何组件都画不进去（实测加在页签容器、
       * HdsTabs、TabContent 子孙上统统无效）。改回 `true` 后内容区 = 全屏，
       * 避让责任回到 App 自己手里：
       *
       * - 顶部：页签内页面走 HdsNavigation 的系统 titleBar 避让，自绘顶栏的
       *   `Theme.statusBarInset` 恒 0；盖住整个窗口的页面（播放器/刷片/分享访客）
       *   没有这层避让，要按 `Theme.shellTopInset`（= `WindowInsets.top`）自己留白。
       * - 底部：MainTabsPage 根 Stack `padding(WindowInsets.bottom)` 把页签内容
       *   结束线抬回手势条上面，几何与系统避让时代完全一致。
       */
      mainWindow.setWindowLayoutFullScreen(true).then((): void => {
        /*
         * 保留最底部系统的**手势导航指示条**（那条「小白条」）。
         *
         * 华为原生应用底部都有它，属于系统观感的一部分（用户明确要它显示）。
         * 悬浮页签胶囊则按 `WindowInsets.bottom` 让开这条指示条的区域——
         * 两者各占各的位置，不互相压。
         *
         * 用 `setSpecificSystemBarEnabled` 单独控制，**不是** `setWindowSystemBarEnable([])`：
         * 后者会把状态栏一起关掉，沉浸通知栏就没了。
         */
        mainWindow.setSpecificSystemBarEnabled('navigationIndicator', true)
          .catch((error: Object): void => {
            hilog.warn(DOMAIN, 'MovieClaw',
              'setSpecificSystemBarEnabled(navigationIndicator) 失败：%{public}s', `${error}`);
          });
        /*
         * 小白条的**颜色**：系统按「导航栏内容色」来画它，默认是深色内容，
         * 压在纯黑底上就是一条暗灰（实测亮度约 39，看着像没显示）。
         * 这里声明浅色内容，它才是白色。状态栏图标同理声明白色。
         */
        mainWindow.setWindowSystemBarProperties({
          statusBarContentColor: '#FFFFFF',
          navigationBarContentColor: '#FFFFFF',
          isNavigationBarLightIcon: true
        }).catch((error: Object): void => {
          hilog.warn(DOMAIN, 'MovieClaw',
            'setWindowSystemBarProperties 失败：%{public}s', `${error}`);
        });
        EntryAbility.publishInsets(mainWindow);
      }).catch((error: Object): void => {
        hilog.warn(DOMAIN, 'MovieClaw', 'setWindowLayoutFullScreen 失败：%{public}s', `${error}`);
      });
    }).catch((error: Object): void => {
      hilog.warn(DOMAIN, 'MovieClaw', 'getMainWindow 失败：%{public}s', `${error}`);
    });
  }

  /**
   * 把状态栏 / 底部导航条 / 挖孔的尺寸换算成 vp 记下来，供页面留白；
   * 并挂 `avoidAreaChange` 监听持续刷新——转横屏（状态栏收起、挖孔转到侧面）、
   * 折叠屏展开、2in1 自由窗口都会改变避让区，只记一次静态值会过期。
   */
  private static publishInsets(mainWindow: window.Window): void {
    EntryAbility.refreshInsets(mainWindow);
    try {
      mainWindow.on('avoidAreaChange', (data: window.AvoidAreaOptions): void => {
        EntryAbility.applyAvoidArea(data.type, data.area);
      });
    } catch (error) {
      hilog.warn(DOMAIN, 'MovieClaw', '挂 avoidAreaChange 失败：%{public}s', `${error}`);
    }
  }

  private static applyAvoidArea(type: window.AvoidAreaType, area: window.AvoidArea): void {
    // 尺寸没变就不动：`avoidAreaChange` 会在滑动、下拉通知等场景反复触发，
    // 每次自增版本号会让所有 V1 页面白重建一遍。
    const insets: WindowInsets = WindowInsets.shared();
    if (type === window.AvoidAreaType.TYPE_SYSTEM) {
      const top: number = px2vp(area.topRect.height);
      if (top !== insets.top) {
        insets.top = top;
        WindowInsets.bumpRevision();
      }
    } else if (type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      const bottom: number = px2vp(area.bottomRect.height);
      if (bottom !== insets.bottom) {
        insets.bottom = bottom;
        WindowInsets.bumpRevision();
      }
    } else if (type === window.AvoidAreaType.TYPE_CUTOUT) {
      const left: number = px2vp(area.leftRect.width);
      const right: number = px2vp(area.rightRect.width);
      if (left !== insets.cutoutLeft || right !== insets.cutoutRight) {
        insets.cutoutLeft = left;
        insets.cutoutRight = right;
        WindowInsets.bumpRevision();
      }
    }
  }

  private static refreshInsets(mainWindow: window.Window): void {
    try {
      EntryAbility.applyAvoidArea(window.AvoidAreaType.TYPE_SYSTEM,
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM));
      EntryAbility.applyAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR,
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR));
      EntryAbility.applyAvoidArea(window.AvoidAreaType.TYPE_CUTOUT,
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT));
      const insets: WindowInsets = WindowInsets.shared();
      hilog.info(DOMAIN, 'MovieClaw', '避让区 top=%{public}d bottom=%{public}d cutout L/R=%{public}d/%{public}d',
        insets.top, insets.bottom, insets.cutoutLeft, insets.cutoutRight);
    } catch (error) {
      hilog.warn(DOMAIN, 'MovieClaw', '读避让区失败：%{public}s', `${error}`);
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // 回前台核实选路：网络可能换过（Wi-Fi ↔ 蜂窝 / 家 ↔ 外面）
    ServerRoutes.shared().reevaluate();
    // 回前台清桌面角标（HarmonyOS 角标要应用主动管；通知点按回来也走这里）
    NotifyCenter.clearBadge();
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}