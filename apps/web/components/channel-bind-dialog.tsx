"use client";

/**
 * 「接入通道」绑定弹窗——所有通道共用一层壳（docs/design/plugin-channels.md §5.2）。
 *
 * 通道是插件，弹窗不认识任何具体平台：按通道声明的绑定方式通用渲染。
 *   - 交互式（flow，如微信扫码）：进弹窗即发起 → 显示二维码与状态 → 需要时填输入框
 *     （微信手机上显示的配对数字）→ 完成；
 *   - 表单（form）：按字段渲染表单 → 提交。带配对码的（Telegram / Discord）显示 6 位码，
 *     用户私聊 bot 发码后完成；不带配对的（飞书 Webhook）提交即完成。
 * 未完成的状态靠 2 秒一次的轮询推进（后端只读内存快照，毫秒级返回）。
 *
 * 为什么收进弹窗：绑定是一次性动作，而设置页的常态是「看看已经接好了哪些」。
 * 只有点「新增通道」才进入这层，绑定成功即关闭并刷新列表。
 */

import { useCallback, useEffect, useRef, useState } from "react";

import { CopyButton } from "@/components/copy-button";
import { Modal } from "@/components/modal";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
} from "@/components/settings-ui";
import {
  type ChannelBinding,
  type ChannelInfo,
  getChannelBinding,
  startChannelBinding,
  submitChannelBindingInput,
} from "@/lib/api/channels";
import { useVisiblePolling } from "@/lib/use-visible-polling";

const INPUT_CLASS = `${SETTINGS_INPUT_CLASS} w-full min-w-0`;

const DONE = new Set(["confirmed", "already_bound"]);
const FAILED = new Set(["expired", "failed"]);

export interface ChannelBindDialogProps {
  channel: ChannelInfo;
  onClose: () => void;
  /** 绑定完成：由调用方负责关闭弹窗并刷新通道列表 */
  onBound: () => void;
}

