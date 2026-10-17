import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/**
 * 离线下载的本机存档（对应 iOS `Shared/Offline/OfflineModels.swift`，设计
 * docs/design/offline-download.md §3）。
 *
 * 每个条目一个文件夹，文件夹本身就是事实来源：删文件夹即删干净。接口模型（详情、库、
 * 分集）原样存 JSON，离线时原样喂给页面；这里的是**自有结构**，都带 `format` 版本号，
 * 不认识的版本跳过、不崩。
 *
 * ```
 * <filesDir>/Offline/<sha(实例号|用户名)>/
 *   owner.json
 *   items/<条目>/summary.json · detail.json · library.json · seasons/<季>.json · progress.json · images/
 *   items/<条目>/units/<文件>/unit.json · playback.json · media.<扩展名> · subs/ · fonts/
 *   viewings/<观看记录>.json
 * ```
 *
 * 日期一律存**毫秒时间戳**（ArkTS 没有 Codable，JSON 里裸 Date 不可靠）。
 */

/**
 * 账号键 = sha256("实例号|用户名") 前 16 字节的 hex（32 个字符）。
 * 按实例号认服务器：同一台服务器换地址（局域网 IP ↔ 域名），副本不丢。
 */
export class OfflineOwnerKey {
  static make(instanceId: string, username: string): string {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: encoder.encodeInto(`${instanceId}|${username}`) });
    const digest: cryptoFramework.DataBlob = md.digestSync();
    const bytes: Uint8Array = digest.data;
    let hex: string = '';
    for (let i: number = 0; i < 16 && i < bytes.length; i++) {
      hex += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    }
    return hex;
  }
}

/** 本机副本属于哪台服务器上的哪个账号（存储页「其他账号」一节也读它） */
export class OfflineOwner {
  static readonly currentFormat: number = 1;
  readonly format: number = OfflineOwner.currentFormat;
  instanceId: string;
  username: string;
  /** 最近一次用的服务器地址（下载、补传都发到这里） */
  origin: string;

  constructor(instanceId: string, username: string, origin: string) {
    this.instanceId = instanceId;
    this.username = username;
    this.origin = origin;
  }

  key(): string {
    return OfflineOwnerKey.make(this.instanceId, this.username);
  }
}

/** 单元状态机的取值（独立类：ArkTS 的 enum 不支持类内常量风格） */
export class OfflineUnitState {
  /** 拉清单、字幕、字体、图片（要在线） */
  static readonly preparing: string = 'preparing';
  /** 视频下载已排队、等轮到它（全局一次只下一个） */
  static readonly queued: string = 'queued';
  static readonly downloading: string = 'downloading';
  /** 用户暂停（部分文件留在盘上，继续时按 Range 续传） */
  static readonly paused: string = 'paused';
  static readonly failed: string = 'failed';
  static readonly done: string = 'done';
}

/**
 * 一个播放单元（一部电影 / 一集）的本机副本：期望状态机本体（`unit.json`）。
 * 要下什么记在这里；实际有没有在下载由对账（`OfflineDownloader.reconcile`）补齐。
 */
export class OfflineUnit {
  static readonly currentFormat: number = 1;
  readonly format: number = OfflineUnit.currentFormat;
  fileId: number;
  mediaItemId: number;
  season: number;
  episode: number;
  /** original / 1080p / 720p / 480p */
  profile: string;
  profileLabel: string;
  state: string;
  expectedBytes: number;
  receivedBytes: number;
  /** 视频存盘的扩展名（原画按原容器，转码档 mp4） */
  fileExtension: string;
  exportId: string | null;
  /** 这一集的剧照（下载中的行用；电影为空、用条目的横幅） */
  stillUrl: string | null;
  /** 失败原因（给人看的中文） */
  error: string | null;
  /** 失败能不能自动重试（网络类、5xx、排队中能；无权限、文件没了、空间不足不能） */
  retryable: boolean;
  attempts: number;
  /** 到点重试的时间戳（毫秒；null = 不自动重试） */
  nextRetryAt: number | null;
  createdAt: number;
  completedAt: number | null;
  /** 本机打不开（引擎读不了）：提示重新下载 */
  damaged: boolean;
  /** 服务器还在排队转码（导出接口回 503）时它说的在等什么；内部仍按失败到点重试走 */
  transcodeWait: string | null;
  /** 上次下载到的 ETag（续传时 If-Range 用；变了就从头下，不拼坏文件） */
  etag: string | null;

