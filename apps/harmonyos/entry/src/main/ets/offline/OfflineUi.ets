import { BusinessError } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { MovieClawApi } from '../api/Endpoints';
import { ApiError } from '../api/ApiClient';
import { OfflineStore } from './OfflineStore';
import { OfflineDownloader, OfflineStartResult } from './OfflineDownloader';
import { OfflineDisk } from './OfflineDisk';
import { OfflineSpace, OfflineUnit, OfflineUnitState } from './OfflineModels';
import {
  OfflineFileProfilesView,
  OfflineManifestView,
  OfflineProfilesView,
  OfflineProfileView } from '../api/Models';

/**
 * 离线下载的 UI（对应 iOS `Features/Offline/OfflineDownloadViews.swift`）：
 * 详情页顶栏的下载按钮、选档 sheet、电影的下载状态条、分集行的下载小标。
 *
 * 全部 `@ComponentV2`：`@Local` 持 `OfflineStore` 单例直接读 `@Trace` 字段；
 * 嵌在 V1 详情页里时只传普通值与回调（项目既定模式，见 SaveAsCollectionSheet）。
 */

/** 把错误转成人话（`ApiError` 里已经是后端原话） */
function offlineErrorText(error: Object): string {
  if (error instanceof ApiError) {
    return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
  }
  const text: string = `${error}`;
  return text.length > 0 ? text : '操作失败';
}

// MARK: 范围与文案

/** 剧集下载的一个范围（选中的这一集 / 未看的集 / 全部）：分段选择里一段 */
export class OfflineDownloadScope {
  readonly id: string;
  /** 分段上的字，如「第 3 集」「接下来 5 集」「未看 8 集」「剩余 40 集」 */
  readonly label: string;
  readonly fileIds: number[];
  /** 范围下方的说明：「第 4～8 集，共 5 集」 */
  readonly detail: string | null;
  /** 打开时默认选中 */
  preferred: boolean;

  constructor(id: string, label: string, fileIds: number[], detail: string | null, preferred: boolean) {
    this.id = id;
    this.label = label;
    this.fileIds = fileIds;
    this.detail = detail;
    this.preferred = preferred;
  }
}

/** 一集在库的集与它在本机的状态（OfflineDownloadChoices.make 的输入） */
export class OfflineEpisodeChoice {
  readonly season: number;
  readonly episode: number;
  /** 该集在库的文件（台账号；null = 虽在库但取不到文件号） */
  readonly file: number | null;
  readonly played: boolean;
  /** 'done' = 本机已下完；'active' = 在下（含排队、失败）；null = 本机没有 */
  readonly local: string | null;

  constructor(season: number, episode: number, file: number | null, played: boolean, local: string | null) {
    this.season = season;
    this.episode = episode;
    this.file = file;
    this.played = played;
    this.local = local;
  }
}

/**
 * 剧集「下载」的可选范围，加一句为什么有些集不在里面
 * （「第 3 集已下载 · 已下载 3 集，不会重复下载」）。范围规则见 iOS `OfflineDownloadChoices.make`。
 */
export class OfflineDownloadChoices {
  scopes: OfflineDownloadScope[];
  note: string | null;

  constructor(scopes: OfflineDownloadScope[], note: string | null) {
    this.scopes = scopes;
    this.note = note;
  }

