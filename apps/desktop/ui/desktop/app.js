// MovieClaw Desktop — Main application

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

function uiIcon(name) {
  const paths = {
    play: '<path d="m8 5 11 7-11 7z" fill="currentColor" stroke="none"/>',
    more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
    left: '<path d="m14 6-6 6 6 6"/>',
    right: '<path d="m10 6 6 6-6 6"/>',
    down: '<path d="m7 10 5 5 5-5"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>',
    bell: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9"/><path d="M10 21h4"/>',
    compass: '<circle cx="12" cy="12" r="9"/><path d="m16 8-3 5-5 3 3-5z"/>',
    account: '<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/>',
  };
  return `<svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${paths[name] || ''}</svg>`;
}

// 自绘深色下拉菜单，避免 Windows 原生选项底色与页面文字颜色冲突。
const DesktopSelect = {
  close(restoreFocus = false) {
    if (!this.menu) return;
    this.menu.remove(); this.menu = null;
    this.trigger?.setAttribute('aria-expanded', 'false');
    if (restoreFocus) this.trigger?.focus();
  },
  enhance(root) {
    if (!this.bound) {
      document.addEventListener('pointerdown', event => {
        if (this.menu && !this.menu.contains(event.target) && !this.trigger.contains(event.target)) this.close();
      }, true);
      document.addEventListener('scroll', event => {
        if (this.menu && !this.menu.contains(event.target)) this.position();
      }, true);
      window.addEventListener('resize', () => this.close());
      this.bound = true;
    }
    for (const select of root.querySelectorAll('select.settings-select')) {
      if (select.hidden) continue;
      const trigger = document.createElement('button');
      trigger.type = 'button'; trigger.className = 'settings-select select-trigger';
      trigger.id = select.id + 'Trigger';
      trigger.setAttribute('role', 'combobox');
      trigger.setAttribute('aria-haspopup', 'listbox');
      trigger.setAttribute('aria-expanded', 'false');
      trigger.setAttribute('aria-label', select.getAttribute('aria-label') || select.id);
      trigger.setAttribute('aria-controls', select.id + 'Menu');
      const update = () => {
        trigger.innerHTML = `<span>${escapeHtml(select.selectedOptions[0]?.textContent || '')}</span><svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="m7 10 5 5 5-5"/></svg>`;
        trigger.disabled = select.disabled;
      };
      update(); select.hidden = true; select.after(trigger);
      select.addEventListener('change', update);
      trigger.addEventListener('click', () => {
        if (this.menu && this.trigger === trigger) this.close(); else this.open(select, trigger);
      });
      trigger.addEventListener('keydown', event => {
        if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
          event.preventDefault(); this.open(select, trigger);
          if (event.key === 'Home') this.menu.firstElementChild?.focus();
          if (event.key === 'End') this.menu.lastElementChild?.focus();
        }
      });
    }
  },
  open(select, trigger) {
    this.close(); this.trigger = trigger;
    const menu = this.menu = document.createElement('div');
    menu.id = select.id + 'Menu'; menu.className = 'select-menu';
    menu.setAttribute('role', 'listbox');
    menu.setAttribute('aria-label', trigger.getAttribute('aria-label'));
    for (const option of select.options) {
      const row = document.createElement('button');
      row.type = 'button'; row.className = 'select-option'; row.tabIndex = -1; row.disabled = option.disabled;
      row.setAttribute('role', 'option'); row.setAttribute('aria-selected', String(option.selected));
      row.innerHTML = `<span>${escapeHtml(option.textContent)}</span><svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12 4 4 10-10"/></svg>`;
      row.addEventListener('click', () => {
        this.close(true);
        if (select.value !== option.value) { select.value = option.value; select.dispatchEvent(new Event('change', { bubbles: true })); }
      });
      menu.appendChild(row);
    }
    menu.addEventListener('keydown', event => {
      const rows = [...menu.children].filter(row => !row.disabled);
      const index = rows.indexOf(document.activeElement);
      if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
        event.preventDefault();
        const next = event.key === 'Home' ? 0 : event.key === 'End' ? rows.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length;
        rows[next]?.focus();
      } else if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); this.close(true); }
      else if (event.key === 'Tab') this.close(true);
    });
    (trigger.closest('dialog') || document.body).appendChild(menu);
    trigger.setAttribute('aria-expanded', 'true');
    this.position();
    (menu.querySelector('[aria-selected="true"]') || menu.firstElementChild)?.focus({ preventScroll: true });
  },
  position() {
    if (!this.menu) return;
    const rect = this.trigger.getBoundingClientRect(), menu = this.menu;
    if (!this.trigger.isConnected || rect.bottom < 0 || rect.top > innerHeight) { this.close(); return; }
    menu.style.minWidth = Math.min(Math.max(rect.width, 140), innerWidth - 16) + 'px';
    const box = menu.getBoundingClientRect();
    menu.style.left = Math.max(8, Math.min(rect.left, innerWidth - box.width - 8)) + 'px';
    menu.style.top = Math.max(8, rect.bottom + box.height + 8 <= innerHeight ? rect.bottom + 6 : rect.top - box.height - 6) + 'px';
  },
};

// 修复图片 URL：相对路径拼接 {server}/api/v1，远程 URL 走服务器代理
const imageSources = new Map();
function imageSourceKey(url) { return `${API.contextEpoch}:${API.baseUrl}:${url}`; }
function resolveUrl(url) {
  if (!url) return '';
  if (typeof url !== 'string') return '';
  const cached = imageSources.get(imageSourceKey(url));
  if (cached) return cached;
  if (url.startsWith('data:')) return /^data:image\/(png|jpeg|webp|gif);/i.test(url) ? url : '';
  if (/^[a-z][a-z0-9+.-]*:/i.test(url) && !/^https?:/i.test(url)) return '';
  const base = (window.__MOVIECLAW_SERVER__ || '').replace(/\/+$/, '');
  // 远程 TMDB 等图片走服务器缓存代理（和 Web 端一致）
  if (url.startsWith('http://') || url.startsWith('https://')) {
    if (!base) return url;
    return base + '/api/v1/images/proxy?url=' + encodeURIComponent(url);
  }
  if (!base) return url;
  // 相对路径：如果已含 /api/ 前缀则直接拼 base，否则补 /api/v1
  const path = url.startsWith('/') ? url : '/' + url;
  if (path.startsWith('/api/')) return base + path;
  return base + '/api/v1' + path;
}

// 图片加载失败时通过 Rust 代理（带 Cookie）重试
function imgFallback(imgEl, rawUrl) {
  if (!rawUrl || imgEl.dataset.retried) {
    imgEl.style.display = 'none';
    imgEl.parentElement?.classList.add('no-img');
    return;
  }
  imgEl.dataset.retried = '1';
  const source = imgEl.getAttribute('src'), epoch = API.contextEpoch;
  API.proxyImage(rawUrl).then(dataUri => {
    if (API.contextEpoch !== epoch || imgEl.dataset.raw !== rawUrl || imgEl.getAttribute('src') !== source) return;
    if (dataUri) {
      const key = imageSourceKey(rawUrl);
      imageSources.delete(key); imageSources.set(key, dataUri);
      if (imageSources.size > 64) imageSources.delete(imageSources.keys().next().value);
      imgEl.src = dataUri;
    } else {
      imgEl.style.display = 'none';
      imgEl.parentElement?.classList.add('no-img');
    }
  });
}

function imageTitleFallback(img, visible) {
  if (img.dataset.titleFallback === undefined) return;
  const title = img.nextElementSibling;
  if (title?.tagName === 'H1') title.hidden = !visible;
}

function replaceContentPreservingImages(root, html) {
  const images = new Map([...root.querySelectorAll('img.loaded[data-raw]')].map(img => [img.dataset.raw, img]));
  root.innerHTML = html;
  for (const img of root.querySelectorAll('img[data-raw]')) {
    const previous = images.get(img.dataset.raw);
    if (previous) { img.replaceWith(previous); images.delete(img.dataset.raw); }
  }
}

function onImageLoad(event) {
  const img = event.target;
  if (img?.tagName !== 'IMG' || img.dataset.raw === undefined) return;
  img.classList.add('loaded');
  if (img.dataset.fade !== undefined) img.style.opacity = '1';
  img.parentElement?.classList.add('has-img');
  if (img.parentElement?.classList.contains('library-cover')) {
    img.parentElement.style.setProperty('--library-image', `url("${img.src.replace(/"/g, '%22')}")`);
  }
  imageTitleFallback(img, false);
}

function onImageError(event) {
  const img = event.target;
  if (img?.tagName !== 'IMG' || img.dataset.raw === undefined) return;
  img.classList.remove('loaded');
  img.parentElement?.classList.remove('has-img');
  imageTitleFallback(img, true);
  imgFallback(img, img.dataset.raw);
}

function libraryCover(kind, rawUrl) {
  const icons = {
    movie: '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M7 3v18M17 3v18M3 8h4M3 16h4M17 8h4M17 16h4"/>',
    tv: '<rect x="3" y="6" width="18" height="14" rx="2"/><path d="m8 2 4 4 4-4M8 23h8"/>',
    video: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m10 8 6 4-6 4z"/>',
    collection: '<rect x="3" y="8" width="18" height="13" rx="2"/><path d="M6 4h12M9 1h6"/>',
  };
  return `<div class="library-placeholder" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${icons[kind] || icons.movie}</svg></div>`
    + (rawUrl ? `<img loading="lazy" src="${escapeHtml(resolveUrl(rawUrl))}" alt="" data-raw="${escapeHtml(rawUrl)}">` : '');
}

