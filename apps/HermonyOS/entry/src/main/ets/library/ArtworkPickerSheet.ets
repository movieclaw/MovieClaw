import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { ArtworkCandidateView, ArtworkCandidatesView, ArtworkSelectPayload } from '../api/Models';

/** 页面签（对应 iOS `ArtworkTab`） */
class ArtworkTabOption {
  readonly value: string;
  readonly label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const TABS: ArtworkTabOption[] = [
  new ArtworkTabOption('backdrop', '背景'),
  new ArtworkTabOption('poster', '海报')
];

/** 「正在恢复自动选图」用的哨兵（和真实 file_path 区分开；ArkTS 没有 nil 表示法） */
const RESTORE_AUTO: string = '__restore_auto__';

/**
 * 「更换图片」弹层（对应 iOS `Features/Library/ArtworkPickerSheet.swift`，
 * 设计见 docs/design/metadata.md 6.3）。
 *
 * 自动选图挑不中口味时的人工通道：背景 / 海报两个页签，网格铺候选缩略图，
 * 点选即落盘 + 覆盖媒体目录 + 加锁（此后刷新元数据不再覆盖）。
 * 候选顺序与自动选图规则一致；「当前」按后端给的**实际在用路径**比对，
 * 不能用「列表第一张」推断（策略升级前刮的条目、锁定的条目都会对不上）。
 * 已锁定时给「恢复自动选图」（`file_path: null` = 解锁）。
 *
 * **本组件是 V1 `@Component`**（宿主 `LibraryItemDetailPage` 也是 V1）。
 */
@Component
export struct ArtworkPickerSheet {
  @Prop libraryId: number = 0;
  @Prop mediaItemId: number = 0;
  /** 选定 / 恢复后回调：调用方重拉详情呈现新图 */
  onChanged: () => void = (): void => {
  };
  onClose: () => void = (): void => {
  };

  @State private tab: string = 'backdrop';
  @State private data: ArtworkCandidatesView | null = null;
  @State private failed: boolean = false;
  /** 某一次保存没成功的原因：挂在网格上方，网格保留可以换一张再试 */
  @State private saveError: string = '';
  /** 正在应用的候选 file_path（`RESTORE_AUTO` 表示正在恢复自动）；空 = 空闲 */
  @State private applying: string = '';

