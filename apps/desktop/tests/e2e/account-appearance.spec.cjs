const {test,expect}=require('@playwright/test');
const {openDesktop}=require('./helpers.cjs');
for (const width of [1280,640,360]) {
 test(`account dialog has aligned actions at ${width}px`,async({page,request},info)=>{
  await page.setViewportSize({width,height:800});await openDesktop(page,request);
  await expect.poll(()=>page.evaluate(()=>!!App.session && !App._authPending)).toBe(true);
  await page.locator('#accountButton').click();
  await expect(page.locator('#panelAccountList .settings-row')).toHaveCount(2);
  const ids=['panelAddAccount','panelSettings','panelAbout','panelLogout'];
  const boxes=await Promise.all(ids.map(id=>page.locator('#'+id).boundingBox()));
  expect(Math.abs(boxes[0].y-boxes[1].y)).toBeLessThan(1);
  expect(Math.abs(boxes[2].y-boxes[3].y)).toBeLessThan(1);
  expect(Math.abs(boxes[0].width-boxes[1].width)).toBeLessThan(1);
  expect(Math.abs(boxes[0].x-boxes[2].x)).toBeLessThan(1);
  const status=await page.locator('#panelAccountList .settings-account-actions > span').boundingBox();
  const remove=await page.locator('#panelAccountList .account-remove').first().boundingBox();
  expect(Math.abs(status.y+status.height/2-remove.y-remove.height/2)).toBeLessThan(1);
  expect(await page.locator('#accountPanel').evaluate(el=>el.scrollWidth<=el.clientWidth+1)).toBe(true);
  await page.screenshot({path:info.outputPath(`account-aligned-${width}.png`)});
 });
}
test('switches use clear blue for enabled state and distinguish disabled state',async({page,request},info)=>{
 await openDesktop(page,request,{friends:true});await expect.poll(()=>page.evaluate(()=>!!App.session && !App._authPending)).toBe(true);
 await page.locator('[data-page="settings"]').click();
 await expect(page.locator('#setFriendsShare')).toBeEnabled();
 await page.locator('#setFriendsVisible').check();
 await expect(page.locator('#setFriendsVisible + .toggle-slider')).toHaveCSS('background-color','rgb(84, 140, 255)');
 await page.locator('#setFriendsVisible').uncheck();
 await expect(page.locator('#setFriendsVisible + .toggle-slider')).not.toHaveCSS('background-color','rgb(84, 140, 255)');
 await page.locator('.friends-help summary').click();
 await expect(page.locator('.friends-help')).toContainText('/api/v1/plugins/watch-presence/settings');
 await expect(page.locator('.friends-settings')).toContainText('主界面侧栏');
 await page.locator('.friends-settings').screenshot({path:info.outputPath('friends-entry-settings.png')});
});
