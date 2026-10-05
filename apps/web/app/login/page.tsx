"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import type { Route } from "next";

import { LockIcon, UserIcon, XIcon } from "@/components/icons";
import { CopyButton } from "@/components/copy-button";
import {
  WelcomeCard,
  WelcomeError,
  WelcomeField,
  WelcomeFields,
  WelcomeScreen,
  WelcomeSubmit,
} from "@/components/welcome-screen";
import { getBootstrapStatus, getSession, login } from "@/lib/api/auth";
import { reloadAfterAccountChange } from "@/lib/account-reload";
import { usePageTitle } from "@/lib/use-page-title";
import { HttpError } from "@/lib/http";
import { accessiblePathFor } from "@/lib/permissions";
import type { DemoAccount, DemoSite, SessionView } from "@/lib/api/auth";

/**
 * 登录成功 / 已登录后要跳回的目标地址：取自 ?next= 参数（会话过期时由 http.ts 写入）。
 * 只接受站内相对路径（以单个 / 开头），拒绝 //host、http(s):// 等外站地址，防开放重定向；
 * 缺失或非法时回落到首页。
 */
function resolveNext(session?: SessionView): string {
  if (typeof window === "undefined") return "/";
  // 公开演示站先落在媒体库：访客第一眼看到海报墙，AI 助手在侧栏里
  const home = session?.demo ? "/library" : "/";
  const raw = new URLSearchParams(window.location.search).get("next");
  if (!raw) return session ? accessiblePathFor(session, home) : "/";
  const next = decodeURIComponent(raw);
  if (next.startsWith("/") && !next.startsWith("//")) {
    return session ? accessiblePathFor(session, next) : next;
  }
  return session ? accessiblePathFor(session, home) : "/";
}

/** 是否处于"添加账号"形态（用户菜单里点「添加账号」带 ?add=1 进来）。 */
function isAddingAccount(): boolean {
  if (typeof window === "undefined") return false;
  return new URLSearchParams(window.location.search).get("add") === "1";
}

/** 是否是会话过期被送回来的（http.ts 写入 ?next=）：直接给登录卡片，不先停在首页 */
function isReturning(): boolean {
  if (typeof window === "undefined") return false;
  return new URLSearchParams(window.location.search).has("next");
}

/**
 * 登录页：星空欢迎页（components/welcome-screen.tsx，对齐原生 App 的欢迎页），
 * 首页底部「登录」按钮升起登录卡片。网页不需要服务器地址——页面本身就是从服务器打开的。
 *
 * 挂载时做两个跳转判断：
 * 1. 系统尚未初始化 → 转 /setup 引导页（首次部署的入口）；
 * 2. 已持有效会话 → 直接回 next 目标（默认首页），不重复登录。
 * 判断完之前不放片头，免得已登录的人先看到星空再被跳走。
 * 安全性完全由后端保证，这里的跳转只是导航体验。
 *
 * 一进来就是卡片的两种情况：会话过期回来（?next=）与「添加账号」（?add=1，
 * docs/design/account-switching.md §4：已登录也不跳走，登录成功后后端自动把新账号
 * 并入本浏览器的账号列表）。添加账号的卡片 × 回到当前账号。
 */
export default function LoginPage() {
  // 挂载后再读 URL：服务端渲染没有 window，初值若按 URL 算会造成水合不一致
  const [adding, setAdding] = useState(false);
  const [returning, setReturning] = useState(false);
  const [ready, setReady] = useState(false);
  // 公开演示站（docs/design/demo-site.md）：信息弹窗提供可一键填入的演示账号
  const [demo, setDemo] = useState<DemoSite | null>(null);
  useEffect(() => {
    setAdding(isAddingAccount());
    setReturning(isReturning());
  }, []);
  usePageTitle(adding ? "添加账号" : "登录");
  const router = useRouter();

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const status = await getBootstrapStatus();
        if (cancelled) return;
        setDemo(status.demo ?? null);
        if (!status.initialized) {
          router.replace("/setup");
          return;
        }
        // 添加账号：已登录也留在本页。直接读 URL 而不用 adding 状态——
        // 状态要等首个 effect 才更新，这里不能抢在它前面把人跳走
        if (isAddingAccount()) {
          setReady(true);
          return;
        }
        const session = await getSession(); // 已登录则不抛错
        if (!cancelled) router.replace(resolveNext(session) as Route);
      } catch {
        // 未登录（401）或后端暂不可达：留在登录页
        if (!cancelled) setReady(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [router]);

  return (
    <WelcomeScreen
      buttonLabel="登录"
      ready={ready}
      initialStage={adding || returning ? "card" : "home"}
      card={({ close, autoFocus }) => (
        <LoginCard
          adding={adding}
          autoFocus={autoFocus}
          demo={demo}
          onClose={adding ? () => router.replace("/") : close}
        />
      )}
    />
  );
}

