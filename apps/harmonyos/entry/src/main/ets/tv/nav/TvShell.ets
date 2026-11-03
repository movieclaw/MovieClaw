/**
 * TV 主外壳（US8）：可收起胶囊侧边栏 + 三页签（谁在看 → 搜索 → 首页）+ 二级页整屏覆盖 + 播放器覆盖层槽位。
 *
 * 侧边栏交互（对齐 Apple TV sidebarAdaptable 的双输入路径）：
 * - 收起态：左上角一枚「‹ 当前页」胶囊；焦点在胶囊上按左键、点击胶囊、或在首页按返回键 → 展开；
 * - 展开态：整高玻璃栏，三页签上下排列；栏内上下移动只走焦点不切页，确认才切换（切换即收起）；
 *   在栏内按右键收起不切页；
 * - 二级页/播放器整屏覆盖时胶囊与侧边栏都不挂载（焦点不可达）。
 *
 * 焦点落点用 FocusController.requestFocus 显式管理（key 定位）：
 * 展开侧边栏 → 焦点进当前页签项；收起/切页/路由清空 → 焦点回页签内容锚点。
 */
import { KeyCode } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SessionView } from '../../api/Models';
import { AppModel } from '../../common/AppModel';
import { ServerAddress } from '../../common/ServerAddress';
import { TvAccountsPage } from '../accounts/TvAccountsPage';
import { TvColors } from '../theme/TvTheme';
import { TvType } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';
import { TvMotion } from '../theme/TvTheme';
import { TvFocusable } from '../components/TvFocusable';
import { TvFocus } from '../components/TvFocus';
import { TvHomePage } from '../home/TvHomePage';
import { TvItemDetail } from '../detail/TvItemDetail';
import { TvLibraryWall } from '../library/TvLibraryWall';
import { TvPlayerPage } from '../player/TvPlayerPage';
import { TvSearchPage } from '../search/TvSearchPage';
import {
  TvCollectionRoute,
  TvDetailRoute,
  TvPersonRoute,
  TvRoute,
  TvRowWallRoute,
  TvTab,
  TvUiState,
  TvWallRoute
} from '../model/TvUiState';

/**
 * 账号身份一变整棵内容重建：外层只按 accountKey 挂一个 TvShellContent，
 * 换账号 = 卸旧挂新，各页签的本地缓存（首页行、搜索结果、账号页）全部重来。
 * 重建必须落在**组件**边界上——把带状态的界面直接塞进 ForEach 会让外层不再随
 * @Trace 重绘（实测：点胶囊、开播放器全无反应）。
 */
@ComponentV2
export struct TvShell {
  @Local model: AppModel = AppModel.shared;

  aboutToAppear(): void {
    // 登录完成（或重新进入主界面）一律落首页，不继承上一次会话留下的页签/浮层
    TvUiState.shared.resetShell();
  }

