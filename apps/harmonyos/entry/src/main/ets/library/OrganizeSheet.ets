import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  LibraryView,
  OrganizePreviewView,
  OrganizeRenameView,
  OrganizeSidecarView,
  OrganizeSkipView,
  OrganizeStartView
} from '../api/Models';

/** 四段式（对应 iOS 的 `Phase`）：预览 → 确认 → 执行 → 结果 */
class Phase {
  static readonly loading: string = 'loading';
  static readonly preview: string = 'preview';
  static readonly running: string = 'running';
  static readonly done: string = 'done';
}

/** 整理进度（执行页用；对应 iOS 轮询单库详情拿到的 `scan_progress`） */
class OrganizeProgress {
  readonly processed: number;
  readonly total: number;

  constructor(processed: number, total: number) {
    this.processed = processed;
    this.total = total;
  }
}

/**
 * 整理文件名（对应 iOS `LibraryOrganizeSheet` / Web `library-organize-dialog`）。
 *
 * **批量改名是半不可逆操作，交互按「手术确认单」打造**（iOS 的原话），四条都照做：
 * - **先看后动**：打开即拉完整预览（`…/file-organization-preview`，只读不动磁盘）——
 *   每个文件改成什么名、哪些跳过及原因，逐条可查；
 * - **风险前置**：无法一键撤销 / 做种会断 / 播放器会重识别三条风险醒目告知，
 *   勾选「我已了解」后执行键才亮；
 * - **执行可离场**：确认后任务在后端跑（`…/file-organizations`），这里轮询单库详情画进度，
 *   关掉面板不影响整理；
 * - **结果可追溯**：完成页给出改名 / 附属 / 清理目录的完整账目，错误原文展示。
 *
 * 一个容易写错的地方（iOS 注释里特意点了）：完成判定要有**两个凭据**——
 * 见过 `organizing=true`，或 `last_organize` 换了新结论。只看 `organizing=false` 不行：
 * POST 受理后后台任务才起跑，首轮轮询可能落在起跑前的空档，那时 `last_organize` 还是旧的。
 */
@ComponentV2
export struct OrganizeSheet {
  @Require @Param libraryId: number;
  /** 受理后回调（宿主据此刷新库状态与墙） */
  @Require @Param onStarted: () => void;
  @Require @Param onClose: () => void;

  @Local private phase: string = Phase.loading;
  @Local private preview: OrganizePreviewView | null = null;
  @Local private progress: OrganizeProgress | null = null;
  @Local private result: LibraryView | null = null;
  @Local private errorMessage: string = '';
  @Local private agreed: boolean = false;
  @Local private busy: boolean = false;
  /** 展开的清单（改名 / 跳过） */
  @Local private openList: string = 'renames';

  /** 完成判定的两个凭据 */
  private sawRunning: boolean = false;
  private baselineFinished: string = '';
  private timer: number = -1;
  private started: boolean = false;

