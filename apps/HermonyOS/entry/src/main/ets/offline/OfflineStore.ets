import { AppModel } from '../common/AppModel';
import { MovieClawApi } from '../api/Endpoints';
import { OfflineDisk } from './OfflineDisk';
import {
  OfflineItemSummary,
  OfflineOwner,
  OfflinePlaybackSpec,
  OfflineProgress,
  OfflineUnit,
  OfflineUnitState } from './OfflineModels';
import {
  EpisodeView,
  LibraryFileView,
  LibraryItemDetailView,
  LibraryView,
  SeasonEpisodesView } from '../api/Models';

/**
 * 本机副本的可观察目录（对应 iOS `Shared/Offline/OfflineStore.swift`）：
 * 当前账号有哪些条目、哪些单元、各自的状态与本机进度。
 *
 * 本类标了 `@ObservedV2`：`@Trace` 字段一变（Map 换引用、set 换键），读它们的
 * `@ComponentV2` 界面自动重绘。派生集合（`doneFileIds` 等）只在完成、删除时重算，
 * 下载进度每秒只改 `units` 里的那个单元，不该连带整面墙重算。
 */
@ObservedV2
export class OfflineStore {
  private static instance: OfflineStore | null = null;

  /** 惰性单例（同 AppModel：静态字段初始化器早于装饰器生效，不能 `static readonly`） */
  static get shared(): OfflineStore {
    if (OfflineStore.instance === null) {
      OfflineStore.instance = new OfflineStore();
    }
    return OfflineStore.instance;
  }

  @Trace owner: OfflineOwner | null = null;
  /** 条目摘要（summary.json 的内存镜像） */
  @Trace items: Map<number, OfflineItemSummary> = new Map<number, OfflineItemSummary>();
  /** 单元（unit.json 的内存镜像；键 = fileId） */
  @Trace units: Map<number, OfflineUnit> = new Map<number, OfflineUnit>();
  /** 本机进度（progress.json 的内存镜像；外层键 = 条目，内层键 = "季-集"） */
  @Trace progress: Map<number, Map<string, OfflineProgress>> =
    new Map<number, Map<string, OfflineProgress>>();
  /** 这台服务器支持离线下载（health 里有实例号）：没有时下载入口不出现 */
  @Trace serverSupported: boolean = false;
  /** 读完本机存档了（据此区分「还在读」和「真的没有」） */
  @Trace loaded: boolean = false;
  /** 正在下载的单元的实时速度（字节 / 秒，平滑过）：只在内存里 */
  @Trace speeds: Map<number, number> = new Map<number, number>();

  /** 下完、能播的单元（派生；只在完成、删除时变） */
  @Trace doneFileIds: Set<number> = new Set<number>();
  /** 至少有一个能播单元的条目（派生） */
  @Trace downloadedItemIds: Set<number> = new Set<number>();
  /** 下完的副本占的字节（「下载」页容量条读它；下载中不跟着每秒跳） */
  @Trace doneBytes: number = 0;

  private speedSamples: Map<number, number[]> = new Map<number, number[]>();
  private adoptingToken: string = '';

  private constructor() {
  }

  key(): string | null {
    const owner: OfflineOwner | null = this.owner;
    return owner !== null ? owner.key() : null;
  }

  // MARK: 账号

  /**
   * 以这个账号的身份使用：找到它的存档（按实例号；还不知道实例号时按地址 + 用户名找），
   * 读进内存。实例号向服务器问一次（`/health`），之后记在 owner.json 里，离线也认得出。
   */
  async adopt(origin: string, username: string, api: MovieClawApi): Promise<void> {
    const token: string = `${origin}|${username}`;
    if (this.adoptingToken === token && this.owner !== null) {
      return;
    }
    this.adoptingToken = token;
    const owners: OfflineOwner[] = OfflineStore.scanOwners();
    let instanceId: string = '';
    let match: OfflineOwner | null = null;
    // 先看本机记过的实例号（owner.json 一人一份，地址相同的服务器只认实例号）：
    // 同一个地址上换了一台服务器（重装），旧存档不能套到新服务器上
    for (const candidate of owners) {
      if (candidate.origin === origin && candidate.username === username) {
        instanceId = candidate.instanceId;
        match = candidate;
        break;
      }
    }
    if (instanceId.length === 0) {
      try {
        const health = await api.healthCheck();
        const id: string | null = health.instance_id ?? null;
        if (id !== null && id.length > 0) {
          instanceId = id;
          // 认得实例号时只按实例号找：换过地址的存档也归队
          for (const candidate of owners) {
            if (candidate.instanceId === instanceId && candidate.username === username) {
              match = candidate;
              break;
            }
          }
        }
      } catch (error) {
        // 连不上（离线冷启动）：本机有存档就先用着，下次连上再核对
      }
    }
    if (this.adoptingToken !== token) {
      return;
    }
    if (match !== null) {
      if (match.origin !== origin) {
        match.origin = origin;
        OfflineDisk.writeJSON(OfflineDisk.ownerFile(match.key()), match as Object);
      }
      this.applyOwner(match);
    } else if (instanceId.length > 0) {
      this.applyOwner(new OfflineOwner(instanceId, username, origin));
    } else {
      // 旧服务器（health 里没有实例号）或连不上又没有存档：先不开离线下载
      this.owner = null;
      this.serverSupported = false;
      this.loaded = true;
      this.refreshDerived();
    }
  }

