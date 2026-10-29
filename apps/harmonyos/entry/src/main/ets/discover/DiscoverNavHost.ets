import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { AppNavBar, AppNavTitleBar } from '../common/AppNavBar';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { DiscoverPage } from './DiscoverPage';
import { DiscoveryFilters, DiscoverFilterSheet } from './DiscoverFilter';

/**
 * 发现页签的导航宿主（对应 iOS 端发现页所在的 NavigationStack）。
 *
 * **用 UIDesignKit 的 `HdsNavigation`（华为官方组件）**，沉浸式 Hero 与标题栏全走官方体系：
 * - `ignoreLayoutSafeArea(SYSTEM, TOP)`：官方 Navigation 级安全区 API——Hero 从屏幕
 *   最顶端钻到状态栏底下（替代旧的「首页外置 Navigation」结构）；
 * - `titleBar` 官方滚动渐变模糊（GRADIENT_BLUR）：静止时标题栏透明（Hero 透出）、
 *   滚动后渐显毛玻璃；
 * - 标题行内容（动态标题「电影/剧集」+ 筛选胶囊 + 视角胶囊）经 `stackBuilder`
 *   （官方标题栏内容扩展点）迁入；版式与其余页签共用 `common/AppNavBar`。
 *
 * 二级页（影人页、片单页…）走 router_map.json 按名字 push。
 */
@ComponentV2
export struct DiscoverNavHost {
  private navStack: NavPathStack = new NavPathStack();
  /** 发现页内容滚动器：标题栏的渐变模糊 / 滑动显隐靠它驱动（文档 bindToScrollable） */
  private scroller: Scroller = new Scroller();
  /** 当前视角：标题与切换菜单的「当前」提示都读它（初始值与 DiscoverPage 的默认一致） */
  @Local private mediaType: string = 'movie';
  @Local private source: string = 'tmdb';
  /** 每次切视角换成 'movie:tmdb' 这类新值；DiscoverPage 用 @Monitor 接住（动作在页面里） */
  @Local private viewpointRequest: string = '';
  /** 组合筛选条件（共享单例，与 DiscoverPage / 筛选弹层同一份） */
  @Local private filters: DiscoveryFilters = DiscoveryFilters.shared();
  /** 顶栏「筛选」胶囊点开的大弹层 */
  @Local private showFilterSheet: boolean = false;

  aboutToAppear(): void {
    // 登记本页签的栈；顺带消费冷启动时积压的分享深链（首个建起来的页签接走）
    NavStacks.register('发现', this.navStack);
    const slug: string = ShareRouter.shared().takePending();
    if (slug.length > 0) {
      this.navStack.pushPathByName('sharePage', new SharePageParams(slug));
    }
  }

  build() {
    HdsNavigation(this.navStack) {
      DiscoverPage({
        navStack: this.navStack,
        viewpointRequest: this.viewpointRequest,
        scroller: this.scroller,
        onViewpointChange: (mediaType: string, source: string): void => {
          this.requestViewpoint(mediaType, source);
        }
      })
    }
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    // 官方安全区 API：内容延伸进顶部安全区——Hero 从 y=0 铺起钻进状态栏底下
    .ignoreLayoutSafeArea(AppNavBar.SAFE_AREA_TYPES, AppNavBar.SAFE_AREA_EDGES)
    // 文档要求：绑内容区滚动器 → 渐变模糊/滑动显隐才真正跟着滚
    .bindToScrollable([this.scroller])
    .dynamicHideTitleBar(AppNavBar.dynamicHide())
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

  /** 标题栏内容行（stackBuilder 扩展点）：动态标题 + 筛选胶囊（视角改到页内四个按钮） */
  @Builder
  TitleRow() {
    AppNavTitleBar({ title: this.mediaType === 'tv' ? '剧集' : '电影' }) {
      if (this.source === 'tmdb') {
        this.FilterCapsule()
      }
    }
  }

  /**
   * 筛选胶囊（TMDB 视角才显示；对应 iOS 顶栏的 `DiscoverFilterMenu`）：
   * 滑杆符号 + 已启用维度数的角标；点开六维筛选的大弹层，点选立即生效。
   */
  @Builder
  FilterCapsule() {
    Button() {
      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
          .fontSize(16)
          .fontColor([this.filters.activeCount() > 0 ? Theme.accent2 : Theme.textMuted])
        if (this.filters.activeCount() > 0) {
          Text(`${this.filters.activeCount()}`)
            .fontSize(13)
            .fontWeight(600)
            .fontColor(Theme.accent2)
        }
      }
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
    }
    .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
    .padding(0)
    .clip(true)
    .borderRadius(20)
    .onClick(() => {
      this.showFilterSheet = true;
    })
    .bindSheet($$this.showFilterSheet, this.FilterSheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  @Builder
  FilterSheetContent() {
    DiscoverFilterSheet({
      mediaType: this.mediaType,
      filters: this.filters,
      onClose: (): void => {
        this.showFilterSheet = false;
      }
    })
  }

  private requestViewpoint(mediaType: string, source: string): void {
    this.mediaType = mediaType;
    this.source = source;
    this.viewpointRequest = mediaType + ':' + source;
  }
}
