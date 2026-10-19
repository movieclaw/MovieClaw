"use client";

/**
 * 「设置 → 网盘」分区（docs/design/cloud-storage.md §2、§11.7；样稿 mockups/cloud-storage-demo.html）。
 *
 * 只回答「我接了哪些网盘账号、它们好不好」：一张账号卡片列表 +「添加网盘账号」。网盘来自存储插件，
 * 卡片与登录弹窗都按接口返回的声明渲染，不认识具体网盘。只有装了存储插件、或者已经有网盘账号时，
 * 设置侧栏才出现这个分区（插件卸载后仍能看到账号与「需要安装插件」的提示）。
 *
 * 常用的只有「同时播放数」，放在卡片上；请求速率、每日预算收进「高级」，默认值够用。
 */

import { useCallback, useEffect, useState } from "react";

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";

import type { Route } from "next";
import Link from "next/link";

import { ErrorBanner, LINK_CLASS, StatusPill, Toggle } from "@/components/cloud-push-ui";
import { DriveLoginDialog } from "@/components/drive-login-dialog";
import { useConfirm, usePrompt, useToast } from "@/components/feedback";
import { CloudDriveIcon, PlusIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsEmpty,
  SettingsList,
  SettingsMoreMenu,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type DriveAccount,
  type DriveAccountUpdate,
  type DriveBackend,
  type DriveSettings,
  deleteDriveAccount,
  getDriveSettings,
  listDriveAccounts,
  listDriveBackends,
  refreshDriveAccount,
  updateDriveAccount,
  updateDriveSettings,
} from "@/lib/api/drives";
import type { Tone } from "@/lib/cloud-push-display";
import { formatBytes } from "@/lib/format";
import { formatRelativeTime } from "@/lib/time";