  static make(episodes: OfflineEpisodeChoice[], selectedSeason: number | null,
    selectedEpisode: number | null, selectedFile: number | null,
    multiSeason: boolean): OfflineDownloadChoices {
    const nextCount: number = 5;
    const name = (season: number, episode: number): string => {
      return multiSeason ? `第 ${season} 季第 ${episode} 集` : `第 ${episode} 集`;
    };
    const describe = (list: OfflineEpisodeChoice[]): string => {
      if (list.length === 0) {
        return '';
      }
      const first: OfflineEpisodeChoice = list[0];
      const last: OfflineEpisodeChoice = list[list.length - 1];
      if (list.length === 1) {
        return name(first.season, first.episode);
      }
      if (first.season === last.season && last.episode - first.episode + 1 === list.length) {
        return `${multiSeason ? `第 ${first.season} 季` : ''}第 ${first.episode}～${last.episode} 集，共 ${list.length} 集`;
      }
      return `${name(first.season, first.episode)} 起，共 ${list.length} 集`;
    };
    // 候选 = 有文件、本机还没有的集（下完的、在下的都不算）
    const candidates: OfflineEpisodeChoice[] = [];
    for (const episode of episodes) {
      if (episode.file !== null && episode.local === null) {
        candidates.push(episode);
      }
    }
    let done: number = 0;
    let active: number = 0;
    for (const episode of episodes) {
      if (episode.local === 'done') {
        done += 1;
      } else if (episode.local === 'active') {
        active += 1;
      }
    }
    const scopes: OfflineDownloadScope[] = [];
    const notes: string[] = [];
    if (selectedSeason !== null && selectedEpisode !== null) {
      let index: number = -1;
      for (let i: number = 0; i < episodes.length; i++) {
        if (episodes[i].season === selectedSeason && episodes[i].episode === selectedEpisode) {
          index = i;
          break;
        }
      }
      if (index >= 0) {
        const current: OfflineEpisodeChoice = episodes[index];
        if (current.local !== null) {
          // 选中的集已下 / 在下：说明一句，范围换成「接下来 N 集」（追剧边看边下）
          notes.push(`${name(current.season, current.episode)}${current.local === 'done' ? '已下载' : '正在下载'}`);
          const next: OfflineEpisodeChoice[] = [];
          for (let i: number = index + 1; i < episodes.length && next.length < nextCount; i++) {
            const candidate: OfflineEpisodeChoice = episodes[i];
            if (candidate.file !== null && candidate.local === null) {
              next.push(candidate);
            }
          }
          if (next.length > 0 && next.length < candidates.length) {
            scopes.push(new OfflineDownloadScope('next', `接下来 ${next.length} 集`,
              OfflineDownloadChoices.fileIdsOf(next), describe(next), false));
          }
        } else {
          const file: number | null = selectedFile !== null ? selectedFile : current.file;
          if (file !== null) {
            scopes.push(new OfflineDownloadScope('selected', name(current.season, current.episode),
              [file], name(current.season, current.episode), false));
          }
        }
      }
    }
    if (done + active > 0) {
      const parts: string[] = [];
      if (done > 0) {
        parts.push(`已下载 ${done} 集`);
      }
      if (active > 0) {
        parts.push(`正在下载 ${active} 集`);
      }
      notes.push(`${parts.join('、')}，不会重复下载`);
    }
    const unwatched: OfflineEpisodeChoice[] = [];
    for (const candidate of candidates) {
      if (!candidate.played) {
        unwatched.push(candidate);
      }
    }
    if (unwatched.length > 0 && unwatched.length < candidates.length) {
      scopes.push(new OfflineDownloadScope('unwatched', `未看 ${unwatched.length} 集`,
        OfflineDownloadChoices.fileIdsOf(unwatched), describe(unwatched), true));
    }
    if (candidates.length > 0) {
      const label: string = done + active === 0 ? `全部 ${candidates.length} 集` : `剩余 ${candidates.length} 集`;
      scopes.push(new OfflineDownloadScope('all', label,
        OfflineDownloadChoices.fileIdsOf(candidates), describe(candidates), false));
    }
    // 内容相同的只留前一个（比如只剩选中的这一集）
    const seen: Set<string> = new Set<string>();
    const deduped: OfflineDownloadScope[] = [];
    for (const scope of scopes) {
      const key: string = scope.fileIds.join(',');
      if (!seen.has(key)) {
        seen.add(key);
        deduped.push(scope);
      }
    }
    // 默认：有「未看」选未看；否则「接下来」；剩下的都没看过时选全部 / 剩余
    let hasPreferred: boolean = false;
    for (const scope of deduped) {
      if (scope.preferred) {
        hasPreferred = true;
        break;
      }
    }
    if (!hasPreferred) {
      let fallback: OfflineDownloadScope | null = null;
      for (const scope of deduped) {
        if (scope.id === 'next') {
          fallback = scope;
          break;
        }
      }
      if (fallback === null && unwatched.length === candidates.length) {
        for (const scope of deduped) {
          if (scope.id === 'all') {
            fallback = scope;
            break;
          }
        }
      }
      if (fallback !== null) {
        fallback.preferred = true;
      }
    }
    return new OfflineDownloadChoices(deduped, notes.length > 0 ? notes.join(' · ') : null);
  }

  private static fileIdsOf(list: OfflineEpisodeChoice[]): number[] {
    const out: number[] = [];
    for (const episode of list) {
      if (episode.file !== null) {
        out.push(episode.file);
      }
    }
    return out;
  }
}

/** 选档的算法（iOS `OfflineProfileSheet` 里的静态函数） */
export class OfflineProfileCalc {
  /** 某一集按这一档的档位：没有这一档就用它的原画（开始下载时同样退回） */
  static pick(profile: string, entry: OfflineFileProfilesView): OfflineProfileView | null {
    const options: OfflineProfileView[] = entry.profiles ?? [];
    for (const option of options) {
      if (option.profile === profile) {
        return option;
      }
    }
    return options.length > 0 ? options[0] : null;
  }

  /** 整批按这一档的大小里有没有预计值：有一集落在转码档上就是 */
  static isEstimate(profile: string, files: OfflineFileProfilesView[]): boolean {
    for (const entry of files) {
      if (entry.unavailable_reason != null) {
        continue;
      }
      const picked: OfflineProfileView | null = OfflineProfileCalc.pick(profile, entry);
      if ((picked !== null ? picked.profile : 'original') !== 'original') {
        return true;
      }
    }
    return false;
  }

  /** 整批按这一档的总大小 */
  static totalBytes(profile: string, files: OfflineFileProfilesView[]): number {
    let sum: number = 0;
    for (const entry of files) {
      if (entry.unavailable_reason != null) {
        continue;
      }
      const picked: OfflineProfileView | null = OfflineProfileCalc.pick(profile, entry);
      if (picked !== null) {
        sum += picked.expected_bytes;
      }
    }
    return sum;
  }

  /** 旧服务器：用逐集清单换算成批量档位（iOS loadManifests 里那段构造） */
  static entryOf(manifest: OfflineManifestView): OfflineFileProfilesView {
    return {
      file_id: manifest.file_id,
      media_item_id: manifest.media_item_id,
      season_number: manifest.season_number,
      episode_number: manifest.episode_number,
      container: manifest.container,
      profiles: manifest.profiles,
      unavailable_reason: manifest.unavailable_reason
    };
  }
}

