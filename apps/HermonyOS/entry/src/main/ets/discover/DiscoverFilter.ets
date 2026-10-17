import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { MovieClawApi } from '../api/Endpoints';
import { DiscoveryFilterOptionsView, DiscoveryGenreView, MediaKind } from '../api/Models';

/**
 * TMDB 组合筛选（对齐 iOS `DiscoverModels.swift` 的 `DiscoveryFilters` + `DiscoverFilter.swift`）：
 * 六个维度——类型（多选）× 国家/地区 × 年份 × 最低评分 × 最长片长 × 排序。
 *
 * 状态放**单例**（`DiscoveryFilters.shared()`）：NavHost 的筛选胶囊（角标）、
 * 发现页（常规版面 ⇄ 筛选网格的分支）、筛选弹层三处共用同一份 `@ObservedV2` 状态，
 * 弹层里点选立即生效，读 `@Trace` 字段的 V2 组件自动重绘。
 */

/** 国家/地区选项（同 iOS `DiscoveryFilters.countries`，ISO 3166-1） */
class DiscoverCountryOption {
  readonly code: string;
  readonly name: string;

  constructor(code: string, name: string) {
    this.code = code;
    this.name = name;
  }
}

const DISCOVER_COUNTRIES: DiscoverCountryOption[] = [
  new DiscoverCountryOption('CN', '中国大陆'),
  new DiscoverCountryOption('US', '美国'),
  new DiscoverCountryOption('JP', '日本'),
  new DiscoverCountryOption('KR', '韩国'),
  new DiscoverCountryOption('GB', '英国'),
  new DiscoverCountryOption('FR', '法国'),
  new DiscoverCountryOption('HK', '中国香港'),
  new DiscoverCountryOption('TW', '中国台湾'),
  new DiscoverCountryOption('IN', '印度')
];

/** 排序选项（同 iOS `DiscoveryFilters.sorts`） */
class DiscoverSortOption {
  readonly value: string;
  readonly label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const DISCOVER_SORTS: DiscoverSortOption[] = [
  new DiscoverSortOption('popular', '热门优先'),
  new DiscoverSortOption('rating', '评分优先'),
  new DiscoverSortOption('newest', '最新优先'),
  new DiscoverSortOption('most-rated', '最多评分')
];

/** 最低评分档（同 iOS） */
const DISCOVER_RATINGS: number[] = [6, 7, 8, 9];
/** 最长片长档（分钟，同 iOS） */
const DISCOVER_RUNTIMES: number[] = [60, 90, 120, 150];

/** 地区码 → 展示名；不在选项里的码原样显示（同 iOS countryLabel） */
export function discoverCountryLabel(code: string): string {
  for (const option of DISCOVER_COUNTRIES) {
    if (option.code === code) {
      return option.name;
    }
  }
  return code;
}

/** 排序值 → 展示名（同 iOS sortLabel） */
export function discoverSortLabel(value: string): string {
  for (const option of DISCOVER_SORTS) {
    if (option.value === value) {
      return option.label;
    }
  }
  return value;
}

/** 评分等数值的展示（6 → "6"，6.5 → "6.5"；同 iOS format） */
function formatScore(value: number): string {
  return value === Math.round(value) ? `${Math.round(value)}` : `${value}`;
}

/**
 * 六维筛选状态（@ObservedV2：`@Trace` 字段一变，所有读到它的 V2 组件自动重绘）。
 * 排序停在默认「热门优先」不算启用（与 activeCount 同口径，同 iOS）。
 */
@ObservedV2
export class DiscoveryFilters {
  /** TMDB 类型 ID（多选，电影与剧集是两套 ID） */
  @Trace genreIds: number[] = [];
  @Trace originCountry: string | null = null;
  @Trace year: number | null = null;
  @Trace ratingGte: number | null = null;
  @Trace runtimeLte: number | null = null;
  @Trace sort: string = 'popular';

  private static instance: DiscoveryFilters | null = null;

