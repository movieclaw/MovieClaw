import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  TrashedBatchResultView,
  TrashedFileView,
  TrashedFilesData,
  TrashedItemRefView,
  TrashedItemView,
  TrashedPurgePayload,
  TrashedReasonCountView,
  TrashedRestorePayload
} from '../api/Models';
import { AppFooter } from '../common/AppFooter';

/**
 * 回收站条目的数据源（LazyForEach 用）。
 *
 * 原来整页 Scroll > Column 里一个圆角容器 ForEach(items) 全量建——回收站条目多时
 * 一次建出全部行。改成外层 List，条目行进一个 ListItemGroup（保留 insetGrouped 圆角容器
 * + 行间分隔线），LazyForEach 只建可视区附近的行。整批换 + onDataReloaded。
 */
class RecycleItemSource implements IDataSource {
  private items: TrashedItemView[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): TrashedItemView {
    return this.items[index];
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

  setItems(items: TrashedItemView[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/** 回收站页的路由参数（会序列化，不要用 instanceof） */
export class RecycleParams {
  /** 限定某个库（0 = 全部） */
  readonly libraryId: number;

  constructor(libraryId: number = 0) {
    this.libraryId = libraryId;
  }

  static of(param: Object | undefined | null): RecycleParams {
    if (param === undefined || param === null) {
      return new RecycleParams();
    }
    const raw: RecycleParams = param as RecycleParams;
    const id: number = raw.libraryId;
    return new RecycleParams(Number.isFinite(id) ? Math.floor(id) : 0);
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function RecycleBinBuilder() {
  RecycleBinPage()
}

/**
 * 回收站（对应 iOS `Features/Library/ManageRecycleBin.swift`）。
 *
 * 这里是**唯一会真正删文件**的地方，所以界面上的每个判断都围绕「别让人误删」：
 *
 * - **`purge_after` 必须显眼**：回收站里的文件到点会被**自动彻底删掉**，
 *   用户以为「反正在回收站里」而其实已经没了，是最糟的误解。所以每条都写清还剩多久。
 * - **`kept_in_place` 要说明**：这类文件**没有被移动**，只是从媒体库里摘掉了记录。
 *   把它们和「真的移到回收站」的混在一起说「已删除」，会让用户以为磁盘空间回来了。
 * - **彻底删除走二次确认并写清数量与体积**，而且文案里明说**不可撤销**。
 * - **恢复是安全的、删除不是**——所以恢复不需要确认，删除必须确认。
 */
@ComponentV2
export struct RecycleBinPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;

  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private data: TrashedFilesData | null = null;
  @Local private reason: string = '';
  @Local private busy: boolean = false;
  /** 展开的文件集合（按条目 key） */
  @Local private expanded: string[] = [];
  /** 选中的文件 id */
  @Local private picked: number[] = [];
  /** 条目行数据源（LazyForEach 只建可视区附近的行） */
  private itemSource: RecycleItemSource = new RecycleItemSource();

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = true;
    try {
      this.data = await api.libraryRecycleList(undefined,
        this.libraryId > 0 ? this.libraryId : undefined,
        this.reason.length > 0 ? this.reason : undefined);
      this.failed = false;
      // 数据换了，之前选中的 id 可能已经不在了——清掉，避免误操作一个看不见的东西
      this.picked = [];
      this.expanded = [];
      this.itemSource.setItems(this.items());
    } catch (error) {
      this.failed = true;
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  private libraryId: number = 0;

  private items(): TrashedItemView[] {
    const view: TrashedFilesData | null = this.data;
    return view !== null ? view.items : [];
  }

  private toggleExpand(key: string): void {
    if (this.expanded.includes(key)) {
      this.expanded = this.expanded.filter((k: string): boolean => k !== key);
    } else {
      this.expanded = this.expanded.concat([key]);
    }
  }

  private togglePick(id: number): void {
    if (this.picked.includes(id)) {
      this.picked = this.picked.filter((value: number): boolean => value !== id);
    } else {
      this.picked = this.picked.concat([id]);
    }
  }

  /** 全部文件的 id（用来「全选」） */
  private allFileIds(): number[] {
    const ids: number[] = [];
    for (const item of this.items()) {
      for (const file of item.files) {
        ids.push(file.id);
      }
    }
    return ids;
  }

  /** 选中文件的总字节数（确认框里要说清有多大） */
  private pickedBytes(): number {
    let total: number = 0;
    for (const item of this.items()) {
      for (const file of item.files) {
        if (this.picked.includes(file.id)) {
          total += file.size_bytes;
        }
      }
    }
    return total;
  }

  // MARK: 动作

  private async restore(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.picked.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const payload: TrashedRestorePayload = { ids: this.picked.slice() };
      const result: TrashedBatchResultView = await api.libraryRecycleRestore(payload);
      this.report(result, '恢复');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  private confirmPurge(): void {
    if (this.picked.length === 0 || this.busy) {
      return;
    }
    const count: number = this.picked.length;
    const size: string = Formatters.bytes(this.pickedBytes());
    this.getUIContext().showAlertDialog({
      title: '彻底删除',
      // 把「不可撤销 + 具体数量 + 具体体积」都写出来，这是唯一真正删文件的操作
      message: `把选中的 ${count} 个文件（${size}）从磁盘上彻底删除？\n\n`
        + '这一步不可撤销，文件不会进系统回收站，也没有第二次机会。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '彻底删除',
        action: (): void => {
          this.purge();
        }
      }
    });
  }

  private async purge(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.picked.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const payload: TrashedPurgePayload = { ids: this.picked.slice() };
      const result: TrashedBatchResultView = await api.libraryRecyclePurge(payload);
      this.report(result, '删除');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  /**
   * 批量操作的结果要**分开说**：`done` 成功几个、`failed` 失败几个、`remaining` 还剩几个。
   * 只说「完成」会掩盖「一部分失败了」——而用户以为都成功了就不会再去看。
   */
  private report(result: TrashedBatchResultView, verb: string): void {
    const failed: number = result.failed.length;
    if (failed === 0) {
      this.toast(`${verb}了 ${result.done} 个`);
      return;
    }
    this.getUIContext().showAlertDialog({
      title: `${verb}部分失败`,
      message: `成功 ${result.done} 个，失败 ${failed} 个，还剩 ${result.remaining} 个未处理。\n\n`
        + `第一个失败的原因：${result.failed[0].error}`,
      primaryButton: {
        value: '知道了',
        action: (): void => {
        }
      }
    });
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        PageTopBar({ title: '回收站', onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.failed) {
          this.ErrorState()
        } else if (this.loading && this.data === null) {
          this.LoadingState()
        } else {
          this.Body()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    // iOS .navigationTitle("回收站") + inline：NavDestination 原生标题栏，去掉自绘 TopBar
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      if (!this.started) {
        this.started = true;
        const params: RecycleParams = RecycleParams.of(ctx.pathInfo.param as Object | undefined);
        this.libraryId = params.libraryId;
        this.load();
      }
    })
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress().width(24).height(24).color(Theme.textMuted)
      Text('正在读回收站…').fontSize(13).fontColor(Theme.textFaint)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 10 }) {
      Text('回收站读取失败').fontSize(15).fontColor(Theme.text)
      Text(this.errorMessage).fontSize(13).fontColor(Theme.textMuted).textAlign(TextAlign.Center)
      Text('重试').fontSize(14).fontColor(Theme.accentStrong).onClick(() => {
        this.load();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  Body() {
    Column() {
      // Scroll > Column 全量建改成 List：条目行进 ListItemGroup（保留 insetGrouped 圆角容器
      // + 行间分隔线），LazyForEach 只建可视区附近的行。
      List({ space: 10 }) {
        ListItem() {
          this.Summary()
        }
        ListItem() {
          this.ReasonChips()
        }
        if (this.items().length === 0) {
          ListItem() {
            this.EmptyState()
          }
        } else {
          ListItemGroup() {
            LazyForEach(this.itemSource, (item: TrashedItemView, index: number) => {
              ListItem() {
                this.ItemCard(item)
                if (index < this.items().length - 1) {
                  Divider().color(Theme.line).margin({ left: 16, right: 16 })
                }
              }
            }, (item: TrashedItemView) => item.key)
          }
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
        }
        ListItem() {
          AppFooter()
        }
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .cachedCount(4)
      .width('100%')
      .alignListItem(ListItemAlign.Start)
      .padding({ left: 16, right: 16, top: 8, bottom: Theme.tabBarInset })
      // 有选中文件时底部恢复/彻底删除条固定在下面（危险操作逻辑原样保留）
      if (this.picked.length > 0) {
        this.ActionBar()
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 概览：多少个文件、多大、以及有多少是「留在原位」的 */
  @Builder
  Summary() {
    if (this.data !== null) {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(`${(this.data as TrashedFilesData).total_files} 个文件`)
            .fontSize(15)
            .fontColor(Theme.text)
          Text(`· ${Formatters.bytes((this.data as TrashedFilesData).total_bytes)}`)
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        if ((this.data as TrashedFilesData).kept_in_place > 0) {
          // 这类文件**没被移动**，说清「删除」在这里的含义，否则用户以为磁盘空间回来了
          Text(`其中 ${(this.data as TrashedFilesData).kept_in_place} 个「留在原位」：`
            + '只是从媒体库摘掉了记录，文件还在原目录，磁盘空间没有释放。')
            .fontSize(12)
            .fontColor(Theme.warn)
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 按原因筛选（换库 / 洗版 / 手动删除…） */
  @Builder
  ReasonChips() {
    if (this.data !== null && (this.data as TrashedFilesData).by_reason.length > 0) {
      Scroll() {
        Row({ space: 8 }) {
          Text('全部')
            .fontSize(13)
            .fontColor(this.reason.length === 0 ? '#0b0d12' : Theme.textMuted)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.reason.length === 0 ? Theme.accent : Theme.glassFill)
            .borderRadius(14)
            .onClick(() => {
              this.reason = '';
              this.load();
            })
          ForEach((this.data as TrashedFilesData).by_reason,
            (entry: TrashedReasonCountView) => {
              Text(`${entry.reason} ${entry.count}`)
                .fontSize(13)
                .fontColor(this.reason === entry.reason ? '#0b0d12' : Theme.textMuted)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.reason === entry.reason ? Theme.accent : Theme.glassFill)
                .borderRadius(14)
                .onClick(() => {
                  this.reason = entry.reason;
                  this.load();
                })
            }, (entry: TrashedReasonCountView) => entry.reason)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
  }

  @Builder
  EmptyState() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.externaldrive'))
        .fontSize(28)
        .fontColor([Theme.textFaint])
      Text(this.reason.length > 0 ? '这个原因下没有文件' : '回收站是空的')
        .fontSize(15)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .padding({ top: 80, bottom: 40 })
  }

  /** 一条 = 一个媒体条目下的若干文件 */
  @Builder
  ItemCard(item: TrashedItemView) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Column({ space: 3 }) {
          Text(item.media_item !== null && item.media_item !== undefined
            ? (item.media_item as TrashedItemRefView).title : item.key)
            .fontSize(15)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${item.library.name}  ·  ${item.file_count} 个文件  ·  ${Formatters.bytes(item.total_bytes)}`)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph(this.expanded.includes(item.key) ? $r('sys.symbol.chevron_up')
          : $r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .onClick(() => {
        this.toggleExpand(item.key);
      })

      // 自动清理倒计时：**这条最要紧**——用户以为「反正在回收站里」，其实到点就没了
      if (item.earliest_purge_after !== null && item.earliest_purge_after !== undefined
        && item.earliest_purge_after.length > 0) {
        Text(`最早 ${Formatters.relative(item.earliest_purge_after)} 一到就自动彻底删除`)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }
      if (item.note !== null && item.note !== undefined && item.note.length > 0) {
        Text(item.note).fontSize(12).fontColor(Theme.textMuted).width('100%')
      }

      if (this.expanded.includes(item.key)) {
        Column({ space: 0 }) {
          ForEach(item.files, (file: TrashedFileView, index: number) => {
            this.FileRow(file, index === item.files.length - 1)
          }, (file: TrashedFileView) => `f-${file.id}`)
        }
        .width('100%')
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
  }

  @Builder
  FileRow(file: TrashedFileView, isLast: boolean) {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        // 勾选：只在展开后出现，选中才会启用批量按钮
        SymbolGlyph(this.picked.includes(file.id) ? $r('sys.symbol.checkmark_circle_fill')
          : $r('sys.symbol.circle'))
          .fontSize(18)
          .fontColor([this.picked.includes(file.id) ? Theme.accent : Theme.textFaint])
          .onClick(() => {
            this.togglePick(file.id);
          })
        Column({ space: 3 }) {
          Text(file.file_name)
            .fontSize(13)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.fileMeta(file))
            .fontSize(11)
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        this.togglePick(file.id);
      })
      if (!isLast) {
        Divider().color(Theme.line).margin({ left: 40, right: 12 })
      }
    }
    .width('100%')
  }

  /** 一行说清：体积 · 画质 · 编码 · 留在原位与否 · 何时被删 */
  private fileMeta(file: TrashedFileView): string {
    const parts: string[] = [Formatters.bytes(file.size_bytes)];
    if (file.resolution !== null && file.resolution !== undefined && file.resolution.length > 0) {
      parts.push(file.resolution);
    }
    if (file.video_codec !== null && file.video_codec !== undefined && file.video_codec.length > 0) {
      parts.push(file.video_codec);
    }
    if (file.kept_in_place) {
      parts.push('留在原位');
    }
    const reason: string | null = file.reason ?? null;
    if (reason !== null && reason.length > 0) {
      parts.push(reason);
    }
    return parts.join('  ·  ');
  }

  /** 底部批量条：**恢复在前（安全）、彻底删除在后（危险）**，颜色也分开 */
  @Builder
  ActionBar() {
    Row({ space: 10 }) {
      Text(`已选 ${this.picked.length}`)
        .fontSize(13)
        .fontColor(Theme.textMuted)
      Blank()
      Text('全选')
        .fontSize(13)
        .fontColor(Theme.accentStrong)
        .onClick(() => {
          this.picked = this.allFileIds();
        })
      Text(this.busy ? '…' : '恢复')
        .fontSize(14)
        .fontColor('#0b0d12')
        .padding({ left: 16, right: 16, top: 9, bottom: 9 })
        .backgroundColor(this.busy ? Theme.glassFill : Theme.accent)
        .borderRadius(16)
        .onClick(() => {
          this.restore();
        })
      Text('彻底删除')
        .fontSize(14)
        .fontColor(Theme.danger)
        .padding({ left: 16, right: 16, top: 9, bottom: 9 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(16)
        .onClick(() => {
          this.confirmPurge();
        })
    }
    .width('100%')
    // 底部不滚动的批量条，要让开系统手势条，否则按钮被小白条压住
    .padding({ top: 8, bottom: 8 + Theme.safeBottomInset })
  }
}
