import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  CollectionPayload,
  CollectionView,
  HomeRowPref,
  HomeRowPrefInput,
  LibraryItemView,
  ShareCreateRequest,
  ShareView,
  UiPreferencesSetting
} from '../api/Models';
import { ItemRouteParams } from './LibraryItemDetailPage';
import { AppFooter } from '../common/AppFooter';
import { LibraryHomePrefs } from './LibraryHomeStore';
import { HomePrefsInput, LibraryHomePrefsHolder } from './LibraryCustomizeSheet';
import { LibraryFilter } from './LibraryWall';
import { LibraryFilterBar } from './LibraryFilterBar';
import { SharePanel, shareMessage } from './ShareSheet';

/** 合集详情页的路由参数（路由参数会被序列化，不要用 instanceof） */
export class CollectionRouteParams {
  readonly collectionId: number;
  /** 所属库（跨库组传 0）；进条目页时当兜底 */
  readonly libraryId: number;

  constructor(collectionId: number, libraryId: number) {
    this.collectionId = collectionId;
    this.libraryId = libraryId;
  }

  static of(param: Object | undefined | null): CollectionRouteParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: CollectionRouteParams = param as CollectionRouteParams;
    const id: number = raw.collectionId;
    if (!Number.isFinite(id) || id <= 0) {
      return null;
    }
    const library: number = raw.libraryId;
    return new CollectionRouteParams(Math.floor(id), Number.isFinite(library) ? Math.floor(library) : 0);
  }
}

