/**
 * 个人五星半打分纯函数格式化（1..10 刻度 → '0.5'..'5.0'，与 UI 解耦供全端与单测共用）。
 */
export function formatUserStars(rating: number | null | undefined): string {
  const r: number = rating ?? 0;
  if (r <= 0) {
    return '';
  }
  const stars: number = r / 2;
  return Number.isInteger(stars) ? `${stars}.0` : `${stars.toFixed(1)}`;
}
