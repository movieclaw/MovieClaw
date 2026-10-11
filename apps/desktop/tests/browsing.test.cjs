const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function deferred() {
  let resolve;
  const promise = new Promise(yes => { resolve = yes; });
  return { promise, resolve };
}

function harness(respond = () => ({ data: [] })) {
  const calls = [], storage = new Map(), elements = new Map();
  function element(id = '') {
    return { id, innerHTML: '', textContent: '', style: {}, dataset: {}, value: '', hidden: true,
      listeners: new Map(),
      addEventListener(type, callback) { const handlers = this.listeners.get(type) || []; handlers.push(callback); this.listeners.set(type, handlers); },
      async emit(type, event = {}) { for (const callback of this.listeners.get(type) || []) await callback(event); },
      querySelectorAll() { return []; }, querySelector() { return null; },
      classList: { add() {}, remove() {} }, appendChild() {}, remove() {}, setAttribute() {},
    };
  }
  const window = { __MOVIECLAW_SERVER__: 'http://old.invalid', addEventListener() {},
    location: {}, confirm() { return true; }, __TAURI__: { core: { async invoke(command, args) {
      calls.push({ command, ...args });
      if (command === 'get_server_url') return 'http://current.invalid';
      if (command === 'cancel_proxy_request') return null;
      if (command !== 'proxy_api') return null;
      const response = await respond(args);
      return response && 'status' in response ? response : { status: 200, body: JSON.stringify(response), headers: { 'server-timing': 'db;dur=12' } };
    } } } };
  const context = vm.createContext({ window, console, setTimeout, clearTimeout, setInterval, clearInterval, queueMicrotask,
    AbortController, DOMException, Headers, URLSearchParams,
    Player: { async close() {} },
    localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
    document: { addEventListener() {}, querySelectorAll() { return []; },
      getElementById(id) { if (!elements.has(id)) elements.set(id, element(id)); return elements.get(id); },
      createElement: () => element(),
    },
  });
  for (const file of ['api.js', 'app.js']) vm.runInContext(fs.readFileSync(path.join(__dirname, '../ui/desktop', file), 'utf8'), context);
  vm.runInContext('globalThis.A = App; globalThis.C = API; globalThis.Pager = DesktopPager; globalThis.E = APIError;', context);
  return { A: context.A, API: context.C, Pager: context.Pager, APIError: context.E, calls, context, storage, elements, element, window };
}

test('server configuration comes from the current Rust value and updates image resolution', async () => {
  const h = harness();
  await h.API.init();
  assert.equal(h.API.baseUrl, 'http://current.invalid');
  assert.equal(h.window.__MOVIECLAW_SERVER__, h.API.baseUrl);
  assert.equal(vm.runInContext('resolveUrl("/images/assets/poster.jpg")', h.context), 'http://current.invalid/api/v1/images/assets/poster.jpg');
});

test('sidebar collapse persists without changing navigation and search restores the input', () => {
  const h = harness(), classes = new Set(), attributes = {};
  h.context.document.documentElement = { classList: { toggle(name, enabled) { if (enabled) classes.add(name); else classes.delete(name); } } };
  const toggle = h.context.document.getElementById('btnToggleSidebar');
  toggle.setAttribute = (name, value) => { attributes[name] = value; };
  h.A.currentPage = 'detail'; h.A.currentParams = { itemId: 3 }; h.A.session = { username: 'fixture' };
  h.A.setSidebarCollapsed(true);
  assert.equal(h.storage.get('mc_sidebarCollapsed'), 'true');
  assert.equal(attributes['aria-expanded'], 'false'); assert.equal(toggle.title, '展开侧边栏');
  assert.ok(classes.has('sidebar-collapsed')); assert.equal(h.A.currentPage, 'detail');
  const search = h.context.document.getElementById('searchInput'); let focused = 0;
  search.focus = () => focused++; search.select = () => {};
  h.A.focusSearch(); assert.equal(focused, 1); assert.equal(attributes['aria-expanded'], 'true');
  assert.equal(h.storage.get('mc_sidebarCollapsed'), 'false'); assert.equal(h.A.currentParams.itemId, 3);
  h.A.setSidebarCollapsed(true, false); assert.equal(h.storage.get('mc_sidebarCollapsed'), 'false');
  h.A.session = null; h.A.focusSearch(); assert.equal(h.A.sidebarCollapsed, true);
});

