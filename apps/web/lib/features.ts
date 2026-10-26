"use client";

/**
 * 功能开关的前端状态（docs/design/plugin-page-tiers.md §6）：哪些功能停用了。
 *
 * 各页面据此隐藏入口或提示「已停用」。整页共享一份（模块级缓存），插件页切换开关后
 * 调 refreshFeatures() 让所有用到的地方一起更新。读失败按「全部开启」处理：宁可多露一个
 * 入口（服务端仍会拦），也不因为网络抖动把功能藏起来。
 */

import { useEffect, useState } from "react";
import { useLocale } from "next-intl";

import { listFeatures, type PluginFeature } from "@/lib/api/plugins";
import { requestLocale, type AppLocale } from "@/lib/i18n/negotiate";

const cache = new Map<AppLocale, PluginFeature[]>();
const inflight = new Map<AppLocale, Promise<PluginFeature[]>>();
const listeners = new Set<(locale: AppLocale, features: PluginFeature[]) => void>();

function load(locale: AppLocale): Promise<PluginFeature[]> {
  const pending = inflight.get(locale);
  if (pending) return pending;
  const request = listFeatures(locale)
    .catch(() => [] as PluginFeature[])
    .then((features) => {
      if (inflight.get(locale) === request) {
        cache.set(locale, features);
        inflight.delete(locale);
        listeners.forEach((listener) => listener(locale, features));
      }
      return features;
    });
  inflight.set(locale, request);
  return request;
}

/** 重新拉一次（切换开关之后） */
export function refreshFeatures(locale: AppLocale = requestLocale() ?? "zh-Hans"): Promise<PluginFeature[]> {
  cache.clear();
  inflight.clear();
  return load(locale);
}

/** 某个功能的开关状态；还没拿到或旧服务端没有这个功能时为 null */
export function useFeature(key: string): PluginFeature | null {
  const locale = useLocale();
  const [snapshot, setSnapshot] = useState(() => ({
    locale, features: cache.get(locale) ?? null,
  }));
  useEffect(() => {
    const accept = (forLocale: AppLocale, features: PluginFeature[]) => {
      if (forLocale === locale) setSnapshot({ locale, features });
    };
    listeners.add(accept);
    setSnapshot({ locale, features: cache.get(locale) ?? null });
    if (!cache.has(locale)) void load(locale);
    return () => {
      listeners.delete(accept);
    };
  }, [locale]);
  return snapshot.locale === locale ? snapshot.features?.find((f) => f.key === key) ?? null : null;
}