/** 单元状态的一句话文案（iOS `OfflineDownloadStrip.status` / `OfflineUnitStatus.text`） */
export class OfflineUnitText {
  /** 短的（电影状态条、分集小标） */
  static status(unit: OfflineUnit): string {
    const percent: string = unit.expectedBytes > 0 ? ` ${Math.floor(unit.progressFraction * 100)}%` : '';
    if (unit.damaged) {
      return '文件损坏，请重新下载';
    }
    if (unit.state === OfflineUnitState.preparing) {
      return '准备下载';
    }
    if (unit.state === OfflineUnitState.queued) {
      return '等待下载';
    }
    if (unit.state === OfflineUnitState.downloading) {
      return `下载中${percent}`;
    }
    if (unit.state === OfflineUnitState.paused) {
      return `已暂停${percent}`;
    }
    if (unit.state === OfflineUnitState.failed) {
      if (unit.waitingForTranscode) {
        return unit.transcodeWait ?? '等待转码';
      }
      return unit.retryable ? '下载中断，稍后重试' : '下载失败';
    }
    return '已下载';
  }

  /** 长的（存储页「下载中」的行） */
  static line(unit: OfflineUnit): string {
    if (unit.state === OfflineUnitState.preparing) {
      return '正在准备…';
    }
    if (unit.state === OfflineUnitState.queued) {
      return '等待下载';
    }
    if (unit.state === OfflineUnitState.downloading) {
      return unit.expectedBytes > 0
        ? `下载中 ${Math.floor(unit.progressFraction * 100)}%`
        : `下载中 ${OfflineDownloader.formatBytes(unit.receivedBytes)}`;
    }
    if (unit.state === OfflineUnitState.paused) {
      return '已暂停';
    }
    if (unit.state === OfflineUnitState.failed) {
      if (unit.waitingForTranscode) {
        return unit.transcodeWait ?? '等待转码';
      }
      return unit.retryable ? '下载中断，稍后自动重试' : (unit.error ?? '下载失败');
    }
    return unit.damaged ? '文件损坏，请重新下载' : '已下载';
  }
}

// MARK: 分集小标

/** 分集行尾的下载小标：「已下载」/「下载中 47%」/「已暂停」…（对应 iOS 分集卡上的下载状态） */
@ComponentV2
export struct OfflineEpisodeDownloadMark {
  @Param mediaItemId: number = 0;
  @Param season: number = 0;
  @Param episode: number = 0;
  @Local store: OfflineStore = OfflineStore.shared;

  build() {
    if (this.markUnit() !== null) {
      Text(this.markText())
        .fontSize(10)
        .fontWeight(600)
        .fontColor(this.markColor())
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor(this.markBackground())
        .borderRadius(6)
        .maxLines(1)
    }
  }

  private markUnit(): OfflineUnit | null {
    return this.store.unitOf(this.mediaItemId, this.season, this.episode);
  }

  private markText(): string {
    const unit: OfflineUnit | null = this.markUnit();
    if (unit === null) {
      return '';
    }
    if (unit.playable) {
      return '已下载';
    }
    return OfflineUnitText.status(unit);
  }

  private markColor(): string {
    const unit: OfflineUnit | null = this.markUnit();
    if (unit === null) {
      return Theme.textFaint;
    }
    if (unit.playable) {
      return Theme.ok;
    }
    if (unit.needsAttention) {
      return Theme.warning;
    }
    return Theme.info;
  }

  private markBackground(): string {
    const unit: OfflineUnit | null = this.markUnit();
    if (unit !== null && unit.needsAttention) {
      return 'rgba(251, 191, 36, 0.12)';
    }
    if (unit !== null && unit.playable) {
      return 'rgba(74, 222, 128, 0.12)';
    }
    return 'rgba(56, 189, 248, 0.12)';
  }
}

// MARK: 电影状态条

/**
 * 电影详情页播放键上方的下载状态条（对应 iOS `OfflineDownloadControl` +
 * `OfflineDownloadStatusBar`）：左边状态图标、中间「下载中 47%」、右边实时速度；
 * 点它出操作菜单（暂停 / 继续 / 重试 / 删除）。没在进行中的副本时什么都不画。
 */
@ComponentV2
export struct OfflineDownloadControl {
  @Param mediaItemId: number = 0;
  @Param title: string = '';
  @Local store: OfflineStore = OfflineStore.shared;