test('a delayed configuration read cannot overwrite a newer server selection', async () => {
  const h = harness(), old = deferred(), recent = deferred();
  let reads = 0;
  h.window.__TAURI__.core.invoke = async () => (++reads === 1 ? old.promise : recent.promise);
  const first = h.API.init(), second = h.API.init();
  recent.resolve('http://new.invalid');
  await second;
  old.resolve('http://stale.invalid');
  await first;
  assert.equal(h.API.baseUrl, 'http://new.invalid');
  assert.equal(h.window.__MOVIECLAW_SERVER__, 'http://new.invalid');
});

test('a late authenticated image response cannot replace a newer image or retired account', async () => {
  const h = harness(), old = deferred();
  const image = { src: 'old-source', dataset: { raw: '/old.png' }, style: {},
    getAttribute(name) { return this[name]; }, parentElement: { classList: { add() {} } } };
  h.context.image = image; h.API.proxyImage = () => old.promise;
  vm.runInContext('imgFallback(image, image.dataset.raw)', h.context);
  image.dataset.raw = '/new.png'; image.src = 'new-source';
  old.resolve('data:image/png;base64,OLD'); await old.promise;
  assert.equal(image.src, 'new-source');
  const retired = deferred(); h.API.proxyImage = () => retired.promise;
  delete image.dataset.retried;
  vm.runInContext('imgFallback(image, image.dataset.raw)', h.context);
  h.API.invalidateContext();
  retired.resolve('data:image/png;base64,RETIRED'); await retired.promise;
  assert.equal(image.src, 'new-source');
});

test('Cookie account mutations use username, active and the real DELETE route', async () => {
  const h = harness(args => args.path === '/auth/accounts'
    ? { data: [{ username: 'alice', nickname: 'Alice', active: true }, { username: 'bob', nickname: 'Bob', active: false }] }
    : { data: { username: 'bob', nickname: 'Bob', role: 'member' } });
  const accounts = await h.API.listAccounts();
  assert.equal(accounts.data[0].active, true);
  await h.API.switchAccount('bob');
  await h.API.removeAccount('姓名/a');
  const requests = h.calls.filter(c => c.command === 'proxy_api');
  assert.deepEqual(JSON.parse(requests[1].body), { username: 'bob' });
  assert.equal(requests[2].method, 'DELETE');
  assert.equal(requests[2].path, '/auth/accounts/%E5%A7%93%E5%90%8D%2Fa');
});

test('Cookie mutations await Rust completion and retain explicit timeouts while reads stay bounded', async () => {
  const h = harness(), timers = [];
  const timer = h.context.setTimeout;
  h.context.setTimeout = (callback, delay) => { timers.push(delay); return timer(callback, delay); };
  await h.API.login('bob', 'fixture-password');
  await h.API.createAdmin('bob', 'fixture-password');
  await h.API.switchAccount('bob');
  await h.API.removeAccount('alice');
  await h.API.request('/auth/logout', { method: 'POST' });
  assert.deepEqual(timers, [], 'a JS-only timeout cannot safely abandon a Cookie mutation');
  await h.API.getSession();
  await h.API.listLibraries();
  assert.deepEqual(timers, [20000, 20000]);
  await h.API.login('bob', 'fixture-password', true, { timeoutMs: 123 });
  await h.API.createAdmin('bob', 'fixture-password', { timeoutMs: 124 });
  assert.deepEqual(timers, [20000, 20000, 123, 124]);
});

