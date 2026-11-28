/**
 * 发现页分页预载闸门（纯逻辑，无 UI 依赖，单测直测）：
 * - 列表空（首屏加载中/首屏报错/零结果）、已有分页错误、加载中、无更多页、或被筛选/防抖阻断时，
 *   一律禁止 onScrollIndex / onReachEnd 自动续页——失败后必须由用户点「重试」触发，避免错误重入死循环；
 * - 扣除前置非数据 ListItem（如页头、顶部占位）后再与倒数 N 行阈值比较，避免偏移误触发。
 */
export function shouldPrefetchOnScrollIndex(
  totalRows: number,
  lastVisibleListIndex: number,
  leadingListItems: number,
  thresholdRows: number,
  hasMore: boolean,
  loading: boolean,
  hasError: boolean,
  blocked: boolean
): boolean {
  if (blocked || !hasMore || loading || hasError || totalRows <= 0) {
    return false;
  }
  const lastDataRowIndex: number = lastVisibleListIndex - leadingListItems;
  if (lastDataRowIndex < 0) {
    return false;
  }
  return lastDataRowIndex >= totalRows - thresholdRows;
}

export function shouldPaginateOnReachEnd(
  totalRows: number,
  hasMore: boolean,
  loading: boolean,
  hasError: boolean,
  blocked: boolean
): boolean {
  return !blocked && hasMore && !loading && !hasError && totalRows > 0;
}
