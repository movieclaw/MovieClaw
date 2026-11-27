"use client";

import { useTranslations } from "next-intl";
import { useCallback, useEffect, useRef, useState } from "react";

import { Toggle } from "@/components/cloud-push-ui";
import { SettingsList, SettingsRow, SettingsSection } from "@/components/settings-ui";
import { fetchReelClipPolicy } from "@/lib/api/reels";
import { useUiPrefs } from "@/lib/ui-prefs";

/**
 * 查服务端管理员是否允许使用片段预切（`GET /reels/clips/policy`）。
 *
 * 允许调用方（如「设置 → 播放」页）直接传入实时的 `override` 值，避免管理员
 * 刚翻动上面的总开关时还要再发一次请求。
 */
export function useReelClipAllowed(override?: boolean | null): boolean | null {
  const [fetched, setFetched] = useState<boolean | null>(null);

  useEffect(() => {
    if (override !== undefined) return;
    let alive = true;
    fetchReelClipPolicy()
      .then((policy) => {
        if (alive) setFetched(policy.allowed);
      })
      .catch(() => {
        if (alive) setFetched(false);
      });
    return () => {
      alive = false;
    };
  }, [override]);

  return override !== undefined ? override : fetched;
}

/**
 * 成员级「片段预切（我的使用偏好）」开关（docs/design/reels.md §8）。
 *
 * - 只在管理员已开启服务端片段预切（`allowed === true`）时显示；管理员关闭或状态未就绪时隐藏。
 * - 保存走现有 `useUiPrefs().savePrefs` 链路（串行 PUT + 乐观更新 + 失败自动回滚）。
 * - 只改变当前账号看到的播放方式，不影响后台预切队列，也不会删除已切好的文件。
 */
export function ReelClipsPreferenceRow({ allowed }: { allowed?: boolean | null } = {}) {
  const t = useTranslations();
  const { prefs, savePrefs } = useUiPrefs();
  const resolvedAllowed = useReelClipAllowed(allowed);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const prefsRef = useRef(prefs);
  prefsRef.current = prefs;

  const toggle = useCallback(
    async (next: boolean) => {
      setError(null);
      setBusy(true);
      const current = prefsRef.current;
      const updated = {
        ...current,
        reels: { ...current.reels, use_clips: next },
      };
      prefsRef.current = updated;
      try {
        await savePrefs(updated);
      } catch (err) {
        setError(
          err instanceof Error ? err.message : t("settings.playback.controls.myClipsSaveFailed"),
        );
      } finally {
        setBusy(false);
      }
    },
    [savePrefs, t],
  );

  if (resolvedAllowed !== true) return null;

  return (
    <SettingsRow
      label={t("settings.playback.controls.myClipsTitle")}
      description={t("settings.playback.controls.myClipsHint")}
      error={error}
    >
      <Toggle
        checked={prefs.reels.use_clips}
        label={t("settings.playback.controls.myClipsTitle")}
        disabled={busy}
        onChange={(next) => void toggle(next)}
      />
    </SettingsRow>
  );
}

/**
 * 个人设置（「设置 → 个人信息」）里的播放偏好小节：
 * 管理员未开启片段预切时整节隐藏，保持页面零噪音。
 */
export function ReelClipsPreferenceSection({ allowed }: { allowed?: boolean | null } = {}) {
  const t = useTranslations();
  const resolvedAllowed = useReelClipAllowed(allowed);

  if (resolvedAllowed !== true) return null;

  return (
    <SettingsSection title={t("settings.playback.personalTitle")}>
      <SettingsList>
        <ReelClipsPreferenceRow allowed />
      </SettingsList>
    </SettingsSection>
  );
}