  /** 全局单例（静态方法 + 局部变量窄化，避免静态初始化器引用类名自身的 TDZ 问题） */
  static shared(): DiscoveryFilters {
    const existing: DiscoveryFilters | null = DiscoveryFilters.instance;
    if (existing !== null) {
      return existing;
    }
    const created: DiscoveryFilters = new DiscoveryFilters();
    DiscoveryFilters.instance = created;
    return created;
  }

  /** 已启用的维度数（筛选胶囊角标；排序默认值不计，同 iOS activeCount） */
  activeCount(): number {
    let count: number = 0;
    if (this.genreIds.length > 0) {
      count += 1;
    }
    if (this.originCountry !== null) {
      count += 1;
    }
    if (this.year !== null) {
      count += 1;
    }
    if (this.ratingGte !== null) {
      count += 1;
    }
    if (this.runtimeLte !== null) {
      count += 1;
    }
    if (this.sort !== 'popular') {
      count += 1;
    }
    return count;
  }

  /** 清空全部条件（切视角时也走这里，同 iOS `filters = .empty`） */
  clear(): void {
    this.genreIds = [];
    this.originCountry = null;
    this.year = null;
    this.ratingGte = null;
    this.runtimeLte = null;
    this.sort = 'popular';
  }

  /** 增删一个类型（多选） */
  toggleGenre(id: number): void {
    const next: number[] = this.genreIds.slice();
    const at: number = next.indexOf(id);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(id);
    }
    this.genreIds = next;
  }

  /** 当前条件的可读标签（结果网格头部的胶囊摘要；类型名由清单补齐，同 iOS labels） */
  labels(genreNames: Map<number, string>): string[] {
    const out: string[] = [];
    for (const id of this.genreIds) {
      const name: string | undefined = genreNames.get(id);
      if (name !== undefined) {
        out.push(name);
      }
    }
    if (this.genreIds.length > 0 && out.length === 0) {
      out.push(`${this.genreIds.length} 个类型`);
    }
    if (this.originCountry !== null) {
      out.push(discoverCountryLabel(this.originCountry));
    }
    if (this.year !== null) {
      out.push(`${this.year} 年`);
    }
    if (this.ratingGte !== null) {
      out.push(`${formatScore(this.ratingGte)} 分以上`);
    }
    if (this.runtimeLte !== null) {
      out.push(`${this.runtimeLte} 分钟以内`);
    }
    if (this.sort !== 'popular') {
      out.push(discoverSortLabel(this.sort));
    }
    return out;
  }
}

/**
 * 类型清单（电影与剧集是两套 TMDB 类型 ID）：按媒体类型缓存（同 iOS `DiscoverGenreCatalog`），
 * 筛选弹层与结果网格共用一份，不重复请求；并发的调用合并成一次。
 */
export class DiscoverGenreCatalog {
  private static cache: Map<string, DiscoveryGenreView[]> = new Map();
  private static inFlight: Map<string, Promise<DiscoveryGenreView[] | null>> = new Map();

  static cached(mediaType: string): DiscoveryGenreView[] {
    return DiscoverGenreCatalog.cache.get(mediaType) ?? [];
  }

  /** id → 类型名（胶囊摘要用） */
  static names(mediaType: string): Map<number, string> {
    const map: Map<number, string> = new Map<number, string>();
    for (const genre of DiscoverGenreCatalog.cached(mediaType)) {
      map.set(genre.id, genre.name);
    }
    return map;
  }

  /** 拉取失败返回 null（其他维度照常可用）；命中缓存或已在途时复用同一次请求 */
  static async load(api: MovieClawApi, mediaType: string): Promise<DiscoveryGenreView[] | null> {
    const hit: DiscoveryGenreView[] | undefined = DiscoverGenreCatalog.cache.get(mediaType);
    if (hit !== undefined) {
      return hit;
    }
    const pending: Promise<DiscoveryGenreView[] | null> | undefined
      = DiscoverGenreCatalog.inFlight.get(mediaType);
    if (pending !== undefined) {
      return pending;
    }
    const task: Promise<DiscoveryGenreView[] | null> = DiscoverGenreCatalog.fetch(api, mediaType);
    DiscoverGenreCatalog.inFlight.set(mediaType, task);
    const genres: DiscoveryGenreView[] | null = await task;
    DiscoverGenreCatalog.inFlight.delete(mediaType);
    return genres;
  }

