/**
 * TV 搜索页（US6，对齐参考端 Search/TVSearchView.swift）：
 * - 输入框拉起系统输入法（遥控器输入/听写共用），输入防抖 350ms 触发 `search/library`，确认键立即搜；
 * - 只搜媒体库：命中的人物是一排小一号的人物头像卡（「库内 N 部」，有 TMDB 影人 id 才可进影人页），
 *   条目是一排海报卡——与别处的海报行不同，片名、年份·类型、命中原因常显在卡下，不等获焦才浮出；
 * - 分页只追加（next_cursor + 「更多结果」尾按钮，按作品 ID 去重）；
 * - 进详情/影人页再返回不重复重搜（页签常驻，结果与输入都留在原地）；无结果/空关键词各给占位。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { MovieClawApi } from '../../api/Endpoints';
import { LibrarySearchHit, LibrarySearchPerson, LibrarySearchView } from '../../api/Models';
import { AppModel } from '../../common/AppModel';
import { ImageUrls } from '../../common/ImageUrls';
import { TvCardCaption, TvPillButton, TvStateView } from '../components/TvCards';
import { TvShelf, TvShelfCard } from '../components/TvShelf';
import { TvDetailRoute, TvPersonRoute, TvUiState } from '../model/TvUiState';
import { TvArt } from '../theme/TvTheme';
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';
import { TvType } from '../theme/TvTheme';

/** 输入停稳多久才搜（毫秒） */
const SEARCH_DEBOUNCE_MS: number = 350;

@ComponentV2
export struct TvSearchPage {
  @Local query: string = '';
  @Local searching: boolean = false;
  @Local moreLoading: boolean = false;
  @Local failed: string | null = null;
  /** 命中原因/人物头像卡的原始数据（卡片激活时按 key 回查） */
  @Local people: LibrarySearchPerson[] = [];
  @Local hits: LibrarySearchHit[] = [];
  /** 拍好的行卡片（fetch 完成时整批重赋值触发刷新） */
  @Local peopleCards: TvShelfCard[] = [];
  @Local itemCards: TvShelfCard[] = [];

  private debounceId: number = -1;
  /** 请求序号：防抖之外再核验，旧响应不能覆盖新输入 */
  private generation: number = 0;
  /** 上一轮搜索用的关键词（翻页与它同参）；空串 = 还没搜过 */
  private lastQuery: string = '';
  private nextCursor: string | null = null;
  private hasMore: boolean = false;

  aboutToDisappear(): void {
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
  }

