import { LengthMetrics } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { MovieClawApi } from '../api/Endpoints';
import { CollectionView, FacetValueView, LibraryFacetsView, LibraryRelaxView, RelaxSuggestionView } from '../api/Models';
import { JsonValue } from '../api/JsonValue';
import { LibraryFilter, facetLabel, facetPool, fetchWallFacets, fetchWallRelax } from './LibraryWall';

/** 空数组占位（ArkTS 的 ForEach 需要稳定的数组类型） */
const EMPTY_SUGGESTIONS: RelaxSuggestionView[] = [];

/**
 * 单库墙的筛选条（对应 iOS 端 Features/Library/LibraryFilterBar.swift，口径即网页
 * components/library-filter-bar.tsx）：
 * - 静止态：「筛选」按钮 + 合集 chip，靠左换行排布（换行暴露数量，横滚只会掩盖数量）；
 * - 点开：拉起底部面板，一二级维度平铺成胶囊，每个取值带「还剩几部」；每次勾选立即生效；
 * - 有条件：条件行出现在按钮下方，维内「或」维间「且」画出来。
 *
 * 条件本体（LibraryFilter 实例）由宿主页面持有：本组件只读它、把改动回调出去，
 * 宿主 clone→改→整体替换来触发整面墙重载。
 */
@Component
export struct LibraryFilterBar {
  libraryId: number = 0;
  @Prop @Watch('onFilterChanged') filter: LibraryFilter = new LibraryFilter();
  /** 本库的合集：以 chip 形式排在同一行（合集本来就是存好的筛选） */
  collections: CollectionView[] = [];
  onToggle: (dim: string, value: string) => void = () => {
  };
  onRemove: (dim: string, value: string) => void = () => {
  };
  onClear: () => void = () => {
  };
  /** 规则驱动的合集 chip 点一下把墙筛成它；再点一次退回全库 */
  onApplyRules: (rules: JsonValue[]) => void = () => {
  };
  /** 名单驱动的合集 chip：跳合集详情（宿主负责导航） */
  onOpenCollection: (collection: CollectionView) => void = () => {
  };
  onShowAllCollections: () => void = () => {
  };
  onSaveAsCollection: (() => void) | null = null;
  @State private open: boolean = false;
  @State private facets: LibraryFacetsView | null = null;
  /**
   * 计数拿没拿到。**必须和「加载中」分开**：拉取失败时 `facets` 也是 null，
   * 只看 null 会把失败当加载，面板永远停在「正在数各档位…」（实测踩到过）。
   */
  @State private facetsFailed: boolean = false;

  /** chip 行最多摆几个：再多就该去「合集」视图一次看全 */
  private static readonly chipLimit: number = 8;

  aboutToAppear(): void {
    this.loadFacets();
  }

  /** 条件、面板开合变化都重取计数（「还剩几部」本来就相对当前条件） */
  private onFilterChanged(): void {
    this.loadFacets();
  }

