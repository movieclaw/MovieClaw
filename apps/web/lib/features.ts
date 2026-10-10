"use client";

/**
 * 功能开关的前端状态（docs/design/plugin-page-tiers.md §6）：哪些功能停用了。
 *
 * 各页面据此隐藏入口或提示「已停用」。整页共享一份（模块级缓存），插件页切换开关后
 * 调 refreshFeatures() 让所有用到的地方一起更新。读失败按「全部开启」处理：宁可多露一个
 * 入口（服务端仍会拦），也不因为网络抖动把功能藏起来。
 */

import { useEffect, useState } from "react";

import { listFeatures, type PluginFeature } from "@/lib/api/plugins";

let cache: PluginFeature[] | null = null;
let inflight: Promise<PluginFeature[]> | null = null;
const listeners = new Set<(features: PluginFeature[]) => void>();

function load(): Promise<PluginFeature[]> {
  inflight ??= listFeatures()
    .catch(() => [] as PluginFeature[])
    .then((features) => {
      cache = features;
      inflight = null;
      listeners.forEach((listener) => listener(features));
      return features;
    });
  return inflight;
}

/** 重新拉一次（切换开关之后） */
export function refreshFeatures(): Promise<PluginFeature[]> {
  inflight = null;
  return load();
}

/** 某个功能的开关状态；还没拿到或旧服务端没有这个功能时为 null */
export function useFeature(key: string): PluginFeature | null {
  const [features, setFeatures] = useState<PluginFeature[] | null>(cache);
  useEffect(() => {
    listeners.add(setFeatures);
    if (cache === null) void load();
    return () => {
      listeners.delete(setFeatures);
    };
  }, []);
  return features?.find((f) => f.key === key) ?? null;
}
