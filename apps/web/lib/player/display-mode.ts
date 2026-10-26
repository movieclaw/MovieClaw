import { appTranslator } from "../i18n/translate.ts";
import { requestLocale, type AppLocale } from "../i18n/negotiate.ts";

/** 与 Apple 客户端一致；选择只属于本次播放，连续剧换集保留，不写全局偏好。 */
export type DisplayMode = "fit" | "fill" | "stretch";

export function displayModes(locale: AppLocale = requestLocale() ?? "zh-Hans") {
  const t = appTranslator(locale);
  return [
    { id: "fit", label: t("player.display.fit"), hint: t("player.display.fitHint") },
    { id: "fill", label: t("player.display.fill"), hint: t("player.display.fillHint") },
    { id: "stretch", label: t("player.display.stretch"), hint: t("player.display.stretchHint") },
  ] as const;
}

export const DISPLAY_MODES = displayModes("zh-Hans");

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
