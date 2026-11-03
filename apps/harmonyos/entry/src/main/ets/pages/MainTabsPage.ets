import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
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
import { ImageUrls } from '../common/ImageUrls';
import { RemoteImage } from '../common/RemoteImage';
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
import { NotifyCenter } from '../notify/NotifyCenter';
import { NotifyOpen, NotifyRouter } from '../notify/NotifyRouter';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';
import { SubscriptionParams } from '../subscriptions/SubscriptionDetailPage';
import { ResumeBar, ResumeBarStore } from './ResumeAccessory';
import { UpNextItemView } from '../api/Models';

/** 页签的图标与无障碍标题。 */
interface AppTabItem {
  icon: Resource;
  title: string;
  /** 有值时改用本地图片图标。 */
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
  /** 系统通知点按中转（通知带着 tab/route 参数拉起：切页签、推详情页落点） */
  @Local private notifyRouter: NotifyRouter = NotifyRouter.shared();
  /** 悬浮底栏上方的「接着看」条（对应 iOS `ResumeAccessory`） */
  @Local private resume: ResumeBarStore = new ResumeBarStore();
  /** 底栏样式（悬浮胶囊 / 经典贴底栏）：设置页开关改的就是这个单例，改了整条底栏跟着重建 */
  @Local private tabBarStyle: TabBarStyle = TabBarStyle.shared();
  /** 内容往下滚后底栏收成圆形按钮的信号（各页签根页在滚动时上报） */
  @Local private collapse: TabBarCollapse = TabBarCollapse.shared();
  /** AI 快捷输入的草稿 / 发送（官方迷你栏方案与「我的」输入卡共用一个 store） */
  @Local private composer: AgentComposerStore = AgentComposerStore.shared();
  /** 迷你栏当前是否展开成长条输入框（官方的展开/折叠回调里同步） */
  @Local private miniBarExpanded: boolean = false;

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

  /** App 已在跑又点了一条系统通知：切到落点页签并推详情页 */
  @Monitor('notifyRouter.pendingSeq')
  onPendingNotifyTap(): void {
    this.consumeNotifyTap();
  }

  /**
   * 消费通知点按：切页签（activity→活动 / subscriptions→订阅）+ 推落点
   * （`item/{库}/{条目}` → 媒体库条目详情；`subscription/{订阅id}` → 订阅详情）。
   *
   * - 冷启动：EntryAbility.onCreate 里 handOff 早于本页挂载，aboutToAppear 的
   *   延迟兜底走同一条路；
   * - 目标页签这个账号看不到（成员没有活动页）：只把 App 带到前台，路由改推当前栈；
   * - 目标栈还没挂载（首次切过去）：NavStacks.has 轮询等它登记，等不到用回退栈。
   */
  private consumeNotifyTap(): void {
    const open: NotifyOpen | null = this.notifyRouter.takePending();
    if (open === null) {
      return;
    }
    const wanted: string = open.tab === 'subscriptions' ? '订阅' : '活动';
    const index: number = MainTabsPage.indexOfTab(this.visibleTabs(), wanted);
    let stackTitle: string = NavStacks.currentKey;
    if (index >= 0) {
      stackTitle = wanted;
      this.tabsController.changeIndex(index);
    }
    if (open.route.length === 0) {
      return;
    }
    this.pushNotifyRouteWhenReady(stackTitle, open.route, 0);
  }

  /** 目标栈登记了就推；还没登记（TabContent 惰性挂载）就小步等它，等不到走回退栈 */
  private pushNotifyRouteWhenReady(stackTitle: string, route: string, attempt: number): void {
    if (NavStacks.has(stackTitle) || attempt >= 10) {
      const stack: NavPathStack | null = NavStacks.of(stackTitle);
      if (stack !== null) {
        this.pushNotifyRoute(stack, route);
      }
      return;
    }
    setTimeout((): void => {
      this.pushNotifyRouteWhenReady(stackTitle, route, attempt + 1);
    }, 100);
  }

