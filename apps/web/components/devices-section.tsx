"use client";

import { type ReactNode, useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import Link from "next/link";
import type { Route } from "next";

import { CopyButton } from "@/components/copy-button";
import { useConfirm, usePrompt, useToast } from "@/components/feedback";
import {
  BellIcon,
  CheckIcon,
  ChevronRightIcon,
  ClockIcon,
  DeviceIcon,
  GlobeIcon,
  InfoIcon,
  PhoneIcon,
  PlayIcon,
  PlusIcon,
  ServerIcon,
  RefreshIcon,
  TerminalIcon,
  TvIcon,
} from "@/components/icons";
import { ErrorBanner } from "@/components/cloud-push-ui";
import { Modal } from "@/components/modal";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_DANGER_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsCard,
  SettingsList,
  SettingsMoreMenu,
  SettingsSection,
  SettingsTabs,
} from "@/components/settings-ui";
import { reloadAfterAccountChange } from "@/lib/account-reload";
import { getAppConfig } from "@/lib/api/app";
import { logout } from "@/lib/api/auth";
import {
  type DeviceCleanupItem,
  type LoginDeviceView,
  cleanupLoginDevices,
  createDeviceToken,
  listLoginDevices,
  renameLoginDevice,
  revokeLoginDevice,
} from "@/lib/api/devices";
import {
  CLEANUP_DAY_OPTIONS,
  DEFAULT_CLEANUP_DAYS,
  type DeviceGlyph,
  type DeviceGroup,
  STALE_AFTER_DAYS,
  deviceGlyph,
  envSnippet,
  grantBadge,
  groupDevices,
  headlessArgs,
  identityParts,
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
import { useTabParam } from "@/lib/use-tab-param";

/** 视图页签（?tab=all 直达「全部成员」）；成员只有自己的视图 */
const ADMIN_SCOPES = ["mine", "all"] as const;
const MEMBER_SCOPES = ["mine"] as const;

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
  const [scope, setScope] = useTabParam(isAdmin ? ADMIN_SCOPES : MEMBER_SCOPES, "mine");
  const [devices, setDevices] = useState<LoginDeviceView[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [cleaning, setCleaning] = useState(false);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [drawerGroup, setDrawerGroup] = useState("browser");
  const requestId = useRef(0);
  // 写操作后递增它来重拉列表；拉取放在 effect 里并丢弃过期响应——快速来回切
  // 「只看我的 / 全部成员」时，晚到的旧响应不能盖掉新视图
  const [reloadTick, setReloadTick] = useState(0);
  const reload = useCallback(() => setReloadTick((tick) => tick + 1), []);

  const refreshDevices = useCallback(async () => {
    const id = ++requestId.current;
    setLoadError(null);
    try {
      const next = await listLoginDevices(scope === "all");
      if (id === requestId.current) setDevices(next);
    } catch (e) {
      if (id === requestId.current) setLoadError((e as Error).message);
    }
  }, [scope]);

  useEffect(() => {
    void refreshDevices();
    return () => {
      requestId.current += 1;
    };
  }, [refreshDevices, reloadTick]);

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

  const changeScope = (next: "mine" | "all") => {
    if (next === scope) return;
    setDrawerOpen(false);
    setDevices(null);
    setScope(next);
  };

  return (
    <div className="space-y-10">
      {/* 批准新设备在独立的 /activate 页（components/device-approval.tsx）；这里只留入口，
          来设备页找「批准」的人不至于扑空 */}
      <SettingsList>
        <Link
          href={"/activate" as Route}
          className="group flex min-h-[56px] items-center gap-4 px-4 py-3 transition-colors hover:bg-white/[0.04]"
        >
          <span className="icon-chip size-9 !rounded-xl">
            <DeviceIcon className="size-[18px]" />
          </span>
          <span className="min-w-0 flex-1">
            <span className="block text-body font-medium text-[var(--text)]">批准新设备登录</span>
            <span className="mt-0.5 block text-caption leading-5 text-[var(--text-faint)]">
              Apple TV、Mac、命令行或转码器显示配对码后，到批准页输入
            </span>
          </span>
          <ChevronRightIcon className="size-4 shrink-0 text-[var(--text-faint)] transition-transform group-hover:translate-x-0.5" />
        </Link>
      </SettingsList>

      <div className="space-y-6">
        {/* 超管专属：只看我的 / 全部成员（all=true 时每台设备带主人） */}
        {isAdmin && (
          <SettingsTabs
            tabs={[
              { id: "mine", label: "只看我的" },
              { id: "all", label: "全部成员" },
            ]}
            value={scope}
            onChange={changeScope}
          />
        )}
        <p className="px-1 text-sub leading-5 text-[var(--text-muted)]">
          按类型列出当前在线的设备，每类最多 5 台；「查看全部」包含在线和离线记录。
        </p>

        {loadError ? (
          <ErrorBanner>{loadError}</ErrorBanner>
        ) : devices === null ? (
          <div className="h-[104px] animate-pulse rounded-xl bg-white/[0.04]" />
        ) : (
          <div className="space-y-10" aria-label="当前在线设备摘要">
            {groups.map((group) => {
              const online = group.devices.filter((device) => deviceLive(device));
              return (
                <SettingsSection
                  key={group.key}
                  title={group.label}
                  description={
                    group.devices.length > 0
                      ? `${online.length} 在线 · 共 ${group.devices.length} 条记录`
                      : "暂无设备记录，登录或配对后会显示在这里"
                  }
                  action={
                    group.devices.length > 0 && (
                      <button
                        type="button"
                        aria-label={`查看全部${group.label}设备`}
                        onClick={() => {
                          setDrawerGroup(group.key);
                          setDrawerOpen(true);
                        }}
                        className={SETTINGS_BUTTON_CLASS}
                      >
                        查看全部
                      </button>
                    )
                  }
                >
                  {group.devices.length > 0 && (
                    <SettingsList>
                      {online.slice(0, 5).map((device) => (
                        <DeviceRow
                          key={device.id}
                          device={device}
                          compact
                          showOwner={scope === "all"}
                          busy={busy === device.id}
                          onRename={() => void handleRename(device)}
                          onRevoke={() => void handleRevoke(device)}
                        />
                      ))}
                      {online.length === 0 && (
                        <p className="px-4 py-4 text-sub text-[var(--text-faint)]">
                          暂无在线设备，离线记录在「查看全部」里
                        </p>
                      )}
                    </SettingsList>
                  )}
                </SettingsSection>
              );
            })}
          </div>
        )}
      </div>

      <DevicesDrawer key={scope} open={drawerOpen} groupKey={drawerGroup} groups={groups} showOwner={scope === "all"} busy={busy}
        error={loadError} onClose={() => setDrawerOpen(false)} onGroupChange={setDrawerGroup} onRefresh={refreshDevices}
        onRename={handleRename} onRevoke={handleRevoke} />

      {isAdmin && <ManualTokenSection onCreated={reload} />}

      <SettingsSection title="危险操作">
        <SettingsCard
          tone="danger"
          title={scope === "all" ? "清理全部成员长期没用的设备" : "清理长期没用的设备"}
          description="一次注销一段时间没用过的设备，被注销的要重新登录或配对才能再用。正在用的这台、连着的转码器不会被清理。"
          action={
            <button
              type="button"
              onClick={() => setCleaning(true)}
              disabled={!devices?.some((device) => !device.current)}
              className={SETTINGS_DANGER_BUTTON_CLASS}
            >
              清理…
            </button>
          }
        />
      </SettingsSection>
      {cleaning && (
        <CleanupDialog all={scope === "all"} onClose={() => setCleaning(false)} onCleaned={reload} />
      )}
    </div>
  );
}

/** 全部记录在抽屉内按批显示；关闭与切换分类都保留各自的浏览位置。 */
function DevicesDrawer({
  open, groupKey, groups, showOwner, busy, error, onClose, onGroupChange, onRefresh, onRename, onRevoke,
}: {
  open: boolean;
  groupKey: string;
  groups: DeviceGroup<LoginDeviceView>[];
  showOwner: boolean;
  busy: string | null;
  error: string | null;
  onClose: () => void;
  onGroupChange: (key: string) => void;
  onRefresh: () => Promise<void>;
  onRename: (device: LoginDeviceView) => Promise<void>;
  onRevoke: (device: LoginDeviceView) => Promise<void>;
}) {
  const [limits, setLimits] = useState<Record<string, number>>({});
  const [refreshing, setRefreshing] = useState(false);
  const [pull, setPull] = useState(0);
  const positions = useRef<Record<string, number>>({});
  const panel = useRef<HTMLElement>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const sentinel = useRef<HTMLDivElement>(null);
  const group = groups.find((item) => item.key === groupKey);
  const online = group?.devices.filter((device) => deviceLive(device)) ?? [];
  const offline = group?.devices.filter((device) => !deviceLive(device)) ?? [];
  const ordered = [...online, ...offline];
  const limit = limits[groupKey] ?? 20;
  const visible = ordered.slice(0, limit);
  const refresh = useCallback(async () => {
    setRefreshing(true);
    try { await onRefresh(); } finally { setRefreshing(false); setPull(0); }
  }, [onRefresh]);

  useLayoutEffect(() => {
    if (open && scroller.current) scroller.current.scrollTop = positions.current[groupKey] ?? 0;
  }, [open, groupKey]);

  useEffect(() => {
    if (!open) return;
    const trigger = document.activeElement as HTMLElement | null;
    const overflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const frame = requestAnimationFrame(() => panel.current?.querySelector<HTMLButtonElement>("button")?.focus());
    return () => {
      cancelAnimationFrame(frame);
      document.body.style.overflow = overflow;
      trigger?.focus({ preventScroll: true });
    };
  }, [open]);

  useEffect(() => {
    if (!open || !sentinel.current || !scroller.current || limit >= ordered.length) return;
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        setLimits((previous) => ({ ...previous, [groupKey]: (previous[groupKey] ?? 20) + 20 }));
      }
    }, { root: scroller.current, rootMargin: "0px 0px 150px 0px" });
    observer.observe(sentinel.current);
    return () => observer.disconnect();
  }, [open, groupKey, limit, ordered.length]);

  useEffect(() => {
    const element = scroller.current;
    if (!open || !element) return;
    let start: number | null = null;
    let distance = 0;
    const reset = () => { start = null; distance = 0; setPull(0); };
    const begin = (event: TouchEvent) => {
      start = element.scrollTop <= 0 && !refreshing ? event.touches[0].clientY : null;
    };
    const move = (event: TouchEvent) => {
      if (start === null) return;
      distance = Math.min(100, Math.max(0, (event.touches[0].clientY - start) / 2));
      if (distance > 0) { event.preventDefault(); setPull(distance); }
    };
    const end = () => { const shouldRefresh = distance >= 55; reset(); if (shouldRefresh) void refresh(); };
    element.addEventListener("touchstart", begin, { passive: true });
    element.addEventListener("touchmove", move, { passive: false });
    element.addEventListener("touchend", end);
    element.addEventListener("touchcancel", reset);
    return () => {
      element.removeEventListener("touchstart", begin);
      element.removeEventListener("touchmove", move);
      element.removeEventListener("touchend", end);
      element.removeEventListener("touchcancel", reset);
    };
  }, [open, groupKey, refresh, refreshing]);

  return (
    <Modal open={open} onClose={onClose} label="全部设备列表" width="lg" placement="right"
      panelClassName="h-full !max-h-full !rounded-none max-md:h-[88dvh] max-md:!rounded-t-3xl">
      <section ref={panel} className="flex min-h-0 flex-1 flex-col" onKeyDown={(event) => {
        if (event.key !== "Tab" || !event.currentTarget.contains(event.target as Node)) return;
        const buttons = [...event.currentTarget.querySelectorAll<HTMLButtonElement>("button:not(:disabled)")].filter((button) => button.getClientRects().length);
        const first = buttons[0], last = buttons[buttons.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
      }}>
        <div aria-hidden className="mx-auto mt-2 hidden h-1 w-9 shrink-0 rounded-full bg-white/20 max-md:block" />
        <header className="shrink-0 space-y-3 px-4 pb-3 pt-4">
          <div className="flex items-center justify-between gap-3">
            <div className="min-w-0"><h2 className="text-ui font-semibold text-[var(--text)]">{group?.label ?? "设备"}</h2>
              <p className="text-caption text-[var(--text-muted)]">{online.length} 在线 · 共 {ordered.length} 条记录</p></div>
            <div className="flex shrink-0 items-center gap-1">
              <button type="button" onClick={() => void refresh()} disabled={refreshing} aria-label="刷新设备列表" className="flex size-11 items-center justify-center rounded-full text-[var(--text-muted)] hover:bg-white/[0.07] disabled:opacity-40"><RefreshIcon className={`size-4 ${refreshing ? "animate-spin" : ""}`} /></button>
              <button type="button" onClick={onClose} className="min-h-11 px-2 text-sub text-[var(--accent)]">完成</button>
            </div>
          </div>
          <div role="tablist" aria-label="设备类型" className="grid grid-cols-4 gap-1 rounded-xl bg-white/[0.06] p-1">
            {groups.map((item) => <button key={item.key} type="button" role="tab" aria-selected={groupKey === item.key} aria-controls="devices-drawer-list"
              onClick={() => onGroupChange(item.key)}
              onKeyDown={(event) => {
                if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
                event.preventDefault();
                const index = groups.findIndex((candidate) => candidate.key === item.key);
                const next = (index + (event.key === "ArrowRight" ? 1 : groups.length - 1)) % groups.length;
                onGroupChange(groups[next].key);
                event.currentTarget.parentElement?.querySelectorAll<HTMLButtonElement>("button")[next]?.focus();
              }}
              className={`min-h-10 rounded-lg px-1 text-sub ${groupKey === item.key ? "bg-white/[0.14] text-[var(--text)]" : "text-[var(--text-muted)]"}`}>
              {item.key === "paired" ? "命令行" : item.label}</button>)}
          </div>
        </header>
        <div ref={scroller} id="devices-drawer-list" role="tabpanel" aria-label={`${group?.label ?? "设备"}记录`}
          onScroll={(event) => { positions.current[groupKey] = event.currentTarget.scrollTop; }}
          className="min-h-0 flex-1 overflow-y-auto overscroll-contain scroll-thin">
          {(pull > 0 || refreshing) && <p role="status" className="flex items-center justify-center text-caption text-[var(--text-muted)]" style={{ height: refreshing ? 44 : pull }}>{refreshing ? "正在刷新…" : pull >= 55 ? "松开刷新" : "下拉刷新"}</p>}
          {error && <p role="alert" className="px-4 py-3 text-sub text-[var(--danger)]">{error}</p>}
          {ordered.length === 0 && <p className="px-4 py-12 text-center text-sub text-[var(--text-muted)]">暂无设备记录，登录或配对后会显示在这里</p>}
          {visible.map((device, index) => <div key={device.id} data-device-id={device.id}>
            {(index === 0 || index === online.length) && <h3 className="px-5 pb-1 pt-4 text-caption text-[var(--text-faint)]">{deviceLive(device) ? "当前在线" : "离线 · 最近使用优先"}</h3>}
            <DeviceRow device={device} showOwner={showOwner} busy={busy === device.id} onRename={() => void onRename(device)} onRevoke={() => void onRevoke(device)} />
          </div>)}
          <div ref={sentinel} role="status" className="px-4 py-5 text-center text-caption text-[var(--text-faint)]">{ordered.length > visible.length ? "继续滚动，自动载入" : ordered.length ? "已显示全部记录" : ""}</div>
        </div>
        <footer className="flex shrink-0 justify-between gap-3 border-t border-white/[0.07] px-4 py-3 text-caption text-[var(--text-faint)]">
          <span>{visible.length} / {ordered.length} 条记录</span><span className="md:hidden">下拉刷新</span>
        </footer>
      </section>
    </Modal>
  );
}

