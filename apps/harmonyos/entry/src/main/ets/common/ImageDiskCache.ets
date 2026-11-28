import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ImageLruPolicy } from './ImageLruPolicy';

/**
 * 图片的 L2 磁盘缓存：原始编码字节（jpg/png/webp 原样落盘），解码留给展示层按视图尺寸做。
 *
 * 位置：`<cacheDir>/img_cache_v1/`——cacheDir 系统紧张时可整体回收，适合当缓存而非数据。
 * 隔离：键按 `ownerKey + URL` 计算双 FNV-1a 哈希（16 个 hex 字符），并记录 owner，
 * 账号/服务器切换互不串读，注销或移除账号时可精确清理该账号条目，全部注销时全清。
 * 索引：`index.json`（version=2）记录键序（旧→新）、归属与文件大小；启动时核对磁盘实际大小、
 * 清理孤儿 `.img`/`.tmp`（含 v1 升级遗留），并立即按预算（默认 256MB）淘汰。
 */
export class ImageDiskCache {
  static readonly DEFAULT_BUDGET_BYTES: number = 256 * 1024 * 1024;
  private static readonly INDEX_FILE: string = 'index.json';
  private static readonly VERSION: number = 2;

  private static baseDir: string = '';
  private static budgetBytes: number = ImageDiskCache.DEFAULT_BUDGET_BYTES;
  private static ready: boolean = false;
  private static writeSeq: number = 0;
  /** 键 → 磁盘实体 */
  private static readonly entries: Map<string, DiskEntry> = new Map<string, DiskEntry>();
  private static readonly lru: ImageLruPolicy = new ImageLruPolicy();

  static init(context: common.Context, budgetBytes?: number): void {
    ImageDiskCache.entries.clear();
    ImageDiskCache.lru.clearAll();
    ImageDiskCache.ready = false;
    ImageDiskCache.budgetBytes =
      budgetBytes !== undefined && budgetBytes > 0 ? budgetBytes : ImageDiskCache.DEFAULT_BUDGET_BYTES;
    ImageDiskCache.baseDir = `${context.cacheDir}/img_cache_v1`;
    try {
      if (!fileIo.accessSync(ImageDiskCache.baseDir)) {
        fileIo.mkdirSync(ImageDiskCache.baseDir, true);
      }
      const indexDirty: boolean = ImageDiskCache.loadIndex();
      const swept: boolean = ImageDiskCache.reconcileDiskFiles();
      const evicted: boolean = ImageDiskCache.evictIfNeeded();
      ImageDiskCache.ready = true;
      if (indexDirty || swept || evicted) {
        ImageDiskCache.saveIndex();
      }
    } catch (error) {
      // 磁盘异常时缓存整体降级为关闭态：读写都走空实现，不阻塞图片展示
      ImageDiskCache.entries.clear();
      ImageDiskCache.lru.clearAll();
      ImageDiskCache.ready = false;
    }
  }

  /** 未 init（比如进程内别的入口先跑）时各接口安全空转。 */
  static isReady(): boolean {
    return ImageDiskCache.ready;
  }

  static contains(ownerKey: string, url: string): boolean {
    return ImageDiskCache.ready && ImageDiskCache.lru.has(ImageDiskCache.keyOf(ownerKey, url));
  }

