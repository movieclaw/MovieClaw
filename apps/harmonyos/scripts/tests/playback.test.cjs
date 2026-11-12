// Host regressions execute the production ArkTS with mocked platform boundaries.
// Use the TypeScript compiler shipped with DevEco; no project dependencies change.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { test, describe } = require('node:test');

const root = path.resolve(__dirname, '../..');
const compilerPath = process.env.HARMONY_TYPESCRIPT_PATH || path.join(
  process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const ts = require(compilerPath);
const pending = () => new Promise(() => {});
const gate = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};
async function drain() { for (let i = 0; i < 80; i++) { await Promise.resolve(); } }

function runtime(overrides = {}, timers = globalThis) {
  const cache = new Map();
  const kits = {
    '@kit.MediaKit': {}, '@kit.AudioKit': {}, '@kit.BasicServicesKit': { deviceInfo: { productModel: 'host-test' } },
    '@kit.NetworkKit': {}, '@kit.CoreFileKit': {}, '@kit.ArkData': {},
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({ decodeToString: (bytes) => new TextDecoder().decode(bytes) }) } } },
    '@kit.AbilityKit': {}, '@kit.AVSessionKit': {}, '@kit.BackgroundTasksKit': {},
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
    '@ohos/hypium': {
      describe,
      it: (name, level, run) => test(name, run),
      expect: (value) => ({
        assertEqual: (other) => assert.equal(value, other),
        assertTrue: () => assert.equal(value, true),
        assertFalse: () => assert.equal(value, false),
        assertContain: (other) => assert.ok(value.includes(other)),
      }),
    },
    ...overrides,
  };
  function load(file) {
    file = path.resolve(root, file);
    if (file.replace(/\\/g, '/').endsWith('/offline/OfflineDisk.ets')) { return { OfflineDisk: { fileSize: () => 100 } }; }
    if (cache.has(file)) { return cache.get(file).exports; }
    const module = { exports: {} };
    cache.set(file, module);
    const source = ts.transpileModule(readFileSync(file, 'utf8'), {
      fileName: file.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    }).outputText;
    function importModule(name) {
      if (Object.hasOwn(kits, name)) { return kits[name]; }
      if (name === '@movieclaw/player-engine') { return load('player_engine/Index.ets'); }
      if (name === '@movieclaw/playback') { return load('playback/Index.ets'); }
      if (name.startsWith('.')) { return load(path.resolve(path.dirname(file), `${name}.ets`)); }
      throw new Error(`Unmocked platform boundary: ${name}`);
    }
    new Function('require', 'module', 'exports', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', source)(
      importModule, module, module.exports,
      (...args) => timers.setTimeout(...args), (id) => timers.clearTimeout(id),
      (...args) => timers.setInterval(...args), (id) => timers.clearInterval(id));
    return module.exports;
  }
  return load;
}

// Run the same shared suites registered by the on-device Hypium runner.
const shared = runtime();
for (const suite of ['PlaybackController', 'PlaybackSession', 'PlaybackGateway', 'HomeRows', 'StaleLoadGuard', 'PgsPrepareGuard']) {
  shared(`entry/src/test/${suite}.test.ets`).default();
}

function clock() {
  let now = 0; let sequence = 0;
  const tasks = new Map();
  return {
    setTimeout(fn, ms) { const id = ++sequence; tasks.set(id, { fn, at: now + ms }); return id; },
    clearTimeout(id) { tasks.delete(id); },
    setInterval() { return ++sequence; }, clearInterval() {},
    async advance(ms) {
      const end = now + ms;
      for (;;) {
        const next = [...tasks].filter(([, task]) => task.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) { break; }
        now = next[1].at; tasks.delete(next[0]); next[1].fn(); await drain();
      }
      now = end; await drain();
    },
  };
}

function playerFixture({ engineId = 'avplayer', play = async () => {}, release = async () => {} } = {}) {
  const timers = clock(); const load = runtime({}, timers);
  const { PlaybackController, PlaybackIntent } = load('playback/Index.ets');
  const { EngineEvent } = load('player_engine/Index.ets');
  let closes = 0;
  const engine = {
    id: engineId, onEvent() {}, open: async () => {}, play, pause: async () => {},
    seek: async () => {}, setRate: async () => {}, setGain: async () => {},
    setSubtitleStyle: async () => {}, release,
  };
  const media = {
    originMs: 0, durationMs: 100000,
    acquire: async () => ({ source: { fd: -1, subtitleFd: -1, url: 'fixture', subtitleUrl: '', length: 0 },
      close: async () => { closes++; } }),
  };
  const controller = new PlaybackController({ create: async () => engine });
  const emit = (type, fields = {}) => engine.onEvent(Object.assign(new EngineEvent(), { type }, fields));
  return { timers, engine, media, controller, intent: new PlaybackIntent(), emit, closes: () => closes };
}

test('startup deadline covers a play call that never acknowledges, then permits retry', async () => {
  const f = playerFixture({ play: pending }); const failures = [];
  f.controller.onFailure = (failure) => failures.push(failure.kind);
  const opening = f.controller.open(f.media, 'surface', f.intent);
  await drain(); assert.equal(f.controller.current().phase, 'ready');
  await f.timers.advance(25000); await opening;
  assert.equal(f.controller.current().phase, 'failed'); assert.deepEqual(failures, ['timeout']);
  assert.equal(f.closes(), 1);
  f.engine.play = async () => f.emit('firstFrame');
  await f.controller.open(f.media, 'retry', f.intent);
  assert.equal(f.controller.current().firstFrame, true);
  await f.timers.advance(25000); assert.equal(failures.length, 1);
  await f.controller.release();
});