  build() {
    if (this.barUnit() !== null) {
      Row({ space: 10 }) {
        this.StateIcon(this.barUnit() as OfflineUnit)
        Text(this.statusText())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.tint())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.speed() > 0) {
          Text(`${OfflineDownloader.formatBytes(this.speed())}/s`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 11, bottom: 11 })
      .backgroundColor(Theme.surfaceRaised)
      .borderRadius(12)
      .border({ width: 1, color: this.tint() === Theme.warning
        ? 'rgba(251, 191, 36, 0.35)' : Theme.line })
      .bindMenu(this.ControlMenu(this.barUnit() as OfflineUnit))
    }
  }

  private barUnit(): OfflineUnit | null {
    const unit: OfflineUnit | null = this.store.unitOf(this.mediaItemId, 0, 0);
    return unit !== null && !unit.playable ? unit : null;
  }

  private tint(): string {
    const unit: OfflineUnit | null = this.barUnit();
    return unit !== null && unit.needsAttention ? Theme.warning : Theme.info;
  }

  private statusText(): string {
    const unit: OfflineUnit | null = this.barUnit();
    if (unit === null) {
      return '';
    }
    const text: string = OfflineUnitText.status(unit);
    if (unit.state === OfflineUnitState.failed && !unit.waitingForTranscode) {
      return `${text}，点按重试`;
    }
    return text;
  }

  private speed(): number {
    const unit: OfflineUnit | null = this.barUnit();
    if (unit === null || unit.state !== OfflineUnitState.downloading) {
      return 0;
    }
    return this.store.speeds.get(unit.fileId) ?? 0;
  }

  @Builder
  StateIcon(unit: OfflineUnit) {
    if (unit.state === OfflineUnitState.paused) {
      SymbolGlyph($r('sys.symbol.pause_circle_fill'))
        .fontSize(18)
        .fontColor([this.tint()])
    } else if (unit.state === OfflineUnitState.failed) {
      if (unit.waitingForTranscode) {
        SymbolGlyph($r('sys.symbol.hourglass'))
          .fontSize(18)
          .fontColor([this.tint()])
      } else {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize(18)
          .fontColor([this.tint()])
      }
    } else if (unit.damaged) {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
        .fontSize(18)
        .fontColor([this.tint()])
    } else if (unit.state === OfflineUnitState.downloading || unit.state === OfflineUnitState.queued) {
      // 同 App Store 的下载环：知道总量画进度
      Progress({ value: Math.max(2, Math.round(unit.progressFraction * 100)), total: 100, type: ProgressType.Ring })
        .width(18)
        .height(18)
        .color(this.tint())
        .style({ strokeWidth: 2.5 })
    } else {
      LoadingProgress()
        .width(16)
        .height(16)
        .color(this.tint())
    }
  }

  @Builder
  ControlMenu(unit: OfflineUnit) {
    Menu() {
      if (unit.state === OfflineUnitState.queued || unit.state === OfflineUnitState.downloading) {
        MenuItem({ content: '暂停', startIcon: $r('sys.symbol.pause_fill') })
          .onClick(() => {
            OfflineDownloader.shared.pause(unit.fileId);
          })
      }
      if (unit.state === OfflineUnitState.paused) {
        MenuItem({ content: '继续下载', startIcon: $r('sys.symbol.play_fill') })
          .onClick(() => {
            OfflineDownloader.shared.resume(unit.fileId);
          })
      }
      if (unit.state === OfflineUnitState.failed && !unit.waitingForTranscode) {
        MenuItem({ content: '重试', startIcon: $r('sys.symbol.arrow_clockwise') })
          .onClick(() => {
            OfflineDownloader.shared.resume(unit.fileId);
          })
      }
      MenuItem({
        content: unit.state === OfflineUnitState.done ? '删除下载' : '取消下载',
        startIcon: $r('sys.symbol.trash')
      })
        .contentFontColor(Theme.danger)
        .onClick(() => {
          this.confirmDelete(unit);
        })
    }
  }

  private confirmDelete(unit: OfflineUnit): void {
    const done: boolean = unit.state === OfflineUnitState.done;
    this.getUIContext().showAlertDialog({
      title: done ? '删除这份下载？' : '取消下载？',
      message: '只删本机上的副本，观看进度会保留。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: `${done ? '删除下载' : '取消下载'}（${OfflineDownloader.formatBytes(unit.receivedBytes)}）`,
        fontColor: Theme.danger,
        action: (): void => {
          OfflineDownloader.shared.delete(unit.fileId);
        }
      }
    });
  }
}

// MARK: 顶栏下载按钮

/**
 * 详情页顶栏的下载按钮（对应 iOS ⋯ 菜单里的「下载」与「取消下载」组）：
 * 电影直接选画质、剧集在面板里选范围；这部剧还在下时给取消入口。
 * 权限与服务器支持由宿主页算好传进来；本机状态自己盯着（V2 观察 OfflineStore）。
 */
@ComponentV2
export struct OfflineItemDownloadButton {
  @Param mediaItemId: number = 0;
  @Param isMovie: boolean = true;
  /** 电影能下的文件 id（选中的版本在前；宿主从 currentFiles() 来） */
  @Param fileIds: number[] = [];
  /** 剧集：选中的季 / 集（「取消下载选中的集」用） */
  @Param selectedSeason: number = -1;
  @Param selectedEpisode: number = -1;
  /** 有没有下载权限（Permissions.canDownloadVideo） */
  @Param canDownload: boolean = false;
  @Event onOpenMovie: () => void = (): void => {
  };
  @Event onOpenSeries: () => void = (): void => {
  };
  @Local store: OfflineStore = OfflineStore.shared;

