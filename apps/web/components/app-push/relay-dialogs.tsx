"use client";

import { useLocale, useTranslations } from "next-intl";

/**
 * 自建中继的添加与编辑弹窗（docs/design/cloud-push.md §3、§7.2；交互稿 3.2）。
 *
 * 添加是「先检测、再填表」：实例读中继的 /v1/info，按它声明的鉴权方式决定后面的
 * 表单——static（和不认识的方式）要填令牌，none 不用，issuer 要签发方的令牌，这里加不了。检测之后
 * 地址又改过，结果作废，要重新检测（规则在 lib/cloud-push-display 的 relayAddBlocker）。
 * 安全提示（http 走公网、无鉴权在公网）由服务端放进 warnings，只提示不拦。
 */

import { useId, useState, type ReactNode } from "react";

import { Banner, ErrorBanner, LINK_CLASS } from "@/components/cloud-push-ui";
import { CheckIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
} from "@/components/settings-ui";
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
  const t = useTranslations();
  const locale = useLocale();
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
  const blocker = relayAddBlocker({ probe, probedUrl, url, token, name }, locale);

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
    <Modal open onClose={onClose} label={t("settings.pushChannels.addRelay")} width="lg">
      <div className="space-y-4 p-6 max-md:p-5">
        <div>
          <h2 className="text-title font-bold text-white">{t("settings.pushChannels.addRelay")}</h2>
          <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
            {t("settings.pushChannels.probeHint")}
          </p>
        </div>

        {error && <ErrorBanner>{error}</ErrorBanner>}

        <div>
          <label htmlFor={urlId} className="mb-1.5 block text-caption text-[var(--text-muted)]">
            {t("settings.pushChannels.address")}
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
              className={SETTINGS_BUTTON_CLASS}
            >
              {busy === "probe" ? t("settings.pushChannels.probing") : t("settings.pushChannels.probe")}
            </button>
          </div>
          {stale && (
            <p className="mt-1.5 text-caption text-[var(--text-faint)]">{t("settings.pushChannels.stale")}</p>
          )}
        </div>

        {current && <ProbeResult probe={current} />}

        {/* 连上了但加不了时，原因已经写在检测结果里，不再出表单 */}
        {current?.reachable &&
          !current.error?.trim() &&
          (current.auth_mode === "issuer" ? (
            <Banner tone="warn">{t("settings.pushChannels.issuerHint")}</Banner>
          ) : (
            <>
              {relayNeedsToken(current.auth_mode) && (
                <Field label={t("settings.pushChannels.token")} hint={t("settings.pushChannels.tokenHint")}>
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
              <Field label={t("settings.pushChannels.name")}>
                {(id) => (
                  <input
                    id={id}
                    type="text"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    maxLength={RELAY_NAME_MAX_LENGTH}
                    placeholder={t("settings.pushChannels.namePlaceholder")}
                    className={INPUT_CLASS}
                  />
                )}
              </Field>
            </>
          ))}

        <p className="text-caption leading-5 text-[var(--text-faint)]">
          {t("settings.pushChannels.ownAppHint")}{locale === "en" && " "}<a href={RELAY_DEPLOY_URL} target="_blank" rel="noopener noreferrer" className={LINK_CLASS}>
            {t("settings.pushChannels.deploy")}</a>
        </p>

        <div className="flex justify-end gap-2">
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            {t("common.cancel")}
          </button>
          <button
            type="button"
            disabled={blocker != null || busy != null}
            title={blocker ?? undefined}
            onClick={() => void save()}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy === "save" ? t("settings.pushChannels.saving") : t("common.save")}
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
  const t = useTranslations();
  const locale = useLocale();
  if (!probe.reachable) {
    return (
      <div className="rounded-xl border border-[var(--danger)]/30 bg-[var(--danger)]/[0.08] px-4 py-3">
        <p className="text-body font-medium text-[var(--danger)]">{t("settings.pushChannels.unreachable")}</p>
        {probe.error && (
          <p className="mt-0.5 text-sub leading-6 text-[var(--text-muted)]">{probe.error}</p>
        )}
      </div>
    );
  }
  const blocked = probe.error?.trim();
  const auth = authModeLabel(probe.auth_mode, locale);
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
          <p className="text-sub font-medium text-[var(--danger)]">{t("settings.pushChannels.incompatible")}</p>
          <p className="mt-0.5 text-sub leading-6 text-[var(--text-muted)]">{blocked}</p>
        </>
      ) : (
        <p className="flex items-center gap-1.5 text-sub font-medium text-[var(--ok)]">
          <CheckIcon className="size-4" />
          {t("settings.pushChannels.reachable")}
        </p>
      )}
      <dl className="mt-2.5 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5 text-sub">
        <dt className="text-[var(--text-faint)]">{t("settings.pushChannels.software")}</dt>
        <dd className="break-words font-mono text-[var(--text-muted)]">
          {probe.software ?? t("settings.pushChannels.undeclared")}
          {probe.protocol != null && t("settings.pushChannels.protocol", { version: probe.protocol })}
        </dd>
        <dt className="text-[var(--text-faint)]">{t("settings.pushChannels.auth")}</dt>
        <dd className="text-[var(--text-muted)]">
          {auth ? t("settings.pushChannels.authWithMode", { auth, mode: probe.auth_mode ?? "" }) : t("settings.pushChannels.undeclared")}
        </dd>
        <dt className="text-[var(--text-faint)]">{t("settings.pushChannels.apps")}</dt>
        <dd className="break-words font-mono text-[var(--text-muted)]">
          {probe.topics.length > 0 ? probe.topics.join(", ") : t("settings.pushChannels.undeclared")}
        </dd>
        <dt className="text-[var(--text-faint)]">{t("settings.pushChannels.coveredDevices")}</dt>
        {/* 没有本地设备匹配也允许保存（可能还没装 App），只用黄字提醒；
            原因服务端已经写进 warnings，这里不重复 */}
        <dd className={probe.matched_devices > 0 ? "text-[var(--text-muted)]" : "text-[var(--warn)]"}>
          {t("settings.pushChannels.coveredCount", { count: probe.matched_devices })}
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
  const t = useTranslations();
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
    <Modal open onClose={onClose} label={t("settings.pushChannels.editTitle", { name: channel.name })}>
      <form
        className="space-y-4 p-6 max-md:p-5"
        onSubmit={(e) => {
          e.preventDefault();
          void save();
        }}
      >
        <h2 className="text-title font-bold text-white">{t("settings.pushChannels.editRelay")}</h2>
        {error && <ErrorBanner>{error}</ErrorBanner>}
        <Field label={t("settings.pushChannels.name")}>
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
        <Field label={t("settings.pushChannels.address")} hint={t("settings.pushChannels.addressHint")}>
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
          label={t("settings.pushChannels.token")}
          hint={channel.auth_mode === "none" ? t("settings.pushChannels.noToken") : t("settings.pushChannels.keepToken")}
        >
          {(id) => (
            <input
              id={id}
              type="text"
              value={token}
              onChange={(e) => setToken(e.target.value)}
              placeholder={channel.token_hint ?? t("settings.pushChannels.keepValue")}
              autoComplete="off"
              spellCheck={false}
              className={`${INPUT_CLASS} font-mono`}
            />
          )}
        </Field>
        <div className="flex justify-end gap-2">
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            {t("common.cancel")}
          </button>
          <button
            type="submit"
            disabled={!canSave || busy}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? t("settings.pushChannels.saving") : t("common.save")}
          </button>
        </div>
      </form>
    </Modal>
  );
}

const INPUT_CLASS = `${SETTINGS_INPUT_CLASS} w-full`;

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
