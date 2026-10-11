const {test,expect}=require('@playwright/test');
const {openDesktop,browseLibrary,state}=require('./helpers.cjs');
const mediaFile=(id,extra={})=>({id,state:'in_place',file_name:`film-${id}.mkv`,resolution:'1080p',container:'mkv',video_codec:'hevc',
  audio_streams:[{language:'eng',codec:'aac',channels:2},{language:'zho',codec:'ac3',channels:6}],
  subtitle_streams:[{external:true,file_name:'original.eng.srt',language:'eng',codec:'srt'},{language:'zho',codec:'ass'}],...extra});
async function detail(page,request,options={}) {
  await openDesktop(page,request,{mediaFiles:{1:[mediaFile(1),mediaFile(11,{resolution:'2160p'})]},...options});
  await browseLibrary(page);await page.locator('[data-item-id="1"]').first().click();
  await expect(page.locator('#detailFileTrigger')).toBeVisible();
  await expect.poll(()=>page.evaluate(()=>!!App.session && !App._authPending)).toBe(true);
}
async function choose(page,id,name) {
  await page.locator('#'+id+'Trigger').click();
  await page.getByRole('option',{name,exact:true}).click();
}
const job=(status='running',extra={})=>({id:'existing',job_type:'subtitle.generate',status,input_data:{file_id:1},resources:[],progress:{message:'正在翻译',percent:45},...extra});

test('details choose a version and neutral track refs for actual playback',async({page,request})=>{
  await detail(page,request);
  await choose(page,'detailFile','2160p · HEVC · film-11.mkv');
  await choose(page,'detailAudio','中文 · AC3 · 6 声道');
  await choose(page,'detailSubtitle','中文 · ASS · 内封');
  await page.locator('#btnPlay').click();
  await expect(page.locator('#playerView')).toBeVisible();
  const body=(await state(request)).requests.find(value=>value.path==='/playback/sessions').body;
  expect(body).toMatchObject({file_id:11,audio_track:'embedded:1',subtitle_track:'embedded:1'});
});

test('generation prechecks bilingual options, reports real progress and refreshes the subtitle list',async({page,request})=>{
  await detail(page,request,{jobStates:['running','succeeded']});
  await page.locator('#subtitleGenerate').click();
  await expect(page.locator('#subtitleStart')).toBeEnabled();
  const modal = await page.locator('#subtitleDialog').boundingBox();
  expect(Math.abs(modal.x + modal.width/2 - page.viewportSize().width/2)).toBeLessThan(2);
  expect(Math.abs(modal.y + modal.height/2 - page.viewportSize().height/2)).toBeLessThan(2);
  await choose(page,'subtitleSecondary','双语 · 英语');
  await expect(page.locator('#subtitleStart')).toBeEnabled();
  await expect(page.locator('.subtitle-preview')).toContainText('2,000 tokens');
  await page.locator('#subtitleStart').click();
  await expect(page.locator('.subtitle-status')).toContainText('排队中');
  expect((await state(request)).generationRequests).toEqual([{fileId:1,target_language:'chs',secondary_language:'eng',source_candidate_key:'embedded:0',convert_pgs:false,pgs_ocr_language:null}]);
  await page.locator('#subtitleClose').click();
  await expect(page.locator('#subtitleGenerate')).toHaveText('生成完成',{timeout:8000});
  await expect(page.locator('[data-use-subtitle]')).toContainText('AI');
  await page.locator('[data-use-subtitle]').click();
  await page.locator('#btnPlay').click();
  expect((await state(request)).requests.find(value=>value.path==='/playback/sessions').body.subtitle_track).toBe('external:fixture.ai.chs.srt');
});

test('PGS generation requires an explicit OCR language when the source language is unknown',async({page,request})=>{
  await detail(page,request,{generationPreview:{candidates:[{kind:'embedded',key:'1',language:null,format:'pgs',selectable:true,requires_ocr:true,reasons:[]}],selected_source_key:'embedded:1',blocker:{code:'pgs_conversion_required',title:'需要 OCR',message:'图片字幕需先识别',suggestions:[]},pgs_conversion:{available:true,ocr_language:null,language_options:[{code:'en',label:'英语'}]}}});
  await page.locator('#subtitleGenerate').click();
  await expect(page.locator('#subtitleStart')).toBeDisabled();
  await choose(page,'subtitleOcr','英语');
  await expect(page.locator('#subtitleStart')).toBeEnabled();
  await page.locator('#subtitleStart').click();
  expect((await state(request)).generationRequests[0]).toMatchObject({source_candidate_key:'embedded:1',convert_pgs:true,pgs_ocr_language:'en'});
});

test('restored jobs support cancellation and retry without duplicate generation',async({page,request})=>{
  await detail(page,request,{jobs:[job()]});
  await expect(page.locator('#subtitleGenerate')).toHaveText('正在生成');
  await page.locator('#subtitleGenerate').click();
  await page.locator('#subtitleCancel').click();
  await expect(page.locator('.subtitle-status')).toContainText('已取消');
  await page.locator('#subtitleRetry').click();
  await expect(page.locator('.subtitle-status')).toContainText('排队中');
  expect((await state(request)).generationRequests).toBeUndefined();
});

