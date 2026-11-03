"use client";

import { useTranslations } from "next-intl";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { REFRESH_AT, ReelsFloorModel } from "@/lib/reels-floor";

/**
 * 手机网页媒体库首页的「下拉二楼」（与 iOS / Android 同一套交互，docs/design/reels.md §6）：
 * 用力往下拉，刷新之后露出一条冷银胶片，过线松手进片段。
 *
 * 挂在首页的滚动容器里（`host`，要带 `reels-floor-host` 类）：拉的时候给容器设
 * `--floor-pull` 与 `data-floor-pulling`，由 globals.css 把其余子元素整体下移——只在拉的时候
 * 加 transform，平时不加（transform 会困住里面 position: fixed 的弹层）。
 * 状态都在这个小组件里，拖动时只重画它自己，不重算整页。
 */
export function ReelsFloor({
  host,
  stills,
  onRefresh,
  onEnter,
}: {
  host: HTMLDivElement | null;
  /** 胶片画格：首页已经拿到的剧照地址 */
  stills: string[];
  onRefresh: () => void;
  onEnter: () => void;
}) {
  const t = useTranslations();
  const model = useMemo(() => new ReelsFloorModel(), []);
  const [, setFrame] = useState(0);
  const refresh = useRef(onRefresh);
  const enter = useRef(onEnter);
  useEffect(() => {
    refresh.current = onRefresh;
    enter.current = onEnter;
  });

  const paint = useCallback(() => {
    const el = host;
    if (el) {
      if (model.pull > 0.5) {
        el.dataset.floorPulling = "";
        el.style.setProperty("--floor-pull", `${model.pull}px`);
      } else {
        delete el.dataset.floorPulling;
        el.style.removeProperty("--floor-pull");
      }
    }
    setFrame((n) => n + 1);
  }, [host, model]);

  useEffect(() => {
    const el = host;
    if (!el) return;
    let startY = 0;
    let tracking = false;
    let raf = 0;
    const onStart = (event: TouchEvent) => {
      if (event.touches.length !== 1 || el.scrollTop > 0) {
        tracking = false;
        return;
      }
      cancelAnimationFrame(raf);
      tracking = true;
      // 回弹途中又按住：从当前拉开的位置接着拉
      startY = event.touches[0].clientY - model.drag;
      model.begin();
    };
    const onMove = (event: TouchEvent) => {
      if (!tracking) return;
      const distance = event.touches[0].clientY - startY;
      if (distance <= 0 && model.drag === 0) return;
      if (el.scrollTop > 0) {
        tracking = false;
        return;
      }
      // 自己接管越界：挡掉 iOS 的原生回弹，内容只跟着这里走
      event.preventDefault();
      if (model.dragTo(distance)) refresh.current();
      paint();
    };
    const onEnd = () => {
      if (!tracking) return;
      tracking = false;
      if (model.release()) {
        enter.current();
        model.reset();
        paint();
        return;
      }
      const from = model.drag;
      const started = performance.now();
      const step = (now: number) => {
        const k = Math.min(1, (now - started) / 380);
        model.settle(from * (1 - (1 - k) ** 3));
        paint();
        if (k < 1) raf = requestAnimationFrame(step);
      };
      raf = requestAnimationFrame(step);
    };
    el.addEventListener("touchstart", onStart, { passive: true });
    el.addEventListener("touchmove", onMove, { passive: false });
    el.addEventListener("touchend", onEnd);
    el.addEventListener("touchcancel", onEnd);
    return () => {
      cancelAnimationFrame(raf);
      el.removeEventListener("touchstart", onStart);
      el.removeEventListener("touchmove", onMove);
      el.removeEventListener("touchend", onEnd);
      el.removeEventListener("touchcancel", onEnd);
      delete el.dataset.floorPulling;
      el.style.removeProperty("--floor-pull");
    };
  }, [host, model, paint]);

  const pull = model.pull;
  if (pull < 0.5) return null;
  const dim = model.reveal * 0.3 + model.progress * 0.3;
  return (
    <>
      <div
        className="reels-floor-layer pointer-events-none absolute inset-x-0 top-0 z-10 overflow-hidden"
        style={{ height: pull }}
        aria-hidden
        data-testid="reels-floor"
        data-armed={model.armed ? "" : undefined}
      >
        <FloorSpinner
          progress={Math.min(1, pull / REFRESH_AT)}
          spinning={model.refreshedAt !== null && model.dragging}
          fade={model.reveal}
        />
        {model.reveal > 0 && (
          <div
            className="absolute inset-x-0 bottom-4 flex flex-col items-center gap-3"
            style={{ opacity: model.reveal, transform: `translateX(${-(1 - model.reveal) * 120}px)` }}
          >
            <p
              className="text-[15px] font-semibold tracking-[1.5px]"
              style={{ color: model.armed ? "var(--accent, #cdd6e6)" : "var(--text-muted)" }}
            >
              {model.armed ? t("library.reels.releaseHint") : t("library.reels.pullHint")}
            </p>
            <FilmCanvas pull={pull} progress={model.progress} armed={model.armed} stills={stills} />
          </div>
        )}
      </div>
      {dim > 0 && (
        <div
          className="reels-floor-layer pointer-events-none absolute inset-x-0 z-10 h-dvh bg-black"
          style={{ top: pull, opacity: dim }}
          aria-hidden
        />
      )}
    </>
  );
}

