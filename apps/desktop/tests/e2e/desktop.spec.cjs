const { test, expect } = require('@playwright/test');

const { openDesktop, state, browseLibrary } = require('./helpers.cjs');

test('search excludes hidden and adult libraries even when an old server ignores the scope', async ({page,request}) => {
  const hit=(id,title,ids,extra={})=>({item:{media_item_id:id,kind:'movie',title,...extra},library_ids:ids,match:{label:'片名匹配'}});
  await openDesktop(page,request,{legacySearchScope:true,searchPeople:true,libraries:[
    {id:1,name:'电影库',kind:'movie'}, {id:2,name:'隐藏库',kind:'tv',exclude_from_home:true},
    {id:3,name:'AV',kind:'video'}, {id:4,name:'自定义隐藏',kind:'movie'}, {id:5,name:'剧集库',kind:'tv'},
  ],homeRows:[{id:'lib:4',hidden:true}],searchItems:[
    hit(100,'正常影片',[1]),hit(101,'隐藏影片',[2]),hit(102,'成人影片',[3]),hit(103,'自定义隐藏影片',[4]),
    hit(104,'多个库同片',[2,5]),hit(105,'成人分级影片',[1],{content_rating:'XXX'}),
  ]});
  await page.locator('#searchInput').fill('影片');
  await expect(page.locator('#posterGrid .poster-card')).toHaveCount(2);
  await expect(page.locator('#posterGrid')).toContainText('正常影片');
  await expect(page.locator('#posterGrid')).toContainText('多个库同片');
  await expect(page.locator('.people-chips,.suggestions')).toHaveCount(0);
  const query=(await state(request)).requests.find(r=>r.path==='/search/library');
  expect(query.libraryIds).toEqual([1,5]); expect(query.query.home_only).toBe('true'); expect(query.query.exclude_adult).toBe('true');
  expect(await page.locator('[data-item-id="104"]').getAttribute('data-library-id')).toBe('5');
});

test('search with no eligible libraries does not fall back to an unrestricted request', async ({page,request}) => {
  await openDesktop(page,request,{libraries:[{id:1,name:'成人库',kind:'movie'}]});
  await page.locator('#searchInput').fill('任意');
  await expect(page.locator('#wallStatus')).toContainText('这里还没有内容');
  expect((await state(request)).requests.some(r=>r.path==='/search/library')).toBe(false);
});

test('login keeps window controls usable and enters the authenticated library', async ({ page, request }) => {
  await openDesktop(page, request, { authenticated: false });
  await expect(page.locator('#loginForm')).toBeVisible();
  await page.locator('#btnMinimize').click();
  await expect.poll(() => page.evaluate(() => window.__fixture.windows)).toEqual(['minimize']);
  await page.locator('#loginUser').fill('fixture');
  await page.locator('#loginPass').fill('fixture-password');
  await page.locator('#loginBtn').click();
  await expect(page.locator('#heroBanner')).toBeVisible();
  await browseLibrary(page);
  // A second initialization must not accumulate titlebar handlers.
  await page.evaluate(() => App.init());
  await page.locator('#btnMinimize').click();
  await expect.poll(() => page.evaluate(() => window.__fixture.windows.length)).toBe(2);
});

test('library loads beyond 200 and sorts through server pagination', async ({ page, request }) => {
  await openDesktop(page, request);
  await browseLibrary(page);
  let snapshot = await state(request);
  expect(snapshot.requests.filter(r => r.path === '/libraries/1/items' && r.query.limit === '60')).toHaveLength(1);
  for (let i = 0; i < 6; i++) {
    await page.locator('#wallSentinel').scrollIntoViewIfNeeded();
    await page.waitForTimeout(150);
  }
  await expect(page.locator('#posterGrid .poster-card')).toHaveCount(245);
  await page.getByRole('combobox', { name: '排序', exact: true }).click();
  await page.getByRole('option', { name: '片名', exact: true }).click();
  await expect(page.locator('#posterGrid .poster-card').first()).toHaveAttribute('data-item-id', '245');
  snapshot = await state(request);
  expect(snapshot.requests.some(r => r.path === '/libraries/1/items' && r.query.sort === 'title' && r.query.offset === '0')).toBe(true);
  await page.getByRole('combobox', { name: '排序方向' }).click();
  await page.getByRole('option', { name: '升序', exact: true }).click();
  await expect(page.locator('#posterGrid .poster-card').first()).toHaveAttribute('data-item-id', '1');
  await page.locator('[data-page="favorites"]').click();
  await page.locator('#libraryNav [data-library-id="1"]').click();
  await expect(page.locator('#wallOrder')).toHaveValue('asc');
});

