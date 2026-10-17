import { fileIo, statfs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  OfflineItemSummary,
  OfflineOwner,
  OfflinePlaybackSpec,
  OfflineProgress,
  OfflineSubtitleSpec,
  OfflineUnit,
  OfflineUnitState,
  OfflineViewing } from './OfflineModels';

/**
 * 离线存档的路径与读写（对应 iOS `Shared/Offline/OfflineDisk.swift`）。
 *
 * 写一律原子（临时文件 + 改名）；所有状态写入都由调用方（`OfflineStore` /
 * `OfflineDownloader`）在自己的单线程异步流里做，不另设队列——ArkTS 的异步是
 * 协作式的，await 点之间不会被打断，没有 iOS 那种回调线程竞争。
 *
 * 目录：`<filesDir>/Offline/`（应用沙箱内；鸿蒙没有 iCloud 之类的自动云备份，
 * 不需要 iOS 那步 `isExcludedFromBackup`）。
 */
export class OfflineDisk {
  private static rootPath: string | null = null;

  /** EntryAbility.onCreate 时调（AppModel.initStore 之后） */
  static init(context: common.Context): void {
    if (OfflineDisk.rootPath === null) {
      OfflineDisk.rootPath = `${context.filesDir}/Offline`;
    }
  }

  private static root(): string {
    const path: string | null = OfflineDisk.rootPath;
    return path !== null ? path : '';
  }

  /** 存档根目录（扫账号用） */
  static rootDir(): string {
    return OfflineDisk.root();
  }

  static ownerDir(key: string): string {
    return `${OfflineDisk.root()}/${key}`;
  }

  static itemsDir(key: string): string {
    return `${OfflineDisk.ownerDir(key)}/items`;
  }

  static itemDir(key: string, itemId: number): string {
    return `${OfflineDisk.itemsDir(key)}/${itemId}`;
  }

  static unitDir(key: string, itemId: number, fileId: number): string {
    return `${OfflineDisk.itemDir(key, itemId)}/units/${fileId}`;
  }

  static imagesDir(key: string, itemId: number): string {
    return `${OfflineDisk.itemDir(key, itemId)}/images`;
  }

  static viewingsDir(key: string): string {
    return `${OfflineDisk.ownerDir(key)}/viewings`;
  }

  static ownerFile(key: string): string {
    return `${OfflineDisk.ownerDir(key)}/owner.json`;
  }

  static summaryFile(key: string, itemId: number): string {
    return `${OfflineDisk.itemDir(key, itemId)}/summary.json`;
  }

  static detailFile(key: string, itemId: number): string {
    return `${OfflineDisk.itemDir(key, itemId)}/detail.json`;
  }

  static libraryFile(key: string, itemId: number): string {
    return `${OfflineDisk.itemDir(key, itemId)}/library.json`;
  }

  static seasonFile(key: string, itemId: number, season: number): string {
    return `${OfflineDisk.itemDir(key, itemId)}/seasons/${season}.json`;
  }

  static progressFile(key: string, itemId: number): string {
    return `${OfflineDisk.itemDir(key, itemId)}/progress.json`;
  }

  static unitFile(key: string, itemId: number, fileId: number): string {
    return `${OfflineDisk.unitDir(key, itemId, fileId)}/unit.json`;
  }

  static playbackFile(key: string, itemId: number, fileId: number): string {
    return `${OfflineDisk.unitDir(key, itemId, fileId)}/playback.json`;
  }

  /** 部分下载的视频（续传的本钱：继续时按它的大小发 Range） */
  static partialMediaFile(key: string, itemId: number, fileId: number, fileExtension: string): string {
    return `${OfflineDisk.unitDir(key, itemId, fileId)}/media.${fileExtension}.part`;
  }

  static viewingFile(key: string, viewingId: string): string {
    return `${OfflineDisk.viewingsDir(key)}/${viewingId}.json`;
  }

  // MARK: 目录操作

  static exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  static ensureDir(path: string): void {
    if (path.length === 0 || OfflineDisk.exists(path)) {
      return;
    }
    const parent: string = path.substring(0, path.lastIndexOf('/'));
    if (parent.length > OfflineDisk.root().length) {
      OfflineDisk.ensureDir(parent);
    }
    try {
      fileIo.mkdirSync(path);
    } catch (error) {
      // 已存在（并发建过）：无所谓
    }
  }

