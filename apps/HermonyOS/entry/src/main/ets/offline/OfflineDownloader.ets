import { http } from '@kit.NetworkKit';
import { fileIo, statfs } from '@kit.CoreFileKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiClient, ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { TokenVault } from '../common/TokenVault';
import { OfflineDisk } from './OfflineDisk';
import { OfflineStore } from './OfflineStore';
import { OfflinePackager } from './OfflinePackager';
import {
  OfflineItemSummary,
  OfflineSpace,
  OfflineUnit,
  OfflineUnitState } from './OfflineModels';
import {
  OfflineFileProfilesView,
  OfflineManifestView,
  OfflineProfileView } from '../api/Models';

/**
 * 离线下载（对应 iOS `Shared/Offline/OfflineDownloader.swift`，设计
 * docs/design/offline-download.md §5.4）。
 *
 * 鸿蒙没有系统后台下载会话，下载在**进程内**进行：`http.requestInStream` 收流式
 * 响应，配 DATA_TRANSFER 长时任务保活。全局一次只下一个（家里上行有限，串行让
 * 第一集最早能看）；准备（清单、字幕、字体、图片、转码导出）与下载并行、一次
 * 也只准备一个。
 *
 * 断点续传不用 iOS 的 resume data——已落盘的 `.part` 文件加 `Range` 请求就是本钱；
 * `ETag`/`If-Range` 保证服务器上的文件变了就从头下，不拼坏文件。被杀、断网后由
 * 对账（`reconcile`）自愈。
 */
export class OfflineDownloader {
  private static instance: OfflineDownloader | null = null;

  /** 惰性单例（同 OfflineStore） */
  static get shared(): OfflineDownloader {
    if (OfflineDownloader.instance === null) {
      OfflineDownloader.instance = new OfflineDownloader();
    }
    return OfflineDownloader.instance;
  }

  static readonly signedOutMessage: string = '这个账号在本机的登录已失效，重新登录后会接着下';

  /** 失败自动重试的退避间隔（秒） */
  private static readonly retrySteps: number[] = [30, 120, 600, 1800, 3600];

  private appContext: common.UIAbilityContext | null = null;
  /** 正在下载的单元（worker 串行，同时至多一个） */
  private activeFileId: number = -1;
  private activeRequest: http.HttpRequest | null = null;
  /** 正在准备的单元（一次一个） */
  private preparingFileId: number = -1;
  private pendingManifests: Map<number, OfflineManifestView> = new Map<number, OfflineManifestView>();
  private workerRunning: boolean = false;
  private retryTimer: number = -1;
  private backgroundHeld: boolean = false;

  private constructor() {
  }

  /** EntryAbility.onCreate 时调：拿上下文（长时任务申请用） */
  activate(context: common.UIAbilityContext): void {
    this.appContext = context;
  }

  // MARK: 发起

  /**
   * 下载一个播放单元：清单已拉好（选档 sheet 里拉的），按选中的档位开始。
   * 已经在下 / 下完的同档不重复。
   */
  start(manifest: OfflineManifestView, profile: OfflineProfileView): OfflineStartResult {
    const store: OfflineStore = OfflineStore.shared;
    if (store.owner === null || !store.serverSupported) {
      return new OfflineStartResult(false, '这台服务器还不支持下载到本机，请先把服务器升级到最新版本');
    }
    const reason: string | null = manifest.unavailable_reason ?? null;
    if (reason !== null) {
      return new OfflineStartResult(false, reason);
    }
    const existing: OfflineUnit | undefined = store.units.get(manifest.file_id);
    if (existing !== undefined && existing.profile === profile.profile
      && existing.state !== OfflineUnitState.failed && !existing.damaged) {
      return new OfflineStartResult(true, '');
    }
    const needed: number = profile.expected_bytes + OfflineSpace.reserveBytes;
    const available: number = this.availableBytes();
    if (available >= 0 && available < needed) {
      return new OfflineStartResult(false, OfflineDownloader.noSpaceMessage(needed, available, profile.profile));
    }
    store.ensureOwnerOnDisk();
    // 换档（比如原画改 720p）：旧的那份连同任务一起去掉，条目的展示数据与本机进度留着
    if (existing !== undefined) {
      this.cancelActive(existing.fileId);
      store.removeUnit(existing.fileId, true);
    }
    const item = manifest.item;
    store.upsertSummary(new OfflineItemSummary(manifest.media_item_id, manifest.library_id,
      manifest.library.name, manifest.library.kind, item.kind, item.title, item.year ?? null,
      item.poster_url ?? null, item.backdrop_url ?? null, Date.now()));
    const unit: OfflineUnit = new OfflineUnit(manifest.file_id, manifest.media_item_id,
      manifest.season_number, manifest.episode_number, profile.profile, profile.label,
      OfflineUnitState.preparing, profile.expected_bytes,
      profile.profile === 'original' ? OfflineDownloader.fileExtension(manifest.container) : 'mp4',
      Date.now());
    unit.stillUrl = OfflineDownloader.stillUrlOf(manifest);
    store.upsert(unit);
    this.pendingManifests.set(unit.fileId, manifest);
    this.reconcile();
    return new OfflineStartResult(true, '');
  }