/** 排序档（与单库页同一套取值，iOS 的 `prefLabels`） */
class SortOption {
  readonly value: string;
  readonly label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const PAGE_SIZE: number = 60;

/** 新加首页行用的随机 id：`row:` + 6 位 base36（同 iOS `HomeRows.newRowId`） */
function randomRowId(): string {
  const chars: string = '0123456789abcdefghijklmnopqrstuvwxyz';
  let out: string = 'row:';
  for (let i: number = 0; i < 6; i++) {
    out += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return out;
}

/**
 * 合集海报墙的行数据源（LazyForEach 用）。
 *
 * 整面墙原来塞在一个 ListItem 里用 Flex(wrap) + ForEach 全量建——分页每到 60 部就多建
 * 60 个海报格，滚到底续到几百部时全部留在树里。这里按 2 列把条目切成行，每一行是外层
 * List 的一个 ListItem，LazyForEach 只建可视区附近的行（口径同 LibraryDetailPage.WallRowSource）。
 * 每次 setItems 整体换 + onDataReloaded，不做指纹跳过。
 */
class CollectionWallSource implements IDataSource {
  private rows: LibraryItemView[][] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): LibraryItemView[] {
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

  /** 整批换成这一批条目，按列数切行 */
  setItems(items: LibraryItemView[], columns: number): void {
    const rows: LibraryItemView[][] = [];
    for (let i: number = 0; i < items.length; i += columns) {
      rows.push(items.slice(i, i + columns));
    }
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function CollectionDetailBuilder() {
  CollectionDetailPage()
}

/**
 * 合集详情页（对应 iOS `Features/Library/CollectionDetailView.swift`）。
 *
 * 结构照 iOS：
 * - **页头**：名称 + 「N 部」+ 可见性（只有我可见 / 已隐藏）+ 一行说明它是**怎么来的**
 *   （系列 / 固定名单 / 自动收录——iOS 把自动收录的条件收成摘要胶囊，点开才是规则详情）；
 * - **排序**：默认档是合集自己的序（iOS 里手动合集叫「自定顺序」、系列叫「按上映顺序」），
 *   其余与单库页一致；
 * - **海报墙**：分页拉取，滚到底自动续；点格进条目详情；
 * - **⋯ 管理菜单**：改名 / 分享… / 改条件… / 整理顺序… / 显示在首页 / 隐藏或删除。
 *
 * **本轮先不做**：自动收录条件详情弹层（页头胶囊点开的只读摘要）、系列合集把「库里缺的那几部」
 * 按上映时间插进墙里、图床浏览。
 */
@Component
export struct CollectionDetailPage {
  private navStack: NavPathStack = new NavPathStack();
  private collectionId: number = 0;
  private fallbackLibraryId: number = 0;
  private started: boolean = false;
  /** 在途的翻页请求（防重入） */
  private loadingMore: boolean = false;
  private reachedEnd: boolean = false;
  /** 海报墙的行数据源（LazyForEach 只建可视区附近的行） */
  private wallSource: CollectionWallSource = new CollectionWallSource();

  @State private collection: CollectionView | null = null;
  @State private items: LibraryItemView[] = [];
  @State private failed: boolean = false;
  @State private errorMessage: string = '';
  @State private sort: string = 'default';
  @State private showSortMenu: boolean = false;
  @State private refreshing: boolean = false;
  @State private loading: boolean = true;
  /** 首页行偏好副本（「显示在首页」开关要在菜单里读它） */
  @State private homeRows: HomeRowPref[] = [];
  /** 正在编辑的收录条件（非空 = 页头切成条件编辑器，对应 iOS 的 `editing`） */
  @State private editingFilter: LibraryFilter | null = null;
  @State private showRename: boolean = false;
  @State private renameText: string = '';
  @State private showShare: boolean = false;
  @State private shareView: ShareView | null = null;
  @State private shareBusy: boolean = false;
  @State private showOrdering: boolean = false;
  @State private orderingItems: LibraryItemView[] = [];
  @State private orderingBusy: boolean = false;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 取数

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = true;
    try {
      const view: CollectionView = await api.collectionGet(this.collectionId);
      this.collection = view;
      this.failed = false;
      this.errorMessage = '';
      // 默认档用合集自己的序（对应 iOS 的 kind === 'series' ? 系列序 : 自定顺序）
      if (this.sort === 'default') {
        this.sort = view.kind === 'series' ? 'release_date' : 'default';
      }
      await this.loadHomePrefs();
      await this.reloadItems();
    } catch (error) {
      if (this.collection === null) {
        this.failed = true;
        this.errorMessage = this.messageOf(error);
      }
    } finally {
      this.loading = false;
    }
  }

  private async reloadItems(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.items = [];
    this.reachedEnd = false;
    await this.loadPage(0);
  }

  /** 拉一页（对应 iOS 海报墙的分页） */
  private async loadPage(offset: number): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    try {
      const page: LibraryItemView[] =
        await api.collectionItemsList(this.collectionId, PAGE_SIZE, offset, this.effectiveSort());
      if (offset === 0) {
        this.items = page;
      } else {
        for (const item of page) {
          this.items.push(item);
        }
      }
      this.wallSource.setItems(this.items, this.columns);
      if (page.length < PAGE_SIZE) {
        this.reachedEnd = true;
      }
    } catch (error) {
      this.reachedEnd = true;
    } finally {
      this.loadingMore = false;
    }
  }

  /** 排序参数：`default`（合集自己的序）不传 sort，交给后端 */
  private effectiveSort(): string | undefined {
    // **必须不传，不能传空串**：空串会被后端当成一个未知排序字段，整个名单返回空
    // （实测合集「N 部」却一面墙全空）。
    return this.sort === 'default' ? undefined : this.sort;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  /** 首页行偏好副本所属账号（服务器 + 用户名）的 key */
  private homeOwnerKey(): string {
    const client = AppModel.shared.client;
    const session = AppModel.shared.session;
    return LibraryHomePrefs.ownerKey(client !== null ? client.origin : '',
      session === null ? null : session.username);
  }

  /** 拉一次首页行偏好（菜单里「显示在首页 / 从首页移除」要读它） */
  private async loadHomePrefs(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    await LibraryHomePrefs.shared.ensureLoaded(api, this.homeOwnerKey());
    this.homeRows = LibraryHomePrefs.shared.rows ?? [];
  }

  // MARK: 权限与派生（对应 iOS 的 manageable / editable / canManageLibraries）

  private canManageLibraries(): boolean {
    return Permissions.fromSession(AppModel.shared.session).canManageLibraries;
  }

  /** 能改名 / 隐藏 / 删除（超管，或成员自己的合集） */
  private canRename(): boolean {
    return this.collection !== null && this.collection.manageable;
  }

  /** 改条件：本库视图里、用户自建、规则驱动 */
  private canEditRules(): boolean {
    const view: CollectionView | null = this.collection;
    return view !== null && this.fallbackLibraryId > 0 && view.editable && view.rule_driven;
  }

  /** 整理顺序：用户自建且名单驱动 */
  private canOrder(): boolean {
    const view: CollectionView | null = this.collection;
    return view !== null && view.editable && !view.rule_driven;
  }

  private isHidden(): boolean {
    return this.collection !== null && this.collection.hidden === true;
  }

  /** 这个合集是不是自动生成的（自动生成的删不掉，只能隐藏） */
  private isAutomatic(): boolean {
    const view: CollectionView | null = this.collection;
    return view !== null && view.kind !== 'user';
  }

  private removeLabel(): string {
    return this.isAutomatic() ? '隐藏这个合集' : '删除合集';
  }

  /** 已经在首页的哪一行（对应 iOS `homeRow`） */
  private homeRow(): HomeRowPref | null {
    const view: CollectionView | null = this.collection;
    if (view === null) {
      return null;
    }
    for (const row of this.homeRows) {
      if (row.collection_id === view.id) {
        return row;
      }
    }
    return null;
  }

  private onHome(): boolean {
    const row: HomeRowPref | null = this.homeRow();
    return row !== null && row.hidden !== true;
  }

  // MARK: 派生

  private sortLabel(): string {
    if (this.sort === 'default') {
      return this.collection !== null && this.collection.kind === 'series' ? '按上映顺序' : '自定顺序';
    }
    for (const option of this.sortOptions()) {
      if (option.value === this.sort) {
        return option.label;
      }
    }
    return this.sort;
  }

  private sortOptions(): SortOption[] {
    return [
      new SortOption('default', this.collection !== null && this.collection.kind === 'series' ? '按上映顺序' : '自定顺序'),
      new SortOption('release_date', '按上映时间'),
      new SortOption('title', '按标题'),
      new SortOption('added_at', '最近添加'),
      new SortOption('rating', '按评分')
    ];
  }

  /** 可见性（对应 iOS 页头的「只有我可见 / 已隐藏」） */
  private visibilityText(): string {
    const view: CollectionView | null = this.collection;
    if (view === null) {
      return '';
    }
    const parts: string[] = [];
    if (view.hidden) {
      parts.push('已隐藏');
    }
    if (view.visibility === 'private') {
      parts.push('只有我可见');
    }
    return parts.join('  ·  ');
  }

  /** 这个合集怎么来的（对应 iOS 页头那行说明） */
  private originText(): string {
    const view: CollectionView | null = this.collection;
    if (view === null) {
      return '';
    }
    if (view.rule_driven) {
      return '✦ 自动收录 · 按条件自动归集';
    }
    if (view.kind === 'series') {
      return '系列合集 · 按作品系列归集';
    }
    return '固定名单 · 手动挑进来的';
  }

  // MARK: 动作

  private openItem(item: LibraryItemView): void {
    const libraryId: number = item.library_id ?? this.fallbackLibraryId;
    this.navStack.pushPathByName('libraryItem', new ItemRouteParams(libraryId, item.media_item_id));
  }

  private pickSort(value: string): void {
    if (value === this.sort) {
      return;
    }
    this.sort = value;
    this.showSortMenu = false;
    this.reloadItems();
  }

  // MARK: ⋯ 菜单的动作（对应 iOS CollectionDetailView 的 rename/openShare/openOrdering/toggleOnHome/remove/unhide）

  private openRename(): void {
    const view: CollectionView | null = this.collection;
    if (view === null) {
      return;
    }
    this.renameText = view.name;
    this.showRename = true;
  }

  private async saveRename(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: CollectionView | null = this.collection;
    if (api === null || view === null) {
      return;
    }
    const name: string = this.renameText.trim();
    if (name.length === 0 || name === view.name) {
      this.showRename = false;
      return;
    }
    try {
      const payload: CollectionPayload = { name: name };
      this.collection = await api.collectionUpdate(view.id, payload);
      this.showRename = false;
      this.toast('已改名');
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  private async openShare(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: CollectionView | null = this.collection;
    if (api === null || view === null) {
      return;
    }
    this.showShare = true;
    this.shareBusy = true;
    try {
      this.shareView = await api.collectionShareGet(view.id);
    } catch (error) {
      // 拿不到就当没建过，用户还能新建
      this.shareView = null;
    } finally {
      this.shareBusy = false;
    }
  }

  private async createShare(days: number, password: string): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: CollectionView | null = this.collection;
    if (api === null || view === null) {
      return;
    }
    this.shareBusy = true;
    try {
      const payload: ShareCreateRequest = {
        expires_in_days: days > 0 ? days : null,
        password: password.length > 0 ? password : null
      };
      this.shareView = await api.collectionShareCreate(view.id, payload);
      this.toast('链接已生成');
    } catch (error) {
      this.toast(shareMessage(error));
    } finally {
      this.shareBusy = false;
    }
  }

  private async revokeShare(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: CollectionView | null = this.collection;
    if (api === null || view === null) {
      return;
    }
    this.shareBusy = true;
    try {
      await api.collectionShareRevoke(view.id);
      this.shareView = null;
      this.toast('已停止分享');
    } catch (error) {
      this.toast(shareMessage(error));
    } finally {
      this.shareBusy = false;
    }
  }

  /** 自定顺序下直接用墙上的名单；换了别的排序时先按自定顺序取一份（同 iOS openOrdering） */
  private async openOrdering(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: CollectionView | null = this.collection;
    if (api === null || view === null) {
      return;
    }
    if (this.sort === 'default') {
      this.orderingItems = this.items.slice();
      this.showOrdering = true;
      return;
    }
    this.orderingBusy = true;
    try {
      this.orderingItems = await api.collectionItemsList(view.id, 60);
      this.showOrdering = true;
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.orderingBusy = false;
    }
  }

  private moveOrdering(from: number, to: number): void {
    if (to < 0 || to >= this.orderingItems.length || from === to) {
      return;
    }
    const next: LibraryItemView[] = this.orderingItems.slice();
    const row: LibraryItemView = next[from];
    next.splice(from, 1);
    next.splice(to, 0, row);
    this.orderingItems = next;
  }

  private async dropOrdering(item: LibraryItemView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: CollectionView | null = this.collection;
    if (api === null || view === null || this.orderingBusy) {
      return;
    }
    this.orderingBusy = true;
    try {
      await api.collectionItemsRemove(view.id, item.media_item_id);
      this.orderingItems = this.orderingItems.filter((row: LibraryItemView): boolean =>
        row.media_item_id !== item.media_item_id);
      this.membersChanged();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.orderingBusy = false;
    }
  }

  private async saveOrdering(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: CollectionView | null = this.collection;
    if (api === null || view === null || this.orderingBusy || this.orderingItems.length === 0) {
      return;
    }
    this.orderingBusy = true;
    try {
      const ids: number[] = this.orderingItems.map((row: LibraryItemView): number => row.media_item_id);
      await api.collectionItemsReorder(view.id, { media_item_ids: ids });
      this.toast('顺序已保存');
      this.showOrdering = false;
      this.membersChanged();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.orderingBusy = false;
    }
  }

  /**
   * 「显示在首页」：把这个合集加成首页的一行；再点一次是隐藏那一行，不删（与自定义页同一份偏好）。
   * 对应 iOS `toggleOnHome`：偏好没读到就先强制重拉，避免以空清单为底整份保存覆盖用户自定义的行。
   */
  private async toggleOnHome(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const client = AppModel.shared.client;
    const view: CollectionView | null = this.collection;
    if (api === null || client === null || view === null) {
      return;
    }
    const key: string = this.homeOwnerKey();
    const prefs: LibraryHomePrefs = LibraryHomePrefs.shared;
    prefs.adopt(key);
    if (prefs.rows === null) {
      try {
        const fetched: UiPreferencesSetting = await api.uiPrefsShow();
        prefs.accept(fetched.home.rows, key);
      } catch (error) {
        this.toast('保存失败');
        return;
      }
    }
    const wasOnHome: boolean = this.onHome();
    const current: HomeRowPref[] = prefs.rows ?? [];
    const next: HomeRowPrefInput[] = [];
    let found: boolean = false;
    for (const row of current) {
      const isThis: boolean = row.collection_id === view.id;
      if (isThis) {
        found = true;
      }
      const input: HomeRowPrefInput = {
        id: row.id,
        sort: row.sort ?? null,
        order: row.order ?? null,
        name: row.name ?? null,
        unwatched: row.unwatched ?? null,
        hidden: isThis ? (wasOnHome ? true : null) : (row.hidden ?? null),
        library_id: row.library_id ?? null,
        collection_id: row.collection_id ?? null
      };
      next.push(input);
    }
    if (!found) {
      const added: HomeRowPrefInput = {
        id: randomRowId(),
        sort: null,
        order: null,
        name: null,
        unwatched: null,
        hidden: null,
        library_id: null,
        collection_id: view.id
      };
      next.push(added);
    }
    try {
      // `PUT /ui/preferences` 是整体覆盖：其余偏好要原样带回（同自定义页 save）
      const full: UiPreferencesSetting = await api.uiPrefsShow();
      const body: Record<string, Object> = {};
      body['theme'] = full.theme;
      body['theme_desktop'] = full.theme_desktop ?? '';
      body['theme_mobile'] = full.theme_mobile ?? '';
      body['sidebar'] = full.sidebar;
      body['scrim'] = full.scrim;
      body['nav'] = full.nav;
      body['home'] = new HomePrefsInput(next);
      const updated: UiPreferencesSetting =
        await client.put<UiPreferencesSetting>('/ui/preferences', JSON.stringify(body));
      const rows: HomeRowPref[] = updated.home.rows ?? [];
      prefs.rows = rows;
      this.homeRows = rows;
      LibraryHomePrefsHolder.publish(rows);
      this.toast(wasOnHome
        ? '已从首页移除，媒体库卡片和播放器入口也会一并移除'
        : '已显示在首页，媒体库卡片和播放器入口同步显示');
    } catch (error) {
      this.toast('保存失败');
    }
  }

  private removeCollection(): void {
    const view: CollectionView | null = this.collection;
    if (view === null) {
      return;
    }
    const automatic: boolean = this.isAutomatic();
    this.getUIContext().showAlertDialog({
      title: automatic ? `隐藏「${view.name}」？` : `删除合集「${view.name}」？`,
      message: automatic
        ? '自动生成的合集会一直重新出现，所以这里是把它藏起来：影片一部都不会少，想找回来在媒体库设置里打开「显示已隐藏的合集」。'
        : '只删掉这层视图，里面的影片一部都不会少。',
      primaryButton: {
        value: '再想想',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: automatic ? '隐藏' : '删除',
        action: (): void => {
          this.performRemove(automatic);
        }
      }
    });
  }

  private async performRemove(automatic: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: CollectionView | null = this.collection;
    if (api === null || view === null) {
      return;
    }
    try {
      await api.collectionDelete(view.id);
      this.toast(automatic ? '已隐藏' : '已删除');
      this.navStack.pop();
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  private async unhideCollection(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: CollectionView | null = this.collection;
    if (api === null || view === null) {
      return;
    }
    try {
      const payload: CollectionPayload = { hidden: false };
      this.collection = await api.collectionUpdate(view.id, payload);
      this.toast('已恢复显示');
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  // MARK: 改条件（页头切成条件编辑器）

  private startEditRules(): void {
    const view: CollectionView | null = this.collection;
    if (view === null) {
      return;
    }
    this.editingFilter = LibraryFilter.fromRules(view.rules);
  }

  private editingFilterOrEmpty(): LibraryFilter {
    const filter: LibraryFilter | null = this.editingFilter;
    return filter !== null ? filter : new LibraryFilter();
  }

  private toggleRule(dim: string, value: string): void {
    const next: LibraryFilter = this.editingFilterOrEmpty().clone();
    next.toggle(dim, value);
    this.editingFilter = next;
  }

  private removeRule(dim: string, value: string): void {
    const next: LibraryFilter = this.editingFilterOrEmpty().clone();
    next.remove(dim, value);
    this.editingFilter = next;
  }

  private clearRules(): void {
    this.editingFilter = new LibraryFilter();
  }

  private async saveRules(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: CollectionView | null = this.collection;
    const filter: LibraryFilter | null = this.editingFilter;
    if (api === null || view === null || filter === null) {
      return;
    }
    try {
      const payload: CollectionPayload = { rules: filter.rules() };
      this.collection = await api.collectionUpdate(view.id, payload);
      this.editingFilter = null;
      this.membersChanged();
      this.toast('条件已保存');
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  /** 名单变了：重拉条目并把合集详情对账一遍（同 iOS membersChanged） */
  private membersChanged(): void {
    this.reloadItems();
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    api.collectionGet(this.collectionId).then((view: CollectionView): void => {
      this.collection = view;
    }).catch((): void => {
    });
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        this.TopBar()
        if (this.failed) {
          this.ErrorState()
        } else if (this.collection === null && this.loading) {
          this.LoadingState()
        } else {
          this.Content()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    // iOS `.navigationTitle(collection?.name ?? "合集")` inline：原生标题栏，返回按钮系统自带
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: CollectionRouteParams | null =
        CollectionRouteParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.collectionId = params.collectionId;
        this.fallbackLibraryId = params.libraryId;
        this.load();
      }
    })
  }

  /** 顶栏：返回 + 名称 + ⋯ 管理菜单（对应 iOS 的 toolbar 菜单） */
  @Builder
  TopBar() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([Theme.text])
        .width(38)
        .height(38)
        .onClick(() => {
          this.navStack.pop();
        })
      Text(this.collection !== null ? this.collection.name : '合集')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.more'))
        .fontSize(22)
        .fontColor([Theme.text])
        .width(38)
        .height(38)
        .bindMenu(this.ActionsMenu(), { showInSubWindow: false })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: Theme.statusBarInset + 6, bottom: 6 })
    .bindSheet($$this.showRename, this.RenameSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /**
   * ⋯ 菜单内容（对应 iOS `menu(_:)`）。权限口径同 iOS：
   * manageable 才给改名/隐藏/删除；canManageLibraries 才给分享；改条件限「本库视图 + 用户自建 + 规则驱动」；
   * 整理顺序限「用户自建 + 名单驱动」。
   */
  @Builder
  ActionsMenu() {
    Menu() {
      if (this.canRename()) {
        MenuItem({ content: '改名' })
          .onClick(() => {
            this.openRename();
          })
      }
      if (this.canManageLibraries()) {
        MenuItem({ content: '分享…' })
          .onClick(() => {
            this.openShare();
          })
      }
      if (this.canEditRules()) {
        MenuItem({ content: '改条件…' })
          .onClick(() => {
            this.startEditRules();
          })
      }
      if (this.canOrder()) {
        MenuItem({ content: '整理顺序…' })
          .onClick(() => {
            this.openOrdering();
          })
      }
      MenuItem({ content: this.onHome() ? '从首页移除' : '显示在首页' })
        .onClick(() => {
          this.toggleOnHome();
        })
      if (this.canRename()) {
        if (this.isHidden()) {
          MenuItem({ content: '恢复显示' })
            .onClick(() => {
              this.unhideCollection();
            })
        } else {
          MenuItem({ content: this.removeLabel() })
            .contentFontColor(this.isAutomatic() ? Theme.text : Theme.danger)
            .onClick(() => {
              this.removeCollection();
            })
        }
      }
    }
  }

  /** 改名弹层（对应 iOS `feedback.prompt("合集名", initial:)`） */
  @Builder
  RenameSheet() {
    Column({ space: 14 }) {
      Text('改名')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16 })
      TextInput({ text: this.renameText, placeholder: '合集名' })
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onChange((value: string): void => {
          this.renameText = value;
        })
      Row({ space: 10 }) {
        Text('取消')
          .fontSize(16)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick(() => {
            this.showRename = false;
          })
        Text('保存')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.accent)
          .borderRadius(Theme.cardRadius)
          .onClick(() => {
            this.saveRename();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
    .backgroundColor(Theme.bg)
  }

  /** 分享弹层：复用条目分享面板，改一句合集的说法（同 iOS 一个弹层两种目标） */
  @Builder
  ShareSheetContent() {
    Column({ space: 12 }) {
      Text('分享')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16 })
      SharePanel({
        share: this.shareView,
        busy: this.shareBusy,
        intro: '生成一条公开链接，拿到链接的人不用登录就能看这个合集，还能逐部点开。',
        onCreate: (days: number, password: string): void => {
          this.createShare(days, password);
        },
        onRevoke: (): void => {
          this.revokeShare();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 整理顺序弹层（对应 iOS `CollectionOrderSheet`）：上下移 + ✕ 移出，保存覆盖名单 */
  @Builder
  OrderingSheet() {
    Column({ space: 0 }) {
      Row() {
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .padding(10)
          .onClick(() => {
            this.showOrdering = false;
          })
        Blank()
        Text('整理顺序')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Blank()
        Text('保存')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.orderingBusy ? Theme.textFaint : Theme.accentStrong)
          .padding(10)
          .onClick(() => {
            this.saveOrdering();
          })
      }
      .width('100%')
      .padding({ left: 6, right: 6, top: 6, bottom: 6 })
      Text('调整先后；顺序在网页、播放器和分享页三处一致。移出去只是从名单里去掉，影片一部都不会少。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
      if (this.orderingItems.length === 0) {
        Text('这个合集现在一部都没有。')
          .fontSize(14)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 16, top: 20 })
      } else {
        List({ space: 0 }) {
          ForEach(this.orderingItems, (item: LibraryItemView, index: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(`${index + 1}`)
                  .fontSize(13)
                  .fontColor(Theme.textFaint)
                  .width(24)
                  .textAlign(TextAlign.End)
                Column({ space: 2 }) {
                  Text(item.title)
                    .fontSize(15)
                    .fontColor(Theme.text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.year !== null && (item.year ?? 0) > 0 ? `${item.year}` : '')
                    .fontSize(12)
                    .fontColor(Theme.textFaint)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                SymbolGlyph($r('sys.symbol.arrow_up'))
                  .fontSize(16)
                  .fontColor([index === 0 ? Theme.textFaint : Theme.textMuted])
                  .width(32)
                  .height(32)
                  .onClick(() => {
                    this.moveOrdering(index, index - 1);
                  })
                SymbolGlyph($r('sys.symbol.arrow_down'))
                  .fontSize(16)
                  .fontColor([index === this.orderingItems.length - 1 ? Theme.textFaint : Theme.textMuted])
                  .width(32)
                  .height(32)
                  .onClick(() => {
                    this.moveOrdering(index, index + 1);
                  })
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(15)
                  .fontColor([Theme.danger])
                  .width(32)
                  .height(32)
                  .onClick(() => {
                    this.dropOrdering(item);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            }
          }, (item: LibraryItemView) => `${item.media_item_id}`)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(26)
        .height(26)
        .color(Theme.textMuted)
      Text('正在加载合集…')
        .fontSize(14)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 12 }) {
      Text('合集加载失败')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(this.errorMessage)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Text('重试')
        .fontSize(14)
        .fontWeight(600)
        .fontColor(Theme.accentStrong)
        .padding({ left: 20, right: 20, top: 9, bottom: 9 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(18)
        .border({ width: 1, color: Theme.lineStrong })
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  Content() {
    Refresh({ refreshing: $$this.refreshing }) {
      List() {
        ListItem() {
          this.Header()
        }
        .bindSheet($$this.showShare, this.ShareSheetContent(), {
          height: SheetSize.MEDIUM,
          dragBar: true,
          showClose: false,
          backgroundColor: Theme.bg
        })
        ListItem() {
          if (this.editingFilter !== null) {
            this.RulesEditor()
          } else {
            this.SortBar()
          }
        }
        if (this.items.length === 0) {
          ListItem() {
            Column({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.rectangle_stack'))
                .fontSize(30)
                .fontColor([Theme.textFaint])
              Text('这个合集还是空的')
                .fontSize(16)
                .fontWeight(600)
                .fontColor(Theme.text)
              Text('从媒体库里挑几部加进来，或按条件自动收录。')
                .fontSize(13)
                .fontColor(Theme.textMuted)
            }
            .width('100%')
            .padding({ top: 60 })
          }
        } else {
          // 海报墙：按 2 列切行，每行一个 ListItem，LazyForEach 只建可视区附近的行
          LazyForEach(this.wallSource, (row: LibraryItemView[]) => {
            ListItem() {
              this.WallRow(row)
            }
          }, (row: LibraryItemView[]) => row.map((item: LibraryItemView): string => `${item.media_item_id}`).join('-'))
        }
        // 页脚：品牌联合声明，复用全局 AppFooter（包在 ListItem 里跟随滚动）
        ListItem() {
          AppFooter({ topSpace: 0 })
        }
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.None)
      .cachedCount(4)
      .padding({ bottom: Theme.tabBarInset })
      .bindSheet($$this.showOrdering, this.OrderingSheet(), {
        height: SheetSize.LARGE,
        dragBar: true,
        showClose: false,
        backgroundColor: Theme.bg
      })
      // 滚到底自动续下一页（对应 iOS 海报墙的翻页）
      .onReachEnd(() => {
        if (!this.reachedEnd && !this.loadingMore) {
          this.loadPage(this.items.length);
        }
      })
    }
    .onRefreshing(() => {
      this.load().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .height('100%')
  }

  /** 页头：名称 + 部数 + 可见性 + 来历（对应 iOS 的页头） */
  @Builder
  Header() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.collection !== null ? this.collection.name : '')
          .fontFamily('serif')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      Text(this.headerStats())
        .fontSize(14)
        .fontColor(Theme.textMuted)
      Text(this.originText())
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 6, bottom: 12 })
  }

  /** 「N 部」+ 可见性（对应 iOS 的「已有 N / 共 M」+ 可见性） */
  private headerStats(): string {
    const view: CollectionView | null = this.collection;
    if (view === null) {
      return '';
    }
    const parts: string[] = [`${view.item_count} 部`];
    const visibility: string = this.visibilityText();
    if (visibility.length > 0) {
      parts.push(visibility);
    }
    return parts.join('  ·  ');
  }

  /** 排序条：一枚玻璃胶囊，点开选档（对应 iOS 的排序胶囊） */
  @Builder
  SortBar() {
    Row({ space: 8 }) {
      Row({ space: 5 }) {
        Text(this.sortLabel())
          .fontSize(13)
          .fontColor(Theme.text)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(11)
          .fontColor([Theme.textMuted])
      }
      .padding({ left: 13, right: 13, top: 7, bottom: 7 })
      .backgroundColor(Theme.glassFill)
      .borderRadius(16)
      .border({ width: 1, color: Theme.line })
      .onClick(() => {
        this.showSortMenu = true;
      })
      Blank()
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 8 })
    .bindMenu(this.SortMenu(), { showInSubWindow: false })
    .bindSheet($$this.showSortMenu, this.SortSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 排序菜单（长按/右键路径；主入口是下面的弹层） */
  @Builder
  SortMenu() {
    Menu() {
      ForEach(this.sortOptions(), (option: SortOption) => {
        MenuItem({ content: option.label })
          .onClick(() => {
            this.pickSort(option.value);
          })
      }, (option: SortOption) => option.value)
    }
  }

  /** 排序弹层 */
  @Builder
  SortSheet() {
    Column({ space: 0 }) {
      Text('排序')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16, bottom: 10 })
      ForEach(this.sortOptions(), (option: SortOption) => {
        Row({ space: 10 }) {
          Text(option.label)
            .fontSize(16)
            .fontColor(Theme.text)
            .layoutWeight(1)
          if (option.value === this.sort) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([Theme.accent])
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 13, bottom: 13 })
        .onClick(() => {
          this.pickSort(option.value);
        })
      }, (option: SortOption) => option.value)
    }
    .width('100%')
    .padding({ bottom: 20 })
  }

  /**
   * 收录条件编辑器（对应 iOS `rulesEditor`）：编辑中的合集在页头位置换成筛选条 + 保存/取消，
   * 与单库墙共用同一个 `LibraryFilterBar` 组件（条件本体由本页持有，改动回调整体替换）。
   */
  @Builder
  RulesEditor() {
    Column({ space: 12 }) {
      LibraryFilterBar({
        libraryId: this.fallbackLibraryId,
        filter: this.editingFilterOrEmpty(),
        collections: [],
        onToggle: (dim: string, value: string): void => {
          this.toggleRule(dim, value);
        },
        onRemove: (dim: string, value: string): void => {
          this.removeRule(dim, value);
        },
        onClear: (): void => {
          this.clearRules();
        }
      })
      Row({ space: 10 }) {
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 11, bottom: 11 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick(() => {
            this.editingFilter = null;
          })
        Text(this.editingFilterOrEmpty().isEmpty() ? '至少选一个条件' : '保存条件')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.editingFilterOrEmpty().isEmpty() ? Theme.textFaint : '#0b0d12')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 11, bottom: 11 })
          .backgroundColor(this.editingFilterOrEmpty().isEmpty() ? Theme.glassFill : Theme.accent)
          .borderRadius(Theme.cardRadius)
          .onClick(() => {
            if (!this.editingFilterOrEmpty().isEmpty()) {
              this.saveRules();
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 12 })
  }

  /** 一行几列：跟媒体库同一口径（2~4 列，按屏宽自适应；末行不满时补等宽空位） */
  private columns: number = Theme.posterColumns();

  @Builder
  WallRow(row: LibraryItemView[]) {
    Row({ space: 12 }) {
      ForEach(row, (item: LibraryItemView) => {
        this.WallCell(item)
      }, (item: LibraryItemView) => `${item.media_item_id}`)
      ForEach(this.emptySlots(row.length), (slot: number) => {
        Column().layoutWeight(1)
      }, (slot: number) => `slot-${slot}`)
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  @Builder
  WallCell(item: LibraryItemView) {
    Column({ space: 6 }) {
      RemoteImage({
        url: ImageUrls.resolve(AppModel.origin(), item.poster_url,
          ImageVariant.card(item.primary_aspect)) ?? ''
      })
        .width('100%')
        .aspectRatio(item.primary_aspect > 0 ? item.primary_aspect : Theme.posterAspect)
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .clip(true)
      Text(item.title)
        .fontSize(14)
        .fontWeight(600)
        .fontColor(Theme.text)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.cellSubtitle(item))
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .margin({ bottom: 18 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openItem(item);
    })
  }

  /** 补位序号（最后一行用） */
  private emptySlots(filled: number): number[] {
    const slots: number[] = [];
    for (let i: number = filled; i < this.columns; i++) {
      slots.push(i);
    }
    return slots;
  }

  private cellSubtitle(item: LibraryItemView): string {
    const parts: string[] = [];
    const year: number | null = item.year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    const rating: number | null = item.rating ?? null;
    if (rating !== null && rating > 0) {
      parts.push(`★ ${rating.toFixed(1)}`);
    }
    return parts.join('  ·  ');
  }
}
