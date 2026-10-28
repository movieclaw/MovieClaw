"use client";

import type { Route } from "next";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { useRef, useState } from "react";

import { ShelfCardCaption } from "@/components/collection-library-card";
import { PlayIcon } from "@/components/icons";
import { resolveStreamUrl } from "@/lib/api/playback";
import { fetchReelFeed } from "@/lib/api/reels";

/**
 * 电脑 / 平板上的片段入口（docs/design/reels.md §6.2）：媒体库首页「我的媒体库」那一排里的一张卡，与库卡片同尺寸。
 * 手机上的入口是下拉二楼（ReelsFloor），这里不加任何工具栏按钮。
 *
 * 封面是冷银胶片（与下拉二楼同一套视觉），画格是首页已经拿到的剧照；悬停时胶片走起来，服务端开了片段预切时
 * 再静音放一段切好的小片（`<video>` 直接放，不开播放会话；没开预切就只走片）。
 */
export function ReelsShelfCard({ stills }: { stills: string[] }) {
  const t = useTranslations();
  const [hover, setHover] = useState(false);
  const [preview, setPreview] = useState<string | null>(null);
  const asked = useRef(false);

  const onEnter = () => {
    setHover(true);
    if (asked.current) return;
    asked.current = true;
    fetchReelFeed({ limit: 1, modes: "clip" }, { filter: {}, kind: null })
      .then((feed) => {
        const url = feed.items[0]?.play.clip_url;
        if (url) setPreview(resolveStreamUrl(url));
      })
      .catch(() => undefined);
  };

  // 画格排两遍：走到一半正好接上第一遍，循环看不出接缝
  const frames = stills.length > 0 ? [...stills, ...stills] : [];
  return (
    <div className="group/lib relative" onPointerEnter={onEnter} onPointerLeave={() => setHover(false)}>
      <Link
        href={"/reels" as Route}
        aria-label={t("library.reels.cardOpen")}
        className="block overflow-hidden rounded-2xl ring-1 ring-white/10 outline-none transition duration-300 hover:ring-white/35 focus-visible:ring-2 focus-visible:ring-[var(--accent-ring)]"
        data-testid="reels-shelf-card"
      >
        <div className="relative aspect-[21/10] overflow-hidden bg-[radial-gradient(120%_90%_at_50%_0%,#1d222b,#07080b)]">
          {/* 胶片：冷银片基、上下两排片孔 */}
          <div className="absolute inset-x-0 top-[14%] h-[62%] -rotate-3 scale-110 bg-[linear-gradient(180deg,#3a414d,#1c2027_45%,#2c323c)] shadow-[0_10px_30px_rgba(0,0,0,0.55)]">
            <div className="absolute inset-x-0 top-[5%] h-[8%] bg-[repeating-linear-gradient(90deg,rgba(214,224,240,0.55)_0_7px,transparent_7px_17px)]" />
            <div className="absolute inset-x-0 bottom-[5%] h-[8%] bg-[repeating-linear-gradient(90deg,rgba(214,224,240,0.55)_0_7px,transparent_7px_17px)]" />
            <div className="absolute inset-x-0 top-[19%] bottom-[19%] overflow-hidden">
              <div
                className="flex h-full w-max gap-[6px] motion-safe:animate-[reels-film-run_18s_linear_infinite]"
                // 行内样式压过 animate 简写里的播放状态：平时停着，悬停才走
                style={{ animationPlayState: hover ? "running" : "paused" }}
              >
                {frames.map((src, index) => (
                  <img
                    key={`${src}-${index}`}
                    src={src}
                    alt=""
                    className="aspect-[16/10] h-full shrink-0 rounded-[3px] object-cover [filter:saturate(0.55)_contrast(1.08)_brightness(0.92)]"
                  />
                ))}
              </div>
            </div>
          </div>
          {hover && preview && (
            <video src={preview} muted autoPlay loop playsInline className="absolute inset-0 size-full object-cover" />
          )}
          <div className="absolute inset-x-0 bottom-0 flex items-center gap-2 bg-gradient-to-t from-black/75 to-transparent px-3 pb-2.5 pt-10">
            <span className="grid size-7 shrink-0 place-items-center rounded-full bg-white/90 text-black">
              <PlayIcon className="size-3.5" />
            </span>
            <span className="truncate text-caption text-white/80">{t("library.reels.cardHint")}</span>
          </div>
        </div>
      </Link>
      <ShelfCardCaption name={t("library.reels.title")} />
    </div>
  );
}
