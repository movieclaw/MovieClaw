/**
 * iOS PWA 启动屏（apple-touch-startup-image）设备清单。
 *
 * iOS 至今不会用 manifest 的 background_color 合成启动屏（那是 Android 的
 * 行为），必须逐设备提供「像素尺寸与启动视口完全一致」的静态图，媒体查询
 * 不精确命中就整条忽略、回落白屏——深色 App 首帧闪白就是这么来的。
 *
 * 图片由 scripts/brand/generate_web_assets.py 生成（纯黑 #000000 底 + 居中极光标志，
 * 标志约 91pt 宽，与网页 SplashLayer 衔接），命名 splash-{逻辑宽}x{逻辑高}@{DPR}[-land].png。
 * 脚本直接解析下面两张表。iPhone 只列竖屏（iPhone 的主屏 App 一律竖屏启动）；
 * iPad 竖横都列。新机型上市后往两张表里加行、重跑生成脚本即可。
 */

/** 逻辑尺寸 (CSS pt 宽, 高, DPR)。landscape 条目沿用竖屏形式的宽高值。 */
const IPHONES: Array<[number, number, number]> = [
  [375, 667, 2], //  SE2/3, 8
  [414, 896, 2], //  XR, 11
  [375, 812, 3], //  X/XS/11 Pro/12 mini/13 mini
  [414, 896, 3], //  XS Max/11 Pro Max
  [390, 844, 3], //  12/13/14/16e
  [393, 852, 3], //  14 Pro/15/15 Pro/16/17
  [402, 874, 3], //  16 Pro/17 Pro
  [420, 912, 3], //  Air
  [428, 926, 3], //  12/13 Pro Max/14 Plus
  [430, 932, 3], //  14 Pro Max/15 Plus/15 Pro Max/16 Plus
  [440, 956, 3], //  16 Pro Max/17 Pro Max
];

const IPADS: Array<[number, number, number]> = [
  [744, 1133, 2], //  mini 6/7
  [768, 1024, 2], //  老 iPad / mini 5 及更早
  [810, 1080, 2], //  iPad 10.2
  [820, 1180, 2], //  iPad 10.9 / Air 11
  [834, 1194, 2], //  Pro 11（一~四代）
  [834, 1210, 2], //  Pro 11 (M4)
  [1024, 1366, 2], // Pro 12.9 / Air 13
  [1032, 1376, 2], // Pro 13 (M4)
];

function entry(w: number, h: number, r: number, landscape: boolean) {
  return {
    url: `/splash/splash-${w}x${h}@${r}${landscape ? "-land" : ""}.png`,
    media:
      `screen and (device-width: ${w}px) and (device-height: ${h}px) ` +
      `and (-webkit-device-pixel-ratio: ${r}) and (orientation: ${landscape ? "landscape" : "portrait"})`,
  };
}

export const appleStartupImages = [
  ...IPHONES.map(([w, h, r]) => entry(w, h, r, false)),
  ...IPADS.map(([w, h, r]) => entry(w, h, r, false)),
  ...IPADS.map(([w, h, r]) => entry(w, h, r, true)),
];
