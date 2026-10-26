"use client";

import { useLocale, useTranslations } from "next-intl";
import { appTranslator } from "@/lib/i18n/translate";
import { requestLocale, type AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";

import { useCallback, useEffect, useState } from "react";

import { StatusPill } from "@/components/cloud-push-ui";
import { XIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  addServerAddress,
  getServerAddresses,
  removeServerAddress,
  type ServerAddressItem,
  type ServerAddressKind,
} from "@/lib/api/app";
import { guessKind } from "@/lib/server-addresses";
import { formatRelativeTime } from "@/lib/time";

/**
 * 访问地址（设置 → 网络，docs/design/server-addresses.md）。
 *
 * 各端 App 拿这份地址簿，在家自动走内网、出门自动走外网，用户不用选。地址主要靠自动收集
 * （管理员登录后用过就记下；成员的请求不算，因为地址会发给全家的 App 去连），这里只做两件事：看看收集到了什么、补上自动收集不到的（典型是家里
 * DNS 把域名解析到内网——只看名字判断不出它是内网地址，要手动标一下）。外部访问地址也会列在
 * 这里，但改它在下面的「外部访问」里。
 */

function sourceText(item: ServerAddressItem, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const seen = item.last_seen ? t("settings.network.addresses.seen", { when: formatRelativeTime(item.last_seen, locale) }) : null;
  switch (item.source) {
    case "manual":
      return [t("settings.network.addresses.manualSource"), seen].filter(Boolean).join(" · ");
    case "configured":
      return [t("settings.network.addresses.configuredSource"), seen].filter(Boolean).join(" · ");
    default:
      return seen ? t("settings.network.addresses.autoSeen", { seen }) : t("settings.network.addresses.automatic");
  }
}

function KindPill({ kind }: { kind: ServerAddressKind }) {
  const t = useTranslations();

  return kind === "lan" ? (
    <StatusPill tone="ok" label={t("settings.network.addresses.lan")} />
  ) : (
    <StatusPill tone="info" label={t("settings.network.addresses.wan")} />
  );
}

export function ServerAddressesSection() {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;

  const [items, setItems] = useState<ServerAddressItem[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState("");
  const [kind, setKind] = useState<ServerAddressKind>("wan");
  const [kindTouched, setKindTouched] = useState(false);
  const [error, setError] = useMessageState();
  const [busy, setBusy] = useState(false);
  const [removeError, setRemoveError] = useState<string | null>(null);

  const reload = useCallback(() => {
    setFailed(false);
    getServerAddresses()
      .then((view) => setItems(view.addresses))
      .catch(() => setFailed(true));
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  const closeForm = () => {
    setAdding(false);
    setDraft("");
    setKind("wan");
    setKindTouched(false);
    setError(null);
  };

  const onDraft = (value: string) => {
    setDraft(value);
    setError(null);
    const guessed = guessKind(value);
    if (guessed && !kindTouched) setKind(guessed);
  };

  const save = async () => {
    const url = draft.trim();
    if (!/^https?:\/\/[^\s/]+/.test(url)) {
      setError({ key: "settings.network.addresses.invalid" });
      return;
    }
    setBusy(true);
    try {
      const view = await addServerAddress(url, kind);
      setItems(view.addresses);
      closeForm();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const remove = async (url: string) => {
    setRemoveError(null);
    try {
      setItems((await removeServerAddress(url)).addresses);
    } catch (e) {
      setRemoveError((e as Error).message);
    }
  };

  const guessed = guessKind(draft);
  const hint =
    guessed === "lan"
      ? t("settings.network.addresses.looksLan")
      : guessed === "wan"
        ? t("settings.network.addresses.looksWan")
        : null;

  return (
    <SettingsSection
      title={t("settings.network.addresses.title")}
      description={t("settings.network.addresses.hint")}
      action={
        !adding && items !== null ? (
          <button type="button" className={SETTINGS_BUTTON_CLASS} onClick={() => setAdding(true)}>
            {t("settings.network.addresses.add")}
          </button>
        ) : null
      }
      footnote={removeError ?? undefined}
    >
      <SettingsList>
        {failed && (
          <SettingsRow stackOnMobile={locale === "en"} label={t("settings.network.addresses.failed")} description={t("settings.network.addresses.failedHint")}>
            <button type="button" className={SETTINGS_BUTTON_CLASS} onClick={reload}>
              {t("settings.network.ui.retry")}
            </button>
          </SettingsRow>
        )}
        {items?.length === 0 && !adding && (
          <SettingsRow stackOnMobile={locale === "en"}
            label={t("settings.network.addresses.empty")}
            description={t("settings.network.addresses.emptyHint")}
          />
        )}
        {items?.map((item) => (
          <SettingsRow stackOnMobile={locale === "en"}
            key={item.url}
            leading={<KindPill kind={item.kind} />}
            label={<span className="break-all font-mono text-sub">{item.url}</span>}
            description={sourceText(item, locale)}
          >
            {item.source !== "configured" && (
              <button
                type="button"
                aria-label={t("settings.network.addresses.deleteAria", { url: item.url })}
                title={t("settings.network.addresses.delete")}
                onClick={() => void remove(item.url)}
                className="grid size-8 place-items-center rounded-full text-[var(--text-faint)] transition-colors hover:bg-white/[0.06] hover:text-[var(--text)]"
              >
                <XIcon className="size-4" />
              </button>
            )}
          </SettingsRow>
        ))}
        {adding && (
          <div className="space-y-3 px-4 py-3">
            <input
              autoFocus
              value={draft}
              onChange={(e) => onDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void save();
                if (e.key === "Escape") closeForm();
              }}
              placeholder="https://nas.home.example.com"
              aria-label={t("settings.network.addresses.address")}
              className={`${SETTINGS_INPUT_CLASS} w-full font-mono`}
            />
            {error && <p className="text-sub text-[var(--danger)]">{error}</p>}
            <div className="flex flex-wrap items-center gap-2">
              <div role="radiogroup" aria-label={t("settings.network.addresses.kind")} className="flex gap-2">
                {(["lan", "wan"] as const).map((value) => (
                  <button
                    key={value}
                    type="button"
                    role="radio"
                    aria-checked={kind === value}
                    onClick={() => {
                      setKind(value);
                      setKindTouched(true);
                    }}
                    className={`${SETTINGS_BUTTON_CLASS} ${kind === value ? "!border-[var(--accent)] !text-[var(--text)]" : "!text-[var(--text-muted)]"}`}
                  >
                    {value === "lan" ? t("settings.network.addresses.lanChoice") : t("settings.network.addresses.wanChoice")}
                  </button>
                ))}
              </div>
              {hint && <span className="text-caption text-[var(--text-faint)]">{hint}</span>}
            </div>
            <div className="flex justify-end gap-2">
              <button type="button" className={SETTINGS_BUTTON_CLASS} onClick={closeForm}>
                {t("settings.network.ui.cancel")}
              </button>
              <button
                type="button"
                className={SETTINGS_PRIMARY_BUTTON_CLASS}
                disabled={busy}
                onClick={() => void save()}
              >
                {t("settings.network.ui.save")}
              </button>
            </div>
          </div>
        )}
      </SettingsList>
    </SettingsSection>
  );
}
