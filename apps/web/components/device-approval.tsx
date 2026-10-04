"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import type { Route } from "next";

import { CheckIcon, DeviceIcon, InfoIcon, XIcon } from "@/components/icons";
import {
  WelcomeCard,
  WelcomeError,
  WelcomeField,
  WelcomeFields,
  WelcomeSubmit,
} from "@/components/welcome-screen";
import {
  type DeviceRequestView,
  approveDeviceRequest,
  denyDeviceRequest,
  getDeviceRequest,
} from "@/lib/api/devices";
import { type ViewerRole, clientTypeLabel, grantSummary, normalizePairingCode } from "@/lib/devices-display";
import { accessiblePathFor } from "@/lib/permissions";
import { useSession } from "@/lib/session";

/**
 * 批准设备登录（/activate，docs/design/login-devices.md §4、device-auth.md）。
 *
 * 为什么是独立页面而不是「设置 → 设备」里的一块：批准是一件一次性的事——人手里拿着
 * 电视 / 终端上的一段配对码，来这里输入、核对、批准，然后回到那台设备上。它和「管理
 * 已登录的设备」是两件事，混在设备列表上方，人既不知道该去设备页找它，到了也分不清
 * 列表里哪些是要处理的。Netflix（netflix.com/tv8）、YouTube（youtube.com/activate）
 * 也都是这样一个只有输入框的独立页面。
 *
 * 防钓鱼：页面**只按配对码查一条**请求，服务端也不提供「列出全部待批准请求」的接口。
 * 发起配对是匿名的，谁都能起一个叫「客厅 Apple TV」的请求；要求输入设备屏幕上的码，
 * 等于证明「那台设备就在我面前」。审批卡上配对码用大号等宽字，就是为了让人真的逐个比对。
 *
 * 设备发起配对后打开的链接带 `?code=`（服务端的 verification_uri_complete），挂载时
 * 读出直接查询；处理完从地址栏抹掉 code——否则一刷新又去查那条已处理的请求。
 */
