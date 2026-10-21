/** 与 Apple 客户端一致；选择只属于本次播放的文件，不写全局偏好。 */
export const DISPLAY_MODES = [
  { id: "fit", label: "完整显示", hint: "保持比例，显示完整画面" },
  { id: "fitWidth", label: "适应宽度", hint: "保持比例，左右贴边，可能裁去上下" },
  { id: "fill", label: "铺满裁切", hint: "保持比例，填满屏幕，可能裁去边缘" },
  { id: "stretch", label: "拉伸铺满", hint: "填满屏幕，画面比例会改变" },
] as const;

export type DisplayMode = (typeof DISPLAY_MODES)[number]["id"];

export function nextDisplayMode(mode: DisplayMode): DisplayMode {
  return DISPLAY_MODES[(DISPLAY_MODES.findIndex((option) => option.id === mode) + 1) % DISPLAY_MODES.length].id;
}

export function displayLayout(mode: DisplayMode, cw: number, ch: number, vw: number, vh: number) {
  const fallback = { bottomInset: 0, height: ch, objectFit: "contain" as "contain" | "cover" | "fill" };
  if (![cw, ch, vw, vh].every((value) => Number.isFinite(value) && value > 0)) return fallback;
  const objectFit: "fill" | "cover" | "contain" = mode === "stretch" ? "fill" : mode === "fill" || (mode === "fitWidth" && cw / vw > ch / vh) ? "cover" : "contain";
  const scale = objectFit === "cover" ? Math.max(cw / vw, ch / vh) : Math.min(cw / vw, ch / vh);
  // 字幕锚定可见部分；不能随画面放大到屏幕之外。
  const height = objectFit === "fill" ? ch : Math.min(ch, vh * scale);
  return { bottomInset: (ch - height) / 2, height, objectFit };
}
