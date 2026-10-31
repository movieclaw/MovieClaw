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
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, error() {} } },
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
    if (file.endsWith('/offline/OfflineDisk.ets')) { return { OfflineDisk: { fileSize: () => 100 } }; }
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
for (const suite of ['PlaybackController', 'PlaybackSession', 'PlaybackGateway']) {
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

test('MPV invalidates its native handle without waiting for a blocked command tail', async () => {
  const commandGate = gate(); const teardown = gate(); let destroyed = 0;
  const load = runtime({ 'libmovieclaw_mpv.so': {
    createEngine: () => 7, command: () => commandGate.promise,
    destroyEngine: () => { destroyed++; return teardown.promise; },
  } });
  const engine = new (load('player_engine/src/main/ets/MpvEngine.ets').MpvEngine)();
  const playing = engine.play(); await drain(); const releasing = engine.release();
  assert.equal(destroyed, 1); assert.equal(engine.release(), releasing);
  teardown.resolve(); await releasing; commandGate.resolve(); await playing;
});

test('MPV skips a rejected optional subtitle command and still plays', async () => {
  const calls = []; const diagnostics = [];
  const load = runtime({ 'libmovieclaw_mpv.so': {
    createEngine: () => 7, initEngine: async (handle, options, callback) => callback({ type: 'ready' }),
    command: async (handle, args) => { calls.push(args[0]); if (args[0] === 'sub-add') { throw new Error('subtitle'); } },
    destroyEngine: async () => {},
  } });
  const engine = new (load('player_engine/src/main/ets/MpvEngine.ets').MpvEngine)();
  engine.onEvent = (event) => diagnostics.push(event.type);
  await engine.open({ fd: -1, url: 'fixture', subtitleFd: 20, subtitleUrl: '' }, 'surface');
  await engine.play(); assert.deepEqual(calls, ['loadfile', 'sub-add', 'set', 'set']);
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
        '@kit.PerformanceAnalysisKit': { hilog: { warn: (...args) => warnings.push(args.join(' ')) } },
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
      assert.equal(options.connectTimeout, 10000); assert.equal(options.readTimeout, 15000);
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
