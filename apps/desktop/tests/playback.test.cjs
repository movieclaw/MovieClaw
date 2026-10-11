const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

test('native speed uses mpv bytes per second and never substitutes stale HLS traffic', () => {
  const h = harness();
  const badge = {hidden:true,textContent:''}; h.elements.set('playerSpeedBadge',badge);
  h.elements.set('playerInfoPanel',{hidden:true});
  h.P.activeEngine = 'mpv'; h.P._net = {bytes:90000000,points:[],bps:999999,frags:[]};
  h.win.__MOVIECLAW_MPV_ACTIVE = true;
  h.P.mpvState = {properties:{'cache-speed':3*1024*1024}};
  h.P._tickNetMeter(); assert.equal(badge.textContent,'↓ 3.0 MB/s'); assert.equal(badge.hidden,false);
  h.P.mpvState.properties['cache-speed']=0; h.P._tickNetMeter(); assert.equal(badge.textContent,'↓ 0 KB/s');
  delete h.P.mpvState.properties['cache-speed']; h.P._tickNetMeter(); assert.equal(badge.textContent,'↓ —');
  h.P.mpvState.properties['cache-speed']=-1; h.P._tickNetMeter(); assert.equal(h.P._net.bps,null);
  h.P.stopNetMeter(); assert.equal(badge.hidden,true);
});

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

function harness(options = {}) {
  const storage = new Map(Object.entries(options.storage || {}));
  const calls = [], events = [], timers = new Map(), intervals = new Map(), elements = new Map();
  let timer = 0;
  function element(id) {
    const listeners = new Map();
    return {
      id, style: { setProperty(name, value) { this[name] = value; } }, dataset: {}, hidden: false, children: [], innerHTML: '', textContent: '',
      classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
      addEventListener(name, fn) { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(fn); },
      emit(name) { for (const fn of listeners.get(name) || []) fn({ target: this }); },
      appendChild(child) { this.children.push(child); if (child.id) elements.set(child.id, child); },
      remove() { elements.delete(this.id); },
      removeAttribute() {}, canPlayType() { return ''; }, querySelectorAll() { return []; },
      getBoundingClientRect() { return { left: 0, top: 0, right: 1000, bottom: 700, width: 1000, height: 700 }; },
    };
  }
  for (const id of ['playerView', 'playerTitle', 'playerLoading', 'playerLoadingText', 'playerSeek', 'playerRemaining', 'playerVideo', 'playerTopbar', 'playerControls']) {
    elements.set(id, element(id));
  }
  const video = Object.assign(elements.get('playerVideo'), {
    currentTime: 0, duration: 0, paused: true, volume: 1, muted: false, textTracks: [], readyState: 0,
    buffered: { length: 0 }, play() { this.paused = false; return Promise.resolve(); },
    pause() { this.paused = true; }, load() {},
  });
  const API = {
    baseUrl: 'https://server.invalid', contextEpoch: 0,
    reportProgress(...args) { calls.push(['progress', ...args]); return options.reportProgress ? options.reportProgress(...args) : Promise.resolve(); },
    sessionStop(id) { calls.push(['stop', id]); return Promise.resolve(); },
    sessionPing(id) { calls.push(['ping', id]); return Promise.resolve(); },
    getItemDetail() { return Promise.resolve({ kind: 'movie', files: [] }); },
    getItemEpisodes() { return Promise.resolve({ episodes: [] }); },
    getResume() { return Promise.resolve({}); },
    rawFetch(route) { calls.push(['rawFetch', route]); return Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('[Script Info]\n') }); },
    request(route, args) { if (route === '/playback/client-log') { calls.push(['client-log', args.body]); return Promise.resolve({}); } if (route === '/playback/metrics') { calls.push(['metrics', args.body]); return Promise.resolve({}); } if (route.includes('/playback/files/')) { calls.push(['preview-request', route, args]); return Promise.resolve(options.preview || { ready: false }); } calls.push(['request', route, args]); return options.request ? options.request(route, args) : Promise.resolve(session()); },
  };
  const win = {
    devicePixelRatio: 1, __MOVIECLAW_SERVER__: API.baseUrl,
    dispatchEvent(event) { events.push(event); }, addEventListener() {},
    __TAURI__: { core: { async invoke(name, args) {
      calls.push(['invoke', name, args]);
      if (options.invoke) return options.invoke(name, args);
      if (name === 'has_embedded_player') return false;
      if (name === 'get_main_window_hwnd') return 1;
      if (name === 'get_embedded_player_status') return { running: true };
      if (name === 'get_embedded_player_state') return { status: { running: true }, properties: {} };
      if (name === 'grant_media_stream') return { streamId: 'cap-' + calls.length, url: 'http://127.0.0.1:3210/cap' };
      return {};
    } } },
  };
  const context = vm.createContext({
    window: win, API, navigator: { userAgent: 'test', ...options.navigator }, AbortController, DOMException, URL, TextEncoder, TextDecoder, Headers, Response, fetch: options.fetch || fetch, performance: { now: () => 1000 },
    console: { log() {}, warn() {}, error() {} },
    localStorage: { getItem(key) { return storage.get(key) ?? null; }, setItem(key, value) { storage.set(key, value); } },
    document: { fullscreenElement: null, addEventListener() {}, removeEventListener() {},
      getElementById: id => elements.get(id) || null,
      querySelector: () => element('wrap'), querySelectorAll: () => [], createElement: () => element(''),
    },
    CustomEvent: class { constructor(type, { detail }) { this.type = type; this.detail = detail; } },
    setTimeout(fn, ms) { const id = ++timer; timers.set(id, { fn, ms }); return id; },
    clearTimeout(id) { timers.delete(id); },
    setInterval(fn, ms) { const id = ++timer; intervals.set(id, { fn, ms }); return id; },
    clearInterval(id) { intervals.delete(id); },
    requestAnimationFrame(fn) { fn(); },
    atob: data => Buffer.from(data, 'base64').toString('binary'),
  });
  for (const file of ['player.js', 'app.js']) vm.runInContext(fs.readFileSync(path.join(__dirname, '../ui/desktop', file), 'utf8'), context);
  vm.runInContext('globalThis.P = Player; globalThis.A = App; globalThis.readBrowserCapability = getCapabilitySnapshot; getCapabilitySnapshot = async () => ({video:[],audio:[],containers:["mp4"]});', context);
  const P = context.P, A = context.A;
  P.init();
  A.libraries = [{ id: 9 }];
  return { P, A, API, calls, events, video, elements, timers, intervals, context, win, storage };
}

function session(overrides = {}) {
  return { media_item_id: 77, session_id: 'session-a', stream_url: '/playback/a.mp4', timeline: 'file',
    start_ms: 0, watch: { duration_ms: 3600000 }, decision: { tier: 3, file_id: 81 }, ...overrides };
}
function item(overrides = {}) {
  return { media_item_id: 77, library_id: 9, title: 'Title', kind: 'movie', files: [],
    seasonNumber: 0, episodeNumber: 0, episodes: [], ...overrides };
}

