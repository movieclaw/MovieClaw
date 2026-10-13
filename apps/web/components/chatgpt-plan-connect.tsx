"use client";

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
  return (
    <div className="space-y-5" data-testid="chatgpt-plan-connect">
      <label className="block space-y-2">
        <span>供应商</span>
        <select value="chatgpt" onChange={(event) => onSelect(event.target.value as LlmProviderType)} className={`${SETTINGS_INPUT_CLASS} w-full`}>
          {presets.map((preset) => <option key={preset.id} value={preset.id}>{preset.display_name}</option>)}
        </select>
      </label>
      <div className="space-y-3 text-sub leading-relaxed text-[var(--text-muted)]">
        <p>使用 ChatGPT Plus / Pro 订阅，无需 API Key。额度与其他使用该订阅的 App 共享。</p>
        {config?.chatgpt_account && <p>已连接：{config.chatgpt_account}</p>}
        <p>在运行浏览器的电脑上先用 mclaw login 配对这台服务器，再执行：</p>
        <code className="block break-all rounded-lg bg-white/[0.05] p-3">{command}</code>
        <button type="button" className={SETTINGS_BUTTON_CLASS} onClick={() => void navigator.clipboard.writeText(command)}>复制连接命令</button>
        <p>在官方页面选择 Continue with ChatGPT，并允许使用订阅。授权会自动传回服务器并加密保存，然后回到这里刷新。</p>
        <a href="https://chatgpt.com/settings/usage" target="_blank" rel="noreferrer" className="underline">管理 ChatGPT 用量</a>
      </div>
      <button type="button" onClick={onDone} className={SETTINGS_PRIMARY_BUTTON_CLASS}>已完成，刷新接入</button>
    </div>
  );
}
