/**
 * 全局外壳（底部标签栏）的显隐状态。
 *
 * 为什么需要它：iOS 上播放器、片段、AI 会话这三页是**盖住标签栏**的整屏页面
 * （`MainTabView` 里明确写了「当前停在片段页…隐藏标签栏」「AI 会话页隐藏标签栏」）。
 * 而鸿蒙这边标签栏挂在 `MainTabsPage` 的 `HdsTabs` 上，**压栈的页面改不了它**，
 * 所以用一个全局对象把「现在有没有整屏页在最上面」告诉标签栏。
 *
 * 用法：整屏页在 `onReady` 里 `push(tag)`、在 `aboutToDisappear` 里 `pop(tag)`。
 * 用**栈**而不是布尔值：播放器 → 片段 → 会话可能叠着，用布尔值会在内层退出时误判成「都退干净了」。
 */
@ObservedV2
export class ShellChrome {
  private static instance: ShellChrome | null = null;

  /** 懒建单例：`@ObservedV2` 的类不能用静态字段初始化器（会拿不到订阅） */
  static get shared(): ShellChrome {
    if (ShellChrome.instance === null) {
      ShellChrome.instance = new ShellChrome();
    }
    return ShellChrome.instance;
  }

  /** 当前压在上面的整屏页标记（底 → 顶） */
  @Trace private stack: string[] = [];

  push(tag: string): void {
    if (this.stack.includes(tag)) {
      return;
    }
    this.stack = this.stack.concat([tag]);
  }

  pop(tag: string): void {
    this.stack = this.stack.filter((value: string): boolean => value !== tag);
  }

  /** 有没有整屏页在最上面：有就让标签栏收起 */
  get immersive(): boolean {
    return this.stack.length > 0;
  }

  /** 跨页切页签的处理器：外壳（MainTabsPage）挂载时注册（对应 iOS `router.open(.libraryHome)`） */
  private static tabHandler: ((tab: string) => void) | null = null;

  static observeTabs(handler: (tab: string) => void): void {
    ShellChrome.tabHandler = handler;
  }

  /** 切到某个页签（'library' / 'discover'，按 MainTabsPage.visibleTabs 解析实际下标）；外壳没挂载时忽略 */
  static openTab(tab: string): void {
    const handler: ((tab: string) => void) | null = ShellChrome.tabHandler;
    if (handler !== null) {
      handler(tab);
    }
  }
}
