/**
 * 轨道列表弹层（iOS `TrackListSheet` + `TrackSubtitlePreview` 的合并实现）。
 *
 * 列表态：按语言分组的完整轨道列表——组头「语言 · N 条」、组内行（格式色块 + 主文案 +
 * 来源/轨号 + 属性标记）；字幕行可点进预览、外挂字幕可左滑删除（管理员）；首组带
 * 「默认」说明，末组带操作提示。列表填满弹层剩余高度，条目多则内部滚动。
 *
 * 预览态（仅字幕）：对白列表（时间列 + 文本）；内封字幕首次读取需通读整个视频文件，
 * 后端用 `pending` + `retry_after_ms` 让前端隔段时间再拉；外挂字幕（管理员）可一键
 * 校准时间轴（音轨互相关）。
 *
 * 高度口径：弹层高度完全由本组件给出**确定数值**——列表态按条目数估算（vp，72% 屏高
 * 封顶），预览态给 88% 屏高（近全屏）；外层 bindSheet 恒为 FIT_CONTENT，贴合内容即可。
 * 半模态的 height 选项打开后不会重新生效，'100%' 链在无界容器里还会层层撑爆
 * （行与行之间大片空白的来源）——两种都不用。
 */
import { display } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { Permissions } from '../common/Permissions';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  CalibratePayload,
  CalibrateResultView,
  LibraryFileView,
  SubtitleCueView,
  SubtitlePreviewView
} from '../api/Models';
import {
  TrackEntry,
  TrackLanguageGroup,
  TrackPreviewInfo,
  trackAudioEntries,
  trackDefaultNote,
  trackGroupByLanguage,
  trackSiblingPath,
  trackSubtitleEntries,
  trackToneBackground,
  trackToneForeground,
  trackVideoStem
} from './MediaTrackModel';

function previewSleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: (value: void) => void) => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/** 对白时间轴的展示（mm:ss / h:mm:ss） */
function cueTimeLabel(ms: number): string {
  const total: number = Math.max(0, Math.floor(ms / 1000));
  const hours: number = Math.floor(total / 3600);
  const minutes: number = Math.floor((total % 3600) / 60);
  const seconds: number = total % 60;
  const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
  const ss: string = seconds < 10 ? `0${seconds}` : `${seconds}`;
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`;
}

@Component
export struct MediaTrackListSheet {
  /** 弹层内容：'audio' 或 'subtitle' */
  @Prop kind: string = 'subtitle';
  @Prop file: LibraryFileView | null = null;
  /** 打开时聚焦滚到的语言组；空串从头展示 */
  @Prop focusLanguage: string = '';
  /** 删除外挂 / 校准完成后由外层刷新详情（轨道与字幕列表都会变） */
  onChanged: () => void = (): void => {};
  onClose: () => void = (): void => {};

  // MARK: 预览态
  @State private previewEntry: TrackEntry | null = null;
  @State private previewData: SubtitlePreviewView | null = null;
  @State private previewError: string = '';
  @State private previewPendingText: string = '';
  @State private previewPendingHint: string = '';
  @State private calibrating: boolean = false;
  @State private calibrationNotice: string = '';
  /** 预览轮询代号：+1 令上一轮 runPreview 的循环自行退出（关闭 / 切换目标 / 销毁都靠它） */
  private previewSeq: number = 0;

  aboutToDisappear(): void {
    // 弹层销毁时停掉预览轮询
    this.previewSeq += 1;
  }

  // MARK: 基础

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private isAdmin(): boolean {
    return Permissions.fromSession(AppModel.shared.session).isAdmin;
  }

  private groups(): TrackLanguageGroup[] {
    const file: LibraryFileView | null = this.file;
    if (file === null) {
      return [];
    }
    if (this.kind === 'audio') {
      return trackGroupByLanguage(trackAudioEntries(file.audio_streams ?? [],
        file.playback_defaults ?? null));
    }
    return trackGroupByLanguage(trackSubtitleEntries(file.subtitle_streams,
      trackVideoStem(file.file_name), file.playback_defaults ?? null));
  }

  /** 弹层头部摘要：音轨给总数，字幕拆内封 / 外挂 */
  private summary(): string {
    const groups: TrackLanguageGroup[] = this.groups();
    let total: number = 0;
    let embedded: number = 0;
    let external: number = 0;
    for (const group of groups) {
      total += group.entries.length;
      for (const entry of group.entries) {
        if (entry.external) {
          external += 1;
        } else {
          embedded += 1;
        }
      }
    }
    if (this.kind === 'audio') {
      return `共 ${total} 条`;
    }
    return `共 ${total} 条 · 内封 ${embedded} · 外挂 ${external}`;
  }

  /** 组尾说明：首组带「默认」说明（服务端记了起播默认才有），末组带操作提示 */
  private groupNotes(index: number): string {
    const file: LibraryFileView | null = this.file;
    const groups: TrackLanguageGroup[] = this.groups();
    if (file === null || index < 0 || index >= groups.length) {
      return '';
    }
    const parts: string[] = [];
    if (index === 0 && file.playback_defaults !== null && file.playback_defaults !== undefined) {
      const note: string | null = trackDefaultNote(file.playback_defaults, this.kind);
      if (note !== null) {
        parts.push(note);
      }
    }
    if (index === groups.length - 1 && this.kind === 'subtitle') {
      parts.push(this.isAdmin()
        ? '点任意一条打开字幕预览；外挂字幕可左滑删除'
        : '点任意一条打开字幕预览');
    }
    return parts.join('\n');
  }

  /** 列表态高度（vp）：按真实条目估算——短列表贴合内容，长列表 72% 屏高封顶后内部滚动 */
  private sheetBodyHeight(): number {
    const groups: TrackLanguageGroup[] = this.groups();
    let height: number = 58; // 头部（标题 + 摘要 + 关闭）
    if (groups.length === 0) {
      height += 46; // 空态文案
    } else {
      for (let i = 0; i < groups.length; i++) {
        height += 38; // 组头
        for (const entry of groups[i].entries) {
          if (this.kind === 'audio') {
            height += 44;
          } else {
            height += entry.primary.length > 18 ? 88 : 66;
          }
        }
        if (this.groupNotes(i).length > 0) {
          height += 46; // 组尾说明
        }
      }
    }
    height += 20; // 拖拽条与余量
    const cap: number = Math.round(this.windowHeightVp() * 0.72);
    return Math.min(Math.max(height, 172), cap);
  }

  /** 预览态高度（vp）：88% 屏高——近全屏但留出状态栏 */
  private previewBodyHeight(): number {
    return Math.round(this.windowHeightVp() * 0.88);
  }

  /** 行高估算（vp）：与 sheetBodyHeight() 同一套数，左滑删除区按它垂直居中 */
  private swipeRowHeight(entry: TrackEntry): number {
    if (this.kind === 'audio') {
      return 44;
    }
    return entry.primary.length > 18 ? 88 : 66;
  }

  private windowHeightVp(): number {
    return this.getUIContext().px2vp(display.getDefaultDisplaySync().height);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
    }
  }

  // MARK: 预览（对应 iOS TrackSubtitlePreview）

  private previewLabel(): string {
    const entry: TrackEntry | null = this.previewEntry;
    if (entry === null || entry.preview === null) {
      return '';
    }
    return entry.preview.label;
  }

  private previewIsExternal(): boolean {
    const entry: TrackEntry | null = this.previewEntry;
    return entry !== null && entry.external;
  }

  private previewFormat(): string {
    const entry: TrackEntry | null = this.previewEntry;
    return entry !== null ? entry.format : '';
  }

  private previewFileName(): string {
    const entry: TrackEntry | null = this.previewEntry;
    if (entry === null || entry.preview === null) {
      return '';
    }
    return entry.preview.stream.file_name ?? '';
  }

  private previewCues(): SubtitleCueView[] {
    const data: SubtitlePreviewView | null = this.previewData;
    return data !== null ? data.cues : [];
  }

  private openPreview(entry: TrackEntry): void {
    if (this.kind !== 'subtitle' || entry.preview === null) {
      return;
    }
    this.previewEntry = entry;
    this.calibrationNotice = '';
    this.refreshPreview();
  }

  private closePreview(): void {
    this.previewSeq += 1;
    this.previewEntry = null;
    this.previewData = null;
    this.previewError = '';
    this.previewPendingText = '';
    this.previewPendingHint = '';
    this.calibrating = false;
    this.calibrationNotice = '';
  }

  /** 重新拉预览（打开 / 重新加载 / 校准成功后） */
  private refreshPreview(): void {
    const entry: TrackEntry | null = this.previewEntry;
    if (entry === null || entry.preview === null) {
      return;
    }
    this.previewSeq += 1;
    this.previewData = null;
    this.previewError = '';
    this.previewPendingText = '';
    this.previewPendingHint = '';
    this.runPreview(entry.preview, this.previewSeq);
  }

  private async runPreview(info: TrackPreviewInfo, seq: number): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const file: LibraryFileView | null = this.file;
    if (api === null || file === null) {
      return;
    }
    try {
      while (seq === this.previewSeq) {
        const preview: SubtitlePreviewView = await api.uiLibraryFilesPreviewSubtitles(file.id, info.track);
        if (seq !== this.previewSeq) {
          return;
        }
        const pending: string = preview.pending ?? '';
        if (pending.length === 0) {
          this.previewData = preview;
          return;
        }
        this.previewPendingText = pending === 'extracting' ? '正在抽取内封字幕…' : '正在读取字幕…';
        this.previewPendingHint = pending === 'extracting'
          ? '首次读取内封字幕需要通读整个视频文件，读好后会自动显示。' : '';
        await previewSleep(Math.max(1000, preview.retry_after_ms));
      }
    } catch (error) {
      if (seq !== this.previewSeq) {
        return;
      }
      const err: ApiError = error as ApiError;
      this.previewError = err.message.length > 0
        ? `无法预览这条字幕：${err.message}`
        : '字幕预览加载失败，请稍后重试';
    }
  }

  /** 一键校准只给管理员的外挂字幕（内封轨不可校准；同 iOS calibratable） */
  private canCalibrate(): boolean {
    const entry: TrackEntry | null = this.previewEntry;
    if (!this.isAdmin() || entry === null || entry.preview === null) {
      return false;
    }
    const stream = entry.preview.stream;
    return stream.external && (stream.file_name ?? '').length > 0;
  }

  private async calibrate(): Promise<void> {
    const file: LibraryFileView | null = this.file;
    const entry: TrackEntry | null = this.previewEntry;
    const api: MovieClawApi | null = this.api();
    if (file === null || entry === null || entry.preview === null || api === null || this.calibrating) {
      return;
    }
    const filename: string = entry.preview.stream.file_name ?? '';
    if (filename.length === 0) {
      return;
    }
    this.calibrating = true;
    try {
      const payload: CalibratePayload = { filename: filename };
      const result: CalibrateResultView = await api.librarySubtitlesCalibrateTiming(file.id, payload);
      this.calibrating = false;
      this.calibrationNotice = result.message;
      if (result.ok) {
        this.onChanged();
        this.refreshPreview();
      }
    } catch (error) {
      this.calibrating = false;
      const err: ApiError = error as ApiError;
      this.calibrationNotice = err.message.length > 0 ? err.message : '校准失败，请稍后再试';
    }
  }

  // MARK: 删除外挂字幕（对应 web/iOS 的删除确认框）

  private canSwipeDelete(entry: TrackEntry): boolean {
    return this.isAdmin() && entry.deletable !== null;
  }

  private confirmDelete(entry: TrackEntry): void {
    const file: LibraryFileView | null = this.file;
    const filename: string | null = entry.deletable;
    if (file === null || filename === null) {
      return;
    }
    const fullPath: string = trackSiblingPath(file.file_path, filename);
    this.getUIContext().showAlertDialog({
      title: '删除这个字幕文件？',
      message: `将从磁盘直接删除下面的文件，删除后无法恢复：\n${fullPath}`,
      primaryButton: {
        value: '不删除',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除字幕',
        fontColor: Theme.danger,
        action: (): void => {
          this.deleteSubtitle(filename);
        }
      }
    });
  }

  private async deleteSubtitle(filename: string): Promise<void> {
    const file: LibraryFileView | null = this.file;
    const api: MovieClawApi | null = this.api();
    if (file === null || api === null) {
      return;
    }
    try {
      await api.librarySubtitlesDelete(file.id, filename);
      this.toast(`已删除字幕：${filename}`);
      this.onChanged();
    } catch (error) {
      const err: ApiError = error as ApiError;
      this.toast(err.message.length > 0 ? err.message : '字幕删除失败，请稍后重试');
    }
  }

  // MARK: 布局

  build() {
    Column() {
      if (this.previewEntry !== null) {
        this.PreviewMode()
      } else {
        this.ListMode()
      }
    }
    .width('100%')
  }

  /** 列表态：头部（标题 + 摘要 + 关闭）+ 按语言分组的完整列表 */
  @Builder
  ListMode() {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text(this.kind === 'audio' ? '音轨' : '字幕')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
          Text(this.summary())
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('关闭')
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .padding({ left: 12, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 10, bottom: 4 })
      if (this.groups().length === 0) {
        Text(this.kind === 'audio' ? '文件内没有音轨' : '无内封或外挂字幕')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      } else {
        // 裸 List 填满弹层剩余高度（外层给了按内容估算的弹层高度），条目多则内部滚动
        List() {
          ForEach(this.groups(), (group: TrackLanguageGroup, index: number) => {
            ListItemGroup({ header: this.GroupHeader(group), footer: this.GroupFooter(index) }) {
              ForEach(group.entries, (entry: TrackEntry) => {
                ListItem() {
                  this.EntryRow(entry)
                }
                .swipeAction({ end: this.canSwipeDelete(entry) ? this.DeleteSwipe(entry) : this.NoSwipe() })
              }, (entry: TrackEntry) => entry.id)
            }
            .divider({ strokeWidth: 1, color: Theme.line, startMargin: 16, endMargin: 16 })
          }, (group: TrackLanguageGroup) => group.language)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height(this.sheetBodyHeight())
  }

  /** 组头：语言 · N 条（点开的那个语言高亮，方便对上芯片） */
  @Builder
  GroupHeader(group: TrackLanguageGroup) {
    Text(`${group.language} · ${group.entries.length}`)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(group.language === this.focusLanguage ? Theme.accentStrong : Theme.textMuted)
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })
      .width('100%')
  }

  /** 组尾说明（首组的「默认」说明 / 末组的操作提示） */
  @Builder
  GroupFooter(index: number) {
    if (this.groupNotes(index).length > 0) {
      Text(this.groupNotes(index))
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .padding({ left: 16, right: 16, top: 6, bottom: 10 })
        .width('100%')
    }
  }

  /** 列表行：格式色块 + 主文案 + 来源/轨号 + 属性标记；字幕行带 chevron、点进预览 */
  @Builder
  EntryRow(entry: TrackEntry) {
    Row({ space: 10 }) {
      Text(entry.format)
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(trackToneForeground(entry.tone))
        .backgroundColor(trackToneBackground(entry.tone))
        .height(20)
        .padding({ left: 6, right: 6 })
        .borderRadius(5)
        .textAlign(TextAlign.Center)
      if (this.kind === 'subtitle') {
        Column({ space: 3 }) {
          Text(entry.primary)
            .fontSize(15)
            .fontColor(Theme.text)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 8 }) {
            Text(entry.secondary)
              .fontSize(12)
              .fontColor(Theme.textMuted)
            ForEach(entry.flags, (flag: string) => {
              Text(flag)
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textMuted)
            }, (flag: string) => flag)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (entry.preview !== null) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([Theme.textFaint])
        }
      } else {
        Text(entry.primary)
          .fontSize(15)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Row({ space: 8 }) {
          Text(entry.secondary)
            .fontSize(12)
            .fontColor(Theme.textMuted)
          ForEach(entry.flags, (flag: string) => {
            Text(flag)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textMuted)
          }, (flag: string) => flag)
        }
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .onClick(() => {
      this.openPreview(entry);
    })
  }

  /** 预览态：头部（返回 + 标题 + 校准）+ 元信息 + 对白列表 */
  @Builder
  PreviewMode() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor([Theme.text])
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .onClick(() => {
          this.closePreview();
        })
        Column({ space: 2 }) {
          Text(this.previewLabel())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.previewData !== null) {
            Text(`共 ${this.previewData.event_count} 条对白`)
              .fontSize(12)
              .fontColor(Theme.textMuted)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.canCalibrate()) {
          if (this.calibrating) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(Theme.accentStrong)
          } else {
            Text('校准时间轴')
              .fontSize(14)
              .fontColor(Theme.accentStrong)
              .padding({ left: 8, right: 0, top: 6, bottom: 6 })
              .onClick(() => {
                this.calibrate();
              })
          }
        }
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 6, bottom: 6 })
      if (this.calibrationNotice.length > 0) {
        this.NoticeRow(this.calibrationNotice)
      }
      this.PreviewInfo()
      if (this.previewError.length > 0) {
        this.PreviewError()
      } else if (this.previewPendingText.length > 0) {
        this.PreviewPending()
      } else if (this.previewData !== null) {
        this.PreviewCues()
      }
    }
    .width('100%')
    .height(this.previewBodyHeight())
  }

  /** 预览元信息：外挂/内封徽章 + 格式 + 文件名 */
  @Builder
  PreviewInfo() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(this.previewIsExternal() ? '外挂' : '内封')
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.65)')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('rgba(255,255,255,0.08)')
          .borderRadius(4)
        Text(this.previewFormat().toUpperCase())
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.65)')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('rgba(255,255,255,0.08)')
          .borderRadius(4)
      }
      if (this.previewFileName().length > 0) {
        Text(this.previewFileName())
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 预览失败：原因 + 重新加载出口 */
  @Builder
  PreviewError() {
    Column({ space: 10 }) {
      Text(this.previewError)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('rgba(255,255,255,0.045)')
        .borderRadius(10)
      Text('重新加载')
        .fontSize(14)
        .fontColor(Theme.accentStrong)
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .onClick(() => {
          this.refreshPreview();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 内封字幕首次读取要通读整个视频文件：转圈 + 等待文案，好了自动接上 */
  @Builder
  PreviewPending() {
    Row({ space: 10 }) {
      LoadingProgress()
        .width(18)
        .height(18)
        .color(Theme.textMuted)
      Column({ space: 2 }) {
        Text(this.previewPendingText)
          .fontSize(14)
          .fontColor(Theme.text)
        if (this.previewPendingHint.length > 0) {
          Text(this.previewPendingHint)
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 6 })
  }

  /** 对白列表：时间列（开始 → 结束）+ 文本；占满弹层剩余高度，长字幕内部滚动 */
  @Builder
  PreviewCues() {
    if (this.previewCues().length === 0) {
      Text('字幕已成功解析，但没有可显示的对白')
        .fontSize(14)
        .fontColor(Theme.textMuted)
        .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    } else {
      List() {
        ForEach(this.previewCues(), (cue: SubtitleCueView, index: number) => {
          ListItem() {
            this.CueRow(cue)
          }
        }, (cue: SubtitleCueView, index: number) => `${index}-${cue.start_ms}-${cue.end_ms}`)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
  }

  @Builder
  CueRow(cue: SubtitleCueView) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(cueTimeLabel(cue.start_ms))
          .fontSize(12)
          .fontColor(Theme.textMuted)
        Text(`→ ${cueTimeLabel(cue.end_ms)}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .width(104)
      .padding({ top: 2 })
      .alignItems(HorizontalAlign.Start)
      Text(cue.text)
        .fontSize(14)
        .fontColor(Theme.text)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  /** 校准结果回执（信息条） */
  @Builder
  NoticeRow(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor(Theme.textMuted)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('rgba(255,255,255,0.045)')
      .borderRadius(10)
      .margin({ left: 16, right: 16, top: 8 })
  }

  /** 不带左滑：占位空视图（swipeAction 需要显式空值；零尺寸，不给所在行任何撑高空间） */
  @Builder
  NoSwipe() {
    Row()
      .width(0)
      .height(0)
  }

  /** 左滑「删除」（对应 iOS swipeActions + destructive 红底）。
   *  swipeAction 的 builder 里 height('100%') 解析不到行高（容器无界），
   *  之前靠 maxHeight 封顶只会恒顶到 88、比矮行还高；改为按行高估算把
   *  紧凑圆角胶囊垂直居中——视觉贴行，不再撑高。 */
  @Builder
  DeleteSwipe(entry: TrackEntry) {
    Column() {
      Button() {
        Text('删除')
          .fontSize(14)
          .fontColor('#ffffff')
          .textAlign(TextAlign.Center)
      }
      .attributeModifier(new GlassButtonModifier(GlassTone.Danger))
      .padding(0)
      .width(64)
      .height(36)
      .borderRadius(18)
      .onClick(() => {
        this.confirmDelete(entry);
      })
    }
    .width(76)
    .height(this.swipeRowHeight(entry))
    .justifyContent(FlexAlign.Center)
  }
}