test('pending login guards duplicate submit, cancel and server change until failure or final identity settles', async () => {
  const first = deferred(), second = deferred();
  let attempts = 0, cookie = 'alice';
  const h = harness(async args => {
    if (args.path === '/auth/login') {
      attempts++;
      if (attempts === 1) return first.promise;
      await second.promise;
      cookie = 'bob';
      return { data: { username: cookie } };
    }
    if (args.path === '/auth/me') return { data: { username: cookie } };
    return { data: [] };
  });
  h.context.document.querySelector = () => null;
  h.A.renderHome = async () => {};
  h.A.session = { username: 'alice' };
  h.A.renderLogin({ addAccount: true });
  h.context.document.getElementById('loginUser').value = 'bob';
  h.context.document.getElementById('loginPass').value = 'fixture-password';
  const form = h.elements.get('loginForm'), cancel = h.elements.get('cancelAddAccount'), change = h.elements.get('loginChangeServer'), button = h.elements.get('loginBtn');
  const pending = form.emit('submit', { preventDefault() {} });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(attempts, 1);
  assert.equal(cancel.disabled, true);
  assert.equal(change.disabled, true);
  await cancel.emit('click'); await change.emit('click'); await form.emit('submit', { preventDefault() {} });
  assert.equal(attempts, 1);
  assert.equal(h.calls.some(call => call.command === 'clear_server_url' || call.path === '/auth/me'), false);
  first.resolve({ status: 401, body: JSON.stringify({ message: '密码错误' }) });
  await pending;
  assert.equal(button.disabled, false);
  assert.equal(cancel.disabled, false);
  assert.equal(change.disabled, false);
  assert.equal(h.elements.get('loginError').textContent, '密码错误');
  const retry = form.emit('submit', { preventDefault() {} });
  await new Promise(resolve => setImmediate(resolve));
  await cancel.emit('click'); await change.emit('click');
  assert.equal(attempts, 2);
  assert.equal(cookie, 'alice');
  second.resolve(); await retry;
  assert.equal(cookie, 'bob');
  assert.equal(h.A.session.username, 'bob');
  assert.equal(h.A._authPending, false);
  assert.equal(h.A._changingContext, false);
});

for (const action of ['login', 'bootstrap', 'logout', 'remove', 'switch']) {
  test(`${action} retires the old progress identity before the server can change its Cookie`, async () => {
    const closing = deferred(), progress = deferred();
    const expectedPath = { login: '/auth/login', bootstrap: '/auth/bootstrap', logout: '/auth/logout', remove: '/auth/accounts/alice', switch: '/auth/accounts/switch' }[action];
    let mutation = false, h;
    h = harness(args => {
      if (args.path === '/playback/progress') return progress.promise;
      if (args.path === '/auth/accounts') return { data: [{ username: 'alice', active: true }] };
      if (args.path === expectedPath && args.method !== 'GET') {
        mutation = true;
        assert.equal(h.API.contextEpoch, 1, 'the old queue identity must already be retired at Cookie mutation');
        assert.equal(h.A._authPending, true);
        return { data: { username: 'bob' } };
      }
      return { data: [] };
    });
    h.A.session = { username: 'alice' };
    h.context.Player.close = () => closing.promise;
    h.A.enterSession = async response => { h.A.session = response.data; h.A._authPending = false; };
    let run;
    if (action === 'switch') run = () => h.A.switchToAccount('bob');
    else if (action === 'logout') {
      h.A.renderSettings(h.element());
      run = () => h.elements.get('btnLogout').emit('click');
    } else if (action === 'remove') {
      const list = h.context.document.getElementById('accountList'), button = h.element();
      button.closest = () => ({ dataset: { username: 'alice' } });
      list.querySelectorAll = selector => selector === '.account-remove' ? [button] : [];
      await h.A.loadAccounts();
      run = () => button.emit('click');
    } else {
      h.A.renderLogin({ setup: action === 'bootstrap', addAccount: action === 'login' });
      h.context.document.getElementById('loginUser').value = 'bob';
      h.context.document.getElementById('loginPass').value = 'safe-password';
      if (action === 'bootstrap') h.context.document.getElementById('loginConfirm').value = 'safe-password';
      run = () => h.elements.get('loginForm').emit('submit', { preventDefault() {} });
    }
    const old = h.API.reportProgress(42, 'stop', 321000, 1000000, null, null, {}, { timeoutMs: 0, cancelable: true });
    const stopped = assert.rejects(old, error => error.name === 'AbortError');
    const request = run();
    assert.equal(mutation, false, 'old-player stop gets its bounded chance before the Cookie changes');
    closing.resolve();
    await request; await stopped;
    assert.equal(mutation, true);
    assert.equal(h.A.session.username, 'bob');
    const reportId = h.calls.find(call => call.path === '/playback/progress').requestId;
    assert.ok(h.calls.some(call => call.command === 'cancel_proxy_request' && call.requestId === reportId));
    progress.resolve({ data: {} });
  });
}

test('API errors keep status, code and response headers without dumping an HTML response', async () => {
  const h = harness(() => ({ status: 401, body: JSON.stringify({ code: 'SESSION_EXPIRED', message: '请重新登录' }), headers: { 'server-timing': 'auth;dur=2' } }));
  let unauthorized = 0;
  h.API.onUnauthorized = error => { unauthorized++; assert.equal(error.status, 401); };
  await assert.rejects(h.API.request('/libraries'), error => error.status === 401 && error.code === 'SESSION_EXPIRED' && error.headers.get('server-timing') === 'auth;dur=2');
  assert.equal(unauthorized, 1);
  await assert.rejects(h.API.getSession(), error => error.status === 401);
  assert.equal(unauthorized, 1, 'a failed login is handled by its own form');
});

