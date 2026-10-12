// MovieClaw Desktop — 内置 HTML5 播放器（HLS.js + Video）

// ===== 自定义 HLS Loader：走 Rust proxy_api 代理，绕过 CORS + 自动携带 Cookie =====
// HLS.js 自定义 loader 接口：constructor / load / abort / destroy
function ProxyHlsLoader(config) {
  this.config = config || {};
  // stats 必须在构造时创建：hls.js 在调用 load() 之前就执行 frag.stats = loader.stats
  this.stats = {
    aborted: false, loaded: 0, total: 0, retry: 0, chunkCount: 0, bwEstimate: 0, _metered: false,
    loading: { start: 0, first: 0, end: 0 },
    parsing: { start: 0, end: 0 },
    buffering: { start: 0, end: 0 },
  };
  this.context = null;
  this.callbacks = null;
}

ProxyHlsLoader.prototype.destroy = function () {
  this.abort();
  this.callbacks = null;
};

ProxyHlsLoader.prototype.abort = function () {
  const loading = this.loading;
  this.loading = false;
  this.stats.aborted = true;
  this.controller?.abort();
  if (this.streamId) window.__TAURI__.core.invoke('release_media_stream', { streamId: this.streamId }).catch(() => {});
  this.streamId = null;
  this.sequence = (this.sequence || 0) + 1;
  if (loading) this.callbacks?.onAbort?.(this.stats, this.context, null);
};

ProxyHlsLoader.prototype.load = function (context, config, callbacks) {
  this.abort();
  this.context = context; this.callbacks = callbacks; this.loading = true;
  const stats = this.stats;
  Object.assign(stats, { aborted: false, loaded: 0, total: 0, retry: 0, chunkCount: 0, bwEstimate: 0, _metered: false,
    loading: { start: performance.now(), first: 0, end: 0 }, parsing: { start: 0, end: 0 }, buffering: { start: 0, end: 0 } });
  const controller = this.controller = new AbortController();
  const sequence = this.sequence;
  const alive = () => !stats.aborted && this.sequence === sequence && !controller.signal.aborted;
  const binary = context.responseType === 'arraybuffer';
  const progressive = !!this.config.progressive && binary && Number.isFinite(config?.highWaterMark) && !!callbacks.onProgress;
  const generation = Player.generation;
  const headers = {};
  if (Number.isFinite(context.rangeStart)) headers.Range = 'bytes=' + context.rangeStart + '-' +
    (Number.isFinite(context.rangeEnd) ? context.rangeEnd - 1 : '');
  let streamId;
  let timer;
  const timeoutMs = config?.timeout || config?.maxLoadTimeMs || 120000;
  const operation = async () => {
    try {
      const grant = await window.__TAURI__.core.invoke('grant_media_stream', { url: playbackMediaUrl(context.url) });
      streamId = grant.streamId;
      if (!alive()) return;
      if (!grant.url || !streamId) throw new Error('媒体代理未返回有效地址');
      this.streamId = streamId;
      timer = setTimeout(() => {
        if (!alive()) return;
        this.loading = false;
        controller.abort();
        callbacks.onTimeout?.(stats, context, null);
      }, timeoutMs);
      const response = await fetch(grant.url, { headers, signal: controller.signal });
      if (!alive()) return;
      stats.loading.first = performance.now();
      const networkDetails = { status: response.status, headers: Object.fromEntries(response.headers) };
      if (!response.ok) {
        this.loading = false;
        callbacks.onError({ code: response.status, text: 'HTTP ' + response.status }, stats, context, networkDetails);
        return;
      }
      stats.total = Number(response.headers.get('content-length')) || 0;
      const chunks = [];
      if (response.body?.getReader) {
        const reader = response.body.getReader();
        try {
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            if (!alive()) return;
            stats.loaded += value.byteLength;
            if (binary && generation === Player.generation && Player._net) { Player._net.bytes += value.byteLength; stats._metered = true; }
            if (progressive) callbacks.onProgress(stats, context, value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength), networkDetails);
            else chunks.push(value);
          }
        } finally { reader.releaseLock(); }
      } else {
        const data = new Uint8Array(await response.arrayBuffer()); chunks.push(data); stats.loaded = data.byteLength;
      }
      if (!alive()) return;
      const data = new Uint8Array(progressive ? 0 : stats.loaded);
      let offset = 0;
      for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.byteLength; }
      stats.total = stats.loaded; stats.loading.end = performance.now();
      if (generation === Player.generation) Player.measure('delivery', { elapsedMs: stats.loading.end - stats.loading.start });
      this.loading = false;
      callbacks.onSuccess({ url: context.url, data: binary ? data.buffer : new TextDecoder().decode(data), code: response.status }, stats, context, networkDetails);
    } catch (error) {
      if (!alive()) return;
      stats.loading.end = performance.now();
      this.loading = false;
      callbacks.onError({ code: 0, text: error.message || '媒体代理请求失败' }, stats, context, null);
    } finally {
      clearTimeout(timer);
      if (streamId) await window.__TAURI__.core.invoke('release_media_stream', { streamId }).catch(() => {});
      if (this.sequence === sequence) { this.streamId = null; this.loading = false; }
    }
  };
  operation();
};

// 挂到 window 确保全局可见
window.ProxyHlsLoader = ProxyHlsLoader;

// 收尾不能让窗口退出或换片无限等待网络。
function boundedPlaybackWait(promise, milliseconds) {
  let timer;
  return Promise.race([promise, new Promise(resolve => { timer = setTimeout(resolve, milliseconds); })])
    .finally(() => clearTimeout(timer));
}