  /** 读原始字节；未命中返回 null。命中即续命。 */
  static getBytes(ownerKey: string, url: string): ArrayBuffer | null {
    if (!ImageDiskCache.ready) {
      return null;
    }
    const key: string = ImageDiskCache.keyOf(ownerKey, url);
    const entry: DiskEntry | undefined = ImageDiskCache.entries.get(key);
    if (entry === undefined) {
      return null;
    }
    const path: string = `${ImageDiskCache.baseDir}/${entry.name}`;
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        ImageDiskCache.removeKey(key);
        ImageDiskCache.saveIndex();
        return null;
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        let readTotal: number = 0;
        while (readTotal < stat.size) {
          const once: number = fileIo.readSync(file.fd, buffer, {
            offset: readTotal,
            length: stat.size - readTotal
          });
          if (once <= 0) {
            ImageDiskCache.removeKey(key);
            ImageDiskCache.saveIndex();
            return null;
          }
          readTotal += once;
        }
        ImageDiskCache.lru.touch(key);
        return buffer;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      // 文件损坏/被系统回收：自愈——摘掉索引条目并回写索引，下次重新下载
      ImageDiskCache.removeKey(key);
      ImageDiskCache.saveIndex();
      return null;
    }
  }

  /** 原始字节落盘 + 超预算淘汰。失败静默（磁盘缓存永远不该影响功能）。 */
  static putBytes(ownerKey: string, url: string, data: ArrayBuffer): void {
    if (!ImageDiskCache.ready) {
      return;
    }
    const key: string = ImageDiskCache.keyOf(ownerKey, url);
    if (data.byteLength <= 0 || data.byteLength > ImageDiskCache.budgetBytes) {
      if (ImageDiskCache.entries.has(key)) {
        ImageDiskCache.removeKey(key);
        ImageDiskCache.saveIndex();
      }
      return;
    }
    const name: string = `${key}.img`;
    const path: string = `${ImageDiskCache.baseDir}/${name}`;
    ImageDiskCache.writeSeq++;
    const tmpPath: string = `${ImageDiskCache.baseDir}/${key}.${ImageDiskCache.writeSeq}.tmp`;
    try {
      // 先写唯一临时文件再改名：写一半被杀或并发写同键不会留下半截文件
      const file: fileIo.File = fileIo.openSync(tmpPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      let writtenTotal: number = 0;
      try {
        while (writtenTotal < data.byteLength) {
          const chunk: ArrayBuffer = writtenTotal === 0 ? data : data.slice(writtenTotal);
          const once: number = fileIo.writeSync(file.fd, chunk);
          if (once <= 0) {
            throw new Error('short write');
          }
          writtenTotal += once;
        }
      } finally {
        fileIo.closeSync(file);
      }
      fileIo.renameSync(tmpPath, path);
      const entry: DiskEntry = { name: name, size: data.byteLength, owner: ownerKey };
      ImageDiskCache.entries.set(key, entry);
      ImageDiskCache.lru.insert(key, data.byteLength);
      ImageDiskCache.evictIfNeeded();
      ImageDiskCache.saveIndex();
    } catch (error) {
      try {
        if (fileIo.accessSync(tmpPath)) {
          fileIo.unlinkSync(tmpPath);
        }
      } catch (cleanupError) {
        // 清理失败只能放弃
      }
    }
  }

  /** 移除单条（如磁盘字节解码失败时的自愈清理）。 */
  static remove(ownerKey: string, url: string): void {
    if (!ImageDiskCache.ready) {
      return;
    }
    const key: string = ImageDiskCache.keyOf(ownerKey, url);
    if (!ImageDiskCache.entries.has(key)) {
      return;
    }
    ImageDiskCache.removeKey(key);
    ImageDiskCache.saveIndex();
  }

  /** 清理指定账号/服务器归属的全部磁盘缓存（注销、移除账号、会话失效时用）。 */
  static clearOwner(ownerKey: string): void {
    if (!ImageDiskCache.ready || ownerKey.length === 0) {
      return;
    }
    const keys: string[] = ImageDiskCache.lru.keysSnapshot();
    let changed: boolean = false;
    for (let index = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const entry: DiskEntry | undefined = ImageDiskCache.entries.get(key);
      if (entry !== undefined && entry.owner === ownerKey) {
        ImageDiskCache.removeKey(key);
        changed = true;
      }
    }
    if (changed) {
      ImageDiskCache.saveIndex();
    }
  }

  /** 全清（全部注销 / 设置清缓存入口用；连同孤儿文件一并清理）。 */
  static clearAll(): void {
    if (!ImageDiskCache.ready) {
      return;
    }
    const keys: string[] = ImageDiskCache.lru.keysSnapshot();
    for (let index = 0; index < keys.length; index++) {
      ImageDiskCache.removeKey(keys[index]);
    }
    ImageDiskCache.entries.clear();
    ImageDiskCache.lru.clearAll();
    ImageDiskCache.reconcileDiskFiles();
    ImageDiskCache.saveIndex();
  }

  static statsEntries(): number {
    return ImageDiskCache.lru.size();
  }

  static statsBytes(): number {
    return ImageDiskCache.lru.budget();
  }

  static statsBudgetBytes(): number {
    return ImageDiskCache.budgetBytes;
  }

  private static removeKey(key: string): void {
    const entry: DiskEntry | undefined = ImageDiskCache.entries.get(key);
    if (entry === undefined) {
      ImageDiskCache.lru.remove(key);
      return;
    }
    try {
      const path: string = `${ImageDiskCache.baseDir}/${entry.name}`;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (error) {
      // 文件已经不在了就算清完成
    }
    ImageDiskCache.entries.delete(key);
    ImageDiskCache.lru.remove(key);
  }

  private static evictIfNeeded(): boolean {
    const evicted: string[] = ImageDiskCache.lru.evictOverBudget(ImageDiskCache.budgetBytes);
    for (let index = 0; index < evicted.length; index++) {
      ImageDiskCache.removeKey(evicted[index]);
    }
    return evicted.length > 0;
  }

  /** 扫描目录：清理未登记在索引里的孤儿 `.img` 与遗留 `.tmp`，保证磁盘实际占用不超过预算。 */
  private static reconcileDiskFiles(): boolean {
    let swept: boolean = false;
    try {
      const trackedNames: Set<string> = new Set<string>();
      ImageDiskCache.entries.forEach((entry: DiskEntry): void => {
        trackedNames.add(entry.name);
      });
      const files: string[] = fileIo.listFileSync(ImageDiskCache.baseDir);
      for (let index = 0; index < files.length; index++) {
        const name: string = files[index];
        if (name === ImageDiskCache.INDEX_FILE) {
          continue;
        }
        if (name.endsWith('.tmp') || (name.endsWith('.img') && !trackedNames.has(name))) {
          try {
            fileIo.unlinkSync(`${ImageDiskCache.baseDir}/${name}`);
            swept = true;
          } catch (unlinkError) {
            // 删不掉忽略
          }
        }
      }
    } catch (error) {
      // 列目录失败时保持当前索引继续工作
    }
    return swept;
  }

  /** 归属 + URL → 双 FNV-1a 64 位哈希（hex）。碰撞概率 2^-64 级，缓存场景足够。 */
  private static keyOf(ownerKey: string, url: string): string {
    const scoped: string = `${ownerKey}\u0000${url}`;
    const high: number = ImageDiskCache.fnv1a(scoped, 0x811c9dc5);
    const low: number = ImageDiskCache.fnv1a(scoped, 0x01000193);
    const highHex: string = high.toString(16).padStart(8, '0');
    const lowHex: string = low.toString(16).padStart(8, '0');
    return `${highHex}${lowHex}`;
  }

  private static fnv1a(data: string, seed: number): number {
    let hash: number = seed >>> 0;
    for (let index = 0; index < data.length; index++) {
      hash ^= data.charCodeAt(index);
      hash = Math.imul(hash, 16777619) >>> 0;
    }
    return hash >>> 0;
  }

  private static indexFilePath(): string {
    return `${ImageDiskCache.baseDir}/${ImageDiskCache.INDEX_FILE}`;
  }

  /** 返回 true 表示索引与磁盘存在差异（版本升级/坏索引/缺文件/尺寸偏差），需要回写。 */
  private static loadIndex(): boolean {
    const path: string = ImageDiskCache.indexFilePath();
    try {
      if (!fileIo.accessSync(path)) {
        return false;
      }
      const raw: Object | null = JSON.parse(fileIo.readTextSync(path));
      if (raw === null) {
        return true;
      }
      const parsed: DiskIndexRaw = raw as DiskIndexRaw;
      if (parsed.version !== ImageDiskCache.VERSION || !Array.isArray(parsed.order)) {
        // 旧版 v1 无账号归属，整仓放弃，随后 reconcileDiskFiles 会扫清旧文件
        return true;
      }
      const record: Record<string, Object> = parsed.entries as Record<string, Object>;
      if (record === undefined || record === null) {
        return true;
      }
      let dirty: boolean = false;
      // 按旧→新的顺序回放进 LRU，最新端落队尾，淘汰语义与落盘前一致
      for (let index = 0; index < parsed.order.length; index++) {
        const key: string = parsed.order[index];
        const entryRaw: Object | undefined = record[key];
        if (entryRaw === undefined) {
          dirty = true;
          continue;
        }
        const entry: DiskEntryRaw = entryRaw as DiskEntryRaw;
        if (typeof entry.name !== 'string' || typeof entry.size !== 'number' || entry.size <= 0
          || typeof entry.owner !== 'string') {
          dirty = true;
          continue;
        }
        const filePath: string = `${ImageDiskCache.baseDir}/${entry.name}`;
        if (!fileIo.accessSync(filePath)) {
          dirty = true;
          continue;
        }
        const stat: fileIo.Stat = fileIo.statSync(filePath);
        if (stat.size <= 0 || stat.size > ImageDiskCache.budgetBytes) {
          dirty = true;
          continue;
        }
        if (stat.size !== entry.size) {
          dirty = true;
        }
        ImageDiskCache.entries.set(key, { name: entry.name, size: stat.size, owner: entry.owner });
        ImageDiskCache.lru.insert(key, stat.size);
      }
      return dirty;
    } catch (error) {
      // 索引坏了就当空缓存开始，reconcileDiskFiles 立即清理遗留文件
      return true;
    }
  }

  private static saveIndex(): void {
    if (!ImageDiskCache.ready) {
      return;
    }
    try {
      const record: Record<string, DiskEntryRaw> = {};
      const order: string[] = ImageDiskCache.lru.keysSnapshot();
      const keys: string[] = Array.from(ImageDiskCache.entries.keys());
      for (let index = 0; index < keys.length; index++) {
        const key: string = keys[index];
        const entry: DiskEntry | undefined = ImageDiskCache.entries.get(key);
        if (entry !== undefined) {
          record[key] = { name: entry.name, size: entry.size, owner: entry.owner };
        }
      }
      const raw: DiskIndexRaw = { version: ImageDiskCache.VERSION, order: order, entries: record };
      const path: string = ImageDiskCache.indexFilePath();
      ImageDiskCache.writeSeq++;
      const tmpPath: string = `${path}.${ImageDiskCache.writeSeq}.tmp`;
      const file: fileIo.File = fileIo.openSync(tmpPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(raw));
      } finally {
        fileIo.closeSync(file);
      }
      fileIo.renameSync(tmpPath, path);
    } catch (error) {
      // 保存失败下次结构变化再试
    }
  }
}

interface DiskEntry {
  name: string;
  size: number;
  owner: string;
}

interface DiskEntryRaw {
  name: string;
  size: number;
  owner: string;
}

interface DiskIndexRaw {
  version: number;
  order: string[];
  entries: Record<string, DiskEntryRaw>;
}
