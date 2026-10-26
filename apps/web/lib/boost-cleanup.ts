/**
 * 刷流清理的文案（任务中心刷流分组、站点设置的关闭刷流 / 删除站点三处共用，
 * iOS 同名 `ActivityBoostCleanupText`）。机制见 docs/design/site-protection-ratio-boost.md §2.9。
 */
import dayjs from "dayjs";

import type { BoostCleanupResult } from "@/lib/api/sites";
import { formatBytes } from "./format.ts";
import { appTranslator } from "./i18n/translate.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";
import { formatDate } from "./i18n/format.ts";

/** 保留期到期时刻「9月29日 14:00」 */
export function formatCleanupDeadline(iso: string | null | undefined, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  if (!iso) return null;
  const value = dayjs(iso);
  // i18n-ignore: preserve the existing zh-Hans date pattern; English uses Intl below.
  if (locale === "zh-Hans" || !value.isValid()) return value.format("M月D日 HH:mm");
  return formatDate(value.toDate(), { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }, locale);
}

/** 清理结果的一句话回执 */
export function boostCleanupSummary(result: BoostCleanupResult, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const parts: string[] = [];
  if (result.deleted_count > 0) {
    parts.push(t("activity.boost.cleanupDeleted", { count: result.deleted_count, size: formatBytes(result.deleted_bytes) }));
  }
  if (result.scheduled_count > 0) {
    const until = formatCleanupDeadline(result.scheduled_until, locale);
    parts.push(t("activity.boost.cleanupScheduled", { count: result.scheduled_count, hasDate: until ? "yes" : "no", until: until ?? "" }));
  }
  if (result.failed_count > 0) {
    parts.push(t("activity.boost.cleanupFailed", { count: result.failed_count }));
  }
  return parts.length > 0 ? parts.join(locale === "zh-Hans" ? "；" : "; ") : t("activity.boost.noneToClean");
}

/** 关闭刷流 / 删除站点确认框里的「同时清理」勾选项（该站还有在池种子时才出现） */
export function boostCleanupCheckbox(count: number, bytes: number, locale: AppLocale = requestLocale() ?? "zh-Hans") {
  const t = appTranslator(locale);
  return {
    label: t("activity.boost.cleanupCheckbox", { count, size: formatBytes(bytes) }),
    description:
      t("activity.boost.cleanupCheckboxHint"),
    defaultChecked: false,
  };
}
