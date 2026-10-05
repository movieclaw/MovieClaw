"use client";

import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";

import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import type { Route } from "next";

import { ActivityBoostPage, BoostSummaryRow, useBoostPool } from "@/components/activity-boost";
import { ActivityGroup, GroupLinkRow } from "@/components/activity-group";
import { CheckIcon, ChevronLeftIcon, FilterIcon } from "@/components/icons";
import { TaskActionsMenu } from "@/components/job-center";
import {
  DownloadCard,
  SessionCard,
  sessionKey,
  useDeviceActions,
  type MediaActivityState,
} from "@/components/media-activity-section";
import { PAGE_NAV_BUTTON_CLASS } from "@/components/page-nav";
import {
  PlaybackHistoryList,
  STATS_PERIODS,
} from "@/components/playback-stats-section";
import { PosterImage } from "@/components/poster-image";
import {
  ActiveDownloadRow,
  ActiveJobRow,
  FinishedJobRow,
  SourceWarning,
  TaskAttentionCards,
  TaskCenterView,
  useTaskCenterActions,
} from "@/components/task-center-view";
import { WatchStatsPanel } from "@/components/watch-stats-panel";
import { activitySummaryParts, weekdayLabel, weeklyDelta } from "@/lib/activity-overview";
import { isSystemCancelled, type JobView } from "@/lib/api/jobs";
import { listMembers, type MemberView } from "@/lib/api/members";
import {
  fetchPlaybackHistory,
  fetchPlaybackWatchStats,
  type MediaActivityScope,
  type PlaybackLogEntry,
  type PlaybackWatchStats,
} from "@/lib/api/playback";
import { useBackNavigation } from "@/lib/back-navigation";
import { useDownloadTasks } from "@/lib/download-tasks";
import { imageUrl } from "@/lib/image-proxy";
import { isDismissed } from "@/lib/job-attention";
import { PageChromeProvider, usePageChrome } from "@/lib/page-chrome";
import { ACTIVITY_PAGE_TITLES, type ActivityPageName } from "@/lib/task-center";
import { useTaskActivity, type DownloadTaskGroup } from "@/lib/task-activity";
import { formatRelativeTime } from "@/lib/time";
import { useIsMobile } from "@/lib/use-media-query";

/**
 * 活动页（银玻璃，手机与桌面同一套）：一页总览 + 二级页，对齐原生 App 的
 * ActivityView.swift / ActivityPages.swift。
 *
 * - **不分「观看 / 任务」段**：打开就是「现在有没有要我管的事、家里在发生什么」，按紧急程度
 *   自上而下——需要处理 → 正在播放 → 正在下载 → 进行中（含刷流）→ 最近播放 → 观看统计 →
 *   最近完成；没内容的分组不出现；
 * - **大标题下一行实时摘要**（「2 项需要处理 · 1 台设备在播放 · 5 个任务进行中」，需要处理标红）；
 * - **历史与统计只露一小段**（3 条 / 一张 7 天摘要卡），分组标题右侧「查看全部」进二级页
 *   （`/activity?view=`），成员 / 周期 / 范围筛选在二级页右上角；
 * - 「需要处理」保留完整卡片：每种故障的补救动作不同，压成一行反而要多点一层；
 * - **浏览范围**不占顶栏：只在确有被隐藏的内容时以分组脚注出现、就地切换。
 *
 * 与 App 有意不同：网页没有左滑 / 长按 / 下拉刷新，行操作统一收进行尾 ⋯ 菜单。
 * Netflix 主题仍是「观看 / 任务」两段版式（activity-view.tsx）。
 *
 * 手机与桌面只在「标题和页面操作放哪」上不同：手机挂进全局顶栏；桌面没有全局顶栏，
 * 画在页内标题行（见 DesktopHeader）。
 */
