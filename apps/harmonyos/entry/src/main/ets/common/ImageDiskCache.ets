import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ImageLruPolicy } from './ImageLruPolicy';

/**
 * 图片的 L2 磁盘缓存：原始编码字节（jpg/png/webp 原样落盘），解码留给展示层按视图尺寸做。
 *
 * 位置：`<cacheDir>/img_cache_v1/`——cacheDir 系统紧张时可整体回收，适合当缓存而非数据。
 * 键：URL 的双 FNV-1a 哈希（16 个 hex 字符）当文件名；一个 URL 一个 `.img` 文件 + 一份索引。
 * 索引：`index.json` 记录键序（旧→新）与文件大小；启动时重建 LRU 策略，touch 只标脏、
 * 结构变化（写入/删除/淘汰）时随写落盘，宕机丢几次 touch 也只是淘汰顺序略旧，无损。
 * 淘汰：总字节数超预算（默认 256MB）从最旧端删文件；策略语义见 ImageLruPolicy（有单测）。
 */
export class ImageDiskCache {
  private static readonly DEFAULT_BUDGET_BYTES: number = 256 * 1024 * 1024;
  private static readonly INDEX_FILE: string = 'index.json';
  private static readonly VERSION: number = 1;

  private static baseDir: string = '';
  private static budgetBytes: number = ImageDiskCache.DEFAULT_BUDGET_BYTES;
  private static ready: boolean = false;
  /** 键 → 磁盘实体 */
  private static readonly entries: Map<string, DiskEntry> = new Map<string, DiskEntry>();
  private static readonly lru: ImageLruPolicy = new ImageLruPolicy();

  static init(context: common.Context, budgetBytes?: number): void {
    if (budgetBytes !== undefined && budgetBytes > 0) {
      ImageDiskCache.budgetBytes = budgetBytes;
    }
    ImageDiskCache.baseDir = `${context.cacheDir}/img_cache_v1`;
    try {
      if (!fileIo.accessSync(ImageDiskCache.baseDir)) {
        fileIo.mkdirSync(ImageDiskCache.baseDir, true);
      }
      ImageDiskCache.loadIndex();
      ImageDiskCache.ready = true;
    } catch (error) {
      // 磁盘异常时缓存整体降级为关闭态：读写都走空实现，不阻塞图片展示
      ImageDiskCache.ready = false;
    }
  }

  /** 未 init（比如进程内别的入口先跑）时各接口安全空转。 */
  static isReady(): boolean {
    return ImageDiskCache.ready;
  }

  static contains(url: string): boolean {
    return ImageDiskCache.ready && ImageDiskCache.lru.has(ImageDiskCache.keyOf(url));
  }

  /** 读原始字节；未命中返回 null。命中即续命。 */
  static getBytes(url: string): ArrayBuffer | null {
    if (!ImageDiskCache.ready) {
      return null;
    }
    const key: string = ImageDiskCache.keyOf(url);
    const entry: DiskEntry | undefined = ImageDiskCache.entries.get(key);
    if (entry === undefined) {
      return null;
    }
    const path: string = `${ImageDiskCache.baseDir}/${entry.name}`;
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
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
      // 文件损坏/被系统回收：自愈——摘掉索引条目，下次重新下载
      ImageDiskCache.removeKey(key);
      return null;
    }
  }

  /** 原始字节落盘 + 超预算淘汰。失败静默（磁盘缓存永远不该影响功能）。 */
  static putBytes(url: string, data: ArrayBuffer): void {
    if (!ImageDiskCache.ready || data.byteLength <= 0) {
      return;
    }
    if (data.byteLength > ImageDiskCache.budgetBytes) {
      return;
    }
    const key: string = ImageDiskCache.keyOf(url);
    const name: string = `${key}.img`;
    const path: string = `${ImageDiskCache.baseDir}/${name}`;
    const tmpPath: string = `${ImageDiskCache.baseDir}/${key}.tmp`;
    try {
      // 先写临时文件再改名：写一半被杀不会留下半截文件被当成完整缓存
      const file: fileIo.File = fileIo.openSync(tmpPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, data);
      } finally {
        fileIo.closeSync(file);
      }
      fileIo.renameSync(tmpPath, path);
      const entry: DiskEntry = { name: name, size: data.byteLength };
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

  /** 全清（设置里的清缓存入口用）。 */
  static clearAll(): void {
    if (!ImageDiskCache.ready) {
      return;
    }
    const keys: string[] = ImageDiskCache.lru.keysSnapshot();
    for (let index = 0; index < keys.length; index++) {
      ImageDiskCache.removeKey(keys[index]);
    }
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

  private static evictIfNeeded(): void {
    const evicted: string[] = ImageDiskCache.lru.evictOverBudget(ImageDiskCache.budgetBytes);
    for (let index = 0; index < evicted.length; index++) {
      ImageDiskCache.removeKey(evicted[index]);
    }
  }

  /** URL → 双 FNV-1a 64 位哈希（hex）。碰撞概率 2^-64 级，缓存场景足够。 */
  private static keyOf(url: string): string {
    const high: number = ImageDiskCache.fnv1a(url, 0x811c9dc5);
    const low: number = ImageDiskCache.fnv1a(url, 0x01000193);
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

  private static loadIndex(): void {
    const path: string = ImageDiskCache.indexFilePath();
    try {
      if (!fileIo.accessSync(path)) {
        return;
      }
      const raw: Object | null = JSON.parse(fileIo.readTextSync(path));
      if (raw === null) {
        return;
      }
      const parsed: DiskIndexRaw = raw as DiskIndexRaw;
      if (parsed.version !== ImageDiskCache.VERSION || !Array.isArray(parsed.order)) {
        return;
      }
      const record: Record<string, Object> = parsed.entries as Record<string, Object>;
      // 按旧→新的顺序回放进 LRU，最新端落队尾，淘汰语义与落盘前一致
      for (let index = 0; index < parsed.order.length; index++) {
        const key: string = parsed.order[index];
        const entryRaw: Object | undefined = record[key];
        if (entryRaw === undefined) {
          continue;
        }
        const entry: DiskEntryRaw = entryRaw as DiskEntryRaw;
        if (typeof entry.name !== 'string' || typeof entry.size !== 'number' || entry.size < 0) {
          continue;
        }
        if (!fileIo.accessSync(`${ImageDiskCache.baseDir}/${entry.name}`)) {
          continue;
        }
        ImageDiskCache.entries.set(key, { name: entry.name, size: entry.size });
        ImageDiskCache.lru.insert(key, entry.size);
      }
    } catch (error) {
      // 索引坏了就当空缓存开始，文件等淘汰/清理流程收拾
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
          record[key] = { name: entry.name, size: entry.size };
        }
      }
      const raw: DiskIndexRaw = { version: ImageDiskCache.VERSION, order: order, entries: record };
      const path: string = ImageDiskCache.indexFilePath();
      const tmpPath: string = `${path}.tmp`;
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
}

interface DiskEntryRaw {
  name: string;
  size: number;
}

interface DiskIndexRaw {
  version: number;
  order: string[];
  entries: Record<string, DiskEntryRaw>;
}
