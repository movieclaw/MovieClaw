"use client";

import { useLocale, useTranslations } from "next-intl";

import { useCallback, useEffect, useRef, useState } from "react";

import { Banner, ErrorBanner, Toggle } from "@/components/cloud-push-ui";
import { useToast } from "@/components/feedback";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SettingsEmpty,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import { type LoginDeviceView, listLoginDevices } from "@/lib/api/devices";
import { relativeTime } from "@/lib/devices-display";
import {
  type RemoteTranscodeConfigView,
  type RemoteTranscodeStatus,
  getRemoteTranscodeConfig,
  getRemoteTranscodeStatus,
  saveRemoteTranscodeConfig,
  saveWorkerLimit,
} from "@/lib/api/transcode-worker";

const BYTES_PER_MIB = 1024 * 1024;
/** Worker 在线状态的轮询间隔；配这个页面时用户就盯着它看，要够跟手。 */
const STATUS_POLL_MS = 5000;
/**
 * 单个 HLS 产物的上传上限，固定 512 MiB，不再让用户填。
 *
 * 它从来不是偏好，是 Worker 内存上传代理的实现上限——服务端的
 * DEFAULT 与 MAX 是同一个数（settings/remote_transcode.py），所以这个值
 * **只能往下调，而往下调只有坏处**：实际分片是 4 秒的 fMP4，通常几 MB 到
 * 几十 MB，离 512 MiB 差两个数量级；调到分片大小以下，播放会在上传阶段
 * 撞 413 失败。NAS 侧是流式落盘、不占内存，调低也省不出任何东西。
 *
 * 一个只能把事情弄坏、用户又无从判断该填多少的输入框，不该出现在界面上。
 */
const ARTIFACT_LIMIT_BYTES = 512 * BYTES_PER_MIB;

export interface RemoteTranscodeSectionProps {
  /** 去「设备」分区批准或注销 Worker。批准是这条链路的必经一步，得能一键到。 */
  onOpenDevices?: () => void;
}

/**
 * 「播放」分区的远程转码设置（原「应用 → 远程转码」标签，设置页按功能重组后
 * 迁入「媒体库」组）。
 *
 * 在这里启用远程转码，并调整每台设备的并发上限。开关、并发上限改完即存；
 * 覆盖地址是单个文本值，失焦或回车提交。
 *
 * Worker 用哪个地址连过来，是在转码器那侧填的；服务端下发任务时用的取源地址和
 * 产物回传地址，默认直接取用那条控制连接自报的地址（remote_worker.py 的
 * observed_base_url）。所以地址在这一页降级成「高级」里的覆盖项，只服务于
 * 反向代理改写 Host 的少数部署，也不再和系统外部访问地址有任何关系。
 */
