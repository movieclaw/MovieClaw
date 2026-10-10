import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  CollectionView,
  HomeRowPref,
  HomeRowPrefInput,
  HomeUiPrefsInput,
  LibraryView,
  NavUiPrefsInput,
  ScrimUiPrefsInput,
  SidebarUiPrefsInput,
  UiPreferencesSetting,
  UiPreferencesSettingInput
} from '../api/Models';
import { HomeRow, HomeRows, LibraryRowKind, CollectionRowKind } from './HomeRows';

/** 一行在编辑态的样子：展示用 + 可编辑的偏好 */
class EditableRow {
  readonly row: HomeRow;
  readonly pref: HomeRowPref;

  constructor(row: HomeRow, pref: HomeRowPref) {
    this.row = row;
    this.pref = pref;
  }
}

/**
 * `HomeUiPrefsInput` **只有一个可选字段**，ArkTS 会把它的对象字面量判成
 * 「无类型字面量」（`arkts-no-untyped-obj-literals`），所以用类实现绕开。
 */
export class HomePrefsInput implements HomeUiPrefsInput {
  rows?: HomeRowPrefInput[] | null;

  constructor(rows: HomeRowPrefInput[]) {
    this.rows = rows;
  }
}

/** 添加一行时可选的两组来源 */
class AddGroup {
  readonly title: string;
  readonly libraries: LibraryView[];
  readonly collections: CollectionView[];

  constructor(title: string, libraries: LibraryView[], collections: CollectionView[]) {
    this.title = title;
    this.libraries = libraries;
    this.collections = collections;
  }
}

/**
 * 自定义首页（对应 iOS `LibraryCustomizeView` / Web `library-customize-view`）。
 *
 * iOS 把这件事组织成**「编辑列表」**（不照搬 Web 的原地展开）：
 * - **主清单只做两件事**：行首圆圈显隐、排序；每行下面一行小字说清来源与排序；
 * - **添加一行**：左上 ＋ 打开来源选择（媒体库 / 合集），选中即加到末尾；
 * - **恢复默认**：红字放在清单最底部，二次确认；
 * - **保存**：每次改动先落本地草稿，**400ms 防抖后整份 PUT `/ui/preferences`**
 *   （后端是整体覆盖，所以要带上主题、侧栏等其余偏好原值），成功后写回本地缓存，关掉即生效。
 *
 * **与 iOS 的差异**：iOS 用拖拽把手排序，这里用「上移 / 下移」两个按钮——
 * ArkUI 的 `List.onMove` 要先进编辑态，为一个次要交互改整页结构不划算；
 * iOS 自己也承认「手机上没有拖拽」时改走按钮面板（见 `LibraryManageView` 的「调整顺序」）。
 */
@ComponentV2
export struct LibraryCustomizeSheet {
  @Require @Param onClose: () => void;

  @Local private rows: EditableRow[] = [];
  @Local private libraries: LibraryView[] = [];
  @Local private collections: CollectionView[] = [];
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private saving: boolean = false;
  @Local private savedHint: string = '';
  @Local private showAdd: boolean = false;

  /** 整份偏好（PUT 是整体覆盖，其余字段要原样带回） */
  private fullPrefs: UiPreferencesSetting | null = null;
  private saveTimer: number = -1;
  private started: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    if (this.saveTimer >= 0) {
      clearInterval(this.saveTimer);
      this.saveTimer = -1;
    }
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // MARK: 取数

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = true;
    try {
      const prefs: UiPreferencesSetting = await api.uiPrefsShow();
      this.fullPrefs = prefs;
      const libs: LibraryView[] = await api.libraryList();
      const cols: CollectionView[] = await api.collectionList(undefined, undefined, true);
      this.libraries = libs;
      this.collections = cols;
      this.rebuild(prefs.home.rows ?? []);
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  /** 用偏好 + 库/合集清单算出可编辑的行列表（同首页那套 `HomeRows.build`） */
  private rebuild(prefs: HomeRowPref[]): void {
    const built: HomeRow[] = HomeRows.build(prefs, this.libraries, this.collections);
    const out: EditableRow[] = [];
    for (const row of built) {
      out.push(new EditableRow(row, this.prefOf(prefs, row.id)));
    }
    this.rows = out;
  }

  private prefOf(prefs: HomeRowPref[], id: string): HomeRowPref {
    for (const pref of prefs) {
      if (pref.id === id) {
        return pref;
      }
    }
    const fresh: HomeRowPref = { id: id, sort: null, order: null, name: null,
      unwatched: null, hidden: null, library_id: null, collection_id: null };
    return fresh;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 保存

  private currentPrefs(): HomeRowPrefInput[] {
    const out: HomeRowPrefInput[] = [];
    for (const item of this.rows) {
      const pref: HomeRowPrefInput = {
        id: item.pref.id,
        sort: item.pref.sort ?? null,
        order: item.pref.order ?? null,
        name: item.pref.name ?? null,
        unwatched: item.pref.unwatched ?? null,
        hidden: item.pref.hidden ?? null,
        library_id: item.pref.library_id ?? null,
        collection_id: item.pref.collection_id ?? null
      };
      out.push(pref);
    }
    return out;
  }

  /** 改动即落草稿，400ms 防抖后整份提交（同 iOS） */
  private scheduleSave(): void {
    this.savedHint = '未保存';
    if (this.saveTimer >= 0) {
      clearInterval(this.saveTimer);
    }
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1;
      this.save();
    }, 400);
  }

