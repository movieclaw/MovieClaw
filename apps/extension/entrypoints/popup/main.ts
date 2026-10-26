/**
 * Popup 逻辑：单弹窗内含「主视图（授权 + 立即同步）」与「设置视图（后端连接 + 全局自动同步）」。
 *
 * 设计要点（回应易用性反馈）：
 * - 设置随时可进：顶栏齿轮进入设置视图，不依赖当前站点、也不跳转到 chrome://extensions。
 * - 保存即时反馈：设置保存后就地提示并自动返回主视图；顶栏常驻「已连接/未配置」状态。
 * - 每个站点的核心动作只有：授权本站 → 立即同步（不再提供"复制"）。
 * - 自动同步是全局开关：同步过的站点自动纳入管理，后台随 Cookie 变化保持最新。
 *
 * 读取 Cookie 需目标站点 host 权限（可选权限，按站点申请）；访问后端需后端源 host 权限
 * （保存/测试时申请）。出于安全，不展示 Cookie 明文，仅展示条数。
 *
 * 授权 → 同步必须能在弹窗被关掉后完成：Firefox 弹出权限提示会关闭弹窗，授权之后的代码
 * 不会执行。因此展示「允许读取本站 Cookie」时先把授权意图写入 storage，由后台在
 * permissions.onAdded 里接手同步；弹窗重开时若本扩展从未推送成功过，也会自动补同步一次。
 * 「重新同步」只在本扩展真的推送成功过之后出现（看本地记录，不看后端是否已有站点记录）。
 */

import { api, requestBackendPermission, type ExtensionSiteView } from '../../lib/api';
import {
  type BackendConfig,
  clearPendingGrant,
  isConfigured,
  loadConfig,
  loadPendingGrant,
  loadSyncState,
  saveConfig,
  savePendingGrant,
} from '../../lib/config';
import { readCookieHeader } from '../../lib/cookies';
import { registrableDomain } from '../../lib/domain';
import {
  type PendingGrant,
  type SyncState,
  formatPushTime,
  lastSuccessAt,
  shouldAutoSync,
  syncActionLabel,
} from '../../lib/sync-logic';
import { syncSiteCookies } from '../../lib/sync';

// —— DOM 引用 ——
const $connChip = document.getElementById('conn-chip') as HTMLSpanElement;
const $gearBtn = document.getElementById('gear-btn') as HTMLButtonElement;
const $backBtn = document.getElementById('back-btn') as HTMLButtonElement;
const $viewMain = document.getElementById('view-main') as HTMLElement;
const $viewSettings = document.getElementById('view-settings') as HTMLElement;

const $avatar = document.getElementById('site-avatar') as HTMLDivElement;
const $siteName = document.getElementById('site-name') as HTMLDivElement;
const $siteUrl = document.getElementById('site-url') as HTMLDivElement;
const $status = document.getElementById('cookie-status') as HTMLDivElement;
const $statusText = document.getElementById('cookie-status-text') as HTMLSpanElement;
const $actionBtn = document.getElementById('action-btn') as HTMLButtonElement;
const $actionLabel = document.getElementById('action-label') as HTMLSpanElement;
const $hint = document.getElementById('hint') as HTMLParagraphElement;

const $backendUrl = document.getElementById('backend-url') as HTMLInputElement;
const $syncToken = document.getElementById('sync-token') as HTMLInputElement;
const $autosyncToggle = document.getElementById('autosync-toggle') as HTMLInputElement;
const $saveBtn = document.getElementById('save-btn') as HTMLButtonElement;
const $settingsStatus = document.getElementById('settings-status') as HTMLParagraphElement;

// —— 状态 ——
type ActionMode = 'none' | 'grant' | 'sync' | 'go-settings';
let actionMode: ActionMode = 'none';

interface TabInfo {
  url: string;
  hostname: string;
  origin: string;
  favIconUrl?: string;
  /** Firefox 容器标签页 / 隐私窗口的 cookie store；Chrome 的 Tab 没有这个字段 */
  cookieStoreId?: string;
}
let tab: TabInfo | null = null; // null = 非 http(s) 页面
let config: BackendConfig = { backendUrl: '', syncToken: '', autoSyncEnabled: true };
let matchedSite: ExtensionSiteView | null = null;
/** 弹窗自己正在推送时，忽略 storage 变化触发的重绘 */
let syncing = false;

