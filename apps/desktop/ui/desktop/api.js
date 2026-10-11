// MovieClaw Desktop — API client
// Uses Rust proxy command (proxy_api) for cookie-aware, CORS-free requests

class APIError extends Error {
  constructor(message, { status = 0, code = '', body = null, headers = {} } = {}) {
    super(message);
    this.name = 'APIError';
    this.status = status;
    this.code = code;
    this.body = body;
    this.headers = headers;
  }
}

const API = {
  baseUrl: '',
  contextEpoch: 0,
  _pending: new Map(),
  _requestSequence: 0,

  scope(signal) {
    return Object.assign(Object.create(this), { defaultSignal: signal });
  },

  invalidateContext() {
    this.contextEpoch++;
    this._preconnectAt = 0;
    for (const cancel of this._pending.values()) cancel();
  },

  async init() {
    const sequence = this._initSequence = (this._initSequence || 0) + 1;
    let url = window.__MOVIECLAW_SERVER__ || '';
    if (window.__TAURI__) {
      try {
        url = await window.__TAURI__.core.invoke('get_server_url');
      } catch (e) {
        throw new APIError('无法读取服务器配置：' + (e.message || e), { code: 'CONFIG_UNAVAILABLE' });
      }
    }
    if (sequence !== this._initSequence) return;
    const next = (url || '').replace(/\/+$/, '');
    if (this.baseUrl !== next) this.invalidateContext();
    this.baseUrl = next;
    window.__MOVIECLAW_SERVER__ = next;
    await window.__TAURI__?.core.invoke('native_ready').catch(() => {});
  },

  // 通过 proxy_api 的 /__image__ 路径加载需要认证的图片，返回 data URI
  async proxyImage(pathOrUrl) {
    try {
      // 补全相对路径的 /api/v1 前缀（API 返回的路径不带 /api/v1）
      let fullPath = pathOrUrl;
      if (!pathOrUrl.startsWith('http') && !pathOrUrl.startsWith('/api/')) {
        fullPath = '/api/v1' + (pathOrUrl.startsWith('/') ? pathOrUrl : '/' + pathOrUrl);
      }
      const encoded = encodeURIComponent(fullPath);
      const result = await this.rawFetch('/__image__?url=' + encoded);
      const body = await result.text();
      if (result.status === 200 && body.startsWith('data:image/')) {
        return body;
      }
      return '';
    } catch (e) {
      console.warn('[API] image request failed', { name: e?.name || 'Error', status: e?.status || 0 });
      return '';
    }
  },

  // 通过 Rust proxy_api 命令发送请求（自动 Cookie，绕过 CORS，无 URL scope 限制）
  async rawFetch(path, options = {}) {
    const started = window.performance?.now();
    const method = (options.method || 'GET').toUpperCase();
    const body = options.body || null;
    const signal = options.signal || this.defaultSignal;
    const requestId = 'desktop-' + Date.now() + '-' + (++API._requestSequence);
    // Session creation is a side effect: its late response must reach the player so it can release it.
    const cancelable = options.cancelable ?? (method === 'GET' || method === 'HEAD');
    const epoch = API.contextEpoch;
    if (cancelable && signal?.aborted) throw new DOMException('请求已取消', 'AbortError');
    let timer;
    let abort;
    try {
      const pending = window.__TAURI__.core.invoke('proxy_api', {
        method,
        path,
        body: body || null,
        headers: options.headers || {},
        requestId,
      });
      const canceled = new Promise((_, reject) => {
        abort = () => {
          window.__TAURI__.core.invoke('cancel_proxy_request', { requestId }).catch(() => {});
          reject(new DOMException('请求已取消', 'AbortError'));
        };
        if (cancelable) {
          API._pending.set(requestId, abort);
          signal?.addEventListener('abort', abort, { once: true });
        }
        const timeout = options.timeoutMs ?? 20000;
        if (timeout > 0) timer = setTimeout(() => {
          if (cancelable) window.__TAURI__.core.invoke('cancel_proxy_request', { requestId }).catch(() => {});
          reject(new APIError('连接服务器超时，请检查网络后重试', { code: 'TIMEOUT' }));
        }, timeout);
      });
      const result = await Promise.race([pending, canceled]);
      if (cancelable && (signal?.aborted || epoch !== API.contextEpoch)) throw new DOMException('请求已取消', 'AbortError');
      const headerValues = result.headers || {};
      const headers = new Headers(headerValues);
      if (started != null) window.MovieClawPerf?.network(path, window.performance.now() - started, headers.get('server-timing'));
      return {
        ok: result.status >= 200 && result.status < 300,
        status: result.status,
        headers,
        text: async () => result.body,
        json: async () => JSON.parse(result.body),
      };
    } catch (e) {
      if (e.name === 'AbortError' || e instanceof APIError) throw e;
      throw new APIError('网络请求失败：' + (e.message || e), { code: 'NETWORK_ERROR' });
    } finally {
      clearTimeout(timer);
      API._pending.delete(requestId);
      signal?.removeEventListener('abort', abort);
    }
  },

  async request(path, options = {}) {
    const method = (options.method || 'GET').toUpperCase();
    let body = options.body;

    // body 已经是对象则序列化为 JSON
    if (body && typeof body !== 'string') {
      body = JSON.stringify(body);
    }

    // Cookie mutations must fully settle in Rust before UI identity can recover or change again.
    const timeoutMs = options.timeoutMs ?? (path.startsWith('/auth/') && method !== 'GET' && method !== 'HEAD' ? 0 : undefined);
    const res = await this.rawFetch(path, { ...options, timeoutMs, method, body });

    if (res.status === 204) return null;

    const text = await res.text();
    let data;
    try { data = JSON.parse(text); } catch { data = text; }

    if (!res.ok) {
      const msg = (data && data.message) || (typeof data?.detail === 'string' ? data.detail : '') || `请求失败（HTTP ${res.status}）`;
      const error = new APIError(msg, { status: res.status, code: data?.code || '', body: data, headers: res.headers });
      if (res.status === 401 && !path.startsWith('/auth/')) API.onUnauthorized?.(error);
      throw error;
    }
    return data;
  },

  // ===== 媒体库 =====
  listLibraries() {
    return this.request('/libraries');
  },

  getUiPreferences() { return this.request('/ui/preferences'); },
  saveUiPreferences(body) { return this.request('/ui/preferences', { method: 'PUT', body }); },
  listKindItems(kind, params = {}) { return this.request(`/libraries/kinds/${encodeURIComponent(kind)}/items?${new URLSearchParams(params)}`); },
  listKindGenres(kind) { return this.request(`/libraries/kinds/${encodeURIComponent(kind)}/genres`); },

  getLibrary(id) {
    return this.request(`/libraries/${id}`);
  },

  listLibraryItems(libraryId, params = {}) {
    const qs = new URLSearchParams(params).toString();
    return this.request(`/libraries/${libraryId}/items${qs ? '?' + qs : ''}`);
  },

  getItemDetail(libraryId, itemId) {
    return this.request(`/libraries/${libraryId}/items/${itemId}`);
  },

  getItemEpisodes(libraryId, itemId, seasonNumber) {
    const qs = seasonNumber != null ? `?season_number=${seasonNumber}` : '';
    return this.request(`/libraries/${libraryId}/items/${itemId}/episodes${qs}`);
  },

  subtitlePreview(fileId, options, signal) {
    const query = new URLSearchParams();
    for (const key of ['target_language', 'secondary_language', 'source_candidate_key']) {
      if (options[key]) query.set(key, options[key]);
    }
    return this.request(`/libraries/files/${fileId}/subtitles/generation-preview?${query}`, { signal });
  },
  generateSubtitles(fileId, body) {
    return this.request(`/libraries/files/${fileId}/subtitles/generations`, { method: 'POST', body });
  },
  subtitleJobs(fileId) {
    return this.request('/jobs?' + new URLSearchParams({ job_type: 'subtitle.generate', resource_type: 'library_file', resource_id: fileId, limit: 20 }));
  },
  getJob(id) { return this.request(`/jobs/${encodeURIComponent(id)}`); },
  cancelJob(id) { return this.request(`/jobs/${encodeURIComponent(id)}/cancel`, { method: 'POST' }); },
  retryJob(id) { return this.request(`/jobs/${encodeURIComponent(id)}/retry`, { method: 'POST' }); },
  llmProviders() { return this.request('/llm/providers'); },

  // ===== 合集 =====
  listCollections() {
    return this.request('/collections');
  },

  getCollection(id) {
    return this.request(`/collections/${id}`);
  },

  listCollectionItems(id, params = {}) {
    const qs = new URLSearchParams(params).toString();
    return this.request(`/collections/${id}/items${qs ? '?' + qs : ''}`);
  },

  // 系列合集：「已有 N / 共 M」与逐部缺片名单（详情页的作品系列行）
  getCollectionSeries(id) {
    return this.request(`/collections/${id}/series`);
  },

  // ===== 搜索 =====
  search(query, params = {}) {
    const search = new URLSearchParams({ q: query });
    for (const [key, value] of Object.entries(params)) {
      for (const entry of Array.isArray(value) ? value : [value]) search.append(key, entry);
    }
    const qs = search.toString();
    return this.request(`/search/library?${qs}`);
  },

  // ===== 人物 =====
  getPerson(personId) {
    return this.request(`/people/${personId}`);
  },

  // ===== 播放 =====
  // 注意：此方法为备用接口，主要播放入口在 app.js 的 startPlayback
  startPlaybackSession(body) {
    return this.request('/playback/sessions', { method: 'POST', body });
  },

  // 预连：详情页一出现就把到服务器的连接建好，点播放时会话 POST 不必再付一次冷握手。
  // 对齐 macOS PlaybackPreconnect.warm（20 秒内合并，别每次进详情都打一发）。
  // GET 不是 HEAD：服务端 /api/v1/health 只注册了 GET，FastAPI 不会自动补 HEAD
  preconnectPlayback() {
    const now = Date.now();
    if (this._preconnectAt && now - this._preconnectAt < 20000) return;
    this._preconnectAt = now;
    this.request('/health').catch(() => {});
  },

  // 进度上报
  // POST /playback/progress body: { media_item_id, event, position_ms, duration_ms, season_number?, episode_number? }
  // event: "start" | "progress" | "stop"
  reportProgress(mediaItemId, event, positionMs, durationMs, seasonNumber, episodeNumber, extras = {}, options = {}) {
    const body = {
      media_item_id: mediaItemId,
      event,
      position_ms: positionMs,
    };
    if (durationMs != null) body.duration_ms = durationMs;
    if (seasonNumber != null) body.season_number = seasonNumber;
    if (episodeNumber != null) body.episode_number = episodeNumber;
    for (const key of ['audio_track', 'subtitle_track', 'file_id', 'paused', 'device_id']) {
      if (extras[key] != null) body[key] = extras[key];
    }
    return this.request('/playback/progress', { ...options, method: 'POST', body });
  },

  // 续播位置
  getResume(mediaItemId, seasonNumber, episodeNumber) {
    const params = new URLSearchParams({ media_item_id: mediaItemId });
    if (seasonNumber != null) params.set('season_number', seasonNumber);
    if (episodeNumber != null) params.set('episode_number', episodeNumber);
    return this.request(`/playback/resume?${params}`);
  },

  // 会话保活
  sessionPing(sessionId) {
    return this.request(`/playback/sessions/${sessionId}/ping`, { method: 'POST' });
  },

  // 会话结束
  // 服务端是 DELETE /playback/sessions/{id}（playback.py stop_playback_session）；
  // 原先 POST .../stop 恒 405，会话只能等 180s 空闲回收，直通槽位被占满后 503
  sessionStop(sessionId) {
    return this.request(`/playback/sessions/${sessionId}`, { method: 'DELETE' });
  },

  // 播放策略增量保存（PUT /playback/policy，playback.py save_playback_policy）。
  // 同意弹窗只翻 software_transcode_enabled 一个开关，未带的字段保持原值。
  // 只有超管能存（require_admin）——同 macOS playbackPolicySet
  playbackPolicySet(body) {
    return this.request('/playback/policy', { method: 'PUT', body });
  },

  // 继续观看列表
  getUpNext() {
    return this.request('/playback/up-next');
  },

  // 收藏列表
  getFavorites(params = {}) {
    const qs = new URLSearchParams(params).toString();
    return this.request(`/playback/favorites${qs ? '?' + qs : ''}`);
  },

  // 收藏/已看 标记
  // GET 响应: { played, is_favorite, unplayed_count }
  // POST body: { media_item_id, played?, favorite?, season_number?, episode_number? }
  // 不带季集 = 整个条目（电影 / 整剧），带季集 = 单集（详情页头图标的就是这一集）
  getMarks(mediaItemId, seasonNumber, episodeNumber) {
    let qs = `?media_item_id=${mediaItemId}`;
    if (seasonNumber != null) qs += `&season_number=${seasonNumber}`;
    if (episodeNumber != null) qs += `&episode_number=${episodeNumber}`;
    return this.request(`/playback/marks${qs}`);
  },

  setMarks(mediaItemId, { played, favorite, seasonNumber, episodeNumber }) {
    const body = { media_item_id: mediaItemId };
    if (played !== undefined) body.played = played;
    if (favorite !== undefined) body.favorite = favorite;
    if (seasonNumber != null) body.season_number = seasonNumber;
    if (episodeNumber != null) body.episode_number = episodeNumber;
    return this.request('/playback/marks', { method: 'POST', body });
  },

  // ===== 认证 =====
  async nativeCall(command, args = {}) {
    try { return await window.__TAURI__.core.invoke(command, args); }
    catch (error) {
      let detail; try { detail = JSON.parse(typeof error === 'string' ? error : error.message); } catch (_) {}
      throw new APIError(detail?.message || error.message || String(error), { status: detail?.status || 0, code: detail?.code || 'NATIVE_AUTH_ERROR' });
    }
  },

  async getNativeAuthStatus() {
    const epoch = API.contextEpoch;
    try {
      const status = await this.nativeCall('native_auth_status');
      if (epoch !== API.contextEpoch) return null;
      API.nativeAuthAvailable = !!status;
      if (status) API.nativeAuthStatus = status;
      return status;
    } catch (error) {
      // An older desktop binary may lack the command; a real authentication failure stays visible.
      if (/unknown command|not found|unexpected fixture command|not registered/i.test(error.message)) {
        API.nativeAuthAvailable = false; return null;
      }
      throw error;
    }
  },

  async nativeMutation(command, args) {
    const status = await this.nativeCall(command, args);
    API.nativeAuthStatus = status;
    return { data: status.session };
  },

  getSession() {
    return this.request('/auth/me');
  },

  async login(username, password, remember = true, options = {}) {
    if (API.nativeAuthAvailable) return this.nativeMutation('native_password_login', { username, password });
    return this.request('/auth/login', {
      ...options,
      method: 'POST',
      body: { username, password, remember },
    });
  },

  async getBootstrapStatus() {
    return this.request('/auth/bootstrap');
  },

  async createAdmin(username, password, options = {}) {
    const response = await this.request('/auth/bootstrap', {
      ...options,
      method: 'POST',
      body: { username, password },
    });
    if (API.nativeAuthAvailable && API.nativeAuthStatus?.mode === 'device') return this.login(username, password);
    return response;
  },

  // 多账号
  async listAccounts() {
    if (API.nativeAuthAvailable) { const status = await this.getNativeAuthStatus(); return { data: status.accounts }; }
    return this.request('/auth/accounts');
  },

  async switchAccount(username) {
    if (API.nativeAuthAvailable) return this.nativeMutation('native_select_account', { username });
    return this.request('/auth/accounts/switch', {
      method: 'POST',
      body: { username },
    });
  },

  async removeAccount(username) {
    if (API.nativeAuthAvailable) return this.nativeMutation('native_remove_account', { username });
    return this.request(`/auth/accounts/${encodeURIComponent(username)}`, { method: 'DELETE' });
  },

  async logout() {
    if (API.nativeAuthAvailable) return this.nativeMutation('native_logout', { all: false });
    return this.request('/auth/logout', { method: 'POST' });
  },

  beginPairing() { return this.nativeCall('native_pair_begin'); },
  pollPairing(pairingId) { return this.nativeCall('native_pair_poll', { pairingId }); },
  cancelPairing(pairingId) { return this.nativeCall('native_pair_cancel', { pairingId }); },

  // QR 配对
  async getDeviceCode(client) {
    return this.request('/auth/device/authorize', { method: 'POST', body: client });
  },

  async checkDeviceStatus(deviceCode) {
    return this.request('/auth/device/token', { method: 'POST', body: { device_code: deviceCode } });
  },
};
