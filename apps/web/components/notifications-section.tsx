"use client";

/**
 * 「账号 → 通知」分区（docs/design/cloud-push.md §1、§5、§7.3、§8；交互稿 4.2）。
 *
 * 每个人只管自己收哪些手机通知，以及给自己发一条测试通知。设备只在「账号 → 设备」
 * 一个地方管：这里不列设备，只有自己有设备收不到时顶部出一条提示，点进设备页。
 * 成员只有这一个入口，不需要知道云、中继这些概念。
 *
 * 开关存在服务器上、按人一份，网页和 App 改的是同一份。服务器还没有任何可用
 * 通道时开关照样能改，顶部说明一句：成员看到「管理员还没有开启」，管理员看到
 * 去哪开启——开通后这里的设置立刻生效。
 */

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";

import { Banner, ErrorBanner, LINK_CLASS, Toggle } from "@/components/cloud-push-ui";
import { useToast } from "@/components/feedback";
import {
  SETTINGS_BUTTON_CLASS,
  SettingsList,
  SettingsRow,
  SettingsSection,
} from "@/components/settings-ui";
import {
  type MyPushLibrary,
  type MyPushMutedItem,
  type MyPushView,
  getMyPush,
  sendMyPushTest,
  unmuteMyPushItem,
  updateMyPushPreferences,
} from "@/lib/api/push";
import {
  attentionLine,
  groupEvents,
  libraryChecked,
  summarizePushTest,
  testTargetHint,
  toggleLibrary,
} from "@/lib/cloud-push-display";

/** 「媒体库有新片」的事件键：打开时在它下面选关心哪些库 */
const LIBRARY_EVENT = "library_new";

