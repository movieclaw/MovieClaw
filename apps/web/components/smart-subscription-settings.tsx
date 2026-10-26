"use client";

import { useLocale, useTranslations } from "next-intl";
import { appTranslator } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";

import { useEffect, useId, useState } from "react";
import {
  getSmartDefaults,
  getSmartMemory,
  saveSmartDefaults,
  updateSmartMemory,
  type SmartDefaults,
  type SmartDefaultsInput,
  type SmartMemory,
  type SmartPreferences,
} from "@/lib/api/subscriptions";
import { usePermissions } from "@/lib/permissions";

const SOURCE_LABELS = { "web-dl": "WEB-DL", remux: "Remux" } as const;

export function smartSummary(p: Pick<SmartPreferences, "resolution" | "source">, locale: AppLocale = "zh-Hans") {
  const t = appTranslator(locale);
  const resolution = p.resolution === "2160p" ? "4K" : "1080p";
  return `${resolution} ${p.source === "blu-ray" ? t("subscription.smart.bluray") : SOURCE_LABELS[p.source]}`;
}

export function waitText(seconds: number, locale: AppLocale = "zh-Hans") {
  const t = appTranslator(locale);
  if (seconds === 0) return t("subscription.smart.asap");
  return seconds % 86400 === 0 ? t("subscription.smart.waitDays", { count: seconds / 86400 }) : t("subscription.smart.waitHours", { count: seconds / 3600 });
}

const selectClass = "mt-1.5 w-full rounded-xl border border-[var(--line)] bg-[var(--surface-inset)] p-2.5";

/** 等待上限：预设三档、自定义 1–7 天，旧版本存下的整小时值原样保留为一档。 */
function WaitField({ label, value, onChange }: { label: string; value: number; onChange: (seconds: number) => void }) {
  const t = useTranslations();
  const daysInputId = useId();
  const [legacyWait] = useState(() => ![0, 10800, 86400].includes(value) && value % 86400 !== 0 ? value : null);
  const [customWait, setCustomWait] = useState(() => ![0, 10800, 86400].includes(value) && value % 86400 === 0);
  const [customDays, setCustomDays] = useState(() => String(Math.max(1, Math.ceil(value / 86400))));
  const days = Number(customDays);
  const validDays = customDays !== "" && Number.isInteger(days) && days >= 1 && days <= 7;
  const changeDays = (next: string) => {
    setCustomDays(next);
    if (next !== "" && Number.isFinite(Number(next))) onChange(Number(next) * 86400);
  };
  return <div>
    <label className="block text-sub">{label}
      <select aria-label={label} className={selectClass} value={customWait ? "custom" : value} onChange={(e) => {
        const custom = e.target.value === "custom";
        const seconds = custom ? Math.min(7, Math.max(1, Math.ceil(value / 86400))) * 86400 : Number(e.target.value);
        setCustomWait(custom);
        setCustomDays(String(seconds / 86400));
        onChange(seconds);
      }}>
        <option value="0">{t("subscription.smart.waitNow")}</option>
        <option value="10800">{t("subscription.smart.waitThreeHours")}</option>
        <option value="86400">{t("subscription.smart.waitOneDay")}</option>
        <option value="custom">{t("subscription.smart.customWait")}</option>
        {legacyWait !== null && <option value={legacyWait}>{t("subscription.smart.legacyWait", { count: legacyWait / 3600 })}</option>}
      </select>
    </label>
    {customWait && <div className="mt-2 flex items-center justify-between gap-3 text-sub">
      <label htmlFor={daysInputId}>{t("subscription.smart.waitLimit")}</label>
      <div className="flex items-center rounded-xl border border-[var(--line)] bg-[var(--surface-inset)]">
        <button type="button" aria-label={t("subscription.smart.decreaseDays", { label })} disabled={!validDays || days <= 1} onClick={() => changeDays(String(days - 1))} className="h-11 w-11 shrink-0 rounded-l-xl text-title disabled:opacity-30">−</button>
        <input id={daysInputId} aria-label={t("subscription.smart.daysLabel", { label })} type="number" inputMode="numeric" min={1} max={7} step={1} required value={customDays} onChange={(e) => changeDays(e.target.value)} className="h-11 w-16 min-w-0 bg-transparent text-center text-ui tnum [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none" />
        <span className="pr-2 text-[var(--text-muted)]">{t("subscription.smart.daysUnit")}</span>
        <button type="button" aria-label={t("subscription.smart.increaseDays", { label })} disabled={!validDays || days >= 7} onClick={() => changeDays(String(days + 1))} className="h-11 w-11 shrink-0 rounded-r-xl text-title disabled:opacity-30">+</button>
      </div>
    </div>}
  </div>;
}

