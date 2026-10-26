import { appTranslator } from "./i18n/translate.ts";
import type { AppLocale } from "./i18n/negotiate.ts";

/** Names are user data unless the server explicitly marks a built-in name. */
export function ruleSetLabel(rule: { name: string; name_key?: string | null }, locale: AppLocale): string {
  return rule.name_key === "subscription.rules.defaultName"
    ? appTranslator(locale)("subscription.rules.defaultName")
    : rule.name;
}
