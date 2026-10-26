import { createTranslator } from "next-intl";
import { messagesFor } from "./messages.ts";
import { requestLocale, type AppLocale } from "./negotiate.ts";

export const APP_FORMATS = { number: { elapsedSeconds: { useGrouping: false, minimumFractionDigits: 1, maximumFractionDigits: 1 }, oneDecimal: { minimumFractionDigits: 1, maximumFractionDigits: 1 } } };

const translator = (locale: AppLocale) => createTranslator({
  locale, messages: messagesFor(locale), formats: APP_FORMATS,
});
const translators = { "zh-Hans": translator("zh-Hans"), en: translator("en") };

export function appTranslator(locale: AppLocale = requestLocale() ?? "zh-Hans") {
  return translators[locale];
}

export type AppMessageKey = Parameters<ReturnType<typeof appTranslator>>[0];
