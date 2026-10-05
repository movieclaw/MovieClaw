"use client";

import { useEffect, useState } from "react";

import { coverWidth, screenImageWidth } from "@/lib/image-width";

/**
 * 大图区（全屏沉浸背景、Hero、详情页大图）按公式算 ``w`` 的 hook
 * （公式见 lib/image-width.ts 与 docs/design/image-sizing.md §6）。
 *
 * 卡片交给 srcset 由浏览器按倍率挑；大图区通常是 CSS 背景或要预加载再换图，
 * 只能在 JS 里自己算一个宽度。这里统一监听窗口尺寸与屏幕倍率（跨屏拖动时
 * devicePixelRatio 会变，同时也会触发 resize），返回的都是**已取阶梯档**的像素宽：
 * 只有跨档才会变，窗口拖动时不会频繁换图。
 *
 * SSR / 首帧返回 0（表示「还不知道」）：调用方此时先不取图，挂载后一个效果周期
 * 就有值——大图本来就是挂载后才开始加载，晚一帧无感知，却不会白拉一张错档的图。
 */

type Viewport = { width: number; height: number; dpr: number };

/** 当前视口尺寸与屏幕倍率；挂载前为 null。 */
function useViewport(): Viewport | null {
  const [viewport, setViewport] = useState<Viewport | null>(null);
  useEffect(() => {
    const update = () =>
      setViewport((prev) => {
        const next = {
          width: window.innerWidth,
          height: window.innerHeight,
          dpr: window.devicePixelRatio || 1,
        };
        return prev && prev.width === next.width && prev.height === next.height && prev.dpr === next.dpr
          ? prev
          : next;
      });
    update();
    window.addEventListener("resize", update);
    return () => window.removeEventListener("resize", update);
  }, []);
  return viewport;
}

/**
 * 铺满整个视口的图（全站沉浸背景层）需要的像素宽：max(视口宽, 视口高 × 宽高比) × 倍率。
 * 1920×1080 的 1 倍屏 → 1920；1440×900 的 2 倍屏铺 16:9 → 3200 → 3840 档。
 */
export function useViewportCoverWidth(aspect: number, scale = 1): number {
  const viewport = useViewport();
  if (!viewport) return 0;
  return screenImageWidth(coverWidth(viewport.width, viewport.height, aspect), scale, viewport.dpr);
}

/**
 * 两个详情页（发现详情 / 媒体库条目详情）的大图宽度。两处的同一张图同时用作
 * 全站沉浸背景与手机页内 Hero（同一个 URL 浏览器只下载一次），所以按「真正看得见
 * 的那个框」算：
 *   - 桌面：全站背景铺满整窗；
 *   - 手机：页内 Hero 框 = 宽撑满 × min(115vw, 62svh)（与两页的 mobileHeroHeight 同一公式），
 *     全站背景在手机上被滚动容器挡住、只给侧栏玻璃折射用，不必按整屏高去取。
 *     393×452 点的 3 倍屏铺 16:9：按宽只要 1179，按高要约 2410 → 2560 档。
 */
export function useDetailHeroImageWidth(isMobile: boolean, aspect: number): number {
  const viewport = useViewport();
  if (!viewport) return 0;
  const boxHeight = isMobile ? Math.min(viewport.width * 1.15, viewport.height * 0.62) : viewport.height;
  return screenImageWidth(coverWidth(viewport.width, boxHeight, aspect), 1, viewport.dpr);
}

/**
 * 量一个元素的框，算铺满它需要的像素宽（框尺寸 × 倍率 × 放大系数，已取阶梯档）。
 * 用于尺寸由布局决定、JS 里算不出来的大图框（ImmersiveHero 的剧照层等）。
 * 元素用回调 ref 存进 state 再传进来；未挂载 / 未量到时返回 0。
 */
export function useElementCoverWidth(element: HTMLElement | null, aspect: number, scale = 1): number {
  const [width, setWidth] = useState(0);
  useEffect(() => {
    if (!element) return;
    const measure = () => {
      const { width: boxWidth, height: boxHeight } = element.getBoundingClientRect();
      if (boxWidth <= 0 || boxHeight <= 0) return;
      setWidth(screenImageWidth(coverWidth(boxWidth, boxHeight, aspect), scale));
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    // 跨屏拖动只改倍率、不改框尺寸，ResizeObserver 不报，靠 resize 兜住
    window.addEventListener("resize", measure);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", measure);
    };
  }, [element, aspect, scale]);
  return width;
}
