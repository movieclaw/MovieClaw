import { Formatters } from '../common/Formatters';
import { ActivityView, ResourceTimingView, SubscriptionDownloadView, WantedUpgradeView, WantedView } from '../api/Models';
import { JsonMap, JsonValue, jsonArrayValue, jsonGet, jsonIntValue, jsonObjectValue, jsonStringValue } from '../api/JsonValue';

/**
 * 追踪项（工单）的呈现逻辑（对应 iOS `SubsColor` / `Milestone` / `WantedPresentation` / `WantedLogic`
 * 与 Web `subscription-inspector-view.tsx`）。
 *
 * 每集展开成一条固定形状的里程碑链（播出 → 搜索 → 投递 → 下载 → 入库 →（洗版）），
 * 第一个非完成节点就是这集卡住的地方。
 */

/** 订阅侧配色（与 iOS `SubsColor` 同值） */
export class SubsColor {
  /** 已入库 / 收尾 */
  static readonly ok: string = '#4ade80';
  /** 下载中 / 排队 / 常规动作 */
  static readonly info: string = '#7fb0ff';
  /** 进度条「下载中」段、追踪中状态点 */
  static readonly infoSoft: string = '#6aa7ff';
  /** 等待资源 / 预测窗口 / 待播出 */
  static readonly warn: string = '#f5c451';
  static readonly danger: string = '#ff6b6b';
  /** 洗版专属青色 */
  static readonly upgrade: string = '#2dd4bf';
  /** 「洗版中」报告徽标 */
  static readonly upgradeInFlight: string = '#34d399';
  /** 未定档 / 无法确认 */
  static readonly neutral: string = '#9ca3af';
  /** 错误文字（链上的红色注解） */
  static readonly reason: string = '#ff8a8a';
}

/** 里程碑链的一站：state = done / now / todo / fail */
export class Milestone {
  readonly label: string;
  readonly state: string;
  readonly time: string;
  readonly detail: string;
  readonly why: string;
  readonly sources: string[];

  constructor(label: string, state: string, detail: string, time: string = '', why: string = '',
    sources: string[] = []) {
    this.label = label;
    this.state = state;
    this.detail = detail;
    this.time = time;
    this.why = why;
    this.sources = sources;
  }
}

/** 工单一行的状态：胶囊文字 + 颜色 + 说明 */
export class WantedPresentation {
  readonly label: string;
  readonly color: string;
  readonly note: string;

  constructor(label: string, color: string, note: string) {
    this.label = label;
    this.color = color;
    this.note = note;
  }

  /** 长词 → 胶囊三字短名 */
  shortLabel(): string {
    if (this.label === '入库失败') {
      return '失败';
    }
    if (this.label === '已提交下载') {
      return '已提交';
    }
    if (this.label === '排队搜索') {
      return '排队中';
    }
    if (this.label === '预测窗口') {
      return '预测中';
    }
    return this.label;
  }
}

/** 资源发布时间预测（`release_forecast` 是自由结构，按 Web `ReleaseForecast` 取字段） */
export class ReleaseForecast {
  readonly version: number;
  readonly targetAirDate: string;
  readonly predictedAt: string;
  readonly windowStart: string;
  readonly windowEnd: string;
  readonly confidence: string;
  readonly siteIds: string[];

  private constructor(version: number, targetAirDate: string, predictedAt: string, windowStart: string,
    windowEnd: string, confidence: string, siteIds: string[]) {
    this.version = version;
    this.targetAirDate = targetAirDate;
    this.predictedAt = predictedAt;
    this.windowStart = windowStart;
    this.windowEnd = windowEnd;
    this.confidence = confidence;
    this.siteIds = siteIds;
  }