test('fullscreen fill preserves aspect ratio and resets HTML5 to contain outside fullscreen', async () => {
  const h = harness({ storage: { mc_fullscreenFit: 'cover' } });
  assert.equal(h.P.fullscreenFit, 'cover');
  await h.P.applyFullscreenFit();
  assert.equal(h.video.style.objectFit, 'contain');
  h.context.document.fullscreenElement = h.video;
  await h.P.applyFullscreenFit();
  assert.equal(h.video.style.objectFit, 'cover');
  assert.equal(await h.P.setFullscreenFit('contain'), true);
  assert.equal(h.video.style.objectFit, 'contain');
  assert.equal(h.storage.get('mc_fullscreenFit'), 'contain');
  assert.equal(await h.P.setFullscreenFit('stretch'), false);
});

test('failed or stale native frame changes cannot overwrite the saved preference', async () => {
  const pending = deferred();
  let fail = true;
  const h = harness({ storage: { mc_fullscreenFit: 'cover' }, invoke: async name => {
    if (name === 'send_mpv_command_embedded') { if (fail) throw new Error('pipe closed'); return pending.promise; }
    return {};
  } });
  h.win.__MOVIECLAW_MPV_ACTIVE = true;
  h.P._nativeFullscreen = true;
  assert.equal(await h.P.setFullscreenFit('contain'), false);
  assert.equal(h.P.fullscreenFit, 'cover');
  assert.equal(h.storage.get('mc_fullscreenFit'), 'cover');
  fail = false;
  const changing = h.P.setFullscreenFit('contain');
  h.P.generation++;
  pending.resolve({ error: 'success' });
  assert.equal(await changing, false);
  assert.equal(h.P.fullscreenFit, 'cover');
});

test('HTML5 reports only after first frame and uses file time for a session-relative stream', async () => {
  const h = harness();
  h.P.open('Title', 'https://server.invalid/a.mp4', [], 0, session({ timeline: 'session', start_ms: 1800000 }), item());
  assert.equal(h.calls.filter(c => c[0] === 'progress').length, 0);
  h.video.currentTime = 60;
  h.video.duration = 1800;
  h.video.emit('playing');
  await flush();
  assert.equal(h.P.engPos(), 1860);
  assert.equal(h.P.engDuration(), 3600);
  assert.equal(h.calls.find(c => c[0] === 'progress')[3], 1860000);
  const ping = [...h.intervals.values()].find(t => t.ms === 30000);
  await ping.fn();
  assert.deepEqual(h.calls.filter(c => c[0] === 'ping'), [['ping', 'session-a']]);
  await h.P.close();
  assert.equal(h.calls.filter(c => c[0] === 'progress').at(-1)[3], 1860000);
  assert.equal(h.events.at(-1).type, 'movieclaw:playback-stopped');
});

test('closing mpv snapshots its position before clearing the engine and reports stop once', async () => {
  const h = harness();
  h.P.adoptSession('Title', session(), item(), 'mpv');
  h.win.__MOVIECLAW_MPV_ACTIVE = true;
  h.P.mpvInstanceId = 42;
  h.P.mpvState = { time: 321, duration: 3600, paused: false };
  h.P.startProgressReporting();
  await flush();
  await h.P.close();
  await h.P.close();
  const stops = h.calls.filter(c => c[0] === 'progress' && c[2] === 'stop');
  assert.equal(stops.length, 1);
  assert.equal(stops[0][3], 321000);
  assert.equal(stops[0][4], 3600000);
  assert.equal(h.calls.find(c => c[0] === 'invoke' && c[1] === 'stop_embedded_player')[2].instanceId, 42);
});

test('TV quality switch preserves unit, library, file, track choices and attempt and replaces the session', async () => {
  const h = harness({ request: () => Promise.resolve(session({ session_id: 'session-b', timeline: 'session', start_ms: 300000 })) });
  const source = item({ seasonNumber: 2, episodeNumber: 4, attemptId: 'logical-play', file_id: 81,
    audio_track: 'embedded:2', subtitle_track: 'off', episodes: [{ owned: true, episode_number: 5 }] });
  h.P.open('Title', 'https://server.invalid/a.mp4', [], 0, session(), source);
  h.video.currentTime = 300;
  h.video.emit('playing');
  await h.P.selectQuality(720);
  const body = h.calls.find(c => c[0] === 'request')[2].body;
  assert.equal(body.season_number, 2);
  assert.equal(body.episode_number, 4);
  assert.equal(body.file_id, 81);
  assert.equal(body.audio_track, 'embedded:2');
  assert.equal(body.subtitle_track, 'off');
  assert.equal(body.max_height, 720);
  assert.equal(body.start_ms, 300000);
  assert.equal(body.attempt_id, 'logical-play');
  assert.equal(h.P.context.library_id, 9);
  assert.equal(h.P.sessionId, 'session-b');
  assert.equal(h.video.currentTime, 0);
  assert.equal(h.P.engPos(), 300);
  assert.ok(h.calls.some(c => c[0] === 'stop' && c[1] === 'session-a'));
});

test('explicit zero remains zero in negotiation and does not reuse an old video position', async () => {
  const h = harness();
  h.video.currentTime = 123;
  await h.A.startPlayback(item({ startMs: 0 }));
  assert.equal(h.calls.find(c => c[0] === 'request')[2].body.start_ms, 0);
  assert.equal(h.video.currentTime, 0);
});

test('authentication and context transitions block old playback buttons before mutating playback state', async () => {
  for (const flag of ['_authPending', '_changingContext']) {
    const h = harness();
    h.A[flag] = true;
    h.elements.get('playerView').hidden = true;
    await h.A.startPlayback(item());
    assert.equal(h.calls.length, 0);
    assert.equal(h.A._retryItem, undefined);
    assert.equal(h.P.activeEngine, null);
    assert.equal(h.elements.get('playerView').hidden, true);
  }
});

test('an old Hero play action during resetContext cannot start another session while close is pending', async () => {
  const pending = deferred();
  const h = harness({ reportProgress: () => pending.promise });
  h.elements.set('searchInput', { value: 'old-search' });
  h.API.invalidateContext = () => h.API.contextEpoch++;
  h.P.open('Title', 'a.mp4', [], 0, session(), item());
  h.video.emit('playing');
  await flush();
  const reset = h.A.resetContext();
  assert.equal(h.A._changingContext, true);
  assert.equal(h.A._authPending, true);
  await h.A.startPlayback(item({ media_item_id: 88 }));
  [...h.timers.values()].find(t => t.ms === 1200).fn();
  await reset;
  assert.equal(h.calls.filter(c => c[0] === 'request').length, 0);
  assert.equal(h.P.activeEngine, null);
  assert.equal(h.elements.get('playerView').hidden, true);
  assert.equal(h.API.contextEpoch, 1);
  pending.resolve();
  await flush();
});

test('a session arriving after close is deleted and cannot reopen the player', async () => {
  const pending = deferred();
  const h = harness({ request: () => pending.promise });
  const start = h.A.startPlayback(item());
  await flush();
  await h.P.close();
  pending.resolve(session({ session_id: 'late-session' }));
  await start;
  assert.equal(h.P.activeEngine, null);
  assert.equal(h.elements.get('playerView').hidden, true);
  assert.ok(h.calls.some(c => c[0] === 'stop' && c[1] === 'late-session'));
});

test('a session arriving after the UI timeout is also deleted', async () => {
  const pending = deferred();
  const h = harness({ request: () => pending.promise });
  h.A._showPlaybackError = () => h.P.close();
  const start = h.A.startPlayback(item());
  await flush();
  const timeout = [...h.timers.values()].find(t => t.ms === 45000);
  timeout.fn();
  await start;
  pending.resolve(session({ session_id: 'timeout-session' }));
  await flush();
  assert.ok(h.calls.some(c => c[0] === 'stop' && c[1] === 'timeout-session'));
  assert.equal(h.P.activeEngine, null);
});

