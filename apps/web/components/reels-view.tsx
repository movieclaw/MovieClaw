"use client";

import { PhoneReels } from "@/components/reels/phone-reels";
import { TheaterReels } from "@/components/reels/theater-reels";
import { useReels } from "@/components/reels/use-reels";
import { useIsMobile } from "@/lib/use-media-query";

/**
 * 片段（docs/design/reels.md §6.1 / §6.2）：数据与播放共用 `useReels`，版式按宽度分——
 * 手机（< 768）上下整页滑动，同 iOS；更宽的（电脑、平板）是放映厅：片段是横片，屏幕宽了就给大画面。
 */
export function ReelsView() {
  const reels = useReels();
  return useIsMobile() ? <PhoneReels reels={reels} /> : <TheaterReels reels={reels} />;
}
