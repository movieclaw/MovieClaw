import { display, promptAction } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { Theme } from '../theme/AppTheme';
import { WindowInsets } from '../common/WindowInsets';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { ShellChrome } from '../common/ShellChrome';
import { SessionView } from '../api/Models';
import { LibraryNavHost } from '../library/LibraryNavHost';
import { DiscoverNavHost } from '../discover/DiscoverNavHost';
import { SubscriptionsNavHost } from '../subscriptions/SubscriptionsNavHost';
import { ActivityNavHost } from '../activity/ActivityNavHost';
import { MoreNavHost } from './MoreNavHost';
import { SubscribeCenter } from '../subscriptions/SubscribeCenter';
import { SubscribeSheetContent } from '../subscriptions/SubscribeSheet';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import { AccountSwitcherSheet } from '../common/AccountSwitcherSheet';
import { AppPhase } from '../common/AppModel';
import { SavedServer } from '../common/SavedServers';
import { AccountView } from '../api/Models';
import { MorePage } from './MorePage';
import { NavStacks, ShareRouter } from '../common/ShareLinks';
import { SharePageParams } from '../share/SharePage';
import { ResumeBar, ResumeBarStore } from './ResumeAccessory';
import { UpNextItemView } from '../api/Models';

/** 页签定义：图标（未选中/选中）+ 标题 + 权限门槛（对齐 iOS MainTab） */
interface TabSpec {
  icon: Resource;
  activeIcon: Resource;
  title: string;
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
  /** 长按头像页签弹出的切换账号抽屉（对应 iOS `AccountSwitcherSheet` 的长按入口） */
  /**
   * 切换账号用**华为原生的自定义弹窗**呈现（长按头像页签弹出），不是 `bindSheet`：
   * 系统负责遮罩、进出场动效、点遮罩关闭。`accountDialogId` 是系统给的弹窗句柄。
   */
  @Local private accountDialogId: number = -1;
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
    const ctx: Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      this.resume.init(ctx)
        .then((): Promise<void> => {
          return this.resume.refresh(this.model.api);
        })
        .catch((): void => {
        });
    }
  }

  /** 整屏页（播放器/会话/片段）关掉了：最近播放可能变了，「接着看」重新取一次 */
  @Monitor('chrome')
  onChromeImmersiveChange(): void {
    if (!this.chrome.immersive) {
      this.resume.refresh(this.model.api);
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
    }
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
    const tabs: TabSpec[] = this.visibleTabs();
    if (this.currentTab >= 0 && this.currentTab < tabs.length
      && tabs[this.currentTab].title === '我的' && this.permissions.isAdmin) {
      return null;
    }
    return this.resume.visibleItem;
  }

  /**
   * 双击头像页签：切回上一个账号（跨服务器也算）——在最近用的两个账号之间来回切，结果可预期
   * （同 Instagram、对应 iOS `switchToPreviousAccount`）。本机只有当前这一个账号时什么都不做。
   */
  private async onAvatarDoubleTap(): Promise<void> {
    try {
      const switched: boolean = await this.model.switchToPreviousAccount();
      if (!switched) {
        this.toast('这台设备上只有当前这一个账号');
      }
    } catch (error) {
      const err = error as Error;
      this.toast(err.message.length > 0 ? err.message : '切换失败');
    }
  }

  /** 按权限得出可见页签的规格（顺序即底栏从左到右，同 iOS visibleTabs） */
  private visibleTabs(): TabSpec[] {
    this.permissions = Permissions.fromSession(this.model.session);
    const tabs: TabSpec[] = [this.libraryTab()];
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

  private libraryTab(): TabSpec {
    // iOS `play.square.stack` 的华为对应：未选中 play_square，选中 play_square_stack_fill
    return { icon: $r('sys.symbol.play_square'), activeIcon: $r('sys.symbol.play_square_stack_fill'), title: '媒体库' };
  }

  private subscriptionsTab(): TabSpec {
    return { icon: $r('sys.symbol.bookmark'), activeIcon: $r('sys.symbol.bookmark_fill'), title: '订阅' };
  }

  private discoverTab(): TabSpec {
    return { icon: $r('sys.symbol.discover'), activeIcon: $r('sys.symbol.discover_fill'), title: '发现' };
  }

  private activityTab(): TabSpec {
    // iOS `waveform.path.ecg`（心电波）的华为对应：waveform
    return { icon: $r('sys.symbol.waveform'), activeIcon: $r('sys.symbol.waveform'), title: '活动' };
  }

  private moreTab(): TabSpec {
    // iOS 最后一个页签是**头像**（person.crop.circle），页名叫「我的」，不是「更多」
    return { icon: $r('sys.symbol.person_crop_circle_fill'), activeIcon: $r('sys.symbol.person_crop_circle_fill'), title: '我的' };
  }

  build() {
    Stack() {
      this.Tabs()
      // 悬浮胶囊底栏上方的「接着看」条（贴底对齐，抬到底栏之上；可见性见 resumeItem）
      if (this.resumeItem() !== null) {
        ResumeBar({
          item: this.resumeItem() as UpNextItemView,
          onHide: (): void => {
            this.resume.hide();
          }
        })
          .margin({ left: 16, right: 16, bottom: 80 })
      }
      // AgentQuickInput 已移到 MorePage 内部
    }
    .alignContent(Alignment.Bottom)
    .width('100%')
    .height('100%')
    /*
     * 窗口是全屏布局（EntryAbility setWindowLayoutFullScreen(true)），底部避让由这里统一做：
     * 把页签内容（含悬浮胶囊底栏）的结束线抬回手势指示条上面——
     * 几何与「系统避让安全区」时代完全一致，白条底下露窗口底色（纯黑）。
     */
    .padding({ bottom: WindowInsets.bottom })
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
   * 拉起「切换账号」原生弹窗：底部对齐、点遮罩可关。
   * 高度取屏幕的六成（同 iOS `.presentationDetents([.medium, .large])` 的 medium 手感），
   * 内容自己撑满这一块（`AccountSwitcherSheet` 的根是 `height('100%')`）。
   */
  private openAccountSwitcher(): void {
    let screenWidthVp: number = 360;
    try {
      screenWidthVp = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    } catch (e) {
    }
    const options: promptAction.CustomDialogOptions = {
      builder: (): void => {
        this.AccountSwitcherCard();
      },
      /*
       * 与「批准设备登录」**完全同一套弹窗样式**：贴底、圆角卡片、屏宽减 32（左右各 16vp）、
       * 底色 surfaceRaised。高度不写：由内容决定（账号少就矮、多就高），内容自己用 maxHeight 封顶。
       */
      width: Math.round(screenWidthVp - 32),
      alignment: DialogAlignment.Bottom,
      keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
      autoCancel: true,
      maskColor: 'rgba(0,0,0,0.6)',
      backgroundColor: Theme.surfaceRaised,
      cornerRadius: Theme.cardRadius
    };
    this.getUIContext().getPromptAction().openCustomDialog(options)
      .then((id: number): void => {
        this.accountDialogId = id;
      })
      .catch((): void => {
        this.accountDialogId = -1;
      });
  }

  /** 关闭「切换账号」原生弹窗 */
  private closeAccountSwitcher(): void {
    if (this.accountDialogId < 0) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().closeCustomDialog(this.accountDialogId);
    } catch (e) {
    }
    this.accountDialogId = -1;
  }

  /** 切换账号弹窗的内容（长按头像页签弹出；内容见 `AccountSwitcherSheet`） */
  @Builder
  AccountSwitcherCard() {
    AccountSwitcherSheet({
      onClose: (): void => {
        this.closeAccountSwitcher();
      }
    })
  }

  @Builder
  Tabs() {
    HdsTabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
      ForEach(this.visibleTabs(), (tab: TabSpec, index: number) => {
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
        .tabBar(this.chrome.immersive ? this.NoBar() : this.TabBarIcon(tab, index))
      }, (tab: TabSpec, index: number) => `${tab.title}-${index}`)
    }
    .barOverlap(true)
    .barFloatingStyle({
      barSideMargin: this.chrome.immersive ? 0 : 16,
      barBottomMargin: this.chrome.immersive ? 0 : 12,
      adaptToHandedness: !this.chrome.immersive,
      gradientMask: this.chrome.immersive ? undefined : { maskColor: Theme.bg, maskHeight: 96 },
      systemMaterialEffect: this.chrome.immersive ? undefined : {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .barHeight(this.chrome.immersive ? 0 : 56)
    .scrollable(false)
    .onChange((index: number) => {
      this.currentTab = index;
      NavStacks.currentKey = this.visibleTabs()[index].title;
    })
    /*
     * 点「已经选中的页签」要回到该页签的根页（iOS 标准行为：在二级页面里点底部同一个页签 = 退回首页）。
     * `onChange` 只在**换页签**时触发，所以这条必须在 `onTabBarClick` 上做。
     */
    .onTabBarClick((index: number): void => {
      const tabs: TabSpec[] = this.visibleTabs();
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
    // 窗口已是全屏布局：内容区从 y=0 铺起（订阅/发现的首屏大图因此能钻进状态栏）。
    // 其余页签由各自 NavHost 的 padding(WindowInsets.top) 推回安全区。
  }

  /** 页签图标（Instagram 式只显示图标，选中用实心 + 亮银，未选中用描边 + 暗白） */
  @Builder
  TabBarIcon(tab: TabSpec, index: number) {
    // 图标 + 文字：华为原生底栏（华为视频等）是带标签的，选中态靠颜色区分
    Column({ space: 2 }) {
      if (tab.title === '我的') {
        this.AvatarTabIcon(index)
      } else {
        SymbolGlyph(this.currentTab === index ? tab.activeIcon : tab.icon)
          .fontSize(24)
          .fontColor([this.currentTab === index ? Theme.accentStrong : Theme.textFaint])
      }
      Text(tab.title)
        .fontSize(10)
        .fontColor(this.currentTab === index ? Theme.accentStrong : Theme.textFaint)
        .maxLines(1)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    /*
     * 头像页签上的两个手势（仿 Instagram，对应 iOS `TabBarAccountGestures`）：
     * - **长按 0.45 秒**（iOS `minimumPressDuration = 0.45`）弹切换账号抽屉；
     * - **双击**切回上一个账号。
     *
     * 家里几个人共用 App、切换账号是高频操作：不用先进「我的」页、不用再点一层，
     * 在哪个页签上都能直接切。
     *
     * 两个手势互斥（`GestureMode.Exclusive`）：快速双击在 450ms 内就完成了，不会被长按吃掉。
     * 单点仍然是切页签——单击不在这个组里，由页签栏自己处理。
     */
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ duration: 450 })
          .onAction(() => {
            if (tab.title === '我的') {
              this.openAccountSwitcher();
            }
          }),
        TapGesture({ count: 2 })
          .onAction(() => {
            if (tab.title === '我的') {
              this.onAvatarDoubleTap();
            }
          })
      )
    )
  }

  /** 整屏页在上面时的空页签栏（什么都不画） */
  @Builder
  NoBar() {
    Column()
      .width(0)
      .height(0)
  }

  /** iOS 的最后一个页签是**用户头像**；没头像时退化成 person 符号，
   *  和其他页签一样做「描边→实心 + 强调色」切换，选中效果保持一致 */
  @Builder
  AvatarTabIcon(index: number) {
    if (this.avatarUrl().length > 0) {
      Stack({ alignContent: Alignment.Center }) {
        RemoteImage({
          url: this.avatarUrl(),
          placeholderSymbol: $r('sys.symbol.person_crop_circle_fill')
        })
          .width(24)
          .height(24)
          .borderRadius(12)
          .clip(true)
        if (this.currentTab === index) {
          Circle()
            .width(28)
            .height(28)
            .fillOpacity(0)
            .border({ width: 1.5, color: Theme.accentStrong })
        }
      }
    } else {
      SymbolGlyph(this.currentTab === index
        ? $r('sys.symbol.person_fill')
        : $r('sys.symbol.person'))
        .fontSize(24)
        .fontColor([this.currentTab === index ? Theme.accentStrong : Theme.textFaint])
    }
  }

  private avatarUrl(): string {
    const session: SessionView | null = AppModel.shared.session;
    const origin: string = AppModel.shared.client !== null ? AppModel.shared.client.origin : '';
    if (session === null) {
      return '';
    }
    const raw: string | null = session.avatar_url ?? null;
    const resolved: string | null = ImageUrls.resolve(origin, raw, null);
    return resolved !== null ? resolved : '';
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
