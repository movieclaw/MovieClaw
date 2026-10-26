"use client";

/**
 * 「AI 设定」设置分区：什么场景用哪个模型。
 *
 * 与「模型接入」分开：接入回答「怎么连上」（实例、Key、端点），这里回答
 * 「智能体 / 字幕处理默认用哪个模型」。选项是所有已接入实例的模型清单
 * （GET /llm/models，同 id 跨实例冲突的项已带「（实例名）」标注）。
 * 服务端保证只要接入了供应商，两个默认就已有值（首次接入自动设为其目录
 * 第一个模型），所以这里显示的永远是真实存的值；一个都没接入时给空态引导。
 * 同页还有「网页搜索」：接入了搜索服务才给智能体网页搜索工具。
 */

import { useLocale, useTranslations } from "next-intl";
import type { AppLocale } from "@/lib/i18n/negotiate";
import type { AppMessageKey } from "@/lib/i18n/translate";

import { useEffect, useState } from "react";

import Link from "next/link";

import { ErrorBanner } from "@/components/cloud-push-ui";
import { useToast } from "@/components/feedback";
import { SparkIcon } from "@/components/icons";
import {
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsEmpty,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import { WebSearchSettings } from "@/components/web-search-settings";
import {
  type LlmDefaults,
  type LlmModelOption,
  getLlmDefaults,
  listLlmModels,
  updateLlmDefaults,
} from "@/lib/api/llm";
import { invalidateModelOptionsCache } from "@/lib/llm-thinking";

/** 一个用途一行：字段名 + 文案 */
const PURPOSES: {
  key: "agent_model" | "subtitle_model";
  effectiveKey: "effective_agent_model" | "effective_subtitle_model";
  label: AppMessageKey;
  desc: AppMessageKey;
}[] = [
  {
    key: "agent_model",
    effectiveKey: "effective_agent_model",
    label: "settings.ai.ui.agentLabel",
    desc: "settings.ai.ui.agentHint",
  },
  {
    key: "subtitle_model",
    effectiveKey: "effective_subtitle_model",
    label: "settings.ai.ui.subtitleLabel",
    desc: "settings.ai.ui.subtitleHint",
  },
];

export function AiSettingsSection() {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const toast = useToast();
  const [defaults, setDefaults] = useState<LlmDefaults | null>(null);
  const [options, setOptions] = useState<LlmModelOption[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([getLlmDefaults(), listLlmModels()])
      .then(([d, o]) => {
        setDefaults(d);
        setOptions(o);
      })
      .catch((e) => setError((e as Error).message));
  }, []);

  async function save(key: "agent_model" | "subtitle_model", value: string | null) {
    if (defaults == null) return;
    const previous = defaults;
    setDefaults({ ...defaults, [key]: value }); // 乐观更新，失败回滚
    setSaving(key);
    setError(null);
    try {
      // 另一项若已失效（不在清单里）不能原样回传——服务端会整体拒绝；传 null 让它按推荐补齐
      const sibling = (ref: string | null) =>
        ref != null && options.some((o) => o.ref === ref) ? ref : null;
      const next = await updateLlmDefaults({
        agent_model: key === "agent_model" ? value : sibling(defaults.agent_model),
        subtitle_model: key === "subtitle_model" ? value : sibling(defaults.subtitle_model),
      });
      setDefaults(next);
      // 对话框的模型清单里 is_default 跟随智能体默认模型，作废缓存
      invalidateModelOptionsCache();
      toast.success(t("settings.ai.ui.saved"));
    } catch (e) {
      setDefaults(previous);
      setError((e as Error).message);
    } finally {
      setSaving(null);
    }
  }

  const labelOf = (ref: string | null) => options.find((o) => o.ref === ref)?.label ?? ref;
  // 已加载且一个供应商都没接入：清单为空即空态（与门禁同口径，不另发请求）
  const noProviders = defaults != null && options.length === 0;

  return (
    <div className="space-y-10">
      {!noProviders && (
        <p className="px-1 text-sub leading-6 text-[var(--text-muted)]">
          {t.rich("settings.ai.ui.intro", {providers: chunks => <Link href="/settings/llm" className="mx-0.5 text-[var(--accent)] hover:underline">{chunks}</Link>})}
        </p>
      )}

      {error && <ErrorBanner>{error}</ErrorBanner>}

      {defaults == null ? (
        <div className="h-[104px] animate-pulse rounded-xl bg-white/[0.04]" />
      ) : noProviders ? (
        /* 空态：没有供应商就没有模型可选，引导先去接入 */
        <SettingsEmpty
          icon={<SparkIcon className="size-5" />}
          title={t("settings.ai.ui.empty")}
          description={t("settings.ai.ui.emptyHint")}
          action={
            <Link href="/settings/llm" className={SETTINGS_PRIMARY_BUTTON_CLASS + " inline-flex items-center"}>
              {t("settings.ai.ui.connect")}</Link>
          }
        />
      ) : (
        <SettingsSection title={t("settings.ai.ui.defaults")}>
          <SettingsList>
            {PURPOSES.map((purpose) => {
              const value = defaults[purpose.key];
              const effective = defaults[purpose.effectiveKey];
              // 正常情况下设定一定有值且在清单里（服务端维护）；只有预设目录变动
              // 这类漂移才会失效，此时提示并展示实际生效的兜底值
              const stale = value == null || !options.some((o) => o.ref === value);
              return (
                <SettingsRow
                  stackOnMobile={locale === "en"}
                  key={purpose.key}
                  label={t(purpose.label)}
                  description={
                    <>
                      {t(purpose.desc)}
                      {stale && (
                        <span className="mt-1 block text-[var(--warn)]">
                          {t("settings.ai.ui.stale", {previous: value ?? t("settings.ai.ui.emptyValue"), effective: labelOf(effective) ?? t("settings.ai.ui.none")})}
                        </span>
                      )}
                    </>
                  }
                >
                  <select
                    aria-label={t(purpose.label)}
                    value={stale ? "" : value}
                    disabled={saving != null}
                    onChange={(e) => void save(purpose.key, e.target.value || null)}
                    className={`${SETTINGS_INPUT_CLASS} w-72 max-sm:w-44 ${locale === "en" ? "max-sm:!w-full max-sm:min-w-0" : ""}`}
                  >
                    {stale && (
                      <option value="" disabled>
                        {t("settings.ai.ui.chooseAgain")}</option>
                    )}
                    {options.map((o) => (
                      <option key={o.ref} value={o.ref}>
                        {o.label}
                        {o.thinking_levels.length > 0 ? t("settings.ai.ui.thinkingSuffix") : ""}
                      </option>
                    ))}
                  </select>
                </SettingsRow>
              );
            })}
          </SettingsList>
        </SettingsSection>
      )}

      <WebSearchSettings />
    </div>
  );
}