// 「12:34」/「1:02:33」——与 Apple 端 Formatters.clock 同一口径（详情页续播按钮）
function fmtClock(ms) {
  const total = Math.floor((ms || 0) / 1000);
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` : `${m}:${String(s).padStart(2, '0')}`;
}

// 「48 分钟」「2 小时 12 分钟」——同 Apple 端 Formatters.runtime
function fmtRuntime(minutes) {
  if (!minutes || minutes <= 0) return '';
  const h = Math.floor(minutes / 60), m = minutes % 60;
  if (!h) return `${m} 分钟`;
  return m > 0 ? `${h} 小时 ${m} 分钟` : `${h} 小时`;
}

// 「58.3 GB」——版本行的文件大小
function fmtBytes(bytes) {
  if (!bytes && bytes !== 0) return '';
  const gb = bytes / 1024 / 1024 / 1024;
  if (gb >= 1) return `${gb.toFixed(1)} GB`;
  return `${Math.round(bytes / 1024 / 1024)} MB`;
}

// Same merge rules as Shared/Library/LibraryHomeRows.swift at the fixed macOS baseline.
const HomeRows = {
  sorts: ['added_at', 'release_date', 'last_played', 'rating', 'random', 'title'],
  label(kind) { return kind === 'tv' ? '剧集' : kind === 'video' ? '其他视频' : '电影'; },
  title(name, sort, order) {
    const reversed = order === (sort === 'title' ? 'desc' : 'asc');
    return sort === 'title' ? name + (reversed ? ' Z–A' : ' A–Z') : sort === 'random' ? '随便看看 · ' + name
      : ({ added_at: reversed ? '最早添加的' : '最近添加的', release_date: reversed ? '最早上映的' : '最近上映的',
        last_played: reversed ? '很久没看的' : '最近观看的', rating: reversed ? '评分最低的' : '评分最高的' }[sort] || '最近添加的') + name;
  },
  build(prefs, libraries, collections) {
    const visible = libraries.filter(lib => lib.viewer_access !== false && lib.kind !== 'photo');
    const groups = ['movie', 'tv', 'video'].filter(kind => visible.some(lib => lib.kind === kind && !lib.exclude_from_home));
    const resolve = pref => {
      const row = { ...pref, hidden: pref.hidden === true, title: pref.name?.trim() || '' };
      if (['up-next', 'libraries', 'favorites'].includes(pref.id)) {
        row.type = pref.id; row.title = { 'up-next': '接下来继续', libraries: '我的媒体库', favorites: '我的收藏' }[pref.id];
        row.sort = ['unwatched_first', 'favorited_at', 'rating', 'title'].includes(pref.sort) ? pref.sort : 'unwatched_first';
      } else if (pref.id?.startsWith('genres:')) {
        row.type = 'genres'; row.media_kind = pref.id.slice(7);
        if (!groups.includes(row.media_kind)) return null;
        row.title = '按类型找' + this.label(row.media_kind);
      } else {
        if (pref.id?.startsWith('lib:')) row.library_id = Number(pref.id.slice(4));
        else if (pref.id?.startsWith('kind:') && !row.hidden) row.media_kind = pref.id.slice(5);
        else if (!pref.id?.startsWith('row:')) return null;
        const library = visible.find(lib => lib.id === row.library_id);
        const collection = collections.find(col => col.id === row.collection_id);
        if (row.media_kind) {
          if (!groups.includes(row.media_kind)) return null;
          row.type = 'kind';
        } else if (row.collection_id) {
          if (!collection || collection.hidden) return null;
          row.type = 'collection'; row.collection = collection;
        } else {
          if (!library || (pref.id.startsWith('lib:') && library.exclude_from_home)) return null;
          row.type = 'library'; row.library = library;
        }
        const allowed = (library?.kind || row.media_kind) === 'video' ? ['added_at', 'last_played', 'title', 'random'] : this.sorts;
        const savedSort = pref.sort ?? collection?.sort;
        row.sort = savedSort === 'release_date_asc' ? 'release_date' : allowed.includes(savedSort) ? savedSort : 'added_at';
        row.order = savedSort === 'release_date_asc' ? 'asc' : ['asc', 'desc'].includes(pref.order) ? pref.order : row.sort === 'title' ? 'asc' : 'desc';
        row.unwatched = pref.unwatched === true && row.sort !== 'last_played';
        row.title ||= row.type === 'collection' ? collection.name : row.type === 'kind'
          ? '全部' + this.label(row.media_kind) + ' · ' + this.title('', row.sort, row.order).replace(/的$| · $/, '').trim()
          : this.title(library.name, row.sort, row.order);
      }
      row.order ||= row.sort === 'title' ? 'asc' : 'desc';
      return row;
    };
    const defaults = [{ id: 'up-next' }, { id: 'favorites' }, { id: 'libraries' },
      ...groups.filter(kind => kind !== 'video').map(kind => ({ id: 'genres:' + kind })),
      ...visible.filter(lib => !lib.exclude_from_home).map(lib => ({ id: 'lib:' + lib.id }))].map(resolve).filter(Boolean);
    if (!prefs?.length) return defaults;
    const seen = new Set(), rows = [];
    for (const pref of prefs) { const row = resolve(pref); if (row && !seen.has(row.id)) { rows.push(row); seen.add(row.id); } }
    for (const row of defaults.filter(row => !['library', 'genres'].includes(row.type))) if (!seen.has(row.id)) { rows.push(row); seen.add(row.id); }
    const genres = defaults.filter(row => row.type === 'genres' && !seen.has(row.id));
    const libsAt = rows.findIndex(row => row.type === 'libraries');
    rows.splice(libsAt < 0 ? rows.length : libsAt + 1, 0, ...genres);
    const missing = defaults.filter(row => row.type === 'library' && !seen.has(row.id));
    let at = rows.findLastIndex(row => row.type === 'library') + 1;
    if (!at) { at = rows.findIndex(row => row.type === 'libraries') + 1 || rows.length; while (rows[at]?.type === 'genres') at++; }
    rows.splice(at, 0, ...missing);
    return rows;
  },
  pinned(rows) { const ids = new Set(); return rows.filter(row => !row.hidden && row.type === 'collection' && !ids.has(row.collection_id) && ids.add(row.collection_id)).map(row => row.collection); },
};

const EpisodeRanges = {
  index(number) { return Math.floor((Math.max(1, Number(number)) - 1) / 50); },
  ranges(episodes) {
    if (episodes.length <= 50) return [];
    const ids = [...new Set(episodes.map(ep => this.index(ep.episode_number)))].sort((a, b) => a - b);
    return ids.map(index => {
      const numbers = episodes.filter(ep => this.index(ep.episode_number) === index).map(ep => Number(ep.episode_number));
      const start = Math.min(...numbers), end = Math.max(...numbers);
      return { index, start, end, label: `${start}–${end}` };
    });
  },
};

// Offset advances by the raw server page; visible items are deduplicated by media id.
class DesktopPager {
  constructor(fetchPage, current) {
    this.fetchPage = fetchPage;
    this.current = current;
    this.items = [];
    this.offset = 0;
    this.cursor = null;
    this.hasMore = true;
    this.loading = false;
    this.total = null;
    this.pageRecords = [];
    this.cachedPages = new Map();
    this.cacheLimit = 0;
  }

  enableWindow(limit = 12) { this.cacheLimit = limit; }

  keepPage(record) {
    if (!this.cacheLimit) return;
    this.cachedPages.delete(record);
    this.cachedPages.set(record, true);
    while (this.cachedPages.size > this.cacheLimit) {
      const oldest = this.cachedPages.keys().next().value;
      this.cachedPages.delete(oldest);
      for (let i = oldest.start; i < oldest.end; i++) {
        const item = this.items[i];
        if (item) this.items[i] = { media_item_id: item.media_item_id, library_id: item.library_id, _evicted: true };
      }
    }
  }

  async hydrateRange(start, end) {
    if (!this.cacheLimit) return;
    for (const record of this.pageRecords.filter(record => record.end > start && record.start < end)) {
      if (!this.current()) return;
      if (this.cachedPages.has(record)) { this.keepPage(record); continue; }
      if (!record.pending) record.pending = this.fetchPage({ offset: record.offset, cursor: record.cursor, limit: record.limit }).finally(() => { record.pending = null; });
      const page = await record.pending;
      if (!this.current()) return;
      const byId = new Map(page.items.map(item => [item.media_item_id, item]));
      for (let i = record.start; i < record.end; i++) {
        const old = this.items[i];
        this.items[i] = byId.get(old?.media_item_id) || { ...old, _evicted: false, title: '项目已移除', source_missing: true };
      }
      this.keepPage(record);
    }
  }

  removeAt(index) {
    this.items.splice(index, 1);
    for (const record of this.pageRecords) {
      if (record.end <= index) continue;
      if (record.start > index) { record.start--; record.offset = Math.max(0, record.offset - 1); }
      record.end--;
    }
  }

  insertAt(index, item) {
    this.items.splice(index, 0, item);
    for (const record of this.pageRecords) {
      if (record.end <= index) continue;
      if (record.start > index) { record.start++; record.offset++; }
      else record.limit++;
      record.end++;
    }
  }

  async loadMore() {
    if (this.loading || !this.hasMore || !this.current()) return [];
    this.loading = true;
    try {
      const cursor = this.cursor;
      const page = await (this.inFlight = this.fetchPage({ offset: this.offset, cursor, limit: 60 }));
      if (!this.current()) return [];
      const known = new Set(this.items.map(item => item.media_item_id));
      const added = page.items.filter(item => {
        if (known.has(item.media_item_id)) return false;
        known.add(item.media_item_id);
        return true;
      });
      const record = { start: this.items.length, offset: this.offset, cursor, limit: 60 };
      this.offset += page.rawCount ?? page.items.length;
      this.items.push(...added);
      record.end = this.items.length;
      this.pageRecords.push(record);
      this.keepPage(record);
      this.total = page.total ?? this.total;
      this.hasMore = page.hasMore;
      this.cursor = page.cursor ?? null;
      return added;
    } finally {
      this.loading = false;
    }
  }
}

const App = {
  currentPage: 'home',
  libraries: [],
  collections: [],
  navStack: [],       // 导航历史栈
  viewGeneration: 0,
  session: null,
  selectedTab: 'home',
  tabStates: new Map(),

  isCurrent(generation) {
    return generation === this.viewGeneration && !this._pageController?.signal.aborted;
  },

  async resetContext() {
    if (this._pairing) {
      const pairing = this._pairing; this._pairing = null;
      clearTimeout(pairing.timer); clearInterval(pairing.countdown);
      await (pairing.cancelPromise ||= API.cancelPairing(pairing.id));
    }
    window.DesktopCatalog?.reset();
    document.getElementById('accountPanel')?.remove();
    document.getElementById('cardMenu')?.remove();
    this._changingContext = true;
    this._authPending = true;
    this._sessionSequence = (this._sessionSequence || 0) + 1;
    this._startupController?.abort();
    this._sessionController?.abort();
    window.DesktopCatalog?.dispose();
    window.DesktopSubtitles?.dispose();
    window.DesktopFriends?.dispose();
    this._pageController?.abort();
    this.viewGeneration++;
    this._playbackSeq = (this._playbackSeq || 0) + 1;
    await Player.close();
    API.invalidateContext();
    this.libraries = [];
    this.collections = [];
    this.navStack = [];
    this.tabStates.clear();
    this.selectedTab = 'home';
    this._homeData = null;
    this._searchData = null;
    this._routeRestore = null;
    this._beforeSearch = null;
    document.getElementById('searchInput').value = '';
  },

  async handleSessionExpired() {
    if (this._authPending) return;
    this._authPending = true;
    this._resumeRoute = { page: this.currentPage, params: this.currentParams || {} };
    const username = this.session?.username || '';
    await this.resetContext();
    this.renderLogin({ username, message: '登录已失效，请重新输入密码。' });
  },

  async init() {
    this.bindEvents();
    API.onUnauthorized = () => this.handleSessionExpired();
    this._authPending = true;
    this._startupController?.abort();
    const controller = this._startupController = new AbortController();
    const sequence = this._startupSequence = (this._startupSequence || 0) + 1;
    const current = () => sequence === this._startupSequence && !controller.signal.aborted;
    const api = API.scope(controller.signal);
    try {
      await API.init();
      if (!current()) return;
      if (!API.baseUrl) {
        this.renderConnectionState('needsServer', '请先选择一台 MovieClaw 服务器。');
        return;
      }
      const health = await api.request('/health', { timeoutMs: 8000 });
      if (!current()) return;
      const server = health?.data || health;
      if (server?.status !== 'ok') {
        this.renderConnectionState('incompatible', '这个地址没有返回健康的 MovieClaw 服务，请核对服务器地址。');
        return;
      }
      const bootstrap = await api.getBootstrapStatus();
      if (!current()) return;
      const nativeStatus = await API.getNativeAuthStatus();
      if (!current()) return;
      if (!(bootstrap?.data || bootstrap)?.initialized) {
        this.renderLogin({ setup: true });
        return;
      }
      if (nativeStatus && !nativeStatus.session) {
        if (nativeStatus.accounts.length) this.renderAccountChooser(nativeStatus.accounts);
        else this.renderLogin();
        return;
      }
      const session = nativeStatus ? { data: nativeStatus.session } : await api.getSession();
      if (current()) await this.enterSession(session);
    } catch (e) {
      if (!current() || e.name === 'AbortError') return;
      if (e.status === 401) this.renderLogin();
      else if (e.status === 404 || e.status === 405) this.renderConnectionState('incompatible', '服务器缺少本版本必需的接口，请先升级服务器后重试。');
      else this.renderConnectionState('unreachable', e.message);
    }
  },

  async enterSession(response) {
    const epoch = API.contextEpoch;
    const sequence = this._sessionSequence = (this._sessionSequence || 0) + 1;
    this._sessionController?.abort();
    const controller = this._sessionController = new AbortController();
    const current = () => sequence === this._sessionSequence && epoch === API.contextEpoch && !controller.signal.aborted;
    this.session = response?.data || response;
    this._authPending = true;
    try {
      await this.loadSidebarData(API.scope(controller.signal));
    } catch (error) {
      if (!current() || error.name === 'AbortError') return;
      this._authPending = false;
      if (error.status === 401) await this.handleSessionExpired();
      else if (error.status === 404 || error.status === 405) this.renderConnectionState('incompatible', '服务器缺少媒体库或合集接口，请升级服务器后重试。');
      else this.renderConnectionState('unreachable', error.message);
      return;
    }
    if (!current()) return;
    this._authPending = false;
    this._changingContext = false;
    document.getElementById('sidebar').style.display = '';
    window.DesktopFriends?.refreshButton();
    const route = this._resumeRoute || { page: 'home', params: {} };
    this._resumeRoute = null;
    await this.navigate(route.page, route.params, false);
  },

  renderConnectionState(phase, message) {
    this._authPending = true;
    window.DesktopCatalog?.dispose();
    window.DesktopSubtitles?.dispose();
    this._pageController?.abort();
    this._wallObserver?.disconnect();
    this.viewGeneration++;
    document.getElementById('sidebar').style.display = 'none';
    const content = document.getElementById('content');
    const title = phase === 'incompatible' ? '需要兼容的 MovieClaw 服务器' : phase === 'needsServer' ? '连接服务器' : '连不上服务器';
    content.innerHTML = `<div class="login-page"><div class="login-card">
      <div class="login-logo">MovieClaw</div><h2>${title}</h2>
      <p class="login-subtitle">${escapeHtml(message)}</p>
      <p class="login-subtitle">${escapeHtml(API.baseUrl)}</p>
      <button class="login-btn" id="retryConnection">重试</button>
      <button class="btn-secondary" id="changeServer">更换服务器</button>
    </div></div>`;
    document.getElementById('retryConnection').addEventListener('click', () => this.init());
    document.getElementById('changeServer').addEventListener('click', () => this.changeServer());
  },

  async changeServer() {
    await this.resetContext();
    await window.__TAURI__.core.invoke('clear_server_url');
    window.location.href = '../connect.html';
  },

  // ===== 登录 =====
  renderLogin({ setup = false, addAccount = false, username = '', message = '' } = {}) {
    window.DesktopCatalog?.dispose();
    window.DesktopSubtitles?.dispose();
    this._pageController?.abort();
    this._wallObserver?.disconnect();
    this.viewGeneration++;
    const content = document.getElementById('content');
    const sidebar = document.getElementById('sidebar');
    if (sidebar) sidebar.style.display = 'none';

    content.innerHTML = `
      <div class="login-page">
        <div class="login-card">
          <div class="login-logo">MovieClaw</div>
          <div class="login-subtitle">${setup ? '初始化这台服务器' : addAccount ? '添加账号' : '登录到服务器'}</div>
          <div class="login-subtitle">${escapeHtml(API.baseUrl)}</div>
          <form id="loginForm">
            <div class="login-field">
              <label for="loginUser">用户名</label>
              <input type="text" id="loginUser" placeholder="输入用户名" autocomplete="username" value="${escapeHtml(username)}" ${setup ? 'minlength="3" maxlength="32"' : ''} required>
            </div>
            <div class="login-field">
              <label for="loginPass">密码</label>
              <input type="password" id="loginPass" placeholder="输入密码" autocomplete="${setup ? 'new-password' : 'current-password'}" ${setup ? 'minlength="8" maxlength="128"' : ''} required>
            </div>
            ${setup ? '<div class="login-field"><label for="loginConfirm">确认密码</label><input type="password" id="loginConfirm" autocomplete="new-password" required></div>' : ''}
            <button type="submit" class="login-btn" id="loginBtn">${setup ? '创建管理员' : '登录'}</button>
            <div class="login-error" id="loginError">${escapeHtml(message)}</div>
          </form>

          ${!setup && API.nativeAuthStatus?.accounts?.length ? '<button class="text-button" id="loginChooseAccount">使用已保存账号</button>' : ''}
          ${API.nativeAuthStatus?.mode === 'cookie' ? `<p class="login-subtitle">兼容登录 · ${escapeHtml(API.nativeAuthStatus.compatibility_reason || '服务器使用 Cookie 登录')}</p>` : ''}
          <button class="btn-secondary" id="loginChangeServer">更换服务器</button>
          ${addAccount ? '<button class="btn-secondary" id="cancelAddAccount">取消</button>' : ''}
        </div>
      </div>
    `;

    const form = document.getElementById('loginForm');
    const btn = document.getElementById('loginBtn');
    const cancel = document.getElementById('cancelAddAccount');
    const changeServer = document.getElementById('loginChangeServer');
    let submitting = false;
    const setSubmitting = busy => {
      submitting = busy;
      btn.disabled = busy;
      if (cancel) cancel.disabled = busy;
      changeServer.disabled = busy;
      document.getElementById('loginPairing') && (document.getElementById('loginPairing').disabled = busy);
      document.getElementById('loginChooseAccount') && (document.getElementById('loginChooseAccount').disabled = busy);
    };
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      if (submitting) return;
      const err = document.getElementById('loginError');
      setSubmitting(true);
      btn.textContent = '正在登录...';
      err.textContent = '';
      let attemptGeneration = this.viewGeneration;

      try {
        const user = document.getElementById('loginUser').value.trim();
        const pass = document.getElementById('loginPass').value;
        if (setup && pass !== document.getElementById('loginConfirm').value) throw new Error('两次输入的密码不一致');
        // Stop against the old Cookie first, then retire its request/progress identity before Cookie mutation.
        await this.resetContext();
        attemptGeneration = this.viewGeneration;
        // Await the transport's final result; a UI-only timeout cannot undo a late Set-Cookie.
        const result = setup ? await API.createAdmin(user, pass, { timeoutMs: 0 }) : await API.login(user, pass, true, { timeoutMs: 0 });
        if (attemptGeneration !== this.viewGeneration) return;
        await this.enterSession(result);
      } catch (ex) {
        if (attemptGeneration !== this.viewGeneration) return;
        err.textContent = ex.message || '登录失败';
        btn.textContent = setup ? '创建管理员' : '登录';
      } finally {
        if (attemptGeneration === this.viewGeneration && document.getElementById('loginForm') === form) setSubmitting(false);
      }
    });
    changeServer.addEventListener('click', () => { if (!submitting) return this.changeServer(); });
    document.getElementById('loginPairing')?.addEventListener('click', () => { if (!submitting) this.renderPairing({ addAccount }); });
    document.getElementById('loginChooseAccount')?.addEventListener('click', () => { if (!submitting) this.renderAccountChooser(API.nativeAuthStatus.accounts); });
    cancel?.addEventListener('click', async () => {
      if (submitting) return;
      try {
        this._resumeRoute = { page: 'settings', params: {} };
        await this.enterSession(await API.getSession());
      } catch (error) {
        if (error.status === 401) this.renderLogin();
        else this.renderConnectionState('unreachable', error.message);
      }
    });
  },

  renderAccountChooser(accounts) {
    this._authPending = true; this.viewGeneration++;
    document.getElementById('sidebar').style.display = 'none';
    const content = document.getElementById('content');
    content.innerHTML = `<div class="login-page"><div class="login-card"><div class="login-logo">MovieClaw</div><h2>选择账号</h2><p class="login-subtitle">${escapeHtml(API.baseUrl)}</p><div class="welcome-accounts">${accounts.map(account => `<button class="welcome-account" data-account="${escapeHtml(account.username)}"><strong>${escapeHtml(account.nickname || account.username)}</strong><span>${account.authenticated === false ? '登录已失效，请输入密码' : '继续使用这个账号'}</span></button>`).join('')}</div><button class="btn-secondary" id="chooseAddAccount">添加账号</button><button class="btn-secondary" id="chooseChangeServer">更换服务器</button></div></div>`;
    content.querySelectorAll('[data-account]').forEach(button => button.addEventListener('click', () => {
      const account = accounts.find(account => account.username === button.dataset.account);
      if (account.authenticated === false) this.renderLogin({ username: account.username });
      else { this._authPending = false; this._changingContext = false; this.switchToAccount(account.username); }
    }));
    content.querySelector('#chooseAddAccount').addEventListener('click', () => this.renderLogin());
    content.querySelector('#chooseChangeServer').addEventListener('click', () => this.changeServer());
  },

  async renderPairing({ addAccount = false } = {}) {
    if (this._pairingStarting) return;
    const content = document.getElementById('content');
    if (!API.nativeAuthAvailable || !API.nativeAuthStatus?.pairing_supported) {
      this.notice(API.nativeAuthStatus?.compatibility_reason || '服务器暂不支持 Windows 扫码登录，请升级服务器或使用账号密码登录。'); return;
    }
    this._pairingStarting = true;
    try {
      await this.resetContext();
      const generation = ++this.viewGeneration;
      document.getElementById('sidebar').style.display = 'none';
      content.innerHTML = `<div class="login-page"><div class="login-card"><div class="login-logo">MovieClaw</div><h2>扫码登录</h2><div id="pairingCode" class="pairing-code"></div><div id="pairingStatus" role="status">正在生成配对码…</div><button id="pairingRetry" class="btn-secondary" hidden>重新生成</button><button id="pairingCancel" class="btn-secondary" disabled>${addAccount ? '取消添加账号' : '使用密码登录'}</button></div></div>`;
      const begin = await API.beginPairing();
      if (generation !== this.viewGeneration) { await API.cancelPairing(begin.pairing_id); return; }
      const pairing = this._pairing = { id: begin.pairing_id, generation };
      const status = content.querySelector('#pairingStatus');
      const qr = qrcodegen.QrCode.encodeText(begin.verification_uri_complete, qrcodegen.QrCode.Ecc.MEDIUM);
      let path = ''; for (let y = 0; y < qr.size; y++) for (let x = 0; x < qr.size; x++) if (qr.getModule(x, y)) path += `M${x + 4},${y + 4}h1v1h-1z `;
      content.querySelector('#pairingCode').innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${qr.size + 8} ${qr.size + 8}" role="img" aria-label="扫码登录二维码"><rect width="100%" height="100%" fill="white"/><path d="${path}" fill="black"/></svg><strong>${escapeHtml(begin.user_code)}</strong><p>用 MovieClaw 手机端扫码，或在服务器设备管理中输入配对码</p>`;
      content.querySelector('#pairingCancel').disabled = false;
      const current = () => this._pairing === pairing && generation === this.viewGeneration && !pairing.terminal;
      const terminal = message => {
        if (pairing.terminal) return;
        pairing.terminal = true; clearTimeout(pairing.timer); clearInterval(pairing.countdown); status.textContent = message;
        const retry = content.querySelector('#pairingRetry'), cancel = content.querySelector('#pairingCancel');
        retry.hidden = false; retry.disabled = true; cancel.disabled = true;
        pairing.cancelPromise = API.cancelPairing(pairing.id);
        pairing.cancelPromise.finally(() => { if (generation === this.viewGeneration) { retry.disabled = false; cancel.disabled = false; } }).catch(error => { if (generation === this.viewGeneration) status.textContent = '无法结束配对：' + error.message; });
      };
      const countdown = () => {
        if (!current()) return;
        const remaining = Math.max(0, Math.ceil(begin.expires_at - Date.now() / 1000));
        if (!remaining) { terminal('配对码已过期，请重新生成。'); return; }
        status.textContent = `等待手机批准 · ${remaining} 秒后过期`;
      };
      countdown(); pairing.countdown = setInterval(countdown, 1000);
      const poll = async () => {
        if (!current() || Date.now() / 1000 >= begin.expires_at) { terminal('配对码已过期，请重新生成。'); return; }
        try {
          const result = await API.pollPairing(pairing.id);
          if (!current()) return;
          if (result.status === 'approved') {
            content.querySelector('#pairingCancel').disabled = true;
            clearInterval(pairing.countdown); this._pairing = null;
            API.nativeAuthStatus = await API.getNativeAuthStatus();
            if (generation === this.viewGeneration) await this.enterSession({ data: result.session || API.nativeAuthStatus.session });
            return;
          }
          if (result.status !== 'pending') { terminal({ denied: '配对请求被拒绝，请重试。', expired: '配对码已过期，请重新生成。', cancelled: '配对已取消。' }[result.status] || '配对未完成，请重试。'); return; }
          pairing.timer = setTimeout(poll, Math.max(1, Math.min(30, result.interval || begin.interval)) * 1000);
        } catch (error) { if (current()) terminal('扫码登录失败：' + error.message); }
      };
      pairing.timer = setTimeout(poll, Math.max(1, Math.min(30, begin.interval)) * 1000);
      content.querySelector('#pairingRetry').addEventListener('click', event => { if (!event.currentTarget.disabled) this.renderPairing({ addAccount }); });
      content.querySelector('#pairingCancel').addEventListener('click', async event => {
        if (event.currentTarget.disabled) return;
        event.currentTarget.disabled = true;
        try {
          await this.resetContext();
          if (addAccount) { this._resumeRoute = { page: 'settings', params: {} }; await this.enterSession(await API.getSession()); }
          else this.renderLogin();
        } catch (error) { this.renderConnectionState('unreachable', error.message); }
      });
    } catch (error) { this.renderLogin({ addAccount, message: '无法开始扫码登录：' + error.message }); }
    finally { this._pairingStarting = false; }
  },

  setSidebarCollapsed(collapsed, persist = true) {
    this.sidebarCollapsed = !!collapsed;
    document.documentElement?.classList.toggle('sidebar-collapsed', this.sidebarCollapsed);
    const toggle = document.getElementById('btnToggleSidebar');
    const label = this.sidebarCollapsed ? '展开侧边栏' : '收起侧边栏';
    toggle?.setAttribute('aria-expanded', String(!this.sidebarCollapsed));
    toggle?.setAttribute('aria-label', label);
    if (toggle) toggle.title = label;
    if (persist) localStorage.setItem('mc_sidebarCollapsed', String(this.sidebarCollapsed));
    DesktopSelect.close();
    window.dispatchEvent?.(new Event('resize'));
  },

  focusSearch() {
    if (!this.session || this._authPending) return;
    this.setSidebarCollapsed(false);
    const search = document.getElementById('searchInput');
    search?.focus(); search?.select();
  },

  bindEvents() {
    if (this._eventsBound) return;
    this._eventsBound = true;
    this.setSidebarCollapsed(localStorage.getItem('mc_sidebarCollapsed') === 'true', false);
    document.getElementById('btnToggleSidebar')?.addEventListener('click', () => this.setSidebarCollapsed(!this.sidebarCollapsed));
    document.getElementById('btnSidebarSearch')?.addEventListener('click', () => this.focusSearch());
    document.querySelectorAll('.nav-item[data-page]').forEach(item => {
      const label = item.querySelector('span')?.textContent || '';
      item.setAttribute('aria-label', label); item.title = label;
    });
    // Image events do not bubble; capture keeps authenticated fallback CSP-compatible.
    document.addEventListener('load', onImageLoad, true);
    document.addEventListener('error', onImageError, true);
    window.__MOVIECLAW_CHANGE_SERVER__ = () => this.changeServer();
    window.addEventListener('movieclaw:playback-stopped', e => this.refreshStoppedItem(e.detail || {}));
    // 侧栏导航
    document.querySelectorAll('.nav-item[data-page]').forEach(item => {
      item.addEventListener('click', (e) => {
        e.preventDefault();
        const page = item.dataset.page;
        this.selectTab(page);
      });
    });

    // 搜索
    const searchInput = document.getElementById('searchInput');
    let searchTimer;
    searchInput?.addEventListener('focus', () => {
      if (this._authPending || !this.session || searchInput.value.trim() || this.currentPage === 'search') return;
      this._beforeSearch = this.captureRoute(); this.navStack = [];
      this.navigate('search', { query: '' }, false);
    });
    searchInput?.addEventListener('input', () => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => {
        const q = searchInput.value.trim();
        if (this._authPending || !this.session) return;
        if (q) {
          if (!this._beforeSearch) this._beforeSearch = this.captureRoute();
          if (this.currentParams?.query !== q || this.currentPage !== 'search') this.navStack = [];
          this.navigate('search', { query: q }, false);
        } else if (this._beforeSearch) {
          const route = this._beforeSearch || { page: 'home', params: {} };
          this._beforeSearch = null;
          this._routeRestore = route;
          this.navStack = route.stack || [];
          this.navigate(route.page, route.params, false);
        }
      }, 300);
    });
    document.getElementById('accountButton')?.addEventListener('click', () => this.showAccountPanel());
    let scrollTimer;
    document.getElementById('content').addEventListener('scroll', () => {
      this._scrolling = true;
      document.getElementById('content').classList.add('is-scrolling');
      clearTimeout(scrollTimer);
      scrollTimer = setTimeout(() => { this._scrolling = false; document.getElementById('content').classList.remove('is-scrolling'); }, 140);
    }, { passive: true });

    // 窗口控制
    const getWindow = () => {
      if (window.__TAURI__?.window?.getCurrentWindow) return window.__TAURI__.window.getCurrentWindow();
      return null;
    };
    document.getElementById('btnMinimize')?.addEventListener('click', () => {
      const w = getWindow();
      if (w) w.minimize().catch(e => console.error('minimize failed:', e));
    });
    document.getElementById('btnMaximize')?.addEventListener('click', () => {
      const w = getWindow();
      if (w) w.toggleMaximize().catch(e => console.error('toggleMaximize failed:', e));
    });
    document.getElementById('btnClose')?.addEventListener('click', () => {
      const w = getWindow();
      if (w) w.close().catch(e => console.error('close failed:', e));
    });

    // 键盘快捷键
    document.addEventListener('keydown', (e) => {
      if (document.querySelector?.('dialog[open]')) return;
      // Esc: 返回上一页
      if (e.key === 'Escape') {
        if (!document.getElementById('playerView').hidden) return;
        if (this.currentPage === 'detail' || this.currentPage === 'search') {
          e.preventDefault();
          this.goBack();
        }
      }
      // Ctrl+F: 聚焦搜索框
      if (e.key === 'f' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        if (!this.session || this._authPending) return;
        this.focusSearch();
      }
      if ((e.ctrlKey || e.metaKey) && e.key === '[') { e.preventDefault(); this.goBack(); }
      if ((e.ctrlKey || e.metaKey) && /^[1-9]$/.test(e.key) && document.getElementById('playerView').hidden) {
        e.preventDefault();
        const index = Number(e.key) - 1;
        if (index < 2) this.selectTab(index ? 'favorites' : 'home');
        else if (this.libraries[index - 2]) this.selectTab('library', { libraryId: this.libraries[index - 2].id });
      }
    });
  },

  async loadSidebarData(api = API) {
    const epoch = API.contextEpoch;
    try {
      const [libs, colls, prefs] = await Promise.all([
        api.listLibraries(),
        api.listCollections(),
        api.getUiPreferences().catch(error => { if (error.status === 404) return { data: { home: { rows: [] } } }; throw error; }),
      ]);
      // API 可能返回 { data: [...] } 包装
      if (epoch !== API.contextEpoch) return;
      this.libraries = (libs?.data || libs || []).filter(lib => lib.viewer_access !== false && lib.kind !== 'photo');
      this.collections = colls?.data || colls || [];
      this.uiPreferences = prefs?.data || prefs || {};
      this.homeRows = HomeRows.build(this.uiPreferences.home?.rows || [], this.libraries, this.collections);
      console.log('Libraries:', this.libraries.length, 'Collections:', this.collections.length);
      this.renderSidebar();
    } catch (e) {
      if (e.name === 'AbortError') return;
      throw e;
    }
  },

  renderSidebar() {
    const libNav = document.getElementById('libraryNav');
    libNav.innerHTML = this.libraries.map(lib => `
      <a class="nav-item" data-library-id="${Number(lib.id)}" href="#" aria-label="${escapeHtml(lib.name)}" title="${escapeHtml(lib.name)}">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
          ${lib.kind === 'tv' ? '<rect x="2" y="7" width="20" height="15" rx="2"/><polyline points="17 2 12 7 7 2"/>' : '<rect x="2" y="2" width="20" height="20" rx="2"/><line x1="7" y1="2" x2="7" y2="22"/><line x1="17" y1="2" x2="17" y2="22"/><line x1="2" y1="12" x2="22" y2="12"/>'}
        </svg>
        <span>${escapeHtml(lib.name)}</span>
        ${lib.stats?.item_count != null ? `<span class="badge">${Number(lib.stats.item_count)}</span>` : ''}
      </a>
    `).join('');

    libNav.querySelectorAll('.nav-item').forEach(item => {
      item.addEventListener('click', (e) => {
        e.preventDefault();
        const id = parseInt(item.dataset.libraryId);
        this.selectTab('library', { libraryId: id });
      });
    });

    const colNav = document.getElementById('collectionNav');
    // 只显示用户/内置合集，过滤掉自动生成的"系列"合集
    // CollectionView.kind: "user" | "builtin" | "series"
    const userCollections = HomeRows.pinned(this.homeRows || []);
    colNav.innerHTML = userCollections.map(col => `
      <a class="nav-item" data-collection-id="${Number(col.id)}" href="#" aria-label="${escapeHtml(col.name)}" title="${escapeHtml(col.name)}">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z"/></svg>
        <span>${escapeHtml(col.name)}</span>
        ${col.item_count != null ? `<span class="badge">${Number(col.item_count)}</span>` : ''}
      </a>
    `).join('');

    colNav.querySelectorAll('.nav-item').forEach(item => {
      item.addEventListener('click', (e) => {
        e.preventDefault();
        const id = parseInt(item.dataset.collectionId);
        this.selectTab('collection', { collectionId: id });
      });
    });
    window.DesktopCatalog?.nav();
    const account = document.getElementById('accountButton');
    if (account) {
      const name = this.session?.nickname || this.session?.username || '账号';
      account.innerHTML = `${uiIcon('account')}<span>${escapeHtml(name)}</span>${uiIcon('down')}`;
      account.title = '账号：' + name; account.setAttribute('aria-label', '账号：' + name);
    }
  },

  captureRoute() {
    const pager = this._wallContext?.pager;
    return { page: this.currentPage, params: this.currentParams || {}, stack: this.navStack.slice(),
      scrollTop: document.getElementById('content').scrollTop || 0,
      search: this.currentPage === 'search' ? this._searchData : null,
      wall: pager && { items: pager.items.slice(), offset: pager.offset, cursor: pager.cursor, hasMore: pager.hasMore, total: pager.total,
        pageRecords: pager.pageRecords.map(record => ({ start: record.start, end: record.end, offset: record.offset, cursor: record.cursor, limit: record.limit })) } };
  },

  async selectTab(page, params = {}) {
    if (this._authPending) return;
    const key = page + (page === 'library' ? ':' + params.libraryId : page === 'collection' ? ':' + params.collectionId : '');
    if (!this._beforeSearch) this.tabStates.set(this.selectedTab, this.captureRoute());
    if (this.tabStates.size > 8) this.tabStates.delete(this.tabStates.keys().next().value);
    document.getElementById('searchInput').value = '';
    this._beforeSearch = null;
    const route = key === this.selectedTab ? null : this.tabStates.get(key);
    this.selectedTab = key;
    this.navStack = route?.stack?.slice() || [];
    this._routeRestore = route;
    await this.navigate(route?.page || page, route?.params || params, false);
  },

  setActiveNav(page, libraryId) {
    document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
    const [tab, id] = this.selectedTab.split(':');
    const selector = tab === 'library' ? `[data-library-id="${Number(id)}"]` : tab === 'collection' ? `[data-collection-id="${Number(id)}"]` : `[data-page="${tab}"]`;
    document.querySelector(selector)?.classList.add('active');
  },

  async navigate(page, params = {}, pushHistory = true) {
    const started = window.performance?.now();
    if (this._authPending) return;
    if (window.DesktopCatalog?.pages.has(page) && !window.DesktopCatalog.enabled(page)) { page = 'home'; params = {}; pushHistory = false; this.selectedTab = 'home'; }
    DesktopSelect.close();
    const previous = this.captureRoute();
    this._searchData = null;
    window.DesktopCatalog?.dispose();
    window.DesktopSubtitles?.dispose();
    this._pageController?.abort();
    this._wallObserver?.disconnect();
    this._wallContext = null;
    this._pageController = new AbortController();
    this.pageAPI = API.scope(this._pageController.signal);
    const generation = ++this.viewGeneration;
    this._cardItems = new Map();
    // 记录历史（用于返回）
    if (pushHistory && (this.currentPage !== page || JSON.stringify(this.currentParams) !== JSON.stringify(params))) {
      delete previous.stack;
      this.navStack.push(previous);
    }
    this.currentPage = page;
    this.currentParams = params;
    this.setActiveNav(page, params.libraryId);
    const content = document.getElementById('content');

    switch (page) {
      case 'discover': case 'discoverCollection': case 'discoverDetail': case 'discoverPerson':
      case 'subscriptions': case 'subscriptionDetail':
        await window.DesktopCatalog.render(page, content, params, generation);
        break;
      case 'home':
        await this.renderHome(content, generation);
        break;
      case 'library':
        await this.renderLibrary(content, params.libraryId, generation);
        break;
      case 'collection':
        await this.renderCollection(content, params.collectionId, generation);
        break;
      case 'favorites':
        await this.renderFavorites(content, generation);
        break;
      case 'search':
        await this.renderSearch(content, params.query, generation, params.person);
        break;
      case 'rowWall':
        await this.renderRowWall(content, params.row, generation);
        break;
      case 'settings':
        this.renderSettings(content);
        break;
      case 'detail':
        await this.renderDetail(content, params, generation);
        break;
      case 'person':
        await this.renderPerson(content, params, generation);
        break;
    }
    if (this.isCurrent(generation)) {
      if (started != null) window.MovieClawPerf?.measure(page, window.performance.now() - started);
      content.scrollTop = this._routeRestore?.scrollTop || 0;
      this._routeRestore = null;
    }
  },

  goBack() {
    if (this.navStack.length > 0) {
      const prev = this.navStack.pop();
      this._routeRestore = prev;
      this.navigate(prev.page, prev.params, false);
    } else {
      this.navigate('home', {}, false);
    }
  },

  // ===== 首页（对齐 macOS 结构） =====
  homeQuery(row, page = {}) {
    return { ...page, ...(row.sort ? { sort: row.sort === 'unwatched_first' ? 'favorited_at' : row.sort, order: row.order } : {}),
      ...(row.sort === 'unwatched_first' ? { unwatched_first: true } : {}),
      ...(row.sort === 'last_played' ? { w: 'seen' } : row.unwatched ? { w: 'unwatched' } : {}),
      ...(row.genre ? { g: row.genre } : {}) };
  },

  async fetchHomeRow(api, row, page = { limit: 20, offset: 0 }) {
    const query = this.homeQuery(row, page);
    if (row.type === 'up-next') return api.getUpNext();
    if (row.type === 'favorites') return api.getFavorites(query);
    if (row.type === 'library') return api.listLibraryItems(row.library_id, query);
    if (row.type === 'collection') return api.listCollectionItems(row.collection_id, query);
    if (row.type === 'kind') return api.listKindItems(row.media_kind, query);
    if (row.type === 'genres') return api.listKindGenres(row.media_kind);
    return { data: this.libraries };
  },

  async renderRowWall(container, row, generation = this.viewGeneration) {
    const api = this.pageAPI || API;
    await this.renderPagedWall(container, { title: row.title, libraryId: row.library_id, generation,
      fetchPage: async page => this.offsetPage(await this.fetchHomeRow(api, row, { limit: page.limit, offset: page.offset }), page.limit) });
  },

  async renderHome(container, generation = this.viewGeneration) {
    const api = this.pageAPI || API;
    container.innerHTML = '<div class="page-loading" role="status"><div class="spinner"></div><span>正在载入首页…</span></div>';
    try {
      const rows = (this.homeRows || HomeRows.build([], this.libraries, this.collections)).filter(row => !row.hidden);
      const cache = new Map();
      const loaded = await Promise.all(rows.map(async row => {
        const key = JSON.stringify([row.type, row.library_id, row.collection_id, row.media_kind, this.homeQuery(row)]);
        if (!cache.has(key)) cache.set(key, this.fetchHomeRow(api, row));
        try { return { row, response: await cache.get(key) }; }
        catch (error) { if (error.name === 'AbortError' || error.status === 401) throw error; return { row, error }; }
      }));
      if (!this.isCurrent(generation)) return;
      this._homeData = { epoch: API.contextEpoch, rows: loaded };
      const continueItems = this.unwrapItems(loaded.find(entry => entry.row.type === 'up-next')?.response).slice(0, 20);
      const heroHtml = continueItems.length ? `<section class="hero-banner" id="heroBanner" aria-label="接下来继续">
        <div class="hero-bg"><img id="heroImg" alt="" data-raw=""></div>
        <div class="hero-info"><div id="heroIdentity"></div><div class="hero-meta" id="heroMeta"></div>
          <p class="hero-overview" id="heroOverview"></p><div class="hero-actions"><button class="btn-play" id="heroPlayBtn">${uiIcon('play')}<span>继续播放</span></button><button class="btn-secondary" id="heroDetailBtn">详情</button></div>
        </div><div class="hero-navigation"><button id="heroPrev" aria-label="上一部">${uiIcon('left')}</button><div id="heroDots"></div><button id="heroNext" aria-label="下一部">${uiIcon('right')}</button></div></section>` : '';
      const shelves = loaded.map(({ row, response, error }) => {
        if (error) return `<section class="shelf-section" data-home-row="${escapeHtml(row.id)}"><h2 class="shelf-title">${escapeHtml(row.title)}</h2><div class="empty-state" role="alert">${escapeHtml(error.message)} <button class="btn-secondary home-retry">重试</button></div></section>`;
        let cards = '';
        if (row.type === 'libraries') cards = this.libraries.map(lib => `<button class="library-tile" data-open-library="${Number(lib.id)}"><div class="library-cover">${libraryCover(lib.kind, '/libraries/' + Number(lib.id) + '/cover?w=600')}<div class="library-name-band"><strong>${escapeHtml(lib.name)}</strong><small>${Number(lib.stats?.item_count || 0)} 部</small></div></div></button>`).join('')
          + HomeRows.pinned(this.homeRows || []).map(collection => `<button class="library-tile collection-tile" data-open-collection="${Number(collection.id)}"><div class="library-cover">${libraryCover('collection', collection.covers?.length ? '/collections/' + Number(collection.id) + '/cover?w=600' : '')}<div class="library-name-band"><strong>${escapeHtml(collection.name)}</strong><small>${Number(collection.item_count || 0)} 部</small><span>合集</span></div></div></button>`).join('');
        else if (row.type === 'genres') cards = this.unwrapItems(response).map(genre => `<button class="genre-tile" data-kind="${escapeHtml(row.media_kind)}" data-genre="${escapeHtml(genre.value)}" data-label="${escapeHtml(genre.label)}"><img loading="lazy" src="${escapeHtml(resolveUrl(genre.cover_url))}" alt="" data-raw="${escapeHtml(genre.cover_url)}"><span>${escapeHtml(genre.label)}</span><small>${Number(genre.count || 0)} 部</small></button>`).join('');
        else {
          const items = this.filterMediaItems(this.unwrapItems(response)).slice(0, 20);
          cards = items.map(item => this.posterCard(item, row.library_id, row.type === 'up-next')).join('');
          if (items.length >= 20 && row.type !== 'up-next') cards += `<button class="see-all-card" data-open-row="${escapeHtml(row.id)}">查看全部 ${uiIcon('right')}</button>`;
        }
        if (!cards) return '';
        const title = ['up-next', 'libraries', 'genres'].includes(row.type) ? `<h2 class="shelf-title">${escapeHtml(row.title)}</h2>` : `<button class="shelf-title row-title" data-open-row="${escapeHtml(row.id)}">${escapeHtml(row.title)} ${uiIcon('right')}</button>`;
        return `<section class="shelf-section" data-home-row="${escapeHtml(row.id)}"><div class="shelf-header">${title}</div><div class="shelf-wrapper"><button class="shelf-arrow shelf-arrow-left" data-dir="-1" aria-label="向左">${uiIcon('left')}</button><div class="shelf-row ${row.type === 'up-next' ? 'continue-row' : ''}">${cards}</div><button class="shelf-arrow shelf-arrow-right" data-dir="1" aria-label="向右">${uiIcon('right')}</button></div></section>`;
      }).join('');
      container.innerHTML = heroHtml + shelves || '<div class="empty-state">暂无内容，请在服务器添加媒体库。</div>';
      this.bindPosterCards(container);
      container.querySelectorAll('[data-open-row]').forEach(button => button.addEventListener('click', () => {
        const row = rows.find(value => value.id === button.dataset.openRow);
        if (row.type === 'libraries') return this.selectTab('library', { libraryId: this.libraries[0]?.id });
        if (row.type === 'genres') return;
        this.navigate('rowWall', { row });
      }));
      container.querySelectorAll('[data-open-library]').forEach(button => button.addEventListener('click', () => this.navigate('library', { libraryId: Number(button.dataset.openLibrary) })));
      container.querySelectorAll('[data-open-collection]').forEach(button => button.addEventListener('click', () => this.navigate('collection', { collectionId: Number(button.dataset.openCollection) })));
      container.querySelectorAll('[data-genre]').forEach(button => button.addEventListener('click', () => this.navigate('rowWall', { row: { id: 'genre:' + button.dataset.genre, type: 'kind', title: button.dataset.label, media_kind: button.dataset.kind, genre: button.dataset.genre, sort: 'added_at', order: 'desc' } })));
      container.querySelectorAll('.home-retry').forEach(button => button.addEventListener('click', () => this.navigate('home', {}, false)));
      container.querySelectorAll('.shelf-arrow').forEach(button => button.addEventListener('click', () => {
        const shelf = button.closest('.shelf-wrapper').querySelector('.shelf-row');
        shelf.scrollBy({ left: Number(button.dataset.dir) * shelf.clientWidth * .75, behavior: this.reducedMotion() ? 'instant' : 'smooth' });
      }));
      container.querySelectorAll('.shelf-row').forEach(shelf => shelf.addEventListener('scroll', () => {
        shelf.dataset.scrolling = '1'; clearTimeout(shelf._scrollTimer);
        shelf._scrollTimer = setTimeout(() => { delete shelf.dataset.scrolling; }, 140);
      }, { passive: true }));
      if (!continueItems.length) return;
      let heroIndex = 0, heroRequest = 0, hoverTimer;
      const showHero = index => {
        if (!this.isCurrent(generation) || index < 0 || index >= continueItems.length) return;
        heroIndex = index; const item = continueItems[index], request = ++heroRequest;
        const raw = item.backdrop_url || item.episode_still_url || item.poster_url;
        const img = container.querySelector('#heroImg'); img.dataset.raw = raw || ''; delete img.dataset.retried; img.style.display = raw ? '' : 'none';
        if (raw) api.proxyImage(raw).then(uri => { if (this.isCurrent(generation) && request === heroRequest) img.src = uri || resolveUrl(raw); }).catch(() => {});
        container.querySelector('#heroIdentity').innerHTML = item.logo_url ? `<img class="hero-logo" src="${escapeHtml(resolveUrl(item.logo_url))}" alt="${escapeHtml(item.title)}" data-raw="${escapeHtml(item.logo_url)}" data-title-fallback><h1 class="hero-title" hidden>${escapeHtml(item.title)}</h1>` : `<h1 class="hero-title">${escapeHtml(item.title)}</h1>`;
        container.querySelector('#heroMeta').textContent = [item.year, ...(item.genres || []).slice(0, 2), item.kind === 'tv' ? `第 ${item.season_number} 季第 ${item.episode_number} 集 · ${item.episode_title || ''}` : null,
          item.duration_ms > item.position_ms ? `还剩 ${fmtRuntime(Math.ceil((item.duration_ms - item.position_ms) / 60000))}` : null].filter(Boolean).join(' · ');
        container.querySelector('#heroOverview').textContent = item.overview || '';
        container.querySelector('#heroDots').innerHTML = continueItems.slice(0, 12).map((_, n) => `<button class="hero-dot ${index === n ? 'active' : ''}" data-index="${n}" aria-label="第 ${n + 1} 部" aria-pressed="${index === n}"></button>`).join('');
        container.querySelectorAll('.hero-dot').forEach(button => button.addEventListener('click', () => showHero(Number(button.dataset.index))));
        container.querySelector('#heroPrev').disabled = index === 0; container.querySelector('#heroNext').disabled = index === continueItems.length - 1;
        container.querySelectorAll('.continue-card').forEach(card => card.classList.toggle('selected', continueItems.length > 1 && card.dataset.itemId === String(item.media_item_id)));
      };
      container.querySelector('#heroPrev').addEventListener('click', () => showHero(heroIndex - 1));
      container.querySelector('#heroNext').addEventListener('click', () => showHero(heroIndex + 1));
      container.querySelector('#heroPlayBtn').addEventListener('click', () => this.playCard(continueItems[heroIndex]));
      container.querySelector('#heroDetailBtn').addEventListener('click', () => { const item = continueItems[heroIndex]; this.navigate('detail', { libraryId: item.library_id, itemId: item.media_item_id }); });
      container.querySelectorAll('.continue-card').forEach(card => {
        card.addEventListener('mouseenter', () => { clearTimeout(hoverTimer); hoverTimer = setTimeout(() => {
          if (!this._scrolling && !card.closest('.shelf-row')?.dataset.scrolling) showHero(continueItems.findIndex(item => String(item.media_item_id) === card.dataset.itemId));
        }, 300); });
        card.addEventListener('mouseleave', () => clearTimeout(hoverTimer));
      });
      showHero(0);
    } catch (error) { this.renderPageError(container, error, generation); }
  },

  // 解包 API 响应：兼容 {data:[...]}, {data:{items:[...]}}, {items:[...]}, [...] 等
  unwrapItems(resp) {
    if (!resp) return [];
    if (Array.isArray(resp)) return resp;
    if (resp.data) {
      if (Array.isArray(resp.data)) return resp.data;
      if (resp.data.items && Array.isArray(resp.data.items)) return resp.data.items;
      if (Array.isArray(resp.data.results)) return resp.data.results;
      if (resp.data.episodes && Array.isArray(resp.data.episodes)) return resp.data.episodes;
    }
    if (resp.items && Array.isArray(resp.items)) return resp.items;
    if (resp.results && Array.isArray(resp.results)) return resp.results;
    if (resp.episodes && Array.isArray(resp.episodes)) return resp.episodes;
    return [];
  },

  // 过滤出真正的媒体项（排除合集、文件等非媒体条目）
  // 依据 LibraryItemView schema: media_item_id, kind(movie/tv/video), title 必须有
  filterMediaItems(items) {
    return items.filter(i => {
      if (!i) return false;
      if (!i.media_item_id) return false;
      if (!i.title) return false;
      // kind 只能是 movie/tv/video，排除合集等
      if (i.kind && !['movie', 'tv', 'video'].includes(i.kind)) return false;
      return true;
    });
  },

  // ===== 媒体库 / 合集 / 收藏 / 搜索：共享按需分页 =====
  async renderLibrary(container, libraryId, generation = this.viewGeneration) {
    const api = this.pageAPI || API;
    const lib = this.libraries.find(l => Number(l.id) === Number(libraryId));
    const prefs = this.wallPreferences('library-' + libraryId);
    await this.renderPagedWall(container, {
      title: lib?.name || '媒体库', libraryId, generation, prefs,
      preferenceId: 'library-' + libraryId, unwatched: true,
      fetchPage: async page => this.offsetPage(await api.listLibraryItems(libraryId, {
        offset: page.offset, limit: page.limit, sort: prefs.sort, order: prefs.order,
        ...(prefs.unwatched ? { w: 'unwatched' } : {}),
      }), page.limit, prefs.unwatched ? undefined : lib?.stats?.item_count),
    });
  },

  async renderCollection(container, collectionId, generation = this.viewGeneration) {
    const api = this.pageAPI || API;
    const collection = this.collections.find(c => Number(c.id) === Number(collectionId));
    const prefs = this.wallPreferences('collection-' + collectionId, 'default');
    await this.renderPagedWall(container, {
      title: collection?.name || '合集', generation, prefs, preferenceId: 'collection-' + collectionId,
      fetchPage: async page => this.offsetPage(await api.listCollectionItems(collectionId, {
        offset: page.offset, limit: page.limit,
        ...(prefs.sort !== 'default' ? { sort: prefs.sort, order: prefs.order } : {}),
      }), page.limit),
    });
  },

  async renderFavorites(container, generation = this.viewGeneration) {
    const api = this.pageAPI || API;
    const prefs = this.wallPreferences('favorites', 'favorited_at');
    await this.renderPagedWall(container, {
      title: '我的收藏', generation, prefs, preferenceId: 'favorites',
      fetchPage: async page => this.offsetPage(await api.getFavorites({
        offset: page.offset, limit: page.limit, sort: prefs.sort, order: prefs.order,
      }), page.limit),
    });
  },

  recentSearches() {
    const key = 'mc_search.' + API.baseUrl + '#' + (this.session?.username || '');
    let items = []; try { items = JSON.parse(localStorage.getItem(key) || '[]'); } catch (_) {}
    return { key, items: Array.isArray(items) ? items.filter(item => typeof item === 'string').slice(0, 10) : [] };
  },

  rememberSearch(query) {
    if (!query?.trim()) return;
    const recent = this.recentSearches();
    localStorage.setItem(recent.key, JSON.stringify([query.trim(), ...recent.items.filter(value => value !== query.trim())].slice(0, 10)));
  },

  async renderSearch(container, query, generation = this.viewGeneration, person) {
    const api = this.pageAPI || API;
    const hidden = new Set((this.uiPreferences?.home?.rows || []).filter(row => row.hidden)
      .map(row => Number(row.library_id ?? (row.id?.startsWith('lib:') ? row.id.slice(4) : 0))));
    const libraryIds = this.libraries.filter(lib => !lib.exclude_from_home && !hidden.has(Number(lib.id))
      && !lib.adult && !lib.is_adult && !/(?:\b(?:AV|JAV|NSFW|XXX)\b|成人|色情)/i.test(lib.name || ''))
      .map(lib => Number(lib.id));
    const allowed = new Set(libraryIds);
    if (!query?.trim()) {
      const recent = this.recentSearches();
      container.innerHTML = `<div class="page-header"><h1 class="page-title">搜索</h1></div><div class="search-idle"><p>搜索片名、演员、导演或类型</p>${recent.items.length ? `<h2>最近搜索 <button class="text-button" id="clearRecentSearches">清除</button></h2><div class="search-chips">${recent.items.map(value => `<button data-recent-query="${escapeHtml(value)}">${escapeHtml(value)}</button>`).join('')}</div>` : ''}</div>`;
      container.querySelectorAll('[data-recent-query]').forEach(button => button.addEventListener('click', () => { document.getElementById('searchInput').value = button.dataset.recentQuery; this.navigate('search', { query: button.dataset.recentQuery }, false); }));
      container.querySelector('#clearRecentSearches')?.addEventListener('click', () => { localStorage.setItem(recent.key, '[]'); this.renderSearch(container, '', generation); });
      return;
    }
    let people = this._routeRestore?.search?.people || [], suggestions = this._routeRestore?.search?.suggestions || [];
    this._searchData = { people, suggestions };
    const updateHeader = () => {
      const filters = container.querySelector('#searchFilters');
      if (!filters) return;
      filters.innerHTML = `${person ? `<div class="person-filter">正在找 ${escapeHtml(person.name)} 的作品 <button class="text-button" id="clearPersonFilter">返回全部结果</button></div>` : ''}
        ${people.length ? `<div class="search-chips people-chips" aria-label="人物匹配">${people.map(value => `<button data-search-person="${Number(value.person_id ?? value.id)}"><strong>${escapeHtml(value.name)}</strong><small>${Number(value.item_count || 0)} 部作品${value.match?.label ? ' · ' + escapeHtml(value.match.label) : ''}</small></button>`).join('')}</div>` : ''}
        ${suggestions.length ? `<div class="search-chips suggestions" aria-label="搜索建议">你可能想找：${suggestions.map(value => { const text = typeof value === 'string' ? value : value.query || value.text || value.label || ''; return `<button data-suggestion="${escapeHtml(text)}">${escapeHtml(text)}</button>`; }).join('')}</div>` : ''}`;
      filters.querySelector('#clearPersonFilter')?.addEventListener('click', () => this.navigate('search', { query }, false));
      filters.querySelectorAll('[data-search-person]').forEach(button => button.addEventListener('click', () => {
        const value = people.find(value => Number(value.person_id ?? value.id) === Number(button.dataset.searchPerson));
        this.rememberSearch(query); this.navigate('search', { query, person: { id: Number(button.dataset.searchPerson), name: value.name } }, false);
      }));
      filters.querySelectorAll('[data-suggestion]').forEach(button => button.addEventListener('click', () => {
        document.getElementById('searchInput').value = button.dataset.suggestion;
        this.navigate('search', { query: button.dataset.suggestion }, false);
      }));
    };
    await this.renderPagedWall(container, {
      title: `“${query}” 的搜索结果`, generation, header: '<div id="searchFilters"></div>', afterPage: updateHeader,
      fetchPage: async page => {
        if (!libraryIds.length) return { items: [], hasMore: false };
        const response = await api.search(query, { library_ids: libraryIds, home_only: true, exclude_adult: true,
          limit: page.limit, ...(page.cursor ? { cursor: page.cursor } : {}), ...(person ? { person_id: person.id } : {}) });
        const data = response?.data || response || {};
        if (!page.cursor) {
          // Older servers ignore scoped-search parameters. Never show their unscoped
          // people/suggestions, which could disclose names from excluded libraries.
          const scoped = data.exclude_adult === true && Array.isArray(data.scope_library_ids)
            && data.scope_library_ids.every(id => allowed.has(Number(id)));
          people = scoped ? data.people || [] : []; suggestions = scoped ? data.suggestions || [] : [];
          if (this.isCurrent(generation)) this._searchData = { people, suggestions };
        }
        return {
          items: this.filterMediaItems((data.items || []).flatMap(hit => {
            const item = hit.item || {}, id = (hit.library_ids || [item.library_id]).find(id => allowed.has(Number(id)));
            if (!id || item.adult || item.is_adult || /^(?:XXX|X|R18\+?|NC-17|ADULT|成人)$/i.test(item.content_rating || '')) return [];
            return [{ ...item, library_id: Number(id), source_missing: false, match_label: hit.match?.label }];
          })), cursor: data.next_cursor, hasMore: !!data.next_cursor,
        };
      },
    });
    updateHeader();
  },

  offsetPage(response, limit, knownTotal) {
    const raw = this.unwrapItems(response);
    const total = (response?.data || response)?.total ?? knownTotal;
    return { items: this.filterMediaItems(raw), rawCount: raw.length, hasMore: raw.length === limit, total };
  },

  wallPreferences(id, defaultSort = 'added_at') {
    const key = 'mc_wall.' + API.baseUrl + '#' + (this.session?.username || '') + '.' + id;
    let stored = {};
    try { stored = JSON.parse(localStorage.getItem(key) || '{}'); } catch (_) {}
    const allowed = ['added_at', 'release_date', 'rating', 'title'];
    if (id.startsWith('collection-')) allowed.push('default');
    if (id === 'favorites') allowed.push('favorited_at');
    return { key, sort: allowed.includes(stored.sort) ? stored.sort : defaultSort,
      order: stored.order === 'asc' ? 'asc' : 'desc', unwatched: stored.unwatched === true };
  },

  async renderPagedWall(container, { title, libraryId, generation, prefs, preferenceId, unwatched = false, fetchPage, header = '', afterPage }) {
    const sorts = [['added_at', '最近添加'], ['release_date', '最近上映'], ['rating', '评分'], ['title', '片名']];
    if (preferenceId?.startsWith('collection')) sorts.unshift(['default', '合集顺序']);
    if (preferenceId === 'favorites') sorts.unshift(['favorited_at', '最近收藏']);
    container.innerHTML = `${this.navStack.length ? '<button class="text-button wall-back" id="wallBack">‹ 返回</button>' : ''}<div class="page-header"><h1 class="page-title">${escapeHtml(title)}</h1><span class="page-subtitle" id="wallCount"></span>
      ${prefs ? `<div class="wall-toolbar"><select id="wallSort" class="settings-select" aria-label="排序">${sorts.map(([value, label]) => `<option value="${value}" ${prefs.sort === value ? 'selected' : ''}>${label}</option>`).join('')}</select>
        <select id="wallOrder" class="settings-select" aria-label="排序方向"><option value="desc" ${prefs.order === 'desc' ? 'selected' : ''}>降序</option><option value="asc" ${prefs.order === 'asc' ? 'selected' : ''}>升序</option></select>
        ${unwatched ? `<label><input type="checkbox" id="wallUnwatched" ${prefs.unwatched ? 'checked' : ''}> 只看没看过的</label>` : ''}</div>` : ''}</div>
      ${header}<div class="poster-wall"><div class="poster-grid" id="posterGrid"></div><div id="wallStatus" class="empty-state" role="status"></div><div id="wallSentinel" style="height:1px"></div></div>`;
    const grid = container.querySelector('#posterGrid');
    const status = container.querySelector('#wallStatus');
    const count = container.querySelector('#wallCount');
    container.querySelector('#wallBack')?.addEventListener('click', () => this.goBack());
    DesktopSelect.enhance(container);
    const pager = new DesktopPager(fetchPage, () => this.isCurrent(generation));
    const virtual = typeof requestAnimationFrame === 'function' && grid.clientWidth > 0;
    if (virtual) pager.enableWindow(12);
    this._wallPager = pager;
    const wall = this._wallContext = { pager, grid, count, container, libraryId, generation, prefs, refreshing: false };
    let renderRequest = 0, animationFrame = null;
    const renderItems = async () => {
      const request = ++renderRequest;
      let start = 0, end = pager.items.length, top = 0, bottom = 0;
      if (virtual && pager.items.length > 360) {
        const columns = Math.max(1, getComputedStyle(grid).gridTemplateColumns.split(' ').length);
        const width = (grid.clientWidth - 18 * (columns - 1)) / columns;
        const rowHeight = grid.querySelector('.poster-card')?.getBoundingClientRect().height + 26 || width * 1.5 + 70;
        const targetScroll = this._routeRestore?.scrollTop ?? container.scrollTop;
        const firstRow = Math.max(0, Math.floor((targetScroll - grid.offsetTop) / rowHeight) - 3);
        const visibleRows = Math.ceil(container.clientHeight / rowHeight) + 6;
        start = Math.min(firstRow * columns, Math.floor(Math.max(0, pager.items.length - 1) / columns) * columns);
        end = Math.min(pager.items.length, start + Math.min(360, visibleRows * columns));
        top = Math.max(0, Math.floor(start / columns) * rowHeight - 26);
        bottom = Math.max(0, (Math.ceil(pager.items.length / columns) - Math.ceil(end / columns)) * rowHeight - 26);
        grid.dataset.virtual = 'true';
      } else delete grid.dataset.virtual;
      const signature = [start, end, pager.items.length, Math.round(top), Math.round(bottom)].join(':');
      if (wall.renderSignature === signature) return;
      await pager.hydrateRange(start, end);
      if (!this.isCurrent(generation) || request !== renderRequest) return;
      this._cardItems = new Map();
      grid.innerHTML = (top ? `<div class="wall-spacer" aria-hidden="true" style="height:${top}px"></div>` : '')
        + pager.items.slice(start, end).map(item => this.posterCard(item, libraryId)).join('')
        + (bottom ? `<div class="wall-spacer" aria-hidden="true" style="height:${bottom}px"></div>` : '');
      wall.firstIndex = start; wall.lastIndex = end;
      wall.renderSignature = signature;
      this.bindPosterCards(grid);
    };
    wall.render = renderItems;
    if (virtual) {
      const schedule = () => {
        if (animationFrame != null || !this.isCurrent(generation)) return;
        animationFrame = requestAnimationFrame(() => { animationFrame = null; renderItems().catch(error => { if (this.isCurrent(generation) && error.name !== 'AbortError') status.textContent = '无法载入这一页：' + error.message; }); });
      };
      container.addEventListener('scroll', schedule, { passive: true, signal: this._pageController.signal });
      window.addEventListener('resize', schedule, { signal: this._pageController.signal });
    }
    const load = async () => {
      if (wall.refreshing || pager.loading || !pager.hasMore || !this.isCurrent(generation)) return;
      status.textContent = '加载中…';
      try {
        const added = await pager.loadMore();
        if (!this.isCurrent(generation)) return;
        if (virtual) await renderItems();
        else { grid.insertAdjacentHTML('beforeend', added.map(item => this.posterCard(item, libraryId)).join('')); this.bindPosterCards(grid); }
        afterPage?.();
        count.textContent = pager.total != null ? `${pager.total} 个项目` : `${pager.items.length}${pager.hasMore ? '+' : ''} 个项目`;
        status.textContent = pager.items.length ? (pager.hasMore ? '' : '已加载全部') : '这里还没有内容';
        if (!pager.hasMore) this._wallObserver?.disconnect();
        else if (this._wallObserver && container.querySelector('#wallSentinel').getBoundingClientRect().top <= container.getBoundingClientRect().bottom + 400) {
          queueMicrotask(load);
        }
      } catch (error) {
        if (!this.isCurrent(generation) || error.name === 'AbortError' || error.status === 401) return;
        status.textContent = error.message;
        const retry = document.createElement('button');
        retry.className = 'btn-secondary'; retry.textContent = '重试';
        retry.addEventListener('click', () => { status.textContent = ''; load(); });
        status.appendChild(retry);
      }
    };
    wall.load = load;
    if (prefs) {
      const changed = async event => {
        prefs.sort = container.querySelector('#wallSort').value;
        prefs.order = container.querySelector('#wallOrder').value;
        prefs.unwatched = container.querySelector('#wallUnwatched')?.checked || false;
        localStorage.setItem(prefs.key, JSON.stringify({ sort: prefs.sort, order: prefs.order, unwatched: prefs.unwatched }));
        await this.navigate(this.currentPage, this.currentParams, false);
        document.getElementById(event.target.id + 'Trigger')?.focus();
      };
      container.querySelectorAll('#wallSort,#wallOrder,#wallUnwatched').forEach(input => input.addEventListener('change', changed));
    }
    const restored = this._routeRestore?.wall;
    if (restored) {
      Object.assign(pager, restored);
      pager.cachedPages = new Map();
      for (const record of pager.pageRecords) if (pager.items.slice(record.start, record.end).every(item => !item._evicted)) pager.keepPage(record);
      container.scrollTop = this._routeRestore.scrollTop || 0;
      if (virtual) await renderItems();
      else { grid.innerHTML = pager.items.map(item => this.posterCard(item, libraryId)).join(''); this.bindPosterCards(grid); }
      count.textContent = pager.total != null ? `${pager.total} 个项目` : `${pager.items.length}${pager.hasMore ? '+' : ''} 个项目`;
      status.textContent = pager.hasMore ? '' : '已加载全部';
      afterPage?.();
    } else await load();
    if (!this.isCurrent(generation) || !pager.hasMore) return;
    if (typeof IntersectionObserver !== 'undefined') {
      this._wallObserver = new IntersectionObserver(entries => {
        if (entries.some(entry => entry.isIntersecting)) load();
      }, { root: container, rootMargin: '400px' });
      this._wallObserver.observe(container.querySelector('#wallSentinel'));
    }
  },

  async refreshStoppedItem({ mediaItemId, libraryId, seasonNumber, episodeNumber }) {
    if (this._authPending || this._changingContext) return;
    if (this.currentPage === 'home' || (this.currentPage === 'detail'
        && Number(this.currentParams?.itemId) === Number(mediaItemId)
        && Number(this.currentParams?.libraryId) === Number(libraryId))) {
      await this.navigate(this.currentPage, this.currentParams || {}, false);
      return;
    }
    const wall = this._wallContext;
    if (!wall || wall.refreshing || !this.isCurrent(wall.generation)) return;
    const item = wall.pager.items.find(value => Number(value.media_item_id) === Number(mediaItemId)
      && Number(value.library_id ?? wall.libraryId) === Number(libraryId));
    if (!item) return;
    wall.refreshing = true;
    const pendingOffset = wall.pager.loading ? wall.pager.offset : null;
    try {
      // Keep the existing pages and scroll position; pause the next batch while a watched filter changes.
      await wall.pager.inFlight?.catch(() => {});
      const api = this.pageAPI;
      const [marksResponse, resumeResponse] = await Promise.all([
        api.getMarks(mediaItemId), api.getResume(mediaItemId, seasonNumber, episodeNumber),
      ]);
      if (wall !== this._wallContext || !this.isCurrent(wall.generation)) return;
      const marks = marksResponse?.data || marksResponse;
      const resume = resumeResponse?.data || resumeResponse;
      const card = wall.grid.querySelector(`[data-item-id="${Number(mediaItemId)}"][data-library-id="${Number(libraryId)}"]`);
      if (wall.prefs?.unwatched && marks?.played) {
        wall.pager.removeAt(wall.pager.items.indexOf(item));
        wall.pager.offset = Math.max(0, wall.pager.offset - 1);
        if (wall.pager.total != null) wall.pager.total = Math.max(0, wall.pager.total - 1);
        card?.remove();
        if (pendingOffset != null && pendingOffset > 0) {
          // A batch already in flight may have observed the removal before we adjusted its offset.
          const boundary = await wall.pager.fetchPage({ offset: pendingOffset - 1, cursor: null, limit: 1 });
          if (wall !== this._wallContext || !this.isCurrent(wall.generation)) return;
          const repair = boundary.items.find(value => !wall.pager.items.some(known => known.media_item_id === value.media_item_id));
          if (repair) {
            const index = Math.min(pendingOffset - 1, wall.pager.items.length);
            wall.pager.insertAt(index, repair);
            wall.pager.offset++;
            const next = wall.pager.items[index + 1];
            const nextCard = next && wall.grid.querySelector(`[data-item-id="${Number(next.media_item_id)}"]`);
            if (nextCard) nextCard.insertAdjacentHTML('beforebegin', this.posterCard(repair, wall.libraryId));
            else wall.grid.insertAdjacentHTML('beforeend', this.posterCard(repair, wall.libraryId));
            this.bindPosterCards(wall.grid);
          }
        }
        wall.count.textContent = wall.pager.total != null ? `${wall.pager.total} 个项目` : `${wall.pager.items.length}${wall.pager.hasMore ? '+' : ''} 个项目`;
        if (wall.grid.dataset?.virtual) await wall.render();
      } else {
        item.is_favorite = marks?.is_favorite ?? item.is_favorite;
        item.progress_percent = !resume?.played && resume?.duration_ms > 0
          ? Math.max(0, Math.min(99, Math.round(resume.position_ms / resume.duration_ms * 100))) : null;
        if (card) card.outerHTML = this.posterCard(item, wall.libraryId);
        this.bindPosterCards(wall.grid);
      }
    } catch (error) {
      if (error.name !== 'AbortError' && error.status !== 401) console.warn('Playback state refresh failed:', error.message);
    } finally {
      wall.refreshing = false;
      if (wall === this._wallContext && this.isCurrent(wall.generation)
          && wall.container.querySelector('#wallSentinel').getBoundingClientRect().top <= wall.container.getBoundingClientRect().bottom + 400) wall.load();
    }
  },

  renderPageError(container, error, generation) {
    if (!this.isCurrent(generation) || error.name === 'AbortError' || error.status === 401) return;
    container.innerHTML = `<div class="empty-state"><p>${escapeHtml(error.message || '加载失败')}</p><button class="btn-secondary" id="retryPage">重试</button></div>`;
    container.querySelector('#retryPage').addEventListener('click', () => this.navigate(this.currentPage, this.currentParams, false));
  },

  // ===== 人物页 =====
  async renderPerson(container, params, generation = this.viewGeneration) {
    const api = this.pageAPI || API;
    container.innerHTML = '<div class="page-loading"><div class="spinner"></div></div>';
    try {
      const resp = await api.getPerson(params.personId);
      if (!this.isCurrent(generation)) return;
      const person = resp?.data || resp;

      // 加载作品
      const credits = person.credits || [];
      const sections = [['参演', credits.filter(c => c.department === 'cast')], ['执导', credits.filter(c => c.department === 'director')]].filter(([, items]) => items.length);
      const avatar = person.avatar_url || person.profile_url;

      container.innerHTML = `
        ${avatar ? `<div class="person-backdrop" aria-hidden="true"><img src="${escapeHtml(resolveUrl(avatar))}" alt="" data-raw="${escapeHtml(avatar)}"></div>` : ''}
        <div class="person-hero">
          <button class="detail-back-btn" id="personBack" aria-label="返回">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>
          </button>
          <div class="person-header">
            ${person.avatar_url || person.profile_url ? `
              <img class="person-avatar" src="${escapeHtml(resolveUrl(person.avatar_url || person.profile_url))}" alt="" data-raw="${escapeHtml(person.avatar_url || person.profile_url)}" data-fade style="opacity:0;transition:opacity 0.3s">
            ` : `<div class="person-avatar person-avatar-placeholder" aria-hidden="true">${escapeHtml((person.name || '?').slice(0, 1))}</div>`}
            <div class="person-info">
              <h1 class="person-name">${escapeHtml(person.name)}</h1>
              <div class="person-meta">
                ${person.original_name && person.original_name !== person.name ? `<span>${escapeHtml(person.original_name)}</span>` : ''}
                ${credits.length ? `<span>库内 ${new Set(credits.map(c => c.media_item_id)).size} 部${sections.length > 1 ? sections.map(([title, items]) => ` · ${title} ${items.length}`).join('') : ''}</span>` : ''}
              </div>
            </div>
          </div>
        </div>
        ${sections.map(([title, items]) => `<div class="person-works"><h2 class="shelf-title" style="margin-bottom:16px">${title}</h2><div class="poster-grid">
          ${items.map(item => this.posterCard({ ...item, source_missing: item.library_id == null,
            match_label: item.library_id == null ? '片源已移除' : item.department === 'director' ? (item.kind === 'tv' ? '主创' : '导演') : item.character ? '饰 ' + item.character : '',
          }, item.library_id)).join('')}</div></div>`).join('') || '<div class="empty-state"><p>库内没有这位影人的作品</p></div>'}
      `;
      container.querySelector('#personBack').addEventListener('click', () => this.goBack());
      this.bindPosterCards(container);
      container.querySelectorAll('.poster-card').forEach(card => {
        if (String(params.fromItem || '') !== card.dataset.itemId) return;
        card.dataset.currentItem = 'true';
        card.querySelector('.poster-art').insertAdjacentHTML('beforeend', '<div class="series-badge">本片</div>');
      });
    } catch (e) {
      if (!this.isCurrent(generation) || e.name === 'AbortError') return;
      if (e.status === 404) {
        container.innerHTML = '<div class="empty-state"><p>库内没有这位影人的作品</p><p>作品可能已被移除，或尚未建立影人档案。</p><button class="btn-secondary" id="personBack">返回</button></div>';
        container.querySelector('#personBack').addEventListener('click', () => this.goBack());
      } else this.renderPageError(container, e, generation);
    }
  },

  // ===== 详情页 =====
  // 版式对齐 macOS（apps/apple MacItemDetailView，docs/design/macos-app.md §4.4）：
  // 头图 = Logo、年份类型片长与画质小标签、第几集、三行简介、写明「继续 第 1 季
  // 第 3 集 · 12:34」的主按钮与「从头播放」，右下角浮「导演 / 主演」；
  // 下面 = 分集横排 → 系列 → 演职员 → 合集 → 信息。头图讲的那一集与下面浏览的
  // 那一季是两套状态：换季只换分集横排。
  async renderDetail(container, params, generation = this.viewGeneration) {
    const api = this.pageAPI || API;
    // 详情页一出现就预连（对齐 macOS PlaybackPreconnect.warm）：进了详情紧接着多半就是点播放
    api.preconnectPlayback();
    container.innerHTML = '<div class="page-loading"><div class="spinner"></div></div>';
    try {
      const resp = await api.getItemDetail(params.libraryId, params.itemId);
      if (!this.isCurrent(generation)) return;
      const info = resp?.data || resp;
      const meta = info.local_meta || {};
      const isMovie = info.kind !== 'tv';
      const genres = meta.genres || [];
      const plot = meta.plot || '';
      const runtime = meta.runtime_minutes || null;
      const mediaId = info.media_item_id;

      const inPlace = (info.files || []).filter(f => f.state === 'in_place');
      const badges = this.bestMediaBadges(inPlace);
      const cast = this.castPeople(meta);
      const backdropRaw = info.backdrop_url || info.poster_url || '';
      const logoRaw = info.logo_url || '';
      const seasonCount = (info.seasons || []).filter(s => s > 0).length;

      const st = {
        season: null, episode: null,      // 头图正讲的那一集
        browseSeason: null, browseEpisodes: [], episodesLoading: false,
        watched: null,                    // 头图单元的续播点（PlaybackStateView）
        favorite: false, marking: false,
      };

      const canPlay = () => (isMovie ? inPlace.length > 0 : st.episode?.owned === true);

      container.innerHTML = `
        <div class="detail-hero">
          <div class="detail-hero-bg">
            <img src="${escapeHtml(resolveUrl(backdropRaw))}" alt="" style="opacity:0;transition:opacity 0.4s" data-raw="${escapeHtml(backdropRaw)}" data-fade>
          </div>
          <button class="detail-back-btn" id="btnBack" title="返回 (Esc)">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>
          </button>
          <div class="detail-stage">
            <div class="detail-stage-main" id="detailStage"></div>
            ${this.detailCreditsHtml(cast)}
          </div>
        </div>
        <div class="detail-body">
          <div class="detail-body-bg"><img src="${escapeHtml(resolveUrl(backdropRaw))}" alt="" data-raw="${escapeHtml(backdropRaw)}"></div>
          <div class="detail-lower">
            <div id="detailSeasonArea"></div>
            <div id="detailSeriesArea"></div>
            <section id="detailTracks" class="detail-section"></section>
            ${cast.length ? this.shelfHtml('演职员', null, 'cast-row', cast.map(p => this.personCardHtml(p)).join('')) : ''}
            ${info.collections?.length ? `
              <div class="detail-section">
                <h2 class="shelf-title">所属合集</h2>
                <div class="collection-chips">
                  ${info.collections.map(c => `<a class="collection-chip" data-collection-id="${Number(c.id)}" href="#">${escapeHtml(c.name)}</a>`).join('')}
                </div>
              </div>
            ` : ''}
            ${this.detailInfoHtml(info, meta, inPlace, isMovie, seasonCount)}
          </div>
        </div>
      `;

      const trackPanel = window.DesktopSubtitles?.mount({
        host: document.getElementById('detailTracks'), api, session: this.session,
        alive: () => this.isCurrent(generation), signal: this._pageController?.signal,
        refresh: async () => {
          const response = await api.getItemDetail(params.libraryId, mediaId);
          if (!this.isCurrent(generation)) return;
          info.files = (response?.data || response).files || [];
          renderStage();
        },
      });
      const updateTracks = () => {
        const key = isMovie ? 'movie' : `${st.season}:${st.episode?.episode_number}`;
        const files = (info.files || []).filter(file => file.state === 'in_place' &&
          (isMovie || Number(file.season_number) === Number(st.season) && Number(file.episode_number) === Number(st.episode?.episode_number)));
        trackPanel?.setFiles(files, key);
      };
      const selectedTracks = (season, episode) => {
        const key = isMovie ? 'movie' : `${season}:${episode}`;
        return trackPanel?.selection(key) || {};
      };

      // ---- 头图（Logo / 画质标签 / 第几集 / 简介 / 按钮）----
      const renderStage = () => {
        if (!this.isCurrent(generation)) return;
        updateTracks();
        const ep = st.episode;
        const overview = (isMovie ? plot : (ep?.overview || plot) || '').trim();
        const position = st.watched?.position_ms || 0;
        const finished = st.watched?.played || false;
        const playable = canPlay();
        const resumable = playable && position > 0;
        const verb = resumable ? '继续' : finished ? '重新播放' : '播放';
        const unit = !isMovie && ep
          ? (st.season === 0 ? `特别篇第 ${ep.episode_number} 集` : `第 ${st.season} 季第 ${ep.episode_number} 集`)
          : null;
        const parts = [verb, unit, resumable ? fmtClock(position) : null].filter(Boolean);
        const label = parts.length > 2 ? `${parts[0]} ${parts[1]} · ${parts[2]}` : parts.join(' ');
        const metaLine = [
          info.year || null,
          ...genres.slice(0, 2),
          isMovie
            ? (runtime ? fmtRuntime(runtime) : null)
            : (seasonCount >= 2 ? `共 ${seasonCount} 季` : null),
        ].filter(Boolean).join(' · ');
        const hint = playable ? '' : (isMovie
          ? '片源已移除，暂时不能播放'
          : ((info.seasons || []).length ? '这一集还没有片源，在下面挑别的集' : '这部剧还没有可播放的分集'));

        replaceContentPreservingImages(document.getElementById('detailStage'), `
          ${logoRaw
            ? `<img class="detail-logo" src="${escapeHtml(resolveUrl(logoRaw))}" alt="${escapeHtml(info.title)}" data-raw="${escapeHtml(logoRaw)}" data-title-fallback>
               <h1 class="detail-title" id="detailTitleFallback" hidden>${escapeHtml(info.title)}</h1>`
            : `<h1 class="detail-title">${escapeHtml(info.title)}</h1>`}
          ${metaLine || badges.length ? `
            <div class="detail-meta">
              ${metaLine ? `<span class="detail-meta-text">${escapeHtml(metaLine)}</span>` : ''}
              ${badges.map(b => `<span class="quality-badge${b.filled ? '' : ' outlined'}">${escapeHtml(b.text)}</span>`).join('')}
            </div>
          ` : ''}
          ${!isMovie && ep ? `<div class="detail-episode-line">${escapeHtml(this.episodeLine(st.season, ep))}</div>` : ''}
          ${overview ? `<p class="detail-hero-overview">${escapeHtml(overview)}</p>` : ''}
          ${hint ? `<div class="detail-hint">${hint}</div>` : ''}
          <div class="detail-actions">
            ${playable ? `
              <button class="btn-play" id="btnPlay">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
                <span>${escapeHtml(label)}</span>
              </button>
              ${resumable ? `
                <button class="btn-secondary" id="btnRestart" title="从头播放">
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/></svg>
                  <span>从头播放</span>
                </button>
              ` : ''}
            ` : ''}
            <button class="btn-icon ${st.favorite ? 'active' : ''}" id="btnFavorite" title="${st.favorite ? '取消收藏' : '收藏'}">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                <path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/>
              </svg>
            </button>
            ${playable ? `
              <button class="btn-icon ${finished ? 'active' : ''}" id="btnMarkWatched" title="${finished ? '标为未看' : '标为已看'}">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                  <circle cx="12" cy="12" r="10"/><polyline points="9 12 11 14 15 10"/>
                </svg>
              </button>
            ` : ''}
          </div>
        `);
        document.getElementById('btnPlay')?.addEventListener('click', () => playUnit(null));
        document.getElementById('btnRestart')?.addEventListener('click', () => playUnit(0));
        document.getElementById('btnFavorite')?.addEventListener('click', () => toggleFavorite());
        document.getElementById('btnMarkWatched')?.addEventListener('click', () => togglePlayed());
      };

      // ---- 续播点 / 收藏 / 已看 ----
      const loadUnitResume = async () => {
        const request = st.resumeRequest = (st.resumeRequest || 0) + 1;
        try {
          const resp2 = await api.getResume(
            mediaId,
            isMovie ? null : st.season,
            isMovie ? null : st.episode?.episode_number,
          );
          if (!this.isCurrent(generation) || request !== st.resumeRequest) return;
          st.watched = resp2?.data || resp2 || null;
        } catch (error) {
          if (!this.isCurrent(generation) || request !== st.resumeRequest || error.name === 'AbortError') return;
          st.watched = null;
        }
        renderStage();
      };

      const toggleFavorite = async () => {
        if (st.marking) return;
        st.marking = true;
        const next = !st.favorite;
        st.favorite = next;
        renderStage();
        try {
          const resp2 = await api.setMarks(mediaId, { favorite: next });
          if (!this.isCurrent(generation)) return;
          st.favorite = (resp2?.data || resp2)?.is_favorite ?? next;
        } catch (e) {
          console.error('Favorite toggle failed:', e);
          st.favorite = !next;
        }
        st.marking = false;
        renderStage();
      };

      const togglePlayed = async () => {
        if (st.marking || !canPlay()) return;
        st.marking = true;
        try {
          await api.setMarks(mediaId, {
            played: !(st.watched?.played || false),
            seasonNumber: isMovie ? null : st.season,
            episodeNumber: isMovie ? null : st.episode?.episode_number,
          });
          if (!this.isCurrent(generation)) return;
          await loadUnitResume();
          if (!isMovie && st.season != null) await loadBrowse(st.season);
        } catch (e) { console.error('Mark watched failed:', e); }
        st.marking = false;
      };

      // ---- 起播 ----
      const playUnit = (startMs, season, ep) => {
        if (!this.isCurrent(generation)) return;
        if (isMovie) {
          // library_id 必传：startPlayback 自动选集用它查详情判断 kind；
          // files/kind 也带上：能力申报分级要用 files 判片源吃不吃得下，
          // kind 让起播链不必再为「是不是剧集」查一遍详情
          this.startPlayback({ media_item_id: mediaId, title: info.title, library_id: params.libraryId, startMs, files: info.files, kind: info.kind, ...selectedTracks() });
          return;
        }
        const useSeason = season ?? st.season;
        const useEp = ep || st.episode;
        if (!useEp || !(ep ? useEp.owned : canPlay())) return;
        // Headline follows the explicit choice; stop reporting refreshes this item on return.
        if (ep && (ep !== st.episode || useSeason !== st.season)) {
          st.season = useSeason;
          st.episode = useEp;
          st.browseRange = EpisodeRanges.index(useEp.episode_number);
          loadUnitResume();
          renderEpisodeShelf(); // 头图跟到这一集，横排的舞台环也要跟着挪
        }
        this.startPlayback({
          media_item_id: mediaId,
          title: `${info.title} S${useSeason}E${useEp.episode_number}`,
          library_id: params.libraryId,
          seasonNumber: useSeason,
          episodeNumber: useEp.episode_number,
          startMs,
          files: info.files,
          // 同季剧集表：播放器的上一集/下一集与自动下一集都按它算（服务端会话不带
          // next_episode，PlaybackSessionView 里压根没这个字段）
          episodes: st.browseEpisodes,
          ...selectedTracks(useSeason, useEp.episode_number),
        });
      };

      // ---- 分集横排（标题 + 「共 N 集 · 已看 · 缺」）----
      const renderEpisodeShelf = () => {
        if (!this.isCurrent(generation)) return;
        const area = document.getElementById('detailSeasonArea');
        if (!area) return;
        const eps = st.browseEpisodes;
        const ranges = EpisodeRanges.ranges(eps);
        if (ranges.length && !ranges.some(range => range.index === st.browseRange)) {
          const anchor = eps.find(ep => ep.episode_number === st.browseAnchor) || this.resumeEpisode(eps) || eps[0];
          st.browseRange = EpisodeRanges.index(anchor.episode_number);
        }
        const visibleEpisodes = ranges.length ? eps.filter(ep => EpisodeRanges.index(ep.episode_number) === st.browseRange) : eps;
        const playedCount = eps.filter(e => e.played).length;
        const missingCount = eps.filter(e => !e.owned).length;
        const summary = (!st.episodesLoading && eps.length)
          ? [`共 ${eps.length} 集`, playedCount ? `已看 ${playedCount} 集` : null, missingCount ? `缺 ${missingCount} 集` : null].filter(Boolean).join(' · ')
          : null;
        const cards = st.episodesLoading
          ? '<div class="page-loading"><div class="spinner"></div></div>'
          : (eps.length
            ? visibleEpisodes.map(ep => this.episodeCardHtml(ep, st, runtime)).join('')
            : `<div class="empty-state">${escapeHtml(st.episodesError || '暂无剧集信息')}</div>`);
        replaceContentPreservingImages(area, `
          ${(info.seasons || []).length > 1 ? `
            <div class="season-selector">
              ${(info.seasons || []).map(s => `<button class="season-pill ${s === st.browseSeason ? 'active' : ''}" data-season="${Number(s)}">${s === 0 ? '特别篇' : `第 ${Number(s)} 季`}</button>`).join('')}
            </div>
          ` : ''}
          ${ranges.length ? `<div class="episode-ranges" aria-label="分集范围">${ranges.map(range => `<button data-episode-range="${range.index}" class="${range.index === st.browseRange ? 'active' : ''} ${EpisodeRanges.index(st.browseAnchor) === range.index ? 'resume-anchor' : ''}" aria-pressed="${range.index === st.browseRange}">${range.label}</button>`).join('')}<button id="allEpisodes">全部 ${eps.length} 集</button></div>` : ''}
          ${this.shelfHtml(st.browseSeason === 0 ? '特别篇' : `第 ${st.browseSeason} 季`, summary, 'episode-row', cards)}
        `);
        area.querySelectorAll('[data-episode-range]').forEach(button => button.addEventListener('click', () => { st.browseRange = Number(button.dataset.episodeRange); renderEpisodeShelf(); }));
        area.querySelector('#allEpisodes')?.addEventListener('click', () => {
          const dialog = document.createElement('dialog'); dialog.className = 'episode-grid-dialog'; dialog.id = 'episodeGridDialog';
          dialog.innerHTML = `<div class="episode-grid-header"><h2>${st.browseSeason === 0 ? '特别篇' : '第 ' + st.browseSeason + ' 季'} · 全部 ${eps.length} 集</h2><button class="panel-close" aria-label="关闭">×</button></div><div class="all-episodes-grid">${eps.map(ep => `<button data-grid-episode="${Number(ep.episode_number)}" class="${ep.played ? 'played' : ''} ${ep.episode_number === st.episode?.episode_number && st.browseSeason === st.season ? 'active' : ''}" ${ep.owned ? '' : 'disabled'} aria-label="第 ${Number(ep.episode_number)} 集${ep.owned ? ep.played ? '，已看' : '' : '，缺集'}">${Number(ep.episode_number)}${ep.played ? ' ✓' : ''}</button>`).join('')}</div>`;
          document.body.appendChild(dialog); dialog.showModal();
          const close = () => { dialog.close(); dialog.remove(); };
          dialog.querySelector('.panel-close').addEventListener('click', close);
          dialog.addEventListener('click', event => { if (event.target === dialog) close(); });
          dialog.addEventListener('close', () => dialog.remove());
          dialog.querySelectorAll('[data-grid-episode]').forEach(button => button.addEventListener('click', () => { const ep = eps.find(ep => ep.episode_number === Number(button.dataset.gridEpisode)); close(); selectEpisode(st.browseSeason, ep); }));
          dialog.querySelector('.active')?.scrollIntoView({ block: 'center' });
        });
        area.querySelectorAll('.season-pill').forEach(pill => {
          pill.addEventListener('click', () => loadBrowse(parseInt(pill.dataset.season, 10)));
        });
        area.querySelectorAll('.episode-card').forEach(card => {
          const ep = eps.find(e => e.episode_number === parseInt(card.dataset.episodeNumber, 10));
          if (ep) {
            card.addEventListener('click', () => selectEpisode(st.browseSeason, ep));
            card.addEventListener('keydown', event => { if (event.target === card && (event.key === 'Enter' || event.key === ' ')) { event.preventDefault(); selectEpisode(st.browseSeason, ep); } });
            card.addEventListener('contextmenu', event => {
              event.preventDefault(); this.showMenu([{ label: ep.owned ? '播放' : '缺集', disabled: !ep.owned, run: () => playUnit(null, st.browseSeason, ep) },
                { label: ep.played ? '标为未看' : '标为已看', disabled: !ep.owned, run: () => markEpisode(ep) }], event.clientX, event.clientY);
            });
          }
        });
        area.querySelectorAll('.episode-mark-btn').forEach(button => button.addEventListener('click', event => {
          event.stopPropagation(); const ep = eps.find(ep => ep.episode_number === Number(button.dataset.episodeNumber));
          if (ep) markEpisode(ep);
        }));
        area.querySelectorAll('.episode-play-btn').forEach(btn => {
          btn.addEventListener('click', e => {
            e.stopPropagation();
            const ep = eps.find(e2 => e2.episode_number === parseInt(btn.dataset.episodeNumber, 10));
            if (ep) playUnit(null, st.browseSeason, ep);
          });
        });
        area.querySelectorAll('.shelf-arrow').forEach(btn => {
          btn.addEventListener('click', () => {
            const row = btn.closest('.shelf-wrapper')?.querySelector('.shelf-row');
            if (row) row.scrollBy({ left: parseInt(btn.dataset.dir, 10) * row.clientWidth * 0.75, behavior: 'smooth' });
          });
        });
        // 头图正讲的那一集滚进视野
        const stageCard = area.querySelector('.episode-card.stage');
        const episodeRow = stageCard?.closest('.episode-row');
        if (episodeRow) {
          // scrollIntoView also scrolls overflow:hidden ancestors, shifting the
          // detail body's padding and backdrop. Only move this horizontal shelf.
          const left = episodeRow.scrollLeft + stageCard.getBoundingClientRect().left - episodeRow.getBoundingClientRect().left;
          episodeRow.scrollTo({ left, behavior: 'instant' });
        }
      };

      // 点分集卡：头图改讲这一集（续播点随单元重取），不起播；起播走悬停播放键或头图按钮
      const selectEpisode = (season, ep) => {
        if (!ep?.owned) return;
        st.season = season;
        st.episode = ep;
        st.browseRange = EpisodeRanges.index(ep.episode_number);
        renderStage();
        loadUnitResume();
        renderEpisodeShelf();
      };

      const markEpisode = async ep => {
        if (!ep?.owned || st.marking) return;
        st.marking = true; const season = st.browseSeason;
        try {
          await api.setMarks(mediaId, { played: !ep.played, seasonNumber: season, episodeNumber: ep.episode_number });
          if (!this.isCurrent(generation)) return;
          if (st.season === season && st.episode?.episode_number === ep.episode_number) await loadUnitResume();
          await loadBrowse(season, true); this.notice(ep.played ? '已标为未看' : '已标为已看');
        } catch (error) { if (this.isCurrent(generation)) this.notice(error.message); }
        finally { st.marking = false; }
      };

      const loadBrowse = async (seasonNumber, preserveRange = false) => {
        const request = st.browseRequest = (st.browseRequest || 0) + 1;
        st.browseSeason = seasonNumber;
        st.browseEpisodes = [];
        if (!preserveRange) st.browseRange = null;
        st.episodesError = null;
        st.episodesLoading = true;
        renderEpisodeShelf();
        try {
          const resp2 = await api.getItemEpisodes(params.libraryId, mediaId, seasonNumber);
          if (!this.isCurrent(generation) || request !== st.browseRequest) return;
          const data = resp2?.data || resp2 || {};
          st.browseEpisodes = (data.episodes || data || []).slice();
          st.browseAnchor = data.resume_episode;
          if (st.browseAnchor == null || !st.browseEpisodes.some(ep => ep.episode_number === st.browseAnchor)) st.browseAnchor = this.resumeEpisode(st.browseEpisodes)?.episode_number;
        } catch (e) {
          if (!this.isCurrent(generation) || request !== st.browseRequest || e.name === 'AbortError') return;
          console.error('Load episodes failed:', e);
          st.episodesError = '无法载入分集：' + e.message;
        }
        st.episodesLoading = false;
        renderEpisodeShelf();
      };

      // Bind static navigation before waiting for marks/resume requests.
      document.getElementById('btnBack')?.addEventListener('click', () => this.goBack());
      container.querySelectorAll('.collection-chip').forEach(chip => {
        chip.addEventListener('click', e => {
          e.preventDefault();
          const id = chip.dataset.collectionId;
          if (id) this.navigate('collection', { collectionId: id });
        });
      });
      container.querySelectorAll('.person-card[data-person-id]').forEach(card => {
        card.addEventListener('click', () => {
          const pid = card.dataset.personId;
          if (pid) this.navigate('person', { personId: pid, fromItem: mediaId });
        });
        card.addEventListener('keydown', event => {
          if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); card.click(); }
        });
      });
      container.querySelectorAll('.detail-lower .shelf-arrow').forEach(btn => {
        btn.dataset.bound = '1';
        btn.addEventListener('click', () => {
          const row = btn.closest('.shelf-wrapper')?.querySelector('.shelf-row');
          if (row) row.scrollBy({ left: parseInt(btn.dataset.dir, 10) * row.clientWidth * 0.75, behavior: 'smooth' });
        });
      });

      // ---- 初始化 ----
      // 收藏是整片级（Mac 头图那颗心也是）；已看/续播跟着头图那一集走
      try {
        const marksResp = await api.getMarks(mediaId);
        if (!this.isCurrent(generation)) return;
        st.favorite = !!(marksResp?.data || marksResp)?.is_favorite;
      } catch (_) {}

      if (!this.isCurrent(generation)) return;
      if (isMovie) {
        await loadUnitResume();
      } else {
        // 「接下来继续」里那一集优先；否则第一个有片源的季（综艺常只收了最新一季）
        let preferred = null;
        try {
          const upNextResp = await api.getUpNext();
          if (!this.isCurrent(generation)) return;
          const upNext = this.unwrapItems(upNextResp).find(
            x => x.media_item_id === mediaId && x.kind === 'tv',
          );
          if (upNext) preferred = { season: upNext.season_number, episode: upNext.episode_number };
        } catch (_) {}
        const ownedSeasons = new Set(inPlace.map(f => f.season_number));
        const seasons = info.seasons || [];
        const start = (preferred && seasons.includes(preferred.season) ? preferred.season : null)
          ?? seasons.find(s => s > 0 && ownedSeasons.has(s))
          ?? seasons.find(s => ownedSeasons.has(s))
          ?? seasons.find(s => s > 0)
          ?? seasons[0];
        if (start != null) {
          st.season = start;
          await loadBrowse(start);
          if (!this.isCurrent(generation)) return;
          const eps = st.browseEpisodes;
          st.episode = (preferred?.season === start ? eps.find(e => e.episode_number === preferred.episode && e.owned) : null)
            || eps.find(e => e.episode_number === st.browseAnchor && e.owned)
            || this.resumeEpisode(eps)
            || eps[0]
            || null;
          if (st.episode) st.browseRange = EpisodeRanges.index(st.episode.episode_number);
          await loadUnitResume();
          renderEpisodeShelf();
        } else {
          renderStage();
        }
      }

      // ---- 电影的作品系列 ----
      if (isMovie && info.series_collection_id) {
        try {
          const resp2 = await api.getCollectionSeries(info.series_collection_id);
          if (!this.isCurrent(generation)) return;
          const series = resp2?.data || resp2;
          if (series?.available && (series.parts || []).length > 1) {
            const area = document.getElementById('detailSeriesArea');
            area.innerHTML = this.shelfHtml(
              series.series_name || info.series_name || '系列',
              `已有 ${series.owned_count} / 共 ${series.total}`,
              'series-row',
              series.parts.map(part => this.seriesCardHtml(part, mediaId, params.libraryId)).join(''),
            );
            area.querySelectorAll('.series-card[data-item-id]').forEach(card => {
              card.addEventListener('click', () => {
                const id = parseInt(card.dataset.itemId, 10);
                if (id && id !== mediaId) this.navigate('detail', { libraryId: params.libraryId, itemId: id });
              });
            });
            area.querySelectorAll('.shelf-arrow').forEach(btn => {
              btn.addEventListener('click', () => {
                const row = btn.closest('.shelf-wrapper')?.querySelector('.shelf-row');
                if (row) row.scrollBy({ left: parseInt(btn.dataset.dir, 10) * row.clientWidth * 0.75, behavior: 'smooth' });
              });
            });
          }
        } catch (e) { console.error('Load series failed:', e); }
      }

    } catch (e) {
      this.renderPageError(container, e, generation);
    }
  },

  // 一季里「接着看的那一集」：看了一半的 → 第一集没看过的 → 第一集（同 Mac resumeEpisode）
  resumeEpisode(episodes) {
    const owned = (episodes || []).filter(e => e.owned);
    return owned.find(e => e.position_ms > 0) || owned.find(e => !e.played) || owned[0] || (episodes || [])[0] || null;
  },

  // 「第 2 季 第 6 集 · 集名」（同 Mac MacStageInfo.episodeLine）：TMDB 没起名字的集不重复写
  episodeLine(season, ep) {
    const number = season === 0 ? `特别篇 第 ${ep.episode_number} 集` : `第 ${season} 季 第 ${ep.episode_number} 集`;
    const name = (ep.name || '').trim();
    if (!name || /^(第\s*\d+\s*集|Episode\s*\d+)$/i.test(name)) return number;
    return `${number} · ${name}`;
  },

  // 画质小标签：在位文件里各挑最好的一档（同 Mac MacMediaBadge.best）
  bestMediaBadges(files) {
    const resHeight = raw => {
      const s = String(raw || '').trim().toLowerCase();
      if (s === '8k') return 4320;
      if (s === '4k' || s === 'uhd') return 2160;
      if (s === '2k') return 1440;
      const n = s.replace(/[^0-9]/g, '');
      return n ? parseInt(n, 10) : 0;
    };
    const badges = [];
    const best = Math.max(0, ...files.map(f => resHeight(f.resolution)));
    if (best >= 4320) badges.push({ text: '8K', filled: true });
    else if (best >= 2160) badges.push({ text: '4K', filled: true });
    else if (best >= 720) badges.push({ text: 'HD', filled: true });
    const hdrPriority = ['Dolby Vision', 'HDR10+', 'HDR10', 'HLG', 'HDR'];
    const hdrs = files.map(f => f.hdr).filter(Boolean)
      .sort((a, b) => (hdrPriority.indexOf(a) + 1 || 99) - (hdrPriority.indexOf(b) + 1 || 99));
    if (hdrs.length) {
      const hdr = hdrs[0];
      badges.push({ text: hdr === 'Dolby Vision' ? 'DOLBY VISION' : hdr.toUpperCase(), filled: false });
    }
    const audio = files.flatMap(f => f.audio_streams || []);
    const described = audio.map(a => [a.profile, a.title, a.codec].filter(Boolean).join(' ').toLowerCase());
    if (described.some(s => s.includes('atmos'))) {
      badges.push({ text: 'DOLBY ATMOS', filled: false });
    } else if (described.some(s => s.includes('dts:x') || s.includes('dts-x'))) {
      badges.push({ text: 'DTS:X', filled: false });
    } else {
      const channels = Math.max(0, ...audio.map(a => a.channels || 0));
      if (channels >= 6) badges.push({ text: channels >= 8 ? '7.1' : '5.1', filled: false });
    }
    return badges;
  },

  // 演职员：导演在前（结构化 person 关系优先，没有退回姓名），演员跟着（同 Mac castPeople）
  castPeople(meta) {
    const people = [];
    const credits = meta.director_credits || [];
    if (credits.length) {
      credits.forEach(d => people.push({ name: d.name, role: '导演', avatar: d.thumb_url, personId: d.tmdb_person_id }));
    } else {
      [...new Set(meta.directors || [])].forEach(n => people.push({ name: n, role: '导演', avatar: null, personId: null }));
    }
    (meta.actors || []).forEach(a => people.push({
      name: a.name,
      role: (a.role || '').trim() ? `饰 ${a.role}` : '',
      avatar: a.thumb_url,
      personId: a.tmdb_person_id,
    }));
    return people;
  },

  // 头图右下角的演职员：「导演 某某」「主演 某某、某某」（同 Apple TV App）
  detailCreditsHtml(cast) {
    const directors = cast.filter(p => p.role === '导演');
    const actors = cast.filter(p => p.role !== '导演');
    const line = (label, names) => (names.length
      ? `<div class="credit-line"><span class="credit-label">${escapeHtml(label)}</span><span class="credit-names">${escapeHtml(names.join('、'))}</span></div>`
      : '');
    const html = line('导演', directors.slice(0, 1).map(p => p.name)) + line('主演', actors.slice(0, 3).map(p => p.name));
    return html ? `<div class="detail-credits">${html}</div>` : '';
  },

  // 横排货架（同 Mac MacShelf）：标题 + 说明小字 + 一排卡
  shelfHtml(title, detail, rowClass, cardsHtml) {
    return `
      <div class="detail-section">
        <div class="shelf-header">
          <h2 class="shelf-title">${escapeHtml(title)}</h2>
          ${detail ? `<span class="shelf-detail">${escapeHtml(detail)}</span>` : ''}
        </div>
        <div class="shelf-wrapper">
          <button class="shelf-arrow shelf-arrow-left" data-dir="-1" aria-label="向左">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>
          </button>
          <div class="shelf-row ${rowClass}">${cardsHtml}</div>
          <button class="shelf-arrow shelf-arrow-right" data-dir="1" aria-label="向右">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg>
          </button>
        </div>
      </div>
    `;
  },

  // 分集卡（同 Mac MacEpisodeCard）：剧照 + 已看角标 + 左下「看到 mm:ss / ▶ 片长」压进度条，
  // 悬停浮出播放键；下面第几集、集名、三行简介、首播日期（缺集写「缺集」并置灰）
  episodeCardHtml(ep, st, runtimeMinutes) {
    const inProgress = ep.position_ms > 0;
    const bandText = inProgress ? `看到 ${fmtClock(ep.position_ms)}` : (runtimeMinutes ? `▶ ${fmtRuntime(runtimeMinutes)}` : '');
    const isStage = !!st.episode && ep.owned && st.browseSeason === st.season
      && ep.episode_number === st.episode.episode_number;
    return `
      <div class="episode-card ${ep.owned ? '' : 'missing'} ${isStage ? 'stage' : ''}" role="button" tabindex="${ep.owned ? '0' : '-1'}" aria-disabled="${!ep.owned}" aria-label="第 ${Number(ep.episode_number)} 集${ep.owned ? '' : '，缺集'}" data-episode-number="${Number(ep.episode_number)}">
        <div class="episode-art">
          ${ep.still_url ? `<img src="${escapeHtml(resolveUrl(ep.still_url))}" alt="" data-raw="${escapeHtml(ep.still_url)}">` : ''}
          ${ep.played ? `
            <div class="episode-watched">
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><polyline points="5 13 10 18 19 6"/></svg>
              已看
            </div>
          ` : ''}
          ${ep.owned ? `
            <div class="episode-hover">
              <button class="episode-play-btn" data-episode-number="${Number(ep.episode_number)}" title="播放">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
              </button>
              <button class="episode-mark-btn" data-episode-number="${Number(ep.episode_number)}" title="${ep.played ? '标为未看' : '标为已看'}" aria-label="第 ${Number(ep.episode_number)} 集${ep.played ? '标为未看' : '标为已看'}">${ep.played ? '✓' : '○'}</button>
            </div>
          ` : ''}
          ${bandText || inProgress ? `
            <div class="episode-band">
              ${bandText ? `<div class="episode-band-text">${bandText}</div>` : ''}
              ${inProgress && ep.progress_percent ? `<div class="episode-progress"><div class="episode-progress-fill" style="width:${Math.max(0, Math.min(100, Number(ep.progress_percent) || 0))}%"></div></div>` : ''}
            </div>
          ` : ''}
        </div>
        <div class="episode-info">
          <div class="episode-ep">第 ${Number(ep.episode_number)} 集</div>
          <div class="episode-title">${escapeHtml(ep.name || '第 ' + ep.episode_number + ' 集')}</div>
          <div class="episode-overview">${escapeHtml(ep.overview)}</div>
          <div class="episode-subtitle">${escapeHtml(ep.owned ? (ep.air_date ? String(ep.air_date).slice(0, 10) : '') : '缺集')}</div>
        </div>
      </div>
    `;
  },

  // 演职员一格（同 Mac MacPersonCard）：圆头像 + 姓名 + 身份；有 TMDB 影人 id 的点进人物页
  personCardHtml(p) {
    return `
      <div class="person-card" ${p.personId ? `data-person-id="${Number(p.personId)}" role="button" tabindex="0" aria-label="${escapeHtml(p.name)} ${escapeHtml(p.role)}"` : ''}>
        ${p.avatar
          ? `<img class="person-card-avatar" src="${escapeHtml(resolveUrl(p.avatar))}" alt="" data-raw="${escapeHtml(p.avatar)}">`
          : `<div class="person-card-avatar person-card-avatar-placeholder" aria-hidden="true">${escapeHtml((p.name || '?').slice(0, 1))}</div>`}
        <div class="person-card-name">${escapeHtml(p.name)}</div>
        <div class="person-card-role">${escapeHtml(p.role)}</div>
      </div>
    `;
  },

  // 系列里的一部：本片标「本片」、没入库的置灰标「未入库」（同 Mac seriesShelf）
  seriesCardHtml(part, currentId, libraryId) {
    const current = part.media_item_id === currentId;
    const missing = part.media_item_id == null;
    return `
      <div class="series-card ${missing ? 'missing' : ''}" ${part.media_item_id != null ? `data-item-id="${Number(part.media_item_id)}"` : ''} data-library-id="${Number(libraryId)}">
        <div class="series-art">
          ${part.poster_url ? `<img src="${escapeHtml(resolveUrl(part.poster_url))}" alt="" data-raw="${escapeHtml(part.poster_url)}">` : ''}
          ${current ? '<div class="series-badge">本片</div>' : missing ? '<div class="series-badge">未入库</div>' : ''}
        </div>
        <div class="series-title">${escapeHtml(part.title)}</div>
        <div class="series-year">${escapeHtml(part.release_date ? String(part.release_date).slice(0, 4) : '')}</div>
      </div>
    `;
  },

  // 页底信息（同 Apple Music 专辑页的发行信息）：事实 + 电影的在位版本
  detailInfoHtml(info, meta, inPlace, isMovie, seasonCount) {
    const facts = [];
    if (info.original_title && info.original_title !== info.title) facts.push(['原名', info.original_title]);
    if (info.year) facts.push(['年份', String(info.year)]);
    if ((meta.genres || []).length) facts.push(['类型', meta.genres.join(' / ')]);
    if (meta.rating) facts.push(['评分', Number(meta.rating).toFixed(1)]);
    if (isMovie) {
      if (meta.runtime_minutes > 0) facts.push(['片长', fmtRuntime(meta.runtime_minutes)]);
    } else if (seasonCount > 0) {
      facts.push(['季数', `${seasonCount} 季`]);
    }
    const inPlaceSize = inPlace.reduce((n, f) => n + (f.size_bytes || 0), 0);
    facts.push(['文件', inPlace.length ? `${inPlace.length} 个 · ${fmtBytes(inPlaceSize)}` : '没有在位的文件']);
    const versions = isMovie ? inPlace.map(f => [
      f.resolution,
      f.video_codec ? String(f.video_codec).toUpperCase() : null,
      f.hdr,
      fmtBytes(f.size_bytes),
    ].filter(Boolean).join(' · ')) : [];
    return `
      <div class="detail-section detail-info">
        <h2 class="shelf-title">信息</h2>
        <div class="detail-info-cols">
          <div class="detail-info-grid">
            ${facts.map(([k, v]) => `<div class="info-row"><span class="info-label">${escapeHtml(k)}</span><span class="info-value">${escapeHtml(v)}</span></div>`).join('')}
          </div>
          ${versions.length ? `
            <div class="detail-versions">
              <div class="info-label">版本</div>
              ${versions.map(v => `<div class="version-line">${escapeHtml(v)}</div>`).join('')}
            </div>
          ` : ''}
        </div>
      </div>
    `;
  },

  reducedMotion() { return window.matchMedia?.('(prefers-reduced-motion: reduce)').matches || false; },

  playCard(item) {
    if (!item || item.source_missing || !item.library_id || this._authPending) return;
    if (this.currentPage === 'search') this.rememberSearch(this.currentParams.query);
    this.startPlayback({ ...item, seasonNumber: item.season_number, episodeNumber: item.episode_number });
  },

  notice(message) {
    document.getElementById('appNotice')?.remove();
    const notice = document.createElement('div'); notice.id = 'appNotice'; notice.className = 'app-notice';
    notice.setAttribute('role', 'status'); notice.textContent = message;
    document.body.appendChild(notice); setTimeout(() => notice.remove(), 5000);
  },

  showMenu(actions, x, y) {
    document.getElementById('cardMenu')?.remove();
    const menu = document.createElement('dialog'); menu.id = 'cardMenu'; menu.className = 'card-menu';
    menu.innerHTML = actions.map((action, index) => `<button data-action="${index}" ${action.disabled ? 'disabled' : ''}>${escapeHtml(action.label)}</button>`).join('');
    document.body.appendChild(menu); menu.showModal();
    menu.style.left = Math.max(8, Math.min(x || 8, window.innerWidth - 230)) + 'px';
    menu.style.top = Math.max(8, Math.min(y || 8, window.innerHeight - 230)) + 'px';
    menu.querySelectorAll('[data-action]').forEach(button => button.addEventListener('click', () => { menu.close(); menu.remove(); actions[Number(button.dataset.action)].run?.(); }));
    menu.addEventListener('click', event => { if (event.target === menu) { menu.close(); menu.remove(); } });
    menu.addEventListener('close', () => menu.remove());
  },

  async cardMenu(item, event) {
    event.preventDefault(); event.stopPropagation();
    const generation = this.viewGeneration, epoch = API.contextEpoch, api = this.pageAPI || API;
    const rect = event.currentTarget.getBoundingClientRect();
    const actions = [{ label: item.source_missing ? '片源不在当前媒体库' : '播放', disabled: !!item.source_missing, run: () => this.playCard(item) },
      { label: '查看详情', disabled: !!item.source_missing, run: () => this.navigate('detail', { libraryId: item.library_id, itemId: item.media_item_id }) }];
    if (!item.source_missing) {
      try {
        const response = await api.getMarks(item.media_item_id);
        if (!this.isCurrent(generation) || epoch !== API.contextEpoch) return;
        const marks = response?.data || response || {};
        actions.push({ label: marks.is_favorite ? '取消收藏' : '收藏', run: async () => {
          try { await api.setMarks(item.media_item_id, { favorite: !marks.is_favorite }); if (this.isCurrent(generation)) { item.is_favorite = !marks.is_favorite; this.notice(item.is_favorite ? '已收藏' : '已取消收藏'); } } catch (error) { if (this.isCurrent(generation)) this.notice(error.message); }
        } });
        actions.push({ label: marks.played ? '标为未看' : '标为已看', run: async () => {
          try { await api.setMarks(item.media_item_id, { played: !marks.played }); if (this.isCurrent(generation)) { this.notice(marks.played ? '已标为未看' : '已标为已看'); await this.refreshStoppedItem({ mediaItemId: item.media_item_id, libraryId: item.library_id }); } } catch (error) { if (this.isCurrent(generation)) this.notice(error.message); }
        } });
      } catch (error) { if (this.isCurrent(generation)) this.notice(error.message); }
    }
    if (this.isCurrent(generation)) this.showMenu(actions, event.clientX || rect.left, event.clientY || rect.bottom);
  },

  posterCard(item, defaultLibId, landscape = false) {
    // LibraryItemView 字段：media_item_id, title, year, poster_url, rating, is_favorite, seasons, episode_count, kind
    // UpNextItemView 额外字段：progress_percent, position_ms, duration_ms, season_number, episode_number
    const progress = item.progress_percent != null ? item.progress_percent / 100 : 0;
    const itemId = item.media_item_id || '';
    const libId = item.library_id ?? defaultLibId ?? '';
    const title = item.title || '未知';
    const rawPoster = (landscape ? item.episode_still_url || item.backdrop_url : '') || item.poster_url || '';
    const posterUrl = resolveUrl(rawPoster);
    const year = item.year || '';
    const rating = item.rating;
    const isFav = item.is_favorite;
    const key = itemId + ':' + libId;
    (this._cardItems ||= new Map()).set(key, { ...item, library_id: libId });
    return `
      <div class="poster-card ${landscape ? 'continue-card' : ''}" role="button" tabindex="${item.source_missing ? '-1' : '0'}" aria-label="${escapeHtml(title)}" aria-disabled="${item.source_missing ? 'true' : 'false'}" style="${item.source_missing ? 'opacity:0.45' : ''}" data-item-id="${escapeHtml(itemId)}" data-library-id="${escapeHtml(libId)}">
        <div class="poster-art">
          ${rawPoster ? `<img src="${escapeHtml(posterUrl)}" alt="" loading="lazy" style="opacity:0;transition:opacity 0.3s" data-raw="${escapeHtml(rawPoster)}" data-fade>` : ''}
          <div class="focus-glow"></div>
          <div class="poster-hover"><button class="card-play" aria-label="播放 ${escapeHtml(title)}" ${item.source_missing ? 'disabled' : ''}>${uiIcon('play')}</button><button class="card-more" aria-label="更多 ${escapeHtml(title)}">${uiIcon('more')}</button></div>
          ${item.source_missing ? '<span class="source-missing">片源已移除</span>' : ''}
          ${landscape ? `<div class="continue-band">${item.advanced ? '<span>下一集</span> · ' : ''}${item.kind === 'tv' ? `S${Number(item.season_number)} E${Number(item.episode_number)} · ` : ''}${escapeHtml(item.position_ms > 0 && item.duration_ms > item.position_ms ? '剩 ' + fmtRuntime(Math.ceil((item.duration_ms - item.position_ms) / 60000)) : item.duration_ms ? fmtRuntime(Math.ceil(item.duration_ms / 60000)) : '')}</div>` : ''}
          ${isFav ? '<div class="poster-fav"><svg width="14" height="14" viewBox="0 0 24 24" fill="#ff375f"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg></div>' : ''}
          ${progress > 0 && progress < 1 ? `
            <div class="poster-progress">
              <div class="poster-progress-fill" style="width:${Math.round(progress * 100)}%"></div>
            </div>
          ` : ''}
        </div>
        <div class="poster-info">
          <div class="poster-title">${escapeHtml(title)}</div>
          <div class="poster-subtitle">${[
            landscape && item.kind === 'tv' ? `第 ${item.season_number} 季第 ${item.episode_number} 集` : '',
            landscape ? item.episode_title || '' : '',
            year,
            rating != null ? Number(rating).toFixed(1) : '',
            item.match_label || '',
            item.kind === 'tv' && item.seasons?.length ? item.seasons.length + ' 季' : (item.episode_count > 0 ? item.episode_count + ' 集' : '')
          ].filter(Boolean).map(escapeHtml).join(' · ')}</div>
        </div>
      </div>
    `;
  },

  bindPosterCards(container) {
    container.querySelectorAll('.poster-card').forEach(card => {
      if (card.dataset.bound) return;
      card.dataset.bound = '1';
      const open = () => {
        if (card.getAttribute('aria-disabled') === 'true') return;
        if (card.dataset.currentItem === 'true') { this.goBack(); return; }
        const itemId = card.dataset.itemId;
        const libId = card.dataset.libraryId;
        if (itemId && libId) {
          if (this.currentPage === 'search') this.rememberSearch(this.currentParams.query);
          this.navigate('detail', { libraryId: libId, itemId });
        }
      };
      card.addEventListener('click', open);
      card.addEventListener('keydown', e => {
        if (e.target !== card) return;
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); }
      });
      const item = this._cardItems?.get(card.dataset.itemId + ':' + card.dataset.libraryId);
      if (item) {
        card.addEventListener('contextmenu', event => this.cardMenu(item, event));
        card.querySelector('.card-more')?.addEventListener('click', event => this.cardMenu(item, event));
        card.querySelector('.card-play')?.addEventListener('click', event => { event.stopPropagation(); this.playCard(item); });
      }
      // Keep the Mac focus glow; scrolling suppresses hover changes.
      card.addEventListener('mousemove', (e) => {
        if (this._scrolling || this.reducedMotion()) return;
        const rect = card.getBoundingClientRect();
        const x = (e.clientX - rect.left) / rect.width;
        const y = (e.clientY - rect.top) / rect.height;
        card.style.setProperty('--mouse-x', (x * 100).toFixed(1) + '%');
        card.style.setProperty('--mouse-y', (y * 100).toFixed(1) + '%');
      });
      card.addEventListener('mouseleave', () => {
        const art = card.querySelector('.poster-art');
        if (art) art.style.transform = '';
      });
    });
  },

  async logout() {
    if (this._authPending || this._changingContext) return;
    if (!window.confirm('退出当前账号？其他已保存账号会保留。')) return;
    try {
      await this.resetContext();
      const response = await API.logout();
      this.session = null;
      if (response?.data) await this.enterSession(response);
      else if (API.nativeAuthStatus?.accounts?.length) this.renderAccountChooser(API.nativeAuthStatus.accounts);
      else this.renderLogin();
    } catch (error) { this.renderConnectionState('unreachable', error.message); }
  },

  showAccountPanel() {
    if (this._authPending || this._changingContext) return;
    document.getElementById('accountPanel')?.remove();
    const panel = document.createElement('dialog'); panel.id = 'accountPanel'; panel.className = 'account-panel';
    panel.innerHTML = `<button class="panel-close" aria-label="关闭">${uiIcon('close')}</button><h2>${escapeHtml(this.session?.nickname || this.session?.username)}</h2><p>${escapeHtml(API.baseUrl)}</p>
      <div id="panelAccountList" class="account-list" role="status">正在读取账号…</div><div class="account-actions"><button id="panelAddAccount" class="btn-secondary">添加账号</button><button id="panelSettings" class="btn-secondary">设置</button><button id="panelAbout" class="btn-secondary">关于 MovieClaw</button><button id="panelLogout" class="btn-secondary">退出当前账号</button></div>`;
    document.body.appendChild(panel); panel.showModal();
    const close = () => { panel.close(); panel.remove(); };
    panel.querySelector('.panel-close').addEventListener('click', close);
    panel.addEventListener('click', event => { if (event.target === panel) close(); });
    panel.addEventListener('close', () => panel.remove());
    panel.querySelector('#panelAddAccount').addEventListener('click', async () => { close(); await Player.close(); this.renderLogin({ addAccount: true }); });
    panel.querySelector('#panelSettings').addEventListener('click', () => { close(); this.selectTab('settings'); });
    panel.querySelector('#panelAbout').addEventListener('click', () => { close(); this.showAbout(); });
    panel.querySelector('#panelLogout').addEventListener('click', () => { close(); this.logout(); });
    this.loadAccounts('panelAccountList');
  },

  async showAbout() {
    document.getElementById('aboutDialog')?.remove();
    const dialog = document.createElement('dialog'); dialog.id = 'aboutDialog'; dialog.className = 'about-dialog';
    dialog.setAttribute('aria-labelledby', 'aboutTitle');
    dialog.innerHTML = `<button class="panel-close" aria-label="关闭关于">${uiIcon('close')}</button><h2 id="aboutTitle">关于 MovieClaw</h2><div class="about-body" role="status">正在读取…</div>`;
    dialog.querySelector('.panel-close').addEventListener('click', () => dialog.close());
    dialog.addEventListener('close', () => dialog.remove());
    document.body.appendChild(dialog); dialog.showModal();
    try {
      const info = await window.__TAURI__.core.invoke('get_about_info');
      if (!dialog.isConnected) return;
      dialog.querySelector('.about-body').innerHTML = `<p>版本 ${escapeHtml(info.version)} · 构建 ${escapeHtml(info.revision?.slice(0, 8) || '未知')}</p><p>媒体、账号与观看记录保存在你连接的 MovieClaw 服务器上。</p><h3>数据来源</h3><p>影视资料与图片由服务器从 TMDB 等来源获取。本产品使用 TMDB API，但未经 TMDB 认可或认证。</p><h3>开源组件</h3>${info.components.map(component => `<details><summary>${escapeHtml(component.name)}</summary><p class="about-source">${escapeHtml(component.source)}</p><pre>${escapeHtml(component.text)}</pre></details>`).join('')}`;
    } catch (_) { if (dialog.isConnected) dialog.querySelector('.about-body').textContent = '无法读取关于信息，请重试。'; }
  },

  // ===== 设置 =====
  renderSettings(container) {
    const generation = this.viewGeneration;
    container.innerHTML = `
      <div class="settings-page">
      <div class="page-header">
        <h1 class="page-title">设置</h1>
      </div>
      <div class="settings-body">
        <div class="settings-card settings-playback">
          <h3>播放设置</h3>
          <div class="settings-preferences">
          <div class="settings-row">
            <span>自动播放下一集</span>
            <label class="settings-toggle">
              <input type="checkbox" id="setAutoNext" aria-label="自动播放下一集" ${localStorage.getItem('mc_autoNext') !== '0' ? 'checked' : ''}>
              <span class="toggle-slider"></span>
            </label>
          </div>
          <div class="settings-row">
            <span>硬件解码</span>
            <label class="settings-toggle">
              <input type="checkbox" id="setHwDecode" aria-label="硬件解码" ${localStorage.getItem('mc_hwDecode') !== '0' ? 'checked' : ''}>
              <span class="toggle-slider"></span>
            </label>
          </div>
          <div class="settings-row">
            <span>播放时置顶</span>
            <label class="settings-toggle">
              <input type="checkbox" id="setAlwaysOnTop" aria-label="播放时置顶" ${localStorage.getItem('mc_alwaysOnTop') !== 'false' ? 'checked' : ''}>
              <span class="toggle-slider"></span>
            </label>
          </div>
          <div class="settings-row">
            <span>窗口贴合画面</span>
            <label class="settings-toggle">
              <input type="checkbox" id="setFitWindow" aria-label="窗口贴合画面" ${localStorage.getItem('mc_fitWindow') !== 'false' ? 'checked' : ''}>
              <span class="toggle-slider"></span>
            </label>
          </div>
          <div class="settings-row">
            <span>默认字幕语言</span>
            <select id="setSubLang" class="settings-select" aria-label="默认字幕语言">
              <option value="">关闭</option>
              <option value="zh" ${localStorage.getItem('mc_subLang') === 'zh' ? 'selected' : ''}>中文</option>
              <option value="en" ${localStorage.getItem('mc_subLang') === 'en' ? 'selected' : ''}>English</option>
            </select>
          </div>
          <div class="settings-row">
            <span>默认音轨语言</span>
            <select id="setAudioLang" class="settings-select" aria-label="默认音轨语言">
              <option value="">自动</option>
              <option value="zh" ${localStorage.getItem('mc_audioLang') === 'zh' ? 'selected' : ''}>中文</option>
              <option value="en" ${localStorage.getItem('mc_audioLang') === 'en' ? 'selected' : ''}>English</option>
            </select>
          </div>
          </div>
        </div>

        <div class="settings-card">
          <h3>服务器</h3>
          <div class="settings-row">
            <span>当前服务器</span>
            <span class="settings-value">${escapeHtml(API.baseUrl || '未配置')}</span>
          </div>
          <div class="settings-actions">
            <button class="btn-secondary" id="btnSwitchServer">更改服务器</button>
            <button class="btn-secondary btn-danger" id="btnLogout">退出登录</button>
          </div>
        </div>

        <div class="settings-card">
          <h3>账号</h3>
          <div id="accountList">
            <div style="color:var(--text-secondary);padding:8px 0">加载中...</div>
          </div>
          <div class="settings-actions">
            <button class="btn-secondary" id="btnAddAccount">添加账号</button>

          </div>

        </div>

        <div class="settings-card settings-about">
          <div class="settings-product">
          <h3>关于</h3>
          <p>MovieClaw for Windows</p>
          <p class="settings-value" id="settingsVersion">正在读取版本…</p>
          </div>
          <div class="settings-actions">
          <button class="btn-secondary" id="btnCheckUpdates">检查更新</button>
          <button class="btn-secondary" id="btnAbout">开源许可与数据来源</button>
          </div>
        </div>
      </div>
      </div>
    `;
    window.__TAURI__.core.invoke('get_app_version').then(version => {
      if (this.isCurrent(generation)) document.getElementById('settingsVersion').textContent = '版本 ' + version;
    }).catch(() => {
      if (this.isCurrent(generation)) document.getElementById('settingsVersion').textContent = '版本信息暂不可用';
    });

    DesktopSelect.enhance(container);
    // 事件绑定
    window.DesktopCatalog?.settings(container);
    window.DesktopFriends?.settings(container);
    document.getElementById('btnCheckUpdates')?.addEventListener('click', () => window.DesktopUpdates?.check());
    document.getElementById('btnAbout')?.addEventListener('click', () => this.showAbout());
    document.getElementById('setAutoNext')?.addEventListener('change', (e) => {
      localStorage.setItem('mc_autoNext', e.target.checked ? '1' : '0');
    });
    document.getElementById('setHwDecode')?.addEventListener('change', (e) => {
      localStorage.setItem('mc_hwDecode', e.target.checked ? '1' : '0');
    });
    for (const [id, key] of [['setAlwaysOnTop', 'mc_alwaysOnTop'], ['setFitWindow', 'mc_fitWindow']]) {
      document.getElementById(id)?.addEventListener('change', e => {
        localStorage.setItem(key, String(e.target.checked));
        window.MovieClawPlatform?.update();
      });
    }
    document.getElementById('setSubLang')?.addEventListener('change', (e) => {
      localStorage.setItem('mc_subLang', e.target.value);
    });
    document.getElementById('setAudioLang')?.addEventListener('change', (e) => {
      localStorage.setItem('mc_audioLang', e.target.value);
    });
    document.getElementById('btnSwitchServer')?.addEventListener('click', () => this.changeServer());
    document.getElementById('btnLogout')?.addEventListener('click', () => this.logout());

    // 多账号列表
    this.loadAccounts();

    // 添加账号
    document.getElementById('btnAddAccount')?.addEventListener('click', async () => {
      await Player.close();
      this.renderLogin({ addAccount: true });
    });

    document.getElementById('btnQRLogin')?.addEventListener('click', () => this.renderPairing({ addAccount: true }));
  },

  async loadAccounts(targetId = 'accountList') {
    const generation = this.viewGeneration;
    const api = this.pageAPI || API;
    const list = document.getElementById(targetId);
    if (!list) return;
    try {
      const accounts = this.unwrapItems(await api.listAccounts());
      if (!this.isCurrent(generation)) return;
      list.innerHTML = accounts.map(acc => `
        <div class="settings-row" data-username="${escapeHtml(acc.username)}">
          <span>${escapeHtml(acc.nickname || acc.username)}</span><div class="settings-account-actions">
            ${acc.active ? '<span style="color:var(--accent);font-size:12px">当前</span>' : '<button class="btn-secondary account-switch" style="padding:4px 12px;font-size:12px">切换</button>'}
            <button class="btn-secondary account-remove" style="padding:4px 12px;font-size:12px">移除</button>
          </div>
        </div>`).join('') || '<div style="color:var(--text-secondary)">没有已保存账号</div>';
      list.querySelectorAll('.account-switch').forEach(button => button.addEventListener('click', () => this.switchToAccount(button.closest('[data-username]').dataset.username)));
      list.querySelectorAll('.account-remove').forEach(button => button.addEventListener('click', async () => {
        if (this._authPending || this._changingContext) return;
        const username = button.closest('[data-username]').dataset.username;
        if (!window.confirm(`从这台电脑移除“${username}”的登录状态？`)) return;
        button.disabled = true;
        try {
          await this.resetContext();
          const response = await API.removeAccount(username);
          this.session = null;
          if (response?.data) await this.enterSession(response);
          else if (API.nativeAuthStatus?.accounts?.length) this.renderAccountChooser(API.nativeAuthStatus.accounts);
          else this.renderLogin();
        } catch (error) {
          if (error.status === 401) this.renderLogin({ message: '登录已失效，请重新输入密码。' });
          else this.renderConnectionState('unreachable', error.message);
        }
      }));
    } catch (error) {
      if (!this.isCurrent(generation) || error.name === 'AbortError') return;
      if (error.status === 401) { this.handleSessionExpired(); return; }
      list.textContent = '无法读取账号：' + error.message;
    }
  },

  async switchToAccount(username) {
    if (this._authPending || this._changingContext) return;
    try {
      await this.resetContext();
      const response = await API.switchAccount(username);
      await this.enterSession(response);
    } catch (error) {
      if (error.status === 404 || error.status === 401) {
        this.renderLogin({ addAccount: true, username, message: '该账号的登录已失效，请重新输入密码。' });
      } else this.renderConnectionState('unreachable', '切换失败：' + error.message);
    }
  },

  // ===== 播放（内置 HTML5 播放器） =====
  async startPlayback(item, isRetry) {
    if (this._authPending || this._changingContext) return;
    item = { ...item };
    if (item.__maxHeight == null) item.__maxHeight = rememberedQuality(item.media_item_id);
    if (!isRetry) this._autoNextStreak = item.__autoNext ? (this._autoNextStreak || 0) + 1 : 0;
    if (!item.attemptId) item.attemptId = Date.now().toString(36) + Math.random().toString(36).slice(2);
    // 错误对话框的「重试」要重跑这一份（同 macOS retry() 重新 request）
    this._retryItem = item;
    this._retryStartMs = null;
    // 连点/返回竞态：新请求立即作废旧请求（清掉上一部的播放器状态），
    // 后续每个 await 之后用 alive() 检查，旧请求回来不再碰界面
    const closing = Player.close({ hide: false, final: !isRetry });
    if (!isRetry || item.__resetFailures) {
      // 全新播放：清掉上一轮的降档记录（web-player.md §6.3 的 failed_tiers 回路）
      this._failedTiers = [];
      this._contentFailures = 0;
      this._netRestarts = 0;
      this._totalNetRestarts = 0;
      this._nativeRetryAt = null;
    }
    this._recoveryAt = null;
    delete item.__resetFailures;
    const seq = (this._playbackSeq = (this._playbackSeq || 0) + 1);
    const alive = () => this._playbackSeq === seq;
    let session = null;

    const loadingText = document.getElementById('playerLoadingText');
    const loading = document.getElementById('playerLoading');
    const playerView = document.getElementById('playerView');
    const titleEl = document.getElementById('playerTitle');
    if (titleEl) titleEl.textContent = item.title || 'MovieClaw';

    // 显示加载状态
    playerView.hidden = false;
    loading.hidden = false;
    if (loadingText) loadingText.textContent = '正在获取播放链接...';

    try {
      await closing;
      if (!alive()) return;
      if (!Player._qoe || Player._qoe.attempt_id !== item.attemptId) Player.beginAttempt(item);

      if (!API.baseUrl) throw new Error('未配置服务器地址');

      const mediaId = Number(item.media_item_id);
      if (!mediaId || isNaN(mediaId)) throw new Error('无效的媒体项 ID: ' + item.media_item_id);

      // TV 剧集需要季/集号 — 若未指定则自动选择。
      // 详情页起播已把 kind 带在 item 上（和 files 同理）：已知就不用为判「是不是剧集」
      // 再查一遍详情——电影起播链上少一次串行往返
      if (item.seasonNumber == null || item.episodeNumber == null) {
        try {
          let detail = item.kind != null ? { kind: item.kind } : null;
          if (!detail) {
            const detailResp = await API.getItemDetail(item.library_id || this.libraries[0]?.id, mediaId);
            detail = detailResp?.data || detailResp;
          }
          if (!alive()) return;
          if (detail?.files && !item.files) item.files = detail.files;
          if (detail?.kind) item.kind = detail.kind;
          if (detail?.kind === 'tv') {
            // 优先用续播信息
            try {
              const resumeResp = await API.getResume(mediaId);
              const resume = resumeResp?.data || resumeResp;
              if (!alive()) return;
              if (resume?.season_number != null && resume?.episode_number != null) {
                item.seasonNumber = resume.season_number;
                item.episodeNumber = resume.episode_number;
              }
            } catch (_) {}
            // 若仍无，获取第一季第一集（未观看的优先）
            if (item.seasonNumber == null) {
              const seasons = detail.seasons || [1];
              const firstSeason = seasons.find(s => s >= 1) || seasons[0] || 1;
              try {
                const epsResp = await API.getItemEpisodes(item.library_id || this.libraries[0]?.id, mediaId, firstSeason);
                const epsData = epsResp?.data || epsResp || {};
                const eps = epsData.episodes || [];
                const ep = eps.find(e => !e.played) || eps[0];
                if (ep) {
                  item.seasonNumber = firstSeason;
                  item.episodeNumber = ep.episode_number;
                }
                item.episodes = eps;
              } catch (_) {}
            }
          }
        } catch (_) { /* 获取详情失败则按电影处理 */ }
      }
      if (!alive()) return;

      if (item.seasonNumber > 0 && item.episodeNumber > 0 && !Array.isArray(item.episodes)) {
        try {
          const response = await API.getItemEpisodes(item.library_id || this.libraries[0]?.id, mediaId, item.seasonNumber);
          item.episodes = (response?.data || response)?.episodes || [];
        } catch (_) { item.episodes = []; }
        if (!alive()) return;
      }

      // ---- 能力申报分级（对齐 macOS PlayerCapability.native()）----
      // mpv 在场且这单片源 HTML5 啃不动 → 报 universal 换 tier-0 原文件直出，交给 mpv；
      // 否则报浏览器真值，服务端据此直通/换壳/转码。报了 universal 就必须真让 mpv 播：
      // 档 0 给的是裸文件地址，HTML5 啃不动 mkv/ISO
      //
      // 例外：用户限了画质上限就绝不能报 universal——decide.py 的 universal 分支
      // 故意不受 max_height 影响（全解码客户端自己拉流），报了还是原文件直出、上限
      // 整个失效。按浏览器真值申报让服务端按上限转码，交 HTML5 放（对齐 macOS
      // negotiationInputs「限了画质时按系统播放器的能力申报，让服务端按上限转码」）
      const qualityCapped = item.__maxHeight > 0;
      const mpvReady = await this.hasEmbeddedPlayer();
      if (!alive()) return;
      let wantsMpv = false;
      if (mpvReady && !item.__forceHtml5 && !item.__forceServerDisc && !qualityCapped) {
        // 详情页起播已把 files 带在 item 上（省一次详情请求）；别的入口没有就现查
        let files = item.files;
        if (!files) {
          try {
            const d = await API.getItemDetail(item.library_id || this.libraries[0]?.id, mediaId);
            files = (d?.data || d)?.files;
            if (files) item.files = files;
          } catch (_) { /* 查不到片源元数据就不报 universal，按浏览器真值走 */ }
        }
        const unitFile = files?.find(f => Number(f.id) === Number(item.file_id)) || this.pickUnitFile(files, item.seasonNumber, item.episodeNumber);
        wantsMpv = !!unitFile && this.needsNativePlayer(unitFile, unitFile.audio_streams);
      }
      item.__universalClaim = wantsMpv;

      const body = {
        media_item_id: mediaId,
        // 真实解码能力（探测一次后缓存）：报空数组会让服务端判定浏览器
        // 什么都不支持 → 所有影片全量转码，起播慢、个别文件决策卡死
        capability: wantsMpv ? getUniversalCapabilitySnapshot() : await getCapabilitySnapshot(),
        client: 'web',
        attempt_id: item.attemptId,
      };
      if (item.file_id != null) body.file_id = Number(item.file_id);
      if (item.audio_track != null) body.audio_track = item.audio_track;
      if (item.subtitle_track != null) body.subtitle_track = item.subtitle_track;
      if (item.seasonNumber != null) body.season_number = Number(item.seasonNumber);
      if (item.episodeNumber != null) body.episode_number = Number(item.episodeNumber);
      // 上几档播失败了：带上让服务端跳过它们换下一档（decide.py 降档回路）
      if (this._failedTiers && this._failedTiers.length) body.failed_tiers = this._failedTiers;

      // 续播位置：详情页「从头播放」带 startMs=0 必须显式传——缺省时
      // 服务端会自己按观看记录续播（playback.py resolved_start_ms）。
      // 不传就别再抢着问一次 /resume：服务端开会话时本来就把续播点并进
      // start_ms 一起带回，前端先问一遍等于起播链上白加一次串行往返
      if (item.startMs != null) {
        body.start_ms = item.startMs;
      }
      // 画质上限（decide.py 的 max_height 参数）：只有不报 universal 时它才生效
      if (qualityCapped) body.max_height = item.__maxHeight;
      if (!alive()) return;

      // 服务端个别文件的决策/转码准备可能极慢：45 秒无响应给出明确错误，
      // 而不是永远停在「正在获取播放链接...」
      let sessionTimeout;
      let sessionResp;
      let timedOut = false;
      try {
        // 创建会话不硬取消：迟到响应里才有可 DELETE 的会话 id。
        const request = API.request('/playback/sessions', { method: 'POST', body, timeoutMs: 0 }).then((response) => {
          if (!alive() || timedOut) this.releasePlaybackSession(response?.data || response);
          return response;
        });
        const negotiationAt = performance.now();
        sessionResp = await Promise.race([
          request,
          new Promise((_, reject) => {
            sessionTimeout = setTimeout(() => { timedOut = true; reject(new Error('播放服务响应超时，请稍后重试')); }, 45000);
          }),
        ]);
        Player.measure('negotiation', { elapsedMs: performance.now() - negotiationAt });
      } finally {
        clearTimeout(sessionTimeout);
      }
      if (!alive()) return;
      session = sessionResp?.data || sessionResp;

      // 决策三态（同 macOS PlaybackController.handleSession）：
      // consent = 要用户同意开软件转码；rejected = 彻底放不了。两者都换对话框，
      // 不再像别的错误那样 5 秒后自己消失——用户还没表态
      const outcome = session?.decision ? session.decision.outcome : null;
      if (outcome === 'consent') {
        this.releasePlaybackSession(session);
        if (loading) loading.hidden = true;
        Player.showConsentDialog(session.decision);
        return;
      }
      if (outcome === 'rejected') {
        this.releasePlaybackSession(session);
        this._showPlaybackError(session.decision.reason || '播放不可用', session.decision.suggestion);
        return;
      }
      if (outcome && outcome !== 'plan') {
        throw new Error('播放不可用: ' + (session.decision.reason || outcome));
      }
      if (!session?.stream_url) throw new Error('服务器未返回播放地址');

      // 处理流地址
      const origin = API.baseUrl;
      const streamUrl = session.stream_url.startsWith('http')
        ? session.stream_url
        : origin + (session.stream_url.startsWith('/api/') ? session.stream_url : '/api/v1' + (session.stream_url.startsWith('/') ? session.stream_url : '/' + session.stream_url));

      const subtitleUrls = (session.subtitle_urls || []).map(s =>
        s.startsWith('http') ? s : origin + (s.startsWith('/api/') ? s : '/api/v1' + (s.startsWith('/') ? s : '/' + s))
      );

      const isSessionTimeline = session.session_id && session.timeline === 'session';
      const startMs = isSessionTimeline ? 0 : (session.start_ms ?? body.start_ms ?? 0);

      // 保存必要字段到 session 中供进度上报使用
      if (!session.media_item_id) session.media_item_id = mediaId;
      session.library_id = item.library_id ?? null;
      if (session.season_number == null) session.season_number = item.seasonNumber ?? null;
      if (session.episode_number == null) session.episode_number = item.episodeNumber ?? null;

      // 起播引擎：申报了 universal 的一定要 mpv 播（裸文件 HTML5 啃不动），
      // 其余按会话给出的片源特征判断（与改前一致）。
      // __forceHtml5 是上一轮 mpv 没起来的重谈：这回一律 HTML5，别再试一遍 mpv
      const source = session.source || {};
      const decision = session.decision || {};
      const selectedFile = item.files?.find(file => Number(file.id) === Number(decision.file_id));
      const sourceKind = String(source.container || selectedFile?.container || '').toLowerCase();
      const folderManifest = decision.disc === 'folder' || /\/playback\/files\/\d+\/disc(?:[?#]|$)/.test(streamUrl);
      if (folderManifest || ['iso', 'dvd'].includes(sourceKind) && decision.tier === 0 || decision.disc === 'image') {
        await this.releasePlaybackSession(session);
        if (!alive()) return;
        if (folderManifest && !item.__forceServerDisc) {
          return this.startPlayback({ ...item, __forceServerDisc: true, __forceHtml5: true }, true);
        }
        this._showPlaybackError(sourceKind === 'iso' || decision.disc === 'image'
          ? 'Windows 播放器暂不支持通过 HTTP 直接读取 ISO 镜像'
          : '此原盘目录需要服务端先按主播放列表生成可播放的视频流',
          '请将 ISO 解出 BDMV 后入库，或使用服务器可处理的普通视频文件。');
        return;
      }
      const needsNative = !item.__forceHtml5 && !qualityCapped
        && (wantsMpv || (mpvReady && this.needsNativePlayer(source, decision.audio_tracks || [])));

      if (needsNative && window.__TAURI__) {
        loading.hidden = true;
        // 档 0 直出的是裸文件，mpv 自己就 demux 得出 MKV 内封字幕轨。再把
        // embedded:N 当 --sub-file 传进去：轨重复一遍，还让服务端现场从几十 GB
        // 的 MKV 里逐条抽字幕——同一部片 10 条字幕首播实测 30 秒没出首帧。
        // 只留外挂字幕（容器里没有，必须旁挂）。HLS 档的流里没有内封轨，全留
        const nativeSubs = decision.tier === 0
          ? subtitleUrls.filter((_, i) => !decision.subtitles?.[i]?.track_ref?.startsWith('embedded:'))
          : subtitleUrls;
        await this.openEmbeddedPlayer(item, streamUrl, nativeSubs, startMs, session, seq);
      } else {
        // 打开内置 HTML5 播放器
        loading.hidden = true;
        Player.open(item.title || 'MovieClaw', streamUrl, subtitleUrls, startMs, session, item);
      }

    } catch (e) {
      if (session?.session_id && Player.sessionId !== session.session_id) this.releasePlaybackSession(session);
      if (!alive()) return; // 已被新的播放请求取代，别覆盖新界面
      Player.measure('error');
      console.error('Playback error:', e.message || '播放失败');
      // 错误对话框（重试/关闭）代替「5 秒后自己消失」的加载文案：用户还没表态
      this._showPlaybackError((e && e.message) || String(e));
    }
  },

  releasePlaybackSession(session) {
    if (session?.session_id) return API.sessionStop(session.session_id).catch(() => {});
    return Promise.resolve();
  },

  restartPlaybackAt(positionMs, overrides = {}) {
    if (!Player.context) return;
    return this.startPlayback({ ...Player.context, startMs: positionMs, ...overrides }, true);
  },

  // 首帧前播放失败（解不了 / 无数据）→ failed_tiers 降档回路（web-player.md §6.3）：
  // 把当前档记入失败集合重开会话，服务端跳过它们换下一档；连败两次直接一步到兜底转码档。
  // 典型场景：直通重封装产出的 init.mp4 hvcC 缺参数集（源片 CodecPrivate 为空），
  // 浏览器 MSE 拒收 → 换转码档重新编码即可修复
  onPlaybackContentFailed(reason, failure = {}) {
    if (Player._qoe) {
      Player._qoe.error_category = failure.status === 507 ? 'storage_full' : [404, 410].includes(failure.status) ? 'source_missing' : failure.kind === 'network' ? 'network' : 'decode';
      Player._qoe.error_kind = failure.status ? 'http_' + Number(failure.status) : Player._qoe.error_category;
      Player._qoe.error_stage = Player._everPlayed ? 'playing' : 'startup';
    }
    if ([401, 403, 404, 410, 507].includes(failure.status)) {
      const message = failure.status === 507 ? '服务器磁盘空间不足' : failure.status === 404 || failure.status === 410
        ? '片源或播放会话已不可用' : '此账号没有播放权限';
      this._showPlaybackError(message + '，请检查服务器后重试');
      return;
    }
    const view = document.getElementById('playerView');
    if (view && view.hidden) return; // 用户已关闭播放器，不再重试
    const sd = Player.sessionData;
    // 同一次播放的重复上报必须静默忽略（hls 同帧连发多个 buffer fatal、destroy 尾声再报一次）：
    // 第一个已发起降档重试，若后续重复走 _showPlaybackError → Player.close() 会推进
    // _playbackSeq，把刚发起的重试在首个 await 处作废（2026-10-09 真机：3 个 fatal
    // 挤掉唯一一次重试，重试的会话 POST 根本没发出去）
    if (sd && sd.__contentFailed) return;
    if (!sd) {
      this._showPlaybackError(reason);
      return;
    }
    sd.__contentFailed = true;
    Player.measure('error');
    if (Player.isMpv() && (this._nativeRetryAt == null || Date.now() - this._nativeRetryAt > 180000)) {
      this._nativeRetryAt = Date.now();
      Player.measure('retry');
      this.restartPlaybackAt(Math.floor(Player.engPos() * 1000));
      return;
    }
    const tier = sd.decision && typeof sd.decision.tier === 'number' ? sd.decision.tier : null;
    if (tier === null) {
      this._showPlaybackError(reason);
      return;
    }
    const failed = new Set(this._failedTiers || []);
    failed.add(tier);
    this._contentFailures = (this._contentFailures || 0) + 1;
    if (this._contentFailures >= 2) {
      for (let t = 0; t < 4; t += 1) failed.add(t);
    }
    if (tier >= 4) {
      this._showPlaybackError(reason + '（已尝试所有播放方式）');
      return;
    }
    this._failedTiers = [...failed].sort((a, b) => a - b);
    const loadingText = document.getElementById('playerLoadingText');
    if (loadingText) loadingText.textContent = '正在切换播放方式...';
    // 降档是「换一档接着看」，不是「从头再来」：把当前位置带上（startPlayback 会先
    // Player.close()，位置必须在这之前读）
    const resumeMs = Math.floor(Player.engPos() * 1000);
    this.restartPlaybackAt(resumeMs, Player.isMpv() ? { __forceHtml5: true } : {});
  },

  // 缓冲见底且连续 N 秒一个字节都没收到（StallWatch 的 .dead）→ 同档原地重开。
  // 预算连续 2 次（NetworkRestartBudget）：归因可能出错，防「网络」误判导致无限重开
  onPlaybackNetworkDead(reason, failure = {}) {
    if ([401, 403, 404, 410, 507].includes(failure.status)) { this.onPlaybackContentFailed(reason, failure); return; }
    const view = document.getElementById('playerView');
    if (view && view.hidden) return;
    const sd = Player.sessionData;
    if (!sd || sd.__networkRestarting) return;
    sd.__networkRestarting = true;
    this._netRestarts = (this._netRestarts || 0) + 1;
    this._totalNetRestarts = (this._totalNetRestarts || 0) + 1;
    const loadingText = document.getElementById('playerLoadingText');
    if (this._totalNetRestarts > 6) { this._showPlaybackError(reason + '（重连预算已用尽）'); return; }
    if (this._netRestarts > 2) {
      // 预算用尽：原文件直出没得可降，落错误页；服务端流还能走降档回路
      const tier = sd && sd.decision ? sd.decision.tier : null;
      if (tier === 0) this._showPlaybackError(reason + '（已多次重连失败）');
      else this.onPlaybackContentFailed(reason);
      return;
    }
    if (loadingText) loadingText.textContent = '连接中断，正在重连...';
    const resumeMs = Math.floor(Player.engPos() * 1000);
    const generation = Player.generation;
    clearTimeout(this._networkRetryTimer);
    this._networkRetryTimer = setTimeout(() => {
      this._networkRetryTimer = null;
      if (generation !== Player.generation || !Player.activeEngine) return;
      Player.measure('retry');
      this.restartPlaybackAt(resumeMs);
    }, Math.min(2000, this._netRestarts * 500));
  },

  // 真播起来过就清网络重开预算（同 macOS reachedPlaying()）
  onPlaybackRecovered() {
    if (this._recoveryAt == null) this._recoveryAt = Date.now();
    if (Date.now() - this._recoveryAt >= 15000) this._netRestarts = 0;
  },

  // 终态错误：清掉播放器与服务端会话，换成「重试 / 关闭」对话框
  // （同 macOS fail() → phase .error → MacPlayerDialog(title:message:重试:关闭)）
  _showPlaybackError(reason, suggestion) {
    if (Player._qoe) Player._qoe.outcome = 'failed';
    // 位置要在 close() 之前读：close 会把 <video> 的 src 摘掉
    const resumeMs = Math.floor(Player.engPos() * 1000);
    this._retryStartMs = Player.context ? resumeMs : null;
    Player.close();
    const view = document.getElementById('playerView');
    const loading = document.getElementById('playerLoading');
    if (view) view.hidden = false;
    if (loading) loading.hidden = true;
    const originalAvailable = this._mpvReady === true && this._retryItem?.__maxHeight > 0
      && !this._retryItem.__forceServerDisc;
    Player.showPlayerDialog({
      title: reason,
      message: originalAvailable
        ? `当前 ${this._retryItem.__maxHeight}p 播放依赖服务器处理。可改用原画，由本机播放器解码；流量会增加。`
        : suggestion || null,
      primary: ['重试', () => this.retryPlayback()],
      secondary: ['关闭', () => Player.close()],
      alternative: originalAvailable ? ['原画播放', () => this.retryPlayback(true)] : null,
    });
  },

  // 对话框「重试」：上一次播放以失败收尾，这是一次新的（同 macOS retry()）。
  // 起播链里的 Player.close() 会顺手把对话框收掉
  retryPlayback(useOriginal = false) {
    const item = this._retryItem;
    if (!item) { Player.close(); return; }
    const next = Object.assign({}, item);
    if (useOriginal === true) {
      next.__maxHeight = 0;
      rememberQuality(next.media_item_id, 0);
    }
    // Manual retry starts with the native capability again, rather than retaining
    // an automatic browser fallback from the failed attempt.
    delete next.__forceHtml5;
    if (this._retryStartMs != null) next.startMs = this._retryStartMs;
    delete next.attemptId;
    next.__autoNext = false;
    this.startPlayback(next);
  },

  // 同意弹窗「开启并播放」：写入全局开关后重新决策（同 macOS grantConsent）。
  // 失败不关框——原因就显示在框里，用户还能再点一次
  async grantConsent() {
    const seq = this._playbackSeq;
    const saved = await API.playbackPolicySet({ software_transcode_enabled: true });
    if (seq !== this._playbackSeq) return;
    const view = (saved && saved.data !== undefined) ? saved.data : saved;
    // 保存接口回显的是落库后的取值：不是 true 说明开关根本没生效，不能假装成功
    if (!view || view.software_transcode_enabled !== true) {
      throw new Error('软件转码开关保存后未生效，请重试或查看服务端日志');
    }
    this.retryPlayback();
  },

  // 播放结束 → 自动下一集
  // 下一集按同季剧集表算（服务端会话没有 next_episode 字段，旧代码读它这一段从没跑过）。
  // 把剧集表条目补成 showAutoNextCard 认的形状，卡片本身不动
  onPlaybackEnded() {
    if (this._autoNextTimer) return;
    if (localStorage.getItem('mc_autoNext') === '0' || this._autoNextCancelledGeneration === Player.generation || this._autoNextStreak >= 3) return;
    const next = Player.nextEpisode();
    if (!next) return;
    this.showAutoNextCard({
      context: Player.context,
      media_item_id: Player.sessionData?.media_item_id ?? Player.mediaItemId,
      title: next.name || `第 ${next.episode_number} 集`,
      season_number: Player.seasonNumber,
      episode_number: next.episode_number,
    });
  },

  // 这单片源 HTML5 是否啃不动（DV/全景声/TrueHD/MKV/冷门编码）→ 要原生引擎。
  // audioTracks 形状两用：detail.files[].audio_streams（codec+profile）和
  // decision.audio_tracks（只有 codec）。触发词常在 profile 里——
  // 实测 3301 是 codec:"dts" + profile:"DTS-HD MA + DTS:X"，4425 是
  // codec:"eac3" + profile:"Dolby Digital Plus + Dolby Atmos"，
  // 只看 codec 两条都漏，只剩容器规则兜底
  needsNativePlayer(source, audioTracks) {
    // 杜比视界
    const hdr = (source.hdr || '').toLowerCase();
    // Native gpu-next can accept HDR source and map to its target; HTML5 requests server SDR.
    if (hdr && hdr !== 'sdr' && hdr !== 'none') return true;
    // 全景声/TrueHD/DTS-HD
    for (const t of audioTracks || []) {
      const text = `${t.codec || ''} ${t.profile || ''}`.toLowerCase();
      if (text.includes('truehd') || text.includes('atmos') || text.includes('dts-hd') || text.includes('dtshd') || text.includes('dts:x')) return true;
    }
    // 不支持的容器
    const container = (source.container || '').toLowerCase();
    if (['mkv', 'bluray', 'iso', 'dvd', 'ts', 'm2ts', 'avi', 'wmv', 'flv'].includes(container)) return true;
    // 特殊视频编码
    const vcodec = (source.video_codec || '').toLowerCase();
    if (['vp9', 'vc-1', 'vc1', 'mpeg2', 'mpeg-2', 'theora'].includes(vcodec)) return true;
    return false;
  },

  // 嵌入式 mpv 在不在（只查路径，不启动进程）。结果缓存住：起播热路径上不能
  // 每次都走一遍 Tauri invoke
  async hasEmbeddedPlayer() {
    if (this._mpvReady == null) {
      this._mpvReady = !!(window.__TAURI__?.core?.invoke)
        ? await window.__TAURI__.core.invoke('has_embedded_player').catch(() => false)
        : false;
    }
    return this._mpvReady;
  },

  // 从 detail.files 挑出这一集/这一部实际要播的那一路（in_place 的）。
  // 电影的 season/episode 是 0/0，剧集按季集号对
  pickUnitFile(files, seasonNumber, episodeNumber) {
    const inPlace = (files || []).filter(f => f && f.state === 'in_place');
    if (!inPlace.length) return null;
    const wantEp = seasonNumber != null && episodeNumber != null
      && !(Number(seasonNumber) === 0 && Number(episodeNumber) === 0);
    if (!wantEp) return inPlace[0];
    return inPlace.find(f =>
      Number(f.season_number) === Number(seasonNumber) &&
      Number(f.episode_number) === Number(episodeNumber)
    ) || null;
  },

  // 打开嵌入式 mpv 播放器
  async openEmbeddedPlayer(item, streamUrl, subtitleUrls, startMs, session, seq) {
    const alive = () => this._playbackSeq === seq;
    if (session.decision?.disc || /\/playback\/files\/\d+\/disc(?:[?#]|$)/.test(streamUrl)
      || ['iso', 'dvd'].includes(String(session.source?.container || '').toLowerCase()) && session.decision?.tier === 0) {
      await this.releasePlaybackSession(session);
      if (alive()) this._showPlaybackError('该光盘输入需要服务端生成可播放的视频流');
      return;
    }
    try {
      // 获取视频区域位置
      const playerView = document.getElementById('playerView');
      const videoWrap = document.querySelector('.player-video-wrap');
      if (!playerView || !videoWrap) throw new Error('播放器容器未找到');

      // 显示播放器 UI（但不显示 video 元素，mpv 自己渲染）
      playerView.hidden = false;
      const video = document.getElementById('playerVideo');
      if (video) video.style.display = 'none'; // 隐藏 HTML5 video

      // Tauri 2 获取 HWND
      const hwnd = await window.__TAURI__.core.invoke('get_main_window_hwnd')
        .catch(() => 0);
      if (!alive()) { await this.releasePlaybackSession(session); return; }

      // 计算视频区域在窗口中的位置
      const rect = videoWrap.getBoundingClientRect();
      const scale = window.devicePixelRatio || 1;

      await window.__TAURI__.core.invoke('launch_embedded_player', {
        parentHwnd: hwnd || 0,
        streamUrl: streamUrl,
        subtitleUrls: subtitleUrls,
        startMs: startMs,
        title: item.title || 'MovieClaw',
        x: Math.round(rect.left * scale),
        y: Math.round(rect.top * scale),
        width: Math.round(rect.width * scale),
        height: Math.round(rect.height * scale),
        instanceId: seq,
        hardwareDecode: localStorage.getItem('mc_hwDecode') !== '0',
      });
      if (!alive()) {
        await window.__TAURI__.core.invoke('stop_embedded_player', { instanceId: seq }).catch(() => {});
        await this.releasePlaybackSession(session);
        return;
      }

      // 两个引擎采用同一播放上下文，画质、重连与进度都从这里继续。
      window.__MOVIECLAW_MPV_ACTIVE = true;

      item.__hardwareDecode = localStorage.getItem('mc_hwDecode') !== '0';
      Player.adoptSession(item.title || 'MovieClaw', session, item, 'mpv');
      Player.mpvInstanceId = seq;
      // 选中态是 HTML5 那条链跟的，mpv 自己挑默认轨；留着上一次的值会把勾打错行
      Player.selectedSubtitle = null;
      // 上下集按钮只在剧集里亮；mpv 这条链不走 Player.open，季集号与兄弟表同步要在这做

      // mpv 没有 media element 也没有事件：进度/时长/暂停态靠轮询喂给 UI
      Player.startMpvPoll(startMs);
      Player.syncEmbeddedPlayerRect();

      // 显示控制栏（复用现有 UI）
      Player.showControls();
      Player.autoHideControls();

    } catch (e) {
      if (!alive()) { await this.releasePlaybackSession(session); return; }
      console.error('Embedded player failed:', e);
      window.__MOVIECLAW_MPV_ACTIVE = false;
      // 恢复被隐藏的 video 元素
      const v = document.getElementById('playerVideo');
      if (v) v.style.display = '';
      // 申报了 universal 但 mpv 没起来：档 0 给的是裸文件地址，HTML5 啃不动，
      // 不能就地拿这个 URL 交给 <video>。标 __forceHtml5 重谈一次，
      // 这回如实报浏览器能力，服务端给能播的换壳/转码流
      if (item.__universalClaim) {
        await this.releasePlaybackSession(session);
        if (!alive()) return;
        item.__universalClaim = false;
        item.__forceHtml5 = true;
        return this.startPlayback(item, true);
      }
      Player.open(item.title || 'MovieClaw', streamUrl, subtitleUrls, startMs, session, item);
    }
  },

  showAutoNextCard(next) {
    this.cancelAutoNext();
    const generation = Player.generation;
    const playNext = (automatic = false) => {
      if (generation !== Player.generation || !Player.activeEngine) return;
      const context = next.context || Player.context || {};
      this.cancelAutoNext();
      const item = { ...context, __autoNext: automatic, media_item_id: next.media_item_id, title: next.title,
        seasonNumber: next.season_number, episodeNumber: next.episode_number, startMs: null };
      delete item.attemptId;
      delete item.file_id;
      this.startPlayback(item);
    };
    let card;

    card = document.createElement('div');
    card.id = 'autoNextCard';
    card.className = 'auto-next-card';
    card.innerHTML = `
      <div class="auto-next-info">
        <div class="auto-next-label">即将播放</div>
        <div class="auto-next-title">${escapeHtml(next.title || '下一集')}</div>
        <div class="auto-next-subtitle">S${next.season_number || 1}E${next.episode_number || ''}</div>
      </div>
      <div class="auto-next-countdown" id="autoNextCountdown">8</div>
      <div class="auto-next-actions">
        <button class="btn-secondary" id="btnCancelAutoNext">取消</button>
        <button class="btn-play" id="btnPlayNext">立即播放</button>
      </div>
    `;
    document.getElementById('playerView')?.appendChild(card);

    let countdown = 8;
    const timer = this._autoNextTimer = setInterval(() => {
      if (generation !== Player.generation || !Player.activeEngine) { this.cancelAutoNext(); return; }
      countdown--;
      const el = document.getElementById('autoNextCountdown');
      if (el) el.textContent = countdown;
      if (countdown <= 0) {
        clearInterval(timer);
        card.remove();
        playNext(true);
      }
    }, 1000);

    document.getElementById('btnCancelAutoNext')?.addEventListener('click', () => {
      this._autoNextCancelledGeneration = generation;
      clearInterval(timer);
      card.remove();
    });
    document.getElementById('btnPlayNext')?.addEventListener('click', () => {
      clearInterval(timer);
      card.remove();
      playNext();
    });
  },

  cancelAutoNext() {
    if (this._autoNextTimer) clearInterval(this._autoNextTimer);
    this._autoNextTimer = null;
    document.getElementById('autoNextCard')?.remove();
  },
};

// 启动
document.addEventListener('DOMContentLoaded', () => App.init());
