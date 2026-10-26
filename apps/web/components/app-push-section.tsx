"use client";

import { useLocale, useTranslations } from "next-intl";

/**
 * 「App 推送」设置分区（docs/design/cloud-push.md §3、§7.2、§8）。
 *
 * 只管通道：官方推送（来自 MovieClaw Cloud）+ 管理员加的自建中继，每个通道一行，
 * 带启用开关和「N 台设备」。设备只在「账号 → 设备」一个地方管，这里不再列设备；
 * 有 App 版本登记了推送却没有任何可用通道时，顶部才出一条提示，没缺口就什么都不说。
 *
 * 官方通道在服务器没连接 MovieClaw Cloud 时显示「未激活」并引导去连接，不隐藏：
 * 让管理员知道有这条路。连接云在「系统 → MovieClaw Cloud」，自建中继的用户可以
 * 完全不碰云（§0.1）。所有写接口都返回整份 PushChannelsView，拿到就整页重画。
 */

import type { Route } from "next";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";

import {
  AddRelayDialog,
  EditRelayDialog,
  RELAY_DEPLOY_URL,
} from "@/components/app-push/relay-dialogs";
import { Banner, ErrorBanner, LINK_CLASS, StatusPill, Toggle } from "@/components/cloud-push-ui";
import { useConfirm, useToast } from "@/components/feedback";
import { CloudIcon, PlusIcon, ServerIcon } from "@/components/icons";
import {
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsList,
  SettingsMoreMenu,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type PushChannelView,
  type PushChannelsView,
  type PushQuota,
  deleteRelay,
  getPushChannels,
  refreshRelay,
  setOfficialChannelEnabled,
  updateRelay,
} from "@/lib/api/push";
import {
  TONE_COLOR,
  channelDetails,
  channelDeviceCount,
  channelPill,
  officialAwaitingCloud,
  quotaLabel,
  quotaPercent,
  quotaTone,
  uncoveredSummary,
} from "@/lib/cloud-push-display";

export function AppPushSection() {
  const t = useTranslations();
  const locale = useLocale();
  const [view, setView] = useState<PushChannelsView | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoadError(null);
    try {
      setView(await getPushChannels(locale));
    } catch (e) {
      setLoadError((e as Error).message);
    }
  }, [locale]);

  useEffect(() => {
    void load();
  }, [load]);

  if (view == null) {
    return loadError ? (
      <div className="space-y-3">
        <ErrorBanner>{loadError}</ErrorBanner>
        <button
          type="button"
          onClick={() => void load()}
          className="btn-glass px-4 py-1.5 text-sub font-medium"
        >
          {t("common.retry")}
        </button>
      </div>
    ) : (
      <div className="space-y-2.5">
        <div className="h-[88px] animate-pulse rounded-xl bg-white/[0.04]" />
        <div className="h-[88px] animate-pulse rounded-xl bg-white/[0.04]" />
      </div>
    );
  }
  return <ChannelList view={view} onView={setView} />;
}