test('GET timeout and AbortSignal both cancel the proxy request', async () => {
  const h = harness(() => new Promise(() => {}));
  await assert.rejects(h.API.request('/libraries', { timeoutMs: 5 }), error => error.code === 'TIMEOUT');
  const controller = new AbortController();
  const request = h.API.scope(controller.signal).request('/collections', { timeoutMs: 0 });
  controller.abort();
  await assert.rejects(request, error => error.name === 'AbortError');
  assert.equal(h.calls.filter(c => c.command === 'cancel_proxy_request').length, 2);
});

test('context invalidation cancels reads but preserves a late session creation response for cleanup', async () => {
  const response = deferred();
  const h = harness(args => args.path === '/playback/sessions' ? response.promise : new Promise(() => {}));
  const read = h.API.request('/libraries', { timeoutMs: 0 });
  const session = h.API.request('/playback/sessions', { method: 'POST', body: { media_item_id: 7 }, timeoutMs: 0 });
  h.API.invalidateContext();
  await assert.rejects(read, error => error.name === 'AbortError');
  response.resolve({ data: { session_id: 'late-session' } });
  assert.equal((await session).data.session_id, 'late-session');
  assert.equal(h.calls.filter(c => c.command === 'cancel_proxy_request').length, 1);
});

test('search consumes the real nested hits and sends the cursor for subsequent pages', async () => {
  const h = harness(args => ({ data: { query: '诺兰', items: [{ item: { media_item_id: 42, kind: 'movie', title: '星际穿越' }, library_ids: [9], match: { label: '导演 诺兰' } }], people: [], suggestions: [], next_cursor: args.path.includes('cursor=') ? null : 'page-2', index_pending: false } }));
  h.A.libraries = [{id:9,name:'电影库',kind:'movie'}];
  let settings;
  h.A.renderPagedWall = async (_, config) => { settings = config; };
  await h.A.renderSearch(h.element(), '诺兰');
  const page = await settings.fetchPage({ limit: 60, offset: 0, cursor: null });
  assert.equal(page.items[0].title, '星际穿越');
  assert.equal(page.items[0].library_id, 9);
  assert.equal(page.items[0].match_label, '导演 诺兰');
  assert.equal(page.hasMore, true);
  const next = await settings.fetchPage({ limit: 60, cursor: page.cursor });
  assert.equal(next.hasMore, false);
  assert.ok(h.calls.some(c => c.path?.includes('cursor=page-2')));
});

test('a 5101-item list loads one page initially and can reach every item without a fixed cap', async () => {
  const data = Array.from({ length: 5101 }, (_, n) => ({ media_item_id: n + 1, title: 'Movie ' + (n + 1), kind: 'movie' }));
  const h = harness(args => {
    const params = new URLSearchParams(args.path.split('?')[1]);
    return { data: data.slice(Number(params.get('offset')), Number(params.get('offset')) + Number(params.get('limit'))) };
  });
  let config;
  h.A.renderPagedWall = async (_, value) => { config = value; };
  await h.A.renderLibrary({}, 9);
  const pager = new h.Pager(config.fetchPage, () => true);
  await pager.loadMore();
  assert.equal(pager.items.length, 60);
  assert.equal(h.calls.filter(c => c.command === 'proxy_api').length, 1);
  while (pager.hasMore) await pager.loadMore();
  assert.equal(pager.items.length, 5101);
  assert.equal(pager.items.at(-1).media_item_id, 5101);
});

test('pagination deduplicates an overlapping page while advancing by the raw page count', async () => {
  const h = harness();
  const offsets = [];
  const pager = new h.Pager(async ({ offset }) => {
    offsets.push(offset);
    return offset === 0 ? { items: [{ media_item_id: 1 }, { media_item_id: 2 }], rawCount: 2, hasMore: true }
      : { items: [{ media_item_id: 2 }, { media_item_id: 3 }], rawCount: 2, hasMore: false };
  }, () => true);
  await pager.loadMore(); await pager.loadMore();
  assert.deepEqual(offsets, [0, 2]);
  assert.equal(pager.offset, 4);
  assert.deepEqual(Array.from(pager.items, item => item.media_item_id), [1, 2, 3]);
});

