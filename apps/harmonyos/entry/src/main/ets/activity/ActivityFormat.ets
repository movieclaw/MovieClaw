/**
 * 活动页的展示格式化（逐条对齐 iOS 端 Features/Activity/TaskCenterLogic.swift 的
 * `ActivityFormat` 与 NowPlayingRows.swift 的 `WatchFormat`）。
 *
 * 只放纯函数：状态判断、分组、文案拼装都在下面，页面只管布局。
 */
import { Theme } from '../theme/AppTheme';
import { DownloadTaskView, JobView, MediaActivityTarget, PlaybackDeliveryView } from '../api/Models';

/** 秒 → 「45 秒」「15 分钟」「1.5 小时」（Web `formatDuration`） */
export class ActivityFormat {
  static rate(bytesPerSecond: number | null): string {
    if (bytesPerSecond === null || bytesPerSecond <= 0) {
      return '—';
    }
    return `${ActivityFormat.bytes(bytesPerSecond)}/s`;
  }

  /** 字节 → 「19.40 GB」；与 Formatters.bytes 同口径，这里只是为了少一次跨模块调用 */
  static bytes(value: number): string {
    if (!Number.isFinite(value) || value < 0) {
      return '—';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    let number: number = value;
    let index: number = 0;
    while (number >= 1024 && index < units.length - 1) {
      number /= 1024;
      index++;
    }
    const rounded: number = Math.round(number * 100) / 100;
    if (rounded >= 100 || index === 0) {
      return `${Math.round(rounded)} ${units[index]}`;
    }
    return `${rounded.toFixed(2)} ${units[index]}`;
  }

  /** 秒 → 「45 秒」「15 分钟」「1.5 小时」 */
  static duration(seconds: number): string {
    if (!Number.isFinite(seconds) || seconds <= 0) {
      return '—';
    }
    if (seconds < 60) {
      return `${Math.floor(seconds)} 秒`;
    }
    if (seconds < 3600) {
      return `${Math.round(seconds / 60)} 分钟`;
    }
    const hours: number = seconds / 3600;
    return hours === Math.round(hours) ? `${Math.round(hours)} 小时` : `${hours.toFixed(1)} 小时`;
  }

  /** 分钟 → 「2 小时 6 分钟」；不足一分钟按一分钟 */
  static runtime(minutes: number): string {
    if (!Number.isFinite(minutes) || minutes <= 0) {
      return '—';
    }
    const rounded: number = Math.round(minutes);
    if (rounded < 60) {
      return `${rounded} 分钟`;
    }
    const rest: number = rounded % 60;
    return rest > 0 ? `${Math.floor(rounded / 60)} 小时 ${rest} 分钟` : `${Math.floor(rounded / 60)} 小时`;
  }

  /** 毫秒观看时长 → 「2 小时 6 分钟」；零显示「—」 */
  static watched(ms: number): string {
    if (ms <= 0) {
      return '—';
    }
    return ActivityFormat.runtime(Math.max(1, Math.round(ms / 60000)));
  }

  /** 毫秒 → 播放器习惯的 h:mm:ss / m:ss */
  static playClock(ms: number): string {
    const total: number = Math.max(0, Math.floor(ms / 1000));
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const pad = (value: number): string => (value < 10 ? `0${value}` : `${value}`);
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
  }
}

/** 作品标题与设备名的拼装规则（iOS `WatchFormat`） */
export class WatchFormat {
  /** 剧集的 SxxEyy；电影返回 null */
  static unitLabel(media: MediaActivityTarget): string | null {
    if (media.kind !== 'tv') {
      return null;
    }
    const season: string = media.season_number < 10 ? `0${media.season_number}` : `${media.season_number}`;
    const episode: string = media.episode_number < 10 ? `0${media.episode_number}` : `${media.episode_number}`;
    return `S${season}E${episode}`;
  }