/** 刷新转圈：拉的时候按距离画满一圈，触发刷新后转起来；胶片出来时淡掉 */
function FloorSpinner({ progress, spinning, fade }: { progress: number; spinning: boolean; fade: number }) {
  const r = 8;
  const c = 2 * Math.PI * r;
  return (
    <div className="absolute left-1/2 top-2 -translate-x-1/2" style={{ opacity: 1 - fade * 0.8 }}>
      <svg width="28" height="28" viewBox="0 0 28 28" className={spinning ? "animate-spin" : undefined}>
        <circle cx="14" cy="14" r={r} fill="none" stroke="rgba(255,255,255,.18)" strokeWidth="2.5" />
        <circle
          cx="14"
          cy="14"
          r={r}
          fill="none"
          stroke="rgba(255,255,255,.8)"
          strokeWidth="2.5"
          strokeLinecap="round"
          strokeDasharray={c}
          strokeDashoffset={spinning ? c * 0.7 : c * (1 - progress)}
          transform="rotate(-90 14 14)"
        />
      </svg>
    </div>
  );
}

/* —— 走片：一条 35mm 胶片随手指穿过片门（同 iOS ReelsFilmStrip，冷银配色）—— */

const FW = 112;
const FH = 70;
/** 相邻两格的间距、整条胶片的宽（含上下齿孔带） */
const STEP = 124;
const BAND = 104;
/** 手指拉一点，胶片走几点 */
const TRAVEL = 2.6;
const HEIGHT = BAND + 24;

function FilmCanvas({ pull, progress, armed, stills }: { pull: number; progress: number; armed: boolean; stills: string[] }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const images = useMemo(
    () =>
      stills.map((src) => {
        const image = new Image();
        image.decoding = "async";
        image.src = src;
        return image;
      }),
    [stills],
  );
  const flash = useRef(0);
  const lastIndex = useRef<number | null>(null);
  const wasArmed = useRef(false);

  useEffect(() => {
    const el = canvas.current;
    if (!el) return;
    if (armed && !wasArmed.current) {
      flash.current = 1;
      navigator.vibrate?.(18);
    }
    wasArmed.current = armed;
    const raw = pull * TRAVEL;
    const position = armed ? Math.round(raw / STEP) * STEP : raw;
    const index = Math.round(position / STEP);
    if (lastIndex.current !== null && index !== lastIndex.current && !armed) navigator.vibrate?.(4);
    lastIndex.current = index;

    let raf = 0;
    const draw = () => {
      drawFilm(el, images, position, progress, armed, flash.current);
      // 合拢那一下的白光慢慢褪掉
      if (flash.current > 0.01) {
        flash.current *= 0.88;
        raf = requestAnimationFrame(draw);
      } else {
        flash.current = 0;
      }
    };
    draw();
    return () => cancelAnimationFrame(raf);
  }, [pull, progress, armed, images]);

  return <canvas ref={canvas} className="block w-full" style={{ height: HEIGHT }} />;
}

