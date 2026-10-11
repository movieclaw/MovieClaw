const { test, expect } = require('@playwright/test');
const { openDesktop, browseLibrary, state } = require('./helpers.cjs');

test('native controls hide after startup and resume, and return on mouse movement', async ({page,request}) => {
  await nativeTracks(page,request);
  await expect(page.locator('#playerControls')).toHaveCSS('opacity','0',{timeout:6000});
  await page.evaluate(()=>window.__fixture.emit('movieclaw:player-input',{instanceId:Player.mpvInstanceId,args:['movieclaw-input','move']}));
  await expect(page.locator('#playerControls')).toHaveCSS('opacity','1');
  await expect(page.locator('#playerControls')).toHaveCSS('opacity','0',{timeout:6000});
  await page.mouse.move(300,300);
  await expect(page.locator('#playerControls')).toHaveCSS('opacity','1');
  await page.keyboard.press('Space');
  await expect.poll(()=>property(page,'pause')).toBe(true);
  await page.waitForTimeout(3500);
  await expect(page.locator('#playerControls')).toHaveCSS('opacity','1');
  await page.keyboard.press('Space');
  await expect(page.locator('#playerControls')).toHaveCSS('opacity','0',{timeout:6000});
});

test('controls remain available while a panel is open and hide after it closes', async ({page,request}) => {
  await nativeTracks(page,request);
  await page.locator('#btnSettings').click();
  await page.waitForTimeout(3500);
  await expect(page.locator('#playerControls')).toHaveCSS('opacity','1');
  await page.keyboard.press('Escape');
  await expect(page.locator('#playerSettingsPanel')).toBeHidden();
  await expect(page.locator('#playerControls')).toHaveCSS('opacity','0',{timeout:6000});
});

test('native playback shows real read speed and optional diagnostics through button, shortcut and right click', async ({page,request}) => {
  await nativeTracks(page,request);
  await page.evaluate(()=>{window.__fixture.props['cache-speed']=4*1024*1024;window.__fixture.props['hwdec-current']='d3d11va';window.__fixture.props['demuxer-cache-duration']=42;window.__fixture.props.ipc_connected=true;});
  await expect(page.locator('#playerSpeedBadge')).toHaveText('↓ 4.0 MB/s');
  const badge=await page.locator('#playerSpeedBadge').boundingBox();
  const header=await page.locator('#playerTopbar').boundingBox();
  expect(badge.y).toBeGreaterThanOrEqual(header.y+header.height);
  await expect(page.locator('#playerInfoPanel')).toBeHidden();
  await page.locator('#btnPlayerInfo').click();
  await expect(page.locator('#btnPlayerInfo')).toHaveAttribute('aria-expanded','true');
  await expect(page.locator('#playerInfoBody')).toContainText('实际解码 d3d11va');
  await expect(page.locator('#playerInfoBody')).toContainText('缓冲 42.0 秒');
  await expect(page.locator('#playerInfoBody')).toContainText('4.0 MB/s');
  await page.locator('#playerInfoClose').click();
  await page.keyboard.press('i'); await expect(page.locator('#playerInfoPanel')).toBeVisible();
  await page.evaluate(()=>window.__fixture.emit('movieclaw:player-input',{instanceId:Player.mpvInstanceId,args:['movieclaw-input','info']}));
  await expect(page.locator('#playerInfoPanel')).toBeHidden();
  await page.evaluate(()=>{Player.hideControls();window.__fixture.props['cache-speed']=0;});
  await expect(page.locator('#playerSpeedBadge')).toHaveText('↓ 0 KB/s');
  await page.locator('#playerSpeedBadge').click(); await expect(page.locator('#playerInfoPanel')).toBeVisible();
  await page.evaluate(()=>{delete window.__fixture.props['cache-speed'];});
  await expect(page.locator('#playerSpeedBadge')).toHaveText('↓ —');
  await page.locator('#playerInfoClose').click(); await page.locator('#playerBack').click();
  await expect(page.locator('#playerSpeedBadge')).toBeHidden();
});