export function RemoteTranscodeSection({ onOpenDevices }: RemoteTranscodeSectionProps) {
  const t = useTranslations();
  const locale = useLocale();
  const [config, setConfig] = useState<RemoteTranscodeConfigView | null>(null);
  const [enabled, setEnabled] = useState(false);
  const [baseURLDraft, setBaseURLDraft] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [toggling, setToggling] = useState(false);
  const [toggleError, setToggleError] = useState<string | null>(null);
  const [savingURL, setSavingURL] = useState(false);
  const [urlError, setURLError] = useState<string | null>(null);
  // Esc 放弃：随后的失焦不再提交（失焦回调读到的还是改过的草稿）
  const discardRef = useRef(false);
  const toast = useToast();
  const [status, setStatus] = useState<RemoteTranscodeStatus | null>(null);
  const [savingLimit, setSavingLimit] = useState<number | null>(null);
  // 已授权的 Worker：「设备」里 scope=transcode 的那些（配对出来的转码器，以及
  // 给命令行模式转码器用的「仅限转码」手工令牌）。运行时注册表在断线时会把
  // Worker 整个摘掉（remote_worker.py 的 unregister），所以只看 status.workers
  // 的话，Mac 一关机这台设备就从页面上凭空消失，用户会以为自己从来没配过、跟着
  // 引导又配一遍。授权是持久的，这份清单补上「配过但现在没连着」的那些。
  //
  // 待批准的请求这里看不到了：服务端不再列出待批准请求（只能按配对码查），
  // 转码器发起配对时会直接打开带码的批准页（docs/design/login-devices.md §4）。
  const [authorizedWorkers, setAuthorizedWorkers] = useState<LoginDeviceView[]>([]);

  async function updateLimit(deviceID: number, value: number) {
    setSavingLimit(deviceID);
    setError(null);
    try {
      await saveWorkerLimit(deviceID, value);
      setStatus(await getRemoteTranscodeStatus());
    } catch (e) {
      setError(e instanceof Error ? e.message : t("settings.playback.controls.limitFailed"));
    } finally {
      setSavingLimit(null);
    }
  }

  function limitControl(name: string, deviceID: number, value: number, supported = true) {
    return (
      <label className="flex items-center gap-2 text-caption text-[var(--text-muted)]">
        {savingLimit === deviceID ? t("settings.playback.controls.saving") : t("settings.playback.controls.concurrent")}
        <select
          aria-label={t("settings.playback.controls.limitLabel", { name })}
          className={SETTINGS_INPUT_CLASS}
          value={value}
          disabled={savingLimit !== null || !supported}
          onChange={(event) => void updateLimit(deviceID, Number(event.target.value))}
        >
          {[1, 2, 3, 4].map((limit) => <option key={limit} value={limit}>{t("settings.playback.controls.limitCount", { count: limit })}</option>)}
        </select>
      </label>
    );
  }

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const next = await getRemoteTranscodeConfig();
      setConfig(next);
      setEnabled(next.enabled);
      setBaseURLDraft(next.base_url_override);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  // Worker 在线状态独立轮询：它和配置是两回事，配置保存成功不代表 Mac 连上了。
  // 拉取失败不弹错——这是个附属指示器，不该盖掉用户正在填的表单。
  useEffect(() => {
    let alive = true;
    async function poll() {
      try {
        const next = await getRemoteTranscodeStatus();
        if (alive) setStatus(next);
      } catch {
        if (alive) setStatus(null);
      }
      try {
        // all=true 按全体取：转码凭证眼下都归超管（只有超管能批准转码器、创建
        // 令牌），但这一页要回答的是「这台服务器配过哪些转码器」，不该依赖
        // 「都归超管」这条假设。本分区只对超管开放，all=true 可用
        const devices = await listLoginDevices(true);
        if (alive) setAuthorizedWorkers(devices.filter((d) => d.scope === "transcode"));
      } catch {
        if (alive) setAuthorizedWorkers([]);
      }
    }
    void poll();
    const timer = window.setInterval(() => void poll(), STATUS_POLL_MS);
    return () => {
      alive = false;
      window.clearInterval(timer);
    };
  }, []);

  /**
   * 开关改完即存。只提交 enabled：base_url 传 null 表示保持当前覆盖地址不动
   * （见 RemoteTranscodeConfigPayload），不会把「高级」里没提交的草稿一并存掉。
   */
  async function toggleEnabled(next: boolean) {
    setEnabled(next); // 乐观更新：失败回滚
    setToggling(true);
    setToggleError(null);
    try {
      const saved = await saveRemoteTranscodeConfig({
        enabled: next,
        base_url: null,
        // 存量若被调低过，这一步顺手拉回默认值——高上限只会更少地误伤
        max_artifact_bytes: ARTIFACT_LIMIT_BYTES,
      });
      setConfig(saved);
      setEnabled(saved.enabled);
      void getRemoteTranscodeStatus().then(setStatus).catch(() => {});
    } catch (e) {
      setEnabled(!next);
      setToggleError((e as Error).message);
    } finally {
      setToggling(false);
    }
  }

  /** 覆盖地址：失焦或回车提交，Esc 放弃；没改动不发请求。 */
  async function commitBaseURL() {
    if (discardRef.current) {
      discardRef.current = false;
      return;
    }
    if (config == null) return;
    const next = baseURLDraft.trim();
    if (next === config.base_url_override) {
      setBaseURLDraft(config.base_url_override);
      return;
    }
    setSavingURL(true);
    setURLError(null);
    try {
      const saved = await saveRemoteTranscodeConfig({
        enabled: config.enabled,
        base_url: next,
        max_artifact_bytes: ARTIFACT_LIMIT_BYTES,
      });
      setConfig(saved);
      setBaseURLDraft(saved.base_url_override);
      toast.success(next ? t("settings.playback.controls.overrideSaved") : t("settings.playback.controls.autoRestored"));
      void getRemoteTranscodeStatus().then(setStatus).catch(() => {});
    } catch (e) {
      setURLError((e as Error).message);
      setBaseURLDraft(config.base_url_override);
    } finally {
      setSavingURL(false);
    }
  }

  if (loading) {
    return <p className="text-ui text-[var(--text-muted)]">{t("settings.playback.controls.loadingRemote")}</p>;
  }

  if (config == null) {
    return (
      <SettingsSection title={t("settings.playback.controls.remoteTitle")}>
        <div className="space-y-3">
          <ErrorBanner>{error ?? t("settings.playback.controls.loadRemoteFailed")}</ErrorBanner>
          <button type="button" onClick={() => void load()} className={SETTINGS_BUTTON_CLASS}>
            {t("settings.playback.controls.retry")}
          </button>
        </div>
      </SettingsSection>
    );
  }

  const onlineWorkers = status?.workers.filter((w) => w.online) ?? [];
  // 按授权设备匹配，Worker 改名或使用不同名称的手工令牌都不会多出一条离线记录。
  const connectedDevices = new Set((status?.workers ?? []).map((w) => `ld-${w.device_id}`));
  const offlineWorkers = authorizedWorkers.filter((d) => !connectedDevices.has(d.id));
  const hasAnyWorker = (status?.workers.length ?? 0) > 0 || offlineWorkers.length > 0;
  // 开关打开 ≠ Worker 连上了。这两件事分开说，用户才知道下一步该干什么：
  // 前者不满足要打开开关（或改正「高级」里填错的覆盖地址），后者不满足
  // 要去 Mac 上看 App。
  const statusText = !config.enabled
    ? t("settings.playback.controls.off")
    : !config.ready
      ? t("settings.playback.controls.invalidOverride")
      : onlineWorkers.length > 0
        ? t("settings.playback.controls.ready", { count: onlineWorkers.length })
        : t("settings.playback.controls.noConnection");
  const statusClass = !config.enabled
    ? "text-[var(--text-muted)]"
    : config.ready && onlineWorkers.length > 0
      ? "text-emerald-300"
      : "text-amber-200";
  // 「设备」页入口：这一页只回答「现在连着吗、在干什么」；「批准新的、授权还在
  // 不在、要不要注销」是设备页的事，两页各管一段，互相指路。
  const devicesLink = onOpenDevices && (
    <button
      type="button"
      onClick={onOpenDevices}
      className="text-[var(--accent)] underline decoration-dotted underline-offset-2"
    >
      {t("settings.playback.controls.deviceLink")}
    </button>
  );
  return (
    <>
      <SettingsSection
        title={t("settings.playback.controls.remoteTitle")}
        description={t("settings.playback.controls.remoteHint")}
      >
        <div className="space-y-3">
          {error && <ErrorBanner>{error}</ErrorBanner>}
          <SettingsList>
            {/* 开关刻意不依赖「有没有 Worker 连着」，两个方向的理由都很硬：
                · 关着时 Worker 连 WebSocket 都握不上（routes/transcode_worker.py
                  的 remote_worker_enabled 闸），要求「先有连接才能开」是死锁；
                · Worker 会掉线（Mac 睡眠、关机、网络抖动）。开关跟着连接走，
                  意味着睡一觉起来设置被改了，或者想关都关不掉。
                开关是**意图**，连接是**现实**，绑在一起就等于掉线即失忆。
                开着而没有 Worker 也无害：决策层每次播放都查 remote_worker_available，
                没有就走本地。所以这里不禁用，只把两个方向的后果说清楚。 */}
            <SettingsRow
              label={t("settings.playback.controls.enableRemote")}
              description={
                enabled
                  ? t("settings.playback.controls.fallbackHint")
                  : t("settings.playback.controls.disabledRemoteHint")
              }
              error={toggleError}
            >
              <Toggle
                checked={enabled}
                label={t("settings.playback.controls.enableRemote")}
                disabled={toggling}
                onChange={(next) => void toggleEnabled(next)}
              />
            </SettingsRow>
            <SettingsRow
              stackOnMobile={locale === "en"}
              label={t("settings.playback.controls.status")}
              description={
                config.issues.length > 0 && (
                  <ul className="space-y-0.5 text-amber-200/90">
                    {config.issues.map((issue) => <li key={issue}>· {issue}</li>)}
                  </ul>
                )
              }
            >
              <span className={`max-w-[18rem] text-right text-sub ${statusClass}`}>{statusText}</span>
            </SettingsRow>
          </SettingsList>
        </div>
      </SettingsSection>

      {/* Worker 单独成节：配完之后「成没成」全靠这一块回答，它是这一页最该被看见的内容。 */}
      <SettingsSection
        title="Worker"
        footnote={
          hasAnyWorker && (
            <>
              {t("settings.playback.controls.limitHint")}{devicesLink}
            </>
          )
        }
      >
        <div className="space-y-3">
          {/* Worker 的 WebSocket 被 remote_worker_enabled（开关打开 AND 地址
              合法）挡着。做成横幅而不是替换整块内容：已授权的设备该照常列出来，
              用户需要同时看到「我配过哪几台」和「现在为什么连不上」。 */}
          {!config.ready && (
            <Banner tone="warn">
              {!config.enabled
                ? t("settings.playback.controls.disabledWorker")
                : t("settings.playback.controls.invalidWorker")}
            </Banner>
          )}

          {status == null ? (
            <p className="px-1 text-caption text-[var(--text-faint)]">{t("settings.playback.controls.loadingWorkers")}</p>
          ) : hasAnyWorker ? (
            <SettingsList>
              {status.workers.map((worker) => (
                <SettingsRow
                  key={worker.worker_id}
                  stackOnMobile={locale === "en"}
                  label={
                    <span className="flex items-center gap-2">
                      <span className="truncate">{worker.worker_id}</span>
                      <span
                        className={`shrink-0 text-caption font-normal ${
                          worker.online
                            ? worker.draining
                              ? "text-amber-200"
                              : "text-emerald-300"
                            : "text-[var(--text-faint)]"
                        }`}
                      >
                        {worker.online ? (worker.draining ? t("settings.playback.controls.draining") : t("settings.playback.controls.online")) : t("settings.playback.controls.offline")}
                      </span>
                    </span>
                  }
                  description={
                    <>
                      {[
                        worker.platform,
                        worker.arch,
                        worker.hardware.chip,
                        worker.hardware.cpu_cores ? t("settings.playback.controls.cores", { count: worker.hardware.cpu_cores }) : null,
                        worker.hardware.memory_bytes ? `${Math.round(worker.hardware.memory_bytes / 1024 ** 3)} GB` : null,
                        worker.ffmpeg_version ? `ffmpeg ${worker.ffmpeg_version}` : null,
                        worker.backends.length > 0 ? worker.backends.join("/") : null,
                        t("settings.playback.controls.jobs", { active: worker.active_jobs, max: worker.max_jobs }),
                        t("settings.playback.controls.seen", { count: Math.round(worker.last_seen_seconds) }),
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                      {worker.load && (
                        <span className="block">
                          {t("settings.playback.controls.load", { cpu: Math.round(worker.load.cpu * 100), pressure: String(worker.load.memory_pressure), hot: worker.load.thermal_state >= 2 ? "yes" : "no" })}
                        </span>
                      )}
                      {!worker.server_config && (
                        <span className="block">{t("settings.playback.controls.upgradeWorker")}</span>
                      )}
                    </>
                  }
                >
                  {worker.device_id != null && limitControl(worker.worker_id, worker.device_id,
                    status.device_limits[`ld-${worker.device_id}`] ?? worker.max_jobs, worker.server_config)}
                </SettingsRow>
              ))}
              {/* 已授权但没连上来的。它们在运行时注册表里不存在，但授权还在，
                  用户也确实配过——不显示的话，Mac 一关机这台就凭空消失，
                  引导还会催他重新配对一遍。 */}
              {offlineWorkers.map((device) => (
                <SettingsRow
                  key={device.id}
                  stackOnMobile={locale === "en"}
                  label={
                    <span className="flex items-center gap-2">
                      <span className="truncate text-[var(--text-muted)]">{device.name}</span>
                      <span className="shrink-0 text-caption font-normal text-[var(--text-faint)]">
                        {t("settings.playback.controls.disconnected")}
                      </span>
                    </span>
                  }
                  description={t("settings.playback.controls.offlineHint", { time: relativeTime(device.last_seen_at, undefined, locale), ready: config.ready ? "yes" : "no" })}
                >
                  {limitControl(device.name, Number(device.id.replace("ld-", "")), status.device_limits[device.id] ?? 1)}
                </SettingsRow>
              ))}
            </SettingsList>
          ) : config.ready ? (
            <SettingsEmpty
              title={t("settings.playback.controls.noWorkers")}
              description={
                <>
                  {t("settings.playback.controls.pairHint")}
                </>
              }
              action={
                onOpenDevices && (
                  <button type="button" onClick={onOpenDevices} className={SETTINGS_BUTTON_CLASS}>
                    {t("settings.playback.controls.devices")}
                  </button>
                )
              }
            />
          ) : null}
        </div>
      </SettingsSection>

      {/* 地址不再是必填项，降级成「高级」里的一行覆盖项。
          服务端下发任务时会用「这台 Worker 自己连上来的地址」拼源视频 URL 和
          产物上传 URL（remote_worker.py 的 observed_base_url）——Worker 刚从
          那个地址握上手，它必然够得着，没有任何理由再让人抄一遍。覆盖项只为
          反向代理改写了 Host、推断失真的少数部署保留。 */}
      <SettingsSection
        title={t("settings.playback.controls.advanced")}
        footnote={t("settings.playback.controls.advancedHint")}
      >
        <SettingsList>
          <SettingsRow
            stackOnMobile={locale === "en"}
            label={t("settings.playback.controls.address")}
            description={
              config.base_url_source === "remote_transcode_setting"
                ? t("settings.playback.controls.overridden", { url: config.base_url })
                : t("settings.playback.controls.autoAddress")
            }
            error={urlError}
          >
            <input
              type="url"
              aria-label={t("settings.playback.controls.addressLabel")}
              value={baseURLDraft}
              onChange={(event) => {
                setBaseURLDraft(event.target.value);
                setURLError(null);
              }}
              onBlur={() => void commitBaseURL()}
              onKeyDown={(event) => {
                if (event.key === "Enter") event.currentTarget.blur();
                if (event.key === "Escape") {
                  discardRef.current = true;
                  setBaseURLDraft(config.base_url_override);
                  setURLError(null);
                  event.currentTarget.blur();
                }
              }}
              placeholder={t("settings.playback.controls.addressPlaceholder")}
              disabled={savingURL}
              spellCheck={false}
              className={`${SETTINGS_INPUT_CLASS} w-60 ${locale === "en" ? "max-sm:w-full" : "max-sm:w-40"}`}
            />
          </SettingsRow>
        </SettingsList>
      </SettingsSection>
    </>
  );
}
