// Update packages are selected and verified by Rust. The UI never supplies URLs or paths.
window.DesktopUpdates = {
  phase: 'idle', info: null, download: null, progress: null, error: '', active: null,
  retiredIds: new Set(),
  retire(active) {
    if (!active?.id) return;
    this.retiredIds.add(active.id);
    while (this.retiredIds.size > 32) this.retiredIds.delete(this.retiredIds.values().next().value);
  },
  text(value, limit = 1200) { return Array.from(typeof value === 'string' ? value : '').slice(0, limit).join(''); },
  releaseText(value) {
    // Release Markdown stays inert text; internal comments are not user instructions.
    return this.text((typeof value === 'string' ? value : '')
      .replace(/<!--[\s\S]*?-->/g, '')
      .replace(/^#{1,6}\s+/gm, '')
      .replace(/`([^`]+)`/g, '$1')
      .replace(/\*\*([^*]+)\*\*/g, '$1')
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '$1')
      .trim());
  },
  errorText(error) {
    const raw = typeof error === 'string' ? error : error?.message || '';
    try { return this.text(JSON.parse(raw).message, 600) || '操作失败，请重试。'; }
    catch (_) { return this.text(raw, 600) || '操作失败，请重试。'; }
  },
  busy() { return ['checking', 'downloading', 'verifying', 'cancelling', 'installing'].includes(this.phase); },
  show(info) {
    if (this.busy()) return;
    this.retire(this.active);
    this.info = { has_update: info?.has_update === true, current_version: this.text(info?.current_version ?? info?.current, 128),
      latest_version: this.text(info?.latest_version ?? info?.version, 128), message: this.text(info?.message, 600), release_notes: this.releaseText(info?.release_notes) };
    this.phase = this.info.has_update ? 'available' : 'current';
    this.error = ''; this.download = null; this.progress = null; this.active = null;
    this.render(true);
  },
  async check() {
    if (this.busy() || ['ready', 'unsigned-confirmation'].includes(this.phase)) { this.render(true); return; }
    this.phase = 'checking'; this.error = ''; this.render(true);
    try {
      const info = await window.__TAURI__.core.invoke('check_for_updates');
      this.phase = 'idle'; this.show(info);
    } catch (error) { this.phase = 'error'; this.error = '检查更新失败：' + this.errorText(error); this.render(); }
  },
  async startDownload() {
    if (this.busy() || !this.info?.has_update || !this.info.latest_version) return;
    this.retire(this.active);
    const active = this.active = { version: this.info.latest_version, id: null, cancelRequested: false, cancelSent: false, terminal: false, settled: false };
    this.download = null; this.progress = null; this.error = ''; this.phase = 'downloading'; this.render(true);
    try {
      await this.eventsReady;
      const metadata = await window.__TAURI__.core.invoke('download_update', { version: active.version });
      active.settled = true;
      if (this.active !== active || active.terminal) return;
      if (active.cancelRequested) { this.finishCancelled(active); return; }
      if (!metadata?.downloadId || metadata.version !== active.version || !/^[a-f0-9]{64}$/i.test(metadata.sha256 || '')
          || !['valid', 'unsigned'].includes(metadata.signature) || !['nsis', 'portable'].includes(metadata.format)) {
        throw new Error('安装包校验结果不完整，无法安装。请从发布页面获取更新。');
      }
      active.id = metadata.downloadId; active.terminal = true; this.retire(active);
      this.download = { downloadId: metadata.downloadId, version: active.version, size: Math.max(0, Number(metadata.size) || 0),
        sha256: metadata.sha256, signature: metadata.signature, format: metadata.format,
        signer: metadata.signature === 'valid' ? this.text(metadata.signer, 256) : '', filename: this.text(metadata.filename, 256).split(/[\\/]/).pop() };
      this.phase = 'ready'; this.render();
    } catch (error) {
      active.settled = true;
      if (this.active !== active || active.terminal) return;
      if (active.cancelRequested) { this.finishCancelled(active); return; }
      active.terminal = true; this.retire(active); this.phase = 'error'; this.error = '下载或校验失败：' + this.errorText(error); this.render();
    }
  },
  onProgress(payload) {
    const active = this.active;
    if (!active || active.terminal || payload?.version !== active.version || !payload.downloadId
        || this.retiredIds.has(payload.downloadId)
        || (active.id && active.id !== payload.downloadId)) return;
    active.id = payload.downloadId;
    const received = Math.max(0, Number(payload.received) || 0), total = Math.max(0, Number(payload.total) || 0);
    const percent = total > 0 ? Math.min(100, received / total * 100) : Number(payload.percent);
    this.progress = { received, total, percent: Number.isFinite(percent) ? Math.max(0, Math.min(100, percent)) : null };
    if (payload.state === 'cancelled') { active.cancelRequested = true; this.phase = 'cancelling'; this.render(); return; }
    if (active.cancelRequested) { this.cancelNative(active); return; }
    // The command settles after native cleanup and carries the specific failure reason.
    if (payload.state === 'error') return;
    else if (['downloading', 'verifying', 'ready'].includes(payload.state)) this.phase = payload.state === 'downloading' ? 'downloading' : 'verifying';
    this.render();
  },
  cancel() {
    const active = this.active;
    if (!active || active.terminal || active.cancelRequested) return;
    active.cancelRequested = true; this.phase = 'cancelling'; this.render();
    if (active.id) this.cancelNative(active);
  },
  async cancelNative(active) {
    if (this.active !== active || active.cancelSent || !active.id) return;
    active.cancelSent = true;
    try {
      await window.__TAURI__.core.invoke('cancel_update_download', { downloadId: active.id });
      if (this.active !== active) return;
      if (active.settled) this.finishCancelled(active);
    } catch (error) {
      if (this.active !== active) return;
      this.phase = 'error'; this.error = '取消下载失败：' + this.errorText(error); this.render();
    }
  },
  finishCancelled(active) {
    if (this.active !== active || active.terminal || !active.settled) return;
    active.terminal = true; this.retire(active); this.phase = 'cancelled'; this.download = null; this.render();
  },
  async install(allowUnsigned = false) {
    if (!this.download || this.download.format !== 'nsis' || !['ready', 'unsigned-confirmation', 'error'].includes(this.phase)) return;
    if (this.download.signature === 'unsigned' && !allowUnsigned) { this.phase = 'unsigned-confirmation'; this.render(true); return; }
    this.phase = 'installing'; this.error = ''; this.render();
    try {
      if (typeof Player !== 'undefined') await Player.close();
      await window.__TAURI__.core.invoke('install_downloaded_update', { downloadId: this.download.downloadId, allowUnsigned });
    } catch (error) { this.phase = 'error'; this.error = '无法启动安装：' + this.errorText(error); this.render(); }
  },
  async releasePage() {
    try { await window.__TAURI__.core.invoke('open_release_page'); }
    catch (error) { this.error = '无法打开发布页面：' + this.errorText(error); this.phase = 'error'; this.render(); }
  },
  async showDownloadedFile() {
    if (!this.download) return;
    try { await window.__TAURI__.core.invoke('open_downloaded_update', { downloadId: this.download.downloadId }); }
    catch (error) { this.error = '无法显示下载文件：' + this.errorText(error); this.phase = 'error'; this.render(); }
  },
  bytes(value) { return value >= 1048576 ? (value / 1048576).toFixed(1) + ' MB' : Math.round(value / 1024) + ' KB'; },
  render(open = false) {
    let dialog = document.getElementById('desktopUpdateDialog');
    if (!dialog && !open) return;
    if (!dialog) {
      dialog = document.createElement('dialog'); dialog.id = 'desktopUpdateDialog'; dialog.className = 'desktop-update-dialog';
      dialog.addEventListener('close', () => dialog.remove(), { once: true }); document.body.append(dialog); dialog.showModal();
    }
    if (dialog.dataset.phase !== this.phase) {
      dialog.dataset.phase = this.phase; dialog.replaceChildren();
      const title = document.createElement('h2');
      title.textContent = ({ checking: '正在检查更新', available: '发现新版本', downloading: '正在下载更新', verifying: '正在校验更新',
        ready: '更新已准备', cancelling: '正在取消下载', cancelled: '下载已取消', installing: '正在启动安装',
        'unsigned-confirmation': '安装前确认', error: '更新失败' })[this.phase] || '检查更新';
      dialog.append(title);
      const message = document.createElement('p'); message.id = 'desktopUpdateMessage'; message.setAttribute('role', 'status'); dialog.append(message);
      if (this.info?.current_version || this.info?.latest_version) {
        const versions = document.createElement('p'); versions.className = 'update-versions';
        versions.textContent = [this.info.current_version && '当前 ' + this.info.current_version, this.info.latest_version && '最新 ' + this.info.latest_version.replace(/^windows-v/, '')].filter(Boolean).join(' · '); dialog.append(versions);
      }
      if (this.info?.release_notes && ['available', 'ready', 'current'].includes(this.phase)) {
        const notes = document.createElement('p'); notes.className = 'update-release-notes'; notes.textContent = this.info.release_notes; dialog.append(notes);
      }
      if (['downloading', 'verifying', 'cancelling'].includes(this.phase)) {
        const progress = document.createElement('progress'); progress.id = 'desktopUpdateProgress'; progress.max = 100; dialog.append(progress);
        const detail = document.createElement('p'); detail.id = 'desktopUpdateProgressText'; dialog.append(detail);
      }
      if (this.download && ['ready', 'unsigned-confirmation', 'error'].includes(this.phase)) {
        const metadata = document.createElement('div'); metadata.className = 'update-metadata';
        for (const text of [this.download.filename + ' · ' + this.bytes(this.download.size),
          'SHA-256 ' + this.download.sha256, this.download.signature === 'valid' ? '数字签名有效' + (this.download.signer ? ' · ' + this.download.signer : '') : '未提供数字签名']) {
          const row = document.createElement('p'); row.textContent = text; metadata.append(row);
        }
        dialog.append(metadata);
      }
      const actions = document.createElement('div'); actions.className = 'settings-actions';
      const button = (id, label, run, primary = false) => {
        const element = document.createElement('button'); element.id = id; element.className = primary ? 'btn-primary' : 'btn-secondary'; element.textContent = label;
        element.addEventListener('click', run); actions.append(element);
      };
      if (['available', 'cancelled'].includes(this.phase) || (this.phase === 'error' && this.info?.has_update)) button('updateDownload', this.download ? '重新下载并校验' : '下载并校验', () => this.startDownload(), true);
      if (this.phase === 'downloading' || this.phase === 'verifying') button('updateCancel', '取消下载', () => this.cancel());
      if (this.download?.format === 'nsis' && ['ready', 'error'].includes(this.phase)) button('updateInstall', '安装更新', () => this.install(), true);
      if (this.download?.format === 'portable' && ['ready', 'error'].includes(this.phase)) button('updateShowFile', '显示下载文件', () => this.showDownloadedFile(), true);
      if (this.phase === 'unsigned-confirmation') {
        button('updateConfirmUnsigned', '仍然安装未签名的更新', () => this.install(true), true);
        button('updateReturn', '返回', () => { this.phase = 'ready'; this.render(); });
      }
      if (this.phase === 'error' && !this.download) button('updateRetryCheck', '重新检查', () => this.check());
      if (this.info?.has_update && !['checking', 'downloading', 'verifying', 'cancelling', 'installing', 'unsigned-confirmation'].includes(this.phase)) button('updateRelease', '打开发布页面', () => this.releasePage());
      button('updateClose', ['downloading', 'verifying', 'cancelling'].includes(this.phase) ? '隐藏' : '关闭', () => dialog.close());
      dialog.append(actions);
    }
    const message = dialog.querySelector('#desktopUpdateMessage');
    message.textContent = this.phase === 'error' ? this.error : this.phase === 'unsigned-confirmation'
      ? 'SHA-256 校验已通过，但这个安装包没有数字签名，尚未验证发行者。继续会退出 MovieClaw 并启动安装程序。'
      : this.phase === 'ready' ? this.download?.format === 'portable'
        ? '便携版已通过校验。便携版需要手动安装：先显示下载文件，退出 MovieClaw 后将压缩包解压到应用目录。'
        : 'SHA-256 校验已通过。安装会退出 MovieClaw 并启动安装程序。'
      : this.phase === 'checking' ? '正在联系更新服务器…' : this.phase === 'downloading' ? '正在下载所选版本，下载后会校验完整性。'
      : this.phase === 'verifying' ? '正在核对 SHA-256 与数字签名，请稍候。' : this.phase === 'cancelling' ? '正在停止下载并清理临时文件…'
      : this.phase === 'cancelled' ? '下载已取消，可以重新下载。' : this.phase === 'installing' ? '正在保存播放状态并启动安装程序…'
      : this.info?.message || '检查完成';
    const progress = dialog.querySelector('#desktopUpdateProgress'), detail = dialog.querySelector('#desktopUpdateProgressText');
    if (progress) {
      if (this.progress?.percent != null) progress.value = this.progress.percent; else progress.removeAttribute('value');
      detail.textContent = this.progress ? this.bytes(this.progress.received) + (this.progress.total ? ' / ' + this.bytes(this.progress.total) : '') : '等待下载响应…';
    }
  },
};

window.DesktopUpdates.eventsReady = window.__TAURI__?.event?.listen ? Promise.all([
  window.__TAURI__.event.listen('update_available', event => window.DesktopUpdates.show({ ...event.payload, has_update: true })),
  window.__TAURI__.event.listen('update_check_result', event => window.DesktopUpdates.show(event.payload)),
  window.__TAURI__.event.listen('movieclaw:update-progress', event => window.DesktopUpdates.onProgress(event.payload)),
].map(promise => promise.catch(() => null))) : Promise.resolve();
