const { test, expect } = require('@playwright/test');
const { openDesktop, browseLibrary } = require('./helpers.cjs');

test('track metadata stays inert text/data and menu listeners survive redraw under CSP', async ({ page, request }) => {
  await openDesktop(page, request);
  await browseLibrary(page);
  await page.evaluate(() => {
    const policy = document.createElement('meta'); policy.httpEquiv = 'Content-Security-Policy';
    policy.content = "script-src-attr 'none'"; document.head.appendChild(policy);
    window.__metadataExecuted = false;
    window.__chosenAudio = [];
    const malicious = "embedded:1');window.__metadataExecuted=true;//\" autofocus onfocus=\"window.__metadataExecuted=true";
    const label = '<img src=x onerror="window.__metadataExecuted=true">';
    Player.adoptSession('Fixture', { media_item_id: 1, session_id: null, timeline: 'file',
      source: { resolution: label, video_codec: label, hdr: label },
      decision: { tier: 3, file_id: 1, audio_tracks: [
        { ref: 'embedded:0', codec: 'aac', language: 'eng', is_default: true },
        { ref: malicious, codec: 'aac', language: label },
      ], subtitles: [{ track_ref: 'sidecar:1', kind: 'vtt', title: label, language: 'eng' }] } },
      { media_item_id: 1, library_id: 1, title: 'Fixture' }, 'html5');
    document.querySelector('#playerView').hidden = false;
    Player.selectAudio = ref => { window.__chosenAudio.push(ref); Player.renderSettingsTab('audio'); };
    Player.toggleSettings(); Player.renderSettingsTab('audio');
  });
  const audio = page.locator('[data-player-action="audio"]').nth(1);
  const ref = await audio.getAttribute('data-audio-ref');
  expect(ref).toContain("');window.__metadataExecuted");
  await expect(audio).toContainText('<img src=x');
  await audio.click();
  expect(await page.evaluate(() => window.__chosenAudio)).toEqual([ref]);
  await expect(page.locator('#playerSettingsPanel')).toBeVisible();
  await page.locator('.player-settings-tab[data-tab="subtitles"]').click();
  await expect(page.locator('[data-sub-index="0"]')).toContainText('<img src=x');
  await page.locator('.player-settings-tab[data-tab="quality"]').click();
  await expect(page.locator('#playerSettingsContent')).toContainText('<img src=x');
  expect(await page.locator('#playerSettingsContent img').count()).toBe(0);
  expect(await page.locator('#playerSettingsContent [onclick]').count()).toBe(0);
  expect(await page.evaluate(() => window.__metadataExecuted)).toBe(false);
});
