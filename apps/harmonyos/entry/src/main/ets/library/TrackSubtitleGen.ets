/**
 * AI 字幕生成：轨道行尾的徽章 + 确认 / 状态弹层
 * （对应 web SubtitleGenPanel、iOS Features/Library/TrackSubtitleGen.swift 的可搬子集）。
 *
 * - 徽章三态：闲时「AI 生成字幕」、运行中显示阶段摘要（SSE `/jobs/stream` + 15s 兜底轮询）、
 *   终态失败显示「AI 未完成」；点徽章 → 没有任务时进确认弹层，有任务时进状态弹层；
 * - 确认弹层：输出语言（单/双语）→ 预检（选源 + 成本估算，不调 LLM）→ PGS 图片字幕
 *   先选语言确认 → 确认生成；预检被服务端拦下时给「重新检查 / 交给 Agent 处理」出口；
 * - 状态弹层：进度卡（阶段、进度条、统计、五段里程碑）+ 停止生成；结束后给结果与重试出口；
 * - 模型没接入时整个徽章换成「去接入」提示（fail-open：供应商接口异常时照常显示徽章）。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassSwitchModifier, GlassTone } from '../common/GlassControls';
import { Formatters } from '../common/Formatters';
import { Permissions } from '../common/Permissions';
import { AppModel } from '../common/AppModel';
import { NavStacks } from '../common/ShareLinks';
import { EventStream, ServerEvent, StreamHandle } from '../common/EventStream';
import { ApiError } from '../api/ApiClient';
import { ChatParams } from '../agent/ChatParams';
import { SectionParams } from '../settings/SettingsIndexPage';
import { MovieClawApi } from '../api/Endpoints';
import {
  GenPreviewPendingView,
  GenPreviewView,
  GenStartPayload,
  JobCancelView,
  JobListView,
  JobView,
  LlmProviderView,
  PgsConversionView,
  PgsOcrLanguageOptionView,
  SessionMessageAcceptedView,
  SessionStartPayload,
  SourceCandidateView
} from '../api/Models';
import {
  JsonValue,
  JsonList,
  jsonArrayValue,
  jsonBoolValue,
  jsonIntValue,
  jsonStringValue
} from '../api/JsonValue';
import { SpatialMaterial } from '../common/SpatialMaterial';

/** 任务还在跑的状态集合（web RUNNING_JOB_STATUSES；blocked/failed/cancelled 是终态问题，succeeded 是成功） */
const GEN_RUNNING_STATUSES: string[] = ['queued', 'running', 'retry_wait', 'cancelling', 'waiting'];

function isDismissedJob(job: JobView): boolean {
  return (job.dismissed_at ?? '') !== '';
}

/** 选出这个文件当前的字幕生成任务：跳过已忽略失败，活跃运行态优先，同档按 created_at 倒序（见 #1337） */
export function selectLatestSubtitleJob(items: JobView[]): JobView | null {
  let best: JobView | null = null;
  let bestActive: boolean = false;
  let bestCreated: number = Number.NEGATIVE_INFINITY;
  let bestUpdated: number = Number.NEGATIVE_INFINITY;
  for (const item of items) {
    if (isDismissedJob(item)) {
      continue;
    }
    const active: boolean = GEN_RUNNING_STATUSES.indexOf(item.status) >= 0;
    const created: number = Formatters.date(item.created_at) ?? Number.NEGATIVE_INFINITY;
    const updated: number = Formatters.date(item.updated_at) ?? Number.NEGATIVE_INFINITY;
    if (best === null || (active && !bestActive) || (active === bestActive
      && (created > bestCreated || (created === bestCreated && updated > bestUpdated)))) {
      best = item;
      bestActive = active;
      bestCreated = created;
      bestUpdated = updated;
    }
  }
  return best;
}

export function subtitleJobShowsTerminalIssue(job: JobView | null, generated: boolean): boolean {
  if (job === null || generated || job.status === 'succeeded' || isDismissedJob(job)) {
    return false;
  }
  return job.status === 'blocked' || job.status === 'failed' || job.status === 'cancelled';
}

export function subtitleGenShouldOpenStatus(job: JobView | null, generated: boolean): boolean {
  if (job !== null && GEN_RUNNING_STATUSES.indexOf(job.status) >= 0) {
    return true;
  }
  return subtitleJobShowsTerminalIssue(job, generated);
}

/** 生成入口支持的目标语言 token（web OUTPUT_LANGUAGES，顺序一致） */
const GEN_LANGUAGES: string[] = ['chs', 'cht', 'eng', 'jpn', 'kor', 'fre', 'ger', 'spa', 'ita', 'por', 'rus', 'tha'];

/** 生成过程的五段里程碑（web PROGRESS_STAGES；当前 phase 命中任一段即属于该段） */
class TrackGenStage {
  readonly phases: string[];
  readonly label: string;

  constructor(phases: string[], label: string) {
    this.phases = phases;
    this.label = label;
  }

  contains(phase: string): boolean {
    return this.phases.indexOf(phase) >= 0;
  }
}

const GEN_STAGES: TrackGenStage[] = [
  new TrackGenStage(['preparing', 'extracting', 'ocr', 'transcribing', 'syncing'], '准备并检查字幕'),
  new TrackGenStage(['glossary'], '统一人名与术语'),
  new TrackGenStage(['translating'], '翻译对白'),
  new TrackGenStage(['validating', 'compressing'], '检查字幕质量'),
  new TrackGenStage(['writing', 'refreshing'], '保存并更新字幕')
];

/** 任务进度的归一化快照（web SubtitleProgress；数字缺省一律 0，percent 未知为 null） */
class TrackGenProgress {
  phase: string = 'preparing';
  message: string = '';
  percent: number | null = null;
  doneBlocks: number = 0;
  totalBlocks: number = 0;
  doneEvents: number = 0;
  totalEvents: number = 0;
  activeBlocks: number[] = [];
  parallelism: number = 0;
  oldestActiveSeconds: number = 0;
  validationRetries: number = 0;
  rateLimitCount: number = 0;
  modelRequests: number = 0;
  modelTokens: number = 0;
  usesOcr: boolean = false;
  /** 来源是音轨识别（本地语音模型），第一阶段显示为「识别台词」 */
  usesAsr: boolean = false;
  /** 本机正在为播放转码，识别暂停中 */
  transcribePaused: boolean = false;
  /** 读取阶段还在排队等别的文件读完（同一时间只通读一个视频） */
  extractQueued: boolean = false;
  targetLanguage: string = '';
  secondaryLanguage: string | null = null;
  sourceCandidateKey: string | null = null;
  elapsedSeconds: number = 0;
}

/** 语言 token → 中文名（web languageLabel + media.languages） */
function genLanguageLabel(token: string | null): string {
  if (token === null || token.length === 0) {
    return '未知语言';
  }
  const labels: Record<string, string> = {
    'chi': '中文', 'chs': '简体中文', 'cht': '繁体中文', 'eng': '英语', 'jpn': '日语',
    'kor': '韩语', 'fre': '法语', 'fra': '法语', 'ger': '德语', 'ita': '意大利语',
    'por': '葡萄牙语', 'rus': '俄语', 'spa': '西班牙语', 'tha': '泰语'
  };
  const label: string | undefined = labels[token];
  return label !== undefined ? label : token.toUpperCase();
}

/** 输出语言组合：「简体中文」或「简体中文 + 英语双语」 */
function genOutputLabel(target: string, secondary: string | null): string {
  if (secondary !== null && secondary.length > 0) {
    return `${genLanguageLabel(target)} + ${genLanguageLabel(secondary)}双语`;
  }
  return genLanguageLabel(target);
}

/** 目标语言变了之后，第二行语言如果撞车就顺延到第一个不重复的（web nextSecondary） */
function genNextSecondary(target: string, current: string): string {
  if (target !== current) {
    return current;
  }
  for (const token of GEN_LANGUAGES) {
    if (token !== target) {
      return token;
    }
  }
  return 'eng';
}

/** 文件名里是否带 AI 产物段（.ai-chs.chi.srt 这类；ai / asr / ai- 前缀段） */
function isAiSubtitleFilename(filename: string): boolean {
  const lowered: string = filename.toLowerCase();
  const segments: string[] = lowered.split('.');
  for (const segment of segments) {
    if (segment === 'ai' || segment === 'asr' || segment.startsWith('ai-')) {
      return true;
    }
  }
  return false;
}

/** 字幕编码 → 用户认知的读法（web formatLabel） */
function genFormatLabel(format: string | null): string {
  if (format === null || format.length === 0) {
    return '未知格式';
  }
  const labels: Record<string, string> = {
    'hdmv_pgs_subtitle': 'PGS', 'dvd_subtitle': 'VobSub', 'subrip': 'SRT', 'srt': 'SRT',
    'ass': 'ASS', 'ssa': 'SSA', 'webvtt': 'VTT', 'vtt': 'VTT'
  };
  const lowered: string = format.toLowerCase();
  const label: string | undefined = labels[lowered];
  return label !== undefined ? label : format.toUpperCase();
}