  aboutToAppear(): void {
    this.load(true);
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private origin(): string {
    const client = AppModel.shared.client;
    return client !== null ? client.origin : '';
  }

  /** 候选图缩略地址：TMDB 远程图走后端缓存代理 */
  private previewUrl(candidate: ArtworkCandidateView): string {
    return ImageUrls.resolve(this.origin(), candidate.preview_url, null) ?? '';
  }

  private candidates(): ArtworkCandidateView[] {
    const view: ArtworkCandidatesView | null = this.data;
    if (view === null) {
      return [];
    }
    return this.tab === 'poster' ? view.posters : view.backdrops;
  }

  private locked(): boolean {
    const view: ArtworkCandidatesView | null = this.data;
    if (view === null) {
      return false;
    }
    return this.tab === 'poster' ? view.poster_locked : view.backdrop_locked;
  }

  private current(): string | null {
    const view: ArtworkCandidatesView | null = this.data;
    if (view === null) {
      return null;
    }
    return this.tab === 'poster' ? (view.current_poster ?? null) : (view.current_backdrop ?? null);
  }

  private tabLabel(): string {
    return this.tab === 'poster' ? '海报' : '背景';
  }

  /** 按列数切行（ArkTS 版 LazyVGrid adaptive 的等价物：海报 3 列、背景 1 列，口径同 iOS 最小宽 116 / 220） */
  private chunked(items: ArtworkCandidateView[]): ArtworkCandidateView[][] {
    const columns: number = this.tab === 'poster' ? 3 : 1;
    const rows: ArtworkCandidateView[][] = [];
    for (let i: number = 0; i < items.length; i += columns) {
      rows.push(items.slice(i, i + columns));
    }
    return rows;
  }

  private emptySlots(count: number): number[] {
    const columns: number = this.tab === 'poster' ? 3 : 1;
    const slots: number[] = [];
    for (let i: number = count; i < columns; i++) {
      slots.push(i);
    }
    return slots;
  }

  /** 候选图下方的小字：尺寸 · 语言（同 iOS `cell` 的 caption） */
  private captionOf(candidate: ArtworkCandidateView): string {
    const width: number | null = candidate.width ?? null;
    const height: number | null = candidate.height ?? null;
    const size: string = width !== null && height !== null ? `${width}×${height}` : '';
    const language: string | null = candidate.language ?? null;
    const lang: string = language !== null && language.length > 0 ? ` · ${language}` : '';
    return `${size}${lang}`;
  }

  /** reset=false 用于选图后的静默刷新：保留当前网格，避免整块闪回「正在拉取」 */
  private async load(reset: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.failed = false;
    if (reset) {
      this.data = null;
    }
    try {
      this.data = await api.libraryArtworkListCandidates(this.libraryId, this.mediaItemId);
    } catch (error) {
      this.failed = true;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `保存失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '保存失败，请稍后重试';
  }

  /** 选定一张（filePath）或恢复自动（null） */
  private async apply(filePath: string | null): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.applying = filePath ?? RESTORE_AUTO;
    this.saveError = '';
    try {
      const payload: ArtworkSelectPayload = { kind: this.tab, file_path: filePath };
      await api.libraryArtworkSelect(this.libraryId, this.mediaItemId, payload);
      this.onChanged();
      await this.load(false);
    } catch (error) {
      this.saveError = `保存失败：${this.messageOf(error)}`;
    } finally {
      this.applying = '';
    }
  }

  build() {
    Column() {
      this.SheetBar()
      Scroll() {
        Column({ space: 14 }) {
          Text('选中即生效，并同步写入媒体目录；此后刷新元数据不会覆盖你选的图')
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .width('100%')
          this.TabPicker()
          if (this.locked()) {
            this.LockedBanner()
          }
          if (this.saveError.length > 0) {
            Text(this.saveError)
              .fontSize(13)
              .fontColor(Theme.danger)
              .width('100%')
          }
          this.Body()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  SheetBar() {
    Row() {
      Row().width(40).height(40)
      Blank()
      Text('更换图片')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Blank()
      Text('完成')
        .fontSize(15)
        .fontColor(this.applying.length > 0 ? Theme.textFaint : Theme.accentStrong)
        .padding(10)
        .onClick(() => {
          if (this.applying.length === 0) {
            this.onClose();
          }
        })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
  }

  /** 背景 / 海报两页签（分段控件） */
  @Builder
  TabPicker() {
    Row({ space: 4 }) {
      ForEach(TABS, (option: ArtworkTabOption) => {
        Text(option.label)
          .fontSize(15)
          .fontWeight(this.tab === option.value ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.tab === option.value ? '#0b0d12' : Theme.textMuted)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(this.tab === option.value ? Theme.accent : Color.Transparent)
          .borderRadius(9)
          .onClick(() => {
            if (this.tab !== option.value) {
              this.tab = option.value;
              this.saveError = '';
            }
          })
      }, (option: ArtworkTabOption) => option.value)
    }
    .width('100%')
    .padding(4)
    .backgroundColor(Theme.surfaceRaised)
    .borderRadius(11)
  }

  /** 已锁定：一句话说明 + 恢复自动选图（`file_path: null`） */
  @Builder
  LockedBanner() {
    Row({ space: 12 }) {
      Text(`当前${this.tabLabel()}由你手动选定，刷新元数据不会覆盖`)
        .fontSize(13)
        .fontColor(Theme.ok)
        .layoutWeight(1)
      Text('恢复自动选图')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.applying.length > 0 ? Theme.textFaint : Theme.text)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(14)
        .onClick(() => {
          if (this.applying.length === 0) {
            this.apply(null);
          }
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(Theme.glassFill)
    .borderRadius(12)
  }

  @Builder
  Body() {
    if (this.failed) {
      Column({ space: 10 }) {
        Text('候选图加载失败（TMDB 可能不可达）')
          .fontSize(14)
          .fontColor(Theme.danger)
        Text('重试')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(18)
          .onClick(() => {
            this.load(this.data === null);
          })
      }
      .width('100%')
      .padding({ top: this.data === null ? 40 : 8, bottom: 8 })
    }
    if (this.data === null) {
      if (!this.failed) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(Theme.textMuted)
          Text('正在拉取候选图…')
            .fontSize(14)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 56, bottom: 56 })
      }
    } else if (this.candidates().length === 0) {
      Text(`TMDB 上没有这个条目的${this.tabLabel()}图`)
        .fontSize(14)
        .fontColor(Theme.textMuted)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 56, bottom: 56 })
    } else {
      this.CandidateGrid()
    }
  }

  @Builder
  CandidateGrid() {
    Column({ space: 12 }) {
      ForEach(this.chunked(this.candidates()), (row: ArtworkCandidateView[]) => {
        Row({ space: 12 }) {
          ForEach(row, (candidate: ArtworkCandidateView) => {
            this.CandidateCell(candidate)
          }, (candidate: ArtworkCandidateView) => candidate.file_path)
          ForEach(this.emptySlots(row.length), (slot: number) => {
            Column()
              .layoutWeight(1)
          }, (slot: number) => `${slot}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (row: ArtworkCandidateView[]) => row.map((c: ArtworkCandidateView): string => c.file_path).join('|'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  CandidateCell(candidate: ArtworkCandidateView) {
    Stack({ alignContent: Alignment.TopStart }) {
      RemoteImage({ url: this.previewUrl(candidate) })
        .width('100%')
        .height('100%')
      // 标出正在用的那张，消除「我现在用的是哪张」的疑问
      if (candidate.file_path === this.current()) {
        Text('当前')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(Theme.accent)
          .borderRadius(4)
          .margin(6)
      }
      // 背景里「无文字」的更好用，标一下（同 iOS）
      if (this.tab === 'backdrop' && (candidate.language ?? null) === null) {
        Text('无文字')
          .fontSize(10)
          .fontColor('rgba(255,255,255,0.85)')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('rgba(0,0,0,0.7)')
          .borderRadius(4)
          .margin(6)
          .align(Alignment.TopEnd)
      }
      if (this.applying.length > 0 && this.applying !== RESTORE_AUTO && this.applying === candidate.file_path) {
        Column() {
          LoadingProgress()
            .width(24)
            .height(24)
            .color(Theme.accent)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.55)')
      }
      if (this.captionOf(candidate).length > 0) {
        Text(this.captionOf(candidate))
          .fontSize(10)
          .fontColor('rgba(255,255,255,0.75)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 6, right: 6, top: 10, bottom: 4 })
          .align(Alignment.BottomStart)
      }
    }
    .width('100%')
    .aspectRatio(this.tab === 'poster' ? 2 / 3 : 16 / 9)
    .borderRadius(8)
    .clip(true)
    .border({
      width: candidate.file_path === this.current() ? 2 : 1,
      color: candidate.file_path === this.current() ? Theme.accent : 'rgba(255,255,255,0.1)'
    })
    .opacity(this.applying.length > 0 && this.applying !== candidate.file_path ? 0.6 : 1)
    .layoutWeight(1)
    .onClick(() => {
      if (this.applying.length === 0) {
        this.apply(candidate.file_path);
      }
    })
  }
}