export function ActivityPages({
  page,
  media,
}: {
  page: ActivityPageName | null;
  media: MediaActivityState;
}) {
  const chrome = usePageChrome();
  const isMobile = useIsMobile();
  // 手机顶栏：总览挂大字标题（标签根页），二级页挂页名 + 返回键（回总览）
  const setTopBarTitle = chrome?.setTopBarTitle;
  useEffect(() => {
    if (!isMobile || !setTopBarTitle) return;
    return page
      ? setTopBarTitle(ACTIVITY_PAGE_TITLES[page], { backHref: "/activity" as Route })
      : setTopBarTitle("活动", { large: true });
  }, [isMobile, page, setTopBarTitle]);

  // 桌面：二级页往顶栏右上角挂的操作（观看页的筛选菜单、刷流页的「清理」）改落到页内
  // 标题行右侧。做法是给子树换一个 setTopBarActions，子页面照旧调用、不必分辨形态；
  // 撤销语义与外壳一致（只撤自己挂上去的那个节点）。
  const [headerActions, setHeaderActions] = useState<ReactNode>(null);
  const setDesktopActions = useCallback((node: ReactNode) => {
    setHeaderActions(node);
    return () => setHeaderActions((current) => (current === node ? null : current));
  }, []);
  const desktopChrome = useMemo(
    () => (chrome ? { ...chrome, setTopBarActions: setDesktopActions } : null),
    [chrome, setDesktopActions],
  );

  const body =
    page === "active" || page === "history" ? (
      <TaskCenterView view={page} subPage />
    ) : page === "boost" ? (
      <ActivityBoostPage />
    ) : page === "plays" || page === "stats" ? (
      <WatchPage page={page} media={media} />
    ) : (
      <ActivityOverview media={media} />
    );
  if (isMobile) return body;
  return (
    <PageChromeProvider value={desktopChrome}>
      <DesktopHeader page={page} actions={headerActions} />
      {body}
    </PageChromeProvider>
  );
}

/**
 * 桌面标题行：总览是「活动」大字标题（字形同订阅首页等桌面页内标题），二级页是返回键 +
 * 正文字号页名（回总览，能按历史回就按历史回）；右侧是二级页的页面操作。
 */
