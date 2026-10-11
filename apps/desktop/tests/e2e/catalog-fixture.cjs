// Stateful public API fixture: exercises desktop workflows without creating NAS downloads.
const title=(id=42,kind='tv',provider='tmdb')=>({title_ref:provider==='douban'?`douban:${id}`:`tmdb:${kind}:${id}`,external_id:String(id),provider,media_type:kind,title:id===42?'星海旅程':`探索影片 ${id}`,release_year:2025,provider_rating:8.7,genres:['剧情'],overview:'一段探索未知世界的旅程。',poster_url:null});
const media={media_item_id:3,kind:'tv',tmdb_id:42,title:'星海旅程',year:2025};
const season=n=>({season_number:n,episode_count:4,aired_count:4,owned_count:1});
const initial=()=>[{id:7,media,status:'active',selected_seasons:[1],follow_future:true,selection_mode:'smart',rule_set_id:1,library_id:1,can_manage:true,progress:{total:4,wanted:1,grabbed:1,downloaded:1,imported:1},episode_seasons:[{season_number:1,tmdb_count:4,floor:null}],wanted:[
{id:70,season_number:1,episode_number:1,status:'imported',air_date:'2026-10-01',last_search_at:'2026-10-01T10:00:00Z',grabbed_at:'2026-10-01T11:00:00Z',downloaded_at:'2026-10-01T12:00:00Z',imported_at:'2026-10-01T13:00:00Z'},
{id:71,season_number:1,episode_number:2,status:'grabbed',info_hash:'hash',grab_title:'Star.S01E02.2160p',selection_version:2,selection_state:{reason:'等待更好的资源',deadline:'2026-10-12',candidate_key:'candidate'}},
{id:72,season_number:1,episode_number:3,status:'downloaded'},
{id:73,season_number:1,episode_number:4,status:'wanted',last_reject_reason:'不符合分辨率要求'}]}];
module.exports=async({route,req,res,state,url,body,json,ok})=>{
 if(!/^\/(ui\/discovery|discover|search\/(titles|torrents)|subscriptions|rule-sets)/.test(route))return false;
 const send=data=>{json(res,ok(data));return true;};
 const error=(message,status)=>{json(res,{message},status);return true;};
 state.catalogRows ||= initial();state.rules ||= [{id:1,name:'默认 4K',is_default:true,spec:{resolutions:['2160p'],media_sources:['web-dl'],upgrade_source:'web-dl'},match_rules:[],reference_count:1}];
 if(state.catalogUnsupported)return error('服务器版本尚未提供该功能',404);
 const admin=(state.role || 'admin')==='admin',cap=key=>admin || state.capabilities?.[key]===true;
 if((route.startsWith('/rule-sets') || route.includes('automation-readiness')) && !admin)return error('需要管理员权限',403);
 if(route.startsWith('/subscriptions') && !cap('allow_subscribe'))return error('没有订阅权限',403);
 if(state.catalogDelay && route.startsWith('/discover'))await new Promise(resolve=>setTimeout(resolve,state.catalogDelay));
 if(route.startsWith('/ui/discovery/'))return send({sections:[{collection_ref:`tmdb:${route.endsWith('tv')?'tv':'movie'}:popular`,title:'热门作品',presentation:'poster-row',preview_limit:12,supports_full_listing:true}]});
 if(route.startsWith('/discover/collections/'))return send({collection:{name:'热门作品'},titles:[title(42,'tv',url.searchParams.get('provider') || 'tmdb'),title(43,'movie')],page:Number(url.searchParams.get('page')),has_more:Number(url.searchParams.get('page'))===1});
 if(route==='/discover/filters')return send({genres:[{id:18,name:'剧情'},{id:28,name:'动作'}]});
 if(route==='/discover/titles')return send({titles:[title()],has_more:false});
 if(route.startsWith('/discover/titles/'))return send({title:title(),metadata:{country:'中国',language:'中文',released:'2025',director_credits:[{name:'探索导演',tmdb_person_id:88}],cast:[{name:'探索演员',role:'船长',tmdb_person_id:89}]},recommendations:[title(43,'movie')],library_links:[{library_id:1,library_name:'影片库',media_item_id:3}]});
 if(route.startsWith('/discover/people/'))return send({name:'探索演员',titles:[title(43,'movie')]});
 if(route==='/search/titles')return send({titles:[title(44,'tv',body.provider==='douban'?'douban':'tmdb')],providers:[]});
 if(route==='/search/torrents')return send({items:[{site_id:'site',site_name:'测试站点',torrent_id:'torrent-1',title:'Star.S01E02.2160p',download_url:'https://example.invalid/download/1',seeders:12,size_bytes:104857600,is_free:true,hit_and_run:false,attrs:{resolution:'2160p'}}],sites:[]});
 if(route==='/subscriptions/title-preview')return send({status:state.catalogAmbiguous && body.title_ref.startsWith('douban')?'ambiguous':'ready',media:{...media,tmdb_id:44,title:'探索影片 44'},seasons:[season(1),season(2),season(3)],suggested_seasons:[1],existing_subscription_id:body.title_ref.includes(':42')?7:null,candidates:[{title_ref:'tmdb:tv:44',title:'探索影片 44',year:2025}]});
 if(route.startsWith('/subscriptions/smart-profiles/')){
  if(state.catalogLegacySmart)return error('没有智能偏好接口',404);
  return send({revision:3,preferences:body?.preferences || {resolution:'2160p',source:'web-dl',wait_seconds:3600,allow_upgrade:true,strict_resolution:false}});
 }
 if(route==='/subscriptions/download-routing-preview')return send({ok:true,library_id:1,library_name:'影片库',rule_set_id:1,entry_dir:'/downloads/media',route_reason:'按默认媒体库入库'});
 if(route==='/subscriptions/automation-readiness')return send({status:'warn',site_check:{label:'站点',detail:'已配置'},issues:[{title:'路径映射待配置',detail:'下载完成后等待入库',options:[{title:'配置映射',steps:'将下载目录映射到媒体库节点',fix_section:'downloaders',fix_label:'打开服务器设置'}]}],libraries:[{library_name:'影片库',narrative:'下载后自动入库',checks:[{status:'warn',label:'路径映射',detail:'等待配置',fix_section:'downloaders'}]}]});
 if(route==='/subscriptions/today-arrivals')return send([{subscription_id:7,media_title:'星海旅程',media_kind:'tv',expected_day:'2026-10-12',season_number:1,episode_number:4,status:'wanted'}]);
 if(route==='/subscriptions/recent-arrivals')return send([{subscription_id:7,media,season_number:3,episode_number:2,units:[{season_number:1,episode_number:1}],imported_at:'2026-10-11'}]);
 if(route==='/subscriptions'){
  if(req.method==='POST'){
   if(state.catalogCreateDelay)await new Promise(resolve=>setTimeout(resolve,state.catalogCreateDelay));
   if(state.catalogCreateError)return error('智能偏好已改变，请重新加载',409);
   const row={...initial()[0],id:8,media:{...media,tmdb_id:44,title:'探索影片 44'},...body};state.catalogRows.push(row);return send({subscription:row});
  }return send(state.catalogRows);
 }
 const subMatch=route.match(/^\/subscriptions\/(\d+)(.*)$/);
 if(subMatch){
  const id=Number(subMatch[1]),tail=subMatch[2],row=state.catalogRows.find(r=>r.id===id);if(!row)return error('订阅不存在',404);
  if(tail==='/active-downloads')return send([{info_hash:'hash',state:state.catalogDownloadError?'error':'downloading',progress:0.55,dlspeed_bytes:2097152,eta_seconds:240,error_message:state.catalogDownloadError?'下载器离线':null}]);
  if(tail==='/activities')return send([{id:1,message:'已投递下载，等待入库',created_at:'2026-10-11T10:00:00Z'}]);
  if(tail==='/removal-preview')return send({torrent_count:2,library_file_count:1,library_bytes:1048576,hit_and_run_count:1,retained_cross_season:[{title:'跨季包',seasons:[1,2]}]});
  if(state.catalogReadOnly && req.method!=='GET')return error('不能管理其他成员的订阅',403);
  if(tail==='/tracking-state'){row.status=body.state;return send(row);}
  if(tail==='/upgrade-runs')return send({summary:'已检查 4 个单元',target_label:'2160p WEB-DL',units:[{season_number:1,episode_number:1,state:'upgradable'}]});
  if(tail==='/selected-torrent-downloads'){if(!body.torrent_id || !body.attrs)return error('必须保留种子标识和服务端解析字段',422);return send({units:[]});}
  if(tail==='/following' && req.method==='DELETE'){state.catalogRows=state.catalogRows.filter(r=>r.id!==id);return send({});}
  if(!tail && req.method==='DELETE'){state.catalogRows=state.catalogRows.filter(r=>r.id!==id);return send({});}
  if(!tail && req.method==='PATCH'){Object.assign(row,body);return send(row);}
  if(req.method==='POST')return send({});
  return send({...row,can_manage:!state.catalogReadOnly});
 }
 if(route==='/rule-sets'){
  if(req.method==='POST'){state.rules.push({...body,id:2,reference_count:0,is_default:false});}return send(state.rules);
 }
 const ruleMatch=route.match(/^\/rule-sets\/(\d+)(.*)$/);
 if(ruleMatch){const row=state.rules.find(r=>r.id===Number(ruleMatch[1]));if(req.method==='PUT')Object.assign(row,body);if(req.method==='DELETE')state.rules=state.rules.filter(r=>r!==row);if(ruleMatch[2]==='/default')state.rules.forEach(r=>r.is_default=r===row);return send(row || {});}
 return error('Unimplemented catalog fixture: '+route,404);
};