  /** 整批下载里除第一集外的各集：只凭选档表单的批量结果先建「准备中」单元（目录里马上有、强退也不丢），完整清单由准备逐集去取 */
  enqueue(entry: OfflineFileProfilesView, profile: OfflineProfileView): OfflineStartResult {
    const store: OfflineStore = OfflineStore.shared;
    if (store.owner === null || !store.serverSupported
      || !store.items.has(entry.media_item_id)) {
      return new OfflineStartResult(false, '这台服务器还不支持下载到本机，请先把服务器升级到最新版本');
    }
    const reason: string | null = entry.unavailable_reason ?? null;
    if (reason !== null) {
      return new OfflineStartResult(false, reason);
    }
    const existing: OfflineUnit | undefined = store.units.get(entry.file_id);
    if (existing !== undefined && existing.profile === profile.profile
      && existing.state !== OfflineUnitState.failed && !existing.damaged) {
      return new OfflineStartResult(true, '');
    }
    const needed: number = profile.expected_bytes + OfflineSpace.reserveBytes;
    const available: number = this.availableBytes();
    if (available >= 0 && available < needed) {
      return new OfflineStartResult(false, OfflineDownloader.noSpaceMessage(needed, available, profile.profile));
    }
    if (existing !== undefined) {
      this.cancelActive(existing.fileId);
      store.removeUnit(existing.fileId, true);
    }
    store.upsert(new OfflineUnit(entry.file_id, entry.media_item_id, entry.season_number,
      entry.episode_number, profile.profile, profile.label, OfflineUnitState.preparing,
      profile.expected_bytes,
      profile.profile === 'original' ? OfflineDownloader.fileExtension(entry.container) : 'mp4',
      Date.now()));
    this.reconcile();
    return new OfflineStartResult(true, '');
  }

  static fileExtension(container: string | null | undefined): string {
    const raw: string = (container ?? '').toLowerCase();
    const known: string[] = ['mp4', 'mkv', 'm4v', 'mov', 'ts', 'm2ts', 'avi', 'webm',
      'flv', 'wmv', 'mpg', 'mpeg', 'iso', 'rmvb'];
    if (known.includes(raw)) {
      return raw;
    }
    if (raw === 'matroska') {
      return 'mkv';
    }
    if (raw.length === 0) {
      return 'mkv';
    }
    const letters: string = raw.replace(/[^a-z]/g, '');
    return (letters.length > 0 ? letters : 'mkv').substring(0, 5);
  }

  private static stillUrlOf(manifest: OfflineManifestView): string | null {
    const season = manifest.season ?? null;
    if (season === null) {
      return null;
    }
    for (const episode of season.episodes) {
      if (episode.episode_number === manifest.episode_number) {
        return episode.still_url ?? null;
      }
    }
    return null;
  }

  // MARK: 用户操作

  pause(fileId: number): void {
    const store: OfflineStore = OfflineStore.shared;
    const unit: OfflineUnit | undefined = store.units.get(fileId);
    if (unit === undefined || (unit.state !== OfflineUnitState.queued
      && unit.state !== OfflineUnitState.downloading)) {
      return;
    }
    unit.state = OfflineUnitState.paused;
    store.upsert(unit);
    this.cancelActive(fileId);
  }

