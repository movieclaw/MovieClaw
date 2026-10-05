"use client";

import type { Route } from "next";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useState } from "react";

import { PlayIcon } from "@/components/icons";
import { ImmersiveHero } from "@/components/immersive-hero";
import {
  FittedLine,
  SubsHomeDot,
  SubsHomeProgressLine,
} from "@/components/subscriptions-home-kit";
import { imageUrl, screenImageWidth } from "@/lib/image-proxy";
import { markPlayIntent, playHref, rememberPlayerReturnPath } from "@/lib/player/play-links";
import { SUBS_HOME_TONE_COLOR, type SubsHomeHeroSlide } from "@/lib/subscriptions-home";
import { useTapGuard } from "@/lib/use-tap-guard";

/**
 * 订阅首页的沉浸 Hero：「下一部到手的」轮播（对照 iOS SubscriptionsHomeHero.swift）。
 *
 * 与发现页 Hero 刻意区分：发现页是编辑推荐（剧照 + 片名 + 简介 + 订阅键，左对齐），
 * 这里是**时间驱动**的——居中的片名 Logo 下面讲「几点能看」，大号细体时刻是主角，
 * 刚到的那张主按钮直接播放。剧照层、8 秒轮播与指示器交给通用的 ImmersiveHero。
 *
 * 高度：手机从屏幕物理顶边算起约 500px（比发现页略低，首屏底部露出「刚刚入库」的标题，
 * 暗示下面还有内容），矮屏按视口收；桌面是主区玻璃卡片顶部的一块。
 */
export const SUBS_HOME_HERO_HEIGHT =
  "h-[min(560px,58vh)] min-h-[380px] max-md:h-[min(500px,70svh)] max-md:min-h-[420px]";

/**
 * Hero 剧照的基础地址：有宽幅剧照用剧照，老条目没有剧照时退回海报铺满。
 * 不带宽度——剧照层按框实测尺寸、窗口背景按整窗、氛围取色按 240 小图各自带 w。
 */
export function heroImageOf(slide: SubsHomeHeroSlide): string | undefined {
  const raw = slide.media.backdrop_url ?? slide.media.poster_url;
  return raw ? imageUrl(raw) : undefined;
}

export function SubsHomeHero({
  slides,
  index,
  onIndexChange,
}: {
  slides: SubsHomeHeroSlide[];
  index: number;
  onIndexChange: (index: number) => void;
}) {
  const router = useRouter();
  const openSubscription = useCallback(
    (slide: SubsHomeHeroSlide) => router.push(`/subscriptions/${slide.subscriptionId}` as Route),
    [router],
  );
  return (
    <ImmersiveHero
      slides={slides}
      index={index}
      onIndexChange={onIndexChange}
      slideKey={(slide) => slide.subscriptionId}
      imageOf={heroImageOf}
      onActivate={openSubscription}
      activateLabel={heroAccessibilityText}
      indicatorLabel={(slide) => `切换到《${slide.media.title}》`}
      renderContent={(slide) => <HeroContent slide={slide} />}
      className={SUBS_HOME_HERO_HEIGHT}
    />
  );
}

/** 整张 Hero 的读屏文字：状态文字只进这里（画面上状态只剩一颗小圆点） */
function heroAccessibilityText(slide: SubsHomeHeroSlide): string {
  return [
    `《${slide.media.title}》`,
    slide.eyebrow.text,
    slide.clockLabel,
    slide.clock,
    slide.detail,
    slide.footnote,
  ]
    .filter(Boolean)
    .join("，");
}

function HeroContent({ slide }: { slide: SubsHomeHeroSlide }) {
  // 时刻数字用大号细体；纯中文的词（「马上就好」「周四」）同样大小会压过片名 Logo，降一档用轻体
  const numeric = slide.clock ? /\d/.test(slide.clock) : false;
  return (
    // 沉浸外框下按内容区居中（大图伸到侧栏底下，左边让出 --immersive-inset）
    <div className="pl-[var(--immersive-inset,0px)]">
    <div className="mx-auto flex max-w-xl flex-col items-center px-7 pb-11 text-center">
      <TitleArt slide={slide} />
      {slide.clock ? (
        <>
          {/* 讲时间的：状态小圆点 + 一句说明（放不下留尾），下面是大号细体时刻 */}
          <StatusLine slide={slide} text={slide.clockLabel} keep="head" />
          <p
            className={`tnum mt-0.5 max-w-full truncate leading-tight text-white ${
              numeric ? "text-[48px] font-thin" : "text-[36px] font-light"
            }`}
          >
            {slide.clock}
          </p>
        </>
      ) : (
        <>
          <StatusLine slide={slide} text={slide.detail} keep="tail" />
          {slide.footnote && (
            <div className="mt-1.5 w-full">
              <FittedLine
                text={slide.footnote}
                keep="tail"
                className="tnum text-[13px] text-white/60"
              />
            </div>
          )}
        </>
      )}
      {slide.progress != null && (
        <SubsHomeProgressLine
          value={slide.progress}
          color={SUBS_HOME_TONE_COLOR.live}
          className="mt-3 w-[168px]"
        />
      )}
      <PrimaryButton slide={slide} />
    </div>
    </div>
  );
}

