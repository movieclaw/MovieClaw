/**
 * 后台自动同步（MV3 service worker）。
 *
 * 模型：用户在弹窗里对某站点点「立即同步」后，该站点即被【纳入管理】（记入 managedSites）。
 * 只要设置里的【全局自动同步开关】开着，被管理的站点一旦 Cookie 变化，后台就把最新
 * Cookie 推送到 MovieClaw，做到"已同步的站点始终保持最新"。
 *
 * MV3 生命周期与设计取舍：
 * - service worker 短命（空闲约 30 秒回收），但监听的事件会自动唤醒它，故监听器必须
 *   在顶层同步注册（本文件在 defineBackground 回调里注册即满足）。
 * - cookies.onChanged 触发极频繁，故用【内存缓存】(管理表 + 全局开关) 做快速过滤，
 *   命中后按站点【防抖】合并连续变化，避免打爆后端。
 * - 事件可能漏（浏览器关闭期间的变化、SW 冷启动窗口），再加两道兜底：启动时全量推、
 *   alarms 周期性全量推。
 *
 * 授权后接手同步：Firefox 里点「允许读取本站 Cookie」弹出权限提示会把弹窗关掉，弹窗里
 * 授权之后的代码根本不会执行（以前因此从没推过 Cookie）。弹窗在申请前把「授权意图」
 * 写进 storage，这里监听 permissions.onAdded，读到意图就替弹窗完成首次同步，并用图标
 * 角标报告结果（✓ 成功 / ! 失败）。弹窗若还活着（Chrome 通常如此），会先清掉意图自己同步，
 * 这里稍等片刻再取意图，避免重复推送。
 */

import {
  type BackendConfig,
  type ManagedSitesMap,
  clearPendingGrant,
  isConfigured,
  loadConfig,
  loadManagedSites,
  loadPendingGrant,
} from '../lib/config';
import { registrableDomain } from '../lib/domain';
import { hostsFromOrigins, isPendingGrantFresh, storeMatches } from '../lib/sync-logic';
import { syncSiteCookies } from '../lib/sync';

/** 防抖等待：合并这段时间内对同一站点的连续 Cookie 变化 */
const DEBOUNCE_MS = 2000;
/** 定时兜底的周期（分钟） */
const PERIODIC_MINUTES = 30;
const ALARM_NAME = 'movieclaw-periodic-sync';
/** 授权后等弹窗先接手的时间；弹窗已关闭时由后台完成同步 */
const GRANT_HANDOFF_MS = 1500;