  build() {
    Column() {
      this.SearchBar()
      this.Results()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
  }

  /** 搜索框：玻璃胶囊 + 放大镜；页签锚点（tv_tab_anchor）在它身上，进页即拉起输入法 */
  @Builder
  private SearchBar() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(22)
        .fontColor([TvColors.textMuted])
      TextInput({ placeholder: '片名、拼音首字母、演员或导演', text: this.query })
        .layoutWeight(1)
        .height('100%')
        .fontSize(TvType.body)
        .fontColor(TvColors.text)
        .placeholderColor(TvColors.textFaint)
        .placeholderFont({ size: TvType.body })
        .caretColor(TvColors.text)
        .backgroundColor(Color.Transparent)
        // 输入框自身默认还有一层圆角底与系统焦点框，套在玻璃胶囊里就是「双椭圆」
        .border({ width: 0 })
        .padding(0)
        .enterKeyType(EnterKeyType.Search)
        .defaultFocus(true)
        .key('tv_tab_anchor')
        .onChange((value: string): void => {
          this.onQueryChange(value);
        })
        .onSubmit((enterKey: EnterKeyType): void => {
          this.runSearch();
        })
    }
    .height(56)
    .padding({ left: 22, right: 22 })
    .backgroundColor(TvColors.glassFill)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, { colorMode: ThemeColorMode.DARK })
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.12)' })
    .borderRadius(999)
    // 与左上角「‹ 搜索」胶囊同一水平线、同一高度/材质；左边距让开胶囊
    .margin({ left: 200, right: TvMetrics.edge, top: 40 })
    .alignItems(VerticalAlign.Center)
  }

  /** 结果区：人物行 + 最相关的影片行 + 分页尾按钮 + 各占位态 */
  @Builder
  private Results() {
    Scroll() {
      Column({ space: TvMetrics.rowGap }) {
        if (this.searching) {
          Row({ space: 10 }) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(TvColors.textMuted)
            Text('正在搜索…')
              .fontSize(TvType.footnote)
              .fontColor(TvColors.textMuted)
          }
          .padding({ left: TvMetrics.edge, top: 8 })
        }

        if (this.peopleCards.length > 0) {
          TvShelf({
            title: '人物',
            cards: this.peopleCards,
            onActivate: (card: TvShelfCard): void => {
              this.activateCard(card);
            }
          })
        }

        if (this.itemCards.length > 0) {
          TvShelf({
            title: '最相关的影片',
            cards: this.itemCards,
            onActivate: (card: TvShelfCard): void => {
              this.activateCard(card);
            }
          })
          if (this.hasMore) {
            Row() {
              TvPillButton({
                label: this.moreLoading ? '正在加载…' : '更多结果',
                onActivate: (): void => {
                  this.loadMore();
                }
              })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 4 })
          }
        }

        this.FooterState()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 10, bottom: 40 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .fadingEdge(false)
    .align(Alignment.Top)
  }

  /** 结果区底部的占位态：失败可重试 / 没搜到 / 还没输入 */
  @Builder
  private FooterState() {
    if (this.failed !== null) {
      Stack() {
        TvStateView({
          symbol: $r('sys.symbol.wifi'),
          title: '搜索失败',
          message: this.failed,
          actionTitle: '重试',
          onAction: (): void => {
            this.runSearch();
          }
        })
      }
      .width('100%')
      .height(420)
    } else if (this.peopleCards.length === 0 && this.itemCards.length === 0 && !this.searching) {
      if (this.trimmed().length > 0) {
        Stack() {
          TvStateView({
            symbol: $r('sys.symbol.magnifyingglass'),
            title: '没有找到相关影片',
            message: '试试片名、别名、拼音首字母或演员、导演姓名。'
          })
        }
        .width('100%')
        .height(420)
      } else {
        Stack() {
          TvStateView({
            symbol: $r('sys.symbol.magnifyingglass'),
            title: '搜索你的媒体库',
            message: '输入片名、拼音首字母或演员、导演姓名。'
          })
        }
        .width('100%')
        .height(420)
      }
    }
  }

  // MARK: - 搜索逻辑

  private trimmed(): string {
    return this.query.trim();
  }

  private onQueryChange(value: string): void {
    this.query = value;
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
    }
    this.debounceId = setTimeout((): void => {
      this.debounceId = -1;
      this.runSearch();
    }, SEARCH_DEBOUNCE_MS);
  }

  /** 防抖到点或按下确认：清旧状态重新搜；空关键词直接清空结果 */
  private runSearch(): void {
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    const q: string = this.trimmed();
    this.generation += 1;
    const gen: number = this.generation;
    this.lastQuery = q;
    this.failed = null;
    this.moreLoading = false;
    if (q.length === 0 || api === null) {
      this.searching = false;
      this.people = [];
      this.hits = [];
      this.peopleCards = [];
      this.itemCards = [];
      this.nextCursor = null;
      this.hasMore = false;
      if (api === null && q.length > 0) {
        this.failed = '未连接服务器';
      }
      return;
    }
    this.searching = true;
    api.searchLibrary(q)
      .then((view: LibrarySearchView): void => {
        if (gen !== this.generation) {
          return;
        }
        this.searching = false;
        this.applyResults(view);
      })
      .catch((error: BusinessError): void => {
        if (gen !== this.generation) {
          return;
        }
        this.searching = false;
        const message: string | undefined = error.message;
        this.failed = message !== undefined && message.length > 0 ? message : '搜索失败';
      });
  }

  /** 翻页：同一关键词 + cursor，按作品 ID 去重后追加 */
  private loadMore(): void {
    if (this.moreLoading || this.searching || this.nextCursor === null || this.lastQuery.length === 0) {
      return;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const cursor: string = this.nextCursor;
    const gen: number = this.generation;
    this.moreLoading = true;
    api.searchLibrary(this.lastQuery, undefined, undefined, cursor)
      .then((view: LibrarySearchView): void => {
        this.moreLoading = false;
        if (gen !== this.generation) {
          return;
        }
        this.appendResults(view);
      })
      .catch((error: BusinessError): void => {
        this.moreLoading = false;
        if (gen !== this.generation) {
          return;
        }
        const message: string | undefined = error.message;
        this.failed = message !== undefined && message.length > 0 ? message : '加载失败';
      });
  }

  private applyResults(view: LibrarySearchView): void {
    this.people = view.people;
    this.hits = view.items;
    this.nextCursor = view.next_cursor ?? null;
    this.hasMore = this.nextCursor !== null;
    this.peopleCards = TvSearchPage.buildPeopleCards(view.people);
    this.itemCards = TvSearchPage.buildItemCards(view.items);
  }

  private appendResults(view: LibrarySearchView): void {
    const existing: Set<number> = new Set<number>();
    for (const hit of this.hits) {
      existing.add(hit.item.media_item_id);
    }
    const merged: LibrarySearchHit[] = this.hits.slice();
    for (const hit of view.items) {
      if (!existing.has(hit.item.media_item_id)) {
        merged.push(hit);
        existing.add(hit.item.media_item_id);
      }
    }
    this.hits = merged;
    this.nextCursor = view.next_cursor ?? null;
    this.hasMore = this.nextCursor !== null;
    this.itemCards = TvSearchPage.buildItemCards(merged);
    this.failed = null;
  }

  // MARK: - 卡片装配

  /** 人物行的头像卡：姓名 + 「库内 N 部」 */
  private static buildPeopleCards(people: LibrarySearchPerson[]): TvShelfCard[] {
    const origin: string = AppModel.origin();
    const cards: TvShelfCard[] = [];
    for (const person of people) {
      const card: TvShelfCard = new TvShelfCard(`person_${person.id}`, 'person', person.name);
      card.cardWidth = 133;
      card.role = `库内 ${person.item_count} 部`;
      card.imageUrl = TvSearchPage.sized(
        ImageUrls.resolve(origin, person.avatar_url ?? null, null), 133);
      cards.push(card);
    }
    return cards;
  }

  /** 条目行的海报卡：片名 / 年份·类型 / 命中原因常显，不等获焦才浮出 */
  private static buildItemCards(hits: LibrarySearchHit[]): TvShelfCard[] {
    const origin: string = AppModel.origin();
    const cards: TvShelfCard[] = [];
    for (const hit of hits) {
      const item = hit.item;
      const card: TvShelfCard = new TvShelfCard(`hit_${item.media_item_id}`, 'poster', item.title);
      card.cardWidth = TvMetrics.posterWidth;
      card.imageUrl = TvSearchPage.sized(
        ImageUrls.resolve(origin, item.poster_url ?? item.backdrop_url ?? null, null),
        TvMetrics.posterWidth);
      card.subtitle = TvSearchPage.itemSubtitle(item.year ?? null, item.kind);
      card.note = hit.match.label;
      card.caption = TvCardCaption.always;
      cards.push(card);
    }
    return cards;
  }

  /** 「2021 · 电影」；年份未知只写类型 */
  private static itemSubtitle(year: number | null, kind: string): string | null {
    const parts: string[] = [];
    if (year !== null) {
      parts.push(`${year}`);
    }
    const kindName: string | null = TvSearchPage.kindLabel(kind);
    if (kindName !== null) {
      parts.push(kindName);
    }
    return parts.length === 0 ? null : parts.join(' · ');
  }

  private static kindLabel(kind: string): string | null {
    if (kind === 'movie') {
      return '电影';
    }
    if (kind === 'tv') {
      return '剧集';
    }
    if (kind === 'video') {
      return '视频';
    }
    return null;
  }

  /** 解析好的 URL 再按显示宽度补 &w=（后端按 w 降采样出图） */
  private static sized(url: string | null, vpWidth: number): string {
    if (url === null) {
      return '';
    }
    return `${url}${url.includes('?') ? '&' : '?'}w=${TvArt.pxWidth(vpWidth)}`;
  }

  // MARK: - 激活路由

  /** 人物卡进影人页（旧服务端没有 TMDB 影人 id 的按确认不跳转）；条目卡进详情 */
  private activateCard(card: TvShelfCard): void {
    if (card.kind === 'person') {
      for (const person of this.people) {
        if (card.key === `person_${person.id}`) {
          const tmdbId: number | null = person.tmdb_person_id ?? null;
          if (tmdbId !== null && tmdbId > 0) {
            TvUiState.shared.pushRoute(new TvPersonRoute(tmdbId, person.name));
          }
          return;
        }
      }
      return;
    }
    for (const hit of this.hits) {
      if (card.key === `hit_${hit.item.media_item_id}`) {
        const libraryId: number = hit.item.library_id ??
          (hit.library_ids.length > 0 ? hit.library_ids[0] : 0);
        if (libraryId > 0) {
          TvUiState.shared.pushRoute(new TvDetailRoute(libraryId, hit.item.media_item_id));
        }
        return;
      }
    }
  }
}
