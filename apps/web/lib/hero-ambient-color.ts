"use client";

import { useEffect, useState } from "react";

import { withImageWidth } from "./image-width.ts";

/**
 * 沉浸 Hero 的「氛围底色」取色：从当前那张剧照里取一个能当页面底色的主色。
 *
 * 移植自原生 App 的 ImmersiveHeroAmbientColor（apps/apple/MovieClaw/DesignSystem/ImmersiveHero.swift）：
 * - 缩到 24×24 取样，每个像素按「饱和度² ×（亮度 + 0.25）」加权，色相按单位圆求平均
 *   （避免红色 0/1 两端相消）；灰黑白（亮度 ≤ 0.12 或色差 ≤ 0.04）不参与；
 * - 亮度统一压到 0.44 的深色档，饱和度夹在 0.28~0.72：上面的白字永远读得清；
 * - 有效权重太少（灰调剧照：黑白片、夜景）回落冷银灰，与银玻璃的强调色同一家族。
 *
 * 画布读像素要求图片不「污染」画布：跨源图必须走带 CORS 的请求。网页端的图一律经
 * 后端 /images/proxy 同源代理（lib/image-proxy.ts），同源时直接读；API 在另一个源
 * （开发环境前后端分端口）时带 crossOrigin 请求，服务端不给 CORS 头就读不到——
 * 取不到一律返回 null，页面退回纯黑底，不报错。
 */

/** 氛围色（0~255 的 RGB） */
export interface AmbientRgb {
  r: number;
  g: number;
  b: number;
}

/** 取样边长：24×24 足够代表整张图的色调，计算量可以忽略 */
const SIDE = 24;

/** 灰调剧照的回落色：冷银灰（HSB 0.61 / 0.14 / 0.36） */
export const AMBIENT_FALLBACK: AmbientRgb = hsbToRgb(0.61, 0.14, 0.36);

/** HSB（均为 0~1）→ RGB（0~255），与 SwiftUI Color(hue:saturation:brightness:) 同一换算 */
export function hsbToRgb(hue: number, saturation: number, brightness: number): AmbientRgb {
  const h = ((hue % 1) + 1) % 1 * 6;
  const c = brightness * saturation;
  const x = c * (1 - Math.abs((h % 2) - 1));
  const m = brightness - c;
  const [r, g, b] =
    h < 1 ? [c, x, 0] : h < 2 ? [x, c, 0] : h < 3 ? [0, c, x] : h < 4 ? [0, x, c] : h < 5 ? [x, 0, c] : [c, 0, x];
  return {
    r: Math.round((r + m) * 255),
    g: Math.round((g + m) * 255),
    b: Math.round((b + m) * 255),
  };
}

/** RGBA 像素数组（canvas getImageData 的格式）→ 氛围色；纯函数，便于单测 */
export function dominantAmbient(data: ArrayLike<number>): AmbientRgb {
  let x = 0;
  let y = 0;
  let saturationSum = 0;
  let weightSum = 0;
  for (let index = 0; index + 3 < data.length; index += 4) {
    const r = data[index] / 255;
    const g = data[index + 1] / 255;
    const b = data[index + 2] / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const delta = max - min;
    if (max <= 0.12 || delta <= 0.04) continue;
    const s = delta / max;
    let hue = max === r ? (g - b) / delta : max === g ? 2 + (b - r) / delta : 4 + (r - g) / delta;
    hue /= 6;
    if (hue < 0) hue += 1;
    const weight = s * s * (max + 0.25);
    x += Math.cos(hue * 2 * Math.PI) * weight;
    y += Math.sin(hue * 2 * Math.PI) * weight;
    saturationSum += s * weight;
    weightSum += weight;
  }
  if (weightSum <= 2) return AMBIENT_FALLBACK;
  let hue = Math.atan2(y, x) / (2 * Math.PI);
  if (hue < 0) hue += 1;
  const meanSaturation = saturationSum / weightSum;
  return hsbToRgb(hue, Math.min(0.72, Math.max(0.28, meanSaturation * 1.1)), 0.44);
}

/** 按图片地址缓存：轮播回到同一张不再计算 */
const cache = new Map<string, AmbientRgb | null>();

/** 加载图片并取氛围色；读不到像素（跨源无 CORS、加载失败）返回 null */
export async function heroAmbientColor(url: string): Promise<AmbientRgb | null> {
  if (cache.has(url)) return cache.get(url) ?? null;
  const color = await new Promise<AmbientRgb | null>((resolve) => {
    const img = new Image();
    try {
      if (new URL(url, window.location.href).origin !== window.location.origin) {
        img.crossOrigin = "anonymous";
      }
    } catch {
      // 地址解析不了就按同源试一次
    }
    img.decoding = "async";
    img.onload = () => {
      try {
        const canvas = document.createElement("canvas");
        canvas.width = SIDE;
        canvas.height = SIDE;
        const context = canvas.getContext("2d", { willReadFrequently: true });
        if (!context) return resolve(null);
        context.drawImage(img, 0, 0, SIDE, SIDE);
        resolve(dominantAmbient(context.getImageData(0, 0, SIDE, SIDE).data));
      } catch {
        // 画布被跨源图污染：读不到像素
        resolve(null);
      }
    };
    img.onerror = () => resolve(null);
    // 缩到 24×24 取样，取 240 档小图就够（设计稿 image-sizing.md §6），不解整张大图
    img.src = withImageWidth(url, 240);
  });
  cache.set(url, color);
  return color;
}

/**
 * 当前 Hero 那张剧照的氛围色。换图时保留上一张的颜色直到新颜色算出来
 * （底色交叉淡入由 HeroAmbientBackdrop 负责），url 为空时清空。
 */
export function useHeroAmbientColor(url: string | null | undefined): AmbientRgb | null {
  const [color, setColor] = useState<AmbientRgb | null>(null);
  useEffect(() => {
    if (!url) {
      setColor(null);
      return;
    }
    let cancelled = false;
    void heroAmbientColor(url).then((next) => {
      if (!cancelled && next) setColor(next);
    });
    return () => {
      cancelled = true;
    };
  }, [url]);
  return color;
}
