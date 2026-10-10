"use client";

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
import { formatBytes } from "@/lib/format";

/** 开着且还在切时多久刷新一次进度 */
const PROGRESS_POLL_MS = 15_000;

const OFF_DESCRIPTION =
  "后台把每部影片的精彩片段提前转成 1080p 小文件。开启后，电视首页和详情页的大图预告起播快、不卡顿，" +
  "刷片更流畅，外网刷片也不用实时转码。首次开启要在后台处理一段时间（有人观看时自动暂停），每部约占 20 MB。";

function progressText(progress: ReelClipProgress | null): string {
  if (!progress) return "正在准备……";
  const { ready, total, state } = progress;
  if (state === "done") {
    const skipped = total - ready;
    return skipped > 0
      ? `已切好 ${ready} 部，其余 ${skipped} 部无法预切（网盘文件或片子太短）；新入库的会自动补切`
      : `已切好全部 ${ready} 部；新入库的会自动补切`;
  }
  if (state === "paused") return `已切好 ${ready} / ${total} 部，有人在观看，暂停中`;
  return `已切好 ${ready} / ${total} 部，正在后台处理；没切好的预告先显示剧照`;
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
            title: "关闭片段预切？",
            description: "关闭后预告和刷片改回直接播放原片，后台不再切新的片段。",
            confirmLabel: "关闭",
            checkbox: {
              label: `同时删除已切好的 ${stats.count} 个片段（${formatBytes(stats.bytes)}）`,
              description: "不删的话，重新打开即可直接使用。",
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
    [confirm, enabled],
  );

  return (
    <SettingsRow
      label="片段预切"
      description={enabled ? progressText(progress) : OFF_DESCRIPTION}
      error={error}
    >
      {enabled !== null && (
        <Toggle
          checked={enabled}
          label="片段预切"
          disabled={busy}
          onChange={(next) => void toggle(next)}
        />
      )}
    </SettingsRow>
  );
}
