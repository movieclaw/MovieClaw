import { util } from '@kit.ArkTS';
import { MovieClawApi } from '../api/Endpoints';
import { OfflineDisk } from './OfflineDisk';
import { OfflineStore } from './OfflineStore';
import {
  OfflineProgress,
  OfflineUnit,
  OfflineViewing } from './OfflineModels';
import { PlaybackViewingRecordIn, PlaybackViewingsRequest } from '../api/Models';

/**
 * 本机播放的观看记录（对应 iOS `Shared/Offline/OfflineViewings.swift`，
 * 设计 docs/design/offline-download.md §7）。
 *
 * 本机播放一律走这条路，在线离线一样；流式播放保持实时上报，两条不混用，
 * 免得一次观看被记两遍。先落盘再发：每 10 秒、暂停、停止时写一次；能连上就发
 * 最新的快照，连不上攒着，回来后一批补传。服务端按编号幂等合并、按发生时间判
 * 新旧、校正手机时钟偏差。
 */
export class OfflineViewingRecorder {
  private record: OfflineViewing;
  private readonly ownerKey: string;
  private readonly api: MovieClawApi | null;
  /** 上一次计时的时刻（在播时才累计观看时长） */
  private lastTickAt: number = -1;
  private lastSaveAt: number = 0;

  constructor(unit: OfflineUnit, startPositionMs: number, durationMs: number | null,
    api: MovieClawApi | null) {
    const key: string | null = OfflineStore.shared.key();
    this.ownerKey = key !== null ? key : '';
    this.api = api;
    const now: number = Date.now();
    this.record = new OfflineViewing(util.generateRandomUUID(false), unit.mediaItemId,
      unit.season, unit.episode, unit.fileId, now, startPositionMs, durationMs,
      OfflineViewingUploader.launch);
  }

  /** 播放读数（播放器每秒调一次）：在播的墙钟时间才算观看时长 */
  tick(positionMs: number, playing: boolean, durationMs: number | null): void {
    const now: number = Date.now();
    const wasPlaying: boolean = this.lastTickAt >= 0;
    if (playing && this.lastTickAt >= 0) {
      this.record.watchedMs += Math.max(0, now - this.lastTickAt);
    }
    this.lastTickAt = playing ? now : -1;
    // 刚暂停：立即落一次盘（暂停后被系统回收也不丢这段进度）
    if (wasPlaying && !playing) {
      this.lastSaveAt = 0;
    }
    this.record.positionMs = positionMs;
    this.record.updatedAt = now;
    if (durationMs !== null) {
      this.record.durationMs = durationMs;
    }
    this.record.dirty = true;
    if (now - this.lastSaveAt >= 10000) {
      this.save(true);
    }
  }

  /** 暂停、退后台：立即落一次盘并尝试发出 */
  checkpoint(): void {
    this.save(true);
  }

  /** 这次播放结束（退出、换集、播完） */
  finish(positionMs: number, completed: boolean): void {
    this.record.positionMs = positionMs;
    this.record.completed = this.record.completed || completed;
    this.record.ended = true;
    this.record.updatedAt = Date.now();
    this.record.dirty = true;
    this.save(true);
  }

  private save(send: boolean): void {
    this.lastSaveAt = Date.now();
    const store: OfflineStore = OfflineStore.shared;
    const current: OfflineProgress | null =
      store.localProgress(this.record.mediaItemId, this.record.season, this.record.episode);
    const outcome: ProgressOutcome = OfflineViewingRecorder.resolve(
      this.record.completed ? null : this.record.positionMs, this.record.durationMs,
      current !== null && current.played);
    store.recordProgress(this.record.mediaItemId, this.record.season, this.record.episode,
      outcome.positionMs, outcome.played, this.record.durationMs, Date.now());
    if (this.ownerKey.length === 0) {
      return;
    }
    OfflineDisk.writeViewing(this.record,
      OfflineDisk.viewingFile(this.ownerKey, this.record.viewingId));
    if (send && this.api !== null) {
      OfflineViewingUploader.shared.flush(this.api, this.ownerKey);
    }
  }

  /**
   * 本机续播点与服务端同一套阈值（movieclaw_playback/progress.py `resolve_progress`）：
   * 不足 5% 不记续播点、超过 90% 或离结尾 1 秒内算看完、短于 5 分钟的片过了开头就算看完。
   * 不同口径的话，离线时显示「继续 0:12」，连上之后服务端却说没看过
   */
  static resolve(positionMs: number | null, runtimeMs: number | null,
    currentlyPlayed: boolean): ProgressOutcome {
    if (positionMs === null) {
      return new ProgressOutcome(0, true);
    }
    if (positionMs <= 0) {
      return new ProgressOutcome(0, currentlyPlayed);
    }
    if (runtimeMs === null || runtimeMs <= 0) {
      return new ProgressOutcome(0, true);
    }
    const pct: number = positionMs / runtimeMs * 100;
    if (pct < 5) {
      return new ProgressOutcome(0, currentlyPlayed);
    }
    if (pct > 90 || positionMs >= runtimeMs - 1000) {
      return new ProgressOutcome(0, true);
    }
    if (runtimeMs < 300000) {
      return new ProgressOutcome(0, true);
    }
    return new ProgressOutcome(positionMs, currentlyPlayed);
  }
}

