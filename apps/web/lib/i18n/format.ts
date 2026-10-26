import { requestLocale, type AppLocale } from "./negotiate.ts";

export function formatNumber(value: number, options?: Intl.NumberFormatOptions,
  locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  return new Intl.NumberFormat(locale, options).format(value);
}

export function formatList(values: string[], locale: AppLocale = requestLocale() ?? "zh-Hans",
  options?: Intl.ListFormatOptions): string {
  return locale === "zh-Hans" ? values.join("、") : new Intl.ListFormat(locale, options).format(values);
}

export function formatDate(value: Date, options: Intl.DateTimeFormatOptions,
  locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  return new Intl.DateTimeFormat(locale, options).format(value);
}