/** 行首图标：形态一眼可辨；在线时右下角亮一个绿点（不在线不画，灰点只是噪音）。 */
const GLYPH_ICON: Record<
  DeviceGlyph,
  (props: { className?: string }) => ReactNode
> = {
  phone: PhoneIcon,
  tv: TvIcon,
  computer: DeviceIcon,
  browser: GlobeIcon,
  terminal: TerminalIcon,
  transcoder: ServerIcon,
  player: PlayIcon,
};

function DeviceBadge({ glyph, live }: { glyph: DeviceGlyph; live: boolean }) {
  const Icon = GLYPH_ICON[glyph];
  return (
    <span className="relative flex size-10 shrink-0 items-center justify-center rounded-xl bg-white/[0.06] text-[var(--text-muted)] max-sm:size-9">
      <Icon className="size-[18px]" />
      {live && (
        <span
          role="img"
          aria-label="在线"
          className="absolute -bottom-0.5 -right-0.5 size-2.5 rounded-full bg-[var(--ok,#4ade80)] shadow-[0_0_0_2px_rgba(14,15,18,0.95),0_0_8px_rgba(74,222,128,0.55)]"
        />
      )}
    </span>
  );
}

/**
 * 一行说明：每段是一个不折断的整块，窄屏只在块与块之间换行。分隔点画在每块左边，
 * 整行左移一个点的宽度再裁掉——每一行行首那个点正好落在裁掉的区域里，不会出现
 * 「· 2026/10/05」这种以点开头的行。
 */