  private async loadFacets(): Promise<void> {
    if (!this.open && this.filter.isEmpty()) {
      // 静止态不为用户还没表达的意图付网络开销
      return;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.facetsFailed = false;
    try {
      this.facets = await fetchWallFacets(api, this.libraryId, this.filter, this.open || this.filter.hasSecondary());
    } catch (error) {
      // 计数拿不到就不显示数字（胶囊仍可点）：数字缺席比数字错了好。
      // 但要记下"拿不到"，否则 UI 会把它当成"还在加载"。
      this.facets = null;
      this.facetsFailed = true;
    }
  }

  /** chip 行只放自建的：自动生成的系列会把自己存的那三五个挤没 */
  private ownCollections(): CollectionView[] {
    return this.collections.filter((collection: CollectionView): boolean => collection.kind !== 'series');
  }

  /** 当前这面墙正好等于哪个合集——推导出来的，不存状态 */
  private activeCollection(): CollectionView | null {
    const current: string = this.filter.key();
    if (current.length === 0) {
      return null;
    }
    for (const collection of this.collections) {
      if (collection.rule_driven && LibraryFilter.fromRules(collection.rules).key() === current) {
        return collection;
      }
    }
    return null;
  }

  private isCollectionSelected(collection: CollectionView): boolean {
    const active: CollectionView | null = this.activeCollection();
    return active !== null && active.id === collection.id;
  }

  /** 底部面板一打开就要全份 facet；条件里已有二级维度时条件行也要二级展示名 */
  private needsAllFacets(): boolean {
    return this.open || this.filter.hasSecondary();
  }

  /** 全份 facet 到了没有：没到就先给一句话，别摆两个空标题等内容弹进来把面板撑高 */
  private secondaryReady(): boolean {
    const facets: LibraryFacetsView | null = this.facets;
    if (facets === null) {
      return false;
    }
    return facets.ratings.length > 0 || facets.runtimes.length > 0;
  }

  build() {
    Column({ space: 10 }) {
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        this.FilterButton()
        ForEach(this.ownCollections().slice(0, LibraryFilterBar.chipLimit), (collection: CollectionView) => {
          this.CollectionChip(collection)
        }, (collection: CollectionView) => `${collection.id}-${this.isCollectionSelected(collection) ? '1' : '0'}`)
        if (this.ownCollections().length > LibraryFilterBar.chipLimit) {
          Text('全部合集 ›')
            .fontSize(12)
            .fontColor('rgba(255, 255, 255, 0.5)')
            .height(28)
            .padding({ left: 4, right: 4 })
            .onClick(() => {
              this.onShowAllCollections();
            })
        }
      }
      .width('100%')

      if (!this.filter.isEmpty()) {
        FilterConditionRow({
          filter: this.filter,
          facets: this.facets,
          collectionName: this.activeCollection() === null ? null : (this.activeCollection() as CollectionView).name,
          onRemove: this.onRemove,
          onClear: this.onClear,
          onSaveAsCollection: this.onSaveAsCollection
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .bindSheet($$this.open, this.FilterSheet(), { height: SheetSize.LARGE })
  }

  /** 筛选按钮：唯一一个带玻璃底的按钮；激活时加角标 */
  @Builder
  FilterButton() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
        .fontSize(12)
        .fontColor([this.open || !this.filter.isEmpty() ? Theme.text : 'rgba(255, 255, 255, 0.9)'])
      Text('筛选')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.open || !this.filter.isEmpty() ? Theme.text : 'rgba(255, 255, 255, 0.9)')
      if (this.filter.count() > 0) {
        Text(`${this.filter.count()}`)
          .fontSize(13)
          .fontWeight(600)
          .fontColor('rgba(255, 255, 255, 0.85)')
      }
    }
    .padding({ left: 12, right: 12 })
    .height(32)
    .backgroundColor(this.open || !this.filter.isEmpty() ? 'rgba(255, 255, 255, 0.16)' : Theme.glassFill)
    .borderRadius(16)
    .border({ width: 1, color: this.open || !this.filter.isEmpty() ? Theme.lineStrong : Theme.line })
    .onClick(() => {
      this.open = true;
      this.loadFacets();
    })
  }

  /**
   * 规则驱动的合集 chip：点一下把当前墙筛成它，再点一次退回全库；
   * 名单驱动的没有规则、表达不成筛选条件，只能跳详情。
   */
  @Builder
  CollectionChip(collection: CollectionView) {
    Row({ space: 6 }) {
      Text(collection.name)
        .fontSize(12)
        .fontColor(this.isCollectionSelected(collection) ? Theme.text : 'rgba(255, 255, 255, 0.7)')
      Text(`${collection.item_count}`)
        .fontSize(12)
        .fontColor('rgba(255, 255, 255, 0.4)')
    }
    .padding({ left: 10, right: 10 })
    .height(28)
    .backgroundColor(this.isCollectionSelected(collection) ? 'rgba(255, 255, 255, 0.16)' : 'rgba(255, 255, 255, 0.05)')
    .borderRadius(14)
    .onClick(() => {
      if (collection.rule_driven) {
        if (this.isCollectionSelected(collection)) {
          this.onClear();
        } else {
          this.onApplyRules(collection.rules);
        }
      } else {
        this.onOpenCollection(collection);
      }
    })
  }

  /** 底部筛选面板：一级四维在上，「找片 / 查库」二级在下；每次勾选立即生效，底部按钮只是收起 */
  @Builder
  FilterSheet() {
    FilterSheetContent({
      filter: this.filter,
      facets: this.facets,
      loading: !this.secondaryReady() && !this.facetsFailed,
      facetsFailed: this.facetsFailed,
      onRetryFacets: (): void => {
        this.loadFacets();
      },
      onToggle: (dim: string, value: string): void => {
        this.onToggle(dim, value);
      },
      onClear: (): void => {
        this.onClear();
      },
      onClose: (): void => {
        this.open = false;
      }
    })
  }
}

/** 条件行的维度分组（维内多个值用「或」连在一个容器里，维度之间用「且」隔开） */
class DimGroup {
  readonly key: string;
  readonly label: string;
  readonly values: string[];

