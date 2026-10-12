(() => {
  const url='/api/v1/plugins/watch-presence/preferences';
  const form=document.getElementById('privacy'), share=document.getElementById('share'), save=document.getElementById('save'), status=document.getElementById('status');
  let persisted;
  const selected=()=>[...document.querySelectorAll('#libraries input:checked:not(:disabled)')].map(input=>Number(input.value));
  const busy=value=>{share.disabled=value;save.disabled=value;form.querySelector('fieldset').disabled=value;};
  async function request(options={}){const response=await fetch(url,{credentials:'same-origin',...options});const data=await response.json();if(!response.ok)throw new Error(data.message || '保存失败');return data.data;}
  async function write(){const prefs={share_enabled:share.checked,library_ids:selected()};busy(true);status.textContent='正在保存…';try{persisted=await request({method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(prefs)});share.checked=persisted.share_enabled;status.textContent=persisted.share_enabled?'已保存：只共享勾选的媒体库。':'共享已关闭，其他成员无法查看你的观看状态和历史。';}catch(error){share.checked=persisted.share_enabled;status.textContent='未保存：'+error.message;}finally{busy(false);}}
  form.onsubmit=event=>{event.preventDefault();write();};
  share.onchange=()=>{if(!share.checked && persisted.share_enabled)write();else status.textContent='点击保存后生效。';};
  request().then(prefs=>{persisted=prefs;share.checked=prefs.share_enabled;for(const lib of prefs.libraries){const label=document.createElement('label'),input=document.createElement('input'),span=document.createElement('span');input.type='checkbox';input.value=String(lib.id);input.checked=prefs.library_ids.includes(lib.id);input.disabled=!lib.shareable;span.textContent=lib.name+(lib.reason?' · '+lib.reason:'');label.append(input,span);document.getElementById('libraries').append(label);}busy(false);status.textContent=prefs.share_enabled?'当前共享已开启，可调整范围。':'共享默认关闭，由你选择是否公开。';}).catch(error=>{status.textContent='无法读取设置：'+error.message+'。请先在同一服务器的 Web 页面登录，再打开此地址。';});
})();