function MetaLine({ parts }: { parts: string[] }) {
  if (parts.length === 0) return null;
  return (
    <p className="mt-0.5 overflow-hidden text-caption text-[var(--text-faint)]">
      <span className="-ml-3 flex flex-wrap">
        {parts.map((part, index) => (
          <span
            key={index}
            className="relative whitespace-nowrap pl-3 before:absolute before:left-0 before:w-3 before:text-center before:content-['·']"
          >
            {part}
          </span>
        ))}
      </span>
    </p>
  );
}

/** 行内提示（长期没用、收不到通知）：小图标 + 一句话，与说明文字同一列对齐。 */
function RowNote({
  icon: Icon,
  color,
  children,
}: {
  icon: (props: { className?: string }) => ReactNode;
  color: string;
  children: ReactNode;
}) {
  return (
    <p
      className="mt-1.5 flex items-start gap-1.5 text-caption"
      style={{ color }}
    >
      <Icon className="mt-[3px] size-3 shrink-0" />
      <span className="min-w-0">{children}</span>
    </p>
  );
}

/**
 * 设备列表的一行：图标（带在线点）+ 名字（当前设备 / 权限标注）+ 系统与版本 +
 * 最近活跃、来源与签发时间 + 提示，操作收在右上角的 ⋯ 菜单里——两颗按钮常驻
 * 会在手机上吃掉三成宽度，把说明挤成一字一行。
 */