function LoginCard({
  adding,
  autoFocus,
  demo,
  onClose,
}: {
  adding: boolean;
  autoFocus: boolean;
  demo: DemoSite | null;
  onClose: () => void;
}) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [remember, setRemember] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const usernameRef = useRef<HTMLInputElement>(null);

  // 用户点按钮打开的卡片：等卡片升起后聚焦用户名（同 App：动画与弹键盘挤在一起会卡）；
  // 页面自己出现的卡片只在有物理键盘的设备上聚焦，手机上不抢着弹键盘
  useEffect(() => {
    if (!autoFocus && !window.matchMedia("(pointer: fine)").matches) return;
    const timer = window.setTimeout(() => usernameRef.current?.focus(), autoFocus ? 450 : 0);
    return () => window.clearTimeout(timer);
  }, [autoFocus]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;
    setError(null);
    setBusy(true);
    try {
      const session = await login(username.trim(), password, remember);
      // 整页跳转而非路由跳转：让 AppShell 及全部数据在已登录态下重新初始化。
      // 回到 next 指向的页面（会话过期前所在处），默认首页；跳之前先备好新账号的
      // 壁纸与界面偏好首帧缓存，进工作台不闪默认图（lib/account-reload.ts）
      await reloadAfterAccountChange(resolveNext(session), true);
    } catch (err) {
      setError(err instanceof HttpError ? err.message : "网络异常，请稍后重试");
      setBusy(false);
    }
  };

  return (
    <WelcomeCard
      title={adding ? "添加账号" : "登录 MovieClaw"}
      subtitle={
        adding
          ? "登录另一个账号；之后可在用户菜单里一键切换，不用再输密码。"
          : demo
            ? demo.notice || "这是公开演示站，选择演示身份即可填入账号。"
            : "使用你在这台服务器上的账号进入。"
      }
      onClose={onClose}
    >
      <form onSubmit={submit} className="space-y-4">
        <WelcomeFields>
          <WelcomeField
            ref={usernameRef}
            icon={<UserIcon className="size-[18px]" />}
            placeholder="用户名"
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            autoComplete="username"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            enterKeyHint="next"
          />
          <WelcomeField
            icon={<LockIcon className="size-[18px]" />}
            placeholder="密码"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password"
            enterKeyHint="go"
          />
        </WelcomeFields>
        <div className="flex flex-wrap items-center justify-between gap-x-2">
          <label className="flex cursor-pointer items-center gap-2 px-1 text-sub text-[var(--text-muted)]">
            <input
              type="checkbox"
              checked={remember}
              onChange={(e) => setRemember(e.target.checked)}
              className="size-3.5 accent-[var(--accent-strong)]"
            />
            30 天内记住我
          </label>
          {demo && demo.accounts.length > 0 && (
            <DemoLoginInfo
              accounts={demo.accounts}
              selected={username.trim()}
              disabled={busy}
              onPick={(account) => {
                setUsername(account.username);
                setPassword(account.password);
                setError(null);
              }}
            />
          )}
        </div>
        <WelcomeError message={error} />
        <WelcomeSubmit busy={busy} disabled={busy || !username.trim() || !password}>
          {busy ? "正在登录…" : adding ? "添加并切换" : "登录"}
        </WelcomeSubmit>
      </form>
    </WelcomeCard>
  );
}

/**
 * 公开演示凭据集中在弹窗：登录卡片只保留入口，手机上不再被身份和复制信息撑高。
 * 原生 dialog 的顶层显示、焦点约束与关闭后焦点恢复，避免玻璃卡片的布局和软键盘干扰。
 * 在弹窗里切换身份仅用于查看和复制；明确点击「填入网页登录」才更新表单，不自动提交。
 */
