import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { AppNavBar, AppNavTitleBar } from '../common/AppNavBar';
import { Permissions } from '../common/Permissions';
import { AppModel } from '../common/AppModel';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { LibraryHomeView } from './LibraryHomeView';
import { ReelsParams } from '../reels/ReelsPage';
import { ManageParams } from './LibraryManagePage';

/**
 * 媒体库页签的导航宿主（对应 iOS 端 NavigationStack + 系统导航栏）。
 *
 * **用 UIDesignKit 的 `HdsNavigation`（华为官方组件）**，标题栏走官方 `titleBar` 体系：
 * - `ScrollEffectType.GRADIENT_BLUR`：官方「滚动渐变模糊」——静止时标题栏融入内容
 *   （海报大图透出），滚动后渐显毛玻璃（华为自家应用的标准行为）；
 * - `BlurStrategy.ENABLE`：标题栏背景模糊（系统实现，模拟器/真机一致）；
 * - 菜单行用 `stackBuilder`（官方提供的标题栏内容扩展点）：⋯ · 搜索 · 片段 的
 *   自定义胶囊（bindMenu 下拉）原样迁入，标题栏背景/布局仍由官方渲染。
 *
 * 右上角三个动作的顺序照 iOS 的工具栏排布：**⋯ · 搜索 · 片段**
 * （片段是媒体库顶部的主操作，放最右；⋯ 是低频配置入口，放最里）。
 *
 * 子页面用系统路由表（router_map.json）按名字 push——单库页 libraryDetail、
 * 全部合集 allCollections、条目页 libraryItem、搜索 search。
 */
@Component
export struct LibraryNavHost {
  private navStack: NavPathStack = new NavPathStack();
  /** 首页 List 的滚动器：标题栏的渐变模糊 / 滑动显隐都靠它驱动（文档 bindToScrollable） */
  private scroller: Scroller = new Scroller();
  /** 每次「自定义首页」加一；LibraryHomeView 用 @Watch 接住（菜单与弹层不在同一层） */
  @State private customizeSignal: number = 0;

  aboutToAppear(): void {
    // 把本页签的栈登记进注册表（深链访客页要推到当前页签的栈上）
    NavStacks.register('媒体库', this.navStack);
    // 冷启动就带着分享链接：本页签是首个建起来的，直接消费
    const slug: string = ShareRouter.shared().takePending();
    if (slug.length > 0) {
      this.navStack.pushPathByName('sharePage', new SharePageParams(slug));
    }
  }

  build() {
    HdsNavigation(this.navStack) {
      LibraryHomeView({
        navStack: this.navStack,
        customizeSignal: this.customizeSignal,
        scroller: this.scroller
      })
    }
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    // 根页没有可返回的上层：别显示那个空的返回键圆圈
    .hideBackButton(true)
    // 沉浸：内容从 y=0 铺起，标题栏浮在上面（样式与其余页签同一份，见 common/AppNavBar）
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
    /*
     * 窗口是全屏布局（见 MainTabsPage）：官方标题栏自带状态栏避让（titleBar 从 y=0
     * 铺起、标题行让开状态栏图标）。标题栏同时是组件级安全区，页面内容由系统排在
     * 标题栏下方——页面不要再自己加顶部留白，否则标题栏与第一行之间会多一条空带。
     */
  }

  /** 标题栏内容行（stackBuilder 扩展点）：标题 + ⋯ · 搜索 · 片段（顺序同 iOS 工具栏） */
  @Builder
  TitleRow() {
    AppNavTitleBar({ title: '媒体库' }) {
      this.TopMenus()
    }
  }

  /** 右上角动作：⋯ · 搜索 · 片段（顺序同 iOS 工具栏） */
  @Builder
  TopMenus() {
    Row({ space: 2 }) {
      SymbolGlyph($r('sys.symbol.more'))
        .fontSize(22)
        .fontColor([Theme.textMuted])
        .width(36)
        .height(36)
        .bindMenu(this.MoreMenu())
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(22)
        .fontColor([Theme.textMuted])
        .width(36)
        .height(36)
        .onClick(() => {
          this.navStack.pushPathByName('search', null);
        })
      Button() {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.play_circle'))
            .fontSize(16)
            .fontColor([Theme.textMuted])
          Text('片段')
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      }
      .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
      .padding(0)
      .clip(true)
      .borderRadius(17)
      .margin({ left: 4 })
      .onClick(() => {
        this.navStack.pushPathByName('reels', new ReelsParams(0));
      })
    }
  }

  /** ⋯ 菜单：低频配置入口（自定义首页 / 全部合集 / 管理媒体库），同 iOS */
  @Builder
  MoreMenu() {
    Menu() {
      MenuItem({ content: '自定义首页', startIcon: $r('sys.symbol.slider_horizontal_2') })
        .onClick(() => {
          this.customizeSignal = this.customizeSignal + 1;
        })
      MenuItem({ content: '全部合集', startIcon: $r('sys.symbol.rectangle_stack') })
        .onClick(() => {
          this.navStack.pushPathByName('allCollections', null);
        })
      if (Permissions.fromSession(AppModel.shared.session).canManageLibraries) {
        MenuItem({ content: '管理媒体库', startIcon: $r('sys.symbol.externaldrive') })
          .onClick(() => {
            this.navStack.pushPathByName('manage', new ManageParams(''));
          })
      }
    }
  }
}