  private static async fetch(api: MovieClawApi,
    mediaType: string): Promise<DiscoveryGenreView[] | null> {
    try {
      const options: DiscoveryFilterOptionsView = await api.discoverFilterOptions(mediaType as MediaKind);
      DiscoverGenreCatalog.cache.set(mediaType, options.genres);
      return options.genres;
    } catch (error) {
      return null;
    }
  }
}

/**
 * 筛选弹层（六节 chip，点选立即生效；对应 iOS 的 `DiscoverFilterOptions` 菜单组，
 * 鸿蒙上折成一张 LARGE 半屏弹层——iOS 的嵌套二级菜单在鸿蒙没有对应形态）。
 * 状态直接改共享单例：弹层后面发现页会实时切到筛选网格。
 */
@ComponentV2
export struct DiscoverFilterSheet {
  @Require @Param mediaType: string;
  @Require @Param filters: DiscoveryFilters;
  @Event onClose: () => void = (): void => {
  };

  /** null = 加载中；[] 之外还要区分失败（genresFailed） */
  @Local private genres: DiscoveryGenreView[] | null = null;
  @Local private genresFailed: boolean = false;

  aboutToAppear(): void {
    this.loadGenres();
  }

  /** 弹层存续期间切了类型（电影 ⇄ 剧集是两套类型 ID）：重拉清单 */
  @Monitor('mediaType')
  onMediaTypeChanged(): void {
    this.loadGenres();
  }

