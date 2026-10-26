import { SmartPreferencesView, SubscriptionDetailView, WantedView } from '../api/Models';
import { JsonValue, jsonGet, jsonIntValue, jsonStringValue } from '../api/JsonValue';

/**
 * 智能订阅的客户端模型与呈现（对应 iOS `SmartSubscription.swift`）。
 * 智能接口返回未声明 schema 的 JSON；这里保留明确的类型与 snake_case 契约。
 */

/** 智能偏好摘要（后端 `SmartPreferences`，字段 snake_case） */
export class SmartPreferences {
  readonly resolution: string;
  readonly source: string;
  readonly waitSeconds: number;
  readonly allowUpgrade: boolean;
  readonly strictResolution: boolean;

  constructor(resolution: string, source: string, waitSeconds: number,
    allowUpgrade: boolean, strictResolution: boolean) {
    this.resolution = resolution;
    this.source = source;
    this.waitSeconds = waitSeconds;
    this.allowUpgrade = allowUpgrade;
    this.strictResolution = strictResolution;
  }

  resolutionLabel(): string {
    return this.resolution === '2160p' ? '4K' : '1080p';
  }

  targetLabel(): string {
    return `${this.resolutionLabel()} ${SmartPreferences.sourceLabel(this.source)}`;
  }

  static sourceLabel(source: string): string {
    if (source === 'web-dl') {
      return 'WEB-DL';
    }
    if (source === 'blu-ray') {
      return '蓝光';
    }
    if (source === 'remux') {
      return 'Remux';
    }
    return source;
  }

  waitLabel(): string {
    if (this.waitSeconds === 0) {
      return '尽快下载';
    }
    if (this.waitSeconds % 86400 === 0) {
      return `最多等 ${this.waitSeconds / 86400} 天`;
    }
    return `最多等 ${this.waitSeconds / 3600} 小时`;
  }

  static defaults(kind: string): SmartPreferences {
    return new SmartPreferences('2160p', 'web-dl', kind === 'movie' ? 86400 : 10800, true, false);
  }

  /** 从接口视图（`smart_profile.preferences`）构造 */
  static fromView(view: SmartPreferencesView): SmartPreferences {
    return new SmartPreferences(view.resolution, view.source, view.wait_seconds,
      view.allow_upgrade, view.strict_resolution);
  }

  /** 序列化为保存请求体里的偏好对象 */
  toView(): SmartPreferencesView {
    return {
      resolution: this.resolution,
      source: this.source,
      wait_seconds: this.waitSeconds,
      allow_upgrade: this.allowUpgrade,
      strict_resolution: this.strictResolution
    };
  }

  /** 从 `smart_policy`（不透明 JSON）严格解析；任一字段缺失或非法返回 null（同 iOS 的 Codable 解码失败） */
  static of(raw: Record<string, JsonValue> | null | undefined): SmartPreferences | null {
    if (raw === null || raw === undefined) {
      return null;
    }
    const resolution: string | null = jsonStringValue(jsonGet(raw, 'resolution'));
    const source: string | null = jsonStringValue(jsonGet(raw, 'source'));
    const waitSeconds: number | null = jsonIntValue(jsonGet(raw, 'wait_seconds'));
    const allowUpgrade: JsonValue = jsonGet(raw, 'allow_upgrade') ?? null;
    const strictResolution: JsonValue = jsonGet(raw, 'strict_resolution') ?? null;
    if (resolution === null || source === null || waitSeconds === null
      || typeof allowUpgrade !== 'boolean' || typeof strictResolution !== 'boolean') {
      return null;
    }
    return new SmartPreferences(resolution, source, waitSeconds, allowUpgrade, strictResolution);
  }
}

/** 这条订阅是否智能模式（同 iOS `isSmart`） */
export function isSmartSubscription(detail: SubscriptionDetailView): boolean {
  return detail.selection_mode === 'smart';
}

/** 智能订阅的警示条文案（智能模式且 smart_status 非 active 时才有；同 iOS `smartNotice`） */
export function smartNoticeOf(detail: SubscriptionDetailView): string {
  if (!isSmartSubscription(detail)) {
    return '';
  }
  const status: string = detail.smart_status ?? '';
  if (status.length === 0 || status === 'active') {
    return '';
  }
  if (status === 'invalid_policy') {
    return '智能设置无法读取，自动选择已暂停。';
  }
  if (status === 'shadow') {
    return '当前仅记录选择结果，尚未开启自动下载。';
  }
  return '智能自动选择已关闭。已有下载和入库继续完成。';
}

/**
 * 服务器已作出的分集决策（同 iOS `SmartSelection`）：只呈现，不再推断；
 * 没有合格候选时继续使用原有未播出 / 搜索状态。
 */
