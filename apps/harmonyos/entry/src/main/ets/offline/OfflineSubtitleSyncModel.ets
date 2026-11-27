import {
  LibraryFileView,
  OfflineManifestView,
  OfflineSubtitleView
} from '../api/Models';
import {
  OfflinePlaybackSpec,
  OfflineSubtitleSpec,
  OfflineUnit
} from './OfflineModels';

const SUPPORTED_EXTERNAL_FORMATS: Set<string> = new Set<string>([
  'srt', 'subrip', 'vtt', 'webvtt', 'ass', 'ssa'
]);

/** 计划下载的一条新外挂字幕 */
export class SubtitleSyncDownload {
  readonly fileName: string;
  readonly url: string;

  constructor(fileName: string, url: string) {
    this.fileName = fileName;
    this.url = url;
  }
}

/** 一次离线字幕补齐的纯计算方案 */
export class OfflineSubtitleSyncPlan {
  readonly subtitles: OfflineSubtitleSpec[];
  readonly downloads: SubtitleSyncDownload[];
  readonly obsoleteFiles: string[];
  readonly changed: boolean;

  constructor(subtitles: OfflineSubtitleSpec[], downloads: SubtitleSyncDownload[],
    obsoleteFiles: string[], changed: boolean) {
    this.subtitles = subtitles;
    this.downloads = downloads;
    this.obsoleteFiles = obsoleteFiles;
    this.changed = changed;
  }
}

/** 已完成单元的并发安全快照指纹（防删除、换档、同档重下竞态） */
export class OfflineUnitStamp {
  readonly profile: string;
  readonly fileExtension: string;
  readonly exportId: string | null;
  readonly createdAt: number;
  readonly completedAt: number | null;
  readonly subtitlesJson: string;
  readonly fontsJson: string;

  constructor(unit: OfflineUnit, spec: OfflinePlaybackSpec) {
    this.profile = unit.profile;
    this.fileExtension = unit.fileExtension;
    this.exportId = unit.exportId;
    this.createdAt = unit.createdAt;
    this.completedAt = unit.completedAt;
    this.subtitlesJson = JSON.stringify(spec.subtitles);
    this.fontsJson = JSON.stringify(spec.fonts);
  }

  matches(unit: OfflineUnit | null, spec: OfflinePlaybackSpec | null): boolean {
    if (unit === null || spec === null || !unit.playable) {
      return false;
    }
    return unit.profile === this.profile
      && unit.fileExtension === this.fileExtension
      && unit.exportId === this.exportId
      && unit.createdAt === this.createdAt
      && unit.completedAt === this.completedAt
      && JSON.stringify(spec.subtitles) === this.subtitlesJson
      && JSON.stringify(spec.fonts) === this.fontsJson;
  }
}

function fileExtensionOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  if (dot < 0 || dot + 1 >= name.length) {
    return '';
  }
  return name.substring(dot + 1).toLowerCase();
}

function safeToken(raw: string): string {
  let out: string = '';
  for (let i: number = 0; i < raw.length && out.length < 40; i++) {
    const ch: string = raw.charAt(i);
    const code: number = raw.charCodeAt(i);
    const ok: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 90)
      || (code >= 97 && code <= 122) || ch === '.' || ch === '_' || ch === '-';
    out += ok ? ch : '_';
  }
  return out.length > 0 ? out : 'und';
}