test('nested search hits render as text, paginate and clear back to the prior page', async ({ page, request }) => {
  await openDesktop(page, request);
  await browseLibrary(page);
  const query = '<img src=x onerror="window.__xss=1">';
  await page.locator('#searchInput').fill(query);
  await expect(page.locator('#posterGrid .poster-card').first()).toHaveAttribute('data-item-id', '201');
  await expect(page.locator('#posterGrid')).toContainText(query);
  await page.locator('#wallSentinel').scrollIntoViewIfNeeded();
  await expect(page.locator('#posterGrid .poster-card')).toHaveCount(2);
  expect(await page.evaluate(() => window.__xss)).toBeUndefined();
  expect(await page.locator('#posterGrid img[onerror*="__xss"]').count()).toBe(0);
  await page.locator('#searchInput').fill('');
  await expect(page.locator('.page-title')).toHaveText('测试媒体库');
});

test('a delayed search response cannot overwrite a newer route', async ({ page, request }) => {
  await openDesktop(page, request);
  await expect(page.locator('#heroBanner')).toBeVisible();
  await page.locator('#searchInput').fill('慢搜索');
  await expect.poll(async () => (await state(request)).requests.some(r => r.path === '/search/library')).toBe(true);
  await page.locator('[data-page="favorites"]').click();
  await expect(page.locator('.page-title')).toHaveText('我的收藏');
  await page.waitForTimeout(1100);
  await expect(page.locator('.page-title')).toHaveText('我的收藏');
  expect(await page.evaluate(() => window.__fixture.calls.some(c => c.command === 'cancel_proxy_request'))).toBe(true);
});

test('accounts switch by username and mark the active account', async ({ page, request }) => {
  await openDesktop(page, request);
  await page.locator('[data-page="settings"]').click();
  await expect(page.locator('#accountList')).toContainText('当前');
  await page.locator('#accountList button').filter({ hasText: '切换' }).click();
  await expect.poll(async () => (await state(request)).username).toBe('second');
  const requestBody = (await state(request)).requests.find(r => r.path === '/auth/accounts/switch').body;
  expect(requestBody).toEqual({ username: 'second' });
});

test('slow account login locks cancellation, restores it on failure and keeps the final identity consistent', async ({ page, request }) => {
  await openDesktop(page, request, { username: 'alice', loginDelay: 1800, loginFailures: 1 });
  await page.locator('[data-page="settings"]').click();
  await page.locator('#btnAddAccount').click();
  await page.locator('#loginUser').fill('bob');
  await page.locator('#loginPass').fill('fixture-password');
  await page.locator('#loginBtn').click();
  await expect(page.locator('#loginBtn')).toBeDisabled();
  await expect(page.locator('#cancelAddAccount')).toBeDisabled();
  await expect(page.locator('#loginChangeServer')).toBeDisabled();
  // Dispatch directly as well: the handler must enforce the lock even without browser button semantics.
  await page.evaluate(() => {
    document.getElementById('cancelAddAccount').dispatchEvent(new Event('click'));
    document.getElementById('loginChangeServer').dispatchEvent(new Event('click'));
    document.getElementById('loginForm').dispatchEvent(new Event('submit', { cancelable: true }));
  });
  await expect(page.locator('#loginError')).toContainText('密码错误');
  await expect(page.locator('#loginBtn')).toBeEnabled();
  await expect(page.locator('#cancelAddAccount')).toBeEnabled();
  await expect(page.locator('#loginChangeServer')).toBeEnabled();
  expect((await state(request)).username).toBe('alice');
  await page.locator('#cancelAddAccount').click();
  await expect(page.locator('#accountList')).toContainText('当前');
  expect(await page.evaluate(() => App.session.username)).toBe('alice');
  await page.locator('#btnAddAccount').click();
  await page.locator('#loginUser').fill('bob');
  await page.locator('#loginPass').fill('fixture-password');
  await page.locator('#loginBtn').click();
  await expect(page.locator('#cancelAddAccount')).toBeDisabled();
  await page.evaluate(() => document.getElementById('cancelAddAccount').dispatchEvent(new Event('click')));
  await expect(page.locator('#heroBanner')).toBeVisible();
  expect(await page.evaluate(() => App.session.username)).toBe('bob');
  const snapshot = await state(request);
  expect(snapshot.username).toBe('bob');
  expect(snapshot.requests.filter(r => r.path === '/auth/login')).toHaveLength(2);
  expect(await page.evaluate(() => window.__fixture.calls.filter(c => c.command === 'clear_server_url'))).toHaveLength(0);
  expect(await page.evaluate(() => [App._authPending, App._changingContext])).toEqual([false, false]);
});

