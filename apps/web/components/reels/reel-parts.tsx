"use client";

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { useTranslations } from "next-intl";
import type { CSSProperties, ReactNode } from "react";

import { CheckIcon, ChevronDownIcon } from "@/components/icons";
import { SubtitleLayer } from "@/components/player/subtitle-layer";
import { ShareDialog } from "@/components/share-dialog";

import type { QualityControl, Reels } from "./use-reels";

/**
 * 唯一的视频元素与字幕层（与 JASSUB 的画布）放在同一个框里：字幕按视频框定位、跟着一起淡出。
 * 框的位置由版式给（手机盖在当前页横带上，电脑在放映厅的画面框里）。
 */
export function ReelVideo({
  reels,
  className,
  style,
  avoidBottomPx = 0,
}: {
  reels: Reels;
  className: string;
  style?: CSSProperties;
  /** 控制条展开时字幕往上让的高度（电脑上的控制条盖在画面底部） */
  avoidBottomPx?: number;
}) {
  return (
    <div className={className} style={style}>
      <video
        ref={reels.setVideoEl}
        playsInline
        muted
        className="absolute inset-0 size-full bg-black object-contain"
        data-testid="reels-video"
        data-status={reels.status}
      />
      {reels.subtitle && (
        <SubtitleLayer
          video={reels.videoEl}
          track={reels.subtitle.track}
          style={reels.subtitleStyle}
          baseOffsetSeconds={reels.subtitle.originS}
          avoidBottomPx={avoidBottomPx}
        />
      )}
    </div>
  );
}

/** 浏览器把声音拦下了（静音起播）：一个小胶囊，点它（或点画面任何地方）开声音。电脑上写「点击」 */
export function UnmuteHint({
  reels,
  className = "",
  wording = "tap",
}: {
  reels: Reels;
  className?: string;
  wording?: "tap" | "click";
}) {
  const t = useTranslations();
  if (!reels.soundBlocked) return null;
  return (
    <button
      type="button"
      onClick={(event) => {
        event.stopPropagation();
        reels.unmute();
      }}
      className={`flex items-center gap-1.5 rounded-full bg-black/60 px-3 py-1.5 text-caption font-semibold text-white backdrop-blur ${className}`}
      data-testid="reels-unmute"
    >
      <SpeakerGlyph muted className="size-4" />
      {wording === "click" ? t("library.reels.clickToUnmute") : t("library.reels.tapToUnmute")}
    </button>
  );
}