  aboutToAppear(): void {
    this.prepare();
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // MARK: 取数

  private async prepare(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.phase = Phase.loading;
    this.errorMessage = '';
    try {
      const library: LibraryView = await api.libraryGet(this.libraryId);
      this.result = library;
      this.baselineFinished = library.last_organize !== null && library.last_organize !== undefined
        ? library.last_organize.finished_at : '';
      // 库已经在整理中（比如中途关过面板）直接进执行页
      if (library.organizing) {
        this.sawRunning = true;
        this.phase = Phase.running;
        this.startPoll();
        return;
      }
      this.preview = await api.workflowLibraryOrganizeFilesPreview(this.libraryId);
      this.phase = Phase.preview;
    } catch (error) {
      this.errorMessage = this.messageOf(error);
      this.phase = Phase.preview;
    }
  }

  /** 轮询单库详情画进度（任务在后端跑，关掉面板不影响） */
  private startPoll(): void {
    if (this.timer >= 0) {
      return;
    }
    this.timer = setInterval((): void => {
      this.pollOnce();
    }, 2000);
  }

  private stopPoll(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private async pollOnce(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const library: LibraryView = await api.libraryGet(this.libraryId);
      this.result = library;
      if (library.scan_progress !== null && library.scan_progress !== undefined) {
        this.progress = new OrganizeProgress(library.scan_progress.processed, library.scan_progress.total);
      }
      if (library.organizing) {
        this.sawRunning = true;
        return;
      }
      // 两个凭据：见过在跑，或出了新结论
      const finished: string = library.last_organize !== null && library.last_organize !== undefined
        ? library.last_organize.finished_at : '';
      if (this.sawRunning || (finished.length > 0 && finished !== this.baselineFinished)) {
        this.stopPoll();
        this.phase = Phase.done;
      }
    } catch (error) {
      // 单轮失败不打断，下一轮自愈
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 动作

  private async execute(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy || !this.agreed) {
      return;
    }
    this.busy = true;
    try {
      const view: OrganizeStartView = await api.workflowLibraryOrganizeFilesStart(this.libraryId);
      this.sawRunning = true;
      this.baselineFinished = this.result !== null && this.result.last_organize !== null
        && this.result.last_organize !== undefined ? this.result.last_organize.finished_at : '';
      this.phase = Phase.running;
      this.startPoll();
      this.onStarted();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  // MARK: 派生

  private renameCount(): number {
    return this.preview !== null ? this.preview.renames.length : 0;
  }

  private skipCount(): number {
    return this.preview !== null ? this.preview.skips.length : 0;
  }

  private sidecarCount(): number {
    let total: number = 0;
    if (this.preview !== null) {
      for (const rename of this.preview.renames) {
        total += rename.sidecars.length;
      }
    }
    return total;
  }

  /** 能不能执行：有要改的、勾了「我已了解」、且不在忙 */
  private canExecute(): boolean {
    return this.renameCount() > 0 && this.agreed && !this.busy && this.phase === Phase.preview;
  }

  // MARK: 视图

  build() {
    Column() {
      this.SheetBar()
      if (this.phase === Phase.loading) {
        this.LoadingState()
      } else if (this.phase === Phase.preview) {
        this.PreviewState()
      } else if (this.phase === Phase.running) {
        this.RunningState()
      } else {
        this.DoneState()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  SheetBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(18)
        .fontColor([Theme.textMuted])
        .width(40)
        .height(40)
        .onClick(() => {
          this.onClose();
        })
      Blank()
      Text('整理文件名')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Blank()
      Row().width(40).height(40)
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
      Text('正在生成预览…')
        .fontSize(14)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /** 预览：先看后动 + 风险前置 */
  @Builder
  PreviewState() {
    Scroll() {
      Column({ space: 14 }) {
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize(13)
            .fontColor(Theme.danger)
            .width('100%')
        }
        this.SummaryCard()
        if (this.skipCount() > 0) {
          this.SkipList()
        }
        if (this.renameCount() > 0) {
          this.RenameList()
        }
        this.RiskBlock()
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 24 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  /** 摘要：共多少个文件、要改多少、跳过多少、附属多少 */
  @Builder
  SummaryCard() {
    Column({ space: 10 }) {
      Text(this.renameCount() > 0 ? `将重命名 ${this.renameCount()} 个文件` : '没有需要重命名的文件')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
        .width('100%')
      Row({ space: 16 }) {
        this.StatCell('共扫描', this.preview !== null ? `${this.preview.total}` : '0')
        this.StatCell('已合规', this.preview !== null ? `${this.preview.already_ok}` : '0')
        this.StatCell('要改名', `${this.renameCount()}`)
        this.StatCell('跳过', `${this.skipCount()}`)
        this.StatCell('附属', `${this.sidecarCount()}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  StatCell(label: string, value: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(18)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(label)
        .fontSize(11)
        .fontColor(Theme.textFaint)
    }
    .alignItems(HorizontalAlign.Start)
  }

  /** 改名清单：每条显示「原名 → 新名」 */
  @Builder
  RenameList() {
    Column() {
      Row() {
        Text(`改名清单 ${this.renameCount()}`)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .layoutWeight(1)
        SymbolGlyph(this.openList === 'renames' ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(13)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 13, bottom: 13 })
      .onClick(() => {
        this.openList = this.openList === 'renames' ? '' : 'renames';
      })
      if (this.openList === 'renames') {
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
        ForEach(this.preview !== null ? this.preview.renames : [], (rename: OrganizeRenameView) => {
          Column({ space: 3 }) {
            Text(rename.source_rel)
              .fontSize(12)
              .fontColor(Theme.textMuted)
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.arrow_right'))
                .fontSize(11)
                .fontColor([Theme.accent])
              Text(rename.target_rel)
                .fontSize(12)
                .fontColor(Theme.text)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            if (rename.sidecars.length > 0) {
              Text(`含 ${rename.sidecars.length} 个附属文件（字幕 / NFO 等）`)
                .fontSize(11)
                .fontColor(Theme.textFaint)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        }, (rename: OrganizeRenameView) => `${rename.file_id}`)
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 跳过清单：逐条给原因（iOS 的「哪些跳过及原因逐条可查」） */
  @Builder
  SkipList() {
    Column() {
      Row() {
        Text(`跳过 ${this.skipCount()}`)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .layoutWeight(1)
        SymbolGlyph(this.openList === 'skips' ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(13)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 13, bottom: 13 })
      .onClick(() => {
        this.openList = this.openList === 'skips' ? '' : 'skips';
      })
      if (this.openList === 'skips') {
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
        ForEach(this.preview !== null ? this.preview.skips : [], (skip: OrganizeSkipView) => {
          Column({ space: 3 }) {
            Text(skip.file_path)
              .fontSize(12)
              .fontColor(Theme.textMuted)
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(skip.reason)
              .fontSize(12)
              .fontColor(Theme.warn)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        }, (skip: OrganizeSkipView) => skip.file_path)
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 风险前置：三条风险 + 「我已了解」，勾了执行键才亮 */
  @Builder
  RiskBlock() {
    Column({ space: 10 }) {
      Text('动手前请确认')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.warn)
        .width('100%')
      this.RiskLine('改名之后没法一键撤销，只能再整理一次改回来。')
      this.RiskLine('正在做种的文件改名会让做种中断，下载器里要重新校验。')
      this.RiskLine('播放器可能把改过名的文件当成新文件，重新识别一次。')
      Row({ space: 10 }) {
        SymbolGlyph(this.agreed ? $r('sys.symbol.checkmark_square_fill') : $r('sys.symbol.square'))
          .fontSize(20)
          .fontColor([this.agreed ? Theme.accent : Theme.textFaint])
        Text('我已了解，开始整理')
          .fontSize(15)
          .fontColor(Theme.text)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 6 })
      .onClick(() => {
        this.agreed = !this.agreed;
      })

      Text(this.busy ? '提交中…' : '开始整理')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(this.canExecute() ? '#0b0d12' : Theme.textFaint)
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 13, bottom: 13 })
        .backgroundColor(this.canExecute() ? Theme.accent : Theme.glassFill)
        .borderRadius(12)
        .onClick(() => {
          if (this.canExecute()) {
            this.execute();
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor('rgba(251, 191, 36, 0.08)')
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: 'rgba(251, 191, 36, 0.35)' })
  }

  @Builder
  RiskLine(text: string) {
    Row({ space: 8 }) {
      Text('•')
        .fontSize(13)
        .fontColor(Theme.warn)
      Text(text)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 执行中：进度（关掉面板不影响，任务在后端跑） */
  @Builder
  RunningState() {
    Column({ space: 14 }) {
      LoadingProgress()
        .width(34)
        .height(34)
        .color(Theme.accent)
      Text('正在整理…')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      if (this.progress !== null) {
        Column({ space: 6 }) {
          Progress({ value: this.progress.processed, total: Math.max(1, this.progress.total) })
            .width('100%')
            .height(5)
            .color(Theme.accent)
            .backgroundColor(Theme.line)
          Text(`${this.progress.processed} / ${this.progress.total}`)
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
        .width('70%')
      }
      Text('整理在后端进行，关掉这个面板不会中断。')
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  /** 结果：完整账目（改名 / 附属 / 清理目录 / 错误原文） */
  @Builder
  DoneState() {
    Scroll() {
      Column({ space: 14 }) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(34)
            .fontColor([Theme.ok])
          Text('整理完成')
            .fontSize(18)
            .fontWeight(600)
            .fontColor(Theme.text)
        }
        .width('100%')
        .padding({ top: 8 })

        if (this.result !== null && this.result.last_organize !== null
          && this.result.last_organize !== undefined) {
          Column({ space: 10 }) {
            Row({ space: 16 }) {
              this.StatCell('已改名', `${this.result.last_organize.renamed}`)
              this.StatCell('附属', `${this.result.last_organize.sidecars_renamed}`)
              this.StatCell('已合规', `${this.result.last_organize.already_ok}`)
              this.StatCell('跳过', `${this.result.last_organize.skipped}`)
            }
            .width('100%')
            Text(`清理空目录 ${this.result.last_organize.removed_dirs} 个  ·  `
              + Formatters.relative(this.result.last_organize.finished_at))
              .fontSize(13)
              .fontColor(Theme.textMuted)
              .width('100%')
            if (this.result.last_organize.errors.length > 0) {
              Divider().color(Theme.line)
              Text(`有 ${this.result.last_organize.errors.length} 条错误`)
                .fontSize(14)
                .fontWeight(600)
                .fontColor(Theme.danger)
                .width('100%')
              ForEach(this.result.last_organize.errors, (message: string) => {
                Text(message)
                  .fontSize(12)
                  .fontColor(Theme.danger)
                  .width('100%')
              }, (message: string, index: number) => `${index}-${message}`)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 24 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }
}