test('playing state alone does not satisfy the first-frame deadline', async () => {
  const f = playerFixture();
  await f.controller.open(f.media, 'surface', f.intent);
  f.emit('state', { state: 'playing' });
  await f.timers.advance(24999); assert.equal(f.controller.current().failure, null);
  await f.timers.advance(1); assert.equal(f.controller.current().failure.kind, 'timeout');
  await f.controller.release();
});

test('first frame cancels the startup deadline', async () => {
  const f = playerFixture();
  await f.controller.open(f.media, 'surface', f.intent);
  f.emit('firstFrame'); await f.timers.advance(30000);
  assert.equal(f.controller.current().failure, null);
  await f.controller.release();
});

for (const action of ['pause', 'interrupt', 'release']) {
  test(`after first frame, ${action} cancels an unacknowledged resume`, async () => {
    const f = playerFixture();
    await f.controller.open(f.media, 'surface', f.intent); f.emit('firstFrame');
    await f.controller.pause(); f.engine.play = pending;
    let resumed = false;
    const resuming = f.controller.play().then(() => { resumed = true; }); await drain();
    const stopping = action === 'interrupt' ? f.emit('interrupt', { hint: 'pause' }) : f.controller[action]();
    await drain(); assert.equal(resumed, true); await stopping; await resuming;
    await f.timers.advance(30000);
    assert.equal(f.controller.current().failure, null);
    assert.equal(f.controller.current().phase === 'failed', false);
    await f.controller.release();
  });
}

test('after first frame, acknowledged resume clears its deadline but a blocked resume still times out', async () => {
  const f = playerFixture();
  await f.controller.open(f.media, 'surface', f.intent); f.emit('firstFrame');
  await f.controller.pause(); await f.controller.play(); await f.timers.advance(30000);
  assert.equal(f.controller.current().failure, null);
  await f.controller.pause(); f.engine.play = pending;
  const resuming = f.controller.play(); await drain();
  f.emit('firstFrame'); // A duplicate frame callback cannot acknowledge the play command.
  await f.timers.advance(25000); await resuming;
  assert.equal(f.controller.current().failure.kind, 'timeout'); await f.controller.release();
});

test('late rejection of a cancelled resume cannot fail a replacement episode', async () => {
  const f = playerFixture(); let rejectPlay;
  await f.controller.open(f.media, 'old', f.intent); f.emit('firstFrame'); await f.controller.pause();
  f.engine.play = () => new Promise((resolve, reject) => { rejectPlay = reject; });
  const resuming = f.controller.play(); await drain();
  const pausing = f.controller.pause(); await drain();
  await f.timers.advance(30000); await pausing; await resuming;
  assert.equal(f.controller.current().failure, null);
  f.engine.play = async () => f.emit('firstFrame');
  await f.controller.open(f.media, 'new', f.intent); rejectPlay(new Error('old play rejected'));
  await drain(); await f.timers.advance(30000);
  assert.equal(f.controller.current().failure, null); await f.controller.release();
});

test('MPV requires clock advancement and never invents a first-frame event', async () => {
  const f = playerFixture({ engineId: 'mpv' }); f.intent.positionMs = 42000;
  await f.controller.open(f.media, 'surface', f.intent, 'mpv');
  f.emit('time', { positionMs: 42000 }); await f.timers.advance(24000);
  assert.equal(f.controller.current().failure, null);
  f.emit('time', { positionMs: 42500 }); await f.timers.advance(30000);
  assert.equal(f.controller.current().failure, null); assert.equal(f.controller.current().firstFrame, false);
  await f.controller.release();
});

test('MPV frozen clock reaches the startup deadline', async () => {
  const f = playerFixture({ engineId: 'mpv' });
  await f.controller.open(f.media, 'surface', f.intent, 'mpv');
  f.emit('time', { positionMs: 0 }); await f.timers.advance(25000);
  assert.equal(f.controller.current().failure.kind, 'timeout'); await f.controller.release();
});

test('pause cancels startup and resume receives a fresh deadline', async () => {
  const f = playerFixture();
  await f.controller.open(f.media, 'surface', f.intent);
  await f.controller.pause(); await f.timers.advance(30000);
  assert.equal(f.controller.current().failure, null);
  await f.controller.play(); await f.timers.advance(25000);
  assert.equal(f.controller.current().failure.kind, 'timeout'); await f.controller.release();
});

test('opening paused waits for explicit play before starting its deadline', async () => {
  const f = playerFixture(); f.intent.paused = true;
  await f.controller.open(f.media, 'surface', f.intent); await f.timers.advance(30000);
  assert.equal(f.controller.current().phase, 'paused');
  await f.controller.play(); f.emit('firstFrame'); await f.timers.advance(30000);
  assert.equal(f.controller.current().failure, null); await f.controller.release();
});

test('a released attempt cannot time out its successor', async () => {
  const f = playerFixture();
  await f.controller.open(f.media, 'old', f.intent); await f.timers.advance(10000);
  const stale = f.engine.onEvent;
  await f.controller.open(f.media, 'new', f.intent);
  stale({ type: 'firstFrame' }); await f.timers.advance(15000);
  assert.equal(f.controller.current().firstFrame, false); assert.equal(f.controller.current().failure, null);
  f.emit('firstFrame'); await f.timers.advance(30000);
  assert.equal(f.controller.current().failure, null); await f.controller.release();
});