  static of(raw: Record<string, JsonValue> | null | undefined): ReleaseForecast | null {
    if (raw === null || raw === undefined) {
      return null;
    }
    const map: JsonMap | null = jsonObjectValue(raw);
    if (map === null) {
      return null;
    }
    const version: number = rawInt(map, 'version') ?? 0;
    const siteIds: string[] = [];
    const sites: JsonValue | null = jsonGet(map, 'sites');
    const list = jsonArrayValue(sites);
    if (list !== null) {
      for (const item of list) {
        const id: string | null = jsonStringValue(jsonGet(item, 'site_id'));
        if (id !== null) {
          siteIds.push(id);
        }
      }
    }
    return new ReleaseForecast(version, rawStr(map, 'target_air_date'), rawStr(map, 'predicted_at'),
      rawStr(map, 'window_start'), rawStr(map, 'window_end'), rawStr(map, 'confidence'), siteIds);
  }
}

function rawStr(map: JsonMap, key: string): string {
  const value: JsonValue | undefined = map[key];
  return jsonStringValue(value === undefined ? null : value) ?? '';
}

function rawInt(map: JsonMap, key: string): number | null {
  const value: JsonValue | undefined = map[key];
  return jsonIntValue(value === undefined ? null : value);
}

/** 秒 → 「N 分钟 / N 小时」（对应 iOS `SubsFormat.duration`） */
export function durationSeconds(seconds: number): string {
  if (seconds <= 0) {
    return '';
  }
  if (seconds < 60) {
    return `${seconds} 秒`;
  }
  if (seconds < 3600) {
    return `${Math.round(seconds / 60)} 分钟`;
  }
  const hours: number = Math.round(seconds / 360) / 10;
  return hours === Math.round(hours) ? `${Math.round(hours)} 小时` : `${hours} 小时`;
}

export class WantedLogic {
  /** 工单 → 调度语义下的状态说明 */
  static presentation(w: WantedView, nowMs: number): WantedPresentation {
    const upgrade: WantedUpgradeView | null = w.upgrade ?? null;
    if (w.status === 'imported') {
      if (upgrade !== null && upgrade.active) {
        return new WantedPresentation('洗版中', SubsColor.upgrade,
          `当前 ${upgrade.current_label} → 目标 ${upgrade.target_label}`);
      }
      if (upgrade !== null && upgrade.indeterminate) {
        return new WantedPresentation('已入库', SubsColor.ok,
          `${upgrade.current_label} · 无法确认是否低于洗版目标，不自动洗；可在季标题「标注片源」，或手动选种替换`);
      }
      if (upgrade !== null) {
        return new WantedPresentation('已入库', SubsColor.ok,
          `${upgrade.current_label} · 入库于 ${Formatters.dateTime(w.imported_at ?? null)}`);
      }
      return new WantedPresentation('已入库', SubsColor.ok, `入库于 ${Formatters.dateTime(w.imported_at ?? null)}`);
    }
    if (w.status === 'downloaded') {
      return new WantedPresentation('已下载', SubsColor.ok,
        `完成于 ${Formatters.dateTime(w.downloaded_at ?? w.grabbed_at ?? null)}，待整理入库`);
    }
    if (w.status === 'grabbed') {
      return new WantedPresentation('已提交下载', SubsColor.ok,
        `${Formatters.relative(w.grabbed_at ?? null)}提交给下载器`);
    }
    const nextSearch: string = w.next_search_at ?? '';
    if (nextSearch.length === 0) {
      return new WantedPresentation('未定档', SubsColor.neutral, '上映/播出日期未公布，定档后自动排队');
    }
    const due: number | null = Formatters.date(nextSearch);
    const airDate: string = w.air_date ?? '';
    const forecast: ReleaseForecast | null = ReleaseForecast.of(w.release_forecast ?? null);
    if (airDate.length > 0 && forecast !== null && forecast.version === 1
      && forecast.targetAirDate === airDate && forecast.confidence !== 'volatile'
      && forecast.siteIds.length > 0) {
      const windowEnd: number | null = Formatters.date(forecast.windowEnd);
      if (windowEnd !== null && windowEnd >= nowMs) {
        const sites: string = forecast.siteIds.slice(0, 2).join('、');
        return new WantedPresentation('预测窗口', SubsColor.warn,
          `预计 ${Formatters.dateTime(forecast.windowStart)} ～ ${Formatters.dateTime(forecast.windowEnd)}，重点探测 ${sites}`);
      }
    }
    if (airDate.length > 0) {
      const air: number | null = Formatters.date(airDate);
      if (air !== null && air > nowMs) {
        return new WantedPresentation('待播出', SubsColor.warn,
          `${airDate} 播出，${Formatters.dateTime(nextSearch)} 起兜底搜索`);
      }
    }
    if (due !== null && due <= nowMs) {
      return new WantedPresentation('排队搜索', SubsColor.info,
        w.last_search_at !== null && w.last_search_at !== undefined
          ? `上次搜索 ${Formatters.relative(w.last_search_at)}` : '等待搜索任务执行');
    }
    if ((w.last_search_at === null || w.last_search_at === undefined)
      && due !== null && due - nowMs > 3600 * 1000) {
      return new WantedPresentation('待搜索', SubsColor.warn, `档期未到，${Formatters.dateTime(nextSearch)} 起兜底搜索`);
    }
    return new WantedPresentation('冷却中', SubsColor.info, `暂无合适资源，${Formatters.dateTime(nextSearch)} 再试`);
  }