  build() {
    if (this.visible()) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.arrow_down_circle'))
          .fontSize(20)
          .fontColor([Theme.text])
      }
      .width(40)
      .height(40)
      .backgroundColor('rgba(0, 0, 0, 0.35)')
      .borderRadius(20)
      .bindMenu(this.DownloadMenu())
    }
  }

  private activeUnits(): OfflineUnit[] {
    const out: OfflineUnit[] = [];
    for (const unit of this.store.activeUnits()) {
      if (unit.mediaItemId === this.mediaItemId) {
        out.push(unit);
      }
    }
    return out;
  }

  /** 按钮出不出来：有下载入口、或这部剧还有可取消的下载 */
  private visible(): boolean {
    if (!this.store.serverSupported) {
      return false;
    }
    const active: OfflineUnit[] = this.activeUnits();
    if (this.canDownload) {
      if (!this.isMovie) {
        return true;
      }
      // 电影：本机已有（下着 / 下完）就不给——状态条上管
      return active.length === 0 && !this.store.downloadedItemIds.has(this.mediaItemId)
        && this.fileIds.length > 0;
    }
    return active.length > 0;
  }

  private activeSelected(): OfflineUnit | null {
    for (const unit of this.activeUnits()) {
      if (unit.season === this.selectedSeason && unit.episode === this.selectedEpisode) {
        return unit;
      }
    }
    return null;
  }

  @Builder
  DownloadMenu() {
    Menu() {
      // 这部剧 / 这部电影还在下的：给取消入口（下完自动消失）
      if (this.isMovie) {
        if (this.activeUnits().length > 0) {
          MenuItem({ content: '取消下载', startIcon: $r('sys.symbol.xmark') })
            .contentFontColor(Theme.danger)
            .onClick(() => {
              const active: OfflineUnit[] = this.activeUnits();
              if (active.length > 0) {
                OfflineDownloader.shared.delete(active[0].fileId);
              }
            })
        }
      } else {
        if (this.activeSelected() !== null) {
          MenuItem({ content: '取消下载选中的集', startIcon: $r('sys.symbol.xmark') })
            .onClick(() => {
              const unit: OfflineUnit | null = this.activeSelected();
              if (unit !== null) {
                OfflineDownloader.shared.delete(unit.fileId);
              }
            })
        }
        if (this.activeUnits().length > 0) {
          MenuItem({ content: `取消全部下载（${this.activeUnits().length} 集）`, startIcon: $r('sys.symbol.xmark') })
            .contentFontColor(Theme.danger)
            .onClick(() => {
              this.confirmCancelAll();
            })
        }
      }
      if (this.canDownload) {
        MenuItem({ content: '下载…', startIcon: $r('sys.symbol.arrow_down_circle') })
          .onClick(() => {
            if (this.isMovie) {
              this.onOpenMovie();
            } else {
              this.onOpenSeries();
            }
          })
      }
    }
  }

  private confirmCancelAll(): void {
    const count: number = this.activeUnits().length;
    this.getUIContext().showAlertDialog({
      title: '取消这部剧正在进行的下载？',
      message: '已下完的集会保留。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: `取消 ${count} 集的下载`,
        fontColor: Theme.danger,
        action: (): void => {
          for (const unit of this.activeUnits()) {
            OfflineDownloader.shared.delete(unit.fileId);
          }
        }
      }
    });
  }
}

// MARK: 选档面板

/**
 * 下载选档（对应 iOS `OfflineProfileSheet`）：点一行只是选中（打勾），右上角「下载」才开始。
 * 每一档显示整批的总大小，空间不够时说明并禁用「下载」。剧集从顶栏进来时顶部多一排范围。
 *
 * 大小来自批量接口 `POST /offline/profiles`：打开时把所有范围的文件一次问完，
 * 切范围只是换个算法，不再发请求。点「下载」才取第一集的完整清单，
 * 其余集先建「准备中」单元，由下载器逐集取清单。旧服务器（404/405）退回逐集取清单。
 */
@ComponentV2
export struct OfflineProfileSheet {
  /** 单文件模式：要下的文件（电影 / 长按某一集）；-1 = 范围模式 */
  @Param fileId: number = -1;
  @Param title: string = '';
  /** 范围模式的取范围（剧集：拉各季分集、算本机状态） */
  @Event choices: () => Promise<OfflineDownloadChoices> = (): Promise<OfflineDownloadChoices> => {
    return Promise.reject(new Error('没有提供下载范围'));
  };
  /** 开始下载 / 点取消后关面板（宿主把 bindSheet 置 false） */
  @Event onDone: () => void = (): void => {
  };

  @Local scopes: OfflineDownloadScope[] | null = null;
  @Local note: string | null = null;
  @Local scopeId: string | null = null;
  /** 每个文件的可选档位（批量接口；旧服务器由逐集清单换算） */
  @Local entries: Map<number, OfflineFileProfilesView> = new Map<number, OfflineFileProfilesView>();
  /** 已经问过的文件（问过却不在 entries 里 = 看不到 / 取不到，会跳过） */
  @Local asked: Set<number> = new Set<number>();
  /** 旧服务器逐集取到的完整清单（开始下载时直接用） */
  @Local manifests: Map<number, OfflineManifestView> = new Map<number, OfflineManifestView>();
  @Local legacy: boolean = false;
  @Local loadError: string | null = null;
  @Local startError: string | null = null;
  /** 用户点过的档位（没点过默认原画） */
  @Local choice: string | null = null;
  @Local starting: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  /** 旧服务器：范围定了（或切了）就逐集取清单（并发 6，取过的不重取） */
  @Monitor('legacy', 'scopeId')
  private onScopeChanged(): void {
    if (!this.legacy || this.scopes === null) {
      return;
    }
    this.loadLegacyManifests();
  }