function ChannelList({
  view,
  onView,
}: {
  view: PushChannelsView;
  onView: (view: PushChannelsView) => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const router = useRouter();
  const confirm = useConfirm();
  const toast = useToast();
  const [error, setError] = useState<string | null>(null);
  // 正在重新检测 / 删除的中继
  const [busyId, setBusyId] = useState<string | null>(null);
  // 开关的乐观值：请求在路上时开关先拨过去，失败再拨回
  const [toggling, setToggling] = useState<Record<string, boolean>>({});
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<PushChannelView | null>(null);
  const uncovered = uncoveredSummary(view.uncovered, locale);

  const toggle = async (channel: PushChannelView, enabled: boolean) => {
    setToggling((prev) => ({ ...prev, [channel.id]: enabled }));
    setError(null);
    try {
      onView(
        channel.kind === "official"
          ? await setOfficialChannelEnabled(enabled)
          : await updateRelay(channel.id, { enabled }),
      );
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setToggling((prev) => {
        const next = { ...prev };
        delete next[channel.id];
        return next;
      });
    }
  };

  const refresh = async (channel: PushChannelView) => {
    setBusyId(channel.id);
    setError(null);
    try {
      const next = await refreshRelay(channel.id);
      onView(next);
      const updated = next.channels.find((c) => c.id === channel.id);
      if (updated) {
        const message = t("settings.pushChannels.statusReceipt", { name: updated.name, status: channelPill(updated, next.cloud_state, locale).label });
        if (updated.state === "error") toast.error(message);
        else toast.success(message);
      }
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusyId(null);
    }
  };

  const remove = async (channel: PushChannelView) => {
    const ok = await confirm({
      title: t("settings.pushChannels.removeTitle", { name: channel.name }),
      description:
        t("settings.pushChannels.removeHint"),
      confirmLabel: t("common.delete"),
      tone: "danger",
    });
    if (!ok) return;
    setBusyId(channel.id);
    setError(null);
    try {
      onView(await deleteRelay(channel.id));
      toast.success(t("settings.pushChannels.removed", { name: channel.name }));
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusyId(null);
    }
  };

  return (
    <div className="space-y-10">
      <div className="space-y-4">
        {/* 有缺口才提示：哪类 App 没有通道、去哪补（加自建中继），以及去「设备」页看是谁的 */}
        {uncovered && (
          <Banner
            tone="warn"
            action={
              <div className="flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={() => setAdding(true)}
                  className="btn-glass px-3 py-1.5 text-sub font-medium"
                >
                  {t("settings.pushChannels.addRelay")}
                </button>
                <button
                  type="button"
                  onClick={() => router.push("/settings/devices" as Route)}
                  className="btn-glass px-3 py-1.5 text-sub font-medium"
                >
                  {t("settings.pushChannels.viewDevices")}
                </button>
              </div>
            }
          >
            {uncovered}
          </Banner>
        )}

        <p className="text-sub leading-6 text-[var(--text-muted)]">
          {t("settings.pushChannels.routingHint")}
        </p>

        {error && <ErrorBanner>{error}</ErrorBanner>}
      </div>

      <SettingsSection
        title={t("settings.pushChannels.channels")}
        action={
          <button
            type="button"
            onClick={() => setAdding(true)}
            className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`}
          >
            <PlusIcon className="size-4" />
            {t("settings.pushChannels.addRelay")}
          </button>
        }
        footnote={
          <>
            {t("settings.pushChannels.relayHint")}{locale === "en" && " "}<a
              href={RELAY_DEPLOY_URL}
              target="_blank"
              rel="noopener noreferrer"
              className={LINK_CLASS}
            >
              {t("settings.pushChannels.deploy")}</a>
          </>
        }
      >
        <SettingsList>
          {view.channels.map((channel) => (
            <ChannelRow
              key={channel.id}
              channel={channel}
              cloudState={view.cloud_state}
              enabled={toggling[channel.id] ?? channel.enabled}
              busy={busyId === channel.id || channel.id in toggling}
              onToggle={(next) => void toggle(channel, next)}
              onEdit={() => setEditing(channel)}
              onRefresh={() => void refresh(channel)}
              onDelete={() => void remove(channel)}
            />
          ))}
        </SettingsList>
      </SettingsSection>

      {adding && (
        <AddRelayDialog
          onClose={() => setAdding(false)}
          onAdded={(next, name) => {
            onView(next);
            setAdding(false);
            toast.success(t("settings.pushChannels.added", { name }));
          }}
        />
      )}
      {editing && (
        <EditRelayDialog
          channel={editing}
          onClose={() => setEditing(null)}
          onSaved={(next) => {
            onView(next);
            setEditing(null);
            toast.success(t("settings.pushChannels.saved"));
          }}
        />
      )}
    </div>
  );
}

/**
 * 一个通道：名称 + 状态胶囊 + 设备数、地址 · 鉴权方式 · Bundle ID、额度条、最近的错误、
 * 启用开关；自建中继另有「⋯」菜单：编辑 / 重新检测 / 删除。
 */
function ChannelRow({
  channel,
  cloudState,
  enabled,
  busy,
  onToggle,
  onEdit,
  onRefresh,
  onDelete,
}: {
  channel: PushChannelView;
  cloudState: string;
  enabled: boolean;
  busy: boolean;
  onToggle: (next: boolean) => void;
  onEdit: () => void;
  onRefresh: () => void;
  onDelete: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const official = channel.kind === "official";
  const pill = channelPill(channel, cloudState, locale);
  const awaitingCloud = officialAwaitingCloud(channel, cloudState);
  const details = channelDetails(channel, locale);
  const deviceCount = channelDeviceCount(channel.device_count, locale);

  return (
    // 网格：开关只占标题那一行，说明、地址和额度从标题左缘一直铺到右缘——
    // 窄屏上开关不再整列占着右侧，地址和 Bundle ID 不会被挤成一截一截
    <div className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-start gap-x-4 px-4 py-3">
      <span className="icon-chip row-span-2 size-10 !rounded-xl">
        {official ? <CloudIcon className="size-5" /> : <ServerIcon className="size-5" />}
      </span>
      <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 self-center">
        <p className={`min-w-0 ${locale === "en" ? "break-words" : "truncate"} text-body font-medium text-[var(--text)]`}>{channel.name}</p>
        <StatusPill tone={pill.tone} label={pill.label} />
        {deviceCount && (
          <span className="text-caption text-[var(--text-faint)]">{deviceCount}</span>
        )}
      </div>
      {/* 官方通道跟着云连接走：没连接时开关关着、按不动，连上之后才由管理员决定开关 */}
      <div className="flex items-center gap-2 self-center">
        {!official && (
          <SettingsMoreMenu
            label={t("settings.pushChannels.more", { name: channel.name })}
            disabled={busy}
            items={[
              { label: t("settings.pushChannels.edit"), onSelect: onEdit },
              { label: t("settings.pushChannels.refresh"), onSelect: onRefresh },
              { label: t("common.delete"), onSelect: onDelete, danger: true },
            ]}
          />
        )}
        <Toggle
          checked={awaitingCloud ? false : enabled}
          label={t("settings.pushChannels.enable", { name: channel.name })}
          disabled={busy || awaitingCloud}
          onChange={onToggle}
        />
      </div>
      <div className="col-span-2 col-start-2 min-w-0">
        {official && (
          <p className="mt-0.5 text-caption leading-5 text-[var(--text-muted)]">
            {t("settings.pushChannels.officialHint")}
          </p>
        )}
        {details && (
          <p
            title={channel.software ?? undefined}
            className="mt-0.5 break-words font-mono text-caption leading-5 text-[var(--text-faint)]"
          >
            {details}
          </p>
        )}
        {awaitingCloud && (
          <p className="mt-1 text-caption leading-5 text-[var(--text-muted)]">
            {t("settings.pushChannels.connectHint")}{locale === "en" && " "}<Link href="/settings/cloud" className={LINK_CLASS}>
              {t("settings.pushChannels.connect")}
            </Link>
          </p>
        )}
        {channel.quota && <QuotaMeter quota={channel.quota} />}
        {channel.last_error && (
          <p className="mt-1 break-words text-caption leading-5 text-[var(--danger)]">
            {channel.last_error}
          </p>
        )}
      </div>
    </div>
  );
}

/**
 * 今日额度：比例条 + 读数，剩不到 5% 转黄（这时实例只发提醒类通知）。
 * 只知道上限（官方通道还没推送过）或只知道用量时只写读数，不画条。
 */
function QuotaMeter({ quota }: { quota: PushQuota }) {
  const locale = useLocale();
  const label = quotaLabel(quota, locale);
  if (!label) return null;
  const percent = quotaPercent(quota);
  const tone = quotaTone(quota);
  return (
    <div className="mt-2 max-w-[260px]">
      {percent != null && (
        <div className="mb-1 h-1.5 overflow-hidden rounded-full bg-white/[0.08]">
          <div
            className="h-full rounded-full"
            style={{
              width: `${percent}%`,
              background: tone ? TONE_COLOR[tone] : "var(--accent)",
            }}
          />
        </div>
      )}
      <p className="text-caption text-[var(--text-faint)]">{label}</p>
    </div>
  );
}