  private async save(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const prefs: UiPreferencesSetting | null = this.fullPrefs;
    if (api === null || prefs === null || this.saving) {
      return;
    }
    this.saving = true;
    try {
      const home: HomeUiPrefsInput = new HomePrefsInput(this.currentPrefs());
      /*
       * 后端 `PUT /ui/preferences` 是**整体覆盖**（`UiPreferencesSetting` 的字段都有默认值，
       * 缺字段会被重置），所以其余偏好要原样带回。
       * 但不能把「视图类型」直接当「写入类型」用——ArkTS 禁结构化类型
       * （`arkts-no-structural-typing`）。于是用 `Record<string, Object>` 承载整份偏好再序列化，
       * 类型检查绕开，语义与 iOS 一致。
       */
      const body: Record<string, Object> = {};
      body['theme'] = prefs.theme;
      body['theme_desktop'] = prefs.theme_desktop ?? '';
      body['theme_mobile'] = prefs.theme_mobile ?? '';
      body['sidebar'] = prefs.sidebar;
      body['scrim'] = prefs.scrim;
      body['nav'] = prefs.nav;
      body['home'] = home;
      const client = AppModel.shared.client;
      if (client === null) {
        return;
      }
      const updated: UiPreferencesSetting = await client.put<UiPreferencesSetting>('/ui/preferences', JSON.stringify(body));
      this.fullPrefs = updated;
      this.savedHint = '已保存';
      // 写回本地缓存，关掉表单首页立即生效
      LibraryHomePrefsHolder.publish(updated.home.rows ?? []);
    } catch (error) {
      this.savedHint = '保存失败';
      this.toast(this.messageOf(error));
    } finally {
      this.saving = false;
    }
  }

  // MARK: 动作

  private toggleHidden(index: number): void {
    const item: EditableRow = this.rows[index];
    item.pref.hidden = !(item.pref.hidden ?? false);
    this.rows.splice(index, 1, new EditableRow(item.row, item.pref));
    this.scheduleSave();
  }

  private move(index: number, delta: number): void {
    const target: number = index + delta;
    if (target < 0 || target >= this.rows.length) {
      return;
    }
    const copy: EditableRow[] = this.rows.slice();
    const moved: EditableRow = copy.splice(index, 1)[0];
    copy.splice(target, 0, moved);
    this.rows = copy;
    this.scheduleSave();
  }

  /** 添加一行：内置行不会重复加，库行与合集行各限一条 */
  private addLibraryRow(library: LibraryView): void {
    const id: string = `lib:${library.id}`;
    for (const item of this.rows) {
      if (item.pref.id === id) {
        this.toast('这一行已经在首页上了');
        return;
      }
    }
    const pref: HomeRowPref = { id: id, sort: null, order: null, name: null,
      unwatched: null, hidden: null, library_id: library.id, collection_id: null };
    this.rows.push(new EditableRow(
      new HomeRow(id, false, new LibraryRowKind(library, '', false, false, '', false)), pref));
    this.showAdd = false;
    this.scheduleSave();
  }

  private addCollectionRow(collection: CollectionView): void {
    const id: string = `col:${collection.id}`;
    for (const item of this.rows) {
      if (item.pref.id === id) {
        this.toast('这一行已经在首页上了');
        return;
      }
    }
    const pref: HomeRowPref = { id: id, sort: null, order: null, name: null,
      unwatched: null, hidden: null, library_id: null, collection_id: collection.id };
    this.rows.push(new EditableRow(
      new HomeRow(id, false, new CollectionRowKind(collection, '', false, '')), pref));
    this.showAdd = false;
    this.scheduleSave();
  }

