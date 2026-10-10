import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { AppFooter } from '../common/AppFooter';
import { MovieClawApi } from '../api/Endpoints';
import { LibraryItemView, LibrarySearchHit, LibrarySearchPerson, LibrarySearchSuggestion, LibrarySearchView } from '../api/Models';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';
import { PersonParams } from '../discover/PersonDetailPage';

/**
 * 媒体库搜索「影片行」的数据源（LazyForEach 用）：命中海报按两列一行切块，
 * 结果整批回来时整体换、整体 onDataReloaded（同 WallRowSource 的教训）。
 */
class LibraryHitsSource implements IDataSource {
  private rows: LibrarySearchHit[][] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): LibrarySearchHit[] {
    return this.rows[index];
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

  setHits(hits: LibrarySearchHit[]): void {
    const rows: LibrarySearchHit[][] = [];
    for (let i: number = 0; i < hits.length; i += 2) {
      const end: number = Math.min(i + 2, hits.length);
      const row: LibrarySearchHit[] = [];
      for (let j: number = i; j < end; j++) {
        row.push(hits[j]);
      }
      rows.push(row);
    }
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/**
 * 媒体库搜索结果（对齐 iOS `LibrarySearchResultsView` + `LibrarySearchModel`）。
 * 两处复用同一份：
 * - 搜索首页媒体库模式的**页内实时结果**（`live=true`：关键词停顿 300ms 再请求，
 *   换词保留上一轮结果直到新结果到达，不每敲一个字闪一次骨架屏）；
 * - 结果页的「媒体库」垂直（关键词固定，一次加载 + 滚动续页）。
 *
 * 结构自上而下：骨架屏 → 空态/出错（出口「搜索影视条目」）→ 搜索联想胶囊 →
 * 人物横滚行 → 影片两列海报墙（命中原因注在卡下）→ 「更多结果」自动续页。
 */
@ComponentV2
export struct LibrarySearchResults {
  /** 搜索关键词（实时模式下随输入变化，@Monitor 驱动重搜） */
  @Require @Param keyword: string;
  /** 页内实时模式：防抖请求 + 显示联想胶囊（结果页关键词固定，不显示联想） */
  @Param live: boolean = false;
  /** 空态出口「搜索影视条目」；搜索首页按权限传入，结果页切垂直用 */
  @Param onSwitchToMedia: (() => void) | null = null;
  /** 点了搜索联想：把词填进搜索框（只有实时模式传） */
  @Param onPickSuggestion: ((text: string) => void) | null = null;
  /** 页内跳转用的导航栈（搜索首页 / 结果页各自注入） */
  @Require @Param navStack: NavPathStack;

  @Local private hits: LibrarySearchHit[] = [];
  @Local private people: LibrarySearchPerson[] = [];
  @Local private suggestions: LibrarySearchSuggestion[] = [];
  @Local private nextCursor: string | null = null;
  @Local private loadingMore: boolean = false;
  @Local private errorMessage: string = '';
  /** 首轮是否已返回（区分骨架屏与空态） */
  @Local private loaded: boolean = false;
  /** 已搜过（或正在搜）的关键词：同词不重搜 */
  private loadedKeyword: string = '';
  /** 请求代次：旧请求的响应一律丢弃（同 iOS generation） */
  private generation: number = 0;
  private debounceId: number = -1;
  private hitsSource: LibraryHitsSource = new LibraryHitsSource();

  aboutToAppear(): void {
    this.scheduleLoad();
  }

  aboutToDisappear(): void {
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
  }

  /** 关键词变了：实时模式停 300ms 再搜（同 iOS live 防抖），结果页立即搜 */
  @Monitor('keyword')
  onKeywordChange(): void {
    this.scheduleLoad();
  }

  private scheduleLoad(): void {
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
    if (!this.live) {
      this.load();
      return;
    }
    this.debounceId = setTimeout((): void => {
      this.debounceId = -1;
      this.load();
    }, 300);
  }

  private async load(): Promise<void> {
    const keyword: string = this.keyword;
    if (keyword === this.loadedKeyword) {
      return;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.loadedKeyword = keyword;
    this.generation += 1;
    const request: number = this.generation;
    // 换词不清空旧结果（实时输入不闪骨架屏），只丢掉绑定上个关键词的游标
    this.nextCursor = null;
    this.loadingMore = false;
    this.errorMessage = '';
    try {
      const view: LibrarySearchView = await api.searchLibrary(keyword);
      if (request !== this.generation) {
        return;
      }
      this.hits = view.items;
      this.people = view.people;
      this.suggestions = view.suggestions;
      this.nextCursor = view.next_cursor ?? null;
      this.hitsSource.setHits(view.items);
    } catch (error) {
      if (request !== this.generation) {
        return;
      }
      this.hits = [];
      this.people = [];
      this.suggestions = [];
      this.hitsSource.setHits([]);
      this.errorMessage = this.messageOf(error);
    } finally {
      if (request === this.generation) {
        this.loaded = true;
      }
    }
  }

  /** 续页（同 iOS loadMore）：有游标才请求；按 media_item_id 去重 */
  private async loadMore(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const cursor: string | null = this.nextCursor;
    if (api === null || cursor === null || this.loadingMore || !this.loaded) {
      return;
    }
    const request: number = this.generation;
    this.loadingMore = true;
    try {
      const view: LibrarySearchView = await api.searchLibrary(this.keyword, cursor);
      if (request !== this.generation) {
        return;
      }
      const existing: Set<number> = new Set<number>();
      for (const hit of this.hits) {
        existing.add(hit.item.media_item_id);
      }
      const merged: LibrarySearchHit[] = this.hits.slice();
      for (const hit of view.items) {
        if (!existing.has(hit.item.media_item_id)) {
          merged.push(hit);
        }
      }
      this.hits = merged;
      this.nextCursor = view.next_cursor ?? null;
      this.hitsSource.setHits(merged);
    } catch (error) {
      if (request === this.generation) {
        this.errorMessage = this.messageOf(error);
      }
    } finally {
      if (request === this.generation) {
        this.loadingMore = false;
      }
    }
  }

  private messageOf(error: Object): string {
    const text: string = `${error}`;
    return text.length > 0 ? text : '媒体库搜索失败，请稍后重试';
  }

  // MARK: 文案

  /**
   * 搜索联想（同 iOS suggestions）：只列片名（人名正下方就有带头像的人物行），
   * 与当前输入完全相同的词不列，重复的去掉。
   */
  private visibleSuggestions(): LibrarySearchSuggestion[] {
    const seen: Set<string> = new Set<string>();
    const current: string = this.keyword.trim().toLowerCase();
    if (current.length > 0) {
      seen.add(current);
    }
    const picked: LibrarySearchSuggestion[] = [];
    for (const suggestion of this.suggestions) {
      if (suggestion.type !== 'title') {
        continue;
      }
      const key: string = suggestion.text.trim().toLowerCase();
      if (key.length === 0 || seen.has(key)) {
        continue;
      }
      seen.add(key);
      picked.push(suggestion);
    }
    return picked;
  }

  /** 联想的命中原因只在有信息量时写：直接按片名命中不必解释，人物带出、拼音才写 */
  private suggestionReason(suggestion: LibrarySearchSuggestion): string {
    const label: string | null = suggestion.label ?? null;
    if (label === null || label === '名称匹配') {
      return '';
    }
    return label;
  }

  /** 命中原因：直接按片名的文字命中不必解释，别名/原名/拼音/人物带出的结果写明原因 */
  private matchHint(hit: LibrarySearchHit): string {
    const match = hit.match;
    if ((match.person_id ?? null) === null && match.source_field === 'title'
      && match.type.startsWith('text')) {
      return '';
    }
    return match.label;
  }

  /** 海报下的附加一行：剧集季集 + 分辨率（同 iOS footnote） */
  private footnote(item: LibraryItemView): string {
    const parts: string[] = [];
    if (item.kind === 'tv' && item.seasons.length > 0) {
      parts.push(item.seasons.length === 1
        ? `第 ${item.seasons[0]} 季 · ${item.episode_count} 集`
        : `${item.seasons.length} 季 · ${item.episode_count} 集`);
    }
    if (item.resolutions.length > 0) {
      parts.push(item.resolutions.join('/'));
    }
    return parts.join(' · ');
  }

  private itemSubtitle(item: LibraryItemView): string {
    const parts: string[] = [];
    const year: number | null = item.year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    if (item.kind === 'tv') {
      parts.push(`${item.episode_count} 集`);
    }
    return parts.join('  ·  ');
  }

  private openHit(hit: LibrarySearchHit): void {
    // 落点库：服务端给的详情落点库优先，其次取所在库里的第一个（同 iOS cell）
    const fallback: number = hit.library_ids.length > 0 ? hit.library_ids[0] : 0;
    const libraryId: number = hit.item.library_id ?? fallback;
    this.navStack.pushPathByName('libraryItem', new ItemRouteParams(libraryId, hit.item.media_item_id));
  }

  private openPerson(person: LibrarySearchPerson): void {
    // 旧服务端不返回 TMDB 影人 id，没有影人页可进：不响应点按（同 iOS 静态块）
    const id: number = person.tmdb_person_id ?? 0;
    if (id > 0) {
      this.navStack.pushPathByName('person', new PersonParams(id));
    }
  }

  // MARK: 视图

  build() {
    List() {
      // 骨架屏：首轮未返回时画两列六格（同 iOS LazyVGrid 骨架）
      if (!this.loaded && this.errorMessage.length === 0) {
        ListItem() {
          Column({ space: 16 }) {
            ForEach([0, 1, 2], (rowIndex: number) => {
              Row({ space: 12 }) {
                Column()
                  .layoutWeight(1)
                  .aspectRatio(Theme.posterAspect)
                  .borderRadius(Theme.cardRadius)
                  .backgroundColor(Theme.surface)
                Column()
                  .layoutWeight(1)
                  .aspectRatio(Theme.posterAspect)
                  .borderRadius(Theme.cardRadius)
                  .backgroundColor(Theme.surface)
              }
              .width('100%')
            }, (rowIndex: number) => `${rowIndex}`)
          }
          .width('100%')
          .padding({ top: 12 })
        }
      }
      // 空态 / 出错：出口指向「影视条目」（有权限才给）
      if (this.loaded && (this.errorMessage.length > 0
        || (this.hits.length === 0 && this.people.length === 0))) {
        ListItem() {
          Column({ space: 8 }) {
            Text(this.errorMessage.length > 0 ? '媒体库搜索出错' : '媒体库中没有找到相关影片')
              .fontSize(16)
              .fontWeight(600)
              .fontColor(Theme.text)
            Text(this.errorMessage.length > 0 ? this.errorMessage
              : '支持片名、别名、拼音首字母和人物姓名；库里还没有的片子，去影视条目里找。')
              .fontSize(13)
              .fontColor(Theme.textMuted)
              .textAlign(TextAlign.Center)
            if (this.onSwitchToMedia !== null) {
              Text('搜索影视条目')
                .fontSize(14)
                .fontWeight(600)
                .fontColor(Theme.accentStrong)
                .padding({ left: 20, right: 20, top: 9, bottom: 9 })
                .backgroundColor(Theme.glassFill)
                .borderRadius(18)
                .border({ width: 1, color: Theme.lineStrong })
                .margin({ top: 8 })
                .onClick(() => {
                  this.onSwitchToMedia?.();
                })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 60, left: 24, right: 24 })
        }
      }
      // 搜索联想：实时模式从本次结果里提取片名，点一下把词填进搜索框
      if (this.live && this.errorMessage.length === 0
        && this.onPickSuggestion !== null && this.visibleSuggestions().length > 0) {
        ListItem() {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.visibleSuggestions(), (suggestion: LibrarySearchSuggestion) => {
                Row({ space: 6 }) {
                  Text(suggestion.text)
                    .fontSize(14)
                    .fontColor(Theme.text)
                    .maxLines(1)
                  if (this.suggestionReason(suggestion).length > 0) {
                    Text(this.suggestionReason(suggestion))
                      .fontSize(11)
                      .fontColor(Theme.textFaint)
                      .maxLines(1)
                  }
                }
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .backgroundColor(Theme.glassFill)
                .borderRadius(17)
                .border({ width: 1, color: Theme.lineStrong })
                .onClick(() => {
                  this.onPickSuggestion?.(suggestion.text);
                })
              }, (suggestion: LibrarySearchSuggestion) => `${suggestion.type}-${suggestion.text}`)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }
      }
      // 人物行：圆形头像 + 姓名 + 库内作品数，点头像进库内影人页
      if (this.errorMessage.length === 0 && this.people.length > 0) {
        ListItem() {
          Column({ space: 12 }) {
            Text('人物')
              .fontSize(17)
              .fontWeight(600)
              .fontColor(Theme.text)
            Scroll() {
              Row({ space: 12 }) {
                ForEach(this.people, (person: LibrarySearchPerson) => {
                  Column({ space: 4 }) {
                    Stack() {
                      Column()
                        .width('100%')
                        .height('100%')
                        .linearGradient({
                          angle: 180,
                          colors: [['rgba(255,255,255,0.07)', 0], ['rgba(255,255,255,0.02)', 1]]
                        })
                      Text(person.name.length > 0 ? person.name.substring(0, 1) : '?')
                        .fontSize(22)
                        .fontWeight(600)
                        .fontColor('rgba(255,255,255,0.35)')
                      if (person.avatar_url !== null && person.avatar_url !== undefined
                        && person.avatar_url.length > 0) {
                        RemoteImage({
                          url: ImageUrls.resolve(AppModel.origin(), person.avatar_url,
                            ImageVariant.photoTile) ?? '',
                          placeholderSymbol: $r('sys.symbol.person')
                        })
                          .width('100%')
                          .height('100%')
                      }
                    }
                    .width(72)
                    .height(72)
                    .borderRadius(36)
                    .clip(true)
                    Text(person.name)
                      .fontSize(14)
                      .fontWeight(500)
                      .fontColor(Theme.text)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`库内 ${person.item_count} 部`)
                      .fontSize(12)
                      .fontColor(Theme.textFaint)
                      .maxLines(1)
                  }
                  .width(96)
                  .alignItems(HorizontalAlign.Start)
                  .onClick(() => {
                    this.openPerson(person);
                  })
                }, (person: LibrarySearchPerson) => `${person.id}-${person.name}`)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 10, bottom: 4 })
        }
      }
      // 影片墙：有人物时才写「影片」小节题；两列海报 + 命中原因
      if (this.errorMessage.length === 0 && this.hits.length > 0) {
        if (this.people.length > 0) {
          ListItem() {
            Text('影片')
              .fontSize(17)
              .fontWeight(600)
              .fontColor(Theme.text)
              .width('100%')
              .padding({ top: 10 })
          }
        }
        LazyForEach(this.hitsSource, (row: LibrarySearchHit[]) => {
          ListItem() {
            Row({ space: 12 }) {
              ForEach(row, (hit: LibrarySearchHit) => {
                this.HitCard(hit)
              }, (hit: LibrarySearchHit) => `${hit.item.media_item_id}-${hit.match.label}`)
            }
            .width('100%')
          }
        }, (row: LibrarySearchHit[], index: number) => `${index}-${row.length}`)
        // 底部「更多结果」进入可视区自动续页（同 iOS onAppear）
        if (this.nextCursor !== null) {
          ListItem() {
            Text(this.loadingMore ? '正在加载…' : '更多结果')
              .fontSize(14)
              .fontWeight(600)
              .fontColor(Theme.textMuted)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 14, bottom: 14 })
              .onClick(() => {
                this.loadMore();
              })
              .onAppear(() => {
                this.loadMore();
              })
          }
        }
      }
      // 页脚：品牌联合声明，复用全局 AppFooter（包在 ListItem 里跟随滚动）
      ListItem() {
        AppFooter({ topSpace: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .cachedCount(4)
    .padding({ left: 20, right: 20 })
    .padding({ bottom: this.live ? Theme.tabBarInset : 24 })
  }

  /** 命中的影片卡（同 iOS cell）：海报 + 片名 + 年份 + 附加行 + 命中原因，单击直达条目详情 */
  @Builder
  HitCard(hit: LibrarySearchHit) {
    Column({ space: 2 }) {
      RemoteImage({
        url: ImageUrls.resolve(AppModel.origin(), hit.item.poster_url ?? null,
          ImageVariant.posterCard) ?? ''
      })
        .width('100%')
        .aspectRatio(hit.item.primary_aspect > 0 ? hit.item.primary_aspect : Theme.posterAspect)
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .clip(true)
      Text(hit.item.title)
        .fontSize(14)
        .fontWeight(600)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ top: 4 })
      Text(this.itemSubtitle(hit.item).length > 0 ? this.itemSubtitle(hit.item) : ' ')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.footnote(hit.item).length > 0) {
        Text(this.footnote(hit.item))
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.matchHint(hit).length > 0) {
        Text(this.matchHint(hit))
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openHit(hit);
    })
  }
}