test('a late page cannot change the state after its route is replaced', async () => {
  const h = harness(), old = deferred();
  let generation = 1;
  const pager = new h.Pager(() => old.promise, () => generation === 1);
  const request = pager.loadMore();
  generation = 2;
  old.resolve({ items: [{ media_item_id: 1 }], hasMore: false });
  await request;
  assert.equal(pager.items.length, 0);
  assert.equal(pager.offset, 0);
});

test('sort preferences are isolated by server, username and wall and are sent to the server', async () => {
  const h = harness();
  h.API.baseUrl = 'http://a.invalid'; h.A.session = { username: 'alice' };
  const prefs = h.A.wallPreferences('library-9');
  h.storage.set(prefs.key, JSON.stringify({ sort: 'rating', order: 'asc', unwatched: true }));
  let config;
  h.A.renderPagedWall = async (_, value) => { config = value; };
  await h.A.renderLibrary({}, 9);
  await config.fetchPage({ offset: 0, limit: 60 });
  const request = h.calls.find(c => c.command === 'proxy_api');
  const params = new URLSearchParams(request.path.split('?')[1]);
  assert.equal(params.get('sort'), 'rating'); assert.equal(params.get('order'), 'asc'); assert.equal(params.get('w'), 'unwatched');
  h.A.session = { username: 'bob' };
  assert.equal(h.A.wallPreferences('library-9').sort, 'added_at');
  h.A.session = { username: 'alice' }; h.API.baseUrl = 'http://b.invalid';
  assert.equal(h.A.wallPreferences('library-9').sort, 'added_at');
});

test('person uses inline credits, displays missing sources and never requests a credits endpoint', async () => {
  const h = harness(() => ({ data: { tmdb_person_id: 1, name: '演员', original_name: 'Actor', credits: [
    { media_item_id: 1, library_id: 9, title: '现有作品', department: 'cast', character: '角色' },
    { media_item_id: 2, library_id: null, title: '移除作品', department: 'director' },
  ] } }));
  const container = h.element(), back = h.element('personBack');
  container.querySelector = selector => selector === '#personBack' ? back : null;
  let returned = false; h.A.goBack = () => { returned = true; };
  await h.A.renderPerson(container, { personId: 1 });
  assert.ok(container.innerHTML.includes('现有作品'));
  assert.ok(container.innerHTML.includes('片源已移除'));
  assert.ok(container.innerHTML.includes('aria-disabled="true"'));
  assert.equal(h.calls.filter(c => c.command === 'proxy_api').length, 1);
  assert.equal(h.calls[0].path, '/people/1');
  await back.emit('click'); assert.equal(returned, true);
});

test('poster text and URL attributes escape hostile metadata and reject script schemes', () => {
  const h = harness();
  const html = h.A.posterCard({ media_item_id: 1, library_id: 9, title: '<script>window.pwn=1</script>', year: '<img src=x>', poster_url: 'javascript:alert(1)', match_label: '" onclick="alert(1)' });
  assert.ok(!html.includes('<script>'));
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(html.includes('src=""'));
  assert.ok(html.includes('&quot; onclick=&quot;'));
});

test('startup distinguishes bootstrap, expired credentials and an unreachable server', async () => {
  for (const state of ['bootstrap', 'expired', 'offline']) {
    const h = harness(args => {
      if (state === 'offline') throw new Error('connection refused');
      if (args.path === '/health') return { status: 200, body: JSON.stringify({ status: 'ok', version: '0.34.0' }), headers: {} };
      if (args.path === '/auth/bootstrap') return { data: { initialized: state !== 'bootstrap' } };
      return { status: 401, body: JSON.stringify({ message: 'expired' }), headers: {} };
    });
    h.A.bindEvents = () => {};
    let result;
    h.A.renderLogin = options => { result = options?.setup ? 'bootstrap' : 'expired'; };
    h.A.renderConnectionState = phase => { result = phase; };
    await h.A.init();
    assert.equal(result, state === 'offline' ? 'unreachable' : state);
  }
});

test('a successful login with an unavailable sidebar provides a visible recovery path', async () => {
  const h = harness(() => ({ status: 503, body: JSON.stringify({ message: '服务器正在重启' }) }));
  await h.A.enterSession({ data: { username: 'alice' } });
  const content = h.elements.get('content');
  assert.ok(content.innerHTML.includes('服务器正在重启'));
  assert.ok(content.innerHTML.includes('retryConnection'));
  assert.equal(h.A._authPending, true);
});

