/**
 * 推送一个站点的 Cookie 到 MovieClaw：读取 → POST /extension/cookies → 纳入管理 → 记录结果。
 * popup（立即同步 / 自动补同步）与 background（授权后接手、自动同步）共用同一条路径。
 */

import { api, hasBackendPermission } from './api';
import { type BackendConfig, recordSyncState, setManagedSite } from './config';
import { readCookieHeader } from './cookies';

export interface SyncTarget {
  /** 可注册域名（storage 键） */
  domain: string;
  /** 精确主机名，推给后端用于匹配站点 */
  host: string;
  /** 读取 Cookie 的页面 URL */
  url: string;
  /** Firefox 容器标签页的 cookie store */
  cookieStoreId?: string;
}

export interface SyncOutcome {
  displayName: string;
  cookieCount: number;
  at: number;
}

/** 成功返回结果；失败把原因记入同步状态后抛出（错误信息即可直接展示给用户）。 */
export async function syncSiteCookies(config: BackendConfig, target: SyncTarget): Promise<SyncOutcome> {
  try {
    // 只检查不申请：可能运行在后台或 await 之后，已不是用户手势；后端权限在保存设置时已申请
    if (!(await hasBackendPermission(config.backendUrl))) {
      throw new Error('未授权访问后端地址，请到设置里重新保存');
    }
    const { header, count } = await readCookieHeader(target.url, target.cookieStoreId);
    if (!count) throw new Error('未读到 Cookie（可能尚未登录或已退出登录）');

    const result = await api.pushCookies(config, target.host, header);
    // 纳入管理：全局自动同步开着时，后台会随 Cookie 变化保持它最新（沿用同一 cookie store）
    await setManagedSite(target.domain, {
      host: target.host,
      siteId: result.site_id,
      displayName: result.display_name,
      ...(target.cookieStoreId ? { cookieStoreId: target.cookieStoreId } : {}),
    });
    const at = Date.now();
    await recordSyncState(target.domain, {
      ok: true,
      at,
      message: `已同步到 ${result.display_name}`,
      siteName: result.display_name,
    });
    return { displayName: result.display_name, cookieCount: count, at };
  } catch (err) {
    const message = (err as Error).message || String(err);
    await recordSyncState(target.domain, { ok: false, at: Date.now(), message });
    throw new Error(message);
  }
}
