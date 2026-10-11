const {test,expect}=require('@playwright/test');
const {openDesktop,state}=require('./helpers.cjs');
async function choose(page,id,name){await page.locator('#'+id+'Trigger').click();await page.getByRole('option',{name,exact:true}).click();}
async function setup(page,request,options={}){
 await openDesktop(page,request,{catalog:true,...options});
 await expect.poll(()=>page.evaluate(()=>!!App.session && !App._authPending)).toBe(true);
 await page.locator('[data-page="settings"]').click();
 await expect(page.getByLabel('显示发现',{exact:true})).toBeVisible();
}
async function enable(page,key){await page.getByLabel('显示'+key,{exact:true}).check();}
async function discover(page,request,options={}){await setup(page,request,options);await enable(page,'发现');await page.locator('#catalogNav [data-page="discover"]').click();await expect(page.locator('.catalog-card')).toHaveCount(2);}
async function subs(page,request,options={}){await setup(page,request,options);await enable(page,'我的订阅');await page.locator('#catalogNav [data-page="subscriptions"]').click();await expect(page.locator('.catalog-subscription')).toHaveCount(1);}
async function inspector(page,request,options={}){await subs(page,request,options);await page.locator('.catalog-subscription').click();await expect(page.locator('#subscriptionUnits .catalog-unit')).toHaveCount(4);}
async function newSub(page,request,options={}){await discover(page,request,options);await page.getByLabel('搜索影视',{exact:true}).fill('新作品');await page.locator('#discoverSearch button').click();await page.locator('[data-subscribe-ref]').click();await expect(page.locator('#subscriptionCreateForm')).toBeVisible();}

