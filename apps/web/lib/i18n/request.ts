import { cookies, headers } from "next/headers";
import { getRequestConfig } from "next-intl/server";

import { APP_FORMATS } from "./translate";
import { messagesFor } from "./messages";
import { LOCALE_COOKIE, resolveLocale } from "./negotiate";

export default getRequestConfig(async () => {
  const [store, requestHeaders] = await Promise.all([cookies(), headers()]);
  const locale = resolveLocale(store.get(LOCALE_COOKIE)?.value, requestHeaders.get("accept-language"));
  return { locale, messages: messagesFor(locale), formats: APP_FORMATS, timeZone: "UTC" };
});
