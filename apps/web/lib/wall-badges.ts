/**
 * 海报墙请求当前要带的 `badges` 参数（见 lib/poster-badges.ts 的 posterBadgeRequest）。
 *
 * 值由 UiPrefsProvider 按生效的角标开关写入；墙的取数函数（listLibraryItems /
 * listKindItems / listCollectionItems / listSimilarItems / listFavorites）在发请求那一刻
 * 读它，于是每一处调用都自动带上、不必层层传参，也不会有哪处漏带。开关变了以后已
 * 加载的墙要重取一遍才有新字段——那由墙自己做（components/poster-badges.tsx 的
 * useWallBadgesRefetch）。
 *
 * 纯模块（不依赖 React / `@/` 别名），`node --test` 直接跑。
 */

let current = "";

/** 写入当前的分组串（"" = 一个都不要）。 */
export function setWallBadgeRequest(value: string): void {
  current = value;
}

/** 当前的分组串；"" = 一个都不要。 */
export function wallBadgeRequest(): string {
  return current;
}

/** 有要请求的角标时把 `badges` 加进查询串；全关时不加（请求与没有角标时一模一样）。 */
export function appendWallBadges(query: URLSearchParams): URLSearchParams {
  if (current) query.set("badges", current);
  return query;
}
