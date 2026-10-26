// Windows platform lifecycle is attached to actual first-frame/end events for both engines.
// The native bridge receives metadata and a session identity, never a media URL or token.
(() => {
  const bridge = () => window.__TAURI__?.core;
  let current = null, lastSequence = 0;
  const api = window.MovieClawPlatform = {
    status: null,
    start(player) {
      this.stop();
      if (!bridge() || !player.activeEngine) return;
      const sequence = lastSequence = Math.max(lastSequence + 1, Date.now() * 1024);
      const state = current = { player, generation: player.generation, sequence,
        instanceId: 'playback-' + sequence, pending: false, ready: false };
      const title = document.getElementById('playerTitle')?.textContent || 'MovieClaw';
      bridge().invoke('begin_native_playback', { instanceId: state.instanceId, sequence, title })
        .then(status => {
          if (current !== state) return bridge().invoke('end_native_playback', { instanceId: state.instanceId, sequence });
          state.ready = true; this.status = status; this.update();
          state.timer = setInterval(() => this.update(), 1000);
        }).catch(() => { if (current === state) this.status = { active: false, error: 'PLATFORM_UNAVAILABLE' }; });
    },
    update() {
      const state = current;
      if (!state?.ready || state.pending) return;
      const player = state.player;
      if (!player.activeEngine || player.generation !== state.generation || player._ended) { this.stop(); return; }
      const dimensions = player.mpvState?.properties?.['video-out-params'] || {};
      const number = value => Number.isFinite(Number(value)) ? Math.max(0, Math.floor(Number(value))) : 0;
      const update = { instanceId: state.instanceId, sequence: state.sequence,
        paused: player.engPaused(), positionMs: number(player.engPos() * 1000), durationMs: number(player.engDuration() * 1000),
        width: number(dimensions.dw || dimensions.w || player.video?.videoWidth),
        height: number(dimensions.dh || dimensions.h || player.video?.videoHeight), rate: player.engRate(),
        alwaysOnTop: localStorage.getItem('mc_alwaysOnTop') !== 'false',
        fitWindow: localStorage.getItem('mc_fitWindow') !== 'false' };
      state.pending = true;
      bridge().invoke('update_native_playback', { update }).then(status => {
        if (current === state) this.status = status;
      }).catch(() => {}).finally(() => { state.pending = false; });
    },
    stop() {
      const state = current; current = null; this.status = null;
      if (state) {
        state.player.nativePip = false;
        document.getElementById('playerView')?.classList.remove('native-pip');
      }
      if (!state) return Promise.resolve();
      clearInterval(state.timer);
      return bridge()?.invoke('end_native_playback', { instanceId: state.instanceId, sequence: state.sequence }).catch(() => {});
    },
    async pictureInPicture(enabled) {
      const state = current;
      if (!state?.ready) throw new Error('播放器尚未就绪');
      const status = await bridge().invoke('set_native_picture_in_picture', {
        instanceId: state.instanceId, sequence: state.sequence, enabled,
      });
      if (current !== state || state.player.generation !== state.generation) return null;
      this.status = status;
      return status;
    },
    command(payload) {
      const state = current;
      if (!state || payload.instanceId !== state.instanceId || payload.sequence !== state.sequence
          || state.player.generation !== state.generation || !state.player.activeEngine) return;
      const player = state.player;
      switch (payload.action) {
        case 'play': if (player.engPaused()) player.togglePlay(); break;
        case 'pause': if (!player.engPaused()) player.togglePlay(); break;
        case 'stop': player.close(); break;
        case 'previous': player.playEpisode(player.prevEpisode()); break;
        case 'next': player.playEpisode(player.nextEpisode()); break;
        case 'forward': player.engSeekBy(10); break;
        case 'rewind': player.engSeekBy(-10); break;
        case 'seek': if (Number.isFinite(payload.positionMs)) player.engSeekTo(Math.max(0, payload.positionMs) / 1000); break;
        default: return;
      }
      this.update();
    },
  };
  window.addEventListener('movieclaw:playback-measurement', event => {
    if (event.detail.event === 'first_frame' && typeof Player !== 'undefined') api.start(Player);
    else if (event.detail.event === 'closed' || event.detail.event === 'ended') api.stop();
  });
  window.addEventListener('beforeunload', () => api.stop());
  document.addEventListener('DOMContentLoaded', () => {
    const video = document.getElementById('playerVideo');
    for (const event of ['pause', 'play', 'ratechange', 'seeked']) video?.addEventListener(event, () => api.update());
  });
  window.__TAURI__?.event?.listen('movieclaw:media-command', event => api.command(event.payload)).catch(() => {});
  window.__TAURI__?.event?.listen('movieclaw:window-scale-changed', () => {
    if (typeof Player !== 'undefined') { Player._mpvRectSig = null; Player.syncEmbeddedPlayerRect(); }
  }).catch(() => {});
})();
