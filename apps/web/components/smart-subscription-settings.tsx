"use client";

import { useCallback, useEffect, useId, useState } from "react";
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

const SOURCE_LABELS = { "web-dl": "WEB-DL", "blu-ray": "蓝光", remux: "Remux" } as const;

export function smartSummary(p: Pick<SmartPreferences, "resolution" | "source">) {
  const resolution = p.resolution === "2160p" ? "4K" : "1080p";
  return `${resolution} ${SOURCE_LABELS[p.source]}`;
}

export function waitText(seconds: number) {
  if (seconds === 0) return "尽快下载";
  return seconds % 86400 === 0 ? `最多等 ${seconds / 86400} 天` : `最多等 ${seconds / 3600} 小时`;
}

const selectClass = "mt-1.5 w-full rounded-xl border border-[var(--line)] bg-[var(--surface-inset)] p-2.5";

/** 等待上限：预设三档、自定义 1–7 天，旧版本存下的整小时值原样保留为一档。 */
function WaitField({ label, value, onChange }: { label: string; value: number; onChange: (seconds: number) => void }) {
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
        <option value="0">尽快下载 · 不等待</option>
        <option value="10800">可以等 · 最多 3 小时</option>
        <option value="86400">更有耐心 · 最多 1 天</option>
        <option value="custom">自定义</option>
        {legacyWait !== null && <option value={legacyWait}>原有设置 · {legacyWait / 3600} 小时</option>}
      </select>
    </label>
    {customWait && <div className="mt-2 flex items-center justify-between gap-3 text-sub">
      <label htmlFor={daysInputId}>最多等待</label>
      <div className="flex items-center rounded-xl border border-[var(--line)] bg-[var(--surface-inset)]">
        <button type="button" aria-label={`${label}减少 1 天`} disabled={!validDays || days <= 1} onClick={() => changeDays(String(days - 1))} className="h-11 w-11 shrink-0 rounded-l-xl text-title disabled:opacity-30">−</button>
        <input id={daysInputId} aria-label={`${label}天数`} type="number" inputMode="numeric" min={1} max={7} step={1} required value={customDays} onChange={(e) => changeDays(e.target.value)} className="h-11 w-16 min-w-0 bg-transparent text-center text-ui tnum [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none" />
        <span className="pr-2 text-[var(--text-muted)]">天</span>
        <button type="button" aria-label={`${label}增加 1 天`} disabled={!validDays || days >= 7} onClick={() => changeDays(String(days + 1))} className="h-11 w-11 shrink-0 rounded-r-xl text-title disabled:opacity-30">+</button>
      </div>
    </div>}
  </div>;
}

