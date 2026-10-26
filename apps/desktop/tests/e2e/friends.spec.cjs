const {test,expect}=require('@playwright/test');
const {openDesktop,browseLibrary,state}=require('./helpers.cjs');
async function settings(page,request,options={}){
 await openDesktop(page,request,{friends:true,...options});await expect.poll(()=>page.evaluate(()=>!!App.session && !App._authPending)).toBe(true);
 await page.locator('[data-page="settings"]').click();await expect(page.locator('#friendsPrivacyState')).not.toHaveText('正在读取服务器隐私设置…');
}
async function playing(page,request,options={}){
 await settings(page,request,options);await page.getByLabel('显示服务器好友列表',{exact:true}).check();
 await browseLibrary(page);await page.locator('#posterGrid .poster-card[data-item-id="3"]').click();await page.locator('#btnPlay').click();
 await expect(page.locator('#btnPlayerFriends')).toBeVisible();await page.locator('#btnPlayerFriends').click();await expect(page.locator('.friends-member')).toHaveCount(1);
}
const patch=(request,body)=>request.post('/__test/friends',{data:body});
test('server privacy page lets existing Web and Mac users opt in without another program',async({page,request},info)=>{
 await openDesktop(page,request,{friends:true});
 await page.goto('/api/v1/plugins/watch-presence/settings');
 await expect(page.locator('#share')).toBeEnabled();await expect(page.locator('#share')).not.toBeChecked();
 await page.locator('#libraries input[value="1"]').check();await page.locator('#share').check();await page.locator('#save').click();
 await expect(page.locator('#status')).toContainText('已保存');expect((await state(request)).friendsPreferences.fixture).toEqual({share_enabled:true,library_ids:[1]});
 await page.screenshot({path:info.outputPath('server-privacy.png')});
 await page.locator('#share').uncheck();await expect(page.locator('#status')).toContainText('共享已关闭');expect((await state(request)).friendsPreferences.fixture.share_enabled).toBe(false);
});
test('entry and sharing default off, only explicit libraries become public and opt-out is immediate',async({page,request})=>{
 await settings(page,request);await expect(page.locator('#setFriendsVisible')).not.toBeChecked();await expect(page.locator('#setFriendsShare')).not.toBeChecked();
 await expect(page.locator('#btnBrowseFriends')).toBeHidden();
 await expect(page.locator('#friendsLibraries input:checked')).toHaveCount(0);await expect(page.locator('#friendsLibraries input[value="4"]')).toBeDisabled();
 await page.locator('#setFriendsShare').check();await page.locator('#saveFriendsPrivacy').click();await expect(page.locator('#friendsPrivacyState')).toContainText('请选择');
 await page.locator('#friendsLibraries input[value="1"]').check();await page.locator('#setFriendsShare').check();await page.locator('#saveFriendsPrivacy').click();
 await expect(page.locator('#friendsPrivacyState')).toContainText('已保存');expect((await state(request)).friendsPreferences.fixture).toEqual({share_enabled:true,library_ids:[1]});
 await page.locator('#setFriendsShare').uncheck();await expect(page.locator('#friendsPrivacyState')).toContainText('共享已关闭');expect((await state(request)).friendsPreferences.fixture.share_enabled).toBe(false);
});
test('homepage entry shows own simultaneous devices without sharing and merges account history',async({page,request},info)=>{
 await settings(page,request,{friendsSelf:true,friendsEmpty:true});
 await expect(page.locator('#setFriendsShare')).not.toBeChecked();
 await page.locator('#setFriendsVisible').check();
 await page.locator('[data-page="home"]').click();await page.locator('#btnBrowseFriends').click();
 await expect(page.locator('#homeFriendsDialog')).toBeVisible();
 await expect(page.locator('.friends-member')).toHaveCount(1);
 await expect(page.locator('.friends-member > header strong')).toHaveText('我的设备');
 await expect(page.locator('.friends-watch')).toHaveCount(2);
 await expect(page.locator('.friends-watch').nth(0)).toContainText('我的 Windows 电脑');
 await expect(page.locator('.friends-watch').nth(1)).toContainText('我的 MacBook');
 await page.screenshot({path:info.outputPath('home-own-devices.png')});
 await page.getByRole('button',{name:'最近观看',exact:true}).click();
 await expect(page.locator('.friends-watch')).toHaveCount(1);
 await expect(page.locator('#homeFriendsDialog .friends-content')).toContainText('不同设备按影片或单集合并');
 expect((await state(request)).friendsPreferences.fixture.share_enabled).toBe(false);
 await page.keyboard.press('Escape');await expect(page.locator('#homeFriendsDialog')).toHaveCount(0);
 await page.locator('[data-page="settings"]').click();await page.locator('#setFriendsVisible').uncheck();
 await expect(page.locator('#btnBrowseFriends')).toBeHidden();
});
for (const mode of ['从头看','跟上进度']) {
 test(`homepage can ${mode} without a hidden player confirmation`,async({page,request})=>{
  await settings(page,request,{friendsSelf:true,friendsEmpty:true});
  await page.locator('#setFriendsVisible').check();await page.locator('[data-page="home"]').click();
  await page.locator('#btnBrowseFriends').click();
  await page.locator('#homeFriendsDialog .friends-watch').nth(1).getByRole('button',{name:mode,exact:true}).click();
  await expect(page.locator('#homeFriendsDialog')).toHaveCount(0);await expect(page.locator('#playerView')).toBeVisible();
  await expect.poll(async()=> (await state(request)).requests.filter(r=>r.path==='/playback/sessions').length).toBe(1);
  const playback=(await state(request)).requests.find(r=>r.path==='/playback/sessions').body;
  expect(playback.media_item_id).toBe(3);expect(playback.season_number).toBe(2);expect(playback.episode_number).toBe(3);
  if(mode==='从头看')expect(playback.start_ms).toBe(0);
  else {expect(playback.start_ms).toBeGreaterThanOrEqual(420000);expect(playback.start_ms).toBeLessThan(430000);}
 });
}
test('display setting restores the homepage entry after login and is scoped to identity',async({page,request})=>{
 await settings(page,request);await page.locator('#setFriendsVisible').check();await page.reload();
 await expect.poll(()=>page.evaluate(()=>!!App.session && !App._authPending)).toBe(true);
 await expect(page.locator('#btnBrowseFriends')).toBeVisible();
 await page.locator('[data-page="settings"]').click();await expect(page.locator('#setFriendsVisible')).toBeChecked();await expect(page.locator('#setFriendsShare')).not.toBeChecked();
 await page.evaluate(()=>App.enterSession({data:{...App.session,username:'another'}}));
 await expect(page.locator('#btnBrowseFriends')).toBeHidden();
 expect(await page.evaluate(()=>DesktopFriends.enabled())).toBe(false);
 expect((await state(request)).requests.filter(row=>row.path.endsWith('/members') && row.path.includes('watch-presence'))).toHaveLength(0);
});
test('left drawer shows devices, progress and history, closes with Esc and preserves native video overlay',async({page,request},info)=>{
 await playing(page,request);await expect(page.locator('.friends-watch')).toContainText('Windows 客户端');await expect(page.locator('.friends-watch')).toContainText('2:00 / 20:00');
 await expect(page.locator('#btnPlayerFriends')).toHaveCSS('border-radius','999px');
 const box=await page.locator('#playerFriendsPanel').boundingBox();expect(box.x).toBeLessThan(30);
 const controls=await page.locator('.player-transport').boundingBox();expect(box.y+box.height).toBeLessThanOrEqual(controls.y-8);
 await page.screenshot({path:info.outputPath('friends-list.png')});
 await expect.poll(()=>page.evaluate(()=>window.__fixture.calls.filter(c=>c.command==='resize_embedded_player').at(-1).args.keepRects.some(r=>r[2]>300 && r[2]<400))).toBe(true);
 await page.getByRole('button',{name:'最近观看',exact:true}).click();await expect(page.locator('.friends-content')).toContainText('最近 7 天');await expect(page.locator('.friends-watch')).toContainText('3:00 / 20:00');
 await page.screenshot({path:info.outputPath('friends-history.png')});
 await page.keyboard.press('Escape');await expect(page.locator('#playerFriendsPanel')).toBeHidden();await expect(page.locator('#playerView')).toBeVisible();
});

