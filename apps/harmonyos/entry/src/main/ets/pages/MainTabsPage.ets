import { SymbolGlyphModifier, display } from '@kit.ArkUI';
import {
  HdsTabs,
  HdsTabsController,
  HdsTabsFloatingStyle,
  HdsTabsMiniBar,
  HdsTabsBarChangeMode,
  HdsBarLayoutMode,
  HdsBarStyle,
  HdsAnimationMode,
  SystemMaterialParams
} from '@kit.UIDesignKit';
import { Theme } from '../theme/AppTheme';
import { WindowInsets } from '../common/WindowInsets';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { ShellChrome } from '../common/ShellChrome';
import { TabBarStyle } from '../common/TabBarStyle';
import { TabBarCollapse } from '../common/TabBarCollapse';
import { SpatialMaterial } from '../common/SpatialMaterial';
import { SessionView } from '../api/Models';
import { LibraryNavHost } from '../library/LibraryNavHost';
import { DiscoverNavHost } from '../discover/DiscoverNavHost';
import { SubscriptionsNavHost } from '../subscriptions/SubscriptionsNavHost';
import { ActivityNavHost } from '../activity/ActivityNavHost';
import { MoreNavHost } from './MoreNavHost';
import { SubscribeCenter } from '../subscriptions/SubscribeCenter';
import { SubscribeSheetContent } from '../subscriptions/SubscribeSheet';
import { AgentComposerStore } from '../agent/AgentQuickInput';
import { ServerAddress } from '../common/ServerAddress';
import { MovieClawApi } from '../api/Endpoints';
import { OfflineStore } from '../offline/OfflineStore';
import { OfflineDownloader } from '../offline/OfflineDownloader';
import { OfflineViewingUploader } from '../offline/OfflineViewings';
import { MorePage } from './MorePage';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { ResumeBar, ResumeBarStore } from './ResumeAccessory';
import { UpNextItemView } from '../api/Models';

/** 一个页签的图标与标题：官方 `BottomTabBarStyle` 用 Symbol 画图标（normal / selected 两态） */
interface AppTabItem {
  icon: Resource;
  activeIcon: Resource;
  title: string;
  /** 有值时改用本地图片图标（官方 `iconStyle` 按选中态上色），此时忽略上面两个 Symbol */
  imageIcon?: Resource;
}

/**
 * 登录后的主界面（对齐 iOS 端 MainTabView）：
 * 底部页签自左向右：媒体库（首页）/ 订阅（有订阅权限）/ 发现 / 活动（管理员）/ 更多（账号）。
 * 页签按权限裁剪（Permissions），搜索在右上角、不占页签。M1 为骨架占位，各页内容在 M2-M5 填充。
 */
@ComponentV2
export struct MainTabsPage {
  /**
   * `@Local` 持有单例：`@Trace` 字段要经由 `@Local` 持有的对象读到才会建立订阅
   * 切账号后 `session` 一变，底栏权限与「更多」页跟着重建。
   */
  @Local private model: AppModel = AppModel.shared;
  @Local private currentTab: number = 0;
  /** 全局订阅弹层：发现海报/详情、条目详情、搜索结果都往 SubscribeCenter 投请求，由这里弹 */
  @Local private showSubscribe: boolean = false;
  private subscribeRef: string = '';
  private subscribeTitle: string = '';
  /** 洗版变体（同 iOS `request.upgrade`） */
  @Local private subscribeUpgrade: boolean = false;
  private permissions: Permissions = Permissions.none();

  private tabsController: HdsTabsController = new HdsTabsController();
  /** 整屏页（播放器/片段/会话）压在上面时收起标签栏 */
  @Local private chrome: ShellChrome = ShellChrome.shared;
  /** 分享深链中转（App 在前台时再点链接：监听 pendingSlug 推到当前页签） */
  @Local private shareRouter: ShareRouter = ShareRouter.shared();
  /** 悬浮底栏上方的「接着看」条（对应 iOS `ResumeAccessory`） */
  @Local private resume: ResumeBarStore = new ResumeBarStore();
  /** 底栏样式（悬浮胶囊 / 经典贴底栏）：设置页开关改的就是这个单例，改了整条底栏跟着重建 */
  @Local private tabBarStyle: TabBarStyle = TabBarStyle.shared();
  /** 迷你栏当前是否展开成长条输入框（官方的展开/折叠回调里同步） */
  @Local private miniBarExpanded: boolean = false;
  /** AI 快捷输入草稿与发送（迷你栏长条里显示/发送同一份） */
  @Local private composer: AgentComposerStore = AgentComposerStore.shared();
  /** 内容往下滚后底栏收成圆形按钮的信号（各页签根页在滚动时上报） */
  @Local private collapse: TabBarCollapse = TabBarCollapse.shared();

