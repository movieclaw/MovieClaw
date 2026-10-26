"use client";

import { useLocale, useTranslations } from "next-intl";

/**
 * 「MovieClaw Cloud」设置分区（docs/design/cloud-push.md §0、§2、§7.1、§8）。
 *
 * 把整台服务器连接到管理员的 MovieClaw 账号：一次性的、管理员的动作，以后云端
 * 加的能力（远程访问……）都挂在这一页下面。用词上叫「连接」，不叫「登录」也
 * 不叫「绑定设备」——服务器拿到的是它自己的凭证，碰不到账号本身（§0.2）。
 *
 * 页面按 GET /cloud 的 state 分三态，所有写接口都返回同一份 CloudStatusView，
 * 拿到响应就整页重画：
 *   - disconnected：讲清连接做什么，「会上报哪些信息」链接到官网隐私政策的那一节，留出
 *     「不连接」的出口（IM 推送、自建中继）。不连接不是错误，页面不用警告色；
 *   - pairing：配对码弹窗（components/cloud/pairing-dialog.tsx）；关掉弹窗不取消，
 *     页面上留一张卡片可以重新打开；
 *   - connected：连在谁的账号下、权限和能力、异常横幅、服务通知、统计开关与
 *     「上报哪些信息」的说明链接（官网隐私政策）、断开。
 */

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";

import { CloudPairingDialog } from "@/components/cloud/pairing-dialog";
import {
  Banner,
  ErrorBanner,
  LINK_CLASS,
  Spinner,
  StatusPill,
  Toggle,
} from "@/components/cloud-push-ui";
import { useConfirm, useToast } from "@/components/feedback";
import { CloudIcon, InfoIcon } from "@/components/icons";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_DANGER_BUTTON_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsCard,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type CloudConnectionView,
  type CloudPairingView,
  type CloudStatusView,
  disconnectCloud,
  dismissCloudNotice,
  getCloudStatus,
  isCloudUnreachable,
  renewCloud,
  updateCloudSettings,
} from "@/lib/api/cloud";
import {
  capabilityRows,
  cloudInstancesUrl,
  cloudReportsInfoUrl,
  connectedAccountLine,
  healthMessage,
  healthTone,
  noticeTone,
  pairingFailureText,
} from "@/lib/cloud-push-display";
import { formatDateTime, formatRelativeTime } from "@/lib/time";
import { useVisiblePolling } from "@/lib/use-visible-polling";

type Run = (action: () => Promise<CloudStatusView>) => Promise<CloudStatusView>;