  /** 实时下载快照 → 一行进度说明 */
  static downloadNote(d: SubscriptionDownloadView): string {
    if (d.state === 'missing') {
      return '种子已不在下载器中（可能被手动删除），稍后自动重新寻找资源';
    }
    const percentValue: number | null = d.progress ?? null;
    const pct: string = percentValue === null ? '' : `${Math.floor(percentValue * 100)}%`;
    if (d.state === 'completed') {
      return '已下载完成，等待整理入库';
    }
    if (d.state === 'paused') {
      return `${pct} · 已在下载器中暂停`;
    }
    if (d.state === 'error') {
      const message: string = d.error_message ?? '';
      if (message.length === 0) {
        return `${pct} · 下载任务出错；换源判定已暂停，需管理员在下载器中处理`;
      }
      return `${pct} · ${message}；换源判定已暂停，请在下载器中处理`;
    }
    if (d.state === 'stalled') {
      return `${pct} · 等待连接做种`;
    }
    const parts: string[] = [];
    if (pct.length > 0) {
      parts.push(pct);
    }
    const speed: number | null = d.dlspeed_bytes ?? null;
    if (speed !== null && speed > 0) {
      parts.push(`${Formatters.bytes(speed)}/s`);
    }
    const eta: number | null = d.eta_seconds ?? null;
    if (eta !== null) {
      parts.push(`剩余约 ${durationSeconds(eta)}`);
    }
    const size: number | null = d.size_bytes ?? null;
    if (parts.length === 1 && size !== null && size > 0) {
      parts.push(Formatters.bytes(size));
    }
    return parts.filter((part: string): boolean => part.length > 0).join(' · ');
  }

  /** 资源时间链 → 「隔了多久才拉到」；超过 7 天的存量耗时不展示 */
  static resourceTimingNote(timing: ResourceTimingView | null, previous: boolean): string {
    if (timing === null) {
      return '';
    }
    const total: number | null = timing.publish_to_submit_seconds ?? null;
    if (total !== null && total > 7 * 24 * 3600) {
      return '';
    }
    const prefix: string = `${previous ? '上次 · ' : ''}${timing.dry_run ? '模拟 · ' : ''}${timing.site_id}：`;
    const seen: number | null = timing.publish_to_seen_seconds ?? null;
    const submit: number | null = timing.seen_to_submit_seconds ?? null;
    if (seen !== null && submit !== null && total !== null) {
      return `${prefix}资源发布后 ${delayText(seen)}进入索引，${delayText(submit)}后提交下载器（总耗时 ${delayText(total)}）`;
    }
    if (total !== null) {
      return `${prefix}资源发布后 ${delayText(total)}提交下载器`;
    }
    if (submit !== null) {
      return `${prefix}进入索引后 ${delayText(submit)}提交下载器`;
    }
    return '';
  }

