import { describe, it, expect, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component } from '@ohos.UiTest';

/** Real UI/server/decoder scenarios; fixture JSON uses the logged-in debug app. */
async function waitFor(driver: Driver, id: string, timeoutMs: number = 40000): Promise<Component> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const component = await driver.findComponent(ON.id(id));
    if (component !== null) { return component; }
    const error = await driver.findComponent(ON.id('player-error'));
    if (error !== null) { throw new Error(await error.getText()); }
    await driver.delayMs(250);
  }
  throw new Error(`Timed out waiting for ${id}`);
}
async function waitGone(driver: Driver, id: string): Promise<void> {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (await driver.findComponent(ON.id(id)) === null) { return; }
    await driver.delayMs(150);
  }
  throw new Error(`Still visible after transition: ${id}`);
}
async function menuScroll(driver: Driver, kind: string): Promise<Component> {
  const deadline = Date.now() + 3000;
  let previous = '';
  while (Date.now() < deadline) {
    const scroll = await driver.findComponent(ON.id(`player-menu-scroll-${kind}`));
    if (scroll !== null) {
      const bounds = await scroll.getBounds();
      const key = `${bounds.left},${bounds.top},${bounds.right},${bounds.bottom}`;
      if (bounds.bottom - bounds.top > 40 && key === previous) { return scroll; }
      previous = key;
    }
    await driver.delayMs(100);
  }
  throw new Error(`Menu layout did not settle: ${kind}`);
}
async function reveal(driver: Driver): Promise<void> {
  if (await driver.findComponent(ON.id('player-toggle')) === null) {
    await (await waitFor(driver, 'player-surface')).click();
    await driver.delayMs(400); // Single taps wait for the double-tap recognition window.
  }
}
async function position(driver: Driver): Promise<string> {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    await reveal(driver);
    const label = await driver.findComponent(ON.id('player-position'));
    if (label !== null) {
      try { return await label.getText(); }
      catch (error) { /* The auto-hide timer can invalidate a previously found widget. */ }
    }
    await driver.delayMs(500);
  }
  throw new Error('Playback controls did not respond to surface taps');
}
async function openFixture(driver: Driver, parameter: string): Promise<void> {
  const args = abilityDelegatorRegistry.getArguments();
  const fixture = args.parameters[`-s ${parameter}`] ?? '';
  if (fixture.length === 0) { throw new Error(`Missing authenticated media fixture: ${parameter}`); }
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  await delegator.startAbility({ bundleName: args.bundleName, abilityName: 'EntryAbility' });
  await driver.delayMs(2500);
  await delegator.startAbility({
    bundleName: args.bundleName, abilityName: 'EntryAbility', parameters: { mcPlaybackTest: fixture }
  });
  await waitFor(driver, 'player-surface');
  await waitFor(driver, 'player-toggle');
  await waitFor(driver, 'player-pause-glyph');
}
async function exercise(driver: Driver, fixture: string, expectedEngine: string): Promise<void> {
  await openFixture(driver, fixture);
  // Wait for actual clock advancement; presence of a surface does not establish playback.
  const initial = await position(driver);
  const deadline = Date.now() + 40000;
  let advanced = false;
  while (Date.now() < deadline) {
    await driver.delayMs(1000);
    if (await position(driver) !== initial) { advanced = true; break; }
  }
  expect(advanced).assertTrue();
  await reveal(driver);
  await (await waitFor(driver, 'player-toggle')).click();
  await waitFor(driver, 'player-play-glyph', 1000);
  await driver.delayMs(750);
  const paused = await position(driver);
  await driver.delayMs(2200);
  expect(await position(driver)).assertEqual(paused);
  await (await waitFor(driver, 'player-forward')).click();
  await driver.delayMs(1500);
  expect(await position(driver) === paused).assertFalse();
  await (await waitFor(driver, 'player-toggle')).click();
  await reveal(driver);
  await (await waitFor(driver, 'player-settings')).click();
  await menuScroll(driver, 'settings');
  await (await menuScroll(driver, 'settings')).scrollToBottom();
  await (await waitFor(driver, 'player-diagnostics')).click();
  expect(await (await waitFor(driver, 'player-engine')).getText()).assertContain(expectedEngine);
  await driver.pressBack(); // dismiss details
  await driver.delayMs(1000);
  await driver.pressBack(); // return to library; host releases session and native player
  await driver.delayMs(1500);
  await waitGone(driver, 'player-page');
}
async function exerciseStyle(driver: Driver, fixture: string, name: string): Promise<void> {
  const captureDir = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().cacheDir;
  await openFixture(driver, fixture);
  await driver.delayMs(2500);
  await reveal(driver);
  await (await waitFor(driver, 'player-toggle')).click();
  await waitFor(driver, 'player-play-glyph', 1000);
  await driver.delayMs(750);
  const paused = await position(driver);
  const video = await (await waitFor(driver, 'player-surface')).getBounds();
  await driver.click(video.left + 20, video.top + 20);
  await driver.delayMs(2300);
  expect(await position(driver)).assertEqual(paused);
  await driver.screenCap(`${captureDir}/mc-style-${name}-portrait.png`);

  await (await waitFor(driver, 'player-audio')).click();
  await menuScroll(driver, 'audio');
  await waitFor(driver, 'player-menu');
  await waitFor(driver, 'player-audio-active', 1000);
  await driver.screenCap(`${captureDir}/mc-style-${name}-audio.png`);
  await (await waitFor(driver, 'player-subtitle')).click();
  await menuScroll(driver, 'subtitle');
  await waitFor(driver, 'player-subtitle-off');
  await waitFor(driver, 'player-subtitle-active', 1000);
  await waitGone(driver, 'player-audio-active');
  await driver.screenCap(`${captureDir}/mc-style-${name}-subtitles.png`);
  await (await waitFor(driver, 'player-subtitle-off')).click();
  await driver.delayMs(2000);
  await waitGone(driver, 'player-menu');
  await waitGone(driver, 'player-subtitle-active');

  await (await waitFor(driver, 'player-settings')).click();
  await menuScroll(driver, 'settings');
  await (await waitFor(driver, 'player-speed')).click();
  await menuScroll(driver, 'speed');
  await (await waitFor(driver, 'player-speed-1.5')).click();
  await waitGone(driver, 'player-menu');
  expect(await (await waitFor(driver, 'player-rate-badge')).getText()).assertEqual('1.5×');
  await (await waitFor(driver, 'player-settings')).click();
  await menuScroll(driver, 'settings');
  await (await waitFor(driver, 'player-quality')).click();
  await (await waitFor(driver, 'player-quality-0')).click();
  await waitGone(driver, 'player-menu');
  await (await waitFor(driver, 'player-settings')).click();
  await menuScroll(driver, 'settings');
  await (await waitFor(driver, 'player-speed')).click();
  await menuScroll(driver, 'speed');
  await (await waitFor(driver, 'player-speed-1')).click();
  await waitGone(driver, 'player-menu');
  await waitGone(driver, 'player-rate-badge');

  await (await waitFor(driver, 'player-rotate')).click();
  await driver.delayMs(1600);
  const landscape = await (await waitFor(driver, 'player-page')).getBounds();
  expect(landscape.right - landscape.left > landscape.bottom - landscape.top).assertTrue();
  await driver.screenCap(`${captureDir}/mc-style-${name}-landscape.png`);
  await (await waitFor(driver, 'player-settings')).click();
  await menuScroll(driver, 'settings');
  await waitFor(driver, 'player-settings-active', 1000);
  await driver.screenCap(`${captureDir}/mc-style-${name}-settings.png`);
  await (await menuScroll(driver, 'settings')).scrollToBottom();
  await (await waitFor(driver, 'player-speed')).click();
  await menuScroll(driver, 'speed');
  // Submenu starts at the top even when the parent menu was scrolled.
  await waitFor(driver, 'player-speed-0.5', 1000);
  await driver.screenCap(`${captureDir}/mc-style-${name}-speed-top.png`);
  await (await waitFor(driver, 'player-menu-back')).click();
  await waitFor(driver, 'player-quality', 1000);
  await (await menuScroll(driver, 'settings')).scrollToBottom();
  await (await waitFor(driver, 'player-speed')).click();
  await menuScroll(driver, 'speed');
  await (await waitFor(driver, 'player-settings')).click();
  await waitGone(driver, 'player-menu');
  await waitGone(driver, 'player-settings-active');
  await (await waitFor(driver, 'player-settings')).click();
  await menuScroll(driver, 'settings');
  await (await waitFor(driver, 'player-display')).click();
  await menuScroll(driver, 'display');
  const panel = await (await waitFor(driver, 'player-menu')).getBounds();
  const top = await (await waitFor(driver, 'player-close')).getBounds();
  const bottom = await (await waitFor(driver, 'player-settings')).getBounds();
  expect(panel.top >= top.bottom).assertTrue(); expect(panel.bottom <= bottom.top).assertTrue();
  await driver.screenCap(`${captureDir}/mc-style-${name}-display.png`);
  await (await waitFor(driver, 'player-display-fill')).click();
  await waitGone(driver, 'player-menu');
  await driver.screenCap(`${captureDir}/mc-style-${name}-fill.png`);
  await (await waitFor(driver, 'player-settings')).click();
  await menuScroll(driver, 'settings');
  await (await waitFor(driver, 'player-display')).click();
  await menuScroll(driver, 'display');
  await (await menuScroll(driver, 'display')).scrollToBottom();
  await (await waitFor(driver, 'player-display-stretch')).click();
  await waitGone(driver, 'player-menu');
  const stretched = await (await waitFor(driver, 'player-surface')).getBounds();
  expect(Math.abs((stretched.right - stretched.left) - (landscape.right - landscape.left)) < 2).assertTrue();
  await driver.screenCap(`${captureDir}/mc-style-${name}-stretch.png`);
  await (await waitFor(driver, 'player-settings')).click();
  await menuScroll(driver, 'settings');
  await (await waitFor(driver, 'player-display')).click();
  await menuScroll(driver, 'display');
  await (await menuScroll(driver, 'display')).scrollToTop();
  await (await waitFor(driver, 'player-display-fit')).click();
  await waitGone(driver, 'player-menu');
  await (await waitFor(driver, 'player-lock')).click();
  await driver.delayMs(300);
  await waitGone(driver, 'player-toggle');
  await driver.click((landscape.left + landscape.right) / 2, (landscape.top + landscape.bottom) / 2);
  await waitGone(driver, 'player-toggle');
  await (await waitFor(driver, 'player-lock')).click();
  await waitFor(driver, 'player-toggle');
  await (await waitFor(driver, 'player-close')).click();
  await driver.delayMs(1600);
  const portrait = await (await waitFor(driver, 'player-page')).getBounds();
  expect(portrait.bottom - portrait.top > portrait.right - portrait.left).assertTrue();
  await (await waitFor(driver, 'player-toggle')).click();
  const resumed = await position(driver); await driver.delayMs(2200);
  expect(await position(driver) === resumed).assertFalse();
  await driver.delayMs(4500); await waitGone(driver, 'player-toggle');
  await reveal(driver); await (await waitFor(driver, 'player-close')).click();
  await driver.delayMs(1000);
  await waitGone(driver, 'player-page');
}