  /**
   * 客户端 · 设备名（对齐 Web `deviceLabel`）：自家客户端的「MovieClaw 」品牌前缀没有信息量，去掉；
   * 设备名里已有某段以客户端名打头时不再重复
   * （「Apple TV」+「Apple TV · tvOS 27.0」→「Apple TV · tvOS 27.0」）。
   */
  static deviceLabel(client: string, deviceName: string): string {
    const name: string = client.startsWith('MovieClaw ') ? client.substring('MovieClaw '.length) : client;
    if (deviceName.length === 0) {
      return name.length === 0 ? '未知设备' : name;
    }
    const segments: string[] = deviceName.split(' · ');
    let repeats: boolean = false;
    for (const segment of segments) {
      if (segment === name || segment.startsWith(`${name} `)) {
        repeats = true;
      }
    }
    if (name.length === 0 || repeats) {
      return deviceName;
    }
    return `${name} · ${deviceName}`;
  }

  /** 可跳详情的前提：有落点库且在可浏览范围内（否则详情接口 404） */
  static canOpenDetail(media: MediaActivityTarget | null | undefined): boolean {
    if (media === null || media === undefined) {
      return false;
    }
    const libraryId: number | null = media.library_id ?? null;
    return media.browsable && libraryId !== null && libraryId > 0;
  }

  /** 把若干片段按「 · 」拼起来，丢掉空段 */
  static metaLine(parts: (string | null | undefined)[]): string {
    const kept: string[] = [];
    for (const part of parts) {
      if (part !== null && part !== undefined && part.trim().length > 0) {
        kept.push(part.trim());
      }
    }
    return kept.join(' · ');
  }

  /** 转码细节：输出规格 · 在哪转、用什么转；直连没有细节 */
  static deliveryDetail(delivery: PlaybackDeliveryView | null | undefined): string | null {
    if (delivery === null || delivery === undefined) {
      return null;
    }
    const detail: string = WatchFormat.metaLine([delivery.target, delivery.executor]);
    return delivery.mode === 'direct' || detail.length === 0 ? null : detail;
  }

  /**
   * 播放方式小标的颜色：按对服务器的负担递进
   * （直连绿、重封装与音频转码蓝、硬件转码橙、软件转码红、远程转码紫）。
   */
  static deliveryColor(delivery: PlaybackDeliveryView | null | undefined): string {
    if (delivery === null || delivery === undefined) {
      return '';
    }
    if (delivery.mode === 'direct') {
      return '#34d399';
    }
    if (delivery.mode === 'remux' || delivery.mode === 'audio') {
      return '#60a5fa';
    }
    if (delivery.label === '远程转码') {
      return '#c084fc';
    }
    return delivery.label === '软件转码' ? '#f87171' : '#fbbf24';
  }
}

/** 任务状态判定（iOS `TaskCenter` 的 attention / active / historical 口径） */
export class TaskState {
  /** 需要用户判断的状态；与「需要处理」同口径 */
  static readonly ATTENTION: string[] = ['blocked', 'failed'];
  /** 「现在」时间线里的进行中状态 */
  static readonly ACTIVE: string[] = ['queued', 'running', 'retry_wait', 'cancelling', 'waiting'];
  /** 已经了结的终态 */
  static readonly HISTORY: string[] = ['succeeded', 'cancelled'];

  /** 失败任务是否已被用户忽略 */
  static isDismissed(job: JobView): boolean {
    return (job.dismissed_at ?? '') !== '';
  }

  /** 这条 Job 是不是**现在**要用户动手：失败但已忽略的不算 */
  static needsAttention(job: JobView): boolean {
    return TaskState.ATTENTION.indexOf(job.status) >= 0 && !TaskState.isDismissed(job);
  }

  /** 已经了结的 Job：正常终态，加上被忽略的失败任务 */
  static isHistorical(job: JobView): boolean {
    return TaskState.HISTORY.indexOf(job.status) >= 0
      || (job.status === 'failed' && TaskState.isDismissed(job));
  }