/** 纯函数 FNV-1a 32-bit 稳定短哈希（给新补齐的字幕生成跨启动一致且不冲突的文件名） */
function stableHashHex(input: string): string {
  let hash: number = 0x811c9dc5;
  for (let i: number = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

/** 详情页服务端文件里的外挂文字字幕 `sourceRef` 集合（跳过图形字幕 `.sup`/`.sub`/`.idx`） */
export function externalSubtitleRefs(file: LibraryFileView): Set<string> {
  const refs: Set<string> = new Set<string>();
  const streams = file.subtitle_streams ?? [];
  for (const stream of streams) {
    if (!stream.external) {
      continue;
    }
    const name: string = stream.file_name ?? '';
    if (name.length === 0) {
      continue;
    }
    const ext: string = (stream.codec ?? fileExtensionOf(name)).toLowerCase();
    if (!SUPPORTED_EXTERNAL_FORMATS.has(ext)) {
      continue;
    }
    refs.add(`external:${name}`);
  }
  return refs;
}

/** 详情页在线刷新后快速判断是否需要补齐外挂字幕（内封轨不参与比较，无变化时不发额外请求） */
export function needsOfflineSubtitleSync(
  localSpec: OfflinePlaybackSpec | null,
  serverFile: LibraryFileView
): boolean {
  if (localSpec === null) {
    return false;
  }
  const localExternal: Set<string> = new Set<string>();
  for (const sub of localSpec.subtitles) {
    if (sub.sourceRef.startsWith('external:')) {
      localExternal.add(sub.sourceRef);
    }
  }
  const remoteExternal: Set<string> = externalSubtitleRefs(serverFile);
  if (localExternal.size !== remoteExternal.size) {
    return true;
  }
  for (const ref of remoteExternal) {
    if (!localExternal.has(ref)) {
      return true;
    }
  }
  return false;
}

/**
 * 判定 `/offline/manifest` 是否为降级 HTTP 200 空清单（文件缺失、需转码同意、被策略拒绝、原盘等）。
 * 此类响应缺少完整播放计划，绝对不能拿空 `subtitles` 去误清本机已有字幕。
 */
export function isDegradedOfflineManifest(
  manifest: OfflineManifestView,
  existingSpec: OfflinePlaybackSpec
): boolean {
  const reason: string = manifest.unavailable_reason ?? '';
  if (reason.length > 0) {
    return true;
  }
  const audioTracks = manifest.audio_tracks ?? [];
  const defaultAudio: string | null = manifest.default_audio ?? null;
  const manifestSubtitles = manifest.subtitles ?? [];
  if (audioTracks.length === 0 && defaultAudio === null && manifestSubtitles.length === 0) {
    return true;
  }
  const existingHasAudio: boolean = (existingSpec.audioTracksJson.length > 2) || existingSpec.defaultAudio !== null;
  if (existingHasAudio && audioTracks.length === 0 && defaultAudio === null) {
    return true;
  }
  const files = manifest.item?.files ?? [];
  let serverFile: LibraryFileView | null = null;
  for (const f of files) {
    if (f.id === manifest.file_id) {
      serverFile = f;
      break;
    }
  }
  if (serverFile !== null) {
    if (serverFile.missing || serverFile.state !== 'in_place') {
      return true;
    }
    const serverAudios = serverFile.audio_streams ?? [];
    if (serverAudios.length > 0 && audioTracks.length === 0 && defaultAudio === null) {
      return true;
    }
    if (externalSubtitleRefs(serverFile).size > 0) {
      let hasRemoteExternal: boolean = false;
      for (const s of manifestSubtitles) {
        if (!s.embedded) {
          hasRemoteExternal = true;
          break;
        }
      }
      if (!hasRemoteExternal) {
        return true;
      }
    }
  }
  return false;
}

/**
 * 计算已下载单元的外挂字幕补齐方案（纯函数）：
 * - 完整保留既有内封轨（`embedded:*`）不删不重下；
 * - 已落盘且仍在清单里的外挂轨直接复用本地文件、只同步元数据；
 * - 新增外挂文字轨分配稳定防冲突文件名并排入下载列表；
 * - 服务端已移除的旧外挂字幕文件名记入 `obsoleteFiles` 待 `playback.json` 落盘后清理。
 */
export function buildOfflineSubtitleSyncPlan(
  existingSubtitles: OfflineSubtitleSpec[],
  manifestSubtitles: OfflineSubtitleView[],
  fileExists: (fileName: string) => boolean
): OfflineSubtitleSyncPlan {
  const existingByRef: Map<string, OfflineSubtitleSpec> = new Map<string, OfflineSubtitleSpec>();
  const usedNames: Set<string> = new Set<string>();
  const embeddedKept: OfflineSubtitleSpec[] = [];

  for (const sub of existingSubtitles) {
    usedNames.add(sub.fileName);
    if (sub.sourceRef.startsWith('embedded:')) {
      embeddedKept.push(sub);
    } else if (!existingByRef.has(sub.sourceRef)) {
      existingByRef.set(sub.sourceRef, sub);
    }
  }

  const finalSubtitles: OfflineSubtitleSpec[] = [];
  for (const emb of embeddedKept) {
    finalSubtitles.push(emb);
  }

  const downloads: SubtitleSyncDownload[] = [];
  const seenRemoteRefs: Set<string> = new Set<string>();

  for (const sub of manifestSubtitles) {
    if (sub.embedded) {
      continue;
    }
    const ext: string = sub.format.toLowerCase();
    if (!SUPPORTED_EXTERNAL_FORMATS.has(ext)) {
      continue;
    }
    if (seenRemoteRefs.has(sub.track_ref)) {
      continue;
    }
    seenRemoteRefs.add(sub.track_ref);

    const kind: string = ext === 'srt' || ext === 'subrip' || ext === 'vtt' || ext === 'webvtt' ? 'vtt' : 'ass';
    const existing: OfflineSubtitleSpec | undefined = existingByRef.get(sub.track_ref);
    if (existing !== undefined && fileExists(existing.fileName)) {
      finalSubtitles.push(new OfflineSubtitleSpec(
        `external:${existing.fileName}`,
        existing.fileName,
        kind,
        sub.language ?? null,
        sub.title ?? null,
        sub.is_default,
        sub.is_forced,
        sub.is_ai,
        sub.track_ref
      ));
      continue;
    }

    const baseHash: string = stableHashHex(sub.track_ref);
    const langTag: string = safeToken(sub.language ?? 'und');
    let candidate: string = `sync-${baseHash}-${langTag}.${ext}`;
    let seq: number = 1;
    while (usedNames.has(candidate)) {
      candidate = `sync-${baseHash}-${seq}-${langTag}.${ext}`;
      seq += 1;
    }
    usedNames.add(candidate);
    downloads.push(new SubtitleSyncDownload(candidate, sub.url));
    finalSubtitles.push(new OfflineSubtitleSpec(
      `external:${candidate}`,
      candidate,
      kind,
      sub.language ?? null,
      sub.title ?? null,
      sub.is_default,
      sub.is_forced,
      sub.is_ai,
      sub.track_ref
    ));
  }

  const referenced: Set<string> = new Set<string>();
  for (const s of finalSubtitles) {
    referenced.add(s.fileName);
  }
  const obsoleteFiles: string[] = [];
  const obsoleteSeen: Set<string> = new Set<string>();
  for (const oldSub of existingSubtitles) {
    if (oldSub.sourceRef.startsWith('embedded:')) {
      continue;
    }
    if (!referenced.has(oldSub.fileName) && !obsoleteSeen.has(oldSub.fileName)) {
      obsoleteSeen.add(oldSub.fileName);
      obsoleteFiles.push(oldSub.fileName);
    }
  }

  const changed: boolean = downloads.length > 0
    || obsoleteFiles.length > 0
    || JSON.stringify(existingSubtitles) !== JSON.stringify(finalSubtitles);

  return new OfflineSubtitleSyncPlan(finalSubtitles, downloads, obsoleteFiles, changed);
}
