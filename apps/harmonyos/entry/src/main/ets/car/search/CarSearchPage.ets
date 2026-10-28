/**
 * 车机搜索页（T020，US7）：语音优先、只搜媒体库。
 *
 * - 大输入框拉起系统输入法（语音经输入法可达——模拟器/车机上语音按系统输入法可达性走），
 *   输入防抖 350ms（CarMotion.searchDebounceMs）触发 `search/library`，确认键立即搜；
 * - 结果为条目与影人的大卡列表（CarShelf 行）：人物头像卡（「库内 N 部」，有 TMDB 影人 id
 *   才可进影人作品墙）、条目海报卡（片名 / 年份·类型 / 命中原因常显在卡下）；
 * - 分页只追加（next_cursor + 「更多结果」尾按钮，按作品 ID 去重）；
 * - 无结果 / 还没输入 / 失败可重试各给占位（CarStateView）；
 * - 进详情/影人墙再返回不重复重搜（页签常驻，结果与输入都留在原地）。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { MovieClawApi } from '../../api/Endpoints';
import {
  LibrarySearchHit,
  LibrarySearchPerson,
  LibrarySearchView
} from '../../api/Models';
import { AppModel } from '../../common/AppModel';
import { ImageUrls } from '../../common/ImageUrls';
import { CarDetailRoute, CarPersonRoute, CarUiState } from '../model/CarUiState';
import { CarPillButton, CarStateView } from '../components/CarCards';
import { CarRowCard, CarShelf } from '../components/CarRows';
import { CarArt } from '../theme/CarTheme';
import { CarColors } from '../theme/CarTheme';
import { CarMetrics } from '../theme/CarTheme';
import { CarMotion } from '../theme/CarTheme';
import { CarType } from '../theme/CarTheme';

@ComponentV2
export struct CarSearchPage {
  @Local query: string = '';
  @Local searching: boolean = false;
  @Local moreLoading: boolean = false;
  @Local failed: string | null = null;
  /** 命中原因/人物头像卡的原始数据（卡片激活时按 key 回查） */
  @Local people: LibrarySearchPerson[] = [];
  @Local hits: LibrarySearchHit[] = [];
  /** 拍好的行卡片（fetch 完成时整批重赋值触发刷新） */
  @Local peopleCards: CarRowCard[] = [];
  @Local itemCards: CarRowCard[] = [];

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
      this.searchBar()
      this.results()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CarColors.bg)
  }

  /** 大输入框：玻璃胶囊 + 放大镜；进页即拉起系统输入法（语音随之可达） */
  @Builder
  private searchBar(): void {
    Row({ space: 14 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(26)
        .fontColor([CarColors.textMuted])
      TextInput({ placeholder: '片名、拼音首字母、演员或导演', text: this.query })
        .layoutWeight(1)
        .height('100%')
        .fontSize(CarType.rowTitle)
        .fontColor(CarColors.text)
        .placeholderColor(CarColors.textFaint)
        .placeholderFont({ size: CarType.body })
        .caretColor(CarColors.text)
        .backgroundColor(Color.Transparent)
        // 输入框自身默认还有一层圆角底与系统焦点框，套在胶囊里就是「双椭圆」
        .border({ width: 0 })
        .padding(0)
        .enterKeyType(EnterKeyType.Search)
        .defaultFocus(true)
        .onChange((value: string): void => {
          this.onQueryChange(value);
        })
        .onSubmit((enterKey: EnterKeyType): void => {
          this.runSearch();
        })
    }
    .height(64)
    .padding({ left: 26, right: 26 })
    .margin({ left: CarMetrics.edge, right: CarMetrics.edge, top: 28 })
    .backgroundColor(CarColors.glassFill)
    .border({ width: 1, color: CarColors.lineStrong })
    .borderRadius(999)
    .alignItems(VerticalAlign.Center)
  }

  /** 结果区：人物行 + 最相关的影片行 + 分页尾按钮 + 各占位态 */
  @Builder
  private results(): void {
    Scroll() {
      Column({ space: CarMetrics.rowGap }) {
        if (this.searching) {
          Row({ space: 10 }) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(CarColors.textMuted)
            Text('正在搜索…')
              .fontSize(CarType.footnote)
              .fontColor(CarColors.textMuted)
          }
          .padding({ left: CarMetrics.edge, top: 8 })
        }

        if (this.peopleCards.length > 0) {
          CarShelf({
            title: '人物',
            cards: this.peopleCards,
            onActivate: (card: CarRowCard): void => {
              this.activateCard(card);
            }
          })
        }

        if (this.itemCards.length > 0) {
          CarShelf({
            title: '最相关的影片',
            cards: this.itemCards,
            onActivate: (card: CarRowCard): void => {
              this.activateCard(card);
            }
          })
          if (this.hasMore) {
            Row() {
              CarPillButton({
                label: this.moreLoading ? '正在加载…' : '更多结果',
                symbol: $r('sys.symbol.arrow_down'),
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

        this.footerState()
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
  private footerState(): void {
    if (this.failed !== null) {
      Stack() {
        CarStateView({
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
      .height(360)
    } else if (this.peopleCards.length === 0 && this.itemCards.length === 0 && !this.searching) {
      if (this.trimmed().length > 0) {
        Stack() {
          CarStateView({
            symbol: $r('sys.symbol.magnifyingglass'),
            title: '没有找到相关影片',
            message: '试试片名、别名、拼音首字母或演员、导演姓名。'
          })
        }
        .width('100%')
        .height(360)
      } else {
        Stack() {
          CarStateView({
            symbol: $r('sys.symbol.magnifyingglass'),
            title: '搜索你的媒体库',
            message: '输入片名、拼音首字母或演员、导演姓名。'
          })
        }
        .width('100%')
        .height(360)
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
    }, CarMotion.searchDebounceMs);
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
    this.peopleCards = CarSearchPage.buildPeopleCards(view.people);
    this.itemCards = CarSearchPage.buildItemCards(view.items);
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
    this.itemCards = CarSearchPage.buildItemCards(merged);
    this.failed = null;
  }

  // MARK: - 卡片装配

  /** 人物行的头像卡：姓名 + 「库内 N 部」 */
  private static buildPeopleCards(people: LibrarySearchPerson[]): CarRowCard[] {
    const origin: string = AppModel.origin();
    const cards: CarRowCard[] = [];
    for (const person of people) {
      const card: CarRowCard = new CarRowCard(`person_${person.id}`, 'person', person.name);
      card.cardWidth = 160;
      card.role = `库内 ${person.item_count} 部`;
      card.worksCount = person.item_count;
      card.imageUrl = CarSearchPage.sized(
        ImageUrls.resolve(origin, person.avatar_url ?? null, null), 160);
      cards.push(card);
    }
    return cards;
  }

  /** 条目行的海报卡：片名 / 年份·类型 / 命中原因常显，不等按压才浮出 */
  private static buildItemCards(hits: LibrarySearchHit[]): CarRowCard[] {
    const origin: string = AppModel.origin();
    const cards: CarRowCard[] = [];
    for (const hit of hits) {
      const item = hit.item;
      const card: CarRowCard = new CarRowCard(`hit_${item.media_item_id}`, 'poster', item.title);
      card.cardWidth = CarMetrics.posterWidth;
      card.imageUrl = CarSearchPage.sized(
        ImageUrls.resolve(origin, item.poster_url ?? item.backdrop_url ?? null, null),
        CarMetrics.posterWidth);
      card.subtitle = CarSearchPage.itemSubtitle(item.year ?? null, item.kind);
      card.note = hit.match.label;
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
    const kindName: string | null = CarSearchPage.kindLabel(kind);
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
    return `${url}${url.includes('?') ? '&' : '?'}w=${CarArt.pxWidth(vpWidth)}`;
  }

  // MARK: - 激活路由

  /** 人物卡进影人作品墙（旧服务端没有 TMDB 影人 id 的点按不跳转）；条目卡进详情 */
  private activateCard(card: CarRowCard): void {
    if (card.kind === 'person') {
      for (const person of this.people) {
        if (card.key === `person_${person.id}`) {
          const tmdbId: number = person.tmdb_person_id ?? 0;
          if (tmdbId > 0) {
            CarUiState.shared.pushRoute(new CarPersonRoute(tmdbId, person.name));
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
          CarUiState.shared.pushRoute(new CarDetailRoute(libraryId, hit.item.media_item_id));
        }
        return;
      }
    }
  }
}