test('a renewed login restores the original route after the account data is ready', async () => {
  const h = harness(args => ({ data: args.path === '/libraries' ? [{ id: 9, name: '电影', kind: 'movie' }] : [] }));
  h.A._resumeRoute = { page: 'detail', params: { itemId: 42, libraryId: 9 } };
  let route;
  h.A.navigate = async (page, params) => { route = { page, ...params }; };
  await h.A.enterSession({ data: { username: 'alice' } });
  assert.deepEqual(route, { page: 'detail', itemId: 42, libraryId: 9 });
  assert.equal(h.A._resumeRoute, null);
  assert.equal(h.A._authPending, false);
});

test('stop refresh updates only the matching card and retains every loaded page and scroll position', async () => {
  const h = harness(args => ({ data: args.path.startsWith('/playback/marks')
    ? { played: false, is_favorite: true } : { position_ms: 321000, duration_ms: 1000000, played: false } }));
  const items = Array.from({ length: 201 }, (_, n) => ({ media_item_id: n + 1, library_id: 9, title: 'Movie ' + (n + 1) }));
  const card = {}, grid = h.element(), container = h.element();
  grid.querySelector = () => card;
  container.scrollTop = 2000;
  container.querySelector = () => ({ getBoundingClientRect: () => ({ top: 1000 }) });
  container.getBoundingClientRect = () => ({ bottom: 0 });
  const pager = { items, offset: 201, hasMore: true };
  h.A.currentPage = 'library'; h.A.pageAPI = h.API;
  h.A._wallContext = { pager, grid, container, generation: 0, libraryId: 9, prefs: {}, load() {} };
  await h.A.refreshStoppedItem({ mediaItemId: 201, libraryId: 8 });
  assert.equal(h.calls.length, 0, 'a different library must not affect this wall');
  await h.A.refreshStoppedItem({ mediaItemId: 201, libraryId: 9 });
  assert.equal(pager.items.length, 201);
  assert.equal(pager.offset, 201);
  assert.equal(container.scrollTop, 2000);
  assert.equal(items.at(-1).progress_percent, 32);
  assert.ok(card.outerHTML.includes('poster-fav'));
  assert.equal(h.calls.filter(c => c.command === 'proxy_api').length, 2);
});

test('stop refresh removes a completed item from the unwatched wall and keeps the next offset aligned', async () => {
  const h = harness(args => ({ data: args.path.startsWith('/playback/marks') ? { played: true } : { played: true, position_ms: 1000 } }));
  const item = { media_item_id: 42, library_id: 9 }, grid = h.element(), count = h.element(), container = h.element();
  let removed = false;
  grid.querySelector = () => ({ remove() { removed = true; } });
  container.querySelector = () => ({ getBoundingClientRect: () => ({ top: 1000 }) });
  container.getBoundingClientRect = () => ({ bottom: 0 });
  const pager = Object.assign(new h.Pager(async () => ({ items: [] }), () => true), { items: [item], offset: 60, total: 201, hasMore: true });
  h.A.currentPage = 'library'; h.A.pageAPI = h.API;
  h.A._wallContext = { pager, grid, count, container, generation: 0, libraryId: 9, prefs: { unwatched: true }, load() {} };
  await h.A.refreshStoppedItem({ mediaItemId: 42, libraryId: 9 });
  assert.equal(removed, true);
  assert.equal(pager.items.length, 0);
  assert.equal(pager.offset, 59);
  assert.equal(pager.total, 200);
});

