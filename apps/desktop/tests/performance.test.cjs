const { test } = require('node:test');
const assert = require('node:assert/strict');
const perf = require('../ui/desktop/performance.js');

test('diagnostics are opt-in and retain no payload while disabled', () => {
  perf.enable(false); perf.reset();
  perf.playback({ event: 'first_frame', elapsedMs: 200, token: 'secret' });
  perf.network('/auth/login', 20, 'db;dur=2');
  assert.deepEqual(perf.snapshot().entries, []);
});

test('diagnostic export strips identities, signed URLs, logs and arbitrary metadata', () => {
  perf.enable(true); perf.reset();
  perf.playback({ event: 'first_frame', engine: 'mpv', hwdec: 'd3d11va', elapsedMs: 321,
    url: 'https://private/film?token=secret', title: 'private-title', token: 'secret',
    account: 'private-user', error: 'password', log_tail: 'secret' });
  perf.network('/libraries/99/items?token=secret', 12, 'db;dur=2.5;desc="private-user", private-user;dur=2, secret=https://private');
  perf.network('https://private?token=secret', 12);
  const out = perf.snapshot();
  assert.equal(out.entries[0].elapsedMs, 321);
  assert.equal(out.entries[0].hwdec, 'd3d11va');
  assert.deepEqual(out.entries[1].serverTiming, [{ name: 'db', durationMs: 2.5 }]);
  assert.equal(out.entries[1].route, 'library');
  assert.equal(out.entries[2].route, 'other');
  assert.doesNotMatch(JSON.stringify(out), /secret|private|password|token/);
});

test('bounded measurements reject malformed input and export independent snapshots', () => {
  perf.enable(true); perf.reset();
  perf.playback({ event: 'https://secret', elapsedMs: 2 });
  perf.measure('unknown', 3);
  perf.measure('home', Infinity);
  for (let i = 0; i < 300; i++) perf.measure('library', i);
  const out = perf.snapshot();
  assert.equal(out.entries.length, 256);
  assert.equal(out.entries[0].durationMs, 44);
  out.entries[0].durationMs = -1;
  assert.equal(perf.snapshot().entries[0].durationMs, 44);
  perf.enable(false);
});
