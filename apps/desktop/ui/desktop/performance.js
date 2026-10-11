// Opt-in, bounded diagnostics. Values are deliberately narrower than API payloads.
(function (root) {
  'use strict';
  const limit = 256;
  const phases = new Set(['home', 'library', 'detail', 'search', 'person', 'startup']);
  const events = new Set(['negotiation', 'first_frame', 'playing', 'buffer_start', 'buffer_end',
    'seek_start', 'seek_end', 'quality_switch', 'retry', 'error', 'ended', 'closed', 'delivery']);
  const numbers = ['elapsedMs', 'positionMs', 'generation', 'tier', 'outputWidth', 'outputHeight', 'dropped', 'rate'];
  const strings = { engine: ['mpv', 'html5', 'hls'], hwdec: ['no', 'auto', 'd3d11va', 'd3d11va-copy', 'dxva2', 'dxva2-copy', 'nvdec', 'nvdec-copy', 'vulkan', 'unknown'] };
  const timingNames = new Set(['total', 'decide', 'prep', 'spawn', 'db', 'auth', 'probe', 'cache', 'fetch']);
  let enabled = root.__MOVIECLAW_PERF_ENABLED__ === true;
  let started = null;
  let entries = [];
  let observer = null;
  const clock = () => root.performance?.now() ?? Date.now();
  const finite = n => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 86400000;
  function record(value) {
    if (!enabled) return;
    if (started === null) started = clock();
    entries.push({ ...value, atMs: Math.round((clock() - started) * 1000) / 1000 });
    if (entries.length > limit) entries.splice(0, entries.length - limit);
  }
  function serverTiming(header) {
    if (typeof header !== 'string') return [];
    return header.slice(0, 4096).split(',').slice(0, 24).flatMap(part => {
      const match = /^\s*([a-zA-Z][a-zA-Z0-9_-]{0,31})\s*;\s*dur=([\d.]+)(?:\s*;|\s*$)/.exec(part);
      return match && timingNames.has(match[1]) && finite(Number(match[2])) ? [{ name: match[1], durationMs: Number(match[2]) }] : [];
    });
  }
  function routeOf(path) {
    // No paths, queries, usernames or signed URLs enter the exported artifact.
    if (typeof path !== 'string') return 'other';
    if (/^\/auth\//.test(path)) return 'auth';
    if (/^\/playback\/sessions(?:\?|$)/.test(path)) return 'session';
    if (/^\/playback\//.test(path)) return 'playback';
    if (/^\/libraries(?:\/|\?|$)/.test(path)) return 'library';
    if (/^\/collections(?:\/|\?|$)/.test(path)) return 'collection';
    if (/^\/search\//.test(path)) return 'search';
    if (/^\/people\//.test(path)) return 'person';
    return 'other';
  }
  function observe() {
    observer?.disconnect(); observer = null;
    if (!enabled || !root.PerformanceObserver) return;
    try {
      observer = new root.PerformanceObserver(list => {
        for (const item of list.getEntries()) if (finite(item.duration)) record({ type: 'longtask', durationMs: item.duration });
      });
      observer.observe({ type: 'longtask' });
    } catch (_) { observer = null; }
  }
  const api = {
    enable(value) { enabled = value === true; observe(); },
    reset() { entries = []; started = null; },
    measure(phase, durationMs) {
      if (enabled && phases.has(phase) && finite(durationMs)) record({ type: 'page', phase, durationMs });
    },
    network(path, durationMs, timing) {
      if (enabled && finite(durationMs)) record({ type: 'network', route: routeOf(path), durationMs, serverTiming: serverTiming(timing) });
    },
    playback(detail) {
      if (!enabled || !detail || !events.has(detail.event)) return;
      const value = { type: 'playback', event: detail.event };
      for (const key of numbers) if (finite(detail[key])) value[key] = detail[key];
      for (const [key, allowed] of Object.entries(strings)) if (allowed.includes(detail[key])) value[key] = detail[key];
      if (typeof detail.buffering === 'boolean') value.buffering = detail.buffering;
      record(value);
    },
    snapshot() { return { schema: 1, enabled, sampleLimit: limit, entries: JSON.parse(JSON.stringify(entries)) }; },
  };
  root.MovieClawPerf = api;
  root.addEventListener?.('movieclaw:playback-measurement', event => api.playback(event.detail));
  observe();
  if (typeof module === 'object' && module.exports) module.exports = api;
})(typeof window === 'object' ? window : globalThis);
