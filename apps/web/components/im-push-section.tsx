"use client";

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

import { useCallback, useEffect, useState } from "react";

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
import { formatRelativeTime } from "@/lib/time";

/**
 * 通道来自通道插件（docs/design/plugin-channels.md）：列表与「新增通道」菜单都按接口返回的
 * 通道渲染，不认识具体平台。提供某个通道的插件关掉 / 卸载了，它的账号照常列出、标「未启用」，
 * 重新启用后自动恢复。
 */
export function ImPushSection() {
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

  const load = useCallback(async () => {
    setError(null);
    try {
      const data = await listChannels();
      setChannels(data.channels);
      setRows(data.accounts);
    } catch (e) {
      setError((e as Error).message);
      setRows([]);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const byId = new Map(channels.map((c) => [c.id, c]));
  // 能对话的通道完全由模型驱动：没接模型时菜单里只留只推送的通道
  const addable = channels.filter((c) => llmConfigured !== false || !c.receive);

  async function handleUnbind(row: ChannelAccount) {
    const title = byId.get(row.channel_id)?.title ?? row.channel_id;
    if (
      !(await confirm({
        title: `解绑该 ${title} 账号？`,
        description: "解绑后停止收发、删除凭据，需要重新绑定才能使用；历史对话保留。",
        confirmLabel: "解绑",
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
      toast.success(`已推送到 ${sent} 个账号，去客户端看看吧`);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setPushBusy(false);
    }
  }

  const loading = rows == null;
  const titles = channels.map((c) => c.title).join("、");

  return (
    <div className="space-y-10">
      <div className="space-y-4">
        <p className="text-sub leading-6 text-[var(--text-muted)]">
          接入的通道是你的通知渠道，收哪些通知和手机 App 一样，在
          <Link href={"/settings/notifications" as Route} className={`mx-1 ${LINK_CLASS}`}>
            账号 → 通知
          </Link>
          里设置。能对话的通道里还能直接和 AI 助手聊：发消息即可搜片、订阅、查进度。
          发送
          <span className="mx-1 rounded bg-white/[0.08] px-1.5 py-0.5 text-caption">/reset</span>
          重置会话，
          <span className="mx-1 rounded bg-white/[0.08] px-1.5 py-0.5 text-caption">/stop</span>
          取消正在进行的处理。通道由插件提供，在
          <Link href={"/settings/plugins" as Route} className={`mx-1 ${LINK_CLASS}`}>
            设置 → 插件
          </Link>
          里可以安装更多通道。
        </p>

        {/* 前置门禁：对话完全由模型驱动，未接入模型时引导（只推送的通道不受影响） */}
        {llmConfigured === false && <LlmSetupNotice feature="通道中的 AI 对话能力" />}

        {error && <ErrorBanner>{error}</ErrorBanner>}
      </div>

      <SettingsSection
        title="接入通道"
        description={
          loading ? "加载中…" : rows.length > 0 ? `已接入 ${rows.length} 个账号` : undefined
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
            title="还没有接入任何通道"
            description={
              channels.length === 0
                ? "没有可用的通道：到「设置 → 插件」看看通道插件是否都关掉了。"
                : `点「新增通道」接入，支持${titles}。`
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
        <SettingsSection title="测试">
          <SettingsList>
            <SettingsRow label="测试推送" description="向所有已接入通道发送一条测试消息">
              <button
                type="button"
                disabled={pushBusy}
                onClick={() => void handleTestPush()}
                className={SETTINGS_BUTTON_CLASS}
              >
                {pushBusy ? "发送中…" : "发送"}
              </button>
            </SettingsRow>
          </SettingsList>
        </SettingsSection>
      )}

      {binding && (
        <ChannelBindDialog
          channel={binding}
          onClose={() => setBinding(null)}
          onBound={() => {
            const done = binding;
            setBinding(null);
            void load();
            toast.success(
              done.receive
                ? `${done.title} 已接入，现在就可以给它发消息试试`
                : `${done.title} 已接入，推送会发到那里`,
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
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`}
        >
          <PlusIcon className="size-4" />
          新增通道
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          collisionPadding={12}
          className="menu-surface z-50 min-w-[14rem] p-1"
        >
          {channels.map((channel) => (
            <DropdownMenu.Item
              key={channel.id}
              onSelect={() => onPick(channel)}
              className="glass-row nav-item cursor-pointer flex-col !items-start gap-0 px-3 py-2 outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)] data-[highlighted]:!text-[var(--text)]"
            >
              <span className="text-sub font-medium">新增 {channel.title} 通道</span>
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
  const pill = !row.channel_available
    ? { label: "插件未启用", tone: "neutral" as const }
    : row.status === "stale"
      ? { label: "需重新绑定", tone: "danger" as const }
      : row.running
        ? { label: "运行中", tone: "ok" as const }
        : { label: "未运行", tone: "neutral" as const };
  const who = row.bound_user_id ?? row.display_name;

  return (
    <SettingsRow
      leading={
        <span className="icon-chip size-10 !rounded-xl">
          <ChatIcon className="size-5" />
        </span>
      }
      label={
        <span className="flex items-center gap-2">
          <span className="truncate">{channel?.title ?? row.channel_id}</span>
          <StatusPill tone={pill.tone} label={pill.label} />
        </span>
      }
      description={
        <span className="block truncate">
          {!row.channel_available
            ? "提供这个通道的插件已关闭或卸载，账号保留，重新启用后自动恢复"
            : row.status === "stale"
              ? (row.last_error ?? "凭据已失效，请重新绑定")
              : `${who} · 绑定于 ${formatRelativeTime(row.bound_at)}`}
        </span>
      }
    >
      <button type="button" disabled={busy} onClick={onUnbind} className={SETTINGS_BUTTON_CLASS}>
        解绑
      </button>
    </SettingsRow>
  );
}