test('native picture in picture has compact controls and restores on Escape and stop', async ({page,request}) => {
  await nativeTracks(page,request);
  await expect.poll(()=>page.evaluate(()=>window.MovieClawPlatform.status?.active)).toBe(true);
  await page.locator('#btnPip').click();
  await expect(page.locator('#playerView')).toHaveClass(/native-pip/);
  await page.setViewportSize({width:480,height:270});
  await expect(page.locator('#btnSettings')).toBeHidden();
  await expect(page.locator('#btnPlayPause')).toBeVisible();
  await expect(page.locator('#btnPip')).toHaveAttribute('aria-pressed','true');
  const rect=await page.locator('.player-transport').boundingBox();
  expect(rect.x).toBeGreaterThanOrEqual(0); expect(rect.x+rect.width).toBeLessThanOrEqual(480);
  await page.keyboard.press('Escape'); await expect(page.locator('#playerView')).not.toHaveClass(/native-pip/);
  await page.locator('#btnPip').click(); await expect(page.locator('#playerView')).toHaveClass(/native-pip/);
  await page.locator('#playerBack').click(); await expect(page.locator('#playerView')).toBeHidden();
  await expect.poll(()=>page.evaluate(()=>window.__fixture.platform?.active)).toBe(false);
});

test('native video Escape restores PiP and the fullscreen button keeps restored fullscreen active', async ({page,request}) => {
  await nativeTracks(page,request);
  await expect.poll(()=>page.evaluate(()=>window.MovieClawPlatform.status?.active)).toBe(true);
  await page.locator('#btnFullscreen').click();
  await expect.poll(()=>page.evaluate(()=>window.__fixture.fullscreen)).toBe(true);
  await page.locator('#btnPip').click();
  await expect(page.locator('#playerView')).toHaveClass(/native-pip/);
  await expect.poll(()=>page.evaluate(()=>window.__fixture.fullscreen)).toBe(false);
  await page.evaluate(()=>Player.handleNativeInput(['escape']));
  await expect(page.locator('#playerView')).not.toHaveClass(/native-pip/);
  await expect(page.locator('#playerView')).toBeVisible();
  await expect.poll(()=>page.evaluate(()=>window.__fixture.fullscreen)).toBe(true);
  await page.locator('#btnPip').click();
  await expect(page.locator('#playerView')).toHaveClass(/native-pip/);
  await page.locator('#btnFullscreen').click();
  await expect(page.locator('#playerView')).not.toHaveClass(/native-pip/);
  await expect.poll(()=>page.evaluate(()=>window.__fixture.fullscreen)).toBe(true);
  await page.locator('#playerBack').click();
});

async function nativeTracks(page, request) {
  await page.route('**/api/v1/playback/sessions', async route => {
    const response = await route.fetch(); const body = await response.json();
    Object.assign(body.data, { timeline: 'file', start_ms: 0 });
    Object.assign(body.data.decision, { tier: 0, file_id: 1,
      audio_tracks: [
        { ref: 'embedded:0', codec: 'aac', language: 'eng', channels: 2, is_default: true },
        { ref: 'embedded:1', codec: 'aac', language: 'zho', channels: 2 },
      ], subtitles: [
        { track_ref: 'embedded:0', kind: 'ass', language: 'eng' },
        { track_ref: 'embedded:1', kind: 'pgs', language: 'zho' },
      ] });
    await route.fulfill({ response, json: body });
  });
  await page.addInitScript(() => {
    localStorage.setItem('mc_audioLang', 'en'); localStorage.setItem('mc_subLang', '');
  });
  await openDesktop(page, request); await browseLibrary(page);
  await page.evaluate(() => Object.assign(window.__fixture.props, {
    aid: 7, sid: 'no', speed: 1, 'sub-delay': 0, 'hwdec-current': 'd3d11va',
    // Deliberately out of order: ffmpeg indexes, type ordinals and mpv IDs differ.
    'track-list': [
      { type: 'video', id: 1, 'ff-index': 0 },
      { type: 'audio', id: 42, 'ff-index': 5, lang: 'zho' },
      { type: 'audio', id: 7, 'ff-index': 2, lang: 'eng' },
      { type: 'sub', id: 19, 'ff-index': 9, lang: 'zho' },
      { type: 'sub', id: 11, 'ff-index': 8, lang: 'eng' },
    ],
  }));
  await page.locator('#posterGrid .poster-card[data-item-id="1"]').click();
  await page.locator('#btnPlay').click();
  await expect.poll(() => page.evaluate(() => Player.mpvTracks.audio.length)).toBe(2);
  await expect.poll(() => page.evaluate(() => Player._reportedStart)).toBe(true);
}
async function property(page, key) { return page.evaluate(key => window.__fixture.props[key], key); }

