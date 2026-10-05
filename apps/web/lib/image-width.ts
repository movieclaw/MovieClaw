/**
 * 图片「宽度阶梯」取图的纯计算部分（设计见 docs/design/image-sizing.md §5、§6）。
 *
 * 服务端所有出图地址都认查询参数 ``w=<需要的像素宽>``，并把它向上取到同一张阶梯表
 * 再派生（只缩不放、不裁切）。客户端这边只做一件事：按公式算出「这个位置需要多少
 * 物理像素」，先在本地取到阶梯档再拼地址——同一档永远是同一个 URL，浏览器缓存与
 * 服务端派生缓存都能复用。
 *
 *   需要宽 = 有效宽 × 屏幕倍率 × 放大系数，再向上取到阶梯
 *   - 有效宽：等比装下（contain）取框宽；铺满（cover）取 max(框宽, 框高 × 图片宽高比)
 *   - 屏幕倍率：卡片交给 srcset（浏览器自己按 DPR 挑），大图区读 devicePixelRatio
 *   - 放大系数：悬停 / 推镜放大（海报卡 1.06、Hero 推镜 1.1 等）
 *
 * 本文件不依赖任何路径别名与浏览器对象（devicePixelRatio 除外，且有兜底），
 * 可以被 node --test 直接导入做单测（test/image-width.test.mjs）。
 */

/** 宽度阶梯：与后端 services/image_variants.py 同一张表，相邻两档不超过 1.5 倍。 */
export const WIDTH_LADDER = [160, 240, 360, 480, 720, 960, 1280, 1920, 2560, 3840] as const;

/** 阶梯最大档：再大的需求也按它取（服务端同样封顶）。 */
const MAX_WIDTH = WIDTH_LADDER[WIDTH_LADDER.length - 1];

/** 把需要的像素宽向上取到阶梯档；超过最大档取最大档。非法输入按最小档。 */
export function snapWidth(px: number): number {
  if (!Number.isFinite(px) || px <= 0) return WIDTH_LADDER[0];
  for (const step of WIDTH_LADDER) {
    if (px <= step) return step;
  }
  return MAX_WIDTH;
}

/**
 * 图片宽高比未知时按资产类型取的默认值（宽 ÷ 高）：海报、头像 2:3；背景、剧照 16:9。
 * 只用于「铺满」时估有效宽，比例知道就直接传数字。
 */
export const IMAGE_ASPECT = {
  poster: 2 / 3,
  avatar: 2 / 3,
  backdrop: 16 / 9,
  still: 16 / 9,
} as const;

/**
 * 铺满（object-cover）时的有效宽：框比图「更竖」时图要按框高放大，左右裁掉，
 * 所以需要的宽是 框高 × 图片宽高比，而不是框宽。
 * 典型反例：手机详情页 393×452 的竖框铺 16:9 剧照，按宽只算 393，按高要 804。
 */
export function coverWidth(boxWidth: number, boxHeight: number, aspect: number): number {
  return Math.max(boxWidth, boxHeight * aspect);
}

/**
 * 给（已解析好的）服务端图片地址设置 ``w``：先取阶梯档，替换掉已有的 ``w`` / ``variant``
 * （宽度取代旧预设，两者不该同时出现）。空串、data: / blob: 这类本地地址原样返回。
 *
 * 只动查询串，不碰 /images/proxy?url= 里编码过的远端地址（那里的 & 已编码成 %26）。
 */
export function withImageWidth(url: string, px: number): string {
  if (!url || /^(data|blob):/i.test(url)) return url;
  const hashAt = url.indexOf("#");
  const hash = hashAt >= 0 ? url.slice(hashAt) : "";
  const bare = hashAt >= 0 ? url.slice(0, hashAt) : url;
  const queryAt = bare.indexOf("?");
  const path = queryAt >= 0 ? bare.slice(0, queryAt) : bare;
  const params = queryAt >= 0 ? bare.slice(queryAt + 1).split("&") : [];
  const kept = params.filter((part) => part && !/^(w|variant)=/.test(part));
  kept.push(`w=${snapWidth(px)}`);
  return `${path}?${kept.join("&")}${hash}`;
}

/**
 * 卡片类 ``<img>`` 的 srcset：按显示宽（CSS px，已是铺满后的有效宽）× 放大系数，
 * 列出 1x / 2x / 3x 屏对应的阶梯档（去重），用 ``w`` 描述符配合 ``sizes`` 让浏览器
 * 自己按设备倍率挑。
 *
 * 注意：w 描述符会参与 ``<img>`` 的「固有尺寸」计算——服务端原图比档位小时回原图，
 * 描述符就比实际像素大。所以只给尺寸由 CSS 定死的框用（海报卡、横卡这类），
 * 靠固有尺寸撑开的图（Logo 的 w-auto）请改用 {@link screenImageWidth} 拼一个固定 w。
 */
export function imageSrcSet(url: string, cssWidth: number, scale = 1): string {
  const base = cssWidth * scale;
  const steps = [...new Set([1, 2, 3].map((dpr) => snapWidth(base * dpr)))];
  return steps.map((step) => `${withImageWidth(url, step)} ${step}w`).join(", ");
}

/** 与 {@link imageSrcSet} 配套的 sizes：放大系数一并算进去，悬停放大后也够清楚。 */
export function imageSizes(cssWidth: number, scale = 1): string {
  return `${Math.ceil(cssWidth * scale)}px`;
}

/**
 * 卡片 ``<img>`` 一次拿齐 src / srcSet / sizes。src 只是不支持 srcset 时的兜底，
 * 取 2x 档（主流屏）。地址为空或不是服务端图（data: / blob:）时只回 src。
 */
export function responsiveImage(
  url: string,
  cssWidth: number,
  scale = 1,
): { src: string; srcSet?: string; sizes?: string } {
  if (!url || /^(data|blob):/i.test(url)) return { src: url };
  return {
    src: withImageWidth(url, cssWidth * scale * 2),
    srcSet: imageSrcSet(url, cssWidth, scale),
    sizes: imageSizes(cssWidth, scale),
  };
}

/** 当前屏幕倍率；服务端渲染 / 拿不到时按 2（主流屏）估。 */
export function currentPixelRatio(): number {
  if (typeof window === "undefined") return 2;
  return window.devicePixelRatio || 1;
}

/**
 * 按当前屏幕倍率直接算一个 ``w``（已取阶梯档）：给 CSS 背景图、Logo、灯箱大图这类
 * 不便用 srcset 的地方。cssWidth 是显示宽（铺满时传 {@link coverWidth} 的结果）。
 */
export function screenImageWidth(cssWidth: number, scale = 1, dpr = currentPixelRatio()): number {
  return snapWidth(cssWidth * scale * dpr);
}

/**
 * 等比装下整屏（灯箱舞台）需要的像素宽：屏宽 × 倍率，取阶梯档。竖图受屏高限制只会
 * 用到更少，屏宽是上限。服务端渲染时没有屏幕，按 1920 估（灯箱只在点开后渲染，实际走不到）。
 */
export function fullScreenImageWidth(): number {
  if (typeof window === "undefined") return snapWidth(1920);
  return screenImageWidth(window.innerWidth);
}
