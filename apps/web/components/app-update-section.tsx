"use client";

import { useLocale, useTranslations } from "next-intl";
import { type AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";

import { useCallback, useEffect, useRef, useState } from "react";

import { Banner, ErrorBanner } from "@/components/cloud-push-ui";
import { useConfirm } from "@/components/feedback";
import { ChevronRightIcon, RefreshIcon } from "@/components/icons";
import { Markdown } from "@/components/markdown";
import { Modal } from "@/components/modal";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_DANGER_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsCard,
  SettingsEmpty,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type GithubTokenView,
  type ModelUpdateCheckView,
  type RollbackOptionsView,
  type RollbackTargetView,
  type UpdateCheckView,
  type UpdateProgressView,
  type UpdateStatusView,
  applyModelUpdate,
  applyUpdate,
  checkModelUpdate,
  checkUpdate,
  dismissLastAbnormalExit,
  getGithubToken,
  getPendingUpdate,
  getRollbackOptions,
  getUpdateProgress,
  getUpdateStatus,
  restartApp,
  rollbackTo,
  saveGithubToken,
  saveUpdateRetention,
} from "@/lib/api/app";
import { getHealth } from "@/lib/api/health";
import { HttpError } from "@/lib/http";
import { useSession } from "@/lib/session";
import { formatBytes } from "@/lib/format";
import { formatDateTime, formatUnixDateTime } from "@/lib/time";

/**
 * 版本与更新（设置 → 更新与维护）。
 *
 * 应用内更新的用户界面（机制见 docs/design/in-app-update.md）：
 *   - 状态区：当前版本 + 代码来源（镜像内置 / 应用内更新 vX / 源码部署）；
 *     曾启动失败被自动回落的版本在此外显。
 *   - **进页即知**：挂载时读服务端的待更新快照（每小时的定时检查早就查过了），
 *     有新版就直接把版本卡片摆出来。用户是被侧栏的更新入口引导过来的，到了
 *     这一页还得自己找一颗「检查更新」按钮点一下才看得见新版本，链路是断的；
 *     按钮保留，语义降级为"我现在就要重查一次"。
 *   - 检查更新：比对 GitHub 最新 Release。依赖没变（runtime 匹配）就能
 *     一键更新；依赖变了明确提示需升级 Docker 镜像。
 *   - 更新执行：后端后台下载校验，前端 1s 轮询进度；进入 restarting 后
 *     改为轮询 /health 等服务恢复（前后端全量重启），恢复即整页刷新。
 *   - 回退：切回上一版本（可再次回退撤销）；无上一版本时回落镜像内置版本。
 *   - GitHub 访问令牌：可选，避开匿名限流（60 次/小时/IP，走代理时被同节点用户共享）。
 *   - 维护：重启应用（页底危险卡片，二次确认走全站统一的 useConfirm 弹窗）。原本是本分区第三个
 *     「维护」标签，但那一整个标签从头到尾
 *     只有这一颗按钮；重启与更新/回退本就是同一类"让应用重来一次"的动作，也
 *     共用同一套「等服务恢复再整页刷新」的等待流程，合到这一页的末尾更好找。
 */

type RestartWait = "idle" | "waiting" | "timeout";
/** 重启的起因，只影响等待页文案：换版本是前后端全量重启，手动重启只重启后端 */
type RestartKind = "version" | "app";

/** 等待页文案：两种重启的耗时量级与"迟迟不恢复"时的补救办法都不同，分开写清楚 */
const RESTART_COPY = {
  "version": {
    "waiting": [
      "settings.update.ui.versionWaiting",
      "settings.update.ui.versionWaitingHint"
    ],
    "timeout": [
      "settings.update.ui.restartTimeout",
      "settings.update.ui.versionTimeoutHint"
    ]
  },
  "app": {
    "waiting": [
      "settings.update.ui.appWaiting",
      "settings.update.ui.appWaitingHint"
    ],
    "timeout": [
      "settings.update.ui.restartTimeout",
      "settings.update.ui.appTimeoutHint"
    ]
  }
} as const;

/** 新版本卡片的数据：手动检查结果与服务端快照两个来源归一到同一形状 */
interface AvailableUpdate {
  version: string;
  compatible: boolean;
  changelog: string;
  /** 该版本曾在本机连续启动失败被回落（只有手动检查结果带这一位；
   *  快照侧这类版本压根不会被记为"可更新"，故恒为 false） */
  knownBad: boolean;
}

