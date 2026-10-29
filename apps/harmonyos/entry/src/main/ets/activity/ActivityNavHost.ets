import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { Theme } from '../theme/AppTheme';
import { AppNavBar, AppNavTitleBar } from '../common/AppNavBar';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { ActivityPage } from './ActivityPage';

/**
 * 活动页签的导航宿主（对应 iOS 端 NavigationStack）。
 *
 * 标题栏与其余页签共用 `common/AppNavBar`（版式、模糊、安全区只有一处实现）；
 * 活动页的实时摘要行是 `ActivityPage.TitleBar` 自绘的（对应 iOS `activity-summary`）；
 * 二级页（进行中/已结束、最近播放、观看统计）走系统路由表按名字 push。
 */
@Component
export struct ActivityNavHost {
  private navStack: NavPathStack = new NavPathStack();
  /** 活动页内容滚动器：标题栏的渐变模糊 / 滑动显隐靠它驱动（文档 bindToScrollable） */
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    // 登记本页签的栈；顺带消费冷启动时积压的分享深链（首个建起来的页签接走）
    NavStacks.register('活动', this.navStack);
    const slug: string = ShareRouter.shared().takePending();
    if (slug.length > 0) {
      this.navStack.pushPathByName('sharePage', new SharePageParams(slug));
    }
  }

  build() {
    HdsNavigation(this.navStack) {
      ActivityPage({ navStack: this.navStack, scroller: this.scroller })
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
        }
      },
      style: AppNavBar.style()
    })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 标题栏内容行：与其余页签同一份版式（common/AppNavBar） */
  @Builder
  TitleRow() {
    AppNavTitleBar({ title: '活动' })
  }
}
