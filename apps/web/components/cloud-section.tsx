"use client";

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
    getCloudStatus().then(
      (next) => {
        if (epoch === epochRef.current && writingRef.current === 0) setStatus(next);
      },
      (e: Error) => {
        // 轮询失败静默，保留上一份状态；只有首次加载失败才要报错
        if (reportError) setLoadError(e.message);
      },
    );
  }, []);

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
          重试
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
            开发者设置：这台服务器连的是{" "}
            <span className="break-words font-mono text-[var(--text-muted)]">{status.cloud_url}</span>
            （环境变量 MOVIECLAW_CLOUD_URL）
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
  const lastDisconnect = status.last_disconnect;

  return (
    <div className="space-y-5">
      {/* 被动断开（在官网解绑、账号删除）：平静地说明，不用警告色——这是结果，不是故障 */}
      {lastDisconnect && (
        <Banner tone="neutral" title="这台服务器已和 MovieClaw 账号断开">
          {lastDisconnect.message?.trim() || "在 MovieClaw 官网上断开了连接，需要的话可以重新连接。"}
          {lastDisconnect.at && (
            <span className="text-[var(--text-faint)]"> · {formatRelativeTime(lastDisconnect.at)}</span>
          )}
        </Banner>
      )}

      <div className="css-glass flex items-start gap-4 !rounded-2xl p-6 max-sm:flex-col max-sm:p-5">
        <span className="icon-chip size-12 !rounded-2xl">
          <CloudIcon className="size-[22px]" />
        </span>
        <div className="min-w-0 flex-1">
          <p className="text-body-lg font-semibold text-[var(--text)]">还没有连接</p>
          <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
            连接后，家人手机上的 MovieClaw App 就能收到通知。连接需要一个 MovieClaw 账号（Apple、Google
            或邮箱都行），只有你（管理员）需要，家人不用。
          </p>
          <div className="mt-4 flex flex-wrap gap-2.5">
            <button
              type="button"
              onClick={onConnect}
              className="btn-accent rounded-full px-4 py-2 text-ui font-semibold"
            >
              连接到 MovieClaw 账号
            </button>
            <a
              href={cloudReportsInfoUrl(status.cloud_url)}
              target="_blank"
              rel="noopener noreferrer"
              className="btn-glass px-4 py-2 text-ui font-medium"
            >
              会向 MovieClaw Cloud 上报哪些信息？
            </a>
          </div>
        </div>
      </div>

      {/* 给不连接的人留出口 */}
      <Banner tone="info">
        只想用微信、Telegram 收通知？不用连接，去{" "}
        <Link href="/settings/im-push" className={LINK_CLASS}>
          IM 推送
        </Link>
        。自己打包了 App？去{" "}
        <Link href="/settings/app-push" className={LINK_CLASS}>
          App 推送
        </Link>{" "}
        添加自建中继。
      </Banner>
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
  const pending = pairing == null || pairing.status === "pending";
  return (
    <div className="css-glass flex items-center gap-4 !rounded-2xl p-5 max-sm:flex-col max-sm:items-start">
      <span className="icon-chip size-11 !rounded-2xl">
        <CloudIcon className="size-5" />
      </span>
      <div className="min-w-0 flex-1">
        <p className="flex items-center gap-2 text-body font-semibold text-[var(--text)]">
          {pending && <Spinner />}
          {pending ? "正在等待在官网批准" : "这次连接没有完成"}
        </p>
        <p className="mt-0.5 text-sub leading-6 text-[var(--text-muted)]">
          {pairing == null ? (
            "正在申请配对码…"
          ) : pending ? (
            <>
              配对码 <span className="font-mono text-[var(--text)]">{pairing.user_code}</span>
              ，在官网批准后这里会自动变成已连接。
            </>
          ) : (
            pairingFailureText(pairing.status, pairing.message)
          )}
        </p>
      </div>
      <button
        type="button"
        onClick={onOpen}
        className="btn-accent shrink-0 rounded-full px-4 py-1.5 text-sub font-semibold"
      >
        {pending ? "查看配对码" : "重新连接"}
      </button>
    </div>
  );
}

/* —— 已连接 —— */