export default defineBackground(() => {
  /** 每个可注册域名的防抖计时器 */
  const timers = new Map<string, ReturnType<typeof setTimeout>>();

  /** 内存缓存：已管理站点表 + 全局自动同步开关，减少高频事件下的 storage 读取 */
  let managedCache: ManagedSitesMap | null = null;
  let autoEnabledCache: boolean | null = null;

  async function getManaged(): Promise<ManagedSitesMap> {
    if (managedCache) return managedCache;
    managedCache = await loadManagedSites();
    return managedCache;
  }

  async function getAutoEnabled(): Promise<boolean> {
    if (autoEnabledCache !== null) return autoEnabledCache;
    autoEnabledCache = (await loadConfig()).autoSyncEnabled;
    return autoEnabledCache;
  }

  // storage 变化时刷新内存缓存，保证开关/管理表即时生效
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local') return;
    if (changes.managedSites) managedCache = (changes.managedSites.newValue as ManagedSitesMap) ?? {};
    if (changes.backendConfig) {
      autoEnabledCache = (changes.backendConfig.newValue as BackendConfig | undefined)?.autoSyncEnabled ?? true;
    }
  });

  /** 防抖调度：同一站点的连续变化只在安静 DEBOUNCE_MS 后推一次 */
  function schedule(domain: string) {
    const prev = timers.get(domain);
    if (prev) clearTimeout(prev);
    timers.set(
      domain,
      setTimeout(() => {
        timers.delete(domain);
        void pushDomain(domain);
      }, DEBOUNCE_MS),
    );
  }

  /** 读取某被管理站点的最新 Cookie 并推送到后端，结果记入 storage 供弹窗展示 */
  async function pushDomain(domain: string): Promise<void> {
    const config = await loadConfig();
    if (!isConfigured(config)) return;

    const entry = (await getManaged())[domain];
    if (!entry) return;

    try {
      await syncSiteCookies(config, {
        domain,
        host: entry.host,
        url: `https://${entry.host}/`,
        cookieStoreId: entry.cookieStoreId,
      });
      setBadge('none');
    } catch (err) {
      console.error('[MovieClaw] 自动同步失败：', domain, err);
      setBadge('error');
    }
  }

  /** 正在接手的域名：同一次授权可能分多次触发 onAdded（每个匹配模式一次），只处理一次 */
  const grantsInFlight = new Set<string>();

  /** 新获得站点权限：若有对应的授权意图（弹窗被权限提示关掉了），替弹窗完成首次同步 */
  async function onPermissionsAdded(origins: string[]): Promise<void> {
    const domains = [...new Set(hostsFromOrigins(origins).map(registrableDomain))].filter(
      (d) => !grantsInFlight.has(d),
    );
    if (!domains.length) return;
    domains.forEach((d) => grantsInFlight.add(d));
    try {
      await new Promise((resolve) => setTimeout(resolve, GRANT_HANDOFF_MS));
      for (const domain of domains) await takeOverGrant(domain);
    } finally {
      domains.forEach((d) => grantsInFlight.delete(d));
    }
  }

  async function takeOverGrant(domain: string): Promise<void> {
    const pending = await loadPendingGrant(domain);
    if (!pending) return; // 弹窗已接手，或不是从弹窗授权的
    await clearPendingGrant(domain);
    if (!isPendingGrantFresh(pending, Date.now())) return;
    const config = await loadConfig();
    if (!isConfigured(config)) return;
    try {
      await syncSiteCookies(config, pending);
      setBadge('ok');
    } catch (err) {
      console.error('[MovieClaw] 授权后同步失败：', domain, err);
      setBadge('error');
    }
  }

  /** 全量推送所有被管理站点（启动/定时兜底用；受全局开关约束） */
  async function syncAll(): Promise<void> {
    if (!(await getAutoEnabled())) return;
    const managed = await loadManagedSites();
    managedCache = managed;
    for (const domain of Object.keys(managed)) {
      await pushDomain(domain);
    }
  }

  /** 图标角标：出错红色「!」，授权后同步成功绿色「✓」（打开弹窗即清除），none 清除 */
  function setBadge(kind: 'none' | 'ok' | 'error'): void {
    chrome.action.setBadgeText({ text: kind === 'error' ? '!' : kind === 'ok' ? '✓' : '' });
    if (kind !== 'none') {
      chrome.action.setBadgeBackgroundColor({ color: kind === 'error' ? '#dc2626' : '#16a34a' });
    }
  }

  // ---- 事件注册（顶层同步注册，保证能唤醒 SW）----------------------------

  // 1) 实时：任意站点 Cookie 变化 → 全局开关开着且命中管理表则防抖推送
  chrome.cookies.onChanged.addListener((info) => {
    void (async () => {
      if (!(await getAutoEnabled())) return;
      const domain = registrableDomain(info.cookie.domain);
      const entry = (await getManaged())[domain];
      // 只响应同步时那个 cookie store 的变化（Firefox 容器标签页）
      if (entry && storeMatches(entry.cookieStoreId, info.cookie.storeId)) schedule(domain);
    })();
  });

  // 1b) 授权后接手：Firefox 弹窗被权限提示关掉时由这里完成首次同步
  chrome.permissions.onAdded.addListener((permissions) => {
    void onPermissionsAdded(permissions.origins ?? []);
  });

  // 1c) 弹窗申请授权前发来的唤醒消息：只为让后台（Firefox 事件页 / Chrome SW）提前醒着，
  //     意图本身已写入 storage，这里无需处理
  chrome.runtime.onMessage.addListener((message) => {
    if ((message as { type?: string } | undefined)?.type === 'movieclaw:grant-pending') return false;
    return undefined;
  });

  // 2) 兜底：浏览器启动时全量推一次（关闭期间 Cookie 可能已变）
  chrome.runtime.onStartup.addListener(() => void syncAll());

  // 3) 兜底：周期性全量推送，防止漏掉的事件累积成陈旧
  chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === ALARM_NAME) void syncAll();
  });

  // 安装/更新与每次 SW 启动时确保周期任务存在（同名 create 会覆盖，幂等）
  chrome.alarms.create(ALARM_NAME, { periodInMinutes: PERIODIC_MINUTES });
});