  static children(path: string): string[] {
    try {
      return fileIo.listFileSync(path);
    } catch (error) {
      return [];
    }
  }

  static fileSize(path: string): number {
    try {
      return fileIo.statSync(path).size;
    } catch (error) {
      return 0;
    }
  }

  /** 剩余空间（字节）；拿不到返回 -1（调用方据此跳过检查） */
  static availableBytes(): number {
    try {
      return statfs.getFreeSizeSync(OfflineDisk.rootDir());
    } catch (error) {
      return -1;
    }
  }

  /** 总容量（字节）；拿不到返回 -1 */
  static totalBytes(): number {
    try {
      return statfs.getTotalSizeSync(OfflineDisk.rootDir());
    } catch (error) {
      return -1;
    }
  }

  /** 目录（含内容）大小：存储页的「占用」 */
  static sizeOf(path: string): number {
    let total: number = 0;
    const names: string[] = OfflineDisk.children(path);
    for (const name of names) {
      const child: string = `${path}/${name}`;
      if (OfflineDisk.isDirectory(child)) {
        total += OfflineDisk.sizeOf(child);
      } else {
        total += OfflineDisk.fileSize(child);
      }
    }
    return total;
  }

  /** 挪文件（下载完成把 .part 转正）；目标已存在先删掉 */
  static moveFile(src: string, dst: string): boolean {
    try {
      if (OfflineDisk.exists(dst)) {
        fileIo.unlinkSync(dst);
      }
      fileIo.renameSync(src, dst);
      return true;
    } catch (error) {
      return false;
    }
  }

  static isDirectory(path: string): boolean {
    try {
      return fileIo.statSync(path).isDirectory();
    } catch (error) {
      return false;
    }
  }

  /** 删文件或目录（递归）：删到一半失败就尽力删（孤儿文件由下次 loadSnapshot 收拾） */
  static remove(path: string): void {
    if (!OfflineDisk.exists(path)) {
      return;
    }
    if (OfflineDisk.isDirectory(path)) {
      const names: string[] = OfflineDisk.children(path);
      for (const name of names) {
        OfflineDisk.remove(`${path}/${name}`);
      }
      try {
        fileIo.rmdirSync(path);
      } catch (error) {
      }
    } else {
      try {
        fileIo.unlinkSync(path);
      } catch (error) {
      }
    }
  }

  // MARK: 文本读写（一律原子）

