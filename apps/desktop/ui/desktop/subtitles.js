// Detail-page tracks and NAS subtitle jobs share the page's account/request lifetime.
window.DesktopSubtitles = (() => {
  const unwrap = value => value?.data ?? value;
  const languages = [['chs','简体中文'],['cht','繁体中文'],['eng','英语'],['jpn','日语'],['kor','韩语'],['fre','法语'],['ger','德语'],['spa','西班牙语'],['ita','意大利语'],['por','葡萄牙语'],['rus','俄语'],['tha','泰语']];
  const active = new Set(['queued','running','retry_wait','waiting','cancelling','blocked']);
  const states = {queued:'排队中',running:'正在生成',retry_wait:'等待重试',waiting:'等待处理',blocked:'需要处理',cancelling:'正在取消',cancelled:'已取消',failed:'生成失败',succeeded:'生成完成'};
  const language = value => ({zh:'中文',chi:'中文',zho:'中文',cmn:'中文',en:'英语',ja:'日语',ko:'韩语',fr:'法语',fra:'法语',de:'德语',deu:'德语'}[value] || languages.find(([code]) => code === value)?.[1] || value || '未知语言');
  const aiSubtitle = stream => /(?:^|[ ._-])ai(?:$|[ ._-])/i.test([stream.title,stream.file_name].filter(Boolean).join(' '));
  function tracks(file) {
    return {
      audio: (file?.audio_streams || []).map((stream,index) => ({
        ref:`embedded:${index}`, label:[language(stream.language),stream.profile || stream.codec?.toUpperCase(),stream.channel_layout || (stream.channels ? `${stream.channels} 声道` : null),stream.title].filter(Boolean).join(' · '),
      })),
      subtitles: (file?.subtitle_streams || []).map((stream,index) => ({
        ref:stream.external ? (stream.file_name ? `external:${stream.file_name}` : null) : `embedded:${index}`,
        label:[language(stream.language),stream.codec?.toUpperCase(),stream.external ? '外挂' : '内封',aiSubtitle(stream) ? 'AI' : null,stream.forced ? '强制' : null,stream.title || stream.file_name].filter(Boolean).join(' · '),
      })).filter(track => track.ref),
    };
  }
  const option = (value,label,selected,disabled=false) => `<option value="${escapeHtml(value)}" ${value === selected ? 'selected' : ''} ${disabled ? 'disabled' : ''}>${escapeHtml(label)}</option>`;
  const retryable = job => ['failed','cancelled'].includes(job?.status) && !job.cancel_requested_by?.startsWith('system:');
  let panel;
  class DetailSubtitles {
    constructor(options) {
      Object.assign(this,options);
      this.admin = this.session?.role === 'admin';
      this.revision = 0; this.files = []; this.audio = ''; this.subtitle = '';
      this.target = 'chs'; this.secondary = ''; this.source = '';
      this.refreshed = new Set();
      this.signal?.addEventListener('abort', () => this.dispose(), {once:true});
    }
    current(revision = this.revision) { return !this.disposed && this.alive() && revision === this.revision; }
    setFiles(files,key) {
      if (!this.current()) return;
      const changed = key !== this.key;
      const id = changed ? files[0]?.id : files.find(file => Number(file.id) === Number(this.file?.id))?.id ?? files[0]?.id;
      this.files = files; this.key = key;
      if (changed || Number(id) !== Number(this.file?.id)) {
        this.closeDialog(); clearTimeout(this.pollTimer); this.revision++;
        this.audio = ''; this.subtitle = ''; this.source = ''; this.job = null; this.jobError = ''; this.busy = false;
        this.file = files.find(file => Number(file.id) === Number(id));
        this.render();
        if (this.file && this.admin) this.restoreJob();
      } else { this.file = files.find(file => Number(file.id) === Number(id)); this.render(); }
    }
    selection(key) {
      if (!this.file || key !== this.key) return {};
      const available = tracks(this.file);
      return {file_id:this.file.id,
        ...(available.audio.some(track => track.ref === this.audio) ? {audio_track:this.audio} : {}),
        ...(this.subtitle === 'off' || available.subtitles.some(track => track.ref === this.subtitle) ? {subtitle_track:this.subtitle} : {}),
      };
    }
    render() {
      if (!this.current() || !this.host) return;
      if (!this.file) { this.host.innerHTML = ''; return; }
      const available = tracks(this.file), defaults = this.file.playback_defaults;
      this.host.innerHTML = `<h2 class="shelf-title">音轨与字幕</h2><div class="detail-track-card">
        <label>播放版本<select class="settings-select" id="detailFile" aria-label="播放版本">${this.files.map(file => option(String(file.id),[file.resolution,file.hdr,file.video_codec?.toUpperCase(),file.file_name || `版本 ${file.id}`].filter(Boolean).join(' · '),String(this.file.id))).join('')}</select></label>
        <div class="detail-track-grid"><label>音轨<select class="settings-select" id="detailAudio" aria-label="音轨">${option('','自动选择',this.audio)}${available.audio.map(track => option(track.ref,track.label + (defaults?.audio_track === track.ref ? ' · 默认' : ''),this.audio)).join('')}</select><small>${escapeHtml(defaults?.audio_note || (this.file.audio_streams == null ? '音轨尚未探测，播放时自动识别' : available.audio.length ? '播放后也可切换音轨' : '未发现音轨'))}</small></label>
        <label>字幕<select class="settings-select" id="detailSubtitle" aria-label="字幕">${option('','自动选择',this.subtitle)}${option('off','关闭字幕',this.subtitle)}${available.subtitles.map(track => option(track.ref,track.label + (defaults?.subtitle_track === track.ref ? ' · 默认' : ''),this.subtitle)).join('')}</select><small>${escapeHtml(defaults?.subtitle_note || '内封和外挂字幕均可选择')}</small></label></div>
        <div class="subtitle-job-summary">${this.admin ? `<button class="btn-secondary" id="subtitleGenerate" ${this.busy ? 'disabled' : ''}>${escapeHtml(this.job ? states[this.job.status] || 'AI 字幕' : 'AI 生成字幕')}</button><span id="subtitleJobSummary">${escapeHtml(this.jobError || this.job?.progress?.message || '在服务器上生成，可选择单语或双语字幕')}</span>` : '<span>AI 字幕生成需要管理员账号</span>'}</div>
        <div class="generated-subtitles">${available.subtitles.filter(track => aiSubtitle((this.file.subtitle_streams || []).find((stream,index) => (stream.external ? `external:${stream.file_name}` : `embedded:${index}`) === track.ref) || {})).map(track => `<button class="text-button" data-use-subtitle="${escapeHtml(track.ref)}">使用 ${escapeHtml(track.label)}</button>`).join('')}</div>
      </div>`;
      this.host.querySelector('#detailFile').addEventListener('change', event => {
        const id = Number(event.target.value);
        this.file = null;
        // The selected version leads this unit's files without changing other units.
        this.setFiles([...this.files].sort((a,b) => Number(b.id === id) - Number(a.id === id)),this.key);
      });
      this.host.querySelector('#detailAudio').addEventListener('change', event => { this.audio = event.target.value; });
      this.host.querySelector('#detailSubtitle').addEventListener('change', event => { this.subtitle = event.target.value; });
      this.host.querySelector('#subtitleGenerate')?.addEventListener('click', () => this.open());
      this.host.querySelectorAll('[data-use-subtitle]').forEach(button => button.addEventListener('click', () => this.useSubtitle(button.dataset.useSubtitle)));
      DesktopSelect.enhance(this.host);
    }
    renderJob() {
      if (!this.current()) return;
      const button = this.host.querySelector('#subtitleGenerate');
      if (button) { button.textContent = this.job ? states[this.job.status] || 'AI 字幕' : 'AI 生成字幕'; button.disabled = !!this.busy; }
      const summary = this.host.querySelector('#subtitleJobSummary');
      if (summary) summary.textContent = this.jobError || this.job?.progress?.message || '在服务器上生成，可选择单语或双语字幕';
    }
    async useSubtitle(ref) {
      this.subtitle = ref; this.render();
      if (Player.activeEngine && Number(Player.sessionData?.source?.file_id || Player.sessionData?.decision?.file_id || Player.context?.file_id) === Number(this.file.id)) {
        const index = Player.sessionData?.decision?.subtitles?.findIndex(plan => plan.track_ref === ref) ?? -1;
        if (index >= 0) await Player.selectSubtitle(index);
        else await App.restartPlaybackAt(Math.floor(Player.engPos()*1000), {file_id:this.file.id,subtitle_track:ref,__subtitleTouched:true});
      } else App.notice('已选择字幕，播放时使用');
    }
    async restoreJob() {
      const revision = this.revision, request = this.jobRequest = (this.jobRequest || 0)+1;
      try {
        const response = unwrap(await this.api.subtitleJobs(this.file.id));
        if (!this.current(revision) || request !== this.jobRequest) return;
        const jobs = (response?.items || []).filter(job => job.job_type === 'subtitle.generate' &&
          (Number(job.input_data?.file_id) === Number(this.file.id) || job.resources?.some(resource => resource.resource_type === 'library_file' && String(resource.resource_id) === String(this.file.id))));
        this.setJob(jobs.find(job => active.has(job.status)) || jobs[0] || null);
      } catch(error) { if (this.current(revision) && request === this.jobRequest && error.name !== 'AbortError') { this.jobError = '暂时无法读取生成任务：' + error.message; this.render(); } }
    }
    setJob(job) {
      const previous = this.job;
      this.job = job; this.jobError = ''; this.jobEpoch = (this.jobEpoch || 0)+1; this.renderJob();
      if (this.dialog && this.mode === 'status') this.renderDialog();
      clearTimeout(this.pollTimer);
      if (job?.status === 'succeeded' && previous?.id === job.id && previous.status !== 'succeeded' && !this.refreshed.has(job.id)) {
        this.refreshed.add(job.id);
        const revision = this.revision;
        this.refresh().catch(error => { if (this.current(revision)) { this.jobError = '字幕已生成，列表刷新失败：' + error.message; this.render(); } });
      }
      if (job && active.has(job.status)) this.schedulePoll();
    }
    schedulePoll() {
      clearTimeout(this.pollTimer);
      const revision = this.revision, id = this.job?.id, epoch = this.jobEpoch;
      this.pollTimer = setTimeout(async () => {
        if (!this.current(revision) || this.job?.id !== id || this.jobEpoch !== epoch) return;
        try {
          const job = unwrap(await this.api.getJob(id));
          if (this.current(revision) && this.job?.id === id && this.jobEpoch === epoch) this.setJob(job);
        } catch(error) {
          if (!this.current(revision) || this.jobEpoch !== epoch || error.name === 'AbortError') return;
          this.jobError = '进度暂时无法更新：' + error.message;
          this.renderJob(); if (this.mode === 'status') this.renderDialog(); this.schedulePoll();
        }
      },2000);
    }
    async open() {
      if (!this.file || !this.admin || this.busy || this.dialog) return;
      this.dialog = document.createElement('dialog');
      this.dialog.id = 'subtitleDialog'; this.dialog.className = 'subtitle-dialog';
      this.dialog.setAttribute('aria-label','AI 字幕');
      document.body.appendChild(this.dialog);
      this.dialog.addEventListener('cancel', event => { event.preventDefault(); this.closeDialog(); });
      this.dialog.addEventListener('click', event => { if (event.target === this.dialog) this.closeDialog(); });
      this.mode = this.job ? 'status' : 'preview'; this.error = '';
      this.dialog.showModal();
      if (this.mode === 'status') this.renderDialog(); else await this.preview();
    }
    closeDialog() {
      this.previewController?.abort(); clearTimeout(this.previewTimer);
      this.previewRequest = (this.previewRequest || 0)+1;
      if (this.dialog?.contains(DesktopSelect.trigger)) DesktopSelect.close();
      this.dialog?.close(); this.dialog?.remove(); this.dialog = null;
    }
    params() { return {target_language:this.target,secondary_language:this.secondary || null,source_candidate_key:this.source || null}; }
    async preview() {
      this.previewController?.abort(); clearTimeout(this.previewTimer);
      const controller = this.previewController = new AbortController();
      const revision = this.revision, request = this.previewRequest = (this.previewRequest || 0)+1;
      const valid = () => this.current(revision) && this.dialog && request === this.previewRequest && !controller.signal.aborted;
      this.mode = 'preview'; this.loading = true; this.error = ''; this.previewData = null; this.ocrLanguage = '';
      this.renderDialog();
      try {
        const [preview,providers] = await Promise.all([this.api.subtitlePreview(this.file.id,this.params(),controller.signal),this.api.llmProviders().catch(() => null)]);
        if (!valid()) return;
        this.previewData = unwrap(preview); this.providersMissing = providers !== null && unwrap(providers)?.length === 0;
        this.source = this.previewData.selected_source_key || this.previewData.chosen_key || '';
        this.ocrLanguage = this.previewData.pgs_conversion?.ocr_language || '';
        if (this.previewData.pending) this.previewTimer = setTimeout(() => { if (valid()) this.preview(); },Math.max(1000,Math.min(10000,this.previewData.pending.retry_after_ms || 2500)));
      } catch(error) { if (valid()) this.error = [404,405].includes(error.status) ? '服务器暂不支持 AI 字幕接口，请升级服务器后重试。' : error.message; }
      finally { if (valid()) { this.loading = false; this.renderDialog(); } }
    }
    canStart() {
      const p = this.previewData, ocr = p?.pgs_conversion;
      return !this.loading && !this.busy && !this.providersMissing && !!p && !p.pending && !!this.source &&
        (!this.secondary || this.secondary !== this.target) &&
        (!p.blocker || p.blocker.code === 'pgs_conversion_required' && ocr?.available && !!this.ocrLanguage);
    }
    renderDialog() {
      if (!this.current() || !this.dialog) return;
      if (this.dialog.contains(DesktopSelect.trigger)) DesktopSelect.close();
      const p = this.previewData, job = this.job, status = this.mode === 'status';
      const percent = Number(job?.progress?.percent), hasPercent = job?.progress?.percent != null && Number.isFinite(percent);
      const body = status ? `<div class="subtitle-status" role="status"><h3>${escapeHtml(states[job?.status] || '生成任务')}</h3>
        <p>${escapeHtml(job?.progress?.message || '')}</p><progress ${hasPercent ? `value="${Math.max(0,Math.min(100,percent))}"` : ''} max="100" aria-label="字幕生成进度"></progress>
        ${hasPercent ? `<span>${Math.round(percent)}%</span>` : ''}
        <p>${escapeHtml(job?.error?.message || this.jobError || '')}</p>
        ${job?.status === 'succeeded' ? '<p>字幕已保存到服务器，关闭窗口后可在字幕列表中选择。</p>' : '<p>关闭此窗口后，任务仍在服务器上执行。</p>'}
        </div>` : `<div class="subtitle-options">
        <label>目标语言<select class="settings-select" id="subtitleTarget" aria-label="目标语言">${languages.map(([code,name]) => option(code,name,this.target)).join('')}</select></label>
        <label>输出形式<select class="settings-select" id="subtitleSecondary" aria-label="输出形式">${option('','单语字幕',this.secondary)}${languages.map(([code,name]) => option(code,'双语 · '+name,this.secondary,code===this.target)).join('')}</select></label>
        <label class="subtitle-source">参考字幕<select class="settings-select" id="subtitleSource" aria-label="参考字幕" ${this.loading ? 'disabled' : ''}>${!p?.candidates?.length ? option('','暂无可用参考字幕','') : p.candidates.map(candidate => option(`${candidate.kind}:${candidate.key}`,[language(candidate.language),candidate.format,candidate.requires_ocr ? '需要 OCR' : null,candidate.excluded, ...(candidate.reasons || [])].filter(Boolean).join(' · '),this.source,!candidate.selectable)).join('')}</select></label>
        </div><div class="subtitle-preview" role="status">${this.loading ? '<p>正在检查参考字幕与生成条件…</p>' : ''}
        ${p ? `<p>${escapeHtml(p.output_filename || '')}</p><p>预计 ${Number(p.estimated_tokens || 0).toLocaleString()} tokens · ${Number(p.event_count || 0)} 条字幕</p>${p.reference_notice ? `<p>${escapeHtml(p.reference_notice)}</p>` : ''}${p.already_generated ? '<p class="subtitle-warning">已有相同输出字幕，本次生成将覆盖它。</p>' : ''}${(p.warnings || []).map(warning => `<p>${escapeHtml(warning)}</p>`).join('')}${p.pending ? `<p>${escapeHtml(p.pending.message)}</p>` : ''}${p.blocker ? `<p>${escapeHtml(p.blocker.title)}：${escapeHtml(p.blocker.message)}</p>${(p.blocker.suggestions || []).map(suggestion => `<p>${escapeHtml(suggestion)}</p>`).join('')}` : ''}` : ''}
        ${p?.pgs_conversion?.available ? `<label>图片字幕原始语言<select class="settings-select" id="subtitleOcr" aria-label="图片字幕原始语言">${option('','请选择图片字幕语言',this.ocrLanguage)}${(p.pgs_conversion.language_options || []).map(value => option(value.code,value.label,this.ocrLanguage)).join('')}</select></label>` : ''}
        ${this.providersMissing ? '<p>服务器尚未配置 AI 模型。</p><button class="btn-secondary" id="subtitleWebSettings">打开 Web AI 设置</button>' : ''}</div>`;
      this.dialog.innerHTML = `<div class="subtitle-dialog-header"><h2>AI 字幕</h2><button class="panel-close" id="subtitleClose" aria-label="关闭">×</button></div>
        <p class="subtitle-file-name">${escapeHtml(this.file.file_name || `文件 ${this.file.id}`)}</p>${body}
        <p class="subtitle-error" role="alert">${escapeHtml(this.error || '')}</p>
        <div class="subtitle-dialog-actions"><button class="btn-secondary" id="subtitleDismiss">关闭</button>
        ${status ? `${active.has(job?.status) && job.status !== 'cancelling' ? `<button class="btn-secondary" id="subtitleCancel" ${this.busy ? 'disabled' : ''}>取消任务</button>` : ''}${retryable(job) ? `<button class="btn-secondary" id="subtitleRetry" ${this.busy ? 'disabled' : ''}>重试任务</button>` : ''}${!active.has(job?.status) ? '<button class="btn-secondary" id="subtitleNew">重新选择生成</button>' : ''}` : `<button class="btn-secondary" id="subtitlePreviewRetry" ${this.busy ? 'disabled' : ''}>重新检查</button><button class="btn-play" id="subtitleStart" ${this.canStart() ? '' : 'disabled'}>${this.busy ? '正在提交…' : '确认生成'}</button>`}</div>`;
      this.dialog.querySelector('#subtitleClose').onclick = () => this.closeDialog();
      this.dialog.querySelector('#subtitleDismiss').onclick = () => this.closeDialog();
      for (const [id,field] of [['subtitleTarget','target'],['subtitleSecondary','secondary'],['subtitleSource','source']]) {
        this.dialog.querySelector('#'+id)?.addEventListener('change', event => {
          this[field] = event.target.value;
          if (field === 'target' && this.secondary === this.target) this.secondary = '';
          if (field !== 'source') this.source = '';
          this.preview();
        });
      }
      this.dialog.querySelector('#subtitleOcr')?.addEventListener('change', event => { this.ocrLanguage = event.target.value; this.renderDialog(); });
      this.dialog.querySelector('#subtitleWebSettings')?.addEventListener('click', async () => {
        try { await window.__TAURI__.core.invoke('open_server_ai_settings'); } catch(error) { this.error = '无法打开 Web 设置：' + (error.message || error); this.renderDialog(); }
      });
      this.dialog.querySelector('#subtitleStart')?.addEventListener('click', () => this.start());
      this.dialog.querySelector('#subtitlePreviewRetry')?.addEventListener('click', () => this.preview());
      this.dialog.querySelector('#subtitleCancel')?.addEventListener('click', () => this.jobAction('cancelJob'));
      this.dialog.querySelector('#subtitleRetry')?.addEventListener('click', () => this.jobAction('retryJob'));
      this.dialog.querySelector('#subtitleNew')?.addEventListener('click', () => this.preview());
      DesktopSelect.enhance(this.dialog);
    }
    async start() {
      if (!this.canStart()) return;
      const revision = this.revision, fileId = this.file.id;
      const payload = {...this.params(),convert_pgs:this.previewData.blocker?.code === 'pgs_conversion_required',pgs_ocr_language:this.ocrLanguage || null};
      this.busy = true; this.jobRequest = (this.jobRequest || 0)+1; this.renderDialog(); this.renderJob();
      try {
        const job = unwrap(await this.api.generateSubtitles(fileId,payload));
        if (!this.current(revision)) return;
        this.mode = 'status'; this.error = ''; this.setJob(job);
      } catch(error) { if (this.current(revision)) this.error = error.message; }
      finally { if (this.current(revision)) { this.busy = false; this.renderJob(); this.renderDialog(); } }
    }
    async jobAction(method) {
      if (this.busy || !this.job || method === 'retryJob' && !retryable(this.job)) return;
      const revision = this.revision, id = this.job.id;
      clearTimeout(this.pollTimer); this.jobEpoch = (this.jobEpoch || 0)+1;
      this.busy = true; this.jobRequest = (this.jobRequest || 0)+1; this.error = ''; this.renderDialog();
      try {
        const result = unwrap(await this.api[method](id));
        if (this.current(revision) && this.job?.id === id) this.setJob(result.job || result);
      } catch(error) { if (this.current(revision)) this.error = error.message; }
      finally { if (this.current(revision)) { this.busy = false; this.renderJob(); this.renderDialog(); if (active.has(this.job?.status)) this.schedulePoll(); } }
    }
    dispose() { this.disposed = true; this.revision++; clearTimeout(this.pollTimer); this.closeDialog(); }
  }
  return {tracks,aiSubtitle,retryable,
    mount(options) { panel?.dispose(); panel = new DetailSubtitles(options); return panel; },
    dispose() { panel?.dispose(); panel = null; },
  };
})();
