"use client";

/**
 * 「AI 设定」里的搜索能力接入。
 *
 * 选一家供应商、粘贴 Key、测试连接，通过之后才能保存。没通过的密钥不会写入服务器。
 * 设置页目前没有语言包（界面文案是中文），这里与同一页的其他分区保持一致。
 * 密钥不回显：输入框留空表示不修改已保存的 Key。
 */

import { useEffect, useState } from "react";

import { ErrorBanner } from "@/components/cloud-push-ui";
import { useConfirm, useToast } from "@/components/feedback";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type WebSearchConfig,
  type WebSearchProviderOption,
  clearWebSearchConfig,
  getWebSearchConfig,
  saveWebSearchConfig,
  testWebSearchConfig,
} from "@/lib/api/web-search";

export function WebSearchSettings() {
  const toast = useToast();
  const confirm = useConfirm();
  const [config, setConfig] = useState<WebSearchConfig | null>(null);
  const [provider, setProvider] = useState("");
  const [apiKey, setApiKey] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [verifiedToken, setVerifiedToken] = useState<string | null>(null);
  const [busy, setBusy] = useState<"save" | "test" | "clear" | null>(null);

  useEffect(() => {
    getWebSearchConfig()
      .then((next) => {
        setConfig(next);
        setProvider(next.provider ?? "");
      })
      .catch((e) => setError((e as Error).message));
  }, []);

  const selected = config?.providers.find((item) => item.id === provider) ?? null;
  const switching = config?.configured === true && provider !== (config.provider ?? "");
  const token = formToken(provider, apiKey, config);
  const canSave = token != null && token === verifiedToken;

  async function save() {
    if (!provider) {
      setError("请先选择搜索供应商");
      return;
    }
    if (!apiKey.trim() && (switching || !config?.configured)) {
      setError("请粘贴 API Key");
      return;
    }
    setBusy("save");
    setError(null);
    setNotice(null);
    try {
      const next = await saveWebSearchConfig(provider, apiKey);
      setConfig(next);
      setProvider(next.provider ?? "");
      setApiKey("");
      setVerifiedToken(null);
      toast.success("网页搜索已验证并保存");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function test() {
    if (!provider) {
      setError("请先选择搜索供应商");
      return;
    }
    if (!apiKey.trim() && (switching || !config?.configured)) {
      setError("请先粘贴 API Key");
      return;
    }
    setBusy("test");
    setError(null);
    setNotice(null);
    try {
      const tested = formToken(provider, apiKey, config);
      const result = await testWebSearchConfig(provider, apiKey);
      setNotice(result.message);
      setVerifiedToken(tested);
    } catch (e) {
      setVerifiedToken(null);
      setError((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function clear() {
    const accepted = await confirm({
      title: "关闭网页搜索？",
      description: "已保存的 API Key 会从这台服务器删除。智能体将不再上网搜索，直到你重新接入。",
      confirmLabel: "清除",
      tone: "danger",
    });
    if (!accepted) return;
    setBusy("clear");
    setError(null);
    setNotice(null);
    try {
      const next = await clearWebSearchConfig();
      setConfig(next);
      setProvider("");
      setApiKey("");
      setVerifiedToken(null);
      toast.success("已关闭网页搜索");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  return (
    <SettingsSection
      title="搜索能力接入"
      description="选一家搜索服务并填入 API Key。先测试连接，通过后才能保存；没通过的密钥不会写入服务器。不配置就不会提供这个工具，对话和现在一样。"
    >
      {config == null ? (
        <div className="h-[104px] animate-pulse rounded-xl bg-white/[0.04]" />
      ) : (
        <div className="css-glass space-y-4 !rounded-xl p-5 max-sm:p-4">
          {error && <ErrorBanner>{error}</ErrorBanner>}
          <label className="block">
            <span className="mb-1.5 block text-ui font-medium text-[var(--text)]">供应商</span>
            <select
              aria-label="搜索供应商"
              value={provider}
              disabled={busy != null}
              onChange={(e) => {
                setProvider(e.target.value);
                setNotice(null);
                setError(null);
              }}
              className={`${SETTINGS_INPUT_CLASS} w-full`}
            >
              <option value="">请选择…</option>
              {config.providers.map((item) => (
                <option key={item.id} value={item.id}>
                  {item.label}
                </option>
              ))}
            </select>
          </label>
          {selected && <ProviderNote option={selected} />}
          <label className="block">
            <span className="mb-1.5 block text-ui font-medium text-[var(--text)]">API Key</span>
            <input
              aria-label="搜索 API Key"
              type="password"
              autoComplete="off"
              spellCheck={false}
              value={apiKey}
              disabled={busy != null}
              placeholder={placeholderFor(config, switching)}
              onChange={(e) => {
                setApiKey(e.target.value);
                setNotice(null);
                setError(null);
              }}
              className={`${SETTINGS_INPUT_CLASS} w-full font-mono`}
            />
          </label>
          <p className="text-caption leading-5 text-[var(--text-faint)]">
            {statusLine(config, selected)}
            {token != null && !canSave ? " 请先测试连接，通过后才能保存。" : ""}
          </p>
          {notice && <p className="text-sub leading-5 text-[var(--ok)]">{notice}</p>}
          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              disabled={busy != null}
              onClick={() => void test()}
              className={SETTINGS_BUTTON_CLASS}
            >
              {busy === "test" ? "测试中…" : "测试连接"}
            </button>
            <button
              type="button"
              disabled={busy != null || !canSave}
              onClick={() => void save()}
              className={SETTINGS_PRIMARY_BUTTON_CLASS}
            >
              {busy === "save" ? "保存中…" : "保存"}
            </button>
            {config.configured && (
              <button
                type="button"
                disabled={busy != null}
                onClick={() => void clear()}
                className="h-8 px-2 text-sub text-[var(--text-faint)] hover:text-[var(--danger)] disabled:opacity-40"
              >
                {busy === "clear" ? "清除中…" : "清除"}
              </button>
            )}
          </div>
        </div>
      )}
    </SettingsSection>
  );
}

function ProviderNote({ option }: { option: WebSearchProviderOption }) {
  return (
    <p className="text-caption leading-5 text-[var(--text-muted)]">
      {option.note}
      <span className="mx-1.5">·</span>
      <a
        href={option.signup_url}
        target="_blank"
        rel="noreferrer"
        className="text-[var(--accent)] hover:underline"
      >
        申请 {option.label} API Key
      </a>
    </p>
  );
}

/** 一次成功的测试只对这一组供应商和密钥有效。空密钥且供应商未变时，测的是已保存的那把。 */
function formToken(provider: string, apiKey: string, config: WebSearchConfig | null): string | null {
  if (!provider) return null;
  const trimmed = apiKey.trim();
  if (trimmed) return `${provider}\n${trimmed}`;
  if (config?.configured && provider === (config.provider ?? "")) return `${provider}\nsaved`;
  return null;
}

function placeholderFor(config: WebSearchConfig, switching: boolean): string {
  if (switching) return "更换供应商时请粘贴新的 API Key";
  if (config.configured && config.key_hint) return `已保存，留空表示不修改（末四位 ${config.key_hint}）`;
  if (config.configured) return "已保存，留空表示不修改";
  return "粘贴 API Key";
}

function statusLine(config: WebSearchConfig, selected: WebSearchProviderOption | null): string {
  if (!config.configured || !selected || selected.id !== config.provider) {
    return "密钥只存在这台服务器上，保存之后界面和接口都不再显示完整密钥。";
  }
  if (config.key_hint) {
    return `已接入 ${selected.label}，密钥末四位 ${config.key_hint}。`;
  }
  return `已接入 ${selected.label}。`;
}