// —— 通用 UI 设置 ——
function setConn(text: string, kind: 'ok' | 'warn' | 'error' | 'neutral') {
  $connChip.textContent = text;
  $connChip.className = `conn-chip conn-${kind}`;
}

function setStatus(text: string, kind: 'neutral' | 'ok' | 'warn') {
  $statusText.textContent = text;
  $status.className = `pill pill-${kind}`; // 覆盖式赋值天然清掉 hidden
}

/** 隐藏 Cookie 状态徽标（当前站点没有值得展示的正文状态时，只留顶部连接徽标） */
function hidePill() {
  $status.classList.add('hidden');
}

function setHint(text: string, kind: 'info' | 'ok' | 'error' = 'info') {
  $hint.textContent = text;
  $hint.dataset.kind = kind;
}

/** 显示主按钮并设定其动作与文案 */
function showAction(mode: ActionMode, label: string, disabled = false) {
  actionMode = mode;
  $actionLabel.textContent = label;
  $actionBtn.disabled = disabled;
  $actionBtn.classList.remove('hidden');
}

/** 隐藏主按钮（当前站点无可执行动作时） */
function hideAction() {
  actionMode = 'none';
  $actionBtn.classList.add('hidden');
}

function registrablePatterns(hostname: string): string[] {
  const domain = registrableDomain(hostname);
  return [`*://${domain}/*`, `*://*.${domain}/*`];
}

function renderAvatar(hostname: string, favIconUrl?: string) {
  if (favIconUrl) {
    const img = new Image();
    img.src = favIconUrl;
    img.alt = '';
    img.onload = () => {
      $avatar.textContent = '';
      $avatar.appendChild(img);
    };
    img.onerror = () => {
      $avatar.textContent = hostname.charAt(0).toUpperCase();
    };
  } else {
    $avatar.textContent = hostname.charAt(0).toUpperCase();
  }
}

// —— 视图切换 ——
function showSettings() {
  $backendUrl.value = config.backendUrl;
  $syncToken.value = config.syncToken;
  $autosyncToggle.checked = config.autoSyncEnabled;
  $settingsStatus.textContent = '';
  $viewMain.classList.add('hidden');
  $viewSettings.classList.remove('hidden');
  $gearBtn.classList.add('hidden');
  $backBtn.classList.remove('hidden');
}

function showMain() {
  $viewSettings.classList.add('hidden');
  $viewMain.classList.remove('hidden');
  $backBtn.classList.add('hidden');
  $gearBtn.classList.remove('hidden');
}

