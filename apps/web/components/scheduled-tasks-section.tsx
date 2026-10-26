"use client";

import { useLocale, useTranslations } from "next-intl";
import { type AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";

import { useCallback, useEffect, useRef, useState } from "react";

import { Banner, ErrorBanner, Toggle } from "@/components/cloud-push-ui";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SettingsEmpty,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import { listLibraries } from "@/lib/api/libraries";
import {
  listScheduledTasks,
  type ScheduledTask,
  type ScheduledTaskUpdate,
  updateScheduledTask,
} from "@/lib/api/scheduled-tasks";
import {
  RECONCILE_NETWORK_SUGGESTED_SECONDS,
  type ScheduleShape,
  dailyCron,
  dailyTimeOf,
  describeSchedule,
  suggestReconcileInterval,
  toggleUpdate,
} from "@/lib/scheduled-tasks";
import { ROW_ANCHOR_CLASS, useRowAnchor } from "@/lib/row-anchor";
import { formatDateTime, formatRelativeTime } from "@/lib/time";

/**
 * 设置 → 应用 → 定时任务：每个后台任务的周期与启停。
 *
 * 周期一直落在库里、此前却没有入口能改。这里给两种人能说清的形状——
 * 「每 N 小时」与「每天固定时刻」——其它 cron 照样能显示与保存（改表达式）。
 * 「媒体库对账」多一条建议：有库在网络挂载上（实时监控收不到变化，对账是唯一
 * 的变更感知）且周期比一小时长，就提示调到一小时——增量对账之后一轮只要几秒，
 * 频繁一点换来"新文件更快出现"。只建议，不替用户改。
 */
export function ScheduledTasksSection() {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;

  const [tasks, setTasks] = useState<ScheduledTask[] | null>(null);
  const [anyNetwork, setAnyNetwork] = useState(false);
  const [error, setError] = useMessageState();
  const [busyKey, setBusyKey] = useState<string | null>(null);
  // 插件详情「定时任务」行的深链：?task=<task.key> 落到这个任务的那一行
  useRowAnchor("task", "data-task-key", tasks != null);

  const readGeneration = useRef(0);
  const reload = useCallback(() => {
    const id = ++readGeneration.current;
    Promise.all([listScheduledTasks(), listLibraries().catch(() => [])])
      .then(([rows, libs]) => {
        if (id !== readGeneration.current) return;
        setTasks(rows);
        setAnyNetwork(libs.some((lib) => lib.network_mount));
        setError(null);
      })
      .catch((err: unknown) => {
        if (id === readGeneration.current)
          setError(err instanceof Error ? err.message : { key: "settings.scheduledTasks.ui.loadFailed" });
      });
  }, [setError]);
  useEffect(() => {
    reload();
    return () => { readGeneration.current += 1; };
  }, [reload, locale]);

  const save = useCallback(async (task: ScheduledTask, body: ScheduledTaskUpdate) => {
    setBusyKey(task.key);
    try {
      const updated = await updateScheduledTask(task.key, body);
      setTasks((prev) => prev?.map((current) => current.key === task.key
        ? { ...updated, title: current.title, description: current.description } : current) ?? null);
      setError(null);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : { key: "settings.scheduledTasks.ui.saveFailed" });
    } finally {
      setBusyKey(null);
    }
  }, [setError]);

  const reconcile = tasks?.find((t) => t.key === "library_reconcile") ?? null;
  const suggest = reconcile !== null && suggestReconcileInterval(reconcile, anyNetwork);

  return (
    <div className="space-y-10">
      <p className="px-1 text-sub leading-relaxed text-[var(--text-muted)]">
        {t("settings.scheduledTasks.ui.intro")}</p>
      <SettingsSection
        title={t("settings.scheduledTasks.ui.title")}
        description={tasks && tasks.length > 0 ? t("settings.scheduledTasks.ui.count", { count: tasks.length }) : undefined}
      >
        <div className="space-y-3">
          {error && <ErrorBanner>{error}</ErrorBanner>}
          {suggest && reconcile && (
            <Banner
              tone="info"
              action={
                <button
                  type="button"
                  className={SETTINGS_BUTTON_CLASS}
                  disabled={busyKey === reconcile.key}
                  onClick={() =>
                    save(reconcile, {
                      enabled: true,
                      trigger_type: "interval",
                      interval_seconds: RECONCILE_NETWORK_SUGGESTED_SECONDS,
                    })
                  }
                >
                  {t("settings.scheduledTasks.ui.applySuggestion")}</button>
              }
            >
              {t("settings.scheduledTasks.ui.networkHint", { schedule: describeSchedule(reconcile, locale) })}
            </Banner>
          )}
          {tasks === null ? (
            !error && <p className="px-1 text-sub text-[var(--text-muted)]">{t("settings.scheduledTasks.ui.loading")}</p>
          ) : tasks.length === 0 ? (
            <SettingsEmpty
              title={t("settings.scheduledTasks.ui.empty")}
              description={t("settings.scheduledTasks.ui.emptyHint")}
            />
          ) : (
            <SettingsList>
              {tasks.map((task) => (
                <TaskRow key={task.key} task={task} busy={busyKey === task.key} onSave={save} />
              ))}
            </SettingsList>
          )}
        </div>
      </SettingsSection>
    </div>
  );
}

type Mode = "interval" | "daily" | "cron";

function modeOf(shape: ScheduleShape): Mode {
  if (shape.trigger_type === "interval") return "interval";
  return dailyTimeOf(shape.cron_expr) ? "daily" : "cron";
}

