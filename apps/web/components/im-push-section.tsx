"use client";

/**
 * 「IM 推送」设置分区（原名「消息推送」，与「App 推送」并列后改名以示区分）。
 *
 * 两类设定按胶囊标签分开（与「更新与维护」「外观」分区同一交互语言），因为它们
 * 回答的是两个完全不同的问题，动线不该缠在一起：
 *   - 接入通道：我接了哪些账号？——一张跨平台的统一列表 +「新增通道」菜单，
 *     绑定流程收进弹窗（见 channel-bind-dialog）；
 *   - 推送内容：什么事件会推给我？——事件开关 + 一键测试推送。
 *
 * 旧版把微信 / Telegram / Discord 三块绑定表单和推送开关平铺在一页里：
 * 只接了一个通道也要滚过另外两块空态与说明，推送开关被夹在中间；进页面
 * 还会自动弹微信二维码。改版后列表只呈现"已接入"的事实，一次性流程只在
 * 用户主动新增时才出现。
 */

import { useCallback, useEffect, useState } from "react";

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";

import {
  CHANNEL_KINDS,
  CHANNEL_META,
  ChannelBindDialog,
  type ChannelKind,
} from "@/components/channel-bind-dialog";
import { ErrorBanner, StatusPill, Toggle } from "@/components/cloud-push-ui";
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
  SettingsTabs,
} from "@/components/settings-ui";
import {
  type ChannelPushConfig,
  type ImChannelId,
  getChannelPushConfig,
  listImAccounts,
  listWeixinAccounts,
  sendChannelPushTest,
  unbindImAccount,
  unbindWeixinAccount,
  updateChannelPushConfig,
} from "@/lib/api/channels";
import { formatRelativeTime } from "@/lib/time";
import { useTabParam } from "@/lib/use-tab-param";

export function ImPushSection() {
  // ?tab=content 深链直达推送内容，切换写回地址栏（useTabParam，全设置页同一套）
  const [tab, setTab] = useTabParam(["channels", "content"] as const, "channels");
  const tabs = [
    { id: "channels" as const, label: "接入通道" },
    { id: "content" as const, label: "推送内容" },
  ];

  return (
    <div className="space-y-6">
      <SettingsTabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === "channels" ? <ChannelsTab /> : <PushContentTab />}
    </div>
  );
}

/* —— 接入通道：跨平台统一列表 + 新增菜单 —— */

/** 列表行：三个平台的账号归一成同一形状，列表本身不再关心来源差异。 */
interface ChannelAccountRow {
  channel: ChannelKind;
  account_id: string;
  /** 完成绑定的用户 id（白名单，同时是推送目标） */
  bound_user_id: string | null;
  status: "active" | "stale";
  running: boolean;
  last_error: string | null;
  bound_at: string;
}

