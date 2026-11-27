/**
 * 图片缓存共用的 LRU 淘汰策略（纯逻辑，无任何框架依赖，单测直测）。
 *
 * 为什么抽成独立类：内存层与磁盘层的淘汰语义完全一致——按 cost 预算淘汰、
 * 命中即续命、插入即最新——只有存储介质不同。逻辑收敛在一处，两层共用同一套
 * 经过测试的淘汰语义，避免两处手搓互相漂移。
 *
 * 语义：
 * - `touch` 把已有键移到最新端；键不存在时静默忽略（读缓存未命中也调它，不必先判）。
 * - `insert` 插入或刷新键（已存在时更新 cost 并移到最新端）。
 * - `evictOverBudget` 从最旧端弹出键直到总 cost 不超预算；返回弹出的键，由调用方负责删实体。
 */
export class ImageLruPolicy {
  /** 键 → cost（字节数或条目数，由调用方定口径） */
  private readonly costs: Map<string, number> = new Map<string, number>();
  /** 从旧到新的键序；LRU 在队头（index 0），MRU 在队尾 */
  private readonly order: string[] = [];
  private totalCost: number = 0;

  has(key: string): boolean {
    return this.costs.has(key);
  }

  size(): number {
    return this.order.length;
  }

  budget(): number {
    return this.totalCost;
  }

  /** 命中续命：移到最新端。不存在的键忽略。 */
  touch(key: string): void {
    const index: number = this.order.indexOf(key);
    if (index < 0) {
      return;
    }
    this.order.splice(index, 1);
    this.order.push(key);
  }

  /** 插入或刷新（cost 变了也走这里），落在最新端。 */
  insert(key: string, cost: number): void {
    const normalized: number = cost > 0 ? cost : 0;
    const index: number = this.order.indexOf(key);
    if (index >= 0) {
      this.order.splice(index, 1);
    }
    const previous: number | undefined = this.costs.get(key);
    if (previous !== undefined) {
      this.totalCost -= previous > 0 ? previous : 0;
    }
    this.costs.set(key, normalized);
    this.order.push(key);
    this.totalCost += normalized;
  }

  /** 精确移除一个键（缓存主动 clear 单条时用）。 */
  remove(key: string): void {
    const index: number = this.order.indexOf(key);
    if (index < 0) {
      return;
    }
    this.order.splice(index, 1);
    const cost: number | undefined = this.costs.get(key);
    if (cost !== undefined) {
      this.totalCost -= cost > 0 ? cost : 0;
      this.costs.delete(key);
    }
  }

  /**
   * 超预算时从最旧端弹键，直到总 cost 回到预算内。
   * 预算 <= 0 视为无上限（永不淘汰）。
   * 返回弹出的键（从旧到新），调用方负责删除对应的存储实体。
   */
  evictOverBudget(budget: number): string[] {
    if (budget <= 0) {
      return [];
    }
    const evicted: string[] = [];
    while (this.totalCost > budget && this.order.length > 0) {
      const oldest: string = this.order[0];
      this.order.splice(0, 1);
      const cost: number | undefined = this.costs.get(oldest);
      if (cost !== undefined) {
        this.totalCost -= cost > 0 ? cost : 0;
        this.costs.delete(oldest);
      }
      evicted.push(oldest);
    }
    return evicted;
  }

  /** 键快照（从旧到新）；给诊断页与测试用。 */
  keysSnapshot(): string[] {
    return this.order.slice();
  }

  /** 全清（协商缓存整仓失效时用；键序与 cost 计数一并归零）。 */
  clearAll(): void {
    this.costs.clear();
    this.order.splice(0, this.order.length);
    this.totalCost = 0;
  }
}