export function CloudSection() {
  const t = useTranslations();
  const locale = useLocale();
  const [status, setStatus] = useState<CloudStatusView | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [pairingOpen, setPairingOpen] = useState(false);

  // 写操作开始时 epoch 加一、进行中计数；轮询只在没有写操作时发，晚到的、早于
  // 写操作发出的快照一律丢弃——否则「获取配对码」请求还在路上时，一次轮询拿回的
  // 未连接快照会把弹窗打回填名字那一步。
  const epochRef = useRef(0);
  const writingRef = useRef(0);

  const refresh = useCallback((reportError: boolean) => {
    if (writingRef.current > 0) return;
    const epoch = epochRef.current;
    getCloudStatus(locale).then(
      (next) => {
        if (epoch === epochRef.current && writingRef.current === 0) setStatus(next);
      },
      (e: Error) => {
        // 轮询失败静默，保留上一份状态；只有首次加载失败才要报错
        if (reportError) setLoadError(e.message);
      },
    );
  }, [locale]);

  const run = useCallback<Run>(async (action) => {
    epochRef.current += 1;
    writingRef.current += 1;
    try {
      const next = await action();
      setStatus(next);
      return next;
    } finally {
      writingRef.current -= 1;
    }
  }, []);

  useEffect(() => {
    epochRef.current += 1;
    refresh(true);
  }, [refresh]);

  // 配对弹窗开着时每 2 秒读一次；弹窗关了但配对还在等批准，就放慢到 5 秒，
  // 官网批准后页面同样会自己变成已连接
  const awaitingApproval = status?.state === "pairing" && status.pairing?.status === "pending";
  useVisiblePolling(
    () => refresh(false),
    pairingOpen ? 2000 : awaitingApproval ? 5000 : null,
  );

  const openPairing = useCallback(() => setPairingOpen(true), []);
  // 稳定引用：弹窗里「已连接后自动收起」的计时器依赖它
  const closePairing = useCallback(() => setPairingOpen(false), []);

  if (status == null) {
    return loadError ? (
      <div className="space-y-3">
        <ErrorBanner>{loadError}</ErrorBanner>
        <button
          type="button"
          onClick={() => {
            setLoadError(null);
            refresh(true);
          }}
          className="btn-glass px-4 py-1.5 text-sub font-medium"
        >
          {t("common.retry")}
        </button>
      </div>
    ) : (
      <div className="space-y-3">
        <div className="h-[168px] animate-pulse rounded-2xl bg-white/[0.04]" />
        <div className="h-[72px] animate-pulse rounded-xl bg-white/[0.04]" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {status.state === "connected" ? (
        <ConnectedView status={status} run={run} />
      ) : status.state === "pairing" ? (
        <PairingCard pairing={status.pairing} onOpen={openPairing} />
      ) : (
        <DisconnectedView status={status} onConnect={openPairing} />
      )}

      {/* 开发者用 MOVIECLAW_CLOUD_URL 指向了自己的云端：低调说一句，免得对着官网找不到这台服务器 */}
      {status.custom_cloud_url && (
        <p className="flex items-start gap-2 px-1 text-caption leading-5 text-[var(--text-faint)]">
          <InfoIcon className="mt-0.5 size-3.5 shrink-0" />
          <span className="min-w-0">
            {t("settings.cloudConnect.developerPrefix")}{" "}
            <span className="break-words font-mono text-[var(--text-muted)]">{status.cloud_url}</span>
            {t("settings.cloudConnect.developerEnv")}
          </span>
        </p>
      )}

      {pairingOpen && <CloudPairingDialog status={status} run={run} onClose={closePairing} />}
    </div>
  );
}

/* —— 未连接 —— */

function DisconnectedView({
  status,
  onConnect,
}: {
  status: CloudStatusView;
  onConnect: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const lastDisconnect = status.last_disconnect;

  return (
    <div className="space-y-5">
      {/* 被动断开（在官网解绑、账号删除）：平静地说明，不用警告色——这是结果，不是故障 */}
      {lastDisconnect && (
        <Banner tone="neutral" title={t("settings.cloudConnect.disconnectedTitle")}>
          {lastDisconnect.message?.trim() || t("settings.cloudConnect.disconnectedHint")}
          {lastDisconnect.at && (
            <span className="text-[var(--text-faint)]"> · {formatRelativeTime(lastDisconnect.at, locale)}</span>
          )}
        </Banner>
      )}

      <div>
        <SettingsCard
          title={t("settings.cloudConnect.notConnected")}
          description={t("settings.cloudConnect.connectHint")}
          hint={
            <a
              href={cloudReportsInfoUrl(status.cloud_url, locale)}
              target="_blank"
              rel="noopener noreferrer"
              className={LINK_CLASS}
            >
              {t("settings.cloudConnect.reportsLink")}</a>
          }
          action={
            <button type="button" onClick={onConnect} className={SETTINGS_PRIMARY_BUTTON_CLASS}>
              {t("settings.cloudConnect.connect")}
            </button>
          }
        />
        {/* 给不连接的人留出口：卡片下方一行补充说明，不再另起一条横幅 */}
        <p className="mt-2 px-1 text-caption leading-5 text-[var(--text-faint)]">
          {t("settings.cloudConnect.imAlternative")}{" "}
          <Link href="/settings/im-push" className={LINK_CLASS}>
            {t("settings.cloudConnect.imPush")}
          </Link>
          {t("settings.cloudConnect.appAlternative")}{" "}
          <Link href="/settings/app-push" className={LINK_CLASS}>
            {t("settings.cloudConnect.appPush")}</Link>{" "}
          {t("settings.cloudConnect.relayAlternative")}
        </p>
      </div>
    </div>
  );
}

/* —— 配对中（弹窗关着时） —— */

function PairingCard({
  pairing,
  onOpen,
}: {
  pairing: CloudPairingView | null;
  onOpen: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const pending = pairing == null || pairing.status === "pending";
  return (
    <SettingsCard
      title={pending ? t("settings.cloudConnect.waitingWebsite") : t("settings.cloudConnect.incomplete")}
      description={
        pairing == null ? (
          t("settings.cloudConnect.requestingCode")
        ) : pending ? (
          <>
            {t("settings.cloudConnect.pairingCode")} <span className="font-mono text-[var(--text)]">{pairing.user_code}</span>
            {t("settings.cloudConnect.pairingAutoConnect")}</>
        ) : (
          pairingFailureText(pairing.status, pairing.message, locale)
        )
      }
      hint={
        pending && (
          <span className="flex items-center gap-2">
            <Spinner />
            {t("settings.cloudConnect.waitingApproval")}
          </span>
        )
      }
      action={
        <button type="button" onClick={onOpen} className={SETTINGS_PRIMARY_BUTTON_CLASS}>
          {pending ? t("settings.cloudConnect.viewCode") : t("settings.cloudConnect.reconnect")}
        </button>
      }
    />
  );
}

/* —— 已连接 —— */

function ConnectedView({ status, run }: { status: CloudStatusView; run: Run }) {
  const t = useTranslations();
  const locale = useLocale();
  const confirm = useConfirm();
  const toast = useToast();
  const [busy, setBusy] = useState<"renew" | "disconnect" | null>(null);
  // 统计开关的乐观值：请求在路上时开关先拨过去，失败再拨回
  const [statsDraft, setStatsDraft] = useState<boolean | null>(null);
  // 刚点了关闭的服务通知先藏起来，不等响应
  const [dismissed, setDismissed] = useState<ReadonlySet<string>>(new Set());

  const connection = status.connection;
  const manageUrl = cloudInstancesUrl(status.cloud_url);
  const tone = healthTone(status.health);
  const reportStats = statsDraft ?? status.report_stats;
  const notices = status.notices.filter((n) => !dismissed.has(n.id));

  const renew = async () => {
    setBusy("renew");
    try {
      const next = await run(renewCloud);
      // 同步时发现已在官网解绑：页面自己切到未连接并说明原因，不再弹回执
      if (next.state !== "connected") return;
      if (next.health === "ok") toast.success(t("settings.cloudConnect.synced"));
      else toast.error(healthMessage(next.health, next.health_message, locale) || t("settings.cloudConnect.syncFailed"));
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const dismiss = async (noticeId: string) => {
    setDismissed((prev) => new Set(prev).add(noticeId));
    try {
      await run(() => dismissCloudNotice(noticeId));
    } catch (e) {
      setDismissed((prev) => {
        const next = new Set(prev);
        next.delete(noticeId);
        return next;
      });
      toast.error((e as Error).message);
    }
  };

  const toggleStats = async (next: boolean) => {
    setStatsDraft(next);
    try {
      await run(() => updateCloudSettings(next));
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setStatsDraft(null);
    }
  };

  const disconnect = async () => {
    const ok = await confirm({
      title: t("settings.cloudConnect.disconnectTitle"),
      description:
        t("settings.cloudConnect.disconnectHint"),
      confirmLabel: t("settings.cloudConnect.disconnect"),
      tone: "danger",
    });
    if (!ok) return;
    setBusy("disconnect");
    try {
      await run(() => disconnectCloud());
      toast.success(t("settings.cloudConnect.disconnected"));
    } catch (e) {
      if (!isCloudUnreachable(e)) {
        toast.error((e as Error).message);
        return;
      }
      // 云端连不上：只能删本地凭证，官网上还会挂着这台服务器，要管理员自己去删
      const force = await confirm({
        title: t("settings.cloudConnect.forceTitle"),
        description:
          t("settings.cloudConnect.forceHint"),
        confirmLabel: t("settings.cloudConnect.forceDisconnect"),
        tone: "danger",
      });
      if (!force) return;
      try {
        await run(() => disconnectCloud(true));
        toast.info(t("settings.cloudConnect.forceReceipt"), {
          action: {
            label: t("settings.cloudConnect.openWebsite"),
            onClick: () => window.open(manageUrl, "_blank", "noopener,noreferrer"),
          },
        });
      } catch (e2) {
        toast.error((e2 as Error).message);
      }
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="space-y-10">
      {(tone || notices.length > 0) && (
        <div className="space-y-4">
          {tone && (
            <Banner
              tone={tone}
              action={
                <button
                  type="button"
                  disabled={busy != null}
                  onClick={() => void renew()}
                  className={SETTINGS_BUTTON_CLASS}
                >
                  {busy === "renew" ? t("settings.cloudConnect.syncing") : t("settings.cloudConnect.syncNow")}
                </button>
              }
            >
              {healthMessage(status.health, status.health_message, locale)}
            </Banner>
          )}

          {notices.map((notice) => (
            <Banner
              key={notice.id}
              tone={noticeTone(notice.level)}
              title={t("settings.cloudConnect.noticeTitle")}
              onDismiss={() => void dismiss(notice.id)}
              dismissLabel={t("settings.cloudConnect.dismissNotice")}
            >
              {notice.message}
            </Banner>
          ))}
        </div>
      )}

      <SummaryCard status={status} connection={connection} manageUrl={manageUrl} />

      <SettingsSection
        title={t("settings.cloudConnect.reporting")}
        footnote={
          <a
            href={cloudReportsInfoUrl(status.cloud_url, locale)}
            target="_blank"
            rel="noopener noreferrer"
            className={LINK_CLASS}
          >
            {t("settings.cloudConnect.connectedReportsLink")}</a>
        }
      >
        <SettingsList>
          <SettingsRow
            label={t("settings.cloudConnect.reportStats")}
            description={t("settings.cloudConnect.reportStatsHint")}
          >
            <Toggle
              checked={reportStats}
              label={t("settings.cloudConnect.reportStats")}
              disabled={statsDraft != null}
              onChange={(next) => void toggleStats(next)}
            />
          </SettingsRow>
        </SettingsList>
      </SettingsSection>

      <SettingsSection title={t("settings.cloudConnect.danger")}>
        <SettingsCard
          tone="danger"
          title={t("settings.cloudConnect.disconnectAction")}
          description={t("settings.cloudConnect.disconnectShortHint")}
          action={
            <button
              type="button"
              disabled={busy != null}
              onClick={() => void disconnect()}
              className={SETTINGS_DANGER_BUTTON_CLASS}
            >
              {busy === "disconnect" ? t("settings.cloudConnect.disconnecting") : t("settings.cloudConnect.disconnect")}
            </button>
          }
        />
      </SettingsSection>
    </div>
  );
}

/** 连接概要：连在谁的账号下、什么时候连的，以及权限与能力清单。 */
function SummaryCard({
  status,
  connection,
  manageUrl,
}: {
  status: CloudStatusView;
  connection: CloudConnectionView | null;
  manageUrl: string;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const rows = capabilityRows(connection?.scopes ?? [], connection?.capabilities ?? [], locale);
  const dailyLimit = connection?.limits?.day;
  const timeline = connection?.connected_at
    ? t("settings.cloudConnect.connectedAt", { time: formatDateTime(connection.connected_at, locale) })
    : null;

  return (
    <>
      <SettingsSection title={t("settings.cloudConnect.account")}>
        <SettingsList>
          <SettingsRow
            stackOnMobile={locale === "en"}
            leading={
              <span className="icon-chip size-10 !rounded-xl">
                <CloudIcon className="size-5" />
              </span>
            }
            label={
              <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
                <span className="min-w-0 truncate">
                  {connection?.instance_name || status.server_name}
                </span>
                <StatusPill tone="ok" label={t("settings.cloudConnect.connected")} />
              </span>
            }
            description={
              <>
                {connectedAccountLine(connection?.account_display, locale)}
                {timeline && <span className="block">{timeline}</span>}
              </>
            }
          >
            <a
              href={manageUrl}
              target="_blank"
              rel="noopener noreferrer"
              className={`${SETTINGS_BUTTON_CLASS} inline-flex items-center`}
            >
              {t("settings.cloudConnect.manageWebsite")}</a>
          </SettingsRow>
        </SettingsList>
      </SettingsSection>

      <SettingsSection title={t("settings.cloudConnect.capabilities")}>
        <SettingsList>
          {rows.map((row) => (
            <SettingsRow
              key={row.id}
              stackOnMobile={locale === "en"}
              label={
                <span className={row.granted ? undefined : "text-[var(--text-muted)]"}>
                  {row.label}
                </span>
              }
              description={
                row.id === "push"
                  ? row.granted
                    ? t("settings.cloudConnect.pushHint", { quota: dailyLimit != null && dailyLimit > 0 ? t("settings.cloudConnect.dailyQuota", { count: dailyLimit }) : "" })
                    : t("settings.cloudConnect.pushDenied")
                  : row.granted
                    ? t("settings.cloudConnect.grantedHint")
                    : t("settings.cloudConnect.upcomingHint")
              }
            >
              <StatusPill
                tone={row.granted ? "ok" : "neutral"}
                label={row.granted ? t("settings.cloudConnect.granted") : row.id === "push" ? t("settings.cloudConnect.notGranted") : t("settings.cloudConnect.comingSoon")}
              />
              {row.id === "push" && (
                <Link href="/settings/app-push" className={`text-sub ${LINK_CLASS}`}>
                  {t("settings.cloudConnect.appPushSettings")}
                </Link>
              )}
            </SettingsRow>
          ))}
        </SettingsList>
      </SettingsSection>
    </>
  );
}