/** 画质菜单：触发器由版式给样式（手机是横带下方的描边胶囊，电脑在画面控制条上） */
export function QualityMenu({
  quality,
  className,
  side = "top",
}: {
  quality: QualityControl;
  className: string;
  side?: "top" | "bottom";
}) {
  const t = useTranslations();
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          className={className}
          aria-label={t("library.reels.qualityValue", { value: quality.label })}
          data-testid="reels-quality"
        >
          {quality.label}
          <ChevronDownIcon className="size-3" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content side={side} align="center" sideOffset={8} collisionPadding={12} className="menu-surface z-50 min-w-[12rem] p-1">
          <DropdownMenu.Label className="px-3 pb-1 pt-1.5 text-caption text-[var(--text-faint)]">
            {t("library.filters.quality")}
          </DropdownMenu.Label>
          {quality.options.map((option) => (
            <DropdownMenu.Item
              key={String(option.maxHeight)}
              onSelect={() => quality.onSelect(option.maxHeight)}
              className="glass-row nav-item flex cursor-pointer items-start gap-2 px-3 py-2 text-sub outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)]"
              data-testid={`reels-quality-${option.maxHeight ?? "original"}`}
            >
              <span className="flex size-4 shrink-0 items-center justify-center pt-0.5">
                {option.maxHeight === quality.value && <CheckIcon className="size-3.5 text-[var(--info)]" />}
              </span>
              <span className="min-w-0">
                <span className={`block font-medium ${option.maxHeight === quality.value ? "text-white" : "text-white/75"}`}>
                  {option.label}
                </span>
                {option.hint && <span className="block text-caption leading-4 text-white/40">{option.hint}</span>}
              </span>
            </DropdownMenu.Item>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** 第一页还没挑出来 / 挑完是空的 / 加载失败：两种版式同一套说法 */
export function ReelsEmptyState({ reels }: { reels: Reels }) {
  const t = useTranslations();
  const { feed } = reels;
  let body: ReactNode;
  if (reels.loadFailed) {
    body = (
      <div className="grid gap-3">
        <p className="text-sub text-white/80">{t("library.reels.loadFailed")}</p>
        <button type="button" onClick={reels.retry} className="btn-glass mx-auto">
          {t("common.retry")}
        </button>
      </div>
    );
  } else if (feed === null) {
    body = <p className="text-sub text-[var(--text-muted)]">{t("library.reels.picking")}</p>;
  } else if (reels.filtered && !feed.clips) {
    body = (
      <div className="grid gap-3" data-testid="reels-empty">
        <p className="text-sub text-white/85">{t("library.reels.noneForFilters")}</p>
        <button type="button" onClick={() => reels.applyFilter({ filter: {}, kind: null })} className="btn-glass mx-auto">
          {t("media.discovery.clearFilters")}
        </button>
      </div>
    );
  } else {
    body = (
      <div className="grid gap-2" data-testid="reels-empty">
        <p className="text-sub text-white/85">
          {feed.clips
            ? t("library.reels.precutProgress", { ready: feed.clips.ready, total: feed.clips.total })
            : t("library.reels.noneInLibrary")}
        </p>
        {feed.clips && <p className="text-caption text-[var(--text-muted)]">{t("library.reels.comeBackLater")}</p>}
      </div>
    );
  }
  return <div className="absolute inset-0 z-20 grid place-items-center px-8 text-center">{body}</div>;
}

/** 超管点分享：详情页同一个分享链接弹窗 */
export function ReelsShareDialog({ reels }: { reels: Reels }) {
  const sharing = reels.sharing;
  if (!sharing) return null;
  return (
    <ShareDialog
      open
      onClose={reels.closeShare}
      libraryId={sharing.item.title.library_id}
      mediaItemId={sharing.item.title.media_item_id}
      title={sharing.item.title.name}
      kind={sharing.item.title.kind}
      year={sharing.item.title.year}
      posterUrl={sharing.item.title.poster_url}
      initialShare={sharing.share}
    />
  );
}

/**
 * 已看：跟着真实观看进度画（同 iOS）——没看完时是暗圈，看了多少白色弧就描多少（没看过 = 一圈暗的）；
 * 看完是绿色实心。没看过不用亮白整圈：那样和「快看完」分不开。
 */
export function PlayedGlyph({ played, progress, className = "size-7" }: { played: boolean; progress: number | null; className?: string }) {
  const radius = 10.25;
  const circumference = 2 * Math.PI * radius;
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" aria-hidden>
      {played ? (
        <circle cx="12" cy="12" r="11" fill="var(--ok)" />
      ) : (
        <>
          <circle cx="12" cy="12" r={radius} stroke="rgba(255,255,255,0.32)" strokeWidth="1.8" />
          {progress ? (
            <circle
              cx="12"
              cy="12"
              r={radius}
              stroke="white"
              strokeWidth="1.8"
              strokeLinecap="round"
              strokeDasharray={`${(circumference * progress) / 100} ${circumference}`}
              transform="rotate(-90 12 12)"
            />
          ) : null}
        </>
      )}
      <path d="m7.6 12.3 3 3 5.8-6.3" stroke={played ? "black" : "white"} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function ShareGlyph({ className = "size-7" }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M13.5 5.5 20 11.5l-6.5 6v-3.6c-4.4 0-7.4 1.3-9.5 4.6.6-4.9 3.3-8.6 9.5-9.4V5.5Z" />
    </svg>
  );
}

export function SpeakerGlyph({ muted, className = "size-7" }: { muted: boolean; className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M11 5 6 9H3v6h3l5 4V5Z" fill="currentColor" stroke="none" />
      {muted ? <path d="m16 9 5 6m0-6-5 6" /> : <path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13" />}
    </svg>
  );
}