  constructor(key: string, label: string, values: string[]) {
    this.key = key;
    this.label = label;
    this.values = values;
  }
}

/** 已选条件行：「＝ 合集「X」」+ 各维度分组 + 清空 / 存为合集 + 筛出 N 部 */
@Component
struct FilterConditionRow {
  @Prop filter: LibraryFilter = new LibraryFilter();
  /**
   * 「筛出 N 部」用的是它的 `total`。**必须 `@Prop`**——非装饰成员只在构造时赋值，
   * 于是筛了之后这个数字还是全库总数（实测：HDR 生效时仍写「筛出 61 部」，
   * 而 HDR 档位自己显示的是 33）。和 `FilterSheetContent` 是同一个病。
   */
  @Prop facets: LibraryFacetsView | null = null;
  /** 当前条件正好等于这个合集时的合集名；改动任意一条即为 null */
  @Prop collectionName: string | null = null;
  onRemove: (dim: string, value: string) => void = () => {
  };
  onClear: () => void = () => {
  };
  onSaveAsCollection: (() => void) | null = null;

  private groups(): DimGroup[] {
    const groups: DimGroup[] = [];
    for (const dim of LibraryFilter.dimensions) {
      const values: string[] = this.filter.valuesOf(dim.key);
      if (values.length > 0) {
        groups.push(new DimGroup(dim.key, dim.label, values));
      }
    }
    return groups;
  }

  build() {
    Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
      if (this.collectionName !== null) {
        Row({ space: 4 }) {
          Text('＝ 合集')
            .fontSize(12)
            .fontColor('rgba(255, 255, 255, 0.7)')
          Text(`「${this.collectionName ?? ''}」`)
            .fontSize(12)
            .fontWeight(600)
            .fontColor(Theme.text)
        }
        .padding({ left: 8, right: 8 })
        .height(28)
        .backgroundColor('rgba(255, 255, 255, 0.1)')
        .borderRadius(8)
      }
      ForEach(this.groups(), (group: DimGroup, index: number) => {
        Row({ space: 8 }) {
          if (index > 0) {
            Text('且')
              .fontSize(12)
              .fontColor('rgba(255, 255, 255, 0.3)')
          }
          this.GroupChip(group)
        }
      }, (group: DimGroup) => `${group.key}-${group.values.join('_')}`)

      Text('清空')
        .fontSize(12)
        .fontColor('rgba(255, 255, 255, 0.5)')
        .padding({ left: 8, right: 8 })
        .height(28)
        .onClick(() => {
          this.onClear();
        })
      if (this.onSaveAsCollection !== null && this.collectionName === null) {
        Text('存为合集')
          .fontSize(12)
          .fontColor('rgba(255, 255, 255, 0.5)')
          .padding({ left: 8, right: 8 })
          .height(28)
          .onClick(() => {
            const handler = this.onSaveAsCollection;
            if (handler !== null) {
              handler();
            }
          })
      }
      if (this.facets !== null) {
        Row({ space: 0 }) {
          Text('筛出 ')
            .fontSize(12)
            .fontColor('rgba(255, 255, 255, 0.6)')
          Text(`${(this.facets as LibraryFacetsView).total}`)
            .fontSize(12)
            .fontWeight(600)
            .fontColor(Theme.text)
          Text(' 部')
            .fontSize(12)
            .fontColor('rgba(255, 255, 255, 0.6)')
        }
        .height(28)
      }
    }
    .width('100%')
  }

