const { test, expect } = require('@playwright/test');
const { openDesktop, state } = require('./helpers.cjs');

async function updates(page, request, options = {}) {
  await openDesktop(page, request, { updater: true, ...options });
  await expect.poll(()=>page.evaluate(()=>!!App.session && !App._authPending)).toBe(true);
  await page.locator('[data-page="settings"]').click();
  await page.locator('#btnCheckUpdates').click();
  await expect(page.locator('#desktopUpdateDialog')).toBeVisible();
}
async function screenshot(page, info, name) {
  const filename=info.outputPath(name+'.png'); await page.screenshot({path:filename});
  await info.attach(name,{path:filename,contentType:'image/png'});
}

test('startup and tray update events supply a downloadable version through legacy field names', async ({page,request}) => {
  await openDesktop(page,request,{updater:true,updateSameVersion:true});
  await page.evaluate(()=>window.__fixture.emit('update_available',{version:'desktop-v1.0.0',current:'1.0.0',message:'发现同版本新构建'}));
  await expect(page.locator('#desktopUpdateDialog')).toBeVisible();
  await expect(page.locator('.update-versions')).toHaveText('当前 1.0.0 · 最新 1.0.0');
  await page.locator('#updateDownload').click();
  await expect(page.locator('#updateInstall')).toBeVisible();
  expect((await state(request)).updateRequests.find(value=>value.command==='download_update').args).toEqual({version:'desktop-v1.0.0'});
});

test('a newer build of 1.0.0 is downloadable while current and failed checks stay distinct', async ({page,request}) => {
  await updates(page,request,{updateSameVersion:true});
  await expect(page.locator('#desktopUpdateMessage')).toContainText('1.0.0 的新构建 bbbbbbbb');
  await page.locator('#updateDownload').click(); await expect(page.locator('#updateInstall')).toBeVisible();
  expect((await state(request)).updateRequests.find(value=>value.command==='download_update').args).toEqual({version:'desktop-v1.0.0'});
  await page.locator('#updateClose').click();
  await updates(page,request,{updateCurrent:true,updateNotes:'<!-- desktop-release-policy: ci-verified -->\n\n# MovieClaw Windows 1.0.0\n\n- **安装版**：下载 `Setup.exe`。\n[使用说明](https://example.com)'});
  await expect(page.locator('#desktopUpdateMessage')).toContainText('已是最新版本 (1.0.0)');
  await expect(page.locator('.update-versions')).toHaveText('当前 1.0.0 · 最新 1.0.0');
  await expect(page.locator('.update-release-notes')).toHaveText('MovieClaw Windows 1.0.0\n\n- 安装版：下载 Setup.exe。\n使用说明');
  await expect(page.locator('#updateDownload')).toHaveCount(0);
  await page.locator('#updateClose').click();
  await updates(page,request,{updateCheckFailure:true});
  await expect(page.locator('#desktopUpdateMessage')).toContainText('检查更新失败');
  await expect(page.locator('#updateRetryCheck')).toBeVisible();
  await expect(page.locator('#updateDownload')).toHaveCount(0);
});

test('verified updater displays release text safely and installs only the registered package', async ({page,request},info) => {
  const notes='更新中文说明 <img src=x onerror=alert(1)> '+ '改'.repeat(1600);
  await updates(page,request,{updateNotes:notes});
  await expect(page.locator('.update-release-notes')).toContainText('<img src=x onerror=alert(1)>');
  await expect(page.locator('.update-release-notes img')).toHaveCount(0);
  expect(await page.locator('.update-release-notes').evaluate(el=>Array.from(el.textContent).length)).toBe(1200);
  await screenshot(page,info,'update-available');
  await page.locator('#updateDownload').click(); await expect(page.locator('#updateInstall')).toBeVisible();
  await expect(page.locator('.update-metadata')).toContainText('数字签名有效');
  await expect(page.locator('.update-metadata')).toContainText('CN=MovieClaw Fixture');
  await screenshot(page,info,'update-ready');
  await page.locator('#updateInstall').click(); await expect(page.locator('#desktopUpdateDialog h2')).toHaveText('正在启动安装');
  await expect.poll(async()=> (await state(request)).updateRequests.filter(value=>value.command==='install_downloaded_update').length).toBe(1);
  const calls=(await state(request)).updateRequests;
  expect(calls.find(value=>value.command==='download_update').args).toEqual({version:'desktop-v0.2.112'});
  expect(calls.find(value=>value.command==='install_downloaded_update').args).toEqual({downloadId:'fixture-update-1',allowUnsigned:false});
});