  /** App 已在跑又点了一条分享链接：推到当前页签的栈上（iOS 同款行为） */
  @Monitor('shareRouter.pendingSlug')
  onPendingShare(): void {
    const slug: string = this.shareRouter.takePending();
    if (slug.length === 0) {
      return;
    }
    const stack: NavPathStack | null = NavStacks.of(NavStacks.currentKey);
    if (stack !== null) {
      stack.pushPathByName('sharePage', new SharePageParams(slug));
    }
  }

  aboutToAppear(): void {
    this.permissions = Permissions.fromSession(this.model.session);
    NavStacks.currentKey = '媒体库';
    // AI 快捷输入的模型清单（管理员才拉；迷你条 / 半屏面板 / 底栏卡三处视图共用一个 store）
    AgentComposerStore.shared().loadModels();
    // 注册全局订阅入口（对应 iOS 的 router.present(.subscribe(...))）
    SubscribeCenter.observe((request): void => {
      this.subscribeRef = request.titleRef;
      this.subscribeTitle = request.title;
      this.subscribeUpgrade = request.upgrade;
      this.showSubscribe = true;
    });
    // 跨页切页签（影人页兜底态「去媒体库」这类，对应 iOS router.open(.libraryHome)）
    ShellChrome.observeTabs((tab: string): void => {
      let index: number = -1;
      if (tab === 'library') {
        index = 0;
      } else if (tab === 'discover') {
        // 媒体库后面可能有订阅页签（visibleTabs 的顺序）
        index = this.permissions.canSubscribe ? 2 : 1;
      }
      if (index >= 0) {
        this.tabsController.changeIndex(index);
      }
    });
    // 自动换过账号（退出/令牌失效）：把提示带过来弹一次。
    // 换账号后主界面整棵重建，当场弹的提示会丢，所以 AppModel 里先存着（对应 iOS pendingNotice）。
    const notice: string | null = this.model.takeNotice();
    if (notice !== null) {
      setTimeout((): void => {
        this.toast(notice);
      }, 400);
    }
    // 「接着看」条：读回叉掉的记录，再取这台设备最近播放的那一条
    this.resume.init(getContext(this))
      .then((): Promise<void> => {
        return this.resume.refresh(this.model.api);
      })
      .catch((): void => {
      });
    // 离线下载：认领本机存档（对应 iOS `OfflineShell` 的 task(id: origin|username)）
    this.adoptOffline();
  }

  /** 会话变了（登录 / 换账号 / 退出）重新认领；退出时把内存里的离线目录清掉 */
  @Monitor('model.session')
  onOfflineSessionChange(): void {
    this.adoptOffline();
  }

  /**
   * 离线下载接线（对应 iOS `OfflineShell`）：认领本机存档 → 补发攒着的观看记录 → 对账下载。
   *
   * 认领要问服务器实例号（`/health`），异步进行、失败不影响进主界面（下次会话变化再试）——
   * 不认领的话 `owner` 一直是 null，下载入口不出现、「我的 → 下载」也永远是空的。
   */
  private adoptOffline(): void {
    const session: SessionView | null = this.model.session;
    if (session === null) {
      OfflineStore.shared.reset();
      return;
    }
    const server: ServerAddress | null = this.model.server;
    const api: MovieClawApi | null = this.model.api;
    if (server === null || api === null) {
      return;
    }
    OfflineStore.shared.adopt(server.origin, session.username, api)
      .then((): void => {
        const key: string | null = OfflineStore.shared.key();
        if (key !== null) {
          OfflineViewingUploader.shared.flush(api, key);
        }
        OfflineDownloader.shared.reconcile();
      })
      .catch((): void => {
      });
  }

