/**
 * 首页「按类型找电影 / 剧集」色块的配色：TMDB genre id → 一块网格渐变。
 *
 * 每个类型手调一组三色相（主色 a、渐变偏移色 b、高光色 c）与明度 l、彩度 k，
 * 色相贴合类型含义（科幻电光蓝、恐怖暗血红、喜剧暖黄……）。颜色全部在 OKLCH
 * 里定义：同样的 l 在人眼里一样亮，黄色不会比蓝色刺眼，渐变中段也不发灰。
 * 整体彩度再乘 CHROMA_SCALE（定稿 80%：比苹果音乐收一档，不艳俗）。
 *
 * 一块色块 = 主色→偏移色的斜向底 + 三团羽化色团（高光团、偏移团、小亮斑）。
 * 色团位置按 id 在三种构图里轮换，一排看不出复制粘贴。
 *
 * iOS / tvOS 的 `Shared/DesignSystem/GenrePalette.swift` 逐项移植同一张表与
 * 同一套公式；test/genre-palette.test.mjs 会解析那个文件比对，两边改一处测试就红。
 *
 * 本模块刻意零依赖（不 import 组件或 `@/` 别名），node --test 直接跑。
 */

export interface GenreTone {
  /** 中文名（类型墙页头用；首页色块用接口回的 label） */
  name: string;
  /** 主色相（OKLCH hue，度） */
  a: number;
  /** 渐变偏移色相 */
  b: number;
  /** 高光色相 */
  c: number;
  /** 主色明度 0-1 */
  l: number;
  /** 主色彩度（乘 CHROMA_SCALE 之前） */
  k: number;
}

/** 整体彩度倍率：设计稿 v6 的「80%」档。 */
export const CHROMA_SCALE = 0.8;

/** 色块宽高比（16:10.5）。色团的纵向位置按它换算。 */
export const TILE_ASPECT = 16 / 10.5;

/** TMDB 电影 19 个 + 剧集独有 8 个。与 movieclaw_media/genres.py 的 id 一一对应。 */
export const GENRE_TONES: Record<number, GenreTone> = {
  // 电影
  28: { name: "动作", a: 33, b: 58, c: 12, l: 0.62, k: 0.2 },
  12: { name: "冒险", a: 190, b: 165, c: 225, l: 0.6, k: 0.13 },
  16: { name: "动画", a: 140, b: 115, c: 168, l: 0.68, k: 0.19 },
  35: { name: "喜剧", a: 75, b: 52, c: 95, l: 0.72, k: 0.17 },
  80: { name: "犯罪", a: 268, b: 290, c: 245, l: 0.4, k: 0.13 },
  99: { name: "纪录", a: 160, b: 135, c: 195, l: 0.52, k: 0.11 },
  18: { name: "剧情", a: 292, b: 318, c: 265, l: 0.52, k: 0.2 },
  10751: { name: "家庭", a: 48, b: 28, c: 72, l: 0.72, k: 0.15 },
  14: { name: "奇幻", a: 310, b: 340, c: 280, l: 0.55, k: 0.2 },
  36: { name: "历史", a: 62, b: 45, c: 82, l: 0.56, k: 0.1 },
  27: { name: "恐怖", a: 22, b: 4, c: 38, l: 0.4, k: 0.16 },
  10402: { name: "音乐", a: 345, b: 318, c: 12, l: 0.62, k: 0.21 },
  9648: { name: "悬疑", a: 205, b: 230, c: 180, l: 0.46, k: 0.1 },
  10749: { name: "爱情", a: 2, b: 345, c: 30, l: 0.68, k: 0.18 },
  878: { name: "科幻", a: 252, b: 225, c: 285, l: 0.58, k: 0.19 },
  10770: { name: "电视电影", a: 278, b: 255, c: 305, l: 0.62, k: 0.13 },
  53: { name: "惊悚", a: 340, b: 12, c: 312, l: 0.42, k: 0.16 },
  10752: { name: "战争", a: 125, b: 150, c: 105, l: 0.54, k: 0.1 },
  37: { name: "西部", a: 58, b: 72, c: 38, l: 0.66, k: 0.15 },
  // 剧集独有
  10759: { name: "动作冒险", a: 42, b: 68, c: 20, l: 0.64, k: 0.19 },
  10762: { name: "儿童", a: 210, b: 185, c: 95, l: 0.7, k: 0.13 },
  10763: { name: "新闻", a: 240, b: 255, c: 220, l: 0.58, k: 0.07 },
  10764: { name: "真人秀", a: 355, b: 40, c: 322, l: 0.66, k: 0.2 },
  10765: { name: "科幻奇幻", a: 272, b: 305, c: 232, l: 0.55, k: 0.19 },
  10766: { name: "肥皂剧", a: 322, b: 352, c: 296, l: 0.65, k: 0.16 },
  10767: { name: "脱口秀", a: 68, b: 45, c: 88, l: 0.7, k: 0.16 },
  10768: { name: "战争政治", a: 140, b: 165, c: 115, l: 0.5, k: 0.09 },
};

/** 表外的 id（TMDB 将来新增的类型）：中性的石板蓝，名字由调用方给。 */
const FALLBACK_TONE: GenreTone = { name: "", a: 250, b: 270, c: 230, l: 0.5, k: 0.06 };

