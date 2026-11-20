import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { AppNavBar, AppNavTitleBar } from '../common/AppNavBar';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { SearchAccess } from '../search/SearchAccess';
import { DiscoverPage } from './DiscoverPage';
import { DiscoveryFilters, DiscoverFilterSheet } from './DiscoverFilter';
import { SearchMode } from '../search/SearchResultsPage';
import { SearchLaunchParams } from '../search/SearchPage';
import { SpatialMaterial } from '../common/SpatialMaterial';

/** 视角选项（四个）：类型 × 数据源；标题栏视角胶囊点开的列表选择 */
class ViewpointOption {
  readonly mediaType: string;
  readonly source: string;
  readonly label: string;

  constructor(mediaType: string, source: string, label: string) {
    this.mediaType = mediaType;
    this.source = source;
    this.label = label;
  }
}

/** 四个视角（顺序：TMDB 电影 / TMDB 剧集 / 豆瓣 电影 / 豆瓣 剧集） */
const VIEWPOINTS: ViewpointOption[] = [
  new ViewpointOption('movie', 'tmdb', 'TMDB 电影'),
  new ViewpointOption('tv', 'tmdb', 'TMDB 剧集'),
  new ViewpointOption('movie', 'douban', '豆瓣 电影'),
  new ViewpointOption('tv', 'douban', '豆瓣 剧集')
];

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
  /** 搜索入口门控（iOS `canOpenSearch`）：没有任一可用分区的账号不画放大镜；默认放行，解析后收 */
  @Local private searchGate: boolean = true;

  aboutToAppear(): void {
    // 登记本页签的栈；顺带消费冷启动时积压的分享深链（首个建起来的页签接走）
    NavStacks.register('发现', this.navStack);
    const slug: string = ShareRouter.shared().takePending();
    if (slug.length > 0) {
      this.navStack.pushPathByName('sharePage', new SharePageParams(slug));
    }
    this.refreshSearchGate();
  }

  /** 解析搜索入口门控（同 iOS MainTabView 顶栏放大镜的显隐口径） */
  private refreshSearchGate(): void {
    const permissions: Permissions = Permissions.fromSession(AppModel.shared.session);
    SearchAccess.openSearchGate(AppModel.shared.api, permissions)
      .then((open: boolean): void => { this.searchGate = open; })
      .catch((): void => { });
  }

  build() {
    HdsNavigation(this.navStack) {
      DiscoverPage({
        navStack: this.navStack,
        viewpointRequest: this.viewpointRequest,
        scroller: this.scroller
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

  /** 标题栏内容行（stackBuilder 扩展点）：动态标题 + 视角胶囊 + 筛选胶囊 + 搜索 */
  @Builder
  TitleRow() {
    AppNavTitleBar({ title: this.mediaType === 'tv' ? '剧集' : '电影' }) {
      this.ViewpointCapsule()
      if (this.source === 'tmdb') {
        this.FilterCapsule()
      }
      this.SearchButton()
    }
  }

  /**
   * 视角胶囊（标题后面，对应 iOS 的标题菜单）：显示当前数据源 + 下箭头，
   * 点开四个视角（类型 × 数据源）的列表选择。
   */
  @Builder
  ViewpointCapsule() {
    Button() {
      Row({ space: 4 }) {
        Text(this.source === 'douban' ? '豆瓣' : 'TMDB')
          .fontSize(14)
          .fontWeight(600)
          .fontColor(Theme.text)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([Theme.textMuted])
      }
      .padding({ left: 12, right: 10, top: 6, bottom: 6 })
    }
    .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
    .padding(0)
    .clip(true)
    .borderRadius(20)
    .margin({ right: 6 })
    .bindMenu(this.ViewpointMenu())
  }

  /** 四个视角的列表选择：当前项系统选中态打勾；点选换视角（同项忽略） */
  @Builder
  ViewpointMenu() {
    Menu() {
      MenuItem({ content: 'TMDB 电影' })
        .selected(this.isCurrent('movie', 'tmdb'))
        .selectIcon(true)
        .onClick(() => {
          this.pickFromMenu('movie', 'tmdb');
        })
      MenuItem({ content: 'TMDB 剧集' })
        .selected(this.isCurrent('tv', 'tmdb'))
        .selectIcon(true)
        .onClick(() => {
          this.pickFromMenu('tv', 'tmdb');
        })
      MenuItem({ content: '豆瓣 电影' })
        .selected(this.isCurrent('movie', 'douban'))
        .selectIcon(true)
        .onClick(() => {
          this.pickFromMenu('movie', 'douban');
        })
      MenuItem({ content: '豆瓣 剧集' })
        .selected(this.isCurrent('tv', 'douban'))
        .selectIcon(true)
        .onClick(() => {
          this.pickFromMenu('tv', 'douban');
        })
    }
  }

  /** 是否当前视角：菜单项的选中态判定 */
  private isCurrent(mediaType: string, source: string): boolean {
    return mediaType === this.mediaType && source === this.source;
  }

  /** 菜单点选：换项走 requestViewpoint（标题、viewpointRequest 连带换）；同项忽略 */
  private pickFromMenu(mediaType: string, source: string): void {
    if (mediaType === this.mediaType && source === this.source) {
      return;
    }
    this.requestViewpoint(mediaType, source);
  }

  /** 右上角搜索（对齐 iOS 发现页顶栏最右的放大镜，预选影视分区，压栈搜索首页） */
  @Builder
  SearchButton() {
    if (this.searchGate) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(22)
        .fontColor([Theme.textMuted])
        .width(36)
        .height(36)
        .margin({ left: 8 })
        .onClick(() => {
          this.navStack.pushPathByName('search', new SearchLaunchParams(SearchMode.media));
        })
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
      systemMaterial: SpatialMaterial.sheet(),
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
