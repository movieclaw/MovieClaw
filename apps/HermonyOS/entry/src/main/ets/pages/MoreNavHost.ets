import { Permissions } from '../common/Permissions';
import { Theme } from '../theme/AppTheme';
import { WindowInsets } from '../common/WindowInsets';
import { AppModel } from '../common/AppModel';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { MorePage } from './MorePage';

/**
 * 「更多」页签的导航宿主：Navigation 本体承载「我的」页，
 * 子页面（个人信息 profile、将来的设置分区）用系统路由表按名字 push。
 * 与媒体库/发现/订阅三个页签保持一致的结构。
 */
@Component
export struct MoreNavHost {
  private navStack: NavPathStack = new NavPathStack();
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
    Navigation(this.navStack) {
      MorePage({ navStack: this.navStack, scanSignal: this.scanSignal })
    }
    .mode(NavigationMode.Stack)
    // 原生标题栏（华为组件，不自绘）：Mini = 常规字号；根页无返回键。
    // 标题栏底色显式接 App 纯黑：系统默认是暗灰，状态栏区域会露出一条割裂的灰带。
    .title('我的', { backgroundColor: Theme.bg })
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(true)
    .menus(this.TopMenus())
    .hideTitleBar(false)
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    // HdsTabs 已整体顶进状态栏：推回安全区（几何同之前），padding 区由上面的纯黑铺满
    .padding({ top: WindowInsets.top })
  }

  /** 右上角动作（原生工具栏）：扫码 / 搜索 胶囊（同 iOS） */
  @Builder
  TopMenus() {
    Row({ space: 3 }) {
      SymbolGlyph($r('sys.symbol.qrcode'))
        .fontSize(20)
        .fontColor([Theme.textMuted])
        .width(36)
        .height(36)
        .onClick(() => {
          this.scanSignal = this.scanSignal + 1;
        })
      if (this.showSearch()) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(20)
          .fontColor([Theme.textMuted])
          .width(36)
          .height(36)
          .onClick(() => {
            this.navStack.pushPathByName('search', null);
          })
      }
    }
    .padding(3)
    .backgroundColor(Theme.glassFill)
    .borderRadius(20)
    .border({ width: 1, color: Theme.line })
  }

  private showSearch(): boolean {
    const permissions: Permissions = Permissions.fromSession(AppModel.shared.session);
    return permissions.isAdmin || permissions.canSearch || permissions.canDirectDownload;
  }
}