function DemoLoginInfo({
  accounts,
  selected,
  disabled,
  onPick,
}: {
  accounts: DemoAccount[];
  selected: string;
  disabled: boolean;
  onPick: (account: DemoAccount) => void;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const [infoUsername, setInfoUsername] = useState(accounts[0].username);
  const current = accounts.find((account) => account.username === infoUsername) ?? accounts[0];
  const [serverAddress, setServerAddress] = useState("");
  useEffect(() => setServerAddress(window.location.origin), []);

  const open = () => {
    // 已选择的网页账号优先；尚未选择时，弹窗明确展示第一个公开身份及其对应凭据。
    setInfoUsername(accounts.find((account) => account.username === selected)?.username ?? accounts[0].username);
    dialogRef.current?.showModal();
  };

  return (
    <>
      <button
        type="button"
        disabled={disabled}
        onClick={open}
        aria-haspopup="dialog"
        className="min-h-[44px] px-1 text-sub text-[var(--text-muted)] underline decoration-white/20 underline-offset-4 hover:text-[var(--text)] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent-strong)] disabled:opacity-40"
      >
        演示账号 / App
      </button>
      <dialog
        ref={dialogRef}
        aria-label="App 登录信息"
        aria-describedby="demo-login-info-description"
        onClick={(event) => {
          if (event.target === event.currentTarget) event.currentTarget.close();
        }}
        className="welcome-glass fixed inset-0 m-auto max-h-[calc(100dvh_-_2rem)] w-[calc(100%_-_2rem)] max-w-sm overflow-y-auto overscroll-contain rounded-3xl p-0 text-[var(--text)] backdrop:bg-black/60 backdrop:backdrop-blur-sm"
      >
        <div className="space-y-4 p-5">
          <header className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-title font-semibold">App 登录信息</h2>
              <p id="demo-login-info-description" className="mt-1 text-sub leading-relaxed text-[var(--text-muted)]">
                演示账号也可用于 iPhone、Apple TV 和 Mac 上的 MovieClaw 应用。选择身份后可复制登录信息，或填入网页登录。
              </p>
            </div>
            <button
              type="button"
              aria-label="关闭登录信息"
              onClick={() => dialogRef.current?.close()}
              className="grid size-11 shrink-0 place-items-center rounded-full hover:bg-white/10 focus-visible:outline focus-visible:outline-2 focus-visible:outline-[var(--accent-strong)]"
            >
              <XIcon aria-hidden="true" className="size-4" />
            </button>
          </header>
          <fieldset>
            <legend className="mb-2 text-sub text-[var(--text-muted)]">演示身份</legend>
            <div className="grid grid-cols-2 gap-2">
              {accounts.map((account) => (
                <button
                  key={account.username}
                  type="button"
                  aria-pressed={current.username === account.username}
                  onClick={() => setInfoUsername(account.username)}
                  className="min-h-[44px] rounded-xl border border-white/10 px-2 text-sub transition-colors hover:bg-white/10 aria-pressed:border-white/30 aria-pressed:bg-white/15 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent-strong)]"
                >
                  {account.label}
                </button>
              ))}
            </div>
            {current.description && (
              <p className="mt-2 text-caption leading-relaxed text-[var(--text-muted)]">{current.description}</p>
            )}
          </fieldset>
          <dl aria-live="polite" className="divide-y divide-white/[0.08] rounded-2xl border border-white/[0.08] bg-white/[0.04] px-3">
            {[
              { label: "账号", value: current.username },
              { label: "密码", value: current.password },
              { label: "服务器地址", value: serverAddress },
            ].map(({ label, value }) => (
              <div key={label} className="flex min-h-[56px] items-center gap-2 py-1.5">
                <div className="min-w-0 flex-1">
                  <dt className="text-caption text-[var(--text-muted)]">{label}</dt>
                  <dd className="select-text break-words font-mono text-sub">{value}</dd>
                </div>
                {value && (
                  <CopyButton
                    key={value}
                    text={value}
                    label="复制"
                    ariaLabel={`复制${label}`}
                    className="min-h-[44px] shrink-0 px-2 text-caption text-[var(--text-muted)] hover:text-[var(--text)] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent-strong)]"
                  />
                )}
              </div>
            ))}
          </dl>
          <button
            type="button"
            onClick={() => {
              onPick(current);
              dialogRef.current?.close();
            }}
            className="flex min-h-[44px] w-full items-center justify-center rounded-full bg-[var(--accent-strong)] text-body font-semibold text-black/85 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent-strong)]"
          >
            填入网页登录
          </button>
        </div>
      </dialog>
    </>
  );
}
