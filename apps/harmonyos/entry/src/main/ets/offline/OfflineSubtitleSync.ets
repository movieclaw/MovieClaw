import { http } from '@kit.NetworkKit';
import { AppModel } from '../common/AppModel';
import { MovieClawApi } from '../api/Endpoints';
import {
  LibraryFileView,
  LibraryItemDetailView,
  OfflineManifestView
} from '../api/Models';
import { OfflineDisk } from './OfflineDisk';
import { OfflinePackager } from './OfflinePackager';
import { OfflineStore } from './OfflineStore';
import { OfflinePlaybackSpec, OfflineUnit } from './OfflineModels';
import {
  OfflineSubtitleSyncPlan,
  OfflineUnitStamp,
  buildOfflineSubtitleSyncPlan,
  isDegradedOfflineManifest,
  needsOfflineSubtitleSync
} from './OfflineSubtitleSyncModel';

const SYNC_HTTP_TIMEOUT_MS: number = 30000;

class FetchedBinary {
  readonly fileName: string;
  readonly data: ArrayBuffer;

  constructor(fileName: string, data: ArrayBuffer) {
    this.fileName = fileName;
    this.data = data;
  }
}

/**
 * 联网时为已下载本机副本自动补齐后来生成的外挂/AI 字幕（对齐并超越 iOS #1348）：
 * - 详情页联网刷新时快速对比外挂文字轨，仅变化时后台静默补齐，不重下视频；
 * - 手机 / 智慧屏 / 车机本机副本起播前限时竞速等待（默认 2 秒），超时立即开播不阻塞、后台继续收尾；
 * - 降级空清单保护 + 磁盘快照指纹校验（防删除/换档/同档重下竞态）+ 失败自动回滚新写文件。
 */
export class OfflineSubtitleSync {
  private static instance: OfflineSubtitleSync | null = null;

  static get shared(): OfflineSubtitleSync {
    if (OfflineSubtitleSync.instance === null) {
      OfflineSubtitleSync.instance = new OfflineSubtitleSync();
    }
    return OfflineSubtitleSync.instance;
  }

  private readonly inFlight: Map<string, Promise<void>> = new Map<string, Promise<void>>();

  private constructor() {
  }

  /** 详情页联网刷新后调用：按本机已下载单元逐个比对，外挂文字轨有变化才后台拉清单补齐 */
  syncForDetail(detail: LibraryItemDetailView, api: MovieClawApi | null): void {
    if (api === null) {
      return;
    }
    const store: OfflineStore = OfflineStore.shared;
    const ownerKey: string | null = store.key();
    if (ownerKey === null) {
      return;
    }
    const filesById: Map<number, LibraryFileView> = new Map<number, LibraryFileView>();
    for (const f of detail.files) {
      filesById.set(f.id, f);
    }
    const units: OfflineUnit[] = store.unitsOfItem(detail.id);
    for (const unit of units) {
      if (!unit.playable) {
        continue;
      }
      const serverFile: LibraryFileView | undefined = filesById.get(unit.fileId);
      if (serverFile === undefined) {
        continue;
      }
      const localSpec: OfflinePlaybackSpec | null = store.spec(unit);
      if (needsOfflineSubtitleSync(localSpec, serverFile)) {
        this.sync(unit, ownerKey, api);
      }
    }
  }

  /** 后台触发一次字幕补齐（同账号同文件实例去重，不重复请求） */
  sync(unit: OfflineUnit, ownerKey: string, api: MovieClawApi): void {
    this.startTask(unit, ownerKey, api);
  }

  /** 本机起播前限时等待补齐（默认最多等 2 秒；超时立刻返回放行起播、后台继续收尾） */
  async syncWaiting(unit: OfflineUnit, ownerKey: string, api: MovieClawApi | null,
    timeoutMs: number = 2000): Promise<void> {
    if (api === null || !unit.playable || timeoutMs <= 0) {
      return;
    }
    const task: Promise<void> | null = this.startTask(unit, ownerKey, api);
    if (task === null) {
      return;
    }
    let timerId: number = -1;
    const timer: Promise<void> = new Promise<void>((resolve: () => void): void => {
      timerId = setTimeout(resolve, timeoutMs);
    });
    try {
      await Promise.race([task, timer]);
    } finally {
      if (timerId >= 0) {
        clearTimeout(timerId);
      }
    }
  }

