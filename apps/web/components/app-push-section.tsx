"use client";

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
  const [view, setView] = useState<PushChannelsView | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoadError(null);
    try {
      setView(await getPushChannels());
    } catch (e) {
      setLoadError((e as Error).message);
    }
  }, []);

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
          重试
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
  const uncovered = uncoveredSummary(view.uncovered);

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
        const message = `「${updated.name}」：${channelPill(updated, next.cloud_state).label}`;
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
      title: `删除「${channel.name}」？`,
      description:
        "用它推送的设备会换到别的能推送它们的通道；没有的话，这些设备就收不到通知了。",
      confirmLabel: "删除",
      tone: "danger",
    });
    if (!ok) return;
    setBusyId(channel.id);
    setError(null);
    try {
      onView(await deleteRelay(channel.id));
      toast.success(`已删除「${channel.name}」`);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusyId(null);
    }
  };

  return (
    <div className="space-y-5">
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
                添加自建中继
              </button>
              <button
                type="button"
                onClick={() => router.push("/settings/devices" as Route)}
                className="btn-glass px-3 py-1.5 text-sub font-medium"
              >
                查看设备
              </button>
            </div>
          }
        >
          {uncovered}
        </Banner>
      )}

      <p className="text-sub leading-6 text-[var(--text-muted)]">
        通知在这台服务器上加密，通道只转发密文。每台设备按它装的 App 自动选通道：官方推送在前，自建中继按列表顺序，前一个连不上就换下一个。
      </p>

      {error && <ErrorBanner>{error}</ErrorBanner>}

      <div className="css-glass !rounded-xl">
        {view.channels.map((channel, i) => (
          <ChannelRow
            key={channel.id}
            channel={channel}
            cloudState={view.cloud_state}
            divided={i > 0}
            enabled={toggling[channel.id] ?? channel.enabled}
            busy={busyId === channel.id || channel.id in toggling}
            onToggle={(next) => void toggle(channel, next)}
            onEdit={() => setEditing(channel)}
            onRefresh={() => void refresh(channel)}
            onDelete={() => void remove(channel)}
          />
        ))}
        <div
          className={`flex flex-wrap items-center gap-x-4 gap-y-2 p-4 ${
            view.channels.length > 0 ? "border-t border-white/[0.06]" : ""
          }`}
        >
          <button
            type="button"
            onClick={() => setAdding(true)}
            className="btn-glass flex shrink-0 items-center gap-1 py-1.5 pl-2.5 pr-3.5 text-sub font-medium"
          >
            <PlusIcon className="size-4" />
            添加自建中继
          </button>
          <p className="min-w-0 flex-1 basis-56 text-caption leading-5 text-[var(--text-faint)]">
            给自己打包的 App 用；能推哪些 App 由中继上的推送证书决定。
            <a
              href={RELAY_DEPLOY_URL}
              target="_blank"
              rel="noopener noreferrer"
              className={LINK_CLASS}
            >
              怎么部署 ↗
            </a>
          </p>
        </div>
      </div>

      {adding && (
        <AddRelayDialog
          onClose={() => setAdding(false)}
          onAdded={(next, name) => {
            onView(next);
            setAdding(false);
            toast.success(`已添加「${name}」`);
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
            toast.success("已保存");
          }}
        />
      )}
    </div>
  );
}

/**
 * 一个通道：名称 + 状态胶囊 + 设备数、地址 · 鉴权方式 · Bundle ID、额度条、最近的错误、
 * 启用开关；自建中继另有编辑 / 重新检测 / 删除。
 */
function ChannelRow({
  channel,
  cloudState,
  divided,
  enabled,
  busy,
  onToggle,
  onEdit,
  onRefresh,
  onDelete,
}: {
  channel: PushChannelView;
  cloudState: string;
  divided: boolean;
  enabled: boolean;
  busy: boolean;
  onToggle: (next: boolean) => void;
  onEdit: () => void;
  onRefresh: () => void;
  onDelete: () => void;
}) {
  const official = channel.kind === "official";
  const pill = channelPill(channel, cloudState);
  const awaitingCloud = officialAwaitingCloud(channel, cloudState);
  const details = channelDetails(channel);
  const deviceCount = channelDeviceCount(channel.device_count);

  return (
    // 网格：开关只占标题那一行，说明、地址、额度和按钮从标题左缘一直铺到右缘——
    // 窄屏上开关不再整列占着右侧，地址和 Bundle ID 不会被挤成一截一截
    <div
      className={`grid grid-cols-[auto_minmax(0,1fr)_auto] items-start gap-x-3.5 p-4 ${
        divided ? "border-t border-white/[0.06]" : ""
      }`}
    >
      <span className="icon-chip row-span-2 size-10 !rounded-xl">
        {official ? <CloudIcon className="size-5" /> : <ServerIcon className="size-5" />}
      </span>
      <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 self-center">
        <p className="min-w-0 truncate text-body font-semibold text-[var(--text)]">{channel.name}</p>
        <StatusPill tone={pill.tone} label={pill.label} />
        {deviceCount && (
          <span className="text-caption text-[var(--text-faint)]">{deviceCount}</span>
        )}
      </div>
      {/* 官方通道跟着云连接走：没连接时开关关着、按不动，连上之后才由管理员决定开关 */}
      <Toggle
        checked={awaitingCloud ? false : enabled}
        label={`启用${channel.name}`}
        disabled={busy || awaitingCloud}
        onChange={onToggle}
      />
      <div className="col-span-2 col-start-2 min-w-0">
        {official && (
          <p className="mt-0.5 text-caption leading-5 text-[var(--text-muted)]">
            给 App Store、TestFlight 版的 MovieClaw App 用，通过 MovieClaw Cloud
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
            这台服务器还没有连接 MovieClaw 账号，连接后官方推送自动启用。
            <Link href="/settings/cloud" className={LINK_CLASS}>
              去连接
            </Link>
          </p>
        )}
        {channel.quota && <QuotaMeter quota={channel.quota} />}
        {channel.last_error && (
          <p className="mt-1 break-words text-caption leading-5 text-[var(--danger)]">
            {channel.last_error}
          </p>
        )}
        {!official && (
          <div className="mt-2.5 flex flex-wrap gap-2">
            <button
              type="button"
              disabled={busy}
              onClick={onEdit}
              className="btn-glass px-3 py-1 text-sub font-medium disabled:opacity-40"
            >
              编辑
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={onRefresh}
              className="btn-glass px-3 py-1 text-sub font-medium disabled:opacity-40"
            >
              重新检测
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={onDelete}
              className="btn-glass px-3 py-1 text-sub font-medium !text-[var(--danger)] disabled:opacity-40"
            >
              删除
            </button>
          </div>
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
  const label = quotaLabel(quota);
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
