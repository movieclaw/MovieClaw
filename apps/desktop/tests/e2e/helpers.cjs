const { expect } = require('@playwright/test');

// Browser tests exercise the shipped DOM and HTTP contract. This bridge is deliberately a
// fixture: native WebView2, Win32 child-window rendering and hardware decode need Windows.
async function openDesktop(page, request, options = {}) {
  await request.post('/__test/reset', { data: options });
  await page.addInitScript(({ native, nativeAuth, updater }) => {
    window.__fixture = { calls: [], windows: [], running: false, instanceId: null,
      props: { 'time-pos': 21, duration: 3300, pause: false, 'eof-reached': false,
        'video-out-params': { w: 1280, h: 720 }, 'demuxer-cache-duration': 30 } };
    const pending = new Map();
    const listeners = new Map();
    window.__fixture.emit = (name, payload) => listeners.get(name)?.({ payload });
    window.__TAURI__ = {
      event: { listen: async (name, fn) => { listeners.set(name, fn); return () => listeners.delete(name); } },
      window: { getCurrentWindow: () => ({
        ...Object.fromEntries(['minimize', 'toggleMaximize', 'close'].map(name => [name, async () => window.__fixture.windows.push(name)])),
        isFullscreen: async () => !!window.__fixture.fullscreen,
        setFullscreen: async value => {
          const f = window.__fixture;
          f.windows.push({ name: 'setFullscreen', value });
          if (f.fullscreenDelay) await new Promise(resolve => setTimeout(resolve, f.fullscreenDelay));
          f.fullscreen = value;
        },
      }) },
      core: { invoke: async (command, args = {}) => {
        const f = window.__fixture;
        f.calls.push({ command, args });
        if (command === 'get_server_url') return location.origin;
        if (command === 'get_app_version') return '0.2.111';
        if (command === 'get_about_info') return {version:'1.0.0',revision:'a'.repeat(40),components:[{name:'mpv — GPL',source:'https://github.com/mpv-player/mpv',text:'GNU GENERAL PUBLIC LICENSE\n<img src=x onerror=alert(1)> fixture license'}]};
        if (updater && ['check_for_updates', 'download_update', 'cancel_update_download', 'install_downloaded_update', 'open_downloaded_update', 'open_release_page'].includes(command)) {
          let fixtureDownloadId;
          if (command === 'download_update') {
            const start = await fetch('/__test/update/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
            const initial = await start.json(); fixtureDownloadId = initial.downloadId;
            f.emit('movieclaw:update-progress', { ...initial, version: args.version, state: 'downloading', received: 0, total: 0 });
          }
          const response = await fetch('/__test/update', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command, args, fixtureDownloadId }) });
          const result = await response.json();
          if (!response.ok) {
            if (command === 'download_update') f.emit('movieclaw:update-progress', { downloadId: fixtureDownloadId, version: args.version, state: result.code === 'DOWNLOAD_CANCELLED' ? 'cancelled' : 'error', received: 0, total: 0 });
            throw JSON.stringify(result);
          }
          if (command === 'download_update') f.emit('movieclaw:update-progress', { downloadId: result.downloadId, version: args.version, state: 'ready', received: result.size, total: result.size });
          return result;
        }
        if (command.startsWith('native_') && nativeAuth) {
          const response = await fetch('/__test/native', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command, args }) });
          if (!response.ok) throw JSON.stringify(await response.json());
          return response.json();
        }
        if (command === 'check_for_updates') return { has_update: false, message: '已是最新版本 (0.2.111)' };
        if (command === 'proxy_api') {
          const controller = new AbortController(); pending.set(args.requestId, controller);
          try {
            let target = args.path;
            if (target.startsWith('/__image__')) {
              const imagePath = new URLSearchParams(target.split('?')[1]).get('url');
              const response = await fetch('/__test/image?path=' + encodeURIComponent(imagePath || ''));
              return { status: response.status, body: await response.text(), headers: Object.fromEntries(response.headers) };
            }
            if (target.startsWith('/__stream__')) target = new URLSearchParams(target.split('?')[1]).get('url');
            const url = target.startsWith('http') ? target : location.origin + (target.startsWith('/api/') ? target : '/api/v1' + target);
            const response = await fetch(url, { method: args.method, body: args.body,
              signal: controller.signal, headers: { 'Content-Type': 'application/json', ...args.headers } });
            const binary = args.path.startsWith('/__stream__') && response.headers.get('Content-Type')?.includes('video/');
            const body = binary ? btoa(String.fromCharCode(...new Uint8Array(await response.arrayBuffer()))) : await response.text();
            return { status: response.status, body, headers: Object.fromEntries(response.headers) };
          } finally { pending.delete(args.requestId); }
        }
        if (command === 'cancel_proxy_request') { pending.get(args.requestId)?.abort(); return; }
        if (command === 'grant_media_stream') return { streamId: 'fixture-' + f.calls.length, url: args.url };
        if (command === 'release_media_stream') return;
        if (command === 'has_embedded_player') return native;
        if (command === 'begin_native_playback') { f.platform = { ...args, active: true }; return { active: true, smtcAvailable: true, sequence: args.sequence }; }
        if (command === 'update_native_playback') {
          if (f.platform?.sequence === args.update.sequence) f.platform = { ...f.platform, ...args.update };
          return { active: true, smtcAvailable: true, sleepInhibited: !args.update.paused, sequence: args.update.sequence };
        }
        if (command === 'end_native_playback') { if (f.platform?.sequence === args.sequence) f.platform.active = false; return; }
        if (command === 'set_native_picture_in_picture') {
          if (f.platform?.sequence !== args.sequence) throw new Error('stale playback');
          if (args.enabled) { f.pipBeforeFullscreen = !!f.fullscreen; f.fullscreen = false; }
          else f.fullscreen = !!f.pipBeforeFullscreen;
          f.platform.pictureInPicture = args.enabled;
          return {...f.platform};
        }
        if (command === 'get_main_window_hwnd') return 1;
        if (command === 'launch_embedded_player') { f.running = true; f.instanceId = args.instanceId; return; }
        if (command === 'stop_embedded_player') {
          if (args.instanceId == null || args.instanceId === f.instanceId) f.running = false;
          return;
        }
        if (command === 'get_embedded_player_status') return { running: f.running && (args.instanceId == null || args.instanceId === f.instanceId), exit_code: null };
        if (command === 'get_embedded_player_state') return { status: { running: f.running && (args.instanceId == null || args.instanceId === f.instanceId), exit_code: null }, properties: f.props };
        if (command === 'send_mpv_command_embedded') {
          const c = args.command;
          if (c[0] === 'get_property') return { data: f.props[c[1]] ?? 0 };
          if (c[0] === 'set_property') f.props[c[1]] = c[2];
          if (c[0] === 'seek') f.props['time-pos'] = c[1];
          return { data: null };
        }
        if (['resize_embedded_player', 'set_embedded_player_visible', 'complete_shutdown', 'clear_server_url'].includes(command)) return;
        throw new Error('Unexpected fixture command: ' + command);
      } },
    };
  }, { native: options.native !== false, nativeAuth: options.nativeAuth || false, updater: options.updater || false });
  await page.goto('/desktop/index.html');
}
async function state(request) { return (await request.get('/__test/state')).json(); }
async function browseLibrary(page) {
  await page.locator('#libraryNav [data-library-id="1"]').click();
  await expect(page.locator('#posterGrid .poster-card')).toHaveCount(60);
}

module.exports = { openDesktop, state, browseLibrary };