test('close finishes at the release bound, retaining descriptors until native teardown completes', async () => {
  const teardown = gate(); const f = playerFixture({ engineId: 'mpv', release: () => teardown.promise });
  await f.controller.open(f.media, 'surface', f.intent, 'mpv');
  let closed = false;
  const closing = f.controller.release().then(() => { closed = true; });
  await drain(); await f.timers.advance(2999); assert.equal(closed, false); assert.equal(f.closes(), 0);
  await f.timers.advance(1); await closing;
  assert.equal(closed, true); assert.equal(f.controller.current().phase, 'idle'); assert.equal(f.closes(), 0);
  teardown.resolve(); await drain(); assert.equal(f.closes(), 1);
});

test('a failed native teardown still lets the host close its session', async () => {
  const f = playerFixture({ release: async () => { throw new Error('release failed'); } });
  await f.controller.open(f.media, 'surface', f.intent);
  await f.controller.release(); assert.equal(f.controller.current().phase, 'idle'); assert.equal(f.closes(), 0);
});

function mpvSurfaceFixture() {
  const timers = clock(); const teardown = gate(); const owners = new Map(); const bindings = [];
  const closed = []; const callbacks = new Map(); let handle = 0; let fd = 10;
  const load = runtime({
    '@kit.CoreFileKit': { fileIo: { OpenMode: {}, openSync: () => ({ fd: ++fd }),
      closeSync: (file) => closed.push(file.fd) } },
    'libmovieclaw_mpv.so': {
      createEngine: () => ++handle,
      initEngine: async (id, options, callback) => {
        assert.equal(owners.has(options.wid), false, 'native Surface already has a producer');
        owners.set(options.wid, id); bindings.push(options.wid); callbacks.set(id, callback);
        callback({ type: 'ready' });
      },
      command: async () => {},
      setProperty: async (id, name, value) => {
        if (name === 'pause' && value === false) {
          callbacks.get(id)({ type: 'property', name: 'pause', value: 0 });
          callbacks.get(id)({ type: 'property', name: 'time-pos', value: 1 });
        }
      },
      destroyEngine: async (id) => {
        if (id === 1) { await teardown.promise; }
        for (const [surface, owner] of owners) { if (owner === id) { owners.delete(surface); } }
      },
    },
  }, timers);
  const { PlaybackController, PlaybackIntent } = load('playback/Index.ets');
  const { PhoneMedia } = load('entry/src/main/ets/playback/PhoneMedia.ets');
  return { timers, teardown, owners, bindings, closed, callbacks, controller: new PlaybackController(),
    intent: () => new PlaybackIntent(), media: new PhoneMedia(0, 100000, '', '/episode.mp4') };
}

for (const replacement of ['switch', 'retry', 'after-close']) {
  test(`native MPV ${replacement} uses a fresh Surface while old teardown retains its fd`, async () => {
    const f = mpvSurfaceFixture(); let resets = 0;
    f.controller.onSurfaceReset = async () => { resets++; return 'fresh'; };
    await f.controller.open(f.media, 'old', f.intent(), 'mpv');
    if (replacement === 'after-close') {
      const closing = f.controller.release(); await drain(); await f.timers.advance(3000); await closing;
    } else if (replacement === 'retry') {
      f.callbacks.get(1)({ type: 'end', reason: 4, code: -13 });
      await drain(); await f.timers.advance(3000);
      assert.equal(f.controller.current().phase, 'failed');
    }
    const opening = f.controller.open(f.media, 'old', f.intent(), 'mpv');
    await drain(); if (replacement === 'switch') { await f.timers.advance(3000); }
    await opening;
    assert.equal(resets, 1); assert.deepEqual(f.bindings, ['old', 'fresh']);
    assert.equal(f.controller.current().failure, null); assert.equal(f.controller.current().playing, true);
    assert.equal(f.owners.get('old'), 1); assert.deepEqual(f.closed, []);
    f.teardown.resolve(); await drain();
    assert.equal(f.owners.has('old'), false); assert.deepEqual(f.closed, [11]);
    await f.controller.release(); assert.deepEqual(f.closed, [11, 12]);
  });
}

for (const reset of ['missing', 'unchanged', 'empty']) {
  test(`unsafe Surface is never rebound when reset is ${reset}`, async () => {
    const f = mpvSurfaceFixture();
    if (reset !== 'missing') { f.controller.onSurfaceReset = async () => reset === 'empty' ? '' : 'old'; }
    await f.controller.open(f.media, 'old', f.intent(), 'mpv');
    const opening = f.controller.open(f.media, 'old', f.intent(), 'mpv');
    await drain(); await f.timers.advance(3000); await opening;
    assert.equal(f.controller.current().phase, 'failed'); assert.deepEqual(f.bindings, ['old']);
    assert.deepEqual(f.closed, []); f.teardown.resolve(); await drain(); await f.controller.release();
  });
}

test('completed native teardown allows Surface reuse without reset', async () => {
  const f = mpvSurfaceFixture(); f.teardown.resolve();
  await f.controller.open(f.media, 'same', f.intent(), 'mpv');
  await f.controller.open(f.media, 'same', f.intent(), 'mpv');
  assert.equal(f.controller.current().failure, null); assert.deepEqual(f.bindings, ['same', 'same']);
  await f.controller.release();
});