  static isActive(job: JobView): boolean {
    return TaskState.ACTIVE.indexOf(job.status) >= 0;
  }

  /** 系统自动收口的取消（`system:` 前缀）：重跑没有意义，不给「重新执行」 */
  static isSystemCancelled(job: JobView): boolean {
    return job.status === 'cancelled' && (job.cancel_requested_by ?? '').startsWith('system:');
  }
}

/** 同一部作品的多个下载资源合并成的一组（iOS `TaskCenter.DownloadGroup`） */
export class DownloadGroup {
  readonly key: string;
  readonly mediaItemId: number | null;
  readonly title: string;
  readonly kind: string;
  readonly posterUrl: string;
  readonly tasks: DownloadTaskView[];

  constructor(key: string, mediaItemId: number | null, title: string, kind: string,
    posterUrl: string, tasks: DownloadTaskView[]) {
    this.key = key;
    this.mediaItemId = mediaItemId;
    this.title = title;
    this.kind = kind;
    this.posterUrl = posterUrl;
    this.tasks = tasks;
  }

  get id(): string {
    return this.key;
  }
}

/** 下载任务的分组与归类（iOS `TaskCenter.groupDownloadTasks` / `buildActivity`） */
export class DownloadTasks {
  /** 只按媒体条目主键合并，未识别的各自一组 */
  static group(tasks: DownloadTaskView[]): DownloadGroup[] {
    const groups: DownloadGroup[] = [];
    const index: Map<string, number> = new Map<string, number>();
    for (const task of tasks) {
      const mediaItemId: number | null = task.media_item_id ?? null;
      const key: string = mediaItemId !== null ? `media:${mediaItemId}` : `task:${task.id}`;
      const position: number | undefined = index.get(key);
      if (position !== undefined) {
        const existing: DownloadGroup = groups[position];
        existing.tasks.push(task);
        continue;
      }
      index.set(key, groups.length);
      const mediaTitle: string = task.media_title ?? '';
      const name: string = task.name ?? '';
      const title: string = mediaTitle.length > 0 ? mediaTitle
        : (name.length > 0 ? name : task.info_hash);
      groups.push(new DownloadGroup(key, mediaItemId, title, task.media_kind ?? '',
        task.poster_url ?? '', [task]));
    }
    return groups;
  }

  /** 可进任务时间线的下载任务（排除刷流，iOS 同口径） */
  static mediaTasks(tasks: DownloadTaskView[]): DownloadTaskView[] {
    const out: DownloadTaskView[] = [];
    for (const task of tasks) {
      if (task.source !== 'boost') {
        out.push(task);
      }
    }
    return out;
  }

  /**
   * 这一组下载要不要用户处理（iOS `downloadTaskNeedsAttention`）。
   * 外部任务（非 MovieClaw 投递）只观察不报警。
   */
  static needsAttention(group: DownloadGroup): boolean {
    for (const task of group.tasks) {
      if (task.source === 'external') {
        continue;
      }
      if (task.can_replace || task.state === 'error' || task.state === 'missing'
        || (task.landing_error ?? '') !== '') {
        return true;
      }
      if ((task.rescue_state ?? '') !== '') {
        return true;
      }
    }
    return false;
  }

  /** 需要处理的下载组（下载/入库出了问题，或关联的入库任务失败） */
  static attentionGroups(tasks: DownloadTaskView[]): DownloadGroup[] {
    const out: DownloadGroup[] = [];
    for (const group of DownloadTasks.group(DownloadTasks.mediaTasks(tasks))) {
      if (DownloadTasks.needsAttention(group)) {
        out.push(group);
      }
    }
    return out;
  }

  /** 进行中的下载组（不包含要用户处理的那批） */
  static activeGroups(tasks: DownloadTaskView[]): DownloadGroup[] {
    const out: DownloadGroup[] = [];
    for (const group of DownloadTasks.group(DownloadTasks.mediaTasks(tasks))) {
      if (!DownloadTasks.needsAttention(group)) {
        out.push(group);
      }
    }
    return out;
  }

