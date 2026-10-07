"use client";

import { useEffect, useId, useState } from "react";
import { getSmartProfile, saveSmartProfile, type SmartPreferences, type SmartProfile } from "@/lib/api/subscriptions";
import { usePermissions } from "@/lib/permissions";

export function smartSummary(p: SmartPreferences) {
  const resolution = p.resolution === "2160p" ? "4K" : "1080p";
  const source = { "web-dl": "WEB-DL", "blu-ray": "蓝光", remux: "Remux" }[p.source];
  return `${resolution} ${source}`;
}

export function SmartPreferencesFields({ draft, setDraft, disabled = false, compact = false }: {
  draft: SmartPreferences;
  setDraft: (value: SmartPreferences) => void; disabled?: boolean; compact?: boolean;
}) {
  const daysInputId = useId();
  const [legacyWait] = useState(() => ![0, 10800, 86400].includes(draft.wait_seconds) && draft.wait_seconds % 86400 !== 0 ? draft.wait_seconds : null);
  const [customWait, setCustomWait] = useState(() => ![0, 10800, 86400].includes(draft.wait_seconds) && draft.wait_seconds % 86400 === 0);
  const [customDays, setCustomDays] = useState(() => String(Math.max(1, Math.ceil(draft.wait_seconds / 86400))));
  const days = Number(customDays);
  const validDays = customDays !== "" && Number.isInteger(days) && days >= 1 && days <= 7;
  const changeDays = (value: string) => {
    setCustomDays(value);
    if (value !== "" && Number.isFinite(Number(value))) setDraft({ ...draft, wait_seconds: Number(value) * 86400 });
  };
  const explanation = <>
    <p>优先比较分辨率，再比较片源；后续洗版不会降低任一项品质。</p>
    <p>已有资源的发布时间会计入等待。等待上限指选择下载版本的时间，不是可观看时间。</p>
    {draft.allow_upgrade && <p>达到 {smartSummary(draft)} 并完成入库核验后停止洗版，剧集逐集判断。</p>}
  </>;
  return (
    <fieldset disabled={disabled} className="space-y-4">
      <div className={compact ? "grid grid-cols-2 gap-3" : "space-y-4"}>
        <label className="block text-sub">优先分辨率
          <select aria-label="优先分辨率" className="mt-1.5 w-full rounded-xl border border-[var(--line)] bg-[var(--surface-inset)] p-2.5" value={draft.resolution} onChange={(e) => setDraft({ ...draft, resolution: e.target.value as SmartPreferences["resolution"] })}>
            <option value="2160p">4K</option><option value="1080p">1080p</option>
          </select>
        </label>
        <label className="block text-sub">优先片源
          <select aria-label="优先片源" className="mt-1.5 w-full rounded-xl border border-[var(--line)] bg-[var(--surface-inset)] p-2.5" value={draft.source} onChange={(e) => setDraft({ ...draft, source: e.target.value as SmartPreferences["source"] })}>
            <option value="web-dl">WEB-DL</option><option value="blu-ray">蓝光</option><option value="remux">Remux</option>
          </select>
        </label>
      </div>
      <label className="block text-sub">等待耐心
        <select aria-label="等待耐心" className="mt-1.5 w-full rounded-xl border border-[var(--line)] bg-[var(--surface-inset)] p-2.5" value={customWait ? "custom" : draft.wait_seconds} onChange={(e) => {
          const custom = e.target.value === "custom";
          const seconds = custom ? Math.min(7, Math.max(1, Math.ceil(draft.wait_seconds / 86400))) * 86400 : Number(e.target.value);
          setCustomWait(custom);
          setCustomDays(String(seconds / 86400));
          setDraft({ ...draft, wait_seconds: seconds });
        }}>
          <option value="0">尽快下载 · 不等待</option>
          <option value="10800">可以等 · 最多 3 小时</option>
          <option value="86400">更有耐心 · 最多 1 天</option>
          <option value="custom">自定义</option>
          {legacyWait !== null && <option value={legacyWait}>原有设置 · {legacyWait / 3600} 小时</option>}
        </select>
      </label>
      {customWait && <div className="text-sub">
        <div className="flex items-center justify-between gap-3">
          <label htmlFor={daysInputId}>最多等待</label>
          <div className="flex items-center rounded-xl border border-[var(--line)] bg-[var(--surface-inset)]">
            <button type="button" aria-label="减少 1 天" disabled={!validDays || days <= 1} onClick={() => changeDays(String(days - 1))} className="h-11 w-11 shrink-0 rounded-l-xl text-title disabled:opacity-30">−</button>
            <input id={daysInputId} aria-label="自定义等待天数" type="number" inputMode="numeric" min={1} max={7} step={1} required value={customDays} onChange={(e) => changeDays(e.target.value)} className="h-11 w-16 min-w-0 bg-transparent text-center text-ui tnum [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none" />
            <span className="pr-2 text-[var(--text-muted)]">天</span>
            <button type="button" aria-label="增加 1 天" disabled={!validDays || days >= 7} onClick={() => changeDays(String(days + 1))} className="h-11 w-11 shrink-0 rounded-r-xl text-title disabled:opacity-30">+</button>
          </div>
        </div>
      </div>}
      <label className="flex min-h-11 items-center gap-2 text-sub"><input type="checkbox" checked={draft.allow_upgrade} onChange={(e) => setDraft({ ...draft, allow_upgrade: e.target.checked })} />允许后续洗版</label>
      {compact ? <details className="text-sub text-[var(--text-muted)]">
        <summary className="cursor-pointer py-1">选择说明与最低要求</summary>
        <div className="mt-2 space-y-2 leading-relaxed">{explanation}</div>
        <label className="mt-3 flex items-start gap-2"><input className="mt-1" type="checkbox" checked={draft.strict_resolution} onChange={(e) => setDraft({ ...draft, strict_resolution: e.target.checked })} />只接受 {draft.resolution === "2160p" ? "4K" : "1080p"}，到期也不降低分辨率</label>
      </details> : <>
        <div className="space-y-2 text-sub text-[var(--text-muted)]">{explanation}</div>
        <details><summary className="cursor-pointer text-sub text-[var(--text-muted)]">最低要求</summary><label className="mt-3 flex items-center gap-2 text-sub"><input type="checkbox" checked={draft.strict_resolution} onChange={(e) => setDraft({ ...draft, strict_resolution: e.target.checked })} />只接受 {draft.resolution === "2160p" ? "4K" : "1080p"}，到期也不降低分辨率</label></details>
      </>}
    </fieldset>
  );
}

