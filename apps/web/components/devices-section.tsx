"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import type { Route } from "next";

import { CopyButton } from "@/components/copy-button";
import { useConfirm, usePrompt, useToast } from "@/components/feedback";
import {
  CheckIcon,
  ChevronRightIcon,
  DeviceIcon,
  InfoIcon,
  PencilIcon,
  PlusIcon,
  TerminalIcon,
} from "@/components/icons";
import { reloadAfterAccountChange } from "@/lib/account-reload";
import { getAppConfig } from "@/lib/api/app";
import { logout } from "@/lib/api/auth";
import {
  type LoginDeviceView,
  createDeviceToken,
  listLoginDevices,
  renameLoginDevice,
  revokeLoginDevice,
} from "@/lib/api/devices";
import {
  STALE_AFTER_DAYS,
  envSnippet,
  grantBadge,
  groupDevices,
  headlessArgs,
  activityLabel,
  deviceLive,
  isStale,
  issuedVerb,
  manualGrantSummary,
  resolveServerAddress,
  revokeConsequence,
} from "@/lib/devices-display";
import { TONE_COLOR, devicePushNote } from "@/lib/cloud-push-display";
import { accessiblePathFor } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import { formatDateTime } from "@/lib/time";
import { useTheme } from "@/lib/ui-prefs";

/**
 * 「设置 → 设备」分区（docs/design/login-devices.md §8；配对流程见 device-auth.md）。
 *
 * 一个人的全部登录设备都在这一页：浏览器、App、命令行、转码器、手工令牌，
 * 以及合并展示的 Jellyfin 播放器。对所有登录用户开放，各看各的；超管另有
 * 「全部成员」视图与手工令牌。这一页承担三件事：
 *
 * 1. **只放「批准新设备」的入口**：批准本身在独立的 /activate 页（device-approval.tsx）。
 *    那是拿着配对码来做的一次性的事，与管理已登录的设备是两件事，混在列表上方反而让人
 *    分不清；设备的批准链接也直接指向 /activate（旧链接 /settings/devices?code= 会跳过去）。
 * 2. **注销是唯一的事后止损手段**：凭证长期有效，改密也默认不连坐配对设备。
 *    所以列表要好用——按类型分组、最近活跃要准、当前设备有标记、一键注销；
 *    长期不用的给一行轻提示，但不自动失效。
 * 3. **手工令牌是配对流够不到的环境的唯一入口**（超管）：NAS 的定时任务、CI、
 *    无界面容器、命令行模式的转码器，那里没人能按批准。
 */