test('an independent Surface can start immediately after the release bound, while the original stays reserved', async () => {
  const f = mpvSurfaceFixture(); let resets = 0;
  f.controller.onSurfaceReset = async () => { resets++; return 'fresh'; };
  await f.controller.open(f.media, 'old', f.intent(), 'mpv');
  const switching = f.controller.open(f.media, 'independent', f.intent(), 'mpv');
  await drain(); await f.timers.advance(3000); await switching;
  assert.equal(resets, 0); assert.deepEqual(f.bindings, ['old', 'independent']);
  await f.controller.open(f.media, 'old', f.intent(), 'mpv');
  assert.equal(resets, 1); assert.deepEqual(f.bindings, ['old', 'independent', 'fresh']);
  assert.deepEqual(f.closed, [12]);
  f.teardown.resolve(); await drain(); await f.controller.release();
  assert.deepEqual(f.closed, [12, 11, 13]);
});

test('Surface replacement timeout fails without binding another native producer', async () => {
  const f = mpvSurfaceFixture(); f.controller.onSurfaceReset = pending;
  await f.controller.open(f.media, 'old', f.intent(), 'mpv');
  const opening = f.controller.open(f.media, 'old', f.intent(), 'mpv');
  await drain(); await f.timers.advance(8000); await opening;
  assert.equal(f.controller.current().failure.kind, 'timeout'); assert.deepEqual(f.bindings, ['old']);
  f.teardown.resolve(); await drain(); await f.controller.release();
});

test('late Surface replacement cannot overwrite a newer episode Surface', async () => {
  const f = mpvSurfaceFixture(); const surface = gate(); f.controller.onSurfaceReset = () => surface.promise;
  await f.controller.open(f.media, 'old', f.intent(), 'mpv');
  const opening = f.controller.open(f.media, 'old', f.intent(), 'mpv');
  await drain(); await f.timers.advance(3000);
  await f.controller.open(f.media, 'newer', f.intent(), 'mpv');
  surface.resolve('stale'); await opening;
  assert.deepEqual(f.bindings, ['old', 'newer']); assert.equal(f.controller.current().playing, true);
  f.teardown.resolve(); await drain(); await f.controller.release();
});

test('exit during Surface replacement cannot reopen a stale episode', async () => {
  const f = mpvSurfaceFixture(); const surface = gate();
  f.controller.onSurfaceReset = () => surface.promise;
  await f.controller.open(f.media, 'old', f.intent(), 'mpv');
  const opening = f.controller.open(f.media, 'old', f.intent(), 'mpv');
  await drain(); await f.timers.advance(3000); await f.controller.release();
  surface.resolve('stale'); await opening;
  assert.deepEqual(f.bindings, ['old']); assert.equal(f.controller.current().phase, 'idle');
  f.teardown.resolve(); await drain();
});

test('MPV invalidates its native handle without waiting for a blocked command tail', async () => {
  const commandGate = gate(); const teardown = gate(); let destroyed = 0;
  const load = runtime({ 'libmovieclaw_mpv.so': {
    createEngine: () => 7, command: () => commandGate.promise, setProperty: () => commandGate.promise,
    destroyEngine: () => { destroyed++; return teardown.promise; },
  } });
  const engine = new (load('player_engine/src/main/ets/MpvEngine.ets').MpvEngine)();
  const playing = engine.play(); await drain(); const releasing = engine.release();
  assert.equal(destroyed, 1); assert.equal(engine.release(), releasing);
  teardown.resolve(); await releasing; commandGate.resolve(); await playing;
});

test('MPV skips a rejected optional subtitle command and still plays', async () => {
  const calls = []; const sets = []; const diagnostics = [];
  const load = runtime({ 'libmovieclaw_mpv.so': {
    createEngine: () => 7, initEngine: async (handle, options, callback) => callback({ type: 'ready' }),
    command: async (handle, args) => { calls.push(args[0]); if (args[0] === 'sub-add') { throw new Error('subtitle'); } },
    setProperty: async (handle, name, value) => { sets.push([name, value]); },
    destroyEngine: async () => {},
  } });
  const engine = new (load('player_engine/src/main/ets/MpvEngine.ets').MpvEngine)();
  engine.onEvent = (event) => diagnostics.push(event.type);
  await engine.open({ fd: -1, url: 'fixture', subtitleFd: 20, subtitleUrl: '' }, 'surface');
  await engine.play();
  assert.deepEqual(calls, ['loadfile', 'sub-add']);
  assert.deepEqual(sets.map((entry) => entry[0]), ['sub-visibility', 'sub-delay', 'pause']);
  assert.equal(sets[0][1], 'yes');
  assert.deepEqual(diagnostics, ['diagnostic']); await engine.release();
});

test('AVPlayer prepares and plays after optional subtitle attachment rejects', async () => {
  const handlers = new Map(); const diagnostics = []; const calls = [];
  const player = {
    state: 'idle', duration: 100000,
    on: (name, fn) => handlers.set(name, fn),
    set url(value) { this.state = 'initialized'; handlers.get('stateChange')('initialized'); },
    addSubtitleFromFd: async () => { throw new Error('subtitle'); },
    prepare: async () => { calls.push('prepare'); player.state = 'prepared'; handlers.get('stateChange')('prepared'); },
    play: async () => { calls.push('play'); player.state = 'playing'; handlers.get('stateChange')('playing'); },
    release: async () => {},
  };
  const load = runtime({ '@kit.MediaKit': { media: { createAVPlayer: async () => player } } });
  const { AVPlayerEngine } = load('player_engine/src/main/ets/AVPlayerEngine.ets');
  const engine = new AVPlayerEngine(); engine.onEvent = (event) => diagnostics.push(event.type);
  await engine.open({ fd: -1, url: 'fixture', subtitleFd: 20, subtitleUrl: '' }, 'surface');
  await engine.play(); assert.deepEqual(calls, ['prepare', 'play']); assert.ok(diagnostics.includes('diagnostic'));
  await engine.release();
});

