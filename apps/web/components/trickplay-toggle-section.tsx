"use client";

import { useTranslations } from "next-intl";

import { useCallback, useEffect, useState } from "react";

import { Toggle } from "@/components/cloud-push-ui";
import { SettingsRow } from "@/components/settings-ui";
import { fetchPlaybackPolicy, savePlaybackPolicy } from "@/lib/api/playback";

/**
 * 「播放」分区：进度条预览缩略图的生成开关。
 *
 * 预览图要通读整部影片抽帧（4 倍速限速下两小时片约 30 分钟），低配 NAS 上
 * 是一段可感知的 CPU/磁盘负载——它默认打开（预览是「这个播放器不便宜」的
 * 第一印象来源），但必须给用户一个体面的关法，而不是逼他去翻 compose 环境变量。
 *
 * 与远程转码那张「改动后按保存」的表单不同，这里只有一个开关，改成即存、
 * 失败即回滚并提示，不需要单独的保存按钮。已生成的预览不受开关影响：
 * 关掉只是不再生成新的，重新打开即恢复。
 */
export function TrickplayToggleRow() {
  const t = useTranslations();
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    fetchPlaybackPolicy()
      .then((policy) => {
        if (alive) setEnabled(policy.trickplay_enabled);
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
      setEnabled(next); // 乐观更新：失败回滚，成功时省一次等待
      setBusy(true);
      setError(null);
      try {
        const policy = await savePlaybackPolicy({ trickplay_enabled: next });
        setEnabled(policy.trickplay_enabled);
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
      label={t("settings.playback.controls.trickplayTitle")}
      description={
        enabled
          ? t("settings.playback.controls.trickplayOn")
          : t("settings.playback.controls.trickplayOff")
      }
      error={error}
    >
      {enabled !== null && (
        <Toggle
          checked={enabled}
          label={t("settings.playback.controls.trickplayTitle")}
          disabled={busy}
          onChange={(next) => void toggle(next)}
        />
      )}
    </SettingsRow>
  );
}
