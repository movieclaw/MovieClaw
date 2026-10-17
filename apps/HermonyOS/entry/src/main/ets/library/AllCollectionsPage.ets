import { display } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { CollectionRouteParams } from './CollectionDetailPage';
import { AppModel } from '../common/AppModel';
import { MovieClawApi } from '../api/Endpoints';
import { CollectionCover, CollectionView, LibraryView } from '../api/Models';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { AppFooter } from '../common/AppFooter';

/**
 * 全部合集（逐条对齐 iOS 端 Features/Library/AllCollectionsView.swift，口径即 Web all-collections-view.tsx）。
 *
 * 按库分组列出当前身份可见的合集（跨库名单单独一组在最前）；顶部两组带计数的筛选：
 * 类型（按所属库的 kind）与来源（自建 / 自动=系列+内置收藏）。计数按 faceted 口径算
 * （带上另一个维度的筛选），数为 0 的档压暗且点不动——「永不空货架」。
 *
 * 同文件还提供合集卡片网格 LibraryCollectionsGrid（单库页「合集」视图复用）：
 * 我的合集与系列分两段；卡片是最多 3 张海报依次向右错开叠放的封面。
 */

/** 筛选档（类型 / 来源）：value 传给接口/比对，title 是展示名 */
export class CollectionChipOption {
  readonly value: string;
  readonly title: string;

  constructor(value: string, title: string) {
    this.value = value;
    this.title = title;
  }
}

/** 稳定排序的中间量：来源优先级 + 原始下标（用户自建 < 内置 < 系列） */
class RankedCollection {
  readonly rank: number;
  readonly offset: number;
  readonly item: CollectionView;

  constructor(rank: number, offset: number, item: CollectionView) {
    this.rank = rank;
    this.offset = offset;
    this.item = item;
  }
}

/** 按库分组的一行（跨库组不在此列，单独渲染） */
export class LibraryCollectionsGroup {
  readonly library: LibraryView;
  readonly items: CollectionView[];

  constructor(library: LibraryView, items: CollectionView[]) {
    this.library = library;
    this.items = items;
  }
}

/**
 * 合集墙「按库分组」的数据源（LazyForEach 用）。
 *
 * 原来外层 Scroll > Column 里 ForEach(groupedRows) 把每个库的合集块一次性全建出来；
 * 库多时跨库块 + N 个库块一起建树。改成 List + LazyForEach，每个库块是一个 ListItem，
 * 只建可视区附近的库块。块内的合集格仍走 LibraryCollectionsGrid（与单库页「合集」视图共用，
 * 数据量小、且那个用法把它包在外层 List 的一个 ListItem 里，故保持它整批建的内联网格，
 * 不改成自滚 Grid——否则会出现两个竖向滚动容器嵌套）。
 */
class CollectionGroupSource implements IDataSource {
  private groups: LibraryCollectionsGroup[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.groups.length;
  }