  constructor(fileId: number, mediaItemId: number, season: number, episode: number,
    profile: string, profileLabel: string, state: string, expectedBytes: number,
    fileExtension: string, createdAt: number) {
    this.fileId = fileId;
    this.mediaItemId = mediaItemId;
    this.season = season;
    this.episode = episode;
    this.profile = profile;
    this.profileLabel = profileLabel;
    this.state = state;
    this.expectedBytes = expectedBytes;
    this.receivedBytes = 0;
    this.fileExtension = fileExtension;
    this.exportId = null;
    this.stillUrl = null;
    this.error = null;
    this.retryable = true;
    this.attempts = 0;
    this.nextRetryAt = null;
    this.createdAt = createdAt;
    this.completedAt = null;
    this.damaged = false;
    this.transcodeWait = null;
    this.etag = null;
  }

  get isMovie(): boolean {
    return this.season === 0 && this.episode === 0;
  }

  get playable(): boolean {
    return this.state === OfflineUnitState.done && !this.damaged;
  }

  /** 在排队等服务器转码（不是出错） */
  get waitingForTranscode(): boolean {
    return this.state === OfflineUnitState.failed && this.retryable && this.transcodeWait !== null;
  }

  /** 界面上要用警告色、写「重试」的：真失败（排队转码不算）或文件损坏 */
  get needsAttention(): boolean {
    return (this.state === OfflineUnitState.failed && !this.waitingForTranscode) || this.damaged;
  }

  get isActive(): boolean {
    return this.state !== OfflineUnitState.done;
  }

  get mediaFileName(): string {
    return `media.${this.fileExtension}`;
  }

  get progressFraction(): number {
    if (this.expectedBytes <= 0) {
      return 0;
    }
    return Math.min(1, this.receivedBytes / this.expectedBytes);
  }

  unitKey(): string {
    return `${this.season}-${this.episode}`;
  }
}

/** 条目的展示摘要（建索引用的小文件）：下载页、存储页只读它 */
export class OfflineItemSummary {
  static readonly currentFormat: number = 1;
  readonly format: number = OfflineItemSummary.currentFormat;
  mediaItemId: number;
  libraryId: number;
  libraryName: string;
  libraryKind: string;
  /** movie / tv / video */
  kind: string;
  title: string;
  year: number | null;
  posterUrl: string | null;
  backdropUrl: string | null;
  /** 最近一次加下载的时间（「最近下载」排序） */
  addedAt: number;

  constructor(mediaItemId: number, libraryId: number, libraryName: string, libraryKind: string,
    kind: string, title: string, year: number | null, posterUrl: string | null,
    backdropUrl: string | null, addedAt: number) {
    this.mediaItemId = mediaItemId;
    this.libraryId = libraryId;
    this.libraryName = libraryName;
    this.libraryKind = libraryKind;
    this.kind = kind;
    this.title = title;
    this.year = year;
    this.posterUrl = posterUrl;
    this.backdropUrl = backdropUrl;
    this.addedAt = addedAt;
  }
}

/** 播放一个本机单元要的数据（playback.json；字幕/字体是存盘文件名） */
export class OfflineSubtitleSpec {
  /** 播放器里的轨引用：一律 `external:<存盘文件名>`（原画档的内封轨由引擎自己读） */
  ref: string;
  fileName: string;
  /** vtt（文本）/ ass */
  kind: string;
  language: string | null;
  title: string | null;
  isDefault: boolean;
  isForced: boolean;
  isAi: boolean;
  /** 服务端的原轨引用（轨记忆用） */
  sourceRef: string;

