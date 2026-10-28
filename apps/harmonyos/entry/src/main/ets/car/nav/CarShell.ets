/**
 * 车机主外壳（T007 骨架）：左侧固定图标导航栏四页签（首页/媒体库/搜索/账号）
 * + 页签内容容器 + 二级页按 CarUiState 路由栈整屏覆盖 + 播放器覆盖层槽位
 * + 底部 mini 播控条槽位。
 *
 * 返回键分级语义（CarIndex.onBackPress → CarUiState.handleBack）：
 * 播放器面板 → 二级页 → 页签 → 退出确认。
 *
 * 布局：600vp 高的超宽画布上导航靠边（车机媒体类惯例）——左侧 96vp 固定图标栏，
 * 垂直空间全部留给内容与 mini 播控条；二级页覆盖内容区（导航栏常驻可点），
 * 播放器覆盖层盖满整屏（全屏视频）。
 */
import { SessionView } from '../../api/Models';
import { AppModel } from '../../common/AppModel';
import { ServerAddress } from '../../common/ServerAddress';
import { CarColors } from '../theme/CarTheme';
import { CarMetrics } from '../theme/CarTheme';
import { CarType } from '../theme/CarTheme';
import {
  CarCollectionRoute,
  CarDetailRoute,
  CarPersonRoute,
  CarRoute,
  CarRowWallRoute,
  CarTab,
  CarUiState,
  CarWallRoute
} from '../model/CarUiState';
import { CarHomePage } from '../home/CarHomePage';
import { CarItemDetail } from '../detail/CarItemDetail';
import { CarLibraryTab, CarLibraryWall } from '../library/CarLibraryWall';
import { CarMiniPlayer } from '../components/CarMiniPlayer';
import { CarSearchPage } from '../search/CarSearchPage';
import { CarAccountPage } from '../accounts/CarAccountPage';
import { CarPlayerPage } from '../player/CarPlayerPage';

/**
 * 账号身份一变整棵内容重建：外层只按 accountKey 挂一个 CarShellContent，
 * 换账号 = 卸旧挂新，各页签的本地缓存（首页行、搜索结果、账号页）全部重来。
 * 重建必须落在**组件**边界上——把带状态的界面直接塞进 ForEach 会让外层不再随
 * @Trace 重绘。
 */
@ComponentV2
export struct CarShell {
  @Local model: AppModel = AppModel.shared;

  aboutToAppear(): void {
    // 登录完成（或重新进入主界面）一律落首页，不继承上一次会话留下的页签/浮层
    CarUiState.shared.resetShell();
  }

  build() {
    ForEach(this.shellKeys(), (key: string) => {
      CarShellContent()
    }, (key: string) => key)
  }

  /** ForEach 重建键（单元素数组：key 变 = 内容整棵重挂） */
  private shellKeys(): string[] {
    return [this.accountKey()];
  }

  /** 当前账号身份：服务器 origin + 用户名 */
  private accountKey(): string {
    const server: ServerAddress | null = this.model.server;
    const session: SessionView | null = this.model.session;
    if (server === null || session === null) {
      return 'anon';
    }
    return `${server.origin}#${session.username}`;
  }
}

@ComponentV2
struct CarShellContent {
  @Local ui: CarUiState = CarUiState.shared;
  /** 导航栏页签顺序：首页 → 媒体库 → 搜索 → 账号 */
  private readonly railTabs: string[] = [CarTab.home, CarTab.library, CarTab.search, CarTab.accounts];

  build() {
    Stack() {
      this.mainBody()
      // 播放器覆盖层：盖满整屏（全屏视频），非 null 即挂载
      this.playerOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CarColors.bg)
  }