  /** 整屏页（播放器/会话/片段）关掉了：底栏放回来，最近播放可能也变了，「接着看」重新取一次 */
  @Monitor('chrome.immersive')
  onChromeImmersiveChange(): void {
    if (this.chrome.immersive) {
      this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION);
      return;
    }
    this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION);
    this.resume.refresh(this.model.api);
  }

  /**
   * 内容向下滚到阈值：**用官方迷你栏样式收起页签栏**——`applyMiniBarStyle(EXPAND)` 会
   * 让官方把五页签胶囊收成只剩当前页签图标的圆钮（和点 ✨ 是同一套官方动效），
   * 迷你栏本身展开成长条输入框。往回滚 / 回顶部 / 换页签再 `COLLAPSE` 放回。
   *
   * 没有迷你栏的账号（非管理员 / 经典贴底栏）没有这套官方折叠形态，保持整条栏不动。
   */
  @Monitor('collapse.collapsed')
  onTabBarCollapsed(): void {
    if (!this.miniBarActive()) {
      return;
    }
    this.tabsController.applyMiniBarStyle(
      this.collapse.collapsed ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /**
   * 「接着看」条当前该显示的那条：
   * - 整屏页（播放器/片段/AI 会话）压在上面时不显示（那几页底部有自己的东西）；
   * - 「我的」页管理员不显示：那页底部是 AI 快捷输入条（同 iOS，附件换成输入框，不叠「接着看」）。
   */
  private resumeItem(): UpNextItemView | null {
    if (this.chrome.immersive) {
      return null;
    }
    const tabs: AppTabItem[] = this.visibleTabs();
    // 贴底栏模式的「我的」页底部是页内输入卡，不叠「接着看」；悬浮模式输入在胶囊
    // 迷你条里（高度已算进 margin），「我的」页也照常显示
    if (this.currentTab >= 0 && this.currentTab < tabs.length
      && tabs[this.currentTab].title === '我的' && this.permissions.isAdmin
      && !this.tabBarStyle.floating) {
      return null;
    }
    return this.resume.visibleItem;
  }

  /** 按权限得出可见页签的规格（顺序即底栏从左到右，同 iOS visibleTabs） */
  private visibleTabs(): AppTabItem[] {
    this.permissions = Permissions.fromSession(this.model.session);
    const tabs: AppTabItem[] = [this.libraryTab()];
    if (this.permissions.canSubscribe) {
      tabs.push(this.subscriptionsTab());
    }
    tabs.push(this.discoverTab());
    if (this.permissions.isAdmin) {
      tabs.push(this.activityTab());
    }
    tabs.push(this.moreTab());
    return tabs;
  }

  private libraryTab(): AppTabItem {
    return {
      icon: $r('sys.symbol.play_square'),
      activeIcon: $r('sys.symbol.play_square_stack_fill'),
      title: '媒体库'
    };
  }

  private subscriptionsTab(): AppTabItem {
    return { icon: $r('sys.symbol.bookmark'), activeIcon: $r('sys.symbol.bookmark_fill'), title: '订阅' };
  }

  private discoverTab(): AppTabItem {
    return { icon: $r('sys.symbol.discover'), activeIcon: $r('sys.symbol.discover_fill'), title: '发现' };
  }

  private activityTab(): AppTabItem {
    // 心电波（ECG）样式，同 iOS `waveform.path.ecg`：系统符号库里只有「心电 + 心形」，
    // 这里用本地 SVG 画一条纯心电折线，按选中态由官方 `iconStyle` 上色
    return {
      icon: $r('sys.symbol.waveform'),
      activeIcon: $r('sys.symbol.waveform'),
      imageIcon: $r('app.media.ic_tab_activity_ecg'),
      title: '活动'
    };
  }

  private moreTab(): AppTabItem {
    // iOS 最后一个页签是**头像**；官方页签只认图标，这里用系统人像符号
    return { icon: $r('sys.symbol.person_crop_circle_fill'), activeIcon: $r('sys.symbol.person_crop_circle_fill'), title: '我的' };
  }

  /** 悬浮胶囊模式才启用迷你栏（管理员可见；整屏页压上来时底栏整体收起） */
  private miniBarActive(): boolean {
    return this.tabBarStyle.floating && this.permissions.isAdmin && !this.chrome.immersive;
  }

  /** 悬浮底栏的页签栏宽度（vp）：给「接着看」条对齐用，与 barFloatingStyle.barWidth 同一口径 */
  private tabBarWidth(): number {
    const screenVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    // 与官方默认页签栏在 5 个页签时的宽度一致（实测约屏宽的 63.7%，夹在 220–328 之间）
    return Math.max(220, Math.min(328, Math.round(screenVp * 0.637)));
  }

  /** 迷你栏折叠宽度（实测 ≈52vp） */
  private miniBarWidth(): number {
    return this.miniBarActive() ? 52 : 0;
  }

  /** 「接着看」条左边界：悬浮模式下与居中的页签栏左缘对齐，否则页面 16 边距 */
  private resumeBarLeft(): number {
    if (!this.tabBarStyle.floating) {
      return 16;
    }
    const screenVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    return Math.max(16, (screenVp - this.tabBarWidth()) / 2);
  }

  /** 收起态：圆形「接着看」放在 AI 输入条右侧，与它同一水平线（贴右边距 16） */
  private resumeCompactLeft(): number {
    const screenVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    return Math.max(16, screenVp - 16 - 56);
  }

  /** 收起态：圆形「接着看」的右边距（固定 16，保证宽度 56） */
  private resumeCompactRight(): number {
    return 16;
  }

  /** 「接着看」条右边界：与迷你栏右缘对齐（迷你栏贴右边距 16），否则页面 16 边距 */
  private resumeBarRight(): number {
    if (!this.tabBarStyle.floating) {
      return 16;
    }
    const screenVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    const mini: number = this.miniBarWidth();
    if (mini <= 0) {
      return this.resumeBarLeft();
    }
    return Math.max(16, screenVp - (this.resumeBarLeft() + this.tabBarWidth() + 8 + mini));
  }

  /** 官方悬浮页签栏的样式：底部抬起 12 + 手势区；管理员多一枚 AI 迷你按钮 */
  private floatingStyle(): HdsTabsFloatingStyle {
    const tabWidth: number = this.tabBarWidth();
    const style: HdsTabsFloatingStyle = {
      barBottomMargin: 12 + WindowInsets.shared().bottom,
      // 页签栏宽度固定下来：「接着看」条要按同一个宽度对齐
      barWidth: { smallWidth: tabWidth, mediumWidth: tabWidth, largeWidth: tabWidth }
    };
    const material: SystemMaterialParams | undefined = SpatialMaterial.hds();
    if (material !== undefined) {
      style.systemMaterialEffect = material;
    }
    if (this.miniBarActive()) {
      style.miniBar = this.miniBarConfig();
    }
    return style;
  }

  /**
   * 迷你栏：左侧一枚 ✨ 按钮，点它官方迷你栏展开成**长条输入框**——和页签栏同一套悬浮材质，
   * 展开后露出「草稿 / 发送」。折叠态宽度只够露出这枚按钮，其余内容由官方裁掉。
   *
   * 官方迷你栏点一下默认展开，这里顺着它的设计走，只在展开态里放输入内容。
   */
  private miniBarConfig(): HdsTabsMiniBar {
    const bar: HdsTabsMiniBar = {
      miniBarBuilder: (): void => {
        this.AiMiniBarRow();
      },
      // 背景跟随页签栏（同一套悬浮材质）：AI 长条和底栏是同一张玻璃
      enableMiniBarBackground: true,
      barLayoutMode: HdsBarLayoutMode.HORIZONTAL,
      miniBarStyle: HdsBarStyle.COLLAPSE,
      onBarStyleChange: (miniStyle: HdsBarStyle, tabStyle: HdsBarStyle, miniWidth: number,
        tabWidth: number, mode: HdsTabsBarChangeMode): void => {
        this.miniBarExpanded = miniStyle === HdsBarStyle.EXPAND;
      }
    };
    return bar;
  }

  /** 迷你栏内容：AI 按钮 / AI 按钮 + 草稿 + 发送（折叠时只露出第一枚按钮） */
  @Builder
  AiMiniBarRow() {
    Row({ space: 8 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.star_message'))
          .fontSize(24)
          .fontColor([Theme.accentStrong])
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .onClick((): void => {
        // 折叠态点它就展开成长条；展开态不再做别的（半屏输入面板已去掉）
        if (!this.miniBarExpanded) {
          this.tabsController.applyMiniBarStyle(HdsBarStyle.EXPAND);
        }
      })
      // 展开后直接在这里输入
      TextInput({ text: this.composer.draft, placeholder: '给 AI 助手发消息' })
        .fontSize(15)
        .fontColor(Theme.text)
        .placeholderColor(Theme.textFaint)
        .placeholderFont({ size: 15 })
        .caretColor(Theme.accentStrong)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .height(36)
        .layoutWeight(1)
        .onChange((value: string): void => {
          this.composer.draft = value;
        })
        .onSubmit((): void => {
          this.sendFromMiniBar();
        })
      Row() {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor([Theme.bg])
      }
      .width(32)
      .height(32)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.accentStrong)
      .borderRadius(16)
      .opacity(this.composer.canSend() ? 1 : 0.4)
      .onClick((): void => {
        this.sendFromMiniBar();
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 8 })
  }

  /** 迷你栏上的发送：有内容直接发；首次发送由官方 AlertDialog 征求同意 */
  private sendFromMiniBar(): void {
    this.composer.maybeSend(this.getUIContext()).then((result: string): void => {
      if (result === 'sent') {
        this.collapse.expand();
        this.tabsController.applyMiniBarStyle(HdsBarStyle.COLLAPSE);
        return;
      }
      if (result === 'consent') {
        // 官方 AlertDialog 已在 maybeSend 里弹出，同意后自动接着发
        return;
      }
      if (result === 'failed') {
        this.toast('发送失败，请重试');
      }
    });
  }

  build() {
    Stack() {
      this.Tabs()
      // 官方悬浮底栏上方的「接着看」条（贴底对齐，抬到底栏之上；可见性见 resumeItem）
      if (this.resumeItem() !== null) {
        ResumeBar({
          item: this.resumeItem() as UpNextItemView,
          // 跟着底栏一起收：滚动向下时收成一枚圆钮，和页签栏的圆钮同高同线
          compact: this.collapse.collapsed,
          onHide: (): void => {
            this.resume.hide();
          }
        })
          .margin({
            left: this.collapse.collapsed ? this.resumeCompactLeft() : this.resumeBarLeft(),
            right: this.collapse.collapsed ? this.resumeCompactRight() : this.resumeBarRight(),
            /*
             * 展开：底栏高度（悬浮 56+12 / 贴底 56）+ 手势区，再留 12 呼吸；
             * 收起：与底栏圆钮同一条水平线（抬起 12 + 手势区）。
             */
            bottom: this.collapse.collapsed
              ? 12 + WindowInsets.shared().bottom
              : (this.tabBarStyle.floating ? 56 + 12 : 56) + WindowInsets.shared().bottom + 12
          })
          // 与页签栏的收起/展开用同一档时长与缓动
          .animation({ duration: 320, curve: Curve.FastOutSlowIn })
      }
    }
    .alignContent(Alignment.Bottom)
    .width('100%')
    .height('100%')
    /*
     * 全屏铺满（edge-to-edge）：内容一直铺到屏幕底。底栏由官方 HdsTabs 悬浮样式渲染，
     * 自己的底部避让（抬起 + 手势区）由 `barFloatingStyle.barBottomMargin` 负责；
     * 「接着看」条按栏高自己算 margin，页面内容的底部留白由 `Theme.tabBarInset` 统一给出。
     */
    .bindSheet($$this.showSubscribe, this.SubscribeSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 全局订阅弹层的内容（对应 iOS 的 form sheet） */
  @Builder
  SubscribeSheet() {
    SubscribeSheetContent({
      titleRef: this.subscribeRef,
      fallbackTitle: this.subscribeTitle,
      upgrade: this.subscribeUpgrade,
      onClose: (): void => {
        this.showSubscribe = false;
      }
    })
  }

  /**
   * 官方页签样式：系统符号（sys.symbol 系列）是 **Symbol** 资源，不是图片——
   * 直接塞进 `BottomTabBarStyle` 的 icon 位只会渲染出文字（图片源解析不到）。
   * 要走 `TabBarSymbol` 的 normal / selected 两个 `SymbolGlyphModifier`。
   */
  private bottomTabStyle(tab: AppTabItem): BottomTabBarStyle {
    // 文字颜色与图标同口径：选中 accentStrong、未选中 textFaint（官方默认的蓝色/灰色跟图标对不上）
    const label: LabelStyle = {
      selectedColor: Theme.accentStrong,
      unselectedColor: Theme.textFaint,
      maxLines: 1
    };
    const image: Resource | undefined = tab.imageIcon;
    if (image !== undefined) {
      const iconStyle: TabBarIconStyle = {
        selectedColor: Theme.accentStrong,
        unselectedColor: Theme.textFaint
      };
      return new BottomTabBarStyle(image, tab.title).iconStyle(iconStyle).labelStyle(label);
    }
    const normal: SymbolGlyphModifier = new SymbolGlyphModifier(tab.icon);
    normal.fontSize(24);
    normal.fontColor([Theme.textFaint]);
    const selected: SymbolGlyphModifier = new SymbolGlyphModifier(tab.activeIcon);
    selected.fontSize(24);
    selected.fontColor([Theme.accentStrong]);
    /*
     * `TabBarSymbol` 只有声明、没有运行时构造器（`new TabBarSymbol()` 会 ReferenceError：
     * TabBarSymbol is not defined），用带类型的对象字面量交给原生层读取字段。
     */
    const symbol: TabBarSymbol = {
      normal: normal,
      selected: selected
    };
    return new BottomTabBarStyle(symbol, tab.title).labelStyle(label);
  }

  @Builder
  Tabs() {
    HdsTabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
      ForEach(this.visibleTabs(), (tab: AppTabItem, index: number) => {
        TabContent() {
          if (tab.title === '媒体库') {
            LibraryNavHost()
          } else if (tab.title === '订阅') {
            SubscriptionsNavHost()
          } else if (tab.title === '发现') {
            DiscoverNavHost()
          } else if (tab.title === '活动') {
            ActivityNavHost()
          } else if (tab.title === '我的') {
            MoreNavHost()
          } else {
            this.PlaceholderContent(tab.title)
          }
        }
        // 页签交给官方渲染：图标 + 文字，选中态、材质、悬浮样式都由 HdsTabs 负责
        .tabBar(this.bottomTabStyle(tab))
      }, (tab: AppTabItem, index: number) => `${tab.title}-${index}`)
    }
    .scrollable(false)
    // 栏高固定 56：悬浮样式的默认值就是 56，贴底模式也按同一个口径（见 Theme.tabBarInset）
    .barHeight(56)
    /*
     * 悬浮样式（设置里的「底栏样式」）：官方要求 barPosition=End、vertical=false、
     * barOverlap=true；切到经典贴底栏时不给 barFloatingStyle，走官方默认整宽底栏。
     */
    .barOverlap(this.tabBarStyle.floating)
    .vertical(false)
    .barFloatingStyle(this.tabBarStyle.floating ? this.floatingStyle() : undefined)
    .barBackgroundColor(this.tabBarStyle.floating ? Color.Transparent : Theme.surfaceRaised)
    .onChange((index: number) => {
      this.currentTab = index;
      const title: string = this.visibleTabs()[index].title;
      NavStacks.currentKey = title;
      // 换页签：新页从顶部开始，底栏放回整条（银玻璃底栏塌陷复位）
      this.collapse.expand();
      // 切回订阅页签：让已挂载保活的订阅首页重拉清单（对齐 iOS 切 tab 触发 onAppear 的语义）；
      // 首次挂载时本广播是空操作，页面 aboutToAppear 自己会拉
      if (title === '订阅') {
        SubscribeCenter.announceSubsRefresh();
      }
    })
    /*
     * 点「已经选中的页签」要回到该页签的根页（iOS 标准行为：在二级页面里点底部同一个页签 = 退回首页）。
     * `onChange` 只在**换页签**时触发，所以这条必须在 `onTabBarClick` 上做。
     */
    .onTabBarClick((index: number): void => {
      const tabs: AppTabItem[] = this.visibleTabs();
      if (index < 0 || index >= tabs.length) {
        return;
      }
      if (index === this.currentTab) {
        const stack: NavPathStack | null = NavStacks.of(tabs[index].title);
        if (stack !== null && stack.size() > 0) {
          stack.clear();
        }
      }
    })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 内容占位页：顶栏（标题 + 右上角搜索入口）+ 中央提示（M2 起逐页替换） */
  @Builder
  PlaceholderContent(title: string) {
    Column() {
      Row() {
        Text(title)
          .fontFamily('serif')
          .fontSize(28)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Blank()
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(22)
          .fontColor([Theme.textMuted])
          .padding(6)
      }
      .width('100%')
      .padding({ left: 24, right: 20, top: 18, bottom: 12 })

      Column({ space: 10 }) {
        Text('「' + title + '」建设中')
          .fontFamily('serif')
          .fontSize(16)
          .fontColor(Theme.textMuted)
        Text('这个模块将在后续版本开放')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
  }
}

/** 预览：管理员会话（全页签可见） */
@Preview
@Component
struct MainTabsPagePreview {
  aboutToAppear(): void {
    AppModel.shared.session = {
      username: 'admin',
      nickname: '放映员',
      role: 'admin',
      capabilities: { allow_subscribe: true, allow_search: true, allow_direct_download: true },
      device: { id: 'ld-1', kind: 'android', name: 'HarmonyOS' }
    } as SessionView;
  }

  build() {
    MainTabsPage()
  }
}