  /** 一组下载的百分比（取第一条的 progress） */
  static percent(group: DownloadGroup): number {
    const task: DownloadTaskView = group.tasks[0];
    const progress: number = task.progress ?? 0;
    return Math.floor(Math.max(0, Math.min(1, progress)) * 100);
  }

  /** 状态色：出错红、完成绿、其余蓝 */
  static color(group: DownloadGroup): string {
    const state: string = group.tasks[0].state;
    if (state === 'error' || state === 'missing') {
      return Theme.danger;
    }
    if (state === 'completed') {
      return Theme.ok;
    }
    return Theme.info;
  }

  /** 下载状态的人话标签（iOS `downloadStateMeta` 的精简版） */
  static stateLabel(task: DownloadTaskView): string {
    if (task.state === 'error') {
      return '下载出错';
    }
    if (task.state === 'missing') {
      return '找不到任务';
    }
    if (task.state === 'completed') {
      return '已完成';
    }
    if (task.state === 'downloading') {
      return '下载中';
    }
    if (task.state === 'paused') {
      return '已暂停';
    }
    if (task.state === 'stalled') {
      return '无进度';
    }
    if (task.state === 'checking') {
      return '校验中';
    }
    return '排队中';
  }

  /** 单个资源的百分比（0–100） */
  static percentOf(task: DownloadTaskView): number {
    const progress: number = task.progress ?? 0;
    return Math.floor(Math.max(0, Math.min(1, progress)) * 100);
  }

  /** 单个资源的状态色：出错红、完成绿、其余蓝 */
  static taskColor(task: DownloadTaskView): string {
    if (task.state === 'error' || task.state === 'missing') {
      return Theme.danger;
    }
    if (task.state === 'completed') {
      return Theme.ok;
    }
    return Theme.info;
  }

  /** 规格行：分辨率 · 片源 · Remux · 体积（iOS `DownloadTaskFeedItem` 的 specs） */
  static taskSpecLine(task: DownloadTaskView): string {
    const parts: string[] = [];
    const resolution: string = task.resolution ?? '';
    if (resolution.length > 0) {
      parts.push(resolution);
    }
    const source: string = task.media_source ?? '';
    if (source.length > 0) {
      parts.push(source);
    }
    if (task.remux) {
      parts.push('Remux');
    }
    if ((task.size_bytes ?? 0) > 0) {
      parts.push(ActivityFormat.bytes(task.size_bytes ?? 0));
    }
    return WatchFormat.metaLine(parts);
  }

  /** 资源说明：补救信息 → 错误 → 速度与剩余时间 */
  static taskNote(task: DownloadTaskView): string {
    const parts: string[] = [];
    if ((task.rescue_message ?? '').length > 0) {
      parts.push(task.rescue_message ?? '');
    } else if ((task.error_message ?? '').length > 0) {
      parts.push(task.error_message ?? '');
    }
    if ((task.dlspeed_bytes ?? 0) > 0 && task.state === 'downloading') {
      parts.push(`↓ ${ActivityFormat.rate(task.dlspeed_bytes ?? 0)}`);
    }
    const eta: number = task.eta_seconds ?? 0;
    if (eta > 0 && task.state === 'downloading') {
      parts.push(`剩余约 ${ActivityFormat.duration(eta)}`);
    }
    return WatchFormat.metaLine(parts);
  }