/** 候选源的一行读法：「英语 · SRT · 原始字幕 · 内封 轨道 1」 */
function genCandidateLabel(candidate: SourceCandidateView): string {
  const kind: string = candidate.kind;
  const location: string = kind === 'embedded' ? '内封' : (kind === 'audio' ? '音频' : '外挂');
  const identity: string = (kind === 'embedded' || kind === 'audio')
    ? `轨道 ${Number(candidate.key) + 1}` : candidate.key;
  const conversion: string = candidate.requires_ocr ? ' · 需先识别' : '';
  const provenanceLabels: Record<string, string> = {
    'original': '原始字幕', 'pgs_ocr': '图片字幕识别结果', 'asr': '本地语音识别',
    'ai': 'AI 字幕', 'ai_bilingual': 'AI 双语成品'
  };
  const provenance: string | undefined = provenanceLabels[candidate.provenance];
  const provenanceLabel: string = provenance !== undefined ? provenance : candidate.provenance;
  return `${genLanguageLabel(candidate.language ?? null)} · ${genFormatLabel(candidate.format ?? null)} · ${provenanceLabel} · ${location} ${identity}${conversion}`;
}

/** 候选源的稳定标识（embedded:0 / audio:1 / external:xxx.srt） */
function genCandidateKey(candidate: SourceCandidateView): string {
  return `${candidate.kind}:${candidate.key}`;
}