  private ranged(): boolean {
    return this.fileId < 0;
  }

  private currentScope(): OfflineDownloadScope | null {
    const scopes: OfflineDownloadScope[] | null = this.scopes;
    if (scopes === null) {
      return null;
    }
    const id: string | null = this.scopeId;
    for (const scope of scopes) {
      if (scope.id === id) {
        return scope;
      }
    }
    return scopes.length > 0 ? scopes[0] : null;
  }

  private currentFileIds(): number[] {
    if (!this.ranged()) {
      return this.fileId >= 0 ? [this.fileId] : [];
    }
    const scope: OfflineDownloadScope | null = this.currentScope();
    return scope !== null ? scope.fileIds : [];
  }

  private batch(): boolean {
    return this.currentFileIds().length > 1;
  }

  private ready(): boolean {
    const ids: number[] = this.currentFileIds();
    if (ids.length === 0) {
      return false;
    }
    for (const id of ids) {
      if (!this.asked.has(id)) {
        return false;
      }
    }
    return true;
  }

  /** 当前范围里取不到下载信息的文件数（开始下载时会跳过） */
  private missing(): number {
    let count: number = 0;
    for (const id of this.currentFileIds()) {
      if (!this.entries.has(id)) {
        count += 1;
      }
    }
    return count;
  }

  /** 当前范围里取到了的文件（按集的顺序） */
  private current(): OfflineFileProfilesView[] {
    const out: OfflineFileProfilesView[] = [];
    for (const id of this.currentFileIds()) {
      const entry: OfflineFileProfilesView | undefined = this.entries.get(id);
      if (entry !== undefined) {
        out.push(entry);
      }
    }
    return out;
  }

  /** 选中的档位：用户点过的 → 原画 */
  private selectedProfile(first: OfflineFileProfilesView): string {
    return this.choice !== null ? this.choice : 'original';
  }

  private neededBytes(): number {
    const files: OfflineFileProfilesView[] = this.current();
    if (files.length === 0) {
      return 0;
    }
    return OfflineProfileCalc.totalBytes(this.selectedProfile(files[0]), files) + OfflineSpace.reserveBytes;
  }

  private spaceShort(): boolean {
    const free: number = OfflineDisk.availableBytes();
    return free >= 0 && this.neededBytes() > free;
  }

  private canStart(): boolean {
    if (this.starting || this.scopes === null) {
      return false;
    }
    const files: OfflineFileProfilesView[] = this.current();
    if (!this.ready() || files.length === 0) {
      return false;
    }
    const first: OfflineFileProfilesView = files[0];
    if (!this.batch() && first.unavailable_reason != null) {
      return false;
    }
    return !this.spaceShort();
  }

  // MARK: 取数

  private async load(): Promise<void> {
    if (this.fileId >= 0) {
      this.scopes = [new OfflineDownloadScope('file', this.title, [this.fileId], null, false)];
      this.scopeId = 'file';
      await this.loadProfiles([this.fileId]);
      return;
    }
    try {
      const result: OfflineDownloadChoices = await this.choices();
      this.note = result.note;
      this.scopes = result.scopes;
      let preferred: OfflineDownloadScope | null = null;
      for (const scope of result.scopes) {
        if (scope.preferred && preferred === null) {
          preferred = scope;
        }
      }
      this.scopeId = preferred !== null ? preferred.id
        : (result.scopes.length > 0 ? result.scopes[0].id : null);
      // 所有范围的文件一次问完：切范围不再发请求
      const all: number[] = [];
      for (const scope of result.scopes) {
        for (const id of scope.fileIds) {
          if (all.indexOf(id) < 0) {
            all.push(id);
          }
        }
      }
      await this.loadProfiles(all);
    } catch (error) {
      this.loadError = offlineErrorText(error);
    }
  }