  private async loadGenres(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      this.genres = [];
      this.genresFailed = true;
      return;
    }
    const mediaType: string = this.mediaType;
    this.genres = DiscoverGenreCatalog.cached(mediaType).length > 0
      ? DiscoverGenreCatalog.cached(mediaType) : null;
    this.genresFailed = false;
    const result: DiscoveryGenreView[] | null = await DiscoverGenreCatalog.load(api, mediaType);
    if (mediaType !== this.mediaType) {
      return;
    }
    if (result === null) {
      this.genres = [];
      this.genresFailed = true;
    } else {
      this.genres = result;
      this.genresFailed = false;
    }
  }

  /** 当前年份（年份档从今年倒回 1874，同 iOS） */
  private currentYear(): number {
    const date: Date = new Date();
    return date.getFullYear();
  }

  /** 维度小节标题（电影/剧集措辞不同，同 iOS DiscoverFilterDimension.title） */
  private dimTitle(kind: string): string {
    if (kind === 'country') {
      return '国家 / 地区';
    }
    if (kind === 'year') {
      return this.mediaType === 'tv' ? '首播年份' : '上映年份';
    }
    if (kind === 'rating') {
      return '最低评分';
    }
    if (kind === 'runtime') {
      return this.mediaType === 'tv' ? '最长单集时长' : '最长片长';
    }
    if (kind === 'sort') {
      return '排序';
    }
    return '类型';
  }

  build() {
    Column() {
      // 头部：标题 + 关闭
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('TMDB DISCOVER')
            .fontSize(12)
            .fontWeight(600)
            .letterSpacing(2)
            .fontColor(Theme.accent2)
          Text(`组合筛选 · ${this.mediaType === 'tv' ? '剧集' : '电影'}`)
            .fontSize(17)
            .fontWeight(600)
            .fontColor(Theme.text)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(40)
          .height(40)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 6, bottom: 10 })

      Divider().color(Theme.line)

      Scroll() {
        Column({ space: 18 }) {
          this.GenreSection()
          this.CountrySection()
          this.YearSection()
          this.RatingSection()
          this.RuntimeSection()
          this.SortSection()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 小节标题行 */
  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(14)
      .fontWeight(600)
      .fontColor(Theme.text)
      .width('100%')
  }

  /** 类型（多选；清单按媒体类型拉取，失败时其他维度照常可用） */
  @Builder
  GenreSection() {
    Column({ space: 10 }) {
      this.SectionTitle(this.dimTitle('genres'))
      if (this.genresFailed) {
        Text('类型加载失败，其他条件仍可使用')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      } else if (this.genres === null) {
        Text('类型加载中…')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      } else if ((this.genres ?? []).length === 0) {
        Text('没有可选的类型')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.genres ?? [], (genre: DiscoveryGenreView) => {
            this.Chip(genre.name, this.filters.genreIds.indexOf(genre.id) >= 0, (): void => {
              this.filters.toggleGenre(genre.id);
            })
          }, (genre: DiscoveryGenreView) => `${genre.id}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 国家/地区（单选，不限 = null） */
  @Builder
  CountrySection() {
    Column({ space: 10 }) {
      this.SectionTitle(this.dimTitle('country'))
      Flex({ wrap: FlexWrap.Wrap }) {
        this.Chip('不限', this.filters.originCountry === null, (): void => {
          this.filters.originCountry = null;
        })
        ForEach(DISCOVER_COUNTRIES, (option: DiscoverCountryOption) => {
          this.Chip(option.name, this.filters.originCountry === option.code, (): void => {
            this.filters.originCountry = option.code;
          })
        }, (option: DiscoverCountryOption) => option.code)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 年份（单选；今年 → 1874，横滑，同 iOS） */
  @Builder
  YearSection() {
    Column({ space: 10 }) {
      this.SectionTitle(this.dimTitle('year'))
      Scroll() {
        Row({ space: 0 }) {
          this.Chip('不限', this.filters.year === null, (): void => {
            this.filters.year = null;
          })
          ForEach(this.yearOptions(), (year: number) => {
            this.Chip(`${year} 年`, this.filters.year === year, (): void => {
              this.filters.year = year;
            })
          }, (year: number) => `${year}`)
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 最低评分（单选：6/7/8/9 分以上） */
  @Builder
  RatingSection() {
    Column({ space: 10 }) {
      this.SectionTitle(this.dimTitle('rating'))
      Flex({ wrap: FlexWrap.Wrap }) {
        this.Chip('不限', this.filters.ratingGte === null, (): void => {
          this.filters.ratingGte = null;
        })
        ForEach(DISCOVER_RATINGS, (score: number) => {
          this.Chip(`${score} 分以上`, this.filters.ratingGte === score, (): void => {
            this.filters.ratingGte = score;
          })
        }, (score: number) => `${score}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 最长片长（单选：60/90/120/150 分钟以内） */
  @Builder
  RuntimeSection() {
    Column({ space: 10 }) {
      this.SectionTitle(this.dimTitle('runtime'))
      Flex({ wrap: FlexWrap.Wrap }) {
        this.Chip('不限', this.filters.runtimeLte === null, (): void => {
          this.filters.runtimeLte = null;
        })
        ForEach(DISCOVER_RUNTIMES, (minutes: number) => {
          this.Chip(`${minutes} 分钟以内`, this.filters.runtimeLte === minutes, (): void => {
            this.filters.runtimeLte = minutes;
          })
        }, (minutes: number) => `${minutes}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 排序（四选一，默认热门优先） */
  @Builder
  SortSection() {
    Column({ space: 10 }) {
      this.SectionTitle(this.dimTitle('sort'))
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(DISCOVER_SORTS, (option: DiscoverSortOption) => {
          this.Chip(option.label, this.filters.sort === option.value, (): void => {
            this.filters.sort = option.value;
          })
        }, (option: DiscoverSortOption) => option.value)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 年份档：今年倒回 1874（build 里不声明局部变量，抽方法） */
  private yearOptions(): number[] {
    const years: number[] = [];
    for (let year: number = this.currentYear(); year >= 1874; year--) {
      years.push(year);
    }
    return years;
  }

  /** 可点胶囊：选中高亮（主题强调底 + 深字） */
  @Builder
  Chip(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .fontWeight(active ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(active ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(active ? Theme.accent : Theme.glassFill)
      .borderRadius(15)
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        onTap();
      })
  }
}
