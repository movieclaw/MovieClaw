import { JsonList, JsonMap, JsonValue, jsonArrayValue, jsonAt, jsonGet, jsonIntValue, jsonObjectValue, jsonStringValue }
  from '../api/JsonValue';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { LibraryKindMeta } from '../library/LibraryShared';
import { Formatters } from '../common/Formatters';
import { LibraryView, MediaKind, PlaybackItemView, SubscriptionDetailView } from '../api/Models';
import { AgentProcessItem } from './AgentTimeline';

/**
 * Agent 生成式 UI：行内媒体卡片（对应 iOS `Features/Agent/AgentMediaCards.swift`
 * 与 Web `lib/agent-media-cards.ts` + `components/agent-media-cards.tsx`）。
 *
 * 机制：模型调用 `show_media_cards_v1` 时只给编号，客户端按编号调产品既有接口现取数据绘制卡片——
 * 卡片与发现页、媒体库页同源，订阅/入库/观看进度永远是此刻的真实状态。
 * 流式与历史回放走同一条路径；加载与失败占同样尺寸的盒子（卡片组在时间线中间，抖动会把正文推来推去），
 * 编号查不到显示「未找到」而不是整组消失——用户要能看出模型引用了不存在的东西。
 */

/** 一张卡片的规格 */
export class AgentMediaCardSpec {
  /** 'library' | 'title' | 'libraryItem' | 'subscription' */
  readonly kind: string;
  readonly libraryId: number;
  readonly titleRef: string;
  readonly mediaItemId: number;
  readonly subscriptionId: number;
  readonly season: number;
  readonly episode: number;

  constructor(kind: string, libraryId: number = 0, titleRef: string = '', mediaItemId: number = 0,
    subscriptionId: number = 0, season: number = -1, episode: number = -1) {
    this.kind = kind;
    this.libraryId = libraryId;
    this.titleRef = titleRef;
    this.mediaItemId = mediaItemId;
    this.subscriptionId = subscriptionId;
    this.season = season;
    this.episode = episode;
  }

  key(): string {
    return `${this.kind}-${this.libraryId}-${this.titleRef}-${this.mediaItemId}-${this.subscriptionId}-${this.season}-${this.episode}`;
  }
}

/** 一次 show_media_cards 调用绘制的卡片组 */
export class AgentMediaCardGroup {
  readonly component: string;
  readonly title: string;
  readonly cards: AgentMediaCardSpec[];

  constructor(component: string, title: string, cards: AgentMediaCardSpec[]) {
    this.component = component;
    this.title = title;
    this.cards = cards;
  }
}

/** 卡片组在时间线里的位置（跟在所属处理过程块之后） */
export class AgentMediaCardEntry {
  readonly id: string;
  readonly group: AgentMediaCardGroup;

  constructor(id: string, group: AgentMediaCardGroup) {
    this.id = id;
    this.group = group;
  }
}

export class AgentMediaCards {
  /** 当前能绘制的版本；工具名带版本后缀，参数契约不兼容变更时后端发 _v2 */
  static readonly TOOL_V1: string = 'show_media_cards_v1';

  static isMediaCardsTool(name: string): boolean {
    return name === AgentMediaCards.TOOL_V1;
  }

  private static readonly titleRefPattern: RegExp = /^(tmdb:(movie|tv):\d+|douban:[^:/\s]+)$/;