  /** 解析通知落点并推入目标栈 */
  private pushNotifyRoute(stack: NavPathStack, route: string): void {
    if (route.startsWith('item/')) {
      const rest: string = route.substring('item/'.length);
      const slash: number = rest.indexOf('/');
      if (slash > 0) {
        const libraryId: number = Number(rest.substring(0, slash));
        const mediaItemId: number = Number(rest.substring(slash + 1));
        if (Number.isFinite(libraryId) && Number.isFinite(mediaItemId)
          && libraryId > 0 && mediaItemId > 0) {
          stack.pushPathByName('libraryItem',
            new ItemRouteParams(Math.floor(libraryId), Math.floor(mediaItemId)));
        }
      }
      return;
    }
    if (route.startsWith('subscription/')) {
      const id: number = Number(route.substring('subscription/'.length));
      if (Number.isFinite(id) && id > 0) {
        stack.pushPathByName('subscriptionDetail', new SubscriptionParams(Math.floor(id)));
      }
    }
  }

  private static indexOfTab(tabs: AppTabItem[], title: string): number {
    for (let index: number = 0; index < tabs.length; index++) {
      if (tabs[index].title === title) {
        return index;
      }
    }
    return -1;
  }

  aboutToAppear(): void {
    this.permissions = Permissions.fromSession(this.model.session);
    NavStacks.currentKey = '媒体库';
    this.syncAccessoryInset();
    // AI 快捷输入的模型清单（管理员才拉；「我的」输入卡与半屏面板共用一个 store）
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
    // 通知点按的冷启动兜底：handOff 发生在本页挂载之前，@Monitor 追不到挂载前的值，
    // 延迟取一次（同 takeNotice 的兜底节奏；takePending 有序号对账，重复消费拿不到）
    setTimeout((): void => {
      this.consumeNotifyTap();
    }, 400);
    // 前台差分轮询：主界面挂着每 10 分钟一轮（登录态每轮自查；退后台由 workScheduler 兜底）
    NotifyCenter.shared().startForegroundTimer();
  }

  aboutToDisappear(): void {
    NotifyCenter.shared().stopForegroundTimer();
  }

