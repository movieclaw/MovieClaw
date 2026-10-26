"use client";

/**
 * 「AI 设定」里的网页搜索接入。
 *
 * 按设置页规范（docs/design/settings-ui.md）：小节里一行状态，行尾「接入」/「编辑」+「⋯」菜单
 * （重新测试连接、关闭网页搜索）；供应商和密钥在右侧抽屉里一起提交。
 * 提交即「验证并保存」：服务端先用这把 Key 搜索一次，通过才落库，失败不动已保存的配置。
 * 密钥不回显，只显示末四位；界面文案随当前语言渲染。
 */

import { useLocale, useTranslations } from "next-intl";
import type { AppLocale } from "@/lib/i18n/negotiate";

import { useEffect, useState } from "react";

import { ErrorBanner } from "@/components/cloud-push-ui";
import { useConfirm, useToast } from "@/components/feedback";
import { CheckIcon, GlobeIcon, OpenIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsDrawer,
  SettingsList,
  SettingsMoreMenu,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type WebSearchConfig,
  clearWebSearchConfig,
  getWebSearchConfig,
  saveWebSearchConfig,
  testWebSearchConfig,
} from "@/lib/api/web-search";

export function WebSearchSettings() {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const toast = useToast();
  const confirm = useConfirm();
  const [config, setConfig] = useState<WebSearchConfig | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false);

  function load() {
    setLoadError(null);
    getWebSearchConfig()
      .then(setConfig)
      .catch((e) => setLoadError((e as Error).message));
  }

  useEffect(load, []);

  const current =
    config?.providers.find((item) => item.id === config.provider) ?? null;

  async function retest() {
    setBusy(true);
    try {
      const result = await testWebSearchConfig(config?.provider ?? "", "");
      toast.success(result.message);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function clear() {
    const accepted = await confirm({
      title: t("settings.webSearch.ui.disableTitle"),
      description:
        t("settings.webSearch.ui.disableHint"),
      confirmLabel: t("settings.webSearch.ui.disableConfirm"),
      tone: "danger",
    });
    if (!accepted) return;
    setBusy(true);
    try {
      setConfig(await clearWebSearchConfig());
      toast.success(t("settings.webSearch.ui.disabled"));
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <SettingsSection
      title={t("settings.webSearch.ui.title")}
      description={t("settings.webSearch.ui.intro")}
    >
      {config == null && loadError ? (
        <div className="css-glass space-y-3 !rounded-xl p-5 max-sm:p-4">
          <ErrorBanner>{loadError}</ErrorBanner>
          <button
            type="button"
            onClick={load}
            className={SETTINGS_BUTTON_CLASS}
          >
            {t("common.retry")}</button>
        </div>
      ) : config == null ? (
        <div className="h-[72px] animate-pulse rounded-xl bg-white/[0.04]" />
      ) : (
        <SettingsList>
          {config.configured && current ? (
            <SettingsRow
              stackOnMobile={locale === "en"}
              leading={<RowIcon />}
              label={
                <span className="flex items-center gap-2">
                  {current.label}
                  <span className="flex items-center gap-1.5 rounded-full bg-[color-mix(in_oklab,var(--ok)_12%,transparent)] px-2 py-0.5 text-caption font-medium text-[var(--ok)]">
                    <span className="size-1.5 rounded-full bg-current" />
                    {t("settings.webSearch.ui.connected")}</span>
                </span>
              }
              description={
                config.key_hint ? t("settings.webSearch.ui.keyHint", {hint: config.key_hint}) : t("settings.webSearch.ui.savedKey")
              }
            >
              <button
                type="button"
                disabled={busy}
                onClick={() => setEditing(true)}
                className={SETTINGS_BUTTON_CLASS}
              >
                {t("settings.webSearch.ui.editButton")}</button>
              <SettingsMoreMenu
                label={t("settings.webSearch.ui.more")}
                disabled={busy}
                items={[
                  { label: t("settings.webSearch.ui.retest"), onSelect: () => void retest() },
                  {
                    label: t("settings.webSearch.ui.disable"),
                    onSelect: () => void clear(),
                    danger: true,
                  },
                ]}
              />
            </SettingsRow>
          ) : (
            <SettingsRow
              leading={<RowIcon />}
              label={t("settings.webSearch.ui.notConnected")}
              description={t("settings.webSearch.ui.supported")}
            >
              <button
                type="button"
                onClick={() => setEditing(true)}
                className={SETTINGS_BUTTON_CLASS}
              >
                {t("settings.webSearch.ui.connect")}</button>
            </SettingsRow>
          )}
        </SettingsList>
      )}
      {editing && config && (
        <WebSearchDrawer
          config={config}
          onClose={() => setEditing(false)}
          onSaved={(next) => {
            setConfig(next);
            setEditing(false);
            const label = next.providers.find(
              (item) => item.id === next.provider,
            )?.label;
            toast.success(label ? t("settings.webSearch.ui.connectedProvider", {provider: label}) : t("settings.webSearch.ui.saved"));
          }}
        />
      )}
    </SettingsSection>
  );
}

function RowIcon() {
  return (
    <span className="icon-chip size-9 shrink-0 !rounded-xl">
      <GlobeIcon className="size-[18px]" />
    </span>
  );
}

/** 选搜索服务 + 填 Key，一次「验证并保存」。 */
function WebSearchDrawer({
  config,
  onClose,
  onSaved,
}: {
  config: WebSearchConfig;
  onClose: () => void;
  onSaved: (next: WebSearchConfig) => void;
}) {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const [provider, setProvider] = useState(
    config.provider ?? config.providers[0]?.id ?? "",
  );
  const [apiKey, setApiKey] = useState("");
  const [showKey, setShowKey] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const selected =
    config.providers.find((item) => item.id === provider) ?? null;
  const keepsSaved = config.configured && provider === config.provider;
  // 不论换不换服务都要一把 Key：同一家不填新 Key 等于什么都没改
  const canSubmit = !!provider && apiKey.trim() !== "";

  async function submit() {
    if (!canSubmit) return;
    setBusy(true);
    setError(null);
    try {
      onSaved(await saveWebSearchConfig(provider, apiKey));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <SettingsDrawer
      open
      onClose={() => {
        if (!busy) onClose();
      }}
      title={config.configured ? t("settings.webSearch.ui.edit") : t("settings.webSearch.ui.add")}
      description={t("settings.webSearch.ui.drawerHint")}
      hint={locale === "en" ? <span className="max-md:hidden">{t("settings.webSearch.ui.verifyHint")}</span> : t("settings.webSearch.ui.verifyHint")}
      actions={
        <>
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className={SETTINGS_BUTTON_CLASS}
          >
            {t("common.cancel")}</button>
          <button
            type="button"
            onClick={() => void submit()}
            disabled={busy || !canSubmit}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? t("settings.webSearch.ui.verifying") : t("settings.webSearch.ui.verifySave")}
          </button>
        </>
      }
    >
      <form
        className="space-y-6"
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        {error && <ErrorBanner>{error}</ErrorBanner>}
        {locale === "en" && <p className="text-caption leading-5 text-[var(--text-faint)] md:hidden">{t("settings.webSearch.ui.verifyHint")}</p>}

        <fieldset>
          <legend className="mb-2 text-sub font-medium text-[var(--text-muted)]">
            {t("settings.webSearch.ui.provider")}</legend>
          <div
            role="radiogroup"
            aria-label={t("settings.webSearch.ui.provider")}
            className="css-glass divide-y divide-[var(--line)] !rounded-xl"
          >
            {config.providers.map((item) => {
              const active = item.id === provider;
              return (
                <button
                  key={item.id}
                  type="button"
                  role="radio"
                  aria-checked={active}
                  disabled={busy}
                  onClick={() => {
                    setProvider(item.id);
                    setError(null);
                  }}
                  className="flex w-full items-center gap-3 px-4 py-3 text-left transition-colors first:rounded-t-xl last:rounded-b-xl hover:bg-white/[0.03] disabled:opacity-60"
                >
                  <span className="min-w-0 flex-1">
                    <span className="block text-body font-medium text-[var(--text)]">
                      {item.label}
                    </span>
                    <span className="mt-0.5 block text-caption leading-5 text-[var(--text-faint)]">
                      {item.note}
                    </span>
                  </span>
                  <CheckIcon
                    className={`size-4 shrink-0 text-[var(--accent)] ${active ? "" : "invisible"}`}
                  />
                </button>
              );
            })}
          </div>
        </fieldset>

        <div>
          <label
            htmlFor="web-search-key"
            className="mb-2 block text-sub font-medium text-[var(--text-muted)]"
          >
            API Key
          </label>
          <div className="relative">
            <input
              id="web-search-key"
              type={showKey ? "text" : "password"}
              autoComplete="off"
              spellCheck={false}
              value={apiKey}
              disabled={busy}
              placeholder={
                keepsSaved && config.key_hint
                  ? t("settings.webSearch.ui.replaceKey", {hint: config.key_hint})
                  : t("settings.webSearch.ui.keyPlaceholder")
              }
              onChange={(e) => {
                setApiKey(e.target.value);
                setError(null);
              }}
              className={`${SETTINGS_INPUT_CLASS} w-full py-2 pr-16 font-mono`}
            />
            <button
              type="button"
              onClick={() => setShowKey((v) => !v)}
              aria-label={showKey ? t("settings.webSearch.ui.hideKey") : t("settings.webSearch.ui.showKey")}
              className="absolute inset-y-0 right-1 my-auto h-7 rounded-md px-2.5 text-sub font-medium text-[var(--text-muted)] hover:bg-white/[0.06] hover:text-[var(--text)]"
            >
              {showKey ? t("settings.webSearch.ui.hide") : t("settings.webSearch.ui.show")}
            </button>
          </div>
          <div className="mt-2 flex flex-wrap items-center justify-between gap-x-4 gap-y-1 text-caption leading-5 text-[var(--text-faint)]">
            <span>
              {config.configured && !keepsSaved
                ? t("settings.webSearch.ui.changedProvider")
                : t("settings.webSearch.ui.keyPrivacy")}
            </span>
            {selected && (
              <a
                href={selected.signup_url}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-1 text-[var(--accent)] hover:underline"
              >
                {t("settings.webSearch.ui.signup", {provider: selected.label})}
                <OpenIcon className="size-3.5" />
              </a>
            )}
          </div>
        </div>
      </form>
    </SettingsDrawer>
  );
}