export function SmartProfileCard({ kind, onSaved, compact = false }: {
  kind: "movie" | "tv";
  onSaved?: (profile: SmartProfile | null) => void;
  compact?: boolean;
}) {
  const { isAdmin } = usePermissions();
  const [profile, setProfile] = useState<SmartProfile | null>(null);
  const [draft, setDraft] = useState<SmartPreferences | null>(null);
  const [reload, setReload] = useState(0);
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const label = kind === "movie" ? "电影" : "剧集";

  useEffect(() => {
    let cancelled = false;
    setProfile(null);
    setDraft(null);
    setError(null);
    onSaved?.(null);
    getSmartProfile(kind).then((value) => {
      if (cancelled) return;
      setProfile(value);
      setDraft(value.preferences ?? { resolution: "2160p", source: "web-dl", wait_seconds: kind === "movie" ? 86400 : 10800, allow_upgrade: true, strict_resolution: false });
      setEditing(!value.preferences);
      onSaved?.(value);
    }).catch((e: Error) => { if (!cancelled) setError(e.message); });
    return () => { cancelled = true; };
  }, [kind, onSaved, reload]);

  const save = async () => {
    if (!draft || !profile) return;
    setBusy(true);
    setError(null);
    try {
      const value = await saveSmartProfile(kind, draft, profile.revision);
      setProfile(value);
      setEditing(false);
      onSaved?.(value);
    } catch (e) {
      setError(e instanceof Error ? e.message : "保存失败，请重试");
    } finally { setBusy(false); }
  };

  const preferences = profile?.preferences;
  const wait = preferences?.wait_seconds ?? 0;
  const waitLabel = wait === 0 ? "尽快下载" : wait % 86400 === 0 ? `最多等 ${wait / 86400} 天` : `最多等 ${wait / 3600} 小时`;

  return <section className="rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4 text-[var(--text)]" aria-label={`${label}智能设置`}>
    <div className="flex items-center justify-between gap-3">
      <h3 className={compact && !editing ? "text-sub text-[var(--text-muted)]" : "text-ui font-semibold"}>{compact && !editing ? "智能选择" : `${label}智能设置`}</h3>
      {profile?.preferences && !editing && isAdmin && <button type="button" onClick={() => { setEditing(true); onSaved?.(null); }} className="min-h-11 -my-2 -mr-2 px-2 text-sub text-[var(--accent)]">修改设置</button>}
    </div>
    {error && <div className="mt-3 text-sub"><p role="alert" className="text-red-400">{error}</p><button type="button" className="mt-2 text-[var(--accent)]" onClick={() => setReload((value) => value + 1)}>重新读取设置</button></div>}
    {!profile && !error && <p className="mt-3 text-sub text-[var(--text-muted)]">正在读取设置…</p>}
    {profile && !profile.preferences && !isAdmin && <p className="mt-3 text-sub text-[var(--text-muted)]">请管理员先完成{label}智能设置，或选择规则模式。</p>}
    {preferences && !editing && compact && <div className="mt-2 space-y-2">
      <p className="text-title font-semibold">优先 {smartSummary(preferences)}</p>
      <p className="text-sub text-[var(--text-muted)]">{waitLabel} · {preferences.allow_upgrade ? "达标后停止洗版" : "入库后不洗版"}</p>
      {preferences.strict_resolution && <p className="text-sub text-[var(--text-muted)]">只接受 {preferences.resolution === "2160p" ? "4K" : "1080p"}</p>}
    </div>}
    {profile?.preferences && !editing && !compact && <div className="mt-3 space-y-2 text-sub text-[var(--text-muted)]">
      <p className="text-title font-semibold text-[var(--text)]">优先 {smartSummary(profile.preferences)}</p>
      <p>{waitLabel}</p>
      <p>{profile.preferences.allow_upgrade ? `允许后续洗版，达到 ${smartSummary(profile.preferences)} 并完成入库核验后停止。` : "入库后不自动洗版。"}</p>
      {profile.preferences.strict_resolution && <p>只接受所选分辨率，到期也不降低要求。</p>}

    </div>}
    {editing && isAdmin && draft && <form className="mt-4 space-y-4" onSubmit={(event) => { event.preventDefault(); void save(); }}>
      <p className="text-sub text-[var(--text-muted)]">{profile?.preferences ? "修改只影响之后新建的订阅。" : `只需设置一次，后续${label}订阅自动复用。`}</p>
      <SmartPreferencesFields draft={draft} setDraft={setDraft} disabled={busy} compact={compact} />
      <div className="flex justify-end gap-3">
        {profile?.preferences && <button type="button" disabled={busy} onClick={() => { setDraft(profile.preferences); setEditing(false); onSaved?.(profile); }} className="btn-glass px-4 py-2 text-sub">取消修改</button>}
        <button type="submit" disabled={busy} className="btn-accent rounded-full px-4 py-2 text-sub font-semibold">{busy ? "正在保存…" : `保存${label}设置`}</button>
      </div>
    </form>}
  </section>;
}

export function SmartSubscriptionSettings() {
  return <section className="space-y-4"><p className="text-sub leading-relaxed text-[var(--text-muted)]">按品质目标和等待耐心自动选择版本，电影和剧集分别设置。</p><div className="grid gap-4 lg:grid-cols-2"><SmartProfileCard kind="movie" /><SmartProfileCard kind="tv" /></div><p className="text-caption leading-relaxed text-[var(--text-muted)]">后续订阅复用对应设置。已有订阅保持创建时的设置。</p></section>;
}