test('EOF completes once; early EOF restarts at the current file position', async () => {
  const h = harness();
  h.P.open('Title', 'a.mp4', [], 0, session(), item());
  h.video.currentTime = 300;
  h.video.emit('playing');
  const restarted = [];
  h.A.restartPlaybackAt = ms => restarted.push(ms);
  h.P.reportPlaybackEnd();
  [...h.timers.values()].find(t => t.ms === 500).fn();
  assert.deepEqual(restarted, [300000]);
  assert.equal(h.P._ended, false);
  h.video.currentTime = 3598;
  h.P.reportPlaybackEnd();
  h.P.reportPlaybackEnd();
  await flush();
  assert.equal(h.P._ended, true);
  assert.equal(h.calls.filter(c => c[0] === 'progress' && c[2] === 'stop').length, 1);
});

test('seeking outside a session-relative buffer renegotiates with file time', () => {
  const h = harness();
  h.P.open('Title', 'a.mp4', [], 0, session({ timeline: 'session', start_ms: 1800000 }), item());
  h.video.currentTime = 60;
  h.video.buffered = { length: 1, start: () => 0, end: () => 120 };
  const restarted = [];
  h.A.restartPlaybackAt = ms => restarted.push(ms);
  h.P.engSeekTo(600);
  assert.deepEqual(restarted, [600000]);
  h.P.engSeekTo(1890);
  assert.equal(h.video.currentTime, 90);
});

test('auto next is cancelled on close; if executed it carries the original library and episode context', async () => {
  const h = harness();
  h.P.adoptSession('Title', session(), item({ seasonNumber: 2, episodeNumber: 4 }), 'html5');
  h.A.showAutoNextCard({ context: h.P.context, media_item_id: 77, title: 'E5', season_number: 2, episode_number: 5 });
  const callback = [...h.intervals.values()].find(t => t.ms === 1000).fn;
  const plays = [];
  h.A.startPlayback = value => plays.push(value);
  await h.P.close();
  for (let i = 0; i < 8; i++) callback();
  assert.equal(plays.length, 0);
  h.P.adoptSession('Title', session(), item({ seasonNumber: 2, episodeNumber: 4 }), 'html5');
  h.A.showAutoNextCard({ context: h.P.context, media_item_id: 77, title: 'E5', season_number: 2, episode_number: 5 });
  const next = [...h.intervals.values()].find(t => t.ms === 1000).fn;
  for (let i = 0; i < 8; i++) next();
  assert.equal(plays.length, 1);
  assert.equal(plays[0].library_id, 9);
  assert.equal(plays[0].episodeNumber, 5);
  assert.equal(plays[0].file_id, undefined);
  assert.equal(plays[0].attemptId, undefined);
});

test('changing an episode releases the old file pin while quality changes retain it', () => {
  const h = harness();
  h.P.adoptSession('Title S2E4', session(), item({ seasonNumber: 2, episodeNumber: 4, file_id: 81, attemptId: 'old-attempt' }), 'html5');
  const plays = [];
  h.A.startPlayback = value => plays.push(value);
  h.P.playEpisode({ owned: true, episode_number: 5 });
  assert.equal(plays[0].library_id, 9);
  assert.equal(plays[0].seasonNumber, 2);
  assert.equal(plays[0].episodeNumber, 5);
  assert.equal(plays[0].file_id, undefined);
  assert.equal(plays[0].attemptId, undefined);
  assert.equal(plays[0].startMs, null);
});

test('file duration prioritizes source metadata and never invents a total from a session tail', () => {
  const h = harness();
  h.P.adoptSession('Title', session({ source: { duration_ms: 7200000 } }), item(), 'html5');
  assert.equal(h.P.engDuration(), 7200);
  h.P.adoptSession('Title', session({ timeline: 'session', start_ms: 1800000, watch: { duration_ms: null } }), item(), 'html5');
  h.video.duration = 30;
  assert.equal(h.P.engDuration(), 0);
  h.P.adoptSession('Title', session({ timeline: 'session', watch: { duration_ms: null } }), item({ files: [{ id: 81, duration_seconds: 5000 }] }), 'html5');
  assert.equal(h.P.engDuration(), 5000);
  h.P.adoptSession('Title', session({ session_id: null, timeline: 'session', start_ms: 1800000, watch: null }), item(), 'html5');
  h.video.duration = 3600;
  assert.equal(h.P.engDuration(), 3600);
  assert.equal(h.P.originMs, 0);
});

test('mpv reports only after rendered video and detects EOF through the actual native poll', async () => {
  let position = 60, rendered = false, eof = false;
  const h = harness({ invoke(name, args) {
    if (name === 'get_embedded_player_state') return { status: { running: true }, properties: {
      'time-pos': position, duration: 1800, pause: false, 'demuxer-cache-duration': 30,
      'eof-reached': eof, 'video-out-params': rendered ? { width: 1920, height: 1080 } : null,
    } };
    if (name === 'get_embedded_player_status') return { running: true };
    return {};
  } });
  h.P.adoptSession('Title', session({ timeline: 'session', start_ms: 1800000 }), item(), 'mpv');
  h.win.__MOVIECLAW_MPV_ACTIVE = true;
  h.P.mpvInstanceId = 12;
  let completions = 0;
  h.A.onPlaybackEnded = () => completions++;
  h.P.startMpvPoll();
  await flush();
  assert.equal(h.calls.filter(c => c[0] === 'progress').length, 0);
  rendered = true;
  const poll = [...h.intervals.values()].find(t => t.ms === 500);
  await poll.fn();
  await flush();
  assert.equal(h.calls.find(c => c[0] === 'progress')[3], 1860000);
  assert.equal(h.P.engDuration(), 3600);
  assert.equal(h.elements.get('playerLoading').hidden, true);
  position = 1799; eof = true;
  await poll.fn();
  await poll.fn();
  await flush();
  assert.equal(completions, 1);
  assert.equal(h.calls.filter(c => c[0] === 'progress' && c[2] === 'stop').length, 1);
  assert.equal(h.calls.filter(c => c[0] === 'progress').at(-1)[3], 3600000);
});

test('a native launch finishing after close is stopped by instance and does not revive the player', async () => {
  const pending = deferred();
  const h = harness({ invoke(name) {
    if (name === 'launch_embedded_player') return pending.promise;
    return name === 'get_main_window_hwnd' ? 1 : {};
  } });
  h.A._playbackSeq = 12;
  const launch = h.A.openEmbeddedPlayer(item(), 'a.mp4', [], 0, session(), 12);
  await flush();
  await h.P.close();
  pending.resolve({});
  await launch;
  assert.equal(h.P.activeEngine, null);
  assert.equal(h.elements.get('playerView').hidden, true);
  assert.equal(h.video.style.display, '');
  assert.ok(h.calls.some(c => c[1] === 'stop_embedded_player' && c[2].instanceId === 12));
  assert.ok(h.calls.some(c => c[0] === 'stop' && c[1] === 'session-a'));
});

