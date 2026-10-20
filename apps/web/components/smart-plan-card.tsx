"use client";

import { useEffect, useId, useState } from "react";

import { SmartDefaultsCard, smartSummary } from "@/components/smart-subscription-settings";
import type { SmartPlan, SmartPreferences } from "@/lib/api/subscriptions";

/** 订阅弹层里管理员做的选择；提交时随创建请求带上，由服务端写入记忆。 */
export interface SmartChoice {
  language?: "subtitles" | "understood";
  resolution?: SmartPreferences["resolution"];
  source?: SmartPreferences["source"];
  scope: string;
}

export const EMPTY_CHOICE: SmartChoice = { scope: "only" };

/** 选择 → 创建请求字段。题目出现时即使没改也回传默认答案：答过就不再问。 */
export function smartChoicePayload(plan: SmartPlan, choice: SmartChoice) {
  if (!plan.can_edit) return {};
  const language = choice.language ?? (plan.question ? "subtitles" : undefined);
  const resolution = choice.resolution && choice.resolution !== plan.resolution ? choice.resolution : undefined;
  const source = choice.source && choice.source !== plan.source ? choice.source : undefined;
  return {
    smart_memory_revision: plan.memory_revision,
    ...(language ? { smart_language_answer: language } : {}),
    ...(resolution ? { smart_resolution: resolution } : {}),
    ...(source ? { smart_source: source } : {}),
    ...(resolution || source ? { smart_scope: choice.scope } : {}),
  };
}

function Segmented<T extends string>({ label, value, options, onChange }: {
  label: string; value: T; options: { value: T; label: string }[]; onChange: (value: T) => void;
}) {
  return <div role="group" aria-label={label} className="flex rounded-full border border-[var(--line)] bg-[var(--surface-inset)] p-0.5">
    {options.map((o) => <button key={o.value} type="button" aria-pressed={value === o.value} onClick={() => onChange(o.value)}
      className={`min-h-9 flex-1 rounded-full px-3 text-sub ${value === o.value ? "bg-[var(--accent)] font-semibold text-[#141821]" : "text-[var(--text-muted)]"}`}>{o.label}</button>)}
  </div>;
}

function Choices({ name, legend, value, options, onChange }: {
  name: string; legend: string; value: string; options: { value: string; label: string }[]; onChange: (value: string) => void;
}) {
  return <fieldset className="mt-3 rounded-xl border border-[var(--line-strong)] p-3">
    <legend className="px-1 text-ui text-[var(--text)]">{legend}</legend>
    <div className="mt-1 space-y-1">
      {options.map((o) => <label key={o.value} className="flex min-h-9 cursor-pointer items-center gap-2.5 text-sub text-[var(--text)]">
        <input type="radio" name={name} value={o.value} checked={value === o.value} onChange={() => onChange(o.value)} />{o.label}
      </label>)}
    </div>
  </fieldset>;
}