  resume(fileId: number): void {
    const store: OfflineStore = OfflineStore.shared;
    const unit: OfflineUnit | undefined = store.units.get(fileId);
    if (unit === undefined || (unit.state !== OfflineUnitState.paused
      && unit.state !== OfflineUnitState.failed)) {
      return;
    }
    unit.state = unit.profile !== 'original' && unit.exportId === null
      ? OfflineUnitState.preparing : OfflineUnitState.queued;
    unit.error = null;
    unit.transcodeWait = null;
    unit.retryable = true;
    unit.nextRetryAt = null;
    store.upsert(unit);
    this.reconcile();
  }

  /** 删除本机副本（任意状态）：先断任务，再删目录 */
  delete(fileId: number): void {
    const store: OfflineStore = OfflineStore.shared;
    this.cancelActive(fileId);
    if (this.preparingFileId === fileId) {
      // 准备中的：取消不了在途请求，靠准备流程里的存活检查丢弃结果
      this.preparingFileId = -1;
    }
    store.removeUnit(fileId, false);
  }

  deleteItem(itemId: number): void {
    for (const unit of OfflineStore.shared.unitsOfItem(itemId)) {
      this.delete(unit.fileId);
    }
  }

  private cancelActive(fileId: number): void {
    if (this.activeFileId === fileId) {
      const request: http.HttpRequest | null = this.activeRequest;
      this.activeFileId = -1;
      this.activeRequest = null;
      if (request !== null) {
        try {
          request.destroy();
        } catch (error) {
        }
      }
    }
  }

  // MARK: 对账（启动、回前台、任务结束、删除、改设置都调）

  reconcile(): void {
    const store: OfflineStore = OfflineStore.shared;
    if (store.owner === null || !store.loaded) {
      return;
    }
    // 到点的失败单元回到准备 / 队列
    const now: number = Date.now();
    for (const unit of store.activeUnits()) {
      if (unit.state !== OfflineUnitState.failed || !unit.retryable) {
        continue;
      }
      const at: number | null = unit.nextRetryAt;
      if (at !== null && at > now) {
        continue;
      }
      unit.state = unit.profile !== 'original' && unit.exportId === null
        ? OfflineUnitState.preparing : OfflineUnitState.queued;
      unit.error = null;
      unit.transcodeWait = null;
      unit.nextRetryAt = null;
      store.upsert(unit);
    }
    this.kickPrepare();
    this.kickWorker();
    this.scheduleRetryTimer();
  }

  /** 前台时到点再对一次账（503 的 Retry-After、失败退避）：没有它，失败的下载要等下次回前台才重试 */
  private scheduleRetryTimer(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    const store: OfflineStore = OfflineStore.shared;
    const now: number = Date.now();
    let nearest: number = -1;
    for (const unit of store.activeUnits()) {
      if (unit.state !== OfflineUnitState.failed || !unit.retryable) {
        continue;
      }
      const at: number | null = unit.nextRetryAt;
      if (at !== null && at > now && (nearest < 0 || at < nearest)) {
        nearest = at;
      }
    }
    if (nearest > 0) {
      this.retryTimer = setTimeout((): void => {
        this.retryTimer = -1;
        this.reconcile();
      }, Math.max(1000, nearest - now));
    }
  }

  // MARK: 准备（一次一个，与下载并行）

  private kickPrepare(): void {
    if (this.preparingFileId >= 0) {
      return;
    }
    const store: OfflineStore = OfflineStore.shared;
    for (const unit of store.activeUnits()) {
      if (unit.state !== OfflineUnitState.preparing) {
        continue;
      }
      this.preparingFileId = unit.fileId;
      const manifest: OfflineManifestView | null = this.pendingManifests.get(unit.fileId) ?? null;
      this.pendingManifests.delete(unit.fileId);
      this.prepareUnit(unit.fileId, manifest).then((): void => {
        if (this.preparingFileId === unit.fileId) {
          this.preparingFileId = -1;
        }
        this.reconcile();
      });
      return;
    }
  }

