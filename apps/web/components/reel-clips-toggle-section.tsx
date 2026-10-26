"use client";

import { useLocale, useTranslations } from "next-intl";

import { useCallback, useEffect, useState } from "react";

import { Toggle } from "@/components/cloud-push-ui";
import { useConfirm } from "@/components/feedback";
import { SettingsRow } from "@/components/settings-ui";
import {
  deleteReelClips,
  fetchPlaybackPolicy,
  fetchReelClipStats,
  savePlaybackPolicy,
  type ReelClipProgress,
} from "@/lib/api/playback";
import { appTranslator } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { formatBytes } from "@/lib/format";

/** 开着且还在切时多久刷新一次进度 */
const PROGRESS_POLL_MS = 15_000;

export function progressText(progress: ReelClipProgress | null, locale: AppLocale = "zh-Hans"): string {
  const t = appTranslator(locale);
  if (!progress) return t("settings.playback.controls.preparing");
  const { ready, total, state } = progress;
  if (state === "done") {
    const skipped = total - ready;
    return skipped > 0
      ? t("settings.playback.controls.clipsSkipped", { ready, skipped })
      : t("settings.playback.controls.clipsDone", { ready });
  }
  return t(state === "paused" ? "settings.playback.controls.clipsPaused" : "settings.playback.controls.clipsRunning", { ready, total });
}

/**
 * 「播放」分区：片段预切开关（docs/design/reels.md §8）。
 *
 * 默认关闭：开启要把全库在后台转一遍，低配 NAS 上是一段可感知的 CPU 负载，得由用户
 * 自己决定要不要用算力换预告的流畅。开着时描述里直接写进度，不进任务中心——切片队列
 * 常驻、随时插队，和任务中心那种一次性作业不是一回事。
 *
 * 关闭时若已有切好的片段，问一句要不要一并删除（默认保留，重新打开即可直接用）。
 */
export function ReelClipsToggleRow() {
  const t = useTranslations();
  const locale = useLocale();
  const confirm = useConfirm();
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [progress, setProgress] = useState<ReelClipProgress | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    fetchPlaybackPolicy()
      .then((policy) => {
        if (!alive) return;
        setEnabled(policy.reel_clips_enabled);
        setProgress(policy.reel_clips_progress);
      })
      .catch((e: Error) => {
        if (alive) setError(e.message);
      });
    return () => {
      alive = false;
    };
  }, []);

  const polling = enabled === true && progress?.state !== "done";
  useEffect(() => {
    if (!polling) return;
    const timer = window.setInterval(() => {
      fetchPlaybackPolicy()
        .then((policy) => setProgress(policy.reel_clips_progress))
        .catch(() => {
          /* 刷新进度失败不打扰：下一轮再试 */
        });
    }, PROGRESS_POLL_MS);
    return () => window.clearInterval(timer);
  }, [polling]);

  const toggle = useCallback(
    async (next: boolean) => {
      setError(null);
      let purge = false;
      if (!next) {
        let stats;
        try {
          stats = await fetchReelClipStats();
        } catch (e) {
          setError((e as Error).message);
          return;
        }
        if (stats.count > 0) {
          const result = await confirm({
            title: t("settings.playback.controls.disableClipsTitle"),
            description: t("settings.playback.controls.disableClipsHint"),
            confirmLabel: t("settings.playback.controls.turnOff"),
            checkbox: {
              label: t("settings.playback.controls.deleteClips", { count: stats.count, bytes: formatBytes(stats.bytes) }),
              description: t("settings.playback.controls.keepClipsHint"),
              defaultChecked: false,
            },
          });
          if (!result.ok) return;
          purge = result.checked;
        }
      }
      const previous = enabled;
      setEnabled(next); // 乐观更新：失败回滚
      setBusy(true);
      try {
        const policy = await savePlaybackPolicy({ reel_clips_enabled: next });
        setEnabled(policy.reel_clips_enabled);
        setProgress(policy.reel_clips_progress);
        if (purge) await deleteReelClips();
      } catch (e) {
        setEnabled(previous);
        setError((e as Error).message);
      } finally {
        setBusy(false);
      }
    },
    [confirm, enabled, t],
  );

  return (
    <SettingsRow
      label={t("settings.playback.controls.clipsTitle")}
      description={enabled ? progressText(progress, locale) : t("settings.playback.controls.clipsOff")}
      error={error}
    >
      {enabled !== null && (
        <Toggle
          checked={enabled}
          label={t("settings.playback.controls.clipsTitle")}
          disabled={busy}
          onChange={(next) => void toggle(next)}
        />
      )}
    </SettingsRow>
  );
}