  /** 工具参数 → 卡片组。参数由模型生成、任何字段都可能缺失或错型：单项不合法跳过，全部不合法返回 null */
  static parse(name: string, args: JsonMap | null): AgentMediaCardGroup | null {
    if (name !== AgentMediaCards.TOOL_V1 || args === null) {
      return null;
    }
    const component: string = jsonStringValue(jsonGet(args, 'component')) ?? '';
    if (component !== 'library' && component !== 'title' && component !== 'library_item'
      && component !== 'subscription') {
      return null;
    }
    const cards: AgentMediaCardSpec[] = [];
    const seen: string[] = [];
    const items: JsonList | null = jsonArrayValue(jsonGet(args, 'items'));
    if (items !== null) {
      for (let i = 0; i < items.length; i++) {
        const raw: JsonMap | null = jsonObjectValue(jsonAt(items, i));
        if (raw === null) {
          continue;
        }
        const spec: AgentMediaCardSpec | null = AgentMediaCards.parseItem(component, raw);
        if (spec === null) {
          continue;
        }
        const key: string = spec.key();
        if (seen.indexOf(key) >= 0) {
          continue; // 同一编号重复给出只画一次
        }
        seen.push(key);
        cards.push(spec);
      }
    }
    if (cards.length === 0) {
      return null;
    }
    const title: string = (jsonStringValue(jsonGet(args, 'title')) ?? '').trim();
    return new AgentMediaCardGroup(component, title, cards);
  }

  /** 副标题的拼装（`2025 · 电影`，两样都可能缺） */
  static formatMeta(year: number | null, kind: string | null): string {
    const parts: string[] = [];
    if (year !== null && year !== undefined) {
      parts.push(`${year}`);
    }
    if (kind !== null && kind !== undefined && kind.length > 0) {
      parts.push(LibraryKindMeta.label(kind));
    }
    return parts.join(' · ');
  }

  private static positiveInt(value: JsonValue | null): number {
    const n: number | null = jsonIntValue(value);
    return n !== null && n > 0 ? n : 0;
  }

  private static parseItem(component: string, item: JsonMap): AgentMediaCardSpec | null {
    if (component === 'library') {
      const id: number = AgentMediaCards.positiveInt(jsonGet(item, 'library_id'));
      return id > 0 ? new AgentMediaCardSpec('library', id) : null;
    }
    if (component === 'subscription') {
      const id: number = AgentMediaCards.positiveInt(jsonGet(item, 'subscription_id'));
      return id > 0 ? new AgentMediaCardSpec('subscription', 0, '', 0, id) : null;
    }
    if (component === 'title') {
      // 首选 title_ref；只有 TMDB 编号时按 tmdb_id + media_type 拼成同一形态
      let ref: string = (jsonStringValue(jsonGet(item, 'title_ref')) ?? '').trim();
      if (ref.length === 0) {
        const tmdb: number = AgentMediaCards.positiveInt(jsonGet(item, 'tmdb_id'));
        const mediaType: string = jsonStringValue(jsonGet(item, 'media_type')) ?? '';
        if (tmdb > 0 && (mediaType === 'movie' || mediaType === 'tv')) {
          ref = `tmdb:${mediaType}:${tmdb}`;
        }
      }
      return AgentMediaCards.titleRefPattern.test(ref) ? new AgentMediaCardSpec('title', 0, ref) : null;
    }
    const id: number = AgentMediaCards.positiveInt(jsonGet(item, 'media_item_id'));
    if (id <= 0) {
      return null;
    }
    const season: number | null = jsonIntValue(jsonGet(item, 'season_number'));
    const episode: number = AgentMediaCards.positiveInt(jsonGet(item, 'episode_number'));
    // 季集必须成对；只给一半按整部处理
    if (season !== null && season >= 0 && episode > 0) {
      return new AgentMediaCardSpec('libraryItem', 0, '', id, 0, season, episode);
    }
    return new AgentMediaCardSpec('libraryItem', 0, '', id);
  }

  /** 处理过程块里所有 show_media_cards 调用的卡片组（参数未生成完或调用已失败的不画） */
  static groupsIn(items: AgentProcessItem[]): AgentMediaCardEntry[] {
    const entries: AgentMediaCardEntry[] = [];
    for (const item of items) {
      if (item.tool === null || item.tool.streaming() || item.tool.failed()) {
        continue;
      }
      const group: AgentMediaCardGroup | null = AgentMediaCards.parse(item.tool.name, item.tool.args);
      if (group !== null) {
        entries.push(new AgentMediaCardEntry(item.tool.id, group));
      }
    }
    return entries;
  }
}