  /** 会话变了（登录 / 换账号 / 退出）重新认领；退出时把内存里的离线目录清掉 */
  @Monitor('model.session')
  onOfflineSessionChange(): void {
    this.adoptOffline();
    this.syncAccessoryInset();
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
    hilog.info(0xD001, 'ChromeDebug', 'immersive monitor fired: %{public}s',
      this.chrome.immersive ? 'true' : 'false');
    this.syncAccessoryInset();
    if (this.chrome.immersive) {
      this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION);
      return;
    }
    this.collapse.expand();
    this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION);
    this.resume.refresh(this.model.api);
  }

  /**
   * 滚动收起走官方迷你栏：`applyMiniBarStyle(EXPAND)` 让官方把五页签胶囊收成只剩当前页签
   * 图标的圆钮（和点 ✨ 是同一套官方动效）；COLLAPSE 反向恢复整条页签。
   */
  @Monitor('collapse.collapsed', 'tabBarStyle.floating')
  onTabBarCollapsed(): void {
    if (this.chrome.immersive) { return; }
    if (this.officialCollapse()) {
      // 整条可能还被整屏页的 hide 收着（退出整屏页的一瞬间）：先放回再交迷你栏接管；
      // 栏本来就显示时这是无害的空操作
      this.tabsController.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION);
      this.tabsController.applyMiniBarStyle(
        this.collapse.collapsed ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE);
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 官方迷你栏收起方案生效中（悬浮 + 非整屏页；迷你栏没有 AI 内容后不限管理员） */
  private officialCollapse(): boolean {
    return this.tabBarStyle.floating && !this.chrome.immersive;
  }

  /** 「接着看」条是否进入收起布局：收起后与底栏圆钮同一条水平线 */
  private resumeCompact(): boolean {
    return this.tabBarStyle.floating && !this.chrome.immersive && this.collapse.collapsed;
  }

  /** 官方收起成圆钮的形态中：页签自带的高亮胶囊底会戳出圆钮弧线，此时不画 */
  private tabCollapsed(): boolean {
    return this.officialCollapse() && this.collapse.collapsed;
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
    if (this.currentTab >= 0 && this.currentTab < tabs.length
      && tabs[this.currentTab].title === '我的' && this.permissions.isAdmin) {
      return null;
    }
    return this.resume.visibleItem;
  }

  private syncAccessoryInset(): void {
    const quickInput: boolean = this.visibleTabs()[this.currentTab]?.title === '我的' && this.permissions.isAdmin;
    const inset: number = this.chrome.immersive ? 0 : quickInput ? Theme.agentDockInset
      : this.resumeItem() !== null ? 68 : 0;
    this.chrome.setBottomAccessoryInset(inset);
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
      icon: $r('sys.symbol.play_square_stack_fill'),
      title: '媒体库'
    };
  }

  private subscriptionsTab(): AppTabItem {
    return { icon: $r('sys.symbol.bookmark'), title: '订阅' };
  }

  private discoverTab(): AppTabItem {
    return { icon: $r('sys.symbol.discover'),
      imageIcon: $r('app.media.ic_tab_sparkles'), title: '发现' };
  }

  private activityTab(): AppTabItem {
    // 心电波（ECG）样式，同 iOS `waveform.path.ecg`：系统符号库里只有「心电 + 心形」，
    // 这里用本地 SVG 画一条纯心电折线。
    return {
      icon: $r('sys.symbol.waveform'),
      imageIcon: $r('app.media.ic_tab_activity_ecg'),
      title: '活动'
    };
  }

  private moreTab(): AppTabItem {
    return { icon: $r('sys.symbol.person_crop_circle_fill'), title: '我的' };
  }

  /** 悬浮底栏的页签栏宽度（vp）：给「接着看」条对齐用，与 barFloatingStyle.barWidth 同一口径 */
  private tabBarWidth(): number {
    const screenVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    return Math.min(364, screenVp - 32);
  }

  /** 「接着看」条左边界：悬浮模式下与居中的页签栏左缘对齐，否则页面 16 边距 */
  private resumeBarLeft(): number {
    if (!this.tabBarStyle.floating) {
      return 16;
    }
    const screenVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    return Math.max(16, (screenVp - this.tabBarWidth()) / 2);
  }

  /** 收起态左边界：官方收起后整行是迷你栏 + 页签圆钮，「接着看」圆片贴右边距 16
   * 放在页签圆钮左边。 */
  private resumeCompactLeft(): number {
    const screenVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    return Math.max(16, screenVp - 16 - 56);
  }

  private resumeCompactRight(): number {
    return 16;
  }

  /** 迷你栏宽度：AI 输入下线期间为 0（不占位，resumeBarRight 不用让位）；接回后恢复 52 */
  private miniBarWidth(): number {
    return 0;
  }

  private resumeBarRight(): number {
    if (this.officialCollapse()) {
      const screenVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
      const mini: number = this.miniBarWidth();
      if (mini > 0) {
        return Math.max(16, screenVp - (this.resumeBarLeft() + this.tabBarWidth() + 8 + mini));
      }
    }
    return this.resumeBarLeft();
  }

  /** 官方悬浮页签栏的样式：底部抬起 12 + 手势区，所有页签共用居中胶囊 */
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
    // 官方收起方案：配迷你栏才有官方的「胶囊收成圆钮」形态（applyMiniBarStyle）
    if (this.officialCollapse()) {
      style.miniBar = this.miniBarConfig();
    }
    return style;
  }

  /**
   * 迷你栏：AI 输入暂时下线（builder 留空），宽度压成 0、不带背景——不占位，
   * 只保留「官方把胶囊收成圆钮」这套收起动效；接回 AI 时删掉 miniBarWidth /
   * enableMiniBarBackground 两行并恢复 AiMiniBarRow 里的内容即可。
   */
  private miniBarConfig(): HdsTabsMiniBar {
    const bar: HdsTabsMiniBar = {
      miniBarBuilder: (): void => {
        this.AiMiniBarRow();
      },
      miniBarWidth: { smallWidth: 0, mediumWidth: 0, largeWidth: 0 },
      enableMiniBarBackground: false,
      barLayoutMode: HdsBarLayoutMode.HORIZONTAL,
      miniBarStyle: HdsBarStyle.COLLAPSE,
      onBarStyleChange: (miniStyle: HdsBarStyle, tabStyle: HdsBarStyle, miniWidth: number,
        tabWidth: number, mode: HdsTabsBarChangeMode): void => {
        this.miniBarExpanded = miniStyle === HdsBarStyle.EXPAND;
      }
    };
    return bar;
  }

  /** 迷你栏内容：AI 按钮 / AI 按钮 + 草稿 + 发送（折叠时只露出第一枚按钮）。
   * AI 按钮与输入框暂时注释（用户要求先隐藏），容器保留——收起动效不受影响。 */
  @Builder
  AiMiniBarRow() {
    Row({ space: 8 }) {
      /*
       * TODO: AI 输入暂时下线，后续接回时恢复这一段
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
        .onChange((value: string) => {
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
      */
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

  private avatarUrl(): string {
    return ImageUrls.resolve(AppModel.origin(), this.model.session?.avatar_url ?? null, null) ?? '';
  }

  @Builder
  TabIcon(tab: AppTabItem) {
    if (tab.title === '我的') {
      Stack() {
        // 姓名缩写只在没头像时兜底：垫在头像底下会从图边缘若隐若现地露出来
        if (this.avatarUrl().length === 0) {
          Text(Permissions.initialsOf(this.model.session?.nickname ?? ''))
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.bg)
        }
        if (this.avatarUrl().length > 0) {
          RemoteImage({ url: this.avatarUrl(), placeholderSymbol: $r('sys.symbol.person_crop_circle_fill') })
            .width(26).height(26)
        }
      }
      .width(26).height(26).borderRadius(13).clip(true)
      .linearGradient({ angle: 180, colors: [[Theme.accentStrong, 0], [Theme.accent2, 1]] })
      .id('app-tab-avatar')
    } else if (tab.imageIcon !== undefined) {
      Image(tab.imageIcon).width(26).height(26).fillColor(Theme.accentStrong)
    } else {
      SymbolGlyph(tab.icon).fontSize(26).fontColor([Theme.accentStrong])
    }
  }

  @Builder
  TabLabel(tab: AppTabItem, index: number) {
    Column({ space: 2 }) {
      this.TabIcon(tab)
      if (!this.tabBarStyle.floating) {
        Text(tab.title).fontSize(10).fontColor(Theme.accentStrong)
      }
    }
    .width('100%').height(48).justifyContent(FlexAlign.Center)
    // 未选中页签压 0.65 区分选中态；「我的」例外——头像是照片，压透明会发灰
    .opacity(this.currentTab === index || tab.title === '我的' ? 1 : 0.65)
    .backgroundColor(this.currentTab === index && !this.tabCollapsed() ? Theme.accentSoft : Color.Transparent)
    .borderRadius(24)
    .visibility(this.chrome.immersive ? Visibility.Hidden : Visibility.Visible)
    .id(`app-tab-${tab.title}`)
    .accessibilityGroup(true)
    .accessibilityText(tab.title)
    .accessibilitySelected(this.currentTab === index)
  }

  build() {
    Stack() {
      this.Tabs()
      /*
       * 经典贴底栏：Tabs 垫的手势区 padding 会被 Tabs 自己的 bg 背景刷掉——在 Tabs
       * 之上垫一条带子把栏底接到屏幕底。经典栏实际渲的是 HDS 默认深色面板（实测
       * ≈ Theme.surface，barBackgroundColor 传什么都不改变它），带子必须跟它同色，
       * 两处统一用 Theme.surface 才无缝；整屏页（底栏隐藏）不垫。
       * 手势区只垫一半：栏往下压，与小白条的间距缩半；带子与 padding 同高。
       */
      if (!this.tabBarStyle.floating && !this.chrome.immersive) {
        Row()
          .width('100%')
          .height(WindowInsets.shared().bottom / 2)
          .backgroundColor(Theme.surface)
      }
      // 官方悬浮底栏上方的「接着看」条（贴底对齐，抬到底栏之上；可见性见 resumeItem）
      if (this.resumeItem() !== null) {
        ResumeBar({
          item: this.resumeItem() as UpNextItemView,
          // 跟着底栏一起收：滚动向下时整条下移、缩窄，和页签栏的圆钮同高同线
          compact: this.resumeCompact(),
          onHide: (): void => {
            this.resume.hide();
          }
        })
          .margin({
            left: this.resumeCompact() ? this.resumeCompactLeft() : this.resumeBarLeft(),
            right: this.resumeCompact() ? this.resumeCompactRight() : this.resumeBarRight(),
            /*
             * 展开：底栏高度（悬浮 56+12 / 贴底 56）+ 手势区，再留 12 呼吸；
             * 收起：与底栏圆钮同一条水平线（抬起 12 + 手势区）。
             */
            bottom: this.resumeCompact()
              ? 12 + WindowInsets.shared().bottom
              : (this.tabBarStyle.floating ? 56 + 12 : 56) + WindowInsets.shared().bottom + 12
          })
          .id('app-resume-bar')
          .onAppear((): void => { this.syncAccessoryInset(); })
          .onDisAppear((): void => { this.syncAccessoryInset(); })
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
        // 导航栈与悬浮材质交给 HdsTabs；图标和头像对齐 iPhone。
        .tabBar(this.TabLabel(tab, index))
      }, (tab: AppTabItem, index: number) => `${tab.title}-${index}`)
    }
    .scrollable(false)
    // 栏高固定 56：悬浮样式的默认值就是 56，贴底模式也按同一个口径（见 Theme.tabBarInset）。
    // 整屏页把经典栏收成 0：applyHideAnimation 只藏了页签，栏本身仍盖在页面底部、点它还会切页签
    .barHeight(this.chrome.immersive && !this.tabBarStyle.floating ? 0 : 56)
    /*
     * 两种模式都 barOverlap=true：内容铺到栏底下、页面用 Theme.tabBarInset 让位
     * （悬浮/经典同一口径）。悬浮样式（设置里的「底栏样式」）官方要求
     * barPosition=End、vertical=false、barOverlap=true；经典贴底栏不给
     * barFloatingStyle，走官方默认整宽底栏，但整棵 Tabs 垫手势区 padding 抬离小白条
     * （悬浮模式的抬离由 barBottomMargin 负责，经典没有对应接口）。
     */
    .barOverlap(true)
    .padding({ bottom: this.tabBarStyle.floating ? 0 : WindowInsets.shared().bottom / 2 })
    .vertical(false)
    .barFloatingStyle(this.tabBarStyle.floating ? this.floatingStyle() : undefined)
    // 经典栏实际渲 HDS 默认深色面板（≈ Theme.surface），这里显式传同一个色：与手势区
    // 垫的带子（build 里的 Row）统一，barBackgroundColor 生不生效两块都无缝
    .barBackgroundColor(this.tabBarStyle.floating ? Color.Transparent : Theme.surface)
    .onChange((index: number) => {
      this.currentTab = index;
      const title: string = this.visibleTabs()[index].title;
      NavStacks.currentKey = title;
      this.syncAccessoryInset();
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
