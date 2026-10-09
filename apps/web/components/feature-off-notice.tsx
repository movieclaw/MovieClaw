"use client";

import Link from "next/link";
import type { ReactNode } from "react";

import { Banner } from "@/components/cloud-push-ui";
import { SETTINGS_BUTTON_CLASS } from "@/components/settings-ui";
import { useFeature } from "@/lib/features";
import { usePermissions } from "@/lib/permissions";
import { featureOff, featureOffText } from "@/lib/plugins-display";

/**
 * 功能停用时贴在它设置页顶部的说明（docs/design/plugin-page-tiers.md §6）：停用期间会怎样、
 * 是谁停的；管理员可以一键去插件页开启（被 plugins.yaml / 环境变量关掉的没有按钮，原因里写明去哪改）。
 * 功能开着、还没拿到状态、旧服务端没有这个功能时都不显示。
 */
export function FeatureOffNotice({ feature: key, children }: { feature: string; children: ReactNode }) {
  const feature = useFeature(key);
  const { isAdmin } = usePermissions();
  if (!feature || !featureOff(feature)) return null;
  const href = `/settings/plugins?module=${encodeURIComponent(feature.entries[0] ?? "")}`;
  return (
    <Banner
      tone="info"
      title={`「${feature.title}」已停用`}
      action={
        isAdmin && !feature.locked_by ? (
          <Link href={href as never} className={`${SETTINGS_BUTTON_CLASS} inline-flex items-center`}>
            去插件页开启
          </Link>
        ) : undefined
      }
    >
      {children}
      <span className="text-[var(--text-faint)]">（{featureOffText(feature)}）</span>
    </Banner>
  );
}
