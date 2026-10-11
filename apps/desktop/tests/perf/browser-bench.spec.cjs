const { test, expect } = require('@playwright/test');
const { openDesktop, browseLibrary, state } = require('../e2e/helpers.cjs');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const crypto = require('node:crypto');
const samples = Math.max(3, Math.min(100, Number(process.env.MC_PERF_SAMPLES) || 30));
const output = path.resolve(__dirname, '../../dist');
const report = { schema: 1, measuredAt: new Date().toISOString(),
  environment: { os: os.platform(), release: os.release(), arch: os.arch(), cpu: os.cpus()[0]?.model,
    logicalCpus: os.cpus().length, node: process.version, viewport: { width: 1280, height: 800 },
    commit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    browser: 'Chromium fixture bridge', nativeWindowsMeasured: false,
    macHardwareComparable: false,
    sources: Object.fromEntries(['app.js', 'api.js', 'player.js', 'performance.js'].map(name => [name,
      crypto.createHash('sha256').update(fs.readFileSync(path.resolve(__dirname, '../../ui/desktop', name))).digest('hex')])) }, scenarios: {} };
function summary(values) {
  const sorted = values.slice().sort((a, b) => a - b);
  const p = n => sorted[Math.max(0, Math.ceil(sorted.length * n) - 1)];
  return { count: sorted.length, minMs: sorted[0], p50Ms: p(.5), p95Ms: p(.95), maxMs: sorted.at(-1) };
}
function save() {
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'browser-performance.json'), JSON.stringify(report, null, 2) + '\n');
}
async function frames(page, count = 2) {
  await page.evaluate(n => new Promise(resolve => {
    const next = () => --n <= 0 ? resolve() : requestAnimationFrame(next);
    requestAnimationFrame(next);
  }), count);
}
test.beforeAll(() => fs.mkdirSync(output, { recursive: true }));
test.afterEach(save);

test('30 cold and warm page renders with actual HTTP and DOM', async ({ browser, request }) => {
  const cold = [], warm = [], library = [];
  for (let i = 0; i < samples; i++) {
    const context = await browser.newContext({ baseURL: 'http://127.0.0.1:4179', viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await page.addInitScript(() => { window.__MOVIECLAW_PERF_ENABLED__ = true; });
    const errors = []; page.on('pageerror', error => errors.push(error.name));
    const start = performance.now();
    await openDesktop(page, request);
    await expect(page.locator('#heroBanner')).toBeVisible(); await frames(page);
    cold.push(performance.now() - start);
    const libStart = performance.now(); await browseLibrary(page); await frames(page);
    library.push(performance.now() - libStart);
    const warmStart = performance.now();
    await page.locator('[data-page="home"]').click();
    await expect(page.locator('#heroBanner')).toBeVisible(); await frames(page);
    warm.push(performance.now() - warmStart);
    expect(errors).toEqual([]);
    if (i === samples - 1) {
      report.telemetry = await page.evaluate(() => MovieClawPerf.snapshot());
      await page.screenshot({ path: path.join(output, 'fixture-home.png') });
    }
    await context.close();
  }
  report.scenarios.coldHome = summary(cold); report.scenarios.warmHome = summary(warm);
  report.scenarios.firstLibrary = summary(library);
  expect(cold).toHaveLength(samples);
});

test('large library retains bounded DOM and restores navigation', async ({ page, request }) => {
  await openDesktop(page, request, { itemCount: 10000 }); await browseLibrary(page);
  for (let i = 0; i < 40; i++) {
    await page.locator('#wallSentinel').scrollIntoViewIfNeeded();
    await expect.poll(() => page.evaluate(() => App._wallPager.offset)).toBeGreaterThan((i + 1) * 60);
  }
  const metrics = await page.evaluate(() => ({ loaded: App._wallPager.offset,
    indexedItems: App._wallPager.items.length,
    retainedItems: App._wallPager.items.filter(item => !item._evicted).length,
    domCards: document.querySelectorAll('#posterGrid .poster-card').length,
    images: document.querySelectorAll('#posterGrid img').length }));
  report.scenarios.largeLibrary = metrics;
  expect(metrics.loaded).toBeGreaterThanOrEqual(2400);
  expect(metrics.retainedItems).toBeLessThanOrEqual(720);
  expect(metrics.domCards).toBeLessThanOrEqual(360);
  const itemId = await page.locator('#posterGrid .poster-card').first().getAttribute('data-item-id');
  await page.locator('#posterGrid .poster-card').first().click();
  await expect(page.locator('#btnPlay')).toBeVisible();
  await page.evaluate(() => App.goBack()); await frames(page);
  await expect(page.locator(`#posterGrid .poster-card[data-item-id="${itemId}"]`)).toBeVisible();
});

test('scroll frame intervals and long tasks have reproducible raw samples', async ({ page, request }) => {
  await openDesktop(page, request, { itemCount: 10000 }); await browseLibrary(page);
  const intervals = await page.evaluate(() => new Promise(resolve => {
    const content = document.querySelector('#content'), result = []; let previous, n = 0;
    function frame(t) {
      if (previous != null) result.push(t - previous); previous = t;
      content.scrollTop += n < 120 ? 10 : -10;
      if (++n >= 240) resolve(result); else requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }));
  report.scenarios.scroll = { ...summary(intervals), frameIntervalsMs: intervals,
    framesOver50Ms: intervals.filter(n => n > 50).length,
    interpretation: 'rAF intervals in fixture Chromium; not input-to-photon or physical display hitches' };
  expect(intervals).toHaveLength(239);
});

test('20 real HTML5 playback cycles release sessions and media', async ({ page, request }) => {
  await openDesktop(page, request, { native: false }); await browseLibrary(page);
  await page.locator('#posterGrid .poster-card[data-item-id="1"]').click();
  const firstFrames = [];
  for (let cycle = 0; cycle < 20; cycle++) {
    const start = performance.now(); await page.locator('#btnPlay').click();
    await expect.poll(() => page.evaluate(() => document.querySelector('#playerVideo').getVideoPlaybackQuality().totalVideoFrames)).toBeGreaterThan(0);
    await expect.poll(async () => (await state(request)).requests.filter(r => r.path === '/playback/progress' && r.body?.event === 'start').length).toBe(cycle + 1);
    firstFrames.push(performance.now() - start);
    await page.locator('#playerBack').click();
    await expect(page.locator('#playerView')).toBeHidden();
    await expect.poll(async () => (await state(request)).stopped.length).toBe(cycle + 1);
    await expect(page.locator('#btnPlay')).toBeVisible();
  }
  const final = await state(request);
  expect(final.created).toHaveLength(20); expect(final.stopped).toHaveLength(20);
  expect(new Set(final.stopped).size).toBe(20);
  const starts = final.requests.filter(r => r.path === '/playback/progress' && r.body?.event === 'start');
  const stops = final.requests.filter(r => r.path === '/playback/progress' && r.body?.event === 'stop');
  expect(starts).toHaveLength(20); expect(stops).toHaveLength(20);
  report.scenarios.browserPlayback = { cycles: 20, firstFrame: summary(firstFrames),
    created: final.created.length, stopped: final.stopped.length, reportedStarts: starts.length, reportedStops: stops.length,
    nativeDecodeMeasured: false };
});