  /** 一个维度一组：维度名压暗 + 各取值（维内「或」）+ 逐项 ✕ */
  @Builder
  GroupChip(group: DimGroup) {
    Row({ space: 6 }) {
      Text(group.label)
        .fontSize(12)
        .fontColor('rgba(255, 255, 255, 0.4)')
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor('rgba(0, 0, 0, 0.25)')
        .borderRadius(4)
      ForEach(group.values, (value: string, index: number) => {
        Row({ space: 8 }) {
          if (index > 0) {
            Text('或')
              .fontSize(12)
              .fontColor('rgba(255, 255, 255, 0.3)')
          }
          Row({ space: 2 }) {
            Text(facetLabel(group.key, value, this.facets))
              .fontSize(12)
              .fontWeight(600)
              .fontColor(Theme.text)
            Text('✕')
              .fontSize(9)
              .fontWeight(FontWeight.Bold)
              .fontColor('rgba(255, 255, 255, 0.4)')
              .width(20)
              .height(22)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.onRemove(group.key, value);
              })
          }
        }
      }, (value: string) => `${group.key}-${value}`)
    }
    .padding({ left: 8, right: 2 })
    .height(28)
    .backgroundColor('rgba(255, 255, 255, 0.12)')
    .borderRadius(8)
  }
}

/** 筛选面板的一组固定档位胶囊 */
@Component
struct FilterPillGroup {
  label: string = '';
  hint: string | null = null;
  dim: string = '';
  /**
   * 这三个要 `@Prop`——非装饰成员只在构造时赋值，父组件 later 拿到的 facet 传不进来，
   * 档位上的数字就会一直是空的/旧的（同 `FilterSheetContent` / `FilterConditionRow` 的病）。
   */
  @Prop filter: LibraryFilter = new LibraryFilter();
  @Prop facets: LibraryFacetsView | null = null;
  /** 库存状态给语义色：要处理的事和不用处理的事，扫一眼就分得开 */
  dangerValues: string[] = [];
  warningValues: string[] = [];
  onToggle: (dim: string, value: string) => void = () => {
  };

  private options(): FacetValueView[] {
    return facetPool(this.dim, this.facets);
  }

  private selectedValues(): string[] {
    return this.filter.valuesOf(this.dim);
  }

  private toneOf(value: string): string {
    if (this.dangerValues.includes(value)) {
      return Theme.danger;
    }
    if (this.warningValues.includes(value)) {
      return Theme.warning;
    }
    return 'rgba(255, 255, 255, 0.65)';
  }