test('native fullscreen frame menu fills, restores the original aspect and remembers its choice', async ({ page, request }) => {
  await nativeTracks(page, request);
  await expect(page.locator('#btnPip')).toBeVisible();
  await page.locator('#btnSettings').click();
  await page.locator('[data-tab="frame"]').click();
  const fill = page.getByRole('button', { name: /^填满屏幕/ });
  const original = page.getByRole('button', { name: /^保持原比例/ });
  await fill.click();
  await expect(fill).toHaveAttribute('aria-pressed', 'true');
  await expect.poll(() => property(page, 'panscan')).toBe(0);
  await page.locator('#btnFullscreen').click();
  await expect.poll(() => property(page, 'panscan')).toBe(1);
  await page.locator('#btnSettings').click(); await page.locator('[data-tab="frame"]').click();
  await original.click();
  await expect.poll(() => property(page, 'panscan')).toBe(0);
  await fill.click();
  await expect.poll(() => property(page, 'panscan')).toBe(1);
  // Engine reconfiguration must also apply the saved fullscreen mode.
  await page.evaluate(async () => { window.__fixture.props.panscan = 0; await Player.initializeTracks(); });
  await expect.poll(() => property(page, 'panscan')).toBe(1);
  await page.locator('#btnFullscreen').click();
  await expect.poll(() => property(page, 'panscan')).toBe(0);
  expect(await page.evaluate(() => localStorage.getItem('mc_fullscreenFit'))).toBe('cover');
  await page.locator('#playerBack').click();
  await page.reload();
  await expect.poll(() => page.evaluate(() => Player.fullscreenFit)).toBe('cover');
});

test('HTML5 fullscreen uses the same frame menu and restores contain on exit', async ({ page, request }) => {
  await openDesktop(page, request, { native: false }); await browseLibrary(page);
  await page.locator('#posterGrid .poster-card[data-item-id="1"]').click();
  await page.locator('#btnPlay').click();
  await page.locator('#btnSettings').click(); await page.locator('[data-tab="frame"]').click();
  await expect(page.locator('[data-tab="audio"]')).toBeHidden();
  await page.getByRole('button', { name: /^填满屏幕/ }).click();
  await expect(page.locator('#playerVideo')).toHaveCSS('object-fit', 'contain');
  await page.locator('#btnFullscreen').click();
  await expect(page.locator('#playerVideo')).toHaveCSS('object-fit', 'cover');
  await page.locator('#btnSettings').click(); await page.locator('[data-tab="frame"]').click();
  await page.getByRole('button', { name: /^保持原比例/ }).click();
  await expect(page.locator('#playerVideo')).toHaveCSS('object-fit', 'contain');
  await page.getByRole('button', { name: /^填满屏幕/ }).click();
  await page.locator('#btnFullscreen').click();
  await expect(page.locator('#playerVideo')).toHaveCSS('object-fit', 'contain');
});

test('native track menus control actual mpv IDs, subtitle off, delay and speed', async ({ page, request }) => {
  await nativeTracks(page, request);
  await page.locator('#btnSettings').click();
  await page.locator('.player-settings-tab[data-tab="audio"]').click();
  await page.locator('.player-settings-item[data-audio-ref="embedded:1"]').click();
  await expect.poll(() => property(page, 'aid')).toBe(42);
  await page.locator('.player-settings-tab[data-tab="subtitles"]').click();
  await page.locator('[data-sub-index="1"]').click();
  await expect.poll(() => property(page, 'sid')).toBe(19);
  await page.locator('.offset-btn').filter({ hasText: '+0.5s' }).click();
  await expect.poll(() => property(page, 'sub-delay')).toBe(.5);
  await page.locator('[data-sub-index="-1"]').click();
  await expect.poll(() => property(page, 'sid')).toBe('no');
  await page.locator('.player-settings-tab[data-tab="speed"]').click();
  await page.locator('.player-settings-item[data-speed="1.5"]').click();
  await expect.poll(() => property(page, 'speed')).toBe(1.5);
  expect(await page.evaluate(() => document.querySelector('#playerVideo').playbackRate)).toBe(1);
  const calls = await page.evaluate(() => window.__fixture.calls.filter(c => c.command === 'send_mpv_command_embedded').map(c => c.args.command));
  expect(calls).toContainEqual(['set_property', 'aid', 42]);
  expect(calls).toContainEqual(['set_property', 'sid', 19]);
  await page.locator('#playerBack').click();
  await expect.poll(async () => (await state(request)).stopped).toEqual(['session-1']);
});

test('keyboard controls drive the active native engine and close once', async ({ page, request }) => {
  await nativeTracks(page, request);
  await page.locator('#playerTitle').click();
  await page.keyboard.press('Space');
  await expect.poll(() => property(page, 'pause')).toBe(true);
  await page.keyboard.press('ArrowRight');
  await expect.poll(() => property(page, 'time-pos')).toBe(31);
  await page.keyboard.press('Shift+ArrowLeft');
  await expect.poll(() => property(page, 'time-pos')).toBe(30);
  await page.keyboard.press(']');
  await expect.poll(() => property(page, 'speed')).toBe(1.25);
  await page.keyboard.press('Control+.');
  await expect(page.locator('#playerView')).toBeHidden();
  await expect.poll(async () => (await state(request)).stopped).toEqual(['session-1']);
});