  static writeText(path: string, text: string): void {
    OfflineDisk.ensureDir(path.substring(0, path.lastIndexOf('/')));
    const tmp: string = `${path}.tmp`;
    const file: fileIo.File = fileIo.openSync(tmp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
      | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
    try {
      fileIo.renameSync(tmp, path);
    } catch (error) {
      // 同名 rename 在部分系统版本要 unlink 先行：兜一遍
      try {
        fileIo.unlinkSync(path);
        fileIo.renameSync(tmp, path);
      } catch (nested) {
      }
    }
  }

  static readText(path: string): string | null {
    try {
      return fileIo.readTextSync(path);
    } catch (error) {
      return null;
    }
  }

  static readJSON(path: string): Object | null {
    const text: string | null = OfflineDisk.readText(path);
    if (text === null || text.length === 0) {
      return null;
    }
    return OfflineDisk.readJSONText(text);
  }

  static readJSONText(text: string): Object | null {
    if (text.length === 0) {
      return null;
    }
    try {
      return JSON.parse(text) as Object;
    } catch (error) {
      return null;
    }
  }

  static writeJSON(path: string, value: Object): void {
    OfflineDisk.writeText(path, JSON.stringify(value));
  }

  // MARK: 二进制读写（字幕 / 字体 / 图片）

  static writeBuffer(path: string, data: ArrayBuffer): void {
    OfflineDisk.ensureDir(path.substring(0, path.lastIndexOf('/')));
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
      | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, data);
    } finally {
      fileIo.closeSync(file);
    }
  }

  static appendBuffer(path: string, data: ArrayBuffer): void {
    OfflineDisk.ensureDir(path.substring(0, path.lastIndexOf('/')));
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
      | fileIo.OpenMode.APPEND);
    try {
      fileIo.writeSync(file.fd, data);
    } finally {
      fileIo.closeSync(file);
    }
  }

  // MARK: 模型读写（自有结构；不认识的 format 返回 null，不崩）

  static readOwner(path: string): OfflineOwner | null {
    const raw: Object | null = OfflineDisk.readJSON(path);
    if (raw === null) {
      return null;
    }
    const record: Record<string, Object> = raw as Record<string, Object>;
    if (record['format'] !== 1) {
      return null;
    }
    const instanceId: string = `${record['instanceId'] ?? ''}`;
    const username: string = `${record['username'] ?? ''}`;
    const origin: string = `${record['origin'] ?? ''}`;
    if (instanceId.length === 0 || username.length === 0) {
      return null;
    }
    return new OfflineOwner(instanceId, username, origin);
  }

  static writeUnit(unit: OfflineUnit, path: string): void {
    OfflineDisk.writeJSON(path, unit as Object);
  }

  static readUnit(path: string): OfflineUnit | null {
    const raw: Object | null = OfflineDisk.readJSON(path);
    if (raw === null) {
      return null;
    }
    const record: Record<string, Object> = raw as Record<string, Object>;
    if (record['format'] !== 1) {
      return null;
    }
    const fileId: number = Number(record['fileId'] ?? 0);
    const mediaItemId: number = Number(record['mediaItemId'] ?? 0);
    if (!Number.isFinite(fileId) || fileId <= 0 || !Number.isFinite(mediaItemId) || mediaItemId <= 0) {
      return null;
    }
    const unit: OfflineUnit = new OfflineUnit(fileId, mediaItemId, Number(record['season'] ?? 0),
      Number(record['episode'] ?? 0), `${record['profile'] ?? ''}`, `${record['profileLabel'] ?? ''}`,
      `${record['state'] ?? OfflineUnitState.preparing}`, Number(record['expectedBytes'] ?? 0),
      `${record['fileExtension'] ?? 'mkv'}`, Number(record['createdAt'] ?? Date.now()));
    unit.receivedBytes = Number(record['receivedBytes'] ?? 0);
    unit.exportId = record['exportId'] === undefined ? null : `${record['exportId']}`;
    unit.stillUrl = record['stillUrl'] === undefined ? null : `${record['stillUrl']}`;
    unit.error = record['error'] === undefined ? null : `${record['error']}`;
    unit.retryable = record['retryable'] !== false;
    unit.attempts = Number(record['attempts'] ?? 0);
    unit.nextRetryAt = record['nextRetryAt'] === undefined ? null : Number(record['nextRetryAt']);
    unit.completedAt = record['completedAt'] === undefined ? null : Number(record['completedAt']);
    unit.damaged = record['damaged'] === true;
    unit.transcodeWait = record['transcodeWait'] === undefined ? null : `${record['transcodeWait']}`;
    unit.etag = record['etag'] === undefined ? null : `${record['etag']}`;
    return unit;
  }

  static writeSummary(summary: OfflineItemSummary, path: string): void {
    OfflineDisk.writeJSON(path, summary as Object);
  }

  static readSummary(path: string): OfflineItemSummary | null {
    const raw: Object | null = OfflineDisk.readJSON(path);
    if (raw === null) {
      return null;
    }
    const record: Record<string, Object> = raw as Record<string, Object>;
    if (record['format'] !== 1) {
      return null;
    }
    const mediaItemId: number = Number(record['mediaItemId'] ?? 0);
    if (!Number.isFinite(mediaItemId) || mediaItemId <= 0) {
      return null;
    }
    const year: Object | undefined = record['year'];
    const summary: OfflineItemSummary = new OfflineItemSummary(mediaItemId,
      Number(record['libraryId'] ?? 0), `${record['libraryName'] ?? ''}`, `${record['libraryKind'] ?? ''}`,
      `${record['kind'] ?? 'movie'}`, `${record['title'] ?? ''}`,
      year === undefined || year === null ? null : Number(year),
      record['posterUrl'] === undefined ? null : `${record['posterUrl']}`,
      record['backdropUrl'] === undefined ? null : `${record['backdropUrl']}`,
      Number(record['addedAt'] ?? Date.now()));
    return summary;
  }

  /** progress.json：`{ "季-集": OfflineProgress }`（Record 存取，键带引号） */
  static readProgressMap(path: string): Map<string, OfflineProgress> {
    const map: Map<string, OfflineProgress> = new Map<string, OfflineProgress>();
    const raw: Object | null = OfflineDisk.readJSON(path);
    if (raw === null) {
      return map;
    }
    const record: Record<string, Object> = raw as Record<string, Object>;
    const keys: string[] = Object.keys(record);
    for (const key of keys) {
      const entry: Record<string, Object> = record[key] as Record<string, Object>;
      if (entry === undefined || entry === null) {
        continue;
      }
      map.set(key, new OfflineProgress(Number(entry['positionMs'] ?? 0), entry['played'] === true,
        entry['durationMs'] === undefined || entry['durationMs'] === null
          ? null : Number(entry['durationMs']), Number(entry['updatedAt'] ?? 0)));
    }
    return map;
  }

  static writeProgressMap(map: Map<string, OfflineProgress>, path: string): void {
    const record: Record<string, Object> = {};
    const keys: string[] = Array.from(map.keys());
    for (const key of keys) {
      const progress: OfflineProgress | undefined = map.get(key);
      if (progress !== undefined) {
        record[key] = progress as Object;
      }
    }
    OfflineDisk.writeJSON(path, record);
  }

  /** 图片索引（index.json）：「原始地址 → 存盘文件名」 */
  static readStringMap(path: string): Record<string, string> {
    const map: Record<string, string> = {};
    const raw: Object | null = OfflineDisk.readJSON(path);
    if (raw === null) {
      return map;
    }
    const record: Record<string, Object> = raw as Record<string, Object>;
    const keys: string[] = Object.keys(record);
    for (const key of keys) {
      map[key] = `${record[key]}`;
    }
    return map;
  }

  static readViewing(path: string): OfflineViewing | null {
    const raw: Object | null = OfflineDisk.readJSON(path);
    if (raw === null) {
      return null;
    }
    const record: Record<string, Object> = raw as Record<string, Object>;
    if (record['format'] !== 1) {
      return null;
    }
    const viewingId: string = `${record['viewingId'] ?? ''}`;
    const mediaItemId: number = Number(record['mediaItemId'] ?? 0);
    if (viewingId.length === 0 || !Number.isFinite(mediaItemId) || mediaItemId <= 0) {
      return null;
    }
    const durationMs: Object | undefined = record['durationMs'];
    const viewing: OfflineViewing = new OfflineViewing(viewingId, mediaItemId,
      Number(record['season'] ?? 0), Number(record['episode'] ?? 0),
      Number(record['fileId'] ?? 0), Number(record['startedAt'] ?? Date.now()),
      Number(record['startPositionMs'] ?? 0),
      durationMs === undefined || durationMs === null ? null : Number(durationMs),
      `${record['launch'] ?? ''}`);
    viewing.updatedAt = Number(record['updatedAt'] ?? viewing.startedAt);
    viewing.positionMs = Number(record['positionMs'] ?? viewing.startPositionMs);
    viewing.watchedMs = Number(record['watchedMs'] ?? 0);
    viewing.completed = record['completed'] === true;
    viewing.ended = record['ended'] === true;
    viewing.dirty = record['dirty'] !== false;
    return viewing;
  }

  static writeViewing(viewing: OfflineViewing, path: string): void {
    OfflineDisk.writeJSON(path, viewing as Object);
  }

  /** playback.json：本机播放要用的章节数据（没打包好 / format 不认识 → null，走不了本机播放） */
  static readSpec(path: string): OfflinePlaybackSpec | null {
    const raw: Object | null = OfflineDisk.readJSON(path);
    if (raw === null) {
      return null;
    }
    const record: Record<string, Object> = raw as Record<string, Object>;
    if (record['format'] !== OfflinePlaybackSpec.currentFormat) {
      return null;
    }
    const subtitles: OfflineSubtitleSpec[] = [];
    const subtitlesRaw: Object | undefined = record['subtitles'];
    if (subtitlesRaw !== undefined && Array.isArray(subtitlesRaw)) {
      for (const item of subtitlesRaw as Object[]) {
        const row: Record<string, Object> = item as Record<string, Object>;
        const language: Object | undefined = row['language'];
        const title: Object | undefined = row['title'];
        subtitles.push(new OfflineSubtitleSpec(`${row['ref'] ?? ''}`, `${row['fileName'] ?? ''}`,
          `${row['kind'] ?? 'vtt'}`,
          language === undefined || language === null ? null : `${language}`,
          title === undefined || title === null ? null : `${title}`,
          row['isDefault'] === true, row['isForced'] === true, row['isAi'] === true,
          `${row['sourceRef'] ?? ''}`));
      }
    }
    const fonts: string[] = [];
    const fontsRaw: Object | undefined = record['fonts'];
    if (fontsRaw !== undefined && Array.isArray(fontsRaw)) {
      for (const font of fontsRaw as Object[]) {
        fonts.push(`${font}`);
      }
    }
    const durationMs: Object | undefined = record['durationMs'];
    const defaultAudio: Object | undefined = record['defaultAudio'];
    const resolution: Object | undefined = record['resolution'];
    const videoCodec: Object | undefined = record['videoCodec'];
    const container: Object | undefined = record['container'];
    return new OfflinePlaybackSpec(
      durationMs === undefined || durationMs === null ? null : Number(durationMs),
      `${record['chaptersJson'] ?? '[]'}`, `${record['segmentsJson'] ?? '[]'}`,
      `${record['audioTracksJson'] ?? '[]'}`,
      defaultAudio === undefined || defaultAudio === null ? null : `${defaultAudio}`,
      subtitles, fonts,
      resolution === undefined || resolution === null ? null : `${resolution}`,
      videoCodec === undefined || videoCodec === null ? null : `${videoCodec}`,
      container === undefined || container === null ? null : `${container}`);
  }

  // MARK: 启动快照（§3.3：后台扫一遍 items/*/summary.json，内存里建索引）

  static loadSnapshot(key: string): OfflineSnapshot {
    const snapshot: OfflineSnapshot = new OfflineSnapshot();
    const itemNames: string[] = OfflineDisk.children(OfflineDisk.itemsDir(key));
    for (const name of itemNames) {
      const itemId: number = Number(name);
      if (!Number.isFinite(itemId) || itemId <= 0) {
        continue;
      }
      const itemDir: string = OfflineDisk.itemDir(key, itemId);
      const summary: OfflineItemSummary | null =
        OfflineDisk.readSummary(`${itemDir}/summary.json`);
      if (summary === null) {
        continue;
      }
      let hasUnit: boolean = false;
      const unitDirRoot: string = `${itemDir}/units`;
      const unitNames: string[] = OfflineDisk.children(unitDirRoot);
      for (const unitName of unitNames) {
        const unitDir: string = `${unitDirRoot}/${unitName}`;
        let unit: OfflineUnit | null = OfflineDisk.readUnit(`${unitDir}/unit.json`);
        if (unit === null) {
          continue;
        }
        // 下完了却没来得及标（挪文件与写状态之间被杀）：视频只在整段收完后才挪进来，文件在就是下完了
        if (unit.state !== OfflineUnitState.done) {
          const media: string = `${unitDir}/${unit.mediaFileName}`;
          const size: number = OfflineDisk.fileSize(media);
          if (size > 0) {
            unit.state = 'done';
            unit.receivedBytes = size;
            unit.expectedBytes = size;
            if (unit.completedAt === null) {
              unit.completedAt = Date.now();
            }
            OfflineDisk.writeUnit(unit, `${unitDir}/unit.json`);
          }
        }
        snapshot.units.set(unit.fileId, unit);
        hasUnit = true;
      }
      if (!hasUnit) {
        // 单元删光了还剩个空条目（删除中途被杀）：收拾掉
        OfflineDisk.remove(itemDir);
        continue;
      }
      snapshot.items.set(itemId, summary);
      const progress: Map<string, OfflineProgress> =
        OfflineDisk.readProgressMap(`${itemDir}/progress.json`);
      if (progress.size > 0) {
        snapshot.progress.set(itemId, progress);
      }
    }
    return snapshot;
  }
}

/** 一个账号存档的全部内容（启动时读一遍，每个文件都很小） */
export class OfflineSnapshot {
  items: Map<number, OfflineItemSummary> = new Map<number, OfflineItemSummary>();
  units: Map<number, OfflineUnit> = new Map<number, OfflineUnit>();
  progress: Map<number, Map<string, OfflineProgress>> = new Map<number, Map<string, OfflineProgress>>();
}
