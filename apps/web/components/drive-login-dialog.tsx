"use client";

/**
 * 「添加网盘账号」弹窗（docs/design/cloud-storage.md §2、§11.5、§11.7）。
 *
 * 网盘是插件，弹窗不认识具体网盘：按后端声明的登录方式通用渲染。
 *   - 扫码（推荐）：先选登录选项（如 115 的登录端，默认已选好、避开常见冲突）→ 显示二维码与状态 →
 *     扫完码服务端在后台建好账号，这里轮询到 confirmed 就完成；
 *   - 浏览器扩展：在已登录网盘的网页上点 MovieClaw 扩展同步，账号自动出现（这里等着刷新列表）；
 *     扩展用不了时可以展开粘贴整页 Cookie；
 *   - 填写凭据：开放平台的 Client ID / 密钥这类，字段由插件声明（login.form），按插件设置的通用表单画，
 *     提交后插件真去网盘验一次才建账号。
 * 同一网盘用户重新登录会更新原账号（不新建、不改名）；从账号卡片上重新登录时带上账号 id，
 * 登进来的是别的网盘用户会被服务端拒绝。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { Route } from "next";
import Link from "next/link";

import { LINK_CLASS } from "@/components/cloud-push-ui";
import { Modal } from "@/components/modal";
import { parseValue, SchemaForm, unsupportedField } from "@/components/schema-form";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsTabs,
} from "@/components/settings-ui";
import {
  type DriveAccount,
  type DriveBackend,
  type DriveLogin,
  cancelDriveLogin,
  getDriveLogin,
  importDriveCookie,
  listDriveAccounts,
  loginDriveWithForm,
  startDriveLogin,
} from "@/lib/api/drives";
import type { ConfigSchema } from "@/lib/api/plugins";
import { useVisiblePolling } from "@/lib/use-visible-polling";

const FAILED = new Set(["expired", "failed"]);

type Tab = "scan" | "form" | "extension";

/** 重新登录默认打开哪一页：沿用原来的方式；网页端 Cookie 容易被挤掉，照旧引导改扫码 */
const METHOD_TAB: Record<DriveAccount["login_method"], Tab> = {
  scan: "scan",
  form: "form",
  cookie: "scan",
};

export interface DriveLoginDialogProps {
  backend: DriveBackend;
  /** 从这个账号的卡片上重新登录（登进来的必须是同一个网盘用户）；不传 = 添加账号 */
  relogin?: DriveAccount;
  onClose: () => void;
  /** 登录完成：由调用方关闭弹窗并刷新列表 */
  onDone: (account: DriveAccount, created: boolean) => void;
}

export function DriveLoginDialog({ backend, relogin, onClose, onDone }: DriveLoginDialogProps) {
  const form = backend.login.form ?? null;
  const tabs: { id: Tab; label: string }[] = [
    ...(backend.login.scan ? [{ id: "scan" as const, label: "扫码登录" }] : []),
    ...(form ? [{ id: "form" as const, label: "填写凭据" }] : []),
    ...(backend.login.cookie ? [{ id: "extension" as const, label: "用浏览器扩展" }] : []),
  ];
  // 填表登录的账号重新登录时不该一进来就发起扫码
  const preferred = relogin ? METHOD_TAB[relogin.login_method] : undefined;
  const [tab, setTab] = useState<Tab>(
    tabs.find((t) => t.id === preferred)?.id ?? tabs[0]?.id ?? "scan",
  );
  const title = relogin ? `重新登录「${relogin.name}」` : `添加 ${backend.title} 账号`;

  return (
    <Modal open onClose={onClose} label={title}>
      <div className="scroll-thin max-h-[80dvh] overflow-y-auto p-6 max-md:p-5">
        <h2 className="text-title font-bold text-white">{title}</h2>
        {backend.login.hint && (
          <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">{backend.login.hint}</p>
        )}
        {tabs.length > 1 && (
          <div className="mt-4">
            <SettingsTabs tabs={tabs} value={tab} onChange={setTab} />
          </div>
        )}
        <div className="mt-5">
          {tab === "scan" ? (
            <ScanBody backend={backend} relogin={relogin?.id} onDone={onDone} />
          ) : tab === "form" && form ? (
            <FormBody backend={backend} schema={form} relogin={relogin?.id} onDone={onDone} />
          ) : (
            <ExtensionBody backend={backend} relogin={relogin?.id} onDone={onDone} />
          )}
        </div>
        <div className="mt-6 flex justify-end">
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            关闭
          </button>
        </div>
      </div>
    </Modal>
  );
}

/* —— 扫码 —— */

