const { test, expect } = require('@playwright/test');
const { openDesktop, browseLibrary, state } = require('./helpers.cjs');

test('sidebar collapse keeps named navigation available and survives restart at narrow widths', async ({page,request}) => {
  await openDesktop(page, request);
  await expect(page.locator('#sidebar')).toBeVisible();
  await page.getByRole('button', {name:'收起侧边栏',exact:true}).click();
  await expect(page.getByRole('button', {name:'展开侧边栏',exact:true})).toHaveAttribute('aria-expanded','false');
  expect((await page.locator('#sidebar').boundingBox()).width).toBe(64);
  await page.getByRole('link',{name:'测试媒体库',exact:true}).click();
  await expect(page.locator('#posterGrid .poster-card')).toHaveCount(60);
  await page.reload();
  await expect(page.getByRole('button',{name:'展开侧边栏',exact:true})).toBeVisible();
  await page.setViewportSize({width:800,height:700});
  expect((await page.locator('#sidebar').boundingBox()).width).toBe(64);
  await page.getByRole('button',{name:'搜索',exact:true}).click();
  await expect(page.locator('#searchInput')).toBeFocused();
  expect((await page.locator('#sidebar').boundingBox()).width).toBe(190);
  await expect(page.locator('[data-page="home"] span')).toBeVisible();
  await page.locator('#searchInput').fill('测试');
  await expect(page.locator('.page-title')).toContainText('搜索结果');
  await page.getByRole('button',{name:'收起侧边栏',exact:true}).click();
  await page.keyboard.press('Control+f');
  await expect(page.locator('#searchInput')).toBeFocused();
  await expect(page.locator('#searchInput')).toHaveValue('测试');
});

test('about exposes local build identity, attribution and selectable inert license text from settings and account', async ({page,request}) => {
  await openDesktop(page, request); await page.locator('[data-page="settings"]').click();
  await page.getByRole('button',{name:'开源许可与数据来源'}).click();
  const dialog=page.getByRole('dialog',{name:'关于 MovieClaw'});
  await expect(dialog).toContainText('版本 1.0.0 · 构建 aaaaaaaa');
  await expect(dialog).toContainText('未经 TMDB 认可或认证');
  await dialog.locator('summary').click(); await expect(dialog.locator('pre')).toContainText('GNU GENERAL PUBLIC LICENSE');
  await expect(dialog.locator('pre img')).toHaveCount(0);
  await expect(dialog).toHaveCSS('user-select','text');
  const bounds=await dialog.boundingBox(), viewport=page.viewportSize();
  expect(Math.abs(bounds.x+bounds.width/2-viewport.width/2)).toBeLessThan(2);
  expect(Math.abs(bounds.y+bounds.height/2-viewport.height/2)).toBeLessThan(2);
  await page.keyboard.press('Escape'); await expect(dialog).toHaveCount(0);
  await page.locator('#accountButton').click(); await page.getByRole('button',{name:'关于 MovieClaw',exact:true}).click();
  await expect(dialog).toBeVisible(); await page.getByRole('button',{name:'关闭关于',exact:true}).click();
  await expect(dialog).toHaveCount(0);
});

test('episode selection preserves decoded authenticated stills and hides pending broken images', async ({page,request}) => {
  await openDesktop(page,request,{episodeImages:true}); await browseLibrary(page);
  await page.locator('.poster-card[data-item-id="3"]').click();
  const first=page.locator('.episode-card[data-episode-number="1"] .episode-art img');
  await expect(first).toHaveClass(/loaded/); await expect(first).toHaveCSS('opacity','1');
  await page.evaluate(()=>window.stillBefore=document.querySelector('.episode-card[data-episode-number="1"] img'));
  const before=(await state(request)).imageRequests.length;
  await page.locator('.episode-card[data-episode-number="1"]').click();
  await expect(page.locator('.detail-episode-line')).toContainText('第 1 集');
  expect(await page.evaluate(()=>window.stillBefore===document.querySelector('.episode-card[data-episode-number="1"] img'))).toBe(true);
  expect((await state(request)).imageRequests.length).toBe(before);
  await page.evaluate(()=>{const img=document.createElement('img');img.dataset.raw='/missing';img.src='/api/v1/fixture-images/missing.png';document.querySelector('.episode-art').appendChild(img);});
  await expect(page.locator('.episode-art img[data-raw="/missing"]')).toHaveCSS('opacity','0');
});