test('AVPlayer ignores focus-gain churn and forwards only explicit interrupt hints', async () => {
  const handlers = new Map(); const hints = [];
  const player = {
    state: 'idle', duration: 100000,
    on: (name, fn) => handlers.set(name, fn),
    set url(value) { this.state = 'initialized'; handlers.get('stateChange')('initialized'); },
    prepare: async () => { player.state = 'prepared'; handlers.get('stateChange')('prepared'); },
    play: async () => {}, release: async () => {},
  };
  const load = runtime({
    '@kit.MediaKit': { media: { createAVPlayer: async () => player } },
    '@kit.AudioKit': { audio: { InterruptHint: { INTERRUPT_HINT_NONE: 0, INTERRUPT_HINT_RESUME: 1,
      INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_STOP: 3, INTERRUPT_HINT_DUCK: 4, INTERRUPT_HINT_UNDUCK: 5 } } },
  });
  const { AVPlayerEngine } = load('player_engine/src/main/ets/AVPlayerEngine.ets');
  const engine = new AVPlayerEngine();
  engine.onEvent = (event) => { if (event.type === 'interrupt') { hints.push(event.hint); } };
  await engine.open({ fd: -1, url: 'fixture', subtitleFd: -1, subtitleUrl: '' }, 'surface');
  const interrupt = handlers.get('audioInterrupt');
  interrupt({ hintType: 0 });
  interrupt({ hintType: 2 });
  interrupt({ hintType: 4 });
  assert.deepEqual(hints, ['pause', 'duck']);
  await engine.release();
});

function avpSeekFixture(seek) {
  const handlers = new Map();
  const player = {
    state: 'idle', duration: 100000, currentTime: 5000,
    on: (name, fn) => handlers.set(name, fn),
    off: (name) => handlers.delete(name),
    set url(value) { this.state = 'initialized'; handlers.get('stateChange')('initialized'); },
    prepare: async () => { player.state = 'prepared'; handlers.get('stateChange')('prepared'); },
    play: async () => { player.state = 'playing'; handlers.get('stateChange')('playing'); },
    seek,
    release: async () => {},
  };
  const load = runtime({ '@kit.MediaKit': { media: { createAVPlayer: async () => player, SeekMode: { SEEK_CLOSEST: 1 } } } });
  const { AVPlayerEngine } = load('player_engine/src/main/ets/AVPlayerEngine.ets');
  return { player, handlers, engine: new AVPlayerEngine(), AVPlayerEngine };
}

test('AVPlayer seek resolves once the position reaches the target', async () => {
  const { player, handlers, engine } = avpSeekFixture((ms) => {
    player.currentTime = ms;
    handlers.get('seekDone')();
    // A fresh timeUpdate after the command is what makes currentTime trustworthy.
    handlers.get('timeUpdate')(ms);
  });
  await engine.open({ fd: -1, url: 'fixture', subtitleFd: -1, subtitleUrl: '' }, 'surface');
  await engine.play();
  await engine.seek(90000);
  assert.equal(player.currentTime, 90000);
  await engine.release();
});

test('AVPlayer seek rejects as timeout when the position never reaches the target', async () => {
  const { handlers, engine, AVPlayerEngine } = avpSeekFixture((ms) => { handlers.get('seekDone')(); });
  AVPlayerEngine.seekVerifyWindowMs = 50;
  await engine.open({ fd: -1, url: 'fixture', subtitleFd: -1, subtitleUrl: '' }, 'surface');
  await engine.play();
  await assert.rejects(engine.seek(90000), (error) => error.kind === 'timeout');
  await engine.release();
});

test('AVPlayer backward seek rejects as timeout when the position never falls back', async () => {
  // Review round 5: the old landing check (`currentTime >= target - tolerance`)
  // accepted backward seeks vacuously — the pre-seek position always sat above the
  // floor. A backward seek must wait for a fresh timeUpdate proving the position
  // actually came down.
  const { player, handlers, engine, AVPlayerEngine } = avpSeekFixture((ms) => { handlers.get('seekDone')(); });
  AVPlayerEngine.seekVerifyWindowMs = 50;
  player.currentTime = 90000;
  await engine.open({ fd: -1, url: 'fixture', subtitleFd: -1, subtitleUrl: '' }, 'surface');
  await engine.play();
  const seeking = engine.seek(7000);
  // Fresh ticks keep flowing, but only at the un-seeked position: no landing.
  handlers.get('timeUpdate')(90000);
  await assert.rejects(seeking, (error) => error.kind === 'timeout');
  await engine.release();
});