  private startTask(unit: OfflineUnit, ownerKey: string, api: MovieClawApi): Promise<void> | null {
    if (!unit.playable) {
      return null;
    }
    const key: string = `${ownerKey}|${unit.fileId}|${unit.profile}|${unit.createdAt}|${unit.completedAt ?? -1}`;
    const existing: Promise<void> | undefined = this.inFlight.get(key);
    if (existing !== undefined) {
      return existing;
    }
    const task: Promise<void> = this.runSync(unit, ownerKey, api)
      .catch((): void => {
      })
      .finally((): void => {
        this.inFlight.delete(key);
      });
    this.inFlight.set(key, task);
    return task;
  }

  private async runSync(unit: OfflineUnit, ownerKey: string, api: MovieClawApi): Promise<void> {
    const unitPath: string = OfflineDisk.unitFile(ownerKey, unit.mediaItemId, unit.fileId);
    const playbackPath: string = OfflineDisk.playbackFile(ownerKey, unit.mediaItemId, unit.fileId);
    const diskUnit: OfflineUnit | null = OfflineDisk.readUnit(unitPath);
    const diskSpec: OfflinePlaybackSpec | null = OfflineDisk.readSpec(playbackPath);
    if (diskUnit === null || diskSpec === null || !diskUnit.playable) {
      return;
    }
    const expectedStamp: OfflineUnitStamp = new OfflineUnitStamp(diskUnit, diskSpec);

    const manifest: OfflineManifestView = await api.offlineManifest(unit.fileId);
    if (isDegradedOfflineManifest(manifest, diskSpec)) {
      return;
    }

    const unitDir: string = OfflineDisk.unitDir(ownerKey, unit.mediaItemId, unit.fileId);
    const subsDir: string = `${unitDir}/subs`;
    const fontsDir: string = `${unitDir}/fonts`;
    const plan: OfflineSubtitleSyncPlan = buildOfflineSubtitleSyncPlan(
      diskSpec.subtitles,
      manifest.subtitles,
      (name: string): boolean => OfflineDisk.exists(`${subsDir}/${name}`)
    );
    if (!plan.changed) {
      return;
    }

    const origin: string = AppModel.origin();
    const token: string = AppModel.shared.client?.getToken() ?? '';
    if (origin.length === 0) {
      return;
    }

    // 下载全部新增外挂字幕（任一失败直接中止，保持原 playback.json 完整）
    const subsToWrite: FetchedBinary[] = [];
    for (const item of plan.downloads) {
      const data: ArrayBuffer | null = await OfflineSubtitleSync.fetchBinary(
        OfflinePackager.resolve(origin, item.url), token);
      if (data === null) {
        return;
      }
      subsToWrite.push(new FetchedBinary(item.fileName, data));
    }

    // 若新补齐的字幕引入 ASS 且本机缺字体，顺手补齐字体包（最佳努力）
    const fontsToWrite: FetchedBinary[] = [];
    const addedFonts: string[] = [];
    let needsFonts: boolean = false;
    for (const s of plan.subtitles) {
      if (s.kind === 'ass') {
        needsFonts = true;
        break;
      }
    }
    const fontsUrl: string = manifest.fonts_url ?? '';
    if (needsFonts && fontsUrl.length > 0) {
      const existingFonts: Set<string> = new Set<string>(diskSpec.fonts);
      const listText: string | null = await OfflineSubtitleSync.fetchText(
        OfflinePackager.resolve(origin, fontsUrl), token);
      if (listText !== null) {
        const raw: Object | null = OfflineDisk.readJSONText(listText);
        const record: Record<string, Object> = raw === null ? {} : raw as Record<string, Object>;
        const innerObj: Object | undefined = record['data'];
        const inner: Record<string, Object> = innerObj === undefined ? {} : innerObj as Record<string, Object>;
        const fontList: Object | undefined = inner['fonts'];
        if (fontList !== undefined && Array.isArray(fontList)) {
          for (const entry of fontList as Object[]) {
            const url: string = `${entry}`;
            const rawName: string = url.substring(url.lastIndexOf('/') + 1);
            const name: string = `${OfflinePackager.safeName(rawName)}.ttf`;
            if (existingFonts.has(name) && OfflineDisk.exists(`${fontsDir}/${name}`)) {
              continue;
            }
            const fontData: ArrayBuffer | null = await OfflineSubtitleSync.fetchBinary(
              OfflinePackager.resolve(origin, url), token);
            if (fontData !== null) {
              fontsToWrite.push(new FetchedBinary(name, fontData));
              addedFonts.push(name);
            }
          }
        }
      }
    }

    // 落盘前再核对一次磁盘快照指纹：下载期间若发生删除、换档或同档重下，立即放弃写入
    const latestUnit: OfflineUnit | null = OfflineDisk.readUnit(unitPath);
    const latestSpec: OfflinePlaybackSpec | null = OfflineDisk.readSpec(playbackPath);
    if (!expectedStamp.matches(latestUnit, latestSpec) || latestSpec === null) {
      return;
    }

    const newlyWrittenPaths: string[] = [];
    try {
      for (const item of subsToWrite) {
        const target: string = `${subsDir}/${item.fileName}`;
        const existed: boolean = OfflineDisk.exists(target);
        OfflineDisk.writeBuffer(target, item.data);
        if (!existed) {
          newlyWrittenPaths.push(target);
        }
      }
      for (const item of fontsToWrite) {
        const target: string = `${fontsDir}/${item.fileName}`;
        const existed: boolean = OfflineDisk.exists(target);
        OfflineDisk.writeBuffer(target, item.data);
        if (!existed) {
          newlyWrittenPaths.push(target);
        }
      }
      latestSpec.subtitles = plan.subtitles;
      if (addedFonts.length > 0) {
        const mergedFonts: string[] = [];
        for (const f of latestSpec.fonts) {
          mergedFonts.push(f);
        }
        for (const f of addedFonts) {
          if (!mergedFonts.includes(f)) {
            mergedFonts.push(f);
          }
        }
        latestSpec.fonts = mergedFonts;
      }
      OfflineDisk.writeJSON(playbackPath, latestSpec as Object);
    } catch (_err) {
      for (const p of newlyWrittenPaths) {
        OfflineDisk.remove(p);
      }
      return;
    }

    // playback.json 落盘成功后再清理已失效的旧外挂字幕文件
    const referenced: Set<string> = new Set<string>();
    for (const s of latestSpec.subtitles) {
      referenced.add(s.fileName);
    }
    for (const obsolete of plan.obsoleteFiles) {
      if (!referenced.has(obsolete)) {
        OfflineDisk.remove(`${subsDir}/${obsolete}`);
      }
    }
  }

  private static async fetchBinary(url: string, token: string): Promise<ArrayBuffer | null> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = { 'Accept': '*/*' };
      if (token.length > 0) {
        header['Authorization'] = `Bearer ${token}`;
      }
      const res: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: SYNC_HTTP_TIMEOUT_MS
      });
      if (res.responseCode >= 200 && res.responseCode < 300 && res.result instanceof ArrayBuffer) {
        return res.result;
      }
      return null;
    } catch (_err) {
      return null;
    } finally {
      client.destroy();
    }
  }

  private static async fetchText(url: string, token: string): Promise<string | null> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = { 'Accept': 'application/json' };
      if (token.length > 0) {
        header['Authorization'] = `Bearer ${token}`;
      }
      const res: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: SYNC_HTTP_TIMEOUT_MS
      });
      if (res.responseCode >= 200 && res.responseCode < 300 && typeof res.result === 'string') {
        return res.result;
      }
      return null;
    } catch (_err) {
      return null;
    } finally {
      client.destroy();
    }
  }
}