export function SmartDefaultsFields({ draft, setDraft, disabled = false }: {
  draft: SmartDefaultsInput;
  setDraft: (value: SmartDefaultsInput) => void;
  disabled?: boolean;
}) {
  const strictLabel = `只接受 ${draft.resolution === "2160p" ? "4K" : "1080p"}，到期也不降低分辨率`;
  return (
    <fieldset disabled={disabled} className="space-y-4">
      <div className="grid grid-cols-2 gap-3">
        <label className="block text-sub">优先分辨率
          <select aria-label="优先分辨率" className={selectClass} value={draft.resolution} onChange={(e) => setDraft({ ...draft, resolution: e.target.value as SmartPreferences["resolution"] })}>
            <option value="2160p">4K</option><option value="1080p">1080p</option>
          </select>
        </label>
        <label className="block text-sub">优先片源
          <select aria-label="优先片源" className={selectClass} value={draft.source} onChange={(e) => setDraft({ ...draft, source: e.target.value as SmartPreferences["source"] })}>
            <option value="web-dl">WEB-DL</option><option value="blu-ray">蓝光</option><option value="remux">Remux</option>
          </select>
        </label>
      </div>
      <WaitField label="电影最多等" value={draft.movie_wait_seconds} onChange={(seconds) => setDraft({ ...draft, movie_wait_seconds: seconds })} />
      <WaitField label="剧集每集最多等" value={draft.tv_wait_seconds} onChange={(seconds) => setDraft({ ...draft, tv_wait_seconds: seconds })} />
      <label className="flex min-h-11 items-center gap-2 text-sub"><input type="checkbox" checked={draft.allow_upgrade} onChange={(e) => setDraft({ ...draft, allow_upgrade: e.target.checked })} />允许后续洗版</label>
      <details className="text-sub text-[var(--text-muted)]">
        <summary className="cursor-pointer py-1">选择说明与最低要求</summary>
        <div className="mt-2 space-y-2 leading-relaxed">
          <p>优先比较分辨率，再比较片源；后续洗版不会降低任一项品质。外语作品只下带你看得懂的字幕的版本。</p>
          <p>已有资源的发布时间会计入等待。等待上限指选择下载版本的时间，不是可观看时间。</p>
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
  const { isAdmin } = usePermissions();
  const [defaults, setDefaults] = useState<SmartDefaults | null>(null);
  const [draft, setDraft] = useState<SmartDefaultsInput | null>(null);
  const [editing, setEditing] = useState(startEditing);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
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
  }, [isAdmin, reload]);

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
      setError(e instanceof Error ? e.message : "保存失败，请重试");
    } finally { setBusy(false); }
  };

  const summary = defaults?.configured && <div className="mt-2 space-y-2">
    <p className="text-title font-semibold">优先 {smartSummary(defaults)}</p>
    <p className="text-sub text-[var(--text-muted)]">电影{waitText(defaults.movie_wait_seconds)} · 剧集每集{waitText(defaults.tv_wait_seconds)} · {defaults.allow_upgrade ? "达标后停止洗版" : "入库后不洗版"}</p>
    {defaults.strict_resolution && <p className="text-sub text-[var(--text-muted)]">只接受 {defaults.resolution === "2160p" ? "4K" : "1080p"}</p>}
  </div>;

  return <section className={compact ? "text-[var(--text)]" : "rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4 text-[var(--text)]"} aria-label="智能设置">
    {!compact && <div className="flex items-center justify-between gap-3">
      <h3 className="text-ui font-semibold">默认</h3>
      {defaults?.configured && !editing && isAdmin && <button type="button" onClick={() => setEditing(true)} className="min-h-11 -my-2 -mr-2 px-2 text-sub text-[var(--accent)]">修改设置</button>}
    </div>}
    {error && <div className="mt-3 text-sub"><p role="alert" className="text-red-400">{error}</p><button type="button" className="mt-2 text-[var(--accent)]" onClick={() => setReload((value) => value + 1)}>重新读取设置</button></div>}
    {!defaults && !error && <p className="mt-3 text-sub text-[var(--text-muted)]">正在读取设置…</p>}
    {defaults && !defaults.configured && !isAdmin && <p className="mt-3 text-sub text-[var(--text-muted)]">请管理员先完成智能设置，或选择规则模式。</p>}
    {!editing && summary}
    {editing && isAdmin && draft && <form className="mt-4 space-y-4" onSubmit={(event) => { event.preventDefault(); void save(); }}>
      <p className="text-sub text-[var(--text-muted)]">{defaults?.configured ? "新订阅和还在等待的订阅都会按新设置来，已经下载的不受影响。" : "只需设置一次，电影和剧集都按它来。"}</p>
      <SmartDefaultsFields draft={draft} setDraft={setDraft} disabled={busy} />
      <div className="flex justify-end gap-3">
        {(defaults?.configured || onCancel) && <button type="button" disabled={busy} onClick={() => { if (defaults) setDraft(inputOf(defaults)); setEditing(false); onCancel?.(); }} className="btn-glass px-4 py-2 text-sub">取消修改</button>}
        <button type="submit" disabled={busy} className="btn-accent rounded-full px-4 py-2 text-sub font-semibold">{busy ? "正在保存…" : "保存设置"}</button>
      </div>
    </form>}
  </section>;
}

