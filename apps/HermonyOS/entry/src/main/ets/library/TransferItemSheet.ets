import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  LibraryItemDetailView,
  LibraryView,
  TransferMoveView,
  TransferPayload,
  TransferPreviewView,
  TransferSkipView,
  TransferStatusView
} from '../api/Models';

/** 转移选项目标库的形态叫法（同 iOS `transferKindLabels`） */
const KIND_LABELS: Record<string, string> = {
  'movie': '电影',
  'tv': '剧集',
  'video': '其他',
  'photo': '图片'
};

/**
 * 「转移到其他媒体库…」弹层（对应 iOS `TransferItemSheet.swift` / Web
 * `TransferDialog` + `TransferPlanPreview` + `TransferResult`）。
 *
 * 分错库时的补救：把条目**磁盘上的目录**连同库存记录搬到另一个同类型库。
 * 界面上必须讲清的三件事（都在预览步骤里，与 Web 一致）：
 * 1. 搬的是磁盘目录，不是「从列表里挪一下」——源 / 目标路径并排列出；
 * 2. 跨盘要完整复制：耗时按体积走，且断开与做种目录的硬链接（占用翻倍），必须显式警示；
 * 3. 目标已有同名目录就不干（`blocked` 非空不给执行），绝不覆盖或合并。
 *
 * 流程：选目标库 → 立即只读预检 `transfer-preview` → 确认转移 `POST …/transfers`
 * → 每 1 秒轮询 `item-transfer-status` 直到结论页。进行中不给「取消」（搬到一半停不下来）。
 *
 * **本组件是 V1 `@Component`**（宿主 `LibraryItemDetailPage` 也是 V1）。
 */
@Component
export struct TransferItemSheet {
  @Prop libraryId: number = 0;
  @Prop mediaItemId: number = 0;
  @Prop title: string = '';
  /** 转移成功完成时回调：让调用方刷新 / 作废缓存（不做页面跳转） */
  onDone: () => void = (): void => {
  };
  onClose: () => void = (): void => {
  };

  /** 当前所在库；候选目标库与文案都按它的形态 × 来源决定 */
  @State private sourceLibrary: LibraryView | null = null;
  /** 取不到库时的兜底（条目自身的形态与来源） */
  private fallbackKind: string = '';
  private fallbackSource: string = '';
  /** 可选目标库：同类型、同来源、非当前库；null = 正在读取 */
  @State private candidates: LibraryView[] | null = null;
  @State private targetId: number = 0;
  @State private preview: TransferPreviewView | null = null;
  @State private loadingPreview: boolean = false;
  @State private errorMessage: string = '';
  /** 进行中 / 已完成的转移状态（轮询同一个接口一路走到结论） */
  @State private status: TransferStatusView | null = null;
  @State private starting: boolean = false;
  private notifiedDone: boolean = false;
  private pollTimer: number = -1;

  aboutToAppear(): void {
    this.loadCandidates();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 派生状态

  private running(): boolean {
    const state: TransferStatusView | null = this.status;
    return state !== null && state.running;
  }

  private busy(): boolean {
    return this.starting || this.running();
  }

  private finished(): boolean {
    const state: TransferStatusView | null = this.status;
    return state !== null && !state.running;
  }

  private canRun(): boolean {
    const view: TransferPreviewView | null = this.preview;
    if (view === null || this.busy()) {
      return false;
    }
    return view.blocked.length === 0 && view.moves.length > 0;
  }

  /** 一文件一条目的库（其他 / 图片）：搬的是文件本身，不是「条目目录」 */
  private fileEntries(): boolean {
    const lib: LibraryView | null = this.sourceLibrary;
    return lib !== null && !lib.capabilities.scraped;
  }

  private sourceKind(): string {
    const lib: LibraryView | null = this.sourceLibrary;
    return lib !== null ? lib.kind : this.fallbackKind;
  }

  private kindLabel(kind: string): string {
    const found: string | undefined = KIND_LABELS[kind];
    return found !== undefined ? found : '';
  }

  private progressSuffix(): string {
    const state: TransferStatusView | null = this.status;
    if (state === null || state.total <= 0) {
      return '';
    }
    return ` · ${state.processed}/${state.total}`;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '出错了，请稍后重试';
  }

  // MARK: 取数

  private async loadCandidates(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.candidates !== null) {
      return;
    }
    try {
      this.sourceLibrary = await api.libraryGet(this.libraryId);
    } catch (error) {
      this.sourceLibrary = null;
    }
    if (this.sourceLibrary === null) {
      try {
        const detail: LibraryItemDetailView = await api.libraryItemsGet(this.libraryId, this.mediaItemId);
        this.fallbackKind = detail.kind;
        this.fallbackSource = detail.source;
      } catch (error) {
        // 兜底也拿不到：下面按空形态查询，列表可能为空
      }
    }
    // 口径必须与后端 assert_transferable 一致：比的是**库**的来源，不是条目的来源
    const kind: string = this.sourceKind();
    const source: string = this.sourceLibrary !== null ? this.sourceLibrary.source : this.fallbackSource;
    try {
      const libs: LibraryView[] = await api.libraryList(kind, 'all');
      this.candidates = libs.filter((lib: LibraryView): boolean =>
        lib.id !== this.libraryId && lib.source === source);
    } catch (error) {
      this.errorMessage = '读取媒体库列表失败，请稍后重试';
    }
  }

