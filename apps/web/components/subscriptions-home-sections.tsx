"use client";

import type { Route } from "next";
import Link from "next/link";
import { Fragment, useState } from "react";

import { HScroller } from "@/components/h-scroller";
import { ChevronRightIcon, PlayIcon } from "@/components/icons";
import { PosterImage } from "@/components/poster-image";
import {
  SUBS_HOME_INSET,
  SubsHomeChipView,
  SubsHomeDot,
  SubsHomePosterCard,
  SubsHomeProgressLine,
  SubsHomeSectionHeader,
  SubsHomeSeeAllCard,
} from "@/components/subscriptions-home-kit";
import type { RecentSubscriptionArrival } from "@/lib/api/subscriptions";
import { imageUrl, screenImageWidth } from "@/lib/image-proxy";
import { markPlayIntent, playHref, rememberPlayerReturnPath } from "@/lib/player/play-links";
import {
  SHELF_ROW_LIMIT,
  SUBS_HOME_TONE_COLOR,
  playRequest,
  recentDetail,
  recentNote,
  shelfAll,
  shelfCountSummary,
  shelfResting,
  toneGlows,
  type SubsHomeScheduleDay,
  type SubsHomeScheduleEntry,
  type SubsHomeShelf,
} from "@/lib/subscriptions-home";
import { useTapGuard } from "@/lib/use-tap-guard";

/**
 * 订阅首页 Hero 以下的三种版块（对照 iOS SubscriptionsHomeSections.swift）：
 * 刚刚入库（16:9 剧照横滑）、日程（日期条 + 当天议程）、剧集 / 电影海报行。
 * 三种形状刻意不同——横卡、竖列、竖海报——一页里有节奏，而不是同一种横滑行一排排往下堆。
 */

// —— 刚刚入库 ——

/**
 * 「刚刚入库」：订阅的回报时刻。一部作品一张 16:9 剧照卡，点一下直接播放（入口是这一批里
 * 第一个没看完的单元）；看完的作品服务端不再返回，这一行自然消失。
 */
export function SubsHomeRecentRow({
  cards,
  now,
}: {
  cards: RecentSubscriptionArrival[];
  now: Date;
}) {
  return (
    <section aria-labelledby="subs-recent-title">
      <SubsHomeSectionHeader
        id="subs-recent-title"
        title="刚刚入库"
        trailing={cards.length > 1 ? `${cards.length} 部` : null}
      />
      <HScroller className={`mt-3 gap-3.5 pb-2 pt-1 ${SUBS_HOME_INSET}`}>
        {cards.map((card) => (
          <RecentCard key={card.subscription_id} card={card} now={now} />
        ))}
      </HScroller>
    </section>
  );
}

