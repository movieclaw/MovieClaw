"use client";

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
export const WEB_PAGE_RISK =
  "网页会以正在使用它的人的身份运行：管理员打开时，它拥有管理员的全部权限。只同意你信任的插件。";

/**
 * 设置 → 插件 → 插件网页（docs/design/plugin-web-pages.md §5）：带网页的插件包与本地插件。
 * 本地插件（常由 Agent 写出来）要在这里同意一次才托管、才进侧边栏；已同意的可以改
 * 「加到侧边栏」「成员也能看到」，或撤销。插件包的同意在批准安装时就给了，这里只管后续调整。
 */
export function PluginWebPagesSection({ reloadKey }: { reloadKey: number }) {
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
  }, [reload, reloadKey]);

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    try {
      await action();
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "操作失败");
    } finally {
      setBusy(false);
      reload();
      refreshApps();
    }
  };

  const approve = async (page: WebPage) => {
    const result = await confirm({
      title: `同意「${page.name}」的网页运行？`,
      description: WEB_PAGE_RISK,
      bullets: [`地址 ${appHref(page.id)}`, "加到左侧栏，之后可以在「外观 → 导航顺序」里移出"],
      confirmLabel: "同意",
      checkbox: { label: "成员也能看到", description: "不勾则只有管理员能打开。" },
    });
    if (!result.ok) return;
    await run(async () => {
      await setWebConsent(page.id, { nav: true, members: result.checked });
      toast.success(`「${page.name}」已加到左侧栏`);
    });
  };

  const update = (page: WebPage, change: Partial<Pick<WebPage, "nav" | "members">>) =>
    run(async () => {
      await setWebConsent(page.id, { nav: page.nav, members: page.members, ...change });
    });

  const revoke = async (page: WebPage) => {
    const ok = await confirm({
      title: `撤销「${page.name}」的网页？`,
      description: "不再托管它的网页，并从侧边栏撤下；插件本身照常运行，之后可以再同意。",
      confirmLabel: "撤销",
      tone: "danger",
    });
    if (!ok) return;
    await run(async () => {
      await revokeWebConsent(page.id);
      toast.success("已撤销");
    });
  };

  if (pages.length === 0) return null;
  return (
    <SettingsSection
      title="插件网页"
      description="插件自带的页面，在主程序里以同源方式打开，可以直接调用接口"
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
              page.source === "local" ? "本地插件" : "插件包",
              page.approved ? (page.members ? "成员可见" : "仅管理员") : null,
              page.approved && !page.nav ? "不在侧边栏" : null,
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
                  打开
                </button>
                <SettingsMoreMenu
                  label={`「${page.name}」的更多操作`}
                  disabled={busy}
                  items={[
                    {
                      label: page.nav ? "从侧边栏撤下" : "加到侧边栏",
                      onSelect: () => void update(page, { nav: !page.nav }),
                    },
                    {
                      label: page.members ? "只给管理员看" : "成员也能看到",
                      onSelect: () => void update(page, { members: !page.members }),
                    },
                    { label: "撤销同意", onSelect: () => void revoke(page), danger: true },
                  ]}
                />
              </>
            ) : (
              <>
                <StatusPill tone="warn" label="待同意" />
                <button
                  type="button"
                  disabled={busy}
                  className={SETTINGS_BUTTON_CLASS}
                  onClick={() => void approve(page)}
                >
                  同意
                </button>
              </>
            )}
          </SettingsRow>
        ))}
      </SettingsList>
    </SettingsSection>
  );
}
