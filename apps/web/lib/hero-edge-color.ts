import { useEffect, useState } from "react";

import { withImageWidth } from "./image-width.ts";

/**
 * 详情页底色：取大图**露出部分**底边的颜色，整页铺它，大图底部渐变到同一个颜色，
 * 图与页面之间没有接缝（银玻璃手机的影片详情 / 媒体库条目详情）。
 *
 * 移植自原生 App 的 HeroEdgeColor.pageColor（apps/apple/MovieClaw/DesignSystem/ImmersiveHero.swift）：
 * - 按显示方式算露出区域：大图是 object-cover 居中裁切，横版剧照在竖向画框里左右被裁、
 *   只有海报时上下被裁——取的是裁切后那块画面的底边，而不是原图的底边，交界处才对得上；
 * - 取露出区最底下 6% 那一条，缩到 24×4 求平均色；
 * - 色相原样、饱和度 ×1.1，亮度封顶 0.34：详情页一屏全是白字与浅灰小字，底色再亮小字就读不清；
 *   本来就暗的底边（夜景、黑边）保持原样，页面就是近黑；
 * - 结果按「地址 + 显示比例」缓存，返回同一部作品不再计算。
 *
 * 读像素要求图片与页面同源（canvas 不能被跨域图片污染）：页面上的大图地址已经走后端
 * 同源图片代理（lib/image-proxy.ts）；万一读不到（跨域部署未放行 CORS、图挂了），返回 null，
 * 页面回落黑底——与取到颜色之前的样子一样，只是不再淡入。
 */

/** 露出区域（像素坐标，原点在左上）：等比填满 containerAspect（宽 / 高）的画框、居中裁切后看得见的那块 */
export function visibleRect(
  width: number,
  height: number,
  containerAspect: number,
): { x: number; y: number; width: number; height: number } {
  if (width / height > containerAspect) {
    const shown = height * containerAspect;
    return { x: (width - shown) / 2, y: 0, width: shown, height };
  }
  const shown = width / containerAspect;
  return { x: 0, y: (height - shown) / 2, width, height: shown };
}

/** 底边平均色（0–255 的 RGB）换算成页面底色：饱和度 ×1.1、亮度封顶 0.34 */
export function pageColorFromEdge(r: number, g: number, b: number): string {
  // RGB → HSV
  const rn = r / 255;
  const gn = g / 255;
  const bn = b / 255;
  const max = Math.max(rn, gn, bn);
  const min = Math.min(rn, gn, bn);
  const delta = max - min;
  let hue = 0;
  if (delta > 0) {
    if (max === rn) hue = ((gn - bn) / delta) % 6;
    else if (max === gn) hue = (bn - rn) / delta + 2;
    else hue = (rn - gn) / delta + 4;
    hue *= 60;
    if (hue < 0) hue += 360;
  }
  const saturation = Math.min(1, (max === 0 ? 0 : delta / max) * 1.1);
  const value = Math.min(0.34, max);
  // HSV → RGB
  const c = value * saturation;
  const x = c * (1 - Math.abs(((hue / 60) % 2) - 1));
  const m = value - c;
  const [r1, g1, b1] =
    hue < 60 ? [c, x, 0] : hue < 120 ? [x, c, 0] : hue < 180 ? [0, c, x] : hue < 240 ? [0, x, c] : hue < 300 ? [x, 0, c] : [c, 0, x];
  const to255 = (channel: number) => Math.round((channel + m) * 255);
  return `rgb(${to255(r1)} ${to255(g1)} ${to255(b1)})`;
}

const BAND_COLUMNS = 24;
/** 取色用的小图宽度（阶梯档） */
const SAMPLE_WIDTH = 240;
const BAND_ROWS = 4;
const cache = new Map<string, string>();

function loadImage(url: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    // 同源代理地址下这一项无副作用；跨域部署时要求后端放行 CORS，否则 onerror 回落黑底
    img.crossOrigin = "anonymous";
    img.decoding = "async";
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("大图加载失败"));
    // 取色只看 24×4 的底边条带，取 240 档小图就够（设计稿 image-sizing.md §6）：
    // 不必为一个颜色去解一整张 2560 宽的大图
    img.src = withImageWidth(url, SAMPLE_WIDTH);
  });
}

/** 取大图露出部分底边色对应的页面底色；读不到返回 null */
export async function heroEdgeColor(url: string, containerAspect: number): Promise<string | null> {
  if (!url || !(containerAspect > 0)) return null;
  const key = `${url}#${Math.round(containerAspect * 100)}`;
  const hit = cache.get(key);
  if (hit) return hit;
  try {
    const img = await loadImage(url);
    const width = img.naturalWidth;
    const height = img.naturalHeight;
    if (!width || !height) return null;
    const visible = visibleRect(width, height, containerAspect);
    const bandHeight = Math.max(1, visible.height * 0.06);
    const canvas = document.createElement("canvas");
    canvas.width = BAND_COLUMNS;
    canvas.height = BAND_ROWS;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    if (!context) return null;
    context.imageSmoothingQuality = "medium";
    context.drawImage(
      img,
      visible.x,
      visible.y + visible.height - bandHeight,
      visible.width,
      bandHeight,
      0,
      0,
      BAND_COLUMNS,
      BAND_ROWS,
    );
    // 跨域图片会在这里抛 SecurityError（画布被污染），交给 catch 回落
    const { data } = context.getImageData(0, 0, BAND_COLUMNS, BAND_ROWS);
    let r = 0;
    let g = 0;
    let b = 0;
    for (let index = 0; index < data.length; index += 4) {
      r += data[index];
      g += data[index + 1];
      b += data[index + 2];
    }
    const count = data.length / 4;
    const color = pageColorFromEdge(r / count, g / count, b / count);
    cache.set(key, color);
    return color;
  } catch {
    return null;
  }
}

/**
 * 大图画框的页面底色：画框（container）挂上、地址就绪后按它当下的宽高比取色。
 * 取到之前与取不到时都是 null（页面按黑底画）；换图时保留旧色直到新色算出，不闪黑。
 */
export function useHeroEdgeColor(src: string | undefined, container: HTMLElement | null): string | null {
  const [color, setColor] = useState<string | null>(null);
  useEffect(() => {
    if (!src || !container || !container.clientHeight) return;
    let cancelled = false;
    void heroEdgeColor(src, container.clientWidth / container.clientHeight).then((next) => {
      if (!cancelled) setColor(next);
    });
    return () => {
      cancelled = true;
    };
  }, [src, container]);
  return color;
}
