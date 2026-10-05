// Standalone prototype verification; no production dependencies are changed.
// PLAYWRIGHT_MODULE=/absolute/path/to/playwright-core/index.mjs node verify.mjs
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const url = process.env.DEMO_URL || 'http://127.0.0.1:8766/docs/design/mockups/genre-directions/';
const out = process.env.DEMO_SHOTS || '/tmp/movieclaw-genre-directions';
await mkdir(out,{recursive:true});
const browser=await chromium.launch({channel:'chrome',headless:true});
const page=await browser.newPage({viewport:{width:1440,height:1250},deviceScaleFactor:1});
const errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('response',r=>{if(r.status()>=400)errors.push(`${r.status()} ${r.url()}`)});
const results=[];
try{
 for(const design of ['cinema','shelf','index','current']){
  for(const device of ['web','phone','tv']){
   await page.goto(`${url}?design=${design}&device=${device}`,{waitUntil:'networkidle'});
   assert.equal(await page.locator('.genre').count(),6);
   const broken=await page.locator('img').evaluateAll(images=>images.filter(i=>!i.complete||!i.naturalWidth).map(i=>i.src));
   assert.deepEqual(broken,[],`${design}/${device}: all images must load`);
   await page.locator('#stage-wrap').screenshot({path:`${out}/${design}-${device}.png`});
   if(device==='tv'){
    assert.equal(await page.locator('.genre:focus').getAttribute('data-genre'),'0');
    await page.keyboard.press('ArrowRight');
    assert.equal(await page.locator('.genre:focus').getAttribute('data-genre'),'1');
    await page.keyboard.press('End');
    assert.equal(await page.locator('.genre:focus').getAttribute('data-genre'),'5');
    await page.keyboard.press('Enter');
    assert.equal(await page.locator('#wall-title').textContent(),'悬疑');
   }else{
    await page.locator('.genre').first().click();
    assert.equal(await page.locator('#wall-title').textContent(),'科幻');
   }
   assert.equal(await page.locator('#wall').evaluate(d=>d.open),true);
   assert.equal(await page.locator('#wall-posters img').count(),3);
   await page.keyboard.press('Escape');
   assert.equal(await page.locator('#wall').evaluate(d=>d.open),false);
   await page.locator('#missing').check();
   assert.equal(await page.locator('.genre img').count(),0,'missing state must not rely on images');
   await page.locator('#long').check();
   assert.match(await page.locator('.genre').first().getAttribute('aria-label'),/科幻奇幻/);
   await page.locator('.genre').first().click();
   assert.equal(await page.locator('#wall-title').textContent(),'科幻奇幻');
   await page.keyboard.press('Escape');
   results.push(`${design}/${device}: images, category entry, dismissal, missing art, long label PASS`);
  }
 }
 // Genuine narrow browser viewport, in addition to the iPhone artboard.
 await page.setViewportSize({width:390,height:844});
 await page.goto(`${url}?design=cinema&device=phone`,{waitUntil:'networkidle'});
 assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'no horizontal page overflow');
 await page.locator('.genre-row').evaluate(el=>el.scrollLeft=600);
 assert.ok(await page.locator('.genre-row').evaluate(el=>el.scrollLeft>0),'genre shelf scrolls on phone');
 await page.getByRole('button',{name:'C 暗色索引',exact:true}).click();
 assert.equal(await page.locator('#stage').evaluate(el=>el.classList.contains('index')),true);
 await page.locator('#stage-wrap').screenshot({path:`${out}/narrow-phone.png`});
 assert.deepEqual(errors,[]);
 results.push('390px viewport: no page overflow, horizontal genre browsing, design switch PASS');
 await writeFile(`${out}/verification.txt`,results.join('\n')+'\nBrowser errors: 0\n');
 console.log(results.join('\n')+'\nBrowser errors: 0');
}finally{await browser.close();}
