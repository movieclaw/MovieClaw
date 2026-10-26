"use client";

import { useLocale, useTranslations } from "next-intl";

/**
 * 「IM 推送」设置分区（原名「消息推送」，与「App 推送」并列后改名以示区分）。
 *
 * 这里只回答「我接了哪些账号」：一张跨平台的统一列表 +「新增通道」菜单，绑定流程收进
 * 弹窗（见 channel-bind-dialog）；通道来自通道插件，按接口渲染。另有一键测试推送。
 *
 * 「推什么」不在这里：IM 只是通知的一个渠道，和手机 App 一样按「账号 → 通知」的开关推
 * （docs/design/cloud-push.md §5）。原先的「推送内容」标签已并入那里。
 *
 * 旧版把微信 / Telegram / Discord 三块绑定表单和推送开关平铺在一页里：
 * 只接了一个通道也要滚过另外两块空态与说明，推送开关被夹在中间；进页面
 * 还会自动弹微信二维码。改版后列表只呈现"已接入"的事实，一次性流程只在
 * 用户主动新增时才出现。
 */

import { useCallback, useEffect, useRef, useState } from "react";

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";

import type { Route } from "next";
import Link from "next/link";

import { ChannelBindDialog } from "@/components/channel-bind-dialog";
import { ErrorBanner, LINK_CLASS, StatusPill } from "@/components/cloud-push-ui";
import { useConfirm, useToast } from "@/components/feedback";
import { ChatIcon, PlusIcon } from "@/components/icons";
import { LlmSetupNotice, useLlmConfigured } from "@/components/llm-gate";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsEmpty,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type ChannelAccount,
  type ChannelInfo,
  listChannels,
  sendChannelPushTest,
  unbindChannelAccount,
} from "@/lib/api/channels";
import { formatList } from "@/lib/i18n/format";
import { formatRelativeTime } from "@/lib/time";

/**
 * 通道来自通道插件（docs/design/plugin-channels.md）：列表与「新增通道」菜单都按接口返回的
 * 通道渲染，不认识具体平台。提供某个通道的插件关掉 / 卸载了，它的账号照常列出、标「未启用」，
 * 重新启用后自动恢复。
 */
