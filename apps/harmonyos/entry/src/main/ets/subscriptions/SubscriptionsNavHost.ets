import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { Theme } from '../theme/AppTheme';
import { AppNavBar, AppNavTitleBar } from '../common/AppNavBar';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { SubscriptionsPage } from './SubscriptionsPage';

/**
 * 订阅页签的导航宿主（对应 iOS 端订阅页所在的 NavigationStack）。
 *
 * **用 UIDesignKit 的 `HdsNavigation`（华为官方组件）**，沉浸式 Hero 与标题栏全走官方体系：
 * - `ignoreLayoutSafeArea(SYSTEM, TOP)`：官方 Navigation 级安全区 API——内容延伸进
 *   顶部安全区，顶部轮播从屏幕最顶端钻到状态栏底下（替代旧的「首页外置 Navigation」
 *   结构；当年外置是因为 TabContent 子孙的 expandSafeArea 无效，Navigation 级的
 *   ignoreLayoutSafeArea 正是官方解法）；
 * - `titleBar` 官方滚动渐变模糊（GRADIENT_BLUR）：静止时标题栏透明（Hero 透出）、
 *   滚动后渐显毛玻璃——比自绘 FrostedBar 更标准的华为行为；
 * - 压栈时官方组件自动收起首页标题栏，由二级页自己的标题栏接管。
 *
 * 二级页（订阅详情、海报墙…）走 router_map.json 按名字 push。
 */
@Component
export struct SubscriptionsNavHost {
  private navStack: NavPathStack = new NavPathStack();
  /** 订阅首页内容滚动器：标题栏的渐变模糊 / 滑动显隐靠它驱动（文档 bindToScrollable） */
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    // 登记本页签的栈；顺带消费冷启动时积压的分享深链（首个建起来的页签接走）
    NavStacks.register('订阅', this.navStack);
    const slug: string = ShareRouter.shared().takePending();
    if (slug.length > 0) {
      this.navStack.pushPathByName('sharePage', new SharePageParams(slug));
    }
  }

  build() {
    HdsNavigation(this.navStack) {
      SubscriptionsPage({ navStack: this.navStack, scroller: this.scroller })
    }
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    // 文档要求：绑内容区滚动器 → 渐变模糊/滑动显隐才真正跟着滚
    .bindToScrollable([this.scroller])
    .dynamicHideTitleBar(AppNavBar.dynamicHide())
    /*
     * 官方安全区 API：内容延伸进顶部系统安全区——Hero 从 y=0 铺起钻进状态栏底下。
     * 全屏布局窗口下系统不做避让，这里显式声明忽略，标题栏自己避让（titleBar 开关）。
     */
    .ignoreLayoutSafeArea(AppNavBar.SAFE_AREA_TYPES, AppNavBar.SAFE_AREA_EDGES)
    .titleBar({
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
    AppNavTitleBar({ title: '订阅' })
  }
}
