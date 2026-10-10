"use client";

import { useRouter } from "next/navigation";

import { TipCard } from "@/components/tip-card";
import { usePermissions } from "@/lib/permissions";
import { defineTip } from "@/lib/tips/engine";

/**
 * 「开启片段预切」建议（docs/design/tips.md「服务端代记的事件」）。
 *
 * 事件由服务端替管理员记：开关关着时有人刷片、电视放了大图预告（谁做的都算）。
 * 开关打开后服务端作废这条提示，哪一端开的都一样。
 */
const reelClipsTip = defineTip({
  id: "playback.reel-clips",
  title: "开启片段预切，预告和刷片更流畅",
  message:
    "家里已经有人在刷片或看电视大图预告了。打开后服务器会在后台把精彩片段提前转成 1080p 小文件，起播更快、不卡顿。",
  actions: [{ id: "open", label: "去开启" }],
  rules: [({ event }) => event("reels.played-without-clips").count >= 1],
});

/** 只有管理员能改播放设置，成员不挂（也就不拉提示状态） */
export function ReelClipsTip({ className }: { className?: string }) {
  const { isAdmin } = usePermissions();
  const router = useRouter();
  if (!isAdmin) return null;
  return (
    <TipCard
      tip={reelClipsTip}
      onAction={() => router.push("/settings/playback")}
      className={className}
    />
  );
}