/** 千分位（web formatNumber zh 的分组习惯） */
function groupedNumber(value: number): string {
  const rounded: number = Math.floor(value);
  return `${rounded}`.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

/** token 估算：「约 1,234 token」「约 3.5k token」「约 23k token」 */
function tokenEstimateText(tokens: number): string {
  if (tokens < 1000) {
    return `约 ${groupedNumber(tokens)} token`;
  }
  if (tokens < 10000) {
    const k: number = Math.round(tokens / 100) / 10;
    return `约 ${k.toFixed(1)}k token`;
  }
  return `约 ${groupedNumber(Math.floor(tokens / 1000))}k token`;
}

/** 已用时：「45 秒」「3 分 12 秒」「1 小时 5 分」 */
function genElapsedText(seconds: number): string {
  const safeSeconds: number = Math.max(0, Math.floor(seconds));
  if (safeSeconds < 60) {
    return `${safeSeconds} 秒`;
  }
  const minutes: number = Math.floor(safeSeconds / 60);
  if (minutes < 60) {
    return `${minutes} 分 ${safeSeconds % 60} 秒`;
  }
  return `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`;
}

/** 参考源 key → 短读法（统计行「参考 xxx」用；空返回空串） */
function genSourceKeyLabel(key: string | null): string {
  if (key === null || key.length === 0) {
    return '';
  }
  if (key.startsWith('embedded:')) {
    const index: number = Number(key.substring('embedded:'.length));
    return Number.isFinite(index) ? `内封轨道 ${index + 1}` : '内封字幕';
  }
  if (key.startsWith('audio:')) {
    const index: number = Number(key.substring('audio:'.length));
    return Number.isFinite(index) ? `音轨 ${index + 1}` : key;
  }
  if (key.startsWith('external:')) {
    return key.substring('external:'.length);
  }
  return key;
}

/** 百分比封顶 100 取整；未知（null）保持 null（进度条转虚线动画） */
function genProgressPercent(progress: TrackGenProgress): number | null {
  if (progress.percent === null) {
    return null;
  }
  return Math.min(100, Math.floor(progress.percent));
}

/** 运行中徽章的阶段摘要（web runningBadgeText） */
function genRunningBadgeText(progress: TrackGenProgress | null): string {
  const phase: string = progress !== null ? progress.phase : 'preparing';
  const percent: number | null = progress !== null ? genProgressPercent(progress) : null;
  if (phase === 'translating') {
    return percent === null ? '翻译中' : `AI ${percent}%`;
  }
  if (phase === 'transcribing') {
    if (progress !== null && progress.transcribePaused) {
      return '识别已暂停';
    }
    return percent === null ? '识别中' : `识别 ${percent}%`;
  }
  if (phase === 'extracting') {
    if (progress !== null && progress.extractQueued) {
      return '排队读取';
    }
    return percent === null ? '读取字幕' : `读取 ${percent}%`;
  }
  const labels: Record<string, string> = {
    'preparing': '准备中', 'ocr': '识别中', 'syncing': '同步检查', 'glossary': '术语分析',
    'validating': '质量检查', 'compressing': '质量优化', 'writing': '保存中', 'refreshing': '更新中'
  };
  const label: string | undefined = labels[phase];
  return label !== undefined ? label : '生成中';
}

/** 当前 phase 落在五段里程碑里的第几段；不认识按第一段 */
function genStageIndex(progress: TrackGenProgress): number {
  for (let i: number = 0; i < GEN_STAGES.length; i++) {
    if (GEN_STAGES[i].contains(progress.phase)) {
      return i;
    }
  }
  return 0;
}

/** 请求失败的对外文案：优先服务端给的 message */
function describeGenError(error: Object): string {
  if (error instanceof ApiError) {
    return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
  }
  if (error instanceof Error) {
    return error.message.length > 0 ? error.message : '请求失败，请稍后再试';
  }
  return '请求失败，请稍后再试';
}

function genSleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: (value: void) => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/** 把任务快照归一化成进度视图（web subtitleProgress：details 缺键按 0，语言回落 input_data） */
function trackGenProgress(job: JobView): TrackGenProgress {
  const progress: TrackGenProgress = new TrackGenProgress();
  const details: Record<string, JsonValue> = job.progress.details;
  const input: Record<string, JsonValue> = job.input_data;
  const usage: Record<string, JsonValue> = job.usage;
  progress.phase = job.progress.phase;
  progress.message = job.progress.message;
  const percent: number | null = job.progress.percent ?? null;
  progress.percent = percent === null ? null : Math.min(100, Math.floor(percent));
  progress.doneBlocks = jsonIntValue(details['done_blocks']) ?? 0;
  progress.totalBlocks = jsonIntValue(details['total_blocks']) ?? 0;
  progress.doneEvents = jsonIntValue(details['done_events']) ?? 0;
  progress.totalEvents = jsonIntValue(details['total_events']) ?? 0;
  const activeBlocks: number[] = [];
  const activeList: JsonList | null = jsonArrayValue(details['active_blocks']);
  if (activeList !== null) {
    for (let i: number = 0; i < activeList.length; i++) {
      const block: number | null = jsonIntValue(activeList[i]);
      if (block !== null) {
        activeBlocks.push(block);
      }
    }
  }
  progress.activeBlocks = activeBlocks;
  progress.parallelism = jsonIntValue(details['parallelism']) ?? 0;
  progress.oldestActiveSeconds = jsonIntValue(details['oldest_active_seconds']) ?? 0;
  progress.validationRetries = jsonIntValue(details['validation_retries']) ?? 0;
  progress.rateLimitCount = jsonIntValue(details['rate_limit_count']) ?? 0;
  progress.modelRequests = jsonIntValue(usage['request_count']) ?? 0;
  progress.modelTokens = jsonIntValue(usage['total_tokens']) ?? 0;
  progress.usesOcr = jsonBoolValue(details['uses_ocr']) === true;
  progress.usesAsr = jsonBoolValue(details['uses_asr']) === true;
  progress.transcribePaused = jsonBoolValue(details['transcribe_paused']) === true;
  progress.extractQueued = jsonBoolValue(details['extract_queued']) === true;
  const targetDetail: string | null = jsonStringValue(details['target_language']);
  const targetInput: string | null = jsonStringValue(input['target_language']);
  progress.targetLanguage = (targetDetail !== null && targetDetail.length > 0)
    ? targetDetail : (targetInput !== null ? targetInput : '');
  const secondaryDetail: string | null = jsonStringValue(details['secondary_language']);
  const secondaryInput: string | null = jsonStringValue(input['secondary_language']);
  const secondary: string = (secondaryDetail !== null && secondaryDetail.length > 0)
    ? secondaryDetail : (secondaryInput !== null ? secondaryInput : '');
  progress.secondaryLanguage = secondary.length > 0 ? secondary : null;
  const sourceDetail: string | null = jsonStringValue(details['source_candidate_key']);
  const sourceInput: string | null = jsonStringValue(input['source_candidate_key']);
  const source: string = (sourceDetail !== null && sourceDetail.length > 0)
    ? sourceDetail : (sourceInput !== null ? sourceInput : '');
  progress.sourceCandidateKey = source.length > 0 ? source : null;
  const startedMs: number | null = Formatters.date(job.started_at ?? null);
  progress.elapsedSeconds = startedMs === null ? 0 : Math.max(0, Math.floor((Date.now() - startedMs) / 1000));
  return progress;
}

@Component
export struct TrackSubtitleGenButton {
  /** 文件台账 ID */
  @Prop @Watch('onFileIdChanged') fileId: number = -1;
  /** 文件名（交给 Agent 时报给对方） */
  @Prop fileName: string = '';
  /** 文件路径（交给 Agent 时报给对方） */
  @Prop filePath: string = '';
  /** 文件是否已不在磁盘上（不在就不给生成入口） */
  @Prop fileMissing: boolean = false;
  /** 外挂字幕文件名列表（判断「AI 生成字幕」是否已经生成过；外面从 subtitle_streams 捞） */
  @Prop externalSubtitleNames: string[] = [];
  /** 产物落盘后回调（详情页借此重拉数据，新字幕立刻可见） */
  onChanged: () => void = (): void => {};

  @State private targetLanguage: string = 'chs';
  @State private bilingual: boolean = false;
  @State private secondaryLanguage: string = 'eng';
  @State private sourceCandidateKey: string | null = null;
  @State private pgsOcrLanguage: string = '';
  @State private preview: GenPreviewView | null = null;
  @State private previewing: boolean = false;
  /** 旧版服务端「预检还没结论」的等待文案；新版预检当场出结论，恒为空 */
  @State private pendingNotice: string | null = null;
  @State private requestError: string | null = null;
  @State private showSheet: boolean = false;
  /** 弹层模式：''（未开）/ preview（确认）/ status（状态） */
  @State private mode: string = '';
  @State private starting: boolean = false;
  @State private stopping: boolean = false;
  @State private agentStarting: boolean = false;
  @State private job: JobView | null = null;
  /** 模型接入状态：checking / configured / missing / unavailable（异常时 fail-open 照常给入口） */
  @State private llm: string = 'checking';

  /** 预检序号：换语言/换源/关弹层时 +1，作废在途响应 */
  private previewSeq: number = 0;
  private stream: StreamHandle | null = null;
  private timer: number = -1;
  private debounceTimer: number = -1;
  private reconnectTimer: number = -1;
  private started: boolean = false;

  aboutToAppear(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.checkLlm();
    this.refreshJob();
    this.startJobsStream();
    this.timer = setInterval((): void => {
      this.refreshJob();
    }, 15000);
  }

  aboutToDisappear(): void {
    this.teardown();
  }

  /** 关流 + 清全部定时器（组件销毁必须全清；started 置回 false，组件复用时重启） */
  private teardown(): void {
    this.previewSeq += 1;
    if (this.stream !== null) {
      this.stream.close();
      this.stream = null;
    }
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.started = false;
  }

  /** 版本菜单切到另一个文件：整份选择作废重来（任务快照也随之切换） */
  onFileIdChanged(): void {
    this.stopPreview();
    this.preview = null;
    this.requestError = null;
    this.showSheet = false;
    this.mode = '';
    this.starting = false;
    this.agentStarting = false;
    this.job = null;
    this.refreshJob();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 任务快照（SSE 事件驱动 + 15s 兜底轮询，同 ActivityPage 的 jobs 流）

  private startJobsStream(): void {
    if (this.stream !== null) {
      return;
    }
    const client = AppModel.shared.client;
    if (client === null) {
      return;
    }
    const es = new EventStream(client.origin, client.getToken());
    this.stream = es.open('/jobs/stream', {}, {
      onEvent: (ev: ServerEvent): void => {
        if (ev.event === 'ready' || ev.event === 'job') {
          this.scheduleJobsRefresh();
        }
      },
      onError: (_err: ApiError): void => {
        this.onJobsStreamDown();
      },
      onEnd: (): void => {
        this.onJobsStreamDown();
      }
    });
  }

  /** 断线（含服务端主动结束）：3 秒后重连，期间兜底轮询保证数据不停 */
  private onJobsStreamDown(): void {
    if (this.stream !== null) {
      this.stream.close();
      this.stream = null;
    }
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
    }
    this.reconnectTimer = setTimeout((): void => {
      this.reconnectTimer = -1;
      this.startJobsStream();
    }, 3000);
  }

  /** 连发事件合并：ready/job 一次连推多条，120ms 合并为一次快照校准 */
  private scheduleJobsRefresh(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout((): void => {
      this.debounceTimer = -1;
      this.refreshJob();
    }, 120);
  }

  /** 拉这个文件的最新未忽略字幕生成任务（同 Web latestFor） */
  private refreshJob(): void {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.fileId < 0) {
      return;
    }
    api.jobsList(undefined, 'subtitle.generate', 'library_file', `${this.fileId}`, undefined, 5)
      .then((view: JobListView): void => {
        this.applyJob(selectLatestSubtitleJob(view.items));
      })
      .catch((): void => {
        // 列表拉取失败不打扰界面：SSE 事件与 15 秒轮询都会再试
      });
  }

  private applyJob(job: JobView | null): void {
    const previous: JobView | null = this.job;
    const wasRunning: boolean = previous !== null && GEN_RUNNING_STATUSES.indexOf(previous.status) >= 0;
    this.job = job;
    // 只在亲眼看到同一任务从活跃态变为成功时回调刷新；初次读到历史成功任务不触发多余请求
    if (job !== null && wasRunning && previous !== null && job.id === previous.id && job.status === 'succeeded') {
      this.onChanged();
    }
  }

  /** 模型是否已接入：供应商列表空 = 没接入；接口异常按已接入处理（fail-open，后端仍是安全边界） */
  private checkLlm(): void {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      this.llm = 'unavailable';
      return;
    }
    api.llmProvidersList()
      .then((providers: LlmProviderView[]): void => {
        this.llm = providers.length > 0 ? 'configured' : 'missing';
      })
      .catch((): void => {
        this.llm = 'unavailable';
      });
  }

  // MARK: 派生态

  private isJobRunning(): boolean {
    return this.job !== null && GEN_RUNNING_STATUSES.indexOf(this.job.status) >= 0;
  }

  private jobSucceeded(): boolean {
    return this.job !== null && this.job.status === 'succeeded';
  }

  private showsTerminalIssue(): boolean {
    return subtitleJobShowsTerminalIssue(this.job, this.hasGenerated());
  }

  /** 已经生成过 AI 字幕（外挂里有 AI 命名段）：徽章不再顶着未完成红态 */
  private hasGenerated(): boolean {
    for (const name of this.externalSubtitleNames) {
      if (isAiSubtitleFilename(name)) {
        return true;
      }
    }
    return false;
  }

  private activeProgress(): TrackGenProgress | null {
    return this.job !== null ? trackGenProgress(this.job) : null;
  }

  /** 运行中 / 结束态报的目标输出（Agent、CLI 发起的任务用户没选过语言，也要写清楚） */
  private activeOutputLabel(): string {
    const progress: TrackGenProgress | null = this.activeProgress();
    const target: string = progress !== null && progress.targetLanguage.length > 0
      ? progress.targetLanguage : this.targetLanguage;
    const secondary: string | null = progress !== null ? progress.secondaryLanguage
      : (this.bilingual ? this.secondaryLanguage : null);
    return genOutputLabel(target, secondary);
  }

  /** 当前选择的目标输出（确认按钮、成本行用） */
  private currentOutputLabel(): string {
    return genOutputLabel(this.targetLanguage, this.bilingual ? this.secondaryLanguage : null);
  }

  // MARK: 预检

  private pgsConversion(): PgsConversionView | null {
    const preview: GenPreviewView | null = this.preview;
    return preview !== null ? (preview.pgs_conversion ?? null) : null;
  }

  /** 图片字幕可以在本机先识别：blocker 要求 PGS 转换且本机引擎可用 */
  private canPreparePgs(): boolean {
    const preview: GenPreviewView | null = this.preview;
    if (preview === null) {
      return false;
    }
    const blocker = preview.blocker ?? null;
    const conversion = preview.pgs_conversion ?? null;
    return blocker !== null && blocker.code === 'pgs_conversion_required'
      && conversion !== null && conversion.available === true;
  }

  /** 服务端没法确定图片字幕语言，要用户先选 */
  private needsPgsLanguage(): boolean {
    const conversion: PgsConversionView | null = this.pgsConversion();
    return conversion !== null && conversion.language_confirmation_required === true;
  }

  private canConvertPgs(): boolean {
    return this.canPreparePgs() && (!this.needsPgsLanguage() || this.pgsOcrLanguage.length > 0);
  }

  private chosenCandidate(): SourceCandidateView | null {
    const preview: GenPreviewView | null = this.preview;
    if (preview === null) {
      return null;
    }
    const chosenKey: string | null = preview.chosen_key ?? null;
    if (chosenKey === null) {
      return null;
    }
    for (const candidate of preview.candidates) {
      if (genCandidateKey(candidate) === chosenKey) {
        return candidate;
      }
    }
    return null;
  }

  /** 用户在参考菜单里选中的候选（提示「当前选择的是图片字幕」用） */
  private selectedCandidate(): SourceCandidateView | null {
    const preview: GenPreviewView | null = this.preview;
    if (preview === null) {
      return null;
    }
    const selectedKey: string | null = preview.selected_source_key ?? null;
    if (selectedKey === null) {
      return null;
    }
    for (const candidate of preview.candidates) {
      if (genCandidateKey(candidate) === selectedKey) {
        return candidate;
      }
    }
    return null;
  }

  private sourceCandidates(): SourceCandidateView[] {
    const preview: GenPreviewView | null = this.preview;
    return preview !== null ? preview.candidates : [];
  }

  private hasSourceCandidates(): boolean {
    return this.sourceCandidates().length > 0;
  }

  private hasBlocker(): boolean {
    const preview: GenPreviewView | null = this.preview;
    return preview !== null && preview.blocker !== null && preview.blocker !== undefined;
  }

  private hasChosen(): boolean {
    return !this.hasBlocker() && this.chosenCandidate() !== null;
  }

  /** 预检：作废上一条在途请求，弹层打开、进入检查态 */
  private loadPreview(sourceKey: string | null): void {
    if (this.fileId < 0) {
      return;
    }
    this.previewSeq += 1;
    const seq: number = this.previewSeq;
    this.mode = 'preview';
    this.showSheet = true;
    this.preview = null;
    this.pgsOcrLanguage = '';
    this.requestError = null;
    this.pendingNotice = null;
    this.previewing = true;
    this.previewLoop(seq, sourceKey);
  }

  /** 预检循环：新版服务端当场给结论；旧版服务端返回 pending 就按 retry_after_ms 等待重试 */
  private async previewLoop(seq: number, sourceKey: string | null): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      if (seq === this.previewSeq) {
        this.requestError = '请求失败，请稍后再试';
        this.previewing = false;
      }
      return;
    }
    let waitMs: number = 0;
    while (seq === this.previewSeq) {
      try {
        const secondary: string | null = this.bilingual ? this.secondaryLanguage : null;
        const result: GenPreviewView = await api.librarySubtitlesPreviewGeneration(this.fileId,
          this.targetLanguage, secondary === null ? undefined : secondary,
          sourceKey === null ? undefined : sourceKey);
        if (seq !== this.previewSeq) {
          return;
        }
        const pending: GenPreviewPendingView | null = result.pending ?? null;
        if (pending !== null) {
          this.pendingNotice = pending.message;
          waitMs = Math.max(1000, pending.retry_after_ms);
        } else {
          this.preview = result;
          this.sourceCandidateKey = result.selected_source_key ?? null;
          const conversion = result.pgs_conversion ?? null;
          this.pgsOcrLanguage = conversion !== null ? (conversion.ocr_language ?? '') : '';
          this.pendingNotice = null;
          this.previewing = false;
          return;
        }
      } catch (error) {
        if (seq !== this.previewSeq) {
          return;
        }
        this.requestError = describeGenError(error);
        this.previewing = false;
        return;
      }
      await genSleep(waitMs);
    }
  }

  /** 收掉在途预检（关弹层、切文件）：作废响应并退出检查态 */
  private stopPreview(): void {
    this.previewSeq += 1;
    this.previewing = false;
    this.pendingNotice = null;
  }

  private closeSheet(): void {
    this.stopPreview();
    this.showSheet = false;
  }

  // MARK: 选择变更（每次都重新预检）

  private changeTarget(target: string): void {
    if (this.starting) {
      return;
    }
    this.targetLanguage = target;
    this.secondaryLanguage = genNextSecondary(target, this.secondaryLanguage);
    this.loadPreview(null);
  }

  private changeSecondary(secondary: string): void {
    if (this.starting) {
      return;
    }
    this.secondaryLanguage = secondary;
    this.loadPreview(null);
  }

  private changeBilingual(isOn: boolean): void {
    if (this.starting) {
      return;
    }
    this.bilingual = isOn;
    this.secondaryLanguage = genNextSecondary(this.targetLanguage, this.secondaryLanguage);
    this.loadPreview(null);
  }

  // MARK: 动作

  /** 徽章点击：运行中或展示未完成态进状态弹层，其余进确认弹层 */
  private openAction(): void {
    if (this.previewing) {
      return;
    }
    if (subtitleGenShouldOpenStatus(this.job, this.hasGenerated())) {
      this.mode = 'status';
      this.showSheet = true;
      return;
    }
    this.loadPreview(null);
  }

  private start(): void {
    if (this.starting) {
      return;
    }
    const api: MovieClawApi | null = this.api();
    if (api === null || this.fileId < 0) {
      return;
    }
    this.starting = true;
    this.requestError = null;
    const convertPgs: boolean = this.canPreparePgs();
    const payload: GenStartPayload = {
      target_language: this.targetLanguage,
      secondary_language: this.bilingual ? this.secondaryLanguage : null,
      source_candidate_key: this.sourceCandidateKey,
      convert_pgs: convertPgs,
      pgs_ocr_language: convertPgs ? (this.pgsOcrLanguage.length > 0 ? this.pgsOcrLanguage : null) : null
    };
    api.librarySubtitlesGenerate(this.fileId, payload)
      .then((started: JobView): void => {
        this.starting = false;
        this.applyJob(started);
        this.showSheet = false;
        this.mode = '';
      })
      .catch((error: BusinessError): void => {
        // 确认到真正入队之间文件可能变化，错误留在弹层里让用户看清
        this.starting = false;
        this.requestError = describeGenError(error);
      });
  }

  private stop(): void {
    const job: JobView | null = this.job;
    if (job === null || this.stopping) {
      return;
    }
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.stopping = true;
    api.jobsCancel(job.id)
      .then((view: JobCancelView): void => {
        this.stopping = false;
        this.applyJob(view.job);
      })
      .catch((error: BusinessError): void => {
        this.stopping = false;
        this.requestError = describeGenError(error);
      });
  }

  /** 结束态给用户的结论：优先失败原因，其次结果说明 */
  private resultMessage(): string {
    const job: JobView | null = this.job;
    if (job === null) {
      return '任务已经结束。';
    }
    const errorMap: Record<string, JsonValue> | null | undefined = job.error;
    if (errorMap !== null && errorMap !== undefined) {
      const message: string | null = jsonStringValue(errorMap['message']);
      if (message !== null && message.length > 0) {
        return message;
      }
    }
    const resultMap: Record<string, JsonValue> | null | undefined = job.result;
    if (resultMap !== null && resultMap !== undefined) {
      const message: string | null = jsonStringValue(resultMap['message']);
      if (message !== null && message.length > 0) {
        return message;
      }
    }
    return '任务已经结束。';
  }

  private handOffToAgent(reason: string): void {
    if (this.agentStarting) {
      return;
    }
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.agentStarting = true;
    const lines: string[] = [];
    lines.push('请帮我处理 MovieClaw 的 AI 字幕生成问题。');
    lines.push(`文件：${this.fileName}`);
    lines.push(`文件台账 ID：${this.fileId}`);
    lines.push(`文件路径：${this.filePath}`);
    lines.push(`期望输出：${this.currentOutputLabel()}`);
    const args: string[] = [`--target-language ${this.targetLanguage}`];
    if (this.bilingual) {
      args.push(`--secondary-language ${this.secondaryLanguage}`);
    }
    if (this.sourceCandidateKey !== null && this.sourceCandidateKey.length > 0) {
      args.push(`--source-candidate-key ${this.sourceCandidateKey}`);
    }
    lines.push(`对应参数：${args.join(' ')}`);
    lines.push(`当前问题：${reason}`);
    const conversion: PgsConversionView | null = this.pgsConversion();
    if (conversion !== null) {
      const engine: string = conversion.engine !== null && conversion.engine !== undefined
        && conversion.engine.length > 0 ? ` · ${conversion.engine}` : ' · 未找到可用识别引擎';
      lines.push(`预检环境：${conversion.platform} ${conversion.architecture}${engine}`);
      if (conversion.message.length > 0) {
        lines.push(`预检诊断：${conversion.message}`);
      }
    }
    const preview: GenPreviewView | null = this.preview;
    const blocker = preview !== null ? (preview.blocker ?? null) : null;
    if (blocker !== null && blocker.suggestions.length > 0) {
      lines.push(`已有建议：${blocker.suggestions.length} 条`);
    }
    lines.push('请先判断原因；如果能通过 MovieClaw 的工具安全解决，请按上面的「对应参数」直接执行（不要换回默认参数），否则给出明确的操作步骤。不要修改影片原文件。');
    const payload: SessionStartPayload = { content: lines.join('\n') };
    api.sessionStart(payload)
      .then((accepted: SessionMessageAcceptedView): void => {
        this.agentStarting = false;
        this.showSheet = false;
        this.mode = '';
        const stack: NavPathStack | null = NavStacks.of(NavStacks.currentKey);
        if (stack !== null) {
          stack.pushPathByName('chat', new ChatParams(accepted.session_id));
        }
      })
      .catch((error: BusinessError): void => {
        this.agentStarting = false;
        this.requestError = `无法启动 Agent：${describeGenError(error)}`;
      });
  }

  // MARK: 弹层文案

  private sheetTitle(): string {
    if (this.mode === 'status') {
      return this.isJobRunning() ? `正在生成${this.activeOutputLabel()}` : 'AI 字幕任务';
    }
    return '生成 AI 字幕';
  }

  private sheetSubtitle(): string {
    if (this.mode === 'status') {
      return this.isJobRunning() ? '后台运行，离开页面不会中断。' : '任务详情与处理建议。';
    }
    const preview: GenPreviewView | null = this.preview;
    if (preview !== null) {
      const chosenKey: string = preview.chosen_key ?? '';
      if (chosenKey.startsWith('audio:') && preview.estimated_tokens === 0) {
        return '确认后在后台用本地语音模型识别，不调用 AI。';
      }
    }
    return '确认后才调用 AI，并在后台生成。';
  }

  private badgeLabel(): string {
    if (this.previewing) {
      return '正在检查';
    }
    if (this.isJobRunning()) {
      return `${this.activeOutputLabel()} · ${genRunningBadgeText(this.activeProgress())}`;
    }
    if (this.showsTerminalIssue()) {
      return 'AI 未完成';
    }
    return 'AI 生成字幕';
  }

  private badgeColor(): string {
    if (this.isJobRunning()) {
      return Theme.info;
    }
    if (this.showsTerminalIssue()) {
      return '#ffb4b4';
    }
    return 'rgba(255,255,255,0.75)';
  }

  private badgeBgColor(): string {
    if (this.isJobRunning()) {
      return 'rgba(127,176,255,0.12)';
    }
    if (this.showsTerminalIssue()) {
      return 'rgba(255,159,159,0.07)';
    }
    return 'transparent';
  }

  private badgeBorderColor(): string {
    if (this.isJobRunning()) {
      return 'rgba(127,176,255,0.3)';
    }
    if (this.showsTerminalIssue()) {
      return 'rgba(255,159,159,0.25)';
    }
    return 'rgba(255,255,255,0.16)';
  }

  private requestErrorText(): string {
    return this.requestError ?? '';
  }

  private pendingNoticeText(): string {
    return this.pendingNotice ?? '';
  }

  // MARK: 参考源 / PGS 文案

  private selectedSourceLabel(): string {
    const key: string | null = this.sourceCandidateKey;
    if (key === null || key.length === 0) {
      return '没有可用的参考字幕';
    }
    const preview: GenPreviewView | null = this.preview;
    if (preview !== null) {
      for (const candidate of preview.candidates) {
        if (genCandidateKey(candidate) === key) {
          return genCandidateLabel(candidate);
        }
      }
    }
    return key;
  }

  private sourceMenuItemLabel(candidate: SourceCandidateView): string {
    const checked: string = genCandidateKey(candidate) === this.sourceCandidateKey ? '✓ ' : '';
    let suffix: string = '';
    if (!candidate.selectable) {
      const reason: string = candidate.excluded !== null && candidate.excluded !== undefined
        && candidate.excluded.length > 0 ? candidate.excluded : '不支持';
      suffix = `（不可用：${reason}）`;
    }
    return `${checked}${genCandidateLabel(candidate)}${suffix}`;
  }

  private selectedCandidateNeedsOcr(): boolean {
    const selected: SourceCandidateView | null = this.selectedCandidate();
    return selected !== null && selected.requires_ocr;
  }

  private pgsLanguageOptions(): PgsOcrLanguageOptionView[] {
    const conversion: PgsConversionView | null = this.pgsConversion();
    return conversion !== null ? conversion.language_options : [];
  }

  private pgsSelectedLanguageLabel(): string {
    const options: PgsOcrLanguageOptionView[] = this.pgsLanguageOptions();
    for (const option of options) {
      if (option.code === this.pgsOcrLanguage) {
        return option.label;
      }
    }
    return '请选择字幕语言';
  }

  private pgsDetectedLabel(): string {
    const conversion: PgsConversionView | null = this.pgsConversion();
    if (conversion === null) {
      return '已自动识别';
    }
    return conversion.ocr_language_label ?? '已自动识别';
  }

  // MARK: 预检结论文案

  private blockerTitle(): string {
    const preview: GenPreviewView | null = this.preview;
    if (preview === null) {
      return '';
    }
    const blocker = preview.blocker ?? null;
    return blocker !== null ? blocker.title : '';
  }

  private blockerMessage(): string {
    const preview: GenPreviewView | null = this.preview;
    if (preview === null) {
      return '';
    }
    const blocker = preview.blocker ?? null;
    return blocker !== null ? blocker.message : '';
  }

  private blockerSuggestions(): string[] {
    const preview: GenPreviewView | null = this.preview;
    if (preview === null) {
      return [];
    }
    const blocker = preview.blocker ?? null;
    return blocker !== null ? blocker.suggestions : [];
  }

  private pgsEnvironmentText(): string {
    const conversion: PgsConversionView | null = this.pgsConversion();
    if (conversion === null) {
      return '';
    }
    const engine: string = conversion.engine !== null && conversion.engine !== undefined
      && conversion.engine.length > 0 ? ` · ${conversion.engine}` : ' · 未找到可用识别引擎';
    return `运行环境：${conversion.platform} ${conversion.architecture}${engine}`;
  }

  /** 诊断块里与 blocker 主文案不同的补充信息（engine 探测结论等） */
  private pgsDiagnosticExtra(): string {
    const conversion: PgsConversionView | null = this.pgsConversion();
    if (conversion === null || this.blockerMessage() === conversion.message) {
      return '';
    }
    return conversion.message;
  }

  private chosenLabel(): string {
    const chosen: SourceCandidateView | null = this.chosenCandidate();
    return chosen !== null ? genCandidateLabel(chosen) : '';
  }

  /** 成本行：音轨复用识别不花钱；首次读取按片长粗估；其余按对白条数 + token 估算 */
  private costLineText(): string {
    const preview: GenPreviewView | null = this.preview;
    const chosen: SourceCandidateView | null = this.chosenCandidate();
    if (preview === null || chosen === null) {
      return '';
    }
    if (chosen.kind === 'audio' && preview.estimated_tokens === 0) {
      return '直接使用识别结果，不调用 AI 模型';
    }
    const referenceNotice: string = preview.reference_notice ?? '';
    if (referenceNotice.length > 0 && preview.event_count === 0) {
      return preview.estimated_tokens > 0
        ? `按片长粗估${tokenEstimateText(preview.estimated_tokens)}` : '读取字幕后按实际对白估算';
    }
    return `${groupedNumber(preview.event_count)} 条对白 · ${tokenEstimateText(preview.estimated_tokens)}`;
  }

  private referenceNoticeText(): string {
    const preview: GenPreviewView | null = this.preview;
    return preview !== null ? (preview.reference_notice ?? '') : '';
  }

  private outputFilenameText(): string {
    const preview: GenPreviewView | null = this.preview;
    const name: string = preview !== null ? (preview.output_filename ?? '') : '';
    return name.length > 0 ? name : '规范命名的 AI 字幕文件';
  }

  private alreadyGenerated(): boolean {
    const preview: GenPreviewView | null = this.preview;
    return preview !== null && preview.already_generated === true;
  }

  // MARK: 进度卡文案

  private progressMessageText(): string {
    const progress: TrackGenProgress | null = this.activeProgress();
    if (progress !== null && progress.message.length > 0) {
      return progress.message;
    }
    return '正在准备生成任务';
  }

  private progressPercentText(): string {
    const progress: TrackGenProgress | null = this.activeProgress();
    const percent: number | null = progress !== null ? genProgressPercent(progress) : null;
    return percent === null ? '' : `${percent}%`;
  }

  private progressStats(): string[] {
    const progress: TrackGenProgress | null = this.activeProgress();
    const stats: string[] = [];
    if (progress === null) {
      return stats;
    }
    if (progress.totalBlocks > 0) {
      stats.push(`翻译块 ${progress.doneBlocks}/${progress.totalBlocks}`);
    }
    if (progress.totalEvents > 0) {
      stats.push(`对白 ${progress.doneEvents}/${progress.totalEvents} 条`);
    }
    const reference: string = genSourceKeyLabel(progress.sourceCandidateKey);
    if (reference.length > 0) {
      stats.push(`参考 ${reference}`);
    }
    if (progress.modelRequests > 0) {
      let calls: string = `模型调用 ${progress.modelRequests} 次`;
      if (progress.modelTokens > 0) {
        calls += ` · ${groupedNumber(progress.modelTokens)} token`;
      }
      stats.push(calls);
    }
    stats.push(`已用时 ${genElapsedText(progress.elapsedSeconds)}`);
    return stats;
  }

  private activeBlocksText(): string {
    const progress: TrackGenProgress | null = this.activeProgress();
    if (progress === null || progress.activeBlocks.length === 0) {
      return '';
    }
    const parts: string[] = [];
    for (const block of progress.activeBlocks) {
      parts.push(`${block}`);
    }
    let text: string = progress.parallelism > 1 ? `并发上限 ${progress.parallelism} 路 · ` : '';
    text += `正在处理第 ${parts.join('、')} 块`;
    if (progress.oldestActiveSeconds > 0) {
      text += ` · 最早一块已等待 ${genElapsedText(progress.oldestActiveSeconds)}`;
    }
    return text;
  }

  private progressNoticesText(): string {
    const progress: TrackGenProgress | null = this.activeProgress();
    if (progress === null) {
      return '';
    }
    let text: string = '';
    if (progress.rateLimitCount > 0) {
      text += `模型服务繁忙 ${progress.rateLimitCount} 次，系统已自动降速重试。`;
    }
    if (progress.validationRetries > 0) {
      text += `有 ${progress.validationRetries} 次返回格式不完整，系统已自动纠正。`;
    }
    return text;
  }

  private stageCompleted(index: number): boolean {
    const progress: TrackGenProgress | null = this.activeProgress();
    if (progress === null) {
      return false;
    }
    return index < genStageIndex(progress);
  }

  private stageCurrent(index: number): boolean {
    const progress: TrackGenProgress | null = this.activeProgress();
    if (progress === null) {
      return false;
    }
    return index === genStageIndex(progress);
  }

  /** 第一段的读法随来源变化：音轨识别 / 图片字幕 / 字幕文件 */
  private stageLabel(stage: TrackGenStage, index: number): string {
    const progress: TrackGenProgress | null = this.activeProgress();
    if (index === 0 && progress !== null) {
      if (progress.usesAsr) {
        return '识别台词并整理字幕';
      }
      if (progress.usesOcr) {
        return '识别并检查图片字幕';
      }
    }
    return stage.label;
  }

  // MARK: 底部按钮

  private cancelLabel(): string {
    if ((this.hasBlocker() && !this.canPreparePgs()) || this.requestError !== null) {
      return '关闭';
    }
    return '取消';
  }

  /** 重新检查：blocker 拦下或请求失败时出现（顺带把参考源重置回服务端默认） */
  private recheckVisible(): boolean {
    return (this.hasBlocker() && !this.canPreparePgs())
      || (this.preview === null && this.requestError !== null);
  }

  private agentVisibleInPreview(): boolean {
    return (this.hasBlocker() && !this.canPreparePgs()) || this.requestError !== null;
  }

  private agentReason(): string {
    if (this.mode === 'status') {
      return this.resultMessage();
    }
    if (this.requestError !== null) {
      return this.requestError;
    }
    const preview: GenPreviewView | null = this.preview;
    if (preview !== null) {
      const blocker = preview.blocker ?? null;
      if (blocker !== null) {
        return blocker.message;
      }
    }
    return '字幕生成预检没有通过';
  }

  // MARK: 视图

  build() {
    Column() {
      if (!this.fileMissing) {
        if (this.llm === 'missing') {
          this.LlmGateChip()
        } else if (this.llm !== 'checking') {
          this.BadgeButton()
        }
      }
    }
    .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      systemMaterial: SpatialMaterial.sheet(),
      backgroundColor: Theme.bg,
      shouldDismiss: (sheetDismiss: SheetDismiss): void => {
        // 启动 / 交接进行中不允许误触关闭；其余关闭即收掉在途预检
        if (!this.starting && !this.agentStarting) {
          this.closeSheet();
          sheetDismiss.dismiss();
        }
      }
    })
  }

  /** 轨道行尾的徽章（web AI_BADGE_*：闲 / 运行 / 未完成三态） */
  @Builder
  BadgeButton() {
    Row({ space: 6 }) {
      if (this.isJobRunning()) {
        Row()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(this.badgeColor())
      } else {
        SymbolGlyph($r('sys.symbol.wand_and_stars'))
          .fontSize(14)
          .fontColor([this.badgeColor()])
      }
      Text(this.badgeLabel())
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.badgeColor())
        .maxLines(1)
    }
    .padding({ left: 10, right: 10 })
    .height(32)
    .borderRadius(7)
    .border({ width: 1, color: this.badgeBorderColor() })
    .backgroundColor(this.badgeBgColor())
    .onClick((): void => {
      this.openAction();
    })
  }

  /** 模型没接入：整个徽章换成提示 + 「去接入」跳设置 */
  @Builder
  LlmGateChip() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
        .fontSize(14)
        .fontColor([Theme.warn])
      Text('接入 AI 模型后即可解锁生成字幕能力。')
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .layoutWeight(1)
      Text('去接入')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.accent)
    }
    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
    .borderRadius(7)
    .border({ width: 1, color: 'rgba(255,255,255,0.16)' })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      const stack: NavPathStack | null = NavStacks.of(NavStacks.currentKey);
      if (stack !== null) {
        stack.pushPathByName('settingsSection', new SectionParams('llm'));
      }
    })
  }

  /** 弹层：头部（AI 方标 + 标题 + 关闭）→ 滚动内容 → 底部动作栏 */
  @Builder
  SheetContent() {
    Column() {
      Row({ space: 12 }) {
        Column() {
          Text('AI')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#a9e2ff')
        }
        .width(36)
        .height(36)
        .borderRadius(8)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('rgba(127,176,255,0.12)')
        .border({ width: 1, color: 'rgba(127,176,255,0.3)' })

        Column({ space: 2 }) {
          Text(this.sheetTitle())
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(1)
          Text(this.sheetSubtitle())
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (!this.starting && !this.agentStarting) {
          Text('关闭')
            .fontSize(14)
            .fontColor(Theme.textMuted)
            .onClick((): void => {
              this.closeSheet();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 16, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          if (this.mode === 'status') {
            this.StatusBody()
          } else {
            this.PreviewBody()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 4, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Start)

      this.SheetActions()
    }
    .width('100%')
    .height('100%')
  }

  /** 确认弹层主体：输出语言 → 检查态 /（参考源、错误、PGS、blocker、结论） */
  @Builder
  PreviewBody() {
    this.OutputLanguageSection()
    if (this.previewing) {
      this.CheckingRow()
    } else {
      if (this.hasSourceCandidates()) {
        this.SourceSection()
      }
      if (this.requestErrorText().length > 0) {
        this.ErrorCard()
      }
      if (this.canPreparePgs()) {
        this.PgsSection()
      } else if (this.hasBlocker()) {
        this.BlockerSection()
      }
      if (this.hasChosen()) {
        this.ChosenSection()
      }
    }
  }

  /** 状态弹层主体：运行中给进度卡，结束后给结论卡 */
  @Builder
  StatusBody() {
    if (this.isJobRunning()) {
      this.ProgressCard()
    } else {
      this.EndedCard()
    }
    if (this.requestErrorText().length > 0) {
      this.ErrorCard()
    }
  }

  /** 输出语言卡：目标 / 第二行（双语时）+ 双语开关 */
  @Builder
  OutputLanguageSection() {
    Column({ space: 10 }) {
      Text('输出语言')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('rgba(255,255,255,0.85)')
      Column({ space: 4 }) {
        Text(this.bilingual ? '第一行语言' : '目标语言')
          .fontSize(12)
          .fontColor(Theme.textMuted)
        Row({ space: 8 }) {
          Text(genLanguageLabel(this.targetLanguage))
            .fontSize(14)
            .fontColor(Theme.text)
            .layoutWeight(1)
            .maxLines(1)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(12)
            .fontColor([Theme.textFaint])
        }
        .width('100%')
        .height(44)
        .padding({ left: 12, right: 12 })
        .borderRadius(12)
        .backgroundColor(Theme.surfaceRaised)
        .border({ width: 1, color: Theme.line })
        .alignItems(VerticalAlign.Center)
        .bindMenu(this.TargetLanguageMenu())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.bilingual) {
        Column({ space: 4 }) {
          Text('第二行语言')
            .fontSize(12)
            .fontColor(Theme.textMuted)
          Row({ space: 8 }) {
            Text(genLanguageLabel(this.secondaryLanguage))
              .fontSize(14)
              .fontColor(Theme.text)
              .layoutWeight(1)
              .maxLines(1)
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(12)
              .fontColor([Theme.textFaint])
          }
          .width('100%')
          .height(44)
          .padding({ left: 12, right: 12 })
          .borderRadius(12)
          .backgroundColor(Theme.surfaceRaised)
          .border({ width: 1, color: Theme.line })
          .alignItems(VerticalAlign.Center)
          .bindMenu(this.SecondaryLanguageMenu())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      Row() {
        Text('生成双语字幕')
          .fontSize(14)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.bilingual })
          .attributeModifier(new GlassSwitchModifier())
          .onChange((isOn: boolean): void => {
            this.changeBilingual(isOn);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.bilingual) {
        Text('每条字幕固定两行，上下顺序按这里的选择生成。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius(12)
    .backgroundColor('rgba(255,255,255,0.035)')
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
  }

  @Builder
  TargetLanguageMenu() {
    Menu() {
      ForEach(GEN_LANGUAGES, (token: string) => {
        MenuItem({ content: `${token === this.targetLanguage ? '✓ ' : ''}${genLanguageLabel(token)}` })
          .onClick(() => {
            this.changeTarget(token);
          })
      }, (token: string) => token)
    }
  }

  @Builder
  SecondaryLanguageMenu() {
    Menu() {
      ForEach(GEN_LANGUAGES, (token: string) => {
        if (token !== this.targetLanguage) {
          MenuItem({ content: `${token === this.secondaryLanguage ? '✓ ' : ''}${genLanguageLabel(token)}` })
            .onClick(() => {
              this.changeSecondary(token);
            })
        }
      }, (token: string) => token)
    }
  }

  /** 检查态：转圈 + 等待说明（内封首读提示：不调用 AI、不产生费用） */
  @Builder
  CheckingRow() {
    Row({ space: 12 }) {
      LoadingProgress()
        .width(20)
        .height(20)
        .color(Theme.info)
      Column({ space: 4 }) {
        Text('正在检查参考字幕，不会调用 AI…')
          .fontSize(14)
          .fontColor(Theme.text)
        if (this.pendingNoticeText().length > 0) {
          Text(this.pendingNoticeText())
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        Text('首次读取内封字幕需要通读整个视频文件，读好后会自动继续；这一步不会调用 AI，也不产生费用。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .lineHeight(18)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor('rgba(255,255,255,0.04)')
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
    .alignItems(VerticalAlign.Center)
  }

  /** 参考字幕卡：选源菜单 + 默认策略说明 + 图片字幕提示 */
  @Builder
  SourceSection() {
    Column({ space: 8 }) {
      Text('参考字幕')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('rgba(255,255,255,0.85)')
      Row({ space: 8 }) {
        Text(this.selectedSourceLabel())
          .fontSize(14)
          .fontColor(Theme.text)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .borderRadius(12)
      .backgroundColor(Theme.surfaceRaised)
      .border({ width: 1, color: Theme.line })
      .alignItems(VerticalAlign.Center)
      .bindMenu(this.SourceMenu())

      Text('默认优先英语。也可以指定其他内封或外挂字幕；选择 PGS 时会先识别文字，再开始 AI 翻译。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .lineHeight(18)
      if (this.selectedCandidateNeedsOcr()) {
        Text('当前选择的是图片字幕，需要先完成文字识别。')
          .fontSize(12)
          .fontColor(Theme.warn)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius(12)
    .backgroundColor('rgba(255,255,255,0.035)')
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
  }

  @Builder
  SourceMenu() {
    Menu() {
      if (this.sourceCandidateKey === null || this.sourceCandidateKey.length === 0) {
        MenuItem({ content: '没有可用的参考字幕' })
          .onClick(() => {
            this.loadPreview(null);
          })
      }
      ForEach(this.sourceCandidates(), (candidate: SourceCandidateView) => {
        MenuItem({ content: this.sourceMenuItemLabel(candidate) })
          .onClick(() => {
            if (candidate.selectable) {
              this.loadPreview(genCandidateKey(candidate));
            }
          })
      }, (candidate: SourceCandidateView) => genCandidateKey(candidate))
    }
  }

  /** 请求失败提示条（预检 / 启动 / 停止 / 交接共用） */
  @Builder
  ErrorCard() {
    Text(this.requestErrorText())
      .fontSize(13)
      .fontColor('#ffb4b4')
      .lineHeight(20)
      .width('100%')
      .padding(14)
      .borderRadius(12)
      .backgroundColor('rgba(255,159,159,0.08)')
      .border({ width: 1, color: 'rgba(255,159,159,0.3)' })
  }

  /** PGS 图片字幕：warn 提示卡 + 原字幕语言选择 / 已识别结论 + 识别说明 */
  @Builder
  PgsSection() {
    Column({ space: 12 }) {
      Column({ space: 6 }) {
        Text(this.needsPgsLanguage() ? '请选择原字幕语言' : '先识别图片字幕')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.warn)
        Text(`这份字幕是图片。MovieClaw 会先识别其中的文字，确认内容完整后再生成${this.currentOutputLabel()}字幕。`)
          .fontSize(13)
          .fontColor(Theme.warn)
          .lineHeight(20)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .borderRadius(12)
      .backgroundColor('rgba(245,196,81,0.08)')
      .border({ width: 1, color: 'rgba(245,196,81,0.3)' })

      Column({ space: 10 }) {
        if (this.needsPgsLanguage()) {
          Column({ space: 4 }) {
            Text('原字幕语言')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
            Row({ space: 8 }) {
              Text(this.pgsSelectedLanguageLabel())
                .fontSize(14)
                .fontColor(this.pgsOcrLanguage.length > 0 ? Theme.text : Theme.textMuted)
                .layoutWeight(1)
                .maxLines(1)
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(12)
                .fontColor([Theme.textFaint])
            }
            .width('100%')
            .height(44)
            .padding({ left: 12, right: 12 })
            .borderRadius(12)
            .backgroundColor(Theme.surfaceRaised)
            .border({ width: 1, color: Theme.line })
            .alignItems(VerticalAlign.Center)
            .bindMenu(this.PgsLanguageMenu())
            Text('请选择画面中实际显示的语言。')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        } else {
          Text(`原字幕语言：${this.pgsDetectedLabel()}`)
            .fontSize(14)
            .fontColor(Theme.text)
        }
        Divider()
          .color(Theme.line)
          .width('100%')
        Text('原影片和字幕不会被修改。识别结果可能有少量错字，完成后建议抽查人名与特殊字体。')
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .lineHeight(18)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .borderRadius(12)
      .backgroundColor('rgba(255,255,255,0.035)')
      .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PgsLanguageMenu() {
    Menu() {
      MenuItem({ content: '请选择字幕语言' })
        .onClick(() => {
          this.pgsOcrLanguage = '';
        })
      ForEach(this.pgsLanguageOptions(), (option: PgsOcrLanguageOptionView) => {
        MenuItem({ content: `${option.code === this.pgsOcrLanguage ? '✓ ' : ''}${option.label}` })
          .onClick(() => {
            this.pgsOcrLanguage = option.code;
          })
      }, (option: PgsOcrLanguageOptionView) => option.code)
    }
  }

  /** 服务端拦下生成：blocker 卡 + 建议 + PGS 诊断信息 */
  @Builder
  BlockerSection() {
    Column({ space: 12 }) {
      Column({ space: 6 }) {
        Text(this.blockerTitle())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#ffb4b4')
        Text(this.blockerMessage())
          .fontSize(13)
          .fontColor('#ffb4b4')
          .lineHeight(20)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .borderRadius(12)
      .backgroundColor('rgba(255,159,159,0.08)')
      .border({ width: 1, color: 'rgba(255,159,159,0.3)' })

      if (this.blockerSuggestions().length > 0) {
        Column({ space: 6 }) {
          Text('可以这样处理')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('rgba(255,255,255,0.85)')
          ForEach(this.blockerSuggestions(), (suggestion: string) => {
            Text(`· ${suggestion}`)
              .fontSize(13)
              .fontColor('rgba(255,255,255,0.75)')
              .lineHeight(20)
          }, (suggestion: string) => suggestion)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      if (this.pgsConversion() !== null) {
        Column({ space: 6 }) {
          Text('诊断信息')
            .fontSize(12)
            .fontColor(Theme.textFaint)
          Text(this.pgsEnvironmentText())
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .lineHeight(20)
          if (this.pgsDiagnosticExtra().length > 0) {
            Text(this.pgsDiagnosticExtra())
              .fontSize(13)
              .fontColor(Theme.textMuted)
              .lineHeight(20)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .borderRadius(12)
        .backgroundColor('rgba(255,255,255,0.025)')
        .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 预检通过：来源 → 目标 的结论卡 + 成本行 + 首读提示 + 覆盖提示 */
  @Builder
  ChosenSection() {
    Column({ space: 12 }) {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text(this.chosenLabel())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .layoutWeight(1)
            .maxLines(2)
          Text('→')
            .fontSize(14)
            .fontColor(Theme.textFaint)
          Text(this.currentOutputLabel())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.info)
            .maxLines(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Text(this.costLineText())
          .fontSize(13)
          .fontColor(Theme.textMuted)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .borderRadius(12)
      .backgroundColor('rgba(255,255,255,0.04)')
      .border({ width: 1, color: 'rgba(255,255,255,0.08)' })

      if (this.referenceNoticeText().length > 0) {
        Text(this.referenceNoticeText())
          .fontSize(13)
          .fontColor(Theme.info)
          .lineHeight(20)
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .borderRadius(8)
          .backgroundColor('rgba(127,176,255,0.07)')
          .border({ width: 1, color: 'rgba(127,176,255,0.25)' })
      }

      Text(`生成同目录${this.outputFilenameText()}，原字幕不变；离开页面不影响生成。`)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .lineHeight(20)

      if (this.alreadyGenerated()) {
        Text('已有 AI 字幕，将被覆盖。')
          .fontSize(13)
          .fontColor(Theme.warn)
          .lineHeight(20)
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .borderRadius(8)
          .backgroundColor('rgba(245,196,81,0.07)')
          .border({ width: 1, color: 'rgba(245,196,81,0.25)' })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 运行中进度卡：消息 + 进度条 + 统计 + 并发说明 + 重试提示 + 五段里程碑 */
  @Builder
  ProgressCard() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text(this.progressMessageText())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.info)
          .layoutWeight(1)
          .lineHeight(20)
        if (this.progressPercentText().length > 0) {
          Text(this.progressPercentText())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.info)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Column() {
        if (this.progressPercentText().length > 0) {
          Row()
            .height(6)
            .borderRadius(3)
            .backgroundColor(Theme.info)
            .width(this.progressPercentText())
        } else {
          Row()
            .height(6)
            .borderRadius(3)
            .backgroundColor(Theme.info)
            .width('33%')
            .opacity(0.55)
        }
      }
      .width('100%')
      .height(6)
      .borderRadius(3)
      .backgroundColor('rgba(255,255,255,0.08)')
      .clip(true)
      .alignItems(HorizontalAlign.Start)

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.progressStats(), (stat: string) => {
          Text(stat)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .margin({ right: 16, bottom: 4 })
        }, (stat: string) => stat)
      }
      .width('100%')

      if (this.activeBlocksText().length > 0) {
        Text(this.activeBlocksText())
          .fontSize(12)
          .fontColor('rgba(127,176,255,0.85)')
          .lineHeight(18)
      }
      if (this.progressNoticesText().length > 0) {
        Text(this.progressNoticesText())
          .fontSize(12)
          .fontColor('#ffd89a')
          .lineHeight(18)
      }

      Column({ space: 6 }) {
        ForEach(GEN_STAGES, (stage: TrackGenStage, index: number) => {
          this.StageRow(stage, index)
        }, (stage: TrackGenStage) => stage.label)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .borderRadius(12)
    .backgroundColor('rgba(127,176,255,0.07)')
    .border({ width: 1, color: 'rgba(127,176,255,0.25)' })
  }

  /** 五段里程碑的一行：✓ / 序号圆点 + 段名 + 「进行中」 */
  @Builder
  StageRow(stage: TrackGenStage, index: number) {
    Row({ space: 8 }) {
      Row() {
        if (this.stageCompleted(index)) {
          Text('✓')
            .fontSize(10)
            .fontColor('#7cf0a4')
        } else {
          Text(`${index + 1}`)
            .fontSize(10)
            .fontColor(this.stageCurrent(index) ? Theme.info : 'rgba(255,255,255,0.4)')
        }
      }
      .width(16)
      .height(16)
      .borderRadius(8)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .border({
        width: 1,
        color: this.stageCurrent(index) ? Theme.info
          : (this.stageCompleted(index) ? 'rgba(74,222,128,0.6)' : 'rgba(255,255,255,0.15)')
      })
      .backgroundColor(this.stageCurrent(index) ? 'rgba(127,176,255,0.15)'
        : (this.stageCompleted(index) ? 'rgba(74,222,128,0.1)' : 'transparent'))

      Text(this.stageLabel(stage, index))
        .fontSize(12)
        .fontWeight(this.stageCurrent(index) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.stageCurrent(index) ? Theme.info
          : (this.stageCompleted(index) ? 'rgba(255,255,255,0.7)' : 'rgba(255,255,255,0.35)'))
        .layoutWeight(1)
      if (this.stageCurrent(index)) {
        Text('进行中')
          .fontSize(11)
          .fontColor(Theme.textMuted)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 结束态结论卡：完成 / 未完成 + 结果说明（Agent、CLI 发起的任务也报出目标输出） */
  @Builder
  EndedCard() {
    Column({ space: 6 }) {
      Text(this.jobSucceeded() ? `${this.activeOutputLabel()}字幕生成完成` : `${this.activeOutputLabel()}字幕生成未完成`)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.jobSucceeded() ? '#7cf0a4' : '#ffb4b4')
      Text(this.resultMessage())
        .fontSize(13)
        .fontColor(this.jobSucceeded() ? '#7cf0a4' : '#ffb4b4')
        .opacity(0.85)
        .lineHeight(20)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .borderRadius(12)
    .backgroundColor(this.jobSucceeded() ? 'rgba(74,222,128,0.08)' : 'rgba(255,159,159,0.08)')
    .border({ width: 1, color: this.jobSucceeded() ? 'rgba(74,222,128,0.3)' : 'rgba(255,159,159,0.3)' })
  }

  /** 底部动作栏（web 弹窗底部的按钮组；空间不够自动换行） */
  @Builder
  SheetActions() {
    if (this.mode === 'status') {
      if (this.isJobRunning()) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
          this.CancelAction('关闭')
          this.StopAction()
        }
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 10, bottom: Theme.safeBottomInset + 16 })
      } else {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
          if (!this.jobSucceeded()) {
            this.RetryPreviewAction()
            this.AgentAction()
          }
          this.CancelAction('关闭')
        }
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 10, bottom: Theme.safeBottomInset + 16 })
      }
    } else if (!this.previewing) {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
        this.CancelAction(this.cancelLabel())
        if (this.recheckVisible()) {
          this.RecheckAction()
        }
        if (this.agentVisibleInPreview()) {
          this.AgentAction()
        }
        if (this.canPreparePgs()) {
          this.StartAction()
        } else if (this.hasChosen()) {
          this.ConfirmAction()
        }
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 10, bottom: Theme.safeBottomInset + 16 })
    }
  }

  @Builder
  CancelAction(label: string) {
    Button(label)
      .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
      .height(40)
      .fontSize(14)
      .fontColor(Theme.text)
      .borderRadius(12)
      .padding({ left: 18, right: 18 })
      .onClick((): void => {
        this.closeSheet();
      })
  }

  /** 停止生成：描边红（破坏性动作不抢主色） */
  @Builder
  StopAction() {
    Button(this.stopping ? '正在请求停止…' : '停止生成')
      .height(40)
      .fontSize(14)
      .fontColor('#ffb4b4')
      .borderRadius(12)
      .padding({ left: 18, right: 18 })
      .backgroundColor('rgba(255,159,159,0.08)')
      .border({ width: 1, color: 'rgba(255,159,159,0.3)' })
      .enabled(!this.stopping)
      .onClick((): void => {
        this.stop();
      })
  }

  /** 重新检查（预检被拦下时）：重新走一遍预检，参考源重置回服务端默认 */
  @Builder
  RecheckAction() {
    Button('重新检查')
      .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
      .height(40)
      .fontSize(14)
      .fontColor(Theme.text)
      .borderRadius(12)
      .padding({ left: 18, right: 18 })
      .onClick((): void => {
        this.loadPreview(null);
      })
  }

  /** 结束态未成功：重新预检 */
  @Builder
  RetryPreviewAction() {
    Button('重新预检')
      .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
      .height(40)
      .fontSize(14)
      .fontColor(Theme.text)
      .borderRadius(12)
      .padding({ left: 18, right: 18 })
      .onClick((): void => {
        this.loadPreview(null);
      })
  }

  /** 交给 Agent 处理：把问题、文件与期望参数打包成新会话的首条消息 */
  @Builder
  AgentAction() {
    Button(this.agentStarting ? '正在交给 Agent…' : '交给 Agent 处理')
      .height(40)
      .fontSize(14)
      .fontColor(Theme.info)
      .borderRadius(12)
      .padding({ left: 18, right: 18 })
      .backgroundColor('rgba(127,176,255,0.08)')
      .border({ width: 1, color: 'rgba(127,176,255,0.35)' })
      .enabled(!this.agentStarting)
      .onClick((): void => {
        this.handOffToAgent(this.agentReason());
      })
  }

  /** 开始生成（PGS 图片字幕先识别再生成；语言没选完禁用） */
  @Builder
  StartAction() {
    Button(this.starting ? '正在启动…' : `开始生成${this.currentOutputLabel()}`)
      .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
      .height(40)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor('#0b0d12')
      .borderRadius(12)
      .padding({ left: 18, right: 18 })
      .enabled(!this.starting && this.canConvertPgs())
      .onClick((): void => {
        this.start();
      })
  }

  /** 确认生成（预检通过的正常路径） */
  @Builder
  ConfirmAction() {
    Button(this.starting ? '正在启动…' : `确认生成${this.currentOutputLabel()}`)
      .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
      .height(40)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor('#0b0d12')
      .borderRadius(12)
      .padding({ left: 18, right: 18 })
      .enabled(!this.starting)
      .onClick((): void => {
        this.start();
      })
  }
}
