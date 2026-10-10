"use client";

import { type ReactNode, useState } from "react";

import { Banner } from "@/components/cloud-push-ui";
import { useToast } from "@/components/feedback";
import { SETTINGS_BUTTON_CLASS } from "@/components/settings-ui";
import { setFeatureEnabled } from "@/lib/api/plugins";
import { refreshFeatures, useFeature } from "@/lib/features";
import { usePermissions } from "@/lib/permissions";
import { featureOff, featureOffText } from "@/lib/plugins-display";

/**
 * 功能停用时贴在它设置页顶部的说明（docs/design/plugin-page-tiers.md §6）：停用期间会怎样、是谁停的。
 * 网页上不出常驻开关（功能开关在服务端 / 接口 / CLI）；功能确实被停用时，管理员在这里一键恢复。
 * 被 plugins.yaml / 环境变量关掉的没有按钮，原因里写明去哪改。功能开着、还没拿到状态、旧服务端时不显示。
 */
export function FeatureOffNotice({ feature: key, children }: { feature: string; children: ReactNode }) {
  const feature = useFeature(key);
  const { isAdmin } = usePermissions();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  if (!feature || !featureOff(feature)) return null;

  const enable = () => {
    setBusy(true);
    setFeatureEnabled(feature.key, true)
      .then((view) => toast.success(`「${view.title}」已重新开启`))
      .catch((err: unknown) => toast.error(err instanceof Error ? err.message : "开启失败"))
      .finally(() => {
        setBusy(false);
        void refreshFeatures();
      });
  };

  return (
    <Banner
      tone="info"
      title={`「${feature.title}」已停用`}
      action={
        isAdmin && !feature.locked_by && feature.switchable ? (
          <button type="button" disabled={busy} onClick={enable} className={SETTINGS_BUTTON_CLASS}>
            {busy ? "正在开启…" : "重新开启"}
          </button>
        ) : undefined
      }
    >
      {children}
      <span className="text-[var(--text-faint)]">（{featureOffText(feature)}）</span>
    </Banner>
  );
}
