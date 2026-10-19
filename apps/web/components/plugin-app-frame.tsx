"use client";

import type { Route } from "next";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";

import { reportPluginAppError } from "@/lib/api/ui";
import { usePageChrome } from "@/lib/page-chrome";
import { usePermissions } from "@/lib/permissions";
import { frameSrc, hostPathFromFrame, parseAppPath, type PluginApp } from "@/lib/plugin-apps";
import { usePluginApps } from "@/lib/plugin-apps-context";
import { publicEnv } from "@/lib/env";
import { useIsMobile } from "@/lib/use-media-query";

/**
 * 插件网页的外框（docs/design/plugin-web-pages.md §6.2）：主程序外框里放一个占满正文区的
 * **同源** iframe（授信模式，不加 sandbox）。页面本身不用写任何主程序专有的代码，下面这些都由
 * 外框借同源直接做掉：
 * - 地址同步：iframe 每次加载、前进后退、hash 变化、pushState / replaceState 之后，把子路径用
 *   replaceState 写回地址栏——浏览器历史里只留 iframe 自己那一条，返回键按一次退一页；
 * - 跳出网页根目录（没写 target="_top" 的站内链接）：把整页带过去，不让主程序套娃进 iframe；
 * - 报错收集：iframe 窗口的 error / unhandledrejection 交给服务端写系统日志；
 * - 主题：把主程序的设计变量以 `--mc-*` 写到页面根元素上，并对齐 color-scheme，切主题时跟着变。
 *
 * 挂在 /apps/[plugin] 的 layout 里：插件内部换页只改子路径，外框与 iframe 不会被重建。
 */

/** 交给插件页面的设计变量：页面里写 `var(--mc-text)` 等，不写也照常能用 */
const SHARED_TOKENS = [
  "text",
  "text-muted",
  "text-faint",
  "line",
  "line-strong",
  "accent",
  "accent-strong",
  "accent-soft",
  "surface-raised",
  "surface-inset",
  "glass-fill",
  "glass-fill-hover",
  "ok",
  "info",
  "warn",
  "danger",
  "danger-solid",
] as const;

function applyTheme(doc: Document | null) {
  if (!doc?.documentElement) return;
  const host = document.documentElement;
  const computed = getComputedStyle(host);
  const root = doc.documentElement;
  for (const name of SHARED_TOKENS) {
    const value = computed.getPropertyValue(`--${name}`).trim();
    if (value) root.style.setProperty(`--mc-${name}`, value);
  }
  root.style.setProperty("--mc-font", getComputedStyle(document.body).fontFamily);
  // 与主程序同一个 color-scheme：不一致时浏览器会给 iframe 垫一层不透明底，玻璃背景就透不出来
  root.style.colorScheme = computed.colorScheme || "dark";
  root.dataset.mcTheme = host.getAttribute("data-theme") ?? "silver";
}

type PatchedHistory = History & { __mcPatched?: boolean };

export function PluginAppFrame({ appId }: { appId: string }) {
  const { apps } = usePluginApps();
  const app = apps?.find((a) => a.id === appId) ?? null;
  useAppTitle(app?.name ?? null);
  useMobileTitle(app?.name ?? null);

  if (apps === null) {
    return <div className="h-full" aria-busy />;
  }
  if (!app) return <Missing />;
  return <Frame key={app.id} app={app} />;
}

