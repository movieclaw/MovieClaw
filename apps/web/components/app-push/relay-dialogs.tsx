"use client";

/**
 * 自建中继的添加与编辑弹窗（docs/design/cloud-push.md §3、§7.2；交互稿 3.2）。
 *
 * 添加是「先检测、再填表」：实例读中继的 /v1/info，按它声明的鉴权方式决定后面的
 * 表单——static（和不认识的方式）要填令牌，none 不用，issuer 要签发方的令牌，这里加不了。检测之后
 * 地址又改过，结果作废，要重新检测（规则在 lib/cloud-push-display 的 relayAddBlocker）。
 * 安全提示（http 走公网、无鉴权在公网）由服务端放进 warnings，只提示不拦。
 */

import { useId, useState, type ReactNode } from "react";

import { Banner, ErrorBanner, INPUT_CLASS, LINK_CLASS } from "@/components/cloud-push-ui";
import { CheckIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import {
  type PushChannelView,
  type PushChannelsView,
  type RelayProbeView,
  addRelay,
  probeRelay,
  updateRelay,
} from "@/lib/api/push";
import {
  authModeLabel,
  relayAddBlocker,
  relayNameFromUrl,
  relayNeedsToken,
} from "@/lib/cloud-push-display";

/** 公开仓库里的部署说明 */
export const RELAY_DEPLOY_URL = "https://github.com/movieclaw/MovieClaw-Push";

const RELAY_NAME_MAX_LENGTH = 64;

export function AddRelayDialog({
  onClose,
  onAdded,
}: {
  onClose: () => void;
  onAdded: (view: PushChannelsView, name: string) => void;
}) {
  const urlId = useId();
  const [url, setUrl] = useState("");
  const [probe, setProbe] = useState<RelayProbeView | null>(null);
  // 检测时用的地址：之后输入框再改，检测结果就不算数了
  const [probedUrl, setProbedUrl] = useState("");
  const [token, setToken] = useState("");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState<"probe" | "save" | null>(null);
  const [error, setError] = useState<string | null>(null);

  const stale = probe != null && probedUrl !== url.trim();
  const current = stale ? null : probe;
  const blocker = relayAddBlocker({ probe, probedUrl, url, token, name });

  const runProbe = async () => {
    const target = url.trim();
    if (!target || busy) return;
    setBusy("probe");
    setError(null);
    try {
      const result = await probeRelay(target);
      setProbe(result);
      setProbedUrl(target);
      if (result.reachable && !name.trim()) setName(relayNameFromUrl(target));
    } catch (e) {
      setProbe(null);
      setError((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const save = async () => {
    if (blocker || busy) return;
    const trimmedName = name.trim();
    setBusy("save");
    setError(null);
    try {
      const view = await addRelay({
        name: trimmedName,
        url: probedUrl,
        ...(relayNeedsToken(current?.auth_mode) ? { token: token.trim() } : {}),
      });
      onAdded(view, trimmedName);
    } catch (e) {
      setError((e as Error).message);
      setBusy(null);
    }
  };

  return (
    <Modal open onClose={onClose} label="添加自建中继" width="lg">
      <div className="space-y-4 p-6 max-md:p-5">
        <div>
          <h2 className="text-title font-bold text-white">添加自建中继</h2>
          <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
            先填地址并检测：MovieClaw 会读取中继的 /v1/info，按它声明的鉴权方式决定要不要填令牌。
          </p>
        </div>

        {error && <ErrorBanner>{error}</ErrorBanner>}

        <div>
          <label htmlFor={urlId} className="mb-1.5 block text-caption text-[var(--text-muted)]">
            中继地址
          </label>
          <div className="flex gap-2">
            <input
              id={urlId}
              type="text"
              inputMode="url"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  void runProbe();
                }
              }}
              placeholder="https://push.example.com"
              autoFocus
              autoComplete="off"
              spellCheck={false}
              className={`${INPUT_CLASS} font-mono`}
            />
            <button
              type="button"
              disabled={busy != null || !url.trim()}
              onClick={() => void runProbe()}
              className="btn-glass shrink-0 px-4 py-1.5 text-sub font-medium disabled:opacity-40"
            >
              {busy === "probe" ? "检测中…" : "检测"}
            </button>
          </div>
          {stale && (
            <p className="mt-1.5 text-caption text-[var(--text-faint)]">地址改过了，重新检测一下。</p>
          )}
        </div>

        {current && <ProbeResult probe={current} />}

        {/* 连上了但加不了时，原因已经写在检测结果里，不再出表单 */}
        {current?.reachable &&
          !current.error?.trim() &&
          (current.auth_mode === "issuer" ? (
            <Banner tone="warn">这个中继需要签发方的令牌，暂不支持在这里添加。</Banner>
          ) : (
            <>
              {relayNeedsToken(current.auth_mode) && (
                <Field label="令牌" hint="在中继上运行 movieclaw-push token create 生成">
                  {(id) => (
                    <input
                      id={id}
                      type="text"
                      value={token}
                      onChange={(e) => setToken(e.target.value)}
                      placeholder="mcpush_…"
                      autoComplete="off"
                      spellCheck={false}
                      className={`${INPUT_CLASS} font-mono`}
                    />
                  )}
                </Field>
              )}
              <Field label="名称">
                {(id) => (
                  <input
                    id={id}
                    type="text"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    maxLength={RELAY_NAME_MAX_LENGTH}
                    placeholder="如 书房中继"
                    className={INPUT_CLASS}
                  />
                )}
              </Field>
            </>
          ))}

        <p className="text-caption leading-5 text-[var(--text-faint)]">
          给自己打包的 App 用；能推哪些 App 由中继上的推送证书决定。
          <a href={RELAY_DEPLOY_URL} target="_blank" rel="noopener noreferrer" className={LINK_CLASS}>
            怎么部署 ↗
          </a>
        </p>

        <div className="flex justify-end gap-2">
          <button type="button" onClick={onClose} className="btn-glass px-4 py-1.5 text-sub font-medium">
            取消
          </button>
          <button
            type="button"
            disabled={blocker != null || busy != null}
            title={blocker ?? undefined}
            onClick={() => void save()}
            className="btn-accent rounded-full px-4 py-1.5 text-sub font-semibold disabled:opacity-40"
          >
            {busy === "save" ? "保存中…" : "保存"}
          </button>
        </div>
      </div>
    </Modal>
  );
}

/**
 * 检测结果卡：连上了列出中继声明的东西；连不上给原因。连上了但加不了
 * （协议不兼容、要签发方的令牌）同样列出声明，并把原因写在头上。
 */
function ProbeResult({ probe }: { probe: RelayProbeView }) {
  if (!probe.reachable) {
    return (
      <div className="rounded-xl border border-[var(--danger)]/30 bg-[var(--danger)]/[0.08] px-4 py-3">
        <p className="text-body font-medium text-[var(--danger)]">连不上这个中继</p>
        {probe.error && (
          <p className="mt-0.5 text-sub leading-6 text-[var(--text-muted)]">{probe.error}</p>
        )}
      </div>
    );
  }
  const blocked = probe.error?.trim();
  const auth = authModeLabel(probe.auth_mode);
  return (
    <div
      className={`rounded-xl border px-4 py-3.5 ${
        blocked
          ? "border-[var(--danger)]/30 bg-[var(--danger)]/[0.08]"
          : "border-[var(--ok)]/25 bg-[var(--ok)]/[0.06]"
      }`}
    >
      {blocked ? (
        <>
          <p className="text-sub font-medium text-[var(--danger)]">连上了，但不能在这里添加</p>
          <p className="mt-0.5 text-sub leading-6 text-[var(--text-muted)]">{blocked}</p>
        </>
      ) : (
        <p className="flex items-center gap-1.5 text-sub font-medium text-[var(--ok)]">
          <CheckIcon className="size-4" />
          连上了
        </p>
      )}
      <dl className="mt-2.5 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5 text-sub">
        <dt className="text-[var(--text-faint)]">软件</dt>
        <dd className="break-words font-mono text-[var(--text-muted)]">
          {probe.software ?? "未声明"}
          {probe.protocol != null && `\u00a0· 协议\u00a0v${probe.protocol}`}
        </dd>
        <dt className="text-[var(--text-faint)]">鉴权方式</dt>
        <dd className="text-[var(--text-muted)]">
          {auth ? `${auth}（${probe.auth_mode}）` : "未声明"}
        </dd>
        <dt className="text-[var(--text-faint)]">能推送的 App</dt>
        <dd className="break-words font-mono text-[var(--text-muted)]">
          {probe.topics.length > 0 ? probe.topics.join(", ") : "未声明"}
        </dd>
        <dt className="text-[var(--text-faint)]">覆盖的设备</dt>
        {/* 没有本地设备匹配也允许保存（可能还没装 App），只用黄字提醒；
            原因服务端已经写进 warnings，这里不重复 */}
        <dd className={probe.matched_devices > 0 ? "text-[var(--text-muted)]" : "text-[var(--warn)]"}>
          {probe.matched_devices} 台
        </dd>
      </dl>
      {probe.warnings.length > 0 && (
        <ul className="mt-3 space-y-1">
          {probe.warnings.map((warning) => (
            <li key={warning} className="flex items-start gap-2 text-caption leading-5 text-[var(--warn)]">
              <span aria-hidden className="mt-[7px] size-1.5 shrink-0 rounded-full bg-[var(--warn)]" />
              {warning}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function EditRelayDialog({
  channel,
  onClose,
  onSaved,
}: {
  channel: PushChannelView;
  onClose: () => void;
  onSaved: (view: PushChannelsView) => void;
}) {
  const [name, setName] = useState(channel.name);
  const [url, setUrl] = useState(channel.url ?? "");
  const [token, setToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // 只送改过的字段；令牌留空 = 不改
  const patch = {
    ...(name.trim() !== channel.name ? { name: name.trim() } : {}),
    ...(url.trim() !== (channel.url ?? "") ? { url: url.trim() } : {}),
    ...(token.trim() ? { token: token.trim() } : {}),
  };
  const canSave = Object.keys(patch).length > 0 && name.trim() !== "" && url.trim() !== "";

  const save = async () => {
    if (!canSave || busy) return;
    setBusy(true);
    setError(null);
    try {
      onSaved(await updateRelay(channel.id, patch));
    } catch (e) {
      setError((e as Error).message);
      setBusy(false);
    }
  };

  return (
    <Modal open onClose={onClose} label={`编辑「${channel.name}」`}>
      <form
        className="space-y-4 p-6 max-md:p-5"
        onSubmit={(e) => {
          e.preventDefault();
          void save();
        }}
      >
        <h2 className="text-title font-bold text-white">编辑自建中继</h2>
        {error && <ErrorBanner>{error}</ErrorBanner>}
        <Field label="名称">
          {(id) => (
            <input
              id={id}
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              maxLength={RELAY_NAME_MAX_LENGTH}
              className={INPUT_CLASS}
            />
          )}
        </Field>
        <Field label="中继地址" hint="改了地址，保存时会重新检测">
          {(id) => (
            <input
              id={id}
              type="text"
              inputMode="url"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              autoComplete="off"
              spellCheck={false}
              className={`${INPUT_CLASS} font-mono`}
            />
          )}
        </Field>
        <Field
          label="令牌"
          hint={channel.auth_mode === "none" ? "这个中继不需要令牌" : "留空保持现有令牌不变"}
        >
          {(id) => (
            <input
              id={id}
              type="text"
              value={token}
              onChange={(e) => setToken(e.target.value)}
              placeholder={channel.token_hint ?? "留空保持不变"}
              autoComplete="off"
              spellCheck={false}
              className={`${INPUT_CLASS} font-mono`}
            />
          )}
        </Field>
        <div className="flex justify-end gap-2">
          <button type="button" onClick={onClose} className="btn-glass px-4 py-1.5 text-sub font-medium">
            取消
          </button>
          <button
            type="submit"
            disabled={!canSave || busy}
            className="btn-accent rounded-full px-4 py-1.5 text-sub font-semibold disabled:opacity-40"
          >
            {busy ? "保存中…" : "保存"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

/** 表单字段：标签 + 输入 + 灰字说明。输入由调用方渲染，拿到关联标签的 id。 */
function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: (id: string) => ReactNode;
}) {
  const id = useId();
  return (
    <div>
      <label htmlFor={id} className="mb-1.5 block text-caption text-[var(--text-muted)]">
        {label}
      </label>
      {children(id)}
      {hint && <p className="mt-1.5 text-caption text-[var(--text-faint)]">{hint}</p>}
    </div>
  );
}
