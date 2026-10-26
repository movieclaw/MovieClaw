/**
 * 同步状态的纯决策逻辑（不碰 chrome.* API，便于 `node --test` 直接测试）。
 *
 * 关键原则：按钮文案、"已同步"提示只看【本扩展】是否真的把 Cookie 推送成功过
 * （本地记录的 lastSuccessAt），不看后端站点记录是否存在——后端有站点记录不代表
 * 扩展推过 Cookie，以前按 `configured` 显示「重新同步」会让用户误以为已同步。
 */

/** 某站点最近一次同步结果（存于 storage.local 的 syncState[domain]）。 */
export interface SyncState {
  ok: boolean;
  /** 最近一次尝试的时间戳（ms） */
  at: number;
  /** 结果说明（成功站点名 / 失败原因） */
  message?: string;
  /** 最近一次【成功】推送的时间戳；失败的尝试不会清掉它 */
  lastSuccessAt?: number;
  /** 最近一次成功时命中的站点展示名 */
  siteName?: string;
}

/**
 * 授权意图：弹窗展示「允许读取本站 Cookie」时先落库。Firefox 弹出权限提示会关掉弹窗，
 * 授权后的代码不会执行；后台在 permissions.onAdded 里据此替弹窗把同步做完，
 * 弹窗重开时也据此补做一次。
 */
export interface PendingGrant {
  domain: string;
  host: string;
  /** 读取 Cookie 用的页面 URL（保留协议） */
  url: string;
  /** Firefox 容器标签页的 cookieStoreId；Chrome 无此字段 */
  cookieStoreId?: string;
  at: number;
}

/** 授权意图的有效期：超过即视为放弃，不再自动同步 */
export const PENDING_GRANT_TTL_MS = 30 * 60 * 1000;

/** 最近一次成功推送的时间；兼容旧版本只记了 ok/at 的数据（旧版只在推送成功后记 ok:true）。 */
export function lastSuccessAt(state: SyncState | undefined): number | undefined {
  if (!state) return undefined;
  return state.lastSuccessAt ?? (state.ok ? state.at : undefined);
}

/** 本扩展是否成功推送过该站点的 Cookie */
export function hasPushed(state: SyncState | undefined): boolean {
  return lastSuccessAt(state) !== undefined;
}

/** 主按钮文案：推送成功过才叫「重新同步」 */
export function syncActionLabel(state: SyncState | undefined): '立即同步' | '重新同步' {
  return hasPushed(state) ? '重新同步' : '立即同步';
}

/** 写入新一次结果时保留上次成功时间（失败不覆盖成功记录） */
export function mergeSyncState(prev: SyncState | undefined, next: SyncState): SyncState {
  if (next.ok) {
    return { ...next, lastSuccessAt: next.at, siteName: next.siteName ?? prev?.siteName };
  }
  const success = lastSuccessAt(prev);
  return {
    ...next,
    ...(success !== undefined ? { lastSuccessAt: success } : {}),
    ...(prev?.siteName ? { siteName: prev.siteName } : {}),
  };
}

export function isPendingGrantFresh(pending: PendingGrant | undefined | null, now: number): boolean {
  return Boolean(pending && now - pending.at >= 0 && now - pending.at <= PENDING_GRANT_TTL_MS);
}

/**
 * 弹窗打开（已授权、已读到 Cookie）时是否自动同步一次：
 * - 有新鲜的授权意图（刚授权、弹窗被关掉、后台没接手成功）→ 同步；
 * - 本扩展从未推送成功过，且没有失败记录 → 同步（补上"授权了却从没推过"的情况）；
 * - 已推送过，或上次失败了 → 不自动（失败时展示错误，让用户手动重试，避免每次打开都重试）。
 */
export function shouldAutoSync(input: {
  cookieCount: number;
  state: SyncState | undefined;
  pending: PendingGrant | undefined | null;
  now: number;
}): boolean {
  if (input.cookieCount <= 0) return false;
  if (isPendingGrantFresh(input.pending, input.now)) return true;
  if (hasPushed(input.state)) return false;
  if (input.state && !input.state.ok) return false;
  return true;
}

/** cookies.getAll 的查询：有 cookieStoreId（Firefox 容器/隐私窗口）就带上，否则只按 URL */
export function cookieQuery(url: string, storeId?: string | null): { url: string; storeId?: string } {
  return storeId ? { url, storeId } : { url };
}

/**
 * 后台 cookies.onChanged 过滤：被管理站点记了同步时用的 cookie store，就只响应该 store 的变化；
 * 任一方没有 store 信息（Chrome / 旧数据）时不过滤。
 */
export function storeMatches(managedStoreId?: string, changedStoreId?: string): boolean {
  if (!managedStoreId || !changedStoreId) return true;
  return managedStoreId === changedStoreId;
}

/** 从 permissions.onAdded 给出的匹配模式里取主机名，如 `*://*.m-team.cc/*` → m-team.cc */
export function hostsFromOrigins(origins: readonly string[]): string[] {
  const hosts = new Set<string>();
  for (const origin of origins) {
    const m = /^[^:]+:\/\/([^/]+)\//.exec(origin);
    if (!m) continue;
    const host = m[1].replace(/^\*\./, '').split(':', 1)[0];
    if (!host || host.includes('*')) continue;
    hosts.add(host);
  }
  return [...hosts];
}

/** 时间展示：相对时间 + 具体时刻 */
export function formatPushTime(at: number, now: number): string {
  const d = new Date(at);
  const pad = (n: number) => String(n).padStart(2, '0');
  const clock = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const min = Math.floor((now - at) / 60000);
  if (min < 1) return `刚刚 ${clock}`;
  if (min < 60) return `${min} 分钟前 ${clock}`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr} 小时前 ${clock}`;
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${clock}`;
}