function Frame({ app }: { app: PluginApp }) {
  const router = useRouter();
  const pathname = usePathname();
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const [src, setSrc] = useState<string | null>(null);
  /** iframe 自己报上来的地址（地址栏同步过去的）：再看到它就不必反过来驱动 iframe */
  const reported = useRef<string | null>(null);

  const currentHost = () => `${window.location.pathname}${window.location.search}${window.location.hash}`;

  // 地址栏 → iframe：首次进入定初始地址；之后只有「不是 iframe 自己报上来的」变化才驱动它
  //（点了同一插件在侧边栏里的另一项）
  useEffect(() => {
    const host = currentHost();
    if (reported.current === host) return;
    const sub = parseAppPath(window.location.pathname)?.sub ?? "";
    const target = frameSrc(app.base, sub, window.location.search, window.location.hash);
    reported.current = host;
    const win = iframeRef.current?.contentWindow;
    if (src === null || !win) setSrc(target);
    // replace 而不是 assign：主程序这次跳转已经在浏览器历史里记了一条，iframe 再记一条，
    // 返回键就得按两次
    else win.location.replace(target);
    // pathname 只用来触发；地址以 window.location 为准（含查询串和片段）
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pathname, app.base]);

  const sync = useCallback(() => {
    const win = iframeRef.current?.contentWindow;
    if (!win) return;
    const host = hostPathFromFrame(app.id, app.base, win.location);
    if (host === null) return;
    reported.current = host;
    if (host !== currentHost()) window.history.replaceState(null, "", host);
  }, [app.id, app.base]);

  const onLoad = useCallback(() => {
    const win = iframeRef.current?.contentWindow;
    if (!win) return;
    let location: Location;
    try {
      location = win.location;
      void location.pathname;
    } catch {
      return; // 不同源：不会发生（插件页面都同源托管），防御一下
    }
    const host = hostPathFromFrame(app.id, app.base, location);
    if (host === null) {
      // 跳出了网页根目录、落到主程序的页面上（没写 target="_top" 的站内链接）：整页带过去，
      // 不在 iframe 里套一个主程序。落到接口地址（插件自己的 JSON、文件）就留在 iframe 里
      if (!location.pathname.startsWith("/api/")) {
        router.push(`${location.pathname}${location.search}${location.hash}` as Route);
      }
      return;
    }
    sync();
    const history = win.history as PatchedHistory;
    if (!history.__mcPatched) {
      history.__mcPatched = true;
      for (const name of ["pushState", "replaceState"] as const) {
        const original = history[name].bind(history);
        history[name] = (...args: Parameters<History["pushState"]>) => {
          original(...args);
          sync();
        };
      }
    }
    win.addEventListener("popstate", sync);
    win.addEventListener("hashchange", sync);
    win.addEventListener("error", (event: ErrorEvent) => {
      const where = event.filename ? `${event.filename}:${event.lineno}:${event.colno}` : "";
      void reportPluginAppError(app.id, event.message || "未知错误", [where, event.error?.stack].filter(Boolean).join("\n"));
    });
    win.addEventListener("unhandledrejection", (event: PromiseRejectionEvent) => {
      const reason = event.reason as { message?: string; stack?: string } | undefined;
      void reportPluginAppError(app.id, reason?.message ?? String(event.reason), reason?.stack ?? "");
    });
    applyTheme(win.document);
  }, [app.id, app.base, router, sync]);

  // 切主题（<html data-theme> 变化）时把设计变量同步进去
  useEffect(() => {
    const observer = new MutationObserver(() => applyTheme(iframeRef.current?.contentDocument ?? null));
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "style", "class"] });
    return () => observer.disconnect();
  }, []);

  return (
    <div className="relative h-full w-full overflow-hidden">
      {src && (
        <iframe
          ref={iframeRef}
          src={src}
          title={app.name}
          onLoad={onLoad}
          className="absolute inset-0 size-full border-0 bg-transparent"
          allow="fullscreen; clipboard-write"
        />
      )}
    </div>
  );
}

/** 没有这个页面：没装、没同意、被停用、安全模式，或成员没被授权看 */
function Missing() {
  const { isAdmin } = usePermissions();
  return (
    <div className="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
      <p className="text-title-sm font-medium text-[var(--text)]">这个页面打不开</p>
      <p className="max-w-sm text-sub leading-relaxed text-[var(--text-muted)]">
        {isAdmin
          ? "插件可能已卸载或停用、还没有同意它的网页运行，或者应用正处于安全模式。"
          : "它可能已被移除，或者管理员没有开放给成员。"}
      </p>
      {isAdmin && (
        <Link href={"/settings/plugins" as Route} className="glass-row px-3 py-1.5 text-sub text-[var(--text)]">
          去插件设置
        </Link>
      )}
    </div>
  );
}

/**
 * 标签页标题用插件名。不能只在名字变化时写一次（usePageTitle 的做法）：地址栏同步是一次
 * replaceState，Next 会随之重新套用路由 metadata 的兜底标题，所以每次地址变化后都要写回。
 */
function useAppTitle(title: string | null) {
  const pathname = usePathname();
  useEffect(() => {
    if (!title) return;
    const text = `${title} · ${publicEnv.appName}`;
    document.title = text;
    // Next 在这次提交之后才套用 metadata：再晚一拍写回（setTimeout，面板里 rAF 会被节流）
    const timer = window.setTimeout(() => {
      document.title = text;
    }, 0);
    return () => window.clearTimeout(timer);
  }, [title, pathname]);
}

/** 手机银玻璃：标题挂进全局顶栏（与订阅、媒体库等顶层页同一写法） */
function useMobileTitle(title: string | null) {
  const chrome = usePageChrome();
  const setTopBarTitle = chrome?.setTopBarTitle;
  const isMobile = useIsMobile();
  useEffect(() => {
    if (!isMobile || !setTopBarTitle || !title) return;
    return setTopBarTitle(title);
  }, [isMobile, setTopBarTitle, title]);
}