  /** 主体：左导航栏 + 内容区（页签内容 / 二级页覆盖）+ 底部 mini 播控条槽位 */
  @Builder
  private mainBody(): void {
    Row() {
      this.rail()
      Column() {
        Stack() {
          this.tabBody()
          this.routeOverlay()
        }
        .width('100%')
        .layoutWeight(1)
        // mini 播控条占内容区底部一行（显隐由条内 if 收放，列表无需让位不遮挡）
        CarMiniPlayer()
      }
      .width('100%')
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  // MARK: - 左侧固定图标导航栏

  @Builder
  private rail(): void {
    Column({ space: 8 }) {
      Blank()
      ForEach(this.railTabs, (tab: string) => {
        Column({ space: 4 }) {
          SymbolGlyph(this.tabIcon(tab))
            .fontSize(26)
            .fontColor([tab === this.ui.tab ? CarColors.text : CarColors.textMuted])
          Text(this.tabLabel(tab))
            .fontSize(CarType.footnote)
            .fontColor(tab === this.ui.tab ? CarColors.text : CarColors.textMuted)
        }
        .width('100%')
        .height(72)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(20)
        .backgroundColor(tab === this.ui.tab ? CarColors.accentSoft : Color.Transparent)
        .onClick((): void => {
          this.ui.selectTab(tab);
        })
      }, (tab: string): string => tab)
      Blank()
      this.driveToggle()
    }
    .width(CarMetrics.railWidth)
    .height('100%')
    .padding({ top: 16, bottom: 16 })
    .backgroundColor(CarColors.surface)
    .alignItems(HorizontalAlign.Center)
    .border({ width: { right: 1 }, color: CarColors.line })
  }

  /** 行车锁手动开关（默认开；停车时关掉才出视频） */
  @Builder
  private driveToggle(): void {
    Column({ space: 4 }) {
      SymbolGlyph(this.ui.drive.manualEnabled
        ? $r('sys.symbol.car_fill') : $r('sys.symbol.car'))
        .fontSize(26)
        .fontColor([this.ui.drive.manualEnabled ? CarColors.warn : CarColors.textMuted])
      Text('行车锁')
        .fontSize(CarType.footnote)
        .fontColor(this.ui.drive.manualEnabled ? CarColors.warn : CarColors.textMuted)
    }
    .width('100%')
    .height(72)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(20)
    .backgroundColor(this.ui.drive.manualEnabled ? CarColors.accentSoft : Color.Transparent)
    .onClick((): void => {
      this.ui.drive.setManual(!this.ui.drive.manualEnabled);
    })
  }

  // MARK: - 四页签内容

  @Builder
  private tabBody(): void {
    Stack() {
      if (this.ui.tab === CarTab.home) {
        CarHomePage()
      } else if (this.ui.tab === CarTab.library) {
        CarLibraryTab()
      } else if (this.ui.tab === CarTab.search) {
        CarSearchPage()
      } else {
        CarAccountPage()
      }
    }
    .width('100%')
    .height('100%')
  }

  // MARK: - 二级页整屏覆盖（按路由栈叠加，后进在上）

  @Builder
  private routeOverlay(): void {
    ForEach(this.ui.routes, (route: CarRoute) => {
      Stack() {
        this.routePage(route)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(CarColors.bg)
    }, (route: CarRoute): string => CarShellContent.routeKey(route))
  }

  /** 路由 → 页面：详情 / 海报墙 / 影人作品墙 / 合集均已接入 */
  @Builder
  private routePage(route: CarRoute): void {
    if (route instanceof CarDetailRoute) {
      CarItemDetail({
        libraryId: route.libraryId,
        itemId: route.itemId
      })
    } else if (route instanceof CarWallRoute) {
      CarLibraryWall({
        route: route,
        libraryId: route.libraryId,
        kindSource: route.kindSource ?? '',
        title: route.title
      })
    } else if (route instanceof CarPersonRoute) {
      CarLibraryWall({
        route: route,
        sourceKey: `person:${route.tmdbPersonId}`,
        title: route.personName
      })
    } else if (route instanceof CarCollectionRoute) {
      CarLibraryWall({
        route: route,
        collectionId: route.collectionId,
        title: route.title
      })
    } else if (route instanceof CarRowWallRoute) {
      CarLibraryWall({
        route: route,
        sourceKey: route.sourceKey,
        title: route.title
      })
    } else {
      this.routePlaceholder(`${CarShellContent.routeTitle(route)}`)
    }
  }

  /** 二级页占位：居中标题 + 返回按钮；后续故事逐个替换成真实页面 */
  @Builder
  private routePlaceholder(title: string): void {
    Column({ space: 16 }) {
      Text(title)
        .fontSize(CarType.heroTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(CarColors.text)
      Text('该页面将在对应故事接入')
        .fontSize(CarType.footnote)
        .fontColor(CarColors.textMuted)
      Button('返回')
        .fontSize(CarType.body)
        .fontColor(CarColors.text)
        .height(CarMetrics.minTouch)
        .padding({ left: 32, right: 32 })
        .backgroundColor(CarColors.surfaceRaised)
        .borderRadius(999)
        .margin({ top: 8 })
        .onClick((): void => {
          this.ui.popRoute();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // MARK: - 播放器覆盖层（playerRequest 非空整屏挂载；页面 adopt 预建会话）

  @Builder
  private playerOverlay(): void {
    if (this.ui.playerRequest !== null) {
      CarPlayerPage()
    }
  }

  // MARK: - 辅助

  private tabLabel(tab: string): string {
    if (tab === CarTab.library) {
      return '媒体库';
    }
    if (tab === CarTab.search) {
      return '搜索';
    }
    if (tab === CarTab.accounts) {
      return '账号';
    }
    return '首页';
  }

  /** 页签图标（系统 Symbol） */
  private tabIcon(tab: string): Resource {
    if (tab === CarTab.library) {
      return $r('sys.symbol.square_grid_2x2');
    }
    if (tab === CarTab.search) {
      return $r('sys.symbol.magnifyingglass');
    }
    if (tab === CarTab.accounts) {
      return $r('sys.symbol.person_2');
    }
    return $r('sys.symbol.house');
  }

  /** 路由 → 稳定 key（ForEach 去重与复用） */
  private static routeKey(route: CarRoute): string {
    if (route instanceof CarDetailRoute) {
      return `detail_${route.libraryId}_${route.itemId}`;
    }
    if (route instanceof CarWallRoute) {
      return `wall_${route.libraryId}_${route.kindSource ?? ''}`;
    }
    if (route instanceof CarRowWallRoute) {
      return `rowWall_${route.sourceKey}`;
    }
    if (route instanceof CarPersonRoute) {
      return `person_${route.tmdbPersonId}`;
    }
    if (route instanceof CarCollectionRoute) {
      return `collection_${route.collectionId}`;
    }
    return route.routeName;
  }

  /** 路由 → 占位标题 */
  private static routeTitle(route: CarRoute): string {
    if (route instanceof CarDetailRoute) {
      return `详情 #${route.itemId}`;
    }
    if (route instanceof CarWallRoute) {
      return route.title;
    }
    if (route instanceof CarRowWallRoute) {
      return route.title;
    }
    if (route instanceof CarPersonRoute) {
      return `影人 · ${route.personName}`;
    }
    if (route instanceof CarCollectionRoute) {
      return route.title;
    }
    return route.routeName;
  }
}