function ChannelsTab() {
  const llmConfigured = useLlmConfigured();
  const confirm = useConfirm();
  const toast = useToast();
  const [rows, setRows] = useState<ChannelAccountRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // 正在绑定的通道（null = 没开弹窗）
  const [binding, setBinding] = useState<ChannelKind | null>(null);

  const load = useCallback(async () => {
    setError(null);
    try {
      // 各平台同源同后端，任一失败都视作整体失败：与其展示半张列表让用户
      // 误以为"某个通道掉了"，不如明确报错让他重试
      const [weixin, telegram, discord, feishu] = await Promise.all([
        listWeixinAccounts(),
        listImAccounts("telegram"),
        listImAccounts("discord"),
        listImAccounts("feishu"),
      ]);
      setRows([
        ...weixin.map((a) => ({ ...a, channel: "weixin" as const })),
        ...telegram.map((a) => ({ ...a, channel: "telegram" as const })),
        ...discord.map((a) => ({ ...a, channel: "discord" as const })),
        ...feishu.map((a) => ({ ...a, channel: "feishu" as const })),
      ]);
    } catch (e) {
      setError((e as Error).message);
      setRows([]);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function handleUnbind(row: ChannelAccountRow) {
    const label = CHANNEL_META[row.channel].label;
    if (
      !(await confirm({
        title: `解绑该 ${label} 账号？`,
        description:
          row.channel === "weixin"
            ? "解绑后需重新扫码才能使用。"
            : row.channel === "feishu"
              ? "解绑后群机器人不再收到推送，需重新粘贴 Webhook 地址。"
              : "解绑将删除 bot 凭据并停止通道，需重新配对才能使用。",
        confirmLabel: "解绑",
        tone: "danger",
      }))
    )
      return;
    setBusy(true);
    setError(null);
    try {
      if (row.channel === "weixin") await unbindWeixinAccount(row.account_id);
      else await unbindImAccount(row.channel as ImChannelId, row.account_id);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  const loading = rows == null;

  return (
    <div className="space-y-10">
      <div className="space-y-4">
        <p className="text-sub leading-6 text-[var(--text-muted)]">
          接入的通道都是推送目标；微信 / Telegram / Discord 里还能直接和 AI 助手对话：发消息即可搜片、订阅、查进度。
          发送
          <span className="mx-1 rounded bg-white/[0.08] px-1.5 py-0.5 text-caption">/reset</span>
          重置会话，
          <span className="mx-1 rounded bg-white/[0.08] px-1.5 py-0.5 text-caption">/stop</span>
          取消正在进行的处理。
        </p>

        {/* 前置门禁：对话完全由模型驱动，未接入模型时隐藏新增入口并引导 */}
        {llmConfigured === false && <LlmSetupNotice feature="通道中的 AI 对话能力" />}

        {error && <ErrorBanner>{error}</ErrorBanner>}
      </div>

      <SettingsSection
        title="接入通道"
        description={
          loading ? "加载中…" : rows.length > 0 ? `已接入 ${rows.length} 个账号` : undefined
        }
        action={
          llmConfigured !== false && <AddChannelMenu onPick={setBinding} disabled={loading} />
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
              // 没接模型时新增入口是藏起来的，文案不能再指向它
              llmConfigured === false
                ? "接入 AI 模型后即可新增微信、Telegram、Discord 和飞书通道。"
                : "点「新增通道」接入，支持微信、Telegram、Discord 和飞书。"
            }
          />
        ) : (
          <SettingsList>
            {rows.map((row) => (
              <ChannelAccountRowView
                key={`${row.channel}:${row.account_id}`}
                row={row}
                busy={busy}
                onUnbind={() => void handleUnbind(row)}
              />
            ))}
          </SettingsList>
        )}
      </SettingsSection>

      {binding && (
        <ChannelBindDialog
          channel={binding}
          onClose={() => setBinding(null)}
          onBound={() => {
            const label = CHANNEL_META[binding].label;
            setBinding(null);
            void load();
            toast.success(
              binding === "feishu"
                ? `${label} 已接入，去飞书群里看看欢迎消息吧`
                : `${label} 已接入，现在就可以给它发消息试试`,
            );
          }}
        />
      )}
    </div>
  );
}

/** 「新增通道」下拉菜单：平台名 + 一句话说明，点选即开绑定弹窗。 */
function AddChannelMenu({
  onPick,
  disabled,
}: {
  onPick: (channel: ChannelKind) => void;
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
          {CHANNEL_KINDS.map((channel) => {
            const meta = CHANNEL_META[channel];
            return (
              <DropdownMenu.Item
                key={channel}
                onSelect={() => onPick(channel)}
                className="glass-row nav-item cursor-pointer flex-col !items-start gap-0 px-3 py-2 outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)] data-[highlighted]:!text-[var(--text)]"
              >
                <span className="text-sub font-medium">新增 {meta.label} 渠道</span>
                <span className="text-caption text-[var(--text-faint)]">{meta.summary}</span>
              </DropdownMenu.Item>
            );
          })}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** 一行已接入账号：平台名 + 运行状态 + 绑定人 / 失效原因 + 解绑。 */
function ChannelAccountRowView({
  row,
  busy,
  onUnbind,
}: {
  row: ChannelAccountRow;
  busy: boolean;
  onUnbind: () => void;
}) {
  const pill =
    row.status === "stale"
      ? { label: "需重新绑定", tone: "danger" as const }
      : row.running
        ? { label: "运行中", tone: "ok" as const }
        : { label: "未运行", tone: "neutral" as const };

  return (
    <SettingsRow
      leading={
        <span className="icon-chip size-10 !rounded-xl">
          <ChatIcon className="size-5" />
        </span>
      }
      label={
        <span className="flex items-center gap-2">
          <span className="truncate">{CHANNEL_META[row.channel].label}</span>
          <StatusPill tone={pill.tone} label={pill.label} />
        </span>
      }
      description={
        <span className="block truncate">
          {row.status === "stale"
            ? (row.last_error ?? "凭据已失效，请重新绑定")
            : row.channel === "feishu"
              ? `群机器人 · 绑定于 ${formatRelativeTime(row.bound_at)}`
              : `${row.bound_user_id ?? row.account_id} · 绑定于 ${formatRelativeTime(row.bound_at)}`}
        </span>
      }
    >
      <button type="button" disabled={busy} onClick={onUnbind} className={SETTINGS_BUTTON_CLASS}>
        解绑
      </button>
    </SettingsRow>
  );
}

/* —— 推送内容：事件开关 + 测试推送 —— */

function PushContentTab() {
  const toast = useToast();
  const [config, setConfig] = useState<ChannelPushConfig | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pushBusy, setPushBusy] = useState(false);

  useEffect(() => {
    getChannelPushConfig()
      .then(setConfig)
      .catch((e) => setError((e as Error).message));
  }, []);

  async function handleToggle(key: keyof ChannelPushConfig, value: boolean) {
    if (config == null) return;
    const next = { ...config, [key]: value };
    setConfig(next); // 乐观更新，失败回滚
    setError(null);
    try {
      await updateChannelPushConfig(next);
    } catch (e) {
      setConfig(config);
      setError((e as Error).message);
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

  const rows: { key: keyof ChannelPushConfig; label: string; desc: string }[] = [
    { key: "push_dispatch", label: "开始下载", desc: "订阅命中资源并提交下载器时" },
    { key: "push_imported", label: "入库完成", desc: "下载完成整理进媒体库时" },
  ];

  return (
    <div className="space-y-10">
      {error && <ErrorBanner>{error}</ErrorBanner>}

      <SettingsSection
        title="推送事件"
        description="对所有已接入通道统一生效——关掉某个事件，任何通道都不会再收到它。"
      >
        {config == null ? (
          <div className="h-[112px] animate-pulse rounded-xl bg-white/[0.04]" />
        ) : (
          <SettingsList>
            {rows.map((row) => (
              <SettingsRow key={row.key} label={row.label} description={row.desc}>
                <Toggle
                  checked={config[row.key]}
                  label={`${row.label}推送`}
                  onChange={(v) => void handleToggle(row.key, v)}
                />
              </SettingsRow>
            ))}
          </SettingsList>
        )}
      </SettingsSection>

      {/* 测试推送：验证已接入通道确实能收到系统事件 */}
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
    </div>
  );
}