test('AVPlayer backward seek lands once a fresh time update reaches the target', async () => {
  const { player, handlers, engine } = avpSeekFixture((ms) => { handlers.get('seekDone')(); });
  player.currentTime = 90000;
  await engine.open({ fd: -1, url: 'fixture', subtitleFd: -1, subtitleUrl: '' }, 'surface');
  await engine.play();
  const seeking = engine.seek(7000);
  player.currentTime = 7200;
  handlers.get('timeUpdate')(7200);
  await seeking;
  assert.equal(player.currentTime, 7200);
  await engine.release();
});

test('AVPlayer paused seek trusts seekDone without landing verification', async () => {
  const { player, handlers, engine } = avpSeekFixture((ms) => { handlers.get('seekDone')(); });
  await engine.open({ fd: -1, url: 'fixture', subtitleFd: -1, subtitleUrl: '' }, 'surface');
  await engine.play();
  player.state = 'paused';
  await engine.seek(90000);
  assert.equal(player.currentTime, 5000);
  await engine.release();
});

test('an old blocked command queue cannot stall commands on the next episode', async () => {
  const f = playerFixture();
  await f.controller.open(f.media, 'old', f.intent);
  const commandGate = gate(); f.engine.setRate = () => commandGate.promise;
  const oldCommand = f.controller.setRate(1.5); await drain(); await f.controller.release();
  let applied = 0; f.engine.setRate = async () => { applied++; };
  await f.controller.open(f.media, 'new', f.intent); await f.controller.setRate(2);
  assert.equal(applied, 2); commandGate.resolve(); await oldCommand; await f.controller.release();
});

for (const backgroundFails of [false, true]) {
  for (const deactivateFails of [false, true]) {
    test(`AVSession is destroyed with background failure=${backgroundFails}, deactivate failure=${deactivateFails}`, async () => {
      const calls = [];
      const session = { on() {}, setAVMetadata: async () => {}, activate: async () => {},
        deactivate: async () => { calls.push('deactivate'); if (deactivateFails) { throw new Error('deactivate'); } },
        destroy: async () => { calls.push('destroy'); } };
      const load = runtime({
        '@kit.AVSessionKit': { avSession: { createAVSession: async () => session } },
        '@kit.AbilityKit': { wantAgent: { getWantAgent: async () => ({}), OperationType: {}, WantAgentFlags: {} } },
        '@kit.BackgroundTasksKit': { backgroundTaskManager: { BackgroundMode: {},
          startBackgroundRunning: async () => {},
          stopBackgroundRunning: async () => { calls.push('background'); if (backgroundFails) { throw new Error('stop'); } },
        } },
      });
      const { PlaybackGuard } = load('playback/Index.ets');
      const guard = new PlaybackGuard({ abilityInfo: {} }, () => {}, () => {}, () => {});
      await guard.start('fixture');
      if (backgroundFails || deactivateFails) { await assert.rejects(guard.stop()); } else { await guard.stop(); }
      assert.deepEqual(calls, ['background', 'deactivate', 'destroy']);
      await guard.stop().catch(() => {}); assert.equal(calls.filter((call) => call === 'destroy').length, 1);
    });
  }
}

for (const engine of ['avplayer', 'mpv']) {
  for (const status of [404, 'timeout', 200, 'bitmap']) {
    test(`${engine}: optional subtitle ${status} preserves video acquisition and playback`, async () => {
      const files = new Map(); const closed = []; const removed = []; const warnings = [];
      let destroyed = 0; let options;
      const load = runtime({
        '@kit.NetworkKit': { http: { RequestMethod: {}, HttpDataType: {}, createHttp: () => ({
          request: async (url, value) => { options = value;
            if (status === 'timeout') { throw new Error('https://signed.invalid/private?token=secret'); }
            return { responseCode: status === 'bitmap' ? 200 : status,
              result: status === 'bitmap' ? new Uint8Array([0x50, 0x47, 0, 0xff]).buffer
                : new TextEncoder().encode('00:00:32,500 --> 00:00:34,000\nHello').buffer };
          }, destroy: () => { destroyed++; },
        }) } },
        '@kit.PerformanceAnalysisKit': { hilog: { info: () => {}, warn: (...args) => warnings.push(args.join(' ')) } },
        '@kit.CoreFileKit': { fileIo: { OpenMode: { READ_ONLY: 1, CREATE: 2, WRITE_ONLY: 4, TRUNC: 8 },
          openSync: (name, mode) => ({ fd: name === '/movie.mp4' ? 10 : mode === 1 ? 20 : 30 }),
          writeSync: (fd, data) => files.set(fd, data), closeSync: (file) => closed.push(file.fd),
          unlinkSync: (name) => removed.push(name),
        } },
      });
      const { PhoneMedia } = load('entry/src/main/ets/playback/PhoneMedia.ets');
      const media = new PhoneMedia(30000, 100000, '', '/movie.mp4', 'https://signed.invalid/sub?token=secret', '', '/cache');
      const lease = await media.acquire(engine);
      assert.equal(lease.source.fd, 10); assert.equal(lease.source.subtitleUrl, ''); assert.equal(destroyed, 1);
      assert.equal(options.connectTimeout, 10000); assert.equal(options.readTimeout, 60000);
      const available = status === 200 || (status === 'bitmap' && engine === 'mpv');
      assert.equal(lease.source.subtitleFd, available ? 20 : -1);
      if (status === 200) {
        const content = files.get(30);
        assert.ok((typeof content === 'string' ? content : new TextDecoder().decode(content))
          .startsWith(engine === 'avplayer' ? '00:00:02,500' : '00:00:32,500'));
        assert.equal(lease.source.subtitleOffsetMs, engine === 'mpv' ? 30000 : 0);
      } else if (available) {
        assert.deepEqual([...new Uint8Array(files.get(30))], [0x50, 0x47, 0, 0xff]);
      } else { assert.equal(warnings.length, 1); assert.ok(!warnings[0].includes('secret')); }
      const { PlaybackController, PlaybackIntent } = load('playback/Index.ets');
      const controller = new PlaybackController({ create: async () => ({ id: engine, onEvent() {},
        open: async () => {}, setRate: async () => {}, setGain: async () => {}, setSubtitleStyle: async () => {},
        play: async () => {}, release: async () => {},
      }) });
      await controller.open({ ...media, acquire: async () => lease }, 'surface', new PlaybackIntent(), engine);
      assert.equal(controller.current().failure, null);
      await controller.release(); await lease.close();
      assert.deepEqual(closed, available ? [30, 10, 20] : [10]);
      assert.equal(removed.length, available ? 1 : 0);
    });
  }
}