  getData(index: number): LibraryCollectionsGroup {
    return this.groups[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  setGroups(groups: LibraryCollectionsGroup[]): void {
    this.groups = groups;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/** 类型筛选：按所属库的 kind 归档 */
const KIND_OPTIONS: CollectionChipOption[] = [
  new CollectionChipOption('all', '全部'),
  new CollectionChipOption('tv', '剧集'),
  new CollectionChipOption('movie', '电影')
];

/** 来源筛选：user=自建，其余（系列 + 内置收藏）都算自动 */
const SOURCE_OPTIONS: CollectionChipOption[] = [
  new CollectionChipOption('all', '全部'),
  new CollectionChipOption('user', '自建'),
  new CollectionChipOption('auto', '自动')
];

/** 合集卡片默认值兜底（组件成员必须有初值，ArkTS 不支持可空成员缺省） */
const EMPTY_COLLECTION: CollectionView = {
  id: 0,
  name: '',
  library_id: null,
  rules: [],
  sort: '',
  visibility: 'household',
  builtin: null,
  editable: false,
  manageable: false,
  rule_driven: false,
  item_count: 0,
  cover_item_id: null,
  covers: [],
  kind: 'user',
  hidden: false,
  position: 0
};

/** 类型匹配：跨库合集（library_id 为空）在任何具体类型档下都不命中 */
function collectionMatchesKind(row: CollectionView, kind: string, kindOf: Map<number, string>): boolean {
  if (kind === 'all') {
    return true;
  }
  const libraryId: number | null | undefined = row.library_id;
  if (libraryId === null || libraryId === undefined) {
    return false;
  }
  return kindOf.get(libraryId) === kind;
}

/** 来源匹配：all 全部；user=自建；auto=非自建（系列 + 内置收藏） */
function collectionMatchesSource(row: CollectionView, source: string): boolean {
  if (source === 'all') {
    return true;
  }
  return source === 'user' ? row.kind === 'user' : row.kind !== 'user';
}

/** 来源优先级：用户自建 < 内置 < 系列 */
function collectionRank(row: CollectionView): number {
  if (row.kind === 'user') {
    return 0;
  }
  if (row.kind === 'builtin') {
    return 1;
  }
  return 2;
}

/** 组内排序：自建在前，同级保持服务端顺序（稳定排序） */
function sortBySource(list: CollectionView[]): CollectionView[] {
  const ranked: RankedCollection[] = [];
  for (let i: number = 0; i < list.length; i++) {
    ranked.push(new RankedCollection(collectionRank(list[i]), i, list[i]));
  }
  ranked.sort((a: RankedCollection, b: RankedCollection): number => {
    if (a.rank !== b.rank) {
      return a.rank - b.rank;
    }
    return a.offset - b.offset;
  });
  return ranked.map((entry: RankedCollection): CollectionView => entry.item);
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function AllCollectionsBuilder() {
  AllCollectionsPage()
}

/**
 * 全部合集页：摘要行 → 类型/来源筛选 → 跨库组 → 按库分组。
 * 数据是合集名单 + 库名单两笔请求；失败保留旧数据，下拉刷新重试。
 */
@Component
struct AllCollectionsPage {
  private navStack: NavPathStack = new NavPathStack();
  /** null = 还在读取 */
  @State private rows: CollectionView[] | null = null;
  @State private libraries: LibraryView[] = [];
  @State private kindFilter: string = 'all';
  @State private sourceFilter: string = 'all';
  @State private refreshing: boolean = false;
  /** 按库分组的数据源（LazyForEach 只建可视区附近的库块） */
  private groupSource: CollectionGroupSource = new CollectionGroupSource();

  private allRows(): CollectionView[] {
    return this.rows ?? [];
  }

  /** 库 id → kind 的对照表（类型筛选按所属库归档） */
  private kindOf(): Map<number, string> {
    const map: Map<number, string> = new Map<number, string>();
    for (const library of this.libraries) {
      map.set(library.id, library.kind);
    }
    return map;
  }

  /** 两个维度都命中的合集 */
  private shownRows(): CollectionView[] {
    const kindOf: Map<number, string> = this.kindOf();
    const picked: CollectionView[] = [];
    for (const row of this.allRows()) {
      if (collectionMatchesKind(row, this.kindFilter, kindOf)
        && collectionMatchesSource(row, this.sourceFilter)) {
        picked.push(row);
      }
    }
    return picked;
  }

  /** 跨库组：不属于任何一个库的手动名单 */
  private crossRows(): CollectionView[] {
    const picked: CollectionView[] = [];
    for (const row of this.shownRows()) {
      if (row.library_id === null || row.library_id === undefined) {
        picked.push(row);
      }
    }
    return sortBySource(picked);
  }

  /** 按库分组（只列有命中的库，顺序同库名单） */
  private groupedRows(): LibraryCollectionsGroup[] {
    const shown: CollectionView[] = this.shownRows();
    const groups: LibraryCollectionsGroup[] = [];
    for (const library of this.libraries) {
      const picked: CollectionView[] = [];
      for (const row of shown) {
        if (row.library_id === library.id) {
          picked.push(row);
        }
      }
      if (picked.length > 0) {
        groups.push(new LibraryCollectionsGroup(library, sortBySource(picked)));
      }
    }
    return groups;
  }

  /** 类型档计数：带上当前的来源筛选（faceted 口径） */
  private kindCounts(): number[] {
    const kindOf: Map<number, string> = this.kindOf();
    const counts: number[] = [];
    for (const option of KIND_OPTIONS) {
      let count: number = 0;
      for (const row of this.allRows()) {
        if (collectionMatchesSource(row, this.sourceFilter)
          && collectionMatchesKind(row, option.value, kindOf)) {
          count++;
        }
      }
      counts.push(count);
    }
    return counts;
  }

  /** 来源档计数：带上当前的类型筛选（faceted 口径） */
  private sourceCounts(): number[] {
    const kindOf: Map<number, string> = this.kindOf();
    const counts: number[] = [];
    for (const option of SOURCE_OPTIONS) {
      let count: number = 0;
      for (const row of this.allRows()) {
        if (collectionMatchesKind(row, this.kindFilter, kindOf)
          && collectionMatchesSource(row, option.value)) {
          count++;
        }
      }
      counts.push(count);
    }
    return counts;
  }

  private summaryText(): string {
    if (this.rows === null) {
      return '正在读取合集…';
    }
    const total: number = this.allRows().length;
    if (total === 0) {
      return '还没有合集';
    }
    if (this.kindFilter !== 'all' || this.sourceFilter !== 'all') {
      return `${this.shownRows().length} / ${total} 个合集 · 按库分组`;
    }
    return `${total} 个合集 · 按库分组`;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private comingSoon(feature: string): void {
    this.toast(`「${feature}」建设中，将在后续版本开放`);
  }

  /** 两笔请求：合集名单 + 库名单；失败保留旧数据（rows 为空时落成空表，结束读取态） */
  /** 打开合集详情（跨库组 libraryId 传 0，进条目页时用合集自己的库兜底） */
  private openCollection(collection: CollectionView): void {
    this.navStack.pushPathByName('collectionDetail',
      new CollectionRouteParams(collection.id, collection.library_id ?? 0));
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      this.rows = await api.collectionList();
    } catch (error) {
      if (this.rows === null) {
        this.rows = [];
      }
    }
    try {
      this.libraries = await api.libraryList(undefined, 'all');
    } catch (error) {
      // 库名单拿不到就先不分组，下拉刷新再试
    }
    this.syncGroups();
  }

  /** 把当前（经过类型/来源筛选的）按库分组喂给懒加载数据源；筛选档变化时也要调 */
  private syncGroups(): void {
    this.groupSource.setGroups(this.groupedRows());
  }

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        PageTopBar({ title: '全部合集', onBack: (): void => {
          this.navStack.pop();
        }})
        Refresh({ refreshing: $$this.refreshing }) {
          // Scroll > Column 全量建改成 List：按库分组的块是 LazyForEach 的 ListItem，
          // 只建可视区附近的库块；块内合集格仍走 LibraryCollectionsGrid（见该数据源注释）。
          List() {
            ListItem() {
              Text(this.summaryText())
                .fontSize(15)
                .fontColor(Theme.textMuted)
                .width('100%')
                .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
            }

            if (this.rows === null) {
              ListItem() {
                LoadingProgress()
                  .width(22)
                  .height(22)
                  .color(Theme.textMuted)
                  .margin({ top: 64 })
              }
            } else if (this.allRows().length === 0) {
              ListItem() {
                Text('还没有合集。在某个库里筛出一批片，点「存为合集」就能把这组条件留下来。')
                  .fontSize(15)
                  .fontColor(Theme.textMuted)
                  .textAlign(TextAlign.Center)
                  .padding({ left: 24, right: 24, top: 64 })
                  .width('100%')
              }
            } else {
              ListItem() {
                Column({ space: 10 }) {
                  CollectionChipBar({
                    label: '类型',
                    options: KIND_OPTIONS,
                    counts: this.kindCounts(),
                    selected: this.kindFilter,
                    onSelect: (value: string): void => {
                      this.kindFilter = value;
                      this.syncGroups();
                    }
                  })
                  CollectionChipBar({
                    label: '来源',
                    options: SOURCE_OPTIONS,
                    counts: this.sourceCounts(),
                    selected: this.sourceFilter,
                    onSelect: (value: string): void => {
                      this.sourceFilter = value;
                      this.syncGroups();
                    }
                  })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 14 })
              }

              if (this.crossRows().length > 0) {
                ListItem() {
                  Column({ space: 28 }) {
                    Column({ space: 4 }) {
                      Text('跨库')
                        .fontSize(15)
                        .fontWeight(600)
                        .fontColor(Theme.text)
                      Text('不属于任何一个库的手动名单')
                        .fontSize(13)
                        .fontColor(Theme.textFaint)
                    }
                    .width('100%')
                    .alignItems(HorizontalAlign.Start)
                    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })

                    Column() {
                      LibraryCollectionsGrid({
                        collections: this.crossRows(),
                        libraryId: null,
                        onOpen: (collection: CollectionView): void => {
                          this.openCollection(collection);
                        }
                      })
                    }
                    .width('100%')
                    .margin({ top: -14 })
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .padding({ top: 20 })
              }

              LazyForEach(this.groupSource, (group: LibraryCollectionsGroup) => {
                ListItem() {
                  Column() {
                    Text(group.library.name)
                      .fontSize(15)
                      .fontWeight(600)
                      .fontColor(Theme.text)
                      .width('100%')
                      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
                    Column() {
                      LibraryCollectionsGrid({
                        collections: group.items,
                        libraryId: group.library.id,
                        onOpen: (collection: CollectionView): void => {
                          this.openCollection(collection);
                        }
                      })
                    }
                    .width('100%')
                    .margin({ top: -16 })
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .margin({ top: 28 })
              }, (group: LibraryCollectionsGroup) => `lib-${group.library.id}`)

              ListItem() {
                AppFooter()
              }
            }
          }
          .scrollBar(BarState.Off)
          .width('100%')
          .height('100%')
          .edgeEffect(EdgeEffect.None)
          .cachedCount(4)
          .padding({ bottom: Theme.tabBarInset })
        }
        .onRefreshing(() => {
          this.load().then((): void => {
            this.refreshing = false;
          });
        })
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    // iOS `.navigationTitle("全部合集")`（push 后 inline）：用 NavDestination 原生标题栏，返回按钮系统自带
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      this.load();
    })
  }
}

/** 一组筛选 chip：横向滚动，档上带计数；计数为 0 且未选中时压暗不可点 */
@Component
struct CollectionChipBar {
  label: string = '';
  options: CollectionChipOption[] = [];
  counts: number[] = [];
  selected: string = '';
  onSelect: ((value: string) => void) | null = null;

  @Builder
  Chip(option: CollectionChipOption, count: number) {
    Row({ space: 6 }) {
      Text(option.title)
        .fontSize(12)
        .fontColor(this.selected === option.value ? '#ffffff' : 'rgba(255, 255, 255, 0.7)')
      Text(`${count}`)
        .fontSize(12)
        .fontColor('rgba(255, 255, 255, 0.4)')
    }
    .padding({ left: 10, right: 10 })
    .height(28)
    .backgroundColor(this.selected === option.value
      ? 'rgba(255, 255, 255, 0.16)'
      : 'rgba(255, 255, 255, 0.05)')
    .borderRadius(14)
    .opacity(count === 0 && this.selected !== option.value ? 0.3 : 1)
    .onClick(() => {
      if (count > 0 || this.selected === option.value) {
        const handler = this.onSelect;
        if (handler !== null) {
          handler(option.value);
        }
      }
    })
  }

  build() {
    Scroll() {
      Row({ space: 6 }) {
        Text(this.label)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .margin({ right: 2 })
        ForEach(this.options, (option: CollectionChipOption, index: number) => {
          this.Chip(option, this.counts[index] ?? 0)
        }, (option: CollectionChipOption) => option.value)
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }
}

/**
 * 合集卡片网格（Web LibraryCollectionsView）：我的合集与系列分两段；
 * 空时印引导文案。单库页「合集」视图与全部合集页共用。
 */
@Component
export struct LibraryCollectionsGrid {
  /**
   * **必须 `@Prop`**——非装饰成员只在构造时赋值，宿主 later 刷新出的合集传不进来
   * （实测：新建的合集在列表里有了，页面上却不出现）。本文件已是第 3 处同类问题。
   */
  @Prop collections: CollectionView[] = [];
  /** 所属库（跨库组传 null）；点开合集详情时带上 */
  libraryId: number | null = null;
  emptyHint: string = '还没有合集。筛出一批片之后，点「存为合集」就能把这组条件留下来。';
  onOpen: ((collection: CollectionView) => void) | null = null;
  /** 列数按屏宽算（最小列宽 140、列距 12，同 iOS LazyVGrid adaptive 口径） */
  private columns: number = 3;

  aboutToAppear(): void {
    try {
      const widthVp: number = px2vp(display.getDefaultDisplaySync().width);
      this.columns = Math.max(2, Math.floor((widthVp - Theme.pagePadding * 2 + 12) / 152));
    } catch (error) {
      this.columns = 3;
    }
  }

  private mineRows(): CollectionView[] {
    return this.collections.filter((row: CollectionView): boolean => row.kind !== 'series');
  }

  private seriesRows(): CollectionView[] {
    return this.collections.filter((row: CollectionView): boolean => row.kind === 'series');
  }

  /** 最后一行的空位序号（补位保持每格等宽、左对齐，同 LazyVGrid） */
  private emptySlots(count: number): number[] {
    const slots: number[] = [];
    for (let i: number = count; i < this.columns; i++) {
      slots.push(i);
    }
    return slots;
  }

  private chunked(items: CollectionView[], size: number): CollectionView[][] {
    const rows: CollectionView[][] = [];
    for (let i: number = 0; i < items.length; i += size) {
      rows.push(items.slice(i, i + size));
    }
    return rows;
  }

  build() {
    if (this.collections.length === 0) {
      Text(this.emptyHint)
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
        .padding({ top: 60, bottom: 60, left: Theme.pagePadding, right: Theme.pagePadding })
        .width('100%')
    } else {
      Column({ space: 28 }) {
        if (this.mineRows().length > 0) {
          this.GridSection(this.seriesRows().length > 0 ? '我的合集' : null, this.mineRows())
        }
        if (this.seriesRows().length > 0) {
          this.GridSection(this.mineRows().length > 0 ? '系列' : null, this.seriesRows())
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 一段：可选段名 + 自适应列数的卡片行（手工分行，行内 layoutWeight 等宽） */
  @Builder
  GridSection(title: string | null, items: CollectionView[]) {
    Column({ space: 12 }) {
      if (title !== null) {
        Text(title)
          .fontSize(15)
          .fontWeight(500)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      }
      Column({ space: 20 }) {
        ForEach(this.chunked(items, this.columns), (row: CollectionView[]) => {
          Row({ space: 12 }) {
            ForEach(row, (collection: CollectionView) => {
              Column() {
                CollectionCell({
                  collection: collection,
                  onOpen: this.onOpen
                })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }, (collection: CollectionView) => `${collection.id}`)
            ForEach(this.emptySlots(row.length), (slot: number) => {
              Column()
                .layoutWeight(1)
            }, (slot: number) => `${slot}`)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (row: CollectionView[]) => row.map((item: CollectionView): string => `${item.id}`).join('-'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 合集卡片：叠放封面 + 名称 + 「N 部 · 自动收录 · 只有我」标签行；已隐藏整体压暗 */
@Component
struct CollectionCell {
  collection: CollectionView = EMPTY_COLLECTION;
  onOpen: ((collection: CollectionView) => void) | null = null;

  private tags(): string {
    const parts: string[] = [`${this.collection.item_count} 部`];
    if (this.collection.kind === 'series') {
      parts.push('系列');
    } else if (this.collection.rule_driven) {
      parts.push('自动收录');
    }
    if (this.collection.visibility === 'private') {
      parts.push('只有我');
    }
    if (this.collection.hidden) {
      parts.push('已隐藏');
    }
    return parts.join(' · ');
  }

  build() {
    Column({ space: 2 }) {
      LibraryCollectionCover({ covers: this.collection.covers })
      Text(this.collection.name)
        .fontSize(15)
        .fontWeight(500)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ top: 8 })
        .width('100%')
      Text(this.tags())
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .opacity(this.collection.hidden ? 0.45 : 1)
    .onClick(() => {
      const handler = this.onOpen;
      if (handler !== null) {
        handler(this.collection);
      }
    })
  }
}

/**
 * 合集封面：最多 3 张海报依次向右错开叠放，后面的压暗。
 * 无封面时印「暂无封面」。叠放几何照搬 iOS：每层右移 7% 宽、下移 2.5% 高、
 * 层高递减 5%，最前一张占满剩余宽度。
 */
@Component
struct LibraryCollectionCover {
  covers: CollectionCover[] = [];

  /** 从后往前画（后面的层先入栈，最前一张最后画在最上面） */
  private stack(): CollectionCover[] {
    const shown: CollectionCover[] = this.covers.slice(0, 3);
    const reversed: CollectionCover[] = [];
    for (let i: number = shown.length - 1; i >= 0; i--) {
      reversed.push(shown[i]);
    }
    return reversed;
  }

  /** ForEach 下标（0 = 最后画的层）换算成叠放层号（0 = 最前） */
  private layerOf(index: number): number {
    return this.stack().length - 1 - index;
  }

  private coverWidthPercent(): string {
    return `${100 - 7 * (this.stack().length - 1)}%`;
  }

  private coverHeightPercent(index: number): string {
    return `${100 - 5 * this.layerOf(index)}%`;
  }

  private coverX(index: number): string {
    return `${7 * this.layerOf(index)}%`;
  }

  private coverY(index: number): string {
    return `${2.5 * this.layerOf(index)}%`;
  }

  private coverUrl(cover: CollectionCover): string {
    const origin: string = AppModel.shared.client !== null ? AppModel.shared.client.origin : '';
    return ImageUrls.resolve(origin, cover.url, ImageVariant.posterCard) ?? '';
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.stack().length === 0) {
        Text('暂无封面')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      } else {
        ForEach(this.stack(), (cover: CollectionCover, index: number) => {
          Stack() {
            RemoteImage({ url: this.coverUrl(cover) })
            if (this.layerOf(index) > 0) {
              Column()
                .width('100%')
                .height('100%')
                .backgroundColor('rgba(0, 0, 0, 0.35)')
            }
          }
          .width(this.coverWidthPercent())
          .height(this.coverHeightPercent(index))
          .position({ x: this.coverX(index), y: this.coverY(index) })
          .borderRadius(Theme.posterRadius)
          .clip(true)
        }, (cover: CollectionCover, index: number) => `${index}-${cover.url}`)
      }
    }
    .width('100%')
    .aspectRatio(Theme.posterAspect)
    .backgroundColor('rgba(255, 255, 255, 0.04)')
    .borderRadius(Theme.posterRadius)
    .clip(true)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.06)', radius: Theme.posterRadius })
  }
}