  /** 选中目标库就立刻算预览：用户要先看清「搬到哪、搬多少」才谈得上确认 */
  private async loadPreview(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.targetId <= 0) {
      return;
    }
    this.loadingPreview = true;
    this.preview = null;
    this.errorMessage = '';
    try {
      this.preview = await api.libraryItemsPreviewTransfer(this.libraryId, this.mediaItemId, this.targetId);
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loadingPreview = false;
    }
  }

  // MARK: 动作

  private pickTarget(libraryId: number): void {
    if (this.busy()) {
      return;
    }
    this.targetId = libraryId;
    this.loadPreview();
  }

  private async run(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.targetId <= 0) {
      return;
    }
    this.starting = true;
    this.errorMessage = '';
    try {
      const payload: TransferPayload = { target_library_id: this.targetId };
      await api.libraryItemsTransfer(this.libraryId, this.mediaItemId, payload);
      this.apply(await api.libraryItemsGetTransferStatus(this.libraryId));
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.starting = false;
    }
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 转移进行中每秒拉一次进度，跑完自动切到结论页 */
  private startPolling(): void {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = setInterval((): void => {
      api.libraryItemsGetTransferStatus(this.libraryId).then((next: TransferStatusView): void => {
        this.apply(next);
      }).catch((): void => {
      });
    }, 1000);
  }

  private apply(next: TransferStatusView): void {
    this.status = next;
    if (next.running) {
      this.startPolling();
    } else {
      this.stopPolling();
      if (next.errors.length === 0 && (next.target_library_id ?? null) !== null && !this.notifiedDone) {
        this.notifiedDone = true;
        this.onDone();
      }
    }
  }

  build() {
    Column() {
      this.SheetBar()
      Scroll() {
        Column({ space: 0 }) {
          if (this.status !== null && this.finished()) {
            this.ResultStep(this.status)
          } else {
            this.PlanStep()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      this.BottomBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  SheetBar() {
    Row() {
      Text(this.finished() ? '关闭' : '取消')
        .fontSize(15)
        .fontColor(this.busy() ? Theme.textFaint : Theme.textMuted)
        .padding(10)
        .onClick(() => {
          if (!this.busy()) {
            this.onClose();
          }
        })
      Blank()
      Text('转移到其他媒体库')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Blank()
      Row().width(40).height(40)
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 6, bottom: 6 })
  }

  // MARK: 第一步 + 第二步：选目标库、预览计划

  @Builder
  PlanStep() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize(17)
        .fontColor([Theme.accent])
      Text(`把「${this.title}」转移到其他媒体库`)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .layoutWeight(1)
    }
    .width('100%')

    Text(this.explainer())
      .fontSize(13)
      .fontColor(Theme.textMuted)
      .width('100%')
      .padding({ top: 8 })

    Text('转 移 到')
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.textFaint)
      .width('100%')
      .padding({ top: 20, bottom: 8 })

    if (this.candidates === null) {
      if (this.errorMessage.length === 0) {
        Text('正在读取媒体库…')
          .fontSize(13)
          .fontColor(Theme.textMuted)
      }
    } else if (this.candidates.length === 0) {
      Text(`没有其他${this.kindLabel(this.sourceKind())}库可选——请先在「媒体库」页新建一个，再回来转移。`)
        .fontSize(13)
        .fontColor(Theme.warning)
        .width('100%')
    } else {
      ForEach(this.candidates, (lib: LibraryView) => {
        this.CandidateRow(lib)
      }, (lib: LibraryView) => `${lib.id}`)
    }

    if (this.loadingPreview) {
      Row({ space: 8 }) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(Theme.textMuted)
        Text('正在计算转移计划…')
          .fontSize(13)
          .fontColor(Theme.textMuted)
      }
      .width('100%')
      .padding({ top: 16 })
    }
    if (this.preview !== null) {
      this.PlanPreview(this.preview)
    }
    if (this.errorMessage.length > 0) {
      Text(this.errorMessage)
        .fontSize(13)
        .fontColor(Theme.danger)
        .width('100%')
        .padding({ top: 12 })
    }
  }

  /** 搬运单元按库的能力档案分叉，文案必须跟着分叉（同 iOS） */
  private explainer(): string {
    if (this.fileEntries()) {
      return '放错库时用它补救。这个条目的文件（连同同名的 NFO、字幕）会连同库存记录一起搬到目标库；'
        + '文件在库里的所在目录结构原样保留，同目录下别的条目留在原地不动。';
    }
    return '分错库时用它补救（例如韩剧被判进了「大陆华语剧」）。磁盘上的整个条目目录'
      + '（视频、NFO、海报、字幕）会连同库存记录一起搬到目标库；目录名原样保留，'
      + '需要规范化请到目标库运行「整理文件名」。';
  }

  @Builder
  CandidateRow(lib: LibraryView) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.targetId === lib.id ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize(20)
          .fontColor([this.targetId === lib.id ? Theme.accent : Theme.textFaint])
      }
      .width(24)
      .height(24)
      Column({ space: 2 }) {
        Row({ space: 8 }) {
          Text(lib.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
          if (lib.is_default) {
            Text('默认库')
              .fontSize(11)
              .fontColor(Theme.textFaint)
          }
        }
        Text(lib.primary_root ?? '未配置根路径')
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor('rgba(255,255,255,0.45)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .margin({ bottom: 6 })
    .backgroundColor(this.targetId === lib.id ? Theme.glassFill : 'rgba(255,255,255,0.03)')
    .borderRadius(12)
    .border({
      width: 1,
      color: this.targetId === lib.id ? Theme.accent : 'rgba(255,255,255,0.08)'
    })
    .opacity(this.busy() ? 0.5 : 1)
    .onClick(() => {
      this.pickTarget(lib.id);
    })
  }

  /** 转移计划预览：阻断原因、跨盘警示、搬运清单（源 → 目标）、跳过说明 */
  @Builder
  PlanPreview(view: TransferPreviewView) {
    Column({ space: 12 }) {
      if (view.blocked.length > 0) {
        Column({ space: 4 }) {
          ForEach(view.blocked, (line: string) => {
            Text(line)
              .fontSize(13)
              .fontColor(Theme.danger)
              .width('100%')
          }, (line: string) => line)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(12)
        .border({ width: 1, color: Theme.danger })
      }
      if (view.cross_device && view.moves.length > 0) {
        Text(`目标库与当前位置不在同一块盘：文件需要完整复制（${Formatters.bytes(view.total_bytes)}），`
          + '耗时取决于体积与盘速；复制会产生新文件，与下载器做种目录的硬链接关系将断开，两边各占一份空间。')
          .fontSize(13)
          .fontColor(Theme.warning)
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(12)
          .border({ width: 1, color: Theme.warning })
      }
      if (view.moves.length > 0) {
        Column({ space: 8 }) {
          Text(this.summaryOf(view))
            .fontSize(11)
            .fontColor(Theme.textFaint)
            .width('100%')
          ForEach(view.moves, (move: TransferMoveView) => {
            Column({ space: 2 }) {
              Text(`${this.sourceLibrary !== null ? this.sourceLibrary.name + ' · ' : ''}${move.source_path}`)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor('rgba(255,255,255,0.45)')
                .width('100%')
              Text(`↳ ${view.target_library_name} · ${move.target_path}`)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor('rgba(255,255,255,0.8)')
                .width('100%')
            }
            .width('100%')
          }, (move: TransferMoveView) => move.source_path)
        }
        .width('100%')
        .padding(14)
        .backgroundColor('rgba(255,255,255,0.03)')
        .borderRadius(12)
        .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
      }
      if (view.skips.length > 0) {
        Column({ space: 4 }) {
          ForEach(view.skips, (skip: TransferSkipView) => {
            Text(`${skip.file_path}：${skip.reason}`)
              .fontSize(11)
              .fontColor('rgba(255,255,255,0.6)')
              .width('100%')
          }, (skip: TransferSkipView) => skip.file_path)
        }
        .width('100%')
        .padding(14)
        .backgroundColor('rgba(255,255,255,0.02)')
        .borderRadius(12)
        .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 16 })
  }

  private summaryOf(view: TransferPreviewView): string {
    let text: string = `${view.moves.length} 个路径 · ${Formatters.bytes(view.total_bytes)}`;
    if (view.missing_count > 0) {
      text += ` · ${view.missing_count} 个缺失记录随迁`;
    }
    return text;
  }

  // MARK: 结论页

  @Builder
  ResultStep(state: TransferStatusView) {
    Text(state.errors.length > 0
      ? '部分转移完成'
      : `「${state.title ?? ''}」已转移到「${state.target_library_name ?? ''}」`)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.text)
      .width('100%')
    Column({ space: 2 }) {
      if (state.moved_paths.length === 0) {
        Text('没有搬运任何磁盘路径')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
      } else {
        ForEach(state.moved_paths, (path: string) => {
          Text(path)
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor('rgba(255,255,255,0.7)')
            .width('100%')
        }, (path: string) => path)
      }
    }
    .width('100%')
    .padding(14)
    .margin({ top: 12 })
    .backgroundColor('rgba(255,255,255,0.03)')
    .borderRadius(12)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
    if (state.errors.length > 0) {
      Column({ space: 4 }) {
        ForEach(state.errors, (line: string) => {
          Text(line)
            .fontSize(13)
            .fontColor(Theme.danger)
            .width('100%')
        }, (line: string) => line)
      }
      .width('100%')
      .padding({ top: 12 })
    }
    Text(this.conclusionOf(state))
      .fontSize(13)
      .fontColor(Theme.textMuted)
      .width('100%')
      .padding({ top: 12 })
  }

  private conclusionOf(state: TransferStatusView): string {
    let text: string = `已随迁 ${state.files_relocated} 条库存记录（${Formatters.bytes(state.bytes_moved)}）`;
    if (state.removed_dirs > 0) {
      text += `，清理空目录 ${state.removed_dirs} 个`;
    }
    text += '。';
    if (state.subscription_moved) {
      text += '该片的订阅已一并改挂到目标库，后续剧集直接入新库。';
    }
    return text;
  }

  // MARK: 底栏

  @Builder
  BottomBar() {
    Column({ space: 10 }) {
      if (this.running()) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(Theme.accent)
          Text(`正在转移${this.progressSuffix()}；跨盘转移需要完整复制文件，请勿关闭页面`)
            .fontSize(13)
            .fontColor(Theme.accent)
            .maxLines(2)
            .layoutWeight(1)
        }
        .width('100%')
      }
      Row({ space: 12 }) {
        Blank()
        if (this.status !== null && this.finished()) {
          Text('留在本页')
            .fontSize(15)
            .fontColor(Theme.textMuted)
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(20)
            .onClick(() => {
              this.onClose();
            })
        } else {
          Text(this.starting ? '确认转移…' : '确认转移')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.canRun() ? '#0b0d12' : Theme.textFaint)
            .padding({ left: 18, right: 18, top: 10, bottom: 10 })
            .backgroundColor(this.canRun() ? Theme.accent : Theme.glassFill)
            .borderRadius(20)
            .onClick(() => {
              if (this.canRun()) {
                this.run();
              }
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 12, bottom: 16 })
    .backgroundColor(Theme.surface)
  }
}