  private applyOwner(owner: OfflineOwner): void {
    const changed: boolean = this.key() !== owner.key();
    this.owner = owner;
    this.serverSupported = true;
    if (!changed) {
      return;
    }
    this.loaded = false;
    this.refreshDerived();
    const key: string = owner.key();
    const snapshot = OfflineDisk.loadSnapshot(key);
    if (this.key() !== key) {
      return;
    }
    this.items = snapshot.items;
    this.units = snapshot.units;
    this.progress = snapshot.progress;
    this.loaded = true;
    this.refreshDerived();
  }

  /** 换账号 / 退出时清空内存（存档留在盘上，同一账号回来就还在） */
  reset(): void {
    this.adoptingToken = '';
    this.owner = null;
    this.loaded = false;
    this.serverSupported = false;
    this.refreshDerived();
  }

  /** 本机存过哪些账号（按 owner.json 认；存储页「其他账号」也读它） */
  static scanOwners(): OfflineOwner[] {
    const owners: OfflineOwner[] = [];
    const root: string = OfflineDisk.rootDir();
    const names: string[] = OfflineDisk.children(root);
    for (const name of names) {
      const owner: OfflineOwner | null = OfflineDisk.readOwner(`${root}/${name}/owner.json`);
      if (owner !== null) {
        owners.push(owner);
      }
    }
    return owners;
  }

  // MARK: 派生

  private refreshDerived(): void {
    const done: Set<number> = new Set<number>();
    const itemIds: Set<number> = new Set<number>();
    let bytes: number = 0;
    const fileIds: number[] = Array.from(this.units.keys());
    for (const fileId of fileIds) {
      const unit: OfflineUnit | undefined = this.units.get(fileId);
      if (unit === undefined || !unit.playable) {
        continue;
      }
      done.add(unit.fileId);
      itemIds.add(unit.mediaItemId);
      bytes += unit.receivedBytes;
    }
    this.doneFileIds = done;
    this.downloadedItemIds = itemIds;
    this.doneBytes = bytes;
  }

  // MARK: 查询

  unitsOfItem(itemId: number): OfflineUnit[] {
    const list: OfflineUnit[] = [];
    const fileIds: number[] = Array.from(this.units.keys());
    for (const fileId of fileIds) {
      const unit: OfflineUnit | undefined = this.units.get(fileId);
      if (unit !== undefined && unit.mediaItemId === itemId) {
        list.push(unit);
      }
    }
    list.sort((a: OfflineUnit, b: OfflineUnit): number => {
      if (a.season !== b.season) {
        return a.season - b.season;
      }
      return a.episode - b.episode;
    });
    return list;
  }

  /** 这个单元有没有能播的本机副本（一集有多个版本时取最新下完的那个） */
  playableUnit(mediaItemId: number, season: number, episode: number): OfflineUnit | null {
    let best: OfflineUnit | null = null;
    const fileIds: number[] = Array.from(this.units.keys());
    for (const fileId of fileIds) {
      const unit: OfflineUnit | undefined = this.units.get(fileId);
      if (unit === undefined || unit.mediaItemId !== mediaItemId || unit.season !== season
        || unit.episode !== episode || !unit.playable) {
        continue;
      }
      if (best === null || (unit.completedAt ?? 0) > (best.completedAt ?? 0)) {
        best = unit;
      }
    }
    return best;
  }