test('a watched item removed during an in-flight page repairs exactly the missing boundary item', async () => {
  const h = harness(args => ({ data: args.path.startsWith('/playback/marks') ? { played: true } : { played: true } }));
  const original = Array.from({ length: 201 }, (_, n) => ({ media_item_id: n + 1, library_id: 9 }));
  const filtered = original.filter(item => item.media_item_id !== 20), pending = deferred(), requested = [];
  const pager = new h.Pager(async ({ offset, limit }) => {
    requested.push({ offset, limit });
    if (offset === 60) return pending.promise;
    const items = (offset === 0 ? original : filtered).slice(offset, offset + limit);
    return { items, rawCount: items.length, hasMore: items.length === limit };
  }, () => true);
  await pager.loadMore();
  const next = pager.loadMore();
  const grid = h.element(), container = h.element(), count = h.element();
  grid.insertAdjacentHTML = () => {};
  grid.querySelector = selector => ({ remove() {}, insertAdjacentHTML() {} });
  container.querySelector = () => ({ getBoundingClientRect: () => ({ top: 1000 }) });
  container.getBoundingClientRect = () => ({ bottom: 0 });
  h.A.currentPage = 'library'; h.A.pageAPI = h.API;
  h.A._wallContext = { pager, grid, count, container, generation: 0, libraryId: 9, prefs: { unwatched: true }, load() {} };
  const refresh = h.A.refreshStoppedItem({ mediaItemId: 20, libraryId: 9 });
  const items = filtered.slice(60, 120);
  pending.resolve({ items, rawCount: items.length, hasMore: true });
  await next; await refresh;
  assert.deepEqual(requested, [{ offset: 0, limit: 60 }, { offset: 60, limit: 60 }, { offset: 59, limit: 1 }]);
  assert.deepEqual(Array.from(pager.items, item => item.media_item_id), filtered.slice(0, 120).map(item => item.media_item_id));
  assert.equal(pager.offset, 120);
  while (pager.hasMore) await pager.loadMore();
  assert.equal(pager.items.length, 200);
  assert.equal(new Set(pager.items.map(item => item.media_item_id)).size, 200);
});

test('HomeRows resolves saved order, hidden builtins, legacy rows and pinned collections against visible sources', () => {
  const h = harness();
  const rows = vm.runInContext(`HomeRows.build([
    {id:'row:collection',collection_id:8}, {id:'favorites',hidden:true}, {id:'kind:movie',hidden:true},
    {id:'row:played',library_id:1,sort:'last_played',unwatched:true}, {id:'lib:2'}, {id:'row:unavailable',collection_id:9}
  ], [{id:1,name:'电影库',kind:'movie'},{id:2,name:'隐藏库',kind:'tv',exclude_from_home:true},{id:3,kind:'photo'}],
  [{id:8,name:'精选',sort:'release_date_asc'},{id:9,name:'不可见',hidden:true}])`, h.context);
  assert.equal(rows[0].id, 'row:collection'); assert.equal(rows[0].sort, 'release_date'); assert.equal(rows[0].order, 'asc');
  assert.equal(rows.find(row => row.id === 'favorites').hidden, true);
  assert.equal(rows.find(row => row.id === 'row:played').unwatched, false);
  assert.equal(rows.some(row => ['lib:2','kind:movie','row:unavailable'].includes(row.id)), false);
  h.context.rowsForTest = rows;
  assert.deepEqual(Array.from(vm.runInContext('HomeRows.pinned(rowsForTest)', h.context), col => col.id), [8]);
  assert.ok(rows.some(row => row.id === 'genres:movie')); assert.ok(rows.some(row => row.id === 'lib:1'));
});

test('home source queries preserve favorites grouping and last-played seen filters in the complete wall', async () => {
  const h = harness(() => ({ data: [] }));
  await h.A.fetchHomeRow(h.API, { type:'favorites', sort:'unwatched_first', order:'desc' }, { offset:60,limit:60 });
  await h.A.fetchHomeRow(h.API, { type:'kind',media_kind:'tv',sort:'last_played',order:'asc',unwatched:true,genre:'28' }, { offset:120,limit:60 });
  const paths = h.calls.filter(call => call.command === 'proxy_api').map(call => call.path);
  assert.match(paths[0], /sort=favorited_at/); assert.match(paths[0], /unwatched_first=true/);
  const query = new URLSearchParams(paths[1].split('?')[1]);
  assert.equal(paths[1].split('?')[0], '/libraries/kinds/tv/items');
  assert.equal(query.get('w'),'seen'); assert.equal(query.get('g'),'28'); assert.equal(query.get('order'),'asc');
});

test('episode bands respect 49/50/51, sparse ranges and the 1050 to 1051 boundary', () => {
  const h = harness();
  assert.deepEqual(Array.from(vm.runInContext('EpisodeRanges.ranges(Array.from({length:50},(_,i)=>({episode_number:i+1})))',h.context)),[]);
  const ranges = vm.runInContext('EpisodeRanges.ranges(Array.from({length:51},(_,i)=>({episode_number:i+49})))',h.context);
  assert.deepEqual(Array.from(ranges, row=>[row.index,row.label]),[[0,'49–50'],[1,'51–99']]);
  assert.equal(vm.runInContext('EpisodeRanges.index(1050)', h.context),20);
  assert.equal(vm.runInContext('EpisodeRanges.index(1051)', h.context),21);
});

