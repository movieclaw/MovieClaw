"use client";

/**
 * 「播放」分区：在外面播放网盘上的片子怎么取流（docs/design/cloud-storage.md §7.2）。
 *
 * 只在有网盘账号时出现——没有网盘，这个选择没有意义。三选一，点选即存、失败回滚：
 *   - 自动（推荐）：一般经家里转发；只有自家 App 能在直连失败时改走转发、且同一时间只有一处在外面时
 *     才直连网盘；
 *   - 总是经家里转发：网盘只看到家里一个地址，最稳妥，受家里上行限制；
 *   - 总是直连网盘：不占上行，但多处同时在外面看可能被网盘判为账号共享。
 * 家里的设备始终经家里转发，离线下载始终由家里转出。
 */

import { useEffect, useState } from "react";

import { SettingsSection } from "@/components/settings-ui";
import { getDriveStatus } from "@/lib/api/drives";
import { type CloudStreamMode, fetchPlaybackPolicy, savePlaybackPolicy } from "@/lib/api/playback";

const OPTIONS: { value: CloudStreamMode; title: string; description: string }[] = [
  {
    value: "auto",
    title: "自动（推荐）",
    description:
      "一般经家里转发；只有 MovieClaw 自家 App、且同一时间只有一处在外面时，才直连网盘（不占家里上行，码率不受限）。直连出错会自动改走转发。",
  },
  {
    value: "relay",
    title: "总是经家里转发",
    description: "网盘只看到家里一个地址，最稳妥；在外面看高码率时受家里上行限制，超过时自动降码率。",
  },
  {
    value: "direct",
    title: "总是直连网盘",
    description: "所有设备在外面都直接从网盘拉流。多处同时在外面看可能被网盘判为账号共享；部分第三方播放器可能播不了。",
  },
];

export function CloudStreamModeSection() {
  const [visible, setVisible] = useState(false);
  const [mode, setMode] = useState<CloudStreamMode | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    // 网盘功能休眠（没装网盘插件）或没有账号时这一组不出现，连播放策略也不用读
    void getDriveStatus()
      .then(async (status) => {
        if (!status.active || status.accounts === 0) return;
        const policy = await fetchPlaybackPolicy();
        if (!alive) return;
        setVisible(true);
        setMode(policy.cloud_stream_mode ?? "auto");
      })
      .catch(() => {
        /* 没有网盘接口（老服务器）或读不到：不显示这一组 */
      });
    return () => {
      alive = false;
    };
  }, []);

  if (!visible || mode == null) return null;

  async function choose(next: CloudStreamMode) {
    if (next === mode || busy) return;
    const previous = mode;
    setMode(next);
    setBusy(true);
    setError(null);
    try {
      const policy = await savePlaybackPolicy({ cloud_stream_mode: next });
      setMode(policy.cloud_stream_mode ?? next);
    } catch (e) {
      setMode(previous);
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <SettingsSection
      title="在外面播放网盘上的片子"
      footnote="在家里的设备始终经家里转发；离线下载始终由家里转出。"
    >
      <div role="radiogroup" aria-label="在外面播放网盘上的片子" className="space-y-2">
        {OPTIONS.map((option) => {
          const on = option.value === mode;
          return (
            <button
              key={option.value}
              type="button"
              role="radio"
              aria-checked={on}
              disabled={busy}
              onClick={() => void choose(option.value)}
              className={`css-glass flex w-full items-start gap-3 !rounded-xl px-4 py-3 text-left transition-colors ${
                on ? "ring-1 ring-[var(--accent-ring)]" : "hover:bg-white/[0.03]"
              }`}
            >
              <span
                aria-hidden
                className={`mt-1 grid size-4 shrink-0 place-items-center rounded-full border ${
                  on ? "border-[var(--accent)]" : "border-white/30"
                }`}
              >
                {on && <span className="size-2 rounded-full bg-[var(--accent)]" />}
              </span>
              <span className="min-w-0">
                <span className="block text-body font-medium text-[var(--text)]">{option.title}</span>
                <span className="mt-0.5 block text-caption leading-5 text-[var(--text-faint)]">
                  {option.description}
                </span>
              </span>
            </button>
          );
        })}
      </div>
      {error && <p className="mt-2 px-1 text-sub text-[var(--danger)]">{error}</p>}
    </SettingsSection>
  );
}
