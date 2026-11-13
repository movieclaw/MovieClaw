"use client";

import { useTranslations } from "next-intl";
import { useEffect, useState } from "react";

import { Toggle } from "@/components/cloud-push-ui";
import { SettingsList, SettingsRow, SettingsSection, SETTINGS_INPUT_CLASS } from "@/components/settings-ui";
import { listLibraries } from "@/lib/api/libraries";
import { fetchPlaybackPolicy, savePlaybackPolicy, type PlaybackPolicy } from "@/lib/api/playback";

export function PlaybackCompletionSection() {
  const t = useTranslations();
  const [policy, setPolicy] = useState<PlaybackPolicy | null>(null);
  const [libraries, setLibraries] = useState<{ enabled: number; total: number } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [threshold, setThreshold] = useState("90");
  const [validationError, setValidationError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    void Promise.all([fetchPlaybackPolicy(), listLibraries("tv")])
      .then(([value, libs]) => {
        if (!alive) return;
        setPolicy(value);
        setThreshold(String(value.played_threshold_percent ?? 90));
        setLibraries({ enabled: libs.filter((lib) => lib.detect_media_segments).length, total: libs.length });
      })
      .catch((e: Error) => { if (alive) setError(e.message); });
    return () => { alive = false; };
  }, []);

  async function save(changes: Partial<PlaybackPolicy>) {
    if (busy || !policy) return;
    setBusy(true);
    setError(null);
    try {
      const value = await savePlaybackPolicy(changes);
      setPolicy(value);
      if (changes.played_threshold_percent != null) {
        setThreshold(String(value.played_threshold_percent));
      }
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  function saveThreshold() {
    const value = Number(threshold);
    if (!threshold.trim() || !Number.isFinite(value) || value < 80 || value > 100) {
      setValidationError(t("settings.playback.completion.range"));
      return;
    }
    setValidationError(null);
    if (value !== policy?.played_threshold_percent) void save({ played_threshold_percent: value });
  }

  const supported = policy?.played_threshold_percent != null && policy?.played_use_outro != null;
  return (
    <SettingsSection
      title={t("settings.playback.completion.title")}
      description={t("settings.playback.completion.description")}
      footnote={t("settings.playback.completion.footnote")}
    >
      <SettingsList>
        <SettingsRow label={t("settings.playback.completion.percent")} error={validationError ?? error}>
          <input
            type="number"
            min={80}
            max={100}
            step="any"
            aria-label={t("settings.playback.completion.percent")}
            aria-invalid={validationError != null}
            className={`${SETTINGS_INPUT_CLASS} w-24`}
            disabled={!supported || busy}
            value={threshold}
            onChange={(e) => { setThreshold(e.target.value); setValidationError(null); }}
            onBlur={saveThreshold}
            onKeyDown={(e) => { if (e.key === "Enter") e.currentTarget.blur(); }}
          />
        </SettingsRow>
        <SettingsRow
          label={t("settings.playback.completion.outro")}
          description={t("settings.playback.completion.outroHint")}
        >
          <Toggle
            label={t("settings.playback.completion.outro")}
            checked={policy?.played_use_outro ?? false}
            disabled={!supported || busy}
            onChange={(next) => void save({ played_use_outro: next })}
          />
        </SettingsRow>
      </SettingsList>
      {libraries && (
        <p className="mt-2 px-1 text-caption text-[var(--text-faint)]" role="status">
          {t("settings.playback.completion.detection", libraries)}
        </p>
      )}
      {policy && !supported && (
        <p className="mt-2 px-1 text-caption text-[var(--text-faint)]">{t("settings.playback.completion.upgrade")}</p>
      )}
    </SettingsSection>
  );
}