export function SmartDefaultsFields({ draft, setDraft, disabled = false }: {
  draft: SmartDefaultsInput;
  setDraft: (value: SmartDefaultsInput) => void;
  disabled?: boolean;
}) {
  const t = useTranslations();
  const strictLabel = t("subscription.smart.strictResolution", { resolution: draft.resolution === "2160p" ? "4K" : "1080p" });
  return (
    <fieldset disabled={disabled} className="space-y-4">
      <div className="grid grid-cols-2 gap-3">
        <label className="block text-sub">{t("subscription.smart.preferredResolution")}
          <select aria-label={t("subscription.smart.preferredResolution")} className={selectClass} value={draft.resolution} onChange={(e) => setDraft({ ...draft, resolution: e.target.value as SmartPreferences["resolution"] })}>
            <option value="2160p">4K</option><option value="1080p">1080p</option>
          </select>
        </label>
        <label className="block text-sub">{t("subscription.smart.preferredSource")}
          <select aria-label={t("subscription.smart.preferredSource")} className={selectClass} value={draft.source} onChange={(e) => setDraft({ ...draft, source: e.target.value as SmartPreferences["source"] })}>
            <option value="web-dl">WEB-DL</option><option value="blu-ray">{t("subscription.smart.bluray")}</option><option value="remux">Remux</option>
          </select>
        </label>
      </div>
      <WaitField label={t("subscription.smart.movieWait")} value={draft.movie_wait_seconds} onChange={(seconds) => setDraft({ ...draft, movie_wait_seconds: seconds })} />
      <WaitField label={t("subscription.smart.tvWait")} value={draft.tv_wait_seconds} onChange={(seconds) => setDraft({ ...draft, tv_wait_seconds: seconds })} />
      <label className="flex min-h-11 items-center gap-2 text-sub"><input type="checkbox" checked={draft.allow_upgrade} onChange={(e) => setDraft({ ...draft, allow_upgrade: e.target.checked })} />{t("subscription.smart.allowUpgrade")}</label>
      <details className="text-sub text-[var(--text-muted)]">
        <summary className="cursor-pointer py-1">{t("subscription.smart.minimumRequirements")}</summary>
        <div className="mt-2 space-y-2 leading-relaxed">
          <p>{t("subscription.smart.selectionHint")}</p>
          <p>{t("subscription.smart.waitHint")}</p>
        </div>
        <label className="mt-3 flex items-start gap-2"><input className="mt-1" type="checkbox" checked={draft.strict_resolution} onChange={(e) => setDraft({ ...draft, strict_resolution: e.target.checked })} />{strictLabel}</label>
      </details>
    </fieldset>
  );
}

function inputOf(d: SmartDefaults): SmartDefaultsInput {
  return {
    movie_revision: d.movie_revision, tv_revision: d.tv_revision, resolution: d.resolution, source: d.source,
    allow_upgrade: d.allow_upgrade, strict_resolution: d.strict_resolution,
    movie_wait_seconds: d.movie_wait_seconds, tv_wait_seconds: d.tv_wait_seconds,
  };
}

/**
 * 智能设置的「默认」：一套画质、洗版与最低要求，电影和剧集各一个等待上限。
 * 订阅弹层里首次设置、点「修改设置」也用它（compact）。
 */