test('third-season resume and mpv close report the final file position then release session', async ({ page, request }) => {
  await openDesktop(page, request);
  await browseLibrary(page);
  await page.locator('#posterGrid .poster-card[data-item-id="3"]').click();
  await expect(page.locator('#btnPlay')).toContainText('第 3 季');
  await page.locator('#btnPlay').click();
  await expect(page.locator('#playerView')).toBeVisible();
  await expect.poll(async () => (await state(request)).requests.some(r => r.path === '/playback/progress' && r.body.event === 'start')).toBe(true);
  const start = (await state(request)).requests.find(r => r.path === '/playback/sessions').body;
  expect(start.season_number).toBe(3); expect(start.episode_number).toBe(2);
  expect(start.capability.universal).toBe(true);
  await expect(page.locator('#playerTime')).toHaveText('5:21');
  await page.locator('#playerBack').click();
  await expect(page.locator('#playerView')).toBeHidden();
  await expect.poll(async () => (await state(request)).stopped).toEqual(['session-1']);
  const stop = (await state(request)).requests.find(r => r.path === '/playback/progress' && r.body.event === 'stop');
  expect(stop.body).toMatchObject({ position_ms: 321000, season_number: 3, episode_number: 2 });
  expect(await page.evaluate(() => window.__fixture.running)).toBe(false);
});

test('closing during a delayed session response releases it without reopening the player', async ({ page, request }) => {
  await openDesktop(page, request, { sessionDelay: 900 });
  await browseLibrary(page);
  await page.locator('#posterGrid .poster-card[data-item-id="1"]').click();
  await page.locator('#btnPlay').click();
  await expect.poll(async () => (await state(request)).created.length).toBe(1);
  await page.locator('#playerBack').click();
  await expect(page.locator('#playerView')).toBeHidden();
  await expect.poll(async () => (await state(request)).stopped).toEqual(['session-1']);
  expect(await page.evaluate(() => window.__fixture.calls.filter(c => c.command === 'launch_embedded_player').length)).toBe(0);
  await expect(page.locator('#playerView')).toBeHidden();
});

test('HTML5 decodes a real MP4 before reporting start and closes on the file timeline', async ({ page, request }) => {
  await openDesktop(page, request, { native: false });
  await browseLibrary(page);
  await page.locator('#posterGrid .poster-card[data-item-id="1"]').click();
  await page.locator('#btnPlay').click();
  await expect.poll(async () => (await state(request)).requests.some(r => r.path === '/playback/progress' && r.body.event === 'start')).toBe(true);
  await expect.poll(() => page.evaluate(() => document.querySelector('#playerVideo').getVideoPlaybackQuality().totalVideoFrames)).toBeGreaterThan(0);
  await page.locator('#btnPlayPause').click();
  const position = await page.evaluate(() => Player.snapshot().positionMs);
  expect(position).toBeGreaterThanOrEqual(300000);
  expect(position).toBeLessThan(308000);
  expect(await page.evaluate(() => Player.engDuration())).toBe(3600);
  await page.locator('#playerBack').click();
  await expect.poll(async () => (await state(request)).stopped).toEqual(['session-1']);
  const stop = (await state(request)).requests.find(r => r.path === '/playback/progress' && r.body.event === 'stop');
  expect(Math.abs(stop.body.position_ms - position)).toBeLessThan(500);
});

