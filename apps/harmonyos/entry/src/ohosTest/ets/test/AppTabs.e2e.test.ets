import { describe, it, expect, beforeAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component } from '@ohos.UiTest';

const titles: string[] = ['媒体库', '订阅', '发现', '活动', '我的'];
async function wait(driver: Driver, id: string): Promise<Component> {
  const end = Date.now() + 10000;
  while (Date.now() < end) {
    const node = await driver.findComponent(ON.id(id));
    if (node !== null) { return node; }
    await driver.delayMs(150);
  }
  throw new Error(`Missing ${id}`);
}
async function choose(driver: Driver, title: string): Promise<void> {
  const expand = await driver.findComponent(ON.id('app-tabs-expand'));
  if (expand !== null) { await expand.click(); await driver.delayMs(400); }
  await (await wait(driver, `app-tab-${title}`)).click();
  await driver.delayMs(400);
}
async function selected(driver: Driver, title: string): Promise<void> {
  for (const tab of titles) {
    expect(await (await wait(driver, `app-tab-${tab}`)).isSelected()).assertEqual(tab === title);
  }
}
async function capture(driver: Driver, name: string): Promise<void> {
  const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
  await driver.screenCap(`${context.cacheDir}/mc-tabs-${name}.png`);
}

/** Authenticated NAS session: actual navigation, scrolling, preferences and playback return. */
export default function appTabsE2E(): void {
  describe('HarmonyAppTabsE2E', () => {
    beforeAll(async () => {
      const args = abilityDelegatorRegistry.getArguments();
      await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
        bundleName: args.bundleName, abilityName: 'EntryAbility'
      });
      await Driver.create().delayMs(3000);
    });
    it('all_tabs_update_selection_and_scope_accessories', 0, async () => {
      const driver = Driver.create();
      for (const title of titles) {
        await choose(driver, title);
        await selected(driver, title);
        const heading = title === '发现' ? '电影' : title;
        const headings = await driver.findComponents(ON.text(heading));
        expect(headings !== null && headings.length > 0).assertTrue();
        expect(await driver.findComponent(ON.id('app-more-ai-input')) !== null).assertEqual(title === '我的');
        if (title === '我的') {
          await wait(driver, 'app-tab-avatar');
          expect(await driver.findComponent(ON.id('app-resume-bar')) === null).assertTrue();
          const input = await (await wait(driver, 'app-more-ai-input')).getBounds();
          const tab = await (await wait(driver, 'app-tab-我的')).getBounds();
          expect(input.bottom < tab.top).assertTrue();
        }
        await capture(driver, title);
      }
      // Reverse order catches labels retaining a previous selected state.
      for (const title of titles.slice().reverse()) {
        await choose(driver, title); await selected(driver, title);
      }
    });
    it('scroll_collapses_to_current_tab_and_tap_restores_all_tabs', 0, async () => {
      const driver = Driver.create();
      await choose(driver, '媒体库');
      const list = await wait(driver, 'app-library-list');
      const expandedBar = await (await wait(driver, 'app-resume-bar')).getBounds();
      const title = await (await wait(driver, 'app-resume-title')).getText();
      await wait(driver, 'app-resume-close');
      const bounds = await list.getBounds();
      const x = Math.round((bounds.left + bounds.right) / 2);
      await driver.swipe(x, Math.round(bounds.bottom * 0.65), x, Math.round(bounds.bottom * 0.3), 700);
      const expand = await wait(driver, 'app-tabs-expand'); await driver.delayMs(500);
      const compact = await expand.getBounds();
      expect(compact.left < bounds.right * 0.1).assertTrue();
      const accessory = await (await wait(driver, 'app-resume-bar')).getBounds();
      expect(accessory.left > compact.right).assertTrue();
      expect(Math.abs(accessory.top - compact.top) < 4).assertTrue();
      expect(accessory.top > expandedBar.top).assertTrue();
      expect(accessory.right - accessory.left < expandedBar.right - expandedBar.left).assertTrue();
      expect(accessory.right - accessory.left > 3 * (accessory.bottom - accessory.top)).assertTrue();
      expect(await (await wait(driver, 'app-resume-title')).getText()).assertEqual(title);
      await wait(driver, 'app-resume-play-icon');
      expect(await driver.findComponent(ON.id('app-resume-close')) === null).assertTrue();
      expect(await driver.findComponent(ON.id('app-tab-发现')) === null).assertTrue();
      await capture(driver, 'compact');
      await (await wait(driver, 'app-tabs-expand')).click();
      await driver.delayMs(500); await selected(driver, '媒体库');
      await wait(driver, 'app-resume-close');
      await driver.swipe(x, Math.round(bounds.bottom * 0.3), x, Math.round(bounds.bottom * 0.8), 700);
    });
    it('classic_style_switch_and_reselect_return_to_root', 0, async () => {
      const driver = Driver.create();
      await choose(driver, '我的');
      await driver.delayMs(400);
      await (await driver.findComponent(ON.text('服务器'))!).click();
      await driver.delayMs(500);
      await (await driver.findComponent(ON.text('服务器设置'))!).click();
      const settings = await wait(driver, 'app-settings-list');
      const bounds = await settings.getBounds();
      for (let attempt = 0; attempt < 8; attempt++) {
        const candidate = await driver.findComponent(ON.id('app-classic-tabs-toggle'));
        if (candidate !== null) {
          const area = await candidate.getBounds();
          if (area.top > bounds.bottom * 0.15 && area.bottom < bounds.bottom * 0.7) { break; }
        }
        await driver.swipe(Math.round(bounds.right * 0.8), Math.round(bounds.bottom * 0.7),
          Math.round(bounds.right * 0.8), Math.round(bounds.bottom * 0.4), 700);
        await driver.delayMs(300);
      }
      const toggle = await wait(driver, 'app-classic-tabs-toggle');
      expect(await toggle.isChecked()).assertFalse();
      await toggle.click();
      try {
        await driver.delayMs(700);
        expect(await (await wait(driver, 'app-classic-tabs-toggle')).isChecked()).assertTrue();
        await selected(driver, '我的');
        await capture(driver, 'classic');
      } finally {
        const current = await wait(driver, 'app-classic-tabs-toggle');
        if (await current.isChecked()) { await current.click(); await driver.delayMs(700); }
      }
      await choose(driver, '我的');
      expect(await driver.findComponent(ON.id('app-settings-list')) === null).assertTrue();
      await wait(driver, 'app-more-list');
      await choose(driver, '媒体库');
    });
    it('player_hides_global_navigation_and_back_restores_it', 0, async () => {
      const driver = Driver.create();
      await choose(driver, '媒体库');
      const args = abilityDelegatorRegistry.getArguments();
      const fixture = args.parameters['-s avplayerFixture'] ?? '';
      expect(fixture.length > 0).assertTrue();
      await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
        bundleName: args.bundleName, abilityName: 'EntryAbility', parameters: { mcPlaybackTest: fixture }
      });
      await wait(driver, 'player-pause-glyph');
      expect(await driver.findComponent(ON.id('app-tab-媒体库')) === null).assertTrue();
      expect(await driver.findComponent(ON.id('app-resume-bar')) === null).assertTrue();
      await driver.pressBack(); await driver.delayMs(1000);
      await selected(driver, '媒体库');
      await wait(driver, 'app-resume-bar');
      const listBounds = await (await wait(driver, 'app-library-list')).getBounds();
      const x = Math.round(listBounds.right / 2);
      await driver.swipe(x, Math.round(listBounds.bottom * 0.65), x, Math.round(listBounds.bottom * 0.3), 700);
      await wait(driver, 'app-tabs-expand'); await driver.delayMs(500);
      await (await wait(driver, 'app-resume-play')).click();
      await wait(driver, 'player-pause-glyph');
      await driver.pressBack(); await driver.delayMs(1000);
      await selected(driver, '媒体库');
      await choose(driver, '发现'); await selected(driver, '发现');
      await choose(driver, '媒体库'); await capture(driver, 'restored');
    });
  });
}