test('offline shared members and own account retain their history entry',async({page,request},info)=>{
 await settings(page,request,{friendsSelf:true,friendsSelfOffline:true,friendsNoLive:true});
 await page.locator('#setFriendsVisible').check();await page.locator('[data-page="home"]').click();await page.locator('#btnBrowseFriends').click();
 await expect(page.locator('.friends-member')).toHaveCount(2);
 await expect(page.locator('.friends-watch')).toHaveCount(0);
 await expect(page.locator('.friends-member').nth(0)).toContainText('当前未在观看，可查看最近观看');
 await page.locator('.friends-member').nth(0).getByRole('button',{name:'最近观看'}).click();
 await expect(page.locator('#homeFriendsDialog .friends-content')).toContainText('我的最近观看');await expect(page.locator('.friends-watch')).toHaveCount(1);
 await page.locator('#friendsBack').click();await page.locator('.friends-member').nth(1).getByRole('button',{name:'最近观看'}).click();
 await expect(page.locator('#homeFriendsDialog .friends-content')).toContainText('Alice的最近观看');await expect(page.locator('.friends-watch')).toHaveCount(1);
 await page.screenshot({path:info.outputPath('offline-history.png')});
 await page.locator('#friendsBack').click();await patch(request,{friendsRevoked:true});await page.keyboard.press('Escape');await page.locator('#btnBrowseFriends').click();
 await expect(page.locator('.friends-member')).toHaveCount(1);
});
test('follow refreshes consent and starts correct episode at fresh progress with own playback session',async({page,request})=>{
 await playing(page,request);await page.getByRole('button',{name:'跟上进度',exact:true}).click();await expect(page.locator('#playerDialog')).toContainText('切换影片');await page.getByRole('button',{name:'开始播放',exact:true}).click();
 await expect.poll(async()=> (await state(request)).requests.filter(r=>r.path==='/playback/sessions').length).toBe(2);
 const requests=(await state(request)).requests;const playback=requests.filter(r=>r.path==='/playback/sessions').at(-1).body;
 expect(playback).toMatchObject({media_item_id:3,season_number:2,episode_number:3});expect(playback.start_ms).toBeGreaterThanOrEqual(120000);expect(playback.start_ms).toBeLessThan(130000);
 expect(requests.some(r=>r.path==='/plugins/watch-presence/members/7/play')).toBe(true);
});
test('from start explicitly sends zero and cancelled switch does not leave current film',async({page,request})=>{
 await playing(page,request);await page.getByRole('button',{name:'从头看',exact:true}).click();await page.getByRole('button',{name:'取消',exact:true}).click();expect((await state(request)).requests.filter(r=>r.path==='/playback/sessions')).toHaveLength(1);
 await page.getByRole('button',{name:'从头看',exact:true}).click();await page.getByRole('button',{name:'开始播放',exact:true}).click();
 await expect.poll(async()=> (await state(request)).requests.filter(r=>r.path==='/playback/sessions').length).toBe(2);
 expect((await state(request)).requests.filter(r=>r.path==='/playback/sessions').at(-1).body.start_ms).toBe(0);
});
test('revoked entry fails closed before switching player and account change rejects late result',async({page,request})=>{
 await playing(page,request);await patch(request,{friendsRevoked:true});await page.getByRole('button',{name:'跟上进度',exact:true}).click();await page.getByRole('button',{name:'开始播放',exact:true}).click();
 await expect(page.locator('.friends-content [role="alert"]')).toBeVisible();expect((await state(request)).requests.filter(r=>r.path==='/playback/sessions')).toHaveLength(1);
 await page.locator('#friendsClose').click();await patch(request,{friendsRevoked:false,friendsDelay:600});await page.locator('#btnPlayerFriends').click();await page.evaluate(()=>{App.session.username='other';DesktopFriends.dispose();});await page.waitForTimeout(800);await expect(page.locator('#playerFriendsPanel')).toBeHidden();await expect(page.locator('.friends-member')).toHaveCount(0);
});
test('unsupported plugin and failed privacy save show truthful state without disabling playback',async({page,request})=>{
 await settings(page,request,{friendsUnsupported:true});await expect(page.locator('#friendsPrivacyState')).toContainText('尚未安装');await expect(page.locator('#setFriendsShare')).toBeDisabled();
 await patch(request,{friendsUnsupported:false,friendsSaveError:true});await page.locator('[data-page="home"]').click();await page.locator('[data-page="settings"]').click();await expect(page.locator('#setFriendsShare')).toBeEnabled();
 await page.locator('#friendsLibraries input[value="1"]').check();await page.locator('#setFriendsShare').check();await page.locator('#saveFriendsPrivacy').click();await expect(page.locator('#friendsPrivacyState')).toContainText('未保存');await expect(page.locator('#setFriendsShare')).not.toBeChecked();
});
test('drawer fits narrow windows, names are escaped and closing stops polling and restores auto-hide',async({page,request})=>{
 await playing(page,request,{friendsXss:true});await expect(page.locator('.friends-member > header strong')).toHaveText('<img src=x onerror=alert(1)>');await expect(page.locator('.friends-content img')).toHaveCount(0);
 await page.setViewportSize({width:640,height:640});const box=await page.locator('#playerFriendsPanel').boundingBox();expect(box.x+box.width).toBeLessThanOrEqual(640);expect(box.y+box.height).toBeLessThanOrEqual(640);
 const count=(await state(request)).requests.filter(r=>r.path.endsWith('/watch-presence/members')).length;
 await page.locator('#friendsClose').click();await expect(page.locator('#playerControls')).toHaveCSS('opacity','0',{timeout:6000});await page.waitForTimeout(5200);
 expect((await state(request)).requests.filter(r=>r.path.endsWith('/watch-presence/members')).length).toBe(count);
});
test('picture in picture closes the friend drawer and cancels its refresh',async({page,request})=>{
 await playing(page,request);await expect.poll(()=>page.evaluate(()=>MovieClawPlatform.status?.active)).toBe(true);
 await page.evaluate(()=>Player.togglePip());await expect(page.locator('#playerView')).toHaveClass(/native-pip/);
 await expect(page.locator('#playerFriendsPanel')).toBeHidden();await expect(page.locator('.friends-member')).toHaveCount(0);
 const count=(await state(request)).requests.filter(r=>r.path.endsWith('/watch-presence/members')).length;
 await page.waitForTimeout(8500);expect((await state(request)).requests.filter(r=>r.path.endsWith('/watch-presence/members')).length).toBe(count);
});