/** 卡片的数据（四种卡片共用一个视图，加载/失败也占同样尺寸） */
export class AgentCardData {
  title: string = '';
  subtitle: string = '';
  imageUrl: string = '';
  /** 宽高比（宽/高） */
  aspect: number = 2 / 3;
  /** 卡片宽度（vp） */
  width: number = 126;
  badge: string = '';
  /** 库内条目卡片要用：条目所属媒体库（服务端按可见性解析，点卡进条目页要用它） */
  routeLibraryId: number = 0;
}

/** 一张媒体卡片：按编号现取数据绘制（对应 iOS `AgentMediaCard` 的四个分支） */
@ComponentV2
export struct AgentMediaCardView {
  @Require @Param spec: AgentMediaCardSpec;

  /** 点卡片：交给页面路由（库内条目要带上服务端解析出的库 id） */
  @Event onOpen: (libraryId: number) => void = (libraryId: number): void => {
  };

  /** 'loading' | 'failed' | 'ready' */
  @Local private state: string = 'loading';
  @Local private data: AgentCardData = new AgentCardData();

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const api = AppModel.shared.api;
    if (api === null) {
      this.state = 'failed';
      return;
    }
    try {
      if (this.spec.kind === 'library') {
        const library: LibraryView = await api.libraryGet(this.spec.libraryId);
        const data: AgentCardData = new AgentCardData();
        data.title = library.name;
        const parts: string[] = [LibraryKindMeta.label(library.kind), `${library.stats.item_count} 部`];
        if (library.stats.total_size_bytes > 0) {
          parts.push(Formatters.bytes(library.stats.total_size_bytes));
        }
        data.subtitle = parts.join(' · ');
        data.aspect = 21 / 10;
        data.width = 212;
        data.imageUrl = library.stats.item_count === 0
          ? '' : `${AppModel.origin()}/api/v1/libraries/${library.id}/cover`;
        data.badge = library.is_default ? '默认' : '';
        this.data = data;
        this.state = 'ready';
        return;
      }
      if (this.spec.kind === 'title') {
        const detail = await api.discoverGetTitleDetails(this.spec.titleRef);
        const data: AgentCardData = new AgentCardData();
        data.title = detail.title.title;
        data.subtitle = AgentMediaCards.formatMeta(detail.title.release_year ?? null, detail.title.media_type ?? null);
        data.imageUrl = ImageUrls.resolve(AppModel.origin(), detail.title.poster_url, ImageVariant.posterCard) ?? '';
        this.data = data;
        this.state = 'ready';
        return;
      }
      if (this.spec.kind === 'subscription') {
        const detail: SubscriptionDetailView = await api.subscriptionsGet(this.spec.subscriptionId);
        const data: AgentCardData = new AgentCardData();
        data.title = detail.media.title;
        data.subtitle = AgentMediaCards.formatMeta(detail.media.year ?? null, detail.media.kind);
        data.imageUrl = ImageUrls.resolve(AppModel.origin(), detail.media.poster_url, ImageVariant.posterCard) ?? '';
        data.badge = detail.status;
        this.data = data;
        this.state = 'ready';
        return;
      }
      const info: PlaybackItemView = await api.playbackItemInfo(this.spec.mediaItemId);
      const data: AgentCardData = new AgentCardData();
      data.title = info.title;
      const code: string = this.spec.season >= 0 && this.spec.episode > 0
        ? `S${Formatters.pad2(this.spec.season)}E${Formatters.pad2(this.spec.episode)}` : '';
      const meta: string[] = [];
      if (info.year !== null && info.year !== undefined) {
        meta.push(`${info.year}`);
      }
      meta.push(LibraryKindMeta.label(info.kind));
      if (code.length > 0) {
        meta.push(code);
      }
      data.subtitle = meta.join(' · ');
      data.aspect = 16 / 9;
      data.width = 212;
      data.imageUrl = ImageUrls.resolve(AppModel.origin(), info.poster_url, ImageVariant.landscapeCard) ?? '';
      data.routeLibraryId = info.library_id;
      this.data = data;
      this.state = 'ready';
    } catch (error) {
      this.state = 'failed';
    }
  }

  private failedText(): string {
    if (this.spec.kind === 'library') {
      return `未找到媒体库 #${this.spec.libraryId}`;
    }
    if (this.spec.kind === 'subscription') {
      return `未找到订阅 #${this.spec.subscriptionId}`;
    }
    if (this.spec.kind === 'libraryItem') {
      return `未找到条目 #${this.spec.mediaItemId}`;
    }
    return '未找到';
  }

  build() {
    Column({ space: 6 }) {
      Stack() {
        if (this.state === 'ready') {
          RemoteImage({
            url: this.data.imageUrl,
            placeholderSymbol: LibraryKindMeta.symbol(this.kindHint())
          })
        }
        if (this.state === 'loading') {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(Theme.textFaint)
        }
        if (this.state === 'failed') {
          Text(this.failedText())
            .fontSize(13)
            .fontColor(Theme.textFaint)
            .padding({ left: 12, right: 12 })
            .textAlign(TextAlign.Center)
        }
        if (this.state === 'ready' && this.data.badge.length > 0) {
          Row() {
            Text(this.data.badge)
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor('rgba(255, 255, 255, 0.85)')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor('rgba(255, 255, 255, 0.12)')
              .borderRadius(12)
          }
          .width('100%')
          .padding(8)
          .justifyContent(FlexAlign.End)
          .alignItems(VerticalAlign.Top)
        }
      }
      .width('100%')
      .aspectRatio(this.aspectOf())
      .backgroundColor('rgba(255, 255, 255, 0.04)')
      .borderRadius(16)
      .border({ width: 1, color: 'rgba(255, 255, 255, 0.06)' })
      .clip(true)

      if (this.state === 'ready') {
        Text(this.data.title)
          .fontSize(13)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        if (this.data.subtitle.length > 0) {
          Text(this.data.subtitle)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
    }
    .width(this.widthOf())
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      if (this.state === 'ready') {
        this.onOpen(this.data.routeLibraryId);
      }
    })
  }

  private aspectOf(): number {
    if (this.state === 'ready') {
      return this.data.aspect;
    }
    if (this.spec.kind === 'library' || this.spec.kind === 'libraryItem') {
      return this.spec.kind === 'library' ? 21 / 10 : 16 / 9;
    }
    return 2 / 3;
  }

  private widthOf(): number {
    if (this.state === 'ready') {
      return this.data.width;
    }
    return this.spec.kind === 'library' || this.spec.kind === 'libraryItem' ? 212 : 126;
  }

  /** 占位图标要用哪种媒体的字形 */
  private kindHint(): string {
    return this.spec.kind === 'library' || this.spec.kind === 'title' ? 'movie' : 'tv';
  }
}

/** 一组卡片：可选小标题 + 横滚行 */
@ComponentV2
export struct AgentMediaCardsBlockView {
  @Require @Param group: AgentMediaCardGroup;

  @Event onOpen: (spec: AgentMediaCardSpec, libraryId: number) => void =
    (spec: AgentMediaCardSpec, libraryId: number): void => {
    };

  build() {
    Column({ space: 8 }) {
      if (this.group.title.length > 0) {
        Text(this.group.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMuted)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.group.cards, (spec: AgentMediaCardSpec) => {
            AgentMediaCardView({
              spec: spec,
              onOpen: (libraryId: number): void => {
                this.onOpen(spec, libraryId);
              }
            })
          }, (spec: AgentMediaCardSpec, index: number): string => `card-${index}-${spec.key()}`)
        }
        .alignItems(VerticalAlign.Top)
        .padding({ top: 4, bottom: 4 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.TopStart)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