/**
 * 重启请求失败时，是否属于「连接层面」的失败：status 0 = 网络断开 / 连接被重置
 * （lib/http.ts 把 fetch 的 TypeError 与超时归一成 status 0），502～504 = 反代在后端
 * 退出的瞬间代答的网关错误。这两类可能正是进程退出掐断了请求，属预期；其余状态码
 * 是后端明确给出的业务错误（如公开演示站的 403），服务根本没有重启。
 */
function isConnectionLoss(status: number): boolean {
  return status === 0 || status === 502 || status === 503 || status === 504;
}

export function AppUpdateSection() {
  const demo = useSession().session.demo === true;
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  const [status, setStatus] = useState<UpdateStatusView | null>(null);
  const [failed, setFailed] = useState(false);
  const [check, setCheck] = useState<UpdateCheckView | null>(null);
  const [checking, setChecking] = useState(false);
  const [checkError, setCheckError] = useState<string | null>(null);
  const [progress, setProgress] = useState<UpdateProgressView | null>(null);
  const [actionError, setActionError] = useMessageState();
  const [restartError, setRestartError] = useMessageState();
  const [modelCheck, setModelCheck] = useState<ModelUpdateCheckView | null>(null);
  const [modelChecking, setModelChecking] = useState(false);
  const [modelError, setModelError] = useState<string | null>(null);
  // 服务端待更新快照（进页预填的数据源）。一旦用户手动检查过，改由 check /
  // modelCheck 接管——手动检查的结论更新，不能被这份旧快照盖回去
  const [pendingVersion, setPendingVersion] = useState<AvailableUpdate | null>(null);
  const [pendingModelTag, setPendingModelTag] = useState<string | null>(null);
  const [restartWait, setRestartWait] = useState<RestartWait>("idle");
  const [restartKind, setRestartKind] = useState<RestartKind>("version");
  const confirm = useConfirm();
  // 回退选择器：候选列表（含保留策略现状）在分区挂载时就拉一次——回退卡的
  // 描述与「本地保留版本数」设置行都要用它，不是只有打开弹窗才需要
  const [rollback, setRollback] = useState<RollbackOptionsView | null>(null);
  const [rollbackOpen, setRollbackOpen] = useState(false);
  const [retentionBusy, setRetentionBusy] = useState(false);
  // GitHub 访问令牌：明文只存在于输入框，保存后后端只回打码尾号
  const [tokenView, setTokenView] = useState<GithubTokenView | null>(null);
  const [tokenInput, setTokenInput] = useState("");
  const [tokenBusy, setTokenBusy] = useState(false);
  const pollTimer = useRef<ReturnType<typeof setInterval> | null>(null);
  // 组件已卸载标记：waitForRestart 的长循环不能在用户离开设置页后还整页刷新
  const unmounted = useRef(false);
  // 进度轮询的连续失败计数：单次瞬时错误（反代 502、网络抖动）绝不能被
  // 误判成「后端已进入重启」——那会提前刷新页面并永久丢失更新跟踪
  const pollFailStreak = useRef(0);
  const statusGeneration = useRef(0);

  const reload = useCallback(() => {
    const generation = ++statusGeneration.current;
    setFailed(false);
    getUpdateStatus()
      .then(value => { if (generation === statusGeneration.current) setStatus(value); })
      .catch(() => { if (generation === statusGeneration.current) setFailed(true); });
  }, []);

  const previousLocale = useRef(locale);
  useEffect(() => {
    if (previousLocale.current === locale) return;
    previousLocale.current = locale;
    let current = true;
    reload();
    // Refresh reader-localized facts without restarting an update or its restart timer.
    getUpdateProgress().then(value => { if (current) setProgress(value); }).catch(() => undefined);
    return () => { current = false; };
  }, [locale, reload]);

  /** 「知道了」：让后端清掉异常退出记录，成功后就地隐藏横幅；失败走
   *  actionError 提示、横幅保留——记录还在，下次进页仍会展示。 */
  const dismissExit = useCallback(async () => {
    try {
      await dismissLastAbnormalExit();
      setStatus((s) => (s ? { ...s, last_abnormal_exit: null } : s));
    } catch {
      setActionError({key: "settings.update.ui.dismissFailed"});
    }
  }, [setActionError]);

  /** 全量重启的等待：先观察到服务不可达（sawDown）、再观察到恢复才算完成
   *  一次真实重启——否则可能命中「还没退出的旧进程」提前刷新，刷新后再无
   *  任何轮询跟踪，页面在真正重启时静默失联。 */
  const waitForRestart = useCallback(async (kind: RestartKind = "version") => {
    if (unmounted.current) return;
    setRestartKind(kind);
    setRestartWait("waiting");
    let sawDown = false;
    for (let i = 0; i < 90; i++) {
      if (unmounted.current) return;
      try {
        await getHealth();
        // 恢复成立的两种情况：见过一次不可达（真实重启完成）；或等了足够久
        // 都没见到不可达（重启在两次探测间隙内完成，30 次 ≈ 60 秒后放行）
        if (sawDown || i >= 30) {
          window.location.reload();
          return;
        }
      } catch {
        sawDown = true;
      }
      await new Promise((r) => setTimeout(r, 2000));
    }
    if (!unmounted.current) setRestartWait("timeout");
  }, []);

  /** 更新执行中：轮询进度直到失败或进入重启阶段。 */
  const pollProgress = useCallback(() => {
    if (pollTimer.current) clearInterval(pollTimer.current);
    pollFailStreak.current = 0;
    pollTimer.current = setInterval(async () => {
      try {
        const p = await getUpdateProgress();
        pollFailStreak.current = 0;
        setProgress(p);
        if (p.phase === "failed") {
          if (pollTimer.current) clearInterval(pollTimer.current);
        } else if (p.phase === "restarting") {
          if (pollTimer.current) clearInterval(pollTimer.current);
          void waitForRestart();
        } else if (p.phase === "idle") {
          // 活跃阶段之后读到 idle = 后端已重启完毕（新进程进度是空的）：
          // 更新已生效，直接刷新页面载入新版
          if (pollTimer.current) clearInterval(pollTimer.current);
          window.location.reload();
        }
      } catch {
        // 连续 3 次失败才认定「后端进入重启」，单次瞬时错误继续轮询
        pollFailStreak.current += 1;
        if (pollFailStreak.current >= 3) {
          if (pollTimer.current) clearInterval(pollTimer.current);
          void waitForRestart();
        }
      }
    }, 1000);
  }, [waitForRestart]);

  useEffect(() => {
    unmounted.current = false;
    reload();
    // 恢复进行中的更新跟踪：页面刷新/中途进入设置页时，后台线程可能正在
    // 下载安装（进度在后端单例里）。不恢复的话 UI 会显示空闲、按钮可点，
    // 全量重启来临时页面毫无预警地失联。
    getUpdateProgress()
      .then((p) => {
        if (["checking", "downloading", "verifying", "applying"].includes(p.phase)) {
          setProgress(p);
          pollProgress();
        } else if (p.phase === "restarting") {
          setProgress(p);
          void waitForRestart();
        } else if (p.phase === "failed" && p.error) {
          setProgress(p);
        }
      })
      .catch(() => undefined);
    if (!demo) {
      getGithubToken()
        .then(setTokenView)
        .catch(() => undefined);
    }
    // 进页预填：读定时检查留下的快照，有新版就直接摆出卡片（读库不触网）
    getPendingUpdate()
      .then((p) => {
        setPendingVersion(
          p.app_version
            ? {
                version: p.app_version,
                compatible: p.app_compatible,
                changelog: p.app_changelog,
                knownBad: false,
              }
            : null,
        );
        setPendingModelTag(p.model_tag);
      })
      .catch(() => undefined); // 快照读不到就退回"手动点检查更新"的老路径
    // 回退候选与保留策略（纯本地读盘）；失败不打扰——回退区自然不显示
    getRollbackOptions()
      .then(setRollback)
      .catch(() => undefined);
    return () => {
      unmounted.current = true;
      if (pollTimer.current) clearInterval(pollTimer.current);
    };
  }, [demo, reload, pollProgress, waitForRestart]);

  const doCheck = async () => {
    setChecking(true);
    setCheckError(null);
    setCheck(null);
    try {
      setCheck(await checkUpdate());
    } catch (e) {
      setCheckError((e as Error).message);
    } finally {
      setChecking(false);
    }
  };

  const doApply = async () => {
    setActionError(null);
    try {
      setProgress(await applyUpdate());
      pollProgress();
    } catch (e) {
      setActionError((e as Error).message);
    }
  };

  const doModelCheck = async () => {
    setModelChecking(true);
    setModelError(null);
    setModelCheck(null);
    try {
      setModelCheck(await checkModelUpdate());
    } catch (e) {
      setModelError((e as Error).message);
    } finally {
      setModelChecking(false);
    }
  };

  const doModelApply = async () => {
    setModelError(null);
    try {
      setProgress(await applyModelUpdate());
      pollProgress();
    } catch (e) {
      setModelError((e as Error).message);
    }
  };

  /** 执行回退：restore 由目标的数据兼容判定决定（restore 档自动带上恢复）。 */
  const doRollbackTo = async (target: RollbackTargetView) => {
    setRollbackOpen(false);
    setActionError(null);
    try {
      await rollbackTo(
        target.kind === "baseline" ? "baseline" : (target.version ?? ""),
        target.schema_action === "restore",
      );
      void waitForRestart();
    } catch (e) {
      setActionError((e as Error).message);
    }
  };

  /**
   * 重启应用：请求后端优雅停机（以约定码 42 退出），随后走与更新同一套等待流程。
   * Docker 镜像的 entrypoint 重启循环只重启后端（前端保持运行），前端观察到服务
   * 先不可达、再恢复才整页刷新，不会命中"还没退出的旧进程"提前刷新。
   */
  const doRestart = async () => {
    // 重启会中断正在进行的任务，走全站统一的确认弹窗（与回退等破坏性动作一致）
    const ok = await confirm({
      title: t("settings.update.ui.restartTitle"),
      description:
        t("settings.update.ui.restartConfirmHint"),
      confirmLabel: t("settings.update.ui.restartConfirm"),
      tone: "danger",
    });
    if (!ok) return;
    setRestartError(null);
    try {
      await restartApp();
    } catch (e) {
      if (e instanceof HttpError && !isConnectionLoss(e.status)) {
        setRestartError(e.message);
        return;
      }
    }
    void waitForRestart("app");
  };

  /** 调整本地保留版本数（立即生效并按新策略清理）。 */
  const doSetRetention = async (value: number) => {
    if (!rollback || retentionBusy) return;
    const next = Math.min(20, Math.max(2, value));
    if (next === rollback.keep_versions) return;
    setRetentionBusy(true);
    try {
      await saveUpdateRetention(next);
      setRollback(await getRollbackOptions()); // 清理后占用与候选都可能变化
    } catch (e) {
      setActionError((e as Error).message);
    } finally {
      setRetentionBusy(false);
    }
  };

  /** 保存或清除 GitHub 访问令牌（空串 = 清除）。 */
  const doSaveToken = async (token: string) => {
    if (tokenBusy) return;
    setTokenBusy(true);
    setActionError(null);
    try {
      setTokenView(await saveGithubToken(token));
      setTokenInput("");
    } catch (e) {
      setActionError((e as Error).message);
    } finally {
      setTokenBusy(false);
    }
  };

  if (failed) {
    return (
      <div className="flex items-center gap-3">
        <p className="text-ui text-[var(--text-muted)]">{t("settings.update.ui.loadFailed")}</p>
        <button type="button" onClick={reload} className={SETTINGS_BUTTON_CLASS}>
          {t("common.retry")}</button>
      </div>
    );
  }
  if (!status) {
    return <p className="text-ui text-[var(--text-muted)]">{t("settings.update.ui.loading")}</p>;
  }

  // 重启等待态：全区替换为状态页，避免用户在服务不可用期间继续操作
  if (restartWait !== "idle") {
    const [title, detail] = RESTART_COPY[restartKind][restartWait];
    return (
      <SettingsEmpty
        title={t(title)}
        description={t(detail)}
        action={
          restartWait === "timeout" && (
            <button
              type="button"
              onClick={() => window.location.reload()}
              className={SETTINGS_BUTTON_CLASS}
            >
              {t("settings.update.ui.refresh")}</button>
          )
        }
      />
    );
  }

  const updating =
    progress != null && !["idle", "failed"].includes(progress.phase);
  // 新版本卡片的数据来源：手动检查过就以检查结果为准（哪怕结论是"已最新"，
  // 也要盖掉进页时那份可能已过时的快照），没检查过才用快照预填
  const available: AvailableUpdate | null = check
    ? check.update_available
      ? {
          version: check.latest_version,
          compatible: check.compatible,
          changelog: check.changelog,
          knownBad: check.latest_known_bad,
        }
      : null
    : pendingVersion;
  // 模型侧同理：手动检查结果优先，否则用快照
  const availableModelTag = modelCheck
    ? modelCheck.update_available && modelCheck.installable
      ? modelCheck.latest_tag
      : null
    : pendingModelTag;
  const sourceLabel =
    status.code_source === "overlay"
      ? t("settings.update.ui.overlaySource", {version: status.overlay_version ? ` v${status.overlay_version}` : ""})
      : status.code_source === "baseline"
        ? t("settings.update.ui.baselineSource")
        : t("settings.update.ui.devSource");

  return (
    <div className="space-y-10">
      {/* —— 版本（状态与动作同行：「检查更新」就挂在当前版本行的右侧，
             与 macOS 软件更新/Windows Update 的版式一致）—— */}
      <SettingsSection title={t("settings.update.ui.versionTitle")}>
        <div className="space-y-3">
          <SettingsList>
            <SettingsRow
              stackOnMobile={locale === "en"}
              label={t("settings.update.ui.currentVersion")}
              description={
                <>
                  {t("settings.update.ui.source", {source: sourceLabel})}
                  {/* 手动检查的即时反馈：跟在动作所在的行下方 */}
                  {check && !check.update_available && (
                    <span className="block text-emerald-300/90">
                      {t("settings.update.ui.latest", {version: check.current_version})}
                    </span>
                  )}
                  {demo ? (
                    <span className="block">演示站不提供应用内更新</span>
                  ) : !status.can_update && (
                    <span className="block">{t("settings.update.ui.sourceHint")}</span>
                  )}
                </>
              }
              error={checkError}
            >
              <span className="font-mono text-body text-[var(--text)]">
                v{status.current_version}
              </span>
              {status.can_update && !updating && !demo && (
                <button
                  type="button"
                  onClick={doCheck}
                  disabled={checking}
                  className={SETTINGS_BUTTON_CLASS}
                >
                  <RefreshIcon className={`size-4 ${checking ? "animate-spin" : ""}`} />
                  <span>{checking ? t("settings.update.ui.checking") : t("settings.update.ui.check")}</span>
                </button>
              )}
            </SettingsRow>
          </SettingsList>

          {status.inactive_overlay_version && (
            <Banner tone="info">
              {t("settings.update.ui.inactive", {version: status.inactive_overlay_version, reason: status.inactive_overlay_reason ? t("settings.update.ui.inactiveReason", {reason: status.inactive_overlay_reason}) : ""})}
            </Banner>
          )}
          {status.bad_versions.length > 0 && (
            <Banner tone="warn">
              {t("settings.update.ui.badVersions", {versions: status.bad_versions.map(v => `v${v}`).join(locale === "zh-Hans" ? "、" : ", ")})}
            </Banner>
          )}
          {status.last_abnormal_exit && (
            <Banner
              tone="warn"
              action={
                // 偶发的单次自愈事件看完即可确认消除；真再崩溃会重新落盘再次提醒
                <button type="button" onClick={dismissExit} className={SETTINGS_BUTTON_CLASS}>
                  {t("settings.update.ui.acknowledge")}</button>
              }
            >
              {t("settings.update.ui.abnormalExit", {at: formatUnixDateTime(status.last_abnormal_exit.at, locale), detail: status.last_abnormal_exit.detail, code: status.last_abnormal_exit.exit_code})}
            </Banner>
          )}

          {/* 更新进度：紧跟版本行，替换新版本卡片的位置 */}
          {updating && progress && (
            <SettingsCard
              title={progress.detail || t("settings.update.ui.updating")}
              hint={t("settings.update.ui.updatingHint")}
            >
              {progress.phase === "downloading" && progress.percent != null && (
                <div className="h-1.5 overflow-hidden rounded-full bg-white/[0.08]">
                  <div
                    className="h-full rounded-full bg-[var(--accent)] transition-[width] duration-500"
                    style={{ width: `${progress.percent}%` }}
                  />
                </div>
              )}
            </SettingsCard>
          )}

          {/* 新版本卡片：进页由快照预填，手动检查后以检查结果为准 */}
          {!updating && available && !demo && (
            <SettingsCard
              title={t("settings.update.ui.available", {version: available.version})}
              hint={
                available.compatible ? undefined : (
                  <span className="text-amber-300/90">
                    {t("settings.update.ui.dependencyChange")}</span>
                )
              }
              action={
                available.compatible && (
                  <button type="button" onClick={doApply} className={SETTINGS_PRIMARY_BUTTON_CLASS}>
                    {t("settings.update.ui.apply")}</button>
                )
              }
            >
              {available.knownBad && (
                <p className="mb-3 text-sub text-amber-300/90">
                  {t("settings.update.ui.knownBad", {version: available.version})}
                </p>
              )}
              {/* 更新说明是 GitHub Release 的 Markdown 原文，复用全站的
                  Markdown 渲染器（紧凑档） */}
              {available.changelog && (
                <div className="scroll-thin max-h-64 overflow-y-auto pr-1">
                  <Markdown text={available.changelog} compact />
                </div>
              )}
            </SettingsCard>
          )}
          {actionError && <ErrorBanner>{actionError}</ErrorBanner>}
          {/* 上一次更新（应用或模型）异步失败的统一外显：失败可能发生在任一区
              发起的后台任务里，放在共享位置避免归属混乱 */}
          {progress?.phase === "failed" && progress.error && (
            <ErrorBanner>
              {t("settings.update.ui.updateFailed", {version: progress.target_version ? t("settings.update.ui.failedVersion", {version: progress.target_version}) : "", error: progress.error})}
            </ErrorBanner>
          )}
        </div>
      </SettingsSection>

      {/* —— NER 模型 ——（独立于代码更新；生效需重新解析模型指针，走全量重启） */}
      {status.can_update && !demo && (
        <SettingsSection
          title={t("settings.update.ui.modelTitle")}
          description={t("settings.update.ui.modelHint")}
        >
          <SettingsList>
            <SettingsRow
              stackOnMobile={locale === "en"}
              label={t("settings.update.ui.currentModel", {tag: status.model_tag ?? t("settings.update.ui.unknownModel")})}
              description={
                // 手动检查后的两种"装不了"的结论：只有点过按钮才说，避免进页就
                // 冒出一句无从触发的结论
                modelCheck && !availableModelTag ? (
                  !modelCheck.update_available ? (
                    <span className="text-emerald-300/90">
                      {t("settings.update.ui.modelLatest", {tag: modelCheck.latest_tag})}
                    </span>
                  ) : (
                    <span className="text-amber-300/90">
                      {t("settings.update.ui.modelUnavailable", {tag: modelCheck.latest_tag})}
                    </span>
                  )
                ) : undefined
              }
              error={modelError}
            >
              {!updating && (
                <button
                  type="button"
                  onClick={doModelCheck}
                  disabled={modelChecking}
                  className={SETTINGS_BUTTON_CLASS}
                >
                  {modelChecking ? t("settings.update.ui.checking") : t("settings.update.ui.checkModel")}
                </button>
              )}
            </SettingsRow>
            {/* 有可装的新模型：进页就摆出来（快照预填），手动检查后以检查结果为准 */}
            {availableModelTag && (
              <SettingsRow stackOnMobile={locale === "en"} label={t("settings.update.ui.modelAvailable", {tag: availableModelTag})}>
                <button
                  type="button"
                  onClick={doModelApply}
                  disabled={updating}
                  className={SETTINGS_PRIMARY_BUTTON_CLASS}
                >
                  {t("settings.update.ui.applyModel")}</button>
              </SettingsRow>
            )}
          </SettingsList>
        </SettingsSection>
      )}

      {/* —— 回退与版本保留 ——（有候选版本才出现回退入口；保留数设置常驻） */}
      {status.can_update && rollback && !demo && (
        <SettingsSection title={t("settings.update.ui.rollbackTitle")}>
          <SettingsList>
            {rollback.targets.length > 0 && (
              <SettingsRow
                stackOnMobile={locale === "en"}
                label={t("settings.update.ui.rollbackRow")}
                description={t("settings.update.ui.rollbackHint")}
              >
                <button
                  type="button"
                  onClick={() => setRollbackOpen(true)}
                  disabled={updating}
                  className={SETTINGS_BUTTON_CLASS}
                >
                  {t("settings.update.ui.rollbackOpen")}</button>
              </SettingsRow>
            )}
            <SettingsRow
              stackOnMobile={locale === "en"}
              label={t("settings.update.ui.retention")}
              description={t("settings.update.ui.retentionHint", {usage: rollback.versions_dir_bytes > 0 ? t("settings.update.ui.retentionUsage", {size: formatBytes(rollback.versions_dir_bytes)}) : ""})}
            >
              <button
                type="button"
                aria-label={t("settings.update.ui.retentionDecrease")}
                onClick={() => doSetRetention(rollback.keep_versions - 1)}
                disabled={retentionBusy || rollback.keep_versions <= 2}
                className="btn-glass !size-8 justify-center !p-0 text-body disabled:opacity-40"
              >
                −
              </button>
              <span className="tnum w-8 text-center text-body font-medium text-[var(--text)]">
                {rollback.keep_versions}
              </span>
              <button
                type="button"
                aria-label={t("settings.update.ui.retentionIncrease")}
                onClick={() => doSetRetention(rollback.keep_versions + 1)}
                disabled={retentionBusy || rollback.keep_versions >= 20}
                className="btn-glass !size-8 justify-center !p-0 text-body disabled:opacity-40"
              >
                +
              </button>
            </SettingsRow>
          </SettingsList>
        </SettingsSection>
      )}

      {/* —— GitHub 访问令牌 ——（检查更新走 GitHub API，匿名按出口 IP 限 60 次/小时，
             走代理时与同节点所有人共用，极易被"限流"；配令牌后改按自己账号计 5000 次）
             凭据是显式提交：卡片页脚唯一的保存按钮，没填时置灰 */}
      {!demo && (
        <SettingsSection
          title={t("settings.update.ui.githubTitle")}
          description={t("settings.update.ui.githubHint")}
        >
          <SettingsCard
            title={t("settings.update.ui.tokenTitle")}
            description={tokenView?.configured ? t("settings.update.ui.tokenConfigured", {masked: tokenView.masked}) : t("settings.update.ui.tokenUnset")}
            hint={t("settings.update.ui.tokenHint")}
            action={
              <button
                type="button"
                onClick={() => doSaveToken(tokenInput)}
                disabled={tokenBusy || !tokenInput.trim()}
                className={SETTINGS_PRIMARY_BUTTON_CLASS}
              >
                {t("common.save")}</button>
            }
          >
            <div className="flex items-center gap-2">
              <input
                type="password"
                value={tokenInput}
                onChange={(e) => setTokenInput(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && tokenInput.trim() && void doSaveToken(tokenInput)}
                placeholder={tokenView?.configured ? t("settings.update.ui.tokenReplace") : t("settings.update.ui.tokenPlaceholder")}
                autoComplete="new-password"
                spellCheck={false}
                aria-label={t("settings.update.ui.githubTitle")}
                className={`${SETTINGS_INPUT_CLASS} min-w-0 flex-1`}
              />
              {tokenView?.configured && (
                <button
                  type="button"
                  onClick={() => doSaveToken("")}
                  disabled={tokenBusy}
                  className={SETTINGS_BUTTON_CLASS}
                >
                  {t("settings.update.ui.tokenClear")}</button>
              )}
            </div>
          </SettingsCard>
        </SettingsSection>
      )}

      {/* —— 维护 ——（重启应用会打断正在进行的任务：放在本页最后、用危险卡片，
             与上面的更新动作隔开，避免顺手误点；点击后先确认） */}
      {!demo && (
        <SettingsSection title={t("settings.update.ui.maintenance")}>
          <SettingsCard
            tone="danger"
            title={t("settings.update.ui.restart")}
            description={t("settings.update.ui.restartHint")}
            hint={t("settings.update.ui.restartDeploymentHint")}
            action={
              <button
                type="button"
                onClick={() => void doRestart()}
                disabled={updating}
                className={SETTINGS_DANGER_BUTTON_CLASS}
              >
                {t("settings.update.ui.restart")}</button>
            }
          />
          {restartError && <ErrorBanner>{restartError}</ErrorBanner>}
        </SettingsSection>
      )}

      <RollbackDialog
        open={rollbackOpen}
        onClose={() => setRollbackOpen(false)}
        targets={rollback?.targets ?? []}
        onConfirm={doRollbackTo}
      />
    </div>
  );
}

/**
 * 回退选择器弹窗：候选版本列表（新的在前）→ 选中展开详情（更新说明 + 数据
 * 兼容结论）→ 底部一颗写明落点与数据后果的确认按钮。
 *
 * 数据兼容三档的呈现（对应后端 schema_action）：
 *   switch  绿字「数据结构一致，直接切换，数据全保留」——零顾虑；
 *   restore 琥珀字明示「将恢复 X 时点的备份，此后数据丢失」——必须知情确认；
 *   unknown 红字强警告「无对应备份，不保证正常运行」——仍可执行但后果自负。
 */
function RollbackDialog({
  open,
  onClose,
  targets,
  onConfirm,
}: {
  open: boolean;
  onClose: () => void;
  targets: RollbackTargetView[];
  onConfirm: (target: RollbackTargetView) => void;
}) {
  const t = useTranslations();
  const locale = useLocale() as AppLocale;
  // 选中项按索引记（targets 来自快照数据，弹窗生命周期内不变）
  const [selected, setSelected] = useState<number | null>(null);
  useEffect(() => {
    if (open) setSelected(null); // 每次打开都从未选状态开始，避免带着上次的选择
  }, [open]);

  const pick = selected != null ? targets[selected] : null;
  const label = (target: RollbackTargetView) =>
    target.kind === "baseline"
      ? t("settings.update.ui.baselineVersion", {version: target.version ? ` v${target.version}` : ""})
      : `v${target.version}`;

  return (
    <Modal
      open={open}
      onClose={onClose}
      label={t("settings.update.ui.selectRollback")}
      width="lg"
      panelClassName="flex max-h-[76dvh] flex-col"
    >
      <div className="px-5 pb-3 pt-5">
        <h2 className="text-title-sm font-semibold text-[var(--text)]">{t("settings.update.ui.selectRollback")}</h2>
        <p className="mt-1 text-sub text-[var(--text-muted)]">
          {t("settings.update.ui.rollbackDialogHint")}</p>
      </div>
      <div className="scroll-thin flex-1 space-y-2 overflow-y-auto px-5 pb-4">
        {targets.map((target, i) => (
          // 展开区不放进 <button>：更新说明里可能有链接（Markdown），交互元素
          // 嵌套交互元素是非法结构。头部行是按钮，详情是它下方的兄弟块
          <div
            key={`${target.kind}-${target.version ?? "?"}`}
            className={`rounded-xl border transition-colors ${
              i === selected
                ? "border-white/[0.18] bg-white/[0.07]"
                : "border-white/[0.07] bg-white/[0.03] hover:bg-white/[0.05]"
            }`}
          >
            <button
              type="button"
              onClick={() => setSelected(i === selected ? null : i)}
              className="flex w-full flex-wrap items-center gap-x-3 gap-y-1 px-4 py-3 text-left"
            >
              <span className="text-ui font-semibold text-[var(--text)]">{label(target)}</span>
              {target.schema_action === "switch" ? (
                <span className="text-caption text-emerald-300/90">{t("settings.update.ui.switchSafe")}</span>
              ) : target.schema_action === "restore" ? (
                <span className="text-caption text-amber-300/90">
                  {t("settings.update.ui.restoreBackup", {at: formatDateTime(target.backup_taken_at, locale)})}
                </span>
              ) : (
                <span className="text-caption text-red-300/90">{t("settings.update.ui.backupMissing")}</span>
              )}
              <span className="ml-auto text-caption text-[var(--text-faint)]">
                {[
                  target.installed_at ? t("settings.update.ui.installedAt", {at: formatDateTime(target.installed_at, locale)}) : null,
                  target.size_bytes != null ? formatBytes(target.size_bytes) : null,
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </span>
              <ChevronRightIcon
                className={`size-4 shrink-0 text-[var(--text-faint)] transition-transform ${
                  i === selected ? "rotate-90" : ""
                }`}
              />
            </button>
            {/* 选中展开：数据后果 + 该版本的更新说明 */}
            {i === selected && (
              <div className="border-t border-white/[0.06] px-4 py-2.5">
                {target.schema_action === "switch" ? (
                  <p className="text-sub text-emerald-300/90">
                    {t("settings.update.ui.switchSafeHint")}</p>
                ) : target.schema_action === "restore" ? (
                  <p className="text-sub text-amber-300/90">
                    {t("settings.update.ui.restoreHint", {at: formatDateTime(target.backup_taken_at, locale)})}
                  </p>
                ) : (
                  <p className="text-sub text-red-300/90">
                    {t("settings.update.ui.backupMissingHint")}</p>
                )}
                {target.changelog && (
                  <div className="scroll-thin mt-2.5 max-h-48 overflow-y-auto pr-1">
                    <Markdown text={target.changelog} compact />
                  </div>
                )}
              </div>
            )}
          </div>
        ))}
      </div>
      {/* 底栏：确认按钮写明落点与数据后果，这是点下去前看到的最后一句话 */}
      <div className="flex items-center justify-end gap-2 border-t border-white/[0.06] px-5 py-3.5">
        <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
          {t("common.cancel")}</button>
        <button
          type="button"
          disabled={pick == null}
          onClick={() => pick && onConfirm(pick)}
          className={`${SETTINGS_DANGER_BUTTON_CLASS} ${locale === "en" ? "!h-auto min-h-8 min-w-0 !shrink whitespace-normal py-1.5" : ""}`}
        >
          {pick == null
            ? t("settings.update.ui.selectVersion")
            : pick.schema_action === "restore"
              ? t("settings.update.ui.rollbackRestore", {version: label(pick)})
              : t("settings.update.ui.rollbackRestart", {version: label(pick)})}
        </button>
      </div>
    </Modal>
  );
}