export function DeviceApproval() {
  const { session } = useSession();
  const [draft, setDraft] = useState("");
  const [lookupError, setLookupError] = useState<string | null>(null);
  const [looking, setLooking] = useState(false);
  const [request, setRequest] = useState<DeviceRequestView | null>(null);
  const [deciding, setDeciding] = useState(false);
  const [decideError, setDecideError] = useState<string | null>(null);
  // 处理完的结果页：告诉人下一步去哪（回到设备上），而不是一闪而过的提示
  const [outcome, setOutcome] = useState<{ approved: boolean; name: string } | null>(null);

  const lookup = useCallback(async (raw: string) => {
    const code = normalizePairingCode(raw);
    if (!code) {
      setLookupError("配对码形如 MCLW-7F3K，请对照设备上显示的重新输入。");
      return;
    }
    setDraft(code);
    setLooking(true);
    setLookupError(null);
    try {
      setRequest(await getDeviceRequest(code));
      setDecideError(null);
    } catch (e) {
      // 服务端的话就是能行动的中文：「不存在或已过期，请让设备重新发起」
      setLookupError((e as Error).message);
    } finally {
      setLooking(false);
    }
  }, []);

  // 读取放在 effect 而非 state 初值：服务端渲染阶段没有 window。先回填输入框：
  // 链接里的码格式不对时，人得看得到它才能对照着改
  useEffect(() => {
    const code = new URLSearchParams(window.location.search).get("code");
    if (!code) return;
    setDraft(code);
    void lookup(code);
  }, [lookup]);

  const startOver = () => {
    setRequest(null);
    setOutcome(null);
    setDraft("");
    setDecideError(null);
    clearCodeParam();
  };

  const decide = async (approve: boolean) => {
    if (!request) return;
    setDeciding(true);
    setDecideError(null);
    try {
      if (approve) await approveDeviceRequest(request.user_code);
      else await denyDeviceRequest(request.user_code);
      clearCodeParam();
      setOutcome({ approved: approve, name: request.client_name });
      setRequest(null);
    } catch (e) {
      setDecideError((e as Error).message);
    } finally {
      setDeciding(false);
    }
  };

  if (outcome) {
    return (
      <WelcomeCard
        title={outcome.approved ? "已批准" : "已拒绝"}
        subtitle={
          outcome.approved
            ? `「${outcome.name}」会在几秒内自动登录，回到那台设备上继续就好。`
            : "这台设备不会登录。如果它其实是你的，让它重新发起配对即可。"
        }
      >
        <div className="space-y-2.5">
          <Link
            href={accessiblePathFor(session, "/") as Route}
            className="flex h-[50px] w-full items-center justify-center rounded-full bg-[var(--accent-strong)] text-[17px] font-semibold text-black/85 transition active:scale-[0.98]"
          >
            进入 MovieClaw
          </Link>
          <button type="button" onClick={startOver} className={SECONDARY_BUTTON}>
            批准另一台设备
          </button>
        </div>
      </WelcomeCard>
    );
  }

  if (request) {
    return (
      <WelcomeCard title="批准这台设备登录？" subtitle="先核对配对码与设备屏幕上显示的完全一致。">
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            void decide(true);
          }}
        >
          <RequestDetails request={request} role={session.role} />
          <WelcomeError message={decideError} />
          <div className="space-y-2.5">
            {!(request.requires_admin && session.role !== "admin") && (
              <WelcomeSubmit busy={deciding} disabled={deciding}>
                <CheckIcon className="size-[18px]" />
                批准登录
              </WelcomeSubmit>
            )}
            <button
              type="button"
              disabled={deciding}
              onClick={() => void decide(false)}
              className={`${SECONDARY_BUTTON} text-[var(--danger)]`}
            >
              <XIcon className="size-4" />
              不是我发起的，拒绝
            </button>
            <button
              type="button"
              disabled={deciding}
              onClick={startOver}
              className="w-full py-1.5 text-sub text-[var(--text-faint)] transition-colors hover:text-[var(--text-muted)] disabled:opacity-40"
            >
              暂不处理，换一个配对码
            </button>
          </div>
          <AccountLine />
        </form>
      </WelcomeCard>
    );
  }

  return (
    <WelcomeCard
      title="批准设备登录"
      subtitle="输入 Apple TV、Mac、命令行（mclaw login）或转码器上显示的配对码。"
    >
      <form
        className="space-y-4"
        onSubmit={(e) => {
          e.preventDefault();
          void lookup(draft);
        }}
      >
        <WelcomeFields>
          <WelcomeField
            icon={<DeviceIcon className="size-[18px]" />}
            aria-label="配对码"
            placeholder="MCLW-XXXX"
            value={draft}
            onChange={(e) => {
              setDraft(e.target.value);
              if (lookupError) setLookupError(null);
            }}
            maxLength={16}
            autoComplete="off"
            autoCapitalize="characters"
            autoCorrect="off"
            spellCheck={false}
            enterKeyHint="go"
          />
        </WelcomeFields>
        <WelcomeError message={lookupError} />
        <WelcomeSubmit busy={looking} disabled={looking || !draft.trim()}>
          {looking ? "查询中…" : "继续"}
        </WelcomeSubmit>
        <AccountLine />
      </form>
    </WelcomeCard>
  );
}

const SECONDARY_BUTTON =
  "flex h-[50px] w-full items-center justify-center gap-1.5 rounded-full border border-white/[0.08] bg-white/[0.05] text-[16px] font-medium text-[var(--text)] transition active:scale-[0.98] disabled:opacity-40";

/** 从地址栏抹掉 ?code=：replaceState 不触发 Next 重渲染、也不留历史记录（同 useTabParam）。 */
function clearCodeParam() {
  const url = new URL(window.location.href);
  if (!url.searchParams.has("code")) return;
  url.searchParams.delete("code");
  window.history.replaceState(window.history.state, "", url);
}

/**
 * 「以谁的身份批准」：独立页面没有侧栏与头像，而批准的后果是「谁批准，设备就登录成谁」，
 * 所以必须把当前账号写出来，并给一条换账号的路（浏览器里登录着多个账号时尤其要紧）。
 * 换账号走登录页的「添加账号」，登录后带着配对码回到这里。
 */
