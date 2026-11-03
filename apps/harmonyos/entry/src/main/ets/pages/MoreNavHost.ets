import { SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationMenuItemOptions, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { Permissions } from '../common/Permissions';
import { Theme } from '../theme/AppTheme';
import { AppNavBar, AppNavTitleBar } from '../common/AppNavBar';
import { AppModel } from '../common/AppModel';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { MorePage } from './MorePage';
import { AgentQuickInput } from '../agent/AgentQuickInput';

/**
 * 「更多」页签的导航宿主：用 UIDesignKit 的 `HdsNavigation`（华为官方组件）承载
 * 「我的」页，标题栏走官方 `titleBar` 体系：`ScrollEffectType.GRADIENT_BLUR`
 * （静止融入内容、滚动渐显毛玻璃）+ `BlurStrategy.ENABLE`；扫码/搜索胶囊经
 * `stackBuilder`（官方标题栏内容扩展点）迁入。子页面（个人信息 profile、设置分区）
 * 用系统路由表按名字 push。
 */
@Component
export struct MoreNavHost {
  private navStack: NavPathStack = new NavPathStack();
  /** 「我的」页内容滚动器：标题栏的渐变模糊 / 滑动显隐靠它驱动（文档 bindToScrollable） */
  private scroller: Scroller = new Scroller();
  /** 点工具栏「扫码」时加一；MorePage 用 @Watch 接住并走批准登录流程（动作在页面里） */
  @State private scanSignal: number = 0;

  aboutToAppear(): void {
    // 登记本页签的栈；顺带消费冷启动时积压的分享深链（首个建起来的页签接走）
    NavStacks.register('我的', this.navStack);
    const slug: string = ShareRouter.shared().takePending();
    if (slug.length > 0) {
      this.navStack.pushPathByName('sharePage', new SharePageParams(slug));
    }
  }

  build() {
    // 底部叠一层管理员快捷输入（同 iOS safeAreaBar）：显隐由组件自己按
    // 管理员身份 + ShellChrome（整屏页压上来）算，这里只负责常驻挂载（草稿不丢）
    Stack({ alignContent: Alignment.Bottom }) {
      HdsNavigation(this.navStack) {
        MorePage({ navStack: this.navStack, scanSignal: this.scanSignal, scroller: this.scroller })
      }
      .mode(NavigationMode.Stack)
      .titleMode(HdsNavigationTitleMode.MINI)
      .hideBackButton(true)
      // 沉浸：内容从 y=0 铺到标题栏下面（标题栏浮在内容上）
      .ignoreLayoutSafeArea(AppNavBar.SAFE_AREA_TYPES, AppNavBar.SAFE_AREA_EDGES)
      // 文档要求：绑内容区滚动器 → 渐变模糊/滑动显隐才真正跟着滚
      .bindToScrollable([this.scroller])
      .dynamicHideTitleBar(AppNavBar.dynamicHide())
      .titleBar({
        // 全屏布局窗口下的官方安全区开关：标题栏自己撑起状态栏避让与组件安全区
        avoidLayoutSafeArea: true,
        enableComponentSafeArea: false,
        content: {
          stackBuilder: (): void => {
            this.TitleRow();
          },
          // 右上角动作交给官方标题栏菜单渲染（系统导航栏图标按钮，间距/命中区由官方负责）
          menu: {
            value: this.menuItems()
          }
        },
        style: AppNavBar.style()
      })
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
      // 全屏布局窗口：官方标题栏自带状态栏避让

      // 经典贴底栏模式的输入卡（悬浮模式隐藏，入口在页签胶囊的迷你条里）
      AgentQuickInput()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 标题栏内容行（stackBuilder 扩展点）：只画标题，右侧动作走官方 `menu` */
  @Builder
  TitleRow() {
    AppNavTitleBar({ title: '我的' })
  }

  /** 右上角动作（官方标题栏菜单项）：扫码 · 搜索 */
  private menuItems(): HdsNavigationMenuItemOptions[] {
    const items: HdsNavigationMenuItemOptions[] = [];
    const scanIcon: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.qrcode'));
    scanIcon.fontSize(22);
    scanIcon.fontColor([Theme.textMuted]);
    items.push({
      content: {
        icon: scanIcon,
        action: (): void => {
          this.scanSignal = this.scanSignal + 1;
        }
      }
    });
    if (this.showSearch()) {
      const searchIcon: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.magnifyingglass'));
      searchIcon.fontSize(22);
      searchIcon.fontColor([Theme.textMuted]);
      items.push({
        content: {
          icon: searchIcon,
          action: (): void => {
            this.navStack.pushPathByName('search', null);
          }
        }
      });
    }
    return items;
  }

  private showSearch(): boolean {
    const permissions: Permissions = Permissions.fromSession(AppModel.shared.session);
    return permissions.isAdmin || permissions.canSearch || permissions.canDirectDownload;
  }
}
