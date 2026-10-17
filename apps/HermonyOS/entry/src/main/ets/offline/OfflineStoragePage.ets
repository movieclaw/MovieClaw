import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';
import { OfflineStore } from './OfflineStore';
import { OfflineDisk } from './OfflineDisk';
import { OfflineDownloader } from './OfflineDownloader';
import { OfflineUnitText } from './OfflineUi';
import { OfflineItemSummary, OfflineOwner, OfflineUnit, OfflineUnitState } from './OfflineModels';

/**
 * 下载管理的分区组件（对应 iOS `Features/Offline/OfflineStorageView.swift`，我的 → 下载）：
 * 下载中（有才出现，每一集一行，下完就移到已下载）→ 清理建议（有已看完的才出现）
 * → 已下载（点进条目、左滑 / 长按删除）→ 其他账号 → 容量条（放最后）。
 *
 * 每个分区是独立的 @ComponentV2（List 直接子组件，根节点 ListItem / ListItemGroup），
 * 既拼成独立的「下载管理」页，也内嵌到「我的」页的下载段（同 iOS 复用 sections）。
 *
 * 鸿蒙没有 OfflineSettings（蜂窝开关、默认档记忆）：iOS 右上角的设置菜单不移植。
 *
 * **行是活的子组件**：ForEach 对没变的键不会重新执行 itemGenerator，下载进度每秒
 * 在变——行组件自己 `@Local` 持 `OfflineStore` 盯 `units` 的 Map 追踪，进度、速度、
 * 状态自己重绘，父级只管行的增删。
 */

/** 地址里的人话主机名（其他账号一行用） */
function hostOf(origin: string): string {
  let rest: string = origin;
  if (rest.startsWith('https://')) {
    rest = rest.substring(8);
  } else if (rest.startsWith('http://')) {
    rest = rest.substring(7);
  }
  const slash: number = rest.indexOf('/');
  const host: string = slash >= 0 ? rest.substring(0, slash) : rest;
  return host.length > 0 ? host : origin;
}

/** 其他账号的一条（扫盘算占用） */
class OtherOwnerEntry {
  readonly owner: OfflineOwner;
  readonly bytes: number;
  readonly items: number;

  constructor(owner: OfflineOwner, bytes: number, items: number) {
    this.owner = owner;
    this.bytes = bytes;
    this.items = items;
  }
}

/** 手动删盘（其他账号整目录）不经过 OfflineStore，用这个信号让容量条知道要重查 */
@ObservedV2
class OfflineDiskSignals {
  @Trace revision: number = 0;
}

const offlineDiskSignals: OfflineDiskSignals = new OfflineDiskSignals();

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function OfflineStorageBuilder() {
  OfflineStoragePage()
}

/** 「下载中」行的左滑按钮：暂停 / 继续 / 取消。状态是活的（绑定时不重算会拿旧图标） */
@ComponentV2
struct DownloadingSwipeActions {
  @Param fileId: number = 0;
  @Local store: OfflineStore = OfflineStore.shared;

  private unit(): OfflineUnit | null {
    return this.store.units.get(this.fileId) ?? null;
  }

  build() {
    Row() {
      if (this.unit() !== null && !(this.unit() as OfflineUnit).waitingForTranscode) {
        if ((this.unit() as OfflineUnit).state === OfflineUnitState.paused
          || (this.unit() as OfflineUnit).state === OfflineUnitState.failed) {
          this.ActionIcon($r('sys.symbol.play_fill'), Theme.info, (): void => {
            OfflineDownloader.shared.resume(this.fileId);
          })
        } else {
          this.ActionIcon($r('sys.symbol.pause_fill'), Theme.textMuted, (): void => {
            OfflineDownloader.shared.pause(this.fileId);
          })
        }
      }
      this.ActionIcon($r('sys.symbol.xmark'), Theme.danger, (): void => {
        OfflineDownloader.shared.delete(this.fileId);
      })
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ActionIcon(icon: Resource, tint: string, action: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([tint])
    }
    .width(64)
    .height('100%')
    .backgroundColor(Theme.surfaceRaised)
    .onClick(action)
  }
}

/** 「下载中」行的长按菜单（与左滑同项、同顺序，同 iOS `contextMenu`） */
@ComponentV2
struct DownloadingMenuItems {
  @Param fileId: number = 0;
  @Local store: OfflineStore = OfflineStore.shared;

