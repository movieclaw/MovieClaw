/**
 * Cookie 读取工具：把某 URL 下的全部 Cookie 拼成请求头格式。popup 与 background 共用。
 *
 * 用 chrome.cookies.getAll（需目标站点 host 权限）能读到 httpOnly 会话 Cookie，
 * 这是页面 document.cookie 读不到的。
 *
 * storeId：Firefox 容器标签页（Multi-Account Containers）/隐私窗口的 Cookie 在独立的
 * cookie store 里，不带 storeId 只能读到默认 store（可能是空的或另一个账号的）。
 */

import { cookieQuery } from './sync-logic';

/** 读取指定 URL（及 cookie store）下的全部 Cookie，拼成 "name=value; name2=value2" 格式；无则返回空串。 */
export async function readCookieHeader(url: string, storeId?: string): Promise<{ header: string; count: number }> {
  const cookies = await chrome.cookies.getAll(cookieQuery(url, storeId));
  return { header: cookies.map((c) => `${c.name}=${c.value}`).join('; '), count: cookies.length };
}