  /** 这个单元的本机副本（任意状态）：详情页的下载按钮看它 */
  unitOf(mediaItemId: number, season: number, episode: number): OfflineUnit | null {
    let playable: OfflineUnit | null = null;
    let latest: OfflineUnit | null = null;
    const fileIds: number[] = Array.from(this.units.keys());
    for (const fileId of fileIds) {
      const unit: OfflineUnit | undefined = this.units.get(fileId);
      if (unit === undefined || unit.mediaItemId !== mediaItemId || unit.season !== season
        || unit.episode !== episode) {
        continue;
      }
      if (unit.playable && playable === null) {
        playable = unit;
      }
      if (latest === null || unit.createdAt > latest.createdAt) {
        latest = unit;
      }
    }
    return playable !== null ? playable : latest;
  }

  /** 已下载的条目：最近下载的在前 */
  downloadedItems(): OfflineItemSummary[] {
    const list: OfflineItemSummary[] = [];
    const ids: number[] = Array.from(this.downloadedItemIds);
    for (const id of ids) {
      const summary: OfflineItemSummary | undefined = this.items.get(id);
      if (summary !== undefined) {
        list.push(summary);
      }
    }
    list.sort((a: OfflineItemSummary, b: OfflineItemSummary): number => b.addedAt - a.addedAt);
    return list;
  }

  /** 还在进行中（含失败、暂停）的单元：下载页「下载中」一节 */
  activeUnits(): OfflineUnit[] {
    const list: OfflineUnit[] = [];
    const fileIds: number[] = Array.from(this.units.keys());
    for (const fileId of fileIds) {
      const unit: OfflineUnit | undefined = this.units.get(fileId);
      if (unit !== undefined && unit.isActive) {
        list.push(unit);
      }
    }
    list.sort((a: OfflineUnit, b: OfflineUnit): number => a.createdAt - b.createdAt);
    return list;
  }

  localProgress(itemId: number, season: number, episode: number): OfflineProgress | null {
    const map: Map<string, OfflineProgress> | undefined = this.progress.get(itemId);
    if (map === undefined) {
      return null;
    }
    return map.get(`${season}-${episode}`) ?? null;
  }

  /** 本机视频文件的路径（播放器以 fd:// 打开） */
  mediaPath(unit: OfflineUnit): string | null {
    const key: string | null = this.key();
    return key !== null
      ? `${OfflineDisk.unitDir(key, unit.mediaItemId, unit.fileId)}/${unit.mediaFileName}` : null;
  }

  /** 本机副本的播放数据（章节 / 音轨 / 外挂字幕清单；没打包好返回 null，走不了本机播放） */
  spec(unit: OfflineUnit): OfflinePlaybackSpec | null {
    const key: string | null = this.key();
    return key !== null
      ? OfflineDisk.readSpec(OfflineDisk.playbackFile(key, unit.mediaItemId, unit.fileId)) : null;
  }

