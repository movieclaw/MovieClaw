/**
 * 个人评分（1–10 整数 ↔ 界面 5 星半星刻度）的纯逻辑模块。
 *
 * 零外部依赖（不带 `@/` 别名），`node --test` 直接导入测试。
 * 刻度与后端对齐（docs/design/user-rating.md）：
 *   1 = 0.5★, 2 = 1.0★, ..., 9 = 4.5★, 10 = 5.0★；null = 未评分；0 = 清除请求值。
 */

export const USER_RATING_MIN = 1;
export const USER_RATING_MAX = 10;
export const STAR_COUNT = 5;

/** 是否为合法的已评分值（1–10 整数）。 */
export function isValidUserRating(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isInteger(value) &&
    value >= USER_RATING_MIN &&
    value <= USER_RATING_MAX
  );
}

/** 1–10 整数 → 0.5–5.0 星数值；未评分或非法值返回 null。 */
export function ratingToStars(rating: number | null | undefined): number | null {
  return isValidUserRating(rating) ? rating / 2 : null;
}

/** 1–10 整数 → 固定一位小数的 5 星刻度文案（如 9 → "4.5"、8 → "4.0"）。 */
export function formatStarRating(rating: number): string {
  return (rating / 2).toFixed(1);
}

/** 1–10 整数 → 紧凑的 5 星刻度文案（整星不带 .0，如 8 → "4"、9 → "4.5"）。 */
export function formatStarShort(rating: number): string {
  return rating % 2 === 0 ? String(rating / 2) : (rating / 2).toFixed(1);
}

/** 筛选门槛文案：10 写 "5★"，其余写 "≥ 4.5★" / "≥ 4★"。 */
export function formatMyRatingThreshold(minRating: number): string {
  if (minRating >= USER_RATING_MAX) return "5★";
  return `≥ ${formatStarShort(minRating)}★`;
}

/** 第 starIndex（1–5）颗星在当前活跃评分下的填充状态。 */
export function starFillState(
  starIndex: number,
  activeRating: number | null,
): "full" | "half" | "empty" {
  if (!isValidUserRating(activeRating)) return "empty";
  const fullValue = starIndex * 2;
  if (activeRating >= fullValue) return "full";
  if (activeRating === fullValue - 1) return "half";
  return "empty";
}

/** 指针落点比例（0–1）换算为第 starIndex（1–5）颗星的半星或整星值（1–10）。 */
export function starValueFromRatio(starIndex: number, ratio: number): number {
  return ratio < 0.5 ? starIndex * 2 - 1 : starIndex * 2;
}

/** 点击某档评分后的提交值：再次点击当前分返回 0（清除），否则返回目标分（1–10）。 */
export function nextRatingOnClick(
  currentRating: number | null,
  clickedRating: number,
): number {
  if (!isValidUserRating(clickedRating)) return 0;
  return currentRating === clickedRating ? 0 : clickedRating;
}

/**
 * 第一期仅开放电影与整剧评分（docs/design/user-rating.md §3）：
 * 带季号或集号，或非 movie / tv 类型一律不允许评分。
 */
export function canRateTarget(target: {
  kind: string;
  seasonNumber?: number | null;
  episodeNumber?: number | null;
}): boolean {
  if (target.kind !== "movie" && target.kind !== "tv") return false;
  if (target.seasonNumber != null || target.episodeNumber != null) return false;
  return true;
}