  private async prepareUnit(fileId: number, given: OfflineManifestView | null): Promise<void> {
    const store: OfflineStore = OfflineStore.shared;
    const owner = store.owner;
    if (owner === null) {
      return;
    }
    let unit: OfflineUnit | undefined = store.units.get(fileId);
    if (unit === undefined || unit.state !== OfflineUnitState.preparing) {
      return;
    }
    const ownerKey: string = owner.key();
    const token: string = await TokenVault.token(owner.origin, owner.username);
    if (this.preparingFileId !== fileId) {
      return;
    }
    if (token.length === 0) {
      this.failUnit(fileId, OfflineDownloader.signedOutMessage, true);
      return;
    }
    const client: ApiClient = new ApiClient(owner.origin, token);
    const api: MovieClawApi = new MovieClawApi(client);
    try {
      const manifest: OfflineManifestView =
        given !== null ? given : await api.offlineManifest(fileId);
      unit = store.units.get(fileId);
      if (unit === undefined || unit.state !== OfflineUnitState.preparing
        || store.key() !== ownerKey) {
        return;
      }
      await new OfflinePackager(owner.origin, token, ownerKey, manifest, unit).run();
      unit = store.units.get(fileId);
      if (unit === undefined || unit.state !== OfflineUnitState.preparing) {
        return;
      }
      // 整批下载先建的单元没有剧照：拿到完整清单后补上
      if (unit.stillUrl === null) {
        unit.stillUrl = OfflineDownloader.stillUrlOf(manifest);
      }
      if (unit.profile !== 'original') {
        const exportView = await api.offlineExportsCreate({
          file_id: unit.fileId,
          profile: unit.profile,
          audio_track: manifest.default_audio
        });
        unit = store.units.get(fileId);
        if (unit === undefined || unit.state !== OfflineUnitState.preparing) {
          return;
        }
        unit.exportId = exportView.export_id;
        unit.etag = exportView.etag;
        if (exportView.expected_bytes > 0) {
          unit.expectedBytes = exportView.expected_bytes;
        }
      }
      unit.state = OfflineUnitState.queued;
      unit.error = null;
      store.upsert(unit);
    } catch (error) {
      const unitNow: OfflineUnit | undefined = store.units.get(fileId);
      if (unitNow === undefined || store.key() !== ownerKey) {
        return;
      }
      if (error instanceof ApiError) {
        if (error.status === 400 || error.status === 422) {
          this.failUnit(fileId, error.message, false);
        } else if (error.status === 403) {
          this.failUnit(fileId, '管理员未对你开放下载影片到设备', false);
        } else if (error.status === 404) {
          this.failUnit(fileId, '服务器上已没有这个文件', false);
        } else {
          this.failUnit(fileId, error.message, true);
        }
      } else {
        this.failUnit(fileId, '准备下载时被中断', true);
      }
    }
  }

  // MARK: 视频下载（worker 串行）

  private kickWorker(): void {
    if (this.workerRunning) {
      return;
    }
    this.workerRunning = true;
    this.workerLoop().then((): void => {
      this.workerRunning = false;
      this.releaseBackground();
      this.scheduleRetryTimer();
    });
  }

  private async workerLoop(): Promise<void> {
    const store: OfflineStore = OfflineStore.shared;
    while (true) {
      if (store.owner === null || !store.loaded) {
        return;
      }
      const fileId: number = this.pickNextDownload();
      if (fileId < 0) {
        return;
      }
      await this.downloadUnit(fileId);
    }
  }

  /** 下一个该下载的单元（按加入先后）；没有返回 -1 */
  private pickNextDownload(): number {
    const store: OfflineStore = OfflineStore.shared;
    for (const unit of store.activeUnits()) {
      if (unit.state === OfflineUnitState.queued || unit.state === OfflineUnitState.downloading) {
        return unit.fileId;
      }
    }
    return -1;
  }

