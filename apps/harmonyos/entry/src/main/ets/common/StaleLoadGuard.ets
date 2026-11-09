/**
 * 异步装载的代次守卫（纯逻辑，主机侧可测）。
 *
 * 连点排序/筛选会并发起多轮 `load()`：每轮先 `begin()` 领一个代次，每个
 * `await` 之后回填前用 `isCurrent()` 对一下——中途又有新一轮 begin 过，旧轮
 * 从这里起整段丢弃。
 *
 * 防的是「旧请求后到把新结果盖掉」：await 前捕获的参数（排序、筛选）属于领
 * 代次那一刻的世界，await 的完成顺序不定，旧轮晚醒还会带着旧参数继续跑（比
 * 如把分页器换回旧数据源）。代次对不上就掐断，让最后发起的那一轮说了算。
 */
export class StaleLoadGuard {
  private current: number = 0;

  /** 开始一轮装载，返回这轮的代次 */
  begin(): number {
    this.current += 1;
    return this.current;
  }

  /** 回填前对一下：这轮还是不是最新一轮（false = 已被更新的装载作废） */
  isCurrent(generation: number): boolean {
    return generation === this.current;
  }
}