export function genreTone(id: number): GenreTone {
  return GENRE_TONES[id] ?? FALLBACK_TONE;
}

/** OKLCH 颜色；彩度在这里统一乘 CHROMA_SCALE，明度钳在 0-1。 */
export interface Oklch {
  l: number;
  c: number;
  h: number;
  alpha: number;
}

function oklch(l: number, k: number, h: number, alpha = 1): Oklch {
  return { l: Math.min(1, Math.max(0, l)), c: k * CHROMA_SCALE, h: ((h % 360) + 360) % 360, alpha };
}

export function oklchCss({ l, c, h, alpha }: Oklch): string {
  return `oklch(${l.toFixed(3)} ${c.toFixed(3)} ${h.toFixed(1)} / ${alpha.toFixed(3)})`;
}

/** 两个色相沿短弧的中点（345° 与 12° 的中点是 358.5°，不是 178.5°）。 */
export function midHue(x: number, y: number): number {
  const d = ((y - x + 540) % 360) - 180;
  return (x + d / 2 + 360) % 360;
}

/** 色团：圆心框左上角相对色块的位置（left 占宽、top 占高的比例）、直径（占宽）与颜色。 */
export interface GenreBlob {
  left: number;
  top: number;
  size: number;
  color: Oklch;
}

/** 羽化：按缓动曲线逐级降透明度，边缘像颜料晕开而没有硬边。[位置 0-1, 透明度倍率] */
export const FEATHER_STOPS: readonly (readonly [number, number])[] = [
  [0, 1],
  [0.22, 0.82],
  [0.45, 0.55],
  [0.68, 0.26],
  [0.86, 0.08],
  [1, 0],
];

/** 三种构图：色团圆心框的左上角（x 占宽、y 占高）与直径（占宽），以及用哪种颜色。 */
const COMPOSITIONS: readonly (readonly { x: number; y: number; d: number; role: "c" | "b" | "c2" }[])[] = [
  [
    { x: -0.15, y: -0.35, d: 0.85, role: "c" },
    { x: 0.55, y: 0.25, d: 0.95, role: "b" },
    { x: 0.65, y: -0.45, d: 0.6, role: "c2" },
  ],
  [
    { x: 0.45, y: -0.4, d: 0.9, role: "c" },
    { x: -0.25, y: 0.3, d: 0.9, role: "b" },
    { x: 0.8, y: 0.35, d: 0.55, role: "c2" },
  ],
  [
    { x: -0.1, y: 0.25, d: 0.8, role: "b" },
    { x: 0.5, y: -0.5, d: 1.0, role: "c" },
    { x: 0.2, y: -0.3, d: 0.45, role: "c2" },
  ],
];

/** 羽化后色团画得比构图里的直径大 35%，圆心不动。 */
const FEATHER_GROW = 1.35;

/** 构图按 id 各位数字之和轮换：稳定（同一类型永远同一构图），且相邻 id 大多不同。 */
export function compositionIndex(id: number): number {
  return [...String(Math.abs(id))].reduce((sum, digit) => sum + Number(digit), 0) % 3;
}

export interface GenreArt {
  /** 斜向底：主色（左上）→ 偏移色（右下），135° */
  from: Oklch;
  to: Oklch;
  blobs: GenreBlob[];
  /** 左下角文字区的局部压暗（0-1）：类型墙页头的字在左下，亮色块上白字也要够清楚 */
  scrim: number;
  /** 外发光投影的颜色：主色与偏移色之间的同色系，让卡片像在发光 */
  glow: Oklch;
}

export function genreArt(id: number): GenreArt {
  const t = genreTone(id);
  const colors: Record<"c" | "b" | "c2", Oklch> = {
    c: oklch(t.l + 0.12, t.k + 0.02, t.c, 0.95),
    b: oklch(t.l - 0.06, t.k + 0.01, t.b, 0.95),
    c2: oklch(t.l + 0.2, t.k * 0.7, midHue(t.a, t.c), 0.7),
  };
  const blobs = COMPOSITIONS[compositionIndex(id)].map((p) => {
    const size = p.d * FEATHER_GROW;
    const grow = (size - p.d) / 2;
    return {
      left: p.x - grow,
      top: p.y - grow * TILE_ASPECT,
      size,
      color: colors[p.role],
    };
  });
  return {
    from: oklch(t.l + 0.03, t.k, t.a),
    to: oklch(t.l - 0.1, t.k, t.b),
    blobs,
    scrim: Math.max(0.06, (t.l - 0.5) * 0.9),
    glow: oklch(t.l - 0.02, t.k, midHue(t.a, t.b), 0.55),
  };
}

/** 一团色团的 CSS 背景：从圆心向外按 FEATHER_STOPS 逐级变透明。 */
export function blobCss(color: Oklch): string {
  const stops = FEATHER_STOPS.map(
    ([at, alpha]) => `${oklchCss({ ...color, alpha: color.alpha * alpha })} ${Math.round(at * 100)}%`,
  );
  return `radial-gradient(closest-side, ${stops.join(", ")})`;
}

/** 斜向底的 CSS：在 OKLCH 里插值，中段不发灰。 */
export function baseCss(art: GenreArt): string {
  return `linear-gradient(in oklch 135deg, ${oklchCss(art.from)}, ${oklchCss(art.to)})`;
}
