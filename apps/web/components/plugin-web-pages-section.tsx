"use client";

import { useLocale, useTranslations } from "next-intl";

import type { Route } from "next";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";

import { StatusPill } from "@/components/cloud-push-ui";
import { useConfirm, useToast } from "@/components/feedback";
import { PluginAppIcon } from "@/components/plugin-app-icon";
import {
  SETTINGS_BUTTON_CLASS,
  SettingsList,
  SettingsMoreMenu,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import { listWebPages, revokeWebConsent, setWebConsent, type WebPage } from "@/lib/api/plugins";
import { appHref } from "@/lib/plugin-apps";
import { usePluginApps } from "@/lib/plugin-apps-context";

/** 批准页与这里共用的后果说明：网页以使用者的身份运行 */
export const WEB_PAGE_RISK = "settings.plugins.webRisk" as const;

/**
 * 设置 → 插件 → 插件网页（docs/design/plugin-web-pages.md §5）：带网页的插件包与本地插件。
 * 本地插件（常由 Agent 写出来）要在这里同意一次才托管、才进侧边栏；已同意的可以改
 * 「加到侧边栏」「成员也能看到」，或撤销。插件包的同意在批准安装时就给了，这里只管后续调整。
 */
export function PluginWebPagesSection({ reloadKey }: { reloadKey: number }) {
  const locale = useLocale();
  const t = useTranslations();
  const [pages, setPages] = useState<WebPage[]>([]);
  const [busy, setBusy] = useState(false);
  const confirm = useConfirm();
  const toast = useToast();
  const router = useRouter();
  const { refresh: refreshApps } = usePluginApps();

  const reload = useCallback(() => {
    void listWebPages().then(setPages);
  }, []);
  useEffect(() => {
    reload();
  }, [reload, reloadKey, locale]);

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    try {
      await action();
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : t("settings.plugins.actionFailed"));
    } finally {
      setBusy(false);
      reload();
      refreshApps();
    }
  };

  const approve = async (page: WebPage) => {
    const result = await confirm({
      title: t("settings.plugins.approveWeb", { name: page.name }),
      description: t(WEB_PAGE_RISK),
      bullets: [t("settings.plugins.webAddress", { address: appHref(page.id) }), t("settings.plugins.addWebHint")],
      confirmLabel: t("settings.plugins.approve"),
      checkbox: { label: t("settings.plugins.membersAlso"), description: t("settings.plugins.membersHint") },
    });
    if (!result.ok) return;
    await run(async () => {
      await setWebConsent(page.id, { nav: true, members: result.checked });
      toast.success(t("settings.plugins.addedWeb", { name: page.name }));
    });
  };

  const update = (page: WebPage, change: Partial<Pick<WebPage, "nav" | "members">>) =>
    run(async () => {
      await setWebConsent(page.id, { nav: page.nav, members: page.members, ...change });
    });

  const revoke = async (page: WebPage) => {
    const ok = await confirm({
      title: t("settings.plugins.revokeWeb", { name: page.name }),
      description: t("settings.plugins.revokeWebHint"),
      confirmLabel: t("settings.plugins.revoke"),
      tone: "danger",
    });
    if (!ok) return;
    await run(async () => {
      await revokeWebConsent(page.id);
      toast.success(t("settings.plugins.revoked"));
    });
  };

  if (pages.length === 0) return null;
  return (
    <SettingsSection
      title={t("settings.plugins.webPages")}
      description={t("settings.plugins.webPagesHint")}
    >
      <SettingsList>
        {pages.map((page) => (
          <SettingsRow
            key={page.id}
            leading={
              <PluginAppIcon
                src={page.approved ? page.entries[0]?.icon ?? null : null}
                monochrome={page.entries[0]?.monochrome ?? false}
                className="size-[18px] text-[var(--text-muted)]"
              />
            }
            label={page.name}
            description={[
              appHref(page.id),
              page.source === "local" ? t("settings.plugins.localPlugin") : t("settings.plugins.package"),
              page.approved ? (page.members ? t("settings.plugins.membersVisible") : t("settings.plugins.adminOnly")) : null,
              page.approved && !page.nav ? t("settings.plugins.notInSidebar") : null,
            ]
              .filter(Boolean)
              .join(" · ")}
          >
            {page.approved ? (
              <>
                <button
                  type="button"
                  className={SETTINGS_BUTTON_CLASS}
                  onClick={() => router.push(appHref(page.id) as Route)}
                >
                  {t("settings.plugins.open")}</button>
                <SettingsMoreMenu
                  label={t("settings.plugins.more", { name: page.name })}
                  disabled={busy}
                  items={[
                    {
                      label: page.nav ? t("settings.plugins.removeSidebar") : t("settings.plugins.addSidebar"),
                      onSelect: () => void update(page, { nav: !page.nav }),
                    },
                    {
                      label: page.members ? t("settings.plugins.makeAdminOnly") : t("settings.plugins.membersAlso"),
                      onSelect: () => void update(page, { members: !page.members }),
                    },
                    { label: t("settings.plugins.revokeConsent"), onSelect: () => void revoke(page), danger: true },
                  ]}
                />
              </>
            ) : (
              <>
                <StatusPill tone="warn" label={t("settings.plugins.pendingConsent")} />
                <button
                  type="button"
                  disabled={busy}
                  className={SETTINGS_BUTTON_CLASS}
                  onClick={() => void approve(page)}
                >
                  {t("settings.plugins.approve")}</button>
              </>
            )}
          </SettingsRow>
        ))}
      </SettingsList>
    </SettingsSection>
  );
}
