/**
 * A–Z 索引要等分页回来才发，慢的那次会晚于下一次筛选。
 * 查询键在等待期间变了就丢掉结果，避免旧索引盖住新墙。
 */
export class WallIndexGuard {
  static async load<T>(requestedKey: string, currentKey: () => string, fetchIndex: () => Promise<T>): Promise<T | null> {
    try {
      const entries: T = await fetchIndex();
      if (requestedKey !== currentKey()) {
        return null;
      }
      return entries;
    } catch (error) {
      if (requestedKey !== currentKey()) {
        return null;
      }
      throw error;
    }
  }
}