export function ImPushSection() {
  const t = useTranslations();
  const locale = useLocale();
  const llmConfigured = useLlmConfigured();
  const confirm = useConfirm();
  const toast = useToast();
  const [channels, setChannels] = useState<ChannelInfo[]>([]);
  const [rows, setRows] = useState<ChannelAccount[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [pushBusy, setPushBusy] = useState(false);
  // 正在绑定的通道（null = 没开弹窗）
  const [binding, setBinding] = useState<ChannelInfo | null>(null);
  const loadEpoch = useRef(0);

  const load = useCallback(async () => {
    const epoch = ++loadEpoch.current;
    setError(null);
    try {
      const data = await listChannels({ headers: { "Accept-Language": locale } });
      if (epoch !== loadEpoch.current) return;
      setChannels(data.channels);
      setRows(data.accounts);
    } catch (e) {
      if (epoch !== loadEpoch.current) return;
      setError((e as Error).message);
      setRows([]);
    }
  }, [locale]);

  useEffect(() => {
    void load();
    return () => { loadEpoch.current += 1; };
  }, [load]);

  const byId = new Map(channels.map((c) => [c.id, c]));
  // 能对话的通道完全由模型驱动：没接模型时菜单里只留只推送的通道
  const addable = channels.filter((c) => llmConfigured !== false || !c.receive);

  async function handleUnbind(row: ChannelAccount) {
    const title = byId.get(row.channel_id)?.title ?? row.channel_id;
    if (
      !(await confirm({
        title: t("settings.imChannels.unbindTitle", { channel: title }),
        description: t("settings.imChannels.unbindDescription"),
        confirmLabel: t("settings.imChannels.unbind"),
        tone: "danger",
      }))
    )
      return;
    setBusy(true);
    setError(null);
    try {
      await unbindChannelAccount(row.channel_id, row.account_id);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function handleTestPush() {
    setPushBusy(true);
    try {
      const { sent } = await sendChannelPushTest();
      toast.success(t("settings.imChannels.testSent", { count: sent }));
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setPushBusy(false);
    }
  }

  const loading = rows == null;
  const titles = formatList(channels.map((c) => c.title), locale);

  return (
    <div className="space-y-10">
      <div className="space-y-4">
        <p className="text-sub leading-6 text-[var(--text-muted)]">
          {t("settings.imChannels.introBefore")}{locale === "en" && " "}
          <Link href={"/settings/notifications" as Route} className={`mx-1 ${LINK_CLASS}`}>
            {t("settings.imChannels.notificationsLink")}
          </Link>
          {t("settings.imChannels.introChat")}{locale === "en" && " "}
          <span className="mx-1 rounded bg-white/[0.08] px-1.5 py-0.5 text-caption">/reset</span>
          {locale === "en" && " "}{t("settings.imChannels.resetHelp")}{locale === "en" && " "}
          <span className="mx-1 rounded bg-white/[0.08] px-1.5 py-0.5 text-caption">/stop</span>
          {locale === "en" && " "}{t("settings.imChannels.stopHelp")}{locale === "en" && " "}
          <Link href={"/settings/plugins" as Route} className={`mx-1 ${LINK_CLASS}`}>
            {t("settings.imChannels.pluginsLink")}
          </Link>
          {t("settings.imChannels.introAfter")}
        </p>

        {/* 前置门禁：对话完全由模型驱动，未接入模型时引导（只推送的通道不受影响） */}
        {llmConfigured === false && <LlmSetupNotice feature={t("settings.imChannels.llmFeature")} />}

        {error && <ErrorBanner>{error}</ErrorBanner>}
      </div>

      <SettingsSection
        title={t("settings.imChannels.section")}
        description={
          loading ? t("settings.imChannels.loading") : rows.length > 0 ? t("settings.imChannels.accountCount", { count: rows.length }) : undefined
        }
        action={
          addable.length > 0 && (
            <AddChannelMenu channels={addable} onPick={setBinding} disabled={loading} />
          )
        }
      >
        {loading ? (
          <div className="space-y-2.5">
            <div className="h-[72px] animate-pulse rounded-xl bg-white/[0.04]" />
            <div className="h-[72px] animate-pulse rounded-xl bg-white/[0.04]" />
          </div>
        ) : rows.length === 0 ? (
          <SettingsEmpty
            icon={<ChatIcon className="size-5" />}
            title={t("settings.imChannels.empty")}
            description={
              channels.length === 0
                ? t("settings.imChannels.unavailable")
                : t("settings.imChannels.supported", { channels: titles })
            }
          />
        ) : (
          <SettingsList>
            {rows.map((row) => (
              <ChannelAccountRowView
                key={`${row.channel_id}:${row.account_id}`}
                row={row}
                channel={byId.get(row.channel_id)}
                busy={busy}
                onUnbind={() => void handleUnbind(row)}
              />
            ))}
          </SettingsList>
        )}
      </SettingsSection>

      {/* 测试推送：验证已接入通道确实能收到消息 */}
      {rows != null && rows.length > 0 && (
        <SettingsSection title={t("settings.imChannels.testSection")}>
          <SettingsList>
            <SettingsRow label={t("settings.imChannels.testLabel")} description={t("settings.imChannels.testDescription")}>
              <button
                type="button"
                disabled={pushBusy}
                onClick={() => void handleTestPush()}
                className={SETTINGS_BUTTON_CLASS}
              >
                {pushBusy ? t("settings.imChannels.sending") : t("settings.imChannels.send")}
              </button>
            </SettingsRow>
          </SettingsList>
        </SettingsSection>
      )}

      {binding && (
        <ChannelBindDialog
          channel={byId.get(binding.id) ?? binding}
          onClose={() => setBinding(null)}
          onBound={() => {
            const done = binding;
            setBinding(null);
            void load();
            toast.success(
              done.receive
                ? t("settings.imChannels.boundChat", { channel: done.title })
                : t("settings.imChannels.boundPush", { channel: done.title }),
            );
          }}
        />
      )}
    </div>
  );
}

/** 「新增通道」下拉菜单：通道名 + 一句话说明，点选即开绑定弹窗。 */
function AddChannelMenu({
  channels,
  onPick,
  disabled,
}: {
  channels: ChannelInfo[];
  onPick: (channel: ChannelInfo) => void;
  disabled: boolean;
}) {
  const t = useTranslations();
  const locale = useLocale();
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`}
        >
          <PlusIcon className="size-4" />
          {t("settings.imChannels.add")}
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          collisionPadding={12}
          className={`menu-surface z-50 min-w-[14rem] p-1${locale === "en" ? " max-w-[calc(100vw-1.5rem)]" : ""}`}
        >
          {channels.map((channel) => (
            <DropdownMenu.Item
              key={channel.id}
              onSelect={() => onPick(channel)}
              className="glass-row nav-item cursor-pointer flex-col !items-start gap-0 px-3 py-2 outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)] data-[highlighted]:!text-[var(--text)]"
            >
              <span className="text-sub font-medium">{t("settings.imChannels.addNamed", { channel: channel.title })}</span>
              {channel.description && (
                <span className="text-caption text-[var(--text-faint)]">{channel.description}</span>
              )}
            </DropdownMenu.Item>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** 一行已接入账号：通道名 + 运行状态 + 绑定人 / 失效原因 + 解绑。 */
function ChannelAccountRowView({
  row,
  channel,
  busy,
  onUnbind,
}: {
  row: ChannelAccount;
  channel: ChannelInfo | undefined;
  busy: boolean;
  onUnbind: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const pill = !row.channel_available
    ? { label: t("settings.imChannels.pluginDisabled"), tone: "neutral" as const }
    : row.status === "stale"
      ? { label: t("settings.imChannels.stale"), tone: "danger" as const }
      : row.running
        ? { label: t("settings.imChannels.running"), tone: "ok" as const }
        : { label: t("settings.imChannels.stopped"), tone: "neutral" as const };
  const who = row.bound_user_id ?? row.display_name;

  return (
    <SettingsRow
      stackOnMobile={locale === "en"}
      leading={
        <span className={`icon-chip size-10 !rounded-xl${locale === "en" ? " max-sm:!hidden" : ""}`}>
          <ChatIcon className="size-5" />
        </span>
      }
      label={
        <span className={`flex items-center gap-2${locale === "en" ? " flex-wrap" : ""}`}>
          <span className={locale === "en" ? "break-words" : "truncate"}>{channel?.title ?? row.channel_id}</span>
          <StatusPill tone={pill.tone} label={pill.label} />
        </span>
      }
      description={
        <span className={locale === "en" ? "block break-words" : "block truncate"}>
          {!row.channel_available
            ? t("settings.imChannels.disabledDescription")
            : row.status === "stale"
              ? (row.last_error ?? t("settings.imChannels.staleDescription"))
              : t("settings.imChannels.boundAt", { who, time: formatRelativeTime(row.bound_at, locale) })}
        </span>
      }
    >
      <button type="button" disabled={busy} onClick={onUnbind} className={SETTINGS_BUTTON_CLASS}>
        {t("settings.imChannels.unbind")}
      </button>
    </SettingsRow>
  );
}
