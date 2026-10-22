/** 与 Apple 客户端一致；选择只属于本次播放，连续剧换集保留，不写全局偏好。 */
export const DISPLAY_MODES = [
  { id: "fit", label: "完整显示", hint: "保持比例，显示完整画面" },
  { id: "fill", label: "铺满裁切", hint: "保持比例，填满屏幕，可能裁去边缘" },
  { id: "stretch", label: "拉伸铺满", hint: "填满屏幕，画面比例会改变" },
] as const;

export type DisplayMode = (typeof DISPLAY_MODES)[number]["id"];
export type DisplaySelection = { mediaItemId: number; mode: DisplayMode };

export function currentDisplaySelection(selection: DisplaySelection | null, mediaItemId: number): DisplaySelection | null {
  return selection?.mediaItemId === mediaItemId ? selection : null;
}

export function displayLayout(mode: DisplayMode, cw: number, ch: number, vw: number, vh: number) {
  const fallback = { bottomInset: 0, height: ch, objectFit: "contain" as "contain" | "cover" | "fill" };
  if (![cw, ch, vw, vh].every((value) => Number.isFinite(value) && value > 0)) return fallback;
  const objectFit: "fill" | "cover" | "contain" = mode === "stretch" ? "fill" : mode === "fill" ? "cover" : "contain";
  const scale = objectFit === "cover" ? Math.max(cw / vw, ch / vh) : Math.min(cw / vw, ch / vh);
  // 字幕锚定可见部分；不能随画面放大到屏幕之外。
  const height = objectFit === "fill" ? ch : Math.min(ch, vh * scale);
  return { bottomInset: (ch - height) / 2, height, objectFit };
}

/** ASS 的定位与特效属于视频坐标：对默认 contain 画布施加与视频相同的缩放。 */
export function subtitleCanvasTransform(mode: DisplayMode, cw: number, ch: number, vw: number, vh: number): string {
  if (mode === "fit" || ![cw, ch, vw, vh].every((v) => Number.isFinite(v) && v > 0)) return "none";
  const contain = Math.min(cw / vw, ch / vh);
  const sx = mode === "stretch" ? cw / vw : Math.max(cw / vw, ch / vh);
  const sy = mode === "stretch" ? ch / vh : sx;
  return `scale(${sx / contain}, ${sy / contain})`;
}
