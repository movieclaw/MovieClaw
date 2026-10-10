import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppModel } from '../common/AppModel';
import { TokenVault } from '../common/TokenVault';
import { SavedServers } from '../common/SavedServers';
import { WindowInsets } from '../common/WindowInsets';
import { ShareRouter, slugFromWantUri } from '../common/ShareLinks';
import { ShareLocalProgress } from '../share/ShareProgress';
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
    // 分享访客的本机续播进度（独立偏好文件）
    ShareLocalProgress.init(this.context);
    this.captureShareLink(want);
    hilog.info(DOMAIN, 'MovieClaw', '%{public}s', 'Ability onCreate');
  }

  /** App 已在跑时又点了一条分享链接（深链 / 二维码） */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.captureShareLink(want);
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

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'MovieClaw', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'MovieClaw', '%{public}s', 'Succeeded in loading the content.');
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
       * - 顶部：五个页签的 NavHost 各自处理（媒体库/活动/我的 `padding(WindowInsets.top)`
       *   推回安全区；订阅/发现故意顶进状态栏，配自绘毛玻璃标题栏）。
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

  /** 把状态栏 / 底部导航条的高度换算成 vp 记下来，供页面留白 */
  private static publishInsets(mainWindow: window.Window): void {
    try {
      const status: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      WindowInsets.top = px2vp(status.topRect.height);
      const indicator: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      WindowInsets.bottom = px2vp(indicator.bottomRect.height);
      hilog.info(DOMAIN, 'MovieClaw', '避让区 top=%{public}d bottom=%{public}d',
        WindowInsets.top, WindowInsets.bottom);
    } catch (error) {
      hilog.warn(DOMAIN, 'MovieClaw', '读避让区失败：%{public}s', `${error}`);
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}