// —— 主流程 ——
async function init() {
  config = await loadConfig();
  // 后台授权后同步成功打的 ✓ 角标，用户打开弹窗即视为已读（错误角标保留）
  if ((await chrome.action.getBadgeText({})) === '✓') void chrome.action.setBadgeText({ text: '' });

  const [activeTab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (activeTab?.url && /^https?:/.test(activeTab.url)) {
    const url = new URL(activeTab.url);
    tab = {
      url: activeTab.url,
      hostname: url.hostname,
      origin: url.origin,
      favIconUrl: activeTab.favIconUrl,
      cookieStoreId: (activeTab as { cookieStoreId?: string }).cookieStoreId,
    };
    $siteName.textContent = url.hostname;
    $siteUrl.textContent = url.origin;
    renderAvatar(url.hostname, activeTab.favIconUrl);
  } else {
    tab = null;
    $avatar.textContent = '—';
    $siteName.textContent = '不支持的页面';
    $siteUrl.textContent = '';
  }

  await refresh();
}

/** 核心解析：根据后端连接与当前站点，决定连接徽标、Cookie 状态与主按钮 */
async function refresh() {
  // 1) 后端连接状态（顺带取支持的站点列表）
  let sites: ExtensionSiteView[] | null = null;
  if (!isConfigured(config)) {
    setConn('未配置', 'warn');
  } else {
    setConn('连接中…', 'neutral');
    try {
      sites = await api.listSites(config);
      setConn('已连接', 'ok');
    } catch {
      // 连接失败：主区只留顶部连接徽标，不在正文重复报错
      setConn('后端未连接', 'error');
      hidePill();
      hideAction();
      setHint('');
      return;
    }
  }

  // 2) 非 http(s) 页面：无可同步对象
  if (!tab) {
    hidePill();
    if (!isConfigured(config)) showAction('go-settings', '去设置后端');
    else hideAction();
    setHint('请在站点网页上打开本扩展。');
    return;
  }

  // 3) 未配置后端：引导去设置
  if (!isConfigured(config)) {
    hidePill();
    showAction('go-settings', '去设置后端');
    setHint('先在设置里填后端地址与令牌。');
    return;
  }

  // 4) 已连接：判断当前站点是否受支持
  const domain = registrableDomain(tab.hostname);
  matchedSite = sites?.find((s) => s.domain === domain) ?? null;
  if (!matchedSite) {
    setStatus('该站点不支持同步', 'neutral');
    hideAction();
    setHint('MovieClaw 未收录该站点。');
    return;
  }

  // 5) 是否已授权读取本站？
  const authorized = await chrome.permissions.contains({
    origins: registrablePatterns(tab.hostname),
  });
  if (!authorized) {
    // 先记下授权意图：Firefox 弹权限提示会关掉弹窗，后台据此在授权后接手同步
    await savePendingGrant(pendingGrantFor(tab));
    setStatus('需要授权访问本站', 'neutral');
    showAction('grant', '允许读取本站 Cookie');
    setHint('首次读取需授权，仅本站生效。');
    return;
  }

  // 6) 已授权：读取 Cookie
  await readAndOfferSync();
}

function pendingGrantFor(t: TabInfo): PendingGrant {
  return {
    domain: registrableDomain(t.hostname),
    host: t.hostname,
    url: t.url,
    cookieStoreId: t.cookieStoreId,
    at: Date.now(),
  };
}

/** 按本地同步记录给出按钮与提示：只有本扩展推送成功过才显示「重新同步」 */
function renderSyncState(state: SyncState | undefined) {
  showAction('sync', syncActionLabel(state));
  const success = lastSuccessAt(state);
  if (state && !state.ok) {
    const lastOk = success ? `（上次成功：${formatPushTime(success, Date.now())}）` : '';
    setHint(`同步失败：${state.message ?? '未知错误'}${lastOk}`, 'error');
  } else if (success) {
    setHint(successHint(state?.siteName, success), 'ok');
  } else {
    setHint(matchedSite?.configured ? '后台已有该站点，但本扩展尚未推送过 Cookie。' : '尚未同步。');
  }
}

function successHint(siteName: string | undefined, at: number): string {
  const time = formatPushTime(at, Date.now());
  const auto = config.autoSyncEnabled ? '后续自动保持最新' : '自动同步未开启';
  return `✓ ${siteName ? `已同步到 ${siteName}` : '已同步'}（${time}），${auto}。`;
}

/** 读取当前站点 Cookie，给出「立即同步 / 重新同步」按钮；必要时（或 forceSync）自动同步一次 */
async function readAndOfferSync(forceSync = false) {
  if (!tab) return;
  const domain = registrableDomain(tab.hostname);
  let count = 0;
  try {
    count = (await readCookieHeader(tab.url, tab.cookieStoreId)).count;
  } catch (err) {
    console.error('[MovieClaw] 读取 Cookie 失败：', err);
    setStatus('读取失败', 'warn');
    hideAction();
    setHint((err as Error).message, 'error');
    return;
  }
  if (count === 0) {
    setStatus('未检测到 Cookie', 'warn');
    hideAction();
    setHint('可能尚未登录该站点，请先登录后再试。');
    return;
  }
  const inContainer = Boolean(tab.cookieStoreId && tab.cookieStoreId !== 'firefox-default');
  setStatus(`已读取 ${count} 条 Cookie${inContainer ? '（容器标签页）' : ''}`, 'ok');

  const state = (await loadSyncState())[domain];
  const pending = await loadPendingGrant(domain);
  if (forceSync || shouldAutoSync({ cookieCount: count, state, pending, now: Date.now() })) {
    // 授权了但从没推送成功过（多半是 Firefox 授权时弹窗被关掉）→ 自动补同步一次
    await syncNow();
    return;
  }
  renderSyncState(state);
}

/** 申请当前站点 host 权限（用户手势中调用） */
async function grantSite() {
  if (!tab) return;
  const domain = registrableDomain(tab.hostname);
  try {
    // Firefox 只认用户手势里【同步】发起的 permissions.request，所以它必须是第一个调用
    const request = chrome.permissions.request({ origins: registrablePatterns(tab.hostname) });
    // 刷新授权意图并唤醒后台：权限提示可能马上关掉弹窗，之后由后台接手同步
    void savePendingGrant(pendingGrantFor(tab));
    chrome.runtime.sendMessage({ type: 'movieclaw:grant-pending' }).catch(() => {});
    const granted = await request;
    if (!granted) {
      setHint('已取消授权，点按钮可再次尝试。');
      return;
    }
    // 弹窗还活着（Chrome 通常如此）：清掉意图自己同步，后台见不到意图就不会重复推
    await clearPendingGrant(domain);
    await readAndOfferSync(true);
  } catch (err) {
    setHint(`申请权限失败：${(err as Error).message}`, 'error');
  }
}

/** 立即同步：推送当前 Cookie，并把该站点纳入自动同步管理 */
async function syncNow() {
  if (!tab || !matchedSite || syncing) return;
  const domain = registrableDomain(tab.hostname);
  syncing = true;
  showAction('sync', '同步中…', true);
  setHint('正在同步到 MovieClaw…');
  try {
    await clearPendingGrant(domain);
    const result = await syncSiteCookies(config, {
      domain,
      host: tab.hostname,
      url: tab.url,
      cookieStoreId: tab.cookieStoreId,
    });
    setStatus(`已同步到 ${result.displayName}`, 'ok');
    showAction('sync', '重新同步');
    setHint(successHint(result.displayName, result.at), 'ok');
  } catch (err) {
    console.error('[MovieClaw] 同步失败：', err);
    renderSyncState((await loadSyncState())[domain]);
  } finally {
    syncing = false;
  }
}

function onAction() {
  if (actionMode === 'grant') void grantSite();
  else if (actionMode === 'sync') void syncNow();
  else if (actionMode === 'go-settings') showSettings();
}

// —— 设置视图逻辑 ——
function readForm(): BackendConfig {
  return {
    backendUrl: $backendUrl.value.trim().replace(/\/+$/, ''),
    syncToken: $syncToken.value.trim(),
    autoSyncEnabled: $autosyncToggle.checked,
  };
}

function validate(c: BackendConfig): string | null {
  if (!c.backendUrl) return '请填写后端地址';
  try {
    new URL(c.backendUrl);
  } catch {
    return '后端地址格式不正确，请以 http:// 或 https:// 开头';
  }
  if (!c.syncToken) return '请填写同步令牌';
  return null;
}

function setSettingsStatus(text: string, kind: 'info' | 'ok' | 'error' = 'info') {
  $settingsStatus.textContent = text;
  $settingsStatus.dataset.kind = kind;
}

/** 保存 = 先连一次做校验，通过才落库；失败则不保存并提示原因（测试与保存合并） */
async function onSave() {
  const form = readForm();
  const err = validate(form);
  if (err) return setSettingsStatus(err, 'error');
  $saveBtn.disabled = true;
  setSettingsStatus('正在连接…');
  try {
    // 第一个异步操作就是申请权限（Firefox 只认用户手势里同步发起的 permissions.request）
    if (!(await requestBackendPermission(form.backendUrl))) {
      setSettingsStatus('未授权访问该地址', 'error');
      return;
    }
    await api.ping(form); // 连接校验；失败抛错 → 不保存
    await saveConfig(form);
    config = form;
    setSettingsStatus('✓ 已连接并保存', 'ok');
    // 稍作停留让用户看到反馈，然后返回主视图并刷新状态
    setTimeout(() => {
      showMain();
      void refresh();
    }, 700);
  } catch (e) {
    setSettingsStatus((e as Error).message, 'error');
  } finally {
    $saveBtn.disabled = false;
  }
}

// —— 事件绑定 ——
$actionBtn.addEventListener('click', onAction);
$gearBtn.addEventListener('click', showSettings);
$backBtn.addEventListener('click', () => {
  showMain();
  void refresh();
});
$saveBtn.addEventListener('click', () => void onSave());
// 后台（授权后接手 / 自动同步）写入结果时，弹窗开着就即时更新
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !changes.syncState || syncing || !tab || actionMode !== 'sync') return;
  const state = (changes.syncState.newValue as Record<string, SyncState> | undefined)?.[registrableDomain(tab.hostname)];
  if (state) renderSyncState(state);
});

void init();
