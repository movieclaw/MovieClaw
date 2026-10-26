"use client";

import { useLocale } from "next-intl";
import { useEffect, useMemo, useState } from "react";

import type { Route } from "next";
import { useRouter } from "next/navigation";

import { PlayerPage } from "@/components/player/player-page";
import { unavailableMessage } from "@/components/share/share-page";
import { sharePlaybackScope } from "@/lib/api/playback";
import { probeShare } from "@/lib/api/shares";
import { sharePath } from "@/lib/share";
import { BrandLoader } from "@/components/brand-loader";

/**
 * 分享页的播放器（docs/design/media-share.md §5.3）：先探针拿到条目 id，
 * 再挂同一个 PlayerPage——接口作用域换成分享通道（进度记本浏览器、不上报
 * 遥测），退出固定回 /s/{slug}。未解锁就回分享页输密码。
 */
export function SharePlayerPage({
  slug,
  season,
  episode,
  startMsOverride,
}: {
  slug: string;
  season?: number;
  episode?: number;
  startMsOverride?: number;
}) {
  const router = useRouter();
  const locale = useLocale();
  const [mediaItemId, setMediaItemId] = useState<number | null>(null);
  const [failed, setFailed] = useState<string | null>(null);
  const scope = useMemo(() => sharePlaybackScope(slug), [slug]);
  const exitHref = sharePath(slug);

  useEffect(() => {
    let cancelled = false;
    probeShare(slug)
      .then((info) => {
        if (cancelled) return;
        if (info.media_item_id == null) {
          // 需要密码且未解锁：回分享页走密码卡片
          router.replace(exitHref as Route);
          return;
        }
        setMediaItemId(info.media_item_id);
      })
      .catch((error: unknown) => {
        if (!cancelled) setFailed(unavailableMessage(error, locale));
      });
    return () => {
      cancelled = true;
    };
  }, [slug, router, exitHref, locale]);

  return (
    <div className="h-dvh w-full overflow-hidden bg-black">
      {failed ? (
        <div className="flex size-full items-center justify-center px-6 text-center">
          <p className="text-[15px] text-white">{failed}</p>
        </div>
      ) : mediaItemId === null ? (
        <div className="flex size-full items-center justify-center text-ui text-white/60">
          <BrandLoader className="size-5" />
        </div>
      ) : (
        <PlayerPage
          mediaItemId={mediaItemId}
          season={season}
          episode={episode}
          startMsOverride={startMsOverride}
          api={scope}
          exitHref={exitHref}
        />
      )}
    </div>
  );
}