  private unit(): OfflineUnit | null {
    return this.store.units.get(this.fileId) ?? null;
  }

  build() {
    Menu() {
      if (this.unit() !== null && !(this.unit() as OfflineUnit).waitingForTranscode) {
        if ((this.unit() as OfflineUnit).state === OfflineUnitState.paused
          || (this.unit() as OfflineUnit).state === OfflineUnitState.failed) {
          MenuItem({ content: '继续下载', startIcon: $r('sys.symbol.play_fill') })
            .onClick(() => {
              OfflineDownloader.shared.resume(this.fileId);
            })
        } else {
          MenuItem({ content: '暂停', startIcon: $r('sys.symbol.pause_fill') })
            .onClick(() => {
              OfflineDownloader.shared.pause(this.fileId);
            })
        }
      }
      MenuItem({ content: '取消下载', startIcon: $r('sys.symbol.xmark') })
        .contentFontColor(Theme.danger)
        .onClick(() => {
          OfflineDownloader.shared.delete(this.fileId);
        })
    }
  }
}

/** 「下载中」的一行：海报 + 片名 + 哪一集 · 档位 + 状态与速度 + 进度（同 iOS `OfflineDownloadingStorageRow`） */
@ComponentV2
struct OfflineDownloadingRow {
  @Param fileId: number = 0;
  @Param navStack: NavPathStack | null = null;
  @Local store: OfflineStore = OfflineStore.shared;

  private unit(): OfflineUnit | null {
    return this.store.units.get(this.fileId) ?? null;
  }

  private summary(): OfflineItemSummary | null {
    const unit: OfflineUnit | null = this.unit();
    return unit !== null ? (this.store.items.get(unit.mediaItemId) ?? null) : null;
  }

  private subtitle(unit: OfflineUnit): string {
    const parts: string[] = [];
    if (!unit.isMovie) {
      parts.push(`第 ${unit.season} 季第 ${unit.episode} 集`);
    }
    parts.push(unit.profileLabel);
    return parts.join(' · ');
  }

  private tint(unit: OfflineUnit): string {
    return unit.needsAttention ? Theme.warning : Theme.info;
  }

  private speed(unit: OfflineUnit): number {
    if (unit.state !== OfflineUnitState.downloading) {
      return 0;
    }
    return this.store.speeds.get(unit.fileId) ?? 0;
  }

  private posterUrl(item: OfflineItemSummary): string {
    const resolved: string | null =
      ImageUrls.resolve(AppModel.origin(), item.posterUrl, ImageVariant.posterCard);
    return resolved !== null ? resolved : '';
  }

  build() {
    if (this.unit() !== null && this.summary() !== null) {
      Row({ space: 12 }) {
        RemoteImage({
          url: this.posterUrl(this.summary() as OfflineItemSummary),
          placeholderSymbol: $r('sys.symbol.film')
        })
          .width(60)
          .height(90)
          .borderRadius(8)
          .clip(true)
        Column({ space: 5 }) {
          Text((this.summary() as OfflineItemSummary).title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subtitle(this.unit() as OfflineUnit))
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 8 }) {
            Text(OfflineUnitText.line(this.unit() as OfflineUnit))
              .fontSize(12)
              .fontColor(this.tint(this.unit() as OfflineUnit))
              .maxLines(1)
              .layoutWeight(1)
            if (this.speed(this.unit() as OfflineUnit) > 0) {
              Text(`${OfflineDownloader.formatBytes(this.speed(this.unit() as OfflineUnit))}/s`)
                .fontSize(12)
                .fontColor(Theme.textMuted)
            }
          }
          .width('100%')
          Progress({
            value: Math.max(2, Math.round((this.unit() as OfflineUnit).progressFraction * 100)),
            total: 100,
            type: ProgressType.Linear
          })
            .width('100%')
            .height(4)
            .color(this.tint(this.unit() as OfflineUnit))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .onClick(() => {
        const unit: OfflineUnit = this.unit() as OfflineUnit;
        const item: OfflineItemSummary = this.summary() as OfflineItemSummary;
        if (this.navStack !== null) {
          this.navStack.pushPathByName('libraryItem', new ItemRouteParams(item.libraryId,
            item.mediaItemId, unit.isMovie ? null : unit.season, unit.isMovie ? null : unit.episode));
        }
      })
    }
  }
}

/** 「已下载」的一行：海报 + 片名 + 明细（已下载 N 集 / 档位 · 还有 M 个在下载）+ 占用（同 iOS `row(_:)`） */
@ComponentV2
struct OfflineDownloadedRow {
  @Param mediaItemId: number = 0;
  @Param navStack: NavPathStack | null = null;
  @Local store: OfflineStore = OfflineStore.shared;

