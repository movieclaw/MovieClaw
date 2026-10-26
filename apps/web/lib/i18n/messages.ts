import zhDownload from "../../locales/zh-Hans/download.json" with { type: "json" };
import enDownload from "../../locales/en/download.json" with { type: "json" };
import zhSearch from "../../locales/zh-Hans/search.json" with { type: "json" };
import enSearch from "../../locales/en/search.json" with { type: "json" };
import zhPlayer from "../../locales/zh-Hans/player.json" with { type: "json" };
import enPlayer from "../../locales/en/player.json" with { type: "json" };
import zhMedia from "../../locales/zh-Hans/media.json" with { type: "json" };
import enMedia from "../../locales/en/media.json" with { type: "json" };
import zhLibrary from "../../locales/zh-Hans/library.json" with { type: "json" };
import enLibrary from "../../locales/en/library.json" with { type: "json" };
import zhSubscription from "../../locales/zh-Hans/subscription.json" with { type: "json" };
import enSubscription from "../../locales/en/subscription.json" with { type: "json" };
import zhAuth from "../../locales/zh-Hans/auth.json" with { type: "json" };
import enAuth from "../../locales/en/auth.json" with { type: "json" };
import zhSetup from "../../locales/zh-Hans/setup.json" with { type: "json" };
import enSetup from "../../locales/en/setup.json" with { type: "json" };
import zhCommon from "../../locales/zh-Hans/common.json" with { type: "json" };
import enCommon from "../../locales/en/common.json" with { type: "json" };
import zhSettings from "../../locales/zh-Hans/settings.json" with { type: "json" };
import enSettings from "../../locales/en/settings.json" with { type: "json" };
import zhUnits from "../../locales/zh-Hans/units.json" with { type: "json" };
import enUnits from "../../locales/en/units.json" with { type: "json" };
import zhHome from "../../locales/zh-Hans/home.json" with { type: "json" };
import enHome from "../../locales/en/home.json" with { type: "json" };
import zhNav from "../../locales/zh-Hans/nav.json" with { type: "json" };
import enNav from "../../locales/en/nav.json" with { type: "json" };
import zhAgent from "../../locales/zh-Hans/agent.json" with { type: "json" };
import enAgent from "../../locales/en/agent.json" with { type: "json" };
import zhNotify from "../../locales/zh-Hans/notify.json" with { type: "json" };
import enNotify from "../../locales/en/notify.json" with { type: "json" };
import zhErrors from "../../locales/zh-Hans/errors.json" with { type: "json" };
import enErrors from "../../locales/en/errors.json" with { type: "json" };
import zhActivity from "../../locales/zh-Hans/activity.json" with { type: "json" };
import enActivity from "../../locales/en/activity.json" with { type: "json" };
import type { AppLocale } from "./negotiate.ts";

export const zhHans = { download: zhDownload, player: zhPlayer, media: zhMedia, library: zhLibrary, subscription: zhSubscription, auth: zhAuth, setup: zhSetup, common: zhCommon, settings: zhSettings, units: zhUnits, home: zhHome, nav: zhNav, search: zhSearch, agent: zhAgent, notify: zhNotify, errors: zhErrors, activity: zhActivity };
const en = { download: enDownload, player: enPlayer, media: enMedia, library: enLibrary, subscription: enSubscription, auth: enAuth, setup: enSetup, common: enCommon, settings: enSettings, units: enUnits, home: enHome, nav: enNav, search: enSearch, agent: enAgent, notify: enNotify, errors: enErrors, activity: enActivity };

// Merge by leaf, keeping the Chinese source as a migration fallback.
function merge(source: Record<string, unknown>, translated: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(source).map(([key, value]) => [key,
    typeof value === "object" && value !== null
      ? merge(value as Record<string, unknown>, (translated[key] ?? {}) as Record<string, unknown>)
      : translated[key] ?? value,
  ]));
}

const english = merge(zhHans, en) as typeof zhHans;

export function messagesFor(locale: AppLocale) {
  return locale === "zh-Hans" ? zhHans : english;
}

declare module "next-intl" {
  interface AppConfig {
    Locale: AppLocale;
    Messages: typeof zhHans;
  }
}
