"use client";

import { useLocale } from "next-intl";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import { ACTIVE_JOB_STATUSES, listJobs, type JobView } from "@/lib/api/jobs";
import { resolveRequestUrl } from "@/lib/http";
import { useSession } from "@/lib/session";

interface JobsContextValue {
  jobs: JobView[];
  activeJobs: JobView[];
  refresh: () => void;
  upsert: (job: JobView) => void;
  latestFor: (resourceType: string, resourceId: string | number, jobType?: string) => JobView | null;
}

const JobsContext = createContext<JobsContextValue | null>(null);
const FALLBACK_POLL_MS = 15_000;

/**
 * 全站唯一后台任务数据源：首次进页面取快照，之后 SSE 即时刷新；反代不支持
 * 流式传输或网络断开时，用低频轮询兜底。任一入口（Web、CLI、Agent、调度器）
 * 创建的任务都会进入这里，业务组件不再各自猜测何时开始轮询。
 */
export function JobsProvider({ children }: { children: React.ReactNode }) {
  const locale = useLocale();
  const { session } = useSession();
  const enabled = session.role !== "member";
  const [jobs, setJobs] = useState<JobView[]>([]);
  const requestSeq = useRef(0);
  const refreshInFlight = useRef(false);
  const refreshQueued = useRef(false);
  const upsert = useCallback((job: JobView) => {
    setJobs((current) =>
      [job, ...current.filter((item) => item.id !== job.id)].toSorted(
        (left, right) => Date.parse(right.updated_at) - Date.parse(left.updated_at),
      ),
    );
  }, []);
  const refresh = useCallback(() => {
    refreshQueued.current = true;
    if (refreshInFlight.current) return;
    refreshInFlight.current = true;
    void (async () => {
      try {
        // SSE 可能在一个翻译批次内连续推送多条进度。串行排空并把期间的
        // 多次通知合为至多一次补充请求，避免前端制造重叠查询风暴。
        while (refreshQueued.current) {
          refreshQueued.current = false;
          const seq = ++requestSeq.current;
          try {
            // 活跃任务与最近历史并行取：即使近期记录很多，运行较久的旧任务
            // 也不会被新完成记录挤出全局状态。
            const [active, recent] = await Promise.all([
              listJobs({ activeOnly: true, limit: 200 }),
              listJobs({ limit: 50 }),
            ]);
            if (seq !== requestSeq.current) continue;
            const merged = new Map([...recent, ...active].map((job) => [job.id, job]));
            setJobs(
              [...merged.values()].sort(
                (left, right) => Date.parse(right.updated_at) - Date.parse(left.updated_at),
              ),
            );
          } catch {
            // 瞬时断线保留最近快照；SSE 重连或下一轮轮询会自动校准。
          }
        }
      } finally {
        refreshInFlight.current = false;
      }
    })();
  }, []);

  useEffect(() => {
    if (!enabled) {
      setJobs([]);
      return;
    }
    refresh();
    const timer = window.setInterval(refresh, FALLBACK_POLL_MS);
    const onFocus = () => refresh();
    window.addEventListener("focus", onFocus);

    let source: EventSource | null = null;
    let eventRefreshTimer: number | null = null;
    const scheduleEventRefresh = () => {
      if (eventRefreshTimer !== null) return;
      // 服务端一次读取可能连续推送多个事件，合为一次快照校准。
      eventRefreshTimer = window.setTimeout(() => {
        eventRefreshTimer = null;
        refresh();
      }, 120);
    };
    try {
      source = new EventSource(resolveRequestUrl("/jobs/stream"), { withCredentials: true });
      source.addEventListener("ready", scheduleEventRefresh);
      source.addEventListener("job", scheduleEventRefresh);
    } catch {
      // 部分 WebView 没有 EventSource，低频轮询仍能提供完整能力。
    }
    return () => {
      requestSeq.current += 1;
      refreshQueued.current = false;
      if (eventRefreshTimer !== null) window.clearTimeout(eventRefreshTimer);
      source?.close();
      window.clearInterval(timer);
      window.removeEventListener("focus", onFocus);
    };
  }, [enabled, refresh, locale]);

  const activeJobs = useMemo(
    () => jobs.filter((job) => ACTIVE_JOB_STATUSES.has(job.status)),
    [jobs],
  );
  const latestFor = useCallback(
    (resourceType: string, resourceId: string | number, jobType?: string) =>
      jobs.find(
        (job) =>
          (!jobType || job.job_type === jobType) &&
          job.resources.some(
            (resource) =>
              resource.resource_type === resourceType &&
              resource.resource_id === String(resourceId),
          ),
      ) ?? null,
    [jobs],
  );
  const value = useMemo(
    () => ({ jobs, activeJobs, refresh, upsert, latestFor }),
    [jobs, activeJobs, refresh, upsert, latestFor],
  );
  return <JobsContext.Provider value={value}>{children}</JobsContext.Provider>;
}

export function useJobs(): JobsContextValue {
  const value = useContext(JobsContext);
  if (!value) throw new Error("useJobs 必须在 JobsProvider 内使用");
  return value;
}
