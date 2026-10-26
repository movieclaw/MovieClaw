"use client";

import { useLocale, useTranslations } from "next-intl";
import { useMessageState } from "@/lib/i18n/use-message-state";

import { useEffect, useState } from "react";
import { listLlmProviders } from "@/lib/api/llm";
import { SETTINGS_BUTTON_CLASS, SETTINGS_INPUT_CLASS, SETTINGS_PRIMARY_BUTTON_CLASS } from "@/components/settings-ui";
import type { LlmPreset, LlmProviderConfig, LlmProviderType } from "@/lib/api/llm";

/** 浏览器只展示接入状态；OAuth 凭据不会经过浏览器存储。 */
export function ChatGPTPlanConnect({ config, presets, onSelect, onDone }: {
  config: LlmProviderConfig | null;
  presets: LlmPreset[];
  onSelect: (value: LlmProviderType) => void;
  onDone: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const command = "mclaw llm chatgpt login" + (config ? ` --provider ${config.id}` : "");
  const [waiting, setWaiting] = useState(false);
  const [error, setError] = useMessageState();
  const [knownIds, setKnownIds] = useState<number[] | null>(null);
  useEffect(() => {
    let disposed = false;
    void listLlmProviders().then((rows) => {
      if (!disposed) setKnownIds(rows.map((row) => row.id));
    }).catch((err) => { if (!disposed) setError((err as Error).message); });
    return () => { disposed = true; };
  }, [setError]);
  useEffect(() => {
    if (!waiting || knownIds === null) return;
    let disposed = false;
    const started = Date.now();
    const timer = setInterval(() => {
      void listLlmProviders().then((rows) => {
        if (disposed) return;
        const connected = rows.find((row) => row.provider_type === "chatgpt" && (
          config ? row.id === config.id && row.updated_at !== config.updated_at : !knownIds.includes(row.id)
        ));
        if (connected?.status === "failed") {
          setError(connected.last_error ?? {key: "settings.llm.chatgpt.failed"});
          setWaiting(false);
        } else if (connected?.status === "active") {
          setWaiting(false);
          onDone();
        } else if (Date.now() - started > 600000) {
          setError({key: "settings.llm.chatgpt.timeout"});
          setWaiting(false);
        }
      }).catch((err) => {
        if (!disposed) { setError((err as Error).message); setWaiting(false); }
      });
    }, 2000);
    return () => { disposed = true; clearInterval(timer); };
  }, [waiting, knownIds, config, onDone, setError]);
  return (
    <div className="space-y-5" data-testid="chatgpt-plan-connect">
      <label className="block space-y-2">
        <span>{t("settings.llm.chatgpt.provider")}</span>
        <select value="chatgpt" onChange={(event) => onSelect(event.target.value as LlmProviderType)} className={`${SETTINGS_INPUT_CLASS} w-full`}>
          {presets.map((preset) => <option key={preset.id} value={preset.id}>{preset.display_name}</option>)}
        </select>
      </label>
      <div className="space-y-3 text-sub leading-relaxed text-[var(--text-muted)]">
        <p>{t("settings.llm.chatgpt.preview")}</p>
        {config?.chatgpt_account && <p>{t("settings.llm.chatgpt.connected", {account: config.chatgpt_account})}</p>}
        <p>{t("settings.llm.chatgpt.pairing")}</p>
        <code className="block break-all rounded-lg bg-white/[0.05] p-3">{command}</code>
        <button type="button" className={SETTINGS_BUTTON_CLASS} onClick={() => void navigator.clipboard.writeText(command)}>{t("settings.llm.chatgpt.copy")}</button>
        <p>{t("settings.llm.chatgpt.authorize")}</p>
        <p>{t("settings.llm.chatgpt.waitingHint")}</p>
        <a href="https://chatgpt.com/settings/usage" target="_blank" rel="noreferrer" className="underline">{t("settings.llm.chatgpt.usage")}</a>
      </div>
      {error && <p role="alert" className="text-[var(--danger)]">{error}</p>}
      {waiting && <p role="status">{t("settings.llm.chatgpt.waiting")}</p>}
      <div className={`flex gap-3 ${locale === "en" ? "max-sm:flex-col max-sm:items-start" : ""}`}>
        <button type="button" disabled={knownIds === null} onClick={() => { setError(null); setWaiting(!waiting); }} className={SETTINGS_PRIMARY_BUTTON_CLASS}>{waiting ? t("settings.llm.chatgpt.stop") : t("settings.llm.chatgpt.wait")}</button>
        <button type="button" onClick={onDone} className={SETTINGS_BUTTON_CLASS}>{t("settings.llm.chatgpt.refresh")}</button>
      </div>
    </div>
  );
}