function ConnectedView({ status, run }: { status: CloudStatusView; run: Run }) {
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
      if (next.health === "ok") toast.success("已和 MovieClaw Cloud 同步");
      else toast.error(healthMessage(next.health, next.health_message) || "同步没有成功");
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
      title: "断开与 MovieClaw 账号的连接？",
      description:
        "家人手机上的官方推送会立即停止；自建中继和 IM 推送不受影响。以后可以随时重新连接。",
      confirmLabel: "断开",
      tone: "danger",
    });
    if (!ok) return;
    setBusy("disconnect");
    try {
      await run(() => disconnectCloud());
      toast.success("已断开连接");
    } catch (e) {
      if (!isCloudUnreachable(e)) {
        toast.error((e as Error).message);
        return;
      }
      // 云端连不上：只能删本地凭证，官网上还会挂着这台服务器，要管理员自己去删
      const force = await confirm({
        title: "云端暂时连不上，仍要断开吗？",
        description:
          "这台服务器会删掉自己的凭证、不再使用官方推送，但 MovieClaw 官网上还会列着它。断开后请到官网把这台服务器也删掉。",
        confirmLabel: "仍要断开",
        tone: "danger",
      });
      if (!force) return;
      try {
        await run(() => disconnectCloud(true));
        toast.info("已断开。记得到 MovieClaw 官网把这台服务器也删掉", {
          action: {
            label: "打开官网",
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
    <div className="space-y-6">
      {tone && (
        <Banner
          tone={tone}
          action={
            <button
              type="button"
              disabled={busy != null}
              onClick={() => void renew()}
              className="btn-glass px-3 py-1.5 text-sub font-medium disabled:opacity-40"
            >
              {busy === "renew" ? "同步中…" : "立即同步"}
            </button>
          }
        >
          {healthMessage(status.health, status.health_message)}
        </Banner>
      )}

      {notices.map((notice) => (
        <Banner
          key={notice.id}
          tone={noticeTone(notice.level)}
          title="来自 MovieClaw 的通知"
          onDismiss={() => void dismiss(notice.id)}
          dismissLabel="关闭这条通知"
        >
          {notice.message}
        </Banner>
      ))}

      <SummaryCard status={status} connection={connection} manageUrl={manageUrl} />

      <section>
        <h3 className="group-label mb-2.5 px-1">上报</h3>
        <div className="css-glass !rounded-2xl">
          <div className="flex items-center gap-3.5 px-5 py-4 max-sm:px-4">
            <div className="min-w-0 flex-1">
              <p className="text-body font-medium text-[var(--text)]">上报统计信息</p>
              <p className="mt-0.5 text-caption leading-5 text-[var(--text-faint)]">
                按平台和 App 版本汇总的设备数、官方推送能不能连通。关掉后只上报版本信息，推送不受影响，只是官网上少一些展示
              </p>
            </div>
            <Toggle
              checked={reportStats}
              label="上报统计信息"
              disabled={statsDraft != null}
              onChange={(next) => void toggleStats(next)}
            />
          </div>
          <div className="border-t border-white/[0.06] px-5 py-3.5 max-sm:px-4">
            <a
              href={cloudReportsInfoUrl(status.cloud_url)}
              target="_blank"
              rel="noopener noreferrer"
              className={`text-sub ${LINK_CLASS}`}
            >
              连接后会向 MovieClaw Cloud 上报哪些信息？
            </a>
          </div>
        </div>
      </section>

      <div className="css-glass flex items-center gap-3.5 !rounded-2xl px-5 py-4 max-sm:px-4">
        <div className="min-w-0 flex-1">
          <p className="text-body font-medium text-[var(--text)]">断开连接</p>
          <p className="mt-0.5 text-caption leading-5 text-[var(--text-faint)]">
            家人手机上的官方推送会立即停止。自建中继不受影响
          </p>
        </div>
        <button
          type="button"
          disabled={busy != null}
          onClick={() => void disconnect()}
          className="btn-glass shrink-0 px-3.5 py-1.5 text-sub font-medium !text-[var(--danger)] disabled:opacity-40"
        >
          {busy === "disconnect" ? "断开中…" : "断开"}
        </button>
      </div>
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
  const rows = capabilityRows(connection?.scopes ?? [], connection?.capabilities ?? []);
  const dailyLimit = connection?.limits?.day;
  const timeline = connection?.connected_at
    ? `连接于 ${formatDateTime(connection.connected_at)}`
    : null;

  return (
    <div className="css-glass !rounded-2xl">
      <div className="flex flex-wrap items-start gap-x-3.5 gap-y-3 px-5 py-4 max-sm:px-4">
        <span className="icon-chip size-11 !rounded-2xl">
          <CloudIcon className="size-5" />
        </span>
        {/* 窄屏上文字列占满图标右侧（图标 44px + 间距 14px，再留一点余量），「在官网管理」换到下一行 */}
        <div className="min-w-0 flex-1 max-sm:basis-[calc(100%-64px)]">
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <p className="min-w-0 truncate text-body-lg font-semibold text-[var(--text)]">
              {connection?.instance_name || status.server_name}
            </p>
            <StatusPill tone="ok" label="已连接" />
          </div>
          <p className="mt-1 text-sub text-[var(--text-muted)]">
            {connectedAccountLine(connection?.account_display)}
          </p>
          {timeline && <p className="mt-0.5 text-caption text-[var(--text-faint)]">{timeline}</p>}
        </div>
        <a
          href={manageUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="btn-glass shrink-0 px-3 py-1.5 text-sub font-medium max-sm:ml-[58px]"
        >
          在官网管理 ↗
        </a>
      </div>

      {rows.map((row) => (
        <div
          key={row.id}
          className="flex flex-wrap items-center gap-x-3.5 gap-y-2 border-t border-white/[0.06] px-5 py-4 max-sm:px-4"
        >
          <div className="min-w-0 flex-1 basis-48">
            <p
              className={`text-body font-medium ${
                row.granted ? "text-[var(--text)]" : "text-[var(--text-muted)]"
              }`}
            >
              {row.label}
            </p>
            <p className="mt-0.5 text-caption leading-5 text-[var(--text-faint)]">
              {row.id === "push"
                ? row.granted
                  ? `给登录了这台服务器的手机发通知${dailyLimit != null && dailyLimit > 0 ? ` · 每天最多 ${dailyLimit} 条` : ""}`
                  : "这台服务器没有使用官方推送的权限"
                : row.granted
                  ? "已授予这台服务器"
                  : "即将推出。推出后在这里单独开启，不用重新连接"}
            </p>
          </div>
          <div className="flex shrink-0 items-center gap-3">
            <StatusPill
              tone={row.granted ? "ok" : "neutral"}
              label={row.granted ? "已授予" : row.id === "push" ? "未授予" : "即将推出"}
            />
            {row.id === "push" && (
              <Link href="/settings/app-push" className={`text-sub ${LINK_CLASS}`}>
                App 推送设置
              </Link>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}