export function DevicesSection() {
  const { session } = useSession();
  const isAdmin = session.role === "admin";
  const confirm = useConfirm();
  const prompt = usePrompt();
  const toast = useToast();
  // 超管专属：只看我的 / 全部成员（all=true 时每台设备带主人）
  const [scope, setScope] = useState<"mine" | "all">("mine");
  const [devices, setDevices] = useState<LoginDeviceView[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  // 写操作后递增它来重拉列表；拉取放在 effect 里并丢弃过期响应——快速来回切
  // 「只看我的 / 全部成员」时，晚到的旧响应不能盖掉新视图
  const [reloadTick, setReloadTick] = useState(0);
  const reload = useCallback(() => setReloadTick((tick) => tick + 1), []);

  useEffect(() => {
    let alive = true;
    setLoadError(null);
    listLoginDevices(scope === "all").then(
      (next) => {
        if (alive) setDevices(next);
      },
      (e: Error) => {
        if (alive) setLoadError(e.message);
      },
    );
    return () => {
      alive = false;
    };
  }, [scope, reloadTick]);

  // 在线状态会变（转码器连上 / 断开、手机刚用过）：页面开着时每 15 秒静默刷新一次，
  // 切到后台标签页就不刷
  useEffect(() => {
    const timer = window.setInterval(() => {
      if (document.visibilityState === "visible") reload();
    }, 15_000);
    return () => window.clearInterval(timer);
  }, [reload]);

  const handleRename = async (device: LoginDeviceView) => {
    const input = await prompt({
      title: "给设备改名",
      description: "只改这里显示的名字，方便日后认出是哪台，不影响设备本身。",
      initialValue: device.name,
      maxLength: 64,
      confirmLabel: "保存",
    });
    const name = input?.trim();
    if (!name || name === device.name) return;
    setBusy(device.id);
    try {
      const updated = await renameLoginDevice(device.id, name);
      setDevices((rows) => rows?.map((row) => (row.id === updated.id ? updated : row)) ?? rows);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  /**
   * 注销当前这个浏览器 = 退出登录：走 /auth/logout 而不是 DELETE /auth/devices/{id}。
   * 两者在服务端都会作废这枚令牌，但只有退出登录会顺带清掉 Cookie、把账号袋切到
   * 浏览器里的下一个账号；直接删只会留下一枚作废的 Cookie，下一个请求 401 被踢去
   * 登录页，袋子里别的账号也白登了。整页跳转与用户菜单的「退出登录」同一套。
   */
  const signOutHere = async (device: LoginDeviceView) => {
    const ok = await confirm({
      title: "注销当前这台设备？",
      description:
        "这就是你正在使用的这个浏览器，注销后会立即退出登录。浏览器里还登录着其他账号的话，会自动切换过去。",
      confirmLabel: "注销并退出登录",
      tone: "danger",
    });
    if (!ok) return;
    setBusy(device.id);
    try {
      const next = await logout();
      await reloadAfterAccountChange(next ? accessiblePathFor(next, "/") : "/login", next != null);
    } catch (e) {
      toast.error((e as Error).message);
      setBusy(null);
    }
  };

  const handleRevoke = async (device: LoginDeviceView) => {
    if (device.current) {
      await signOutHere(device);
      return;
    }
    // 超管在「全部成员」视图里注销别人的设备：点名是谁的，免得误伤
    const owner =
      scope === "all" && device.owner_id !== 0 ? `它属于成员「${device.owner_nickname}」。` : "";
    const ok = await confirm({
      title: `注销「${device.name}」？`,
      description: `${owner}${revokeConsequence(device.kind, device.family)}其他设备不受影响。`,
      confirmLabel: "注销",
      tone: "danger",
    });
    if (!ok) return;
    setBusy(device.id);
    try {
      toast.success(await revokeLoginDevice(device.id));
      reload();
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const groups = devices ? groupDevices(devices) : [];

  return (
    <div className="space-y-8">
      {/* 批准新设备在独立的 /activate 页（components/device-approval.tsx）；这里只留入口，
          来设备页找「批准」的人不至于扑空 */}
      <Link
        href={"/activate" as Route}
        className="css-glass group flex items-center gap-3.5 !rounded-2xl px-5 py-4 transition-colors hover:bg-white/[0.06]"
      >
        <DeviceIcon className="size-5 shrink-0 text-[var(--text-muted)]" />
        <span className="min-w-0 flex-1">
          <span className="block text-body font-semibold text-[var(--text)]">批准新设备登录</span>
          <span className="block text-sub text-[var(--text-muted)]">
            Apple TV、Mac、命令行或转码器显示配对码后，到批准页输入
          </span>
        </span>
        <ChevronRightIcon className="size-4 shrink-0 text-[var(--text-faint)] transition-transform group-hover:translate-x-0.5" />
      </Link>

      <section className="space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-3 px-1">
          <h2 className="text-caption font-semibold uppercase tracking-wider text-[var(--text-faint)]">
            {scope === "all" ? "全部成员的设备" : "我的设备"}
          </h2>
          {isAdmin && (
            <ScopeToggle
              value={scope}
              onChange={(next) => {
                if (next === scope) return;
                setDevices(null);
                setScope(next);
              }}
            />
          )}
        </div>

        {loadError ? (
          <p className="rounded-xl border border-[var(--danger)]/30 bg-[var(--danger)]/10 px-4 py-2.5 text-sub text-[var(--danger)]">
            {loadError}
          </p>
        ) : devices === null ? (
          <p className="px-1 text-sub text-[var(--text-faint)]">加载中…</p>
        ) : groups.length === 0 ? (
          <EmptyState />
        ) : (
          groups.map((group) => (
            <div key={group.key} className="space-y-2">
              <h3 className="px-1 text-caption text-[var(--text-faint)]">
                {group.label}
                <span className="ml-1.5 tabular-nums">{group.devices.length}</span>
              </h3>
              <div className="css-glass divide-y divide-white/[0.055] !rounded-2xl">
                {group.devices.map((device) => (
                  <DeviceRow
                    key={device.id}
                    device={device}
                    showOwner={scope === "all"}
                    busy={busy === device.id}
                    onRename={() => void handleRename(device)}
                    onRevoke={() => void handleRevoke(device)}
                  />
                ))}
              </div>
            </div>
          ))
        )}
      </section>

      {isAdmin && <ManualTokenSection onCreated={reload} />}
    </div>
  );
}

/** 超管的视图切换：与设置页其余胶囊标签同一交互语言（Netflix 激活态白底黑字）。 */
function ScopeToggle({
  value,
  onChange,
}: {
  value: "mine" | "all";
  onChange: (next: "mine" | "all") => void;
}) {
  const activePillCls = useTheme().structural ? "bg-white text-black" : "bg-white/[0.14] text-white";
  const options = [
    { id: "mine" as const, label: "只看我的" },
    { id: "all" as const, label: "全部成员" },
  ];
  return (
    <div className="flex gap-1.5">
      {options.map((option) => (
        <button
          key={option.id}
          type="button"
          aria-pressed={option.id === value}
          onClick={() => onChange(option.id)}
          className={`rounded-full px-3 py-1 text-sub font-medium transition-colors ${
            option.id === value
              ? activePillCls
              : "text-[var(--text-muted)] hover:bg-white/[0.07] hover:text-[var(--text)]"
          }`}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}

/**
 * 设备列表的一行：在线点 + 名字（当前设备 / 权限标注）+ 类型与系统 + 最近活跃、
 * 来源与签发时间 + 改名 / 注销。
 */
function DeviceRow({
  device,
  showOwner,
  busy,
  onRename,
  onRevoke,
}: {
  device: LoginDeviceView;
  /** 「全部成员」视图：写明这台设备是谁的 */
  showOwner: boolean;
  busy: boolean;
  onRename: () => void;
  onRevoke: () => void;
}) {
  const live = deviceLive(device);
  const pushNote = devicePushNote(device.push);
  const identity = [
    device.kind_label,
    device.platform,
    device.client_version ? `版本 ${device.client_version}` : null,
  ]
    .filter(Boolean)
    .join(" · ");
  const activity = [
    activityLabel(device),
    device.last_seen_ip ? `来自 ${device.last_seen_ip}` : null,
    `${issuedVerb(device.kind, device.family)} ${formatDateTime(device.created_at)}`,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <div className="flex items-start gap-4 px-5 py-4 first:rounded-t-2xl last:rounded-b-2xl max-sm:gap-3 max-sm:px-4">
      <span
        aria-hidden
        className={`mt-[9px] size-2 shrink-0 rounded-full ${
          live ? "bg-[var(--ok,#4ade80)] shadow-[0_0_8px_rgba(74,222,128,0.55)]" : "bg-white/25"
        }`}
      />
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <p className="min-w-0 truncate text-body font-medium text-[var(--text)]">{device.name}</p>
          {device.current && (
            <span className="shrink-0 rounded-full bg-[var(--accent-soft)] px-2 py-0.5 text-caption font-semibold text-[var(--accent)]">
              当前设备
            </span>
          )}
          {/* 权限标注只给配对类：浏览器、App 就是本人在用，标「完全权限」只是噪音 */}
          {device.family === "paired" && (
            <span className="shrink-0 rounded-full bg-white/[0.06] px-2 py-0.5 text-caption text-[var(--text-muted)]">
              {grantBadge(device.scope, device.owner_id)}
            </span>
          )}
        </div>
        {showOwner && (
          <p className="mt-0.5 text-caption text-[var(--text-muted)]">
            属于 {device.owner_id === 0 ? "我" : `${device.owner_nickname}（@${device.owner_username}）`}
          </p>
        )}
        <p className="mt-0.5 text-caption text-[var(--text-faint)]">{identity}</p>
        <p className="mt-0.5 text-caption text-[var(--text-faint)]">{activity}</p>
        {isStale(device.last_seen_at, device.created_at) && (
          <p className="mt-1 text-caption text-[var(--warn)]">
            已超过 {STALE_AFTER_DAYS} 天没有活跃（不会自动失效），不再使用的话建议注销。
          </p>
        )}
        {/* App 收不到通知时写一行原因；能收到就什么都不写（docs/design/cloud-push.md §8） */}
        {pushNote && (
          <p
            className="mt-1 text-caption"
            style={{ color: pushNote.tone === "neutral" ? "var(--text-faint)" : TONE_COLOR[pushNote.tone] }}
          >
            {pushNote.text}
          </p>
        )}
      </div>
      <div className="flex shrink-0 items-center gap-1.5">
        {device.renamable && (
          <button
            type="button"
            disabled={busy}
            onClick={onRename}
            aria-label={`给「${device.name}」改名`}
            title="改名"
            className="btn-glass !size-8 justify-center !p-0 text-[var(--text-muted)] disabled:opacity-40"
          >
            <PencilIcon className="size-3.5" />
          </button>
        )}
        <button
          type="button"
          disabled={busy}
          onClick={onRevoke}
          className="btn-glass px-3 py-1.5 text-sub font-medium text-[var(--text-muted)] hover:text-[var(--danger)] disabled:opacity-40"
        >
          注销
        </button>
      </div>
    </div>
  );
}

/** 空态：直接告诉用户设备从哪来，而不是只说「暂无数据」。 */
function EmptyState() {
  return (
    <div className="css-glass flex flex-col items-center gap-3 !rounded-2xl px-6 py-10 text-center">
      <span className="icon-chip size-11 !rounded-2xl">
        <TerminalIcon className="size-5" />
      </span>
      <p className="text-body font-medium text-[var(--text)]">还没有登录着的设备</p>
      <p className="max-w-sm text-sub leading-relaxed text-[var(--text-muted)]">
        在 App 里登录、在终端运行 mclaw login，或在转码器里连接并配对后，它们会出现在这里。
      </p>
    </div>
  );
}

type ManualScope = "full" | "transcode";

const MANUAL_SCOPE_OPTIONS: { value: ManualScope; label: string; hint: string }[] = [
  { value: "full", label: "完全权限", hint: "给脚本、定时任务、CI 里的 mclaw 用" },
  { value: "transcode", label: "仅限转码", hint: "给命令行模式（Headless）的转码器用" },
];

/**
 * 「手工创建令牌」分区（超管专属；docs/design/device-auth.md §6.1、login-devices.md §1）。
 *
 * 存在的理由只有一条：**配对流要求有人在浏览器里按批准，而有些环境根本没有
 * 那个人**——NAS 上的定时任务、CI、无界面容器、命令行模式的转码器。在那里跑
 * `mclaw login` 只会挂到超时，CLI 因此在非 TTY 下直接以用法错误退出，并把用户
 * 指到这里。
 *
 * 四个刻意的取舍：
 *
 * 1. **做成次要入口，并主动劝退**。完全权限的手工令牌不过期，也没有配对流那道
 *    「核对配对码」的人工闸；能开浏览器的机器就该走 `mclaw login`。所以收起态
 *    第一段话就写明「不必走这里」，而不是把两条路并列摆着让用户挑。
 * 2. **权限分两档**：完全权限给脚本；仅限转码给命令行模式的转码器——它碰不到
 *    订阅、媒体库和设置，泄露了也只能被拿去转码。「将获得」随选择改写。
 * 3. **给能直接用的地址 + 令牌，不是一个裸令牌**。用户接下来要做的事是「让那台
 *    机器连上这台 movieclaw」，地址和令牌缺一不可；只给令牌等于把找地址这一步
 *    留给用户，而地址恰恰是自部署里最容易填错的东西。完全权限给 mclaw 的两行
 *    环境变量；仅限转码给命令行模式转码器的一行启动参数（它不读环境变量）。
 * 4. **明文只在创建响应里出现一次**，服务端只存哈希。所以这张卡必须让用户当场
 *    存走：关闭前有确认，关闭后只能注销重建。
 */
function ManualTokenSection({ onCreated }: { onCreated: () => void }) {
  const confirm = useConfirm();
  const [stage, setStage] = useState<"idle" | "form">("idle");
  const [name, setName] = useState("");
  const [scope, setScope] = useState<ManualScope>("full");
  const [nameError, setNameError] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [created, setCreated] = useState<{ name: string; token: string; scope: ManualScope } | null>(
    null,
  );
  // 对外访问地址：进入这个分区就先拉一次，等按下创建再拉会让那一下多等一个往返
  const [externalUrl, setExternalUrl] = useState("");
  const manualGrant = manualGrantSummary(scope);

  useEffect(() => {
    void getAppConfig()
      .then((config) => setExternalUrl(config.external_url))
      .catch(() => undefined); // 拿不到就回落当前地址，不该挡住创建
  }, []);

  const resetForm = () => {
    setStage("idle");
    setName("");
    setScope("full");
    setNameError(null);
  };

  const handleCreate = async () => {
    const trimmed = name.trim();
    if (!trimmed) {
      setNameError("先给它起个名字，否则日后没法在列表里认出是哪台机器。");
      return;
    }
    setCreating(true);
    setError(null);
    try {
      const token = await createDeviceToken(trimmed, scope);
      setCreated({ name: token.name, token: token.token, scope });
      resetForm();
      onCreated();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setCreating(false);
    }
  };

  // 关闭一次性凭据卡要过确认：明文关掉就再也读不到，误点的代价是注销重建
  const handleDismiss = async () => {
    const ok = await confirm({
      title: "关闭后就看不到这枚令牌了？",
      description:
        "令牌明文只显示这一次。确认你已经把它存进目标机器，或者复制到了安全的地方。",
      confirmLabel: "我已保存",
    });
    if (ok) setCreated(null);
  };

  return (
    <section className="space-y-3">
      <div className="flex items-baseline justify-between gap-3 px-1">
        <h2 className="text-caption font-semibold uppercase tracking-wider text-[var(--text-faint)]">
          手工创建令牌
        </h2>
        {stage === "idle" && !created && (
          <button
            type="button"
            onClick={() => setStage("form")}
            className="btn-glass flex items-center gap-1.5 px-3 py-1.5 text-sub font-medium"
          >
            <PlusIcon className="size-3.5" />
            创建令牌
          </button>
        )}
      </div>

      {error && (
        <p className="rounded-xl border border-[var(--danger)]/30 bg-[var(--danger)]/10 px-4 py-2.5 text-sub text-[var(--danger)]">
          {error}
        </p>
      )}

      {created ? (
        <CreatedTokenCard
          name={created.name}
          token={created.token}
          scope={created.scope}
          externalUrl={externalUrl}
          onDismiss={() => void handleDismiss()}
        />
      ) : stage === "form" ? (
        <div className="css-glass space-y-4 !rounded-2xl p-5">
          <div className="space-y-1.5">
            <label htmlFor="manual-token-name" className="text-sub font-medium text-[var(--text-muted)]">
              名字
            </label>
            <input
              id="manual-token-name"
              type="text"
              autoFocus
              maxLength={64}
              value={name}
              placeholder={scope === "transcode" ? "macmini-m1" : "nas-cron"}
              onChange={(e) => {
                setName(e.target.value);
                if (nameError) setNameError(null);
              }}
              onKeyDown={(e) => e.key === "Enter" && void handleCreate()}
              className="w-full rounded-xl border border-white/[0.08] bg-white/[0.04] px-3 py-2 text-body text-[var(--text)] outline-none transition-colors placeholder:text-[var(--text-faint)] focus:border-[var(--accent)]/50"
            />
            <p
              className={`text-caption ${
                nameError ? "text-[var(--danger)]" : "text-[var(--text-faint)]"
              }`}
            >
              {nameError ??
                (scope === "transcode"
                  ? "建议与转码器的 --worker-id 同名：「设置 → 播放」靠名字对上它的在线状态。"
                  : "日后在上面的设备列表里就靠它认出这枚令牌、决定要不要注销。")}
            </p>
          </div>

          <fieldset className="space-y-1.5">
            <legend className="mb-1.5 text-sub font-medium text-[var(--text-muted)]">权限</legend>
            <div className="grid grid-cols-2 gap-2 max-sm:grid-cols-1">
              {MANUAL_SCOPE_OPTIONS.map((option) => (
                <label
                  key={option.value}
                  className={`cursor-pointer rounded-xl border px-3.5 py-2.5 transition-colors has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-[var(--accent-ring)] ${
                    scope === option.value
                      ? "border-[var(--accent)]/50 bg-[var(--accent-soft)]"
                      : "border-white/[0.08] bg-white/[0.03] hover:bg-white/[0.06]"
                  }`}
                >
                  <input
                    type="radio"
                    name="manual-token-scope"
                    value={option.value}
                    checked={scope === option.value}
                    onChange={() => setScope(option.value)}
                    className="sr-only"
                  />
                  <span
                    className={`block text-sub font-medium ${
                      scope === option.value ? "text-[var(--accent)]" : "text-[var(--text)]"
                    }`}
                  >
                    {option.label}
                  </span>
                  <span className="mt-0.5 block text-caption text-[var(--text-faint)]">{option.hint}</span>
                </label>
              ))}
            </div>
          </fieldset>

          {/* 与审批卡同一套说法：完全权限的手工令牌和批准出来的命令行令牌同权，
              没有理由在这里说得更轻 */}
          <div className="rounded-xl border border-[var(--accent)]/20 bg-[var(--accent-soft)] px-4 py-3">
            <p className="text-sub font-semibold text-[var(--accent)]">{manualGrant.title}</p>
            <p className="mt-1 text-sub leading-relaxed text-[var(--text-muted)]">
              {manualGrant.body}
            </p>
          </div>

          <div className="flex items-center gap-2.5">
            <button
              type="button"
              disabled={creating}
              onClick={() => void handleCreate()}
              className="btn-accent rounded-full px-4.5 py-2 text-sub font-semibold disabled:opacity-40"
            >
              {creating ? "创建中…" : "创建令牌"}
            </button>
            <button
              type="button"
              disabled={creating}
              onClick={resetForm}
              className="btn-glass px-3.5 py-2 text-sub font-medium text-[var(--text-muted)] disabled:opacity-40"
            >
              取消
            </button>
          </div>
        </div>
      ) : (
        <div className="css-glass !rounded-2xl p-5">
          <p className="text-sub leading-relaxed text-[var(--text-muted)]">
            没法在浏览器里按下批准的环境——NAS 上的定时任务、CI、无界面容器——在这里创建一枚令牌，用{" "}
            <code className="rounded bg-white/[0.06] px-1.5 py-0.5 font-mono text-[0.92em] text-[var(--text)]">
              MOVIECLAW_SERVER
            </code>{" "}
            和{" "}
            <code className="rounded bg-white/[0.06] px-1.5 py-0.5 font-mono text-[0.92em] text-[var(--text)]">
              MOVIECLAW_TOKEN
            </code>{" "}
            两个环境变量注入给 mclaw。能打开浏览器的机器请直接运行 mclaw login 配对，不必走这里。
            命令行模式（Headless）的转码器同样在这里创建，权限选「仅限转码」。
          </p>
        </div>
      )}
    </section>
  );
}

/**
 * 一次性凭据卡：全站唯一一处「现在不存就永远没了」的地方。
 *
 * 边框用 --warn 而不是 --accent 或 --danger：--danger 的语义是「失败了，要你
 * 处理」，这里没有任何东西失败；需要的是一个独有的、能让人停下来的信号。
 */
function CreatedTokenCard({
  name,
  token,
  scope,
  externalUrl,
  onDismiss,
}: {
  name: string;
  token: string;
  scope: ManualScope;
  externalUrl: string;
  onDismiss: () => void;
}) {
  const address = resolveServerAddress(
    externalUrl,
    typeof window === "undefined" ? "" : window.location.origin,
  );
  // 两种用途两种格式：完全权限给 mclaw 的两行环境变量；仅限转码给命令行模式
  // 转码器的一行启动参数——它只认显式参数、不读环境变量，照抄两行连不上
  const headless = scope === "transcode";
  const snippet = headless ? headlessArgs(address.url, token) : envSnippet(address.url, token);

  return (
    <div className="css-glass space-y-4 !rounded-2xl border-[var(--warn)]/35 p-5">
      <div className="flex items-start gap-3">
        <CheckIcon className="mt-0.5 size-[18px] shrink-0 text-[var(--ok)]" />
        <div className="min-w-0">
          <p className="text-body font-semibold text-[var(--text)]">已创建「{name}」</p>
          <p className="mt-0.5 text-sub leading-relaxed text-[var(--warn)]">
            令牌明文只显示这一次。关掉这张卡就再也读不到，只能注销后重建。
          </p>
        </div>
      </div>

      <div>
        <div className="mb-2 flex items-center justify-between gap-3">
          <span className="text-sub font-medium text-[var(--text-muted)]">
            {headless ? "加到转码器的启动命令里" : "粘贴到目标环境"}
          </span>
          <CopyButton
            text={snippet}
            label={headless ? "复制这一行" : "复制两行"}
            className="btn-glass px-3 py-1.5 text-sub font-medium text-[var(--text-muted)]"
          />
        </div>
        {/* 令牌那段用 --warn 上色：一眼分得出哪部分是秘密、不能贴进工单和聊天。
            显示的文字与复制出去的 snippet 逐字一致 */}
        <pre className="overflow-x-auto rounded-xl border border-white/[0.08] bg-black/[0.28] px-4 py-3.5 font-mono text-sub leading-relaxed">
          {headless ? (
            <>
              <span className="text-[var(--accent-2)]">--nas-url </span>
              <span className="text-[var(--text)]">{address.url}</span>
              <span className="text-[var(--accent-2)]"> --token </span>
              <span className="text-[var(--warn)]">{token}</span>
            </>
          ) : (
            <>
              <span className="text-[var(--accent-2)]">MOVIECLAW_SERVER=</span>
              <span className="text-[var(--text)]">{address.url}</span>
              {"\n"}
              <span className="text-[var(--accent-2)]">MOVIECLAW_TOKEN=</span>
              <span className="text-[var(--warn)]">{token}</span>
            </>
          )}
        </pre>
      </div>

      {/* 这一行只是参数，得告诉人接在哪：可执行文件名与 macos/MovieClawTranscoder
          的 Package.swift / Info.plist 一致 */}
      {headless && (
        <p className="text-caption leading-relaxed text-[var(--text-faint)]">
          接在{" "}
          <code className="font-mono text-[var(--text-muted)]">movieclaw-transcoder --headless</code>{" "}
          后面即可，--worker-id、--ffmpeg 等其余参数照常。
        </p>
      )}

      {address.configured ? (
        <p className="text-caption leading-relaxed text-[var(--text-faint)]">
          地址取自「设置 → 网络与维护」里填写的对外访问地址。
        </p>
      ) : (
        /* 没配对外地址时给的是浏览器地址栏那个值——它未必是目标机器连得到的地址。
           直接给一个可能不通的值，用户只会看到 mclaw 连接超时而查不到原因，
           所以这里说破，并指向真正的修法。 */
        <div className="flex gap-2.5 rounded-xl border border-[var(--warn)]/28 bg-[var(--warn)]/[0.09] px-3.5 py-3">
          <InfoIcon className="mt-0.5 size-4 shrink-0 text-[var(--warn)]" />
          <p className="text-sub leading-relaxed text-[var(--text-muted)]">
            上面这行地址取自你现在浏览器的地址栏，只是猜测——目标机器不一定连得到。
            请到「设置 → 网络与维护」填写对外访问地址，之后这里会直接给出正确的一行。
          </p>
        </div>
      )}

      <div className="flex flex-wrap items-center justify-between gap-3">
        <CopyButton
          text={token}
          label="仅复制令牌"
          className="btn-glass px-3.5 py-2 text-sub font-medium text-[var(--text-muted)]"
        />
        <button
          type="button"
          onClick={onDismiss}
          className="btn-accent rounded-full px-4.5 py-2 text-sub font-semibold"
        >
          我已保存，关闭
        </button>
      </div>
    </div>
  );
}