export function NotificationsSection() {
  const toast = useToast();
  const [view, setView] = useState<MyPushView | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [testing, setTesting] = useState(false);
  // 只采纳最后一次改开关的响应：连着拨两个开关时，先回来的那份不能把后一个拨回去
  const seqRef = useRef(0);

  const load = useCallback(async () => {
    setLoadError(null);
    try {
      setView(await getMyPush());
    } catch (e) {
      setLoadError((e as Error).message);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  /**
   * 改偏好：先按 optimistic 把页面拨过去，再存。失败时不猜怎么回滚，直接从服务端
   * 重读一份——开关和选库会连着改，逐项回滚容易把后一次的改动一起冲掉。
   */
  const save = async (
    patch: Parameters<typeof updateMyPushPreferences>[0],
    optimistic: (prev: MyPushView) => MyPushView,
  ) => {
    const seq = ++seqRef.current;
    setError(null);
    setView((prev) => prev && optimistic(prev));
    try {
      const next = await updateMyPushPreferences(patch);
      if (seq === seqRef.current) setView(next);
    } catch (e) {
      setError((e as Error).message);
      void load();
    }
  };

  const withEvent = (prev: MyPushView, key: string, enabled: boolean): MyPushView => ({
    ...prev,
    events: prev.events.map((event) => (event.key === key ? { ...event, enabled } : event)),
  });

  const toggle = (key: string, enabled: boolean) =>
    void save({ events: { [key]: enabled } }, (prev) => withEvent(prev, key, enabled));

  /** 勾 / 取消一个库；一个都不剩就等于关掉「媒体库有新片」 */
  const pickLibrary = (id: number, checked: boolean) => {
    if (view == null) return;
    const visible = view.libraries.map((lib) => lib.id);
    const result = toggleLibrary(view.library_ids, visible, id, checked);
    if (result.turnOff) {
      void save({ events: { [LIBRARY_EVENT]: false }, library_ids: null }, (prev) => ({
        ...withEvent(prev, LIBRARY_EVENT, false),
        library_ids: null,
      }));
    } else {
      void save({ library_ids: result.libraryIds }, (prev) => ({
        ...prev,
        library_ids: result.libraryIds,
      }));
    }
  };

  /** 恢复一部片的推送：先从列表里拿掉，失败从服务端重读 */
  const unmute = async (id: number) => {
    const seq = ++seqRef.current;
    setError(null);
    setView(
      (prev) =>
        prev && { ...prev, muted_items: prev.muted_items?.filter((item) => item.id !== id) },
    );
    try {
      const next = await unmuteMyPushItem(id);
      if (seq === seqRef.current) setView(next);
    } catch (e) {
      setError((e as Error).message);
      void load();
    }
  };

  const sendTest = async () => {
    setTesting(true);
    try {
      const summary = summarizePushTest(await sendMyPushTest());
      if (summary.tone === "success") toast.success(summary.message);
      else toast.error(summary.message);
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setTesting(false);
    }
  };

  if (view == null) {
    return loadError ? (
      <div className="space-y-3">
        <ErrorBanner>{loadError}</ErrorBanner>
        <button
          type="button"
          onClick={() => void load()}
          className="btn-glass px-4 py-1.5 text-sub font-medium"
        >
          重试
        </button>
      </div>
    ) : (
      <div className="space-y-2.5">
        <div className="h-[104px] animate-pulse rounded-xl bg-white/[0.04]" />
        <div className="h-[72px] animate-pulse rounded-xl bg-white/[0.04]" />
      </div>
    );
  }

  return (
    <div className="space-y-10">
      {!view.instance_ready &&
        (view.is_admin ? (
          <Banner
            tone="info"
            title="这台服务器还没有开启手机通知"
            action={
              <Link
                href="/settings/cloud"
                className="btn-accent inline-flex rounded-full px-4 py-1.5 text-sub font-semibold"
              >
                去开启
              </Link>
            }
          >
            连接 MovieClaw Cloud 就能用官方推送；自己打包的 App 可以在{" "}
            <Link href="/settings/app-push" className={LINK_CLASS}>
              App 推送
            </Link>{" "}
            里添加自建中继。下面的开关现在就能改，开启后立刻生效。
          </Banner>
        ) : (
          <Banner tone="info">管理员还没有开启手机通知，开启后这里的设置会立刻生效。</Banner>
        ))}

      {/* 自己有设备收不到才提示，逐台一句原因；设备的全貌在「设备」页 */}
      {view.attention.length > 0 && (
        <Banner
          tone="warn"
          title={`有 ${view.attention.length} 台设备收不到通知`}
          action={
            <Link href="/settings/devices" className="btn-glass inline-flex px-3 py-1.5 text-sub font-medium">
              查看设备
            </Link>
          }
        >
          <ul>
            {view.attention.map((item) => (
              <li key={item.device_id}>{attentionLine(item)}</li>
            ))}
          </ul>
        </Banner>
      )}

      {error && <ErrorBanner>{error}</ErrorBanner>}

      {groupEvents(view.events).map((group) => (
        <SettingsSection key={group.group} title={group.group}>
          <SettingsList>
            {group.items.map((event) => (
              <SettingsRow key={event.key} label={event.title} description={event.description}>
                <Toggle
                  checked={event.enabled}
                  label={`${event.title}通知`}
                  onChange={(next) => toggle(event.key, next)}
                />
              </SettingsRow>
            ))}
            {/* 「媒体库有新片」打开、而且能看到不止一个库时，就地选关心哪些库 */}
            {group.items.some((e) => e.key === LIBRARY_EVENT && e.enabled) &&
              view.libraries.length > 1 && (
                <LibraryPicker
                  libraries={view.libraries}
                  libraryIds={view.library_ids}
                  onPick={pickLibrary}
                />
              )}
          </SettingsList>
        </SettingsSection>
      ))}

      {view.muted_items && view.muted_items.length > 0 && (
        <MutedItems items={view.muted_items} onUnmute={(id) => void unmute(id)} />
      )}

      <SettingsSection title="测试">
        <SettingsList>
          <SettingsRow label="发送测试通知" description={testTargetHint(view.ready_devices)}>
            <button
              type="button"
              disabled={testing || view.ready_devices === 0}
              onClick={() => void sendTest()}
              className={SETTINGS_BUTTON_CLASS}
            >
              {testing ? "发送中…" : "发送"}
            </button>
          </SettingsRow>
        </SettingsList>
      </SettingsSection>
    </div>
  );
}

/**
 * 「媒体库有新片」下面的选库：每个库一行勾选框。默认「全部」（含以后新建的库），
 * 取消任何一个就变成明确的列表；全部勾上又回到「全部」。
 */
function LibraryPicker({
  libraries,
  libraryIds,
  onPick,
}: {
  libraries: MyPushLibrary[];
  libraryIds: number[] | null;
  onPick: (id: number, checked: boolean) => void;
}) {
  const all = libraryIds == null;
  return (
    <div className="px-4 pb-3 pt-2">
      <ul>
        {libraries.map((lib) => (
          <li key={lib.id}>
            <label className="-mx-1.5 flex cursor-pointer items-center gap-2.5 rounded-lg px-1.5 py-1.5 transition-colors hover:bg-white/[0.04]">
              <input
                type="checkbox"
                checked={libraryChecked(libraryIds, lib.id)}
                onChange={(e) => onPick(lib.id, e.target.checked)}
                className="size-4 shrink-0 accent-[var(--accent)]"
              />
              <span className="min-w-0 truncate text-sub text-[var(--text)]">{lib.name}</span>
            </label>
          </li>
        ))}
      </ul>
      <p className="mt-1 text-caption leading-5 text-[var(--text-faint)]">
        {all ? "全选时包括以后新建的库" : "只推勾上的库；全部勾上时也包括以后新建的库"}
      </p>
    </div>
  );
}

/** 「不再提醒」：长按通知选了「这部剧不再提醒」的片，一部一行，可以恢复 */
function MutedItems({
  items,
  onUnmute,
}: {
  items: MyPushMutedItem[];
  onUnmute: (id: number) => void;
}) {
  return (
    <SettingsSection
      title="不再提醒"
      description={`${items.length} 部作品`}
      footnote="在手机通知上长按选「这部剧不再提醒」的片。只是不推送，订阅照常下载。"
    >
      <SettingsList>
        {items.map((item) => (
          <SettingsRow
            key={item.id}
            label={
              <span className="block truncate">
                {item.title}
                {item.year != null && (
                  <span className="text-[var(--text-faint)]">（{item.year}）</span>
                )}
              </span>
            }
          >
            <button
              type="button"
              onClick={() => onUnmute(item.id)}
              className={SETTINGS_BUTTON_CLASS}
            >
              恢复
            </button>
          </SettingsRow>
        ))}
      </SettingsList>
    </SettingsSection>
  );
}
