"use client";

import type { Route } from "next";
import Link from "next/link";
import { useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from "react";

import { ChevronRightIcon, PosterGridIcon } from "@/components/icons";
import { PosterImage } from "@/components/poster-image";
import { imageUrl } from "@/lib/image-proxy";
import {
  SUBS_HOME_TONE_COLOR,
  shortenCandidates,
  toneGlows,
  type SubsHomeChip,
  type SubsHomeShelfItem,
  type SubsHomeTone,
} from "@/lib/subscriptions-home";
import { useTapGuard } from "@/lib/use-tap-guard";

/**
 * 订阅首页的小部件：状态小圆点、海报状态签、发丝进度线、版块标题、按段收短的信息行、
 * 海报卡（首页横滑与「全部」海报墙共用）。口径对照 iOS 的 SubscriptionsHomeHero.swift
 * （小部件段）与 SubscriptionsHomeSections.swift。
 */

/** 版块左右留白：手机 16px，桌面 24px（与全站 page-inset 同档） */
export const SUBS_HOME_INSET = "px-4 md:px-6";

/**
 * 状态小圆点：「正在发生」的两档（下载中 / 整理中 / 刚到）带柔光，
 * pulse 再加呼吸（0.9 秒往返）。颜色是状态唯一的视觉表达，文字只给读屏。
 */
export function SubsHomeDot({
  tone,
  pulse = false,
  size = 6,
}: {
  tone: SubsHomeTone;
  pulse?: boolean;
  size?: number;
}) {
  const color = SUBS_HOME_TONE_COLOR[tone];
  return (
    <span
      aria-hidden="true"
      className={`inline-block shrink-0 rounded-full ${pulse ? "subs-home-breathe" : ""}`}
      style={{
        width: size,
        height: size,
        background: color,
        boxShadow: toneGlows(tone)
          ? `0 0 ${Math.round(size * 1.2)}px color-mix(in srgb, ${color} 75%, transparent)`
          : undefined,
      }}
    />
  );
}

/** 海报上的状态小签：暗色毛玻璃胶囊，颜色只落在圆点与文字上（平常语气用白字） */
export function SubsHomeChipView({ chip }: { chip: SubsHomeChip }) {
  return (
    <span
      className="tnum inline-flex max-w-full items-center gap-1 whitespace-nowrap rounded-full bg-black/40 px-[7px] py-1 text-[10.5px] font-semibold leading-none backdrop-blur-md"
      style={{ color: chip.tone === "calm" ? "rgba(255,255,255,0.9)" : SUBS_HOME_TONE_COLOR[chip.tone] }}
    >
      <SubsHomeDot tone={chip.tone} pulse={chip.pulse} size={5} />
      {chip.text}
    </span>
  );
}

/** 发丝进度线：底槽 + 带柔光的进度段（下载进度、海报收录、续播进度共用） */
export function SubsHomeProgressLine({
  value,
  color = "#fff",
  height = 3,
  className = "",
}: {
  value: number;
  color?: string;
  height?: number;
  className?: string;
}) {
  const percent = Math.min(Math.max(value, 0), 1) * 100;
  return (
    <div
      aria-hidden="true"
      className={`relative overflow-visible rounded-full bg-white/20 ${className}`}
      style={{ height }}
    >
      <div
        className="absolute inset-y-0 left-0 rounded-full"
        style={{
          width: `max(${height}px, ${percent}%)`,
          background: color,
          boxShadow: `0 0 4px color-mix(in srgb, ${color} 60%, transparent)`,
        }}
      />
    </div>
  );
}

/** 版块标题：粗体标题（可点时带「›」进二级页）+ 右侧一句弱化的计数 */
export function SubsHomeSectionHeader({
  title,
  trailing,
  href,
  id,
}: {
  title: string;
  trailing?: string | null;
  href?: Route;
  id?: string;
}) {
  return (
    <div className={`flex items-baseline justify-between gap-3 ${SUBS_HOME_INSET}`}>
      <h3 id={id} className="min-w-0 text-[20px] font-bold leading-tight text-[var(--text)]">
        {href ? (
          <Link
            href={href}
            aria-label={`${title}，查看全部`}
            className="group inline-flex items-baseline gap-1 outline-none focus-visible:underline"
          >
            {title}
            <ChevronRightIcon className="size-4 translate-y-[2px] text-[var(--text-faint)] transition group-hover:translate-x-0.5 group-hover:text-[var(--text-muted)]" />
          </Link>
        ) : (
          title
        )}
      </h3>
      {trailing && (
        <span className="tnum shrink-0 text-[13px] text-[var(--text-faint)]">{trailing}</span>
      )}
    </div>
  );
}

/**
 * 一行不折行的文字：放不下就按「 · 」分段逐段收短（候选见 shortenCandidates），
 * 最短的写法仍放不下才省略号兜底。对应 iOS 的 ViewThatFits + SubsHomeShortening。
 *
 * 做法：在不可见的量尺里把全部候选排成单行量宽，挑第一个不超过可用宽度的；
 * 可用宽度 = 本元素（占满父级宽度）宽度 - reserve（同行的小圆点等）。
 * 容器变宽变窄、字体晚到都会触发重量（ResizeObserver 同时盯容器与量尺）。
 */
export function FittedLine({
  text,
  keep,
  reserve = 0,
  className = "",
  style,
  children,
}: {
  text: string;
  keep: "head" | "tail";
  /** 同一行里文字之外占掉的宽度（px） */
  reserve?: number;
  /** 文字的字形类（量尺与显示共用，必须一致才量得准） */
  className?: string;
  style?: CSSProperties;
  /** 排在文字前面的内容（如状态小圆点），宽度要算进 reserve */
  children?: React.ReactNode;
}) {
  const options = useMemo(() => shortenCandidates(text, keep), [text, keep]);
  const boxRef = useRef<HTMLDivElement>(null);
  const rulerRef = useRef<HTMLDivElement>(null);
  const [pick, setPick] = useState(0);

  useLayoutEffect(() => {
    const box = boxRef.current;
    const ruler = rulerRef.current;
    if (!box || !ruler) return;
    const fit = () => {
      const available = box.clientWidth - reserve;
      const spans = Array.from(ruler.children) as HTMLElement[];
      const index = spans.findIndex((span) => span.offsetWidth <= available);
      setPick(index === -1 ? options.length - 1 : index);
    };
    fit();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(fit);
    observer.observe(box);
    for (const span of Array.from(ruler.children)) observer.observe(span);
    return () => observer.disconnect();
  }, [options, reserve]);

  return (
    <div ref={boxRef} className="relative w-full min-w-0">
      <div ref={rulerRef} aria-hidden="true" className="invisible absolute left-0 top-0 h-0 overflow-hidden">
        {options.map((option) => (
          <span key={option} className={`block w-max whitespace-nowrap ${className}`} style={style}>
            {option}
          </span>
        ))}
      </div>
      <div className="flex min-w-0 items-center justify-center gap-[7px]">
        {children}
        <span className={`min-w-0 truncate whitespace-nowrap ${className}`} style={style}>
          {options[Math.min(pick, options.length - 1)]}
        </span>
      </div>
    </div>
  );
}

/**
 * 海报卡：只留一个状态小签 + 进行中剧集的当季收录细线，其余交给下面两行字。
 * 首页横滑与海报墙共用这一张，状态签与顺序两处一致；墙上多一行「规则组 → 媒体库」流向。
 * 点击进订阅详情；横滑时的误触由 useTapGuard 拦下。
 */
export function SubsHomePosterCard({
  item,
  flow,
  dimsResting = true,
}: {
  item: SubsHomeShelfItem;
  /** 海报墙的第三行（规则组 → 媒体库）；首页横滑不带 */
  flow?: string | null;
  /** 已暂停 / 已完成是否压暗：首页一排靠压暗衬出分隔线；海报墙已按分段标题分组，保持原色 */
  dimsResting?: boolean;
}) {
  const tapGuard = useTapGuard();
  const { sub, chip, meta, progress } = item;
  const dimmed = dimsResting && item.resting;
  return (
    <Link
      href={`/subscriptions/${sub.id}` as Route}
      data-subscription-id={sub.id}
      aria-label={[`《${sub.media.title}》`, chip?.text, meta, flow].filter(Boolean).join("，")}
      {...tapGuard}
      className="group/poster block outline-none"
    >
      <div
        className={`relative aspect-[2/3] overflow-hidden rounded-xl bg-[var(--poster-placeholder)] ring-1 ring-white/[0.08] transition duration-300 group-hover/poster:-translate-y-0.5 group-hover/poster:ring-white/25 group-focus-visible/poster:ring-2 group-focus-visible/poster:ring-white/80 group-active/poster:scale-[0.97] ${
          dimmed ? "shadow-[0_6px_10px_rgba(0,0,0,0.18)]" : "shadow-[0_6px_14px_rgba(0,0,0,0.4)]"
        }`}
      >
        <PosterImage
          src={sub.media.poster_url ? imageUrl(sub.media.poster_url) : null}
          // 首页横滑卡与订阅墙格子 minmax(140px,1fr)，按 180 取
          width={180}
          alt=""
          className={`absolute inset-0 size-full object-cover ${dimmed ? "brightness-[0.88] saturate-[0.35]" : ""}`}
        />
        {progress != null && (
          <div className="pointer-events-none absolute inset-x-0 bottom-0 h-[34px] bg-gradient-to-b from-transparent to-black/55">
            <SubsHomeProgressLine
              value={progress}
              color="rgba(255,255,255,0.92)"
              height={2.5}
              className="absolute inset-x-[9px] bottom-2"
            />
          </div>
        )}
        {chip && (
          <div className="pointer-events-none absolute left-[7px] right-[7px] top-[7px] flex">
            <SubsHomeChipView chip={chip} />
          </div>
        )}
      </div>
      <p
        className={`mt-2 truncate text-[13px] font-semibold ${
          dimmed ? "text-[var(--text-muted)]" : "text-[var(--text)]"
        }`}
      >
        {sub.media.title}
      </p>
      <p className="tnum mt-px truncate text-[12px] text-[var(--text-faint)]">{meta}</p>
      {flow && <p className="mt-px truncate text-[11px] text-[var(--text-faint)]">{flow}</p>}
    </Link>
  );
}

/** 横滑末尾的「查看全部」：与海报同尺寸的一块透明玻璃，排在最后一张之后 */
export function SubsHomeSeeAllCard({ href, total }: { href: Route; total: number }) {
  return (
    <Link
      href={href}
      aria-label={`查看全部 ${total} 部`}
      className="flex aspect-[2/3] flex-col items-center justify-center gap-2 rounded-xl bg-white/[0.045] ring-1 ring-white/[0.09] transition hover:bg-white/[0.08] active:scale-[0.97]"
    >
      <PosterGridIcon className="size-[22px] text-[var(--text-muted)]" />
      <span className="text-[13px] font-semibold text-[var(--text)]">查看全部</span>
      <span className="tnum text-[12px] text-[var(--text-faint)]">{total} 部</span>
    </Link>
  );
}
