import { Theme } from '../theme/AppTheme';
import { AppFooter } from '../common/AppFooter';
import { TorrentParams } from './TorrentResultsPage';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { Formatters } from '../common/Formatters';
import { MovieClawApi } from '../api/Endpoints';
import { SearchHistoryItem } from '../api/Models';
import { SearchMode, SearchParams } from './SearchResultsPage';
import { SearchAccess } from './SearchAccess';
import { LibrarySearchResults } from './LibrarySearchResults';

/** 搜索竖向的展示规格（对应 iOS `SearchVertical`：label 用 shortLabel） */
class ModeOption {
  readonly value: string;
  readonly label: string;
  readonly hint: string;
  readonly modeHint: string;

  constructor(value: string, label: string, hint: string, modeHint: string) {
    this.value = value;
    this.label = label;
    this.hint = hint;
    this.modeHint = modeHint;
  }
}

const MODES: ModeOption[] = [
  new ModeOption(SearchMode.library, '媒体库', '搜索已入库的影片…', '在媒体库中搜索已入库的影片。'),
  new ModeOption(SearchMode.media, '影视', '搜索电影、剧集…', '在豆瓣与 TMDB 中搜索影视条目。'),
  new ModeOption(SearchMode.torrent, '资源', '搜索资源或 IMDb ID…', '跨全部已配置站点搜索种子。')
];

/** 记住搜索模式的 AppStorage 键（同 iOS UserDefaults 的 stateKey） */
const MODE_STORAGE_KEY: string = 'mc_search_mode';
/** 结果页搜索词胶囊回传草稿的 AppStorage 键（同 iOS Router.searchDraft） */
const DRAFT_STORAGE_KEY: string = 'mc_search_draft';

/** 同关键词（忽略首尾空格与大小写）的历史记录折叠成一组，组内按最近搜索时间倒序（同 iOS HistoryGroup） */
class HistoryGroup {
  readonly key: string;
  readonly keyword: string;
  readonly items: SearchHistoryItem[];

  constructor(key: string, keyword: string, items: SearchHistoryItem[]) {
    this.key = key;
    this.keyword = keyword;
    this.items = items;
  }
}

/** 结果页胶囊回传的搜索草稿（JSON 序列化走 AppStorage） */
class SearchDraft {
  readonly keyword: string;
  readonly mode: string;

  constructor(keyword: string, mode: string) {
    this.keyword = keyword;
    this.mode = mode;
  }