/** 把攒着的观看记录发给服务器：同一时刻只有一个在途请求；确认后、且这次播放已结束的才删 */
export class OfflineViewingUploader {
  static readonly shared: OfflineViewingUploader = new OfflineViewingUploader();

  /** 这次启动的编号：上次启动留下、又没结束的观看，是播放中被强退，补传前先收尾 */
  static readonly launch: string = util.generateRandomUUID(false);

  private inFlight: boolean = false;
  private again: boolean = false;

  flush(api: MovieClawApi, ownerKey: string): void {
    if (this.inFlight) {
      this.again = true;
      return;
    }
    this.inFlight = true;
    this.send(api, ownerKey).then((): void => {
      if (this.again) {
        this.again = false;
        this.inFlight = false;
        this.flush(api, ownerKey);
        return;
      }
      this.inFlight = false;
    }).catch((): void => {
      this.inFlight = false;
    });
  }

  private async send(api: MovieClawApi, ownerKey: string): Promise<void> {
    const dir: string = OfflineDisk.viewingsDir(ownerKey);
    const records: OfflineViewing[] = [];
    const names: string[] = OfflineDisk.children(dir);
    for (const name of names) {
      const viewing: OfflineViewing | null =
        OfflineDisk.readViewing(`${dir}/${name}`);
      if (viewing === null) {
        continue;
      }
      if (!viewing.ended && viewing.launch !== OfflineViewingUploader.launch) {
        // 上次启动时播放中被强退：这次播放到最后一次落盘的位置就结束了
        viewing.ended = true;
        viewing.dirty = true;
        OfflineDisk.writeViewing(viewing, `${dir}/${name}`);
      }
      if (viewing.dirty) {
        records.push(viewing);
      }
    }
    if (records.length === 0) {
      return;
    }
    for (let start: number = 0; start < records.length; start += 100) {
      const end: number = Math.min(start + 100, records.length);
      const batch: PlaybackViewingRecordIn[] = [];
      for (let i: number = start; i < end; i++) {
        batch.push(OfflineViewingUploader.recordIn(records[i]));
      }
      const body: PlaybackViewingsRequest = {
        sent_at: new Date().toISOString(),
        records: batch
      };
      const result = await api.playbackViewings(body);
      const acknowledged: Set<string> = new Set<string>();
      for (const row of result.results) {
        acknowledged.add(row.viewing_id);
      }
      let newer: boolean = false;
      for (let i: number = start; i < end; i++) {
        const record: OfflineViewing = records[i];
        if (!acknowledged.has(record.viewingId)) {
          continue;
        }
        const file: string = OfflineDisk.viewingFile(ownerKey, record.viewingId);
        const current: OfflineViewing | null = OfflineDisk.readViewing(file);
        if (current === null) {
          continue;
        }
        if (current.updatedAt !== record.updatedAt) {
          // 发出去之后又有了新快照（还在播）：留着，再发一次
          newer = true;
          continue;
        }
        if (current.ended) {
          OfflineDisk.remove(file);
        } else {
          current.dirty = false;
          OfflineDisk.writeViewing(current, file);
        }
      }
      if (newer) {
        this.again = true;
      }
    }
  }

  private static recordIn(record: OfflineViewing): PlaybackViewingRecordIn {
    const rec: PlaybackViewingRecordIn = {
      viewing_id: record.viewingId,
      media_item_id: record.mediaItemId,
      season_number: record.season,
      episode_number: record.episode,
      file_id: record.fileId,
      started_at: new Date(record.startedAt).toISOString(),
      updated_at: new Date(record.updatedAt).toISOString(),
      start_position_ms: record.startPositionMs,
      position_ms: record.positionMs,
      watched_ms: record.watchedMs,
      completed: record.completed,
      ended: record.ended,
      duration_ms: record.durationMs
    };
    return rec;
  }

  /** 是否还有没确认的记录（在线拿到服务器的续播点时，有待发的本机记录就不拿服务器的覆盖本机进度） */
  static hasPending(ownerKey: string, itemId: number, season: number, episode: number): boolean {
    const dir: string = OfflineDisk.viewingsDir(ownerKey);
    const names: string[] = OfflineDisk.children(dir);
    for (const name of names) {
      const record: OfflineViewing | null = OfflineDisk.readViewing(`${dir}/${name}`);
      if (record !== null && record.dirty && record.mediaItemId === itemId
        && record.season === season && record.episode === episode) {
        return true;
      }
    }
    return false;
  }
}

/** 本机续播点的判定结果（ArkTS 没有元组） */
class ProgressOutcome {
  positionMs: number;
  played: boolean;

  constructor(positionMs: number, played: boolean) {
    this.positionMs = positionMs;
    this.played = played;
  }
}