test('episode switch carries immutable choices through the real API report adapter', async () => {
  const load = runtime();
  const { PlaybackSessionCoordinator } = load('playback/Index.ets');
  const { MovieClawPlaybackSession } = load('entry/src/main/ets/playback/MovieClawPlaybackSession.ets');
  const { PlayerParams } = load('entry/src/main/ets/player/PlayerParams.ets');
  const gateFirst = gate(); const bodies = []; const stops = [];
  const api = {
    playbackProgress: async (body) => { if (body.episode_number === 1 && body.event === 'start') { await gateFirst.promise; }
      bodies.push(body); return { ended_by_admin: false }; },
    playbackSessionStop: async (id) => stops.push(id),
  };
  const port = (episode) => new MovieClawPlaybackSession(api, { session_id: `session-${episode}`, decision: { file_id: episode } },
    new PlayerParams(42, episode, 1, episode));
  const coordinator = new PlaybackSessionCoordinator();
  coordinator.bind(port(1)); coordinator.update(42000, 100000, true, 'embedded:1', 'off'); await drain();
  coordinator.update(45000, 100000, false, 'embedded:2', 'external:old');
  coordinator.bind(port(2)); coordinator.update(2000, 100000, true, 'embedded:3', 'external:new');
  gateFirst.resolve(); await drain();
  const old = bodies.filter((body) => body.episode_number === 1);
  assert.deepEqual(old.map((body) => [body.event, body.audio_track, body.subtitle_track, body.position_ms]),
    [['start', 'embedded:1', 'off', null], ['stop', 'embedded:2', 'external:old', 45000]]);
  assert.deepEqual(stops, ['session-1']);
  coordinator.close(); await drain(); assert.deepEqual(stops, ['session-1', 'session-2']);
});

test('a transient genre failure keeps the old tiles, retries next round, and never touches the rows gate', async () => {
  const load = runtime();
  const { HomeRows } = load('entry/src/main/ets/library/HomeRows.ets');
  const { LibraryHomeStore } = load('entry/src/main/ets/library/LibraryHomeStore.ets');
  const library = { id: 1, name: 'Movies', kind: 'movie', viewer_access: true,
    exclude_from_home: false, scanning: false, organizing: false,
    stats: { item_count: 5, file_count: 6 } };
  // The default layout is exactly these rows: using it as the row prefs keeps build() from appending anything.
  const prefs = HomeRows.build([], [library], []).map((row) => ({ id: row.id, hidden: row.hidden }));
  const rowCalls = [];
  let genreCalls = 0;
  let genreFails = true;
  const api = {
    uiPrefsShow: async () => ({ home: { rows: prefs } }),
    libraryList: async () => [library],
    collectionList: async () => [],
    playbackUpNext: async () => ({ items: [] }),
    playbackFavorites: async () => ({ items: [], total: 0 }),
    libraryItemsList: async () => { rowCalls.push('items'); return []; },
    uiLibraryKindItems: async () => { rowCalls.push('kindItems'); return []; },
    uiLibraryKindGenres: async () => {
      genreCalls++;
      if (genreFails) { throw new Error('genre 503'); }
      return [{ name: 'Drama', count: 2 }];
    },
  };
  const store = new LibraryHomeStore();
  // Round 1: the genre endpoint 503s — rows still commit, genres keep the old value and no fingerprint lands.
  await store.reload(api, 'owner');
  assert.equal(store.rowsLoaded, true);
  assert.equal(genreCalls, 1);
  assert.deepEqual(store.genresByKind, {});
  const rowsAfterFirst = rowCalls.length;
  // Round 2: still failing — the rows gate stays shut, the genre gate keeps retrying.
  await store.reload(api, 'owner');
  assert.equal(rowCalls.length, rowsAfterFirst);
  assert.equal(genreCalls, 2);
  assert.deepEqual(store.genresByKind, {});
  // Round 3: recovered — only the genre distribution refetches and lands its fingerprint.
  genreFails = false;
  await store.reload(api, 'owner');
  assert.equal(rowCalls.length, rowsAfterFirst);
  assert.equal(genreCalls, 3);
  assert.deepEqual(store.genresByKind, { movie: [{ name: 'Drama', count: 2 }] });
  // Round 4: both gates shut — nothing is requested at all.
  await store.reload(api, 'owner');
  assert.equal(rowCalls.length, rowsAfterFirst);
  assert.equal(genreCalls, 3);
});