for (const [name,options,message] of [
  ['missing model',{noLlm:true},'服务器尚未配置 AI 模型'],
  ['missing reference',{generationPreview:{candidates:[],selected_source_key:null,blocker:{code:'no_reference',title:'没有参考字幕',message:'请先添加参考字幕',suggestions:[]}}},'没有参考字幕'],
  ['unsupported server',{previewUnsupported:true},'服务器暂不支持 AI 字幕接口'],
]) test(`${name} blocks generation with an actionable explanation`,async({page,request})=>{
  await detail(page,request,options);await page.locator('#subtitleGenerate').click();
  await expect(page.locator('#subtitleDialog')).toContainText(message);
  await expect(page.locator('#subtitleStart')).toBeDisabled();
  expect((await state(request)).generationRequests).toBeUndefined();
});

test('members can choose tracks while generation and QR entries remain hidden',async({page,request})=>{
  await detail(page,request,{role:'member'});
  await expect(page.locator('#subtitleGenerate')).toHaveCount(0);
  await expect(page.locator('#detailTracks')).toContainText('需要管理员');
  await page.locator('[data-page="settings"]').click();
  await expect(page.locator('#btnQRLogin')).toHaveCount(0);
});

test('changing files cancels a pending preview and prevents stale results from reaching the new version',async({page,request})=>{
  await detail(page,request,{previewDelay:1200});
  await page.locator('#subtitleGenerate').click();
  await page.locator('#subtitleClose').click();
  await choose(page,'detailFile','2160p · HEVC · film-11.mkv');
  await page.waitForTimeout(1400);
  await expect(page.locator('#subtitleDialog')).toHaveCount(0);
  await expect(page.locator('#detailFile')).toHaveValue('11');
  expect((await state(request)).generationRequests).toBeUndefined();
});

test('generation failure stays recoverable and never fabricates a task',async({page,request})=>{
  await detail(page,request,{generationFailure:true});await page.locator('#subtitleGenerate').click();
  await expect(page.locator('#subtitleStart')).toBeEnabled();await page.locator('#subtitleStart').click();
  await expect(page.locator('.subtitle-error')).toContainText('服务器模型不可用');
  await expect(page.locator('#subtitleStart')).toBeEnabled();
});

test('switching selected TV episodes resets the file and previous track selection',async({page,request})=>{
  const files=[mediaFile(31,{season_number:3,episode_number:1}),mediaFile(32,{season_number:3,episode_number:2})];
  await openDesktop(page,request,{mediaFiles:{3:files}});await browseLibrary(page);
  await page.locator('[data-item-id="3"]').first().click();
  await expect(page.locator('#detailFile')).toHaveValue('32');
  await choose(page,'detailSubtitle','关闭字幕');
  await page.locator('.episode-card[data-episode-number="1"]').click();
  await expect(page.locator('#detailFile')).toHaveValue('31');
  await expect(page.locator('#detailSubtitle')).toHaveValue('');
  await page.locator('#btnPlay').click();
  expect((await state(request)).requests.find(value=>value.path==='/playback/sessions').body).toMatchObject({file_id:31,season_number:3,episode_number:1});
});

test('progress updates preserve an open track menu',async({page,request})=>{
  await detail(page,request,{jobs:[job()]});
  await expect(page.locator('#subtitleGenerate')).toHaveText('正在生成');
  await page.locator('#detailAudioTrigger').click();
  await page.waitForTimeout(2400);
  await expect(page.locator('#detailAudioMenu')).toBeVisible();
  await page.getByRole('option',{name:'中文 · AC3 · 6 声道',exact:true}).click();
  await expect(page.locator('#detailAudio')).toHaveValue('embedded:1');
});

test('late job polls cannot revive a cancelled task',async({page,request})=>{
  let release; const pending=new Promise(resolve=>release=resolve);
  await page.route('**/api/v1/jobs/existing',async route=>{await pending;await route.fulfill({json:{data:job()}});});
  await detail(page,request,{jobs:[job()]});
  const poll=page.waitForRequest('**/api/v1/jobs/existing');
  await page.locator('#subtitleGenerate').click();await poll;
  await page.locator('#subtitleCancel').click();
  await expect(page.locator('.subtitle-status')).toContainText('已取消');release();
  await page.waitForTimeout(300);
  await expect(page.locator('.subtitle-status')).toContainText('已取消');
});

test('account retirement aborts prechecks and removes the old account dialog',async({page,request})=>{
  await detail(page,request,{previewDelay:1200});await page.locator('#subtitleGenerate').click();
  await page.evaluate(()=>App.resetContext());
  await expect(page.locator('#subtitleDialog')).toHaveCount(0);
  await page.waitForTimeout(1400);expect((await state(request)).generationRequests).toBeUndefined();
});