/**
 * Logo 下第一行：状态小圆点 + 一句说明。状态有用但不是重点（用户拍板：文字标签太重），
 * 只留一颗 7px 的点：绿 = 刚到 / 整理中，琥珀 = 等资源，蓝 = 下载中（呼吸），淡紫 = 今天更新；
 * 平常状态（即将更新、追踪中）不放点。状态文字在整张的读屏标签里。
 */
function StatusLine({
  slide,
  text,
  keep,
}: {
  slide: SubsHomeHeroSlide;
  text: string | null;
  keep: "head" | "tail";
}) {
  const showDot = slide.eyebrow.tone !== "calm";
  const dot = showDot ? (
    <SubsHomeDot tone={slide.eyebrow.tone} pulse={slide.eyebrow.pulse} size={7} />
  ) : null;
  if (!text) return dot ? <div className="mt-4 flex justify-center">{dot}</div> : null;
  return (
    <div className="mt-4 w-full">
      <FittedLine
        text={text}
        keep={keep}
        reserve={showDot ? 14 : 0}
        className="tnum text-[15px] font-semibold text-white/90"
      >
        {dot}
      </FittedLine>
    </div>
  );
}

/**
 * 片名：有 Logo 用 Logo（透明底 PNG，不带派生预设以保住透明通道），没有或加载失败退回文字片名。
 * 固定占一块 88px 高的框：各张高度一致，轮播时下面的文字不上下跳。
 */
function TitleArt({ slide }: { slide: SubsHomeHeroSlide }) {
  const [failed, setFailed] = useState(false);
  // Logo 靠固有尺寸撑开（max-w 240），不用 srcset，按显示宽 × 倍率拼固定 w
  const logo =
    slide.media.logo_url && !failed
      ? imageUrl(slide.media.logo_url, { width: screenImageWidth(240) })
      : null;
  return (
    <div aria-hidden="true" className="flex h-[88px] w-full max-w-[300px] items-end justify-center">
      {logo ? (
        <img
          src={logo}
          alt=""
          decoding="async"
          referrerPolicy="no-referrer"
          onError={() => setFailed(true)}
          className="max-h-[88px] max-w-[240px] object-contain drop-shadow-[0_4px_14px_rgba(0,0,0,0.45)]"
        />
      ) : (
        <p className="line-clamp-2 text-[34px] font-bold leading-[1.1] tracking-[-0.01em] text-white [text-shadow:0_3px_12px_rgba(0,0,0,0.45)]">
          {slide.media.title}
        </p>
      )}
    </div>
  );
}

/**
 * 主按钮：刚到的那张是「播放 / 继续播放」（白底黑字，同影片页的播放键，直接进播放页），
 * 其余是「查看订阅」（玻璃）。它嵌在整张可点的 Hero 里，点击必须 stopPropagation，
 * 否则会同时进订阅详情；横滑 Hero 时手指停在按钮上的误触由 useTapGuard 拦下。
 */
function PrimaryButton({ slide }: { slide: SubsHomeHeroSlide }) {
  const playGuard = useTapGuard(() => {
    rememberPlayerReturnPath("/subscriptions");
    markPlayIntent();
  });
  const detailGuard = useTapGuard();
  const base =
    "mt-5 inline-flex h-11 items-center justify-center gap-2 rounded-full px-6 text-[15px] font-semibold transition active:scale-[0.97] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/80";
  if (slide.play) {
    const { mediaItemId, season, episode } = slide.play;
    return (
      <Link
        href={playHref(mediaItemId, { season, episode }) as Route}
        aria-label={`播放《${slide.media.title}》${slide.detail ? ` ${slide.detail}` : ""}`}
        onPointerDown={playGuard.onPointerDown}
        onPointerUp={playGuard.onPointerUp}
        onPointerCancel={playGuard.onPointerCancel}
        onClick={(event) => {
          event.stopPropagation();
          playGuard.onClick(event);
        }}
        className={`${base} bg-white text-black hover:bg-white/90`}
      >
        <PlayIcon className="size-5" />
        {slide.resumePercent == null ? "播放" : "继续播放"}
      </Link>
    );
  }
  return (
    <Link
      href={`/subscriptions/${slide.subscriptionId}` as Route}
      aria-label={`查看《${slide.media.title}》的订阅`}
      onPointerDown={detailGuard.onPointerDown}
      onPointerUp={detailGuard.onPointerUp}
      onPointerCancel={detailGuard.onPointerCancel}
      onClick={(event) => {
        event.stopPropagation();
        detailGuard.onClick(event);
      }}
      className={`${base} bg-white/[0.16] text-white ring-1 ring-white/20 backdrop-blur-md hover:bg-white/[0.24]`}
    >
      查看订阅
    </Link>
  );
}