  /**
   * 下载任务的完整过程（照 iOS `TaskCenter.lifecycleSteps` 的简化版）：
   * 已投递 → 下载（状态）→ 等待下载完成 / 等待入库 → 入库。没有入库作业可关联时，
   * 后两步按「计划」展示为未来的灰点。
   */
  static lifecycleSteps(task: DownloadTaskView): LifecycleStep[] {
    const steps: LifecycleStep[] = [];
    const downloader: string = (task.downloader_name ?? '').length > 0
      ? (task.downloader_name ?? '') : '下载器';
    steps.push(new LifecycleStep('已投递', downloader, 'done'));
    const percent: number = DownloadTasks.percentOf(task);
    const attention: boolean = task.state === 'error' || task.state === 'missing';
    const waiting: boolean = task.state === 'stalled' || task.state === 'paused'
      || task.state === 'queued' || task.state === 'unknown';
    if (attention) {
      steps.push(new LifecycleStep(DownloadTasks.stateLabel(task),
        task.state === 'missing' ? '等待恢复关联' : '需要在下载器中处理', 'attention'));
    } else if (task.state === 'completed') {
      steps.push(new LifecycleStep('下载完成',
        (task.size_bytes ?? 0) > 0 ? ActivityFormat.bytes(task.size_bytes ?? 0) : '文件已就绪', 'done'));
    } else {
      steps.push(new LifecycleStep(DownloadTasks.stateLabel(task), `${percent}%`,
        waiting ? 'waiting' : 'current'));
    }
    if ((task.landing_error ?? '').length > 0) {
      steps.push(new LifecycleStep('无法入库', 'MovieClaw 看不到已下载的文件', 'attention'));
      return steps;
    }
    if (task.state === 'completed') {
      steps.push(new LifecycleStep('等待入库', '下一步', 'future'));
      steps.push(new LifecycleStep('入库完成', '全部文件进媒体库', 'future'));
    } else {
      steps.push(new LifecycleStep('等待下载完成', '下一步', 'future'));
      steps.push(new LifecycleStep('入库', '下载完成后自动处理', 'future'));
    }
    return steps;
  }

  /** 一行状态：状态 + 补救信息 / 错误 / 速度 / 剩余时间 */
  static statusLine(group: DownloadGroup): string {
    const task: DownloadTaskView = group.tasks[0];
    const parts: string[] = [DownloadTasks.stateLabel(task)];
    if ((task.rescue_message ?? '').length > 0) {
      parts.push(task.rescue_message ?? '');
    } else {
      if ((task.error_message ?? '').length > 0) {
        parts.push(task.error_message ?? '');
      }
      if ((task.dlspeed_bytes ?? 0) > 0) {
        parts.push(`↓ ${ActivityFormat.rate(task.dlspeed_bytes ?? 0)}`);
      }
      const eta: number = task.eta_seconds ?? 0;
      if (eta > 0 && task.state === 'downloading') {
        parts.push(`剩 ${ActivityFormat.duration(eta)}`);
      }
    }
    return WatchFormat.metaLine(parts);
  }
}

/** 下载过程的一步（iOS `TaskCenter.LifecycleStep`）：标签 + 说明 + 色调 */
export class LifecycleStep {
  readonly label: string;
  readonly detail: string;
  /** done / current / waiting / attention / future */
  readonly tone: string;

  constructor(label: string, detail: string, tone: string) {
    this.label = label;
    this.detail = detail;
    this.tone = tone;
  }
}

/** 刷流做种的汇总（iOS `ActivityBoostTotals`）：做种数、上速、累计上传/已完成 */
export class BoostTotals {
  readonly count: number;
  readonly upSpeed: number;
  readonly uploaded: number;
  readonly completed: number;

  constructor(count: number, upSpeed: number, uploaded: number, completed: number) {
    this.count = count;
    this.upSpeed = upSpeed;
    this.uploaded = uploaded;
    this.completed = completed;
  }

  static of(tasks: DownloadTaskView[]): BoostTotals {
    let upSpeed: number = 0;
    let uploaded: number = 0;
    let completed: number = 0;
    for (const task of tasks) {
      upSpeed += task.upspeed_bytes ?? 0;
      uploaded += task.uploaded_bytes ?? 0;
      completed += task.completed_bytes ?? 0;
    }
    return new BoostTotals(tasks.length, upSpeed, uploaded, completed);
  }
}
