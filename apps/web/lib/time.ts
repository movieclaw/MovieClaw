/**
 * 全产品统一的时间处理入口。
 *
 * 约定：所有需要展示时间的地方都走这里，不要在组件里散落 `new Date().toLocaleString()`
 * 之类的裸写法。好处：
 *   1. 解析口径统一 —— 后端时间统一为**带时区标记**的 ISO 串（naive UTC 序列化时补 +00:00，
 *      见 movieclaw_api/schemas/base.py），dayjs 会正确按 UTC 解析后转成
 *      浏览器本地时区展示，避免"刚验证完却显示 8 小时前"这类时区错位。
 *   2. 中文文案统一 —— relativeTime 插件配 zh-cn locale，产出"几秒前 / 几分钟前 / 几天前"。
 *
 * dayjs 选型：~2KB，仅按需加载 relativeTime 插件与 zh-cn 语言包，不引入完整 moment。
 */
import dayjs from "dayjs";
import relativeTime from "dayjs/plugin/relativeTime.js";
import "dayjs/locale/zh-cn.js";
import "dayjs/locale/en.js";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";
import { appTranslator } from "./i18n/translate.ts";
import { formatDate } from "./i18n/format.ts";

dayjs.extend(relativeTime);

/** 时间展示的唯一地区化配置；未来切换语言或格式只改这里。 */
const TIME_DISPLAY_CONFIG = {
  dateTimeFormat: "YYYY/MM/DD HH:mm",
  clockTimeFormat: "HH:mm",
  timelineDateFormat: "MM/DD",
  emptyLabel: "—",
} as const;

/**
 * ISO 时间 → 中文相对时间，如「刚刚 / 3 分钟前 / 2 天前」。
 * 用于"上次检查""最近验证"这类关注"多久之前"的场景。
 * 传入 null/空 表示从未发生，返回「从未」。
 */
export function formatRelativeTime(iso: string | null | undefined, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  if (!iso) return appTranslator(locale)("common.never");
  return dayjs(iso).locale(locale === "zh-Hans" ? "zh-cn" : "en").fromNow();
}

/**
 * ISO 时间 → 本地绝对时间，如「2026/07/09 18:00」。
 * 用于"令牌生成于""创建于"这类关注"具体是哪一刻"的场景。
 */
export function formatDateTime(iso: string | null | undefined, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  if (!iso) return TIME_DISPLAY_CONFIG.emptyLabel;
  return locale === "zh-Hans"
    ? dayjs(iso).format(TIME_DISPLAY_CONFIG.dateTimeFormat)
    : formatDate(dayjs(iso).toDate(), { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }, locale);
}

/** 时间线的紧凑本地时间；完整日期仍通过卡片提示中的 formatDateTime 提供。 */
export function formatClockTime(iso: string | null | undefined, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  if (!iso) return TIME_DISPLAY_CONFIG.emptyLabel;
  return dayjs(iso).locale(locale === "zh-Hans" ? "zh-cn" : "en").format(TIME_DISPLAY_CONFIG.clockTimeFormat);
}

/**
 * Feed 时间轴的紧凑时间：当天记录显示时分，跨天记录显示月日。调用方仍可在
 * 卡片悬停信息里提供完整绝对时间，避免长历史把不同日期误看成同一天。
 */
export function formatTimelineTime(
  iso: string | null | undefined,
  referenceIso?: string,
  locale: AppLocale = requestLocale() ?? "zh-Hans",
): string {
  if (!iso) return TIME_DISPLAY_CONFIG.emptyLabel;
  const value = dayjs(iso);
  return value.isSame(referenceIso ? dayjs(referenceIso) : dayjs(), "day")
    ? value.format(TIME_DISPLAY_CONFIG.clockTimeFormat)
    : locale === "zh-Hans" ? value.format(TIME_DISPLAY_CONFIG.timelineDateFormat)
      : formatDate(value.toDate(), { month: "short", day: "numeric" }, locale);
}

/** Feed 历史分组键使用浏览器本地日期，避免 UTC 日期把午夜附近的记录分错组。 */
export function timelineDayKey(iso: string): string {
  return dayjs(iso).format("YYYY-MM-DD");
}

/** 历史分组标题：今天、昨天优先使用自然语言，更早记录才显示具体日期。 */
export function formatTimelineDayLabel(iso: string, referenceIso?: string, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const value = dayjs(iso);
  const reference = referenceIso ? dayjs(referenceIso) : dayjs();
  const t = appTranslator(locale);
  if (value.isSame(reference, "day")) return t("common.earlierToday");
  if (value.isSame(reference.subtract(1, "day"), "day")) return t("common.yesterday");
  return formatDate(value.toDate(), { month: locale === "zh-Hans" ? "long" : "short",
    day: "numeric", ...(value.isSame(reference, "year") ? {} : { year: "numeric" }),
  }, locale);
}

/** Unix 秒时间戳 → 本地绝对时间，避免组件绕开统一地区化配置。 */
export function formatUnixDateTime(seconds: number | null | undefined, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  if (seconds == null) return TIME_DISPLAY_CONFIG.emptyLabel;
  return formatDateTime(dayjs.unix(seconds).toISOString(), locale);
}