function DeviceRow({
  device,
  showOwner,
  busy,
  onRename,
  onRevoke,
  compact = false,
}: {
  device: LoginDeviceView;
  /** 「全部成员」视图：写明这台设备是谁的 */
  showOwner: boolean;
  busy: boolean;
  onRename: () => void;
  onRevoke: () => void;
  compact?: boolean;
}) {
  const pushNote = devicePushNote(device.push);
  const activity = [
    device.current ? "正在使用" : activityLabel(device),
    device.last_seen_ip ? `来自 ${device.last_seen_ip}` : null,
    `${issuedVerb(device.kind, device.family)} ${formatDateTime(device.created_at)}`,
  ].filter((part): part is string => Boolean(part));

  return (
    <div className="flex items-start gap-3.5 px-4 py-3 max-sm:gap-3">
      <DeviceBadge
        glyph={deviceGlyph(device.kind, device.scope)}
        live={deviceLive(device)}
      />
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <p className="min-w-0 break-words text-body font-medium text-[var(--text)]">
            {device.name}
          </p>
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
            属于{" "}
            {device.owner_id === 0
              ? "我"
              : `${device.owner_nickname}（@${device.owner_username}）`}
          </p>
        )}
        <MetaLine parts={identityParts(device)} />
        {!compact && <MetaLine parts={activity} />}
        {!compact && isStale(device.last_seen_at, device.created_at) && (
          <RowNote icon={ClockIcon} color="var(--warn)">
            已超过 {STALE_AFTER_DAYS}{" "}
            天没有活跃（不会自动失效），不再使用的话建议注销。
          </RowNote>
        )}
        {/* App 收不到通知时写一行原因；能收到就什么都不写（docs/design/cloud-push.md §8） */}
        {!compact && pushNote && (
          <RowNote
            icon={BellIcon}
            color={
              pushNote.tone === "neutral"
                ? "var(--text-faint)"
                : TONE_COLOR[pushNote.tone]
            }
          >
            {pushNote.text}
          </RowNote>
        )}
      </div>
      <SettingsMoreMenu
        label={`管理「${device.name}」`}
        disabled={busy}
        items={[
          ...(device.renamable ? [{ label: "改名…", onSelect: onRename }] : []),
          {
            label: device.current ? "注销并退出登录…" : "注销…",
            onSelect: onRevoke,
            danger: true,
          },
        ]}
      />
    </div>
  );
}

