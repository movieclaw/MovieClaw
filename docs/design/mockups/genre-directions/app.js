const $ = (s) => document.querySelector(s);
const icons = {
 library:'<path d="m3 8 9-5 9 5-9 5z"/><path d="m3 12 9 5 9-5M3 16l9 5 9-5"/>',
 film:'<rect x="3" y="3" width="18" height="18" rx="3"/><path d="M7 3v18M17 3v18M3 8h4M3 16h4M17 8h4M17 16h4"/>',
 search:'<circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/>',
 star:'<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5z"/>',
 bookmark:'<path d="M6 21V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v16l-6-4z"/>',
 activity:'<path d="M2 12h5l3-8 4 16 3-8h5"/>',
 planet:'<circle cx="12" cy="12" r="7"/><ellipse cx="12" cy="12" rx="12" ry="4" transform="rotate(-30 12 12)"/>',
 bolt:'<path d="m14 2-11 12h8l-1 8 11-12h-8z"/>',
 smile:'<circle cx="12" cy="12" r="9"/><path d="M8 9h.01M16 9h.01M7 14q5 6 10 0"/>',
 heart:'<path d="M12 21 3.8 12.8A5.5 5.5 0 0 1 12 5.5a5.5 5.5 0 0 1 8.2 7.3z"/>',
 eye:'<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>'
};
const icon = (name) => `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.film}</svg>`;
const movies = {
 space:['星际穿越','2014'],dune:['沙丘','2021'],action:['疯狂的麦克斯：狂暴之路','2015'],comedy:['布达佩斯大饭店','2014'],animation:['千与千寻','2001'],romance:['爱乐之城','2016'],mystery:['盗梦空间','2010'],drama:['肖申克的救赎','1994'],truman:['楚门的世界','1998'],ratatouille:['料理鼠王','2007'],'wall-e':['机器人总动员','2008'],parasite:['寄生虫','2019'],arrival:['降临','2016'],amelie:['天使爱美丽','2001'],titanic:['泰坦尼克号','1997']
};
const genres = [
 {id:878,name:'科幻',count:128,image:'space',symbol:'planet',films:['space','dune','arrival'],color:'linear-gradient(125deg,#c3c8cf,#eceef0 42%,#aab2bc)',ink:'#30343a'},
 {id:28,name:'动作',count:96,image:'action',symbol:'bolt',films:['action','dune','mystery'],color:'oklch(.76 .112 33)',ink:'#391f19'},
 {id:35,name:'喜剧',count:84,image:'comedy',symbol:'smile',films:['comedy','truman','ratatouille'],color:'oklch(.86 .112 95)',ink:'#393014'},
 {id:16,name:'动画',count:62,image:'animation',symbol:'star',films:['animation','ratatouille','wall-e'],color:'oklch(.86 .072 152)',ink:'#193b2e'},
 {id:10749,name:'爱情',count:48,image:'romance',symbol:'heart',films:['romance','amelie','titanic'],color:'oklch(.86 .072 0)',ink:'#3c2530'},
 {id:9648,name:'悬疑',count:37,image:'mystery',symbol:'eye',films:['mystery','parasite','arrival'],color:'oklch(.38 .056 215)',ink:'#e4f3f4'}
];
const notes = {
 cinema:{title:'A / 全幅剧照',summary:'把“类型入口”融入现有剧照语言。横向构图，类型优先，颜色来自电影。',decision:'最值得先试的一版。',reason:'保留电影的氛围，移除彩色卡套和片名副标题。类型名固定在左下，部数紧随其后，和继续观看、影片海报自然接在一起。',tradeoff:'只需要现有 cover_url、label、count。单张封面仍可能被误认为单片，所以始终显示“部电影”和浏览箭头；正式版沿用现有最新入库封面，稳定封面选取可另行讨论。',phone:'236 × 150 pt 的横向卡，一屏露出下一张。分类名保持 24 pt，滑动距离与继续观看接近。',spec:{web:'236 × 150 · 圆角 12 · 间距 16',phone:'236 × 150 pt · 圆角 12 · 间距 12',tv:'416 × 234 pt · 圆角 20 · 焦点 1.07×'}},
 shelf:{title:'B / 海报片架',summary:'一眼看懂“这是一组电影”。银黑卡面，三张真实海报，像收藏架的一角。',decision:'更有个人片库的收藏感。',reason:'叠放的海报把“分类里有多部影片”直接画出来。色彩集中在右侧内容，类型标题仍落在安静、统一的暗色底上。',tradeoff:'需要每个类型提供 3 张可用海报，现有接口只有 1 张剧照，落地需要扩展数据。首页的媒体库卡已经有拼贴，使用这一版时要留意两行重复。',phone:'手机保留大标题，海报只占右半边。封面缺失时留出中性图标区域，数量与入口仍然可用。',spec:{web:'236 × 178 · 3 张海报 · 间距 16',phone:'220 × 172 pt · 间距 12',tv:'416 × 280 pt · 焦点 1.07×'}},
 index:{title:'C / 暗色索引',summary:'让类型成为导航。统一深灰底、大字、部数；低对比符号仅作辅助。',decision:'最安静，也最容易长期保持一致。',reason:'压低分类导航的视觉重量，把注意力让给电影本身。不依赖封面质量，缺图、小片库和长类型名称都更容易处理。',tradeoff:'只使用类型与数量，无新增图片请求。扫读清楚，但“想点进去看”的影视氛围弱于 A。低对比图标不承载唯一信息，焦点时整张卡明确提亮。',phone:'164 × 110 pt，手机同时看到两个完整入口。分类更像索引，下面的海报能更早出现在首屏。',spec:{web:'200 × 108 · 圆角 12 · 无封面',phone:'164 × 110 pt · 两张完整可见',tv:'326 × 174 pt · 5 列 · 焦点 1.07×'}},
 current:{title:'现版 / 彩色方卡',summary:'按 main 的结构、尺寸与主要配色重绘；使用同一组演示封面作比较。',decision:'突兀来自层级，不只是某一种颜色。',reason:'类型底色、内部剧照、外部片名形成三层视觉。类型入口拥有比邻近内容更醒目的容器，也同时传达了“分类”和“最近入库推荐”。',tradeoff:'现版可沿用，实施成本为零。这里是依据代码重绘的对照，银色材质为近似；不是线上截图。电视与现版一致，不显示卡片下的片名。',phone:'现版手机卡为 150 pt 方形，卡片下额外展示片名与“最近入库”。',spec:{web:'200 × 200 + 两行文字',phone:'150 × 150 pt + 两行文字',tv:'326 × 326 pt · 无外部片名'}}
};
const params = new URLSearchParams(location.search);
let design = Object.hasOwn(notes,params.get('design')) ? params.get('design') : 'cinema';
let device = ['web','phone','tv'].includes(params.get('device')) ? params.get('device') : 'web';
const dimensions = {web:[1280,790],phone:[393,852],tv:[1920,1080]};
const image = (file,extra='') => `<img src="assets/${file}.jpg" alt="" ${extra}>`;
const fallback = (g) => `<span class="fallback">${icon(g.symbol)}</span>`;
const displayName = (g,i) => $('#long').checked ? ['科幻奇幻','动作冒险','喜剧','动画','战争政治','电视电影'][i] : g.name;
function card(g,i){
 const label = displayName(g,i), missing = $('#missing').checked;
 let artwork = '';
 if(design === 'cinema') artwork = missing ? fallback(g) : image(g.image);
 if(design === 'shelf') artwork = missing ? fallback(g) : `<span class="poster-stack">${g.films.map(f=>image('p-'+f)).join('')}</span>`;
 if(design === 'index') artwork = `<span class="symbol">${icon(g.symbol)}</span>`;
 if(design === 'current') artwork = `<span class="legacy-image">${missing ? fallback(g) : image(g.image)}</span>`;
 return `<button class="genre" data-genre="${i}" aria-label="浏览${label}，${g.count}部电影" style="--tile:${g.color};--ink:${g.ink}"><span class="face">${artwork}<span class="label">${label}</span><span class="count">${g.count} ${design==='current'?'部':'部电影'}</span>${design==='current'?'':'<span class="arrow" aria-hidden="true">›</span>'}</span><span class="outside">${movies[g.image][0]}<small>最近入库</small></span></button>`;
}
function render(){
 const n = notes[design], stage = $('#stage');
 stage.className = `${device} ${design} ${$('#long').checked?'long-label':''}`;
 stage.style.width = dimensions[device][0]+'px';stage.style.height = dimensions[device][1]+'px';
 const brand = '<span class="brand"><img src="../../../../apps/web/public/brand/movieclaw-mark-ui.png" alt="">MovieClaw</span>';
 const nav = [['star','新会话'],['library','媒体库'],['film','发现电影'],['film','发现剧集'],['bookmark','我的订阅'],['activity','活动']];
 stage.innerHTML = `<aside class="sidebar">${brand}${nav.map(([ic,l],i)=>`<div class="side-item ${i===1?'active':''}">${icon(ic)}${l}</div>`).join('')}<div class="side-label">最近会话</div><div class="side-item" style="font-size:11px;color:#666770">今晚想看点什么？</div><div class="side-foot"><span class="avatar">MC</span><span>我的影院<br><small>个人媒体库</small></span></div></aside>
 <div class="statusbar"><span>9:41</span><span class="island"></span><span>▂▄▆ &nbsp;◒ ▰</span></div><div class="tv-nav">${brand}<span class="active">首页</span><span>媒体库</span><span>发现</span><span>搜索</span></div>
 <div class="content"><div class="product-head"><div><h2>${device==='phone'?'首页':'媒体库'}</h2><p>你的电影，随时开场</p></div><div class="head-actions"><span>${icon('search')}</span><span>···</span></div></div>
 <section class="shelf-section continue-section"><div class="section-heading"><h3>接下来继续</h3><span>查看全部 ›</span></div><div class="continue-row">${['space','romance','mystery'].map((f,i)=>`<div class="continue-card"><div class="still">${image(f)}<span class="play">▶</span><span class="progress" style="width:${[43,65,27][i]}%"></span></div><div class="card-caption">${movies[f][0]}<small>${['剩余 1 小时 36 分钟','剩余 42 分钟','剩余 1 小时 48 分钟'][i]}</small></div></div>`).join('')}</div></section>
 <section class="shelf-section genre-section"><div class="section-heading"><h3>按类型找电影</h3><span>${device==='tv'?'你的片库 · 按类型探索':'全部类型'}</span></div><div class="genre-row" aria-label="电影类型">${genres.map(card).join('')}</div></section>
 <section class="shelf-section"><div class="section-heading"><h3>最近添加的电影</h3><span>查看全部 ›</span></div><div class="poster-row">${['dune','animation','comedy','action','romance','space','mystery'].map(f=>`<div class="poster-card">${image('p-'+f)}<div class="card-caption">${movies[f][0]}<small>${movies[f][1]}</small></div></div>`).join('')}</div></section></div>
 <div class="mobile-tabs">${[['library','首页'],['bookmark','订阅'],['star','发现'],['activity','活动']].map(([ic,l],i)=>`<span class="${i===0?'active':''}">${icon(ic)}${l}</span>`).join('')}<span><span class="avatar">我</span></span></div>`;
 document.querySelectorAll('[data-design]').forEach(b=>b.setAttribute('aria-pressed',b.dataset.design===design));
 document.querySelectorAll('[data-device]').forEach(b=>b.setAttribute('aria-pressed',b.dataset.device===device));
 $('#summary').textContent = n.summary;$('#decision').textContent=n.decision;$('#reason').textContent=n.reason;$('#tradeoff').textContent=n.tradeoff;$('#spec').textContent=n.spec[device];$('#phone-copy').textContent=n.phone;
 $('#try').textContent=device==='tv'?'点击任意类型获得焦点；用 ← → 切换，Enter 进入分类，Esc 返回。电视预览按 1920 × 1080 等比缩放。':'点击卡片预览分类。横向滚动看其余类型；打开“缺图测试”观察封面缺失时的表现。';
 stage.querySelectorAll('[data-genre]').forEach(b=>b.addEventListener('click',()=>openGenre(Number(b.dataset.genre))));
 const url = new URL(location.href);url.searchParams.set('design',design);url.searchParams.set('device',device);history.replaceState(null,'',url);
 resize();
 if(device==='tv')stage.querySelector('.genre').focus({preventScroll:true});
}
function resize(){
 const workspace=$('.workspace'), width=workspace.clientWidth;
 const [w,h]=dimensions[device];
 const available=device==='phone'?Math.min(393,width-(width<500?34:60)):width;
 const scale=Math.min(1,available/w);
 $('#stage').style.transform=`scale(${scale})`;$('#stage-wrap').style.width=w*scale+'px';$('#stage-wrap').style.height=h*scale+'px';
}
function openGenre(i){
 const g=genres[i];$('#wall-title').textContent=displayName(g,i);$('#wall-meta').textContent=`${g.count} 部电影 · 最近添加`;
 $('#wall-posters').innerHTML=g.films.map(f=>`<div>${image('p-'+f)}<p>${movies[f][0]}</p><small>${movies[f][1]}</small></div>`).join('');$('#wall').showModal();
}
$('.designs').addEventListener('click',e=>{const b=e.target.closest('[data-design]');if(b){design=b.dataset.design;render()}});
$('.devices').addEventListener('click',e=>{const b=e.target.closest('[data-device]');if(b){device=b.dataset.device;render()}});
$('#missing').addEventListener('change',render);$('#long').addEventListener('change',render);
$('#stage').addEventListener('keydown',e=>{
 if(!['ArrowLeft','ArrowRight','Home','End'].includes(e.key)||!e.target.matches('.genre'))return;
 const cards=[...document.querySelectorAll('.genre')];const i=cards.indexOf(e.target);
 const next=e.key==='Home'?0:e.key==='End'?cards.length-1:Math.max(0,Math.min(cards.length-1,i+(e.key==='ArrowRight'?1:-1)));
 e.preventDefault();cards[next].focus({preventScroll:true});cards[next].scrollIntoView({block:'nearest',inline:'nearest',behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});
});
$('#wall').addEventListener('click',e=>{if(e.target===$('#wall')){const r=e.target.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)e.target.close()}});
new ResizeObserver(resize).observe($('.workspace'));
render();
