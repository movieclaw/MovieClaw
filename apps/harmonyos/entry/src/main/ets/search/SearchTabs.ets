import { JsonMap, jsonArrayValue, jsonAt, jsonBoolValue, jsonGet, jsonObjectValue, jsonStringValue } from '../api/JsonValue';
import { MovieClawApi } from '../api/Endpoints';
import { SearchPresetListView } from '../api/Models';

/**
 * 资源搜索的标签与范围（对齐 iOS `SearchScope.swift` 的 `TorrentCategories` /
 * `SearchScope` / `SearchTab` / `SearchTabs`）。
 *
 * 资源分类（内置分类 + 管理员自定义预设）拆成两种用法（同 iOS）：
 * - **浏览**：搜索词为空时是「浏览最新资源」列表，点一行直接看该范围最新资源
 *   （后端 keyword 留空 = 浏览模式，拉各站种子列表页；浏览不写历史）；
 * - **换范围搜索**：输入了关键词后列表给出「在其他范围搜索」，点一行就换到那个范围搜。
 */

/** 分类选项的展示数据 */
class CategoryOption {
  readonly value: string;
  readonly label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

/** 种子一级分类（值与后端 TorrentCategory 逐一对应；对应 iOS `TorrentCategories`） */
export class TorrentCategories {
  /** 全量内置分类（8 类，同 iOS `TorrentCategories.all`；成人不是内置分类） */
  static readonly ALL: CategoryOption[] = [
    new CategoryOption('movie', '电影'),
    new CategoryOption('tv', '剧集'),
    new CategoryOption('documentary', '纪录片'),
    new CategoryOption('anime', '动漫'),
    new CategoryOption('music', '音乐'),
    new CategoryOption('game', '游戏'),
    new CategoryOption('av', '成人'),
    new CategoryOption('other', '其他')
  ];

  /** 分类值 → 展示名；不在表内的原样返回（同 iOS label） */
  static label(value: string): string {
    for (const option of TorrentCategories.ALL) {
      if (option.value === value) {
        return option.label;
      }
    }
    return value;
  }

  /** 分类值是否是已知的一级分类（解析路由/预设参数时过滤未知值） */
  static known(value: string): boolean {
    for (const option of TorrentCategories.ALL) {
      if (option.value === value) {
        return true;
      }
    }
    return false;
  }

  /** 分类图标（HM Symbol）；「全部分类」用 `allSymbol` */
  static symbol(value: string): Resource {
    switch (value) {
      case 'movie':
        return $r('sys.symbol.film');
      case 'tv':
        return $r('sys.symbol.display');
      case 'documentary':
        return $r('sys.symbol.camera');
      case 'anime':
        return $r('sys.symbol.wand_and_stars');
      case 'music':
        return $r('sys.symbol.music');
      case 'game':
        return $r('sys.symbol.gamecontroller');
      case 'av':
        return $r('sys.symbol.eye_slash');
      case 'other':
        return $r('sys.symbol.archivebox');
      default:
        return $r('sys.symbol.archivebox');
    }
  }

  /** 「全部分类」的图标（同 iOS allSymbol 的 square.grid.2x2） */
  static allSymbol(): Resource {
    return $r('sys.symbol.square_grid_2x2');
  }
}

/**
 * 一次搜索的范围：分类组合 × 站点组合（对应 iOS `SearchScope`）。
 * label 仅用于展示与历史（空 = 「全部」）。
 */
export class SearchScope {
  readonly label: string;
  readonly categories: string[];
  readonly siteIds: string[];
  /** 结果页图览模式的初始值（自定义预设可设定） */
  readonly posterMode: boolean;
  /** 无痕搜索：不写入搜索历史 */
  readonly skipHistory: boolean;

  constructor(label: string = '', categories: string[] = [], siteIds: string[] = [],
    posterMode: boolean = false, skipHistory: boolean = false) {
    this.label = label;
    this.categories = categories;
    this.siteIds = siteIds;
    this.posterMode = posterMode;
    this.skipHistory = skipHistory;
  }

  static all(): SearchScope {
    return new SearchScope();
  }

  /** 详情页「搜索资源」的范围（同 iOS ofMediaKind）：剧集只搜剧集分类、电影只搜电影分类 */
  static ofMediaKind(kind: string): SearchScope {
    if (kind === 'movie' || kind === 'tv') {
      return new SearchScope(TorrentCategories.label(kind), [kind]);
    }
    return SearchScope.all();
  }
}

/** 搜索标签：内置分类或自定义「分类 × 站点」预设（对应 iOS `SearchTab`） */
export class SearchTab {
  /** 选中态 key：类型加前缀，内置分类与预设 id 不会互撞 */
  readonly key: string;
  readonly isPreset: boolean;
  readonly id: string;
  /** 预设的展示名（内置分类为空，label() 走分类表） */
  readonly name: string;
  readonly visible: boolean;
  readonly categories: string[];
  readonly siteIds: string[];
  readonly posterMode: boolean;
  readonly skipHistory: boolean;

