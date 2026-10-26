module.exports=async({route,req,res,state,url,body,json,ok})=>{
 const base='/plugins/watch-presence';if(!route.startsWith(base))return false;
 const send=data=>{json(res,ok(data));return true;};const error=(message,status=404)=>{json(res,{message},status);return true;};
 if(state.friendsUnsupported)return error('插件未安装');
 const asset=route.slice(base.length+1);
 if(req.method==='GET' && ['settings','settings.js','settings.css'].includes(asset)){
  const path=require('node:path'),fs=require('node:fs');
  res.writeHead(200,{'Content-Type':asset==='settings'?'text/html':asset.endsWith('.js')?'text/javascript':'text/css','Cache-Control':'no-store'});
  res.end(fs.readFileSync(path.resolve(__dirname,'../../../../plugins/watch-presence',asset==='settings'?'settings.html':asset)));return true;
 }
 if(state.friendsDelay)await new Promise(resolve=>setTimeout(resolve,state.friendsDelay));
 state.friendsPreferences ||= {};const account=state.username || 'fixture';state.friendsPreferences[account] ||= {share_enabled:false,library_ids:[]};
 const live={entry_id:'live-alice',kind:'live',media:{media_item_id:3,library_id:1,title:'好友的剧集',kind:'tv',season_number:2,episode_number:3},position_ms:120000,duration_ms:1200000,device:'Windows 客户端',client:'MovieClaw Windows',paused:!!state.friendsPaused,sampled_at:new Date().toISOString()};
 const history={...live,entry_id:'recent-1',kind:'history',watched_at:new Date().toISOString(),position_ms:180000,completed:false};
 if(route===base+'/preferences'){
  if(req.method==='PUT'){
   if(state.friendsSaveError)return error('保存失败，请重试',503);
   if(body.share_enabled && !body.library_ids.length)return error('请选择共享媒体库',400);
   if(body.library_ids.some(id=>id!==1 && id!==2))return error('媒体库不可共享',400);
   state.friendsPreferences[account]=body;return send(body);
  }
  return send({...state.friendsPreferences[account],libraries:[{id:1,name:'电影库',shareable:true},{id:2,name:'剧集库',shareable:true},{id:4,name:'私人隐藏库',shareable:false,reason:'首页隐藏媒体库不参与共享'}],protocol_version:1,history_days:7,history_limit:20});
 }
 const self={member_id:5,name:account,is_self:true,sessions:state.friendsSelfOffline ? [] : [{...live,entry_id:'own-windows',device:'我的 Windows 电脑'},{...live,entry_id:'own-mac',device:'我的 MacBook',position_ms:420000}]};
 if(route===base+'/members')return send({members:[...(state.friendsSelf ? [self] : []),...(state.friendsEmpty || state.friendsRevoked ? [] : [{member_id:7,name:state.friendsXss ? '<img src=x onerror=alert(1)>' : 'Alice',is_self:false,sessions:state.friendsNoLive ? [] : [live]}])],refresh_seconds:8});
 if(state.friendsSelf && route===base+'/members/5/history')return send({items:[{...history,position_ms:420000,device:'我的 MacBook'}]});
 if(state.friendsSelf && route===base+'/members/5/play')return send(self.sessions.find(row=>row.entry_id===url.searchParams.get('entry_id')) || history);
 if(state.friendsRevoked)return error('共享已关闭');
 if(route===base+'/members/7/history')return send({items:[history]});
 if(route===base+'/members/7/play'){
  if(state.friendsPlayError)return error('观看状态已失效');
  return send(url.searchParams.get('kind')==='history' ? history : live);
 }
 return error('不存在');
};
