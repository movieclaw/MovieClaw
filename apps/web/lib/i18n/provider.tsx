"use client";

import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { NextIntlClientProvider } from "next-intl";
import { useRouter } from "next/navigation";

import { APP_FORMATS } from "./translate";

import { messagesFor } from "./messages";
import { writeLanguageCookie, type AppLocale, type LanguagePreference } from "./negotiate";

const LanguageContext = createContext<{
  browserLocale: AppLocale;
  setLanguage: (language: LanguagePreference) => void;
} | null>(null);

export function LanguageProvider({ locale: initialLocale, browserLocale, children }: {
  locale: AppLocale;
  browserLocale: AppLocale;
  children: React.ReactNode;
}) {
  const [locale, setLocale] = useState(initialLocale);
  const [timeZone, setTimeZone] = useState("UTC");
  const router = useRouter();
  const [debugMessages, setDebugMessages] = useState<ReturnType<typeof messagesFor> | null>(null);
  useEffect(() => {
    setTimeZone(Intl.DateTimeFormat().resolvedOptions().timeZone);
    if (process.env.NODE_ENV === "development") {
      void import("./pseudo").then(({ pseudoEnabled, pseudoMessages }) => {
        if (pseudoEnabled(process.env.NODE_ENV, window.location.search)) {
          setDebugMessages(pseudoMessages(messagesFor("en")));
        }
      });
    }
  }, []);
  const effectiveLocale = debugMessages ? "en" : locale;
  useEffect(() => { document.documentElement.lang = effectiveLocale; }, [effectiveLocale]);
  const messages = debugMessages ?? messagesFor(locale);
  useEffect(() => setLocale(initialLocale), [initialLocale]);
  const setLanguage = useCallback((language: LanguagePreference) => {
    const next = language === "auto" ? browserLocale : language;
    writeLanguageCookie(language);
    document.documentElement.lang = next;
    setLocale(next);
    router.refresh();
  }, [browserLocale, router]);

  return (
    <LanguageContext.Provider value={{ browserLocale, setLanguage }}>
      <NextIntlClientProvider locale={effectiveLocale} messages={messages} formats={APP_FORMATS} timeZone={timeZone}>
        {children}
      </NextIntlClientProvider>
    </LanguageContext.Provider>
  );
}

export function useLanguage() {
  const value = useContext(LanguageContext);
  if (!value) throw new Error("LanguageProvider is required");
  return value;
}
