import { Want } from '@kit.AbilityKit';

/**
 * 跨端接续与深链载荷（手机 ↔ 平板 ↔ 折叠屏 ↔ 智慧屏 分布式流转 + movieclaw:// 深链）。
 *
 * `kind`:
 * - `'play'`：直接续播指定条目（带 mediaItemId / fileId / season / episode / positionMs）
 * - `'item'`：打开库内条目详情（带 libraryId / mediaItemId / season / episode）
 * - `'search'`：打开全局搜索并填入关键词
 * - `'subscription'`：打开订阅详情（带 subscriptionId）
 * - `'continue_latest'`：小艺意图「继续播放」直达最近观看的一条
 */
export class ContinuationTarget {
  readonly kind: string;
  readonly origin: string;
  readonly libraryId: number;
  readonly mediaItemId: number;
  readonly fileId: number;
  readonly season: number;
  readonly episode: number;
  readonly positionMs: number;
  readonly subscriptionId: number;
  readonly query: string;
  readonly title: string;

  constructor(
    kind: string,
    origin: string = '',
    libraryId: number = 0,
    mediaItemId: number = 0,
    fileId: number = 0,
    season: number = 0,
    episode: number = 0,
    positionMs: number = 0,
    subscriptionId: number = 0,
    query: string = '',
    title: string = ''
  ) {
    this.kind = kind;
    this.origin = origin;
    this.libraryId = libraryId;
    this.mediaItemId = mediaItemId;
    this.fileId = fileId;
    this.season = season;
    this.episode = episode;
    this.positionMs = positionMs;
    this.subscriptionId = subscriptionId;
    this.query = query;
    this.title = title;
  }
}