function DesktopHeader({ page, actions }: { page: ActivityPageName | null; actions: ReactNode }) {
  const back = useBackNavigation("/activity" as Route);
  return (
    <div className="mb-2 flex min-h-11 items-center gap-2">
      {page && (
        <button
          type="button"
          onClick={back}
          aria-label="返回活动"
          className={`${PAGE_NAV_BUTTON_CLASS} -ml-1 shrink-0`}
        >
          <ChevronLeftIcon className="size-[22px]" />
        </button>
      )}
      {/* 字号层级同手机顶栏 / iOS：标签根页（总览）大字标题，二级页正文字号小标题 */}
      <h1
        className={
          page
            ? "text-on-image min-w-0 flex-1 truncate text-body font-semibold tracking-[-0.01em] text-[var(--text)]"
            : "text-on-image min-w-0 flex-1 truncate text-[26px] font-bold leading-tight tracking-[-0.02em] text-white"
        }
      >
        {page ? ACTIVITY_PAGE_TITLES[page] : "活动"}
      </h1>
      {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
    </div>
  );
}

/** 总览「进行中」最多露几条，其余进二级页 */
const ACTIVE_LIMIT = 5;
/** 最近播放 / 最近完成露几条 */
const RECENT_LIMIT = 3;

function ActivityOverview({ media }: { media: MediaActivityState }) {
  const activity = useTaskActivity();
  const { sources, error: downloadsError, loading: downloadsLoading } = useDownloadTasks();
  const actions = useTaskCenterActions();
  const devices = useDeviceActions(media.refresh);
  const { pool } = useBoostPool(activity.boostTasks);
  const { snapshot, scope, setScope } = media;
  const watching = snapshot.sessions.length + snapshot.hidden_session_count;
  const downloading = snapshot.downloads.length + snapshot.hidden_download_count;
  // 有人开播 / 停播时播放记录会多一条，跟着重取最近播放与 7 天统计
  const extras = useWatchExtras(media.enabled, scope, watching);
  const failedSources = sources.filter((source) => source.status !== "active");
  const canDismissAll = activity.standaloneAttentionJobs.some((job) => job.status === "failed");
  const activeItems: ({ kind: "group"; group: DownloadTaskGroup } | { kind: "job"; job: JobView })[] = [
    ...activity.activeDownloadGroups.map((group) => ({ kind: "group" as const, group })),
    ...activity.standaloneActiveJobs.map((job) => ({ kind: "job" as const, job })),
  ];

  /** 浏览范围脚注：有被隐藏的内容才出现，就地切到「全部」；已是「全部」时给回退出口 */
  const scopeFooter = (hidden: number, noun: string) =>
    hidden > 0 || scope === "all" ? (
      <>
        {hidden > 0 ? `另有 ${hidden} ${noun}不在你的浏览范围内` : "已包含对你隐藏的库"}
        <button
          type="button"
          onClick={() => setScope(hidden > 0 ? "all" : "visible")}
          className="ml-1.5 font-semibold text-[var(--info)]"
        >
          {hidden > 0 ? "显示全部" : "只看我的范围"}
        </button>
      </>
    ) : null;

  return (
    <div>
      <p className="tnum px-1 text-sub text-[var(--text-muted)]">
        {downloadsLoading && media.loading
          ? "正在读取…"
          : activitySummaryParts({
              attention: activity.attentionTotal,
              watching,
              downloading,
              active: activity.activeTotal,
            }).map((part, index) => (
              <span key={index}>
                {index > 0 && " · "}
                <span className={part.alert ? "font-semibold text-[var(--danger)]" : undefined}>
                  {part.text}
                </span>
              </span>
            ))}
      </p>

      {media.error && (
        <p className="mt-4 rounded-xl border border-amber-400/25 bg-amber-500/10 px-4 py-3 text-sub leading-6 text-amber-100">
          {media.error}
        </p>
      )}
      {(failedSources.length > 0 || downloadsError) && (
        <div>
          <SourceWarning sources={failedSources} error={downloadsError} />
        </div>
      )}

      {activity.attentionTotal > 0 && (
        <ActivityGroup
          title="需要处理"
          count={activity.attentionTotal}
          tone="danger"
          plain
          trailing={
            canDismissAll
              ? {
                  label: actions.bulkDismissing ? "正在忽略…" : "全部忽略",
                  onClick: actions.dismissAllFailed,
                  disabled: actions.bulkDismissing,
                }
              : null
          }
        >
          <TaskAttentionCards actions={actions} />
        </ActivityGroup>
      )}

      {watching > 0 && (
        <ActivityGroup
          title="正在播放"
          count={watching}
          tone="ok"
          footer={scopeFooter(snapshot.hidden_session_count, "台设备在播放的内容")}
        >
          {snapshot.sessions.map((session) => (
            <SessionCard
              key={sessionKey(session)}
              session={session}
              variant="row"
              onEnd={devices.requestEnd}
              onRevoke={devices.requestRevoke}
              busy={devices.busy}
            />
          ))}
        </ActivityGroup>
      )}

      {downloading > 0 && (
        <ActivityGroup
          title="正在下载"
          count={downloading}
          footer={scopeFooter(snapshot.hidden_download_count, "条下载")}
        >
          {snapshot.downloads.map((download) => (
            <DownloadCard
              key={`${download.device_id}-${download.file_name}`}
              download={download}
              variant="row"
              onRevoke={devices.requestRevoke}
              busy={devices.busy}
            />
          ))}
        </ActivityGroup>
      )}

      {(activity.activeTotal > 0 || activity.boostTasks.length > 0) && (
        <ActivityGroup
          title="进行中"
          count={activity.activeTotal > 0 ? activity.activeTotal : null}
          trailing={
            activity.activeTotal > 0 ? { label: "查看全部", href: "/activity?view=active" as Route } : null
          }
        >
          {activeItems.slice(0, ACTIVE_LIMIT).map((item) =>
            item.kind === "group" ? (
              <GroupLinkRow
                key={`group:${item.group.key}`}
                href={"/activity?view=active" as Route}
                menu={downloadGroupMenu(item.group, actions)}
              >
                <ActiveDownloadRow group={item.group} ingestJobsByHash={activity.ingestJobsByHash} />
              </GroupLinkRow>
            ) : (
              <GroupLinkRow
                key={`job:${item.job.id}`}
                href={"/activity?view=active" as Route}
                menu={
                  item.job.status !== "cancelling" ? (
                    <TaskActionsMenu
                      ariaLabel="作业操作"
                      disabled={actions.cancellingJobId != null}
                      items={[
                        {
                          id: "cancel",
                          label: "取消任务",
                          onSelect: () => actions.cancelBackgroundJob(item.job),
                        },
                      ]}
                    />
                  ) : null
                }
              >
                <ActiveJobRow job={item.job} />
              </GroupLinkRow>
            ),
          )}
          {activity.boostTasks.length > 0 && (
            <BoostSummaryRow tasks={activity.boostTasks} pool={pool} />
          )}
        </ActivityGroup>
      )}

      {extras.recentPlays.length > 0 && (
        <ActivityGroup
          title="最近播放"
          trailing={{ label: "查看全部", href: "/activity?view=plays" as Route }}
        >
          {extras.recentPlays.map((entry) => (
            <RecentPlayRow key={entry.id} entry={entry} />
          ))}
        </ActivityGroup>
      )}

      {extras.weekly && (
        <ActivityGroup
          title="观看统计"
          trailing={{ label: "查看全部", href: "/activity?view=stats" as Route }}
        >
          <GroupLinkRow href={"/activity?view=stats" as Route}>
            <WeeklyWatchCard stats={extras.weekly} />
          </GroupLinkRow>
        </ActivityGroup>
      )}

      {activity.standaloneHistoricalJobs.length > 0 && (
        <ActivityGroup
          title="最近完成"
          trailing={{
            label: `查看全部 ${activity.historyTotal} 个`,
            href: "/activity?view=history" as Route,
          }}
        >
          {activity.standaloneHistoricalJobs.slice(0, RECENT_LIMIT).map((job) => (
            <GroupLinkRow
              key={job.id}
              href={"/activity?view=history" as Route}
              menu={finishedJobMenu(job, actions)}
            >
              <FinishedJobRow job={job} />
            </GroupLinkRow>
          ))}
        </ActivityGroup>
      )}

      {actions.deleteDialog}
      {devices.dialogs}
    </div>
  );
}

type Actions = ReturnType<typeof useTaskCenterActions>;

/** 进行中下载的 ⋯：单资源才能在这里删种（多资源进二级页逐个处理） */
function downloadGroupMenu(group: DownloadTaskGroup, actions: Actions) {
  const task = group.tasks[0];
  if (group.tasks.length !== 1 || task.downloader_id == null) return null;
  return (
    <TaskActionsMenu
      ariaLabel={`${group.title}的更多操作`}
      disabled={actions.deletingTaskId != null}
      items={[
        { id: "delete", label: "删除任务", tone: "danger", onSelect: () => actions.requestDelete(task) },
      ]}
    />
  );
}

/** 最近完成的 ⋯：被忽略的失败可撤销忽略，用户取消的可重新执行 */
function finishedJobMenu(job: JobView, actions: Actions) {
  if (job.status === "failed" && isDismissed(job)) {
    return (
      <TaskActionsMenu
        ariaLabel="作业操作"
        disabled={actions.undismissingJobId != null}
        items={[{ id: "undismiss", label: "撤销忽略", onSelect: () => actions.restoreDismissedJob(job) }]}
      />
    );
  }
  if (job.status === "cancelled" && !isSystemCancelled(job)) {
    return (
      <TaskActionsMenu
        ariaLabel="作业操作"
        disabled={actions.retryingJobId != null}
        items={[{ id: "retry", label: "重新执行", onSelect: () => actions.retryHistoricalJob(job) }]}
      />
    );
  }
  return null;
}

/**
 * 总览的「最近播放」（3 条）与「观看统计」（7 天）数据：打开总览时取一次，切换浏览范围、
 * 有人开播 / 停播（`liveKey` 变化）时重取；失败保留上次结果（App 的 MediaActivityStore.refreshExtras）。
 */
function useWatchExtras(enabled: boolean, scope: MediaActivityScope, liveKey: number) {
  const [recentPlays, setRecentPlays] = useState<PlaybackLogEntry[]>([]);
  const [weekly, setWeekly] = useState<PlaybackWatchStats | null>(null);
  useEffect(() => {
    if (!enabled) return;
    let cancelled = false;
    void fetchPlaybackHistory({ limit: RECENT_LIMIT, scope })
      .then((page) => !cancelled && setRecentPlays(page.entries))
      .catch(() => undefined);
    void fetchPlaybackWatchStats(7, scope)
      .then((stats) => !cancelled && setWeekly(stats))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [enabled, scope, liveKey]);
  return { recentPlays, weekly };
}

/**
 * 最近播放一行：小海报 · 片名 /「成员 · 设备」，右列固定不截断（ActivityDashboardRows.swift 的
 * ActivityRecentPlayRow）——设备名常带长长的型号与系统版本，只截断它自己那一行，不会把
 * 「看到 42%」挤没。结果在上（与片名同行、字重高一档），相对时间在下。
 */
function RecentPlayRow({ entry }: { entry: PlaybackLogEntry }) {
  const media = entry.media;
  const playing = entry.ended_at == null;
  const unit =
    media.kind === "tv"
      ? `S${String(media.season_number).padStart(2, "0")}E${String(media.episode_number).padStart(2, "0")}`
      : null;
  const href =
    media.library_id != null && media.browsable
      ? (`/library/${media.library_id}/item/${media.media_item_id}` as Route)
      : null;
  return (
    <GroupLinkRow href={href}>
      <PosterImage
        src={media.poster_url ? imageUrl(media.poster_url) : null}
        width={34}
        alt={media.title}
        className="h-[50px] w-[34px] shrink-0 rounded-md object-cover ring-1 ring-white/10"
      />
      <span className="min-w-0 flex-1">
        <span className="block truncate text-ui font-semibold text-[var(--text)]">
          {media.title || "（条目已删除）"}
          {unit && <span className="tnum ml-1.5 font-normal text-[var(--text-muted)]">{unit}</span>}
        </span>
        <span className="mt-0.5 block truncate text-sub text-[var(--text-muted)]">
          {[entry.member_name, entry.device_name || entry.client].filter(Boolean).join(" · ")}
        </span>
      </span>
      <span className="tnum flex shrink-0 flex-col items-end gap-0.5 whitespace-nowrap text-sub">
        {playing ? (
          <span className="font-medium text-[var(--ok)]">播放中</span>
        ) : entry.completed ? (
          <span className="inline-flex items-center gap-1 font-medium text-[var(--ok)]">
            <CheckIcon className="size-3" />
            看完
          </span>
        ) : entry.progress_percent != null ? (
          <span className="font-medium text-[var(--text-muted)]">看到 {entry.progress_percent}%</span>
        ) : null}
        {!playing && (
          <span className="text-[var(--text-faint)]">{formatRelativeTime(entry.started_at)}</span>
        )}
      </span>
    </GroupLinkRow>
  );
}

/**
 * 最近 7 天观看摘要：总时长大字 + 较前 7 天涨跌 + 按天 7 根柱子（今天高亮），点进观看统计
 * （ActivityDashboardRows.swift 的 ActivityWeeklyWatchCard）。
 */
function WeeklyWatchCard({ stats }: { stats: PlaybackWatchStats }) {
  // 服务端按「含今天往前 N 天」给，可能多出一天；只画最近 7 根
  const bars = stats.by_day.slice(-7);
  const max = Math.max(1, ...bars.map((bar) => bar.watched_ms));
  const minutes = Math.round(stats.current.watched_ms / 60_000);
  const hours = Math.floor(minutes / 60);
  const delta = weeklyDelta(stats);
  const number = "text-[30px] font-bold leading-none tracking-[-0.02em] text-[var(--text)]";
  const unit = "text-sub text-[var(--text-muted)]";
  return (
    <span className="block min-w-0 flex-1">
      <span className="flex items-baseline justify-between gap-3">
        <span>
          <span className="block text-sub text-[var(--text-muted)]">最近 7 天</span>
          <span className="tnum mt-1.5 flex items-baseline gap-1">
            {hours > 0 && (
              <>
                <span className={number}>{hours}</span>
                <span className={unit}>小时</span>
              </>
            )}
            {(minutes % 60 > 0 || hours === 0) && (
              <>
                <span className={number}>{minutes % 60}</span>
                <span className={unit}>分钟</span>
              </>
            )}
          </span>
        </span>
        {delta && (
          <span
            className={`shrink-0 text-sub font-semibold ${
              delta.tone === "up"
                ? "text-[var(--ok)]"
                : delta.tone === "flat"
                  ? "text-[var(--text-faint)]"
                  : "text-[var(--text-muted)]"
            }`}
          >
            {delta.text}
          </span>
        )}
      </span>
      <span className="mt-3 grid grid-cols-7 gap-2" aria-hidden="true">
        {bars.map((bar, index) => (
          <span key={bar.date} className="flex flex-col items-center gap-1.5">
            <span className="flex h-14 w-full items-end justify-center">
              <span
                className="w-[55%] rounded-[4px] bg-[var(--info)]"
                style={{
                  height: `${Math.max(bar.watched_ms > 0 ? 6 : 2, (bar.watched_ms / max) * 100)}%`,
                  opacity: index === bars.length - 1 ? 1 : 0.45,
                }}
              />
            </span>
            <span className="text-caption text-[var(--text-faint)]">{weekdayLabel(bar.date)}</span>
          </span>
        ))}
      </span>
    </span>
  );
}

// ---------------------------------------------------------------------------
// 二级页：最近播放 / 观看统计
// ---------------------------------------------------------------------------

const SCOPE_LABELS: Record<MediaActivityScope, string> = {
  visible: "我的浏览范围",
  all: "全部（含对你隐藏的库）",
};

/**
 * 最近播放 / 观看统计：筛选（周期、成员、范围）收进右上角的筛选菜单，当前条件写在页内副标题
 * （ActivityPages.swift 的 ActivityWatchPage）。内容直接复用桌面观看视角的 PlaybackHistoryList /
 * WatchStatsPanel。
 */
function WatchPage({ page, media }: { page: "plays" | "stats"; media: MediaActivityState }) {
  const { scope, setScope, enabled } = media;
  const [memberId, setMemberId] = useState<number | null>(null);
  const [days, setDays] = useState(30);
  const [members, setMembers] = useState<MemberView[]>([]);
  const showAll = useCallback(() => setScope("all"), [setScope]);

  useEffect(() => {
    if (!enabled) return;
    void listMembers()
      .then(setMembers)
      .catch(() => undefined);
  }, [enabled]);

  const memberOptions = useMemo(
    () => [
      { value: -1, label: "全部成员" },
      { value: 0, label: "超级管理员" },
      ...members.map((m) => ({ value: m.id, label: m.nickname || m.username })),
    ],
    [members],
  );
  const memberLabel =
    memberId == null ? null : (memberOptions.find((o) => o.value === memberId)?.label ?? null);

  // 筛选菜单挂到顶栏右上角；有条件偏离默认时图标点亮
  const setTopBarActions = usePageChrome()?.setTopBarActions;
  const filtered = memberId != null || scope === "all" || (page === "stats" && days !== 30);
  const menu = useMemo(
    () => (
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button
            type="button"
            aria-label="筛选"
            className={`${PAGE_NAV_BUTTON_CLASS} ${filtered ? "!text-[var(--info)]" : ""}`}
          >
            <FilterIcon className="size-[18px]" />
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="end"
            sideOffset={6}
            collisionPadding={12}
            className="menu-surface scroll-thin z-50 w-[15rem] max-h-[min(28rem,var(--radix-dropdown-menu-content-available-height))] overflow-y-auto p-1"
          >
            {page === "stats" && (
              <FilterRadioGroup
                label="周期"
                value={String(days)}
                options={STATS_PERIODS.map((p) => ({ value: String(p.value), label: p.label }))}
                onChange={(value) => setDays(Number(value))}
              />
            )}
            <FilterRadioGroup
              label="成员"
              value={String(memberId ?? -1)}
              options={memberOptions.map((o) => ({ value: String(o.value), label: o.label }))}
              onChange={(value) => setMemberId(Number(value) < 0 ? null : Number(value))}
            />
            <FilterRadioGroup
              label="范围"
              value={scope}
              options={(["visible", "all"] as const).map((value) => ({ value, label: SCOPE_LABELS[value] }))}
              onChange={(value) => setScope(value as MediaActivityScope)}
            />
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
    ),
    [days, filtered, memberId, memberOptions, page, scope, setScope],
  );
  useEffect(() => {
    if (!setTopBarActions) return;
    return setTopBarActions(menu);
  }, [menu, setTopBarActions]);

  // 页内副标题：「最近 30 天 · 全部成员 · 我的浏览范围」
  const subtitle = [
    page === "stats" ? `最近 ${days} 天` : null,
    memberLabel ?? "全部成员",
    scope === "all" ? "含隐藏的库" : "我的浏览范围",
  ]
    .filter(Boolean)
    .join(" · ");

  if (!enabled) return null;
  return (
    <div>
      <p className="mb-4 px-1 text-sub text-[var(--text-muted)]">{subtitle}</p>
      {page === "plays" ? (
        <PlaybackHistoryList
          scope={scope}
          memberId={memberId}
          memberLabel={memberLabel}
          onClearMember={() => setMemberId(null)}
          onShowAll={showAll}
        />
      ) : (
        <WatchStatsPanel
          scope={scope}
          days={days}
          memberId={memberId}
          memberLabel={memberLabel}
          onMemberSelect={setMemberId}
          onDaysChange={setDays}
          onShowAll={showAll}
        />
      )}
    </div>
  );
}

const MENU_ITEM_CLASS =
  "glass-row nav-item flex cursor-pointer items-center gap-2.5 px-3 py-2 text-sub text-white/85 outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)]";

/** 筛选菜单里的一组单选（带小标题），选中项打勾 */
function FilterRadioGroup({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: string;
  options: { value: string; label: string }[];
  onChange: (value: string) => void;
}) {
  return (
    <>
      <DropdownMenu.Label className="px-3 pb-1 pt-2 text-caption font-semibold text-white/45">
        {label}
      </DropdownMenu.Label>
      <DropdownMenu.RadioGroup value={value} onValueChange={onChange}>
        {options.map((option) => (
          <DropdownMenu.RadioItem key={option.value} value={option.value} className={MENU_ITEM_CLASS}>
            <span className="flex size-4 shrink-0 items-center justify-center">
              <DropdownMenu.ItemIndicator>
                <CheckIcon className="size-3.5 text-[var(--info)]" />
              </DropdownMenu.ItemIndicator>
            </span>
            <span className="min-w-0 truncate">{option.label}</span>
          </DropdownMenu.RadioItem>
        ))}
      </DropdownMenu.RadioGroup>
    </>
  );
}