test('recent searches are recorded on selection, bounded and isolated by account and server', () => {
  const h=harness(); h.API.baseUrl='http://a.invalid'; h.A.session={username:'alice'};
  for(let i=0;i<15;i++) h.A.rememberSearch('标题 '+i);
  assert.equal(h.A.recentSearches().items.length,10); assert.equal(h.A.recentSearches().items[0],'标题 14');
  h.A.session={username:'bob'}; assert.equal(h.A.recentSearches().items.length,0);
  h.A.rememberSearch('Bob'); h.API.baseUrl='http://b.invalid'; assert.equal(h.A.recentSearches().items.length,0);
});

test('person-filter search sends the local person id alongside the stable cursor', async () => {
  const h=harness(()=>({data:{items:[],people:[],suggestions:[],next_cursor:null}})); let config;
  h.A.libraries = [{id:1,name:'电影库',kind:'movie'}];
  h.A.renderPagedWall=async(_,value)=>config=value;
  await h.A.renderSearch(h.element(),'演员',0,{id:9,name:'演员'});
  await config.fetchPage({limit:60,cursor:'cursor-two'});
  const query=new URLSearchParams(h.calls.find(call=>call.path?.startsWith('/search/')).path.split('?')[1]);
  assert.equal(query.get('person_id'),'9'); assert.equal(query.get('cursor'),'cursor-two');
});

test('native credentials use opaque native account commands and structured failures, never device tokens in JS', async () => {
  const h=harness(); const native=[];
  h.window.__TAURI__.core.invoke=async(command,args)=>{ native.push({command,args}); if(command==='native_auth_status') return {mode:'device',session:{username:'alice'},accounts:[{username:'alice',active:true}],pairing_supported:true}; if(command==='native_remove_account') throw JSON.stringify({status:401,code:'REVOKED',message:'设备已失效'}); return {mode:'device',session:{username:args?.username||'bob'},accounts:[]}; };
  await h.API.getNativeAuthStatus(); await h.API.login('bob','fixture-password'); await h.API.switchAccount('alice'); await h.API.logout();
  await assert.rejects(h.API.removeAccount('alice'),error=>error.status===401&&error.code==='REVOKED');
  assert.deepEqual(native.map(call=>call.command),['native_auth_status','native_password_login','native_select_account','native_logout','native_remove_account']);
  assert.equal(native.some(call=>call.args?.token||call.args?.device_code),false);
});

test('large-wall payload cache keeps twelve pages and rehydrates evicted pages by their original cursor or offset', async () => {
  const h=harness(); const calls=[];
  const pager=new h.Pager(async page=>{calls.push({...page}); return {items:Array.from({length:60},(_,i)=>({media_item_id:page.offset+i+1,title:'Large payload '+(page.offset+i+1),poster_url:'/images/'+(page.offset+i+1)})),rawCount:60,hasMore:true,cursor:'next-'+(page.offset+60)};},()=>true);
  pager.enableWindow(12);
  for(let i=0;i<40;i++) await pager.loadMore();
  assert.equal(pager.items.length,2400); assert.equal(pager.offset,2400);
  assert.equal(pager.cachedPages.size,12); assert.equal(pager.items.filter(item=>!item._evicted).length,720);
  assert.equal(pager.items[0].title,undefined);
  await pager.hydrateRange(0,60);
  assert.equal(pager.items[0].title,'Large payload 1'); assert.equal(pager.cachedPages.size,12);
  assert.equal(calls.at(-1).offset,0); assert.equal(calls.at(-1).cursor,null);
  await pager.hydrateRange(60,120); assert.equal(calls.at(-1).cursor,'next-60');
});

test('an old native status cannot overwrite metadata after its server or account context is retired', async () => {
  const h=harness(), stale=deferred();
  h.API.nativeAuthAvailable=true; h.API.nativeAuthStatus={mode:'device',session:{username:'new'}};
  h.window.__TAURI__.core.invoke=()=>stale.promise;
  const old=h.API.getNativeAuthStatus(); h.API.invalidateContext();
  stale.resolve({mode:'cookie',session:{username:'old'},accounts:[]});
  assert.equal(await old,null); assert.equal(h.API.nativeAuthStatus.session.username,'new');
});
