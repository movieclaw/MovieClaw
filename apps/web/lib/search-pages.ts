/** 一次搜索里单个站点的分页状态（SiteSearchStatus 的子集）。 */
interface SitePageStatus {
  /** 失败原因；成功为 null */
  error: string | null;
  /** 该站明确告知后面还有没有页；null / 缺省 = 不确定（老服务器没有这个字段） */
  has_more?: boolean | null;
}

/**
 * 各站都明确说没有下一页（失败或说不准的站不算）→ 不再显示「加载更多」。
 * 真实站点多半不报，照旧靠「加载一页没有新条目」判断到底。
 */
export function noMorePages(sites: SitePageStatus[]): boolean {
  return sites.length > 0 && sites.every((s) => s.error === null && s.has_more === false);
}
