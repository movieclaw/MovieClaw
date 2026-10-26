"use client";

import { useLocale, useTranslations } from "next-intl";
import { useState } from "react";

import { useUiPrefs } from "@/lib/ui-prefs";
import { useLanguage } from "@/lib/i18n/provider";
import type { LanguagePreference } from "@/lib/i18n/negotiate";

// i18n-ignore: language autonyms are data and never translated.
export const LANGUAGE_NAMES = { "zh-Hans": "简体中文", en: "English" } as const;

export function LanguagePicker() {
  const t = useTranslations("settings.appearance");
  const locale = useLocale();
  const { setLanguage } = useLanguage();
  return (
    <label className="flex items-center justify-center gap-2 text-sub text-[var(--text-muted)]">
      <span aria-hidden="true">🌐</span>
      <select
        aria-label={t("language")}
        value={locale}
        onChange={(event) => setLanguage(event.target.value as LanguagePreference)}
        className="rounded-lg bg-transparent px-2 py-1.5"
      >
        <option value="zh-Hans">{LANGUAGE_NAMES["zh-Hans"]}</option>
        <option value="en">{LANGUAGE_NAMES.en}</option>
      </select>
    </label>
  );
}

export function LanguageSettings() {
  const t = useTranslations("settings.appearance");
  const { browserLocale } = useLanguage();
  const { prefs, savePrefs, loading } = useUiPrefs();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);
  const options = [
    { value: "auto", label: t("browser", { language: LANGUAGE_NAMES[browserLocale] }) },
    { value: "zh-Hans", label: LANGUAGE_NAMES["zh-Hans"] },
    { value: "en", label: LANGUAGE_NAMES.en },
  ] as const;

  async function change(language: LanguagePreference) {
    setBusy(true);
    setError(false);
    try {
      await savePrefs({ ...prefs, language });
    } catch {
      setError(true);
    } finally {
      setBusy(false);
    }
  }

  return (
    <fieldset disabled={loading || busy} className="space-y-3" data-testid="language-settings">
      <legend className="mb-3 text-ui font-medium">{t("language")}</legend>
      {options.map(({ value, label }) => (
        <label key={value} className="flex cursor-pointer items-center gap-3 text-ui">
          <input type="radio" name="language" value={value} checked={prefs.language === value}
            onChange={() => void change(value)} className="accent-[var(--accent-strong)]" />
          {label}
        </label>
      ))}
      {error && <p role="alert" className="text-sub text-[var(--danger)]">{t("saveFailed")}</p>}
    </fieldset>
  );
}
