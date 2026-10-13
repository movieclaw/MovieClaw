// Strict HTTP fixtures mirror the server's public response envelopes, without NAS credentials.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const ui = path.resolve(__dirname, '../../ui');
const csp = Object.entries(require('../../src-tauri/tauri.conf.json').app.security.csp)
  .map(([directive, values]) => `${directive} ${values}`).join('; ');
const imageData = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==';
const imageBytes = Buffer.from(imageData, 'base64');
const ok = data => ({ code: 0, message: 'ok', data });
let state;
const reset = options => state = { authenticated: true, initialized: true, requests: [], created: [], stopped: [], ...options };
reset({});
const item = n => ({ media_item_id: n, library_id: 1, kind: n === 3 ? 'tv' : 'movie',
  title: n === 3 ? '第三季续播' : `影片 ${String(n).padStart(3, '0')}`, year: 2025,
  poster_url: state.images ? '/fixture-images/protected.png' : null,
  backdrop_url: state.images ? '/fixture-images/good.png' : null,
  logo_url: state.images ? '/fixture-images/missing-logo.png' : null,
  file_count: 1, total_size_bytes: 1024,
  seasons: n === 3 ? [1, 2, 3] : [], episode_count: n === 3 ? 9 : 0, resolutions: ['1080p'], missing_count: 0 });
const file = n => ({ id: n, file_id: n, state: 'in_place', container: 'mkv', video_codec: 'hevc',
  duration_ms: 3600000, size_bytes: 1024, resolution: '1080p', audio_streams: [], subtitle_streams: [],
  season_number: n === 3 ? 3 : null, episode_number: n === 3 ? 2 : null });
