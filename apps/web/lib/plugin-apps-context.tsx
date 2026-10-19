"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";

import { fetchPluginApps } from "@/lib/api/ui";
import type { PluginApp } from "@/lib/plugin-apps";
import { useSession } from "@/lib/session";

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
    void fetchPluginApps().then((next) => {
      if (!cancelled) setApps(next);
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
