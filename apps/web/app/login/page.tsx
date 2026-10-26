"use client";

import { useMessageState } from "@/lib/i18n/use-message-state";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import type { Route } from "next";

import { LanguagePicker } from "@/components/language-picker";
import { LockIcon, UserIcon } from "@/components/icons";
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
import type { SessionView } from "@/lib/api/auth";

/**
 * 登录成功 / 已登录后要跳回的目标地址：取自 ?next= 参数（会话过期时由 http.ts 写入）。
 * 只接受站内相对路径（以单个 / 开头），拒绝 //host、http(s):// 等外站地址，防开放重定向；
 * 缺失或非法时回落到首页。
 */
function resolveNext(session?: SessionView): string {
  if (typeof window === "undefined") return "/";
  const raw = new URLSearchParams(window.location.search).get("next");
  if (!raw) return session ? accessiblePathFor(session, "/") : "/";
  const next = decodeURIComponent(raw);
  if (next.startsWith("/") && !next.startsWith("//")) {
    return session ? accessiblePathFor(session, next) : next;
  }
  return session ? accessiblePathFor(session, "/") : "/";
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
  const t = useTranslations("auth");
  // 挂载后再读 URL：服务端渲染没有 window，初值若按 URL 算会造成水合不一致
  const [adding, setAdding] = useState(false);
  const [returning, setReturning] = useState(false);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    setAdding(isAddingAccount());
    setReturning(isReturning());
  }, []);
  usePageTitle(adding ? t("login.addAccount") : t("login.action"));
  const router = useRouter();

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const status = await getBootstrapStatus();
        if (cancelled) return;
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
      footer={<LanguagePicker />}
      buttonLabel={t("login.action")}
      ready={ready}
      initialStage={adding || returning ? "card" : "home"}
      card={({ close, autoFocus }) => (
        <LoginCard
          adding={adding}
          autoFocus={autoFocus}
          onClose={adding ? () => router.replace("/") : close}
        />
      )}
    />
  );
}

function LoginCard({
  adding,
  autoFocus,
  onClose,
}: {
  adding: boolean;
  autoFocus: boolean;
  onClose: () => void;
}) {
  const t = useTranslations("auth");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [remember, setRemember] = useState(false);
  const [error, setError] = useMessageState();
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
      if (err instanceof HttpError && (err.details as { message_key?: string } | null)?.message_key === "errors.auth.wrongPassword") {
        setError({ key: "errors.auth.wrongPassword" });
      } else {
        setError(err instanceof HttpError ? err.message : { key: "common.networkRetry" });
      }
      setBusy(false);
    }
  };

  return (
    <WelcomeCard
      title={adding ? t("login.addAccount") : t("login.title")}
      subtitle={
        adding
          ? t("login.addSubtitle")
          : t("login.subtitle")
      }
      onClose={onClose}
    >
      <form onSubmit={submit} className="space-y-4">
        <WelcomeFields>
          <WelcomeField
            ref={usernameRef}
            icon={<UserIcon className="size-[18px]" />}
            placeholder={t("login.username")}
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
            placeholder={t("login.password")}
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password"
            enterKeyHint="go"
          />
        </WelcomeFields>
        <label className="flex cursor-pointer items-center gap-2 px-1 text-sub text-[var(--text-muted)]">
          <input
            type="checkbox"
            checked={remember}
            onChange={(e) => setRemember(e.target.checked)}
            className="size-3.5 accent-[var(--accent-strong)]"
          />
          {t("login.remember")}
        </label>
        <WelcomeError message={error} />
        <WelcomeSubmit busy={busy} disabled={busy || !username.trim() || !password}>
          {busy ? t("login.pending") : adding ? t("login.addAndSwitch") : t("login.action")}
        </WelcomeSubmit>
      </form>
    </WelcomeCard>
  );
}