const session = body => {
  const sid = `session-${state.created.length + 1}`;
  state.created.push(sid);
  return { session_id: sid, stream_url: state.hls ? '/test-media/index.m3u8' : '/fixture.mp4', timeline: 'session', start_ms: body.start_ms ?? 300000,
    decision: { outcome: 'plan', tier: 1, audio_tracks: [], subtitles: [], source_duration_ms: 3600000 },
    source: { file_id: body.file_id || body.media_item_id, container: 'mkv', video_codec: 'hevc', duration_ms: 3600000 },
    subtitle_urls: [], chapters: [], segments: [], watch: { position_ms: 300000, duration_ms: 3600000 } };
};
async function bodyOf(req) {
  const chunks = []; for await (const chunk of req) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString(); return text ? JSON.parse(text) : null;
}
function json(res, data, status = 200) {
  res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(data));
}
http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname === '/__test/reset') { reset(await bodyOf(req) || {}); return json(res, { ok: true }); }
    if (url.pathname === '/__test/state') return json(res, state);
    if (url.pathname === '/__test/friends') { Object.assign(state, await bodyOf(req)); return json(res, {ok:true}); }
    if (url.pathname === '/__test/image') {
      const imagePath = url.searchParams.get('path');
      state.imageRequests ||= []; state.imageRequests.push(imagePath);
      const protectedCover = state.libraryCovers === 'protected' && /^\/api\/v1\/libraries\/\d+\/cover(?:\?w=600)?$/.test(imagePath);
      const episode = state.episodeImages && /^\/api\/v1\/fixture-images\/episode-\d+\.png$/.test(imagePath);
      if (!episode && !protectedCover && (!state.images || imagePath !== '/api/v1/fixture-images/protected.png')) return json(res, {}, 404);
      res.writeHead(200, { 'Content-Type': 'text/plain' }); return res.end('data:image/png;base64,' + imageData);
    }
    if (url.pathname.startsWith('/api/v1/fixture-images/')) {
      if (state.images && url.pathname.endsWith('/good.png')) {
        res.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': imageBytes.length }); return res.end(imageBytes);
      }
      return json(res, {}, url.pathname.endsWith('/protected.png') ? 401 : 404);
    }
    if (url.pathname === '/__test/update/start') {
      const args = await bodyOf(req); state.updateDownloads ||= {};
      const downloadId = 'fixture-update-' + (Object.keys(state.updateDownloads).length + 1);
      state.updateDownloads[downloadId] = { version: args.version, cancelled: false, completed: false, settled: false };
      return json(res, { downloadId, total: 10240 });
    }
    if (url.pathname === '/__test/update') {
      const { command, args, fixtureDownloadId } = await bodyOf(req);
      state.updateRequests ||= []; state.updateRequests.push({ command, args });
      if (command === 'check_for_updates') {
        if (state.updateCheckFailure) return json(res, { code: 'UPDATE_NETWORK', message: '更新服务暂不可用' }, 503);
        if (state.updateCurrent) return json(res, {has_update:false,current_version:'1.0.0',latest_version:'windows-v1.0.0',message:'已是最新版本 (1.0.0)',release_notes:state.updateNotes || ''});
        if (state.updateSameVersion) return json(res, {has_update:true,current_version:'1.0.0',latest_version:'windows-v1.0.0',message:'发现 1.0.0 的新构建 bbbbbbbb（当前 aaaaaaaa）',release_notes:'Windows 10/11 x64；安装后输入服务器地址。'});
        return json(res, { has_update: true, current_version: '0.2.111', latest_version: 'windows-v0.2.112',
          message: '发现新版本 windows-v0.2.112', release_notes: state.updateNotes || '修复播放与账号体验。' });
      }
      if (command === 'download_update') {
        const entry = state.updateDownloads?.[fixtureDownloadId];
        const delay = state.updateDelays?.shift() ?? state.updateDelay ?? 20;
        if (delay) await new Promise(resolve => setTimeout(resolve, delay));
        if (entry) entry.settled = true;
        if (!entry || entry.cancelled) return json(res, { code: 'DOWNLOAD_CANCELLED', message: '下载已取消' }, 409);
        if (state.updateDownloadFailure) return json(res, { code: 'HASH_MISMATCH', message: 'SHA-256 不匹配，安装包已删除' }, 422);
        entry.completed = true;
        return json(res, { downloadId: fixtureDownloadId, version: entry.version, size: 10240, sha256: 'a'.repeat(64),
          signature: state.updateSignature || 'valid', signer: state.updateSignature === 'unsigned' ? null : 'CN=MovieClaw Fixture',
          format: state.updateFormat || 'nsis', filename: state.updateFormat === 'portable' ? 'MovieClaw-portable-x64.zip' : 'MovieClaw-Setup-x64.exe' });
      }
      if (command === 'cancel_update_download') {
        const entry = state.updateDownloads?.[args.downloadId]; if (entry) entry.cancelled = true;
        return json(res, !!entry);
      }
      if (command === 'install_downloaded_update') {
        const entry = state.updateDownloads?.[args.downloadId];
        if (!entry?.completed || entry.cancelled) return json(res, { code: 'PACKAGE_MISSING', message: '没有可安装的更新' }, 409);
        if (state.updateSignature === 'unsigned' && !args.allowUnsigned) return json(res, { code: 'UNSIGNED_PACKAGE', message: '未签名安装包需要明确确认' }, 403);
        if (state.updateFormat === 'portable') return json(res, { code: 'PORTABLE_PACKAGE', message: '便携版需要手动安装' }, 409);
        return json(res, { installing: true });
      }
      if (command === 'open_release_page') return json(res, true);
      if (command === 'open_downloaded_update') return json(res, !!state.updateDownloads?.[args.downloadId]?.completed);
      return json(res, { code: 'UNKNOWN_UPDATE_COMMAND', message: 'Unknown update fixture command' }, 404);
    }
    if (url.pathname === '/__test/native') {
      const { command, args } = await bodyOf(req);
      state.nativeRequests ||= []; state.nativeRequests.push({ command, username: args.username, pairingId: args.pairingId });
      const status = () => ({ mode: state.nativeAuth === 'cookie' ? 'cookie' : 'device', initialized: state.initialized,
        session: state.authenticated ? { username: state.username || 'fixture', role: state.role || 'admin', capabilities: state.capabilities || {} } : null,
        accounts: state.savedAccounts || [{ username: state.username || 'fixture', nickname: '当前账号', active: state.authenticated, authenticated: state.authenticated }],
        pairing_supported: state.nativeAuth !== 'cookie', compatibility_reason: state.nativeAuth === 'cookie' ? '服务器尚不支持 Windows 设备登录，请升级服务器。' : null, context_generation: 1 });
      if (command === 'native_auth_status') return json(res, status());
      if (command === 'native_password_login') {
        if (state.loginDelay) await new Promise(resolve => setTimeout(resolve, state.loginDelay));
        if (state.loginFailures > 0) { state.loginFailures--; return json(res, { status: 401, code: 'BAD_PASSWORD', message: '密码错误，请重试' }, 401); }
        state.authenticated = true; state.username = args.username; return json(res, status());
      }
      if (command === 'native_select_account') { state.authenticated = true; state.username = args.username; return json(res, status()); }
      if (command === 'native_remove_account' || command === 'native_logout') { state.authenticated = false; return json(res, status()); }
      if (command === 'native_pair_begin') {
        state.pairingId = 'pair-' + state.nativeRequests.length; state.pairCancelled = false;
        return json(res, { pairing_id: state.pairingId, user_code: 'FIX-1234', verification_uri: 'http://127.0.0.1:4179/pair', verification_uri_complete: 'http://127.0.0.1:4179/pair?user_code=FIX-1234', expires_at: Date.now() / 1000 + (state.pairExpires || 180), interval: 1 });
      }
      if (command === 'native_pair_cancel') { state.pairCancelled = true; return json(res, null); }
      if (command === 'native_pair_poll') {
        if (state.pairDelay) await new Promise(resolve => setTimeout(resolve, state.pairDelay));
        if (state.pairCancelled || state.pairingId !== args.pairingId) return json(res, { status: 'cancelled', interval: 1 });
        const result = state.pairStatuses?.shift() || 'pending';
        if (result === 'approved') { state.authenticated = true; state.username = 'paired'; }
        return json(res, { status: result, interval: 1, ...(result === 'approved' ? { session: status().session } : {}) });
      }
      return json(res, { status: 404, message: 'Unknown native fixture command' }, 404);
    }
    if (url.pathname.startsWith('/api/v1/test-media/')) {
      const name = path.basename(url.pathname);
      const filename = path.join(__dirname, 'media', name);
      if (!fs.existsSync(filename)) return json(res, {}, 404);
      const bytes = fs.readFileSync(filename);
      const match = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || '');
      const headers = { 'Content-Type': name.endsWith('.m3u8') ? 'application/vnd.apple.mpegurl' : 'video/mp4', 'Accept-Ranges': 'bytes' };
      if (match) {
        const start = Number(match[1]), end = Math.min(Number(match[2] || bytes.length - 1), bytes.length - 1);
        res.writeHead(206, { ...headers, 'Content-Range': `bytes ${start}-${end}/${bytes.length}`, 'Content-Length': end - start + 1 });
        return res.end(bytes.subarray(start, end + 1));
      }
      res.writeHead(200, { ...headers, 'Content-Length': bytes.length }); return res.end(bytes);
    }
    if (url.pathname === '/fixture.mp4' || url.pathname === '/api/v1/fixture.mp4') {
      res.writeHead(200, { 'Content-Type': 'video/mp4', 'Content-Length': fs.statSync(path.join(__dirname, 'fixture.mp4')).size });
      fs.createReadStream(path.join(__dirname, 'fixture.mp4')).pipe(res); return;
    }
    if (!url.pathname.startsWith('/api/v1/')) {
      const relative = decodeURIComponent(url.pathname === '/' ? '/desktop/index.html' : url.pathname);
      const filename = path.resolve(ui, '.' + relative);
      if (!filename.startsWith(ui + path.sep) || !fs.existsSync(filename)) return json(res, {}, 404);
      const type = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.wasm': 'application/wasm' }[path.extname(filename)] || 'application/octet-stream';
      res.writeHead(200, { 'Content-Type': type, 'Content-Security-Policy': csp }); fs.createReadStream(filename).pipe(res); return;
    }
    const route = url.pathname.slice('/api/v1'.length);
    const body = await bodyOf(req);
    // Avoid recording even fixture passwords, so this stays safe for CI artifacts.
    state.requests.push({ method: req.method, path: route, query: Object.fromEntries(url.searchParams), libraryIds: url.searchParams.getAll('library_ids').map(Number), body: body && route === '/auth/login' ? { username: body.username } : body });
    if (route === '/health') return json(res, { status: 'ok', service: 'movieclaw', version: '0.34.0' });
    if (route === '/auth/bootstrap') return json(res, ok({ initialized: state.initialized }));
    if (route === '/auth/login') {
      if (state.loginDelay) await new Promise(resolve => setTimeout(resolve, state.loginDelay));
      if (state.loginFailures > 0) {
        state.loginFailures--;
        return json(res, { message: '密码错误，请重试' }, 401);
      }
      if (!body?.username || !body?.password) return json(res, { message: '密码错误' }, 401);
      state.authenticated = true; state.username = body.username;
      return json(res, ok({ username: state.username, role: state.role || 'admin', capabilities: state.capabilities || {} }));
    }
    if (!state.authenticated) return json(res, { message: '需要登录' }, 401);
    if (state.friends && await require('./friends-fixture.cjs')({route,req,res,state,url,body,json,ok})) return;
    if (state.catalog && await require('./catalog-fixture.cjs')({route,req,res,state,url,body,json,ok})) return;
    if (route === '/auth/me') return json(res, ok({ username: state.username || 'fixture', role: state.role || 'admin', capabilities: state.capabilities || {} }));
    if (route === '/auth/accounts') return json(res, ok([
      { username: state.username || 'fixture', nickname: '当前账号', role: state.role || 'admin', active: true },
      { username: 'second', nickname: '另一个账号', role: 'member', active: false },
    ]));
    if (route === '/auth/accounts/switch') {
      if (Object.keys(body || {}).join() !== 'username') return json(res, { message: '必须按 username 切换' }, 422);
      state.username = body.username;
      return json(res, ok({ username: state.username, role: 'member' }));
    }
    if (route === '/llm/providers') return json(res,ok(state.noLlm ? [] : [{id:1,name:'fixture'}]));
    if (route === '/jobs') return json(res,ok({items:(state.jobs || []).filter(job => Number(job.input_data?.file_id) === Number(url.searchParams.get('resource_id')))}));
    const preview = route.match(/^\/libraries\/files\/(\d+)\/subtitles\/generation-preview$/);
    if (preview) {
      if (state.previewDelay) await new Promise(resolve=>setTimeout(resolve,state.previewDelay));
      if (state.previewUnsupported) return json(res,{message:'unsupported'},404);
      return json(res,ok({candidates:[{kind:'embedded',key:'0',language:'eng',format:'srt',selectable:true,reasons:['原始参考字幕']}],selected_source_key:url.searchParams.get('source_candidate_key') || 'embedded:0',estimated_tokens:2000,event_count:100,output_filename:'fixture.ai.chs.srt',warnings:[],blocker:null,...state.generationPreview}));
    }
    const generation = route.match(/^\/libraries\/files\/(\d+)\/subtitles\/generations$/);
    if (generation && req.method === 'POST') {
      if (state.role === 'member') return json(res,{message:'需要管理员'},403);
      if (state.generationFailure) return json(res,{message:'服务器模型不可用'},503);
      const fileId=Number(generation[1]);
      state.generationRequests ||= []; state.generationRequests.push({fileId,...body});
      const existing=(state.jobs || []).find(job=>job.input_data.file_id===fileId && ['queued','running','blocked'].includes(job.status));
      if (existing) return json(res,ok(existing),202);
      const job={id:'subtitle-'+((state.jobs || []).length+1),job_type:'subtitle.generate',status:'queued',input_data:{file_id:fileId,...body},resources:[{resource_type:'library_file',resource_id:String(fileId)}],progress:{message:'任务已入队',percent:null}};
      state.jobs ||= []; state.jobs.unshift(job);return json(res,ok(job),202);
    }
    const jobRoute=route.match(/^\/jobs\/([^/]+)(?:\/(cancel|retry))?$/);
    if (jobRoute) {
      const job=(state.jobs || []).find(job=>job.id===jobRoute[1]);
      if (!job) return json(res,{message:'任务不存在'},404);
      if (jobRoute[2]==='cancel') {job.status='cancelled';job.progress.message='任务已取消';return json(res,ok({cancelled:true,job}));}
      if (jobRoute[2]==='retry') {job.status='queued';job.progress.message='重新排队';return json(res,ok({created:true,job}));}
      if (state.jobStates?.length) {job.status=state.jobStates.shift();job.progress={message:job.status==='succeeded'?'字幕生成完成':'正在翻译',percent:job.status==='succeeded'?100:45};}
      if (job.status==='succeeded') {
        for (const files of Object.values(state.mediaFiles || {})) for (const entry of files) {
          if (entry.id!==job.input_data.file_id || entry.subtitle_streams.some(stream=>stream.file_name==='fixture.ai.chs.srt')) continue;
          entry.subtitle_streams.push({external:true,file_name:'fixture.ai.chs.srt',codec:'srt',language:'chs'});
        }
      }
      return json(res,ok(job));
    }
    if (route === '/libraries') return json(res, ok(state.libraries || [{ id: 1, name: '测试媒体库', kind: 'movie', stats: { item_count: state.itemCount || 245 } }]));
    if (/^\/libraries\/\d+\/cover$/.test(route)) {
      if (state.libraryCovers === 'available') {
        res.writeHead(200, { 'Content-Type': 'image/png' }); return res.end(imageBytes);
      }
      return json(res, {}, state.libraryCovers === 'protected' ? 401 : 404);
    }
    if (route === '/ui/preferences') return json(res, ok({ home: { rows: state.homeRows || [] } }));
    if (/^\/libraries\/kinds\/\w+\/genres$/.test(route)) return json(res, ok([{ value: '28', label: '动作', count: 120, cover_url: null }, { value: '18', label: '剧情', count: 125, cover_url: null }]));
    if (route === '/collections') return json(res, ok([{ id: 8, name: '测试合集', library_id: 1, hidden: false, item_count: state.itemCount || 245 }]));
    if (/^\/(libraries\/1|libraries\/kinds\/\w+|collections\/8)\/items$/.test(route) || route === '/playback/favorites') {
      const offset = Number(url.searchParams.get('offset') || 0);
      const limit = Number(url.searchParams.get('limit') || 20);
      if (limit > 200) return json(res, { message: 'limit must be <=200' }, 422);
      const total = state.itemCount || 245;
      const reversed = url.searchParams.get('sort') === 'title' && url.searchParams.get('order') === 'desc';
      const page = Array.from({ length: Math.max(0, Math.min(limit, total - offset)) }, (_, i) => item(reversed ? total - offset - i : offset + i + 1));
      return json(res, ok(route.startsWith('/libraries/') ? page : { items: page, total }));
    }
    if (route === '/search/library') {
      const q = url.searchParams.get('q') || '';
      if (q === '慢搜索') await new Promise(resolve => setTimeout(resolve, 900));
      const next = url.searchParams.has('cursor');
      return json(res, ok({ ...(state.legacySearchScope ? {} : {scope_library_ids:url.searchParams.getAll('library_ids').map(Number),exclude_adult:true}), items: state.searchItems || [{ item: { ...item(next ? 202 : 201), title: q }, library_ids: [1], match: { type: 'title', source_field: 'title', matched_name: q, label: url.searchParams.has('person_id') ? '演员：测试演员' : '片名匹配' } }],
        people: state.searchPeople ? [{ id: 9, tmdb_person_id: 9, name: '测试演员', item_count: 2, profile_path: null, match: { label: '演员：测试演员' } }] : [], suggestions: state.searchPeople ? [{ type: 'title', text: '推荐片名', media_item_id: 201, label: '片名匹配' }] : [], next_cursor: next ? null : 'fixture-next' }));
    }
    if (route === '/playback/up-next') return json(res, ok({ items: [{ ...item(3), season_number: 3, episode_number: state.longSeason ? 1051 : 2, position_ms: 300000, duration_ms: 3600000, progress_percent: 8, episode_title: state.longSeason ? '第1051集' : '第二集' }] }));
    if (route === '/playback/marks') {
      if (req.method === 'GET' && state.marksDelay) await new Promise(resolve => setTimeout(resolve, state.marksDelay));
      state.marks ||= {};
      const target = req.method === 'POST' ? body : Object.fromEntries(url.searchParams);
      const key = [target.media_item_id, target.season_number || '', target.episode_number || ''].join(':');
      if (req.method === 'POST') state.marks[key] = { ...state.marks[key], ...body };
      return json(res, ok({ played: false, is_favorite: false, unplayed_count: 2, ...state.marks[key] }));
    }
    if (route === '/playback/resume') return json(res, ok({ season_number: 3, episode_number: 2, position_ms: 300000, duration_ms: 3600000 }));
    if (/^\/libraries\/1\/items\/\d+$/.test(route)) {
      const n = Number(route.split('/').pop());
      return json(res, ok({ ...item(n), files: state.mediaFiles?.[n] || [file(n)], local_meta: { plot: '测试简介', genres: [], runtime_minutes: 60, actors: [{ name: '测试演员', tmdb_person_id: 9, thumb_url: state.images ? '/fixture-images/good.png' : null }] }, collections: [] }));
    }
    if (route.endsWith('/episodes')) {
      const season = Number(url.searchParams.get('season_number') || 3);
      return json(res, ok({ season_number: season, resume_episode: state.longSeason ? 1051 : 2, episodes: Array.from({ length: state.longSeason ? 1101 : 3 }, (_, i) => i + 1).map(n => ({ season_number: season, episode_number: n, name: `第 ${n} 集`, title: `第 ${n} 集`, still_url: state.episodeImages ? `/fixture-images/episode-${n}.png` : null, owned: n !== (state.longSeason ? 1052 : 0), played: state.marks?.[`3:${season}:${n}`]?.played ?? n === 1, files: [file(3)], duration_ms: 3600000 })) }));
    }
    if (route === '/people/9') return json(res, ok({ name: '测试演员', profile_url: state.images ? '/fixture-images/good.png' : null, credits: [{ ...item(3), department: 'cast', character: '演员', library_id: 1 }] }));
    if (route === '/playback/sessions' && req.method === 'POST') {
      if (!body?.media_item_id || !body?.capability || body.capability.quality_tier != null) return json(res, { message: 'invalid playback contract' }, 422);
      const result = session(body);
      if (state.sessionDelay) await new Promise(resolve => setTimeout(resolve, state.sessionDelay));
      return json(res, ok(result));
    }
    if (/^\/playback\/sessions\/[^/]+$/.test(route) && req.method === 'DELETE') { state.stopped.push(route.split('/').pop()); return json(res, ok(null)); }
    if (route.endsWith('/ping') || route === '/playback/progress') return json(res, ok(null));
    return json(res, { message: `fixture has no route: ${route}` }, 404);
  } catch (error) { json(res, { message: error.message }, 500); }
}).listen(4179, '127.0.0.1');