function AccountLine() {
  const { session } = useSession();
  return (
    <p className="text-center text-caption leading-relaxed text-[var(--text-faint)]">
      将以「{session.nickname || session.username}」的身份批准 ·{" "}
      <a
        href="/login?add=1"
        onClick={(e) => {
          // 带上当前地址（含配对码）：登录后回到这里继续批准
          e.preventDefault();
          const next = encodeURIComponent(window.location.pathname + window.location.search);
          window.location.href = `/login?add=1&next=${next}`;
        }}
        className="text-[var(--text-muted)] underline-offset-2 hover:text-[var(--text)] hover:underline"
      >
        换个账号
      </a>
    </p>
  );
}

/**
 * 审批依据：用户做决定的全部信息都在这一块。
 *
 * 配对码用大号等宽字并加字距——它要被拿去和设备屏幕上的字符逐个比对，
 * 这是防钓鱼的实际动作，字号小了就没人会真的比。
 */
function RequestDetails({ request, role }: { request: DeviceRequestView; role: ViewerRole }) {
  const grant = grantSummary(request.client_type, role);
  // 转码器只能由超管批准（转码占用的是整台服务器的资源）：成员看到时说清原因、
  // 不给批准按钮，而不是让他按下去再吃一个 403
  const blocked = request.requires_admin && role !== "admin";
  return (
    <div className="space-y-3">
      <div className="rounded-2xl border border-white/[0.08] bg-white/[0.05] px-4 py-3.5">
        <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
          <p className="min-w-0 break-all text-body font-semibold text-[var(--text)]">{request.client_name}</p>
          <span className="font-mono text-[22px] font-semibold tracking-[0.16em] text-[var(--accent)]">
            {request.user_code}
          </span>
        </div>
        <dl className="mt-2.5 grid grid-cols-[auto_1fr] gap-x-5 gap-y-1.5 text-sub">
          <dt className="text-[var(--text-faint)]">类型</dt>
          <dd className="text-[var(--text-muted)]">{clientTypeLabel(request.client_type)}</dd>
          {request.platform && (
            <>
              <dt className="text-[var(--text-faint)]">系统</dt>
              <dd className="text-[var(--text-muted)]">{request.platform}</dd>
            </>
          )}
          {request.client_version && (
            <>
              <dt className="text-[var(--text-faint)]">版本</dt>
              <dd className="text-[var(--text-muted)]">{request.client_version}</dd>
            </>
          )}
          <dt className="text-[var(--text-faint)]">来源</dt>
          {request.source_ip ? (
            <dd className="font-mono text-[var(--text-muted)]">{request.source_ip}</dd>
          ) : (
            /* 服务端判定这个地址认不出设备时会返回空串（api/client_address.py）：
               桥接网络的容器看到的源地址是网桥网关，全网设备长得一模一样。
               与其摆一个「172.17.0.1」让人以为那是对方的地址，不如直说看不到，
               并把判断依据推回配对码——那本来就是这张卡真正的安全控制。 */
            <dd className="text-[var(--text-faint)]">
              无法确定
              <span className="ml-1.5 text-caption">容器网络改写了源地址，请以配对码为准</span>
            </dd>
          )}
        </dl>
      </div>

      {blocked ? (
        <div className="flex gap-2.5 rounded-2xl border border-[var(--warn)]/28 bg-[var(--warn)]/[0.09] px-3.5 py-3">
          <InfoIcon className="mt-0.5 size-4 shrink-0 text-[var(--warn)]" />
          <p className="text-sub leading-relaxed text-[var(--text-muted)]">
            转码器只能由管理员批准——转码占用的是整台服务器的资源。请把这个配对码告诉管理员，让他在自己的网页或 App 上输入并批准。
          </p>
        </div>
      ) : (
        <div className="rounded-2xl border border-[var(--accent)]/20 bg-[var(--accent-soft)] px-4 py-3">
          <p className="text-sub font-semibold text-[var(--accent)]">{grant.title}</p>
          <p className="mt-1 text-sub leading-relaxed text-[var(--text-muted)]">{grant.body}</p>
        </div>
      )}
    </div>
  );
}