export function SmartDefaultsCard({ compact = false, startEditing = false, onSaved, onCancel }: {
  compact?: boolean;
  startEditing?: boolean;
  onSaved?: (defaults: SmartDefaults) => void;
  onCancel?: () => void;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const { isAdmin } = usePermissions();
  const [defaults, setDefaults] = useState<SmartDefaults | null>(null);
  const [draft, setDraft] = useState<SmartDefaultsInput | null>(null);
  const [editing, setEditing] = useState(startEditing);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useMessageState();
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setError(null);
    getSmartDefaults().then((value) => {
      if (cancelled) return;
      setDefaults(value);
      setDraft(inputOf(value));
      if (!value.configured && isAdmin) setEditing(true);
    }).catch((e: Error) => { if (!cancelled) setError(e.message); });
    return () => { cancelled = true; };
  }, [isAdmin, reload, setError]);

  const save = async () => {
    if (!draft) return;
    setBusy(true);
    setError(null);
    try {
      const value = await saveSmartDefaults(draft);
      setDefaults(value);
      setDraft(inputOf(value));
      setEditing(false);
      onSaved?.(value);
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.smart.saveFailed" });
    } finally { setBusy(false); }
  };

  const summary = defaults?.configured && <div className="mt-2 space-y-2">
    <p className="text-title font-semibold">{t("subscription.smart.prefer", { quality: smartSummary(defaults, locale) })}</p>
    <p className="text-sub text-[var(--text-muted)]">{t("subscription.smart.defaultsSummary", { movie: waitText(defaults.movie_wait_seconds, locale), tv: waitText(defaults.tv_wait_seconds, locale), upgrade: defaults.allow_upgrade ? "yes" : "no" })}</p>
    {defaults.strict_resolution && <p className="text-sub text-[var(--text-muted)]">{t("subscription.smart.onlyResolution", { resolution: defaults.resolution === "2160p" ? "4K" : "1080p" })}</p>}
  </div>;

  return <section className={compact ? "text-[var(--text)]" : "rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4 text-[var(--text)]"} aria-label={t("subscription.smart.settingsLabel")}>
    {!compact && <div className="flex items-center justify-between gap-3">
      <h3 className="text-ui font-semibold">{t("subscription.smart.default")}</h3>
      {defaults?.configured && !editing && isAdmin && <button type="button" onClick={() => setEditing(true)} className="min-h-11 -my-2 -mr-2 px-2 text-sub text-[var(--accent)]">{t("subscription.smart.editSettings")}</button>}
    </div>}
    {error && <div className="mt-3 text-sub"><p role="alert" className="text-red-400">{error}</p><button type="button" className="mt-2 text-[var(--accent)]" onClick={() => setReload((value) => value + 1)}>{t("subscription.smart.reload")}</button></div>}
    {!defaults && !error && <p className="mt-3 text-sub text-[var(--text-muted)]">{t("subscription.smart.loading")}</p>}
    {defaults && !defaults.configured && !isAdmin && <p className="mt-3 text-sub text-[var(--text-muted)]">{t("subscription.smart.adminRequired")}</p>}
    {!editing && summary}
    {editing && isAdmin && draft && <form className="mt-4 space-y-4" onSubmit={(event) => { event.preventDefault(); void save(); }}>
      <p className="text-sub text-[var(--text-muted)]">{defaults?.configured ? t("subscription.smart.updateHint") : t("subscription.smart.setupHint")}</p>
      <SmartDefaultsFields draft={draft} setDraft={setDraft} disabled={busy} />
      <div className="flex justify-end gap-3">
        {(defaults?.configured || onCancel) && <button type="button" disabled={busy} onClick={() => { if (defaults) setDraft(inputOf(defaults)); setEditing(false); onCancel?.(); }} className="btn-glass px-4 py-2 text-sub">{t("subscription.smart.cancelChanges")}</button>}
        <button type="submit" disabled={busy} className="btn-accent rounded-full px-4 py-2 text-sub font-semibold">{busy ? t("subscription.smart.saving") : t("subscription.smart.save")}</button>
      </div>
    </form>}
  </section>;
}