  build() {
    ForEach(this.shellKeys(), (key: string) => {
      TvShellContent()
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
struct TvShellContent {
  @Local ui: TvUiState = TvUiState.shared;
  @Local model: AppModel = AppModel.shared;
  /** 页签顺序：谁在看 → 搜索 → 首页（spec US8 信息架构） */
  private readonly railTabs: string[] = [TvTab.accounts, TvTab.search, TvTab.home];
  /** 侧边栏内当前激活（焦点或悬浮）的页签下标；-1 = 无 */
  @Local railActiveIndex: number = -1;
  /** 胶囊激活态 */
  @Local capsuleActive: boolean = false;

  /** 侧边栏展开/收起：焦点在胶囊/侧边栏项与页签内容锚点之间显式转移 */
  @Monitor('ui.railExpanded')
  onRailExpandedChange(): void {
    const expanded: boolean = this.ui.railExpanded;
    setTimeout((): void => {
      if (expanded) {
        TvFocus.request(this.getUIContext(), `tv_rail_${this.railIndexOf(this.ui.tab)}`);
      } else {
        TvFocus.request(this.getUIContext(), 'tv_tab_anchor');
      }
    }, 60);
  }

  /** 路由栈清空（最后一层二级页返回）：焦点回页签内容锚点 */
  @Monitor('ui.routes')
  onRoutesChange(): void {
    if (this.ui.routes.length === 0 && this.ui.playerRequest === null) {
      setTimeout((): void => {
        TvFocus.request(this.getUIContext(), 'tv_tab_anchor');
      }, 60);
    }
  }

  build() {
    this.ShellRoot()
  }

  /** 外壳内容 */
  @Builder
  private ShellRoot(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      this.tabBody()
      // 二级页/播放器整屏覆盖时胶囊与侧边栏都不挂载
      if (this.ui.routes.length === 0 && this.ui.playerRequest === null) {
        if (this.ui.railExpanded) {
          this.railPanel()
        } else {
          this.collapsedCapsule()
        }
      }
      this.routeOverlay()
      this.playerOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
    .onTouch((event: TouchEvent): void => {
      hilog.info(0x0000, 'DbgTouch', 'SHELL_ROOT_TOUCH type=%{public}s x=%{public}d y=%{public}d',
        event.type.toString(), Math.round(event.touches[0].x), Math.round(event.touches[0].y));
    })
  }

  // MARK: - 三页签内容

  @Builder
  private tabBody(): void {
    Stack() {
      if (this.ui.tab === TvTab.home) {
        TvHomePage()
      } else if (this.ui.tab === TvTab.search) {
        TvSearchPage()
      } else {
        TvAccountsPage()
      }
    }
    .width('100%')
    .height('100%')
  }

  // MARK: - 侧边栏（收起胶囊 / 展开栏）

  /** 收起态：左上角「‹ 当前页」胶囊；焦点上按左键或点击展开 */
  @Builder
  private collapsedCapsule(): void {
    Row({ space: 8 }) {
      Text('‹')
        .fontSize(TvType.body)
        .fontColor(this.capsuleActive ? TvColors.text : TvColors.textMuted)
      Text(this.tabLabel(this.ui.tab))
        .fontSize(TvType.body)
        .fontColor(this.capsuleActive ? TvColors.text : TvColors.textMuted)
    }
    .height(56)
    .padding({ left: 22, right: 22 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.capsuleActive ? TvColors.glassFillHover : TvColors.glassFill)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, { colorMode: ThemeColorMode.DARK })
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.12)' })
    .borderRadius(999)
    .focusable(true)
    .key('tv_capsule')
    // 与搜索框同一水平线、同一高度、同一材质（左上内容边距 = TvMetrics.edge）
    .margin({ left: TvMetrics.edge, top: 40 })
    .onFocus((): void => {
      this.animateActive((): void => {
        this.capsuleActive = true;
      });
    })
    .onBlur((): void => {
      this.animateActive((): void => {
        this.capsuleActive = false;
      });
    })
    .onHover((isHover: boolean): void => {
      this.animateActive((): void => {
        this.capsuleActive = isHover;
      });
    })
    .onKeyEvent((event: KeyEvent): void => {
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_DPAD_LEFT) {
        this.ui.railExpanded = true;
      }
    })
    .onClick((): void => {
      hilog.info(0x0000, 'DbgTap', 'CAPSULE_CLICK');
      this.ui.railExpanded = true;
    })
  }

  /**
   * 展开态：左上角弹出的玻璃方片（对齐 tvOS sidebarAdaptable 的悬浮侧边栏）。
   * 栏内上下只走焦点不切页，确认才切换（切换即收起），右键收起不切页。
   */
  @Builder
  private railPanel(): void {
    Column({ space: 4 }) {
      ForEach(this.railTabs, (tab: string, index: number) => {
        Row({ space: 14 }) {
          SymbolGlyph(this.tabIcon(tab))
            .fontSize(22)
            .fontColor([tab === this.ui.tab || this.railActiveIndex === index
              ? TvColors.text : TvColors.textMuted])
          Text(this.tabLabel(tab))
            .fontSize(TvType.railItem)
            .fontWeight(tab === this.ui.tab ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.railActiveIndex === index ? TvColors.text
              : (tab === this.ui.tab ? TvColors.text : TvColors.textMuted))
            .layoutWeight(1)
          if (tab === this.ui.tab) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([TvColors.text])
          }
        }
        .width('100%')
        .height(60)
        .padding({ left: 18, right: 18 })
        .borderRadius(16)
        .backgroundColor(this.railActiveIndex === index ? 'rgba(255, 255, 255, 0.18)'
          : (tab === this.ui.tab ? 'rgba(255, 255, 255, 0.09)' : Color.Transparent))
        .focusable(true)
        .key(`tv_rail_${index}`)
        .onFocus((): void => {
          this.setRailActive(index, true);
        })
        .onBlur((): void => {
          this.setRailActive(index, false);
        })
        .onHover((isHover: boolean): void => {
          this.setRailActive(index, isHover);
        })
        .onKeyEvent((event: KeyEvent): void => {
          if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) {
            this.ui.railExpanded = false;
          }
        })
        .onClick((): void => {
          this.ui.selectTab(tab);
        })
      }, (tab: string): string => tab)
    }
    .width(TvMetrics.railExpanded)
    .padding(12)
    .margin({ left: TvMetrics.edge, top: 40 })
    .borderRadius(28)
    // 玻璃质感：半透明底 + 系统背景模糊 + 细亮边 + 投影
    .backgroundColor('rgba(18, 20, 27, 0.62)')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.14)' })
    .shadow({ radius: 36, color: 'rgba(0, 0, 0, 0.55)', offsetY: 14 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })))
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 二级页整屏覆盖（按路由栈叠加，后进在上）

  @Builder
  private routeOverlay(): void {
    ForEach(this.ui.routes, (route: TvRoute) => {
      Stack() {
        if (route instanceof TvDetailRoute) {
          TvItemDetail({ libraryId: route.libraryId, itemId: route.itemId })
        } else if (route instanceof TvWallRoute) {
          TvLibraryWall({
            route: route,
            libraryId: route.libraryId,
            kindSource: route.kindSource ?? '',
            collectionId: 0,
            sourceKey: '',
            title: route.title
          })
        } else if (route instanceof TvRowWallRoute) {
          TvLibraryWall({
            route: route,
            libraryId: 0,
            kindSource: '',
            collectionId: 0,
            sourceKey: route.sourceKey,
            title: route.title
          })
        } else if (route instanceof TvPersonRoute) {
          this.routePlaceholder(`影人 · ${route.personName}`)
        } else if (route instanceof TvCollectionRoute) {
          TvLibraryWall({
            route: route,
            libraryId: 0,
            kindSource: '',
            collectionId: route.collectionId,
            sourceKey: '',
            title: route.title
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(TvColors.bg)
    }, (route: TvRoute): string => TvShellContent.routeKey(route))
  }

  /** 二级页占位：居中标题 + 返回按钮（默认焦点）；后续故事逐个替换成真实页面 */
  @Builder
  private routePlaceholder(title: string): void {
    Column({ space: 16 }) {
      Text(title)
        .fontSize(TvType.heroTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(TvColors.text)
      Text('该页面将在对应故事接入')
        .fontSize(TvType.footnote)
        .fontColor(TvColors.textMuted)
      TvFocusable({
        focusScale: 1.04,
        cornerRadius: 999,
        defaultFocused: true,
        onActivate: (): void => {
          this.ui.popRoute();
        }
      }) {
        Text('返回')
          .fontSize(TvType.body)
          .fontColor(TvColors.textMuted)
          .padding({ left: 28, right: 28, top: 12, bottom: 12 })
          .backgroundColor(TvColors.glassFill)
          .borderRadius(999)
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // MARK: - 播放器覆盖层（playerRequest 非空整屏挂载；引擎由起播入口 playback-first 预建）

  @Builder
  private playerOverlay(): void {
    if (this.ui.playerRequest !== null) {
      TvPlayerPage()
    }
  }

  // MARK: - 辅助

  private tabLabel(tab: string): string {
    if (tab === TvTab.search) {
      return '搜索';
    }
    if (tab === TvTab.accounts) {
      return '谁在看';
    }
    return '首页';
  }

  /** 页签图标（系统 Symbol） */
  private tabIcon(tab: string): Resource {
    if (tab === TvTab.search) {
      return $r('sys.symbol.magnifyingglass');
    }
    if (tab === TvTab.accounts) {
      return $r('sys.symbol.person_2');
    }
    return $r('sys.symbol.house');
  }

  private railIndexOf(tab: string): number {
    for (let index: number = 0; index < this.railTabs.length; index++) {
      if (this.railTabs[index] === tab) {
        return index;
      }
    }
    return this.railTabs.length - 1;
  }

  private setRailActive(index: number, active: boolean): void {
    this.animateActive((): void => {
      this.railActiveIndex = active ? index : -1;
    });
  }

  /** 统一的短过渡（焦点高亮等） */
  private animateActive(action: () => void): void {
    this.getUIContext().animateTo(
      { duration: TvMotion.focusMs, curve: Curve.EaseOut },
      action);
  }

  /** 路由 → 稳定 key（ForEach 去重与复用） */
  private static routeKey(route: TvRoute): string {
    if (route instanceof TvDetailRoute) {
      return `detail_${route.libraryId}_${route.itemId}`;
    }
    if (route instanceof TvWallRoute) {
      return `wall_${route.libraryId}_${route.kindSource ?? ''}`;
    }
    if (route instanceof TvRowWallRoute) {
      return `rowWall_${route.sourceKey}`;
    }
    if (route instanceof TvPersonRoute) {
      return `person_${route.tmdbPersonId}`;
    }
    if (route instanceof TvCollectionRoute) {
      return `collection_${route.collectionId}`;
    }
    return route.routeName;
  }
}