  private async downloadUnit(fileId: number): Promise<void> {
    const store: OfflineStore = OfflineStore.shared;
    const owner = store.owner;
    if (owner === null) {
      return;
    }
    const key: string = owner.key();
    let unit: OfflineUnit | undefined = store.units.get(fileId);
    if (unit === undefined || (unit.state !== OfflineUnitState.queued
      && unit.state !== OfflineUnitState.downloading)) {
      return;
    }
    const url: string | null = unit.profile === 'original'
      ? `${owner.origin}/api/v1/offline/files/${fileId}/content`
      : unit.exportId !== null ? `${owner.origin}/api/v1/offline/exports/${unit.exportId}/content` : null;
    if (url === null) {
      // 转码档丢了导出：回到准备阶段重建
      unit.state = OfflineUnitState.preparing;
      store.upsert(unit);
      return;
    }
    const token: string = await TokenVault.token(owner.origin, owner.username);
    if (token.length === 0) {
      this.failUnit(fileId, OfflineDownloader.signedOutMessage, true);
      return;
    }
    unit = store.units.get(fileId);
    if (unit === undefined || (unit.state !== OfflineUnitState.queued
      && unit.state !== OfflineUnitState.downloading)) {
      return;
    }
    const partialPath: string =
      OfflineDisk.partialMediaFile(key, unit.mediaItemId, fileId, unit.fileExtension);
    const finalPath: string = `${OfflineDisk.unitDir(key, unit.mediaItemId, fileId)}/${unit.mediaFileName}`;
    const resumeFrom: number = OfflineDisk.fileSize(partialPath);
    const canResume: boolean = resumeFrom > 0 && unit.etag !== null;

    const session: http.HttpRequest = http.createHttp();
    this.activeFileId = fileId;
    this.activeRequest = session;

    // 响应头（事件在数据前到）
    let etag: string | null = null;
    let contentRange: string | null = null;
    let contentLength: number = -1;
    let retryAfterSec: number = -1;
    let exportWait: string | null = null;
    let exportsAhead: number = -1;
    let received: number = 0;
    let lastProgressAt: number = 0;
    let file: fileIo.File | null = null;
    let baseOffset: number = canResume ? resumeFrom : 0;

    try {
      session.on('headersReceive', (header: Object): void => {
        const record: Record<string, Object> = header as Record<string, Object>;
        etag = OfflineDownloader.headerString(record, 'etag');
        contentRange = OfflineDownloader.headerString(record, 'content-range');
        contentLength = OfflineDownloader.headerNumber(record, 'content-length');
        retryAfterSec = OfflineDownloader.headerNumber(record, 'retry-after');
        exportWait = OfflineDownloader.headerString(record, 'x-export-wait');
        exportsAhead = OfflineDownloader.headerNumber(record, 'x-export-ahead');
      });
      session.on('dataReceive', (chunk: ArrayBuffer): void => {
        const unitNow: OfflineUnit | undefined = store.units.get(fileId);
        if (unitNow === undefined || unitNow.state === OfflineUnitState.paused) {
          return;
        }
        if (file === null) {
          // 请求了续传、服务器却从头发（If-Range 不匹配或它不支持 Range）：旧的 .part 作废
          if (canResume && contentRange === null) {
            baseOffset = 0;
            OfflineDisk.remove(partialPath);
          }
          const mode: number = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
            | (baseOffset > 0 ? fileIo.OpenMode.APPEND : fileIo.OpenMode.TRUNC);
          file = fileIo.openSync(partialPath, mode);
        }
        fileIo.writeSync(file.fd, chunk);
        received += chunk.byteLength;
        const now: number = Date.now();
        if (now - lastProgressAt >= 1000) {
          lastProgressAt = now;
          const expected: number | null = contentLength >= 0 ? baseOffset + contentLength : null;
          store.updateReceived(fileId, baseOffset + received, expected);
        }
      });
      unit.state = OfflineUnitState.downloading;
      unit.error = null;
      unit.transcodeWait = null;
      store.upsert(unit);
      const header: Record<string, string> = {
        'Accept': '*/*',
        'Authorization': `Bearer ${token}`
      };
      if (canResume) {
        header['Range'] = `bytes=${resumeFrom}-`;
        header['If-Range'] = unit.etag ?? '';
      }
      await this.acquireBackground();
      // requestInStream 的 Promise 重载返回的是请求 id；callback 重载给响应码（number）
      const code: number = await new Promise<number>(
        (resolve: (value: number) => void,
          reject: (reason: BusinessError) => void): void => {
          session.requestInStream(url, {
            method: http.RequestMethod.GET,
            header: header,
            connectTimeout: 15000,
            // 边转边下时转码一时没产出的空档要扛得住
            readTimeout: 120000
          }, (error: BusinessError, data: number): void => {
            if (error !== null && error !== undefined) {
              reject(error);
            } else {
              resolve(data);
            }
          });
        });
      if (code === 200 || code === 206) {
        const finalSize: number = OfflineDisk.fileSize(partialPath);
        if (finalSize <= 0) {
          this.failUnit(fileId, '下载中断：没有收到数据', true);
          return;
        }
        if (code === 200 && contentLength >= 0 && finalSize !== contentLength) {
          this.failUnit(fileId, '下载中断：文件没有收全', true);
          return;
        }
        if (file !== null) {
          fileIo.closeSync(file);
          file = null;
        }
        if (!OfflineDisk.moveFile(partialPath, finalPath)) {
          this.failUnit(fileId, '保存下载的文件失败', true);
          return;
        }
        const done: OfflineUnit | undefined = store.units.get(fileId);
        if (done === undefined) {
          return;
        }
        done.state = OfflineUnitState.done;
        done.receivedBytes = finalSize;
        done.expectedBytes = finalSize;
        done.completedAt = Date.now();
        done.error = null;
        done.attempts = 0;
        done.nextRetryAt = null;
        done.transcodeWait = null;
        if (etag !== null) {
          done.etag = etag;
        }
        store.upsert(done);
        // 下完了：告诉服务端可以回收导出（尽力而为，服务端另有过期）
        if (done.exportId !== null) {
          new MovieClawApi(new ApiClient(owner.origin, token))
            .offlineExportsRelease(done.exportId).catch((): void => {
            });
        }
        return;
      }
      if (code === 503) {
        // 导出还在排队：按服务端说的时间再来，界面写在等什么
        const unitNow: OfflineUnit | undefined = store.units.get(fileId);
        if (unitNow === undefined) {
          return;
        }
        const delayMs: number = retryAfterSec >= 0 ? retryAfterSec * 1000 : 60000;
        unitNow.state = OfflineUnitState.failed;
        unitNow.retryable = true;
        unitNow.error = '服务器正在排队转码';
        unitNow.transcodeWait = OfflineDownloader.transcodeWaitNote(exportWait, exportsAhead);
        unitNow.nextRetryAt = Date.now() + delayMs;
        store.upsert(unitNow);
        return;
      }
      if (code === 401) {
        // 可重试：重新登录后对账会接着下
        this.failUnit(fileId, OfflineDownloader.signedOutMessage, true);
      } else if (code === 403) {
        this.failUnit(fileId, '管理员未对你开放下载影片到设备', false);
      } else if (code === 404 || code === 410) {
        const unitNow: OfflineUnit | undefined = store.units.get(fileId);
        if (unitNow === undefined) {
          return;
        }
        if (unitNow.profile !== 'original') {
          // 转码档 404 = 导出被回收：回到准备阶段重建
          unitNow.exportId = null;
          this.failUnit(fileId, '服务器上已没有这个文件（可能被删除、移动或回收了导出）', true);
        } else {
          this.failUnit(fileId, '服务器上已没有这个文件', false);
        }
      } else if (code === 422) {
        this.failUnit(fileId, '服务器转码失败', false);
      } else {
        this.failUnit(fileId, `服务器出错了（HTTP ${code}）`, true);
      }
    } catch (error) {
      const unitNow: OfflineUnit | undefined = store.units.get(fileId);
      if (unitNow === undefined) {
        return;
      }
      if (unitNow.state === OfflineUnitState.paused) {
        // 暂停触发的取消：.part 留着，续传的 ETag 与读数记下来
        if (etag !== null) {
          unitNow.etag = etag;
        }
        unitNow.receivedBytes = baseOffset + received;
        store.upsert(unitNow);
        return;
      }
      const e = error as BusinessError;
      const message: string = e.message !== undefined && e.message !== null && e.message.length > 0
        ? e.message : '下载中断';
      if (etag !== null) {
        unitNow.etag = etag;
      }
      this.failUnit(fileId, message, true);
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (error) {
        }
      }
      session.off('headersReceive');
      session.off('dataReceive');
      try {
        session.destroy();
      } catch (error) {
      }
      if (this.activeFileId === fileId) {
        this.activeFileId = -1;
        this.activeRequest = null;
      }
    }
  }

  // MARK: 失败

  private failUnit(fileId: number, message: string, retryable: boolean): void {
    const store: OfflineStore = OfflineStore.shared;
    const unit: OfflineUnit | undefined = store.units.get(fileId);
    if (unit === undefined) {
      return;
    }
    unit.state = OfflineUnitState.failed;
    unit.transcodeWait = null;
    unit.error = message;
    unit.retryable = retryable;
    unit.attempts += 1;
    if (retryable) {
      const steps: number[] = OfflineDownloader.retrySteps;
      const index: number = Math.min(unit.attempts - 1, steps.length - 1);
      unit.nextRetryAt = Date.now() + steps[index] * 1000;
    } else {
      unit.nextRetryAt = null;
    }
    store.upsert(unit);
  }

  /** 排队转码时界面上的一句话（服务端 503 的 x-export-wait / x-export-ahead） */
  static transcodeWaitNote(wait: string | null, ahead: number): string {
    if (wait === 'transcoder') {
      return '等待转码器空闲';
    }
    if (ahead > 0) {
      return `等待转码，前面还有 ${ahead} 个`;
    }
    return wait === 'queue' ? '即将开始转码' : '等待转码';
  }

  // MARK: 长时任务（下载保活）

  private async acquireBackground(): Promise<void> {
    if (this.backgroundHeld) {
      return;
    }
    const context: common.UIAbilityContext | null = this.appContext;
    if (context === null) {
      return;
    }
    try {
      const agent: WantAgent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this.backgroundHeld = true;
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(0x0000, 'OfflineDownloader', 'startBackgroundRunning failed code=%{public}d msg=%{public}s',
        e.code ?? -1, e.message ?? '');
    }
  }

  private async releaseBackground(): Promise<void> {
    if (!this.backgroundHeld) {
      return;
    }
    this.backgroundHeld = false;
    const context: common.UIAbilityContext | null = this.appContext;
    if (context === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (error) {
    }
  }

  // MARK: 工具

  private static headerString(record: Record<string, Object>, name: string): string | null {
    const value: Object | undefined = record[name] ?? record[name.toLowerCase()]
      ?? record[name.charAt(0).toUpperCase() + name.substring(1)];
    return value === undefined || value === null ? null : `${value}`;
  }

  private static headerNumber(record: Record<string, Object>, name: string): number {
    const raw: string | null = OfflineDownloader.headerString(record, name);
    if (raw === null) {
      return -1;
    }
    const value: number = Number(raw);
    return Number.isFinite(value) ? value : -1;
  }

  /** 剩余空间（字节）；拿不到返回 -1（不检查） */
  private availableBytes(): number {
    try {
      return statfs.getFreeSizeSync(OfflineDisk.rootDir());
    } catch (error) {
      return -1;
    }
  }

  /** `estimated`：需要的大小里含转码档的预计值（原画是精确的文件大小） */
  private static noSpaceMessage(needed: number, available: number, profile: string): string {
    const estimated: string = profile === 'original' ? '' : '约 ';
    return `本机空间不足：需要 ${estimated}${OfflineDownloader.formatBytes(needed)}（含预留 2 GB），`
      + `只剩 ${OfflineDownloader.formatBytes(available)}`;
  }

  static formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    const units: string[] = ['KB', 'MB', 'GB', 'TB'];
    let value: number = bytes;
    let unit: number = -1;
    do {
      value /= 1024;
      unit += 1;
    } while (value >= 1024 && unit < units.length - 1);
    return `${value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
  }
}

/** 开始下载的结果（ArkTS 没有异常签名，用结果对象代替 iOS 的 StartError） */
export class OfflineStartResult {
  readonly ok: boolean;
  readonly message: string;

  constructor(ok: boolean, message: string) {
    this.ok = ok;
    this.message = message;
  }
}