function drawFilm(
  el: HTMLCanvasElement,
  images: HTMLImageElement[],
  position: number,
  progress: number,
  armed: boolean,
  flash: number,
) {
  const dpr = Math.min(3, window.devicePixelRatio || 1);
  const w = el.clientWidth;
  if (el.width !== Math.round(w * dpr) || el.height !== Math.round(HEIGHT * dpr)) {
    el.width = Math.round(w * dpr);
    el.height = Math.round(HEIGHT * dpr);
  }
  const ctx = el.getContext("2d");
  if (!ctx) return;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, HEIGHT);
  const cy = HEIGHT / 2;
  const half = w / 2;

  // 放映灯：冷白，跟着进度变亮
  const lampR = 150 + 40 * progress;
  const lamp = ctx.createRadialGradient(half, cy, 4, half, cy, lampR);
  lamp.addColorStop(0, `rgba(204,219,255,${Math.min(1, 0.16 + 0.3 * progress + 0.4 * flash)})`);
  lamp.addColorStop(1, "rgba(204,219,255,0)");
  ctx.fillStyle = lamp;
  ctx.fillRect(0, 0, w, HEIGHT);

  const base = Math.floor(position / STEP);
  const frac = position - base * STEP;
  const cells: { k: number; x: number; c: number }[] = [];
  for (let i = -3; i <= 3; i += 1) {
    const x = half + i * STEP - frac;
    cells.push({ k: base + i, x, c: (x - half) / half });
  }
  // 先画两侧、后画中间：中间那格压在最上面
  cells.sort((a, b) => Math.abs(b.c) - Math.abs(a.c));
  for (const { k, x, c } of cells) {
    const near = Math.max(0, 1 - Math.abs(c) * 1.35);
    const light = Math.min(1.2, near * (0.35 + 0.65 * progress) + flash * near);
    const color = near * (0.4 + 0.6 * progress);
    ctx.save();
    ctx.translate(x, cy + 18 * c * c);
    ctx.rotate(c * 0.11);
    const s = 1 - 0.16 * c * c;
    ctx.scale(s, s);
    drawCell(ctx, images.length ? images[((k % images.length) + images.length) % images.length] : null, light, color);
    ctx.restore();
  }

  // 两头隐进黑里
  ctx.globalCompositeOperation = "destination-in";
  const edge = ctx.createLinearGradient(0, 0, w, 0);
  edge.addColorStop(0, "rgba(0,0,0,0)");
  edge.addColorStop(0.2, "rgba(0,0,0,1)");
  edge.addColorStop(0.8, "rgba(0,0,0,1)");
  edge.addColorStop(1, "rgba(0,0,0,0)");
  ctx.fillStyle = edge;
  ctx.fillRect(0, 0, w, HEIGHT);
  ctx.globalCompositeOperation = "source-over";

  // 片门：两块拉丝钢压片板，过线时合拢
  const gap = FW / 2 + 9 + (armed ? 0 : 14);
  const plateH = FH + 22;
  const steel = ctx.createLinearGradient(0, cy - plateH / 2, 0, cy + plateH / 2);
  steel.addColorStop(0, "#30333b");
  steel.addColorStop(0.5, `rgb(${204 + 18 * progress},${214 + 15 * progress},${224 + 13 * progress})`);
  steel.addColorStop(1, "#262930");
  ctx.fillStyle = steel;
  for (const side of [-1, 1]) roundRect(ctx, half + side * gap - 3, cy - plateH / 2, 6, plateH, 3, true);
  ctx.strokeStyle = `rgba(205,214,230,${armed ? 0.85 : 0.25})`;
  ctx.lineWidth = 1;
  roundRect(ctx, half - FW / 2 - 3, cy - FH / 2 - 3, FW + 6, FH + 6, 4, false);
  if (flash > 0.01) {
    ctx.globalCompositeOperation = "lighter";
    const glow = ctx.createRadialGradient(half, cy, 0, half, cy, 90);
    glow.addColorStop(0, `rgba(255,255,255,${0.9 * flash})`);
    glow.addColorStop(1, "rgba(255,255,255,0)");
    ctx.fillStyle = glow;
    ctx.fillRect(half - 90, cy - 90, 180, 180);
    ctx.globalCompositeOperation = "source-over";
  }
}

/** 一格胶片（以格中心为原点）：石墨片基、上下各一排透光的齿孔、中间的画格（两侧黑白、片门里彩色） */
function drawCell(ctx: CanvasRenderingContext2D, image: HTMLImageElement | null, light: number, color: number) {
  const lit = Math.min(1, light);
  ctx.fillStyle = `rgba(${18 + 31 * light | 0},${20 + 33 * light | 0},${23 + 36 * light | 0},0.97)`;
  ctx.fillRect(-STEP / 2 - 4, -BAND / 2, STEP + 8, BAND);
  ctx.fillStyle = `rgba(227,234,247,${0.1 + 0.78 * lit})`;
  for (const y of [-BAND / 2 + 4, BAND / 2 - 4 - 7]) {
    for (let j = 0; j < 4; j += 1) roundRect(ctx, -STEP / 2 + 8 + j * (STEP / 4), y, 11, 7, 2, true);
  }
  ctx.save();
  roundRect(ctx, -FW / 2, -FH / 2, FW, FH, 3, false, true);
  ctx.clip();
  ctx.fillStyle = "#1c1c1e";
  ctx.fillRect(-FW / 2, -FH / 2, FW, FH);
  if (image && image.complete && image.naturalWidth > 0) {
    ctx.filter = `grayscale(${(1 - color).toFixed(2)}) contrast(1.08) brightness(${(0.55 + 0.5 * lit).toFixed(2)})`;
    // 铺满画格（按比例裁）
    const scale = Math.max(FW / image.naturalWidth, FH / image.naturalHeight);
    const dw = image.naturalWidth * scale;
    const dh = image.naturalHeight * scale;
    ctx.drawImage(image, -dw / 2, -dh / 2, dw, dh);
    ctx.filter = "none";
  }
  ctx.restore();
}

function roundRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
  fill: boolean,
  pathOnly = false,
) {
  ctx.beginPath();
  if (ctx.roundRect) ctx.roundRect(x, y, w, h, r);
  else ctx.rect(x, y, w, h);
  if (pathOnly) return;
  if (fill) ctx.fill();
  else ctx.stroke();
}