function TaskRow({
  task,
  busy,
  onSave,
}: {
  task: ScheduledTask;
  busy: boolean;
  onSave: (task: ScheduledTask, body: ScheduledTaskUpdate) => Promise<void>;
}) {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;

  const [mode, setMode] = useState<Mode>(() => modeOf(task));
  const [hours, setHours] = useState(() =>
    task.interval_seconds ? Math.max(1, Math.round(task.interval_seconds / 3600)) : 6,
  );
  const [time, setTime] = useState(() => {
    const daily = dailyTimeOf(task.cron_expr);
    return daily
      ? `${String(daily.hour).padStart(2, "0")}:${String(daily.minute).padStart(2, "0")}`
      : "03:00";
  });
  const [cron, setCron] = useState(task.cron_expr ?? "");
  // 服务器上的周期变了（保存成功 / 别处改了）就把编辑态对齐回去；只拨了开关
  // 周期没变，不动用户还没保存的草稿
  const { trigger_type, interval_seconds, cron_expr } = task;
  useEffect(() => {
    setMode(modeOf({ trigger_type, interval_seconds, cron_expr }));
    if (interval_seconds) setHours(Math.max(1, Math.round(interval_seconds / 3600)));
    const daily = dailyTimeOf(cron_expr);
    if (daily) {
      setTime(
        `${String(daily.hour).padStart(2, "0")}:${String(daily.minute).padStart(2, "0")}`,
      );
    }
    setCron(cron_expr ?? "");
  }, [trigger_type, interval_seconds, cron_expr]);

  const draft: ScheduledTaskUpdate =
    mode === "interval"
      ? { enabled: task.enabled, trigger_type: "interval", interval_seconds: hours * 3600 }
      : mode === "daily"
        ? {
            enabled: task.enabled,
            trigger_type: "cron",
            cron_expr: dailyCron(Number(time.slice(0, 2)), Number(time.slice(3, 5))),
          }
        : { enabled: task.enabled, trigger_type: "cron", cron_expr: cron.trim() };
  const dirty =
    draft.trigger_type !== task.trigger_type ||
    (draft.trigger_type === "interval"
      ? draft.interval_seconds !== task.interval_seconds
      : draft.cron_expr !== task.cron_expr);

  return (
    <div data-task-key={task.key} className={ROW_ANCHOR_CLASS}>
      <SettingsRow
        stackOnMobile={locale === "en"}
        label={
          <span className="flex flex-wrap items-baseline gap-x-2">
            {task.title}
            <span className="text-sub font-normal text-[var(--text-muted)]">
              {describeSchedule(task, locale)}
            </span>
          </span>
        }
        description={
          <>
            {task.description && <span className="block">{task.description}</span>}
            <span className="block">
              {t("settings.scheduledTasks.ui.lastRun", {
                last: task.last_run_at ? formatRelativeTime(task.last_run_at, locale) : t("settings.scheduledTasks.ui.neverRun"),
                next: task.enabled && task.next_run_at ? "yes" : "no",
                when: task.next_run_at ? formatDateTime(task.next_run_at, locale) : "",
                enabled: task.enabled ? "yes" : "no",
              })}
            </span>
          </>
        }
      >
        {/* 启停改完即存，只换启停：周期带服务器上已保存的那份（接口要求整体提交），
            下方没点保存的周期草稿原样留在界面上 */}
        <Toggle
          checked={task.enabled}
          label={t("settings.scheduledTasks.ui.enable", { title: task.title })}
          disabled={busy}
          onChange={(next) => void onSave(task, toggleUpdate(task, next))}
        />
      </SettingsRow>
      {/* 周期是「方式 + 数值」两个字段一起提交：改完点保存，没改动时置灰 */}
      <div className="-mt-1 flex flex-wrap items-center gap-2 px-4 pb-3 text-sub text-[var(--text-muted)]">
        <select
          value={mode}
          onChange={(e) => setMode(e.target.value as Mode)}
          className={SETTINGS_INPUT_CLASS}
          aria-label={t("settings.scheduledTasks.ui.mode")}
        >
          <option value="interval">{t("settings.scheduledTasks.ui.interval")}</option>
          <option value="daily">{t("settings.scheduledTasks.ui.daily")}</option>
          <option value="cron">{t("settings.scheduledTasks.ui.cron")}</option>
        </select>
        {mode === "interval" && (
          <label className="flex items-center gap-1.5">
            <input
              type="number"
              min={1}
              max={168}
              value={hours}
              onChange={(e) => setHours(Math.max(1, Math.min(168, Number(e.target.value) || 1)))}
              className={`${SETTINGS_INPUT_CLASS} w-20`}
              aria-label={t("settings.scheduledTasks.ui.intervalHours")}
            />
            {t("settings.scheduledTasks.ui.hoursUnit", { count: hours })}</label>
        )}
        {mode === "daily" && (
          <input
            type="time"
            value={time}
            onChange={(e) => setTime(e.target.value || "03:00")}
            className={SETTINGS_INPUT_CLASS}
            aria-label={t("settings.scheduledTasks.ui.dailyTime")}
          />
        )}
        {mode === "cron" && (
          <input
            type="text"
            value={cron}
            onChange={(e) => setCron(e.target.value)}
            placeholder={t("settings.scheduledTasks.ui.cronPlaceholder")}
            className={`${SETTINGS_INPUT_CLASS} w-56 font-mono`}
            aria-label={t("settings.scheduledTasks.ui.cron")}
          />
        )}
        <button
          type="button"
          className={SETTINGS_BUTTON_CLASS}
          disabled={busy || !dirty}
          onClick={() => onSave(task, draft)}
        >
          {busy ? t("settings.scheduledTasks.ui.saving") : t("settings.scheduledTasks.ui.save")}
        </button>
      </div>
    </div>
  );
}