test('closing during a failed native launch cleanup prevents its HTML5 fallback from reopening', async () => {
  const deletion = deferred();
  const h = harness({ invoke(name) {
    if (name === 'launch_embedded_player') return Promise.reject(new Error('mpv launch failed'));
    return name === 'get_main_window_hwnd' ? 1 : {};
  } });
  h.API.sessionStop = id => { h.calls.push(['stop', id]); return deletion.promise; };
  h.A._playbackSeq = 12;
  const launch = h.A.openEmbeddedPlayer(item({ __universalClaim: true }), 'a.mkv', [], 0, session(), 12);
  await flush();
  assert.ok(h.calls.some(c => c[0] === 'stop' && c[1] === 'session-a'));
  await h.P.close();
  deletion.resolve();
  await launch;
  assert.equal(h.P.activeEngine, null);
  assert.equal(h.elements.get('playerView').hidden, true);
  assert.equal(h.calls.filter(c => c[0] === 'request').length, 0);
});

test('closing while consent is being saved prevents playback from reopening after the PUT succeeds', async () => {
  const saving = deferred();
  const h = harness();
  h.API.playbackPolicySet = () => saving.promise;
  h.A._retryItem = item();
  const granted = h.A.grantConsent();
  await h.P.close();
  saving.resolve({ software_transcode_enabled: true });
  await granted;
  await flush();
  assert.equal(h.P.activeEngine, null);
  assert.equal(h.elements.get('playerView').hidden, true);
  assert.equal(h.calls.filter(c => c[0] === 'request').length, 0);
});

test('progress queue coalesces periodic updates, preserves start/stop order, and is bounded', async () => {
  const pending = deferred();
  let count = 0;
  const h = harness({ reportProgress() { return ++count === 1 ? pending.promise : Promise.resolve(); } });
  h.P.adoptSession('Title', session(), item(), 'html5');
  const first = h.P.sendSnapshot('start', h.P.snapshot());
  h.video.currentTime = 100;
  const progress = h.P.sendSnapshot('progress', h.P.snapshot());
  h.video.currentTime = 200;
  assert.equal(h.P.sendSnapshot('progress', h.P.snapshot()), progress);
  const last = h.P.sendSnapshot('stop', h.P.snapshot());
  pending.resolve();
  await Promise.all([first, progress, last]);
  assert.deepEqual(h.calls.filter(c => c[0] === 'progress').map(c => [c[2], c[3]]), [
    ['start', 0], ['progress', 200000], ['stop', 200000],
  ]);
  const blocked = deferred();
  h.API.reportProgress = () => blocked.promise;
  const tasks = Array.from({ length: 20 }, () => h.P.sendSnapshot('stop', h.P.snapshot()).catch(() => {}));
  assert.equal(h.P._reportQueue.length, 7);
  blocked.resolve();
  await Promise.all(tasks);
});

test('reports retry network and 5xx twice, never retry 4xx, and drop queued data after account change', async () => {
  let attempt = 0;
  const h = harness({ reportProgress() {
    attempt++;
    return attempt < 3 ? Promise.reject(Object.assign(new Error('temporary'), { status: 503 })) : Promise.resolve();
  } });
  h.P.adoptSession('Title', session(), item(), 'html5');
  const retried = h.P.sendSnapshot('start', h.P.snapshot());
  await flush();
  [...h.timers.values()].find(t => t.ms === 200).fn();
  await flush();
  [...h.timers.values()].find(t => t.ms === 400).fn();
  await retried;
  assert.equal(attempt, 3);
  assert.equal(h.calls.find(c => c[0] === 'progress')[8].timeoutMs, 3000);
  h.API.reportProgress = () => { attempt++; return Promise.reject(Object.assign(new Error('unauthorized'), { status: 401 })); };
  await assert.rejects(h.P.sendSnapshot('stop', h.P.snapshot()), /unauthorized/);
  assert.equal(attempt, 4);
  const blocked = deferred();
  h.API.reportProgress = () => blocked.promise;
  const active = h.P.sendSnapshot('start', h.P.snapshot());
  const stale = assert.rejects(h.P.sendSnapshot('progress', h.P.snapshot()), /上下文已更换/);
  h.A.session = { username: 'someone-else' };
  h.API.contextEpoch++;
  blocked.resolve();
  await Promise.all([active, stale]);
});

test('shutdown bounds unfinished progress work and always completes the native handshake', async () => {
  const pending = deferred();
  const h = harness({ reportProgress: () => pending.promise });
  h.P.open('Title', 'a.mp4', [], 0, session(), item());
  h.video.emit('playing');
  await flush();
  const shutdown = h.win.__MOVIECLAW_SHUTDOWN__();
  await flush();
  assert.equal(h.P.activeEngine, null);
  [...h.timers.values()].find(t => t.ms === 1200).fn();
  await shutdown;
  assert.ok(h.calls.some(c => c[1] === 'complete_shutdown'));
  pending.resolve();
  await flush();
});

test('HLS gateway loader sends Range, preserves 206 headers and cancels its real fetch/capability', async () => {
  const pending = deferred(), requests = [];
  const h = harness({ fetch(url, args) { requests.push({ url, args }); return pending.promise; } });
  const loader = new h.win.ProxyHlsLoader({});
  let success;
  loader.load({ url: 'https://server.invalid/part.mp4', responseType: 'arraybuffer', rangeStart: 4, rangeEnd: 8 }, { highWaterMark: 131072 }, {
    onProgress() { throw new Error('非progressive不能把媒体数据只交给未启用的progress callback'); },
    onSuccess(response, stats, context, details) { success = { response, stats, details }; }, onError(error) { throw error; },
  });
  await flush();
  assert.equal(requests[0].args.headers.Range, 'bytes=4-7');
  pending.resolve(new Response(Buffer.from('abcd'), { status: 206, headers: { 'content-range': 'bytes 4-7/20' } }));
  await flush();
  assert.equal(success.response.code, 206);
  assert.equal(success.stats.loaded, 4);
  assert.equal(Buffer.from(success.response.data).toString(), 'abcd');
  assert.equal(success.details.headers['content-range'], 'bytes 4-7/20');
  const other = deferred();
  h.context.fetch = (url, args) => { requests.push({ url, args }); return other.promise; };
  let delivered = false;
  loader.load({ url: 'https://server.invalid/other.mp4', responseType: 'arraybuffer' }, {}, { onSuccess() { delivered = true; }, onError() {} });
  await flush();
  loader.destroy();
  assert.equal(requests.at(-1).args.signal.aborted, true);
  other.resolve(new Response('late'));
  await flush();
  assert.equal(delivered, false);
  assert.ok(h.calls.some(c => c[1] === 'release_media_stream' && c[2].streamId));
});

test('mpv track mapping uses per-type ffmpeg ordinal, real id, and gateway source order', () => {
  const h = harness();
  const map = h.context.mpvTrackMap([
    { type: 'audio', id: 42, 'ff-index': 8 }, { type: 'audio', id: 7, 'ff-index': 1 },
    { type: 'sub', id: 19, 'ff-index': 5 }, { type: 'sub', id: 91, external: true, 'external-filename': 'http://127.0.0.1/cap/sub' },
  ], [{ track_ref: 'embedded:0' }, { track_ref: 'external:English.ass' }], ['/playback/subs/0', '/playback/subs/1'], true,
  ['http://127.0.0.1/cap/sub']);
  assert.deepEqual(Array.from(map.audio, t => [t.ref, t.id]), [['embedded:0', 7], ['embedded:1', 42]]);
  assert.deepEqual(Array.from(map.subtitles, t => [t.ref, t.id]), [['embedded:0', 19], ['external:English.ass', 91]]);
});

