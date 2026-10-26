/**
 * 数值格式化工具。
 *
 * 后端约定只回传原始数值（如字节数），展示格式统一由前端决定，
 * 避免各站点原始文本（"1.5 TB" / "1536GB"）格式不一。
 */

import { appTranslator } from "./i18n/translate.ts";
import { formatNumber } from "./i18n/format.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";

export { formatNumber, formatList } from "./i18n/format.ts";

/**
 * 字节数 → 可读体积，如「1.50 TB」「800 GB」。0 也是有效值（显示 0 B）。
 * 百位起省掉小数，保证数字部分最多 5 个字符（"99.99"），调用方的定宽数字列
 * 按这个上限留宽度。判断档位前先按 2 位四舍五入，否则 99.997 会被格成
 * "100.00"——多出一个字符，正好把窄屏的定宽列撑破。
 */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let value = bytes;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  const rounded = Number(value.toFixed(2));
  return `${rounded.toFixed(rounded >= 100 || i === 0 ? 0 : 2)} ${units[i]}`;
}

/**
 * 分享率 → 展示文本。null 表示站点未提供（与 0.00 —— 真实无上传 —— 含义不同），
 * 显示为「—」。
 */
export function formatRatio(ratio: number | null): string {
  if (ratio == null) return "—";
  return ratio.toFixed(2);
}

/** 秒数 → 可读时长，如「15 分钟」「1.5 小时」。用于同步间隔这类节奏展示。 */
export function formatDuration(seconds: number, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "—";
  const t = appTranslator(locale);
  if (seconds < 60) return t("units.duration.seconds", { count: seconds });
  if (seconds < 3600) return t("units.duration.minutes", { count: Math.round(seconds / 60) });
  const hours = seconds / 3600;
  return Number.isInteger(hours)
    ? t("units.duration.hours", { count: hours })
    : t("units.duration.fractionalHours", { count: hours });
}

/**
 * 影片分钟数 → 小时 + 分钟。电影详情需要保留精确分钟，不能复用上面的
 * 小数小时格式，否则「2.1 小时」不如「2 小时 6 分钟」直观。
 */
export function formatRuntimeMinutes(minutes: number, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  if (!Number.isFinite(minutes) || minutes <= 0) return "—";
  const rounded = Math.round(minutes);
  const t = appTranslator(locale);
  if (rounded < 60) return t("units.duration.minutes", { count: rounded });
  const hours = Math.floor(rounded / 60);
  const remainder = rounded % 60;
  return remainder > 0
    ? t("units.duration.hoursMinutes", { hours, minutes: remainder })
    : t("units.duration.hours", { count: hours });
}

/**
 * 探测层的垂直分辨率 → 消费级画质标签。1080p 不是 2K：常说的 2K/QHD
 * 是 1440p，2160p 才对应电视与流媒体语境里的 4K。
 */
export function formatVideoResolution(resolution: string): string {
  const normalized = resolution.trim().toLowerCase();
  const key = /^\d+$/.test(normalized) ? `${normalized}p` : normalized;
  const labels: Record<string, string> = {
    "4320p": "8K",
    "2160p": "4K",
    "1440p": "2K",
    "1080p": "1080p",
    "720p": "720p",
    "4k": "4K",
    "2k": "2K",
  };
  return labels[key] ?? resolution;
}

/** 大数 → 中文紧凑格式，如 12345.6 →「1.2万」。用于魔力值这类可能到百万级的数。 */
export function formatCompact(value: number, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  return formatNumber(value, { notation: "compact", maximumFractionDigits: 1 }, locale);
}
