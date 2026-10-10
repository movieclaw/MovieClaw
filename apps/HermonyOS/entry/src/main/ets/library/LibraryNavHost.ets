import { Theme } from '../theme/AppTheme';
import { WindowInsets } from '../common/WindowInsets';
import { Permissions } from '../common/Permissions';
import { AppModel } from '../common/AppModel';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { LibraryHomeView } from './LibraryHomeView';
import { ReelsParams } from '../reels/ReelsPage';

/**
 * 媒体库页签的导航宿主（对应 iOS 端 NavigationStack + 系统导航栏）。
 *
 * **顶栏用 `Navigation` 的原生标题栏**，不是自绘的 Row——这是照 iOS 来的：
 * iOS 那边是 `.navigationTitle("媒体库")` + `.toolbarTitleDisplayMode(.inlineLarge)`，
 * 也就是「大标题，滚动时收缩成 inline」；鸿蒙对应的原生能力就是
 * `titleMode(NavigationTitleMode.Free)`（不滚动时 Full 高度、滚动时收到 Mini 高度）。
 *
 * 右上角三个动作的顺序也照 iOS 的工具栏排布：**⋯ · 搜索 · 片段**
 * （片段是媒体库顶部的主操作，放最右；⋯ 是低频配置入口，放最里）。
 *
 * 子页面用系统路由表（router_map.json）按名字 push——单库页 libraryDetail、
 * 全部合集 allCollections、条目页 libraryItem、搜索 search。
 */
@Component
export struct LibraryNavHost {
  private navStack: NavPathStack = new NavPathStack();
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
    Navigation(this.navStack) {
      LibraryHomeView({ navStack: this.navStack, customizeSignal: this.customizeSignal })
    }
    .mode(NavigationMode.Stack)
    // 原生标题栏（华为组件，不自绘）：`titleMode(Mini)` = 常规字号的小标题栏。
    // **不用 `Free`**：Free 的大标题栏会自己再留一份状态栏高度，实测标题被顶到距屏顶 111vp
    // （窗口已是「系统避让安全区」，等于状态栏算两遍）。
    // 标题栏底色显式接 App 纯黑：系统默认是暗灰，状态栏区域会露出一条割裂的灰带。
    .title('媒体库', { backgroundColor: Theme.bg })
    .titleMode(NavigationTitleMode.Mini)
    // 根页没有可返回的上层：别显示那个空的返回键圆圈
    .hideBackButton(true)
    .menus(this.TopMenus())
    .hideTitleBar(false)
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    /*
     * HdsTabs 已整体顶进状态栏（见 MainTabsPage），本页签不沉浸：
     * 用状态栏高度把自己推回安全区，几何与之前完全一致；
     * padding 区域由上面的 backgroundColor 铺成纯黑，状态栏底下不露灰。
     */
    .padding({ top: WindowInsets.top })
  }



  /** 右上角动作（原生工具栏菜单）：⋯ · 搜索 · 片段（顺序同 iOS 工具栏） */
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
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.play_circle'))
          .fontSize(16)
          .fontColor([Theme.textMuted])
        Text('片段')
          .fontSize(13)
          .fontColor(Theme.textMuted)
      }
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(Theme.glassFill)
      .borderRadius(17)
      .border({ width: 1, color: Theme.line })
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
            this.navStack.pushPathByName('libraryCreate', null);
          })
      }
    }
  }
}