  /** 恢复默认：清空全部行偏好，回到服务端的推荐布局（二次确认） */
  private confirmRestore(): void {
    this.getUIContext().showAlertDialog({
      title: '恢复默认首页',
      message: '自己调过的显隐、顺序、名字与排序都会丢掉，回到推荐的布局。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '恢复默认',
        fontColor: Theme.danger,
        action: (): void => {
          this.rebuild([]);
          this.scheduleSave();
        }
      }
    });
  }

  /** 一行的小字：说清来源与排序（iOS：每行下面一行小字说清来源与排序） */
  private subtitleOf(item: EditableRow): string {
    const parts: string[] = [];
    const kind = item.row.kind;
    if (kind instanceof LibraryRowKind) {
      parts.push(kind.library.name);
      if (kind.sort.length > 0) {
        parts.push(HomeRows.preset(kind.sort).name(kind.library.name, kind.reversed));
      }
    } else if (kind instanceof CollectionRowKind) {
      parts.push('合集');
    } else {
      parts.push('内置');
    }
    if (item.pref.hidden === true) {
      parts.push('已隐藏');
    }
    return parts.join('  ·  ');
  }

  // MARK: 视图

  build() {
    Column() {
      this.SheetBar()
      if (this.loading) {
        this.LoadingState()
      } else if (this.errorMessage.length > 0) {
        this.ErrorState()
      } else {
        Scroll() {
          Column({ space: 14 }) {
            this.RowList()
            this.RestoreButton()
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 28 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    .bindSheet($$this.showAdd, this.AddPicker(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 顶栏（对应 iOS）：左上 ＋ 添加、居中标题、右上 ✓ 完成 */
  @Builder
  SheetBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(19)
        .fontColor([Theme.accentStrong])
        .width(40)
        .height(40)
        .onClick(() => {
          this.showAdd = true;
        })
      Blank()
      Column({ space: 1 }) {
        Text('自定义首页')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        if (this.savedHint.length > 0) {
          Text(this.savedHint)
            .fontSize(11)
            .fontColor(Theme.textFaint)
        }
      }
      Blank()
      Text('完成')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.accentStrong)
        .padding({ left: 8, right: 8 })
        .height(40)
        .onClick(() => {
          this.onClose();
        })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(26)
        .height(26)
        .color(Theme.textMuted)
      Text('正在加载首页布局…')
        .fontSize(14)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 10 }) {
      Text('加载失败')
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
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  /** 主清单：行首圆圈显隐 + 标题/小字 + 上移下移 */
  @Builder
  RowList() {
    Column() {
      ForEach(this.rows, (item: EditableRow, index: number) => {
        Column() {
          Row({ space: 12 }) {
            // 行首圆圈显隐（对应 iOS 的显隐圆圈）
            SymbolGlyph(item.pref.hidden === true
              ? $r('sys.symbol.circle') : $r('sys.symbol.checkmark_circle_fill'))
              .fontSize(22)
              .fontColor([item.pref.hidden === true ? Theme.textFaint : Theme.accent])
              .onClick(() => {
                this.toggleHidden(index);
              })
            Column({ space: 3 }) {
              Text(item.row.title())
                .fontSize(16)
                .fontColor(item.pref.hidden === true ? Theme.textFaint : Theme.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.subtitleOf(item))
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            // 排序：上移 / 下移（iOS 是拖拽把手，见类注释里的取舍）
            Column() {
              SymbolGlyph($r('sys.symbol.chevron_up'))
                .fontSize(15)
                .fontColor([index === 0 ? Theme.textFaint : Theme.textMuted])
                .width(32)
                .height(22)
                .onClick(() => {
                  this.move(index, -1);
                })
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(15)
                .fontColor([index === this.rows.length - 1 ? Theme.textFaint : Theme.textMuted])
                .width(32)
                .height(22)
                .onClick(() => {
                  this.move(index, 1);
                })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 10, top: 11, bottom: 11 })
          if (index < this.rows.length - 1) {
            Divider().color(Theme.line).margin({ left: 50, right: 16 })
          }
        }
        .width('100%')
      }, (item: EditableRow) => item.pref.id)
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 恢复默认：红字放清单最底部，二次确认（iOS 明确不占右上角） */
  @Builder
  RestoreButton() {
    Text('恢复默认布局')
      .fontSize(16)
      .fontColor(Theme.danger)
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
      .onClick(() => {
        this.confirmRestore();
      })
  }

  /** 添加一行：按来源分组（媒体库 / 合集） */
  @Builder
  AddPicker() {
    Column() {
      Text('添加一行')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16, bottom: 10 })
      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 8 }) {
            Text('按媒体库')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
            ForEach(this.libraries, (library: LibraryView) => {
              this.AddRow(`${library.name}`, `${library.stats.item_count} 部`, (): void => {
                this.addLibraryRow(library);
              })
            }, (library: LibraryView) => `lib-${library.id}`)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Column({ space: 8 }) {
            Text('按合集')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
            ForEach(this.collections, (collection: CollectionView) => {
              this.AddRow(`${collection.name}`, `${collection.item_count} 部`, (): void => {
                this.addCollectionRow(collection);
              })
            }, (collection: CollectionView) => `col-${collection.id}`)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  AddRow(title: string, subtitle: string, onTap: () => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(16)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(subtitle)
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(16)
        .fontColor([Theme.accent])
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .onClick(() => {
      onTap();
    })
  }
}

/**
 * 把保存后的行偏好写回首页的本地缓存。
 *
 * 单独抽出来是因为 `LibraryHomePrefs` 是 `@ObservedV2`，
 * 从弹层里直接改它会让「谁在什么时候改了全局状态」变得难追。
 */
export class LibraryHomePrefsHolder {
  private static publisher: ((rows: HomeRowPref[]) => void) | null = null;

  static register(publisher: (rows: HomeRowPref[]) => void): void {
    LibraryHomePrefsHolder.publisher = publisher;
  }

  static publish(rows: HomeRowPref[]): void {
    const publisher = LibraryHomePrefsHolder.publisher;
    if (publisher !== null) {
      publisher(rows);
    }
  }
}
