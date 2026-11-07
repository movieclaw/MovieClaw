/**
 * 查询身份守卫：只让当前这次查询的结果落地。
 * 单库墙的 A–Z 索引用它——快速切筛选/排序时，旧条件的索引晚到会盖掉新索引，
 * 点字母就会按旧 offset 跳错位置（PR #1205 维护者 P1）。
 *
 * 用法：查询入口（reloadWall 一开始、在任何 await 之前）调用 begin() 拿到身份；
 * 轮询刷新在开始时用 current() 记下身份（不作废进行中的查询）。之后每次发请求都用
 * run(身份, 请求)：身份已过期就不发请求，请求回来（成功或失败）时身份过期也丢弃。
 */
export class LatestRequestGate {
  private ticket: number = 0;

  /** 开始一次新查询：此前所有身份全部作废 */
  begin(): number {
    this.ticket += 1;
    return this.ticket;
  }

  /** 当前查询的身份（轮询刷新用，不作废任何东西） */
  current(): number {
    return this.ticket;
  }

  isCurrent(ticket: number): boolean {
    return ticket === this.ticket;
  }

  /**
   * 以 ticket 的身份发请求。返回 undefined = 身份已过期（请求没发，或结果已作废），调用方不得提交；
   * 过期请求的失败也吞掉，免得旧查询的失败清掉新索引。
   */
  async run<T>(ticket: number, request: () => Promise<T>): Promise<T | undefined> {
    if (!this.isCurrent(ticket)) {
      return undefined;
    }
    let value: T;
    try {
      value = await request();
    } catch (error) {
      if (!this.isCurrent(ticket)) {
        return undefined;
      }
      throw error as Error;
    }
    return this.isCurrent(ticket) ? value : undefined;
  }
}