function RecentCard({ card, now }: { card: RecentSubscriptionArrival; now: Date }) {
  // 横滑这一行时手指常停在卡上，没有误触判定一划就起播了（会真的开转码会话）
  const tapGuard = useTapGuard(() => {
    rememberPlayerReturnPath("/subscriptions");
    markPlayIntent();
  });
  const detail = recentDetail(card);
  const note = recentNote(card, now);
  const { mediaItemId, season, episode } = playRequest(card);
  // 剧集用这一集的剧照；电影和缺剧照的集用作品剧照，再没有退回海报
  const artwork = card.still_url ?? card.media.backdrop_url ?? card.media.poster_url;
  // Logo 靠固有尺寸撑开（max-w 118），不用 srcset，按显示宽 × 倍率拼固定 w
  const logo = card.media.logo_url ? imageUrl(card.media.logo_url, { width: screenImageWidth(118) }) : null;
  return (
    <Link
      href={playHref(mediaItemId, { season, episode }) as Route}
      aria-label={`播放《${card.media.title}》，${detail}${note ? `，${note}` : ""}`}
      {...tapGuard}
      className="group/recent block w-[264px] shrink-0 outline-none md:w-[300px]"
    >
      <div className="relative aspect-video overflow-hidden rounded-[14px] bg-[var(--poster-placeholder)] shadow-[0_6px_12px_rgba(0,0,0,0.35)] ring-1 ring-white/[0.08] transition duration-300 group-hover/recent:-translate-y-0.5 group-hover/recent:ring-white/25 group-focus-visible/recent:ring-2 group-focus-visible/recent:ring-white/80 group-active/recent:scale-[0.97]">
        <PosterImage
          src={artwork ? imageUrl(artwork) : null}
          // 卡宽 264（桌面 300）、16:9；退回海报时竖图铺横框也是贴宽，同样按卡宽取
          width={300}
          alt=""
          className="absolute inset-0 size-full object-cover"
        />
        <div className="pointer-events-none absolute inset-x-0 bottom-0 h-[76px] bg-gradient-to-b from-transparent to-black/[0.72]" />
        {logo && <RecentLogo src={logo} />}
        {/* 右下角的播放圆钮：说明「这张卡能直接看」 */}
        <span className="pointer-events-none absolute bottom-2.5 right-2.5 flex size-9 items-center justify-center rounded-full bg-white/[0.18] text-white ring-1 ring-white/25 backdrop-blur-md">
          <PlayIcon className="size-[18px]" />
        </span>
        {card.units.length > 1 && (
          <div className="pointer-events-none absolute left-[9px] top-[9px]">
            <SubsHomeChipView chip={{ text: `新 ${card.units.length} 集`, tone: "ok" }} />
          </div>
        )}
        {card.progress_percent != null && (
          <SubsHomeProgressLine
            value={card.progress_percent / 100}
            className="absolute inset-x-0 bottom-0 !rounded-none"
          />
        )}
      </div>
      <p className="mt-2.5 truncate text-[15px] font-semibold text-[var(--text)]">{card.media.title}</p>
      <p className="tnum mt-0.5 truncate text-[13px] text-[var(--text-muted)]">{detail}</p>
      {note && <p className="tnum mt-0.5 truncate text-[12px] text-[var(--text-faint)]">{note}</p>}
    </Link>
  );
}

/** 卡片左下角的小号片名 Logo（没有或加载失败就不画，片名在卡片下面） */
function RecentLogo({ src }: { src: string }) {
  const [failed, setFailed] = useState(false);
  if (failed) return null;
  return (
    <img
      src={src}
      alt=""
      decoding="async"
      referrerPolicy="no-referrer"
      onError={() => setFailed(true)}
      className="pointer-events-none absolute bottom-3 left-3 max-h-[34px] max-w-[118px] object-contain object-left-bottom drop-shadow-[0_1px_6px_rgba(0,0,0,0.6)]"
    />
  );
}

// —— 日程 ——

/**
 * 「日程」：今天起一周的日期条 + 选中那天的议程。
 *
 * Hero 只挑亮点，扫全貌靠这里。日期条上的小圆点是当天的更新数（有正在下载 / 整理的，圆点带状态色）；
 * 没有更新的日子照样占位但点不了——一周的节奏本身就是信息。议程是一列竖排：左列大号时刻、
 * 中间剧照、右边片名与集号，和上下两排横滑行形状不同，页面有呼吸。
 */