  private summary(): OfflineItemSummary | null {
    return this.store.items.get(this.mediaItemId) ?? null;
  }

  private detailLine(item: OfflineItemSummary): string {
    const units: OfflineUnit[] = this.store.unitsOfItem(item.mediaItemId);
    const parts: string[] = [];
    if (item.kind === 'tv') {
      let done: number = 0;
      for (const unit of units) {
        if (unit.playable) {
          done += 1;
        }
      }
      parts.push(`已下载 ${done} 集`);
    } else {
      for (const unit of units) {
        if (unit.playable) {
          parts.push(unit.profileLabel);
          break;
        }
      }
    }
    let active: number = 0;
    for (const unit of units) {
      if (unit.isActive) {
        active += 1;
      }
    }
    if (active > 0) {
      parts.push(`还有 ${active} 个在下载`);
    }
    return parts.join(' · ');
  }

  private posterUrl(item: OfflineItemSummary): string {
    const resolved: string | null =
      ImageUrls.resolve(AppModel.origin(), item.posterUrl, ImageVariant.posterCard);
    return resolved !== null ? resolved : '';
  }

  build() {
    if (this.summary() !== null) {
      Row({ space: 12 }) {
        RemoteImage({
          url: this.posterUrl(this.summary() as OfflineItemSummary),
          placeholderSymbol: $r('sys.symbol.film')
        })
          .width(60)
          .height(90)
          .borderRadius(8)
          .clip(true)
        Column({ space: 5 }) {
          Text((this.summary() as OfflineItemSummary).title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.detailLine(this.summary() as OfflineItemSummary))
            .fontSize(12)
            .fontColor(Theme.textMuted)
          Text(OfflineDownloader.formatBytes(this.store.bytesOfItem(this.mediaItemId)))
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .onClick(() => {
        const item: OfflineItemSummary = this.summary() as OfflineItemSummary;
        if (this.navStack !== null) {
          this.navStack.pushPathByName('libraryItem',
            new ItemRouteParams(item.libraryId, item.mediaItemId));
        }
      })
    }
  }
}

/** 下载中分区（有才出现，每一集一行，下完就移到已下载；List 直接子组件） */
@ComponentV2
export struct OfflineDownloadingSection {
  @Param navStack: NavPathStack | null = null;
  @Local store: OfflineStore = OfflineStore.shared;

  /** 下载中的行（有摘要才显示，同 iOS） */
  private activeUnits(): OfflineUnit[] {
    const out: OfflineUnit[] = [];
    for (const unit of this.store.activeUnits()) {
      if (this.store.items.has(unit.mediaItemId)) {
        out.push(unit);
      }
    }
    return out;
  }

  build() {
    if (this.activeUnits().length > 0) {
      ListItemGroup({ header: this.SectionHeader() }) {
        ForEach(this.activeUnits(), (unit: OfflineUnit) => {
          ListItem() {
            OfflineDownloadingRow({ fileId: unit.fileId, navStack: this.navStack })
          }
          .swipeAction({
            end: this.DownloadingSwipeEnd(unit),
            edgeEffect: SwipeEdgeEffect.None
          })
          .bindContextMenu(this.DownloadingMenuEnd(unit), ResponseType.LongPress)
        }, (unit: OfflineUnit) => `unit-${unit.fileId}`)
      }
      .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 16, endMargin: 16 })
      .borderRadius(Theme.cardRadius)
      .backgroundColor(Theme.surface)
      .border({ width: 1, color: Theme.line })
    }
  }

  @Builder
  SectionHeader() {
    Text('下载中')
      .fontSize(13)
      .fontColor(Theme.textFaint)
      .width('100%')
      .padding({ left: 16, top: 12, bottom: 6 })
  }

  @Builder
  DownloadingSwipeEnd(unit: OfflineUnit) {
    DownloadingSwipeActions({ fileId: unit.fileId })
  }

  @Builder
  DownloadingMenuEnd(unit: OfflineUnit) {
    DownloadingMenuItems({ fileId: unit.fileId })
  }
}

/** 清理建议卡片（有已看完的才出现；List 直接子组件） */
@ComponentV2
export struct OfflineWatchedCard {
  @Local store: OfflineStore = OfflineStore.shared;