function playerText(value) {
  return String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function playbackNetworkKey() {
  const connection = navigator.connection;
  // Browser APIs cannot establish the machine's subnet. Keep unknown separate
  // from measured link classes rather than calling every private server "home".
  return [connection?.type || 'unknown', connection?.effectiveType || 'unknown', connection?.saveData ? 'limited' : 'normal'].join(':');
}

function playbackPreferenceKey(mediaId) {
  return 'mc_player.' + API.baseUrl + '#' + (App.session?.username || '') + '#' + mediaId + '#' + playbackNetworkKey();
}

function rememberedQuality(mediaId) {
  try {
    const entries = JSON.parse(localStorage.getItem('mc_quality_memory') || '{}');
    const value = entries[playbackPreferenceKey(mediaId)]?.height;
    return [480, 720, 1080].includes(value) ? value : 0;
  } catch (_) { return 0; }
}

function rememberQuality(mediaId, height) {
  try {
    const entries = JSON.parse(localStorage.getItem('mc_quality_memory') || '{}');
    const key = playbackPreferenceKey(mediaId);
    if (height > 0) entries[key] = { height, at: Date.now() };
    else delete entries[key];
    Object.keys(entries).sort((a, b) => entries[b].at - entries[a].at).slice(300).forEach(k => delete entries[k]);
    localStorage.setItem('mc_quality_memory', JSON.stringify(entries));
  } catch (_) {}
}

function languageMatches(language, preferred) {
  const value = String(language || '').toLowerCase();
  return preferred === 'zh' ? /^(zh|zho|chi|cmn|yue)/.test(value)
    : preferred === 'en' ? /^(en|eng)/.test(value) : value === preferred;
}

function playbackMediaUrl(url) {
  if (/^https?:\/\//i.test(url)) return url;
  return API.baseUrl + (String(url).startsWith('/api/') ? url : '/api/v1' + (String(url).startsWith('/') ? url : '/' + url));
}

function mpvTrackMap(tracks, subtitlePlans, subtitleUrls, originalFile, nativeSources = []) {
  const result = { audio: [], subtitles: [] };
  for (const [type, output] of [['audio', result.audio], ['sub', result.subtitles]]) {
    const internal = tracks.filter(t => t.type === type && !t.external)
      .sort((a, b) => (a['ff-index'] ?? a.id) - (b['ff-index'] ?? b.id));
    if (originalFile) internal.forEach((track, ordinal) => output.push({ ...track, ref: 'embedded:' + ordinal }));
    else if (type === 'audio') internal.forEach(track => output.push({ ...track, ref: null }));
  }
  const key = url => { try { return decodeURIComponent(new URL(playbackMediaUrl(url)).href); } catch (_) { return String(url || ''); } };
  tracks.filter(t => t.type === 'sub' && t.external).forEach(track => {
    let index = subtitleUrls.findIndex(url => key(url) === key(track['external-filename']));
    if (index < 0) {
      const sourceOrdinal = nativeSources.indexOf(track['external-filename']);
      const delivered = subtitlePlans.map((plan, i) => ({ plan, i })).filter(({ plan }) => !originalFile || !plan.track_ref.startsWith('embedded:'));
      index = sourceOrdinal >= 0 ? delivered[sourceOrdinal]?.i ?? -1 : -1;
    }
    if (index >= 0 && subtitlePlans[index]) result.subtitles.push({ ...track, ref: subtitlePlans[index].track_ref });
  });
  return result;
}

function trickplayTile(index, fileMs) {
  if (!index?.ready || !(index.interval_ms > 0 && index.columns > 0 && index.rows > 0 && index.count > 0)) return null;
  const tile = Math.max(0, Math.min(index.count - 1, Math.floor(fileMs / index.interval_ms)));
  const capacity = index.columns * index.rows;
  const sheet = index.sheets?.[Math.floor(tile / capacity)];
  return sheet ? { sheet, x: (tile % index.columns) * index.tile_width,
    y: Math.floor(tile % capacity / index.columns) * index.tile_height,
    width: index.tile_width, height: index.tile_height } : null;
}

// ===== 解码能力探测（移植自 web 客户端 lib/player/capability.ts，字段与服务端 ClientCapabilityIn 对应）=====
// 不用 canPlayType（分不清「能解」和「能流畅解」），走 mediaCapabilities.decodingInfo：
// 探测喂 RFC 6381 全串，上报归一到家族名（服务端与 ffprobe 落库的 codec_name 比对）。
// video/audio 报空数组 = 告诉服务端「浏览器什么都不支持」→ 所有影片全量转码，起播慢。
// Browser codec decoding support does not prove HDR rendering or display output.
// Until the whole HDR path is measured, request server SDR output for HTML5.
const CAPABILITY_SCHEMA_VERSION = 3;
const CAPABILITY_CACHE_KEY = 'movieclaw.desktop.capability';
// 4K 一档特意用 Main 10 / 高 profile：真实 4K 片源几乎都是 10bit/高码率，用 1080p 串探出来的结论对不上
const CAPABILITY_VIDEO_MATRIX = {
  h264: (h) => (h >= 2160 ? 'avc1.640033' : 'avc1.640028'),
  hevc: (h) => (h >= 2160 ? 'hvc1.2.4.L153.B0' : 'hvc1.1.6.L120.90'),
  av1: (h) => (h >= 2160 ? 'av01.0.12M.10' : 'av01.0.08M.08'),
  vp9: (h) => (h >= 2160 ? 'vp09.02.51.10' : 'vp09.00.41.08'),
};
// DTS/TrueHD 不探：没有浏览器能解，服务端一律转码
const CAPABILITY_AUDIO_MATRIX = {
  aac: 'mp4a.40.2', ac3: 'ac-3', eac3: 'ec-3', opus: 'opus', flac: 'flac', mp3: 'mp4a.69',
};
const CAPABILITY_HEIGHTS = [2160, 1440, 1080, 720];
const CAPABILITY_CHANNELS = [8, 6, 2];

function capBitrateFor(height) {
  if (height >= 2160) return 25000000;
  if (height >= 1440) return 14000000;
  if (height >= 1080) return 8000000;
  return 4000000;
}

async function capDecodingInfo(mseAvailable, kind, contentType, height, channels) {
  const unsupported = { supported: false, smooth: false, powerEfficient: false };
  const mc = navigator.mediaCapabilities;
  if (!mc || !mc.decodingInfo) return unsupported;
  // 档位都经 MSE 喂分片（media-source）；无 MSE 时才用 file 语义
  const type = mseAvailable ? 'media-source' : 'file';
  try {
    const r = await mc.decodingInfo(kind === 'video'
      ? { type, video: { contentType, width: Math.round(((height || 1080) * 16) / 9), height: height || 1080, bitrate: capBitrateFor(height || 1080), framerate: 24 } }
      : { type, audio: { contentType, channels: String(channels || 2) } });
    return { supported: r.supported, smooth: r.smooth, powerEfficient: r.powerEfficient };
  } catch (_) {
    // 非法 codec 串会抛 TypeError，语义上等同不支持
    return unsupported;
  }
}

let capInflight = null;
async function getCapabilitySnapshot() {
  // UA 哈希：浏览器升级后 codec 支持可能变化，旧缓存自动作废
  const ua = navigator.userAgent;
  let uaHash = 0x811c9dc5;
  for (let i = 0; i < ua.length; i++) { uaHash ^= ua.charCodeAt(i); uaHash = Math.imul(uaHash, 0x01000193) >>> 0; }
  uaHash = uaHash.toString(16);
  try {
    const raw = localStorage.getItem(CAPABILITY_CACHE_KEY);
    if (raw) {
      const cached = JSON.parse(raw);
      if (cached.version === CAPABILITY_SCHEMA_VERSION && cached.uaHash === uaHash) return cached.snapshot;
    }
  } catch (_) { /* 存储不可用则重新探 */ }
  if (capInflight) return capInflight;

  capInflight = (async () => {
    const w = window;
    // ManagedMediaSource 优先（与 hls.js 实际后端一致），没有则 MediaSource
    const mse = w.ManagedMediaSource ? 'managed' : (w.MediaSource ? 'full' : 'none');
    const mseAvailable = mse !== 'none';
    const nativeHls = document.createElement('video').canPlayType('application/vnd.apple.mpegurl') !== '';

    const video = [];
    for (const family of Object.keys(CAPABILITY_VIDEO_MATRIX)) {
      let pick = null;
      for (const height of CAPABILITY_HEIGHTS) {
        const p = await capDecodingInfo(mseAvailable, 'video', `video/mp4; codecs="${CAPABILITY_VIDEO_MATRIX[family](height)}"`, height);
        if (p.supported && (!pick || height > pick.max_height)) pick = { max_height: height, smooth: p.smooth, power_efficient: p.powerEfficient };
      }
      // 一个高度都不支持 → 该家族不出现在快照（服务端据此转码）
      if (pick) video.push({ codec: family, ...pick });
    }
    const audio = [];
    for (const family of Object.keys(CAPABILITY_AUDIO_MATRIX)) {
      let maxChannels = null;
      for (const channels of CAPABILITY_CHANNELS) {
        const p = await capDecodingInfo(mseAvailable, 'audio', `audio/mp4; codecs="${CAPABILITY_AUDIO_MATRIX[family]}"`, null, channels);
        if (p.supported && (maxChannels === null || channels > maxChannels)) maxChannels = channels;
      }
      if (maxChannels !== null) audio.push({ codec: family, max_channels: maxChannels });
    }
    // mp4 恒成立；hls-fmp4 要么 MSE（hls.js）要么原生 HLS
    const containers = ['mp4'];
    if (mseAvailable || nativeHls) containers.push('hls-fmp4');
    const snapshot = {
      video, audio, containers,
      // false asks the server to tone-map HDR into SDR; codec probes above remain independent.
      hdr_passthrough: false,
      mse, is_mobile: false, native_hls: nativeHls,
    };
    try {
      localStorage.setItem(CAPABILITY_CACHE_KEY, JSON.stringify({ version: CAPABILITY_SCHEMA_VERSION, uaHash, probedAt: new Date().toISOString(), snapshot }));
    } catch (_) { /* 写不进只是下次再探 */ }
    return snapshot;
  })();
  try { return await capInflight; } finally { capInflight = null; }
}
window.getCapabilitySnapshot = getCapabilitySnapshot;

// ===== 全解码引擎（嵌入式 mpv）的能力申报（对齐 macOS PlayerCapability.native()）=====
// mpv 直读原文件、硬解不了的编码由它本机软解，申报 universal：服务端直接给档 0
// 原文件直连，不再为一路用不上的换封装/转码起 ffmpeg（NAS 冷启动白花 1.6 秒）。
// 编码/容器清单只在服务端不认 universal 时起作用（老服务端），按 mpv 实际能解的报。
// 音频只报「能原样装进 fMP4 分片」的编码（服务端 FMP4_COPY_AUDIO_CODECS）：报了
// TrueHD，老服务端会计划「换壳成 HLS fMP4 并原样拷 TrueHD」，ffmpeg 的 MP4 封装
// 不支持 TrueHD，转码进程启动即失败（macOS《蜘蛛侠》实测同款教训）。
// 不报 disc_image/disc_folder：嵌入式 mpv 不装载盘内结构，目录清单它吃不下。
function getUniversalCapabilitySnapshot() {
  return {
    video: ['h264', 'hevc', 'av1', 'vp9', 'vp8', 'mpeg2video', 'mpeg4', 'vc1']
      .map(codec => ({ codec, max_height: 2160, smooth: true, power_efficient: codec === 'h264' || codec === 'hevc' })),
    audio: ['aac', 'ac3', 'eac3', 'dts', 'flac', 'alac', 'opus', 'mp3']
      .map(codec => ({ codec, max_channels: 8 })),
    containers: ['mp4', 'hls-fmp4', 'mkv', 'webm', 'ts', 'm2ts', 'avi'],
    // This protocol flag permits HDR source bytes. mpv gpu-next maps them to its target;
    // it does not claim the attached monitor is HDR. Actual target is observed below.
    hdr_passthrough: true,
    mse: 'full', is_mobile: false, native_hls: false,
    universal: true, disc_image: false, disc_folder: false,
  };
}
window.getUniversalCapabilitySnapshot = getUniversalCapabilitySnapshot;

// ===== 播放看门狗（阈值逐一照搬 Shared/Player/PlaybackWatchdogs.swift + PlaybackRouting.swift）=====
// 三块纯逻辑：喂 1 Hz 样本、吐判定，动作由 App 执行。卡顿归因分三态，其中「线路慢」
// 明确不算失败——带宽不够的唯一出口是画质建议卡（换不换由用户定，2026-09-28 拍板）。
//
// 与 macOS 的一处刻意差异：Apple 的原文件直出故意不判掉帧（NativeEngine.swift
// 「掉帧不是换播放器的理由」），根因是那条路拿不到总帧数做分母。Windows 的 mpv 有
// frame-drop-count，分母用 time-pos × container-fps 估，因此档 0 直出也判——4K 解
// 不动就该降档，这正是 failed_tiers 回路要干的事。转码档（3/4）仍不判：再掉帧说明
// 连转码产物都放不动，继续降档只会更糟。

// 掉帧：10 秒窗（11 个 1 Hz 累计样本的首尾差）内掉帧率 ≥10%，且窗口 ≥100 帧才判
function createFrameDropTracker() {
  const WINDOW = 10, MIN_FRAMES = 100, RATIO = 0.1;
  let history = [];
  return {
    threshold: RATIO,
    // 喂一个累计样本；返回 null = 没到判定条件，否则是窗口掉帧率
    sample(dropped, total) {
      const last = history[history.length - 1];
      // 累计计数变小 = 引擎换了流，旧窗口作废（调用方漏 reset 的兜底）
      if (last && (total < last.total || dropped < last.dropped)) history = [];
      history.push({ dropped, total });
      if (history.length > WINDOW + 1) history.shift();
      if (history.length !== WINDOW + 1) return null;
      const first = history[0];
      const totalDelta = total - first.total;
      if (totalDelta < MIN_FRAMES) return null;
      return (dropped - first.dropped) / totalDelta;
    },
    reset() { history = []; },
  };
}

// 卡顿归因：解码卡 / 线路慢（不算失败）/ 连接断；缓冲够却不动先推 2 把再判死
function createStallWatch() {
  const DECODE_STALL_S = 8, DECODE_MIN_BUFFER = 3.0, SERVER_DEAD_S = 45, DIRECT_DEAD_S = 15;
  const NUDGE_AT = 3, MAX_NUDGES = 2, NUDGE_STEP = 0.1;
  let lastTime = null, stalledFor = 0, silentFor = 0, nudges = 0, sinceNudge = 99, everAdvanced = false;
  return {
    DIRECT_DEAD_S, SERVER_DEAD_S, NUDGE_STEP,
    reset() {
      lastTime = null; stalledFor = 0; silentFor = 0; nudges = 0; sinceNudge = 99; everAdvanced = false;
    },
    // receiving: 这一秒有没有从源收到字节；deadLimit: 缓冲见底后连续多少秒没字节算断线
    sample(time, bufferedAhead, paused, ended, seeking, receiving, deadLimit) {
      const advanced = lastTime != null && time > lastTime;
      // 「真正播起来过」只认小步前进：起播定位、用户拖动是一次大跳，不算
      if (advanced && !seeking && lastTime != null && time - lastTime < 5) everAdvanced = true;
      lastTime = time;
      sinceNudge += 1;
      if (paused || ended || seeking || advanced) {
        stalledFor = 0; silentFor = 0;
        // 只有远离上次推动的真实前进才算恢复——推动自己造成的播放头变化不作数
        if (advanced && sinceNudge > 3) nudges = 0;
        return 'ok';
      }
      stalledFor += 1;
      if (bufferedAhead >= DECODE_MIN_BUFFER) {
        silentFor = 0;
        if (stalledFor >= DECODE_STALL_S) { stalledFor = 0; nudges = 0; return 'decodeStalled'; }
        // 有数据却不动：先推一把（起播预滚阶段不推，否则会把预滚冲掉重来）
        if (everAdvanced && stalledFor >= NUDGE_AT && nudges < MAX_NUDGES) {
          nudges += 1; sinceNudge = 0; stalledFor = 0; return 'nudge';
        }
        return 'ok';
      }
      // 缓冲见底：字节还在进来就是线路慢，不算失败
      silentFor = receiving ? 0 : silentFor + 1;
      if (silentFor >= deadLimit) { stalledFor = 0; silentFor = 0; nudges = 0; return 'dead'; }
      return 'ok';
    },
    reason(verdict, deadLimit) {
      if (verdict === 'decodeStalled') return `播放停滞超过 ${DECODE_STALL_S} 秒，这一档的码流播放器吃不下`;
      return deadLimit < SERVER_DEAD_S
        ? `连续 ${deadLimit} 秒没有收到数据——连接可能中断了`
        : `连续 ${deadLimit} 秒没有收到服务端的数据——转码可能中断了`;
    },
  };
}

// 画质建议：只在等待期测速（缓冲满引擎会停下载，平时读数不可信）
function createQualitySuggestion() {
  const GRACE = 10, WINDOW = 300, MIN_STALLS = 2, LONG_WAIT = 8, LINK_MARGIN = 0.9;
  // 推荐档位阶梯（同 macOS QualityOption）：1080p 约 6、720p 约 3、480p 约 1.5 Mbps
  const LADDER = [[1080, 6e6], [720, 3e6], [480, 1.5e6]];
  let clock = 0, graceUntil = GRACE, stalls = [], stalling = false;
  let waitSeconds = 0, waitSpeeds = [], offered = false;
  function recommendedHeight(bps, currentHeight) {
    const lower = LADDER.filter(([h]) => currentHeight == null || h < currentHeight);
    const fit = lower.find(([, b]) => b <= bps * 0.8);
    return fit ? fit[0] : (lower.length ? lower[lower.length - 1][0] : null);
  }
  return {
    get offered() { return offered; },
    get waitSeconds() { return waitSeconds; },
    // 起播、跳转、从暂停恢复：接下来 10 秒的缓冲不算「卡」
    restartGrace() {
      graceUntil = clock + GRACE; stalling = false;
      waitSeconds = 0; waitSpeeds = [];
    },
    // 每秒一次，只在用户想看时调用。stalled: 正在等（含起播）；seeking: 这段等待是跳转造成的
    tick(stalled, seeking, loadingBps) {
      clock += 1;
      stalls = stalls.filter(s => s.start + s.seconds >= clock - WINDOW);
      const speed = loadingBps > 0 ? loadingBps : null;
      if (stalled) {
        waitSeconds += 1;
        if (speed != null) waitSpeeds.push(speed);
      } else {
        waitSeconds = 0; waitSpeeds = [];
      }
      if (!stalled || seeking || clock <= graceUntil) { stalling = false; return; }
      if (!stalling) { stalls.push({ start: clock, seconds: 0, speeds: [] }); stalling = true; }
      const cur = stalls[stalls.length - 1];
      cur.seconds += 1;
      if (speed != null) cur.speeds.push(speed);
    },
    // 该不该提议；给出一次后本单元不再给
    offer(streamBitrate, currentHeight) {
      if (offered || !(streamBitrate > 0)) return null;
      let measured;
      if (waitSeconds >= LONG_WAIT) {
        // 一次长等取这段里最快的一秒：冷起播分头取流，逐秒读数时有时无，最快那秒
        // 最接近线路能力，它都跟不上码率才算线路问题
        if (!waitSpeeds.length) return null;
        measured = Math.max(...waitSpeeds);
      } else if (stalls.length >= MIN_STALLS) {
        const speeds = stalls.reduce((a, s) => a.concat(s.speeds), []).sort((a, b) => a - b);
        if (!speeds.length) return null;
        measured = speeds[speeds.length >> 1];
      } else return null;
      if (measured >= streamBitrate * LINK_MARGIN) return null;
      const height = recommendedHeight(measured, currentHeight);
      if (height == null) return null;
      offered = true;
      return { measuredBps: measured, requiredBps: streamBitrate, maxHeight: height };
    },
    reset() { offered = false; },
  };
}

function formatBandwidth(bps) {
  if (!(bps > 0) || !isFinite(bps)) return null;
  const mb = bps / 8 / (1024 * 1024);
  if (mb >= 1) return mb.toFixed(1) + ' MB/s';
  const kb = bps / 8 / 1024;
  return kb < 1 ? '0 KB/s' : Math.round(kb) + ' KB/s';
}

// source.resolution 形如 "3840x1632" / "1080p" → 画面高度
function heightOfResolution(r) {
  if (!r) return null;
  const wh = String(r).match(/(\d{3,5})\s*[x×*]\s*(\d{3,5})/i);
  if (wh) return Number(wh[2]);
  const p = String(r).match(/(\d{3,5})\s*[pP]/);
  return p ? Number(p[1]) : null;
}

const Player = {
  video: null,
  hls: null,
  currentTitle: '',
  hideTimer: null,
  isSeeking: false,
  // 拖动跟随（同 macOS scrubFollow）：上次跟随时刻 + 排到一半的跟随任务 + 手指在进度条上的位置
  _lastScrubFollowAt: 0,
  _scrubFollowTask: null,
  _scrubPct: null,
  // 进度上报 & 会话保活
  sessionId: null,
  mediaItemId: null,
  seasonNumber: null,
  episodeNumber: null,
  // 上一集 / 下一集：同季剧集表（详情页 loadBrowse 那一份，只含已入库集）
  episodes: [],
  // 右侧时间显剩余还是总长（点它切换，同 QuickTime）
  showsTotal: false,
  progressTimer: null,
  pingTimer: null,
  lastProgressReport: 0,
  context: null,
  originMs: 0,
  durationMs: 0,
  activeEngine: null,
  generation: 0,
  _reportedStart: false,
  _ended: false,
  _closePromise: null,
  _reportQueue: [],
  _reportRunning: false,
  mpvTracks: { audio: [], subtitles: [] },
  subtitleFontScale: 1,
  fullscreenFit: 'contain',
  // JASSUB 字幕渲染
  jassub: null,
  jassubTracks: [],

  init() {
    this.video = document.getElementById('playerVideo');
    if (!this.video) return;
    this.fullscreenFit = localStorage.getItem('mc_fullscreenFit') === 'cover' ? 'cover' : 'contain';
    this.initSettings();
    this.initInfoPanel();

    // 播放/暂停
    document.getElementById('btnPlayPause')?.addEventListener('click', () => this.togglePlay());
    document.getElementById('playerCenterBtn')?.addEventListener('click', () => this.togglePlay());
    this.video.addEventListener('click', () => { this.showControls(); this.autoHideControls(); });
    document.querySelector('.player-video-wrap')?.addEventListener('dblclick', () => this.toggleFullscreen());
    window.__TAURI__?.event?.listen('movieclaw:player-input', event => {
      const input = event.payload;
      if (!this.isMpv() || input.instanceId !== this.mpvInstanceId) return;
      this.handleNativeInput(input.args?.slice(1) || []);
    }).then(unlisten => { this._nativeInputUnlisten = unlisten; }).catch(() => {});
    const cueStyle = document.createElement('style');
    cueStyle.textContent = '#playerVideo::cue { font-size: var(--mc-sub-size, 24px); }';
    document.head?.appendChild(cueStyle);

    // 进度条：按下/拖动走 scrubFollow 让画面跟手，松手精确跳到落点
    // （同 macOS MacScrubber 的 DragGesture：onChanged → scrubFollow，onEnded → seek）
    const seek = document.getElementById('playerSeek');
    if (seek) {
      const pctAt = (clientX) => {
        const rect = seek.getBoundingClientRect();
        return Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
      };
      seek.addEventListener('mousedown', (e) => {
        if (!this.engDuration()) return;
        this.isSeeking = true;
        this._scrubPct = pctAt(e.clientX);
        this.renderScrub();
        this.scrubFollow(this._scrubPct * this.engDuration());
        const onMove = (e2) => {
          if (!this.engDuration()) return;
          this._scrubPct = pctAt(e2.clientX);
          this.renderScrub();
          this.scrubFollow(this._scrubPct * this.engDuration());
        };
        const onUp = (e3) => {
          this.isSeeking = false;
          document.removeEventListener('mousemove', onMove);
          document.removeEventListener('mouseup', onUp);
          // 排到一半的跟随别再落地，松手那一次就到点了
          if (this._scrubFollowTask) { clearTimeout(this._scrubFollowTask); this._scrubFollowTask = null; }
          const pct = pctAt(e3.clientX);
          this._scrubPct = null;
          // 松手这一次才算真 seek（跟随不计入 seek 次数）：精确落地 + 作废掉帧/卡顿窗口
          if (this.engDuration()) this.engSeekTo(pct * this.engDuration());
        };
        document.addEventListener('mousemove', onMove);
        document.addEventListener('mouseup', onUp);
      });

      // Trickplay: 悬停显示缩略图预览
      let trickplayPreview = null;
      seek.addEventListener('mousemove', (e) => {
        if (!this.engDuration()) return;
        const rect = seek.getBoundingClientRect();
        const pct = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
        const hoverTime = pct * this.engDuration();

        if (!trickplayPreview) {
          trickplayPreview = document.createElement('div');
          trickplayPreview.className = 'trickplay-preview';
          seek.parentElement.appendChild(trickplayPreview);
        }
        const timeStr = this.formatTime(hoverTime);
        this.renderTrickplayPreview(trickplayPreview, Math.floor(hoverTime * 1000), timeStr);
        trickplayPreview.hidden = false;
        trickplayPreview.style.display = 'block';
        trickplayPreview.style.left = (pct * 100) + '%';
      });

      seek.addEventListener('mouseleave', () => {
        if (trickplayPreview) { trickplayPreview.hidden = true; trickplayPreview.style.display = 'none'; }
      });
    }

    // 快进快退
    document.getElementById('btnRew')?.addEventListener('click', () => this.engSeekBy(-10));
    document.getElementById('btnFwd')?.addEventListener('click', () => this.engSeekBy(10));

    // 上一集 / 下一集
    document.getElementById('btnPrevEp')?.addEventListener('click', () => this.playEpisode(this.prevEpisode()));
    document.getElementById('btnNextEp')?.addEventListener('click', () => this.playEpisode(this.nextEpisode()));

    // 右侧时间：剩余 ↔ 总长（同 QuickTime / macOS mac-player-remaining）
    document.getElementById('playerRemaining')?.addEventListener('click', () => {
      this.showsTotal = !this.showsTotal;
      this.updateProgress();
    });

    // 音量
    document.getElementById('btnMute')?.addEventListener('click', () => this.toggleMute());
    const volSlider = document.getElementById('volumeSlider');
    if (volSlider) {
      volSlider.addEventListener('input', () => {
        this.engSetVolume(parseFloat(volSlider.value));
      });
    }
    this.video.addEventListener('volumechange', () => {
      if (this.activeEngine === 'html5') this.updateVolumeIcon();
    });

    // 全屏
    document.getElementById('btnFullscreen')?.addEventListener('click', () => this.toggleFullscreen());
    document.getElementById('btnPip')?.addEventListener('click', () => this.togglePip());

    // 返回
    document.getElementById('playerBack')?.addEventListener('click', () => this.close());

    // 视频事件
    this.video.addEventListener('timeupdate', () => {
      if (this.activeEngine !== 'html5') return;
      this.updateProgress();
      this.checkSegments();
    });
    this.video.addEventListener('loadedmetadata', () => {
      if (this.activeEngine !== 'html5') return;
      this.renderChapters(this.sessionData?.chapters);
      // 片长在这里才定下来，下行两端要立刻跟上；只等 timeupdate 的话，起播慢时
      // 右侧会一直挂着占位（mpv 那条链靠轮询的首个 tick 补上，HTML5 得在这补）
      this.updateProgress();
    });
    this.video.addEventListener('progress', () => this.updateBuffer());
    this.video.addEventListener('play', () => {
      if (this.activeEngine !== 'html5') return;
      this.showIcon('pause');
      this.hideCenterBtn();
      this.autoHideControls();
    });
    this.video.addEventListener('pause', () => {
      if (this.activeEngine !== 'html5') return;
      this.autoHideControls();
      this._buffering = false;
      this.showIcon('play');
      this.showCenterBtn();
      this.showControls();
    });
    this.video.addEventListener('ended', () => {
      if (this.activeEngine !== 'html5') return;
      this.showIcon('play');
      this.showCenterBtn();
      this.showControls();
      this.reportPlaybackEnd();
    });
    this.video.addEventListener('waiting', () => {
      if (this.activeEngine !== 'html5') return;
      this._buffering = true;
      const loading = document.getElementById('playerLoading');
      if (loading) loading.hidden = false;
    });
    this.video.addEventListener('playing', () => {
      if (this.activeEngine !== 'html5') return;
      this._everPlayed = true;
      this._buffering = false;
      const loading = document.getElementById('playerLoading');
      if (loading) loading.hidden = true;
      this.measure('playing');
      if (!this._reportedStart && !this._frameRequestId && this.video.requestVideoFrameCallback) {
        const generation = this.generation;
        this._frameRequestId = this.video.requestVideoFrameCallback(() => {
          this._frameRequestId = null;
          if (generation === this.generation && this.activeEngine === 'html5') this.startProgressReporting();
        });
      } else if (!this.video.requestVideoFrameCallback) this.startProgressReporting();
    });
    this.video.addEventListener('error', () => {
      if (this.activeEngine !== 'html5') return;
      const text = document.getElementById('playerLoadingText');
      const loading = document.getElementById('playerLoading');
      // 首帧前解不了（浏览器不认该格式/编码）→ 走 failed_tiers 降档回路换转码
      if (typeof App !== 'undefined' && App.onPlaybackContentFailed) {
        App.onPlaybackContentFailed('无法解码该视频格式');
        return;
      }
      if (text) text.textContent = '播放失败: 无法解码该视频格式';
      if (loading) loading.hidden = false;
    });

    // 鼠标移动显示控制栏
    const view = document.getElementById('playerView');
    view?.addEventListener('mousemove', () => {
      this.showControls();
      this.autoHideControls();
    });

    // 键盘快捷键（对齐 macOS MacPlayerScreen.handleKey：⌘ 在 Windows 取 Ctrl）
    document.addEventListener('keydown', (e) => {
      if (document.getElementById('playerView')?.hidden) return;
      if (e.target?.matches?.('input:not([type="range"]),textarea,select,[contenteditable="true"]')) return;
      // 长按连发：跳转/音量要跟手，换集/开关只认第一次按下（同 macOS phase .down 而非 .repeat）
      const once = !e.repeat;
      const mod = e.ctrlKey || e.metaKey;
      switch (e.key) {
        case ' ': case 'k': e.preventDefault(); if (once) this.togglePlay(); break;
        case 'ArrowLeft':
          e.preventDefault();
          if (mod) { if (once) this.playEpisode(this.prevEpisode()); }
          else this.engSeekBy(e.shiftKey ? -1 : -10);
          break;
        case 'ArrowRight':
          e.preventDefault();
          if (mod) { if (once) this.playEpisode(this.nextEpisode()); }
          else this.engSeekBy(e.shiftKey ? 1 : 10);
          break;
        case 'ArrowUp': e.preventDefault(); this.engSetVolume(this.engVolume() + 0.1); break;
        case 'ArrowDown': e.preventDefault(); this.engSetVolume(this.engVolume() - 0.1); break;
        case 'm': if (once) this.toggleMute(); break;
        case 'f': if (once) this.toggleFullscreen(); break;
        case 'i': case 'I': if (once) this.toggleInfoPanel(); break;
        case 'Home': e.preventDefault(); if (once) this.engSeekTo(0); break;
        case 'PageUp': e.preventDefault(); if (once) this.seekChapter(-1); break;
        case 'PageDown': e.preventDefault(); if (once) this.seekChapter(1); break;
        case '[': if (once) this.setSpeed(Math.max(0.5, this.engRate() - 0.25)); break;
        case ']': if (once) this.setSpeed(Math.min(2, this.engRate() + 0.25)); break;
        case 's': if (once) this.cycleSubtitle(); break;
        case '.': if (mod && once) { e.preventDefault(); this.close(); } break;
        case 'Enter':
          // 对话框的主按钮（同 SwiftUI .defaultAction）。焦点在框内按钮上时交给按钮自己触发
          if (!once || !this._dialog) break;
          if (e.target && e.target.closest && e.target.closest('#playerDialog button')) break;
          e.preventDefault();
          if (this._dialog.primary) this._dialog.primary();
          break;
        case 'Escape':
          if (!once) break;
          // 对话框在时 Esc 认次按钮（同 SwiftUI .cancelAction），不落到下面的 Esc 阶梯上
          if (this._dialog) {
            e.preventDefault();
            if (this._dialog.secondary) this._dialog.secondary();
            break;
          }
          // Esc 阶梯（同 macOS escape()）：收起面板 → 退出全屏 → 关闭播放器
          if (this.closeAnyPanel()) { e.preventDefault(); break; }
          if (this.nativePip) { e.preventDefault(); this.togglePip(); break; }
          if (this.isFullscreen()) { e.preventDefault(); this.toggleFullscreen(); break; }
          this.close();
          break;
      }
    });

    // mpv 画面是主窗口的子窗口，缩放/全屏后要手动对齐到视频区域
    window.addEventListener('resize', () => this.syncEmbeddedPlayerRect());
    document.addEventListener('fullscreenchange', () => {
      this.applyFullscreenFit();
      // 布局要等全屏切换落定才量得准
      requestAnimationFrame(() => this.syncEmbeddedPlayerRect());
    });
  },

  // ===== 设置面板 =====
  sessionData: null,   // 播放会话完整数据

  initSettings() {
    // 设置按钮
    document.getElementById('btnSettings')?.addEventListener('click', (e) => {
      e.stopPropagation();
      this.toggleSettings();
    });

    // 倍速按钮
    document.getElementById('btnSpeed')?.addEventListener('click', (e) => {
      e.stopPropagation();
      this.toggleSpeedPanel();
    });

    // 设置标签页切换
    document.querySelectorAll('.player-settings-tab').forEach(tab => {
      tab.addEventListener('click', () => {
        document.querySelectorAll('.player-settings-tab').forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        this.renderSettingsTab(tab.dataset.tab);
      });
    });

    // 倍速选项
    document.querySelectorAll('.player-speed-option').forEach(opt => {
      opt.addEventListener('click', () => {
        const speed = parseFloat(opt.dataset.speed);
        this.setSpeed(speed);
      });
    });

    // 点击外部关闭面板
    document.getElementById('playerView')?.addEventListener('click', (e) => {
      const path = e.composedPath?.() || [e.target];
      const inside = selector => path.some(node => node.matches?.(selector));
      if (!inside('.player-settings-panel') && !inside('#btnSettings')) {
        this.hideSettings();
      }
      if (!inside('.player-speed-panel') && !inside('#btnSpeed')) {
        this.hideSpeedPanel();
      }
    });

    // 跳过按钮
    document.getElementById('playerSkipBtn')?.addEventListener('click', () => this.skipSegment());
  },

  toggleSettings() {
    const panel = document.getElementById('playerSettingsPanel');
    if (panel.hidden) {
      panel.hidden = false;
      this.hideSpeedPanel();
      // 音轨只在两条以上才有这一栏（没得选的菜单是纯噪音，同 macOS MacTracksPanel）
      const audioTab = document.querySelector('.player-settings-tab[data-tab="audio"]');
      if (audioTab) audioTab.hidden = this.audioTracks().length === 0;
      this.renderSettingsTab('subtitles');
      // 更新激活的标签页
      document.querySelectorAll('.player-settings-tab').forEach(t => t.classList.remove('active'));
      document.querySelector('.player-settings-tab[data-tab="subtitles"]')?.classList.add('active');
    } else {
      panel.hidden = true;
    }
  },

  hideSettings() {
    const panel = document.getElementById('playerSettingsPanel');
    if (panel) panel.hidden = true;
  },

  toggleSpeedPanel() {
    const panel = document.getElementById('playerSpeedPanel');
    if (panel.hidden) {
      panel.hidden = false;
      this.hideSettings();
    } else {
      panel.hidden = true;
    }
  },

  hideSpeedPanel() {
    const panel = document.getElementById('playerSpeedPanel');
    if (panel) panel.hidden = true;
  },

  // Esc 阶梯的第一级：有面板开着就收掉一个，返回是否处理过
  closeAnyPanel() {
    const friends = document.getElementById('playerFriendsPanel');
    if (friends && !friends.hidden) { window.DesktopFriends?.close(); return true; }
    for (const [id, hide] of [
      ['playerInfoPanel', () => this.hideInfoPanel()],
      ['playerSettingsPanel', () => this.hideSettings()],
      ['playerSpeedPanel', () => this.hideSpeedPanel()],
    ]) {
      const panel = document.getElementById(id);
      if (panel && !panel.hidden) { hide(); return true; }
    }
    return false;
  },

  // ===== 实时速度徽标 + 播放诊断面板（右键打开）=====
  // 口径对齐 web 端（lib/player/bandwidth.ts 的 LoadingMeter 与
  // components/player/diagnostics-panel.tsx 的「源 → 处理」层次）

  initInfoPanel() {
    // 播放区域内右键 = 诊断面板；拦截掉 WebView 默认菜单
    document.getElementById('playerView')?.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      this.toggleInfoPanel();
    });
    document.getElementById('playerInfoClose')?.addEventListener('click', (e) => {
      e.stopPropagation();
      this.hideInfoPanel();
    });
    document.getElementById('playerSpeedBadge')?.addEventListener('click', (e) => {
      e.stopPropagation();
      this.toggleInfoPanel();
    });
    document.getElementById('btnPlayerInfo')?.addEventListener('click', () => this.toggleInfoPanel());
  },

  toggleInfoPanel() {
    const panel = document.getElementById('playerInfoPanel');
    if (!panel) return;
    if (panel.hidden) {
      panel.hidden = false;
      document.getElementById('btnPlayerInfo')?.setAttribute('aria-expanded', 'true');
      this._renderInfoPanel();
      clearInterval(this._infoTimer);
      this._infoTimer = setInterval(() => this._renderInfoPanel(), 500);
    } else {
      this.hideInfoPanel();
    }
  },

  hideInfoPanel() {
    const panel = document.getElementById('playerInfoPanel');
    if (panel) panel.hidden = true;
    document.getElementById('btnPlayerInfo')?.setAttribute('aria-expanded', 'false');
    clearInterval(this._infoTimer);
    this._infoTimer = null;
  },

  // 分片字节：速度徽标与面板的数据源。ProxyHlsLoader 一次性交付整片，字节在
  // FRAG_LOADED 一步到位；每片另记「实收字节/耗时」作为带宽峰值样本
  attachNetHooks(hls) {
    hls.on(Hls.Events.FRAG_LOADED, (_, data) => {
      const n = this._net;
      const st = data && data.frag && data.frag.stats;
      if (!n || !st || !st.loaded) return;
      if (!st._metered) n.bytes += st.loaded;
      const dur = st.loading && st.loading.end > st.loading.start ? st.loading.end - st.loading.start : 0;
      if (dur > 0) {
        n.frags.push({ at: performance.now(), bps: (st.loaded * 8 * 1000) / dur });
        if (n.frags.length > 60) n.frags.splice(0, n.frags.length - 60);
      }
    });
  },

  startNetMeter() {
    this.stopNetMeter();
    const badge = document.getElementById('playerSpeedBadge');
    if (badge) { badge.hidden = false; badge.textContent = '↓ —'; }
    this._netTimer = setInterval(() => this._tickNetMeter(), 500);
  },

  stopNetMeter() {
    clearInterval(this._netTimer);
    this._netTimer = null;
    const badge = document.getElementById('playerSpeedBadge');
    if (badge) badge.hidden = true;
  },

  _tickNetMeter() {
    const n = this._net;
    if (!n) return;
    const now = performance.now();
    if (this.isMpv()) {
      // mpv fetches the source itself; WebView/HLS byte counters do not measure it.
      const speed = this.mpvState?.properties?.['cache-speed'];
      n.bps = typeof speed === 'number' && Number.isFinite(speed) && speed >= 0 ? speed * 8 : null;
      if (n.bps != null) {
        n.frags.push({ at: now, bps: n.bps });
        n.frags = n.frags.filter(sample => now - sample.at < 30000).slice(-60);
      }
      const badge = document.getElementById('playerSpeedBadge');
      if (badge) { badge.hidden = false; badge.textContent = '↓ ' + (this.formatNetSpeed(n.bps) || '—'); }
      if (!document.getElementById('playerInfoPanel')?.hidden) this._renderInfoPanel();
      return;
    }
    n.points.push({ at: now, bytes: n.bytes });
    // 窗口起点：至少早 1.75s（2s 窗口留 250ms 给计时器抖动）的最后一个点；
    // 起播不满窗口时用最早的点，但至少隔 900ms——sampleLoadingMeter 同款逻辑，
    // 计数倒退（换了取流对象）时从头量，不许出现负速度
    const last = n.points[n.points.length - 2];
    if (last && n.bytes < last.bytes) n.points = [{ at: now, bytes: n.bytes }];
    const cutoff = now - 1750;
    let ref = -1;
    for (let i = n.points.length - 1; i >= 0; i--) {
      if (n.points[i].at <= cutoff) { ref = i; break; }
    }
    if (ref < 0 && now - n.points[0].at >= 900) ref = 0;
    if (ref >= 0) {
      const base = n.points[ref];
      const dt = now - base.at;
      n.bps = dt > 0 ? ((n.bytes - base.bytes) * 8 * 1000) / dt : null;
      n.points = n.points.slice(ref);
    }
    const badge = document.getElementById('playerSpeedBadge');
    if (badge) {
      badge.hidden = false;
      badge.textContent = '↓ ' + (this.formatNetSpeed(n.bps) || '—');
    }
    if (!document.getElementById('playerInfoPanel')?.hidden) this._renderInfoPanel();
  },

  // bps → 「3.2 MB/s」：1024 进位，MB/s 而非 Mbps（用户对网速的直觉来自下载条，
  // 换 Mbps 会让人以为快了八倍）——同 web bandwidth.ts formatBandwidth
  formatNetSpeed(bps) {
    if (bps == null || !isFinite(bps) || bps < 0) return null;
    const bytesPerSec = bps / 8;
    const mb = bytesPerSec / (1024 * 1024);
    if (mb >= 1) return mb.toFixed(1) + ' MB/s';
    const kb = bytesPerSec / 1024;
    if (kb < 1) return '0 KB/s';
    return Math.round(kb) + ' KB/s';
  },

  _renderInfoPanel() {
    const body = document.getElementById('playerInfoBody');
    if (!body) return;
    const s = this.sessionData || {};
    const d = s.decision || {};
    const src = s.source || {};
    const v = this.isMpv() ? null : this.video;
    const native = this.mpvState?.properties || {};
    const n = this._net || {};
    const mbps = (bps) => (bps ? (bps / 1e6).toFixed(bps >= 1e7 ? 0 : 1) + ' Mbps' : null);
    const TIER = { 0: '原文件直出', 1: '换壳直通', 2: '换壳 + 转音轨', 3: '硬件转码', 4: '软件转码' };
    const HW = { videotoolbox: 'VideoToolbox', vaapi: 'VAAPI', qsv: 'Intel QSV', nvenc: 'NVENC' };
    const READY = ['无媒体', '元数据', '可播放', '可播放且有数据', '可持续播放'];
    const NETST = ['空闲', '加载中', '已加载', '无资源'];
    const sec = (title, lines) => `<div class="player-info-sec"><div class="sec-title">${title}</div>${lines.filter(Boolean).join('')}</div>`;
    const srcLine = (t) => (t ? `<div class="src">${playerText(t)}</div>` : '');
    const actLine = (t, alert) => (t ? `<div class="act${alert ? ' alert' : ''}">${playerText(t)}</div>` : '');

    // —— 流媒体：源容器 → 处理方式 ——
    const container = (src.container || d.container || '未知').toUpperCase();
    const streamTarget = d.tier === 0 ? '原文件直出' : `HLS · fMP4（${TIER[d.tier] ?? '未知档位'}）`;

    // —— 视频：源规格 → 这次怎么处理的 ——
    const fps = src.frame_rate ? `${Number(src.frame_rate.toFixed(3))} fps` : null;
    const videoSrc = [src.resolution, src.video_codec && src.video_codec.toUpperCase(), src.hdr, fps].filter(Boolean).join(' · ');
    let videoAction = null;
    if (d.video) {
      videoAction = d.video.action === 'copy' ? '直通'
        : `转码（${(d.video.codec || 'h264').toUpperCase()}${d.video.height ? ` ${d.video.height}p` : ''} · ${s.hw_backend ? (HW[s.hw_backend] || s.hw_backend) : '软件'}${d.video.tone_map ? ' · HDR 转 SDR' : ''}${d.video.bitrate_cap_bps ? ` · 按线路限 ${mbps(d.video.bitrate_cap_bps)}` : ''}）`;
    }
    // 实测行：输出分辨率 + 掉帧（掉帧率 >2% 标红：能解但解不动，该降档了）
    let perfLine = null;
    let dropAlert = false;
    if (v && v.videoWidth) {
      const bits = [`输出 ${v.videoWidth}×${v.videoHeight}`];
      try {
        const q = v.getVideoPlaybackQuality && v.getVideoPlaybackQuality();
        if (q) {
          // 标准属性名是 droppedVideoFrames（droppedFrames 不存在，会渲染成 undefined）
          bits.push(`掉帧 ${q.droppedVideoFrames ?? 0} / ${q.totalVideoFrames ?? 0}`);
          dropAlert = (q.totalVideoFrames ?? 0) > 0 && (q.droppedVideoFrames ?? 0) / q.totalVideoFrames > 0.02;
        }
      } catch (_) { /* 环境无 playback quality API 时只报分辨率 */ }
      perfLine = bits.join(' · ');
    }

    if (this.isMpv()) {
      const out = native['video-out-params'] || {};
      const hw = native['hwdec-current'] || 'no';
      perfLine = [out.w && out.h ? `输出 ${out.w}×${out.h}` : null,
        `实际解码 ${hw === 'no' ? '软件' : hw}`, `掉帧 ${(Number(native['frame-drop-count']) || 0) + (Number(native['decoder-frame-drop-count']) || 0)}`,
        this.context?.__hardwareDecode !== false && hw === 'no' ? '硬解未启用或已回退' : null,
        `渲染目标 ${[native['video-target-params']?.primaries, native['video-target-params']?.gamma].filter(Boolean).join(' / ') || '未知'}`,
        this.sessionData?.source?.hdr && native['video-target-params']?.gamma && !['pq', 'hlg'].includes(native['video-target-params'].gamma) ? 'HDR 转 SDR' : null,
        '显示器最终输出需实测'].filter(Boolean).join(' · ');
      dropAlert = this.context?.__hardwareDecode !== false && hw === 'no';
    }

    // —— 音频：这次放的那条轨 → 处理 ——
    const activeTrack = (d.audio_tracks || []).find((t) => t.ref === (this.currentAudioRef || d.audio?.track_ref));
    const audioSrc = activeTrack
      ? [activeTrack.language, activeTrack.codec && activeTrack.codec.toUpperCase(), activeTrack.channels ? `${activeTrack.channels} 声道` : null]
          .filter(Boolean).join(' ') + (activeTrack.is_default ? '（默认）' : '')
      : null;
    let audioAction = null;
    if (d.audio) {
      audioAction = d.audio.action === 'copy' ? '直通'
        : `转码（${(d.audio.codec || 'aac').toUpperCase()}${d.audio.channels ? ` ${d.audio.channels} 声道` : ''}${d.audio.downmix ? ' · 已降混' : ''}）`;
    }

    // —— 传输：此刻的实测读数 ——
    const trans = [];
    let peak = null;
    if (n.frags && n.frags.length) {
      const recent = n.frags.filter((f) => performance.now() - f.at < 30000);
      if (recent.length) peak = Math.max(...recent.map((f) => f.bps));
    }
    trans.push(['↓ ' + (this.formatNetSpeed(n.bps) || '—'), peak ? `带宽峰值 ${this.formatNetSpeed(peak)}` : null].filter(Boolean).join(' · '));
    let ahead = 0;
    if (v) {
      for (let i = 0; i < v.buffered.length; i++) {
        if (v.currentTime >= v.buffered.start(i) - 0.15 && v.currentTime <= v.buffered.end(i)) {
          ahead = v.buffered.end(i) - v.currentTime;
          break;
        }
      }
      trans.push(`缓冲 ${ahead.toFixed(1)} 秒 · 播放头 ${v.currentTime.toFixed(1)} 秒${isFinite(v.duration) && v.duration > 0 ? ` / ${v.duration.toFixed(0)} 秒` : ''}`);
    }
    const hls = this.hls;
    if (hls && hls.levels && hls.currentLevel >= 0 && hls.levels[hls.currentLevel]) {
      const lv = hls.levels[hls.currentLevel];
      // 服务端 fMP4 playlist 不带 RESOLUTION/BANDWIDTH（实测 attrs 为空）：有元数据才报，
      // 单档又没元数据时整行省略——分辨率在「输出」行、处理方式在视频节已经摆了
      const bits = [lv.height ? `${lv.height}p` : null, lv.bitrate ? mbps(lv.bitrate) : null].filter(Boolean);
      if (bits.length || hls.levels.length > 1) {
        trans.push(`档位 ${[...bits, hls.levels.length > 1 ? `${hls.levels.length} 档可选` : null].filter(Boolean).join(' · ')}`);
      }
      if (lv.details) trans.push(`播放列表 ${lv.details.live ? '直播流（边播边给）' : '点播（VOD）'}`);
    }
    if (this.isMpv()) {
      trans.push(`缓冲 ${(Number(native['demuxer-cache-duration']) || 0).toFixed(1)} 秒 · 播放头 ${this.engPos().toFixed(1)} 秒${this.engDuration() > 0 ? ` / ${this.engDuration().toFixed(0)} 秒` : ''}`);
      trans.push(`IPC ${native.ipc_connected ? '已连接' : '连接中'} · ${this.engPaused() ? '已暂停' : this._buffering ? '缓冲中' : '播放中'}`);
    }
    if (v) trans.push(`${READY[v.readyState] ?? `readyState ${v.readyState}`} · ${NETST[v.networkState] ?? `networkState ${v.networkState}`} · ${v.paused ? '已暂停' : v.seeking ? '定位中' : '播放中'}`);
    trans.push(`会话 ${s.session_id || '无（直出）'}`);

    body.innerHTML = [
      sec('流媒体', [srcLine([container, mbps(src.bit_rate)].filter(Boolean).join(' · ')), actLine(streamTarget),
        d.degraded_from != null ? actLine('上一档播放失败，自动降档而来', true) : '']),
      sec('视频', [srcLine(videoSrc), actLine(videoAction), perfLine ? `<div class="act${dropAlert ? ' alert' : ''}">${playerText(perfLine)}</div>` : '']),
      sec('音频', [srcLine(audioSrc), actLine(audioAction)]),
      sec('传输', trans.map((t) => `<div>${playerText(t)}</div>`)),
    ].join('');

    const reasonEl = document.getElementById('playerInfoReason');
    if (reasonEl) reasonEl.textContent = d.reason || '';
  },

  // ===== 轨道清单与分组（同 macOS PlayerTracks.swift / MacPlayerPanels.swift）=====

  // 语言代码 → 中文名（同 Web lib/language-labels.ts）；und/空没有名字，由调用方兜底
  _langLabel(code) {
    if (!code || code === 'und') return null;
    const names = {
      chs: '简体中文', cht: '繁体中文', chi: '中文', zho: '中文', cmn: '中文',
      yue: '粤语', eng: '英语', jpn: '日语', kor: '韩语', fre: '法语', fra: '法语',
      ger: '德语', deu: '德语', spa: '西班牙语', rus: '俄语', ita: '意大利语',
      por: '葡萄牙语', tha: '泰语', hin: '印地语',
    };
    return names[String(code).toLowerCase()] || code;
  },

  // 轨道标签拆成主标题 + 一行小字（标签是「语言 · 编码 · 声道」）。同 macOS MacTrackText.split
  trackTextSplit(label) {
    const parts = String(label == null ? '' : label).split(' · ');
    const rest = parts.slice(1).join(' · ');
    return { title: parts[0] || label, detail: rest || null };
  },

  // 语言标记 → 分组（各种写法：zh / chi / zho / chs / cht / zh-Hans / cmn / yue……）
  subtitleLangKind(language) {
    const code = String(language == null ? '' : language).toLowerCase();
    if (!code) return 'other';
    if (code.startsWith('zh') || ['chi', 'zho', 'chs', 'cht', 'cmn', 'yue', 'chinese'].includes(code)) return 'chinese';
    if (code.startsWith('en') || code === 'english') return 'english';
    return 'other';
  },

  // 字幕按语言分组：中文 → 英语 → 其他语言，空组不出现。纯函数，同 macOS MacSubtitleGroups.build
  subtitleGroups(options) {
    const buckets = { chinese: [], english: [], other: [] };
    for (const o of options) buckets[this.subtitleLangKind(o.language)].push(o);
    return [
      { id: 'zh', title: '中文', options: buckets.chinese },
      { id: 'en', title: '英语', options: buckets.english },
      { id: 'other', title: '其他语言', options: buckets.other },
    ].filter((g) => g.options.length > 0);
  },

  _embeddedIndex(ref) {
    const n = ref && String(ref).startsWith('embedded:') ? parseInt(String(ref).slice(9), 10) : null;
    return Number.isInteger(n) ? n : null;
  },

  _refLabel(ref) {
    if (ref && String(ref).startsWith('external:')) return String(ref).slice(9);
    const n = this._embeddedIndex(ref);
    return n == null ? '未知语言' : '内封轨 ' + (n + 1);
  },

  subtitleTrackLabel(plan) {
    const title = String(plan.title == null ? '' : plan.title).trim();
    const name = title || this._langLabel(plan.language) || this._refLabel(plan.track_ref);
    return name + ' · ' + ({ vtt: '文本', ass: '特效', pgs: '图形' }[plan.kind] || plan.kind);
  },

  subtitleDisplayTitle(plan) {
    const title = String(plan.title == null ? '' : plan.title).trim();
    if (title) return title;
    const n = this._embeddedIndex(plan.track_ref);
    if (n != null) return '内封轨 ' + (n + 1);
    if (String(plan.track_ref || '').startsWith('external:')) return String(plan.track_ref).slice(9);
    return this.subtitleTrackLabel(plan);
  },

  subtitleDetail(plan) {
    const formats = { vtt: 'WebVTT', ass: 'ASS', pgs: 'PGS 图形', text: '文本' };
    const parts = [this._langLabel(plan.language) || '未知语言', formats[plan.kind] || plan.kind];
    const n = this._embeddedIndex(plan.track_ref);
    const displayTitle = this.subtitleDisplayTitle(plan);
    if (n != null) parts.push(displayTitle === '内封轨 ' + (n + 1) ? '内封' : '内封轨 ' + (n + 1));
    else if (String(plan.track_ref || '').startsWith('external:')) parts.push('外挂');
    if (plan.is_ai) parts.push('AI 翻译');
    if (plan.is_default) parts.push('默认');
    if (plan.is_forced) parts.push('强制');
    return parts.join(' · ');
  },

  // 决策里的字幕计划配上取流地址（与 subtitle_urls 一一对应，少一个就当那条没有地址）；
  // 拿不到的轨置灰给原因，不给一个点了没反应的选项。同 macOS SubtitleTracks.plan。
  // index 是 decision.subtitles 里的原位：selectSubtitle 与 <track> 都按这个下标走
  buildSubtitleTracks() {
    const plans = (this.sessionData && this.sessionData.decision && this.sessionData.decision.subtitles) || [];
    const urls = this.sessionData?.subtitle_urls || [];
    const options = [], unavailable = [];
    plans.forEach((p, index) => {
      const label = this.subtitleTrackLabel(p);
      const native = this.isMpv() && this.mpvTracks.subtitles.find(t => t.ref === p.track_ref);
      if (index >= urls.length && !native) {
        unavailable.push({ index, ref: p.track_ref, label, reason: '服务端没有给出这条轨的地址' });
        return;
      }
      if (!['vtt', 'ass', 'pgs'].includes(p.kind) && !native) {
        unavailable.push({ index, ref: p.track_ref, label, reason: '暂不支持的字幕格式：' + p.kind });
        return;
      }
      options.push({
        index, ref: p.track_ref, kind: p.kind, language: p.language || null,
        displayTitle: this.subtitleDisplayTitle(p), detail: this.subtitleDetail(p),
      });
    });
    const sourceCodecs = this.sessionData?.source?.subtitle_codecs || [];
    if (sourceCodecs.some(codec => ['dvd_subtitle', 'vobsub'].includes(String(codec).toLowerCase()))) {
      unavailable.push({ index: null, ref: null, label: 'DVD 位图字幕', reason: '此播放路径暂不支持 DVD 位图字幕，可使用外挂文本字幕' });
    }
    return { options, unavailable };
  },

  // 可选音轨（同 macOS AudioOption.plan）：只有一条时返回空——没得选的菜单是纯噪音
  audioTracks() {
    const tracks = (this.sessionData && this.sessionData.decision && this.sessionData.decision.audio_tracks) || [];
    if (tracks.length < 2) return [];
    const unrec = (c) => { const s = String(c == null ? '' : c).toLowerCase(); return !s || s === 'none' || s === 'unknown'; };
    const anyRecognized = tracks.some((t) => !unrec(t.codec));
    return tracks.map((t) => ({
      ref: t.ref,
      language: t.language,
      label: this.audioLabel(t),
      is_default: !!t.is_default,
      unavailableReason: this.isMpv() && this.playsOriginalFile && this._nativeTrackInit && !this.mpvTracks.audio.some(native => native.ref === t.ref) ? '播放器没有载入这条音轨' : anyRecognized && unrec(t.codec)
        ? '音频编码无法识别（常见于菁彩声 Audio Vivid），没有可用的解码器' : null,
    }));
  },

  audioLabel(t) {
    const name = this._langLabel(t.language)
      || (String(t.ref || '').startsWith('embedded:') ? '音轨 ' + String(t.ref).slice(9) : '未知音轨');
    const rest = [];
    if (t.codec) rest.push(String(t.codec).toUpperCase());
    if (t.channels > 0) rest.push({ 1: '单声道', 2: '立体声', 6: '5.1', 8: '7.1' }[t.channels] || (t.channels + ' 声道'));
    return rest.length ? [name].concat(rest).join(' · ') : name;
  },

  renderSettingsTab(tabName) {
    this._settingsTab = tabName;
    const content = document.getElementById('playerSettingsContent');
    if (!content) return;

    const session = this.sessionData;
    const decision = session?.decision || {};
    const check = '<svg class="item-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="9 12 11 14 15 10"/></svg>';

    if (tabName === 'subtitles') {
      // 关闭 → 中文 → 英语 → 其他语言 → 暂时放不了（同 macOS MacTracksPanel.subtitleRows）
      const { options, unavailable } = this.buildSubtitleTracks();
      const currentOffset = this.subtitleOffset || 0;
      const sel = this.selectedSubtitle;
      let html = `
        <div class="player-settings-item ${sel === null ? 'active' : ''}" data-sub-index="-1" data-player-action="subtitle">
          <span class="item-label">关闭字幕</span>
          ${check}
        </div>
      `;
      for (const g of this.subtitleGroups(options)) {
        html += `<div class="player-settings-group">${g.title}</div>`;
        html += g.options.map((o) => `
          <div class="player-settings-item stacked ${sel === o.index ? 'active' : ''}" data-sub-index="${o.index}" data-player-action="subtitle">
            <div class="item-text">
              <span class="item-label">${playerText(o.displayTitle)}</span>
              <span class="item-info">${playerText(o.detail)}</span>
            </div>
            ${check}
          </div>
        `).join('');
      }
      if (unavailable.length) {
        html += '<div class="player-settings-group">暂时放不了</div>';
        html += unavailable.map((u) => `
          <div class="player-settings-item stacked disabled" data-sub-index="${u.index}">
            <div class="item-text">
              <span class="item-label">${playerText(u.label)}</span>
              <span class="item-info">${playerText(u.reason)}</span>
            </div>
            ${check}
          </div>
        `).join('');
      }
      if (!options.length && !unavailable.length) {
        html += '<div style="padding:20px;text-align:center;color:rgba(255,255,255,0.4);font-size:13px">无可用字幕</div>';
      }
      // 字幕延迟调整
      html += `
        <div class="player-settings-item" style="cursor:default">
          <span class="item-label">字幕延迟</span>
          <div class="subtitle-offset-controls">
            <button class="offset-btn" ${decision.video?.burn_subtitle ? 'disabled' : ''} data-player-action="offset" data-offset="-0.5">-0.5s</button>
            <span class="offset-value" id="subOffsetValue">${currentOffset > 0 ? '+' : ''}${currentOffset.toFixed(1)}s</span>
            <button class="offset-btn" ${decision.video?.burn_subtitle ? 'disabled' : ''} data-player-action="offset" data-offset="0.5">+0.5s</button>
          </div>
        </div>
      `;
      html += `<div class="player-settings-item"><span class="item-label">字幕大小</span><div class="subtitle-offset-controls">
        <button class="offset-btn" ${decision.video?.burn_subtitle ? 'disabled' : ''} data-player-action="scale" data-scale="-0.1">−</button>
        <span>${Math.round(this.subtitleFontScale * 100)}%</span>
        <button class="offset-btn" ${decision.video?.burn_subtitle ? 'disabled' : ''} data-player-action="scale" data-scale="0.1">+</button></div></div>`;
      if (decision.video?.burn_subtitle) html += '<div class="player-settings-group">字幕已压制进画面；大小与延迟不可在播放端调整。</div>';
      content.innerHTML = html;
    }

    else if (tabName === 'audio') {
      const tracks = this.audioTracks();
      const currentRef = this.currentAudioRef ?? decision.audio?.track_ref ?? null;
      let html = tracks.map(t => {
        const parts = this.trackTextSplit(t.label);
        const detail = [parts.detail, t.is_default ? '默认' : null, t.unavailableReason].filter(Boolean).join(' · ');
        const active = t.ref === currentRef || (currentRef == null && t.is_default);
        return `
          <div class="player-settings-item stacked ${active ? 'active' : ''}${t.unavailableReason ? ' disabled' : ''}"${t.unavailableReason ? '' : ` data-player-action="audio" data-audio-ref="${playerText(t.ref)}"`}>
            <div class="item-text">
              <span class="item-label">${playerText(parts.title)}</span>
              ${detail ? `<span class="item-info">${playerText(detail)}</span>` : ''}
            </div>
            ${check}
          </div>
        `;
      }).join('');
      if (!tracks.length) html = '<div style="padding:20px;text-align:center;color:rgba(255,255,255,0.4);font-size:13px">无可用音轨</div>';
      content.innerHTML = html;
    }

    else if (tabName === 'quality') {
      const source = session?.source || {};
      const video = decision.video || {};
      const tier = decision.tier;
      const currentQuality = this.currentQuality || 0; // 0=原画
      const html = `
        <div class="player-settings-item ${currentQuality === 0 ? 'active' : ''}" data-player-action="quality" data-quality="0">
          <span class="item-label">原画</span>
          <span class="item-info">不压缩</span>
          <svg class="item-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="9 12 11 14 15 10"/></svg>
        </div>
        <div class="player-settings-item ${currentQuality === 1080 ? 'active' : ''}" data-player-action="quality" data-quality="1080">
          <span class="item-label">1080p</span>
          <span class="item-info">~6 Mbps</span>
          <svg class="item-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="9 12 11 14 15 10"/></svg>
        </div>
        <div class="player-settings-item ${currentQuality === 720 ? 'active' : ''}" data-player-action="quality" data-quality="720">
          <span class="item-label">720p</span>
          <span class="item-info">~3 Mbps</span>
          <svg class="item-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="9 12 11 14 15 10"/></svg>
        </div>
        <div class="player-settings-item ${currentQuality === 480 ? 'active' : ''}" data-player-action="quality" data-quality="480">
          <span class="item-label">480p</span>
          <span class="item-info">~1.5 Mbps</span>
          <svg class="item-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="9 12 11 14 15 10"/></svg>
        </div>
        <div style="padding:12px 16px;border-top:1px solid rgba(255,255,255,0.06)">
          <div style="font-size:11px;color:rgba(255,255,255,0.35);margin-bottom:8px">当前画质信息</div>
          ${source.resolution ? `<div style="font-size:12px;color:rgba(255,255,255,0.6);margin-bottom:4px">源：${playerText(source.resolution)} · ${playerText(source.video_codec || '')} · ${playerText(source.hdr || '')}</div>` : ''}
          ${video.height ? `<div style="font-size:12px;color:rgba(255,255,255,0.6);margin-bottom:4px">输出：${playerText(video.height)}p${video.action === 'copy' ? ' (直通)' : ' (转码)'}</div>` : ''}
          ${tier != null ? `<div style="font-size:12px;color:rgba(255,255,255,0.6)">档位：${playerText(tier)}</div>` : ''}
          ${source.bit_rate ? `<div style="font-size:12px;color:rgba(255,255,255,0.6);margin-top:4px">码率：${(source.bit_rate / 1000000).toFixed(1)} Mbps</div>` : ''}
        </div>
      `;
      content.innerHTML = html;
    }

    else if (tabName === 'speed') {
      const speeds = [0.5, 0.75, 1, 1.25, 1.5, 2];
      const current = this.engRate();
      content.innerHTML = speeds.map(s => `
        <div class="player-settings-item ${s === current ? 'active' : ''}" data-player-action="speed" data-speed="${s}">
          <span class="item-label">${s}x${s === 1 ? ' (正常)' : ''}</span>
          <svg class="item-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="9 12 11 14 15 10"/></svg>
        </div>
      `).join('');
    }
    else if (tabName === 'frame') {
      content.innerHTML = `<div class="player-settings-group">全屏画幅</div>` + [
        ['contain', '保持原比例', '完整显示画面，可能保留黑边'],
        ['cover', '填满屏幕', '等比例放大，裁掉边缘；仅在全屏时生效'],
      ].map(([mode, label, detail]) => `<button type="button" class="player-settings-item stacked ${this.fullscreenFit === mode ? 'active' : ''}" data-player-action="frame" data-fit="${mode}" aria-pressed="${this.fullscreenFit === mode}">
        <span class="item-text"><span class="item-label">${label}</span><span class="item-info">${detail}</span></span>${check}</button>`).join('');
    }
    // Server metadata is text/data only. Do not embed track refs in executable attributes.
    for (const row of content.querySelectorAll('[data-player-action]')) {
      row.addEventListener('click', () => {
        if (row.disabled || row.classList.contains('disabled')) return;
        const data = row.dataset;
        if (data.playerAction === 'audio') this.selectAudio(data.audioRef);
        else if (data.playerAction === 'subtitle') this.selectSubtitle(Number(data.subIndex));
        else if (data.playerAction === 'offset') this.adjustSubtitleOffset(Number(data.offset));
        else if (data.playerAction === 'scale') this.adjustSubtitleScale(Number(data.scale));
        else if (data.playerAction === 'quality') this.selectQuality(Number(data.quality));
        else if (data.playerAction === 'speed') this.setSpeed(Number(data.speed));
        else if (data.playerAction === 'frame') this.setFullscreenFit(data.fit);
      });
    }
  },

  async selectSubtitle(index, { remember = true } = {}) {
    const plans = this.sessionData?.decision?.subtitles || [];
    const plan = index >= 0 ? plans[index] : null;
    if (index >= 0 && !plan) return false;
    const selection = this._subtitleSelectionSeq = (this._subtitleSelectionSeq || 0) + 1;
    const ref = plan?.track_ref || 'off';
    const generation = this.generation;
    if (this.isMpv()) {
      const track = plan ? this.mpvTracks.subtitles.find(t => t.ref === ref) : null;
      if (plan && !track) { this.controlError('这条字幕尚未被播放器载入'); return false; }
      const result = await this.mpvCmd(['set_property', 'sid', track?.id ?? 'no']);
      if (generation !== this.generation || selection !== this._subtitleSelectionSeq) return false;
      if (!result) { this.controlError('字幕切换失败，请重试'); return false; }
      if (this.mpvState) this.mpvState.sid = track?.id ?? 'no';
      await this.mpvCmd(['set_property', 'sub-delay', this.subtitleOffset - (track?.external ? this.originMs / 1000 : 0)]);
      if (generation !== this.generation) return false;
    } else {
      const burned = this.sessionData?.decision?.video?.burn_subtitle;
      if ((plan?.kind === 'pgs' && burned !== ref) || burned && burned !== ref) {
        this.context.subtitle_track = ref;
        if (remember) this.context.__subtitleTouched = true;
        return App.restartPlaybackAt(Math.floor(this.engPos() * 1000));
      }
      for (const track of this.video?.textTracks || []) track.mode = 'disabled';
      this.jassub?.freeTrack?.();
      if (plan?.kind === 'ass') {
        await this.initJassub(this.sessionData?.subtitle_urls, this.sessionData, index, selection);
        if (generation !== this.generation || selection !== this._subtitleSelectionSeq) return false;
        if (!this.jassub) { this.controlError('ASS 字幕渲染器未能启动'); return false; }
      } else if (plan?.kind === 'vtt') {
        const track = this._subtitleElements?.get(ref)?.track || this.video?.textTracks[index];
        if (track) { this.applyCueStyle(track); track.mode = 'showing'; }
      }
    }
    this.selectedSubtitle = plan ? index : null;
    if (this.context) {
      this.context.subtitle_track = ref;
      if (remember) this.context.__subtitleTouched = true;
    }
    this.measure('subtitle-change', { selected: ref });
    this.renderSettingsTab('subtitles');
    if (remember && this._reportedStart) this.sendSnapshot('progress', this.snapshot()).catch(() => {});
    return true;
  },

  subtitleOffset: 0,
  selectedSubtitle: undefined,

  async adjustSubtitleOffset(delta) {
    if (this.sessionData?.decision?.video?.burn_subtitle) return;
    const value = Math.max(-30, Math.min(30, this.subtitleOffset + delta));
    const generation = this.generation;
    if (this.isMpv()) {
      // External subtitle files keep file timestamps; native embedded tracks use stream time.
      const plan = this.sessionData?.decision?.subtitles?.[this.selectedSubtitle];
      const external = this.mpvTracks.subtitles.find(t => t.ref === plan?.track_ref)?.external;
      const result = await this.mpvCmd(['set_property', 'sub-delay', value - (external ? this.originMs / 1000 : 0)]);
      if (!result || generation !== this.generation) return;
    }
    this.subtitleOffset = value;
    if (this.context) this.context.subtitleOffset = value;
    for (const track of this.video?.textTracks || []) this.applyCueStyle(track);
    if (this.jassub) this.jassub.timeOffset = this.originMs / 1000 - value;
    this.renderSettingsTab('subtitles');
  },

  async adjustSubtitleScale(delta) {
    if (this.sessionData?.decision?.video?.burn_subtitle) return;
    const value = Math.max(0.5, Math.min(2, this.subtitleFontScale + delta));
    const generation = this.generation;
    if (this.isMpv() && !await this.mpvCmd(['set_property', 'sub-scale', value])) return;
    if (generation !== this.generation) return;
    this.subtitleFontScale = value;
    if (this.context) this.context.subtitleFontScale = value;
    this.applySubtitleStyle();
    this.renderSettingsTab('subtitles');
  },

  applyCueStyle(track) {
    if (!track?.cues) return;
    this._cueOriginal ||= new WeakMap();
    const offset = this.subtitleOffset - this.originMs / 1000;
    for (const cue of track.cues) {
      if (!this._cueOriginal.has(cue)) this._cueOriginal.set(cue, { start: cue.startTime, end: cue.endTime, line: cue.line });
      const original = this._cueOriginal.get(cue);
      cue.startTime = original.start + offset;
      cue.endTime = original.end + offset;
      if (original.line === 'auto' || original.line == null) { cue.snapToLines = false; cue.line = this.controlsVisible ? 78 : 92; }
    }
  },

  applySubtitleStyle() {
    if (this.video?.style?.setProperty) this.video.style.setProperty('--mc-sub-size', (24 * this.subtitleFontScale) + 'px');
    for (const track of this.video?.textTracks || []) this.applyCueStyle(track);
    if (this.jassub?.getStyles) {
      const renderer = this.jassub;
      renderer.getStyles((error, styles) => {
        if (error || renderer !== this.jassub) return;
        this._assOriginal ||= new Map();
        styles.forEach((style, index) => {
          if (!this._assOriginal.has(index)) this._assOriginal.set(index, { size: style.FontSize, margin: style.MarginV });
          const original = this._assOriginal.get(index);
          renderer.setStyle({ ...style, FontSize: original.size * this.subtitleFontScale,
            MarginV: Math.max(original.margin || 0, this.controlsVisible ? 90 : 20) }, index);
        });
      });
    }
    if (this.isMpv()) {
      const signature = [this.generation, this.controlsVisible, this.subtitleFontScale].join(':');
      if (signature === this._nativeSubtitleStyle) return;
      this._nativeSubtitleStyle = signature;
      this.mpvCmd(['set_property', 'sub-pos', this.controlsVisible ? 82 : 95]);
      this.mpvCmd(['set_property', 'sub-scale', this.subtitleFontScale]);
    }
  },

  async selectAudio(ref, { remember = true } = {}) {
    if (!this.context || !this.audioTracks().some(t => t.ref === ref && !t.unavailableReason)) return false;
    const generation = this.generation;
    if (this.isMpv() && this.playsOriginalFile) {
      const track = this.mpvTracks.audio.find(t => t.ref === ref);
      if (!track || !await this.mpvCmd(['set_property', 'aid', track.id])) { this.controlError('音轨切换失败，请重试'); return false; }
      if (generation !== this.generation) return false;
      this.mpvState.aid = track.id;
      this.currentAudioRef = ref;
      this.context.audio_track = ref;
      if (remember) this.context.__audioTouched = true;
      if (remember && this._reportedStart) this.sendSnapshot('progress', this.snapshot()).catch(() => {});
      this.renderSettingsTab('audio');
      this.measure('audio-change', { selected: ref });
      return true;
    }
    // A remux/transcode stream has only its negotiated source audio. IDs in its
    // HLS rendition list are not the source's embedded:N references.
    return App.restartPlaybackAt(Math.floor(this.engPos() * 1000), { audio_track: ref, __audioTouched: remember || this.context.__audioTouched });
  },

  engRate() { return this.isMpv() ? (this.mpvState?.speed ?? this.context?.playbackRate ?? 1) : (this.video?.playbackRate || 1); },

  async setSpeed(rate) {
    if (!(rate >= 0.5 && rate <= 2)) return;
    const generation = this.generation;
    if (this.isMpv()) {
      if (!await this.mpvCmd(['set_property', 'speed', rate]) || generation !== this.generation) return;
      if (this.mpvState) this.mpvState.speed = rate;
    } else if (this.video) this.video.playbackRate = rate;
    if (this.context) this.context.playbackRate = rate;
    const label = document.getElementById('speedLabel');
    if (label) label.textContent = rate + 'x';
    document.querySelectorAll('.player-speed-option').forEach(o => o.classList.toggle('active', parseFloat(o.dataset.speed) === rate));
    this.hideSettings();
    this.hideSpeedPanel();
  },

  controlError(message) {
    const content = document.getElementById('playerSettingsContent');
    if (!content) return;
    const notice = document.createElement('div');
    notice.className = 'player-dialog-error';
    notice.textContent = message;
    content.appendChild(notice);
  },

  cycleSubtitle() {
    const options = this.buildSubtitleTracks().options;
    const next = options.findIndex(o => o.index === this.selectedSubtitle) + 1;
    this.selectSubtitle(next < options.length ? options[next].index : -1);
  },

  currentQuality: 0, // 0=原画, 否则 maxHeight

  async selectQuality(maxHeight) {
    this.hideSettings();
    if (!this.context || typeof App === 'undefined') return;
    rememberQuality(this.mediaItemId, maxHeight);
    this.measure('quality_switch');
    return App.startPlayback({ ...this.context, startMs: Math.floor(this.engPos() * 1000),
      __maxHeight: maxHeight, __resetFailures: true }, true);
  },

  // 两个引擎共用的播放上下文；所有外部时间均为文件时间，只有引擎边界换算。
  adoptSession(title, session, context, engine) {
    window.DesktopFriends?.refreshButton();
    this.generation += 1;
    this.context = { ...(context || {}), title };
    if (this.context.file_id == null && session.decision?.file_id != null) this.context.file_id = session.decision.file_id;
    this.sessionData = session;
    this.sessionId = session.session_id || null;
    this.mediaItemId = session.media_item_id ?? this.context.media_item_id;
    this.seasonNumber = session.season_number ?? this.context.seasonNumber ?? 0;
    this.episodeNumber = session.episode_number ?? this.context.episodeNumber ?? 0;
    this.originMs = session.session_id && session.timeline === 'session' ? (session.start_ms ?? 0) : 0;
    const file = (this.context.files || []).find(f => Number(f.id) === Number(session.decision?.file_id));
    this.durationMs = [session.source?.duration_ms, session.watch?.duration_ms,
      file?.duration_seconds != null ? file.duration_seconds * 1000 : null, this.context.durationMs]
      .map(Number).find(ms => Number.isFinite(ms) && ms > 0) || 0;
    this.currentTitle = title || 'MovieClaw';
    this.currentQuality = this.context.__maxHeight ?? 0;
    this.episodes = Array.isArray(this.context.episodes) ? this.context.episodes : [];
    this.activeEngine = engine;
    if (!this._qoe || this._qoe.attempt_id !== this.context.attemptId) this.beginAttempt(this.context);
    this._openedAt = this._qoe.at;
    this._nativeSubtitleStyle = null;
    this._measuredBuffering = null;
    this._qoe.tier = session.decision?.tier ?? -1;
    this._qoe.engine = engine;
    this._qoe.library_file_id = session.decision?.file_id ?? null;
    this._qoe.hw_backend = session.hw_backend || '';
    this._seekMeasurement = null;
    this._nativeTrackInit = false;
    this.mpvTracks = { audio: [], subtitles: [] };
    this.selectedSubtitle = null;
    this.currentAudioRef = session.decision?.audio?.track_ref || null;
    this.subtitleOffset = this.context.subtitleOffset || 0;
    this.subtitleFontScale = this.context.subtitleFontScale || 1;
    this._subtitleElements = new Map();
    this._cueOriginal = new WeakMap();
    this._assOriginal = null;
    this._trickplayAbort?.abort();
    this._trickplayAbort = new AbortController();
    this.trickplayIndex = null;
    this._spriteImages = new Map();
    this._outroOffered = false;
    this.showControls();
    const pip = document.getElementById('btnPip');
    if (pip) { pip.hidden = engine !== 'mpv' && !document.pictureInPictureEnabled; pip.title = '画中画'; pip.setAttribute('aria-pressed', 'false'); }
    this._reportedStart = false;
    this._ended = false;
    this._everPlayed = false;
    this._buffering = true;
    this.lastProgressReport = 0;
    this._reportIdentity = { server: API.baseUrl, account: App.session?.username || '', epoch: API.contextEpoch };
    this.initSegments(session.segments);
    this.syncEpisodeNav();
    this.startSessionPing();
    this.loadTrickplayIndex();
    clearInterval(this._mediaLeaseTimer);
    const generation = this.generation;
    this._mediaLeaseTimer = setInterval(() => {
      if (generation !== this.generation) return;
      for (const streamId of this._mediaGrants || []) window.__TAURI__?.core?.invoke('renew_media_stream', { streamId }).catch(() => {});
    }, 60000);
  },

  snapshot() {
    return {
      mediaItemId: this.mediaItemId, libraryId: this.context?.library_id,
      seasonNumber: this.seasonNumber, episodeNumber: this.episodeNumber,
      sessionId: this.sessionId, positionMs: Math.floor(this.engPos() * 1000),
      durationMs: Math.floor(this.engDuration() * 1000), started: this._reportedStart,
      extras: { paused: this.engPaused(), file_id: this.sessionData?.decision?.file_id,
        ...(this.context?.__audioTouched ? { audio_track: this.currentAudioRef } : {}),
        ...(this.context?.__subtitleTouched ? { subtitle_track: this.context.subtitle_track || 'off' } : {}) },
      identity: this._reportIdentity,
    };
  },

  sendSnapshot(event, snapshot) {
    if (!snapshot.mediaItemId) return Promise.resolve();
    const queue = this._reportQueue;
    // 断网时只留每个单元最近一次的周期进度；开始和结束仍按顺序发送。
    const matching = event === 'progress' ? queue.find(job => job.event === 'progress' &&
      job.snapshot.mediaItemId === snapshot.mediaItemId && job.snapshot.seasonNumber === snapshot.seasonNumber &&
      job.snapshot.episodeNumber === snapshot.episodeNumber && job.snapshot.identity === snapshot.identity) : null;
    if (matching) { matching.snapshot = snapshot; return matching.promise; }
    if (queue.length + (this._reportRunning ? 1 : 0) >= 8) {
      if (event === 'progress') return Promise.resolve(false);
      const index = queue.findIndex(job => job.event === 'progress');
      const discarded = queue.splice(index >= 0 ? index : 0, 1)[0];
      discarded?.reject(new Error('进度队列已满，旧上报已丢弃'));
    }
    const job = { event, snapshot };
    job.promise = new Promise((resolve, reject) => { job.resolve = resolve; job.reject = reject; });
    queue.push(job);
    this.drainReports();
    return job.promise;
  },

  async drainReports() {
    if (this._reportRunning) return;
    this._reportRunning = true;
    try {
      while (this._reportQueue.length) {
        const job = this._reportQueue.shift();
        try {
          for (let attempt = 0; ; attempt++) {
            const s = job.snapshot;
            const identity = s.identity;
            if (identity && (identity.server !== API.baseUrl || identity.account !== (App.session?.username || '') ||
              identity.epoch !== API.contextEpoch)) throw new Error('播放上下文已更换，取消旧进度上报');
            try {
              await API.reportProgress(s.mediaItemId, job.event, s.positionMs, s.durationMs,
                s.seasonNumber, s.episodeNumber, s.extras, { timeoutMs: 3000, cancelable: true });
              break;
            } catch (error) {
              const retryable = error.name !== 'AbortError' && (!error.status || error.status >= 500);
              if (!retryable || attempt >= 2) throw error;
              await new Promise(resolve => setTimeout(resolve, 200 * (attempt + 1)));
            }
          }
          job.resolve(true);
        } catch (error) { job.reject(error); }
      }
    } finally { this._reportRunning = false; }
  },

  // ===== 跳过片头/片尾 =====
  currentSegments: [],
  currentSkipIndex: -1,

  initSegments(segments) {
    this.currentSegments = segments || [];
    this.currentSkipIndex = -1;
    const btn = document.getElementById('playerSkipBtn');
    if (btn) btn.hidden = true;
  },

  checkSegments() {
    if (!this.activeEngine) return;
    const curMs = this.engPos() * 1000;
    const btn = document.getElementById('playerSkipBtn');
    const index = this.currentSegments.findIndex(seg => !(seg.type === 'outro' && seg.to_end) &&
      curMs >= seg.start_ms && curMs < seg.end_ms - 3000);
    this.currentSkipIndex = index;
    if (btn) {
      btn.hidden = index < 0;
      if (index >= 0) btn.textContent = ({ intro: '跳过片头', outro: '跳过片尾', ad: '跳过广告',
        preview: '跳过预告', other: '跳过此段' })[this.currentSegments[index].type] || '跳过此段';
    }
    if (!this._outroOffered && this.currentSegments.some(seg => seg.type === 'outro' && seg.to_end && curMs >= seg.start_ms)) {
      this._outroOffered = true;
      App.onPlaybackEnded();
    }
  },

  skipSegment() {
    const seg = this.currentSegments[this.currentSkipIndex];
    if (seg && this.activeEngine && !(seg.type === 'outro' && seg.to_end)) this.engSeekTo(seg.end_ms / 1000);
    const btn = document.getElementById('playerSkipBtn');
    if (btn) btn.hidden = true;
    this.currentSkipIndex = -1;
  },

  chapterList() {
    if (this.sessionData?.chapters?.length) return this.sessionData.chapters;
    return (this.mpvState?.properties?.['chapter-list'] || []).map(ch => ({
      start_ms: this.originMs + (Number(ch.time) || 0) * 1000, title: ch.title || '',
    }));
  },

  seekChapter(direction) {
    const chapters = this.chapterList().slice().sort((a, b) => a.start_ms - b.start_ms);
    const now = this.engPos() * 1000;
    const chapter = direction > 0 ? chapters.find(ch => ch.start_ms > now + 1000)
      : chapters.reverse().find(ch => ch.start_ms < now - 3000);
    if (chapter) this.engSeekTo(chapter.start_ms / 1000);
  },

  // ===== 章节标记 =====
  renderChapters(chapters) {
    const seek = document.getElementById('playerSeek');
    if (!seek) return;
    // 清除旧的章节标记
    seek.querySelectorAll('.player-chapter-mark').forEach(el => el.remove());
    const dur = this.engDuration();
    if (!dur || !chapters?.length) return;
    chapters.forEach(ch => {
      const pct = (ch.start_ms / 1000 / dur) * 100;
      if (pct < 0 || pct > 100) return;
      const mark = document.createElement('div');
      mark.className = 'player-chapter-mark';
      mark.style.left = pct + '%';
      mark.title = ch.title || '';
      seek.appendChild(mark);
    });
  },

  // ---- 上一集 / 下一集 ----
  // 同 macOS PlaybackController.nextEpisode/previousEpisode：只在**本季已入库**的
  // 集里找，缺集跳过。服务端的 PlaybackSessionView 不带 next_episode 字段（旧代码读
  // 它，按钮永远不亮），所以这份兄弟表由详情页 loadBrowse 那一份随起播传进来
  prevEpisode() {
    if (this.seasonNumber == null || this.episodeNumber == null) return null;
    return this.episodes
      .filter((e) => e && e.owned && e.episode_number < this.episodeNumber)
      .sort((a, b) => b.episode_number - a.episode_number)[0] || null;
  },

  nextEpisode() {
    if (this.seasonNumber == null || this.episodeNumber == null) return null;
    return this.episodes
      .filter((e) => e && e.owned && e.episode_number > this.episodeNumber)
      .sort((a, b) => a.episode_number - b.episode_number)[0] || null;
  },

  // 换集：关掉当前这一集，按同一部剧的下一单元重开。episodes 随身带走——
  // 降档/重连回路也会重新进 startPlayback，兄弟表不能在那几条路上丢
  playEpisode(ep) {
    if (!ep || typeof App === 'undefined') return;
    const mediaId = this.sessionData?.media_item_id ?? this.mediaItemId;
    if (!mediaId) return;
    const seriesTitle = String(this.currentTitle || '').replace(/\s+S\d+E\d+$/i, '');
    const season = this.seasonNumber;
    const title = season == null
      ? ep.name || seriesTitle
      : `${seriesTitle} S${season}E${ep.episode_number}`;
    const context = { ...this.context };
    delete context.attemptId;
    delete context.file_id;
    App.startPlayback({
      ...context,
      media_item_id: mediaId,
      __autoNext: false,
      title,
      library_id: context.library_id,
      seasonNumber: season,
      episodeNumber: ep.episode_number,
      episodes: this.episodes,
      startMs: null,
    });
  },

  // 剧集才出上下集按钮；到头的那一侧禁用（不隐藏，免得控制条宽度跳）
  syncEpisodeNav() {
    const isEpisode = this.seasonNumber != null && this.episodeNumber != null
      && !(Number(this.seasonNumber) === 0 && Number(this.episodeNumber) === 0);
    for (const [id, ep] of [['btnPrevEp', this.prevEpisode()], ['btnNextEp', this.nextEpisode()]]) {
      const btn = document.getElementById(id);
      if (!btn) continue;
      btn.hidden = !isEpisode;
      btn.disabled = !ep;
    }
  },

  // 打开播放器并加载流
  open(title, streamUrl, subtitles, startMs, sessionData, context) {
    const view = document.getElementById('playerView');
    const titleEl = document.getElementById('playerTitle');
    const loading = document.getElementById('playerLoading');
    const loadingText = document.getElementById('playerLoadingText');

    this.currentTitle = title || 'MovieClaw';
    if (titleEl) titleEl.textContent = this.currentTitle;
    if (loading) loading.hidden = false;
    if (loadingText) loadingText.textContent = '正在加载...';

    view.hidden = false;
    this.adoptSession(title, sessionData || {}, context, 'html5');
    const generation = this.generation;
    const alive = () => generation === this.generation && this.activeEngine === 'html5';

    // 初始化片段/章节
    this.initSegments(sessionData?.segments);
    // 渲染字幕轨信息到 settings（更新可用状态）

    // 清理旧的 HLS 实例
    if (this.hls) { this.hls.destroy(); this.hls = null; }
    clearTimeout(this._stuckTimer);
    this._everPlayed = false;

    // 复用的 <video> 会把上一次的播放位置当成「默认起播位置」带进新源
    // （readyState=0 时 currentTime 读到的就是它，removeAttribute/load 也清不掉），
    // 「从头播放」(startMs=0/null) 必须在这里显式归位，否则从旧位置接着放
    if (this.video) this.video.currentTime = (startMs || 0) / 1000;

    // 实时速度：累计字节 + 2 秒滑动窗口（口径对齐 web bandwidth.ts 的 LoadingMeter）
    this._net = { bytes: 0, points: [], bps: null, frags: [] };
    this.hideInfoPanel();
    this.stopNetMeter(); // 原生直链没有分片钩子，徽标保持隐藏，由 hls 分支的 startNetMeter 点亮
    this.startWatchdogs();

    const isHls = streamUrl.includes('.m3u8') || streamUrl.includes('/hls');

    if (isHls && window.Hls && Hls.isSupported()) {
      this.hls = new Hls({
        // 对齐 web 引擎（apps/web/lib/player/engine.ts）的起播配置
        maxBufferLength: 60,
        maxMaxBufferLength: 60,
        // 必须显式给起播位置，不能留默认(-1)：EVENT playlist（转码/重封装会话）
        // 没有 ENDLIST，hls.js 当直播从「直播边缘」起播——续播时服务端已 burst
        // 出几十秒就会从错误位置开播。会话相对制传 0（续播由服务端 -ss 决定，
        // 流头即续播点）；非会话流传文件内续播秒数。
        startPosition: startMs ? startMs / 1000 : 0,
        // 分片超时要盖过服务端 ensure_segment 按需等待（最长 30s）：默认 20s
        // TTFB 会在服务端即将给出分片前掐掉重发，慢转码场景反复空转
        fragLoadPolicy: {
          default: {
            maxTimeToFirstByteMs: 45000,
            maxLoadTimeMs: 120000,
            timeoutRetry: { maxNumRetry: 4, retryDelayMs: 0, maxRetryDelayMs: 0 },
            errorRetry: { maxNumRetry: 6, retryDelayMs: 1000, maxRetryDelayMs: 8000 },
          },
        },
        loader: window.__TAURI__ ? ProxyHlsLoader : undefined,
      });
      this.hls.loadSource(streamUrl);
      this.hls.attachMedia(this.video);
      this.attachNetHooks(this.hls);
      this.startNetMeter();
      this.hls.on(Hls.Events.MANIFEST_PARSED, () => {
        if (!alive()) return;
        if (startMs) this.video.currentTime = startMs / 1000;
        this.video.play().catch(() => {});
      });
      this.hls.on(Hls.Events.ERROR, (_, data) => {
        if (!alive()) return;
        if (data.fatal) {
          const details = String(data.details || '');
          // 首帧前的 buffer* 错误 = 视频初始化数据本身解不了（如直通重封装的
          // hvcC 缺参数集）→ 交给 App 走 failed_tiers 降档回路换转码重来
          if (details.startsWith('buffer') &&
              typeof App !== 'undefined' && App.onPlaybackContentFailed) {
            setTimeout(() => { if (alive()) App.onPlaybackContentFailed(details); }, 0);
            return;
          }
          if (data.type === Hls.ErrorTypes?.NETWORK_ERROR && typeof App !== 'undefined') {
            App.onPlaybackNetworkDead(details || '视频连接中断', { kind: 'network', status: data.response?.code || data.networkDetails?.status });
          } else if (typeof App !== 'undefined') {
            App.onPlaybackContentFailed(details || 'HLS 流加载错误', { kind: 'decode', status: data.response?.code || data.networkDetails?.status });
          }
        }
      });
    } else {
      // MP4 / WebM 等原生格式
      this.mediaCapability(streamUrl, generation).then(url => { if (alive()) this.video.src = url; })
        .catch(error => { if (alive()) App.onPlaybackNetworkDead(error.message || '视频取流失败'); });
      this.video.addEventListener('loadedmetadata', () => {
        if (!alive()) return;
        if (startMs) this.video.currentTime = startMs / 1000;
        this.video.play().catch(() => {});
      }, { once: true });
    }

    // 卡死兜底：服务端转码产出不出数据（如 ffmpeg 中途崩了）时首帧永远不来，
    // 35 秒后明确报错/降档，而不是无限停在「正在加载...」。
    // readyState>=2 = 数据其实到了（如自动播放被浏览器拦下），不算内容失败
    this._stuckTimer = setTimeout(() => {
      if (!alive()) return;
      if (this._everPlayed || (this.video && this.video.readyState >= 2)) return;
      const lt = loadingText ? loadingText.textContent : '';
      if (lt && lt.startsWith('播放失败')) return; // 已有明确错误，不覆盖
      if (typeof App !== 'undefined' && App.onPlaybackContentFailed) {
        App.onPlaybackContentFailed('视频数据加载超时');
      } else if (loadingText) {
        loadingText.textContent = '播放失败: 视频数据加载超时，请稍后重试';
        if (loading) loading.hidden = false;
      }
    }, 35000);

    // VTT uses text tracks; ASS/PGS must never be attached as invalid VTT.
    (sessionData?.decision?.subtitles || []).forEach((plan, i) => {
      if (plan.kind !== 'vtt' || !subtitles?.[i]) return;
      const track = document.createElement('track');
      track.kind = 'subtitles'; track.srclang = plan.language || 'und';
      track.label = plan.title || '字幕 ' + (i + 1);
      this._subtitleElements.set(plan.track_ref, track);
      track.addEventListener('load', () => {
        if (!alive()) return;
        this.applyCueStyle(track.track);
        track.track.mode = this.selectedSubtitle === i ? 'showing' : 'disabled';
      });
      this.video.appendChild(track);
      this.mediaCapability(subtitles[i], generation).then(url => {
        if (alive()) track.src = url;
      }).catch(() => { if (alive()) this.controlError('字幕加载失败，可重新选择字幕轨'); });
    });
    this.initializeTracks().catch(error => { if (alive()) this.controlError(error.message || '字幕初始化失败'); });

    this.showControls();
    this.autoHideControls();
  },

  // 先快照再撤引擎；异步收尾有上限，调用者可等 mpv 停完再装下一部。
  close(options = {}) {
    window.DesktopFriends?.dispose();
    if (options.invalidate !== false && typeof App !== 'undefined') App._playbackSeq = (App._playbackSeq || 0) + 1;
    if (typeof App !== 'undefined') { App.cancelAutoNext(); clearTimeout(App._networkRetryTimer); App._networkRetryTimer = null; }
    const nativeFullscreenRestore = options.hide !== false ? this.restoreNativeFullscreen() : Promise.resolve();
    if (!this.activeEngine && this._closePromise) {
      if (options.hide !== false) {
        const view = document.getElementById('playerView');
        if (view) view.hidden = true;
        this.hidePlayerDialog();
      }
      return boundedPlaybackWait(Promise.allSettled([this._closePromise, nativeFullscreenRestore]), 1200);
    }
    const snapshot = this.snapshot();
    const metrics = options.final !== false ? this.finishAttempt() : Promise.resolve();
    if (this.activeEngine) this.measure('closed');
    const wasMpv = this.isMpv();
    const instanceId = this.mpvInstanceId;
    const started = this._reportedStart;
    const stopReport = started ? this.sendSnapshot('stop', snapshot).then(() => {
      window.dispatchEvent(new CustomEvent('movieclaw:playback-stopped', { detail: snapshot }));
    }).catch(() => {}) : Promise.resolve();
    const sessionStop = snapshot.sessionId ? API.sessionStop(snapshot.sessionId).catch(() => {}) : Promise.resolve();
    this.activeEngine = null;
    this.generation += 1;
    this._reportedStart = false;
    this.sessionId = null;
    this.mediaItemId = null;
    this.sessionData = null;
    this.context = null;
    window.__MOVIECLAW_MPV_ACTIVE = false;
    this.stopMpvPoll();
    this.stopProgressReporting();
    this.stopSessionPing();
    clearTimeout(this._stuckTimer);
    this._trickplayAbort?.abort();
    this._trickplayAbort = null;
    clearInterval(this._mediaLeaseTimer);
    this._mediaLeaseTimer = null;
    this._spriteImages = null;
    this.trickplayIndex = null;
    for (const streamId of this._mediaGrants || []) window.__TAURI__?.core?.invoke('release_media_stream', { streamId }).catch(() => {});
    this._mediaGrants = new Set();
    if (this._scrubFollowTask) clearTimeout(this._scrubFollowTask);
    this._scrubFollowTask = null;
    this._scrubPct = null;
    this.isSeeking = false;
    this.stopNetMeter();
    this.stopWatchdogs();
    this.hideInfoPanel();
    this.hidePlayerDialog();
    this.destroyJassub();
    const view = document.getElementById('playerView');
    if (view && options.hide !== false) view.hidden = true;
    if (this.hls) { this.hls.destroy(); this.hls = null; }
    if (this.video) {
      if (this._frameRequestId) this.video.cancelVideoFrameCallback?.(this._frameRequestId);
      this._frameRequestId = null;
      this.video.style.display = '';
      this.video.pause();
      this.video.removeAttribute('src');
      this.video.innerHTML = '';
      this.video.load();
    }
    if (document.fullscreenElement && options.hide !== false) document.exitFullscreen().catch(() => {});
    clearTimeout(this.hideTimer);
    const nativeStop = wasMpv && window.__TAURI__?.core?.invoke
      ? window.__TAURI__.core.invoke('stop_embedded_player', { instanceId }).catch(() => {}) : Promise.resolve();
    this._nativeStop = nativeStop;
    const task = boundedPlaybackWait(Promise.allSettled([stopReport, sessionStop, nativeStop, metrics, nativeFullscreenRestore]), 1200);
    this._closePromise = task;
    task.finally(() => { if (this._closePromise === task) this._closePromise = null; });
    return task;
  },

  // ===== 播放引擎读写 =====
  // HTML5 会话直接读写 <video>；mpv 会话没有 media element，属性靠 IPC 轮询缓存到
  // this.mpvState，控制命令发出即返回。调用点一律走 eng*，不用关心底下是哪个引擎。
  mpvState: null,
  mpvPollTimer: null,

  isMpv() {
    return !!window.__MOVIECLAW_MPV_ACTIVE;
  },

  // 发一条 mpv JSON IPC 命令。失败只记日志：mpv 退了由 stop 收尾，不该把 UI 打断
  mpvCmd(command) {
    if (!window.__TAURI__?.core?.invoke) return Promise.resolve(null);
    return window.__TAURI__.core.invoke('send_mpv_command_embedded', { command, instanceId: this.mpvInstanceId })
      .catch(e => { console.warn('[mpv]', command && command[0], (e && e.message) || e); return null; });
  },

  engPos() {
    const streamTime = this.isMpv() ? (this.mpvState?.time ?? 0) : (this.video?.currentTime ?? 0);
    return this.originMs / 1000 + (Number.isFinite(streamTime) ? streamTime : 0);
  },

  engDuration() {
    if (this.durationMs > 0) return this.durationMs / 1000;
    // EVENT 会话的 duration 只是目前已产出的尾，不可当成整部片长。
    if (this.usesSessionTimeline) return 0;
    const duration = this.isMpv() ? this.mpvState?.duration : this.video?.duration;
    return Number.isFinite(duration) && duration > 0 ? this.originMs / 1000 + duration : 0;
  },

  engPaused() {
    if (this.isMpv()) return this.mpvState ? this.mpvState.paused : true;
    return !this.video || this.video.paused;
  },

  engVolume() {
    return this.isMpv() ? (this.mpvState ? this.mpvState.volume : 1) : (this.video ? this.video.volume : 1);
  },

  engMuted() {
    return this.isMpv() ? !!(this.mpvState && this.mpvState.muted) : !!this.video?.muted;
  },

  // 统一收口夹取：两个引擎都只认 [0, duration]
  engSeekTo(sec) {
    // 用户 seek 作废掉帧/卡顿窗口（同 macOS seek 时 reset + restartGrace）。
    // 只在用户入口清：StallWatch 的 nudge 自己也 seek，跟着清掉「最多推 2 把」就失效了
    this._stallWatch?.reset();
    this._frameDrops?.reset();
    this._qualitySuggestion?.restartGrace();
    const dur = this.engDuration();
    this.measure('seek_start');
    const target = Math.max(0, dur ? Math.min(Math.max(0, dur - 0.1), sec) : sec);
    if (this.usesSessionTimeline) {
      if (target < this.originMs / 1000 || target > this.engBufferedEndSec()) {
        if (typeof App !== 'undefined') App.restartPlaybackAt(Math.floor(target * 1000));
        return;
      }
    }
    if (this._ended && typeof App !== 'undefined') {
      App.restartPlaybackAt(Math.floor(target * 1000));
      return;
    }
    this._seekMeasurement = { at: performance.now(), target };
    const t = Math.max(0, target - this.originMs / 1000);
    if (this.isMpv()) {
      if (this.mpvState) this.mpvState.time = t;
      this.mpvCmd(['seek', t, 'absolute', 'exact']);
    } else if (this.video) {
      this.video.currentTime = t;
    }
  },

  engSeekBy(delta) {
    this.engSeekTo(this.engPos() + delta);
  },

  // 拖动途中画面跟着手指走的那次跳转：**不**作废掉帧/卡顿窗口（跟随不计入 seek
  // 次数，松手那次才算，同 macOS scrubFollow），mpv 用关键帧 seek——扫动途中要的是快
  engFollowTo(sec) {
    const dur = this.engDuration();
    const target = Math.max(0, dur ? Math.min(dur, sec) : sec);
    if (target < this.originMs / 1000) return;
    const t = Math.max(0, target - this.originMs / 1000);
    if (this.isMpv()) {
      if (this.mpvState) this.mpvState.time = t;
      this.mpvCmd(['seek', t, 'absolute', 'keyframe']);
    } else if (this.video) {
      this.video.currentTime = t;
    }
  },

  // 落点是不是在已缓冲里。缓冲未知按 0 算（macOS bufferedEndMs ?? 0）
  engBufferedEndSec() {
    if (this.isMpv()) {
      const t = this.mpvState ? this.mpvState.time : 0;
      return this.originMs / 1000 + t + (this.mpvState && this.mpvState.bufferedAhead ? this.mpvState.bufferedAhead : 0);
    }
    const v = this.video;
    if (!v || !v.buffered || !v.buffered.length) return 0;
    for (let i = 0; i < v.buffered.length; i++) {
      if (v.buffered.start(i) <= v.currentTime && v.currentTime <= v.buffered.end(i)) return this.originMs / 1000 + v.buffered.end(i);
    }
    return this.originMs / 1000 + v.buffered.end(v.buffered.length - 1);
  },

  // 原文件直出（档 0）= 每次 seek 都是一条新的 Range 请求，扫动途中跟只会一路抽
  // （同 macOS playsOriginalFile，PlaybackController.swift:764）
  get usesSessionTimeline() {
    return !!this.sessionData?.session_id && this.sessionData.timeline === 'session';
  },

  get playsOriginalFile() {
    return this.sessionData?.decision?.tier === 0;
  },

  // 拖动跟随的节奏（同 macOS ScrubFollow.plan，PlaybackWatchdogs.swift:134）：
  // 后沿落地 + 连续扫动 10Hz 兜底。跳转便宜（落点在缓冲里）时途中跟手；
  // 原文件直出拖出缓冲只在手指停住 settleMs 后跟一次；其余情况松手才跳。
  scrubFollowPlan(nowMs, lastFollowMs, cheap, reachable, settleOnly) {
    const settleMs = 60, maxWaitMs = 100;
    if (!reachable) return { kind: 'skip' };
    if (!cheap) return settleOnly ? { kind: 'deferred', ms: settleMs } : { kind: 'skip' };
    const waited = nowMs - lastFollowMs;
    if (waited >= maxWaitMs) return { kind: 'follow' };
    return { kind: 'deferred', ms: Math.max(0, Math.min(settleMs, maxWaitMs - waited)) };
  },

  scrubFollow(targetSec) {
    if (!this.engDuration()) return;
    const plan = this.scrubFollowPlan(
      Date.now(), this._lastScrubFollowAt,
      // cheap：落点在当前位置前 1 秒~已缓冲尾之间（同 macOS）
      targetSec >= this.engPos() - 1 && targetSec <= this.engBufferedEndSec(),
      targetSec >= this.originMs / 1000,
      this.playsOriginalFile,  // settleOnly
    );
    if (this._scrubFollowTask) { clearTimeout(this._scrubFollowTask); this._scrubFollowTask = null; }
    if (plan.kind === 'skip') return;
    if (plan.kind === 'follow') {
      this._lastScrubFollowAt = Date.now();
      this.engFollowTo(targetSec);
      return;
    }
    // 后沿落地：中途再来一次拖动就把这次取消重排，手指停住 plan.ms 后才跟
    this._scrubFollowTask = setTimeout(() => {
      this._scrubFollowTask = null;
      this._lastScrubFollowAt = Date.now();
      this.engFollowTo(targetSec);
    }, plan.ms);
  },

  engSetVolume(v) {
    const vol = Math.max(0, Math.min(1, v));
    if (this.isMpv()) {
      if (this.mpvState) this.mpvState.volume = vol;
      this.mpvCmd(['set_property', 'volume', Math.round(vol * 100)]);
      if (this.engMuted() !== (vol === 0)) this.engSetMuted(vol === 0);
    } else if (this.video) {
      this.video.volume = vol;
      this.video.muted = vol === 0;
    }
    this.updateVolumeIcon();
    this.showControls();
    this.autoHideControls();
  },

  engSetMuted(muted) {
    if (this.isMpv()) {
      if (this.mpvState) this.mpvState.muted = !!muted;
      this.mpvCmd(['set_property', 'mute', !!muted]);
    } else if (this.video) {
      this.video.muted = !!muted;
    }
    this.updateVolumeIcon();
    this.showControls();
    this.autoHideControls();
  },

  // One Rust actor observes properties; JS reads its last complete snapshot.
  startMpvPoll(startMs = 0) {
    this.stopMpvPoll();
    const generation = this.generation;
    const instanceId = this.mpvInstanceId;
    const alive = () => generation === this.generation && this.isMpv() && this.mpvState;
    this.mpvState = { time: (startMs ?? 0) / 1000, duration: 0, paused: true, volume: 1, muted: false, properties: {} };
    this._net = { bytes: 0, points: [], bps: null, frags: [] };
    this._mpvRectSig = null;
    this.mpvRectTimer = setInterval(() => this.syncEmbeddedPlayerRect(), 200);
    let pending = false;
    const tick = async () => {
      if (!alive() || pending) return;
      pending = true;
      try {
        const result = await window.__TAURI__.core.invoke('get_embedded_player_state', { instanceId }).catch(() => null);
        if (!alive() || !result) return;
        const v = result.properties || {}, status = result.status;
        if (v.ipc_error && !this._ended) { App.onPlaybackContentFailed('本机播放器控制连接失败', { kind: 'decode' }); return; }
        this.mpvState.properties = v;
        if (typeof v['time-pos'] === 'number') this.mpvState.time = v['time-pos'];
        if (typeof v.duration === 'number') this.mpvState.duration = v.duration;
        if (typeof v.pause === 'boolean' && v.pause !== this.mpvState.paused) {
          this.mpvState.paused = v.pause;
          if (v.pause) { this.showCenterBtn(); this.showControls(); }
          else this.hideCenterBtn();
          this.autoHideControls();
        }
        if (typeof v.volume === 'number') this.mpvState.volume = v.volume / 100;
        if (typeof v.mute === 'boolean') this.mpvState.muted = v.mute;
        this.updateVolumeIcon();
        if (typeof v.speed === 'number') this.mpvState.speed = v.speed;
        this.mpvState.aid = v.aid; this.mpvState.sid = v.sid;
        this.mpvState.bufferedAhead = Number(v['demuxer-cache-duration']) || 0;
        this._buffering = !!v['paused-for-cache'] || !this._everPlayed;
        if (Array.isArray(v['track-list'])) {
          this.mpvTracks = mpvTrackMap(v['track-list'], this.sessionData?.decision?.subtitles || [],
            this.sessionData?.subtitle_urls || [], this.playsOriginalFile, v['subtitle-source-order'] || []);
          const audio = this.mpvTracks.audio.find(t => t.id === v.aid);
          if (audio?.ref) this.currentAudioRef = audio.ref;
          const sub = this.mpvTracks.subtitles.find(t => t.id === v.sid);
          this.selectedSubtitle = sub ? this.sessionData?.decision?.subtitles?.findIndex(p => p.track_ref === sub.ref) : null;
          if (!this._nativeTrackInit && v['track-list'].length && typeof v['time-pos'] === 'number') {
            this._nativeTrackInit = true;
            await this.initializeTracks();
            if (!alive()) return;
          }
        }
        if (typeof v['time-pos'] === 'number' && v['video-out-params'] && !this._everPlayed) {
          this._everPlayed = true; this._buffering = !!v['paused-for-cache'];
          this.measure('first_frame', { elapsedMs: performance.now() - this._openedAt });
          this.startProgressReporting();
          const loading = document.getElementById('playerLoading');
          if (loading) loading.hidden = true;
        }
        if (this._seekMeasurement && Math.abs(this.engPos() - this._seekMeasurement.target) < 1 && !v.seeking) {
          this.measure('seek_end', { elapsedMs: performance.now() - this._seekMeasurement.at });
          this._seekMeasurement = null;
        }
        this.showIcon(this.mpvState.paused ? 'play' : 'pause');
        this.updateProgress(); this.checkSegments(); this.renderChapters(this.chapterList());
        if (!document.getElementById('playerInfoPanel')?.hidden) this._renderInfoPanel();
        if (document.getElementById('playerSettingsPanel') && !document.getElementById('playerSettingsPanel').hidden) this.renderSettingsTab(this._settingsTab || 'subtitles');
        if (v['eof-reached'] === true || v.end_file?.reason === 'eof' || status?.running === false && this._everPlayed && status.exit_code === 0) {
          this.reportPlaybackEnd();
        } else if ((status?.running === false || v.end_file?.reason === 'error') && !this._ended) {
          App.onPlaybackContentFailed('本机播放器意外退出', { kind: 'decode' });
        }
      } finally { pending = false; }
    };
    tick();
    this.mpvPollTimer = setInterval(tick, 500);
    this.startNetMeter();
    this._stuckTimer = setTimeout(() => {
      if (alive() && !this._everPlayed) App.onPlaybackContentFailed('本机播放器加载超时', { kind: 'decode' });
    }, 35000);
    this.startWatchdogs();
  },

  stopMpvPoll() {
    if (this.mpvPollTimer) { clearInterval(this.mpvPollTimer); this.mpvPollTimer = null; }
    if (this.mpvRectTimer) { clearInterval(this.mpvRectTimer); this.mpvRectTimer = null; }
    this.stopWatchdogs();
    this.mpvState = null;
  },

  // ===== 播放看门狗：1 Hz 采样喂三个 tracker，判定交 App 执行 =====
  startWatchdogs() {
    this.stopWatchdogs();
    this._frameDrops = createFrameDropTracker();
    this._stallWatch = createStallWatch();
    this._qualitySuggestion = createQualitySuggestion();
    this._watchedSeconds = 0;
    this._lastWatchTime = null;
    this._lastNetBytes = null;
    const generation = this.generation;
    let pending = false;
    this._watchdogTick = setInterval(async () => {
      if (pending) return;
      pending = true;
      try { await this._tickWatchdogs(generation); }
      finally { pending = false; }
    }, 1000);
  },

  stopWatchdogs() {
    if (this._watchdogTick) { clearInterval(this._watchdogTick); this._watchdogTick = null; }
    this._frameDrops = this._stallWatch = this._qualitySuggestion = null;
    this.hideQualityOffer();
  },

  // 采一帧当前引擎的真实状态。mpv 那边要走 IPC，所以只在 1 Hz 采（UI 轮询 500ms 不掺这个）
  async _sampleEngine() {
    if (this.isMpv()) {
      if (!this.mpvState) return null;
      const v = this.mpvState.properties || {};
      const time = typeof v['time-pos'] === 'number' ? v['time-pos'] : this.mpvState.time;
      return {
        time: this.originMs / 1000 + time,
        paused: !!v.pause,
        ended: !!v['eof-reached'],
        seeking: !!v.seeking,
        // mpv 的前向缓存秒数；没有 demuxer 属性时按 0 算（缓冲见底）
        bufferedAhead: typeof v['demuxer-cache-duration'] === 'number' ? v['demuxer-cache-duration'] : 0,
        // cache-speed = 正在填的缓存读速；缓存满时为 0，正好符合「只在等待期测速」的口径。
        // mpv 给的是**字节**/秒，这里统一成比特/秒（formatBandwidth 与码率阈值都按 bps 算）
        loadingBps: typeof v['cache-speed'] === 'number' ? v['cache-speed'] * 8 : 0,
        dropped: (Number(v['frame-drop-count']) || 0) + (Number(v['decoder-frame-drop-count']) || 0),
        fps: typeof v['container-fps'] === 'number' ? v['container-fps'] : 0,
        // 没数据要攒 / 还没出过帧 = 正在等（对应 macOS phase == .buffering）
        buffering: !!v['paused-for-cache'] || !this._everPlayed,
      };
    }
    const v = this.video;
    if (!v) return null;
    let bufferedAhead = 0;
    try {
      for (let i = 0; i < v.buffered.length; i++) {
        if (v.buffered.start(i) <= v.currentTime && v.currentTime <= v.buffered.end(i)) {
          bufferedAhead = v.buffered.end(i) - v.currentTime;
          break;
        }
      }
    } catch (_) {}
    let dropped = 0, total = 0;
    try {
      const q = v.getVideoPlaybackQuality && v.getVideoPlaybackQuality();
      if (q) { dropped = q.droppedVideoFrames || 0; total = q.totalVideoFrames || 0; }
    } catch (_) {}
    // 等待期测速源：ProxyHlsLoader 一次性交付整片，字节只在片尾跳一次，
    // _net.bps 那个 2 秒窗口量出来「收片瞬间虚高十几倍、其余时间恒为 0」——
    // 两个都不像线路能力，看门狗拿它判「跟不跟得上」只会把所有样本都否掉。
    // 改成对累计收片字节做 1 Hz 差分：等待期里每秒都在收，差分就是那一秒的真实
    // 下行速率（同 macOS 在等待期逐秒读引擎字节计数，取最快那秒）
    let loadingBps = 0;
    if (this._net) {
      const bytes = this._net.bytes || 0;
      if (this._lastNetBytes != null && bytes >= this._lastNetBytes) {
        loadingBps = (bytes - this._lastNetBytes) * 8; // 每秒一字节 = 8 bps
      }
      this._lastNetBytes = bytes;
    }
    return {
      time: this.engPos(),
      paused: !!v.paused,
      ended: !!v.ended,
      seeking: !!v.seeking,
      bufferedAhead,
      loadingBps,
      dropped, total, fps: 0,
      buffering: !!this._buffering,
    };
  },

  async _tickWatchdogs(generation = this.generation) {
    if (!this._frameDrops || !this.sessionData) return;
    const view = document.getElementById('playerView');
    if (view && view.hidden) return;
    const s = await this._sampleEngine();
    if (generation !== this.generation || !s || !this._frameDrops || !this.sessionData || this._ended) return;
    this.sampleQoe(s);
    if (s.ended) { this.reportPlaybackEnd(); return; }
    if (s.buffering !== this._measuredBuffering) {
      this._measuredBuffering = s.buffering;
      this.measure(s.buffering ? 'buffer_start' : 'buffer_end');
      if (s.buffering) App._recoveryAt = null;
      else this.measure('playing');
    }
    // 真播起来了就清网络重开预算（同 macOS reachedPlaying()）
    if (!s.buffering && !s.paused && !s.ended && s.time > 0 && typeof App !== 'undefined' && App.onPlaybackRecovered) {
      App.onPlaybackRecovered();
    }

    const sd = this.sessionData;
    const decision = sd.decision || {};
    const tier = typeof decision.tier === 'number' ? decision.tier : null;
    // 只在视频直通档判掉帧：转码档（3/4）再掉帧说明连转码产物都放不动，降档只会更糟
    const isCopy = decision.video ? decision.video.action === 'copy' : tier === 0;
    const playsOriginalFile = tier === 0;

    if (isCopy && tier != null && tier < 3 && !s.paused && !s.ended && !s.seeking) {
      if (this.isMpv()) {
        // mpv 不给已播帧数，用累计观看时长 × 帧率估（同 macOS EngineStats）；
        // 只认小步前进，起播定位/用户拖动的大跳不算
        const d = this._lastWatchTime == null ? 0 : s.time - this._lastWatchTime;
        if (d > 0 && d < 5) this._watchedSeconds += d;
        this._lastWatchTime = s.time;
        s.total = Math.floor(this._watchedSeconds * (s.fps || 24));
      }
      const ratio = this._frameDrops.sample(s.dropped, s.total);
      if (ratio != null && ratio >= this._frameDrops.threshold) {
        this._frameDrops.reset();
        const pct = Math.round(ratio * 100);
        if (typeof App !== 'undefined' && App.onPlaybackContentFailed) {
          App.onPlaybackContentFailed(`直通播放持续掉帧（${pct}%），正在换转码重试`);
        }
        return;
      }
    }

    const deadLimit = playsOriginalFile ? this._stallWatch.DIRECT_DEAD_S : this._stallWatch.SERVER_DEAD_S;
    const verdict = this._stallWatch.sample(
      s.time, s.bufferedAhead, s.paused, s.ended, s.seeking, s.loadingBps > 0, deadLimit,
    );
    if (verdict === 'nudge') {
      // 有数据却不动：推一把踢活解码管线（起播预滚阶段 tracker 不会推）。
      // 故意不走 engSeekTo —— 那条路会清 StallWatch，把「最多推 2 把」清成无限推
      const t = Math.max(0, s.time + this._stallWatch.NUDGE_STEP - this.originMs / 1000);
      if (this.isMpv()) {
        if (this.mpvState) this.mpvState.time = t;
        this.mpvCmd(['seek', t, 'absolute']);
        this.mpvCmd(['set_property', 'pause', false]);
      } else if (this.video) {
        this.video.currentTime = t;
        this.video.play().catch(() => {});
      }
    } else if (verdict === 'decodeStalled') {
      if (typeof App !== 'undefined' && App.onPlaybackContentFailed) {
        App.onPlaybackContentFailed(this._stallWatch.reason(verdict, deadLimit));
      }
      return;
    } else if (verdict === 'dead') {
      if (typeof App !== 'undefined' && App.onPlaybackNetworkDead) {
        App.onPlaybackNetworkDead(this._stallWatch.reason(verdict, deadLimit));
      }
      return;
    }

    // ---- 画质建议（与掉帧互不触发：那是解码吃不下，这是线路跟不上）----
    if (!this._qualitySuggestion) return;
    this._qualitySuggestion.tick(s.buffering || s.seeking, s.seeking, s.loadingBps);
    if (this._qualityOffer || this._qualitySuggestion.offered) return;
    const bitrate = (sd.source && sd.source.bit_rate) || 0;
    const sourceHeight = heightOfResolution(sd.source && sd.source.resolution)
      ?? (decision.video && decision.video.height) ?? null;
    const currentHeight = this.currentQuality > 0
      ? (sourceHeight != null ? Math.min(sourceHeight, this.currentQuality) : this.currentQuality)
      : sourceHeight;
    const offer = this._qualitySuggestion.offer(bitrate, currentHeight);
    if (offer) this.showQualityOffer(offer);
  },

  // 画质建议卡（macOS QualitySuggestion）：一次性、20 秒没理会自动收起、换不换由用户定
  showQualityOffer(offer) {
    this._qualityOffer = offer;
    const meas = formatBandwidth(offer.measuredBps) || '—';
    const req = formatBandwidth(offer.requiredBps) || '—';
    let card = document.getElementById('qualityOfferCard');
    if (!card) {
      card = document.createElement('div');
      card.id = 'qualityOfferCard';
      card.className = 'quality-offer-card';
      document.getElementById('playerView')?.appendChild(card);
    }
    card.innerHTML = `
      <div class="quality-offer-title">网速跟不上当前画质</div>
      <div class="quality-offer-body">实测约 ${meas}，这一版需要约 ${req}。可以暂停攒一会缓冲再看，或改用 ${offer.maxHeight}p（服务端转码，画质会降低）。</div>
      <div class="quality-offer-actions">
        <button class="btn-secondary" id="btnKeepQuality">继续当前画质</button>
        <button class="btn-play" id="btnAcceptQuality">改用 ${offer.maxHeight}p</button>
      </div>
    `;
    document.getElementById('btnAcceptQuality')?.addEventListener('click', () => this.acceptQualityOffer());
    document.getElementById('btnKeepQuality')?.addEventListener('click', () => this.hideQualityOffer());
    clearTimeout(this._qualityOfferTimer);
    this._qualityOfferTimer = setTimeout(() => this.hideQualityOffer(), 20000);
  },

  acceptQualityOffer() {
    const offer = this._qualityOffer;
    if (!offer) return;
    this.hideQualityOffer();
    this.selectQuality(offer.maxHeight);
  },

  hideQualityOffer() {
    clearTimeout(this._qualityOfferTimer);
    this._qualityOfferTimer = null;
    this._qualityOffer = null;
    document.getElementById('qualityOfferCard')?.remove();
  },

  // ===== 对话框（同 macOS MacPlayerDialog / MacConsentDialog）=====
  // 会话决策的两个终态：要用户同意才能软件转码、或彻底放不了。模态压在播放器上，
  // 键盘 ⏎ 认主按钮、Esc 认次按钮（同 SwiftUI .defaultAction / .cancelAction）
  hidePlayerDialog() {
    this._dialog = null;
    document.getElementById('playerDialog')?.remove();
  },

  _dialogButton(label, prominent, onClick) {
    const b = document.createElement('button');
    b.className = prominent ? 'btn-play' : 'btn-secondary';
    b.textContent = label;
    b.addEventListener('click', onClick);
    return b;
  },

  // 错误对话框：标题 + 一行建议 +「重试 / 关闭」（macOS MacPlayerDialog 的 .error 用法）
  showPlayerDialog({ title, message, primary, secondary, alternative }) {
    this.hidePlayerDialog();
    const card = document.createElement('div');
    card.className = 'player-dialog';
    // SF Symbol 的感叹号三角，Windows 用同形状的内联 SVG（界面不用 emoji）
    card.innerHTML = `
      <svg class="player-dialog-icon" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
        <path d="M12 2.5 1.2 21.5h21.6L12 2.5zm0 6.2a.9.9 0 0 1 .9.9v5a.9.9 0 1 1-1.8 0v-5a.9.9 0 0 1 .9-.9zm0 9.1a1.15 1.15 0 1 1 0 2.3 1.15 1.15 0 0 1 0-2.3z"/>
      </svg>
    `;
    const t = document.createElement('div');
    t.className = 'player-dialog-title';
    t.textContent = title;
    card.appendChild(t);
    if (message) {
      const m = document.createElement('div');
      m.className = 'player-dialog-message';
      m.textContent = message;
      card.appendChild(m);
    }
    const actions = document.createElement('div');
    actions.className = 'player-dialog-actions';
    // 主次顺序同 macOS：次按钮在左、主按钮在右
    if (secondary) actions.appendChild(this._dialogButton(secondary[0], false, secondary[1]));
    if (alternative) actions.appendChild(this._dialogButton(alternative[0], false, alternative[1]));
    actions.appendChild(this._dialogButton(primary[0], true, primary[1]));
    card.appendChild(actions);
    this._mountDialog(card, primary[1], secondary ? secondary[1] : null);
  },

  // 软件转码同意：说清原因与代价，能自开的给「开启并播放」（macOS MacConsentDialog）
  showConsentDialog(decision) {
    this.hidePlayerDialog();
    const card = document.createElement('div');
    card.className = 'player-dialog consent';
    const t = document.createElement('div');
    t.className = 'player-dialog-title';
    t.textContent = '这部片需要软件转码才能播放';
    card.appendChild(t);

    const field = (label, text) => {
      const wrap = document.createElement('div');
      const l = document.createElement('div');
      l.className = 'player-dialog-field-label';
      l.textContent = label;
      const v = document.createElement('div');
      v.className = 'player-dialog-field-value';
      v.textContent = text;
      wrap.append(l, v);
      return wrap;
    };
    card.appendChild(field('原因', decision.reason || ''));
    if (decision.cost_hint) card.appendChild(field('代价', decision.cost_hint));

    // 开关存不下去时把原因留在框里（macOS 的 error 状态）
    const errEl = document.createElement('div');
    errEl.className = 'player-dialog-error';
    errEl.hidden = true;
    card.appendChild(errEl);

    if (decision.can_self_enable !== true) {
      const hint = document.createElement('div');
      hint.className = 'player-dialog-hint';
      hint.textContent = '当前未开启软件转码。请联系管理员开启（管理员播放此类影片时会收到开启询问）。';
      card.appendChild(hint);
    }

    const actions = document.createElement('div');
    actions.className = 'player-dialog-actions';
    if (decision.can_self_enable !== true) {
      // 非超管改不了开关：只有「知道了」，等于退出
      actions.appendChild(this._dialogButton('知道了', true, () => this.close()));
      card.appendChild(actions);
      this._mountDialog(card, () => this.close(), null);
      return;
    }
    let saving = false;
    const grant = async () => {
      if (saving) return;
      saving = true;
      errEl.hidden = true;
      primaryBtn.disabled = true;
      primaryBtn.textContent = '正在开启…';
      try {
        await App.grantConsent();
        // 成功会重新起播，起播链里的 Player.close() 自己把对话框收掉
      } catch (e) {
        errEl.textContent = (e && e.message) || String(e);
        errEl.hidden = false;
        saving = false;
        primaryBtn.disabled = false;
        primaryBtn.textContent = '开启并播放';
      }
    };
    actions.appendChild(this._dialogButton('取消', false, () => this.close()));
    const primaryBtn = this._dialogButton('开启并播放', true, grant);
    actions.appendChild(primaryBtn);
    card.appendChild(actions);
    this._mountDialog(card, grant, () => this.close());
  },

  _mountDialog(card, primary, secondary) {
    const scrim = document.createElement('div');
    scrim.id = 'playerDialog';
    scrim.className = 'player-dialog-scrim';
    scrim.appendChild(card);
    document.getElementById('playerView')?.appendChild(scrim);
    // 键盘 ⏘/Esc 要找得到按钮对应的动作
    this._dialog = { primary, secondary };
  },

  // mpv 画面是主窗口的子窗口，不跟 HTML5 布局走：视频区域一变（缩放窗口/进全屏）得手动挪它。
  // 同时网页层要在这块区域上挖洞透出画面——但顶栏/进度条/浮层压在视频上，
  // 洞必须把它们刨出去，否则 SetWindowRgn 会把控件一起剪没
  syncEmbeddedPlayerRect() {
    if (!this.isMpv() || !window.__TAURI__?.core?.invoke) return;
    const wrap = document.querySelector('.player-video-wrap');
    const topbar = document.getElementById('playerTopbar');
    const controls = document.getElementById('playerControls');
    if (!wrap || !topbar || !controls) return;
    const wr = wrap.getBoundingClientRect();
    const scale = window.devicePixelRatio || 1;
    const box = (r) => [r.left, r.top, r.width, r.height].map((v) => Math.round(v * scale));
    // 视频始终占满容器，控件只保留网页绘制区域，不改变 mpv 的画幅。
    // opacity 过渡结束后再挖掉隐藏的控件，避免全屏留下上下黑带。
    const overlays = ['playerTopbar', 'playerFriendsPanel', 'playerCenterBtn', 'playerSpeedBadge', 'playerLoading', 'playerInfoPanel', 'playerSettingsPanel', 'playerSpeedPanel', 'playerSkipBtn', 'playerDialog', 'autoNextCard']
      .map((id) => document.getElementById(id))
      .concat(controls.querySelector('.player-transport'));
    const visibleOverlays = overlays
      .filter((el) => el && !el.hidden && !el.closest('[hidden]') && getComputedStyle(el).display !== 'none'
        && Number(getComputedStyle(el.closest('#playerControls') || el).opacity) > 0);
    const keepRects = visibleOverlays.map((el) => box(el.getBoundingClientRect()));
    // 圆形播放键和圆角面板按实际轮廓保留，四角仍透出视频。
    const keepRadii = visibleOverlays.map(el => {
      const radius = getComputedStyle(el).borderTopLeftRadius;
      const rect = el.getBoundingClientRect();
      const px = radius.endsWith('%') ? Math.min(rect.width, rect.height) * parseFloat(radius) / 100 : parseFloat(radius);
      return Math.round((px || 0) * scale);
    });
    const args = {
      x: Math.round(wr.left * scale),
      y: Math.round(wr.top * scale),
      width: Math.round(wr.width * scale),
      height: Math.round(wr.height * scale),
      keepRects,
      keepRadii,
    };
    // 浮层显隐没有统一入口，靠轮询兜着；签名没变就不重设区域，免得每 200ms 触发一次重绘
    const sig = JSON.stringify(args);
    if (sig === this._mpvRectSig) return;
    this._mpvRectSig = sig;
    window.__TAURI__.core.invoke('resize_embedded_player', args).catch(() => {});
    window.__TAURI__.core.invoke('set_embedded_player_visible', { visible: true }).catch(() => {});
  },

  togglePlay() {
    if (this._ended && this.context && typeof App !== 'undefined') {
      App.restartPlaybackAt(0);
      return;
    }
    const wasPaused = this.engPaused();
    if (this.isMpv()) {
      if (this.mpvState) this.mpvState.paused = !wasPaused;
      this.mpvCmd(['set_property', 'pause', !wasPaused]);
      // HTML5 的 play/pause 事件在 mpv 会话里不会来，图标/控制条这里补上
      this.showIcon(wasPaused ? 'pause' : 'play');
      if (wasPaused) { this.hideCenterBtn(); this.autoHideControls(); }
      else { this.showCenterBtn(); this.showControls(); this.autoHideControls(); }
      window.MovieClawPlatform?.update();
    } else if (this.video) {
      if (this.video.paused) this.video.play().catch(() => {});
      else this.video.pause();
    }
  },

  toggleMute() {
    const next = !this.engMuted();
    this.engSetMuted(next);
  },

  isFullscreen() {
    return !!document.fullscreenElement || !!this._nativeFullscreen;
  },

  async applyFullscreenFit(mode = this.fullscreenFit) {
    const fill = this.isFullscreen() && mode === 'cover';
    if (this.isMpv()) {
      const result = await this.mpvCmd(['set_property', 'panscan', fill ? 1 : 0]);
      if (!result) { this.controlError('无法调整画幅，请重试'); return false; }
    } else if (this.video) this.video.style.objectFit = fill ? 'cover' : 'contain';
    return true;
  },

  async setFullscreenFit(mode) {
    if (!['contain', 'cover'].includes(mode)) return false;
    const generation = this.generation;
    const selection = this._frameSelectionSeq = (this._frameSelectionSeq || 0) + 1;
    if (!await this.applyFullscreenFit(mode)) return false;
    if (generation !== this.generation || selection !== this._frameSelectionSeq) return false;
    this.fullscreenFit = mode;
    localStorage.setItem('mc_fullscreenFit', mode);
    if (this._settingsTab === 'frame') {
      this.renderSettingsTab('frame');
      document.querySelector(`[data-fit="${mode}"]`)?.focus();
    }
    return true;
  },

  toggleFullscreen() {
    if (this.nativePip) {
      const generation = this.generation;
      return this.togglePip().then(() => {
        if (generation === this.generation && this.activeEngine && !this.nativePip && !this.isFullscreen()) return this.toggleFullscreen();
      });
    }
    const view = document.getElementById('playerView');
    if (!view) return Promise.resolve();
    if (this.isMpv() && window.__TAURI__?.window?.getCurrentWindow) {
      const generation = this.generation;
      const state = this._nativeFullscreenState ||= { before: undefined, active: false };
      const task = (this._nativeFullscreenTask || Promise.resolve()).catch(() => {}).then(async () => {
        const nativeWindow = window.__TAURI__.window.getCurrentWindow();
        const current = await nativeWindow.isFullscreen();
        if (state.before === undefined) state.before = current;
        if (generation !== this.generation || this._nativeFullscreenState !== state) return;
        const next = !current;
        await nativeWindow.setFullscreen(next);
        state.active = next;
        if (this._nativeFullscreenState === state) this._nativeFullscreen = next;
        if (generation === this.generation && this._nativeFullscreenState === state) await this.applyFullscreenFit();
        requestAnimationFrame(() => this.syncEmbeddedPlayerRect());
      });
      this._nativeFullscreenTask = task;
      return task.catch(() => { if (generation === this.generation) this.controlError('无法切换窗口全屏'); });
    }
    if (document.fullscreenElement) return document.exitFullscreen().catch(() => {});
    return view.requestFullscreen().catch(() => {});
  },

  restoreNativeFullscreen() {
    const state = this._nativeFullscreenState;
    this._nativeFullscreenState = null;
    this._nativeFullscreen = false;
    if (!state || !window.__TAURI__?.window?.getCurrentWindow) return Promise.resolve();
    const task = (this._nativeFullscreenTask || Promise.resolve()).catch(() => {}).then(async () => {
      if (state.before !== undefined) await window.__TAURI__.window.getCurrentWindow().setFullscreen(state.before);
    });
    this._nativeFullscreenTask = task;
    return task.catch(() => {});
  },

  async togglePip() {
    if (this.isMpv()) {
      if (this._pipPending) return;
      const generation = this.generation;
      this._pipPending = true;
      try {
        this.closeAnyPanel();
        const status = await window.MovieClawPlatform?.pictureInPicture(!this.nativePip);
        if (!status || generation !== this.generation) return;
        this.nativePip = status.pictureInPicture === true;
        this._nativeFullscreen = await window.__TAURI__.window.getCurrentWindow().isFullscreen();
        if (this._nativeFullscreenState) this._nativeFullscreenState.active = this._nativeFullscreen;
        document.getElementById('playerView')?.classList.toggle('native-pip', this.nativePip);
        const button = document.getElementById('btnPip');
        if (button) { button.title = this.nativePip ? '恢复播放器窗口 (Esc)' : '画中画'; button.setAttribute('aria-pressed', String(this.nativePip)); }
        await this.applyFullscreenFit();
        this._mpvRectSig = null; this.syncEmbeddedPlayerRect();
      } catch (_) { if (generation === this.generation) this.controlError('无法切换画中画，请重试'); }
      finally { this._pipPending = false; }
      return;
    }
    if (!this.video || this.isMpv() || !document.pictureInPictureEnabled) return;
    if (document.pictureInPictureElement) document.exitPictureInPicture();
    else this.video.requestPictureInPicture().catch(() => {});
  },

  showIcon(name) {
    const play = document.getElementById('iconPlay');
    const pause = document.getElementById('iconPause');
    if (play) play.style.display = name === 'play' ? '' : 'none';
    if (pause) pause.style.display = name === 'pause' ? '' : 'none';
    const centerBtn = document.getElementById('playerCenterBtn');
    if (centerBtn) {
      centerBtn.innerHTML = name === 'play'
        ? '<svg width="48" height="48" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>'
        : '<svg width="48" height="48" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg>';
    }
  },

  showCenterBtn() {
    const btn = document.getElementById('playerCenterBtn');
    if (btn) btn.hidden = false;
  },

  hideCenterBtn() {
    const btn = document.getElementById('playerCenterBtn');
    if (btn) btn.hidden = true;
  },

  showControls() {
    const changed = !this.controlsVisible;
    this.controlsVisible = true;
    const view = document.getElementById('playerView');
    if (view) view.style.cursor = '';
    if (changed) this.applySubtitleStyle();
    const topbar = document.getElementById('playerTopbar');
    const controls = document.getElementById('playerControls');
    if (topbar) topbar.style.opacity = '1';
    if (controls) controls.style.opacity = '1';
  },

  hideControls() {
    if (['playerFriendsPanel', 'playerSettingsPanel', 'playerSpeedPanel', 'playerInfoPanel', 'playerDialogOverlay', 'autoNextCard'].some(id => { const el = document.getElementById(id); return el && !el.hidden; }) || this.isSeeking) return;
    this.controlsVisible = false;
    const view = document.getElementById('playerView');
    if (view) view.style.cursor = 'none';
    this.applySubtitleStyle();
    const topbar = document.getElementById('playerTopbar');
    const controls = document.getElementById('playerControls');
    if (topbar) topbar.style.opacity = '0';
    if (controls) controls.style.opacity = '0';
  },

  autoHideControls() {
    clearTimeout(this.hideTimer);
    this.hideTimer = null;
    if (this.activeEngine && !this.engPaused() && !this._ended) {
      this.hideTimer = setTimeout(() => {
        this.hideTimer = null;
        if (!this.activeEngine || this.engPaused() || this._ended) return;
        this.hideControls();
        if (this.controlsVisible) this.autoHideControls();
        else this.hideCenterBtn();
      }, 3000);
    }
  },

  // 进度条上的已播条与滑块：拖动中跟手指（_scrubPct），否则跟播放头
  renderScrub() {
    const dur = this.engDuration();
    const frac = this._scrubPct != null
      ? this._scrubPct
      : (dur ? this.engPos() / dur : 0);
    const pct = Math.max(0, Math.min(1, frac)) * 100;
    const fill = document.getElementById('playerSeekFill');
    const thumb = document.getElementById('playerSeekThumb');
    if (fill) fill.style.width = pct + '%';
    if (thumb) thumb.style.left = pct + '%';
  },

  updateProgress() {
    if (!this.isMpv() && this._seekMeasurement && !this.video?.seeking && Math.abs(this.engPos() - this._seekMeasurement.target) < 1) {
      this.measure('seek_end', { elapsedMs: performance.now() - this._seekMeasurement.at });
      this._seekMeasurement = null;
    }
    if (this.isSeeking) return;
    if (!this.isMpv() && !this.video) return;
    const cur = this.engPos();
    const dur = this.engDuration();

    this.renderScrub();

    // 下行两端：左「已播」，右「剩余」或「总长」（点它切换，同 QuickTime）。
    // 片长还没起（起播中）时右侧显示占位，不显示「-0:00」（同 macOS）
    const timeEl = document.getElementById('playerTime');
    if (timeEl) timeEl.textContent = this.formatTime(cur);
    const remEl = document.getElementById('playerRemaining');
    if (remEl) {
      remEl.textContent = dur > 0
        ? (this.showsTotal ? this.formatTime(dur) : '-' + this.formatTime(Math.max(0, dur - cur)))
        : '--:--';
      remEl.title = this.showsTotal ? '显示剩余时间' : '显示总时长';
    }
  },

  updateBuffer() {
    if (!this.video || !this.video.buffered.length) return;
    const dur = this.engDuration();
    const buf = this.originMs / 1000 + this.video.buffered.end(this.video.buffered.length - 1);
    const pct = dur ? (buf / dur) * 100 : 0;
    const bufEl = document.getElementById('playerSeekBuffer');
    if (bufEl) bufEl.style.width = pct + '%';
  },

  updateVolumeIcon() {
    const vol = document.getElementById('iconVol');
    const mute = document.getElementById('iconMute');
    const isMuted = this.isMpv()
      ? (this.engMuted() || this.engVolume() === 0)
      : (!this.video || this.video.muted || this.video.volume === 0);
    if (vol) vol.style.display = isMuted ? 'none' : '';
    if (mute) mute.style.display = isMuted ? '' : 'none';
    const volume = isMuted ? 0 : Math.max(0, Math.min(1, this.engVolume()));
    const percent = Math.round(volume * 100);
    const slider = document.getElementById('volumeSlider');
    if (slider) {
      slider.value = String(volume);
      slider.setAttribute('aria-valuetext', isMuted ? '静音' : `${percent}%`);
    }
    const label = document.getElementById('playerVolumeValue');
    if (label) label.textContent = isMuted ? '静音' : `${percent}%`;
  },

  beginAttempt(context) {
    this._qoe = { at: performance.now(), attempt_id: context.attemptId || null, origin: context.__autoNext ? 'auto_next' : 'tap',
      media_item_id: Number(context.media_item_id) || null, season_number: context.seasonNumber ?? null,
      episode_number: context.episodeNumber ?? null, tier: -1, engine: '', hw_backend: '', first_frame_ms: null,
      playing_ms: null, rebuffer_ms: 0, rebuffer_count: 0, seek_count: 0, watched_ms: 0, timeline: [], outcome: '',
      identity: { server: API.baseUrl, account: App.session?.username || '', epoch: API.contextEpoch } };
  },

  sampleQoe(sample) {
    const q = this._qoe;
    if (!q || !sample) return;
    const now = performance.now();
    if (!sample.paused && !sample.buffering && !sample.seeking && !sample.ended && q.lastAt != null) {
      q.watched_ms += Math.max(0, Math.min(5000, now - q.lastAt));
    }
    q.lastAt = now;
  },

  finishAttempt() {
    const q = this._qoe;
    if (!q) return Promise.resolve();
    this._qoe = null;
    if (!q.attempt_id || q.identity.server !== API.baseUrl || q.identity.epoch !== API.contextEpoch ||
      q.identity.account !== (App.session?.username || '')) return Promise.resolve();
    if (q.bufferAt != null) q.rebuffer_ms += performance.now() - q.bufferAt;
    const v = this.mpvState?.properties || {};
    const body = { attempt_id: q.attempt_id, client: 'windows', origin: q.origin,
      media_item_id: q.media_item_id, season_number: q.season_number, episode_number: q.episode_number,
      library_file_id: q.library_file_id, tier: q.tier, engine: q.engine, hw_backend: q.hw_backend,
      first_frame_ms: q.first_frame_ms, playing_ms: q.playing_ms, rebuffer_ms: Math.floor(q.rebuffer_ms),
      rebuffer_count: q.rebuffer_count, seek_count: q.seek_count, watched_ms: Math.floor(q.watched_ms),
      dropped_frames: this.isMpv() ? (Number(v['frame-drop-count']) || 0) + (Number(v['decoder-frame-drop-count']) || 0)
        : this.video?.getVideoPlaybackQuality?.().droppedVideoFrames ?? null,
      network_class: 'unknown', route: q.tier === 0 ? 'remote_bypass' : 'server_transcode',
      error_category: q.error_category || '', error_kind: q.error_kind || '', error_stage: q.error_stage || '',
      outcome: q.outcome || (q.first_frame_ms != null ? 'exited' : 'exit_before_start'),
      detail: { timeline: q.timeline, context: { hwdec: String(v['hwdec-current'] || 'unknown'),
        target_primaries: String(v['video-target-params']?.primaries || 'unknown'),
        target_gamma: String(v['video-target-params']?.gamma || 'unknown') } } };
    if (body.outcome === 'failed') API.request('/playback/client-log', { method: 'POST', timeoutMs: 1200, cancelable: true,
      body: { event: 'playback_failure', detail: { attempt_id: q.attempt_id, client: 'windows', engine: q.engine,
        category: body.error_category, kind: body.error_kind, stage: body.error_stage, tier: q.tier } } }).catch(() => {});
    return API.request('/playback/metrics', { method: 'POST', body, timeoutMs: 1200, cancelable: true }).catch(() => {});
  },

  measure(event, extra = {}) {
    const v = this.mpvState?.properties || {}, output = v['video-out-params'] || {};
    const qoe = this._qoe;
    if (qoe) {
      const now = performance.now();
      if (event === 'first_frame' && qoe.first_frame_ms == null) qoe.first_frame_ms = Math.floor(now - qoe.at);
      if (event === 'playing' && qoe.playing_ms == null) qoe.playing_ms = Math.floor(now - qoe.at);
      if (event === 'seek_start') qoe.seek_count++;
      if (event === 'buffer_start' && this._everPlayed && qoe.bufferAt == null) { qoe.bufferAt = now; qoe.rebuffer_count++; }
      if (event === 'buffer_end' && qoe.bufferAt != null) { qoe.rebuffer_ms += now - qoe.bufferAt; qoe.bufferAt = null; }
      if (event === 'error') qoe.outcome = 'failed';
      if (event === 'retry' || event === 'playing') qoe.outcome = '';
      if (event === 'ended') qoe.outcome = 'watched';
      qoe.timeline.push({ event, at_ms: Math.max(0, Math.floor(now - qoe.at)), ...(Number.isFinite(extra.elapsedMs) ? { duration_ms: Math.floor(extra.elapsedMs) } : {}) });
      if (qoe.timeline.length > 64) qoe.timeline.shift();
    }
    const detail = { event, engine: this.activeEngine, generation: this.generation,
      positionMs: Math.floor(this.engPos() * 1000), tier: this.sessionData?.decision?.tier ?? null,
      hwdec: this.isMpv() ? String(v['hwdec-current'] || 'no') : 'browser',
      outputWidth: output.w ?? this.video?.videoWidth ?? 0, outputHeight: output.h ?? this.video?.videoHeight ?? 0,
      dropped: (Number(v['frame-drop-count']) || 0) + (Number(v['decoder-frame-drop-count']) || 0),
      buffering: !!this._buffering, rate: this.engRate() };
    if (Number.isFinite(extra.elapsedMs)) detail.elapsedMs = Math.max(0, extra.elapsedMs);
    window.dispatchEvent(new CustomEvent('movieclaw:playback-measurement', { detail }));
  },

  handleNativeInput(args) {
    const [action, number] = args;
    if (action === 'move' || action === 'click') { this.showControls(); this.autoHideControls(); }
    else if (action === 'double-click' || action === 'fullscreen') this.toggleFullscreen();
    else if (action === 'info') this.toggleInfoPanel();
    else if (action === 'play') this.togglePlay();
    else if (action === 'seek') this.engSeekBy(Number(number) || 0);
    else if (action === 'volume') this.engSetVolume(this.engVolume() + (Number(number) || 0));
    else if (action === 'mute') this.toggleMute();
    else if (action === 'home') this.engSeekTo(0);
    else if (action === 'chapter') this.seekChapter(Number(number));
    else if (action === 'speed') this.setSpeed(Math.max(0.5, Math.min(2, this.engRate() + (Number(number) || 0))));
    else if (action === 'subtitle-cycle') this.cycleSubtitle();
    else if (action === 'close') this.close();
    else if (action === 'enter') this._dialog?.primary?.();
    else if (action === 'previous') this.playEpisode(this.prevEpisode());
    else if (action === 'next') this.playEpisode(this.nextEpisode());
    else if (action === 'escape') { if (this._dialog) { this._dialog.secondary?.(); return; } if (this.closeAnyPanel()) return; if (this.nativePip) this.togglePip(); else if (this.isFullscreen()) this.toggleFullscreen(); else this.close(); }
  },

  initialSubtitle() {
    const plans = this.sessionData?.decision?.subtitles || [];
    const options = this.buildSubtitleTracks().options;
    const remembered = this.context?.subtitle_track ?? this.sessionData?.watch?.subtitle_track;
    if (remembered === 'off') return -1;
    const explicit = options.find(o => plans[o.index]?.track_ref === remembered);
    if (explicit) return explicit.index;
    const preferred = localStorage.getItem('mc_subLang');
    if (preferred === '') return -1;
    const language = options.find(o => languageMatches(o.language, preferred));
    if (language) return language.index;
    return options.find(o => plans[o.index]?.is_default)?.index ?? -1;
  },

  async initializeTracks() {
    const generation = this.generation;
    const audioRef = this.context?.audio_track ?? this.sessionData?.watch?.audio_track;
    const tracks = this.audioTracks();
    const audio = tracks.find(t => t.ref === audioRef) || tracks.find(t => languageMatches(t.language, localStorage.getItem('mc_audioLang')));
    if (audio && audio.ref !== this.currentAudioRef) await this.selectAudio(audio.ref, { remember: false });
    if (generation !== this.generation) return;
    await this.selectSubtitle(this.initialSubtitle(), { remember: false });
    if (generation !== this.generation) return;
    await this.setSpeed(this.context?.playbackRate || 1);
    if (this.subtitleOffset) await this.adjustSubtitleOffset(0);
    this.applySubtitleStyle();
    if (generation === this.generation) await this.applyFullscreenFit();
  },

  playbackToken() {
    try { const token = new URL(playbackMediaUrl(this.sessionData?.stream_url || '')).searchParams.get('token');
      return token ? '?token=' + encodeURIComponent(token) : ''; } catch (_) { return ''; }
  },

  async mediaCapability(url, generation = this.generation) {
    if (!window.__TAURI__) return playbackMediaUrl(url);
    const grant = await window.__TAURI__.core.invoke('grant_media_stream', { url: playbackMediaUrl(url) });
    if (generation !== this.generation) {
      await window.__TAURI__.core.invoke('release_media_stream', { streamId: grant.streamId }).catch(() => {});
      throw new DOMException('播放已更换', 'AbortError');
    }
    if (!grant.url || !grant.streamId) throw new Error('媒体代理未返回有效地址');
    (this._mediaGrants ||= new Set()).add(grant.streamId);
    return grant.url;
  },

  async loadTrickplayIndex() {
    const fileId = this.sessionData?.decision?.file_id;
    if (!fileId) return;
    const generation = this.generation;
    const signal = this._trickplayAbort.signal;
    try {
      for (let attempt = 0; attempt < 3; attempt++) {
        const response = await API.request('/playback/files/' + fileId + '/trickplay' + this.playbackToken(), { signal });
        if (generation !== this.generation) return;
        const index = response?.data || response;
        if (index?.ready) { this.trickplayIndex = index; return; }
        if (attempt < 2) await new Promise(resolve => {
          const timer = setTimeout(resolve, 3000);
          signal.addEventListener('abort', () => { clearTimeout(timer); resolve(); }, { once: true });
        });
        if (signal.aborted) return;
      }
    } catch (_) { /* Preview is optional; time labels still work. */ }
  },

  renderTrickplayPreview(preview, fileMs, time) {
    const ticket = preview._ticket = (preview._ticket || 0) + 1;
    preview.innerHTML = '<div class="time">' + playerText(time) + '</div>';
    const tile = trickplayTile(this.trickplayIndex, fileMs);
    if (!tile) return;
    const generation = this.generation;
    const images = this._spriteImages;
    if (!images) return;
    if (!images.has(tile.sheet)) images.set(tile.sheet, this.mediaCapability(tile.sheet, generation).catch(() => ''));
    images.get(tile.sheet).then(url => {
      if (!url || generation !== this.generation || preview.hidden || ticket !== preview._ticket) return;
      const image = document.createElement('div'); image.className = 'img';
      image.style.width = tile.width + 'px'; image.style.height = tile.height + 'px';
      image.style.backgroundImage = 'url(' + JSON.stringify(url) + ')';
      image.style.backgroundPosition = '-' + tile.x + 'px -' + tile.y + 'px';
      preview.innerHTML = ''; preview.appendChild(image);
      const label = document.createElement('div'); label.className = 'time'; label.textContent = time; preview.appendChild(label);
    });
  },

  // ===== JASSUB ASS 字幕渲染 =====
  async initJassub(subtitles, sessionData, index, selection) {
    if (!subtitles?.[index] || typeof JASSUB === 'undefined') throw new Error('ASS 字幕渲染器不可用');
    const generation = this.generation;
    const response = await API.rawFetch('/__stream__?url=' + encodeURIComponent(playbackMediaUrl(subtitles[index])),
      { signal: this._trickplayAbort?.signal });
    if (!response.ok) throw new Error('ASS 字幕读取失败（HTTP ' + response.status + '）');
    const content = await response.text();
    if (generation !== this.generation || selection !== this._subtitleSelectionSeq) return;
    if (this.jassub) this.jassub.setTrack(content);
    else this.jassub = new JASSUB({ video: this.video, subContent: content,
      availableFonts: { default: 'jassub-default.woff2' }, workerUrl: 'jassub-worker.js',
      wasmUrl: 'jassub-worker.wasm', fallbackFont: 'jassub-default.woff2',
      timeOffset: this.originMs / 1000 - this.subtitleOffset, debug: false });
    this.jassub.timeOffset = this.originMs / 1000 - this.subtitleOffset;
    this._assOriginal = null;
    this.applySubtitleStyle();
    // Lazy font extraction can take time. It never delays the video or subtitle
    // selection; libass updates existing glyphs once attachment fonts arrive.
    this.loadAssFonts(generation).catch(() => {});
  },

  async loadAssFonts(generation) {
    const fileId = this.sessionData?.decision?.file_id;
    if (!fileId || this._fontGeneration === generation) return;
    this._fontGeneration = generation;
    const token = this.playbackToken();
    const response = await API.request('/playback/files/' + fileId + '/fonts' + token,
      { signal: this._trickplayAbort?.signal, timeoutMs: 30000 });
    if (generation !== this.generation || !this.jassub) return;
    for (const font of (response?.data || response)?.fonts || []) {
      const url = await this.mediaCapability(font, generation);
      if (generation !== this.generation) return;
      const result = await fetch(url, { signal: this._trickplayAbort?.signal });
      if (!result.ok) continue;
      const bytes = new Uint8Array(await result.arrayBuffer());
      if (generation !== this.generation || !this.jassub) return;
      this.jassub.addFont(bytes);
    }
  },

  destroyJassub() {
    if (this.jassub) {
      try { this.jassub.destroy(); } catch (_) {}
      this.jassub = null;
    }
    this.jassubTracks = [];
    this._assOriginal = null;
    this._fontGeneration = null;
  },

  // ===== 进度上报 & 会话保活 =====
  startProgressReporting() {
    if (!this.activeEngine || this._reportedStart) return;
    this._reportedStart = true;
    if (!this.isMpv()) this.measure('first_frame', { elapsedMs: performance.now() - this._openedAt });
    this.lastProgressReport = Date.now();
    this.sendSnapshot('start', this.snapshot()).catch(() => {});
    const generation = this.generation;
    this.progressTimer = setInterval(() => {
      if (generation !== this.generation || !this.activeEngine || this._ended) return;
      this.lastProgressReport = Date.now();
      this.sendSnapshot('progress', this.snapshot()).catch(() => {});
    }, 10000);
  },

  stopProgressReporting() {
    if (this.progressTimer) clearInterval(this.progressTimer);
    this.progressTimer = null;
  },

  startSessionPing() {
    this.stopSessionPing();
    const sid = this.sessionId;
    if (!sid) return;
    this.pingTimer = setInterval(() => {
      if (this.sessionId !== sid) return;
      API.sessionPing(sid).catch((error) => {
        if (this.sessionId === sid && error.status === 404 && typeof App !== 'undefined') {
          App.onPlaybackNetworkDead('播放会话已失效，正在重连');
        }
      });
    }, 30000);
  },

  stopSessionPing() {
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = null;
  },

  reportPlaybackEnd() {
    if (!this.activeEngine || this._ended) return;
    const position = this.engPos();
    const duration = this.engDuration();
    if (duration > 0 && duration - position > 5) {
      if (typeof App !== 'undefined') App.onPlaybackNetworkDead('视频提前结束，正在恢复播放');
      return;
    }
    this._ended = true;
    this.measure('ended');
    this._buffering = false;
    this.stopProgressReporting();
    this.stopSessionPing();
    if (duration > 0) {
      if (this.isMpv() && this.mpvState) this.mpvState.time = Math.max(0, duration - this.originMs / 1000);
      else if (this.video && Number.isFinite(this.video.duration)) this.video.currentTime = Math.max(0, duration - this.originMs / 1000);
    }
    const snapshot = this.snapshot();
    if (this._reportedStart) {
      this.sendSnapshot('stop', snapshot).then(() => {
        window.dispatchEvent(new CustomEvent('movieclaw:playback-stopped', { detail: snapshot }));
      }).catch(() => {});
      this._reportedStart = false;
    }
    if (this.sessionId) API.sessionStop(this.sessionId).catch(() => {});
    this.sessionId = null;
    this.showIcon('play');
    this.showControls();
    if (typeof App !== 'undefined') App.onPlaybackEnded();
  },

  reportPlaybackStop() {
    if (!this._reportedStart) return Promise.resolve();
    return this.sendSnapshot('stop', this.snapshot());
  },

  formatTime(secs) {
    if (!secs || isNaN(secs)) return '0:00';
    const h = Math.floor(secs / 3600);
    const m = Math.floor((secs % 3600) / 60);
    const s = Math.floor(secs % 60);
    if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
    return `${m}:${String(s).padStart(2, '0')}`;
  },
};

// DOM 加载后初始化
document.addEventListener('DOMContentLoaded', () => Player.init());
window.__MOVIECLAW_SHUTDOWN__ = async () => {
  try { await Player.close(); }
  finally { await window.__TAURI__?.core?.invoke('complete_shutdown'); }
};