  /** 一次问完一批文件的档位（每次最多 500 个）。旧服务器（404/405）改走逐集清单 */
  private async loadProfiles(ids: number[]): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      this.loadError = '还没有连接到服务器';
      return;
    }
    try {
      for (let start: number = 0; start < ids.length; start += 500) {
        const chunk: number[] = ids.slice(start, Math.min(start + 500, ids.length));
        const result: OfflineProfilesView = await api.offlineProfiles({ file_ids: chunk });
        const files: OfflineFileProfilesView[] = result.files ?? [];
        for (const entry of files) {
          this.entries.set(entry.file_id, entry);
        }
        for (const id of chunk) {
          this.asked.add(id);
        }
      }
    } catch (error) {
      if (error instanceof ApiError && (error.status === 404 || error.status === 405)) {
        this.legacy = true;
        return;
      }
      this.loadError = offlineErrorText(error);
      for (const id of ids) {
        this.asked.add(id);
      }
    }
  }

  private async loadLegacyManifests(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const ids: number[] = this.currentFileIds();
    if (api === null || ids.length === 0) {
      return;
    }
    const pending: number[] = [];
    for (const id of ids) {
      if (!this.asked.has(id)) {
        pending.push(id);
      }
    }
    for (let start: number = 0; start < pending.length; start += 6) {
      const chunk: number[] = pending.slice(start, Math.min(start + 6, pending.length));
      const requests: Promise<void>[] = [];
      for (const id of chunk) {
        requests.push(api.offlineManifest(id)
          .then((manifest: OfflineManifestView): void => {
            this.manifests.set(manifest.file_id, manifest);
            this.entries.set(manifest.file_id, OfflineProfileCalc.entryOf(manifest));
          })
          .catch((error: BusinessError): void => {
            this.loadError = offlineErrorText(error);
          }));
      }
      await Promise.all(requests);
      for (const id of chunk) {
        this.asked.add(id);
      }
    }
  }

  // MARK: 开始下载

  private async startDownload(): Promise<void> {
    const files: OfflineFileProfilesView[] = this.current();
    if (files.length === 0 || this.starting) {
      return;
    }
    const profileName: string = this.selectedProfile(files[0]);
    const available: OfflineFileProfilesView[] = [];
    for (const entry of files) {
      if (entry.unavailable_reason == null) {
        available.push(entry);
      }
    }
    if (available.length === 0) {
      this.startError = files[0].unavailable_reason ?? '没能开始下载';
      return;
    }
    this.starting = true;
    const lead: OfflineFileProfilesView = available[0];
    let manifest: OfflineManifestView;
    const known: OfflineManifestView | undefined = this.manifests.get(lead.file_id);
    if (known !== undefined) {
      manifest = known;
    } else {
      const api: MovieClawApi | null = AppModel.shared.api;
      if (api === null) {
        this.startError = '还没有连接到服务器';
        this.starting = false;
        return;
      }
      try {
        manifest = await api.offlineManifest(lead.file_id);
      } catch (error) {
        this.startError = offlineErrorText(error);
        this.starting = false;
        return;
      }
    }
    let leadProfile: OfflineProfileView | null = null;
    for (const option of manifest.profiles) {
      if (option.profile === profileName) {
        leadProfile = option;
        break;
      }
    }
    if (leadProfile === null && manifest.profiles.length > 0) {
      leadProfile = manifest.profiles[0];
    }
    if (leadProfile === null) {
      this.startError = manifest.unavailable_reason ?? '没能开始下载';
      this.starting = false;
      return;
    }
    const leadResult: OfflineStartResult = OfflineDownloader.shared.start(manifest, leadProfile);
    if (!leadResult.ok) {
      this.startError = leadResult.message;
      this.starting = false;
      return;
    }
    if (!this.batch()) {
      this.onDone();
      return;
    }
    // 其余集：清单有的直接开始，没有的先建「准备中」单元（由下载器逐集取清单）
    let started: number = 1;
    let failures: number = 0;
    for (let i: number = 1; i < available.length; i++) {
      const entry: OfflineFileProfilesView = available[i];
      const chosen: OfflineProfileView | null = OfflineProfileCalc.pick(profileName, entry);
      if (chosen === null) {
        continue;
      }
      const full: OfflineManifestView | undefined = this.manifests.get(entry.file_id);
      let result: OfflineStartResult;
      if (full !== undefined) {
        let match: OfflineProfileView | null = null;
        for (const option of full.profiles) {
          if (option.profile === chosen.profile) {
            match = option;
            break;
          }
        }
        result = OfflineDownloader.shared.start(full, match !== null ? match : chosen);
      } else {
        result = OfflineDownloader.shared.enqueue(entry, chosen);
      }
      if (result.ok) {
        started += 1;
      } else {
        failures += 1;
      }
    }
    const skipped: number = failures + this.missing() + (files.length - available.length);
    const message: string = skipped > 0
      ? `已开始下载 ${started} 集，${skipped} 集没能开始`
      : `已开始下载 ${started} 集`;
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    this.onDone();
  }

  // MARK: 视图

  build() {
    Column() {
      // 顶栏：取消 / 标题 / 下载
      Row() {
        Text('取消')
          .fontSize(16)
          .fontColor(Theme.textMuted)
          .onClick(() => {
            this.onDone();
          })
        Blank()
        Text('下载到本机')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Blank()
        if (this.starting) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(Theme.accentStrong)
        } else {
          Text('下载')
            .fontSize(16)
            .fontWeight(600)
            .fontColor(this.canStart() ? Theme.accentStrong : Theme.textFaint)
            .onClick(() => {
              this.startDownload();
            })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 10 })

      if (this.scopes === null && this.loadError === null) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(24)
            .height(24)
            .color(Theme.textMuted)
          Text('正在读取可下载的集')
            .fontSize(14)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.scopes !== null && this.scopes.length === 0) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(32)
            .fontColor([Theme.ok])
          Text('都已下载')
            .fontSize(16)
            .fontWeight(600)
            .fontColor(Theme.text)
          Text('这部剧能下的集都已在本机上')
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.scopes === null && this.loadError !== null) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(32)
            .fontColor([Theme.warning])
          Text('拿不到下载信息')
            .fontSize(16)
            .fontWeight(600)
            .fontColor(Theme.text)
          Text(this.loadError as string)
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            Column({ space: 4 }) {
              Text(this.title)
                .fontSize(17)
                .fontWeight(600)
                .fontColor(Theme.text)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.note !== null) {
                Text(this.note as string)
                  .fontSize(12)
                  .fontColor(Theme.textMuted)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 20, right: 20, top: 4, bottom: 12 })

            if (this.ranged() && this.currentScope() !== null) {
              this.ScopeSection()
            }
            if (this.ready() && this.current().length > 0) {
              this.ProfileSection()
            } else if (this.ready()) {
              Text(this.loadError ?? '拿不到下载信息')
                .fontSize(14)
                .fontColor(Theme.warning)
                .padding({ left: 20, right: 20, bottom: 12 })
            } else {
              Row({ space: 10 }) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color(Theme.textMuted)
                Text(this.batch() ? `正在计算 ${this.currentFileIds().length} 集的大小` : '正在读取可下载的画质')
                  .fontSize(14)
                  .fontColor(Theme.textMuted)
              }
              .padding({ top: 8, bottom: 12 })
            }
            if (this.startError !== null) {
              Text(this.startError as string)
                .fontSize(13)
                .fontColor(Theme.danger)
                .padding({ left: 20, right: 20, bottom: 12 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ bottom: 24 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Start)
        .edgeEffect(EdgeEffect.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 剧集：下载范围（分段胶囊 + 范围说明） */
  @Builder
  ScopeSection() {
    Column({ space: 8 }) {
      Text('下载范围')
        .fontSize(13)
        .fontColor(Theme.textFaint)
      if ((this.scopes as OfflineDownloadScope[]).length > 1) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.scopes as OfflineDownloadScope[], (scope: OfflineDownloadScope) => {
              Text(scope.label)
                .fontSize(13)
                .fontWeight(this.scopeId === scope.id ? 600 : 400)
                .fontColor(this.scopeId === scope.id ? '#0b0d12' : Theme.textMuted)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.scopeId === scope.id ? Color.White : Theme.glassFill)
                .borderRadius(14)
                .onClick(() => {
                  this.scopeId = scope.id;
                  this.startError = null;
                })
            }, (scope: OfflineDownloadScope) => scope.id)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      } else {
        Text((this.currentScope() as OfflineDownloadScope).label)
          .fontSize(14)
          .fontColor(Theme.text)
      }
      Text(this.scopeDetailLine())
        .fontSize(12)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, bottom: 14 })
  }

  private scopeDetailLine(): string {
    const scope: OfflineDownloadScope | null = this.currentScope();
    if (scope === null) {
      return '';
    }
    const detail: string = scope.detail ?? scope.label;
    const skippedNote: string = this.ready() && this.missing() > 0
      ? `（其中 ${this.missing()} 集取不到下载信息，会跳过）` : '';
    return `${detail}${skippedNote}`;
  }

  /** 画质列表 + 空间说明 */
  @Builder
  ProfileSection() {
    Column({ space: 0 }) {
      if (!this.batch() && (this.current()[0].unavailable_reason ?? '') !== '') {
        Text(this.current()[0].unavailable_reason ?? '')
          .fontSize(14)
          .fontColor(Theme.warning)
          .padding({ bottom: 12 })
      } else {
        Text('画质')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .padding({ bottom: 4 })
        ForEach(this.current()[0].profiles ?? [], (profile: OfflineProfileView) => {
          this.ProfileRow(profile)
        }, (profile: OfflineProfileView) => profile.profile)
        this.SpaceFooter()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20 })
  }

  @Builder
  ProfileRow(profile: OfflineProfileView) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(profile.label)
          .fontSize(15)
          .fontColor(Theme.text)
        Text(profile.profile === 'original' ? '原文件，画质最好' : '服务器转码后下载，边转边下')
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(this.profileSizeText(profile))
        .fontSize(13)
        .fontColor(Theme.textMuted)
      if (this.isSelectedProfile(profile)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(15)
          .fontWeight(600)
          .fontColor([Theme.info])
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(() => {
      this.choice = profile.profile;
      this.startError = null;
    })
  }

  private isSelectedProfile(profile: OfflineProfileView): boolean {
    const files: OfflineFileProfilesView[] = this.current();
    return files.length > 0 && profile.profile === this.selectedProfile(files[0]);
  }

  /** 原画是文件实际大小，写准数；转码档是预计，前面带 ≈；批量前面带「共」 */
  private profileSizeText(profile: OfflineProfileView): string {
    const files: OfflineFileProfilesView[] = this.current();
    const total: number = OfflineProfileCalc.totalBytes(profile.profile, files);
    const estimate: string = OfflineProfileCalc.isEstimate(profile.profile, files) ? '≈ ' : '';
    return `${this.batch() ? '共 ' : ''}${estimate}${OfflineDownloader.formatBytes(total)}`;
  }

  @Builder
  SpaceFooter() {
    if (this.spaceShort()) {
      Text(this.spaceShortText())
        .fontSize(12)
        .fontColor(Theme.danger)
    } else if (OfflineDisk.availableBytes() >= 0) {
      Text(`本机剩余 ${OfflineDownloader.formatBytes(OfflineDisk.availableBytes())}`)
        .fontSize(12)
        .fontColor(Theme.textMuted)
    }
  }

  private spaceShortText(): string {
    const files: OfflineFileProfilesView[] = this.current();
    const estimate: string = files.length > 0
      && OfflineProfileCalc.isEstimate(this.selectedProfile(files[0]), files) ? '≈ ' : '';
    return `空间不够：需要 ${estimate}${OfflineDownloader.formatBytes(this.neededBytes())}`
      + `（含预留 2 GB），本机只剩 ${OfflineDownloader.formatBytes(OfflineDisk.availableBytes())}。`
      + '换个小一点的画质，或先清理空间。';
  }
}
