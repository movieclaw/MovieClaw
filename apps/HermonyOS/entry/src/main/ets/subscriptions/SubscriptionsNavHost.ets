import { Theme } from '../theme/AppTheme';
import { WindowInsets } from '../common/WindowInsets';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { SubscriptionsPage } from './SubscriptionsPage';

/**
 * 订阅页签的导航宿主（对应 iOS 端订阅页所在的 NavigationStack）。
 *
 * **沉浸式的关键结构**（MainTabsPage 已把 HdsTabs 顶进状态栏，本页签内容从 y=0 铺起）：
 * - 首页（SubscriptionsPage）**不在 Navigation 里**，直接铺满页签——顶部轮播从屏幕
 *   最顶端钻到状态栏底下。为什么必须拿出来：Navigation 一旦 padding 避让状态栏，
 *   首页也会跟着缩进安全区；而官方 FAQ 明确 TabContent 子孙的 expandSafeArea 无效。
 * - Navigation 只承载压栈的二级页（订阅详情、海报墙…走 router_map.json 按名字 push），
 *   顶部 `padding(WindowInsets.top)` 让二级页从状态栏下面开始；栈空时完全透明。
 * - 首页可见时，顶部盖一层**自绘毛玻璃标题栏**（标题「订阅」）；压栈后换成一条
 *   纯黑遮幅盖住状态栏区域，观感同系统避让。
 */
@Component
export struct SubscriptionsNavHost {
  private navStack: NavPathStack = new NavPathStack();
  /** 首页（NavBar）可见才显示毛玻璃标题栏；压栈进详情后由详情页自己的标题栏接管 */
  @State private homeVisible: boolean = true;

  aboutToAppear(): void {
    // 登记本页签的栈；顺带消费冷启动时积压的分享深链（首个建起来的页签接走）
    NavStacks.register('订阅', this.navStack);
    const slug: string = ShareRouter.shared().takePending();
    if (slug.length > 0) {
      // 冷启动直进分享页：首页不可见（onNavBarStateChange 对首帧的初始压栈可能不触发）
      this.homeVisible = false;
      this.navStack.pushPathByName('sharePage', new SharePageParams(slug));
    }
  }

  build() {
    // TopStart：浮层贴屏幕顶端（Stack 默认居中，毛玻璃会飘到屏幕中间）
    Stack({ alignContent: Alignment.TopStart }) {
      // 首页：铺满整个页签，顶部轮播钻到状态栏底下（沉浸式头图）。
      // 压栈时整页 Visibility.None：既不渲染也不进触摸测试，详情页的点击
      // 不会透过路由层漏到首页（Transparent 不阻断兄弟节点）。
      SubscriptionsPage({ navStack: this.navStack })
        .visibility(this.homeVisible ? Visibility.Visible : Visibility.None)

      // 路由栈：只承载二级页；栈空时透明，首页透出。
      // **padding 必须包在外层普通容器上**：实测加在 Navigation 本体上约束不了
      // NavDestination 的布局（二级页照样从 y=0 顶起），普通 Stack 的 padding 才可靠。
      Stack() {
        Navigation(this.navStack) {
        }
        .mode(NavigationMode.Stack)
        .hideTitleBar(true)
        .backgroundColor(Color.Transparent)
        .onNavBarStateChange((visible: boolean): void => {
          this.homeVisible = visible;
        })
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      // 二级页从状态栏下面开始（同其它页签的几何）；栈空时这层不产生任何可见物
      .padding({ top: WindowInsets.top })
      /*
       * 常驻 Transparent：本层自身与子节点都参与触摸测试，但**永不阻断**下面的
       * 首页兄弟节点——栈空时首页能正常收到点击（HitTestMode.None/Default 都会
       * 把点击吞在本层：None 只豁免节点自身，其内部 NavBar 照旧拦截；Default
       * 直接阻断。实测 Transparent 是唯一能让点击穿透满尺寸透明 Navigation 的
       * 取值）。压栈后首页 Visibility.None 退出触摸测试，本层正常独享交互。
       */
      .hitTestBehavior(HitTestMode.Transparent)

      if (!this.homeVisible) {
        // 压栈时盖住状态栏区域：底下透出的首页头图不上翻，观感同系统避让（纯黑 + 状态图标）
        Column() {
        }
        .width('100%')
        .height(WindowInsets.top)
        .backgroundColor(Theme.bg)
      }

      if (this.homeVisible) {
        this.FrostedBar()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 自绘毛玻璃标题栏：blur 背板从 y=0 铺起，标题行让开状态栏图标 */
  @Builder
  FrostedBar() {
    Column() {
      Row() {
        Text('订阅')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .margin({ left: 16 })
      }
      .width('100%')
      .height(56)
      .margin({ top: WindowInsets.top })
    }
    .width('100%')
    // 自定义模糊半径（backgroundBlurStyle 的预设最浅也有 ~15vp，这里压到 5vp）
    .backgroundEffect({ radius: 5 })
  }
}