test('native input fullscreen bypasses browser activation and Escape exits before closing', async ({ page, request }) => {
  await nativeTracks(page, request);
  await page.evaluate(() => {
    document.querySelector('#playerView').requestFullscreen = () => { throw new Error('no browser transient activation'); };
    window.__fixture.emit('movieclaw:player-input', { instanceId: Player.mpvInstanceId, args: ['movieclaw-input', 'double-click'] });
  });
  await expect.poll(() => page.evaluate(() => window.__fixture.fullscreen)).toBe(true);
  await page.keyboard.press('Escape');
  await expect.poll(() => page.evaluate(() => window.__fixture.fullscreen)).toBe(false);
  await expect(page.locator('#playerView')).toBeVisible();
  await page.evaluate(() => { window.__fixture.fullscreenDelay = 200; Player.toggleFullscreen(); });
  await expect.poll(() => page.evaluate(() => window.__fixture.windows.filter(w => w?.name === 'setFullscreen').length)).toBe(3);
  await page.locator('#playerBack').click();
  await expect(page.locator('#playerView')).toBeHidden();
  await expect.poll(() => page.evaluate(() => window.__fixture.windows.filter(w => w?.name === 'setFullscreen').length)).toBe(4);
  await expect.poll(() => page.evaluate(() => window.__fixture.fullscreen)).toBe(false);
  const changes = await page.evaluate(() => window.__fixture.windows.filter(w => w?.name === 'setFullscreen').map(w => w.value));
  expect(changes).toEqual([true, false, true, false]);
  await expect.poll(async () => (await state(request)).stopped).toEqual(['session-1']);
});

test('native fullscreen video fills its viewport while only visible controls keep their web regions', async ({ page, request }) => {
  await nativeTracks(page, request);
  const geometry = () => page.evaluate(() => {
    Player.syncEmbeddedPlayerRect();
    const rect = document.querySelector('.player-video-wrap').getBoundingClientRect();
    const scale = devicePixelRatio;
    return { expected: { x: Math.round(rect.x * scale), y: Math.round(rect.y * scale),
      width: Math.round(rect.width * scale), height: Math.round(rect.height * scale) },
      actual: window.__fixture.calls.filter(c => c.command === 'resize_embedded_player').at(-1)?.args };
  });
  await expect.poll(async () => (await geometry()).actual?.height).toBe(800);
  let boxes = await geometry();
  expect(boxes.actual).toMatchObject(boxes.expected);
  expect(boxes.actual.keepRects.some(rect => rect[2] < boxes.actual.width && rect[3] === 100)).toBe(true);
  await page.locator('#btnFullscreen').click();
  await page.setViewportSize({ width: 1920, height: 1080 });
  await page.evaluate(() => Player.hideControls());
  await expect.poll(async () => (await geometry()).actual?.keepRects.length).toBe(1); // Persistent speed badge.
  boxes = await geometry();
  expect(boxes.actual).toMatchObject({ x: 0, y: 0, width: 1920, height: 1080 });
  await page.evaluate(() => Player.showControls());
  await expect.poll(async () => (await geometry()).actual?.keepRects.length).toBe(3);
  expect((await geometry()).actual).toMatchObject(boxes.expected);
  await page.evaluate(() => Player.togglePlay());
  await expect(page.getByRole('button',{name:'播放或暂停',exact:true})).toBeVisible();
  await expect.poll(async () => (await geometry()).actual?.keepRadii).toContain(36);
  await page.locator('#playerBack').click();
  await expect(page.locator('#playerView')).toBeHidden();
});

test('probed DVD bitmap subtitles stay disabled and explain the actual limitation', async ({ page, request }) => {
  await nativeTracks(page, request);
  await page.evaluate(() => {
    Player.sessionData.source = { subtitle_codecs: ['dvd_subtitle'] };
    Player.sessionData.decision.subtitles = []; Player.sessionData.subtitle_urls = [];
  });
  await page.locator('#btnSettings').click();
  await expect(page.locator('#playerSettingsContent .disabled')).toContainText('此播放路径暂不支持 DVD 位图字幕');
  await expect(page.locator('#playerSettingsContent')).not.toContainText('无可用字幕');
  await page.locator('#playerBack').click();
});