test('an actor opens credits from the person detail response and returns to the media', async ({ page, request }) => {
  await openDesktop(page, request);
  await browseLibrary(page);
  await page.locator('#posterGrid .poster-card[data-item-id="3"]').click();
  await page.locator('.person-card[data-person-id="9"]').click();
  await expect(page.locator('.person-name')).toHaveText('测试演员');
  await expect(page.locator('.person-works .poster-card')).toHaveCount(1);
  expect((await state(request)).requests.filter(r => r.path === '/people/9/credits')).toHaveLength(0);
  await page.locator('.person-works .poster-card').click();
  await expect(page.locator('#btnPlay')).toContainText('第 3 季');
});

test('session expiration prompts for a password and restores the requested route', async ({ page, request }) => {
  await openDesktop(page, request);
  await browseLibrary(page);
  await request.post('/__test/reset', { data: { authenticated: false } });
  await page.locator('[data-page="favorites"]').click();
  await expect(page.locator('#loginForm')).toBeVisible();
  await expect(page.locator('#loginError')).toContainText('登录已失效');
  await page.locator('#loginPass').fill('fixture-password');
  await page.locator('#loginBtn').click();
  await expect(page.locator('.page-title')).toHaveText('我的收藏');
});

test('manual update check shows a visible result with the runtime version', async ({ page, request }) => {
  await openDesktop(page, request);
  await page.locator('[data-page="settings"]').click();
  await expect(page.locator('#settingsVersion')).toHaveText('版本 0.2.111');
  await page.locator('#btnCheckUpdates').click();
  await expect(page.locator('#desktopUpdateDialog')).toContainText('已是最新版本');
  await page.locator('#desktopUpdateDialog button').filter({ hasText: '关闭' }).click();
  await expect(page.locator('#desktopUpdateDialog')).toHaveCount(0);
});

test('HLS loads real fMP4 fragments through the proxy loader and reports file time', async ({ page, request }) => {
  await openDesktop(page, request, { native: false, hls: true });
  await browseLibrary(page);
  await page.locator('#posterGrid .poster-card[data-item-id="1"]').click();
  await page.locator('#btnPlay').click();
  await expect.poll(() => page.evaluate(() => document.querySelector('#playerVideo').getVideoPlaybackQuality().totalVideoFrames)).toBeGreaterThan(0);
  await expect.poll(async () => (await state(request)).requests.some(r => r.path === '/playback/progress' && r.body.event === 'start')).toBe(true);
  expect(await page.evaluate(() => !!Player.hls)).toBe(true);
  expect(await page.evaluate(() => Player.engPos())).toBeGreaterThanOrEqual(300);
  await page.locator('#playerBack').click();
  await expect.poll(async () => (await state(request)).stopped).toEqual(['session-1']);
  await expect(page.locator('#playerView')).toBeHidden();
});

test('saved home rows determine pinned collections and complete walls, while genre tiles use genre ids', async ({ page, request }) => {
  await openDesktop(page, request, { homeRows: [{ id:'row:selected',collection_id:8,sort:'title',order:'asc',name:'我的精选' }, {id:'favorites',hidden:true}] });
  await expect(page.locator('[data-home-row]').first()).toHaveAttribute('data-home-row','row:selected');
  await expect(page.locator('[data-home-row="favorites"]')).toHaveCount(0);
  await expect(page.locator('#collectionNav [data-collection-id="8"]')).toBeVisible();
  await expect(page.locator('.continue-card')).toHaveCount(1);
  await expect(page.locator('.library-tile')).toHaveCount(2);
  await page.locator('[data-home-row="row:selected"] .see-all-card').click();
  await expect(page.locator('.page-title')).toHaveText('我的精选');
  await expect(page.locator('#posterGrid .poster-card')).toHaveCount(60);
  expect((await state(request)).requests.some(r=>r.path==='/collections/8/items'&&r.query.limit==='60'&&r.query.sort==='title'&&r.query.order==='asc')).toBe(true);
  await page.locator('[data-page="home"]').click();
  await page.locator('.genre-tile[data-genre="28"]').click();
  await expect(page.locator('.page-title')).toHaveText('动作');
  expect((await state(request)).requests.some(r=>r.path==='/libraries/kinds/movie/items'&&r.query.g==='28')).toBe(true);
});