  private constructor(key: string, isPreset: boolean, id: string, name: string, visible: boolean,
    categories: string[], siteIds: string[], posterMode: boolean, skipHistory: boolean) {
    this.key = key;
    this.isPreset = isPreset;
    this.id = id;
    this.name = name;
    this.visible = visible;
    this.categories = categories;
    this.siteIds = siteIds;
    this.posterMode = posterMode;
    this.skipHistory = skipHistory;
  }

  static category(id: string, visible: boolean): SearchTab {
    return new SearchTab(`category:${id}`, false, id, '', visible, [], [], false, false);
  }

  static preset(id: string, name: string, visible: boolean, categories: string[],
    siteIds: string[], posterMode: boolean, skipHistory: boolean): SearchTab {
    return new SearchTab(`preset:${id}`, true, id, name, visible, categories, siteIds,
      posterMode, skipHistory);
  }

  label(): string {
    return this.isPreset ? this.name : TorrentCategories.label(this.id);
  }

  /** 列表行图标：内置分类各有一个，自定义预设统一用「叠放」表示组合范围 */
  symbol(): Resource {
    return this.isPreset ? $r('sys.symbol.square_stack_3d') : TorrentCategories.symbol(this.id);
  }

  /** 标签 → 搜索范围（内置分类 = 单分类 × 全部站点） */
  scope(): SearchScope {
    if (this.isPreset) {
      return new SearchScope(this.name, this.categories, this.siteIds, this.posterMode, this.skipHistory);
    }
    return new SearchScope(TorrentCategories.label(this.id), [this.id]);
  }

  /** 预设的范围摘要（同设置页预设行）：分类组合 · 站点组合（· 图览 · 无痕）；内置分类没有摘要 */
  summary(): string | null {
    if (!this.isPreset) {
      return null;
    }
    const cats: string = this.categories.length === 0
      ? '不限分类'
      : this.categories.map((value: string): string => TorrentCategories.label(value)).join('、');
    const sites: string = this.siteIds.length === 0 ? '全部站点' : `${this.siteIds.length} 个站点`;
    return `${cats} · ${sites}${this.posterMode ? ' · 图览' : ''}${this.skipHistory ? ' · 无痕' : ''}`;
  }

  /** 从服务端预设 JSON 解析一条标签；类型/缺失 id 的脏数据丢弃（同 iOS SearchTab.init?） */
  static parse(map: JsonMap): SearchTab | null {
    const type: string | null = jsonStringValue(jsonGet(map, 'type'));
    const id: string | null = jsonStringValue(jsonGet(map, 'id'));
    if (type === null || id === null || id.length === 0) {
      return null;
    }
    const visible: boolean = jsonBoolValue(jsonGet(map, 'visible')) ?? true;
    if (type === 'category') {
      return SearchTab.category(id, visible);
    }
    if (type === 'preset') {
      return SearchTab.preset(id,
        jsonStringValue(jsonGet(map, 'name')) ?? id,
        visible,
        SearchTab.parseStrings(map, 'categories'),
        SearchTab.parseStrings(map, 'site_ids'),
        jsonBoolValue(jsonGet(map, 'poster_mode')) ?? false,
        jsonBoolValue(jsonGet(map, 'skip_history')) ?? false);
    }
    return null;
  }

  private static parseStrings(map: JsonMap, key: string): string[] {
    const out: string[] = [];
    const raw = jsonArrayValue(jsonGet(map, key));
    if (raw === null) {
      return out;
    }
    for (let i = 0; i < raw.length; i++) {
      const s = jsonStringValue(jsonAt(raw, i));
      if (s !== null) {
        out.push(s);
      }
    }
    return out;
  }

  /** 默认标签（与后端 default_search_tabs 一致）：常用四类可见（同 iOS SearchTab.defaults） */
  static defaults(): SearchTab[] {
    return [
      SearchTab.category('movie', true),
      SearchTab.category('tv', true),
      SearchTab.category('documentary', true),
      SearchTab.category('anime', true),
      SearchTab.category('music', false),
      SearchTab.category('game', false),
      SearchTab.category('other', false)
    ];
  }
}

/** 搜索标签的加载（对应 iOS `SearchTabs`）：管理员从服务端读取（设置里可排序/显隐/自建预设），成员与拉取失败时用内置默认 */
export class SearchTabs {
  static async visible(api: MovieClawApi | null, isAdmin: boolean): Promise<SearchTab[]> {
    if (!isAdmin || api === null) {
      return SearchTabs.defaultsVisible();
    }
    try {
      const view: SearchPresetListView = await api.searchPresetsList();
      const parsed: SearchTab[] = [];
      for (const raw of view.presets) {
        const map: JsonMap | null = jsonObjectValue(raw);
        if (map !== null) {
          const tab: SearchTab | null = SearchTab.parse(map);
          if (tab !== null) {
            parsed.push(tab);
          }
        }
      }
      return SearchTabs.filterVisible(parsed.length > 0 ? parsed : SearchTab.defaults());
    } catch (error) {
      return SearchTabs.defaultsVisible();
    }
  }

  private static defaultsVisible(): SearchTab[] {
    return SearchTabs.filterVisible(SearchTab.defaults());
  }

  private static filterVisible(tabs: SearchTab[]): SearchTab[] {
    const out: SearchTab[] = [];
    for (const tab of tabs) {
      if (tab.visible) {
        out.push(tab);
      }
    }
    return out;
  }
}