  static parse(raw: string): SearchDraft | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as SearchDraft;
      const keyword: string = parsed.keyword;
      if (keyword === undefined || keyword === null) {
        return null;
      }
      const mode: string = parsed.mode === undefined || parsed.mode === null ? '' : parsed.mode;
      return new SearchDraft(keyword, mode);
    } catch (error) {
      return null;
    }
  }

  encode(): string {
    const record: Record<string, string> = { 'keyword': this.keyword, 'mode': this.mode };
    return JSON.stringify(record);
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function SearchBuilder() {
  SearchPage()
}

/**
 * 搜索首页（对齐 iOS `Features/Search/SearchHomeView.swift`）。
 *
 * - **媒体库模式 = 页内实时结果**：输入关键词后主体直接换成 `LibrarySearchResults`
 *   （300ms 防抖、联想胶囊、人物行、影片墙），回车只收键盘、不再压结果页（同 iOS）；
 * - **影视 / 资源模式**：输入后顶上一行「搜索“…”」提交；下面是分组折叠的最近搜索
 *   （媒体库没有历史，整段隐藏——同 iOS）；
 * - 模式按 `SearchAccess` 权限裁剪，只有一个可用分区时不出切换 chips；
 * - 历史行点按**回放**：有快照进快照（结果页秒开），没有发起实时搜索；
 * - 模式记忆在 AppStorage，结果页胶囊回来时按草稿回填关键词与模式。
 */
@ComponentV2
export struct SearchPage {
  /** @Local：onReady 里换真栈后要同步给 LibrarySearchResults 的 @Param navStack */
  @Local private navStack: NavPathStack = new NavPathStack();
  @Local private keyword: string = '';
  @Local private mode: string = SearchMode.library;
  @Local private access: SearchAccess = SearchAccess.notReady();
  /** null = 正在加载；[] = 已加载（媒体库模式恒为 []，整段不显示） */
  @Local private history: SearchHistoryItem[] | null = null;

  private started: boolean = false;
  /** 历史请求代次：切模式 / 刷新后旧响应不能覆盖当前列表 */
  private historyGeneration: number = 0;

  aboutToAppear(): void {
    this.restoreMode();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private currentMode(): ModeOption {
    for (const option of MODES) {
      if (option.value === this.mode) {
        return option;
      }
    }
    return MODES[0];
  }

  /** 可用模式的展示规格（按权限裁剪，同 iOS `access.available`） */
  private visibleModes(): ModeOption[] {
    const modes: ModeOption[] = [];
    for (const option of MODES) {
      if (this.access.allows(option.value)) {
        modes.push(option);
      }
    }
    return modes;
  }

  /** 历史分区：影视 → titles、资源 → torrents、媒体库 → 无（同 iOS historyVertical） */
  private historyVertical(): string {
    if (this.mode === SearchMode.media) {
      return 'titles';
    }
    if (this.mode === SearchMode.torrent) {
      return 'torrents';
    }
    return '';
  }

  /** 媒体库模式且输入了关键词：面板主体换成实时结果（同 iOS liveLibrary） */
  private liveLibrary(): boolean {
    return this.mode === SearchMode.library && this.access.canLibrary
      && this.keyword.trim().length > 0;
  }

  // MARK: 取数

  /** 搜索历史（同 iOS loadHistory）：只取当前分区的 8 条；媒体库直接置空 */
  private async loadHistory(): Promise<void> {
    const vertical: string = this.historyVertical();
    this.historyGeneration += 1;
    const request: number = this.historyGeneration;
    if (vertical.length === 0) {
      this.history = [];
      return;
    }
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      this.history = [];
      return;
    }
    this.history = null;
    try {
      const list: SearchHistoryItem[] = await api.searchHistoryList(8, vertical);
      if (request !== this.historyGeneration) {
        return;
      }
      this.history = list;
    } catch (error) {
      if (request === this.historyGeneration) {
        this.history = [];
      }
    }
  }

  /** 解析搜索分区权限；当前模式没权限时落到第一个可用分区（同 iOS initialize） */
  private async resolveAccess(): Promise<void> {
    const permissions: Permissions = Permissions.fromSession(AppModel.shared.session);
    this.access = await SearchAccess.resolve(this.api(), permissions);
    if (!this.access.allows(this.mode)) {
      const available: string[] = this.access.available();
      if (available.length > 0) {
        this.mode = available[0];
        this.saveMode();
      }
    }
    await this.loadHistory();
  }

  // MARK: 动作

  /**
   * 提交（同 iOS submit）：
   * - 资源：压栈种子结果页（关键词可空 = 浏览，浏览分类本轮尚未接入）；
   * - 媒体库：结果已在本页实时展示，回车只收键盘；
   * - 影视：空词不提交，压栈结果页。
   */
  private submit(): void {
    if (!this.access.allows(this.mode)) {
      return;
    }
    const keyword: string = this.keyword.trim();
    if (this.mode === SearchMode.torrent) {
      this.navStack.pushPathByName('torrents', new TorrentParams(keyword));
      return;
    }
    if (keyword.length === 0) {
      return;
    }
    if (this.mode === SearchMode.library) {
      this.getUIContext().getFocusController().clearFocus();
      return;
    }
    this.navStack.pushPathByName('searchResults', new SearchParams(keyword, SearchMode.media, 0));
    setTimeout((): void => {
      this.loadHistory();
    }, 1200);
  }

  /**
   * 点开一条历史（同 iOS pick）：按记录自身的分区回放——
   * 有快照进快照（结果页秒开、顶上提示快照年龄），没有发起实时搜索。
   */
  private pick(item: SearchHistoryItem): void {
    const snapshotId: number = item.has_snapshot ? item.id : 0;
    if (item.vertical === 'titles') {
      this.navStack.pushPathByName('searchResults',
        new SearchParams(item.keyword, SearchMode.media, snapshotId));
      return;
    }
    this.navStack.pushPathByName('torrents', new TorrentParams(item.keyword));
  }

  /** 切模式：历史重新加载（旧分区列表不残留），模式记忆落 AppStorage（同 iOS changeMode） */
  private changeMode(next: string): void {
    if (next !== this.mode) {
      this.history = null;
    }
    this.mode = next;
    this.saveMode();
    this.loadHistory();
  }

  private removeOne(id: number): void {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    api.searchHistoryDelete(id).then((): void => {
      this.loadHistory();
    }).catch((): void => {
      this.getUIContext().getPromptAction().showToast({ message: '删除失败，请重试' });
    });
  }

  /** 删整组：多条时先确认（同 iOS removeGroup） */
  private removeGroup(group: HistoryGroup): void {
    if (group.items.length > 1) {
      const options: AlertDialogParamWithButtons = {
        title: `删除「${group.keyword}」的 ${group.items.length} 条搜索记录？`,
        message: '删除后无法恢复。',
        primaryButton: {
          value: '取消',
          action: (): void => {
          }
        },
        secondaryButton: {
          value: '删除',
          fontColor: Theme.danger,
          action: (): void => {
            this.deleteGroup(group);
          }
        }
      };
      this.getUIContext().showAlertDialog(options);
      return;
    }
    this.deleteGroup(group);
  }

  private deleteGroup(group: HistoryGroup): void {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    const next = (): void => {
      this.loadHistory();
    };
    const fail = (): void => {
      this.getUIContext().getPromptAction().showToast({ message: '删除失败，请重试' });
    };
    const steps: Promise<void>[] = [];
    for (const item of group.items) {
      steps.push(api.searchHistoryDelete(item.id));
    }
    Promise.all(steps).then(next).catch(fail);
  }

  /** 清空当前分区的历史（媒体库没有历史，不能以空调全部——同 iOS 清空按分区） */
  private clearHistory(): void {
    const vertical: string = this.historyVertical();
    if (vertical.length === 0) {
      return;
    }
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '清空搜索历史',
      message: '搜索过的关键词都会删掉。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: Theme.danger,
        action: (): void => {
          this.history = [];
          api.searchHistoryClear(vertical).then((): void => {
            this.loadHistory();
          }).catch((): void => {
            this.getUIContext().getPromptAction().showToast({ message: '清空失败，请重试' });
          });
        }
      }
    });
  }

  // MARK: 状态记忆

  private restoreMode(): void {
    const saved: string = AppStorage.get<string>(MODE_STORAGE_KEY) ?? '';
    if (saved === SearchMode.media || saved === SearchMode.torrent || saved === SearchMode.library) {
      this.mode = saved;
    }
  }

  private saveMode(): void {
    AppStorage.setOrCreate(MODE_STORAGE_KEY, this.mode);
  }

  /** 结果页点搜索词胶囊回来：填回关键词、切回当时的模式（同 iOS takeDraft） */
  private takeDraft(): void {
    const raw: string = AppStorage.get<string>(DRAFT_STORAGE_KEY) ?? '';
    if (raw.length === 0) {
      return;
    }
    AppStorage.setOrCreate(DRAFT_STORAGE_KEY, '');
    const draft: SearchDraft | null = SearchDraft.parse(raw);
    if (draft === null) {
      return;
    }
    this.keyword = draft.keyword;
    if (draft.mode.length > 0 && draft.mode !== this.mode && this.access.allows(draft.mode)) {
      this.changeMode(draft.mode);
    }
  }

  // MARK: 文案

  /** 历史行的范围标签（同 iOS scopeLabel）：「影视」「资源」「资源 · 电影」 */
  private scopeLabel(item: SearchHistoryItem): string {
    if (item.vertical === 'titles') {
      return '影视';
    }
    const label: string | null = item.label ?? null;
    return label !== null && label.length > 0 ? `资源 · ${label}` : '资源';
  }

  /** 历史行的时间与快照（同 iOS detailLine）：「4 小时前 · 快照」 */
  private detailLine(item: SearchHistoryItem): string {
    const time: string = Formatters.relative(item.last_searched_at);
    return item.has_snapshot ? `${time} · 快照` : time;
  }

  /** 分组折叠 + 随输入过滤（同 iOS groups） */
  private groups(): HistoryGroup[] {
    const list: SearchHistoryItem[] = this.history ?? [];
    const vertical: string = this.historyVertical();
    const order: string[] = [];
    const map: Record<string, HistoryGroup> = {};
    for (const item of list) {
      if (item.vertical !== vertical) {
        continue;
      }
      if (vertical === 'titles' && !this.access.canMedia) {
        continue;
      }
      if (vertical === 'torrents' && !this.access.canTorrent) {
        continue;
      }
      const key: string = item.keyword.trim().toLowerCase();
      if (key.length === 0) {
        continue;
      }
      if (map[key] === undefined) {
        order.push(key);
        map[key] = new HistoryGroup(key, item.keyword, []);
      }
      map[key].items.push(item);
    }
    const needle: string = this.keyword.trim().toLowerCase();
    const result: HistoryGroup[] = [];
    for (const key of order) {
      if (needle.length === 0 || key.indexOf(needle) >= 0) {
        result.push(map[key]);
      }
    }
    return result;
  }

  /** 提交行的副标题（同 iOS submitSubtitle）：写清在哪儿搜 */
  private submitSubtitle(): string {
    if (this.mode === SearchMode.media) {
      return '豆瓣与 TMDB 影视条目';
    }
    if (this.mode === SearchMode.torrent) {
      return '在全部分类中搜索';
    }
    return '已入库的影片';
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        this.SearchField()
        if (this.access.ready && this.visibleModes().length > 1) {
          this.ModeChips()
        }
        Divider().color(Theme.line)
        if (!this.access.ready) {
          Column() {
            LoadingProgress()
              .width(26)
              .height(26)
              .color(Theme.textMuted)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.visibleModes().length === 0) {
          Column() {
            Text('当前账号没有可用的搜索入口，请联系管理员调整成员权限。')
              .fontSize(15)
              .fontColor(Theme.textMuted)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.liveLibrary()) {
          LibrarySearchResults({
            keyword: this.keyword.trim(),
            live: true,
            navStack: this.navStack,
            onPickSuggestion: (text: string): void => {
              this.keyword = text;
            },
            onSwitchToMedia: this.access.canMedia
              ? (): void => {
                this.changeMode(SearchMode.media);
              }
              : null
          })
        } else {
          this.HomeList()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      if (!this.started) {
        this.started = true;
        this.resolveAccess();
        this.takeDraft();
      }
    })
    .onShown(() => {
      this.takeDraft();
    })
  }

  /** 返回 + 原生 `Search` 组件（对应 iOS 的系统搜索栏；首次进页自动聚焦弹键盘） */
  @Builder
  SearchField() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([Theme.text])
        .onClick(() => {
          this.navStack.pop();
        })
      Search({ value: this.keyword, placeholder: this.currentMode().hint })
        .layoutWeight(1)
        .height(42)
        .placeholderColor(Theme.textFaint)
        .placeholderFont({ size: 15 })
        .textFont({ size: 15 })
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(21)
        .enterKeyType(EnterKeyType.Search)
        .defaultFocus(true)
        .onChange((value: string): void => {
          this.keyword = value;
        })
        .onSubmit((value: string): void => {
          this.keyword = value;
          this.submit();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 12, right: 16, top: 10 + Theme.statusBarInset, bottom: 10 })
  }

  /** 竖向切换（对应 iOS 的 `.searchScopes` 范围栏；只有一个可用分区时不出） */
  @Builder
  ModeChips() {
    Row({ space: 8 }) {
      ForEach(this.visibleModes(), (option: ModeOption) => {
        Text(option.label)
          .fontSize(14)
          .fontColor(this.mode === option.value ? '#0b0d12' : Theme.textMuted)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(this.mode === option.value ? Theme.accent : Theme.glassFill)
          .borderRadius(16)
          .onClick(() => {
            this.changeMode(option.value);
          })
      }, (option: ModeOption) => option.value)
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 10 })
  }

  /** 非实时模式的主列表：提交行 + 分组历史（同 iOS content 的 List 分支） */
  @Builder
  HomeList() {
    List() {
      // 输入了关键词：顶上一行直接搜索，下注在哪儿搜（同 iOS submitSection）
      if (this.keyword.trim().length > 0 && this.access.allows(this.mode)) {
        ListItem() {
          Row({ space: 14 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(17)
              .fontColor([Theme.accentStrong])
              .width(26)
            Column({ space: 2 }) {
              Text(`搜索“${this.keyword.trim()}”`)
                .fontSize(16)
                .fontColor(Theme.text)
                .maxLines(1)
              Text(this.submitSubtitle())
                .fontSize(14)
                .fontColor(Theme.textMuted)
                .maxLines(1)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 14, bottom: 14 })
          .onClick(() => {
            this.submit();
          })
        }
      }
      // 历史分区：影视 / 资源（媒体库整段隐藏——同 iOS）
      if (this.historyVertical().length > 0) {
        if (this.history === null) {
          ListItem() {
            Row() {
              LoadingProgress()
                .width(22)
                .height(22)
                .color(Theme.textFaint)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 28, bottom: 28 })
          }
        } else if ((this.history ?? []).length === 0) {
          ListItem() {
            Column({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(30)
                .fontColor([Theme.textFaint])
              Text('还没有搜索记录')
                .fontSize(16)
                .fontWeight(600)
                .fontColor(Theme.text)
              Text(this.currentMode().modeHint)
                .fontSize(13)
                .fontColor(Theme.textMuted)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 40, bottom: 40 })
          }
        } else if (this.groups().length > 0) {
          ListItem() {
            Row() {
              Text('最近搜索')
                .fontSize(13)
                .fontWeight(600)
                .fontColor(Theme.textFaint)
                .layoutWeight(1)
              Text('清空')
                .fontSize(15)
                .fontColor(Theme.danger)
                .onClick(() => {
                  this.clearHistory();
                })
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 12, bottom: 8 })
          }
          ForEach(this.groups(), (group: HistoryGroup) => {
            ListItemGroup() {
              // 主行：最近一条记录（时钟图标），点按回放；左滑删整组
              ListItem() {
                Row({ space: 14 }) {
                  SymbolGlyph($r('sys.symbol.clock'))
                    .fontSize(17)
                    .fontColor([Theme.textFaint])
                    .width(26)
                  Column({ space: 2 }) {
                    Text(group.keyword)
                      .fontSize(16)
                      .fontColor(Theme.text)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${this.scopeLabel(group.items[0])} · ${this.detailLine(group.items[0])}`)
                      .fontSize(14)
                      .fontColor(Theme.textMuted)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .padding({ left: 20, right: 20, top: 12, bottom: 12 })
                .onClick(() => {
                  this.pick(group.items[0]);
                })
              }
              .swipeAction({
                end: {
                  builder: (): void => {
                    this.DeleteSwipe()
                  },
                  actionAreaDistance: 56,
                  onAction: (): void => {
                    this.removeGroup(group);
                  }
                }
              })
              // 同词的其余范围：「↳」连接符 + 范围名，点按回放该条；左滑删这一条
              ForEach(group.items, (item: SearchHistoryItem) => {
                if (item !== group.items[0]) {
                  ListItem() {
                    Row({ space: 14 }) {
                      Text('↳')
                        .fontSize(15)
                        .fontWeight(600)
                        .fontColor(Theme.textFaint)
                        .width(26)
                        .textAlign(TextAlign.Center)
                      Column({ space: 2 }) {
                        Text(this.scopeLabel(item))
                          .fontSize(15)
                          .fontColor(Theme.text)
                          .maxLines(1)
                        Text(this.detailLine(item))
                          .fontSize(13)
                          .fontColor(Theme.textMuted)
                          .maxLines(1)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                    }
                    .width('100%')
                    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
                    .onClick(() => {
                      this.pick(item);
                    })
                  }
                  .swipeAction({
                    end: {
                      builder: (): void => {
                        this.DeleteSwipe()
                      },
                      actionAreaDistance: 56,
                      onAction: (): void => {
                        this.removeOne(item.id);
                      }
                    }
                  })
                }
              }, (item: SearchHistoryItem) => `${item.id}`)
            }
          }, (group: HistoryGroup) => group.key)
        }
      }
      // 页脚：品牌联合声明，复用全局 AppFooter（包在 ListItem 里跟随滚动）
      ListItem() {
        AppFooter({ topSpace: 0 })
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .cachedCount(4)
    .padding({ bottom: Theme.tabBarInset })
    .backgroundColor(Theme.bg)
  }

  /** 左滑出现的删除按钮（垃圾桶，红底白字——同 iOS deleteAction） */
  @Builder
  DeleteSwipe() {
    Column() {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(18)
        .fontColor([Color.White])
    }
    .width(56)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.danger)
  }
}