  constructor(ref: string, fileName: string, kind: string, language: string | null,
    title: string | null, isDefault: boolean, isForced: boolean, isAi: boolean, sourceRef: string) {
    this.ref = ref;
    this.fileName = fileName;
    this.kind = kind;
    this.language = language;
    this.title = title;
    this.isDefault = isDefault;
    this.isForced = isForced;
    this.isAi = isAi;
    this.sourceRef = sourceRef;
  }
}

export class OfflinePlaybackSpec {
  static readonly currentFormat: number = 1;
  readonly format: number = OfflinePlaybackSpec.currentFormat;
  durationMs: number | null;
  /** 章节与片段原样存（JSON 里就是服务端模型） */
  chaptersJson: string;
  segmentsJson: string;
  /** 音轨原样存（服务端模型数组） */
  audioTracksJson: string;
  defaultAudio: string | null;
  subtitles: OfflineSubtitleSpec[];
  fonts: string[];
  resolution: string | null;
  videoCodec: string | null;
  container: string | null;

  constructor(durationMs: number | null, chaptersJson: string, segmentsJson: string,
    audioTracksJson: string, defaultAudio: string | null, subtitles: OfflineSubtitleSpec[],
    fonts: string[], resolution: string | null, videoCodec: string | null, container: string | null) {
    this.durationMs = durationMs;
    this.chaptersJson = chaptersJson;
    this.segmentsJson = segmentsJson;
    this.audioTracksJson = audioTracksJson;
    this.defaultAudio = defaultAudio;
    this.subtitles = subtitles;
    this.fonts = fonts;
    this.resolution = resolution;
    this.videoCodec = videoCodec;
    this.container = container;
  }
}

/** 一个单元的本机续播点（progress.json 里的一项：离线续播、离线「接着看」靠它） */
export class OfflineProgress {
  positionMs: number;
  played: boolean;
  durationMs: number | null;
  updatedAt: number;

  constructor(positionMs: number, played: boolean, durationMs: number | null, updatedAt: number) {
    this.positionMs = positionMs;
    this.played = played;
    this.durationMs = durationMs;
    this.updatedAt = updatedAt;
  }
}

/**
 * 一次本机播放的观看记录（docs/design/offline-download.md §7）：先落盘，能连上就发，
 * 服务端按 viewing_id 幂等合并。
 */
export class OfflineViewing {
  static readonly currentFormat: number = 1;
  readonly format: number = OfflineViewing.currentFormat;
  viewingId: string;
  mediaItemId: number;
  season: number;
  episode: number;
  fileId: number;
  startedAt: number;
  updatedAt: number;
  startPositionMs: number;
  positionMs: number;
  watchedMs: number;
  completed: boolean;
  /** 这次播放已结束（之后不会再更新） */
  ended: boolean;
  durationMs: number | null;
  /** 有没有还没发出去的更新 */
  dirty: boolean;
  /** 记下它的那次启动：上次启动留下、又没结束的，是播放中被强退 / 崩溃，补传前先收尾 */
  launch: string | null;

  constructor(viewingId: string, mediaItemId: number, season: number, episode: number,
    fileId: number, startedAt: number, startPositionMs: number, durationMs: number | null, launch: string) {
    this.viewingId = viewingId;
    this.mediaItemId = mediaItemId;
    this.season = season;
    this.episode = episode;
    this.fileId = fileId;
    this.startedAt = startedAt;
    this.updatedAt = startedAt;
    this.startPositionMs = startPositionMs;
    this.positionMs = startPositionMs;
    this.watchedMs = 0;
    this.completed = false;
    this.ended = false;
    this.durationMs = durationMs;
    this.dirty = true;
    this.launch = launch;
  }
}

/** 离线下载的开始前预留空间（预计大小之外）：设计定的 2 GB */
export class OfflineSpace {
  static readonly reserveBytes: number = 2 * 1024 * 1024 * 1024;
}