export function SmartPlanCard({ plan, choice, setChoice, onSettingsSaved, onEditingChange }: {
  plan: SmartPlan | null;
  choice: SmartChoice;
  setChoice: (choice: SmartChoice) => void;
  onSettingsSaved: () => void;
  /** 正在改智能设置时不能提交订阅（还没保存的设置不算数） */
  onEditingChange?: (editing: boolean) => void;
}) {
  const id = useId();
  const [editingDefaults, setEditingDefaultsState] = useState(false);
  const setEditingDefaults = (editing: boolean) => {
    setEditingDefaultsState(editing);
    onEditingChange?.(editing);
  };
  // 卡片被换掉（切到规则模式、重新预检）时，没保存的编辑就不算了
  useEffect(() => () => onEditingChange?.(false), [onEditingChange]);
  const [editingQuality, setEditingQuality] = useState(false);
  const [editingSubtitle, setEditingSubtitle] = useState(false);

  if (!plan) return <section aria-label="智能选择" className="rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4">
    <p className="text-sub text-[var(--text-muted)]">正在读取设置…</p>
  </section>;

  const heading = <div className="flex items-center justify-between gap-3">
    <h3 className="text-sub text-[var(--text-muted)]">智能选择</h3>
    {plan.configured && plan.can_edit && !editingDefaults && <button type="button" onClick={() => setEditingDefaults(true)} className="min-h-11 -my-2 -mr-2 px-2 text-sub text-[var(--accent)]">修改设置</button>}
  </div>;

  if (!plan.configured || editingDefaults) {
    return <section aria-label="智能选择" className="rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4">
      {heading}
      {plan.can_edit
        ? <SmartDefaultsCard compact startEditing onSaved={() => { setEditingDefaults(false); onSettingsSaved(); }} onCancel={plan.configured ? () => setEditingDefaults(false) : undefined} />
        : <p className="mt-3 text-sub text-[var(--text-muted)]">请管理员先完成智能设置，或选择规则模式。</p>}
    </section>;
  }

  const resolution = choice.resolution ?? plan.resolution!;
  const source = choice.source ?? plan.source!;
  const qualityChanged = resolution !== plan.resolution || source !== plan.source;
  const answer = choice.language ?? (plan.subtitle_understood ? "understood" : "subtitles");
  const language = plan.subtitle_language_label;
  const askLanguage = plan.can_edit && language && (plan.question || editingSubtitle);
  const question = plan.question ?? (language ? {
    prompt: `${language}看得懂吗？`,
    subtitles_label: plan.subtitle_understood ? `要，只下带字幕的` : (plan.subtitle_line ?? "").replace(`${language} · `, "要，"),
    understood_label: `不用，我看得懂${language}`,
  } : null);
  const subtitleLine = choice.language === "understood" ? `${language} · 不需要字幕`
    : choice.language === "subtitles" && plan.subtitle_understood ? `${language} · 只下带字幕的` : plan.subtitle_line;

  return <section aria-label="智能选择" className="rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4 text-[var(--text)]">
    {heading}
    <div className="mt-2 flex items-start justify-between gap-3">
      <div className="min-w-0 space-y-1">
        <p className="text-title font-semibold">{qualityChanged ? `优先 ${smartSummary({ resolution, source })}` : plan.quality_label}</p>
        {!qualityChanged && plan.quality_note && <p className="text-caption text-[var(--text-muted)]">{plan.quality_note}</p>}
        {!qualityChanged && plan.quality_shadow && <p className="text-caption text-[var(--text-muted)]">{plan.quality_shadow}</p>}
        <p className="text-sub text-[var(--text-muted)]">{plan.wait_label}</p>
      </div>
      {plan.can_edit && <button type="button" aria-expanded={editingQuality} onClick={() => setEditingQuality((v) => !v)} className="min-h-11 -my-2 -mr-2 shrink-0 px-2 text-sub text-[var(--accent)]">{editingQuality ? "收起" : "改画质"}</button>}
    </div>
    {editingQuality && <div className="mt-3 space-y-2">
      <Segmented label="分辨率" value={resolution} onChange={(value) => setChoice({ ...choice, resolution: value })}
        options={[{ value: "2160p", label: "4K" }, { value: "1080p", label: "1080p" }]} />
      <Segmented label="片源" value={source} onChange={(value) => setChoice({ ...choice, source: value })}
        options={[{ value: "web-dl", label: "WEB-DL" }, { value: "blu-ray", label: "蓝光" }, { value: "remux", label: "Remux" }]} />
      {qualityChanged && <Choices name={`${id}-scope`} legend="以后也这样吗？" value={choice.scope}
        options={plan.scope_options} onChange={(value) => setChoice({ ...choice, scope: value })} />}
    </div>}
    {askLanguage && question
      ? <Choices name={`${id}-language`} legend={question.prompt} value={answer}
          options={[{ value: "subtitles", label: question.subtitles_label }, { value: "understood", label: question.understood_label }]}
          onChange={(value) => setChoice({ ...choice, language: value as SmartChoice["language"] })} />
      : subtitleLine && <div className="mt-3 flex items-center justify-between gap-3 border-t border-[var(--line)] pt-3">
          <p className="text-sub">{subtitleLine}</p>
          {plan.can_edit && <button type="button" onClick={() => setEditingSubtitle(true)} className="min-h-11 -my-2 -mr-2 shrink-0 px-2 text-sub text-[var(--accent)]" aria-label="改字幕要求">改</button>}
        </div>}
  </section>;
}