/**
 * 「清理长期没用的设备」：选多少天没用过，先让服务端列出会注销哪几台（dry_run），
 * 看清了再一次注销。清理就是注销——被清掉的要重新登录或配对，所以名单必须摆在
 * 确认按钮上面。本机与此刻连着的转码器服务端永远不清。
 */
function CleanupDialog({
  all,
  onClose,
  onCleaned,
}: {
  /** 超管在「全部成员」视图里打开：清的是所有人的设备 */
  all: boolean;
  onClose: () => void;
  onCleaned: () => void;
}) {
  const toast = useToast();
  const [days, setDays] = useState<number>(DEFAULT_CLEANUP_DAYS);
  const [preview, setPreview] = useState<DeviceCleanupItem[] | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    setPreview(null);
    setPreviewError(null);
    cleanupLoginDevices(days, { all, dryRun: true }).then(
      ({ devices }) => alive && setPreview(devices),
      (e: Error) => alive && setPreviewError(e.message),
    );
    return () => {
      alive = false;
    };
  }, [days, all]);

  const submit = () => {
    if (!preview?.length || busy) return;
    setBusy(true);
    cleanupLoginDevices(days, { all })
      .then(({ message }) => {
        toast.success(message);
        onCleaned();
        onClose();
      })
      .catch((e: Error) => toast.error(e.message))
      .finally(() => setBusy(false));
  };

  return (
    <Modal open onClose={onClose} label="清理长期没用的设备">
      <div className="p-6 max-md:p-5">
        <h2 className="text-title-sm font-bold text-white">
          {all ? "清理全部成员长期没用的设备" : "清理长期没用的设备"}
        </h2>
        <p className="mt-2 text-sub leading-6 text-[var(--text-muted)]">
          一次注销一段时间没用过的设备，被注销的要重新登录或配对才能再用。正在用的这台、连着的转码器不会被清理。
        </p>
        <div
          role="radiogroup"
          aria-label="多久没用过"
          className="mt-4 flex flex-wrap gap-1.5"
        >
          {CLEANUP_DAY_OPTIONS.map((option) => (
            <button
              key={option}
              type="button"
              role="radio"
              aria-checked={option === days}
              onClick={() => setDays(option)}
              className={`rounded-full px-3.5 py-1.5 text-sub font-medium transition-colors ${
                option === days
                  ? "bg-white/[0.14] text-white"
                  : "text-[var(--text-muted)] hover:bg-white/[0.07] hover:text-[var(--text)]"
              }`}
            >
              {option} 天没用过
            </button>
          ))}
        </div>
        <div className="mt-4 max-h-60 overflow-y-auto rounded-xl border border-white/[0.07] bg-white/[0.03] px-4 py-3">
          {previewError ? (
            <p className="text-sub text-[var(--danger)]">{previewError}</p>
          ) : preview === null ? (
            <p className="text-sub text-[var(--text-faint)]">正在查找…</p>
          ) : preview.length === 0 ? (
            <p className="text-sub text-[var(--text-muted)]">
              没有超过 {days} 天没用过的设备。
            </p>
          ) : (
            <>
              <p className="text-caption text-[var(--text-faint)]">
                将注销 {preview.length} 台：
              </p>
              <ul className="mt-1.5 space-y-1">
                {preview.map((item) => (
                  <li
                    key={item.id}
                    className="flex items-baseline justify-between gap-3 text-sub"
                  >
                    <span className="min-w-0 truncate text-[var(--text)]">
                      {item.name}
                    </span>
                    {all && (
                      <span className="shrink-0 text-caption text-[var(--text-faint)]">
                        {item.owner_nickname}
                      </span>
                    )}
                  </li>
                ))}
              </ul>
            </>
          )}
        </div>
        <div className="mt-5 flex justify-end gap-2.5">
          <button
            type="button"
            onClick={onClose}
            className={SETTINGS_BUTTON_CLASS}
          >
            取消
          </button>
          <button
            type="button"
            onClick={submit}
            disabled={!preview?.length || busy}
            className={SETTINGS_DANGER_BUTTON_CLASS}
          >
            {busy
              ? "注销中…"
              : preview?.length
                ? `注销 ${preview.length} 台`
                : "注销"}
          </button>
        </div>
      </div>
    </Modal>
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

  const code = (text: string) => (
    <code className="rounded bg-white/[0.06] px-1.5 py-0.5 font-mono text-[0.92em] text-[var(--text)]">
      {text}
    </code>
  );

  return (
    <SettingsSection
      title="手工创建令牌"
      description={
        <>
          没法在浏览器里按下批准的环境——NAS 上的定时任务、CI、无界面容器——在这里创建一枚令牌，用{" "}
          {code("MOVIECLAW_SERVER")} 和 {code("MOVIECLAW_TOKEN")}{" "}
          两个环境变量注入给 mclaw。能打开浏览器的机器请直接运行 mclaw login 配对，不必走这里。
          命令行模式（Headless）的转码器同样在这里创建，权限选「仅限转码」。
        </>
      }
      action={
        stage === "idle" &&
        !created && (
          <button
            type="button"
            onClick={() => setStage("form")}
            className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1`}
          >
            <PlusIcon className="size-4" />
            创建令牌
          </button>
        )
      }
    >
      {error && (
        <div className="mb-3">
          <ErrorBanner>{error}</ErrorBanner>
        </div>
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
        <SettingsCard
          title="新令牌"
          action={
            <div className="flex items-center gap-2">
              <button
                type="button"
                disabled={creating}
                onClick={resetForm}
                className={SETTINGS_BUTTON_CLASS}
              >
                取消
              </button>
              <button
                type="button"
                disabled={creating}
                onClick={() => void handleCreate()}
                className={SETTINGS_PRIMARY_BUTTON_CLASS}
              >
                {creating ? "创建中…" : "创建令牌"}
              </button>
            </div>
          }
        >
          <div className="space-y-4">
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
                className={`${SETTINGS_INPUT_CLASS} w-full`}
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
          </div>
        </SettingsCard>
      ) : null}
    </SettingsSection>
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
    <div className="css-glass space-y-4 !rounded-xl border-[var(--warn)]/35 p-5">
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
            className={SETTINGS_BUTTON_CLASS}
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
          className={SETTINGS_BUTTON_CLASS}
        />
        <button
          type="button"
          onClick={onDismiss}
          className={SETTINGS_PRIMARY_BUTTON_CLASS}
        >
          我已保存，关闭
        </button>
      </div>
    </div>
  );
}