  /** 等目录加载完（进详情页先等这个；最多 timeoutMs 毫秒，超了就先按空目录渲染） */
  async waitUntilLoaded(timeoutMs: number = 3000): Promise<void> {
    const deadline: number = Date.now() + timeoutMs;
    while (!this.loaded && Date.now() < deadline) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 50);
      });
    }
  }

  /** 本机存的条目详情（离线只读页；没有副本返回 null）。就地改，别再导出去共享 */
  detail(itemId: number): LibraryItemDetailView | null {
    const key: string | null = this.key();
    if (key === null || !this.items.has(itemId)) {
      return null;
    }
    const raw: Object | null = OfflineDisk.readJSON(OfflineDisk.detailFile(key, itemId));
    return raw === null ? null : raw as LibraryItemDetailView;
  }

  /** 本机存的所属库（离线时详情页顶部要显示库名） */
  library(itemId: number): LibraryView | null {
    const key: string | null = this.key();
    if (key === null || !this.items.has(itemId)) {
      return null;
    }
    const raw: Object | null = OfflineDisk.readJSON(OfflineDisk.libraryFile(key, itemId));
    return raw === null ? null : raw as LibraryView;
  }

  /** 本机存的某季分集（离线只读页） */
  season(itemId: number, season: number): SeasonEpisodesView | null {
    const key: string | null = this.key();
    if (key === null || !this.items.has(itemId)) {
      return null;
    }
    const raw: Object | null = OfflineDisk.readJSON(OfflineDisk.seasonFile(key, itemId, season));
    return raw === null ? null : raw as SeasonEpisodesView;
  }

  /**
   * 离线显示的详情（对应 iOS `offlineDetail`）：文件只留本机有的，季只留有下载的，
   * 刮削/章节状态清掉。就地改传入的 detail（读盘对象或服务端快照，都不外传）。
   */
  offlineDetail(detail: LibraryItemDetailView): LibraryItemDetailView {
    const local: Set<number> = new Set<number>();
    for (const unit of this.unitsOfItem(detail.media_item_id)) {
      if (unit.playable) {
        local.add(unit.fileId);
      }
    }
    const files: LibraryFileView[] = [];
    let bytes: number = 0;
    for (const file of detail.files) {
      if (local.has(file.id)) {
        files.push(file);
        bytes += file.size_bytes;
      }
    }
    detail.files = files;
    detail.file_count = files.length;
    detail.total_size_bytes = bytes;
    if (detail.kind === 'tv') {
      const keptSeasons: Set<number> = new Set<number>();
      for (const file of files) {
        keptSeasons.add(file.season_number);
      }
      const seasons: number[] = [];
      for (const season of detail.seasons) {
        if (keptSeasons.has(season)) {
          seasons.push(season);
        }
      }
      detail.seasons = seasons;
    }
    detail.scraping = false;
    detail.chapters_pending = false;
    return detail;
  }

  /**
   * 离线显示的分集（对应 iOS `offlineSeason`）：「在库」改成「本机有没有」，
   * 进度取本机；服务端锚点指向没下的集时清掉锚点。就地改传入的 view。
   */
  offlineSeason(view: SeasonEpisodesView, itemId: number): SeasonEpisodesView {
    const episodes: EpisodeView[] = [];
    for (const episode of view.episodes) {
      const unit: OfflineUnit | null =
        this.playableUnit(itemId, view.season_number, episode.episode_number);
      episode.owned = unit !== null;
      episode.file_ids = unit !== null ? [unit.fileId] : [];
      const local: OfflineProgress | null =
        this.localProgress(itemId, view.season_number, episode.episode_number);
      if (local !== null) {
        episode.position_ms = local.positionMs;
        episode.played = local.played;
        const duration: number = local.durationMs ?? 0;
        if (duration > 0 && local.positionMs > 0) {
          episode.progress_percent = Math.min(100, Math.round(local.positionMs / duration * 100));
        }
      }
      episodes.push(episode);
    }
    view.episodes = episodes;
    const anchor: number | null = view.resume_episode ?? null;
    if (anchor !== null) {
      let anchorOwned: boolean = false;
      for (const episode of episodes) {
        if (episode.episode_number === anchor && episode.owned) {
          anchorOwned = true;
          break;
        }
      }
      if (!anchorOwned) {
        view.resume_episode = null;
      }
    }
    return view;
  }

  /** 本机这个条目的副本占了多少空间（存储页） */
  bytesOfItem(itemId: number): number {
    let total: number = 0;
    for (const unit of this.unitsOfItem(itemId)) {
      total += unit.receivedBytes;
    }
    return total;
  }

  get totalBytes(): number {
    let total: number = 0;
    const fileIds: number[] = Array.from(this.units.keys());
    for (const fileId of fileIds) {
      const unit: OfflineUnit | undefined = this.units.get(fileId);
      if (unit !== undefined) {
        total += unit.receivedBytes;
      }
    }
    return total;
  }

  // MARK: 写入

  upsert(unit: OfflineUnit): void {
    const key: string | null = this.key();
    if (key === null) {
      return;
    }
    this.units.set(unit.fileId, unit);
    if (unit.state !== OfflineUnitState.downloading) {
      this.clearSpeed(unit.fileId);
    }
    this.refreshDerived();
    OfflineDisk.writeUnit(unit, OfflineDisk.unitFile(key, unit.mediaItemId, unit.fileId));
  }

  /** 只改内存里的进度读数（下载回调每秒一次，不值得每次写盘） */
  updateReceived(fileId: number, received: number, expected: number | null): void {
    const unit: OfflineUnit | undefined = this.units.get(fileId);
    if (unit === undefined || (unit.state !== OfflineUnitState.downloading
      && unit.state !== OfflineUnitState.queued)) {
      return;
    }
    unit.receivedBytes = received;
    if (expected !== null && expected > 0 && (unit.profile === 'original' || unit.expectedBytes === 0)) {
      unit.expectedBytes = expected;
    }
    if (unit.state === OfflineUnitState.queued) {
      unit.state = OfflineUnitState.downloading;
    }
    this.sampleSpeed(fileId, received);
    // OfflineUnit 是普通类（序列化安全优先，没标 @ObservedV2）：字段直改不触发观察。
    // V2 的 Map 方法级追踪会盯住 set——同引用重设一次，读 units 的组件就重绘了。
    this.units.set(fileId, unit);
  }

  /** 速度 = 两次读数之间的字节差 / 时间差，再做指数平滑（原始值跳得厉害） */
  private sampleSpeed(fileId: number, received: number): void {
    const now: number = Date.now();
    const last: number[] | undefined = this.speedSamples.get(fileId);
    if (last === undefined) {
      this.speedSamples.set(fileId, [now, received]);
      return;
    }
    const elapsed: number = (now - last[0]) / 1000;
    if (elapsed < 0.5) {
      return;
    }
    const instant: number = Math.max(0, (received - last[1]) / elapsed);
    const previous: number | undefined = this.speeds.get(fileId);
    const smoothed: number = previous !== undefined ? previous * 0.6 + instant * 0.4 : instant;
    this.speeds.set(fileId, smoothed);
    this.speedSamples.set(fileId, [now, received]);
  }

  private clearSpeed(fileId: number): void {
    this.speedSamples.delete(fileId);
    this.speeds.delete(fileId);
  }

  upsertSummary(summary: OfflineItemSummary): void {
    const key: string | null = this.key();
    if (key === null) {
      return;
    }
    this.items.set(summary.mediaItemId, summary);
    OfflineDisk.writeSummary(summary, OfflineDisk.summaryFile(key, summary.mediaItemId));
  }

  /** 记一次本机进度（本机播放时每 10 秒；打包时服务器上的续播点也写进来） */
  recordProgress(itemId: number, season: number, episode: number, positionMs: number,
    played: boolean, durationMs: number | null, at: number): void {
    const key: string | null = this.key();
    if (key === null || !this.items.has(itemId)) {
      return;
    }
    let map: Map<string, OfflineProgress> | undefined = this.progress.get(itemId);
    if (map === undefined) {
      map = new Map<string, OfflineProgress>();
      this.progress.set(itemId, map);
    }
    map.set(`${season}-${episode}`, new OfflineProgress(positionMs, played, durationMs, at));
    OfflineDisk.writeProgressMap(map, OfflineDisk.progressFile(key, itemId));
  }

  /**
   * 删一个单元（取消下载、删本机副本）。条目的单元删光了，整个条目目录一起删；
   * `keepItem`：换档时只换这个单元，条目的展示数据与本机进度都留着。
   */
  removeUnit(fileId: number, keepItem: boolean): void {
    const key: string | null = this.key();
    const unit: OfflineUnit | undefined = this.units.get(fileId);
    if (key === null || unit === undefined) {
      return;
    }
    this.units.delete(fileId);
    this.clearSpeed(fileId);
    const itemId: number = unit.mediaItemId;
    const itemEmpty: boolean = !keepItem && !this.hasUnitsOfItem(itemId);
    if (itemEmpty) {
      this.items.delete(itemId);
      this.progress.delete(itemId);
    }
    this.refreshDerived();
    OfflineDisk.remove(itemEmpty
      ? OfflineDisk.itemDir(key, itemId)
      : OfflineDisk.unitDir(key, itemId, fileId));
  }

  removeItem(itemId: number): void {
    for (const unit of this.unitsOfItem(itemId)) {
      this.removeUnit(unit.fileId, false);
    }
  }

  private hasUnitsOfItem(itemId: number): boolean {
    const fileIds: number[] = Array.from(this.units.keys());
    for (const fileId of fileIds) {
      const unit: OfflineUnit | undefined = this.units.get(fileId);
      if (unit !== undefined && unit.mediaItemId === itemId) {
        return true;
      }
    }
    return false;
  }

  /** 首次下载这个账号的东西：建账号目录 */
  ensureOwnerOnDisk(): void {
    const owner: OfflineOwner | null = this.owner;
    if (owner === null) {
      return;
    }
    OfflineDisk.writeJSON(OfflineDisk.ownerFile(owner.key()), owner as Object);
  }

  /** AppModel 当前会话的取用（便捷口） */
  static currentApi(): MovieClawApi | null {
    return AppModel.shared.api;
  }
}
