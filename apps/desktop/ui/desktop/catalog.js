// Discovery and subscription views use the same authenticated domain APIs as Web.
window.DesktopCatalog = (() => {
  const unwrap = value => value?.data ?? value;
  const html = value => escapeHtml(value);
  const pages = new Set(['discover','discoverCollection','discoverDetail','discoverPerson','subscriptions','subscriptionDetail']);
  const statusNames = {active:'进行中',paused:'已暂停',completed:'已完成',wanted:'等待资源',grabbed:'下载中',downloaded:'等待入库',imported:'已入库',downloading:'下载中',stalled:'下载停滞',error:'下载出错',missing:'任务已丢失',unknown:'状态未知'};
  const identity = () => JSON.stringify([API.baseUrl, App.session?.username || '']);
  const permissions = () => {
    const session = App.session || {}, admin = session.role === 'admin', caps = session.capabilities || {};
    const allowed = key => admin || caps[key] === true;
    return {admin, subscribe:allowed('allow_subscribe'), grab:allowed('allow_subscribe') && allowed('allow_search') && allowed('allow_direct_download')};
  };
  function preferences() {
    try { return JSON.parse(localStorage.getItem('mc_catalog:' + identity()) || '{}'); } catch { return {}; }
  }
  function enabled(page) {
    if (!pages.has(page)) return true;
    const key = page.startsWith('subscription') ? 'subscriptions' : 'discover';
    return preferences()[key] === true && (key !== 'subscriptions' || permissions().subscribe);
  }
  const option = (value, text, selected) => `<option value="${html(value)}" ${String(value) === String(selected) ? 'selected' : ''}>${html(text)}</option>`;
  const select = (id, label, values, selected) => `<label class="catalog-field">${html(label)}<select id="${id}" class="settings-select" aria-label="${html(label)}">${values.map(([value,text]) => option(value,text,selected)).join('')}</select></label>`;
  const checked = value => value ? 'checked' : '';
  const bytes = value => { let n = Number(value || 0), unit = 0; while (n >= 1024 && unit < 3) { n /= 1024; unit++; } return `${n.toFixed(unit ? 1 : 0)} ${['B','KB','MB','GB'][unit]}`; };
  const percent = value => value == null ? '—' : Math.round(Math.max(0,Math.min(1,Number(value))) * 100) + '%';
  const eta = value => value == null || value < 0 ? '未知' : value < 60 ? `${Math.ceil(value)} 秒` : `${Math.ceil(value / 60)} 分钟`;
  const time = value => value ? new Date(value).toLocaleString('zh-CN') : '—';
  const picture = (source, className = '') => `<div class="catalog-picture ${className}">${source ? `<img loading="lazy" decoding="async" data-fade style="opacity:0;transition:opacity .2s" src="${html(resolveUrl(source))}" alt="" data-raw="${html(source)}">` : ''}<span aria-hidden="true">${uiIcon('play')}</span></div>`;
  const progress = sub => { const p = sub.progress || {}; return `${Number(p.imported || 0)} / ${Number(p.total || 0)} 已入库${p.upgrading ? ` · ${p.upgrading} 正在洗版` : ''}`; };
  let view;
  let subscriptionCache;
  function nav() {
    const host = document.getElementById('catalogNav');
    if (!host) return;
    const prefs = preferences();
    host.innerHTML = [['subscriptions','我的订阅','bell'],['discover','发现','compass']].filter(([key]) => prefs[key] === true && (key !== 'subscriptions' || permissions().subscribe)).map(([key,label,icon]) => `<button class="nav-item" data-page="${key}" aria-label="${label}" title="${label}">${uiIcon(icon)}<span>${label}</span></button>`).join('');
    host.hidden = !host.children.length;
    host.querySelectorAll('button').forEach(button => button.addEventListener('click', () => App.selectTab(button.dataset.page)));
  }
  function settings(host) {
    const prefs = preferences(), canSubscribe = permissions().subscribe;
    const card = document.createElement('div'); card.className = 'settings-card catalog-navigation-settings';
    card.innerHTML = `<h3>导航入口</h3><p class="catalog-muted">按本机的服务器和账号保存。关闭入口不会停止 NAS 上的订阅和下载。</p>${[['subscriptions','我的订阅'],['discover','发现']].map(([key,label]) => `<div class="settings-row"><span>${label}${key === 'subscriptions' && !canSubscribe ? '<small class="catalog-muted">当前账号没有订阅权限</small>' : ''}</span><label class="settings-toggle"><input type="checkbox" id="setCatalog${key}" aria-label="显示${label}" ${checked(prefs[key] === true)} ${key === 'subscriptions' && !canSubscribe ? 'disabled' : ''}><span class="toggle-slider"></span></label></div>`).join('')}`;
    host.querySelector('.settings-body')?.insertBefore(card, host.querySelector('.settings-about'));
    card.querySelectorAll('input').forEach(input => input.addEventListener('change', () => {
      const key = input.id.replace('setCatalog','');
      localStorage.setItem('mc_catalog:' + identity(), JSON.stringify({...preferences(),[key]:input.checked}));
      nav();
      if (!enabled(App.currentPage)) { App.tabStates.clear(); App.selectTab('home'); }
    }));
  }
  class CatalogView {
    constructor(host, generation, params) {
      this.host = host; this.generation = generation; this.params = {...params}; this.owner = identity();
      this.signal = App._pageController.signal; this.api = App.pageAPI; this.disposed = false; this.rowSnapshots=new Map(); this.snapshotPending=new Set(); this.snapshotQueue=[]; this.snapshotWorkers=0;
      this.signal.addEventListener('abort', () => this.dispose(), {once:true});
    }
    alive() { return !this.disposed && identity() === this.owner && App.isCurrent(this.generation); }
    async request(path, options = {}) {
      const data = unwrap(await this.api.request(path, options));
      if (!this.alive()) throw new DOMException('页面已关闭','AbortError');
      return data;
    }
    async optional(path, statuses = [404,405,422]) {
      try { return await this.request(path); } catch(error) { if (statuses.includes(error.status)) return null; throw error; }
    }
    fail(error, host = this.host) {
      if (!this.alive() || error.name === 'AbortError') return;
      host.innerHTML = `<div class="catalog-error" role="alert"><h2>${error.status === 403 ? '当前账号没有权限' : [404,405,422].includes(error.status) ? '服务器暂不支持此功能' : '加载失败'}</h2><p>${html(error.message)}</p><button class="btn-secondary" data-retry>重试</button></div>`;
      host.querySelector('[data-retry]').onclick = () => App.navigate(App.currentPage, this.params, false);
    }
    loading() { this.host.innerHTML = '<div class="page-loading" role="status"><div class="spinner"></div><span>正在加载…</span></div>'; }
    back() { return `<button class="btn-secondary catalog-back" id="catalogBack">${uiIcon('left')}返回</button>`; }
    finish() {
      DesktopSelect.enhance(this.host);
      this.host.querySelector('#catalogBack')?.addEventListener('click', () => App.goBack());
      this.bindTitles(this.host);
    }
    poll(callback, delay) {
      clearTimeout(this.timer);
      this.timer = setTimeout(async () => {
        if (!this.alive()) return;
        try {
          if (!document.hidden && document.hasFocus() && document.getElementById('playerView')?.hidden !== false) await callback();
        } catch(error) {
          if (this.alive() && error.name !== 'AbortError') this.host.querySelector('#catalogRefreshState')?.replaceChildren(document.createTextNode('刷新失败，保留上次结果：' + error.message));
        }
        if (this.alive()) this.poll(callback, delay);
      }, delay);
    }
    async subscriptions() {
      const data = await this.request('/subscriptions');
      subscriptionCache = {owner:this.owner, rows:Array.isArray(data) ? data : []};
      return subscriptionCache.rows;
    }
    card(item) {
      const sub = subscriptionCache?.owner === this.owner ? subscriptionCache.rows.find(row => row.media?.kind === item.media_type && String(row.media?.tmdb_id) === String(item.external_id) && item.provider === 'tmdb' || row.media?.douban_id && item.provider === 'douban' && String(row.media.douban_id) === String(item.external_id)) : null;
      return `<article class="catalog-card"><button class="catalog-card-main" data-title-ref="${html(item.title_ref)}" aria-label="${html(item.title)}">${picture(item.poster_url)}<strong>${html(item.title)}</strong><small>${html([item.release_year,item.provider_rating ? `${item.provider_rating} 分` : null].filter(Boolean).join(' · '))}</small></button><div class="catalog-card-status">${item.library_status?.file_count ? '<span>已入库</span>' : ''}${sub ? `<button class="text-button" data-subscription="${Number(sub.id)}">已订阅</button>` : permissions().subscribe ? `<button class="text-button" data-subscribe-ref="${html(item.title_ref)}">订阅</button>` : ''}</div></article>`;
    }
    bindTitles(host) {
      host.querySelectorAll('[data-title-ref]').forEach(button => button.onclick = () => App.navigate('discoverDetail',{reference:button.dataset.titleRef}));
      host.querySelectorAll('[data-subscription]').forEach(button => button.onclick = () => enabled('subscriptionDetail') ? App.navigate('subscriptionDetail',{id:Number(button.dataset.subscription)}) : this.openSubscription(Number(button.dataset.subscription)));
      host.querySelectorAll('[data-subscribe-ref]').forEach(button => button.onclick = () => this.subscribe(button.dataset.subscribeRef));
      host.querySelectorAll('[data-person]').forEach(button => button.onclick = () => App.navigate('discoverPerson',{id:Number(button.dataset.person)}));
    }
    dispose() { this.disposed = true; this.downloadObserver?.disconnect(); clearTimeout(this.timer); this.closeDialog(); }
    closeDialog() { this.dialogController?.abort(); clearTimeout(this.dialogTimer); this.dialog?.close(); this.dialog?.remove(); this.dialog = null; this.dialogEpoch = (this.dialogEpoch || 0) + 1; }
    dialogBox(title) {
      this.closeDialog();
      this.dialogController = new AbortController();
      const dialog = this.dialog = document.createElement('dialog'); dialog.className = 'catalog-dialog';
      dialog.innerHTML = `<header><h2>${html(title)}</h2><button class="titlebar-btn" aria-label="关闭">${uiIcon('close')}</button></header><div class="catalog-dialog-body"><div role="status">正在加载…</div></div>`;
      document.body.appendChild(dialog); dialog.querySelector('header button').onclick = () => this.closeDialog();
      dialog.addEventListener('cancel', event => { event.preventDefault(); this.closeDialog(); }); dialog.showModal();
      const epoch = this.dialogEpoch, current = () => this.alive() && this.dialog === dialog && this.dialogEpoch === epoch;
      return {dialog, body:dialog.querySelector('.catalog-dialog-body'), current, signal:this.dialogController.signal};
    }
    dialogError(context, error) {
      if (!context.current() || error.name === 'AbortError') return;
      let alert = context.body.querySelector('[role="alert"]');
      if (!alert) { alert = document.createElement('p'); alert.className = 'catalog-error'; alert.setAttribute('role','alert'); context.body.prepend(alert); }
      alert.textContent = error.message;
    }
    async loadSubscriptionsForDiscovery() {
      if (permissions().subscribe) await this.subscriptions();
    }
    discoveryControls() {
      const p = this.params;
      return `<div class="catalog-toolbar">${select('discoverKind','类型',[['movie','电影'],['tv','剧集']],p.kind || 'movie')}${select('discoverProvider','来源',[['tmdb','TMDB'],['douban','豆瓣']],p.provider || 'tmdb')}<form id="discoverSearch"><input id="discoverQuery" aria-label="搜索影视" placeholder="搜索影视资料" value="${html(p.query || '')}"><button class="btn-secondary">搜索</button></form><button class="btn-secondary" id="discoverFilters" ${(p.provider || 'tmdb') !== 'tmdb' ? 'disabled' : ''}>筛选</button><button class="btn-secondary" id="catalogRefresh">刷新</button></div>`;
    }
    bindDiscoveryControls() {
      const change = patch => App.navigate('discover',{...this.params,...patch,page:1},false);
      this.host.querySelector('#discoverKind').onchange = event => change({kind:event.target.value,collection:null});
      this.host.querySelector('#discoverProvider').onchange = event => change({provider:event.target.value,filters:null,query:''});
      this.host.querySelector('#discoverSearch').onsubmit = event => { event.preventDefault(); change({query:this.host.querySelector('#discoverQuery').value.trim(),filters:null}); };
      this.host.querySelector('#discoverFilters').onclick = () => this.filters();
      this.host.querySelector('#catalogRefresh').onclick = () => App.navigate('discover',this.params,false);
    }
    async discover() {
      this.loading();
      try {
        const p = this.params, kind = p.kind || 'movie', provider = p.provider || 'tmdb';
        await this.loadSubscriptionsForDiscovery();
        if (p.query || p.filters) {
          const page = Math.max(1,Number(p.page) || 1), query = new URLSearchParams({media_type:kind,page});
          for (const [key,value] of Object.entries(p.filters || {})) if (value !== '') { for (const v of Array.isArray(value) ? value : [value]) query.append(key,v); }
          const result = p.query ? await this.request('/search/titles',{method:'POST',body:{query:p.query,provider,save_history:false},cancelable:true}) : await this.request('/discover/titles?' + query);
          this.host.innerHTML = `<div class="catalog-page"><h1>发现</h1>${this.discoveryControls()}${p.filters ? '<button id="clearFilters" class="text-button">清除筛选</button>' : ''}<div class="catalog-muted">${html((result.providers || []).filter(row=>!row.success).map(row=>row.message).join(' · '))}</div><div class="catalog-grid">${(result.titles || []).map(item=>this.card(item)).join('') || '<p class="catalog-muted">没有匹配的影视</p>'}</div>${!p.query ? `<div class="catalog-paging"><button class="btn-secondary" id="catalogPrevious" ${page === 1 ? 'disabled' : ''}>上一页</button><span>第 ${page} 页</span><button class="btn-secondary" id="catalogNext" ${!result.has_more ? 'disabled' : ''}>下一页</button></div>` : ''}</div>`;
          this.host.querySelector('#clearFilters')?.addEventListener('click',()=>App.navigate('discover',{kind,provider},false));
          this.host.querySelector('#catalogPrevious')?.addEventListener('click',()=>App.navigate('discover',{...p,page:page-1},false));
          this.host.querySelector('#catalogNext')?.addEventListener('click',()=>App.navigate('discover',{...p,page:page+1},false));
        } else {
          const manifest = await this.request(`/ui/discovery/${kind}?provider=${provider}`);
          this.host.innerHTML = `<div class="catalog-page"><h1>发现</h1>${this.discoveryControls()}<div id="discoverySections"></div></div>`;
          this.finish();this.bindDiscoveryControls();
          const sections = this.host.querySelector('#discoverySections');
          for (const section of manifest.sections || []) {
            const holder = document.createElement('section'); holder.className = 'catalog-section';
            holder.innerHTML = `<div class="catalog-section-heading"><h2>${html(section.title)}</h2>${section.supports_full_listing ? '<button class="text-button">查看全部</button>' : ''}</div><div class="catalog-shelf" role="status">正在加载…</div>`;
            sections.appendChild(holder);
            holder.querySelector('button')?.addEventListener('click',()=>App.navigate('discoverCollection',{reference:section.collection_ref,title:section.title,page:1}));
            try {
              const data = await this.request(`/discover/collections/${encodeURIComponent(section.collection_ref)}/titles?limit=${Math.min(20,Math.max(1,Number(section.preview_limit) || 12))}&page=1`);
              holder.querySelector('.catalog-shelf').innerHTML = (data.titles || []).map(item=>this.card(item)).join('') || '<p>暂无内容</p>';
              holder.querySelector('.catalog-shelf').removeAttribute('role'); this.bindTitles(holder);
            } catch(error) { if (!this.alive()) return; holder.querySelector('.catalog-shelf').textContent = error.message; }
          }
        }
        if (!this.alive()) return;
        this.finish(); this.bindDiscoveryControls();
      } catch(error) { this.fail(error); }
    }
    async filters() {
      const c = this.dialogBox('发现筛选');
      try {
        const result = await this.request('/discover/filters?media_type=' + (this.params.kind || 'movie'),{signal:c.signal});
        if (!c.current()) return;
        const p = this.params.filters || {};
        c.body.innerHTML = `<form id="discoveryFilterForm"><div class="catalog-form-grid"><fieldset class="catalog-seasons"><legend>类型（可多选）</legend>${(result.genres || []).map(g=>`<label><input name="filterGenre" type="checkbox" value="${g.id}" ${checked((p.genre_ids || []).map(String).includes(String(g.id)))}>${html(g.name)}</label>`).join('')}</fieldset>${select('filterCountry','地区',[['','不限'],['CN','中国大陆'],['HK','中国香港'],['TW','中国台湾'],['US','美国'],['GB','英国'],['JP','日本'],['KR','韩国'],['FR','法国'],['DE','德国'],['IN','印度'],['CA','加拿大'],['AU','澳大利亚']],p.origin_country || '')}<label class="catalog-field">年份<input id="filterYear" aria-label="年份" type="number" min="1888" max="${new Date().getFullYear()+5}" value="${html(p.year || '')}"></label><label class="catalog-field">最低评分<input id="filterRating" aria-label="最低评分" type="number" min="0" max="10" step="0.5" value="${html(p.rating_gte ?? '')}"></label><label class="catalog-field">最长片长（分钟）<input id="filterRuntime" aria-label="最长片长" type="number" min="1" value="${html(p.runtime_lte || '')}"></label>${select('filterSort','排序',[['popular','热门'],['rating','评分'],['newest','最近上映'],['most-rated','最多评分']],p.sort || 'popular')}</div><button class="btn-play">查看结果</button></form>`;
        DesktopSelect.enhance(c.body);
        c.body.querySelector('form').onsubmit = event => {
          event.preventDefault(); const value = id => c.body.querySelector('#'+id).value;
          App.navigate('discover',{...this.params,query:'',page:1,filters:{genre_ids:[...c.body.querySelectorAll('[name="filterGenre"]:checked')].map(i=>i.value),origin_country:value('filterCountry').toUpperCase(),year:value('filterYear'),rating_gte:value('filterRating'),runtime_lte:value('filterRuntime'),sort:value('filterSort')}},false);
        };
      } catch(error) { this.dialogError(c,error); }
    }
    async collection() {
      this.loading();
      try {
        const p = this.params, page = Math.max(1,Number(p.page) || 1);
        await this.loadSubscriptionsForDiscovery();
        const result = await this.request(`/discover/collections/${encodeURIComponent(p.reference)}/titles?limit=40&page=${page}`);
        this.host.innerHTML = `<div class="catalog-page">${this.back()}<h1>${html(result.collection?.name || p.title || '片单')}</h1><div class="catalog-grid">${(result.titles || []).map(item=>this.card(item)).join('')}</div><div class="catalog-paging"><button class="btn-secondary" id="catalogPrevious" ${page===1?'disabled':''}>上一页</button><span>第 ${page} 页</span><button class="btn-secondary" id="catalogNext" ${!result.has_more?'disabled':''}>下一页</button></div></div>`;
        this.finish(); this.host.querySelector('#catalogPrevious').onclick=()=>App.navigate('discoverCollection',{...p,page:page-1},false); this.host.querySelector('#catalogNext').onclick=()=>App.navigate('discoverCollection',{...p,page:page+1},false);
      } catch(error) { this.fail(error); }
    }
    async externalLink(url, c) {
      try { await window.__TAURI__.core.invoke('open_catalog_link',{url}); }
      catch(error){if(c?.current())this.dialogError(c,new Error(typeof error==='string'?error:error.message));else if(this.alive())this.host.querySelector('#catalogLinkState').textContent=typeof error==='string'?error:error.message;}
    }
    async titleDetail() {
      this.loading();
      try {
        await this.loadSubscriptionsForDiscovery();
        const data = await this.request('/discover/titles/' + encodeURIComponent(this.params.reference)), item = data.title, metadata = data.metadata || {};
        const sub = subscriptionCache?.rows.find(row=>item.provider==='tmdb' ? row.media?.kind===item.media_type && String(row.media?.tmdb_id)===String(item.external_id) : String(row.media?.douban_id)===String(item.external_id));
        const links = data.library_links || [];
        this.host.innerHTML = `<div class="catalog-page">${this.back()}<section class="catalog-title-detail">${picture(item.poster_url)}<div><small>${html(item.provider?.toUpperCase())}</small><h1>${html(item.title)}</h1><p>${html([item.original_title,item.release_year,item.provider_rating ? item.provider_rating+' 分' : '',...(item.genres || [])].filter(Boolean).join(' · '))}</p><p class="catalog-overview">${html(item.overview || '暂无简介')}</p><div class="catalog-actions">${sub ? `<button class="btn-secondary" data-subscription="${Number(sub.id)}">查看订阅 · ${html(statusNames[sub.status])}</button>` : permissions().subscribe && !(item.media_type==='movie' && item.library_status?.file_count) ? `<button class="btn-play" data-subscribe-ref="${html(item.title_ref)}">订阅追踪</button>` : ''}${links.map((link,index)=>`<button class="btn-secondary" data-library-link="${index}">在${html(link.library_name)}中查看</button>`).join('')}</div></div></section><div class="catalog-facts"><span>地区：${html(metadata.country || '未知')}</span><span>语言：${html(metadata.language || '未知')}</span><span>上映：${html(metadata.released || '未知')}</span></div><section class="catalog-section"><h2>演职员</h2><div class="catalog-people">${[...(metadata.director_credits || []),...(metadata.cast || [])].map(person=>`<button class="catalog-person" ${person.tmdb_person_id ? `data-person="${Number(person.tmdb_person_id)}"` : 'disabled'}>${picture(person.avatar_url)}<strong>${html(person.name)}</strong><small>${html(person.role || '导演')}</small></button>`).join('')}</div></section>${data.collection?.titles?.length ? `<section class="catalog-section"><h2>${html(data.collection.name)}</h2><div class="catalog-shelf">${data.collection.titles.map(t=>this.card(t)).join('')}</div></section>` : ''}<section class="catalog-section"><h2>相关推荐</h2><div class="catalog-shelf">${(data.recommendations || []).map(t=>this.card(t)).join('')}</div></section></div>`;
        const more=document.createElement('section');more.className='catalog-section';
        const images=[...(data.backdrops || []),...(data.posters || [])], videos=data.videos || [];
        more.innerHTML=`${metadata.source_url?'<button class="btn-secondary" id="catalogSource">查看资料来源</button>':''}<p id="catalogLinkState" class="catalog-muted" role="status"></p>${videos.length?`<h2>预告片</h2><div class="catalog-shelf">${videos.map((video,index)=>`<button class="catalog-video" data-video="${index}">${picture(video.thumbnail_url)}<strong>${html(video.name)}</strong></button>`).join('')}</div>`:''}${images.length?`<h2>图片</h2><div class="catalog-shelf">${images.map((image,index)=>`<button class="catalog-video" data-still="${index}" aria-label="查看图片 ${index+1}">${picture(image.preview_url)}</button>`).join('')}</div>`:''}`;
        this.host.querySelector('.catalog-page').appendChild(more);
        more.querySelector('#catalogSource')?.addEventListener('click',()=>this.externalLink(metadata.source_url));
        more.querySelectorAll('[data-video]').forEach(button=>button.onclick=()=>this.externalLink(videos[Number(button.dataset.video)].watch_url));
        more.querySelectorAll('[data-still]').forEach(button=>button.onclick=()=>{const c=this.dialogBox('图片预览');c.body.innerHTML=picture(images[Number(button.dataset.still)].full_url,'catalog-image-preview');});
        this.finish(); this.host.querySelectorAll('[data-library-link]').forEach(button=>button.onclick=()=>{const link=links[Number(button.dataset.libraryLink)]; App.navigate('detail',{libraryId:link.library_id,itemId:link.media_item_id});});
      } catch(error) { this.fail(error); }
    }
    async person() {
      this.loading();
      try {
        const data = await this.request('/discover/people/' + Number(this.params.id));
        await this.loadSubscriptionsForDiscovery();
        this.host.innerHTML = `<div class="catalog-page">${this.back()}<h1>${html(data.name)}</h1><div class="catalog-grid">${(data.titles || []).map(item=>this.card(item)).join('')}</div></div>`; this.finish();
      } catch(error) { this.fail(error); }
    }
    async subscriptionList() {
      this.loading();
      try {
        const [rows,week,recent] = await Promise.all([this.subscriptions(),this.optional('/subscriptions/today-arrivals?window=week'),this.optional('/subscriptions/recent-arrivals')]);
        this.rows = rows; this.week = week || []; this.recent = recent || [];
        const p = this.params;
        this.host.innerHTML = `<div class="catalog-page"><div class="catalog-page-heading"><h1>我的订阅</h1><div class="catalog-actions"><button class="btn-secondary" id="catalogRefresh">刷新</button>${permissions().admin ? '<button class="btn-secondary" id="catalogRules">规则组</button><button class="btn-secondary" id="catalogHealth">入库链路</button>' : ''}</div></div><div class="catalog-summary" id="subscriptionSummary"></div><div class="catalog-toolbar">${select('subscriptionKind','类型',[['','全部'],['movie','电影'],['tv','剧集']],p.kind || '')}${select('subscriptionStatus','状态',[['','全部'],['active','进行中'],['paused','已暂停'],['completed','已完成']],p.status || '')}<input id="subscriptionQuery" aria-label="搜索订阅" placeholder="搜索订阅片名" value="${html(p.query || '')}">${select('subscriptionView','视图',[['list','列表'],['poster','海报']],p.layout || 'list')}</div><p id="catalogRefreshState" class="catalog-muted" role="status"></p><div id="subscriptionList"></div><div id="subscriptionSchedule"></div><div id="subscriptionRecent"></div></div>`;
        this.renderSubscriptionRows(); this.renderSchedule(); this.finish();
        for (const [id,key] of [['subscriptionKind','kind'],['subscriptionStatus','status'],['subscriptionView','layout']]) this.host.querySelector('#'+id).onchange = event => { this.params[key]=event.target.value; App.currentParams={...this.params}; this.renderSubscriptionRows(); };
        this.host.querySelector('#subscriptionQuery').oninput=event=>{this.params.query=event.target.value;App.currentParams={...this.params};this.renderSubscriptionRows();};
        this.host.querySelector('#catalogRefresh').onclick=()=>App.navigate('subscriptions',this.params,false);
        this.host.querySelector('#catalogRules')?.addEventListener('click',()=>this.ruleSets());
        this.host.querySelector('#catalogHealth')?.addEventListener('click',()=>this.health());
        let ticks = 0;
        this.poll(async()=>{
          const fresh = await this.subscriptions(); this.rows=fresh; this.renderSubscriptionRows();
          this.week=await this.optional('/subscriptions/today-arrivals?window=week') || [];
          if (++ticks % 2 === 0) this.recent=await this.optional('/subscriptions/recent-arrivals') || [];
          this.renderSchedule(); this.host.querySelector('#catalogRefreshState').textContent='已刷新 ' + new Date().toLocaleTimeString('zh-CN');
        },10000);
      } catch(error) { this.fail(error); }
    }
    filteredSubscriptions(rows = this.rows || []) {
      const p=this.params, query=(p.query || '').toLowerCase();
      return rows.filter(sub=>(!p.kind || sub.media.kind===p.kind) && (!p.status || sub.status===p.status) && (!query || (sub.media.title || '').toLowerCase().includes(query)));
    }
    renderSubscriptionRows() {
      if (!this.alive()) return;
      const counts={active:0,downloading:0,imported:0,wanted:0};
      for(const sub of this.rows){counts.active+=sub.status==='active';counts.downloading+=Number(sub.progress?.grabbed || 0);counts.imported+=Number(sub.progress?.imported || 0);counts.wanted+=Number(sub.progress?.wanted || 0);}
      this.host.querySelector('#subscriptionSummary').innerHTML=[['正在追踪',counts.active],['正在下载的单元',counts.downloading],['已入库的单元',counts.imported],['等待资源的单元',counts.wanted]].map(([name,value])=>`<div><strong>${value}</strong><span>${name}</span></div>`).join('');
      const host=this.host.querySelector('#subscriptionList'), rows=this.filteredSubscriptions();
      host.className=this.params.layout==='poster' ? 'catalog-grid' : 'catalog-subscription-list';
      replaceContentPreservingImages(host,rows.map(sub=>`<button class="catalog-subscription ${this.params.layout==='poster'?'catalog-subscription-poster':''}" data-subscription="${Number(sub.id)}">${picture(sub.media.poster_url)}<div><strong>${html(sub.media.title)}</strong><small>${html(sub.media.kind==='tv' ? (sub.selected_seasons || []).map(n=>`第 ${n} 季`).join(' · ') || '剧集' : '电影')} · ${html(statusNames[sub.status] || sub.status)}</small><progress max="${Math.max(1,Number(sub.progress?.total || 0))}" value="${Number(sub.progress?.imported || 0)}" aria-label="入库进度"></progress><small>${html(progress(sub))}</small>${sub.progress?.grabbed?`<small data-download-summary="${sub.id}">${html(this.rowSnapshots.get(sub.id) || '正在读取下载进度…')}</small>`:''}</div>${uiIcon('right')}</button>`).join('') || '<div class="empty-state">没有匹配的订阅。开启“发现”后可以浏览和订阅影片。</div>');
      this.bindTitles(host);this.observeDownloads(host);
    }
    observeDownloads(host) {
      this.downloadObserver?.disconnect();
      this.downloadObserver=new IntersectionObserver(entries=>{for(const entry of entries)if(entry.isIntersecting){const id=Number(entry.target.dataset.downloadSummary);this.downloadObserver.unobserve(entry.target);if(!this.snapshotPending.has(id)){this.snapshotPending.add(id);this.snapshotQueue.push(id);}}this.drainDownloads();},{root:document.getElementById('content')});
      host.querySelectorAll('[data-download-summary]').forEach(row=>this.downloadObserver.observe(row));
    }
    drainDownloads() {
      while(this.alive() && this.snapshotWorkers<2 && this.snapshotQueue.length){
        const id=this.snapshotQueue.shift();this.snapshotWorkers++;
        (async()=>{try {
          if(document.hidden || !document.hasFocus() || document.getElementById('playerView')?.hidden===false)return;
          const rows=await this.optional(`/subscriptions/${id}/active-downloads`);
          const text=rows===null?'服务器暂不提供下载快照':rows.length?rows.map(row=>this.downloadText(row)).join('；'):'暂无在途下载，等待服务器状态确认';
          this.rowSnapshots.set(id,text);const label=this.host.querySelector(`[data-download-summary="${id}"]`);if(label)label.textContent=text;
        }catch(error){if(this.alive())this.host.querySelector(`[data-download-summary="${id}"]`)?.replaceChildren(document.createTextNode('进度暂不可用，点击查看详情'));}
        finally{this.snapshotWorkers--;this.snapshotPending.delete(id);this.drainDownloads();}})();
      }
    }
    downloadText(row) {
      if(row.state==='completed')return `${percent(row.progress)} · 下载已完成，等待服务器入库确认`;
      return `${percent(row.progress)} · ${statusNames[row.state] || row.state} · ${bytes(row.dlspeed_bytes)}/s · 预计 ${eta(row.eta_seconds)}`;
    }
    renderSchedule() {
      if(!this.alive())return;
      this.host.querySelector('#subscriptionSchedule').innerHTML=`<section class="catalog-section"><h2>一周日程</h2><div class="catalog-agenda">${this.week.map(row=>`<button data-subscription="${Number(row.subscription_id)}"><time>${html(row.expected_day)}</time><strong>${html(row.media_title)}</strong><span>${row.media_kind==='tv'?`S${Number(row.season_number)}E${Number(row.episode_number)} · `:''}${html(statusNames[row.status] || row.status)}</span></button>`).join('') || '<p class="catalog-muted">近期暂无安排</p>'}</div></section>`;
      this.host.querySelector('#subscriptionRecent').innerHTML=`<section class="catalog-section"><h2>刚刚入库</h2><div class="catalog-shelf">${this.recent.map((row,index)=>`<article class="catalog-recent">${picture(row.still_url || row.media?.backdrop_url || row.media?.poster_url)}<strong>${html(row.media?.title)}</strong><div class="catalog-actions"><button class="text-button" data-subscription="${Number(row.subscription_id)}">查看订阅</button>${row.units?.length ? `<button class="text-button" data-recent="${index}">播放</button>` : ''}</div></article>`).join('') || '<p class="catalog-muted">最近暂无入库内容</p>'}</div></section>`;
      this.bindTitles(this.host.querySelector('#subscriptionSchedule')); this.bindTitles(this.host.querySelector('#subscriptionRecent'));
      this.host.querySelectorAll('[data-recent]').forEach(button=>button.onclick=()=>{const row=this.recent[Number(button.dataset.recent)],unit=row.units[0];App.startPlayback({...row.media,seasonNumber:row.season_number ?? unit.season_number,episodeNumber:row.episode_number ?? unit.episode_number});});
    }
    async subscriptionDetail() {
      this.loading();
      try {
        const id=Number(this.params.id);
        const [detail,downloads,activities,rows]=await Promise.all([this.request(`/subscriptions/${id}`),this.optional(`/subscriptions/${id}/active-downloads`),this.request(`/subscriptions/${id}/activities?limit=100`),this.subscriptions()]);
        this.detail=detail;this.downloads=downloads || [];this.activities=activities || [];
        this.host.innerHTML=`<div class="catalog-page">${this.back()}<div class="catalog-inspector-layout"><aside class="catalog-inspector-list" aria-label="其他订阅">${rows.map(sub=>`<button class="${sub.id===id?'active':''}" data-subscription="${Number(sub.id)}"><strong>${html(sub.media.title)}</strong><small>${html(progress(sub))}</small></button>`).join('')}</aside><div id="subscriptionInspector"></div></div><p id="catalogRefreshState" class="catalog-muted" role="status"></p></div>`;
        this.renderInspector(this.host.querySelector('#subscriptionInspector'));this.finish();
        let ticks=0;
        this.poll(async()=>{
          const active=this.detail.wanted?.some(row=>['grabbed','downloaded'].includes(row.status)) || this.detail.selection_mode==='smart';
          if(active)this.downloads=await this.optional(`/subscriptions/${id}/active-downloads`) || [];
          if(++ticks%6===0){await this.reloadInspector(this.host.querySelector('#subscriptionInspector'),id);}
          // Update live data without replacing focused controls or expanded history.
          this.renderUnits(this.host.querySelector('#subscriptionUnits'));
          this.host.querySelector('#subscriptionProgress').textContent=progress(this.detail);
          this.host.querySelector('#catalogRefreshState').textContent='已刷新 ' + new Date().toLocaleTimeString('zh-CN');
        },5000);
      } catch(error){this.fail(error);}
    }
    async openSubscription(id) {
      const c=this.dialogBox('订阅进程');
      try {
        const [detail,downloads,activities]=await Promise.all([this.request(`/subscriptions/${id}`,{signal:c.signal}),this.optional(`/subscriptions/${id}/active-downloads`),this.request(`/subscriptions/${id}/activities?limit=100`,{signal:c.signal})]);
        if(!c.current())return; this.detail=detail;this.downloads=downloads || [];this.activities=activities || [];this.renderInspector(c.body);
        const refresh=async()=>{if(!c.current())return;try{if(!document.hidden && document.hasFocus() && document.getElementById('playerView')?.hidden!==false)await this.reloadInspector(c.body,id);}catch(error){this.dialogError(c,error);}if(c.current())this.dialogTimer=setTimeout(refresh,10000);};this.dialogTimer=setTimeout(refresh,10000);
      } catch(error){this.dialogError(c,error);}
    }
    renderInspector(host) {
      const d=this.detail, allowed=permissions().subscribe && d.can_manage===true;
      replaceContentPreservingImages(host,`<div class="catalog-inspector"><div class="catalog-inspector-heading">${picture(d.media.poster_url)}<div><h1>${html(d.media.title)}</h1><p>${html(statusNames[d.status] || d.status)}${d.follow_future?' · 自动追踪未来季':''}</p><p id="subscriptionProgress">${html(progress(d))}</p><p>${html(d.selection_mode==='smart'?'智能选择':'规则选择')}</p></div></div><div class="catalog-actions">${allowed?`<button class="btn-secondary" id="subscriptionTracking">${d.status==='paused'?'恢复追踪':'暂停追踪'}</button><button class="btn-secondary" id="subscriptionAdjust">调整订阅</button><button class="btn-secondary" id="subscriptionMissing">搜索缺失资源</button><button class="btn-secondary" id="subscriptionUpgrade">洗一轮版</button>${permissions().grab?'<button class="btn-secondary" id="subscriptionGrab">手动选种</button>':''}`:''}${permissions().subscribe?'<button class="btn-secondary" id="subscriptionUnfollow">取消关注</button>':''}${permissions().admin?'<button class="btn-secondary btn-danger" id="subscriptionRemove">移除订阅</button>':''}<button class="btn-secondary" id="subscriptionReload">刷新</button></div><p id="subscriptionActionState" role="status" class="catalog-muted"></p>${d.episode_hints?.length?`<section class="catalog-notice"><h2>集数有新提示</h2>${d.episode_hints.map(h=>`<p>第 ${Number(h.season_number)} 季：TMDB ${Number(h.tmdb_count)} 集，建议 ${Number(h.suggested)} 集</p>`).join('')}<small>可在“调整订阅”中确认每季集数下限。</small></section>`:''}<div id="subscriptionUnits"></div><details class="catalog-history"><summary>排查记录 · ${(this.activities || []).length} 条</summary>${(this.activities || []).map(a=>`<p><time>${html(time(a.created_at))}</time>${html(a.message)}</p>`).join('') || '<p>暂无记录</p>'}</details></div>`);
      this.renderUnits(host.querySelector('#subscriptionUnits'));
      const run=async(path,method,body)=>{
        if(!allowed)return;
        const buttons=[...host.querySelectorAll('.catalog-actions button')];buttons.forEach(b=>b.disabled=true);
        try{await this.request(path,{method,body});subscriptionCache=null;if(this.alive())await this.reloadInspector(host,d.id);}
        catch(error){if(this.alive())host.querySelector('#subscriptionActionState').textContent=error.message;}
        finally{if(this.alive())buttons.forEach(b=>b.disabled=false);}
      };
      host.querySelector('#subscriptionTracking')?.addEventListener('click',()=>run(`/subscriptions/${d.id}/tracking-state`,'PATCH',{state:d.status==='paused'?'active':'paused'}));
      host.querySelector('#subscriptionMissing')?.addEventListener('click',()=>run(`/subscriptions/${d.id}/missing-resource-searches`,'POST'));
      host.querySelector('#subscriptionAdjust')?.addEventListener('click',()=>this.adjust(d));
      host.querySelector('#subscriptionUpgrade')?.addEventListener('click',()=>this.upgrade(d));
      host.querySelector('#subscriptionGrab')?.addEventListener('click',()=>this.grab(d));
      host.querySelector('#subscriptionUnfollow')?.addEventListener('click',()=>this.remove(d,false));
      host.querySelector('#subscriptionRemove')?.addEventListener('click',()=>this.remove(d,true));
      host.querySelector('#subscriptionReload').onclick=()=>this.reloadInspector(host,d.id).catch(error=>{if(this.alive())host.querySelector('#subscriptionActionState').textContent=error.message;});
    }
    async reloadInspector(host,id) {
      const [detail,downloads,activities]=await Promise.all([this.request(`/subscriptions/${id}`),this.optional(`/subscriptions/${id}/active-downloads`),this.request(`/subscriptions/${id}/activities?limit=100`)]);
      if(!host.isConnected)return;
      const expanded=host.querySelector('.catalog-history')?.open,focused=document.activeElement?.id;this.detail=detail;this.downloads=downloads || [];this.activities=activities || [];this.renderInspector(host);if(expanded)host.querySelector('.catalog-history').open=true;if(focused)host.querySelector('#'+focused)?.focus({preventScroll:true});
    }
    renderUnits(host) {
      if(!host || !this.alive())return;
      const d=this.detail, focused=document.activeElement?.closest('[data-smart-wanted]'), focusKey=focused?{id:focused.dataset.smartWanted,action:focused.dataset.smartAction}:null;
      host.innerHTML=(d.wanted || []).map(unit=>{
        const download=(this.downloads || []).find(row=>row.info_hash && row.info_hash===unit.info_hash);
        const chain=[['播出',unit.air_date],['搜索',unit.last_search_at],['投递',unit.grabbed_at],['下载',unit.downloaded_at],['入库',unit.imported_at]];
        const smart=unit.selection_state,stage={grabbed:2,downloaded:3,imported:4}[unit.status] ?? -1;
        return `<article class="catalog-unit"><div class="catalog-unit-heading"><strong>${d.media.kind==='tv'?`S${Number(unit.season_number)}E${Number(unit.episode_number)}`:'影片'}</strong><span>${html(unit.status==='grabbed' && download?.state==='completed'?'下载已完成 · 待入库确认':statusNames[unit.status] || unit.status)}</span>${unit.upgrade?.active?'<span>洗版中</span>':''}</div><ol class="catalog-chain">${chain.map(([name,date],index)=>`<li class="${date || stage>=index?'recorded':''}"><strong>${name}</strong><small>${html(date?time(date):stage>=index?'时间未记录':'等待')}</small></li>`).join('')}</ol>${download?`<div class="catalog-download"><progress max="1" value="${Number(download.progress || 0)}" aria-label="下载进度"></progress><span>${html(this.downloadText(download))}</span>${download.error_message?`<p class="catalog-error">${html(download.error_message)}</p>`:''}</div>`:''}${unit.last_reject_reason?`<p class="catalog-muted">最近未采用：${html(unit.last_reject_reason)}</p>`:''}${unit.grab_title?`<p class="catalog-muted">已投递：${html(unit.grab_title)}</p>`:''}${unit.upgrade?`<p class="catalog-muted">${html(unit.upgrade.current_label)} → ${html(unit.upgrade.target_label)}${unit.upgrade.indeterminate?' · 当前版本规格尚无法确认':''}</p>`:''}${smart?`<p class="catalog-muted">${html(smart.wait_explanation || smart.reason)}${smart.deadline?' · 等待至 '+html(time(smart.deadline)):''}</p>${d.can_manage && permissions().subscribe?`<div class="catalog-actions"><button class="text-button" data-smart-wanted="${unit.id}" data-smart-action="extend">再等待 30 分钟</button>${smart.candidate_key?`<button class="text-button" data-smart-wanted="${unit.id}" data-smart-action="choose">采用当前候选</button>`:''}</div>`:''}`:''}</article>`;
      }).join('') || '<div class="empty-state">暂无追踪单元</div>';
      if(focusKey)host.querySelector(`[data-smart-wanted="${focusKey.id}"][data-smart-action="${focusKey.action}"]`)?.focus({preventScroll:true});
      host.querySelectorAll('[data-smart-wanted]').forEach(button=>button.onclick=()=>{
        const unit=d.wanted.find(w=>Number(w.id)===Number(button.dataset.smartWanted));
        this.confirmMutation('调整智能等待',button.dataset.smartAction==='choose'?'将采用服务器当前候选并投递下载。':'将该单元的等待窗口延长 30 分钟。',`/subscriptions/${d.id}/wanted/${unit.id}/smart-wait`,'POST',{version:unit.selection_version,...(button.dataset.smartAction==='choose'?{candidate_key:unit.selection_state.candidate_key}:{extend_seconds:1800})});
      });
    }
    async submit(c, form, operation) {
      if(!c.current() || c.busy)return;
      c.busy=true;
      const button=form.querySelector('[type="submit"]'); if(button)button.disabled=true;
      c.body.querySelector('[role="alert"]')?.remove();
      try{await operation();}catch(error){this.dialogError(c,error);}
      finally{c.busy=false;if(c.current() && button)button.disabled=false;}
    }
    async changed(id) {
      subscriptionCache=null;
      if(!this.alive())return;
      this.closeDialog();
      if(id && enabled('subscriptionDetail'))await App.navigate('subscriptionDetail',{id});
      else await App.navigate(App.currentPage==='subscriptionDetail'?'subscriptions':App.currentPage,this.params,false);
    }
    async confirmMutation(title, message, path, method, body) {
      const c=this.dialogBox(title);
      c.body.innerHTML=`<p>${html(message)}</p><form><button class="btn-play" type="submit">确认</button></form>`;
      c.body.querySelector('form').onsubmit=event=>{event.preventDefault();this.submit(c,event.target,async()=>{await this.request(path,{method,body});subscriptionCache=null;if(c.current())await this.changed(this.detail?.id);});};
    }
    async subscribe(reference, sourceReference) {
      if(!permissions().subscribe)return;
      const c=this.dialogBox('订阅追踪');
      try {
        const prepared=await this.request('/subscriptions/title-preview',{method:'POST',body:{title_ref:reference},signal:c.signal,cancelable:true});
        if(!c.current())return;
        if(prepared.status==='ambiguous'){
          c.body.innerHTML=`<p>请确认要订阅的作品</p><div class="catalog-candidates">${(prepared.candidates || []).map((row,index)=>`<button class="btn-secondary" data-candidate="${index}">${html(row.title)} · ${html(row.year)}</button>`).join('')}</div>`;
          c.body.querySelectorAll('[data-candidate]').forEach(button=>button.onclick=()=>this.subscribe(prepared.candidates[Number(button.dataset.candidate)].title_ref,sourceReference || reference));return;
        }
        if(prepared.status!=='ready' || !prepared.media){c.body.innerHTML='<p>未能匹配到可订阅的作品，请从其他来源确认。</p>';return;}
        if(prepared.existing_subscription_id){await this.openSubscription(prepared.existing_subscription_id);return;}
        const kind=prepared.media.kind, admin=permissions().admin;
        const [rules,profile,routing]=await Promise.all([admin?this.request('/rule-sets',{signal:c.signal}):[],this.optional(`/subscriptions/smart-profiles/${kind}`),admin?this.optional('/subscriptions/download-routing-preview?' + new URLSearchParams({kind,tmdb_id:prepared.media.tmdb_id,title:prepared.media.title,year:prepared.media.year || ''})):null]);
        if(!c.current())return;
        const seasons=prepared.seasons || [], initial=prepared.suggested_seasons?.length?prepared.suggested_seasons:seasons.filter(s=>s.season_number>0 && s.aired_count>0).map(s=>s.season_number);
        const modes=profile?.preferences?[['smart','智能选择'],['rules','规则选择']]:[['rules','规则选择']];
        const selectedRule=routing?.rule_set_id || rules.find(r=>r.is_default)?.id || '';
        c.body.innerHTML=`<form id="subscriptionCreateForm"><h3>${html(prepared.media.title)} · ${html(prepared.media.year)}</h3>${prepared.movie_owned?'<p class="catalog-notice">媒体库已拥有此片，仍可创建订阅管理或洗版。</p>':''}${kind==='tv'?`<fieldset class="catalog-seasons"><legend>订阅季</legend>${seasons.map(s=>`<label><input type="checkbox" name="season" value="${s.season_number}" ${checked(initial.includes(s.season_number))}>第 ${s.season_number} 季 <small>${Number(s.owned_count || 0)} / ${Number(s.episode_count || 0)} 已拥有</small></label>`).join('')}<label><input id="subscribeFuture" type="checkbox" checked>追踪未来新季</label></fieldset>`:''}<div class="catalog-form-grid">${select('subscribeMode','选择方式',modes,profile?.preferences?'smart':'rules')}${admin?select('subscribeRule','规则组',[['','服务器自动选择'],...rules.map(r=>[r.id,r.name])],selectedRule):'<p class="catalog-muted">规则组由服务器按账号权限选择</p>'}${admin?select('subscribeLibrary','入库媒体库',[['','服务器自动选择'],...App.libraries.filter(lib=>lib.kind===kind).map(lib=>[lib.id,lib.name])],routing?.library_id || ''):''}</div><p id="subscribeRoute" class="catalog-notice">${html(routing?.warning || routing?.route_reason || routing?.entry_dir || '按服务器配置完成下载与入库')}</p>${profile?.preferences?`<p class="catalog-muted">智能偏好：${html(profile.preferences.resolution)} · ${html(profile.preferences.source)} · 等待 ${Math.round(profile.preferences.wait_seconds/60)} 分钟</p>`:'<p class="catalog-muted">服务器未提供智能偏好，本次使用规则选择。</p>'}<div class="catalog-actions"><button type="button" class="btn-secondary" id="subscribeSmart">智能偏好</button>${admin?'<button type="button" class="btn-secondary" id="subscribeRules">管理规则组</button>':''}</div>${prepared.douban_episodes?`<label class="catalog-check"><input id="subscribeDoubanFloor" type="checkbox">按豆瓣提示追踪第 ${prepared.douban_episodes.season_number} 季 ${prepared.douban_episodes.douban_count} 集</label>`:''}<button type="submit" class="btn-play">确认订阅</button></form>`;
        DesktopSelect.enhance(c.body);
        c.body.querySelector('#subscribeSmart').onclick=()=>this.smartProfile(kind,()=>this.subscribe(reference,sourceReference));
        c.body.querySelector('#subscribeRules')?.addEventListener('click',()=>this.ruleSets(()=>this.subscribe(reference,sourceReference)));
        let routeRequest=0;
        c.body.querySelector('#subscribeLibrary')?.addEventListener('change',async event=>{
          const sequence=++routeRequest;
          const query=new URLSearchParams({kind,tmdb_id:prepared.media.tmdb_id,title:prepared.media.title,year:prepared.media.year || ''});
          if(event.target.value)query.set('library_id',event.target.value);
          try{const data=await this.request('/subscriptions/download-routing-preview?'+query,{signal:c.signal});if(c.current() && sequence===routeRequest)c.body.querySelector('#subscribeRoute').textContent=data.warning || data.entry_dir || data.route_reason;}
          catch(error){if(c.current() && sequence===routeRequest)this.dialogError(c,error);}
        });
        c.body.querySelector('form').onsubmit=event=>{
          event.preventDefault();
          this.submit(c,event.target,async()=>{
            if(!permissions().subscribe)throw new Error('当前账号没有订阅权限');
            const selected=[...c.body.querySelectorAll('[name="season"]:checked')].map(input=>Number(input.value));
            const future=c.body.querySelector('#subscribeFuture')?.checked || false;
            if(kind==='tv' && !selected.length && !future)throw new Error('请至少选择一季或开启追踪未来季');
            const mode=c.body.querySelector('#subscribeMode').value, payload={title_ref:reference,...(sourceReference?{source_title_ref:sourceReference}:{}),selected_seasons:selected,follow_future:future,selection_mode:mode,rule_set_id:mode==='rules' && admin?Number(c.body.querySelector('#subscribeRule').value) || null:null,...(mode==='smart'?{smart_profile_revision:profile.revision}:{}),...(admin?{library_id:Number(c.body.querySelector('#subscribeLibrary').value) || null}:{}),...(c.body.querySelector('#subscribeDoubanFloor')?.checked?{episode_floors:{[prepared.douban_episodes.season_number]:prepared.douban_episodes.douban_count}}:{})};
            const result=await this.request('/subscriptions',{method:'POST',body:payload}); subscriptionCache=null;if(c.current())await this.changed(result.subscription?.id || result.id);
          });
        };
      }catch(error){this.dialogError(c,error);}
    }
    async smartProfile(kind, done) {
      const c=this.dialogBox('智能订阅偏好');
      try {
        const profile=await this.request(`/subscriptions/smart-profiles/${kind}`,{signal:c.signal});if(!c.current())return;
        const p=profile.preferences || {resolution:'1080p',source:'web-dl',wait_seconds:3600,allow_upgrade:true,strict_resolution:false};
        c.body.innerHTML=`<form><div class="catalog-form-grid">${select('smartResolution','目标分辨率',[['1080p','1080p'],['2160p','4K / 2160p']],p.resolution)}${select('smartSource','目标片源',[['web-dl','WEB-DL'],['blu-ray','Blu-ray'],['remux','Remux']],p.source)}<label class="catalog-field">等待窗口（分钟）<input id="smartWait" type="number" min="0" max="10080" required value="${Math.round(p.wait_seconds/60)}"></label></div><label class="catalog-check"><input id="smartUpgrade" type="checkbox" ${checked(p.allow_upgrade)}>允许后续洗版</label><label class="catalog-check"><input id="smartStrict" type="checkbox" ${checked(p.strict_resolution)}>严格要求目标分辨率</label><p class="catalog-muted">保存到服务器，供当前账号之后创建的订阅使用。</p><button type="submit" class="btn-play">保存偏好</button></form>`;
        DesktopSelect.enhance(c.body);
        c.body.querySelector('form').onsubmit=event=>{event.preventDefault();this.submit(c,event.target,async()=>{await this.request(`/subscriptions/smart-profiles/${kind}`,{method:'PUT',body:{revision:profile.revision,preferences:{resolution:c.body.querySelector('#smartResolution').value,source:c.body.querySelector('#smartSource').value,wait_seconds:Number(c.body.querySelector('#smartWait').value)*60,allow_upgrade:c.body.querySelector('#smartUpgrade').checked,strict_resolution:c.body.querySelector('#smartStrict').checked}}});if(c.current()){if(done)done();else this.closeDialog();}});};
      }catch(error){this.dialogError(c,error);}
    }
    async adjust(d) {
      if(!d.can_manage || !permissions().subscribe)return;
      const c=this.dialogBox('调整订阅');
      try {
        const rules=permissions().admin?await this.request('/rule-sets',{signal:c.signal}):[]; if(!c.current())return;
        const prepared=d.media.kind==='tv'?await this.request('/subscriptions/title-preview',{method:'POST',body:{title_ref:`tmdb:tv:${d.media.tmdb_id}`},signal:c.signal,cancelable:true}):null;if(!c.current())return;
        const seasonMap=new Map([...(prepared?.seasons || []),...(d.season_collection || []),...(d.episode_seasons || [])].map(s=>[s.season_number,s]));for(const n of d.selected_seasons || [])if(!seasonMap.has(n))seasonMap.set(n,{season_number:n});const seasons=[...seasonMap.values()].sort((a,b)=>a.season_number-b.season_number);
        c.body.innerHTML=`<form><fieldset class="catalog-seasons"><legend>订阅范围</legend>${seasons.map(s=>`<div><label><input name="adjustSeason" type="checkbox" value="${s.season_number}" ${checked(d.selected_seasons.includes(s.season_number))}>第 ${s.season_number} 季</label><label class="catalog-field">至少追踪集数<input data-floor="${s.season_number}" type="number" min="1" aria-label="第 ${s.season_number} 季集数下限" placeholder="以 TMDB 为准" value="${s.floor || ''}"></label></div>`).join('')}</fieldset>${d.media.kind==='tv'?`<label class="catalog-check"><input id="adjustFuture" type="checkbox" ${checked(d.follow_future)}>追踪未来新季</label>`:''}<div class="catalog-form-grid">${permissions().admin?(d.selection_mode==='smart'?'<p class="catalog-muted">智能选择（保持当前偏好）</p>':select('adjustRule','规则组',rules.map(r=>[r.id,r.name]),d.rule_set_id))+select('adjustLibrary','目标媒体库',[['','服务器自动选择'],...App.libraries.filter(l=>l.kind===d.media.kind).map(l=>[l.id,l.name])],d.library_id || ''):''}</div>${(d.episode_hints || []).map(h=>`<p class="catalog-notice">第 ${h.season_number} 季建议 ${h.suggested} 集 <button type="button" class="text-button" data-dismiss-hint="${h.season_number}">忽略此提示</button></p>`).join('')}<button type="submit" class="btn-play">保存调整</button></form>`;
        DesktopSelect.enhance(c.body);
        c.body.querySelectorAll('[data-dismiss-hint]').forEach(button=>button.onclick=()=>this.confirmMutation('忽略集数提示','继续以 TMDB 集数为准。',`/subscriptions/${d.id}/episode-hints/dismiss`,'POST',{season_number:Number(button.dataset.dismissHint)}));
        c.body.querySelector('form').onsubmit=event=>{event.preventDefault();this.submit(c,event.target,async()=>{
          const seasons=[...c.body.querySelectorAll('[name="adjustSeason"]:checked')].map(i=>Number(i.value)), floors={};
          c.body.querySelectorAll('[data-floor]').forEach(i=>{if(i.value)floors[i.dataset.floor]=Number(i.value);});
          const payload={selected_seasons:seasons,follow_future:!!c.body.querySelector('#adjustFuture')?.checked,episode_floors:floors,...(permissions().admin?{...(d.selection_mode==='smart'?{}:{rule_set_id:Number(c.body.querySelector('#adjustRule').value)}),library_id:Number(c.body.querySelector('#adjustLibrary').value)||null}:{})};
          if(d.media.kind==='tv' && !seasons.length && !payload.follow_future)throw new Error('请保留至少一季或追踪未来季');
          await this.request(`/subscriptions/${d.id}`,{method:'PATCH',body:payload});const removed=d.selected_seasons.filter(n=>!seasons.includes(n));
          if(!c.current())return;subscriptionCache=null;if(permissions().admin && removed.length)await this.remove(d,true,removed);else await this.changed(d.id);
        });};
      }catch(error){this.dialogError(c,error);}
    }
    async remove(d, permanent, seasons) {
      const c=this.dialogBox(seasons?'清理已移出的季':permanent?'移除订阅':'取消关注');
      try {
        const preview=permanent?await this.request(`/subscriptions/${d.id}/removal-preview`+(seasons?'?'+new URLSearchParams(seasons.map(n=>['seasons',n])):''),{signal:c.signal}):null;
        if(!c.current())return;
        c.body.innerHTML=`<form><p>${seasons?`已保存订阅范围。可选择清理第 ${seasons.join('、')} 季的资源。`:permanent?'将移除订阅及追踪工单。默认保留所有已下载、已入库内容。':'仅取消你的关注，不影响其他关注者的追踪。'}</p>${preview?`<p>${preview.torrent_count} 个种子 · ${preview.library_file_count} 个媒体文件 · ${bytes(preview.library_bytes)}</p>${preview.hit_and_run_count?`<p class="catalog-notice">${preview.hit_and_run_count} 个种子可能有 H&R 要求，请确认后再清理。</p>`:''}<label class="catalog-check"><input id="removeTorrents" type="checkbox">同时删除相关下载种子</label><label class="catalog-check"><input id="removeFiles" type="checkbox">同时回收媒体库文件</label>${preview.retained_cross_season?.length?`<p class="catalog-muted">跨季种子会保留：${html(preview.retained_cross_season.map(t=>t.title).join('、'))}</p>`:''}`:''}<button type="submit" class="btn-secondary ${permanent?'btn-danger':''}">${seasons?'确认清理':'确认'}</button>${seasons?'<button type="button" class="btn-secondary" id="skipCleanup">保留资源</button>':''}</form>`;
        c.body.querySelector('#skipCleanup')?.addEventListener('click',()=>this.changed(d.id));
        c.body.querySelector('form').onsubmit=event=>{event.preventDefault();this.submit(c,event.target,async()=>{
          const options={delete_torrents:!!c.body.querySelector('#removeTorrents')?.checked,delete_library_files:!!c.body.querySelector('#removeFiles')?.checked};
          if(permanent && !permissions().admin)throw new Error('需要管理员权限');
          if(seasons)await this.request(`/subscriptions/${d.id}/season-cleanup`,{method:'POST',body:{seasons,...options}});
          else await this.request(permanent?`/subscriptions/${d.id}?${new URLSearchParams(options)}`:`/subscriptions/${d.id}/following`,{method:'DELETE'});
          subscriptionCache=null;if(!c.current())return;if(seasons)await this.changed(d.id);else {this.closeDialog();await App.navigate(enabled('subscriptions')?'subscriptions':'discover',{},false);}
        });};
      }catch(error){this.dialogError(c,error);}
    }
    async upgrade(d) {
      const c=this.dialogBox('洗一轮版');
      try {
        const rules=permissions().admin?await this.request('/rule-sets',{signal:c.signal}):[];if(!c.current())return;
        c.body.innerHTML=`<form><p>先检查当前版本与目标档位，再为可洗版的单元排入搜索。已达到目标的内容不会重复下载。</p>${permissions().admin?select('upgradeRule','目标规则组',[['','沿用当前规则'],...rules.filter(r=>r.spec?.upgrade_source).map(r=>[r.id,r.name])],''):''}<button class="btn-play" type="submit">检查并执行</button></form>`;DesktopSelect.enhance(c.body);
        c.body.querySelector('form').onsubmit=event=>{event.preventDefault();this.submit(c,event.target,async()=>{const id=Number(c.body.querySelector('#upgradeRule')?.value);const result=await this.request(`/subscriptions/${d.id}/upgrade-runs`,{method:'POST',body:id?{rule_set_id:id}:{}});if(c.current())c.body.innerHTML=`<h3>${html(result.summary)}</h3><p>目标：${html(result.target_label)}</p><div>${(result.units || []).map(u=>`<p>S${u.season_number}E${u.episode_number} · ${html({upgradable:'已排入搜索',at_cutoff:'已达目标',in_flight:'已在洗版',not_comparable:'规格未确认',missing:'缺失，按缺集搜索处理'}[u.state] || u.state)}</p>`).join('')}</div><button class="btn-secondary" id="upgradeDone">返回</button>`;if(!c.current())return;c.body.querySelector('#upgradeDone').onclick=()=>this.changed(d.id);});};
      }catch(error){this.dialogError(c,error);}
    }
    async grab(d) {
      if(!permissions().grab || !d.can_manage)return;
      const c=this.dialogBox('手动选种');
      c.body.innerHTML=`<form id="torrentSearch"><label class="catalog-field">资源关键词<input id="torrentQuery" required value="${html(d.media.title)}" aria-label="资源关键词"></label><button type="submit" class="btn-secondary">搜索资源</button></form><div id="torrentResults"></div>`;
      let currentPage=1;
      const search=async page=>{
        const keyword=c.body.querySelector('#torrentQuery').value.trim();
        const result=await this.request('/search/torrents?'+new URLSearchParams({keyword,categories:d.media.kind,page,no_history:true}),{signal:c.signal,timeoutMs:120000});
        if(!c.current())return;currentPage=page;
        c.body.querySelector('#torrentResults').innerHTML=`<p class="catalog-muted">${html((result.sites || []).filter(s=>!s.success).map(s=>s.message || s.site_id).join(' · '))}</p>${(result.items || []).map((item,index)=>`<article class="catalog-torrent"><strong>${html(item.title)}</strong><small>${html(item.site_name || item.site_id)} · ${bytes(item.size_bytes)} · ${Number(item.seeders || 0)} 做种${item.hit_and_run?' · H&R':''}${item.is_free?' · 免费':''}</small><button class="btn-secondary" data-grab="${index}">选择此资源</button></article>`).join('') || '<p>没有找到资源</p>'}<div class="catalog-paging"><button type="button" id="torrentPrevious" class="btn-secondary" ${page===1?'disabled':''}>上一页</button><span>第 ${page} 页</span><button type="button" id="torrentNext" class="btn-secondary" ${!(result.items || []).length?'disabled':''}>下一页</button></div>`;
        c.body.querySelector('#torrentPrevious').onclick=()=>this.submit(c,c.body.querySelector('form'),()=>search(currentPage-1));
        c.body.querySelector('#torrentNext').onclick=()=>this.submit(c,c.body.querySelector('form'),()=>search(currentPage+1));
        c.body.querySelectorAll('[data-grab]').forEach(button=>button.onclick=()=>{
          const item=result.items[Number(button.dataset.grab)],payload={};
          for(const key of ['site_id','torrent_id','title','subtitle','category','attrs','download_url','size_bytes','seeders','is_free','hit_and_run','imdb_id','douban_id','publish_time'])if(item[key]!=null)payload[key]=item[key];
          this.confirmMutation('确认投递资源',item.title,`/subscriptions/${d.id}/selected-torrent-downloads`,'POST',payload);
        });
      };
      c.body.querySelector('form').onsubmit=event=>{event.preventDefault();this.submit(c,event.target,()=>search(1));};
    }
    async health() {
      if(!permissions().admin)return;
      const c=this.dialogBox('订阅入库链路');
      try {
        const data=await this.request('/subscriptions/automation-readiness',{signal:c.signal});if(!c.current())return;
        const destination=section=>['sites','downloaders','import-watch'].includes(section)?`settings/${section}`:section==='libraries'?'library':null;
        const repair=section=>destination(section)?`<button class="text-button" data-repair="${html(section)}">打开服务器配置</button>`:'';
        c.body.innerHTML=`<p>${html(data.site_check?.label)}：${html(data.site_check?.detail)}</p>${(data.issues || []).map(issue=>`<section class="catalog-notice"><h3>${html(issue.title)}</h3><p>${html(issue.detail)}</p>${(issue.options || []).map(option=>`<details><summary>${html(option.title)}</summary><p>${html(option.why)}</p><p>${html(option.steps)}</p>${repair(option.fix_section)}</details>`).join('')}</section>`).join('')}${(data.libraries || []).map(lib=>`<section class="catalog-section"><h3>${html(lib.library_name)}</h3><p>${html(lib.narrative)}</p>${(lib.checks || []).map(check=>`<p class="${check.status==='error'?'catalog-error':'catalog-muted'}">${html(check.label)}：${html(check.detail)} ${repair(check.fix_section)}</p>`).join('')}</section>`).join('') || '<p>没有可检查的媒体库</p>'}`;
        c.body.querySelectorAll('[data-repair]').forEach(button=>button.onclick=()=>this.externalLink(API.baseUrl.replace(/\/$/,'')+'/'+destination(button.dataset.repair),c));
      }catch(error){this.dialogError(c,error);}
    }
    async ruleSets(done) {
      if(!permissions().admin)return;
      const c=this.dialogBox('订阅规则组');
      try {
        const rules=await this.request('/rule-sets',{signal:c.signal});if(!c.current())return;
        c.body.innerHTML=`<button class="btn-secondary" id="createRule">新建规则组</button>${rules.map((rule,index)=>`<article class="catalog-rule"><div><strong>${html(rule.name)}${rule.is_default?' · 默认':''}</strong><small>${Number(rule.reference_count || 0)} 个订阅使用</small></div><div class="catalog-actions"><button class="text-button" data-rule-edit="${index}">编辑</button>${!rule.is_default?`<button class="text-button" data-rule-default="${index}">设为默认</button>`:''}${!rule.is_default && !rule.reference_count?`<button class="text-button" data-rule-delete="${index}">删除</button>`:''}</div></article>`).join('')}${done?'<button class="btn-play" id="rulesDone">返回订阅表单</button>':''}`;
        c.body.querySelector('#createRule').onclick=()=>this.ruleEditor(null,done);
        c.body.querySelector('#rulesDone')?.addEventListener('click',done);
        c.body.querySelectorAll('[data-rule-edit]').forEach(b=>b.onclick=()=>this.ruleEditor(rules[Number(b.dataset.ruleEdit)],done));
        c.body.querySelectorAll('[data-rule-default]').forEach(b=>b.onclick=()=>this.confirmRule('设为默认规则组','将用于之后自动选组的订阅。已有订阅不会更换规则组。',`/rule-sets/${rules[Number(b.dataset.ruleDefault)].id}/default`,'POST',done));
        c.body.querySelectorAll('[data-rule-delete]').forEach(b=>b.onclick=()=>this.confirmRule('删除规则组','仅可删除未被使用的非默认规则组。',`/rule-sets/${rules[Number(b.dataset.ruleDelete)].id}`,'DELETE',done));
      }catch(error){this.dialogError(c,error);}
    }
    confirmRule(title,message,path,method,done) {
      const c=this.dialogBox(title);c.body.innerHTML=`<p>${html(message)}</p><form><button type="submit" class="btn-secondary">确认</button></form>`;
      c.body.querySelector('form').onsubmit=event=>{event.preventDefault();this.submit(c,event.target,async()=>{if(!permissions().admin)throw new Error('需要管理员权限');await this.request(path,{method});if(c.current())this.ruleSets(done);});};
    }
    async ruleEditor(rule,done) {
      const c=this.dialogBox(rule?'编辑规则组':'新建规则组'), spec=rule?.spec || {};
      const arrayFields=[['resolutions','分辨率',['2160p','1080p','720p','480p']],['media_sources','片源',['remux','blu-ray','web-dl','rip','tv']],['video_codecs','视频编码',['hevc','h264','av1','vp9']],['hdr_levels','允许的画面格式',['DV','HDR10+','HDR10','HLG','SDR']],['hdr_block','排除的画面格式',['DV','HDR10+','HDR10','HLG','SDR']]];
      const csvFields=[['platforms','允许流媒体平台'],['platforms_block','排除流媒体平台'],['release_groups_allow','允许制作组'],['release_groups_block','排除制作组'],['subtitle_languages_require','要求字幕语言'],['audio_languages_require','要求音轨语言'],['sites','允许站点']];
      const numericFields=[['min_seeders','最低做种数'],['size_min_mb','每集最小体积（MB）'],['size_max_mb','每集最大体积（MB）']];
      c.body.innerHTML=`<form><label class="catalog-field">规则组名称<input id="ruleName" required maxlength="120" value="${html(rule?.name || '')}"></label><div class="catalog-rule-options">${arrayFields.map(([key,label,values])=>`<fieldset><legend>${label}（不选则不限）</legend>${[...new Set([...(spec[key] || []),...values])].map(value=>`<label><input type="checkbox" name="rule_${key}" value="${html(value)}" ${checked((spec[key] || []).includes(value))}>${html(value)}</label>`).join('')}</fieldset>`).join('')}</div><details><summary>高级匹配条件</summary><p class="catalog-muted">多项用逗号分隔。语言示例：字幕 zh、en；音轨 cmn、yue、en。</p><div class="catalog-form-grid">${csvFields.map(([key,label])=>`<label class="catalog-field">${label}<input id="rule_${key}" value="${html((spec[key] || []).join(', '))}"></label>`).join('')}${numericFields.map(([key,label])=>`<label class="catalog-field">${label}<input id="rule_${key}" type="number" min="0" value="${spec[key] ?? ''}"></label>`).join('')}${select('ruleHrUnknown','未知 H&R 策略',[['lenient','宽松'],['strict','严格']],spec.hr_unknown_policy || 'lenient')}${select('ruleUpgrade','洗版目标',[['','不洗版'],['web-dl','WEB-DL'],['blu-ray','Blu-ray'],['remux','Remux']],spec.upgrade_source || '')}${select('ruleCutoff','洗版目标分辨率',[['','跟随分辨率偏好'],['1080p','1080p'],['2160p','2160p']],spec.cutoff_resolution || '')}<label class="catalog-field">洗版比较顺序<input id="ruleLadder" value="${html((spec.upgrade_ladder || ['resolution','source']).join(', '))}" aria-label="洗版比较顺序"></label></div><label class="catalog-check"><input id="ruleFree" type="checkbox" ${checked(spec.free_only)}>仅免费资源</label><label class="catalog-check"><input id="ruleExcludeHr" type="checkbox" ${checked(spec.exclude_hr)}>排除 H&R 资源</label><label class="catalog-check"><input id="ruleKeepOld" type="checkbox" ${checked(spec.upgrade_keep_old)}>洗版后保留旧版本</label></details><details><summary>自动选组范围</summary><div class="catalog-form-grid">${select('ruleScopeKind','作品类型',[['','不限'],['movie','电影'],['tv','剧集']],rule?.match_rules?.find(r=>r.field==='kind')?.values?.[0] || '')}<label class="catalog-field">地区代码<input id="ruleScopeCountries" placeholder="例如 CN, US" value="${html((rule?.match_rules?.find(r=>r.field==='origin_countries')?.values || []).join(', '))}"></label><label class="catalog-field">类型编号<input id="ruleScopeGenres" placeholder="例如 28, 18" value="${html((rule?.match_rules?.find(r=>r.field==='genres')?.values || []).join(', '))}"></label></div></details><p class="catalog-muted">更新只影响之后的匹配，不追溯已经投递的资源。</p><button type="submit" class="btn-play">保存规则组</button></form>`;
      DesktopSelect.enhance(c.body);
      c.body.querySelector('form').onsubmit=event=>{event.preventDefault();this.submit(c,event.target,async()=>{
        if(!permissions().admin)throw new Error('需要管理员权限');
        const next={...spec}, csv=value=>value.split(/[,，]/).map(v=>v.trim()).filter(Boolean), get=id=>c.body.querySelector('#'+id).value;
        arrayFields.forEach(([key])=>next[key]=[...c.body.querySelectorAll(`[name="rule_${key}"]:checked`)].map(i=>i.value));
        csvFields.forEach(([key])=>next[key]=csv(get('rule_'+key)));
        numericFields.forEach(([key])=>next[key]=get('rule_'+key)===''?null:Number(get('rule_'+key)));
        Object.assign(next,{free_only:c.body.querySelector('#ruleFree').checked,exclude_hr:c.body.querySelector('#ruleExcludeHr').checked,upgrade_keep_old:c.body.querySelector('#ruleKeepOld').checked,hr_unknown_policy:get('ruleHrUnknown'),upgrade_source:get('ruleUpgrade') || null,cutoff_resolution:get('ruleCutoff') || null,upgrade_ladder:csv(get('ruleLadder'))});
        const match_rules=[];if(get('ruleScopeKind'))match_rules.push({field:'kind',op:'any_of',values:[get('ruleScopeKind')]});if(get('ruleScopeCountries'))match_rules.push({field:'origin_countries',op:'any_of',values:csv(get('ruleScopeCountries')).map(s=>s.toUpperCase())});if(get('ruleScopeGenres')){const values=csv(get('ruleScopeGenres')).map(Number);if(values.some(v=>!Number.isInteger(v)||v<=0))throw new Error('类型编号应为正整数');match_rules.push({field:'genres',op:'any_of',values});}
        await this.request(rule?`/rule-sets/${rule.id}`:'/rule-sets',{method:rule?'PUT':'POST',body:{name:get('ruleName').trim(),spec:next,match_rules}});if(c.current())this.ruleSets(done);
      });};
    }
  }
  const routes={discover:'discover',discoverCollection:'collection',discoverDetail:'titleDetail',discoverPerson:'person',subscriptions:'subscriptionList',subscriptionDetail:'subscriptionDetail'};
  return {
    pages, preferences, permissions, enabled, nav, settings,
    reset(){view?.dispose();view=null;subscriptionCache=null;},
    dispose(){view?.dispose();view=null;},
    async render(page,host,params,generation){
      view?.dispose();view=new CatalogView(host,generation,params);
      if(!enabled(page)){host.innerHTML='<div class="empty-state">请先在设置中开启该入口，并确认账号权限。</div>';return;}
      await view[routes[page]]();
    },
    CatalogView,
  };
})();