function ScanBody({
  backend,
  relogin,
  onDone,
}: {
  backend: DriveBackend;
  relogin?: number;
  onDone: (account: DriveAccount, created: boolean) => void;
}) {
  const defaults = useMemo(
    () => Object.fromEntries(backend.login.options.map((o) => [o.key, o.default])),
    [backend.login.options],
  );
  const [options, setOptions] = useState<Record<string, string>>(defaults);
  const [login, setLogin] = useState<DriveLogin | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const loginRef = useRef<DriveLogin | null>(null);
  loginRef.current = login;

  const begin = useCallback(
    async (picked: Record<string, string>) => {
      setError(null);
      setBusy(true);
      const previous = loginRef.current;
      if (previous && !FAILED.has(previous.status) && previous.status !== "confirmed") {
        void cancelDriveLogin(previous.login_id).catch(() => {});
      }
      try {
        setLogin(await startDriveLogin(backend.type, picked, relogin));
      } catch (e) {
        setLogin(null);
        setError((e as Error).message);
      } finally {
        setBusy(false);
      }
    },
    [backend.type, relogin],
  );

  // 进弹窗即发起：点「添加」的意图就是要二维码。改登录选项时重新发起（旧的二维码作废）
  const autoStartedRef = useRef(false);
  useEffect(() => {
    if (autoStartedRef.current) return;
    autoStartedRef.current = true;
    void begin(defaults);
  }, [begin, defaults]);

  // 关弹窗时取消还没完成的扫码
  useEffect(
    () => () => {
      const current = loginRef.current;
      if (current && !FAILED.has(current.status) && current.status !== "confirmed") {
        void cancelDriveLogin(current.login_id).catch(() => {});
      }
    },
    [],
  );

  const active = login != null && login.status !== "confirmed" && !FAILED.has(login.status);
  useVisiblePolling(
    () => {
      if (login == null) return;
      void getDriveLogin(login.login_id)
        .then((snap) => {
          if (snap.status === "confirmed" && snap.account) {
            onDone(snap.account, snap.created);
            return;
          }
          setLogin(snap);
        })
        .catch(() => {
          /* 轮询失败静默重试（过期由状态自己表达） */
        });
    },
    active ? 1500 : null,
  );

  const failed = login != null && FAILED.has(login.status);

  return (
    <div className="space-y-4">
      {backend.login.options.map((option) => {
        const chosen = option.choices.find((c) => c.value === options[option.key]);
        return (
          <div key={option.key}>
            <label className="mb-1.5 block text-sub font-medium text-[var(--text-muted)]">
              {option.label}
            </label>
            <select
              value={options[option.key]}
              onChange={(e) => {
                const next = { ...options, [option.key]: e.target.value };
                setOptions(next);
                void begin(next);
              }}
              className={`${SETTINGS_INPUT_CLASS} w-full`}
            >
              {option.choices.map((c) => (
                <option key={c.value} value={c.value}>
                  {c.label}
                  {c.value === option.default ? "（推荐）" : ""}
                </option>
              ))}
            </select>
            {(chosen?.help || option.help) && (
              <p className="mt-1.5 text-caption leading-5 text-[var(--text-faint)]">
                {chosen?.help || option.help}
              </p>
            )}
          </div>
        );
      })}

      {error && (
        <div className="rounded-xl border border-[#ff6b6b]/30 bg-[#ff6b6b]/10 px-4 py-3 text-body text-[#ff6b6b]">
          {error}
        </div>
      )}

      <div className="flex flex-col items-center gap-4 rounded-2xl bg-white/[0.03] px-6 py-6 text-center">
        {login == null ? (
          busy ? (
            <div className="size-[200px] animate-pulse rounded-2xl bg-white/[0.06]" />
          ) : (
            <button type="button" onClick={() => void begin(options)} className={SETTINGS_PRIMARY_BUTTON_CLASS}>
              重试
            </button>
          )
        ) : (
          <>
            {!failed && login.qr_image && (
              <div className="rounded-2xl bg-white p-3">
                {/* 服务端渲染的 SVG data URL，用原生 img 展示内联数据 */}
                <img src={login.qr_image} alt={`${backend.title}登录二维码`} className="size-44" />
              </div>
            )}
            <div>
              <p className="text-body font-medium text-[var(--text)]">
                {failed ? "登录未完成" : login.status === "scanned" ? "已扫描" : `用 ${backend.title} App 扫码`}
              </p>
              <p className="mt-1 text-sub text-[var(--text-muted)]">
                {login.message || (login.status === "pending" ? "扫码后在手机上确认登录" : "")}
              </p>
            </div>
            {failed && (
              <button
                type="button"
                disabled={busy}
                onClick={() => void begin(options)}
                className={SETTINGS_PRIMARY_BUTTON_CLASS}
              >
                重新扫码
              </button>
            )}
          </>
        )}
      </div>
    </div>
  );
}

/* —— 浏览器扩展（与粘贴 Cookie） —— */