  /** 看完了的本机单元（本机进度标了已看） */
  private watchedUnits(): OfflineUnit[] {
    const out: OfflineUnit[] = [];
    const fileIds: number[] = Array.from(this.store.units.keys());
    for (const fileId of fileIds) {
      const unit: OfflineUnit | undefined = this.store.units.get(fileId);
      if (unit === undefined || !unit.playable) {
        continue;
      }
      const progress = this.store.localProgress(unit.mediaItemId, unit.season, unit.episode);
      if (progress !== null && progress.played) {
        out.push(unit);
      }
    }
    return out;
  }

  private watchedBytes(): number {
    let total: number = 0;
    for (const unit of this.watchedUnits()) {
      total += unit.receivedBytes;
    }
    return total;
  }

  private confirmDeleteWatched(): void {
    const count: number = this.watchedUnits().length;
    if (count === 0) {
      return;
    }
    const bytes: string = OfflineDownloader.formatBytes(this.watchedBytes());
    this.getUIContext().showAlertDialog({
      title: `删除 ${count} 个已看完的下载？`,
      message: '只删本机上的副本，观看进度会保留。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: `删除（释放 ${bytes}）`,
        fontColor: Theme.danger,
        action: (): void => {
          for (const unit of this.watchedUnits()) {
            OfflineDownloader.shared.delete(unit.fileId);
          }
        }
      }
    });
  }

