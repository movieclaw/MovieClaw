/**
 * 定时任务的周期表达（设置 → 应用 → 定时任务）。
 *
 * 后端存的是 interval 秒数或 5 段 cron；界面只提供两种人能说清的形状：
 * 「每 N 小时」与「每天固定时刻」。其它 cron 写法照样能显示、能保存，只是
 * 不给可视化编辑——那类需求直接改表达式。
 */

import type { ScheduledTaskUpdate } from "@/lib/api/scheduled-tasks";

export type TriggerType = "interval" | "cron";

export interface ScheduleShape {
  trigger_type: TriggerType;
  interval_seconds: number | null;
  cron_expr: string | null;
}

/** 「每天 HH:MM」形状的 cron（分 时 * * *）；不是这个形状返回 null */
export function dailyTimeOf(cron: string | null): { hour: number; minute: number } | null {
  if (!cron) return null;
  const parts = cron.trim().split(/\s+/);
  if (parts.length !== 5) return null;
  const [minute, hour, dom, month, dow] = parts;
  if (dom !== "*" || month !== "*" || dow !== "*") return null;
  if (!/^\d{1,2}$/.test(minute) || !/^\d{1,2}$/.test(hour)) return null;
  const h = Number(hour);
  const m = Number(minute);
  if (h > 23 || m > 59) return null;
  return { hour: h, minute: m };
}

export function dailyCron(hour: number, minute: number): string {
  return `${minute} ${hour} * * *`;
}

/** 给人看的周期文案 */
export function describeSchedule(shape: ScheduleShape): string {
  if (shape.trigger_type === "interval") {
    const seconds = shape.interval_seconds ?? 0;
    if (seconds <= 0) return "间隔未设置";
    if (seconds % 3600 === 0) return `每 ${seconds / 3600} 小时`;
    if (seconds % 60 === 0) return `每 ${seconds / 60} 分钟`;
    return `每 ${seconds} 秒`;
  }
  const daily = dailyTimeOf(shape.cron_expr);
  if (daily) {
    const hh = String(daily.hour).padStart(2, "0");
    const mm = String(daily.minute).padStart(2, "0");
    return `每天 ${hh}:${mm}`;
  }
  return shape.cron_expr ? `cron：${shape.cron_expr}` : "未设置";
}

/** 网络挂载库的对账建议：一小时。增量对账之后一轮只要几秒，频繁一点换来"新文件更快出现" */
export const RECONCILE_NETWORK_SUGGESTED_SECONDS = 3600;

/**
 * 对账周期要不要提建议：有库在网络挂载上（实时监控收不到变化，对账是唯一的
 * 变更感知）且当前周期比建议的长。
 */
export function suggestReconcileInterval(
  shape: ScheduleShape,
  anyNetworkLibrary: boolean,
): boolean {
  if (!anyNetworkLibrary) return false;
  if (shape.trigger_type !== "interval") return true; // 固定时刻 = 一天一次，比一小时长
  return (shape.interval_seconds ?? 0) > RECONCILE_NETWORK_SUGGESTED_SECONDS;
}

/**
 * 只切启停时提交的请求体。接口要求整体提交（启停 + 周期），这里周期一律取
 * 服务器上已保存的那份——界面上改了还没点保存的周期草稿不能借开关夹带提交。
 */
export function toggleUpdate(
  saved: ScheduleShape,
  enabled: boolean,
): ScheduledTaskUpdate {
  return saved.trigger_type === "interval"
    ? { enabled, trigger_type: "interval", interval_seconds: saved.interval_seconds }
    : { enabled, trigger_type: "cron", cron_expr: saved.cron_expr };
}
