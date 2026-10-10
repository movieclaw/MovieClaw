"use client";

import type { SessionView } from "@/lib/api/auth";
import { useSession } from "@/lib/session";

/**
 * 前端只消费业务权限，不在各页面散落角色判断。这里负责把管理员角色和成员
 * 能力快照收敛为稳定语义；后端鉴权仍是最终安全边界。
 */
export interface AppPermissions {
  isAdmin: boolean;
  canSubscribe: boolean;
  /** PT 搜索能力快照；实际资源入口用 canSearchTorrents，全局入口用 useSearchAccess */
  canSearch: boolean;
  /** 能用站点资源（PT 种子）搜索：搜索页的资源垂直、详情页「搜索资源」、手动选种 */
  canSearchTorrents: boolean;
  canDirectDownload: boolean;
  canManageLibraries: boolean;
  canManageSubscriptions: boolean;
  /**
   * 订阅详情「手动选种」：先搜资源、再把选中的种子投给下载器，所以要同时具备
   * 订阅、资源搜索与一键下载三项能力；后端投递接口另校验订阅归属（仅发起人）。
   */
  canGrabForSubscription: boolean;
}

export function permissionsFor(session: SessionView): AppPermissions {
  const isAdmin = session.role === "admin";
  // 公开演示站的只读会话（docs/design/demo-site.md，session.demo）：服务端会拒绝资源站搜索
  // 与一键下载，这里就不摆这两个入口（公开超管也一样）；影视与媒体库搜索按 useSearchAccess
  // 的分区授权显示，订阅入口照常显示、确认时由后端说明只读。审核账号的会话不带 demo 标记，
  // 与正式部署完全一样
  const demo = session.demo === true;
  const canSubscribe = isAdmin || session.capabilities.allow_subscribe;
  const canSearch = isAdmin || session.capabilities.allow_search;
  const canSearchTorrents = !demo && canSearch;
  const canDirectDownload = !demo && (isAdmin || session.capabilities.allow_direct_download);
  return {
    isAdmin,
    canSubscribe,
    canSearch,
    canSearchTorrents,
    canDirectDownload,
    canManageLibraries: isAdmin,
    canManageSubscriptions: isAdmin,
    canGrabForSubscription: canSubscribe && canSearchTorrents && canDirectDownload,
  };
}

/** 当前会话的语义权限；权限变化后随 SessionProvider 快照立即更新。 */
export function usePermissions(): AppPermissions {
  return permissionsFor(useSession().session);
}

export function roleLabel(session: SessionView): string {
  return session.role === "admin" ? "超级管理员" : "成员";
}

/**
 * 把登录后的目标地址收敛到当前身份可进入的页面。除了登录落点，AuthGate
 * 也复用它拦截手输 URL，避免成员短暂看到 Agent 页面再收到后端 403。
 */
export function accessiblePathFor(session: SessionView, requestedPath: string): string {
  if (session.role === "member") {
    // Agent 入口（首页输入台 / 直达页 / 会话页）一律挡在成员之外：界面上已经
    // 不给入口，手输 URL 也不该看到一个后端全 403 的空壳页
    if (
      requestedPath === "/" ||
      requestedPath === "/new" ||
      requestedPath.startsWith("/sessions/")
    ) {
      return "/library";
    }
    // 观看活动与媒体库管理是超管页面，成员界面上没有入口，手输 URL 同样改道
    if (requestedPath.startsWith("/activity") || requestedPath.startsWith("/library/manage")) {
      return "/library";
    }
    if (!session.capabilities.allow_subscribe && requestedPath.startsWith("/subscriptions")) {
      return "/library";
    }
    // /search 不在这里拦：搜索按分区授权（影视 / 资源 / 媒体库，见 useSearchAccess），
    // 「有没有可用分区」要查可见库才知道，这个同步守卫给不出结论；搜索页自己在
    // 没有可用分区时渲染空状态，入口也已按同一口径隐藏
  }
  return requestedPath;
}