export function SubsHomeSchedule({ days }: { days: SubsHomeScheduleDay[] }) {
  // null = 默认选中第一个有安排的日子
  const [selected, setSelected] = useState<number | null>(null);
  const pick = selected ?? days.find((day) => day.entries.length > 0)?.daysAhead;
  const current = days.find((day) => day.daysAhead === pick) ?? days[0];
  if (!current) return null;
  const caption =
    current.entries.length === 0
      ? current.dateLabel
      : `${current.dateLabel} · ${current.entries.length} 部`;

  return (
    <section aria-labelledby="subs-schedule-title">
      <SubsHomeSectionHeader id="subs-schedule-title" title="日程" trailing={caption} />
      <div className={`mt-3 md:max-w-[720px] ${SUBS_HOME_INSET}`}>
        <div
          role="tablist"
          aria-label="一周日程"
          className="grid gap-1.5"
          style={{ gridTemplateColumns: `repeat(${days.length}, minmax(0, 1fr))` }}
        >
          {days.map((day) => (
            <ScheduleDayChip
              key={day.daysAhead}
              day={day}
              on={day.daysAhead === current.daysAhead}
              onSelect={() => setSelected(day.daysAhead)}
            />
          ))}
        </div>
        {current.entries.length > 0 && (
          <div
            key={current.daysAhead}
            role="tabpanel"
            className="mt-3 animate-[immersive-hero-ambient-in_0.3s_ease-out_both] rounded-[22px] bg-white/[0.045] py-1 ring-1 ring-inset ring-white/[0.07]"
          >
            {current.entries.map((entry, offset) => (
              <Fragment key={entry.subscriptionId}>
                {offset > 0 && <div className="ml-[86px] h-px bg-white/[0.06]" />}
                <AgendaRow entry={entry} />
              </Fragment>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}

function ScheduleDayChip({
  day,
  on,
  onSelect,
}: {
  day: SubsHomeScheduleDay;
  on: boolean;
  onSelect: () => void;
}) {
  const empty = day.entries.length === 0;
  // 日期条小圆点：当天有正在发生的（下载 / 整理）就亮状态色，否则中性白
  const glowing = day.entries.find((entry) => toneGlows(entry.tone));
  const dotColor = on
    ? "rgba(0,0,0,0.4)"
    : glowing
      ? SUBS_HOME_TONE_COLOR[glowing.tone]
      : "rgba(255,255,255,0.45)";
  return (
    <button
      type="button"
      role="tab"
      aria-selected={on}
      disabled={empty}
      onClick={onSelect}
      aria-label={`${day.weekday}，${day.dateLabel}，${empty ? "没有更新" : `${day.entries.length} 部更新`}`}
      className={`flex flex-col items-center gap-[3px] rounded-[15px] py-[9px] transition duration-300 active:scale-[0.92] disabled:opacity-[0.36] ${
        on ? "bg-white" : "bg-white/[0.05] ring-1 ring-inset ring-white/[0.07]"
      }`}
    >
      <span
        className={`text-[11px] font-semibold ${on ? "text-black/55" : "text-[var(--text-muted)]"}`}
      >
        {day.weekday}
      </span>
      <span
        className={`tnum text-[19px] leading-tight ${on ? "font-bold text-black" : "font-medium text-[var(--text)]"}`}
      >
        {day.dayNumber}
      </span>
      <span className="flex h-1 items-center gap-[3px]" aria-hidden="true">
        {day.entries.slice(0, 3).map((entry) => (
          <span
            key={entry.subscriptionId}
            className="size-1 rounded-full"
            style={{ background: dotColor }}
          />
        ))}
      </span>
    </button>
  );
}

function AgendaRow({ entry }: { entry: SubsHomeScheduleEntry }) {
  const artwork = entry.media?.backdrop_url ?? entry.media?.poster_url;
  return (
    <Link
      href={`/subscriptions/${entry.subscriptionId}` as Route}
      aria-label={`《${entry.title}》${entry.episodeLabel}，${entry.status}，${entry.time ?? "时间待定"}`}
      className="flex items-center gap-3 rounded-[18px] px-3 py-2.5 outline-none transition hover:bg-white/[0.04] focus-visible:ring-2 focus-visible:ring-white/60"
    >
      <div className="w-[62px] shrink-0">
        <p
          className={`tnum text-[20px] leading-tight ${
            entry.time ? "font-semibold text-[var(--text)]" : "text-[var(--text-faint)]"
          }`}
        >
          {entry.time ?? "待定"}
        </p>
        <p
          className="tnum mt-[3px] flex items-center gap-1 whitespace-nowrap text-[11px] font-semibold"
          style={{ color: SUBS_HOME_TONE_COLOR[entry.tone] }}
        >
          <SubsHomeDot tone={entry.tone} pulse={entry.tone === "live"} size={5} />
          <span className="truncate">{entry.status}</span>
        </p>
      </div>
      <div className="relative h-[52px] w-[92px] shrink-0 overflow-hidden rounded-[9px] bg-[var(--poster-placeholder)] ring-1 ring-inset ring-white/[0.08]">
        <PosterImage
          src={artwork ? imageUrl(artwork) : null}
          width={92}
          alt=""
          className="absolute inset-0 size-full object-cover"
        />
        {entry.progress != null && (
          <SubsHomeProgressLine
            value={entry.progress}
            color={SUBS_HOME_TONE_COLOR.live}
            height={2.5}
            className="absolute inset-x-1.5 bottom-[5px]"
          />
        )}
      </div>
      <div className="min-w-0 flex-1">
        <p className="truncate text-[15px] font-semibold text-[var(--text)]">{entry.title}</p>
        <p className="tnum mt-[3px] truncate text-[13px] text-[var(--text-muted)]">{entry.episodeLabel}</p>
      </div>
      <ChevronRightIcon className="size-3.5 shrink-0 text-[var(--text-faint)]" />
    </Link>
  );
}

// —— 海报行 ——

/**
 * 剧集 / 电影海报行：进行中的在前（此刻最要紧的排最左，连没上映的也算进行中），
 * 已暂停 / 已完成压暗排在一道竖排小字的分隔线后面。
 *
 * 横滑最多放 20 张：一排是浏览亮点的地方，翻到底要十几下就不再是「一眼扫过」；
 * 超出时末尾放一张「查看全部」卡，与标题「›」一样进完整海报墙（/subscriptions/wall/[kind]），
 * 墙上是同一份排好的结果，顺序不变。
 */
export function SubsHomeShelfRow({
  title,
  kind,
  shelf,
}: {
  title: string;
  kind: "movie" | "tv";
  shelf: SubsHomeShelf;
}) {
  const wallHref = `/subscriptions/wall/${kind}` as Route;
  const active = shelf.active.slice(0, SHELF_ROW_LIMIT);
  const resting = shelfResting(shelf).slice(0, SHELF_ROW_LIMIT - active.length);
  const total = shelfAll(shelf).length;
  const hidden = total - active.length - resting.length;
  const card = "w-[126px] shrink-0 md:w-[148px]";
  return (
    <section aria-labelledby={`subs-shelf-${kind}`}>
      <SubsHomeSectionHeader
        id={`subs-shelf-${kind}`}
        title={title}
        trailing={shelfCountSummary(shelf)}
        href={wallHref}
      />
      <HScroller className={`mt-3 items-start gap-3 pb-2 pt-1 ${SUBS_HOME_INSET}`}>
        {active.map((item) => (
          <div key={item.sub.id} className={card}>
            <SubsHomePosterCard item={item} />
          </div>
        ))}
        {resting.length > 0 && active.length > 0 && <RestingDivider label={shelf.restingLabel} />}
        {resting.map((item) => (
          <div key={item.sub.id} className={card}>
            <SubsHomePosterCard item={item} />
          </div>
        ))}
        {hidden > 0 && (
          <div className={card}>
            <SubsHomeSeeAllCard href={wallHref} total={total} />
          </div>
        )}
      </HScroller>
    </section>
  );
}

/** 在追与歇着之间的分隔：一道上下渐隐的发丝线，中间竖排小字（中文逐字竖排，不用旋转） */
function RestingDivider({ label }: { label: string }) {
  return (
    <div
      aria-hidden="true"
      className="flex aspect-[18/189] w-[18px] shrink-0 flex-col items-center gap-2 md:aspect-[18/222]"
    >
      <span className="w-px flex-1 bg-gradient-to-b from-transparent via-white/[0.16] to-transparent" />
      <span className="flex flex-col items-center text-[10px] font-semibold leading-[1.15] text-[var(--text-faint)]">
        {Array.from(label).map((char, offset) => (
          <span key={offset}>{char}</span>
        ))}
      </span>
      <span className="w-px flex-1 bg-gradient-to-b from-transparent via-white/[0.16] to-transparent" />
    </div>
  );
}
