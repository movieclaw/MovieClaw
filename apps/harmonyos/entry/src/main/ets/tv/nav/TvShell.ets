/**
 * TV 主外壳（US8 + 鸿蒙客厅专属扩展）：
 * - 可收起胶囊侧边栏 + 五页签（谁在看 → 搜索 → 首页 → 发现 → 放映厅）+ 二级页整屏覆盖 + 播放器覆盖层；
 * - 接入影人档案页 `TvPersonPage`（彻底消除二级路由占位页）；
 * - 接入 `ContinuationBridge` 分布式流转消费端：手机/折叠屏/平板流转至智慧屏毫秒级直达播放或详情页。
 */
import { KeyCode } from '@kit.InputKit';
import { SessionView } from '../../api/Models';
import { AppModel } from '../../common/AppModel';
import { AppLanguage } from '../../common/AppLanguage';
import { ContinuationBridge, ContinuationTarget } from '../../common/ContinuationBridge';
import { ServerAddress } from '../../common/ServerAddress';
import { TvAccountsPage } from '../accounts/TvAccountsPage';
import { TvFocus } from '../components/TvFocus';
import { TvDetailRoute, TvPersonRoute, TvPlayRequest, TvRoute, TvRowWallRoute, TvTab, TvUiState, TvWallRoute,
  TvCollectionRoute } from '../model/TvUiState';
import { TvDiscoverPage } from '../discover/TvDiscoverPage';
import { TvHomePage } from '../home/TvHomePage';
import { TvItemDetail } from '../detail/TvItemDetail';
import { TvLibraryWall } from '../library/TvLibraryWall';
import { TvPersonPage } from '../person/TvPersonPage';
import { TvPlayback } from '../playback/TvPlaybackHost';
import { TvPlayerPage } from '../player/TvPlayerPage';
import { TvReelsPage } from '../reels/TvReelsPage';
import { TvSearchPage } from '../search/TvSearchPage';
import { TvColors, TvMetrics, TvMotion, TvType } from '../theme/TvTheme';

@ComponentV2
export struct TvShell {
  @Local model: AppModel = AppModel.shared;

  aboutToAppear(): void {
    TvUiState.shared.resetShell();
  }

  build() {
    ForEach(this.shellKeys(), (_key: string) => {
      TvShellContent()
    }, (key: string) => key)
  }

  private shellKeys(): string[] {
    return [this.accountKey()];
  }

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
  @Local appLanguage: AppLanguage = AppLanguage.shared();
  @Local continuation: ContinuationBridge = ContinuationBridge.shared();
  /** 页签顺序：谁在看 → 搜索 → 首页 → 发现 → 放映厅 */
  private readonly railTabs: string[] = [
    TvTab.accounts,
    TvTab.search,
    TvTab.home,
    TvTab.discover,
    TvTab.reels
  ];
  @Local railActiveIndex: number = -1;
  @Local capsuleActive: boolean = false;

  aboutToAppear(): void {
    this.consumeContinuation();
  }

  @Monitor('continuation.pendingSeq')
  onPendingContinuation(): void {
    this.consumeContinuation();
  }

  private consumeContinuation(): void {
    const target: ContinuationTarget | null = this.continuation.takePending();
    if (target === null) {
      return;
    }
    if (target.kind === 'play' && target.mediaItemId > 0) {
      const isTv: boolean = target.season > 0 && target.episode > 0;
      const req: TvPlayRequest = new TvPlayRequest(
        target.libraryId,
        target.mediaItemId,
        isTv ? target.season : null,
        isTv ? target.episode : null,
        target.fileId > 0 ? target.fileId : null,
        target.positionMs > 0 ? target.positionMs : null,
        target.title.length > 0 ? target.title : '继续播放',
        isTv ? `第 ${target.season} 季 第 ${target.episode} 集` : null,
        isTv
      );
      TvPlayback.begin(req);
      this.ui.openPlayer(req);
      return;
    }
    if (target.kind === 'item' && target.libraryId > 0 && target.mediaItemId > 0) {
      this.ui.pushRoute(new TvDetailRoute(target.libraryId, target.mediaItemId));
      return;
    }
    if (target.kind === 'search') {
      this.ui.selectTab(TvTab.search);
    }
  }

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

  @Builder
  private ShellRoot(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      this.tabBody()
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
  }

  @Builder
  private tabBody(): void {
    Stack() {
      if (this.ui.tab === TvTab.home) {
        TvHomePage()
      } else if (this.ui.tab === TvTab.discover) {
        TvDiscoverPage()
      } else if (this.ui.tab === TvTab.reels) {
        TvReelsPage()
      } else if (this.ui.tab === TvTab.search) {
        TvSearchPage()
      } else {
        TvAccountsPage()
      }
    }
    .width('100%')
    .height('100%')
  }

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
      this.ui.railExpanded = true;
    })
  }

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
    .backgroundColor('rgba(18, 20, 27, 0.68)')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.14)' })
    .shadow({ radius: 36, color: 'rgba(0, 0, 0, 0.55)', offsetY: 14 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })))
    .alignItems(HorizontalAlign.Start)
  }

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
            title: route.title,
            actor: route.actor ?? ''
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
          TvPersonPage({
            tmdbPersonId: route.tmdbPersonId,
            personName: route.personName
          })
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

  @Builder
  private playerOverlay(): void {
    if (this.ui.playerRequest !== null) {
      TvPlayerPage()
    }
  }

  private tabLabel(tab: string): string {
    if (tab === TvTab.search) {
      return this.appLanguage.t('tv.tab.search');
    }
    if (tab === TvTab.accounts) {
      return this.appLanguage.t('tv.tab.accounts');
    }
    if (tab === TvTab.discover) {
      return this.appLanguage.t('tv.tab.discover');
    }
    if (tab === TvTab.reels) {
      return this.appLanguage.t('tv.tab.reels');
    }
    return this.appLanguage.t('tv.tab.home');
  }

  private tabIcon(tab: string): Resource {
    if (tab === TvTab.search) {
      return $r('sys.symbol.magnifyingglass');
    }
    if (tab === TvTab.accounts) {
      return $r('sys.symbol.person_2');
    }
    if (tab === TvTab.discover) {
      return $r('sys.symbol.sparkles');
    }
    if (tab === TvTab.reels) {
      return $r('sys.symbol.film');
    }
    return $r('sys.symbol.house');
  }

  private railIndexOf(tab: string): number {
    for (let index: number = 0; index < this.railTabs.length; index++) {
      if (this.railTabs[index] === tab) {
        return index;
      }
    }
    return 2;
  }

  private setRailActive(index: number, active: boolean): void {
    this.animateActive((): void => {
      this.railActiveIndex = active ? index : -1;
    });
  }

  private animateActive(action: () => void): void {
    this.getUIContext().animateTo(
      { duration: TvMotion.focusMs, curve: Curve.EaseOut },
      action);
  }

  private static routeKey(route: TvRoute): string {
    if (route instanceof TvDetailRoute) {
      return `detail_${route.libraryId}_${route.itemId}`;
    }
    if (route instanceof TvWallRoute) {
      return `wall_${route.libraryId}_${route.kindSource ?? ''}_${route.actor ?? ''}`;
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