test('both new entries default off, persist independently and are scoped to server and account',async({page,request})=>{
 await setup(page,request);await expect(page.locator('#catalogNav')).toBeHidden();
 expect((await state(request)).requests.some(r=>/^\/(subscriptions|discover|ui\/discovery)/.test(r.path))).toBe(false);
 await enable(page,'发现');await page.reload();await expect(page.locator('#catalogNav [data-page="discover"]')).toBeVisible();await expect(page.locator('#catalogNav [data-page="subscriptions"]')).toHaveCount(0);
 expect(await page.evaluate(()=>{App.session.username='another';return DesktopCatalog.enabled('discover');})).toBe(false);
 expect(await page.evaluate(()=>{App.session.username='fixture';API.baseUrl='https://other.invalid';return DesktopCatalog.enabled('discover');})).toBe(false);
});
test('discovery browses collections, title credits, person filmography and returns to desktop library',async({page,request})=>{
 await discover(page,request);await page.getByRole('button',{name:'查看全部',exact:true}).click();await expect(page.locator('.catalog-grid .catalog-card')).toHaveCount(2);
 await page.locator('#catalogNext').click();await expect.poll(async()=> (await state(request)).requests.filter(r=>r.path.startsWith('/discover/collections/')).at(-1).query.page).toBe('2');
 await page.getByRole('button',{name:'星海旅程',exact:true}).click();await expect(page.locator('.catalog-title-detail')).toContainText('星海旅程');
 await page.locator('[data-person="89"]').click();await expect(page.locator('.catalog-page h1')).toHaveText('探索演员');
 await page.locator('#catalogBack').click();await page.locator('[data-library-link]').click();await expect(page.locator('#btnPlay')).toBeVisible();
});
test('search uses discovery API rather than local library, supports provider and filters with multiple genres',async({page,request})=>{
 await discover(page,request);await choose(page,'discoverProvider','豆瓣');await page.getByLabel('搜索影视',{exact:true}).fill('新作品');await page.locator('#discoverSearch button').click();await expect(page.locator('.catalog-card')).toHaveCount(1);
 expect((await state(request)).requests.find(r=>r.path==='/search/titles').body).toEqual({query:'新作品',provider:'douban',save_history:false});
 await choose(page,'discoverProvider','TMDB');await page.locator('#discoverFilters').click();await page.getByLabel('剧情',{exact:true}).check();await page.getByLabel('动作',{exact:true}).check();await choose(page,'filterSort','最多评分');await page.getByRole('button',{name:'查看结果',exact:true}).click();
 await expect(page.locator('#clearFilters')).toBeVisible();expect((await state(request)).requests.find(r=>r.path==='/discover/titles').query.sort).toBe('most-rated');
});
test('disabled subscription entry still allows inspecting existing subscription from discovery',async({page,request})=>{
 await discover(page,request);await page.locator('[data-subscription="7"]').click();await expect(page.locator('.catalog-dialog')).toContainText('55%');await expect(page.locator('.catalog-dialog')).toContainText('等待入库');await expect(page.locator('#catalogNav [data-page="subscriptions"]')).toHaveCount(0);
});
test('subscriptions preserve filters, show weekly schedule and distinct download versus import statuses',async({page,request})=>{
 await subs(page,request);await expect(page.locator('[data-download-summary]')).toContainText('55%');await expect(page.locator('#subscriptionSchedule')).toContainText('S1E4');await page.getByLabel('搜索订阅').fill('不存在');await expect(page.locator('.catalog-subscription')).toHaveCount(0);await page.getByLabel('搜索订阅').fill('星海');await choose(page,'subscriptionView','海报');await expect(page.locator('.catalog-subscription-poster')).toHaveCount(1);await page.locator('.catalog-subscription').click();await expect(page.locator('#subscriptionUnits')).toContainText('等待入库');await expect(page.locator('#subscriptionUnits')).toContainText('55%');await expect(page.locator('#subscriptionUnits')).toContainText('2.0 MB/s');
});
test('recent arrival plays the actual first-unwatched season and episode, not the first batch unit',async({page,request})=>{
 await subs(page,request);await page.locator('[data-recent]').click();await expect(page.locator('#playerView')).toBeVisible();expect((await state(request)).requests.find(r=>r.path==='/playback/sessions').body).toMatchObject({media_item_id:3,season_number:3,episode_number:2});
});
test('create smart subscription sends stable ref and profile revision exactly once',async({page,request})=>{
 await newSub(page,request,{catalogCreateDelay:400});await page.getByRole('button',{name:'确认订阅',exact:true}).click();await expect(page.getByRole('button',{name:'确认订阅',exact:true})).toBeDisabled();await expect(page.locator('.catalog-dialog')).toHaveCount(0);
 const writes=(await state(request)).requests.filter(r=>r.path==='/subscriptions' && r.method==='POST');expect(writes).toHaveLength(1);expect(writes[0].body).toMatchObject({title_ref:'tmdb:tv:44',selection_mode:'smart',smart_profile_revision:3,rule_set_id:null,selected_seasons:[1]});
});
test('server without smart profile falls back to rules and mutation errors preserve form',async({page,request})=>{
 await newSub(page,request,{catalogLegacySmart:true,catalogCreateError:true});await expect(page.locator('#subscribeModeTrigger')).toContainText('规则选择');await page.getByRole('button',{name:'确认订阅',exact:true}).click();await expect(page.locator('.catalog-dialog [role="alert"]')).toContainText('智能偏好已改变');await expect(page.getByRole('button',{name:'确认订阅',exact:true})).toBeEnabled();
 const body=(await state(request)).requests.find(r=>r.path==='/subscriptions' && r.method==='POST').body;expect(body.selection_mode).toBe('rules');expect(body).not.toHaveProperty('smart_profile_revision');
});
test('closing a submitted dialog ignores late UI result and retains current page',async({page,request})=>{
 await newSub(page,request,{catalogCreateDelay:800});await page.getByRole('button',{name:'确认订阅',exact:true}).click();await page.locator('.catalog-dialog header button').click();await page.waitForTimeout(1000);await expect(page.locator('.catalog-page h1')).toHaveText('发现');await expect(page.locator('.catalog-dialog')).toHaveCount(0);
});
test('pause and resume reflect actual server state',async({page,request})=>{
 await inspector(page,request);await page.locator('#subscriptionTracking').click();await expect(page.locator('#subscriptionTracking')).toHaveText('恢复追踪');await expect(page.locator('.catalog-inspector-heading')).toContainText('已暂停');await page.locator('#subscriptionTracking').click();await expect(page.locator('#subscriptionTracking')).toHaveText('暂停追踪');
});
test('adjust includes new seasons and sends numeric episode floors',async({page,request})=>{
 await inspector(page,request);await page.locator('#subscriptionAdjust').click();await expect(page.locator('[name="adjustSeason"]')).toHaveCount(3);await page.locator('[name="adjustSeason"][value="2"]').check();await page.getByLabel('第 2 季集数下限').fill('8');await page.getByRole('button',{name:'保存调整',exact:true}).click();await expect(page.locator('.catalog-dialog')).toHaveCount(0);expect((await state(request)).requests.find(r=>r.method==='PATCH' && r.path==='/subscriptions/7').body).toMatchObject({selected_seasons:[1,2],episode_floors:{2:8}});
});
test('manual selection preserves torrent identity and parsed attributes with confirmation',async({page,request})=>{
 await inspector(page,request);await page.locator('#subscriptionGrab').click();await page.getByRole('button',{name:'搜索资源',exact:true}).click();await page.getByRole('button',{name:'选择此资源',exact:true}).click();await expect(page.locator('.catalog-dialog')).toContainText('确认投递资源');await page.getByRole('button',{name:'确认',exact:true}).click();await expect(page.locator('.catalog-dialog')).toHaveCount(0);
 const rows=(await state(request)).requests;expect(rows.find(r=>r.path==='/search/torrents').query).toMatchObject({categories:'tv',no_history:'true'});expect(rows.find(r=>r.path.endsWith('/selected-torrent-downloads')).body).toMatchObject({torrent_id:'torrent-1',attrs:{resolution:'2160p'},seeders:12});
});
test('permanent removal previews H&R and cross-season retention, deletion flags default false',async({page,request})=>{
 await inspector(page,request);await page.locator('#subscriptionRemove').click();await expect(page.locator('.catalog-dialog')).toContainText('H&R');await expect(page.locator('.catalog-dialog')).toContainText('跨季包');await expect(page.locator('#removeTorrents')).not.toBeChecked();await expect(page.locator('#removeFiles')).not.toBeChecked();await page.getByRole('button',{name:'确认',exact:true}).click();await expect(page.locator('.catalog-subscription')).toHaveCount(0);expect((await state(request)).requests.find(r=>r.method==='DELETE' && r.path==='/subscriptions/7').query).toEqual({delete_torrents:'false',delete_library_files:'false'});
});
test('read-only member sees progress without admin and owner actions',async({page,request})=>{
 await inspector(page,request,{role:'member',capabilities:{allow_subscribe:true},catalogReadOnly:true});await expect(page.locator('#subscriptionAdjust')).toHaveCount(0);await expect(page.locator('#subscriptionGrab')).toHaveCount(0);await expect(page.locator('#subscriptionRemove')).toHaveCount(0);await expect(page.locator('#subscriptionUnfollow')).toBeVisible();
});
test('account without subscribe permission cannot enable entry or subscribe discovery titles',async({page,request})=>{
 await setup(page,request,{role:'member'});await expect(page.getByLabel('显示我的订阅',{exact:true})).toBeDisabled();await enable(page,'发现');await page.locator('#catalogNav [data-page="discover"]').click();await expect(page.locator('.catalog-card')).toHaveCount(2);await expect(page.locator('[data-subscribe-ref]')).toHaveCount(0);expect((await state(request)).requests.some(r=>r.path==='/subscriptions')).toBe(false);
});
test('unsupported server displays error without silent successful empty state',async({page,request})=>{
 await setup(page,request,{catalogUnsupported:true});await enable(page,'我的订阅');await page.locator('#catalogNav [data-page="subscriptions"]').click();await expect(page.locator('.catalog-error')).toContainText('服务器暂不支持此功能');
});
test('leaving a delayed discovery request cannot replace home and aborts the request',async({page,request})=>{
 await setup(page,request,{catalogDelay:900});await enable(page,'发现');await page.locator('#catalogNav [data-page="discover"]').click();await page.locator('[data-page="home"]').click();await page.waitForTimeout(1100);await expect(page.locator('.catalog-page')).toHaveCount(0);expect(await page.evaluate(()=>App.currentPage)).toBe('home');
});
test('smart preferences and admin rule editor save structured settings',async({page,request})=>{
 await newSub(page,request);await page.locator('#subscribeSmart').click();await page.locator('#smartWait').fill('90');await page.getByRole('button',{name:'保存偏好',exact:true}).click();await expect(page.locator('#subscriptionCreateForm')).toBeVisible();expect((await state(request)).requests.find(r=>r.method==='PUT' && r.path.includes('smart-profiles')).body.preferences.wait_seconds).toBe(5400);
 await page.locator('#subscribeRules').click();await page.locator('#createRule').click();await page.locator('#ruleName').fill('桌面追剧');await page.getByLabel('2160p',{exact:true}).check();await page.getByRole('button',{name:'保存规则组',exact:true}).click();await expect(page.locator('.catalog-rule')).toHaveCount(2);expect((await state(request)).requests.find(r=>r.method==='POST' && r.path==='/rule-sets').body).toMatchObject({name:'桌面追剧',spec:{resolutions:['2160p']}});
});
test('desktop pages and dialogs fit narrow and wide windows with centered controls',async({page,request})=>{
 await inspector(page,request);for(const width of [640,900,1280]){await page.setViewportSize({width,height:800});expect(await page.locator('#subscriptionInspector').evaluate(el=>el.scrollWidth<=el.clientWidth+1)).toBe(true);}
 await page.locator('#subscriptionAdjust').click();const box=await page.locator('.catalog-dialog').boundingBox();expect(Math.abs(box.x+box.width/2-page.viewportSize().width/2)).toBeLessThan(2);
});

