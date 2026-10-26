// Server-enforced opt-in presence. This module runs inside the existing player.
window.DesktopFriends = (() => {
  const base = '/plugins/watch-presence';
  const identity = () => JSON.stringify([API.baseUrl, App.session?.username || '', API.contextEpoch]);
  const storageKey = () => 'mc_friends:' + JSON.stringify([API.baseUrl, App.session?.username || '']);
  const enabled = () => localStorage.getItem(storageKey()) === 'true';
  const html = value => escapeHtml(value ?? '');
  const time = ms => Player.formatTime(Math.floor(Math.max(0, Number(ms) || 0) / 1000));
  let drawer, controller, timer, epoch = 0, owner, selectedMember, pendingPlay = false, loadSequence = 0;
  const alive = token => token === epoch && owner === identity() && drawer && !drawer.hidden;
  const unwrap = result => result?.data ?? result;
  const label = row => row.media.title + (row.media.kind === 'tv' ? ` · 第 ${row.media.season_number} 季第 ${row.media.episode_number} 集` : '');
  function message(error) {
    return [404, 405].includes(error.status) ? '服务器尚未安装观看动态插件，或该内容已停止共享。' : error.message || '连接失败，请重试';
  }
  function refreshButton() {
    const button = document.getElementById('btnPlayerFriends');
    if (button) button.hidden = !enabled();
    const browse = document.getElementById('btnBrowseFriends');
    if (browse) browse.hidden = !enabled();
    if (!enabled()) close();
  }
  function close() {
    epoch++; clearTimeout(timer); timer = null; controller?.abort(); controller = null;
    if (drawer) {
      const previous = drawer; drawer = null;
      previous.hidden = true; previous.querySelector('.friends-content')?.replaceChildren();
      if (previous.tagName === 'DIALOG') { previous.close(); previous.remove(); }
    }
    document.getElementById('btnPlayerFriends')?.setAttribute('aria-expanded', 'false');
    Player.syncEmbeddedPlayerRect(); Player.autoHideControls();
  }
  function dispose() { close(); owner = null; selectedMember = null; }
  function rowCard(row, member) {
    const duration = Number(row.duration_ms), position = Number(row.position_ms);
    const percent = duration > 0 && Number.isFinite(position) ? Math.min(100, Math.max(0, position / duration * 100)) : 0;
    return `<article class="friends-watch"><strong>${html(label(row))}</strong><small>${html([row.device || row.client || '设备未知', row.kind === 'history' ? new Date(row.watched_at).toLocaleString('zh-CN') : row.paused ? '已暂停' : '正在播放'].join(' · '))}</small><progress max="100" value="${percent}" aria-label="影片进度"></progress><small>${row.position_ms == null ? '进度未知' : time(row.position_ms)} / ${duration > 0 ? time(duration) : '时长未知'}</small><div class="friends-watch-actions"><button class="btn-secondary" data-friend-play="start">从头看</button><button class="btn-primary" data-friend-play="follow" ${row.position_ms == null ? 'disabled' : ''}>${row.kind === 'live' ? '跟上进度' : '从进度继续'}</button></div></article>`;
  }
  function bindRows(host, rows, member, token) {
    host.querySelectorAll('.friends-watch').forEach((card, index) => card.querySelectorAll('[data-friend-play]').forEach(button => {
      button.onclick = () => confirmPlay(rows[index], member, button.dataset.friendPlay, token);
    }));
  }
  async function play(row, member, mode, token) {
    if (!alive(token) || pendingPlay) return;
    pendingPlay = true;
    try {
      const fresh = unwrap(await API.request(`${base}/members/${member.member_id}/play?${new URLSearchParams({kind:row.kind, entry_id:row.entry_id})}`, {signal:controller.signal}));
      if (!alive(token)) return;
      const media = fresh.media;
      let startMs = mode === 'start' ? 0 : Number(fresh.position_ms);
      if (!Number.isFinite(startMs) || startMs < 0) throw new Error('当前进度不可用，请选择从头看');
      // This is a one-time join, not synchronized remote playback control.
      if (mode === 'follow' && fresh.kind === 'live' && !fresh.paused) {
        const elapsed = Math.max(0, Math.min(8000, Date.now() - Date.parse(fresh.sampled_at)));
        if (Number.isFinite(elapsed)) startMs += elapsed;
      }
      if (fresh.duration_ms > 0) startMs = Math.min(startMs, Math.max(0, fresh.duration_ms - 1000));
      close();
      await App.startPlayback({media_item_id:media.media_item_id, library_id:media.library_id,
        title:media.title, kind:media.kind, seasonNumber:media.season_number,
        episodeNumber:media.episode_number, startMs:Math.floor(startMs)});
    } catch(error) {
      if (alive(token) && error.name !== 'AbortError') {
        drawer.querySelector('.friends-content').innerHTML = `<p role="alert">${html(message(error))}</p><button class="btn-secondary" id="friendsRetry">刷新列表</button>`;
        drawer.querySelector('#friendsRetry').onclick = () => load(token);
      }
    } finally { pendingPlay = false; }
  }
  function confirmPlay(row, member, mode, token) {
    if (!alive(token)) return;
    if (!Player.activeEngine) { play(row, member, mode, token); return; }
    const card = document.createElement('div'); card.className = 'player-dialog';
    const title = document.createElement('h2'); title.textContent = '切换影片';
    const description = document.createElement('p'); description.textContent = `将离开当前影片，${mode === 'start' ? '从头播放' : member.is_self ? '从所选设备的进度播放' : '从对方进度播放'}《${label(row)}》。`;
    const actions = document.createElement('div'); actions.className = 'player-dialog-actions';
    const confirm = () => { Player.hidePlayerDialog(); play(row, member, mode, token); };
    actions.append(Player._dialogButton('取消', false, () => Player.hidePlayerDialog()));
    actions.append(Player._dialogButton('开始播放', true, confirm));
    card.append(title, description, actions);
    Player.hidePlayerDialog();
    Player._mountDialog(card, confirm, () => Player.hidePlayerDialog());
  }
  async function load(token) {
    if (!alive(token)) return;
    const sequence = ++loadSequence;
    const current = () => alive(token) && sequence === loadSequence;
    clearTimeout(timer);
    const host = drawer.querySelector('.friends-content');
    try {
      const result = unwrap(await API.request(base + '/members', {signal:controller.signal}));
      if (!current()) return;
      const members = result.members || [];
      const selected = members.find(member => member.member_id === selectedMember);
      if (selectedMember != null && !selected) selectedMember = null;
      if (selectedMember != null) {
        const history = unwrap(await API.request(`${base}/members/${selectedMember}/history`, {signal:controller.signal}));
        if (!current()) return;
        const rows = history.items || [];
        host.innerHTML = `<button class="text-button" id="friendsBack">← 返回成员列表</button><h3>${selected.is_self ? '我的最近观看' : html(selected.name) + '的最近观看'}</h3><p class="friends-muted">最近 7 天，最多 20 条，${selected.is_self ? '同账号的不同设备按影片或单集合并记录，仅自己可见。' : '仅展示对方允许共享的媒体库。'}</p>${rows.length ? rows.map(row => rowCard(row, selected)).join('') : '<p class="friends-muted">暂无可查看的共享记录</p>'}`;
        host.querySelector('#friendsBack').onclick = () => {selectedMember = null; load(token);};
        bindRows(host, rows, selected, token);
      } else {
        host.innerHTML = `<p class="friends-muted friends-guide">自己的设备仅自己可见，无需公开共享。其他成员需先在客户端或插件网页中授权。</p>` + (members.length ? members.map(member => `<section class="friends-member"><header><span class="friends-avatar" aria-hidden="true">${html(Array.from(member.name || '?')[0])}</span><strong>${member.is_self ? '我的设备' : html(member.name)}</strong><button class="text-button" data-friend-history="${member.member_id}">最近观看</button></header>${member.is_self ? `<p class="friends-muted">${html(member.name)} · 同账号设备分别显示</p>` : ''}${member.sessions.length ? member.sessions.map(row => rowCard(row, member)).join('') : '<p class="friends-muted">当前未在观看，可查看最近观看</p>'}</section>`).join('') : '<p class="friends-muted">暂无正在观看的设备或公开的观看动态。其他成员需主动开启共享，并选择允许公开的媒体库。</p>');
        host.querySelectorAll('.friends-member').forEach((section, index) => {
          const member = members[index]; bindRows(section, member.sessions, member, token);
          section.querySelector('[data-friend-history]').onclick = () => {selectedMember = member.member_id; load(token);};
        });
      }
    } catch(error) {
      if (!current() || error.name === 'AbortError') return;
      // Do not keep potentially revoked private data on a failed refresh.
      host.innerHTML = `<p role="alert">${html(message(error))}</p><button class="btn-secondary" id="friendsRetry">重试</button>`;
      host.querySelector('#friendsRetry').onclick = () => load(token);
    }
    if (current()) timer = setTimeout(() => {
      if (document.hidden) { close(); return; }
      load(token);
    }, 8000);
  }
  function open() {
    if (!enabled() || !Player.activeEngine) return;
    if (drawer && !drawer.hidden) { close(); return; }
    Player.closeAnyPanel(); close(); owner = identity(); selectedMember = null;
    controller = new AbortController(); drawer = document.getElementById('playerFriendsPanel'); drawer.hidden = false;
    drawer.querySelector('.friends-content').innerHTML = '<p role="status">正在读取观看动态…</p>';
    document.getElementById('btnPlayerFriends').setAttribute('aria-expanded', 'true');
    Player.showControls(); Player.syncEmbeddedPlayerRect(); load(epoch);
  }
  function openHome() {
    if (!enabled()) return;
    if (Player.activeEngine) { open(); return; }
    close(); owner = identity(); selectedMember = null;
    controller = new AbortController();
    drawer = document.createElement('dialog'); drawer.className = 'friends-home-dialog';
    drawer.id = 'homeFriendsDialog'; drawer.setAttribute('aria-labelledby', 'homeFriendsTitle');
    drawer.innerHTML = '<header><div><h2 id="homeFriendsTitle">正在观看</h2><p class="friends-muted">我的设备与服务器好友</p></div><button class="friends-close" aria-label="关闭正在观看">×</button></header><div class="friends-content"><p role="status">正在读取观看动态…</p></div>';
    drawer.querySelector('.friends-close').onclick = close;
    drawer.addEventListener('cancel', event => {event.preventDefault(); close();});
    document.body.append(drawer); drawer.showModal(); load(epoch);
  }
  function init() {
    document.getElementById('btnPlayerFriends').onclick = open;
    document.getElementById('btnBrowseFriends').onclick = openHome;
    document.getElementById('friendsClose').onclick = close;
    document.addEventListener('visibilitychange', () => {if (document.hidden) close();});
    refreshButton();
  }
  function settings(host) {
    const card = document.createElement('div'); card.className = 'settings-card friends-settings';
    card.innerHTML = `<h3>好友与观看隐私</h3><p class="friends-muted">查看与公开互相独立。自己的其他设备无需开启共享；关闭公开共享不会影响自己查看。</p><div class="settings-row"><span>显示服务器好友列表<small class="friends-muted">开启后，从主界面侧栏或播放器左上角的“正在观看”查看自己的设备与已授权好友</small></span><label class="settings-toggle"><input id="setFriendsVisible" aria-label="显示服务器好友列表" type="checkbox" ${enabled() ? 'checked' : ''}><span class="toggle-slider"></span></label></div><div class="settings-row"><span>允许其他成员查看我的观看状态<small class="friends-muted">包括所选媒体库的当前播放和最近 7 天历史；按账号在服务器保存</small></span><label class="settings-toggle"><input id="setFriendsShare" aria-label="允许其他成员查看我的观看状态" type="checkbox" disabled><span class="toggle-slider"></span></label></div><fieldset class="friends-libraries"><legend>允许共享的媒体库</legend><p class="friends-muted">未勾选的库和新建的库默认保密。</p><div id="friendsLibraries"></div></fieldset><button class="btn-secondary" id="saveFriendsPrivacy" disabled>保存共享设置</button><p id="friendsPrivacyState" class="friends-muted" role="status">正在读取服务器隐私设置…</p>`;
    host.querySelector('.settings-body')?.insertBefore(card, host.querySelector('.settings-about'));
    const help = document.createElement('details'); help.className = 'friends-help';
    const summary = document.createElement('summary'); summary.textContent = 'Web / Mac / 手机用户如何开启共享？';
    const explanation = document.createElement('p'); explanation.className = 'friends-muted';
    explanation.textContent = '请先在浏览器中登录同一服务器，再打开下方地址，选择允许共享的媒体库并保存。无需安装额外软件；未授权的成员不会向其他账号公开。';
    const address = document.createElement('code'); address.textContent = API.baseUrl + '/api/v1/plugins/watch-presence/settings';
    help.append(summary, explanation, address); card.append(help);
    const controller = new AbortController(), owner = identity();
    const valid = () => card.isConnected && owner === identity() && !controller.signal.aborted;
    App._pageController?.signal.addEventListener('abort', () => controller.abort(), {once:true});
    const toggle = card.querySelector('#setFriendsVisible');
    toggle.onchange = () => {localStorage.setItem(storageKey(), String(toggle.checked)); refreshButton();};
    const share = card.querySelector('#setFriendsShare'), save = card.querySelector('#saveFriendsPrivacy'), status = card.querySelector('#friendsPrivacyState');
    let libraries = [], persisted;
    const render = prefs => {
      persisted = prefs; share.checked = prefs.share_enabled === true;
      card.querySelector('#friendsLibraries').innerHTML = libraries.map(lib => `<label class="friends-library"><input type="checkbox" value="${Number(lib.id)}" ${prefs.library_ids.includes(lib.id) ? 'checked' : ''} ${!lib.shareable ? 'disabled' : ''}><span>${html(lib.name)}${lib.reason ? `<small class="friends-muted">${html(lib.reason)}</small>` : ''}</span></label>`).join('');
      share.disabled = save.disabled = false;
      card.querySelector('fieldset').disabled = false;
    };
    async function write(prefs, immediate = false) {
      if (!valid()) return;
      share.disabled = save.disabled = true;
      card.querySelector('fieldset').disabled = true;
      status.textContent = immediate ? '正在关闭共享…' : '正在保存…';
      try {
        const result = unwrap(await API.request(base + '/preferences', {method:'PUT', body:prefs, signal:controller.signal}));
        if (!valid()) return;
        render(result); status.textContent = result.share_enabled ? '已保存：仅所选媒体库的观看状态与最近历史可见。' : '共享已关闭，其他成员无法查看你的观看动态和历史。';
      } catch(error) {
        if (!valid() || error.name === 'AbortError') return;
        share.checked = persisted.share_enabled; status.textContent = '未保存：' + message(error); share.disabled = save.disabled = false; card.querySelector('fieldset').disabled = false;
      }
    }
    const selected = () => [...card.querySelectorAll('#friendsLibraries input:checked:not(:disabled)')].map(input => Number(input.value));
    // Opt-out takes effect immediately. Opt-in requires explicit Save with its library list.
    share.onchange = () => {
      if (!share.checked && persisted.share_enabled) write({share_enabled:false, library_ids:selected()}, true);
      else status.textContent = '点击“保存共享设置”后生效。';
    };
    save.onclick = () => write({share_enabled:share.checked, library_ids:selected()});
    API.request(base + '/preferences', {signal:controller.signal}).then(unwrap).then(prefs => {
      if (!valid()) return; libraries = prefs.libraries || []; render(prefs);
      status.textContent = prefs.share_enabled ? '当前已开启共享，可调整公开范围。' : '共享默认关闭，开启前请勾选允许公开的媒体库。';
    }).catch(error => {if (valid() && error.name !== 'AbortError') status.textContent = message(error);});
  }
  document.addEventListener('DOMContentLoaded', init, {once:true});
  return {init, enabled, settings, refreshButton, open, openHome, close, dispose, label};
})();