test('native playback starts one idle timer, preserves it across polls, and ignores inactive video events', async () => {
  const props = { pause: false };
  const h = harness({ invoke: name => Promise.resolve(name === 'get_embedded_player_state'
    ? { status: { running: true }, properties: props } : {}) });
  nativeTracks(h);
  h.P.startMpvPoll();
  await flush();
  const idle = h.P.hideTimer;
  assert.ok(idle);
  h.video.emit('pause');
  assert.equal(h.P.hideTimer, idle);
  await [...h.intervals.values()].find(t => t.ms === 500).fn();
  assert.equal(h.P.hideTimer, idle);
  h.timers.get(idle).fn();
  assert.equal(h.P.controlsVisible, false);
  h.P.handleNativeInput(['move']);
  assert.equal(h.P.controlsVisible, true);
  assert.notEqual(h.P.hideTimer, idle);
  props.pause = true;
  await [...h.intervals.values()].find(t => t.ms === 500).fn();
  assert.equal(h.P.hideTimer, null);
  assert.equal(h.P.controlsVisible, true);
  props.pause = false;
  await [...h.intervals.values()].find(t => t.ms === 500).fn();
  assert.ok(h.P.hideTimer);
  h.P.stopMpvPoll();
});

function nativeTracks(h) {
  h.P.adoptSession('Native', session({ timeline: 'session', start_ms: 100000,
    decision: { tier: 0, file_id: 81, audio: { track_ref: 'embedded:0' },
      audio_tracks: [{ ref: 'embedded:0', codec: 'aac', language: 'eng' }, { ref: 'embedded:1', codec: 'aac', language: 'chi' }],
      subtitles: [{ track_ref: 'external:en.ass', kind: 'ass', language: 'eng' }] }, subtitle_urls: ['/playback/en.ass'] }), item(), 'mpv');
  h.win.__MOVIECLAW_MPV_ACTIVE = true;
  h.P.mpvInstanceId = 51;
  h.P.mpvState = { time: 22, duration: 1000, paused: false, properties: {}, volume: 1 };
  h.P.mpvTracks = { audio: [{ id: 7, ref: 'embedded:0' }, { id: 42, ref: 'embedded:1' }],
    subtitles: [{ id: 91, ref: 'external:en.ass', external: true }] };
}

test('native visible controls change actual aid/sid/speed/volume and file-time external subtitle delay', async () => {
  const h = harness(); nativeTracks(h);
  h.P.startProgressReporting(); await flush();
  await h.P.selectAudio('embedded:1');
  await h.P.selectSubtitle(0);
  await h.P.adjustSubtitleOffset(0.5);
  await h.P.adjustSubtitleScale(0.1);
  await h.P.setSpeed(1.5);
  h.P.engSetVolume(0.7);
  const commands = h.calls.filter(c => c[1] === 'send_mpv_command_embedded').map(c => Array.from(c[2].command));
  assert.ok(commands.some(c => c[1] === 'aid' && c[2] === 42));
  assert.ok(commands.some(c => c[1] === 'sid' && c[2] === 91));
  assert.ok(commands.some(c => c[1] === 'sub-delay' && c[2] === -99.5));
  assert.ok(commands.some(c => c[1] === 'sub-scale' && c[2] === 1.1));
  assert.ok(commands.some(c => c[1] === 'speed' && c[2] === 1.5));
  assert.ok(commands.some(c => c[1] === 'volume' && c[2] === 70));
  assert.equal(h.video.playbackRate, undefined);
  assert.equal(h.P.engRate(), 1.5);
  assert.equal(h.P.snapshot().extras.audio_track, 'embedded:1');
  assert.equal(h.P.snapshot().extras.subtitle_track, 'external:en.ass');
  await h.P.selectSubtitle(-1);
  assert.equal(h.P.selectedSubtitle, null);
  assert.equal(h.P.snapshot().extras.subtitle_track, 'off');
});

test('native cached subscriptions serve watchdogs without extra command connections', async () => {
  const h = harness(); nativeTracks(h);
  h.P.mpvState.properties = { 'time-pos': 22, pause: false, 'demuxer-cache-duration': 10,
    'cache-speed': 500, 'frame-drop-count': 3, 'decoder-frame-drop-count': 4, 'container-fps': 24 };
  const result = await h.P._sampleEngine();
  assert.equal(result.time, 122); assert.equal(result.loadingBps, 4000); assert.equal(result.dropped, 7);
  assert.equal(h.calls.filter(c => c[1] === 'send_mpv_command_embedded').length, 0);
});