test('health lists root causes and opens the configured server repair page',async({page,request})=>{
 await subs(page,request);await page.locator('#catalogHealth').click();await expect(page.locator('.catalog-dialog')).toContainText('路径映射待配置');await page.locator('.catalog-dialog details').first().locator('summary').click();await page.locator('[data-repair]').first().click();expect(await page.evaluate(()=>window.__fixture.calls.filter(c=>c.command==='open_catalog_link').at(-1).args.url)).toBe('http://127.0.0.1:4179/settings/downloaders');
});
test('unfollow does not permanently remove subscription or delete downloaded resources',async({page,request})=>{
 await inspector(page,request,{role:'member',capabilities:{allow_subscribe:true},catalogReadOnly:false});await page.locator('#subscriptionUnfollow').click();await expect(page.locator('.catalog-dialog')).toContainText('不影响其他关注者');await page.getByRole('button',{name:'确认',exact:true}).click();await expect(page.locator('.catalog-dialog')).toHaveCount(0);const deletes=(await state(request)).requests.filter(r=>r.method==='DELETE');expect(deletes.map(r=>r.path)).toEqual(['/subscriptions/7/following']);
});
test('polling refreshes downloaded progress but stops after leaving the page',async({page,request})=>{
 await page.clock.install();await inspector(page,request);const before=(await state(request)).requests.filter(r=>r.path==='/subscriptions/7/active-downloads').length;await page.clock.runFor(5100);await expect.poll(async()=> (await state(request)).requests.filter(r=>r.path==='/subscriptions/7/active-downloads').length).toBeGreaterThan(before);
 await page.locator('[data-page="home"]').click();const count=(await state(request)).requests.filter(r=>r.path.startsWith('/subscriptions')).length;await page.clock.runFor(35000);expect((await state(request)).requests.filter(r=>r.path.startsWith('/subscriptions')).length).toBe(count);
});
test('completed download snapshot does not show a stale ETA or claim media has imported',async({page,request})=>{
 await inspector(page,request,{catalogDownloadComplete:true});const row=page.locator('.catalog-unit').nth(1);await expect(row).toContainText('下载已完成 · 待入库确认');await expect(row).not.toContainText('预计');await expect(row).not.toContainText('已入库');
});