  build() {
    if (this.options().length > 0) {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text(this.label)
            .fontSize(12)
            .fontColor(Theme.textFaint)
          if (this.hint !== null) {
            Text(this.hint ?? '')
              .fontSize(12)
              .fontColor('rgba(255, 255, 255, 0.25)')
          }
        }
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
          ForEach(this.options(), (option: FacetValueView) => {
            Row({ space: 6 }) {
              Text(option.label)
                .fontSize(12)
                .fontWeight(this.selectedValues().includes(option.value) ? 600 : FontWeight.Normal)
                .fontColor(this.selectedValues().includes(option.value) ? Theme.text : this.toneOf(option.value))
              Text(`${option.count}`)
                .fontSize(10)
                .fontColor('rgba(255, 255, 255, 0.35)')
            }
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.selectedValues().includes(option.value) ? 'rgba(255, 255, 255, 0.14)' : Color.Transparent)
            .borderRadius(16)
            .border({ width: 1, color: this.selectedValues().includes(option.value) ? 'rgba(255, 255, 255, 0.4)' : 'rgba(255, 255, 255, 0.14)' })
            .enabled(!(option.count === 0 && !this.selectedValues().includes(option.value)))
            .opacity(option.count === 0 && !this.selectedValues().includes(option.value) ? 0.3 : 1)
            .onClick(() => {
              this.onToggle(this.dim, option.value);
            })
          }, (option: FacetValueView) => `${option.value}-${this.selectedValues().includes(option.value) ? '1' : '0'}-${option.count}`)
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/**
 * 点「筛选」拉起的底部面板（网页窄屏 FilterSheet）：一级四维在上，二级「找片 / 查库」在下。
 * 不透明深色底（同 Web 筛选面板）：透明底会让海报透上来，筛选项文字看不清。
 * 底部那颗「查看 N 部」不是提交（条件早已生效），只是收起来看结果。
 */
@Component
struct FilterSheetContent {
  @Prop filter: LibraryFilter = new LibraryFilter();
  /**
   * 这三个必须是 `@Prop`——**ArkUI 里非装饰成员只在构造时赋值一次，之后不更新**。
   * 写成普通成员时，facet 拉回来了子组件也看不到，面板会一直停在「正在数各档位…」（实测踩到）。
   */
  @Prop facets: LibraryFacetsView | null = null;
  /** 全份 facet 还没到（二级维度的档位要等它） */
  @Prop loading: boolean = true;
  /** 计数拉取失败（和「加载中」分开，否则失败会一直显示加载文案） */
  @Prop facetsFailed: boolean = false;
  onRetryFacets: () => void = () => {
  };
  onToggle: (dim: string, value: string) => void = () => {
  };
  onClear: () => void = () => {
  };
  onClose: () => void = () => {
  };

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          FilterPillGroup({ label: '类型', hint: '可多选 · 维度内是「或」', dim: 'genres', filter: this.filter, facets: this.facets, onToggle: this.onToggle })
          FilterPillGroup({ label: '年代', dim: 'decades', filter: this.filter, facets: this.facets, onToggle: this.onToggle })
          FilterPillGroup({ label: '地区', hint: '可多选 · 维度内是「或」', dim: 'countries', filter: this.filter, facets: this.facets, onToggle: this.onToggle })
          FilterPillGroup({ label: '观看', hint: '单选', dim: 'watch', filter: this.filter, facets: this.facets, onToggle: this.onToggle })
          if (this.loading) {
            Divider().color(Theme.line)
            Text('正在数各档位还剩多少部…')
              .fontSize(15)
              .fontColor(Theme.textFaint)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 16, bottom: 16 })
          } else if (this.facetsFailed) {
            Divider().color(Theme.line)
            Row({ space: 8 }) {
              Text('各档位的数量暂时拿不到，筛选项仍可正常勾选。')
                .fontSize(14)
                .fontColor(Theme.textFaint)
                .layoutWeight(1)
              Text('重试')
                .fontSize(14)
                .fontColor(Theme.accentStrong)
                .onClick(() => {
                  this.onRetryFacets();
                })
            }
            .width('100%')
            .padding({ top: 16, bottom: 16 })
          } else {
            Divider().color(Theme.line)
            this.SectionTitle('找片', '作品是什么样的 · 来自刮削档案')
            FilterPillGroup({ label: '评分', dim: 'rating_gte', filter: this.filter, facets: this.facets, onToggle: this.onToggle })
            FilterPillGroup({ label: '片长', dim: 'runtimes', filter: this.filter, facets: this.facets, onToggle: this.onToggle })
            FilterPillGroup({ label: '原始语言', dim: 'languages', filter: this.filter, facets: this.facets, onToggle: this.onToggle })
            Divider().color(Theme.line)
            this.SectionTitle('查库', '文件是什么规格 · 来自库存台账')
            FilterPillGroup({ label: '分辨率', dim: 'resolutions', filter: this.filter, facets: this.facets, onToggle: this.onToggle })
            FilterPillGroup({ label: '动态范围', dim: 'hdr', filter: this.filter, facets: this.facets, onToggle: this.onToggle })
            FilterPillGroup({ label: '库存状态', hint: '要处理的事', dim: 'stock', filter: this.filter, facets: this.facets, dangerValues: ['missing'], warningValues: ['unscraped'], onToggle: this.onToggle })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 20, bottom: 12 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')

      Row({ space: 8 }) {
        Text('清空')
          .fontSize(16)
          .fontColor(Theme.textMuted)
          .height(48)
          .padding({ left: 20, right: 20 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(24)
          .border({ width: 1, color: Theme.line })
          .onClick(() => {
            this.onClear();
          })
        Text(this.facets === null ? '查看结果' : `查看 ${(this.facets as LibraryFacetsView).total} 部`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#000000')
          .layoutWeight(1)
          .height(48)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.accentStrong)
          .borderRadius(24)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#171a23')
  }

  @Builder
  SectionTitle(title: string, detail: string) {
    Row({ space: 8 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(detail)
        .fontSize(12)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
  }
}

/**
 * 筛空之后的出路（铁律：永不空货架）。不渲染空墙——直接告诉用户放宽哪一条能救回多少部，
 * 一点就生效。服务端只返回救得回内容的条件，拿到空表就只留「清空全部条件」。
 */
@Component
export struct LibraryFilterEmptyState {
  libraryId: number = 0;
  @Prop @Watch('onFilterChanged') filter: LibraryFilter = new LibraryFilter();
  onRemove: (dim: string, value: string) => void = () => {
  };
  onClear: () => void = () => {
  };
  @State private relax: LibraryRelaxView | null = null;

  aboutToAppear(): void {
    this.loadRelax();
  }

  private onFilterChanged(): void {
    this.loadRelax();
  }

  private async loadRelax(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      this.relax = await fetchWallRelax(api, this.libraryId, this.filter);
    } catch (error) {
      this.relax = null;
    }
  }

  build() {
    Column({ space: 0 }) {
      Text(`没有同时满足这 ${this.filter.count()} 个条件的作品`)
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text((this.relax === null || this.relax.suggestions.length === 0)
        ? '这几个条件两两之间就没有交集，去掉任意一条也救不回来。'
        : '放宽一条就能找回内容。')
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .padding({ top: 4 })
      Column({ space: 6 }) {
        ForEach(this.relax === null ? EMPTY_SUGGESTIONS : this.relax.suggestions, (row: RelaxSuggestionView) => {
          Row({ space: 12 }) {
            Row({ space: 0 }) {
              Text('去掉「')
                .fontSize(15)
                .fontColor('rgba(255, 255, 255, 0.8)')
              Text(`${row.dim_label} = ${row.label}`)
                .fontSize(15)
                .fontWeight(600)
                .fontColor(Theme.text)
              Text('」')
                .fontSize(15)
                .fontColor('rgba(255, 255, 255, 0.8)')
            }
            .layoutWeight(1)
            Text(`→ ${row.count} 部`)
              .fontSize(12)
              .fontColor(Theme.info)
          }
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(12)
          .border({ width: 1, color: Theme.line })
          .width('100%')
          .onClick(() => {
            this.onRemove(row.dim, row.value);
          })
        }, (row: RelaxSuggestionView) => `${row.dim}-${row.value}`)
      }
      .padding({ top: 16 })
      Text('清空全部条件')
        .fontSize(12)
        .fontColor('rgba(255, 255, 255, 0.5)')
        .padding({ top: 14, bottom: 8 })
        .onClick(() => {
          this.onClear();
        })
    }
    .padding(16)
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.14)', radius: 16, style: BorderStyle.Dashed })
  }
}