test('updater cancellation stops the registered transfer and rejects late or unrelated progress', async ({page,request},info) => {
  await updates(page,request,{updateDelays:[1400,20]});
  await page.locator('#updateDownload').click();
  await expect(page.locator('#desktopUpdateProgress')).toBeVisible();
  await expect.poll(()=>page.evaluate(()=>window.DesktopUpdates.active?.id)).toBe('fixture-update-1');
  await expect(page.locator('#desktopUpdateProgress')).not.toHaveAttribute('value',/.+/);
  await page.locator('#updateCancel').focus();
  await page.evaluate(()=>window.__fixture.emit('movieclaw:update-progress',{downloadId:'fixture-update-1',version:'desktop-v0.2.112',state:'downloading',received:5120,total:10240}));
  await expect(page.locator('#desktopUpdateProgress')).toHaveAttribute('value','50');
  await expect(page.locator('#updateCancel')).toBeFocused();
  await page.evaluate(()=>window.__fixture.emit('movieclaw:update-progress',{downloadId:'another-download',version:'desktop-v0.2.112',state:'error',received:90,total:100}));
  await expect(page.locator('#desktopUpdateDialog h2')).toHaveText('正在下载更新');
  await screenshot(page,info,'update-downloading');
  await page.locator('#updateCancel').click(); await expect(page.locator('#desktopUpdateDialog h2')).toHaveText('下载已取消');
  expect((await state(request)).updateRequests.find(value=>value.command==='cancel_update_download').args).toEqual({downloadId:'fixture-update-1'});
  await page.evaluate(()=>{
    document.querySelector('#updateDownload').click();
    window.__fixture.emit('movieclaw:update-progress',{downloadId:'fixture-update-1',version:'desktop-v0.2.112',state:'error',received:90,total:100});
  });
  await expect(page.locator('#updateInstall')).toBeVisible();
  await page.evaluate(()=>window.__fixture.emit('movieclaw:update-progress',{downloadId:'fixture-update-1',version:'desktop-v0.2.112',state:'cancelled',received:10,total:100}));
  await expect(page.locator('#desktopUpdateDialog h2')).toHaveText('更新已准备');
  await expect.poll(async()=>Object.values((await state(request)).updateDownloads).every(value=>value.settled)).toBe(true);
  await expect(page.locator('#desktopUpdateDialog h2')).toHaveText('更新已准备');
  expect((await state(request)).updateRequests.some(value=>value.command==='install_downloaded_update')).toBe(false);
});

test('unsigned update requires a separate explicit installation confirmation', async ({page,request},info) => {
  await updates(page,request,{updateSignature:'unsigned'});
  await page.locator('#updateDownload').click(); await expect(page.locator('#updateInstall')).toBeVisible();
  await expect(page.locator('.update-metadata')).toContainText('未提供数字签名');
  await page.locator('#updateInstall').click(); await expect(page.locator('#updateConfirmUnsigned')).toBeVisible();
  await expect(page.locator('#desktopUpdateMessage')).toContainText('尚未验证发行者');
  expect((await state(request)).updateRequests.some(value=>value.command==='install_downloaded_update')).toBe(false);
  await screenshot(page,info,'update-unsigned-confirmation');
  await page.locator('#updateReturn').click(); await expect(page.locator('#updateInstall')).toBeVisible();
  await page.locator('#updateInstall').click(); await page.locator('#updateConfirmUnsigned').click();
  await expect.poll(async()=> (await state(request)).updateRequests.filter(value=>value.command==='install_downloaded_update').length).toBe(1);
  expect((await state(request)).updateRequests.find(value=>value.command==='install_downloaded_update').args.allowUnsigned).toBe(true);
});

test('failed package verification exposes recovery and never offers installation', async ({page,request},info) => {
  await updates(page,request,{updateDownloadFailure:true});
  await page.locator('#updateDownload').click(); await expect(page.locator('#desktopUpdateMessage')).toContainText('SHA-256 不匹配');
  await expect(page.locator('#updateInstall')).toHaveCount(0); await expect(page.locator('#updateDownload')).toBeVisible();
  await screenshot(page,info,'update-verification-failed');
  await page.locator('#updateRelease').click();
  await expect.poll(async()=> (await state(request)).updateRequests.some(value=>value.command==='open_release_page')).toBe(true);
  expect((await state(request)).updateRequests.some(value=>value.command==='install_downloaded_update')).toBe(false);
});

test('portable updates give manual instructions without invoking an installer', async ({page,request}) => {
  await updates(page,request,{updateFormat:'portable'});
  await page.locator('#updateDownload').click(); await expect(page.locator('#desktopUpdateMessage')).toContainText('便携版需要手动安装');
  await expect(page.locator('#updateInstall')).toHaveCount(0); await expect(page.locator('#updateShowFile')).toBeVisible();
  await page.locator('#updateShowFile').click();
  await expect.poll(async()=> (await state(request)).updateRequests.some(value=>value.command==='open_downloaded_update' && value.args.downloadId==='fixture-update-1')).toBe(true);
  expect((await state(request)).updateRequests.some(value=>value.command==='install_downloaded_update')).toBe(false);
});