export class SmartSelection {
  private readonly values: Record<string, JsonValue>;

  private constructor(values: Record<string, JsonValue>) {
    this.values = values;
  }

  /** 工单处于 wanted 且决策里有候选键或决策处于指定原因时才呈现（同 iOS `SmartSelection.init?`） */
  static of(w: WantedView): SmartSelection | null {
    if (w.status !== 'wanted') {
      return null;
    }
    const state: Record<string, JsonValue> | null = w.selection_state ?? null;
    if (state === null) {
      return null;
    }
    const reason: string = SmartSelection.str(state, 'reason') ?? '';
    const hasCandidate: boolean = SmartSelection.str(state, 'candidate_key') !== null;
    const presentingReasons: string[] = ['identity_unconfirmed', 'manual_candidate_unavailable',
      'reconciling', 'submitting'];
    if (hasCandidate || presentingReasons.indexOf(reason) >= 0) {
      return new SmartSelection(state);
    }
    return null;
  }

  private static str(values: Record<string, JsonValue>, key: string): string | null {
    return jsonStringValue(jsonGet(values, key));
  }

  value(key: string): string | null {
    return SmartSelection.str(this.values, key);
  }

  rawValue(key: string): JsonValue | null {
    return jsonGet(this.values, key);
  }

  reason(): string {
    return SmartSelection.str(this.values, 'reason') ?? '';
  }

  /** 胶囊短名（观察中 / 等版本 / 选择中 / 待核对 / 提交中 / 寻找中，同 iOS `presentation`） */
  presentationLabel(): string {
    return this.presentation().label;
  }

  /** 状态说明（同 iOS `presentation.note`） */
  presentationNote(): string {
    return this.presentation().note;
  }

  private presentation(): SmartPresentation {
    const reason: string = this.reason();
    const manualExtended: JsonValue = jsonGet(this.values, 'manual_extended') ?? null;
    const extendedReasons: string[] = ['observing', 'waiting_target', 'waiting_series'];
    if (reason === 'user_extended'
      || (manualExtended === true && extendedReasons.indexOf(reason) >= 0)) {
      return new SmartPresentation('观察中', '按你延长的时间继续等待合适版本');
    }
    if (reason === 'identity_unconfirmed') {
      return new SmartPresentation('寻找中', '部分资源未通过影片身份核验，已跳过，继续寻找。');
    }
    if (reason === 'waiting_target') {
      return new SmartPresentation('等版本', '历史发布记录支持等待目标品质版本');
    }
    if (reason === 'waiting_series') {
      return new SmartPresentation('等版本', '已有合格候选，等待当前跟随版本');
    }
    if (reason === 'manual_requested') {
      return new SmartPresentation('选择中', '已请求立即下载，正在核验当前候选');
    }
    if (reason === 'manual_candidate_unavailable') {
      return new SmartPresentation('选择中', '指定候选已不可用，正在重新选择');
    }
    if (reason === 'reconciling') {
      return new SmartPresentation('待核对', '正在核对提交结果，系统会恢复同一任务');
    }
    if (reason === 'submitting') {
      return new SmartPresentation('提交中', '正在提交所选资源');
    }
    if (reason === 'deadline_fallback') {
      return new SmartPresentation('选择中', '等待上限已到，正在选择当前合格版本');
    }
    if (reason === 'published_window_elapsed') {
      return new SmartPresentation('选择中', '资源已发布一段时间，正在选择当前合格版本');
    }
    if (reason === 'observation_finished') {
      return new SmartPresentation('选择中', '观察结束，正在选择当前合格版本');
    }
    if (reason === 'target_available') {
      return new SmartPresentation('选择中', '目标版本已出现，正在选择');
    }
    return new SmartPresentation('观察中', '已有合格候选，短暂观察更合适的版本');
  }

  /** 跟随版本的人话（`a|b|3` → 「a · b · WEB-DL」，同 iOS `followingLabel`） */
  followingLabel(): string | null {
    const raw: string | null = this.value('following');
    if (raw === null || raw.length === 0) {
      return null;
    }
    const parts: string[] = raw.split('|');
    if (parts.length < 3) {
      return raw;
    }
    const sources: Record<string, string> = {
      '1': '电视 / DVD',
      '2': '压制版',
      '3': 'WEB-DL',
      '4': '蓝光',
      '5': 'Remux',
      '6': '原盘'
    };
    const source: string = sources[parts[2]] ?? '未知片源';
    return `${parts[0]} · ${parts[1]} · ${source}`;
  }
}

class SmartPresentation {
  readonly label: string;
  readonly note: string;

  constructor(label: string, note: string) {
    this.label = label;
    this.note = note;
  }
}
