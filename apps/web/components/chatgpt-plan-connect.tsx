"use client";

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
  const command = "mclaw llm chatgpt login" + (config ? ` --provider ${config.id}` : "");
  const [waiting, setWaiting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [knownIds, setKnownIds] = useState<number[] | null>(null);
  useEffect(() => {
    let disposed = false;
    void listLlmProviders().then((rows) => {
      if (!disposed) setKnownIds(rows.map((row) => row.id));
    }).catch((err) => { if (!disposed) setError((err as Error).message); });
    return () => { disposed = true; };
  }, []);
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
          setError(connected.last_error ?? "ChatGPT 连接失败，请重新授权");
          setWaiting(false);
        } else if (connected?.status === "active") {
          setWaiting(false);
          onDone();
        } else if (Date.now() - started > 600000) {
          setError("尚未收到完成的授权，请检查电脑上的连接命令并重试。");
          setWaiting(false);
        }
      }).catch((err) => {
        if (!disposed) { setError((err as Error).message); setWaiting(false); }
      });
    }, 2000);
    return () => { disposed = true; clearInterval(timer); };
  }, [waiting, knownIds, config, onDone]);
  return (
    <div className="space-y-5" data-testid="chatgpt-plan-connect">
      <label className="block space-y-2">
        <span>供应商</span>
        <select value="chatgpt" onChange={(event) => onSelect(event.target.value as LlmProviderType)} className={`${SETTINGS_INPUT_CLASS} w-full`}>
          {presets.map((preset) => <option key={preset.id} value={preset.id}>{preset.display_name}</option>)}
        </select>
      </label>
      <div className="space-y-3 text-sub leading-relaxed text-[var(--text-muted)]">
        <p>ChatGPT 订阅接入目前为预览功能。使用 ChatGPT Plus / Pro 订阅，无需 API Key。额度与其他使用该订阅的 App 共享。</p>
        {config?.chatgpt_account && <p>已连接：{config.chatgpt_account}</p>}
        <p>在运行浏览器的电脑上先用 mclaw login 配对这台服务器，再执行：</p>
        <code className="block break-all rounded-lg bg-white/[0.05] p-3">{command}</code>
        <button type="button" className={SETTINGS_BUTTON_CLASS} onClick={() => void navigator.clipboard.writeText(command)}>复制连接命令</button>
        <p>在官方页面选择 Continue with ChatGPT，并允许使用订阅。授权会自动传回服务器并加密保存，然后回到这里刷新。</p>
        <p>运行命令前，可以先点击下方「等待授权结果」，网页会显示连接进度。</p>
        <a href="https://chatgpt.com/settings/usage" target="_blank" rel="noreferrer" className="underline">管理 ChatGPT 用量</a>
      </div>
      {error && <p role="alert" className="text-[var(--danger)]">{error}</p>}
      {waiting && <p role="status">正在等待电脑授权及模型验证…</p>}
      <div className="flex gap-3">
        <button type="button" disabled={knownIds === null} onClick={() => { setError(null); setWaiting(!waiting); }} className={SETTINGS_PRIMARY_BUTTON_CLASS}>{waiting ? "停止等待" : "等待授权结果"}</button>
        <button type="button" onClick={onDone} className={SETTINGS_BUTTON_CLASS}>已完成，刷新接入</button>
      </div>
    </div>
  );
}