  /** 工单 → 里程碑链：播出 → 搜索 → 投递 → 下载 → 入库 →（洗版） */
  static milestones(w: WantedView, isMovie: boolean, live: SubscriptionDownloadView | null,
    failure: ActivityView | null, nowMs: number): Milestone[] {
    const chain: Milestone[] = [];
    const upgrade: WantedUpgradeView | null = w.upgrade ?? null;
    // 1. 播出 / 上映
    if (isMovie) {
      const undated: boolean = w.status === 'wanted'
        && (w.next_search_at === null || w.next_search_at === undefined);
      chain.push(undated
        ? new Milestone('上映', 'now', '上映日期未公布，定档后自动排队')
        : new Milestone('上映', 'done', '已定档或已上映'));
    } else {
      const airDate: string = w.air_date ?? '';
      if (airDate.length > 0) {
        const air: number | null = Formatters.date(airDate);
        const future: boolean = air !== null && air > nowMs;
        chain.push(new Milestone('播出', 'done', future ? `${airDate} 播出` : '已播出', airDate));
      } else {
        chain.push(new Milestone('播出', 'now', '播出日期未公布，定档后自动排队'));
      }
    }
    const preAir: boolean = chain[0].state === 'now';

    // 2. 搜索
    if (w.status !== 'wanted') {
      chain.push(new Milestone('搜索', 'done',
        w.search_attempts > 0 ? `搜索 ${w.search_attempts} 次后命中` : '被动匹配命中',
        (w.last_search_at === null || w.last_search_at === undefined) ? '' : Formatters.relative(w.last_search_at)));
    } else if (preAir) {
      chain.push(new Milestone('搜索', 'todo', '定档后进入搜索队列'));
    } else {
      const reject: string = w.last_reject_reason ?? '';
      chain.push(new Milestone('搜索', 'now', WantedLogic.presentation(w, nowMs).note,
        w.search_attempts > 0 ? `已搜 ${w.search_attempts} 次` : '',
        reject.length > 0 ? `最近一次被拒：${reject}` : ''));
    }

    // 3. 投递
    const grabbedAt: string = w.grabbed_at ?? '';
    if (grabbedAt.length > 0) {
      const sources: string[] = [];
      const title: string = w.grab_title ?? '';
      if (title.length > 0) {
        sources.push(title);
      }
      const timing: string = WantedLogic.resourceTimingNote(w.resource_timing ?? null, false);
      if (timing.length > 0) {
        sources.push(timing);
      }
      chain.push(new Milestone('投递', 'done', '已提交下载器', Formatters.relative(grabbedAt), '', sources));
    } else {
      const lastTiming: string = WantedLogic.resourceTimingNote(w.resource_timing ?? null, true);
      const dispatchFailure: ActivityView | null = failure !== null && failure.type === 'dispatch_failed' ? failure : null;
      chain.push(new Milestone('投递', 'todo',
        dispatchFailure !== null ? '上次投递未成功，已退回队列' : '尚未找到符合规则组的资源',
        '', dispatchFailure !== null ? dispatchFailure.message : '',
        lastTiming.length > 0 ? [lastTiming] : []));
    }

    // 4. 下载
    const downloadedAt: string = w.downloaded_at ?? w.imported_at ?? '';
    if (downloadedAt.length > 0) {
      chain.push(new Milestone('下载', 'done', '全部落盘', Formatters.relative(downloadedAt)));
    } else if (grabbedAt.length > 0) {
      chain.push(new Milestone('下载', 'now',
        live !== null ? WantedLogic.downloadNote(live) : '已提交下载器，等待进度汇报', '进行中'));
    } else {
      chain.push(new Milestone('下载', 'todo', '等待投递完成'));
    }

    // 5. 入库
    const importedAt: string = w.imported_at ?? '';
    if (importedAt.length > 0) {
      chain.push(new Milestone('入库', 'done',
        upgrade !== null ? `已整理入库 · ${upgrade.current_label}` : '已整理入库',
        Formatters.relative(importedAt)));
    } else if (failure !== null && failure.type === 'import_failed') {
      chain.push(new Milestone('入库', 'fail', '下载完成了，但 movieclaw 无法把文件整理入库', '', failure.message));
    } else if (w.downloaded_at !== null && w.downloaded_at !== undefined) {
      chain.push(new Milestone('入库', 'now', '下载完成，等待整理入库'));
    } else {
      chain.push(new Milestone('入库', 'todo', '下载完成后自动整理'));
    }

    // 6. 洗版（规则组配了洗版目标才有）
    if (upgrade !== null) {
      if (upgrade.active) {
        chain.push(new Milestone('洗版', 'now',
          `当前 ${upgrade.current_label} → 目标 ${upgrade.target_label}`,
          upgrade.search_attempts > 0 ? `已搜 ${upgrade.search_attempts} 次` : ''));
      } else if (upgrade.indeterminate) {
        chain.push(new Milestone('洗版', 'now',
          `${upgrade.current_label} · 无法确认是否低于洗版目标，不自动洗；可在季标题「标注片源」或手动选种替换`));
      } else {
        chain.push(new Milestone('洗版', 'done', `当前 ${upgrade.current_label}`));
      }
    }
    return chain;
  }

