/**
 * 会话集合变化的信号（新建 / 删除 / 重命名后 +1）。
 *
 * 为什么需要它：「我的」页的「最近会话」只在 `aboutToAppear` 拉一次，而会话页是**压在上面的整屏页**，
 * 退出回来时「我的」页不会重建（同 `ShellChrome` 的情形），所以新建完会话退回来看不到新会话。
 * 会话页在建会话 / 离开时 bump，列表页 `@Monitor` 到版本变化就重拉。
 */
@ObservedV2
export class AgentSessionsSignal {
  private static instance: AgentSessionsSignal | null = null;

  /** 懒建单例（`@ObservedV2` 的类不能用静态字段初始化器，会拿不到订阅） */
  static get shared(): AgentSessionsSignal {
    if (AgentSessionsSignal.instance === null) {
      AgentSessionsSignal.instance = new AgentSessionsSignal();
    }
    return AgentSessionsSignal.instance;
  }

  /** 版本号：每次会话集合可能变了就 +1 */
  @Trace version: number = 0;

  bump(): void {
    this.version = this.version + 1;
  }
}