  build() {
    if (this.watchedUnits().length > 0) {
      ListItem() {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(22)
            .fontColor([Theme.ok])
            .width(28)
          Column({ space: 2 }) {
            Text('删除已看完的')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
            Text(`${this.watchedUnits().length} 个已看完，占用 ${OfflineDownloader.formatBytes(this.watchedBytes())}`)
              .fontSize(12)
              .fontColor(Theme.textMuted)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text('删除')
            .fontSize(13)
            .fontColor(Theme.danger)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .border({ width: 1, color: Theme.danger, radius: 14 })
            .onClick(() => {
              this.confirmDeleteWatched();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      }
    }
  }
}

/** 已下载分区（点进条目、左滑 / 长按删除；List 直接子组件，无下载时显示引导文案） */
@ComponentV2
export struct OfflineDownloadedSection {
  @Param navStack: NavPathStack | null = null;
  @Local store: OfflineStore = OfflineStore.shared;

  private downloadedEmptyText(hasActive: boolean): string {
    return hasActive
      ? '下完的会出现在这里。'
      : '还没有下载。在影片详情页点「下载」，没网的时候也能看。';
  }

  private confirmDeleteItem(item: OfflineItemSummary): void {
    const bytes: string = OfflineDownloader.formatBytes(this.store.bytesOfItem(item.mediaItemId));
    this.getUIContext().showAlertDialog({
      title: `删除「${item.title}」的下载？`,
      message: '只删本机上的副本，观看进度会保留。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: `删除（释放 ${bytes}）`,
        fontColor: Theme.danger,
        action: (): void => {
          OfflineDownloader.shared.deleteItem(item.mediaItemId);
        }
      }
    });
  }

  build() {
    ListItemGroup({ header: this.DownloadedHeader() }) {
      if (this.store.downloadedItems().length === 0) {
        ListItem() {
          Text(this.downloadedEmptyText(this.store.activeUnits().length > 0))
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 16 })
        }
      }
      ForEach(this.store.downloadedItems(), (item: OfflineItemSummary) => {
        ListItem() {
          OfflineDownloadedRow({ mediaItemId: item.mediaItemId, navStack: this.navStack })
        }
        .swipeAction({
          end: this.DownloadedSwipeEnd(item),
          edgeEffect: SwipeEdgeEffect.None
        })
        .bindContextMenu(this.DownloadedMenuEnd(item), ResponseType.LongPress)
      }, (item: OfflineItemSummary) => `item-${item.mediaItemId}`)
    }
    .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 16, endMargin: 16 })
    .borderRadius(Theme.cardRadius)
    .backgroundColor(Theme.surface)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  DownloadedHeader() {
    Row({ space: 8 }) {
      Text('已下载')
        .fontSize(13)
        .fontColor(Theme.textFaint)
      if (this.store.downloadedItems().length > 0) {
        Text(`${this.store.downloadedItems().length} 部`)
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
    }
    .width('100%')
    .padding({ left: 16, top: 12, bottom: 6 })
  }

  @Builder
  DownloadedSwipeEnd(item: OfflineItemSummary) {
    Row() {
      this.SwipeIcon($r('sys.symbol.trash'), Theme.danger, (): void => {
        this.confirmDeleteItem(item);
      })
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  DownloadedMenuEnd(item: OfflineItemSummary) {
    Menu() {
      MenuItem({ content: '删除下载', startIcon: $r('sys.symbol.trash') })
        .contentFontColor(Theme.danger)
        .onClick(() => {
          this.confirmDeleteItem(item);
        })
    }
  }

  @Builder
  SwipeIcon(icon: Resource, tint: string, action: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([tint])
    }
    .width(64)
    .height('100%')
    .backgroundColor(Theme.surfaceRaised)
    .onClick(action)
  }
}

/** 其他账号分区（这台设备上其他账号的下载，重新登录那个账号就能看；List 直接子组件） */
@ComponentV2
export struct OfflineOtherOwnersSection {
  @Local store: OfflineStore = OfflineStore.shared;
  @Local otherOwners: OtherOwnerEntry[] = [];

  aboutToAppear(): void {
    this.loadOtherOwners();
  }

  private loadOtherOwners(): void {
    const current: string | null = this.store.key();
    const entries: OtherOwnerEntry[] = [];
    for (const owner of OfflineStore.scanOwners()) {
      const key: string = owner.key();
      if (key === current) {
        continue;
      }
      const bytes: number = OfflineDisk.sizeOf(OfflineDisk.ownerDir(key));
      if (bytes <= 0) {
        continue;
      }
      entries.push(new OtherOwnerEntry(owner, bytes,
        OfflineDisk.children(OfflineDisk.itemsDir(key)).length));
    }
    this.otherOwners = entries;
  }

  private confirmDeleteOwner(entry: OtherOwnerEntry): void {
    const bytes: string = OfflineDownloader.formatBytes(entry.bytes);
    this.getUIContext().showAlertDialog({
      title: `删除「${entry.owner.username}」在这台设备上的全部下载？`,
      message: '只删本机上的副本，观看进度会保留。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: `删除（释放 ${bytes}）`,
        fontColor: Theme.danger,
        action: (): void => {
          OfflineDisk.remove(OfflineDisk.ownerDir(entry.owner.key()));
          this.loadOtherOwners();
          offlineDiskSignals.revision += 1;
        }
      }
    });
  }

  build() {
    if (this.otherOwners.length > 0) {
      ListItemGroup({ header: this.SectionHeader(), footer: this.OtherOwnersFooter() }) {
        ForEach(this.otherOwners, (entry: OtherOwnerEntry) => {
          ListItem() {
            this.OwnerRow(entry)
          }
          .swipeAction({
            end: this.OwnerSwipeEnd(entry),
            edgeEffect: SwipeEdgeEffect.None
          })
        }, (entry: OtherOwnerEntry) => entry.owner.key())
      }
      .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 16, endMargin: 16 })
      .borderRadius(Theme.cardRadius)
      .backgroundColor(Theme.surface)
      .border({ width: 1, color: Theme.line })
    }
  }

  @Builder
  SectionHeader() {
    Text('其他账号')
      .fontSize(13)
      .fontColor(Theme.textFaint)
      .width('100%')
      .padding({ left: 16, top: 12, bottom: 6 })
  }

  @Builder
  OtherOwnersFooter() {
    Text('这台设备上其他账号的下载，重新登录那个账号就能看。')
      .fontSize(11)
      .fontColor(Theme.textFaint)
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 12 })
  }

  @Builder
  OwnerRow(entry: OtherOwnerEntry) {
    Row() {
      Column({ space: 2 }) {
        Text(entry.owner.username)
          .fontSize(15)
          .fontColor(Theme.text)
        Text(`${hostOf(entry.owner.origin)} · ${entry.items} 部`)
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(OfflineDownloader.formatBytes(entry.bytes))
        .fontSize(13)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  OwnerSwipeEnd(entry: OtherOwnerEntry) {
    Row() {
      this.SwipeIcon($r('sys.symbol.trash'), Theme.danger, (): void => {
        this.confirmDeleteOwner(entry);
      })
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SwipeIcon(icon: Resource, tint: string, action: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([tint])
    }
    .width(64)
    .height('100%')
    .backgroundColor(Theme.surfaceRaised)
    .onClick(action)
  }
}

/** 容量卡片（放最后：这一页先管下载，剩余空间是参考，同系统「储存空间」；List 直接子组件） */
@ComponentV2
export struct OfflineCapacityCard {
  @Local store: OfflineStore = OfflineStore.shared;
  @Local signals: OfflineDiskSignals = offlineDiskSignals;
  /** 容量条读数：打开页面、下完一集、删除时取一次（查磁盘不便宜，不跟下载进度跳） */
  @Local capacityFree: number = -1;
  @Local capacityTotal: number = -1;

  aboutToAppear(): void {
    this.refreshCapacity();
  }

  /** 下完 / 删掉时刷新容量条（对应 iOS `.task(id: store.doneBytes)`） */
  @Monitor('store.doneBytes')
  private onDoneBytesChanged(): void {
    this.refreshCapacity();
  }

  /** 手动删盘（其他账号）后重查 */
  @Monitor('signals.revision')
  private onDiskRevisionChanged(): void {
    this.refreshCapacity();
  }

  private refreshCapacity(): void {
    this.capacityFree = OfflineDisk.availableBytes();
    this.capacityTotal = OfflineDisk.totalBytes();
  }

  private downloadsBarWidth(): string {
    if (this.capacityTotal <= 0 || this.store.doneBytes <= 0) {
      return '0%';
    }
    const pct: number = this.store.doneBytes / this.capacityTotal * 100;
    // 最小可见段（同 iOS：不能把右侧可用空间挤出面板）
    return `${Math.min(100, Math.max(1, pct))}%`;
  }

  private otherBarWidth(): string {
    if (this.capacityTotal <= 0 || this.capacityFree < 0) {
      return '0%';
    }
    const other: number = Math.max(0, this.capacityTotal - this.capacityFree - this.store.doneBytes);
    return `${Math.min(100, other / this.capacityTotal * 100)}%`;
  }

  build() {
    ListItem() {
      Column({ space: 12 }) {
        Row() {
          Text('本机储存空间')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .layoutWeight(1)
          if (this.capacityFree >= 0) {
            Text(`可用 ${OfflineDownloader.formatBytes(this.capacityFree)}`)
              .fontSize(12)
              .fontColor(Theme.textMuted)
          }
        }
        .width('100%')
        if (this.capacityTotal > 0 && this.capacityFree >= 0) {
          Row({ space: 0 }) {
            Rect()
              .fill(Theme.info)
              .width(this.downloadsBarWidth())
              .height(6)
            Rect()
              .fill('rgba(255, 255, 255, 0.25)')
              .width(this.otherBarWidth())
              .height(6)
            Rect()
              .fill('rgba(255, 255, 255, 0.06)')
              .layoutWeight(1)
              .height(6)
          }
          .width('100%')
          .height(6)
          .borderRadius(3)
          .clip(true)
          Row() {
            this.LegendDot(Theme.info, `下载 ${OfflineDownloader.formatBytes(this.store.doneBytes)}`)
            Blank()
            this.LegendDot('rgba(255, 255, 255, 0.25)', '其他已用')
          }
          .width('100%')
        } else {
          Text(`MovieClaw 下载 ${OfflineDownloader.formatBytes(this.store.doneBytes)}`)
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
  }

  @Builder
  LegendDot(color: string, text: string) {
    Row({ space: 5 }) {
      Circle()
        .width(6)
        .height(6)
        .fill(color)
      Text(text)
        .fontSize(12)
        .fontColor(Theme.textMuted)
    }
  }
}

/** 下载管理页：五个分区拼一页（独立入口，「我的」页的下载段也复用同一批分区） */
@ComponentV2
export struct OfflineStoragePage {
  private navStack: NavPathStack = new NavPathStack();

  build() {
    NavDestination() {
      Column() {
        PageTopBar({ title: '下载', onBack: (): void => {
          this.navStack.pop();
        } })
        List({ space: 12 }) {
          OfflineDownloadingSection({ navStack: this.navStack })
          OfflineWatchedCard()
          OfflineDownloadedSection({ navStack: this.navStack })
          OfflineOtherOwnersSection()
          OfflineCapacityCard()
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .padding({ left: 16, right: 16, top: 0, bottom: 32 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
    })
  }
}