  /** 卡点 = 第一个非 done 的站；全 done 时亮终点站 */
  static stuckIndex(chain: Milestone[]): number {
    for (let index = 0; index < chain.length; index++) {
      if (chain[index].state !== 'done') {
        return index;
      }
    }
    return Math.max(chain.length - 1, 0);
  }

  /** 工单 id → 此刻仍未解决的失败活动（该工单最新一条活动仍是入库/投递失败） */
  static pendingFailures(activities: ActivityView[]): Record<string, ActivityView> {
    const failures: Record<string, ActivityView> = {};
    const seen: number[] = [];
    for (const activity of activities) {
      const wantedId: number | null = activity.wanted_item_id ?? null;
      if (wantedId === null || seen.indexOf(wantedId) >= 0) {
        continue;
      }
      seen.push(wantedId);
      if (activity.type === 'import_failed' || activity.type === 'dispatch_failed') {
        failures[`${wantedId}`] = activity;
      }
    }
    return failures;
  }

  /** 取某工单的失败活动（没有则 null） */
  static failureFor(failures: Record<string, ActivityView>, wantedId: number): ActivityView | null {
    const value: ActivityView | undefined = failures[`${wantedId}`];
    return value === undefined ? null : value;
  }

  /** 活动类型的圆点颜色（同 iOS `WantedLogic.activityColor`） */
  static activityColor(type: string): string {
    if (type === 'grabbed' || type === 'match_accepted' || type === 'completed'
      || type === 'downloaded' || type === 'imported' || type === 'replacement_promoted') {
      return SubsColor.ok;
    }
    if (type === 'upgrade_grabbed' || type === 'upgraded') {
      return SubsColor.upgrade;
    }
    if (type === 'match_rejected' || type === 'dispatch_failed' || type === 'import_failed') {
      return SubsColor.danger;
    }
    if (type === 'paused' || type === 'download_stalled'
      || type === 'upgrade_verify_failed' || type === 'spec_mismatch') {
      return SubsColor.warn;
    }
    return SubsColor.info;
  }
}

function delayText(seconds: number): string {
  return seconds < 60 ? '不到 1 分钟' : durationSeconds(seconds);
}
