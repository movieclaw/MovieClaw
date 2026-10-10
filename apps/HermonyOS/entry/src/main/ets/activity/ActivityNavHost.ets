import { Theme } from '../theme/AppTheme';
import { WindowInsets } from '../common/WindowInsets';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { ActivityPage } from './ActivityPage';

/**
 * 活动页签的导航宿主（对应 iOS 端 NavigationStack）。
 *
 * 活动页的大标题 + 实时摘要行是自绘的（`ActivityPage.TitleBar`，对应 iOS
 * `activity-summary`），所以这里把系统标题栏藏掉，只借 `Navigation` 的路由栈；
 * 二级页（进行中/已结束、最近播放、观看统计）走系统路由表按名字 push。
 */
@Component
export struct ActivityNavHost {
  private navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    // 登记本页签的栈；顺带消费冷启动时积压的分享深链（首个建起来的页签接走）
    NavStacks.register('活动', this.navStack);
    const slug: string = ShareRouter.shared().takePending();
    if (slug.length > 0) {
      this.navStack.pushPathByName('sharePage', new SharePageParams(slug));
    }
  }

  build() {
    Navigation(this.navStack) {
      ActivityPage({ navStack: this.navStack })
    }
    .mode(NavigationMode.Stack)
    // 原生标题栏（华为组件，不自绘）：Mini = 常规字号；根页无返回键。
    // 标题栏底色显式接 App 纯黑：系统默认是暗灰，状态栏区域会露出一条割裂的灰带。
    .title('活动', { backgroundColor: Theme.bg })
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(true)
    .hideTitleBar(false)
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    // HdsTabs 已整体顶进状态栏：推回安全区（几何同之前），padding 区由上面的纯黑铺满
    .padding({ top: WindowInsets.top })
  }
}
