"use client";

import { usePathname } from "next/navigation";
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";

import { fetchPluginApps } from "@/lib/api/ui";
import {
  activeAppNavId,
  appNavItems,
  withoutHidden,
  type PluginApp,
  type PluginAppNavItem,
} from "@/lib/plugin-apps";
import { useSession } from "@/lib/session";
import { useUiPrefs } from "@/lib/ui-prefs";

interface PluginAppsContextValue {
  /** 当前用户可见的插件网页；首次拉取前为 null */
  apps: PluginApp[] | null;
  /** 同意 / 撤销 / 改侧边栏设置之后重拉 */
  refresh: () => void;
}

const PluginAppsContext = createContext<PluginAppsContextValue>({ apps: [], refresh: () => {} });

/**
 * 插件网页的全站数据源（docs/design/plugin-web-pages.md）：侧边栏、导航设置与
 * `/apps/...` 页面共用一份 `GET /ui/apps`，登录主体变了（切换账号）就重拉。
 */
export function PluginAppsProvider({ children }: { children: React.ReactNode }) {
  const { session } = useSession();
  const [apps, setApps] = useState<PluginApp[] | null>(null);
  const [version, setVersion] = useState(0);
  const refresh = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    let cancelled = false;
    fetchPluginApps()
      .then((next) => {
        if (!cancelled) setApps(next);
      })
      .catch(() => {
        // 一次拉取失败（网络抖动、服务重启中）不把侧边栏里的插件项清空：沿用上一份；
        // 从没拉到过才当作没有（旧服务端没有这个接口也走这里）
        if (!cancelled) setApps((current) => current ?? []);
      });
    return () => {
      cancelled = true;
    };
  }, [session.username, version]);

  const value = useMemo(() => ({ apps, refresh }), [apps, refresh]);
  return <PluginAppsContext.Provider value={value}>{children}</PluginAppsContext.Provider>;
}

export function usePluginApps(): PluginAppsContextValue {
  return useContext(PluginAppsContext);
}

/**
 * 插件网页的导航入口与当前高亮项，给**不跟个人排序**的外框用（主题的顶栏等）：
 * 只尊重「移出侧边栏」（nav.hidden），顺序按插件给的；侧栏要的是排过序的整表，
 * 见 components/sidebar.tsx 的 usePluginNavItems。activeId 未命中任何插件网页时为 null。
 */
export function useAppNavLinks(): { items: PluginAppNavItem[]; activeId: string | null } {
  const { apps } = usePluginApps();
  const { prefs } = useUiPrefs();
  const pathname = usePathname();
  return {
    items: withoutHidden(appNavItems(apps ?? []), prefs.nav.hidden),
    activeId: activeAppNavId(pathname, apps ?? []),
  };
}
