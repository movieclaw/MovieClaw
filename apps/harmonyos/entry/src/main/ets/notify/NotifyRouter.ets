/**
 * 系统通知点按的中转（照 `ShareRouter` 的双消费模式）。
 *
 * wantAgent 只能带 Want 参数进 EntryAbility 的 onCreate/onNewWant；落到哪个页签、
 * 推哪个详情页由主界面决定：
 * - **冷启动**：EntryAbility.onCreate 里 handOff 早于 MainTabsPage 挂载，
 *   MainTabsPage.aboutToAppear 的延迟兜底取走；
 * - **热启动**：onNewWant 里 handOff 触发 `pendingSeq` 变化，
 *   MainTabsPage 的 `@Monitor` 取走。
 */
export class NotifyOpen {
  /** 点按落到哪个底栏页：activity（活动）/ subscriptions（订阅） */
  readonly tab: string;
  /** 具体落点：空 = 只切页签；`item/{库}/{条目}`；`subscription/{订阅id}` */
  readonly route: string;

  constructor(tab: string, route: string) {
    this.tab = tab;
    this.route = route;
  }
}

@ObservedV2
export class NotifyRouter {
  private static instance: NotifyRouter | null = null;

  static shared(): NotifyRouter {
    if (NotifyRouter.instance === null) {
      NotifyRouter.instance = new NotifyRouter();
    }
    return NotifyRouter.instance;
  }

  /** 每次点按自增；MainTabsPage 的 `@Monitor` 盯它（tab/route 本体不参与观察） */
  @Trace pendingSeq: number = 0;
  private pendingTab: string = 'activity';
  private pendingRoute: string = '';
  private consumedSeq: number = 0;

  /** EntryAbility 在 onCreate/onNewWant 里解析完 want 参数后调这里 */
  handOff(tab: string, route: string): void {
    this.pendingTab = tab.length > 0 ? tab : 'activity';
    this.pendingRoute = route;
    this.pendingSeq = this.pendingSeq + 1;
  }

  /** MainTabsPage 消费（@Monitor 与冷启动兜底各调一次；没有待处理时返回 null） */
  takePending(): NotifyOpen | null {
    if (this.pendingSeq === this.consumedSeq) {
      return null;
    }
    this.consumedSeq = this.pendingSeq;
    return new NotifyOpen(this.pendingTab, this.pendingRoute);
  }
}