/** 「看得懂的语言」与「画质习惯」：智能订阅记住的东西，每条写明来源，可以删。 */
export function SmartMemoryPanel() {
  const locale = useLocale();
  const t = useTranslations();
  const { isAdmin } = usePermissions();
  const [memory, setMemory] = useState<SmartMemory | null>(null);
  const [adding, setAdding] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useMessageState();

  const [reload, setReload] = useState(0);
  const load = () => setReload(value => value + 1);
  useEffect(() => {
    let cancelled = false;
    setError(null);
    getSmartMemory().then(value => { if (!cancelled) setMemory(value); })
      .catch((e: Error) => { if (!cancelled) setError(e.message); });
    return () => { cancelled = true; };
  }, [locale, reload, setError]);

  const change = async (body: { language?: string; understood?: boolean; remove_habit?: string }) => {
    if (!memory) return;
    setBusy(true);
    setError(null);
    try {
      setMemory(await updateSmartMemory({ revision: memory.revision, ...body }));
      load();
      setAdding("");
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.smart.saveFailed" });
      load();
    } finally { setBusy(false); }
  };

  if (!memory) return error ? <p role="alert" className="text-sub text-red-400">{error}</p> : null;
  return <section aria-label={t("subscription.smart.memoryLabel")} className="space-y-4">
    {error && <p role="alert" className="text-sub text-red-400">{error}</p>}
    <div className="rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4">
      <h3 className="text-ui font-semibold">{t("subscription.smart.understoodLanguages")}</h3>
      <p className="mt-1 text-sub text-[var(--text-muted)]">{t("subscription.smart.understoodHint")}</p>
      <ul className="mt-3 divide-y divide-[var(--line)]" aria-label={t("subscription.smart.understoodLanguages")}>
        {memory.languages.map((lang) => <li key={lang.key} className="flex min-h-11 items-center justify-between gap-3 py-2 text-sub">
          <span className="text-[var(--text)]">{lang.label}</span>
          <span className="flex items-center gap-3 text-caption text-[var(--text-muted)]">
            {lang.removable ? (lang.source_title ? t("subscription.smart.languageAddedFrom", { title: lang.source_title }) : t("subscription.smart.addedInSettings")) : t("subscription.smart.default")}
            {lang.removable && isAdmin && <button type="button" disabled={busy} onClick={() => void change({ language: lang.key, understood: false })} className="min-h-11 px-1 text-[var(--accent)]" aria-label={t("subscription.smart.removeNamed", { name: lang.label })}>{t("subscription.smart.remove")}</button>}
          </span>
        </li>)}
      </ul>
      {isAdmin && memory.addable_languages.length > 0 && <div className="mt-3 flex items-center gap-2">
        <select aria-label={t("subscription.smart.addLanguageLabel")} value={adding} onChange={(e) => setAdding(e.target.value)} className="min-w-0 flex-1 rounded-xl border border-[var(--line)] bg-[var(--surface-inset)] p-2.5 text-sub">
          <option value="">{t("subscription.smart.addLanguagePlaceholder")}</option>
          {memory.addable_languages.map((lang) => <option key={lang.key} value={lang.key}>{lang.label}</option>)}
        </select>
        <button type="button" disabled={busy || !adding} onClick={() => void change({ language: adding, understood: true })} className="btn-glass px-4 py-2 text-sub">{t("subscription.smart.addLanguage")}</button>
      </div>}
    </div>
    {memory.habits.length > 0 && <div className="rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4">
      <h3 className="text-ui font-semibold">{t("subscription.smart.qualityHabits")}</h3>
      <p className="mt-1 text-sub text-[var(--text-muted)]">{t("subscription.smart.habitsHint")}</p>
      <ul className="mt-3 divide-y divide-[var(--line)]" aria-label={t("subscription.smart.qualityHabits")}>
        {memory.habits.map((habit) => <li key={habit.key} className="flex min-h-11 items-center justify-between gap-3 py-2 text-sub">
          <span className="text-[var(--text)]">{habit.label} · {habit.quality_label}</span>
          <span className="flex items-center gap-3 text-caption text-[var(--text-muted)]">
            {habit.source_title ? t("subscription.smart.habitFrom", { title: habit.source_title }) : t("subscription.smart.legacyTvSource")}
            {isAdmin && <button type="button" disabled={busy} onClick={() => void change({ remove_habit: habit.key })} className="min-h-11 px-1 text-[var(--accent)]" aria-label={t("subscription.smart.removeNamed", { name: habit.label })}>{t("subscription.smart.remove")}</button>}
          </span>
        </li>)}
      </ul>
    </div>}
  </section>;
}

export function SmartSubscriptionSettings() {
  const t = useTranslations();
  return <section className="space-y-4">
    <p className="text-sub leading-relaxed text-[var(--text-muted)]">{t("subscription.smart.settingsHint")}</p>
    <SmartDefaultsCard />
    <SmartMemoryPanel />
    <p className="text-caption leading-relaxed text-[var(--text-muted)]">{t("subscription.smart.applyHint")}</p>
  </section>;
}