test('native JSON false track properties stay off and never map to a source ordinal', async () => {
  const h = harness({ invoke: name => name === 'get_embedded_player_state'
    ? Promise.resolve({ status: { running: true }, properties: {
      aid: false, sid: false, pause: true, 'time-pos': 22, duration: 1000,
      'track-list': [{ type: 'audio', id: 7, 'ff-index': 0 },
        { type: 'audio', id: 42, 'ff-index': 1 },
        { type: 'sub', id: 91, external: true, 'external-filename': '/playback/en.ass' }],
    } }) : Promise.resolve({}) });
  nativeTracks(h);
  h.P._nativeTrackInit = true;
  h.P._everPlayed = true;
  h.P.selectedSubtitle = 0;
  h.P.startMpvPoll();
  await flush();
  assert.equal(h.P.mpvState.aid, false);
  assert.equal(h.P.mpvState.sid, false);
  assert.equal(h.P.mpvTracks.audio.find(t => t.id === h.P.mpvState.aid), undefined);
  assert.equal(h.P.selectedSubtitle, null);
  h.elements.set('playerSettingsContent', h.elements.get('playerTitle'));
  h.P.renderSettingsTab('subtitles');
  assert.match(h.elements.get('playerSettingsContent').innerHTML,
    /player-settings-item active" data-sub-index="-1"/);
  h.P.stopMpvPoll();
});

test('remembered watch tracks take precedence, global languages choose only when no remembered track exists', async () => {
  const h = harness({ storage: { mc_subLang: 'zh', mc_audioLang: 'zh' } }); nativeTracks(h);
  h.P.sessionData.watch.subtitle_track = 'off';
  assert.equal(h.P.initialSubtitle(), -1);
  delete h.P.sessionData.watch.subtitle_track;
  h.P.sessionData.decision.subtitles.push({ track_ref: 'embedded:0', kind: 'pgs', language: 'chi' });
  h.P.mpvTracks.subtitles.push({ id: 19, ref: 'embedded:0' });
  assert.equal(h.P.initialSubtitle(), 1);
  h.P.context.subtitle_track = 'external:en.ass';
  assert.equal(h.P.initialSubtitle(), 0);
  h.P.context.audio_track = 'embedded:0';
  h.P.currentAudioRef = 'embedded:1';
  await h.P.initializeTracks();
  assert.equal(h.P.currentAudioRef, 'embedded:0');
  assert.equal(h.P.snapshot().extras.audio_track, undefined);
  assert.equal(h.P.snapshot().extras.subtitle_track, undefined);
});

test('HTML5 audio and PGS controls renegotiate the common context at file position', async () => {
  const h = harness();
  h.P.open('Title', 'https://server.invalid/a.mp4', [], 0, session({ timeline: 'session', start_ms: 100000,
    decision: { tier: 3, file_id: 81, audio: { track_ref: 'embedded:0' }, video: {},
      audio_tracks: [{ ref: 'embedded:0', codec: 'aac' }, { ref: 'embedded:1', codec: 'aac' }],
      subtitles: [{ track_ref: 'embedded:0', kind: 'pgs' }] }, subtitle_urls: ['/pgs'] }), item());
  await flush(); h.video.currentTime = 20;
  const restarted = [];
  h.A.restartPlaybackAt = (position, overrides) => restarted.push({ position, overrides, ref: h.P.context.subtitle_track });
  await h.P.selectAudio('embedded:1');
  assert.equal(restarted[0].position, 120000); assert.equal(restarted[0].overrides.audio_track, 'embedded:1');
  await h.P.selectSubtitle(0);
  assert.equal(restarted[1].position, 120000); assert.equal(restarted[1].ref, 'embedded:0');
  h.P.sessionData.decision.video.burn_subtitle = 'embedded:0';
  await h.P.adjustSubtitleOffset(1); assert.equal(h.P.subtitleOffset, 0);
  await h.P.selectSubtitle(-1); assert.equal(restarted[2].ref, 'off');
});

test('VTT cues shift from file clock once, and subtitle size/offset survive engine replacement', async () => {
  const h = harness();
  h.P.adoptSession('Title', session({ timeline: 'session', start_ms: 100000 }), item(), 'html5');
  const cue = { startTime: 150, endTime: 155, line: 'auto' };
  h.video.textTracks = [{ cues: [cue], mode: 'disabled' }];
  h.P.applyCueStyle(h.video.textTracks[0]); assert.equal(cue.startTime, 50);
  await h.P.adjustSubtitleOffset(0.5); assert.equal(cue.startTime, 50.5);
  h.P.applyCueStyle(h.video.textTracks[0]); assert.equal(cue.startTime, 50.5);
  await h.P.adjustSubtitleScale(0.1);
  const context = { ...h.P.context };
  h.P.adoptSession('Again', session(), context, 'html5');
  assert.equal(h.P.subtitleOffset, 0.5); assert.equal(h.P.subtitleFontScale, 1.1);
});

test('ASS renderer loads only the selected content and uses file-clock offset without hidden VTT duplicates', async () => {
  const h = harness(); const renderers = [];
  h.context.JASSUB = class {
    constructor(config) { this.config = config; renderers.push(this); }
    setTrack(content) { this.content = content; } freeTrack() {} destroy() {}
  };
  h.P.open('Title', 'https://server.invalid/a.mp4', ['/vtt', '/ass'], 0, session({ timeline: 'session', start_ms: 100000,
    decision: { tier: 3, file_id: 81, subtitles: [{ track_ref: 'embedded:0', kind: 'vtt', is_default: true },
      { track_ref: 'embedded:1', kind: 'ass' }] }, subtitle_urls: ['/vtt', '/ass'] }), item());
  await flush(); assert.equal(renderers.length, 0); assert.equal(h.video.children.length, 1);
  await h.P.selectSubtitle(1); assert.equal(renderers.length, 1);
  assert.ok(renderers[0].config.subContent.startsWith('[Script Info]'));
  assert.equal(renderers[0].timeOffset, 100);
  await h.P.adjustSubtitleOffset(0.5); assert.equal(renderers[0].timeOffset, 99.5);
  await h.P.selectSubtitle(-1); assert.equal(h.P.selectedSubtitle, null);
});

test('late ASS selection is discarded when another subtitle or off is selected', async () => {
  const h = harness(), pending = deferred(); let constructed = 0;
  h.context.JASSUB = class { constructor() { constructed++; } };
  h.P.adoptSession('Title', session({ decision: { tier: 3, file_id: 81, subtitles: [{ track_ref: 'embedded:0', kind: 'ass' }] },
    subtitle_urls: ['/ass'] }), item(), 'html5');
  h.API.rawFetch = () => pending.promise;
  const old = h.P.selectSubtitle(0); await h.P.selectSubtitle(-1);
  pending.resolve({ ok: true, text: async () => '[Script Info]' });
  await old; assert.equal(constructed, 0); assert.equal(h.P.selectedSubtitle, null);
});

test('quality memory is bounded and isolated by server, account and measured network class', () => {
  const h = harness(); h.A.session = { username: 'alice' };
  h.context.rememberQuality(77, 720); assert.equal(h.context.rememberedQuality(77), 720);
  h.A.session.username = 'bob'; assert.equal(h.context.rememberedQuality(77), 0);
  h.A.session.username = 'alice'; h.API.baseUrl = 'https://other.invalid'; assert.equal(h.context.rememberedQuality(77), 0);
  h.API.baseUrl = 'https://server.invalid'; h.context.navigator.connection = { effectiveType: '3g' }; assert.equal(h.context.rememberedQuality(77), 0);
  h.context.navigator.connection = undefined; h.context.rememberQuality(77, 0); assert.equal(h.context.rememberedQuality(77), 0);
  for (let id = 1; id <= 305; id++) h.context.rememberQuality(id, 1080);
  assert.equal(Object.keys(JSON.parse(h.storage.get('mc_quality_memory'))).length, 300);
});

test('trickplay sheet/row/column calculation clamps the file timeline across sheet boundaries', () => {
  const h = harness(); const index = { ready: true, interval_ms: 10000, columns: 3, rows: 2, count: 11,
    tile_width: 160, tile_height: 90, sheets: ['sheet-a', 'sheet-b'] };
  const tile = h.context.trickplayTile(index, 80000);
  assert.equal(tile.sheet, 'sheet-b'); assert.equal(tile.x, 320); assert.equal(tile.y, 0);
  const last = h.context.trickplayTile(index, 999999); assert.equal(last.x, 160); assert.equal(last.y, 90);
  assert.equal(h.context.trickplayTile({ ready: false }, 0), null);
});

test('skip supports ad/preview kinds and does not offer a meaningless skip in the last three seconds or outro-to-end', () => {
  const h = harness(); h.elements.set('playerSkipBtn', { hidden: true, textContent: '' });
  h.P.adoptSession('Title', session({ segments: [{ type: 'ad', start_ms: 10000, end_ms: 20000 },
    { type: 'outro', start_ms: 30000, end_ms: 3600000, to_end: true }] }), item(), 'html5');
  let next = 0; h.A.onPlaybackEnded = () => next++;
  h.video.currentTime = 12; h.P.checkSegments(); assert.equal(h.elements.get('playerSkipBtn').textContent, '跳过广告');
  h.P.skipSegment(); assert.equal(h.video.currentTime, 20);
  h.video.currentTime = 18; h.P.checkSegments(); assert.equal(h.elements.get('playerSkipBtn').hidden, true);
  h.video.currentTime = 35; h.P.checkSegments(); h.P.checkSegments();
  assert.equal(next, 1); assert.equal(h.elements.get('playerSkipBtn').hidden, true);
});

test('chapters from native session clock seek on the common file timeline', () => {
  const h = harness(); nativeTracks(h);
  h.P.mpvState.properties['chapter-list'] = [{ time: 0, title: 'A' }, { time: 50, title: 'B' }];
  const sought = []; h.P.engSeekTo = value => sought.push(value);
  h.P.seekChapter(1); h.P.seekChapter(-1);
  assert.deepEqual(sought, [150, 100]);
});

test('retry budget permits one native retry then server fallback and caps repeated network restarts', () => {
  const h = harness(); nativeTracks(h); const retries = [];
  h.A.restartPlaybackAt = (ms, overrides) => retries.push(overrides || {});
  h.A.onPlaybackContentFailed('decode failed');
  assert.equal(retries.length, 1); assert.equal(retries[0].__forceHtml5, undefined);
  delete h.P.sessionData.__contentFailed; h.A.onPlaybackContentFailed('decode failed twice');
  assert.equal(retries[1].__forceHtml5, true);
  h.A._totalNetRestarts = 6; h.P.sessionData.__contentFailed = false;
  let final; h.A._showPlaybackError = reason => final = reason;
  h.A.onPlaybackNetworkDead('lost'); assert.match(final, /预算已用尽/);
});

test('native mouse input uses the same controls and does not toggle pause on a single click', () => {
  const h = harness(); nativeTracks(h); let full = 0;
  h.P.toggleFullscreen = () => full++;
  h.P.handleNativeInput(['click']); assert.equal(h.P.mpvState.paused, false);
  h.P.handleNativeInput(['double-click']); assert.equal(full, 1);
  h.P.mpvState.bufferedAhead = 100;
  h.P.handleNativeInput(['seek', '10']); assert.equal(h.P.engPos(), 132);
});

test('QoE final metrics use a bounded redacted payload and never cross account identity', async () => {
  const h = harness();
  h.P.open('Title secret', 'https://server.invalid/a.mp4?token=secret', [], 0, session(), item({ attemptId: 'attempt-1' }));
  h.video.currentTime = 20; h.video.emit('playing'); h.P.engSeekTo(21);
  h.P.measure('buffer_start'); h.P.measure('buffer_end');
  await h.P.close();
  const metrics = h.calls.find(c => c[0] === 'metrics')[1];
  assert.equal(metrics.client, 'windows'); assert.equal(metrics.attempt_id, 'attempt-1'); assert.equal(metrics.seek_count, 1);
  assert.ok(metrics.first_frame_ms != null); assert.equal(metrics.outcome, 'exited');
  assert.equal(JSON.stringify(metrics).includes('secret'), false);
  assert.ok(metrics.detail.timeline.length <= 64);
  const other = harness(); other.P.adoptSession('Title', session(), item({ attemptId: 'attempt-2' }), 'html5');
  other.A.session = { username: 'new-account' }; await other.P.close();
  assert.equal(other.calls.filter(c => c[0] === 'metrics').length, 0);
});

test('explicit progressive HLS delivers each chunk once and leaves success data empty', async () => {
  const h = harness({ fetch: async () => new Response('fragment') });
  const loader = new h.win.ProxyHlsLoader({ progressive: true });
  const chunks = []; let success;
  loader.load({ url: 'https://server.invalid/part.m4s', responseType: 'arraybuffer' }, { highWaterMark: 4 }, {
    onProgress(stats, context, data) { chunks.push(Buffer.from(data)); },
    onSuccess(response, stats) { success = { response, stats }; }, onError(error) { throw error; },
  });
  await flush();
  assert.equal(Buffer.concat(chunks).toString(), 'fragment'); assert.equal(success.response.data.byteLength, 0);
  assert.equal(success.stats.loaded, 8); assert.equal(success.stats.chunkCount, 0);
});

test('aborting a pending HLS capability notifies onAbort once and revokes its late grant', async () => {
  const pending = deferred(); let aborts = 0, fetched = 0;
  const h = harness({ invoke(name) { return name === 'grant_media_stream' ? pending.promise : {}; },
    fetch() { fetched++; return Promise.resolve(new Response('should not happen')); } });
  const loader = new h.win.ProxyHlsLoader({});
  loader.load({ url: 'https://server.invalid/part.m4s', responseType: 'arraybuffer' }, {}, {
    onAbort() { aborts++; }, onSuccess() { throw new Error('stale response'); }, onError() {},
  });
  loader.destroy(); loader.destroy();
  pending.resolve({ streamId: 'late-grant', url: 'http://127.0.0.1/cap/late' }); await flush();
  assert.equal(aborts, 1); assert.equal(fetched, 0);
  assert.ok(h.calls.some(c => c[1] === 'release_media_stream' && c[2].streamId === 'late-grant'));
});

test('browser progress starts on a real video-frame callback and discards callbacks after close', async () => {
  const h = harness(); let callback, cancelled;
  h.video.requestVideoFrameCallback = fn => { callback = fn; return 123; };
  h.video.cancelVideoFrameCallback = id => { cancelled = id; };
  h.P.open('Title', 'https://server.invalid/a.mp4', [], 0, session(), item());
  h.video.emit('playing'); await flush();
  assert.equal(h.calls.filter(c => c[0] === 'progress').length, 0);
  callback(); await flush(); assert.equal(h.calls.filter(c => c[0] === 'progress' && c[2] === 'start').length, 1);
  await h.P.close();
  h.P.open('Title 2', 'https://server.invalid/a.mp4', [], 0, session(), item());
  h.video.emit('playing'); await h.P.close(); callback(); await flush();
  assert.equal(cancelled, 123);
  assert.equal(h.calls.filter(c => c[0] === 'progress' && c[2] === 'start').length, 1);
});


test('browser codec decode probes never claim HDR output; HDR source prefers native mapping', async () => {
  const h = harness({ navigator: { mediaCapabilities: { decodingInfo: async () => ({ supported: true, smooth: true, powerEfficient: true }) } } });
  const browser = await h.context.readBrowserCapability();
  assert.ok(browser.video.length > 0);
  assert.equal(browser.hdr_passthrough, false);
  assert.equal(h.A.needsNativePlayer({ container: 'mp4', video_codec: 'hevc', hdr: 'HDR10' }, []), true);
  assert.equal(h.context.getUniversalCapabilitySnapshot().disc_image, false);
  assert.equal(h.context.getUniversalCapabilitySnapshot().disc_folder, false);
});

test('known ISO and DVD request server remux without disc-reader claims; legacy raw discs never reach an engine', async () => {
  for (const container of ['iso', 'dvd']) {
    const h = harness({ request: () => Promise.resolve(session({ stream_url: '/playback/files/81/stream?token=x',
      source: { container }, decision: { tier: 0, file_id: 81 } })) });
    h.A._mpvReady = true;
    const errors = [], opened = [];
    h.A._showPlaybackError = message => errors.push(message);
    h.P.open = (...args) => opened.push(args);
    await h.A.startPlayback(item({ file_id: 81, files: [{ id: 81, state: 'in_place', container }] }));
    const body = h.calls.find(c => c[0] === 'request')[2].body;
    assert.equal(body.capability.universal, true);
    assert.equal(body.capability.disc_image, false);
    assert.equal(body.capability.disc_folder, false);
    assert.equal(opened.length, 0);
    assert.equal(h.calls.filter(c => c[1] === 'launch_embedded_player').length, 0);
    assert.deepEqual(h.calls.filter(c => c[0] === 'stop'), [['stop', 'session-a']]);
    assert.equal(errors.length, 1);
  }
});

test('unexpected disc manifests renegotiate once and cannot fall through to mpv or HTML5', async () => {
  let count = 0;
  const h = harness({ request: () => Promise.resolve(session({ session_id: 'disc-' + ++count,
    stream_url: '/playback/files/81/disc?token=x', source: { container: 'bluray' },
    decision: { tier: 0, file_id: 81, disc: 'folder' } })) });
  h.A._mpvReady = true;
  const errors = [], opened = [];
  h.A._showPlaybackError = message => errors.push(message);
  h.P.open = (...args) => opened.push(args);
  await h.A.startPlayback(item({ files: [{ id: 81, state: 'in_place', container: 'bluray' }] }));
  const requests = h.calls.filter(c => c[0] === 'request');
  assert.equal(requests.length, 2);
  assert.equal(requests[0][2].body.capability.universal, true);
  assert.equal(requests[0][2].body.capability.disc_folder, false);
  assert.notEqual(requests[1][2].body.capability.universal, true);
  assert.deepEqual(h.calls.filter(c => c[0] === 'stop'), [['stop', 'disc-1'], ['stop', 'disc-2']]);
  assert.equal(opened.length, 0);
  assert.equal(h.calls.filter(c => c[1] === 'launch_embedded_player').length, 0);
  assert.equal(errors.length, 1);
});

test('BDMV server remux is accepted and direct native entry still refuses a JSON manifest', async () => {
  const h = harness({ request: () => Promise.resolve(session({ stream_url: '/playback/sessions/a/master.m3u8',
    source: { container: 'bluray' }, decision: { tier: 1, file_id: 81, container: 'hls-fmp4' } })) });
  h.A._mpvReady = true;
  const launches = [], opened = [], errors = [];
  h.A.openEmbeddedPlayer = async (...args) => launches.push(args);
  await h.A.startPlayback(item({ files: [{ id: 81, state: 'in_place', container: 'bluray' }] }));
  assert.equal(launches.length, 1);
  assert.match(launches[0][1], /master\.m3u8$/);
  const direct = harness(); direct.A._playbackSeq = 12;
  direct.P.open = (...args) => opened.push(args);
  direct.A._showPlaybackError = message => errors.push(message);
  await direct.A.openEmbeddedPlayer(item(), 'https://server.invalid/api/v1/playback/files/81/disc?token=x', [], 0,
    session({ decision: { tier: 0, file_id: 81 } }), 12);
  assert.equal(opened.length, 0);
  assert.equal(direct.calls.filter(c => c[1] === 'launch_embedded_player').length, 0);
  assert.deepEqual(direct.calls.filter(c => c[0] === 'stop'), [['stop', 'session-a']]);
  assert.equal(errors.length, 1);
});

test('native fullscreen uses the Tauri window without DOM activation and restores after a delayed close', async () => {
  const h = harness();
  let fullscreen = false;
  const entered = deferred(), release = deferred(), changes = [];
  h.win.__TAURI__.window = { getCurrentWindow: () => ({
    isFullscreen: async () => fullscreen,
    setFullscreen: async value => {
      changes.push(value);
      if (value) { entered.resolve(); await release.promise; }
      fullscreen = value;
    },
  }) };
  h.P.activeEngine = 'mpv'; h.win.__MOVIECLAW_MPV_ACTIVE = true;
  h.elements.get('playerView').requestFullscreen = () => { throw new Error('DOM fullscreen has no user activation'); };
  const toggle = h.P.toggleFullscreen();
  await entered.promise;
  const close = h.P.close();
  release.resolve();
  await Promise.all([toggle, close]);
  assert.deepEqual(changes, [true, false]);
  assert.equal(fullscreen, false);
  assert.equal(h.P.isFullscreen(), false);
  assert.equal(h.elements.get('playerView').hidden, true);
});

test('native fullscreen preserves prior window mode through engine replacement and final close', async () => {
  const h = harness();
  let fullscreen = true;
  const changes = [];
  h.win.__TAURI__.window = { getCurrentWindow: () => ({
    isFullscreen: async () => fullscreen,
    setFullscreen: async value => { changes.push(value); fullscreen = value; },
  }) };
  h.P.activeEngine = 'mpv'; h.win.__MOVIECLAW_MPV_ACTIVE = true;
  await h.P.toggleFullscreen();
  assert.equal(fullscreen, false);
  await h.P.close({ hide: false });
  assert.equal(fullscreen, false);
  h.P.activeEngine = 'mpv'; h.win.__MOVIECLAW_MPV_ACTIVE = true;
  await h.P.close();
  assert.equal(fullscreen, true);
  assert.deepEqual(changes, [false, true]);
});

test('fullscreen from PiP keeps an already restored fullscreen and cannot reenter after playback closes', async () => {
  const h = harness();
  h.P.activeEngine = 'mpv'; h.P.nativePip = true;
  const changes = [];
  h.win.__TAURI__.window = { getCurrentWindow: () => ({ isFullscreen: async () => true, setFullscreen: async value => changes.push(value) }) };
  h.P.togglePip = async () => { h.P.nativePip = false; h.P._nativeFullscreen = true; };
  await h.P.toggleFullscreen();
  assert.deepEqual(changes, []);
  h.P.nativePip = true; h.P._nativeFullscreen = false;
  h.P.togglePip = async () => { h.P.nativePip = false; h.P.generation++; h.P.activeEngine = null; };
  await h.P.toggleFullscreen();
  assert.deepEqual(changes, []);
});

test('Escape forwarded from mpv restores PiP instead of closing playback', () => {
  const h = harness();
  h.P.nativePip = true;
  let restored = 0, closed = 0;
  h.P.closeAnyPanel = () => false;
  h.P.togglePip = () => restored++;
  h.P.close = () => closed++;
  h.P.handleNativeInput(['escape']);
  assert.equal(restored, 1); assert.equal(closed, 0);
});

test('probed DVD bitmap subtitles are unavailable with an accurate reason instead of claiming no tracks', () => {
  const h = harness();
  h.P.sessionData = session({ source: { subtitle_codecs: ['dvd_subtitle'] }, decision: { subtitles: [] } });
  const tracks = h.P.buildSubtitleTracks();
  assert.equal(tracks.options.length, 0);
  assert.equal(tracks.unavailable.length, 1);
  assert.match(tracks.unavailable[0].reason, /此播放路径暂不支持 DVD 位图字幕/);
  h.P.sessionData.source.subtitle_codecs = [];
  assert.equal(h.P.buildSubtitleTracks().unavailable.length, 0);
});

test('HTML5 volume feedback follows external media changes and adjustment reveals controls', () => {
  const h=harness();
  const slider={value:'1',setAttribute(name,value){this[name]=value;}};
  const label={textContent:''};
  h.elements.set('volumeSlider',slider);h.elements.set('playerVolumeValue',label);
  h.P.activeEngine='html5';h.video.paused=false;
  h.video.volume=.4;h.video.emit('volumechange');
  assert.equal(Number(slider.value),.4);assert.equal(label.textContent,'40%');
  h.P.hideControls();h.P.engSetVolume(.5);
  assert.equal(label.textContent,'50%');assert.equal(h.P.controlsVisible,true);
  h.P.engSetMuted(true);assert.equal(label.textContent,'静音');assert.equal(Number(slider.value),0);
  h.P.engSetVolume(.6);assert.equal(h.video.muted,false);assert.equal(label.textContent,'60%');
  h.video.volume=.2;h.video.emit('volumechange');assert.equal(label.textContent,'20%');
});