/** 「看得懂的语言」与「画质习惯」：智能订阅记住的东西，每条写明来源，可以删。 */
export function SmartMemoryPanel() {
  const { isAdmin } = usePermissions();
  const [memory, setMemory] = useState<SmartMemory | null>(null);
  const [adding, setAdding] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => {
    setError(null);
    getSmartMemory().then(setMemory).catch((e: Error) => setError(e.message));
  }, []);
  useEffect(load, [load]);

  const change = async (body: { language?: string; understood?: boolean; remove_habit?: string }) => {
    if (!memory) return;
    setBusy(true);
    setError(null);
    try {
      setMemory(await updateSmartMemory({ revision: memory.revision, ...body }));
      setAdding("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "保存失败，请重试");
      load();
    } finally { setBusy(false); }
  };

  if (!memory) return error ? <p role="alert" className="text-sub text-red-400">{error}</p> : null;
  return <section aria-label="它记住的" className="space-y-4">
    {error && <p role="alert" className="text-sub text-red-400">{error}</p>}
    <div className="rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4">
      <h3 className="text-ui font-semibold">看得懂的语言</h3>
      <p className="mt-1 text-sub text-[var(--text-muted)]">这些语言的作品不带字幕也能看；其他语言只下带字幕的版本。</p>
      <ul className="mt-3 divide-y divide-[var(--line)]" aria-label="看得懂的语言">
        {memory.languages.map((lang) => <li key={lang.key} className="flex min-h-11 items-center justify-between gap-3 py-2 text-sub">
          <span className="text-[var(--text)]">{lang.label}</span>
          <span className="flex items-center gap-3 text-caption text-[var(--text-muted)]">
            {lang.removable ? (lang.source_title ? `订阅《${lang.source_title}》时加入` : "在设置里加入") : "默认"}
            {lang.removable && isAdmin && <button type="button" disabled={busy} onClick={() => void change({ language: lang.key, understood: false })} className="min-h-11 px-1 text-[var(--accent)]" aria-label={`移除${lang.label}`}>移除</button>}
          </span>
        </li>)}
      </ul>
      {isAdmin && memory.addable_languages.length > 0 && <div className="mt-3 flex items-center gap-2">
        <select aria-label="添加看得懂的语言" value={adding} onChange={(e) => setAdding(e.target.value)} className="min-w-0 flex-1 rounded-xl border border-[var(--line)] bg-[var(--surface-inset)] p-2.5 text-sub">
          <option value="">添加一种语言…</option>
          {memory.addable_languages.map((lang) => <option key={lang.key} value={lang.key}>{lang.label}</option>)}
        </select>
        <button type="button" disabled={busy || !adding} onClick={() => void change({ language: adding, understood: true })} className="btn-glass px-4 py-2 text-sub">添加</button>
      </div>}
    </div>
    {memory.habits.length > 0 && <div className="rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4">
      <h3 className="text-ui font-semibold">画质习惯</h3>
      <p className="mt-1 text-sub text-[var(--text-muted)]">订阅时改过画质并选了「以后也这样」，就记在这里。</p>
      <ul className="mt-3 divide-y divide-[var(--line)]" aria-label="画质习惯">
        {memory.habits.map((habit) => <li key={habit.key} className="flex min-h-11 items-center justify-between gap-3 py-2 text-sub">
          <span className="text-[var(--text)]">{habit.label} · {habit.quality_label}</span>
          <span className="flex items-center gap-3 text-caption text-[var(--text-muted)]">
            {habit.source_title ? `来自《${habit.source_title}》` : "来自原来的剧集设置"}
            {isAdmin && <button type="button" disabled={busy} onClick={() => void change({ remove_habit: habit.key })} className="min-h-11 px-1 text-[var(--accent)]" aria-label={`移除${habit.label}`}>移除</button>}
          </span>
        </li>)}
      </ul>
    </div>}
  </section>;
}

export function SmartSubscriptionSettings() {
  return <section className="space-y-4">
    <p className="text-sub leading-relaxed text-[var(--text-muted)]">按品质目标和等待耐心自动选择版本，电影和剧集共用一套。订阅外语作品时会问一次看不看得懂，改过的画质也可以记住。</p>
    <SmartDefaultsCard />
    <SmartMemoryPanel />
    <p className="text-caption leading-relaxed text-[var(--text-muted)]">保存后新订阅和还在等待的订阅同时生效。正在等待的集只会按新设置缩短等待，不会延长；手动延长过的保持不变。</p>
  </section>;
}
