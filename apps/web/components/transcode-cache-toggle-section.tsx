"use client";

import { useCallback, useEffect, useState } from "react";

import { Toggle } from "@/components/cloud-push-ui";
import { SettingsRow } from "@/components/settings-ui";
import { fetchPlaybackPolicy, savePlaybackPolicy } from "@/lib/api/playback";

/**
 * 「播放」分区：转码产物复用开关（docs/design/player-pipeline-optimization.md §B）。
 *
 * 开着时会话结束不删分片，同一部片同一档位再播直接读文件、不重转——续播
 * 首帧从「起 ffmpeg 转首片」变成读文件。代价是盘上常驻一块缓存（按剩余空间
 * 四分之一自动限额、24 小时未用自动清理，缓存管理页可一键清空）。盘特别紧的
 * 部署要能关掉它，所以给一个开关而不是只写在文档里。
 *
 * 交互与进度条预览那颗开关同款：改成即存、失败回滚。
 */
export function TranscodeCacheToggleRow() {
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    fetchPlaybackPolicy()
      .then((policy) => {
        if (alive) setEnabled(policy.transcode_cache_enabled);
      })
      .catch((e: Error) => {
        if (alive) setError(e.message);
      });
    return () => {
      alive = false;
    };
  }, []);

  const toggle = useCallback(
    async (next: boolean) => {
      const previous = enabled;
      setEnabled(next);
      setBusy(true);
      setError(null);
      try {
        const policy = await savePlaybackPolicy({ transcode_cache_enabled: next });
        setEnabled(policy.transcode_cache_enabled);
      } catch (e) {
        setEnabled(previous);
        setError((e as Error).message);
      } finally {
        setBusy(false);
      }
    },
    [enabled],
  );

  return (
    <SettingsRow
      label="保留转码产物供续播、重看复用"
      description={
        enabled
          ? "同一部片再次播放时已转出的部分直接读文件、不重新转码；缓存按磁盘剩余空间自动限额、24 小时未用自动清理，也可在「更新与维护 → 缓存管理」里清空"
          : "会话结束即删除分片，每次播放都重新转码；磁盘特别紧张时用"
      }
      error={error}
    >
      {enabled !== null && (
        <Toggle
          checked={enabled}
          label="保留转码产物供续播、重看复用"
          disabled={busy}
          onChange={(next) => void toggle(next)}
        />
      )}
    </SettingsRow>
  );
}