function intOrZero(raw: string | undefined | null): number {
  if (raw === undefined || raw === null || raw.length === 0) {
    return 0;
  }
  const parsed: number = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function parseQueryMap(search: string): Map<string, string> {
  const out: Map<string, string> = new Map<string, string>();
  const trimmed: string = search.startsWith('?') ? search.substring(1) : search;
  if (trimmed.length === 0) {
    return out;
  }
  const pairs: string[] = trimmed.split('&');
  for (const pair of pairs) {
    const eq: number = pair.indexOf('=');
    if (eq > 0) {
      const k: string = decodeURIComponent(pair.substring(0, eq));
      const v: string = decodeURIComponent(pair.substring(eq + 1));
      out.set(k, v);
    }
  }
  return out;
}

/**
 * 解析 `movieclaw://` 深链（纯函数，单测与 EntryAbility 共用）：
 * - `movieclaw://play/{mediaItemId}?file=0&season=1&episode=2&pos=12000`
 * - `movieclaw://item/{libraryId}/{mediaItemId}?season=1&episode=2`
 * - `movieclaw://subscriptions/{subscriptionId}`
 * - `movieclaw://search?q=星际穿越`
 * - `movieclaw://continue`
 */
export function parseMovieClawUri(uri: string): ContinuationTarget | null {
  const trimmed: string = uri.trim();
  if (!trimmed.toLowerCase().startsWith('movieclaw://')) {
    return null;
  }
  const rest: string = trimmed.substring('movieclaw://'.length);
  const qIndex: number = rest.indexOf('?');
  const pathPart: string = qIndex >= 0 ? rest.substring(0, qIndex) : rest;
  const queryMap: Map<string, string> = qIndex >= 0 ? parseQueryMap(rest.substring(qIndex)) : new Map<string, string>();
  const segments: string[] = pathPart.split('/').filter((s: string): boolean => s.length > 0);
  if (segments.length === 0) {
    return null;
  }
  const head: string = segments[0].toLowerCase();
  if (head === 'continue') {
    return new ContinuationTarget('continue_latest');
  }
  if (head === 'play' && segments.length >= 2) {
    const mediaItemId: number = intOrZero(segments[1]);
    if (mediaItemId <= 0) {
      return null;
    }
    return new ContinuationTarget(
      'play',
      queryMap.get('origin') ?? '',
      intOrZero(queryMap.get('library')),
      mediaItemId,
      intOrZero(queryMap.get('file')),
      intOrZero(queryMap.get('season')),
      intOrZero(queryMap.get('episode')),
      intOrZero(queryMap.get('pos')),
      0,
      '',
      queryMap.get('title') ?? ''
    );
  }
  if (head === 'item' && segments.length >= 3) {
    const libraryId: number = intOrZero(segments[1]);
    const mediaItemId: number = intOrZero(segments[2]);
    if (libraryId <= 0 || mediaItemId <= 0) {
      return null;
    }
    return new ContinuationTarget(
      'item',
      queryMap.get('origin') ?? '',
      libraryId,
      mediaItemId,
      0,
      intOrZero(queryMap.get('season')),
      intOrZero(queryMap.get('episode'))
    );
  }
  if ((head === 'subscription' || head === 'subscriptions') && segments.length >= 2) {
    const subId: number = intOrZero(segments[1]);
    if (subId > 0) {
      return new ContinuationTarget('subscription', '', 0, 0, 0, 0, 0, 0, subId);
    }
    return null;
  }
  if (head === 'search') {
    return new ContinuationTarget('search', '', 0, 0, 0, 0, 0, 0, 0, queryMap.get('q') ?? '');
  }
  return null;
}

/** 把活跃目标编码进分布式接续参数表 */
export function encodeContinueParams(target: ContinuationTarget, out: Record<string, Object>): void {
  out['mcContinueKind'] = target.kind;
  out['mcOrigin'] = target.origin;
  out['mcLibraryId'] = target.libraryId;
  out['mcMediaItemId'] = target.mediaItemId;
  out['mcFileId'] = target.fileId;
  out['mcSeason'] = target.season;
  out['mcEpisode'] = target.episode;
  out['mcPositionMs'] = target.positionMs;
  out['mcSubscriptionId'] = target.subscriptionId;
  out['mcQuery'] = target.query;
  out['mcTitle'] = target.title;
  out['ohos.extra.param.key.supportContinuePageStack'] = false;
}

/** 从分布式接续或卡片拉起的 parameters 里解码目标（兼容 FormKit 序列化在 parameters['params'] 中的 JSON 串） */
export function decodeContinueParams(params: Record<string, Object> | undefined): ContinuationTarget | null {
  if (params === undefined) {
    return null;
  }
  let source: Record<string, Object> = params;
  if (source['mcContinueKind'] === undefined || source['mcContinueKind'] === null) {
    const nested: Object | undefined = source['params'];
    if (typeof nested === 'string' && nested.length > 0) {
      try {
        const parsed: Record<string, Object> = JSON.parse(nested) as Record<string, Object>;
        if (parsed !== null && parsed !== undefined) {
          source = parsed;
        }
      } catch (_err) {
        return null;
      }
    }
  }
  const rawKind: Object | undefined = source['mcContinueKind'];
  if (rawKind === undefined || rawKind === null) {
    return null;
  }
  const kind: string = `${rawKind}`;
  if (kind.length === 0) {
    return null;
  }
  const origin: string = source['mcOrigin'] !== undefined && source['mcOrigin'] !== null ? `${source['mcOrigin']}` : '';
  const libraryId: number = intOrZero(source['mcLibraryId'] !== undefined ? `${source['mcLibraryId']}` : '');
  const mediaItemId: number = intOrZero(source['mcMediaItemId'] !== undefined ? `${source['mcMediaItemId']}` : '');
  const fileId: number = intOrZero(source['mcFileId'] !== undefined ? `${source['mcFileId']}` : '');
  const season: number = intOrZero(source['mcSeason'] !== undefined ? `${source['mcSeason']}` : '');
  const episode: number = intOrZero(source['mcEpisode'] !== undefined ? `${source['mcEpisode']}` : '');
  const positionMs: number = intOrZero(source['mcPositionMs'] !== undefined ? `${source['mcPositionMs']}` : '');
  const subId: number = intOrZero(source['mcSubscriptionId'] !== undefined ? `${source['mcSubscriptionId']}` : '');
  const query: string = source['mcQuery'] !== undefined && source['mcQuery'] !== null ? `${source['mcQuery']}` : '';
  const title: string = source['mcTitle'] !== undefined && source['mcTitle'] !== null ? `${source['mcTitle']}` : '';
  return new ContinuationTarget(kind, origin, libraryId, mediaItemId, fileId, season, episode,
    positionMs, subId, query, title);
}

/**
 * 分布式跨端流转与深链中转站（HarmonyOS NEXT 独占生态能力）：
 * - 播放页 / 详情页实时登记当前活跃上下文（`activeTarget`），任务中心/靠近流转触发 `onContinue` 时原样打包；
 * - 对端（或深链/桌面卡片/小艺意图）拉起后投进 `pending`，由 `MainTabsPage` / `TvShell` 响应式消费。
 */
@ObservedV2
export class ContinuationBridge {
  private static instance: ContinuationBridge | null = null;

  static shared(): ContinuationBridge {
    if (ContinuationBridge.instance === null) {
      ContinuationBridge.instance = new ContinuationBridge();
    }
    return ContinuationBridge.instance;
  }

  private activeTarget: ContinuationTarget | null = null;
  private activePositionGetter: (() => number) | null = null;
  private pendingTarget: ContinuationTarget | null = null;
  @Trace pendingSeq: number = 0;

  /** 播放器在播时登记：onContinue 当场向 positionGetter 要毫秒级进度 */
  publishPlayback(
    origin: string,
    mediaItemId: number,
    fileId: number,
    season: number,
    episode: number,
    positionGetter: () => number,
    title: string = '',
    libraryId: number = 0
  ): void {
    this.activeTarget = new ContinuationTarget('play', origin, libraryId, mediaItemId, fileId,
      season, episode, 0, 0, '', title);
    this.activePositionGetter = positionGetter;
  }

  /** 条目详情页展示时登记：流转到平板/智慧屏直接落同一部作品 */
  publishItem(origin: string, libraryId: number, mediaItemId: number, season: number = 0, episode: number = 0,
    title: string = ''): void {
    this.activeTarget = new ContinuationTarget('item', origin, libraryId, mediaItemId, 0,
      season, episode, 0, 0, '', title);
    this.activePositionGetter = null;
  }

  clearActive(): void {
    this.activeTarget = null;
    this.activePositionGetter = null;
  }

  /** UIAbility.onContinue 调用：把当前播放/详情状态写入 wantParam */
  fillContinueWant(wantParam: Record<string, Object>): boolean {
    const active: ContinuationTarget | null = this.activeTarget;
    if (active === null) {
      return false;
    }
    const pos: number = this.activePositionGetter !== null
      ? Math.max(0, Math.floor(this.activePositionGetter()))
      : active.positionMs;
    const resolved: ContinuationTarget = new ContinuationTarget(
      active.kind,
      active.origin,
      active.libraryId,
      active.mediaItemId,
      active.fileId,
      active.season,
      active.episode,
      pos,
      active.subscriptionId,
      active.query,
      active.title
    );
    encodeContinueParams(resolved, wantParam);
    return true;
  }

  /** EntryAbility / 小艺意图投递目标 */
  handOff(target: ContinuationTarget): void {
    this.pendingTarget = target;
    this.pendingSeq = this.pendingSeq + 1;
  }

  /** 从 Ability 的 Want 里识别分布式接续参数或 `movieclaw://` 深链 */
  captureFromWant(want: Want): boolean {
    const fromParams: ContinuationTarget | null = decodeContinueParams(want.parameters);
    if (fromParams !== null) {
      this.handOff(fromParams);
      return true;
    }
    const uri: string = want.uri ?? '';
    if (uri.length > 0) {
      const fromUri: ContinuationTarget | null = parseMovieClawUri(uri);
      if (fromUri !== null) {
        this.handOff(fromUri);
        return true;
      }
    }
    return false;
  }

  takePending(): ContinuationTarget | null {
    const target: ContinuationTarget | null = this.pendingTarget;
    this.pendingTarget = null;
    return target;
  }
}