test('a genre answer landed mid-scan does not outlive the scan', async () => {
  const load = runtime();
  const { HomeRows } = load('entry/src/main/ets/library/HomeRows.ets');
  const { LibraryHomeStore } = load('entry/src/main/ets/library/LibraryHomeStore.ets');
  // Review round 2: while a scan runs the genre endpoint can legitimately answer an
  // empty list and still commit its fingerprint. Once the scan lands files and ends,
  // the fingerprint has to move so the next poll brings the tiles back — an empty
  // answer must never be remembered as the final verdict.
  let scanning = true;
  let itemCount = 0;
  const library = () => ({ id: 7, name: 'Movies', kind: 'movie', viewer_access: true,
    exclude_from_home: false, scanning, organizing: false,
    stats: { item_count: itemCount, file_count: itemCount } });
  const prefs = HomeRows.build([], [library()], []).map((row) => ({ id: row.id, hidden: row.hidden }));
  let genreCalls = 0;
  const api = {
    uiPrefsShow: async () => ({ home: { rows: prefs } }),
    libraryList: async () => [library()],
    collectionList: async () => [],
    playbackUpNext: async () => ({ items: [] }),
    playbackFavorites: async () => ({ items: [], total: 0 }),
    libraryItemsList: async () => [],
    uiLibraryKindItems: async () => [],
    uiLibraryKindGenres: async () => {
      genreCalls++;
      return scanning ? [] : [{ name: 'Drama', count: 2 }];
    },
  };
  const store = new LibraryHomeStore();
  // Round 1: mid-scan the endpoint succeeds with an empty list — the fingerprint commits.
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 1);
  assert.deepEqual(store.genresByKind, { movie: [] });
  // Round 2: still scanning and the ledger has not moved — the genre gate stays shut.
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 1);
  assert.deepEqual(store.genresByKind, { movie: [] });
  // Round 3: the scan batch has landed and the scan ended — the fingerprint moves, the tiles come back.
  scanning = false;
  itemCount = 2;
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 2);
  assert.deepEqual(store.genresByKind, { movie: [{ name: 'Drama', count: 2 }] });
  // Round 4: the world is stable again — nothing is requested.
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 2);
  assert.deepEqual(store.genresByKind, { movie: [{ name: 'Drama', count: 2 }] });
});

test('the genre fingerprint moves with exclude, viewer access, and metadata refresh', async () => {
  const load = runtime();
  const { HomeRows } = load('entry/src/main/ets/library/HomeRows.ets');
  const { LibraryHomeStore } = load('entry/src/main/ets/library/LibraryHomeStore.ets');
  // Review round 5: the genre aggregate is served per kind, and the server folds each
  // library in or out by its home visibility, viewer access, and metadata refresh. Those
  // transitions must move the fingerprint even when the ledger (item/file counts) stands
  // still, or the tiles go stale until an unrelated counter ticks. A stable sibling
  // library keeps the genres row itself alive through every flip — a single flipping
  // library would drag the row down (and the kind list with it) instead.
  const world = { excluded: false, viewer: true, refreshing: false };
  const stable = { id: 1, name: 'Movies', kind: 'movie', viewer_access: true,
    exclude_from_home: false, scanning: false, organizing: false,
    stats: { item_count: 5, file_count: 6 } };
  const flipping = () => ({ id: 2, name: 'Archive', kind: 'movie', viewer_access: world.viewer,
    exclude_from_home: world.excluded, scanning: false, organizing: false,
    metadata_refresh: world.refreshing
      ? { refreshing: true, processed: 1, total: 2, failed: 0, stopping: false, active: [] }
      : undefined,
    stats: { item_count: 3, file_count: 4 } });
  const prefs = HomeRows.build([], [stable, flipping()], []).map((row) => ({ id: row.id, hidden: row.hidden }));
  let genreCalls = 0;
  const api = {
    uiPrefsShow: async () => ({ home: { rows: prefs } }),
    libraryList: async () => [stable, flipping()],
    collectionList: async () => [],
    playbackUpNext: async () => ({ items: [] }),
    playbackFavorites: async () => ({ items: [], total: 0 }),
    libraryItemsList: async () => [],
    uiLibraryKindItems: async () => [],
    uiLibraryKindGenres: async () => {
      genreCalls++;
      return [{ name: 'Drama', count: 2 }];
    },
  };
  const store = new LibraryHomeStore();
  // Round 1: the baseline lands.
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 1);
  assert.deepEqual(store.genresByKind, { movie: [{ name: 'Drama', count: 2 }] });
  // Round 2: the ledger and every state bit are unchanged — the gate stays shut.
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 1);
  // Round 3: the library is excluded from home — the server's aggregate changes.
  world.excluded = true;
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 2);
  // Round 4: back in — refetch again.
  world.excluded = false;
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 3);
  // Round 5: viewer access drops (locked admin card) — the library leaves the aggregate.
  world.viewer = false;
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 4);
  // Round 6: browsable again — refetch.
  world.viewer = true;
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 5);
  // Round 7: a whole-library metadata refresh starts — genre names can change mid-run.
  world.refreshing = true;
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 6);
  // Round 8: the refresh ends — the final verdict can differ from the mid-run answer.
  world.refreshing = false;
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 7);
  assert.deepEqual(store.genresByKind, { movie: [{ name: 'Drama', count: 2 }] });
  // Round 9: the world is stable — nothing is requested.
  await store.reload(api, 'owner');
  assert.equal(genreCalls, 7);
});