export function DrivesSection() {
  const confirm = useConfirm();
  const toast = useToast();
  const [backends, setBackends] = useState<DriveBackend[]>([]);
  const [accounts, setAccounts] = useState<DriveAccount[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  // 正在登录的网盘（null = 没开弹窗）
  const [login, setLogin] = useState<{ backend: DriveBackend; relogin?: DriveAccount } | null>(
    null,
  );

  const load = useCallback(async () => {
    setError(null);
    try {
      const [b, a] = await Promise.all([listDriveBackends(), listDriveAccounts()]);
      setBackends(b);
      setAccounts(a);
    } catch (e) {
      setError((e as Error).message);
      setAccounts([]);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const byType = new Map(backends.map((b) => [b.type, b]));

  function replace(next: DriveAccount) {
    setAccounts((rows) => rows?.map((r) => (r.id === next.id ? next : r)) ?? rows);
  }

  async function handleRemove(account: DriveAccount) {
    if (
      !(await confirm({
        title: `移除网盘账号「${account.name}」？`,
        description:
          "只删除 MovieClaw 里的账号记录，不会动网盘上的任何文件。用到这个账号的媒体库需要重新选择账号。",
        confirmLabel: "移除",
        tone: "danger",
      }))
    )
      return;
    try {
      await deleteDriveAccount(account.id);
      setAccounts((rows) => rows?.filter((r) => r.id !== account.id) ?? rows);
      toast.success(`已移除「${account.name}」`);
    } catch (e) {
      toast.error((e as Error).message);
    }
  }

  async function handleRefresh(account: DriveAccount) {
    try {
      replace(await refreshDriveAccount(account.id));
    } catch (e) {
      toast.error((e as Error).message);
      void load();
    }
  }

  const loading = accounts == null;

  return (
    <div className="space-y-10">
      <div className="space-y-4">
        <p className="text-sub leading-6 text-[var(--text-muted)]">
          媒体库可以放在网盘上：网盘里已有的片子直接看，新片下载后自动上传、本地自动腾空。网盘由插件提供，在
          <Link href={"/settings/plugins" as Route} className={`mx-1 ${LINK_CLASS}`}>
            设置 → 插件
          </Link>
          里安装。
        </p>
        {error && <ErrorBanner>{error}</ErrorBanner>}
      </div>

      <SettingsSection
        title="账号"
        description={
          loading ? "加载中…" : accounts.length > 0 ? `已登录 ${accounts.length} 个账号` : undefined
        }
        action={
          backends.length > 0 && (
            <AddAccountButton
              backends={backends}
              onPick={(backend) => setLogin({ backend })}
              disabled={loading}
            />
          )
        }
      >
        {loading ? (
          <div className="space-y-2.5">
            <div className="h-[132px] animate-pulse rounded-xl bg-white/[0.04]" />
          </div>
        ) : accounts.length === 0 ? (
          <SettingsEmpty
            icon={<CloudDriveIcon className="size-5" />}
            title="还没有网盘账号"
            description={
              backends.length === 0
                ? "没有可用的网盘：先到「设置 → 插件」安装网盘存储插件。"
                : `点「添加网盘账号」登录，支持${backends.map((b) => b.title).join("、")}。`
            }
          />
        ) : (
          <div className="space-y-3">
            {accounts.map((account) => (
              <AccountCard
                key={account.id}
                account={account}
                backend={byType.get(account.backend)}
                onChange={replace}
                onRelogin={() => {
                  const b = byType.get(account.backend);
                  if (b) setLogin({ backend: b, relogin: account });
                }}
                onRefresh={() => void handleRefresh(account)}
                onRemove={() => void handleRemove(account)}
              />
            ))}
          </div>
        )}
      </SettingsSection>

      {!loading && accounts.length > 0 && <AfterReleaseSection />}

      {login && (
        <DriveLoginDialog
          backend={login.backend}
          relogin={login.relogin}
          onClose={() => setLogin(null)}
          onDone={(account, created) => {
            setLogin(null);
            void load();
            toast.success(
              created ? `已添加：${account.name}` : `已重新登录：${account.name}`,
            );
          }}
        />
      )}
    </div>
  );
}

/** 「添加网盘账号」：只有一种网盘时直接开弹窗，多种时下拉选。 */
function AddAccountButton({
  backends,
  onPick,
  disabled,
}: {
  backends: DriveBackend[];
  onPick: (backend: DriveBackend) => void;
  disabled: boolean;
}) {
  const className = `${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`;
  if (backends.length === 1) {
    return (
      <button type="button" disabled={disabled} onClick={() => onPick(backends[0])} className={className}>
        <PlusIcon className="size-4" />
        添加网盘账号
      </button>
    );
  }
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button type="button" disabled={disabled} className={className}>
          <PlusIcon className="size-4" />
          添加网盘账号
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          collisionPadding={12}
          className="menu-surface z-50 min-w-[14rem] p-1"
        >
          {backends.map((backend) => (
            <DropdownMenu.Item
              key={backend.type}
              onSelect={() => onPick(backend)}
              className="glass-row nav-item flex cursor-pointer items-center gap-2.5 px-3 py-2 outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)] data-[highlighted]:!text-[var(--text)]"
            >
              <DriveMonogram title={backend.title} color={backend.accent_color} small />
              <span className="text-sub font-medium">{backend.title}</span>
            </DropdownMenu.Item>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/**
 * 网盘图标：主程序用名称生成字母方块，插件只能声明一个主题色（不支持插件带图片，§11.7）。
 * 名称以数字开头（115、123）取整段数字，否则取首字。
 */
export function DriveMonogram({
  title,
  color,
  small = false,
}: {
  title: string;
  color: string;
  small?: boolean;
}) {
  const digits = /^\d+/.exec(title)?.[0];
  const text = digits ? digits.slice(0, 3) : title.slice(0, 1);
  const base = color || "#5b6b8c";
  return (
    <span
      aria-hidden
      className={`grid shrink-0 place-items-center font-extrabold tracking-tight text-white ${
        small ? "size-6 rounded-md text-[9px]" : "size-10 rounded-xl text-[12px]"
      }`}
      style={{ background: `linear-gradient(135deg, ${base}, color-mix(in srgb, ${base} 62%, white))` }}
    >
      {text}
    </span>
  );
}

function statusPill(account: DriveAccount): { tone: Tone; label: string } {
  if (!account.backend_available) return { tone: "neutral", label: "需要安装插件" };
  switch (account.status) {
    case "ok":
      return { tone: "ok", label: "正常" };
    case "auth_expired":
      return { tone: "danger", label: "要重新登录" };
    case "rate_limited":
      return { tone: "warn", label: "限流中" };
    case "api_broken":
      return { tone: "warn", label: "接口异常" };
    default:
      return { tone: "neutral", label: "已停用" };
  }
}

function AccountCard({
  account,
  backend,
  onChange,
  onRelogin,
  onRefresh,
  onRemove,
}: {
  account: DriveAccount;
  backend: DriveBackend | undefined;
  onChange: (next: DriveAccount) => void;
  onRelogin: () => void;
  onRefresh: () => void;
  onRemove: () => void;
}) {
  const toast = useToast();
  const prompt = usePrompt();
  const [advanced, setAdvanced] = useState(false);
  const pill = statusPill(account);
  const how = `${
    account.login_method === "cookie"
      ? "浏览器导入"
      : account.login_method === "form"
        ? "填写凭据"
        : "扫码登录"
  }${account.login_detail ? ` · ${account.login_detail}` : ""}`;
  const quota =
    account.quota_total && account.quota_total > 0
      ? {
          text: `${formatBytes(account.quota_used ?? 0)} / ${formatBytes(account.quota_total)}`,
          ratio: Math.min(1, (account.quota_used ?? 0) / account.quota_total),
        }
      : null;

  async function save(patch: DriveAccountUpdate, done?: string) {
    try {
      onChange(await updateDriveAccount(account.id, patch));
      if (done) toast.success(done);
    } catch (e) {
      toast.error((e as Error).message);
    }
  }

  const problem = !account.backend_available
    ? `提供「${account.backend_title}」的存储插件没在运行：到「设置 → 插件」安装或启用，账号与设置都保留。`
    : account.status === "auth_expired"
      ? (account.status_message ?? "登录已失效") +
        (account.login_method === "cookie"
          ? "。网页端登录与浏览器共用，在没装扩展的电脑上登录网页版会让它失效；改为扫码登录更稳定。"
          : "。播放与上传暂停中，重新登录后自动继续。")
      : account.status === "rate_limited"
        ? `${account.status_message ?? "被网盘限流"}${
            account.status_until ? `，后台任务暂停到 ${formatRelativeTime(account.status_until)}` : ""
          }；播放照常尝试。`
        : account.status === "api_broken"
          ? `${account.status_message ?? "网盘接口有变化"}。已有的片子仍可尝试播放；上传与同步暂停。`
          : null;

  return (
    <div className="css-glass !rounded-xl" data-testid={`drive-account-${account.id}`}>
      <div className="flex items-center gap-3 px-4 py-3.5">
        <DriveMonogram title={account.backend_title} color={account.accent_color} />
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span className="truncate text-body font-semibold text-[var(--text)]">{account.name}</span>
            <StatusPill tone={pill.tone} label={pill.label} />
            {account.vip && <span className="text-caption text-[var(--text-faint)]">{account.vip}</span>}
          </div>
          <div className="mt-0.5 truncate text-caption text-[var(--text-faint)]">
            {account.backend_title} · {how}
          </div>
        </div>
        {quota && (
          <div className="w-44 shrink-0 max-md:hidden">
            <div className="flex justify-between text-caption text-[var(--text-muted)]">
              <span>容量</span>
              <span className="tabular-nums">{quota.text}</span>
            </div>
            <div className="mt-1 h-1.5 overflow-hidden rounded-full bg-white/[0.08]">
              <div
                className="h-full rounded-full bg-[var(--accent-2,#9fb0c9)]"
                style={{ width: `${Math.round(quota.ratio * 100)}%` }}
              />
            </div>
          </div>
        )}
        <div className="flex shrink-0 items-center gap-2">
          {(account.status === "auth_expired" || account.status === "disabled") &&
            account.backend_available && (
              <button type="button" onClick={onRelogin} className={SETTINGS_PRIMARY_BUTTON_CLASS}>
                重新登录
              </button>
            )}
          <SettingsMoreMenu
            label={`「${account.name}」的更多操作`}
            items={[
              { label: "刷新容量", onSelect: onRefresh, disabled: !account.backend_available },
              {
                label: !backend?.login.scan
                  ? "重新登录"
                  : account.login_method === "cookie"
                    ? "改为扫码登录"
                    : account.login_method === "form"
                      ? "重新登录"
                      : "重新扫码登录",
                onSelect: onRelogin,
                disabled:
                  !account.backend_available ||
                  !(backend?.login.scan || backend?.login.form || backend?.login.cookie),
              },
              {
                label: "改名",
                onSelect: () =>
                  void prompt({ title: "账号名", initialValue: account.name }).then((name) => {
                    if (name != null && name.trim() && name.trim() !== account.name) {
                      void save({ name: name.trim() }, "已改名");
                    }
                  }),
              },
              { label: "移除账号", onSelect: onRemove, danger: true },
            ]}
          />
        </div>
      </div>

      {problem && (
        <div className="border-t border-[var(--line)] px-4 py-2.5 text-caption leading-5 text-[var(--text-muted)]">
          {problem}
        </div>
      )}

      <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 border-t border-[var(--line)] px-4 py-2.5">
        <ReadSlots account={account} onSave={(n) => save({ read_slots: n }, "已保存")} />
        <div className="flex items-center gap-3 text-caption text-[var(--text-faint)]">
          <span className="tabular-nums">
            今日调用 {account.used_today.toLocaleString()} / {account.daily_budget.toLocaleString()}
          </span>
          <button
            type="button"
            onClick={() => setAdvanced((v) => !v)}
            aria-expanded={advanced}
            className="text-[var(--text-muted)] underline-offset-4 hover:text-[var(--text)] hover:underline"
          >
            高级{advanced ? " ▴" : " ▾"}
          </button>
        </div>
      </div>

      {advanced && <AdvancedLimits account={account} onSave={save} />}
    </div>
  );
}

/** 同时播放数：家里转发时，网盘同一时间最多开几路连接（1～10）。 */
function ReadSlots({
  account,
  onSave,
}: {
  account: DriveAccount;
  onSave: (value: number) => Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState(String(account.read_slots));
  const n = Number(value);
  const valid = Number.isInteger(n) && n >= 1 && n <= 10;
  if (!editing) {
    return (
      <div className="flex items-center gap-2 text-caption text-[var(--text-muted)]">
        <span>
          同时播放数 <b className="font-semibold text-[var(--text)]">{account.read_slots}</b>
        </span>
        <span className="text-[var(--text-faint)] max-md:hidden">· 家里转发时网盘同一时间最多开几路连接</span>
        <button
          type="button"
          onClick={() => {
            setValue(String(account.read_slots));
            setEditing(true);
          }}
          className={`${SETTINGS_BUTTON_CLASS} !py-0.5`}
        >
          调整
        </button>
      </div>
    );
  }
  return (
    <div className="flex items-center gap-2 text-caption text-[var(--text-muted)]">
      <span>同时播放数</span>
      <input
        aria-label="同时播放数"
        type="number"
        min={1}
        max={10}
        value={value}
        onChange={(e) => setValue(e.target.value)}
        className={`${SETTINGS_INPUT_CLASS} w-16 !py-0.5`}
      />
      <button
        type="button"
        disabled={!valid}
        onClick={() => void onSave(n).then(() => setEditing(false))}
        className={`${SETTINGS_PRIMARY_BUTTON_CLASS} !py-0.5`}
      >
        保存
      </button>
      <button type="button" onClick={() => setEditing(false)} className={`${SETTINGS_BUTTON_CLASS} !py-0.5`}>
        取消
      </button>
      {!valid && <span className="text-[var(--danger)]">1～10</span>}
    </div>
  );
}

/** 高级：请求速率、每日预算（都可以回到插件默认值）。 */
function AdvancedLimits({
  account,
  onSave,
}: {
  account: DriveAccount;
  onSave: (patch: DriveAccountUpdate, done?: string) => Promise<void>;
}) {
  const [qps, setQps] = useState(String(account.qps));
  const [budget, setBudget] = useState(String(account.daily_budget));
  const qpsN = Number(qps);
  const budgetN = Number(budget);
  // 只校验用户改过的项：插件声明的默认值可能在用户可设范围之外（如更宽的速率）
  const qpsDirty = qpsN !== account.qps;
  const budgetDirty = budgetN !== account.daily_budget;
  const qpsValid = !qpsDirty || (Number.isFinite(qpsN) && qpsN >= 0.1 && qpsN <= 20);
  const budgetValid =
    !budgetDirty || (Number.isInteger(budgetN) && budgetN >= 100 && budgetN <= 1_000_000);
  const dirty = qpsDirty || budgetDirty;
  return (
    <div className="space-y-3 border-t border-[var(--line)] px-4 py-3 text-caption text-[var(--text-muted)]">
      <label className="flex flex-wrap items-center gap-2">
        <span className="w-20">请求速率</span>
        <input
          type="number"
          step={0.1}
          value={qps}
          onChange={(e) => setQps(e.target.value)}
          className={`${SETTINGS_INPUT_CLASS} w-20 !py-0.5`}
        />
        <span>次 / 秒{account.qps_custom ? "" : "（插件默认）"}</span>
        {account.qps_custom && (
          <button
            type="button"
            onClick={() => void onSave({ reset: ["qps"] }, "已恢复默认")}
            className="underline-offset-4 hover:underline"
          >
            恢复默认
          </button>
        )}
      </label>
      <label className="flex flex-wrap items-center gap-2">
        <span className="w-20">每日预算</span>
        <input
          type="number"
          step={100}
          value={budget}
          onChange={(e) => setBudget(e.target.value)}
          className={`${SETTINGS_INPUT_CLASS} w-24 !py-0.5`}
        />
        <span>次 · 后台任务用到 70% 就暂停，余量留给播放{account.daily_budget_custom ? "" : "（插件默认）"}</span>
        {account.daily_budget_custom && (
          <button
            type="button"
            onClick={() => void onSave({ reset: ["daily_budget"] }, "已恢复默认")}
            className="underline-offset-4 hover:underline"
          >
            恢复默认
          </button>
        )}
      </label>
      <div className="flex items-center gap-2">
        <button
          type="button"
          disabled={!dirty || !qpsValid || !budgetValid}
          onClick={() =>
            void onSave(
              {
                ...(qpsDirty ? { qps: qpsN } : {}),
                ...(budgetDirty ? { daily_budget: budgetN } : {}),
              },
              "已保存",
            )
          }
          className={`${SETTINGS_PRIMARY_BUTTON_CLASS} !py-0.5`}
        >
          保存
        </button>
        {(!qpsValid || !budgetValid) && (
          <span className="text-[var(--danger)]">
            {!qpsValid ? "请求速率要在 0.1～20 之间" : "每日预算要在 100～1,000,000 之间"}
          </span>
        )}
      </div>
      <p className="text-[var(--text-faint)]">移除账号只删 MovieClaw 里的记录，不动网盘上的任何文件。</p>
    </div>
  );
}

/** 文件传到网盘、本地腾空之后的事（cloud-storage.md §6.3）：点选即存、失败回滚。 */
function AfterReleaseSection() {
  const toast = useToast();
  const [settings, setSettings] = useState<DriveSettings | null>(null);

  useEffect(() => {
    void getDriveSettings()
      .then(setSettings)
      .catch(() => {
        /* 老服务器没有这个接口：不显示 */
      });
  }, []);

  if (settings == null) return null;

  async function change(next: boolean) {
    const previous = settings;
    setSettings({ ...settings!, remove_download_tasks: next });
    try {
      setSettings(await updateDriveSettings({ remove_download_tasks: next }));
    } catch (e) {
      setSettings(previous);
      toast.error((e as Error).message);
    }
  }

  return (
    <SettingsSection title="上传到网盘之后">
      <SettingsList>
        <SettingsRow
          label="本地腾空后删除下载任务"
          description="主根在网盘的库，文件传上去、本地腾空后，把下载器里对应的任务连同下载目录里的数据一起删掉，空间才真正回来（硬链接入库时尤其如此）。有 H&R 考核的、不是 MovieClaw 投递的、还供着库里别的本地文件的种子都保留。"
        >
          <Toggle
            checked={settings.remove_download_tasks}
            label="本地腾空后删除下载任务"
            onChange={(next) => void change(next)}
          />
        </SettingsRow>
      </SettingsList>
    </SettingsSection>
  );
}