function ExtensionBody({
  backend,
  relogin,
  onDone,
}: {
  backend: DriveBackend;
  relogin?: number;
  onDone: (account: DriveAccount, created: boolean) => void;
}) {
  const domain = backend.login.cookie_domains[0] ?? "";
  const [paste, setPaste] = useState(false);
  const [cookie, setCookie] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const knownRef = useRef<Map<number, string> | null>(null);

  // 等扩展推送：账号出现（或同一账号的登录更新了）就算完成
  useVisiblePolling(
    () => {
      void listDriveAccounts()
        .then((rows) => {
          const mine = rows.filter((r) => r.backend === backend.type && r.login_method === "cookie");
          if (knownRef.current == null) {
            knownRef.current = new Map(rows.map((r) => [r.id, r.profile_at ?? r.created_at]));
            return;
          }
          const known = knownRef.current;
          const fresh = mine.find(
            (r) => !known.has(r.id) || known.get(r.id) !== (r.profile_at ?? r.created_at),
          );
          if (fresh) onDone(fresh, !known.has(fresh.id));
        })
        .catch(() => {});
    },
    paste ? null : 2000,
    { leading: true },
  );

  async function submit() {
    setBusy(true);
    setError(null);
    try {
      const result = await importDriveCookie(backend.type, cookie.trim(), relogin);
      if (result.account) onDone(result.account, result.created);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4 text-sub leading-6 text-[var(--text-muted)]">
      <ol className="list-decimal space-y-1 pl-5">
        <li>
          在这台电脑的浏览器里打开 <span className="text-[var(--text)]">{domain}</span> 并登录；
        </li>
        <li>点工具栏上的 MovieClaw 扩展图标 →「同步当前站点」；</li>
        <li>回到这里，账号会自动出现。</li>
      </ol>
      <div className="rounded-xl border border-[var(--warn)]/30 bg-[var(--warn)]/[0.07] px-4 py-3 text-caption leading-5">
        这种方式用的是<b className="text-[var(--text)]">网页端登录</b>
        ，与浏览器共用：在别的电脑上登录网页版会让它失效（开着扩展的自动同步时，回到这台浏览器会自动恢复）。想更稳定请用扫码。
      </div>
      <p className="text-caption text-[var(--text-faint)]">
        还没装扩展？在
        <Link href={"/settings/sites" as Route} className={`mx-1 ${LINK_CLASS}`}>
          设置 → 资源站点
        </Link>
        下载。
        {!paste && (
          <button
            type="button"
            onClick={() => setPaste(true)}
            className="ml-2 underline underline-offset-4 hover:text-[var(--text)]"
          >
            扩展用不了？粘贴 Cookie
          </button>
        )}
      </p>
      {paste && (
        <div className="space-y-2">
          <textarea
            value={cookie}
            onChange={(e) => setCookie(e.target.value)}
            rows={3}
            placeholder="整页 Cookie：name=value; name2=value2"
            className={`${SETTINGS_INPUT_CLASS} w-full font-mono text-caption`}
          />
          {error && <p className="text-caption text-[var(--danger)]">{error}</p>}
          <button
            type="button"
            disabled={busy || !cookie.trim()}
            onClick={() => void submit()}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? "校验中…" : "登录"}
          </button>
        </div>
      )}
    </div>
  );
}

/* —— 填写凭据（开放平台的 Client ID / 密钥等） —— */

function FormBody({
  backend,
  schema,
  relogin,
  onDone,
}: {
  backend: DriveBackend;
  schema: ConfigSchema;
  relogin?: number;
  onDone: (account: DriveAccount, created: boolean) => void;
}) {
  // 敏感字段不带默认值（服务端也不给），其余字段用插件声明的默认值
  const [values, setValues] = useState<Record<string, unknown>>(() =>
    Object.fromEntries(
      Object.entries(schema.properties)
        .filter(([, field]) => field.default !== undefined)
        .map(([name, field]) => [name, field.default]),
    ),
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const unknown = unsupportedField(schema);

  async function submit() {
    setBusy(true);
    setError(null);
    try {
      const payload = Object.fromEntries(
        Object.entries(schema.properties)
          .filter(([name]) => values[name] !== undefined)
          .map(([name, field]) => {
            const value = values[name];
            return [name, typeof value === "string" ? parseValue(field, value) : value];
          }),
      );
      const result = await loginDriveWithForm(backend.type, payload, relogin);
      if (result.account) onDone(result.account, result.created);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  if (unknown) {
    return (
      <p className="text-sub text-[var(--text-muted)]">
        这个网盘的登录表单有网页还不认识的字段（{unknown}），刷新页面后再试。
      </p>
    );
  }

  return (
    <form
      className="space-y-5"
      onSubmit={(e) => {
        e.preventDefault();
        void submit();
      }}
    >
      <SchemaForm
        schema={schema}
        values={values}
        disabled={busy}
        onChange={(name, value) => setValues((prev) => ({ ...prev, [name]: value }))}
      />
      <p className="text-caption leading-5 text-[var(--text-faint)]">
        提交后会用这组凭据登录一次 {backend.title} 来确认有效；密钥加密保存，之后不再显示。
      </p>
      {error && <p className="text-caption text-[var(--danger)]">{error}</p>}
      <button type="submit" disabled={busy} className={SETTINGS_PRIMARY_BUTTON_CLASS}>
        {busy ? "验证中…" : "验证并登录"}
      </button>
    </form>
  );
}
