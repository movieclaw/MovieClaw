export type AppLocale = "zh-Hans" | "en";
export type LanguagePreference = AppLocale | "auto";

export const LOCALE_COOKIE = "mc_locale";

export function normalizeLocale(value: string): AppLocale | null {
  if (/^zh(?:-[a-z0-9]{1,8})*$/i.test(value)) return "zh-Hans";
  if (/^en(?:-[a-z0-9]{1,8})*$/i.test(value)) return "en";
  return null;
}

export function negotiate(acceptLanguage: string | null | undefined): AppLocale {
  // Same rule as the server: no header at all keeps the source language; unsupported ones fall back to English.
  if (!(acceptLanguage ?? "").trim()) return "zh-Hans";
  const candidates = (acceptLanguage ?? "").split(",").map((part, index) => {
    const [tag, ...parameters] = part.trim().split(";");
    const quality = parameters.find((p) => p.trim().startsWith("q="));
    const weight = quality?.trim().slice(2) ?? "1";
    const q = /^(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)$/.test(weight) ? Number(weight) : 0;
    return { locale: normalizeLocale(tag), q, index };
  });
  return candidates
    .filter(({ locale, q }) => locale && Number.isFinite(q) && q > 0 && q <= 1)
    .sort((a, b) => b.q - a.q || a.index - b.index)[0]?.locale ?? "en";
}

export function resolveLocale(cookie: string | undefined, acceptLanguage: string | null): AppLocale {
  return (cookie && normalizeLocale(cookie)) || negotiate(acceptLanguage);
}

export function writeLanguageCookie(language: LanguagePreference): void {
  document.cookie = `${LOCALE_COOKIE}=${language === "auto" ? "" : language}; Path=/; Max-Age=${language === "auto" ? 0 : 31536000}; SameSite=Lax${location.protocol === "https:" ? "; Secure" : ""}`;
}

/** Read at request time so a language change also affects requests outside React. */
export function requestLocale(): AppLocale | undefined {
  return typeof document === "undefined" ? undefined : normalizeLocale(document.documentElement.lang) ?? "en";
}