test('each tab restores its detail stack and loaded wall scroll, while reselect returns to the tab root', async ({ page, request }) => {
  await openDesktop(page, request); await browseLibrary(page);
  await page.locator('#wallSentinel').scrollIntoViewIfNeeded();
  await expect(page.locator('#posterGrid .poster-card')).toHaveCount(120);
  await page.locator('#posterGrid [data-item-id="101"]').scrollIntoViewIfNeeded();
  const scroll=await page.locator('#content').evaluate(el=>el.scrollTop);
  await page.locator('#posterGrid [data-item-id="101"]').click();
  await expect(page.locator('.detail-title')).toHaveText('影片 101');
  await page.locator('#accountButton').click(); await expect(page.locator('#accountPanel')).toBeVisible();
  await page.keyboard.press('Escape'); await expect(page.locator('#accountPanel')).toHaveCount(0);
  await expect(page.locator('.detail-title')).toHaveText('影片 101');
  await page.locator('[data-page="favorites"]').click(); await page.locator('#libraryNav [data-library-id="1"]').click();
  await expect(page.locator('.detail-title')).toHaveText('影片 101');
  await page.locator('#btnBack').click();
  await expect(page.locator('#posterGrid .poster-card')).toHaveCount(120);
  expect(await page.locator('#content').evaluate(el=>el.scrollTop)).toBe(scroll);
  await page.locator('#posterGrid [data-item-id="101"]').click();
  await page.locator('#libraryNav [data-library-id="1"]').click();
  await expect(page.locator('.page-title')).toHaveText('测试媒体库');
  await expect(page.locator('#posterGrid .poster-card')).toHaveCount(60);
});

test('hover and right click menus operate on the selected media without opening its detail', async ({ page, request }) => {
  await openDesktop(page, request); await browseLibrary(page);
  const card=page.locator('#posterGrid [data-item-id="1"]');
  await card.hover(); await expect(card.locator('.card-more')).toBeVisible();
  await card.click({button:'right'}); await expect(page.locator('#cardMenu')).toBeVisible();
  await page.locator('#cardMenu button').filter({hasText:/^收藏$/}).click();
  await expect(page.locator('#appNotice')).toHaveText('已收藏');
  await expect(page.locator('.page-title')).toHaveText('测试媒体库');
  expect((await state(request)).requests.some(r=>r.path==='/playback/marks'&&r.body?.media_item_id===1&&r.body.favorite===true)).toBe(true);
});

test('people chips filter search with explanations and selection persists account recent searches', async ({ page, request }) => {
  await openDesktop(page, request, {searchPeople:true});
  await page.locator('#searchInput').fill('演员');
  await expect(page.locator('[data-search-person="9"]')).toBeVisible();
  await expect(page.locator('#posterGrid')).toContainText('片名匹配');
  await page.locator('[data-search-person="9"]').click();
  await expect(page.locator('.person-filter')).toContainText('测试演员');
  await expect(page.locator('#posterGrid')).toContainText('演员：测试演员');
  expect((await state(request)).requests.some(r=>r.path==='/search/library'&&r.query.person_id==='9')).toBe(true);
  await page.locator('#posterGrid .poster-card').first().click();
  await expect(page.locator('#btnPlay')).toBeVisible(); await page.locator('#btnBack').click();
  await expect(page.locator('.person-filter')).toContainText('测试演员');
  await expect(page.locator('[data-search-person="9"]')).toBeVisible();
  await page.locator('#clearPersonFilter').click();
  await page.locator('#searchInput').fill('');
  await expect(page.locator('#heroBanner')).toBeVisible();
  await page.locator('#searchInput').blur(); await page.locator('#searchInput').focus();
  await expect(page.locator('[data-recent-query="演员"]')).toBeVisible();
  await page.locator('#clearRecentSearches').click(); await expect(page.locator('[data-recent-query]')).toHaveCount(0);
});

