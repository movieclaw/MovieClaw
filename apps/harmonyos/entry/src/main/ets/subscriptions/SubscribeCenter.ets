/**
 * 全局订阅入口（对应 iOS 的 `router.present(.subscribe(SubscribeRequest(...)))`）。
 *
 * 订阅弹层由外壳（`MainTabsPage`）统一托管——发现海报、发现详情、搜索结果、条目详情、
 * 媒体库「洗版」都往这里投一个请求，由外壳弹出。这样弹层只有一份，行为各处一致。
 *
 * 不是 `@ObservedV2`：外壳轮询式地读它（见 `MainTabsPage` 的定时器），
 * 因为 ArkUI 的 `bindSheet` 需要一个可观察的布尔量来驱动，而这里的「请求」是瞬时的。
 */
export class SubscribeRequest {
  readonly titleRef: string;
  readonly title: string;
  /** 洗版变体（对应 iOS 的 `request.upgrade`）：季按库存预填、自动续订默认关 */
  readonly upgrade: boolean;

  constructor(titleRef: string, title: string, upgrade: boolean = false) {
    this.titleRef = titleRef;
    this.title = title;
    this.upgrade = upgrade;
  }
}

export class SubscribeCenter {
  /** 外壳注册的处理器；没注册时请求先存着，注册时补发 */
  private static handler: ((request: SubscribeRequest) => void) | null = null;
  private static pending: SubscribeRequest | null = null;

  /** 外壳（MainTabsPage）挂载时注册 */
  static observe(handler: (request: SubscribeRequest) => void): void {
    SubscribeCenter.handler = handler;
    const waiting: SubscribeRequest | null = SubscribeCenter.pending;
    if (waiting !== null) {
      SubscribeCenter.pending = null;
      handler(waiting);
    }
  }

  static present(titleRef: string, title: string, upgrade: boolean = false): void {
    const request: SubscribeRequest = new SubscribeRequest(titleRef, title, upgrade);
    const handler = SubscribeCenter.handler;
    if (handler !== null) {
      handler(request);
    } else {
      SubscribeCenter.pending = request;
    }
  }

  /** 订阅清单需要重拉的监听者（订阅首页/海报墙挂载时注册、卸载时注销） */
  private static refreshListeners: (() => void)[] = [];

  /** 挂载中的订阅页面注册回调；同引用重复注册自动去重 */
  static observeSubsRefresh(listener: () => void): void {
    if (SubscribeCenter.refreshListeners.indexOf(listener) < 0) {
      SubscribeCenter.refreshListeners.push(listener);
    }
  }

  static unobserveSubsRefresh(listener: () => void): void {
    const at: number = SubscribeCenter.refreshListeners.indexOf(listener);
    if (at >= 0) {
      SubscribeCenter.refreshListeners.splice(at, 1);
    }
  }

  /**
   * 广播「订阅清单可能变了，请重拉」：创建/取消/删除成功后、切回订阅页签时调用。
   * 没有监听者（页面未挂载）时是空操作——首次挂载的页面自己会拉。
   */
  static announceSubsRefresh(): void {
    const listeners: (() => void)[] = SubscribeCenter.refreshListeners.slice();
    for (const listener of listeners) {
      listener();
    }
  }
}