async function exerciseToggleIcon(driver: Driver, fixture: string, name: string): Promise<void> {
  const captureDir = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().cacheDir;
  await openFixture(driver, fixture);
  await driver.delayMs(2500);
  await reveal(driver);
  await waitFor(driver, 'player-pause-glyph', 1000);
  for (let i = 0; i < 3; i++) {
    await (await waitFor(driver, 'player-toggle')).click();
    await waitFor(driver, 'player-play-glyph', 500);
    expect(await driver.findComponent(ON.id('player-pause-glyph')) === null).assertTrue();
    const paused = await position(driver);
    await driver.delayMs(1200);
    expect(await position(driver)).assertEqual(paused);
    if (i === 0) { await driver.screenCap(`${captureDir}/mc-toggle-${name}-paused.png`); }
    await (await waitFor(driver, 'player-toggle')).click();
    await waitFor(driver, 'player-pause-glyph', 500);
    expect(await driver.findComponent(ON.id('player-play-glyph')) === null).assertTrue();
    await driver.delayMs(1200);
    expect(await position(driver) === paused).assertFalse();
    if (i === 0) { await driver.screenCap(`${captureDir}/mc-toggle-${name}-playing.png`); }
  }
}

export default function playbackE2ETest() {
  describe('HarmonyPhonePlaybackE2E', () => {
    afterEach(async () => {
      const driver = Driver.create();
      for (let i = 0; i < 4; i++) {
        if (await driver.findComponent(ON.id('player-page')) === null) { return; }
        await driver.pressBack(); await driver.delayMs(1000);
      }
      await waitGone(driver, 'player-page');
    });
    it('AVPlayer_toggle_icon_tracks_native_playback_without_reopening_controls', 0, async () => {
      await exerciseToggleIcon(Driver.create(), 'avplayerFixture', 'avp');
    });
    it('MPV_toggle_icon_tracks_native_playback_without_reopening_controls', 0, async () => {
      await exerciseToggleIcon(Driver.create(), 'mpvFixture', 'mpv');
    });
    it('AVPlayer_iPhone_style_menus_rotation_lock_and_pause', 0, async () => {
      await exerciseStyle(Driver.create(), 'avplayerFixture', 'avp');
    });
    it('MPV_iPhone_style_menus_rotation_lock_and_pause', 0, async () => {
      await exerciseStyle(Driver.create(), 'mpvFixture', 'mpv');
    });
    it('AVPlayer_real_media_play_pause_seek_and_exit', 0, async () => {
      await exercise(Driver.create(), 'avplayerFixture', 'avplayer');
    });
    it('unsupported_original_falls_back_to_MPV_and_remains_interactive', 0, async () => {
      await exercise(Driver.create(), 'fallbackFixture', 'mpv');
    });
    it('MPV_real_media_play_pause_seek_and_exit', 0, async () => {
      await exercise(Driver.create(), 'mpvFixture', 'mpv');
    });
  });
}