test('dark dropdowns keep labels separate from icons and support keyboard selection and dismissal', async ({page,request}) => {
  await openDesktop(page,request); await browseLibrary(page);
  const sort=page.getByRole('combobox',{name:'排序',exact:true});
  await sort.click();
  const menu=page.getByRole('listbox',{name:'排序',exact:true});
  await expect(menu).toBeVisible(); await expect(sort).toHaveAttribute('aria-expanded','true');
  const colors=await menu.evaluate(el=>({bg:getComputedStyle(el).backgroundColor,fg:getComputedStyle(el).color}));
  expect(colors.bg).toMatch(/rgba?\(37, 39, 46/); expect(colors.fg).toBe('rgb(243, 245, 249)');
  const row=page.getByRole('option',{name:'最近添加',exact:true});
  const label=await row.locator('span').boundingBox(), icon=await row.locator('svg').boundingBox();
  expect(icon.x).toBeGreaterThan(label.x+label.width);
  await page.keyboard.press('Escape'); await expect(menu).toBeHidden(); await expect(sort).toBeFocused();
  await page.keyboard.press('ArrowDown'); await page.keyboard.press('End'); await page.keyboard.press('Enter');
  await expect(sort).toHaveText('片名'); await expect(sort).toBeFocused();
  await sort.click(); await page.locator('.page-title').click(); await expect(menu).toBeHidden();
  await page.locator('[data-page="settings"]').click();
  const language=page.getByRole('combobox',{name:'默认字幕语言',exact:true});
  await language.click(); await page.getByRole('option',{name:'English',exact:true}).click();
  expect(await page.evaluate(()=>localStorage.getItem('mc_subLang'))).toBe('en');
});

test('home library covers use authenticated images and hide their type placeholder after decoding', async ({page,request}) => {
  await openDesktop(page,request,{libraryCovers:'protected'});
  const cover=page.locator('.library-tile[data-open-library="1"] .library-cover');
  await cover.scrollIntoViewIfNeeded();
  await expect(cover.locator('img')).toHaveAttribute('src',/^data:image\/png/);
  await expect(cover).toHaveClass(/has-img/);
  await expect(cover.locator('img')).toHaveCSS('opacity','1');
  expect(await cover.locator('img').evaluate(img=>img.naturalWidth)).toBeGreaterThan(0);
  await expect(cover.locator('.library-placeholder')).toBeHidden();
});

test('unavailable movie and TV covers retain visible type icons and library navigation', async ({page,request},info) => {
  await openDesktop(page,request,{homeRows:[{id:'row:selected',collection_id:8}],libraries:[
    {id:1,name:'电影库',kind:'movie',stats:{item_count:245}},
    {id:2,name:'剧集库',kind:'tv',stats:{item_count:0}},
  ]});
  for (const id of [1,2]) {
    const cover=page.locator(`.library-tile[data-open-library="${id}"] .library-cover`);
    await cover.scrollIntoViewIfNeeded();
    await expect(cover).toHaveClass(/no-img/);
    await expect(cover.locator('.library-placeholder')).toBeVisible();
    await expect(cover.locator('.library-placeholder svg')).toBeVisible();
    await expect(cover.locator('img')).toBeHidden();
  }
  const collection=page.locator('.collection-tile .library-cover');
  await expect(collection.locator('.library-placeholder svg')).toBeVisible();
  await expect(collection.locator('img')).toHaveCount(0);
  await page.locator('[data-home-row="libraries"]').screenshot({path:info.outputPath('library-icons.png')});
  await page.locator('.library-tile[data-open-library="1"]').click();
  await expect(page.locator('#posterGrid .poster-card').first()).toBeVisible();
});

test('library header shows its actual total and keeps sort controls beside the heading', async ({page,request}) => {
  await openDesktop(page,request,{itemCount:3102});
  await browseLibrary(page);
  await expect(page.locator('#wallCount')).toHaveText('3102 个项目');
  const title=await page.locator('.page-title').boundingBox();
  const sort=await page.locator('#wallSortTrigger').boundingBox();
  expect(Math.abs(sort.y-title.y)).toBeLessThan(20);
});

test('person page opened by keyboard identifies the current movie and returns to its existing detail', async ({page,request}) => {
  await openDesktop(page,request,{images:true,marksDelay:1200});
  await browseLibrary(page);
  await page.locator('#posterGrid [data-item-id="3"]').click();
  const actor=page.locator('.person-card[data-person-id="9"]');
  await actor.focus();
  await page.keyboard.press('Enter');
  await expect(page.locator('.person-name')).toHaveText('测试演员');
  await expect(page.locator('.person-backdrop img')).toBeVisible();
  const current=page.locator('.person-works [data-item-id="3"]');
  await expect(current.locator('.series-badge')).toHaveText('本片');
  await current.click();
  await expect(page.locator('#btnPlay')).toBeVisible();
  await expect(page.locator('.person-name')).toHaveCount(0);
  expect(await page.evaluate(()=>App.navStack.length)).toBe(1);
});

test('selecting a TV episode scrolls its shelf without shifting the detail body or page', async ({page,request}) => {
  await openDesktop(page,request,{images:true});
  await browseLibrary(page);
  await page.locator('#posterGrid [data-item-id="3"]').click();
  await expect(page.locator('#btnPlay')).toBeVisible();
  await page.locator('.episode-card[data-episode-number="2"]').click();
  await expect(page.locator('.episode-card.stage')).toHaveAttribute('data-episode-number','2');
  expect(await page.locator('.detail-body').evaluate(el=>el.scrollLeft)).toBe(0);
  expect(await page.locator('#content').evaluate(el=>el.scrollLeft)).toBe(0);
  const content=await page.locator('#content').boundingBox();
  const cast=await page.locator('.cast-row').boundingBox();
  expect(cast.x-content.x).toBe(32);
});

for (const viewport of [{width:1280,height:800},{width:1440,height:900},{width:900,height:650}]) {
  test(`browsing layout, focus and reduced motion at ${viewport.width}x${viewport.height}`, async ({page,request},info) => {
    await page.setViewportSize(viewport);
    await page.emulateMedia({reducedMotion:'reduce'});
    const errors=[]; page.on('pageerror',error=>errors.push(error.message));
    await openDesktop(page,request,{searchPeople:true,homeRows:[{id:'row:collection',collection_id:8,name:'我的精选'}]});
    const shot=async name=>{
      const filename=info.outputPath(name+'.png'); await page.screenshot({path:filename});
      await info.attach(name,{path:filename,contentType:'image/png'});
    };
    await expect(page.locator('#heroBanner')).toBeVisible();
    const hero=await page.locator('#heroBanner').boundingBox();
    const content=await page.locator('#content').boundingBox();
    expect(Math.abs(hero.width-content.width)).toBeLessThanOrEqual(1);
    expect(hero.height).toBeGreaterThanOrEqual(420);
    expect(await page.locator('#content').evaluate(el=>el.scrollWidth<=el.clientWidth+1)).toBe(true);
    await shot('home');
    await page.locator('#accountButton').click(); await expect(page.locator('#accountPanel')).toBeVisible();
    const panel=await page.locator('#accountPanel').boundingBox(); expect(panel.x).toBeGreaterThanOrEqual(0); expect(panel.x+panel.width).toBeLessThanOrEqual(viewport.width);
    await shot('account-panel'); await page.keyboard.press('Escape');
    await browseLibrary(page);
    await page.keyboard.press('Tab');
    await page.locator('#posterGrid .poster-card').first().focus();
    const focusStyle=await page.locator('#posterGrid .poster-card').first().evaluate(el=>{
      const style=getComputedStyle(el); return {width:parseFloat(style.outlineWidth),style:style.outlineStyle};
    });
    expect(focusStyle.width).toBeGreaterThanOrEqual(2); expect(focusStyle.style).not.toBe('none');
    await shot('library-focus');
    await page.locator('#posterGrid .poster-card').first().hover(); await shot('card-hover');
    await page.locator('#posterGrid .poster-card').first().click(); await expect(page.locator('#btnPlay')).toBeVisible();
    const detail=await page.locator('.detail-hero').boundingBox();
    expect(Math.abs(detail.width-content.width)).toBeLessThanOrEqual(1);
    await expect(page.locator('.detail-body')).toHaveCSS('padding-left','32px');
    await expect(page.locator('.person-card-avatar').first()).toHaveCSS('border-radius','50%');
    expect(await page.locator('.detail-hero-bg img').first().evaluate(el=>getComputedStyle(el).animationName)).toBe('none');
    await shot('detail');
    await page.locator('#searchInput').fill('演员'); await expect(page.locator('[data-search-person="9"]')).toBeVisible(); await shot('search');
    expect(await page.locator('#content').evaluate(el=>el.scrollWidth<=el.clientWidth+1)).toBe(true);
    expect(errors).toEqual([]);
  });
}

test('search waiting, failure retry and empty states remain visible and usable', async ({page,request},info) => {
  await page.setViewportSize({width:1280,height:800});
  await openDesktop(page,request);
  let release;
  const gate=new Promise(resolve=>{release=resolve;});
  let fail=true;
  await page.route('**/api/v1/search/library?**',async route=>{
    await gate;
    await route.fulfill({status:fail?503:200,contentType:'application/json',body:JSON.stringify(fail
      ?{code:'LIBRARY_UNAVAILABLE',message:'媒体索引暂不可用，请重试'}
      :{code:0,message:'ok',data:{query:'空结果',items:[],people:[],suggestions:[],next_cursor:null}})});
  });
  const shot=async name=>{
    const filename=info.outputPath(name+'.png'); await page.screenshot({path:filename});
    await info.attach(name,{path:filename,contentType:'image/png'});
  };
  try {
    await page.locator('#searchInput').fill('空结果');
    await expect(page.locator('#wallStatus')).toHaveText('加载中…'); await shot('search-waiting');
    release();
    await expect(page.locator('#wallStatus')).toContainText('媒体索引暂不可用');
    await expect(page.locator('#wallStatus button')).toHaveText('重试'); await shot('search-failed');
    fail=false; await page.locator('#wallStatus button').click();
    await expect(page.locator('#wallStatus')).toHaveText('这里还没有内容');
    await expect(page.locator('#posterGrid .poster-card')).toHaveCount(0); await shot('search-empty');
    expect(await page.locator('#content').evaluate(el=>el.scrollWidth<=el.clientWidth+1)).toBe(true);
  } finally { release(); }
});

test('playback preferences have accessible names, visible keyboard focus and persistent values', async ({page,request}) => {
  await openDesktop(page,request);
  await page.locator('[data-page="settings"]').click();
  await page.keyboard.press('Tab');
  const preferences=[
    ['自动播放下一集','mc_autoNext','0'],
    ['硬件解码','mc_hwDecode','0'],
    ['播放时置顶','mc_alwaysOnTop','false'],
    ['窗口贴合画面','mc_fitWindow','false'],
  ];
  for (const [name,key,value] of preferences) {
    const checkbox=page.getByRole('checkbox',{name,exact:true});
    await expect(checkbox).toBeChecked();
    await checkbox.focus();
    const focus=await checkbox.evaluate(input=>{
      const style=getComputedStyle(input.nextElementSibling);
      return {width:parseFloat(style.outlineWidth),style:style.outlineStyle};
    });
    expect(focus.width).toBeGreaterThanOrEqual(2); expect(focus.style).not.toBe('none');
    await page.keyboard.press('Space');
    await expect(checkbox).not.toBeChecked();
    expect(await page.evaluate(key=>localStorage.getItem(key),key)).toBe(value);
  }
  await page.locator('[data-page="home"]').click();
  await page.locator('[data-page="settings"]').click();
  for (const [name] of preferences) await expect(page.getByRole('checkbox',{name,exact:true})).not.toBeChecked();
});

test('strict CSP preserves authenticated images, logo fallback and the person back button', async ({page,request}) => {
  const documentResponse=await request.get('/desktop/index.html');
  expect(documentResponse.headers()['content-security-policy']).toContain("script-src-attr 'none'");
  await page.addInitScript(()=>{
    window.__imageCspViolations=[];
    document.addEventListener('securitypolicyviolation',event=>window.__imageCspViolations.push(event.effectiveDirective));
  });
  await openDesktop(page,request,{images:true});
  await expect(page.locator('#heroIdentity .hero-title')).toBeVisible();
  await browseLibrary(page);
  const poster=page.locator('#posterGrid .poster-card').first().locator('img');
  await expect(poster).toHaveAttribute('src',/^data:image\/png/);
  await expect(poster).toHaveCSS('opacity','1');
  expect(await poster.evaluate(img=>img.naturalWidth)).toBeGreaterThan(0);
  await page.locator('#posterGrid .poster-card').first().click();
  await expect(page.locator('.detail-hero-bg img')).toHaveCSS('opacity','1');
  expect(await page.locator('.detail-hero-bg img').evaluate(img=>img.naturalWidth)).toBeGreaterThan(0);
  await expect(page.locator('#detailTitleFallback')).toBeVisible();
  await expect(page.locator('.detail-logo')).toBeHidden();
  await page.locator('.person-card[data-person-id="9"]').click();
  await expect(page.locator('.person-avatar')).toHaveCSS('opacity','1');
  expect(await page.locator('.person-avatar').evaluate(img=>img.naturalWidth)).toBeGreaterThan(0);
  await page.locator('#personBack').click();
  await expect(page.locator('#btnPlay')).toBeVisible();
  expect(await page.locator('[onload],[onerror],[onclick]').count()).toBe(0);
  expect(await page.evaluate(()=>window.__imageCspViolations)).toEqual([]);
});

for (const width of [1280, 900, 640]) {
  test(`settings groups align and remain usable at ${width}px`, async ({page,request},info) => {
    await page.setViewportSize({width,height:900});
    await openDesktop(page,request);
    if (width===640) await page.getByRole('button',{name:'收起侧边栏',exact:true}).click();
    await page.locator('[data-page="settings"]').click();
    await expect(page.locator('#accountList .settings-row')).toHaveCount(2);
    const cards=page.locator('.settings-body > .settings-card');
    await expect(cards).toHaveCount(5);
    const [playback,server,accounts,navigation,about]=await Promise.all([0,1,2,3,4].map(i=>cards.nth(i).boundingBox()));
    const content=await page.locator('#content').boundingBox();
    expect(Math.abs(playback.x-content.x-(content.x+content.width-playback.x-playback.width))).toBeLessThanOrEqual(1);
    expect(Math.abs(server.width-accounts.width)).toBeLessThanOrEqual(1);
    if (width===1280) {
      expect(server.y).toBe(accounts.y);
      const actions=await Promise.all([1,2].map(i=>cards.nth(i).locator('.settings-actions').boundingBox()));
      expect(Math.abs(actions[0].y-actions[1].y)).toBeLessThanOrEqual(1);
    } else {
      expect(accounts.y).toBeGreaterThan(server.y+server.height);
    }
    expect(about.y).toBeGreaterThan(accounts.y+accounts.height);
    expect(navigation.width).toBe(playback.width);
    expect(about.y).toBeGreaterThan(navigation.y+navigation.height);
    const sub=await page.locator('#setSubLangTrigger').boundingBox();
    const audio=await page.locator('#setAudioLangTrigger').boundingBox();
    expect(sub.width).toBe(audio.width);
    await page.getByRole('combobox',{name:'默认音轨语言',exact:true}).click();
    await page.getByRole('option',{name:'English',exact:true}).click();
    expect(await page.evaluate(()=>localStorage.getItem('mc_audioLang'))).toBe('en');
    // A saved server address or account name must wrap rather than push controls out.
    await page.locator('.settings-row > .settings-value').evaluate(el=>el.textContent='https://'+ 'server-name-'.repeat(12)+'.example.com:3000');
    await page.locator('#accountList .settings-row > span').first().evaluate(el=>el.textContent='account-name-'.repeat(12));
    for (const button of await page.locator('.settings-page button').all()) {
      await button.scrollIntoViewIfNeeded();
      const box=await button.boundingBox();
      expect(box.x).toBeGreaterThanOrEqual(content.x);
      expect(box.x+box.width).toBeLessThanOrEqual(content.x+content.width);
    }
    expect(await page.locator('#content').evaluate(el=>el.scrollWidth<=el.clientWidth+1)).toBe(true);
    await page.locator('.settings-row > .settings-value').evaluate(el=>el.textContent='http://nas.local:3000');
    await page.locator('#accountList .settings-row > span').first().evaluate(el=>el.textContent='当前账号');
    await page.locator('#content').evaluate(el=>el.scrollTop=0);
    await page.screenshot({path:info.outputPath('settings.png')});
  });
}