export function ChannelBindDialog({ channel, onClose, onBound }: ChannelBindDialogProps) {
  return (
    <Modal open onClose={onClose} label={`接入 ${channel.title}`}>
      <div className="scroll-thin max-h-[76dvh] overflow-y-auto p-6 max-md:p-5">
        <h2 className="text-title font-bold text-white">接入 {channel.title}</h2>
        <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
          {channel.binding.hint || channel.description}
        </p>

        <div className="mt-5">
          {channel.binding.kind === "flow" ? (
            <FlowBindBody channel={channel} onBound={onBound} />
          ) : (
            <FormBindBody channel={channel} onBound={onBound} />
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

/** 回调地址：靠平台回调收消息的通道（如企业微信自建应用）要填到平台后台。 */
function CallbackAddress({ binding }: { binding: ChannelBinding }) {
  if (!binding.callback_url) return null;
  return (
    <div className="w-full space-y-2 rounded-xl border border-white/[0.08] bg-black/[0.28] px-4 py-3 text-left">
      <div className="flex items-center justify-between gap-3">
        <span className="text-sub font-medium text-[var(--text)]">回调地址</span>
        <CopyButton text={binding.callback_url} label="复制" className={SETTINGS_BUTTON_CLASS} />
      </div>
      <p className="break-all font-mono text-caption text-[var(--text)] select-all">
        {binding.callback_url}
      </p>
      {binding.callback_note && (
        <p className="text-caption leading-5 text-[var(--text-faint)]">{binding.callback_note}</p>
      )}
    </div>
  );
}

/** 错误条：两种 body 共用。 */
function ErrorBanner({ message }: { message: string }) {
  return (
    <div className="rounded-xl border border-[#ff6b6b]/30 bg-[#ff6b6b]/10 px-4 py-3 text-body text-[#ff6b6b]">
      {message}
    </div>
  );
}

/** 未完成的绑定每 2 秒轮询一次；完成即回调，终态失败停在原地给重试入口。 */
function useBindingPolling(
  binding: ChannelBinding | null,
  setBinding: (next: ChannelBinding) => void,
  onBound: () => void,
) {
  const active = binding != null && !DONE.has(binding.status) && !FAILED.has(binding.status);
  useVisiblePolling(
    () => {
      if (binding == null) return;
      void getChannelBinding(binding.binding_id)
        .then((snap) => {
          if (DONE.has(snap.status)) {
            onBound();
            return;
          }
          setBinding(snap);
        })
        .catch(() => {
          /* 轮询失败静默重试（过期由状态自己表达） */
        });
    },
    active ? 2000 : null,
  );
}

/* —— 交互式：二维码 + 可选输入 —— */

function FlowBindBody({ channel, onBound }: { channel: ChannelInfo; onBound: () => void }) {
  const [binding, setBinding] = useState<ChannelBinding | null>(null);
  const [value, setValue] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const begin = useCallback(async () => {
    setError(null);
    setValue("");
    setBusy(true);
    try {
      setBinding(await startChannelBinding(channel.id));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }, [channel.id]);

  // 进弹窗即发起：点「新增」的意图就是要二维码，不再多一次点击。
  // 只自动发起一次，失败 / 过期后由用户点按钮重来，不无限重试。
  const autoStartedRef = useRef(false);
  useEffect(() => {
    if (autoStartedRef.current) return;
    autoStartedRef.current = true;
    void begin();
  }, [begin]);

  useBindingPolling(binding, setBinding, onBound);

  async function handleSubmit() {
    if (binding == null || !value.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const next = await submitChannelBindingInput(binding.binding_id, value.trim());
      setValue("");
      if (DONE.has(next.status)) onBound();
      else setBinding(next);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  const failed = binding != null && FAILED.has(binding.status);

  return (
    <div className="space-y-4">
      {error && <ErrorBanner message={error} />}

      {binding == null ? (
        busy ? (
          <div className="h-[240px] animate-pulse rounded-2xl bg-white/[0.04]" />
        ) : (
          // 发起失败（网关不可达等）：留一个手动重试入口
          <div className="flex flex-col items-center gap-3 rounded-2xl bg-white/[0.03] px-6 py-10 text-center">
            <p className="text-body font-medium text-[var(--text)]">没能发起绑定</p>
            <button
              type="button"
              onClick={() => void begin()}
              className={SETTINGS_PRIMARY_BUTTON_CLASS}
            >
              重试
            </button>
          </div>
        )
      ) : (
        <div className="flex flex-col items-center gap-4 rounded-2xl bg-white/[0.03] px-6 py-6 text-center">
          {!failed && binding.qr_image && (
            <div className="rounded-2xl bg-white p-3">
              {/* 服务端渲染的 SVG data URL，用原生 img 展示内联数据 */}
              <img src={binding.qr_image} alt={`${channel.title}绑定二维码`} className="size-44" />
            </div>
          )}
          <div>
            <p className="text-body font-medium text-[var(--text)]">
              {failed
                ? "绑定未完成"
                : binding.status === "pending"
                  ? "等待扫码"
                  : binding.status === "need_input"
                    ? "还差一步"
                    : "已扫码"}
            </p>
            <p className="mt-1 text-sub text-[var(--text-muted)]">{binding.message}</p>
          </div>
          {failed && (
            <button
              type="button"
              disabled={busy}
              onClick={() => void begin()}
              className={SETTINGS_PRIMARY_BUTTON_CLASS}
            >
              重新发起
            </button>
          )}
        </div>
      )}

      {binding?.status === "need_input" && (
        <div className="flex gap-2">
          <input
            value={value}
            onChange={(e) => setValue(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && void handleSubmit()}
            inputMode="numeric"
            autoFocus
            placeholder={binding.input_label ?? "请输入"}
            className={INPUT_CLASS}
          />
          <button
            type="button"
            disabled={busy || !value.trim()}
            onClick={() => void handleSubmit()}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            确认
          </button>
        </div>
      )}
    </div>
  );
}

/* —— 表单：字段 +（可选）配对码 —— */

function FormBindBody({ channel, onBound }: { channel: ChannelInfo; onBound: () => void }) {
  const fields = channel.binding.fields;
  const [values, setValues] = useState<Record<string, string>>({});
  const [binding, setBinding] = useState<ChannelBinding | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const ready = fields.every((f) => !f.required || (values[f.key] ?? "").trim());

  async function handleSubmit() {
    if (!ready) return;
    setBusy(true);
    setError(null);
    try {
      const trimmed = Object.fromEntries(
        Object.entries(values).map(([key, value]) => [key, value.trim()]),
      );
      const next = await startChannelBinding(channel.id, trimmed);
      // 回调式通道直接接入完成时，先把回调地址给用户看、复制，再关弹窗
      if (DONE.has(next.status) && !next.callback_url) onBound();
      else setBinding(next);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  useBindingPolling(binding, setBinding, onBound);

  if (binding == null) {
    return (
      <div className="space-y-3">
        {error && <ErrorBanner message={error} />}
        {fields.map((field, index) => (
          <label key={field.key} className="block space-y-1.5">
            <span className="text-sub font-medium text-[var(--text)]">
              {field.label}
              {!field.required && (
                <span className="ml-1 font-normal text-[var(--text-faint)]">（选填）</span>
              )}
            </span>
            <input
              value={values[field.key] ?? ""}
              onChange={(e) => setValues({ ...values, [field.key]: e.target.value })}
              onKeyDown={(e) => e.key === "Enter" && void handleSubmit()}
              autoFocus={index === 0}
              type={field.secret ? "password" : "text"}
              autoComplete="off"
              placeholder={field.placeholder}
              className={INPUT_CLASS}
            />
            {field.help && (
              <span className="block text-caption leading-5 text-[var(--text-faint)]">
                {field.help}
              </span>
            )}
          </label>
        ))}
        <button
          type="button"
          disabled={busy || !ready}
          onClick={() => void handleSubmit()}
          className={`${SETTINGS_PRIMARY_BUTTON_CLASS} w-full`}
        >
          {busy
            ? "校验中…"
            : channel.binding.pairing === "code"
              ? "获取配对码"
              : "完成接入"}
        </button>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {error && <ErrorBanner message={error} />}
      <div className="flex flex-col items-center gap-3 rounded-2xl bg-white/[0.03] px-6 py-8 text-center">
        {DONE.has(binding.status) ? (
          <>
            <p className="text-body font-medium text-[var(--text)]">{binding.message}</p>
            <CallbackAddress binding={binding} />
            <button type="button" onClick={onBound} className={SETTINGS_PRIMARY_BUTTON_CLASS}>
              完成
            </button>
          </>
        ) : binding.status === "pending" ? (
          <>
            <CallbackAddress binding={binding} />
            <p className="text-body font-medium text-[var(--text)]">{binding.message}</p>
            <p className="select-all font-mono text-[32px] font-bold tracking-[0.3em] text-[var(--accent)]">
              {binding.pair_code}
            </p>
            <p className="text-caption text-[var(--text-faint)]">
              10 分钟内有效 · 发码人将成为唯一可对话的用户与推送目标
            </p>
          </>
        ) : (
          <>
            <p className="text-body font-medium text-[var(--text)]">绑定未完成</p>
            <p className="text-sub text-[var(--text-muted)]">{binding.message}</p>
            <button
              type="button"
              onClick={() => setBinding(null)}
              className={SETTINGS_PRIMARY_BUTTON_CLASS}
            >
              重新发起
            </button>
          </>
        )}
      </div>
    </div>
  );
}