test('long seasons locate 1051, browse 50-item bands and mark a single episode from the complete grid', async ({ page, request }) => {
  await openDesktop(page, request,{longSeason:true}); await browseLibrary(page);
  await page.locator('#posterGrid [data-item-id="3"]').click();
  await expect(page.locator('[data-episode-range="21"]')).toHaveClass(/active/);
  await expect(page.locator('.episode-card')).toHaveCount(50);
  await expect(page.locator('.detail-episode-line')).toContainText('1051');
  await page.locator('[data-episode-range="20"]').click();
  await expect(page.locator('.episode-card').last()).toHaveAttribute('data-episode-number','1050');
  await expect(page.locator('.detail-episode-line')).toContainText('1051');
  await page.locator('#allEpisodes').click(); await expect(page.locator('[data-grid-episode]')).toHaveCount(1101);
  await expect(page.locator('[data-grid-episode="1052"]')).toBeDisabled();
  await page.locator('[data-grid-episode="51"]').click();
  await expect(page.locator('[data-episode-range="1"]')).toHaveClass(/active/);
  await expect(page.locator('.detail-episode-line')).toContainText('51');
  await page.locator('.episode-card[data-episode-number="51"] .episode-mark-btn').click();
  await expect(page.locator('#appNotice')).toHaveText('已标为已看');
  expect((await state(request)).requests.some(r=>r.path==='/playback/marks'&&r.body?.season_number===3&&r.body.episode_number===51&&r.body.played===true)).toBe(true);
});

test('native welcome chooses a saved account and keeps device credential material out of the browser', async ({ page, request }) => {
  await openDesktop(page,request,{nativeAuth:true,authenticated:false,savedAccounts:[{username:'alice',nickname:'Alice',authenticated:true},{username:'expired',authenticated:false}]});
  await expect(page.locator('h2')).toHaveText('选择账号');
  await page.locator('[data-account="alice"]').click(); await expect(page.locator('#heroBanner')).toBeVisible();
  expect(await page.evaluate(()=>App.session.username)).toBe('alice');
  expect((await state(request)).nativeRequests.some(r=>r.command==='native_select_account'&&r.username==='alice')).toBe(true);
  expect(await page.evaluate(()=>Object.keys(API.nativeAuthStatus).some(key=>/token|device_code/.test(key)))).toBe(false);
});

test('native QR waits for approval, retries a denial and enters the approved account', async ({ page, request }) => {
  await openDesktop(page,request,{nativeAuth:true,authenticated:false,savedAccounts:[],pairStatuses:['denied','pending','approved']});
  await page.locator('#loginPairing').click(); await expect(page.locator('#pairingCode svg')).toBeVisible();
  await expect(page.locator('#pairingCode')).toContainText('FIX-1234');
  await expect(page.locator('#pairingStatus')).toContainText('被拒绝'); await page.locator('#pairingRetry').click();
  await expect(page.locator('#heroBanner')).toBeVisible();
  expect(await page.evaluate(()=>App.session.username)).toBe('paired');
  const snapshot=await state(request);
  expect(snapshot.nativeRequests.filter(r=>r.command==='native_pair_begin')).toHaveLength(2);
  expect(snapshot.nativeRequests.some(r=>r.command==='native_pair_cancel')).toBe(true);
  expect(snapshot.requests.some(r=>r.path==='/auth/device/token')).toBe(false);
});

test('an expired QR can be regenerated and cancel retires an in-flight approval before password login', async ({ page, request }) => {
  await openDesktop(page,request,{nativeAuth:true,authenticated:false,savedAccounts:[],pairExpires:1.2,pairDelay:1500,pairStatuses:['approved']});
  await page.locator('#loginPairing').click(); await expect(page.locator('#pairingStatus')).toContainText('过期');
  await expect(page.locator('#pairingRetry')).toBeVisible();
  await page.locator('#pairingCancel').click(); await expect(page.locator('#loginForm')).toBeVisible();
  await page.waitForTimeout(1800); expect((await state(request)).authenticated).toBe(false);
  await expect(page.locator('#loginForm')).toBeVisible();
});

test('old servers give a specific QR upgrade explanation while native password compatibility remains usable', async ({ page, request }) => {
  await openDesktop(page,request,{nativeAuth:'cookie',authenticated:false,savedAccounts:[]});
  await page.locator('#loginPairing').click(); await expect(page.locator('#appNotice')).toContainText('尚不支持 Windows');
  await page.locator('#loginUser').fill('fixture'); await page.locator('#loginPass').fill('fixture-password'); await page.locator('#loginBtn').click();
  await expect(page.locator('#heroBanner')).toBeVisible();
  expect((await state(request)).nativeRequests.some(r=>r.command==='native_password_login')).toBe(true);
});
