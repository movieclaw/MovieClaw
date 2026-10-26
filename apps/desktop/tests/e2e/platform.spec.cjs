const { test, expect } = require('@playwright/test');
const { openDesktop, browseLibrary, state } = require('./helpers.cjs');

test('system media commands target the current native playback and release paused/end state', async ({ page, request }) => {
  await openDesktop(page, request); await browseLibrary(page);
  await page.locator('#posterGrid .poster-card[data-item-id="1"]').click(); await page.locator('#btnPlay').click();
  await expect.poll(() => page.evaluate(() => window.__fixture.platform?.active)).toBe(true);
  await expect.poll(() => page.evaluate(() => window.__fixture.platform?.paused)).toBe(false);
  const identity = await page.evaluate(() => ({ instanceId: window.__fixture.platform.instanceId, sequence: window.__fixture.platform.sequence }));
  await page.evaluate(identity => window.__fixture.emit('movieclaw:media-command', { ...identity, sequence: identity.sequence - 1, action: 'pause' }), identity);
  expect(await page.evaluate(() => window.__fixture.props.pause)).toBe(false);
  await page.evaluate(identity => window.__fixture.emit('movieclaw:media-command', { ...identity, action: 'pause' }), identity);
  await expect.poll(() => page.evaluate(() => window.__fixture.props.pause)).toBe(true);
  await expect.poll(() => page.evaluate(() => MovieClawPlatform.status?.sleepInhibited)).toBe(false);
  await page.evaluate(identity => window.__fixture.emit('movieclaw:media-command', { ...identity, action: 'seek', positionMs: 321000 }), identity);
  await expect.poll(() => page.evaluate(() => Player.engPos())).toBe(321);
  await page.evaluate(identity => window.__fixture.emit('movieclaw:media-command', { ...identity, action: 'play' }), identity);
  await expect.poll(() => page.evaluate(() => window.__fixture.props.pause)).toBe(false);
  await page.evaluate(identity => window.__fixture.emit('movieclaw:media-command', { ...identity, action: 'stop' }), identity);
  await expect(page.locator('#playerView')).toBeHidden();
  await expect.poll(() => page.evaluate(() => window.__fixture.platform.active)).toBe(false);
  await expect.poll(async () => (await state(request)).stopped).toEqual(['session-1']);
});

test('HTML5 first frame registers platform services and native window preferences are persistent', async ({ page, request }) => {
  await openDesktop(page, request, { native: false });
  await page.locator('[data-page="settings"]').click();
  await expect(page.locator('#setAlwaysOnTop')).toBeChecked(); await expect(page.locator('#setFitWindow')).toBeChecked();
  await page.locator('.settings-toggle').filter({ has: page.locator('#setAlwaysOnTop') }).click();
  await page.locator('.settings-toggle').filter({ has: page.locator('#setFitWindow') }).click();
  await expect(page.locator('#setAlwaysOnTop')).not.toBeChecked();
  await expect(page.locator('#setFitWindow')).not.toBeChecked();
  await browseLibrary(page); await page.locator('#posterGrid .poster-card[data-item-id="1"]').click();
  await page.locator('#btnPlay').click();
  await expect.poll(() => page.evaluate(() => document.querySelector('#playerVideo').getVideoPlaybackQuality().totalVideoFrames)).toBeGreaterThan(0);
  await expect.poll(() => page.evaluate(() => window.__fixture.platform?.fitWindow)).toBe(false);
  expect(await page.evaluate(() => window.__fixture.platform.alwaysOnTop)).toBe(false);
  const updates = await page.evaluate(() => window.__fixture.calls.filter(call => call.command === 'update_native_playback').map(call => call.args.update));
  expect(updates.length).toBeGreaterThan(0); expect(updates[0].durationMs).toBeGreaterThan(0);
  expect(Object.keys(updates[0]).some(key => /token|url|account|password/i.test(key))).toBe(false);
  await page.locator('#playerBack').click(); await expect.poll(() => page.evaluate(() => window.__fixture.platform.active)).toBe(false);
});
