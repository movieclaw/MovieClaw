/**
 * 条目详情的媒体轨道区（对应 iOS `Features/Library/MediaTrackSection.swift`）：
 * - 多版本（同一部片多个在位文件）时给全宽的版本选择菜单；
 * - 音轨 / 字幕各一行：按语言分组的芯片摘要，点芯片打开按语言分组的完整列表弹层
 *   （默认组带播放标）；音轨行尾挂「最高规格」，字幕行尾挂 AI 字幕生成徽章；
 *   芯片数按实测宽度自适应——放得下就多放、放不下收「+N 种」，保证整行恒为一行；
 * - 弹层（`MediaTrackListSheet`）里才是全部轨道：字幕行可进预览、外挂可左滑删除。
 */
import { display } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { LibraryFileView } from '../api/Models';
import { TrackSubtitleGenButton } from './TrackSubtitleGen';
import { MediaTrackListSheet } from './MediaTrackListSheet';
import { SpatialMaterial } from '../common/SpatialMaterial';
import {
  TrackEntry,
  TrackLanguageGroup,
  trackAudioEntries,
  trackFileOptionLabel,
  trackGroupByLanguage,
  trackSubtitleEntries,
  trackTopAudioSpec,
  trackVideoStem
} from './MediaTrackModel';

/** 芯片行的自适应折行：芯片占宽用 measure 实测文字 + 按样式硬算常量，
 *  行内放得下就多放、放不下收进「+N 种」，保证整行恒为一行（窄屏、折叠副屏都成立）。 */

/** 「音轨 / 字幕」行标签宽（15fp 两字 ≈ 30，留 6 松量） */
const ROW_LABEL_WIDTH: number = 36;
/** 行标签与芯片内容的间距 */
const ROW_GAP: number = 10;
/** 芯片左右内边距合计（9 + 9） */
const CHIP_H_PAD: number = 18;
/** 芯片左右边框合计 */
const CHIP_BORDER: number = 2;
/** 芯片右外边距（收紧，给芯片腾位） */
const CHIP_MARGIN: number = 4;
/** 芯片内元素间距 */
const CHIP_GAP: number = 6;
/** 直接展示的语言芯片数上限，再多收「+N 种」（防芯片墙） */
const MAX_VISIBLE_CHIPS: number = 4;

@Component
export struct MediaTrackSection {
  /** 当前播放单元的在位文件（state == "in_place"；外面过滤） */
  @Prop files: LibraryFileView[] = [];
  @State private selectedFileId: number = -1;
  /** 弹层状态：'audio' / 'subtitle'，空串表示未开 */
  @State private sheetKind: string = '';
  @State private sheetOpen: boolean = false;
  /** 打开弹层时聚焦的语言组；空串从头展示 */
  @State private focusLanguage: string = '';
  /** AI 字幕生成 / 删除外挂 / 校准完成后由外层刷新详情（轨道与字幕列表都会变） */
  onChanged: () => void = (): void => {};

  /** 选中的文件：外部指定的，否则第一个 */
  private selectedFile(): LibraryFileView | null {
    for (const file of this.files) {
      if (file.id === this.selectedFileId) {
        return file;
      }
    }
    return this.files.length > 0 ? this.files[0] : null;
  }

  private isSelected(file: LibraryFileView): boolean {
    const selected: LibraryFileView | null = this.selectedFile();
    return selected !== null && selected.id === file.id;
  }

  private openSheet(kind: string, language: string): void {
    this.sheetKind = kind;
    this.focusLanguage = language;
    this.sheetOpen = true;
  }

  /** 下滑/点遮罩关掉时也会走这里（onDisappear 兜底），停掉弹层里的预览轮询 */
  private closeSheet(): void {
    this.sheetOpen = false;
    this.sheetKind = '';
    this.focusLanguage = '';
  }

  // MARK: 数据

  private audioEntries(file: LibraryFileView): TrackEntry[] {
    return trackAudioEntries(file.audio_streams ?? [], file.playback_defaults ?? null);
  }

  private subtitleEntries(file: LibraryFileView): TrackEntry[] {
    return trackSubtitleEntries(file.subtitle_streams, trackVideoStem(file.file_name),
      file.playback_defaults ?? null);
  }

  private audioGroups(file: LibraryFileView): TrackLanguageGroup[] {
    return trackGroupByLanguage(this.audioEntries(file));
  }

  private subtitleGroups(file: LibraryFileView): TrackLanguageGroup[] {
    return trackGroupByLanguage(this.subtitleEntries(file));
  }

  private visibleGroups(file: LibraryFileView, kind: string): TrackLanguageGroup[] {
    return this.rowGroups(file, kind).slice(0, this.fittingChipCount(file, kind));
  }

  private moreCount(file: LibraryFileView, kind: string): number {
    const groups: TrackLanguageGroup[] = this.rowGroups(file, kind);
    return Math.max(0, groups.length - this.fittingChipCount(file, kind));
  }

  private rowGroups(file: LibraryFileView, kind: string): TrackLanguageGroup[] {
    return kind === 'audio' ? this.audioGroups(file) : this.subtitleGroups(file);
  }

  /** 行内直接展示的语言芯片数：先试全放，放不下从多到少找到还能配上「+N 种」的最大值 */
  private fittingChipCount(file: LibraryFileView, kind: string): number {
    const groups: TrackLanguageGroup[] = this.rowGroups(file, kind);
    if (groups.length === 0) {
      return 0;
    }
    const budget: number = this.chipsBudgetVp(file, kind);
    let total: number = 0;
    for (const group of groups) {
      total += this.chipWidthVp(file, group);
    }
    if (total <= budget) {
      return Math.min(groups.length, MAX_VISIBLE_CHIPS);
    }
    const maxTry: number = Math.min(groups.length - 1, MAX_VISIBLE_CHIPS);
    for (let count: number = maxTry; count >= 1; count--) {
      let used: number = 0;
      for (let i: number = 0; i < count; i++) {
        used += this.chipWidthVp(file, groups[i]);
      }
      if (used + this.moreChipWidthVp(groups.length - count) <= budget) {
        return count;
      }
    }
    return 1;
  }

  /** 芯片可用宽度：窗口宽 − 页边距 − 行标签 − 行距 − 行尾元素（规格 / AI 徽章），再留 6 余量 */
  private chipsBudgetVp(file: LibraryFileView, kind: string): number {
    const windowVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    const reserve: number = kind === 'audio' ? this.specChipWidthVp(file) : this.badgeWidthVp();
    return windowVp - Theme.pagePadding * 2 - ROW_LABEL_WIDTH - ROW_GAP - reserve - 6;
  }

  /** 一个语言芯片的占宽：右外边距 + 边框 + 内边距 + 播放标？ + 语言 + 格式/条数 */
  private chipWidthVp(file: LibraryFileView, group: TrackLanguageGroup): number {
    let width: number = CHIP_MARGIN + CHIP_BORDER + CHIP_H_PAD;
    if (this.marksDefault(file) && group.hasDefault()) {
      width += 10 + CHIP_GAP;
    }
    width += this.textWidthVp(group.language, 12) + CHIP_GAP;
    width += group.entries.length === 1
      ? this.textWidthVp(group.entries[0].format, 11)
      : this.textWidthVp(`×${group.entries.length}`, 12);
    return width;
  }

  /** 「+N 种」芯片占宽 */
  private moreChipWidthVp(count: number): number {
    return CHIP_MARGIN + CHIP_BORDER + CHIP_H_PAD + this.textWidthVp(`+${count} 种`, 12);
  }

  /** 音轨行尾「最高规格」芯片占宽；无规格记 0 */
  private specChipWidthVp(file: LibraryFileView): number {
    const spec: string = this.topSpec(file);
    if (spec.length === 0) {
      return 0;
    }
    return CHIP_MARGIN + CHIP_BORDER + CHIP_H_PAD + this.textWidthVp(spec, 12);
  }

  /** 字幕行尾 AI 徽章占宽（非管理员记 0）。徽章文字有闲 / 运行 / 未完成三态，运行中更短，
   *  按最宽的闲时文案「AI 生成字幕」预留；模型未接入时徽章换成整条提示（降级态，会折行） */
  private badgeWidthVp(): number {
    if (!this.canGenSubtitles()) {
      return 0;
    }
    // 右外边距 4 + 边框 2 + 内边距 20 + 图标 16 + 间距 6
    return 4 + 2 + 20 + 16 + CHIP_GAP + this.textWidthVp('AI 生成字幕', 12);
  }

  /** 单行文字实测宽（vp）：measure 返回 px，用屏密度换算；测失败按字数粗估（只大不小，
   *  宁可少放芯片也不折行） */
  private textWidthVp(text: string, fontSize: number): number {
    const px: number = this.getUIContext().getMeasureUtils().measureText({
      textContent: text,
      fontSize: `${fontSize}fp`,
      fontWeight: FontWeight.Medium
    });
    if (px > 0) {
      return this.getUIContext().px2vp(px);
    }
    return text.length * fontSize;
  }

  /** 芯片上的播放标只在服务端记下了起播默认时画（原盘/未探测时没有这个信息） */
  private marksDefault(file: LibraryFileView): boolean {
    return file.playback_defaults !== null && file.playback_defaults !== undefined;
  }

  /** 音轨行尾的最高规格摘要；只有一条音轨时芯片已写格式，不重复挂 */
  private topSpec(file: LibraryFileView): string {
    const spec: string | null = trackTopAudioSpec(file.audio_streams ?? []);
    return spec !== null ? spec : '';
  }

  /** 外挂字幕文件名（生成面板的源候选回退名单） */
  private externalSubtitleNames(file: LibraryFileView): string[] {
    const names: string[] = [];
    for (const stream of file.subtitle_streams) {
      if (stream.external) {
        const name: string = stream.file_name ?? '';
        if (name.length > 0) {
          names.push(name);
        }
      }
    }
    return names;
  }

  /** AI 字幕生成只对管理员开放（iOS 同款门槛） */
  private canGenSubtitles(): boolean {
    return Permissions.fromSession(AppModel.shared.session).isAdmin;
  }

  // MARK: 布局

  build() {
    // 根节点恒在：files 清空时也要留着 bindSheet 宿主，否则弹层随内容一起卸载
    Column({ space: 10 }) {
      if (this.files.length > 0 && this.selectedFile() !== null) {
        if (this.files.length > 1) {
          this.VersionPicker(this.selectedFile() as LibraryFileView)
        }
        this.AudioTrackRow(this.selectedFile() as LibraryFileView)
        this.SubtitleTrackRow(this.selectedFile() as LibraryFileView)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4 })
    .bindSheet($$this.sheetOpen, this.TrackSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      // 半模态上最厚的沉浸光感材质（规范推荐）；不支持的设备自动落回 backgroundColor
      systemMaterial: SpatialMaterial.sheet(),
      backgroundColor: Theme.bg,
      onDisappear: (): void => {
        this.closeSheet();
      }
    })
  }

  /** 弹层内容：按语言分组的完整轨道列表（列表 + 字幕预览都在里面） */
  @Builder
  TrackSheet() {
    if (this.sheetKind === 'audio' || this.sheetKind === 'subtitle') {
      MediaTrackListSheet({
        kind: this.sheetKind,
        file: this.selectedFile(),
        focusLanguage: this.focusLanguage,
        onChanged: (): void => {
          this.onChanged();
        },
        onClose: (): void => {
          this.closeSheet();
        }
      })
    }
  }

  /** 多版本：全宽的版本选择菜单（分辨率 — 文件名；同 iOS versionPicker） */
  @Builder
  VersionPicker(file: LibraryFileView) {
    Row({ space: 8 }) {
      Text(trackFileOptionLabel(file))
        .fontSize(15)
        .fontColor('rgba(255,255,255,0.9)')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(12)
        .fontColor(['rgba(255,255,255,0.6)'])
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 9, bottom: 9 })
    .backgroundColor('rgba(255,255,255,0.055)')
    .borderRadius(12)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
    .bindMenu(this.VersionMenu())
  }

  @Builder
  VersionMenu() {
    Menu() {
      ForEach(this.files, (file: LibraryFileView) => {
        MenuItem({ content: `${this.isSelected(file) ? '✓ ' : ''}${trackFileOptionLabel(file)}` })
          .onClick(() => {
            this.selectedFileId = file.id;
          })
      }, (file: LibraryFileView) => `${file.id}`)
    }
  }

  /** 音轨行：语言芯片 + 最高规格；尚未探测与空列表给不同文案 */
  @Builder
  AudioTrackRow(file: LibraryFileView) {
    Row({ space: ROW_GAP }) {
      Text('音轨')
        .fontSize(15)
        .fontColor(Theme.textFaint)
        .width(ROW_LABEL_WIDTH)
      Flex({ wrap: FlexWrap.Wrap, alignContent: FlexAlign.Start }) {
        if (file.audio_streams === null || file.audio_streams === undefined) {
          Text('尚未探测')
            .fontSize(15)
            .fontColor(Theme.textMuted)
            .height(32)
        } else {
          if (this.audioGroups(file).length === 0) {
            Text('文件内没有音轨')
              .fontSize(15)
              .fontColor(Theme.textMuted)
              .height(32)
          } else {
            ForEach(this.visibleGroups(file, 'audio'), (group: TrackLanguageGroup) => {
              this.LanguageChip(file, group, 'audio')
            }, (group: TrackLanguageGroup) => `audio-${group.language}`)
            if (this.moreCount(file, 'audio') > 0) {
              this.MoreChip(this.moreCount(file, 'audio'), 'audio')
            }
            this.AudioSpecChip(file)
          }
        }
      }
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 字幕行：语言芯片 + AI 生成徽章；空的也保留徽章（可以先给它生成一份） */
  @Builder
  SubtitleTrackRow(file: LibraryFileView) {
    Row({ space: ROW_GAP }) {
      Text('字幕')
        .fontSize(15)
        .fontColor(Theme.textFaint)
        .width(ROW_LABEL_WIDTH)
      Flex({ wrap: FlexWrap.Wrap, alignContent: FlexAlign.Start }) {
        if (this.subtitleGroups(file).length === 0) {
          Text('无内封或外挂字幕')
            .fontSize(15)
            .fontColor(Theme.textMuted)
            .height(32)
          this.GenBadge(file)
        } else {
          ForEach(this.visibleGroups(file, 'subtitle'), (group: TrackLanguageGroup) => {
            this.LanguageChip(file, group, 'subtitle')
          }, (group: TrackLanguageGroup) => `subtitle-${group.language}`)
          if (this.moreCount(file, 'subtitle') > 0) {
            this.MoreChip(this.moreCount(file, 'subtitle'), 'subtitle')
          }
          this.GenBadge(file)
        }
      }
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 语言芯片：默认组带播放标；单条时给格式，多条给 ×N；点开聚焦该语言的弹层 */
  @Builder
  LanguageChip(file: LibraryFileView, group: TrackLanguageGroup, kind: string) {
    Row({ space: 6 }) {
      if (this.marksDefault(file) && group.hasDefault()) {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(8)
          .fontColor([Theme.accentStrong])
      }
      Text(group.language)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('rgba(255,255,255,0.85)')
      if (group.entries.length === 1) {
        Text(group.entries[0].format)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('rgba(255,255,255,0.5)')
      } else {
        Text(`×${group.entries.length}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('rgba(255,255,255,0.5)')
      }
    }
    .height(32)
    .padding({ left: 9, right: 9 })
    .backgroundColor('rgba(255,255,255,0.075)')
    .borderRadius(7)
    .border({ width: 1, color: 'rgba(255,255,255,0.06)' })
    .margin({ right: CHIP_MARGIN, bottom: 6 })
    .onClick(() => {
      this.openSheet(kind, group.language);
    })
  }

  /** 折叠行放不下的语言：点开完整列表（不聚焦某一组，从头看） */
  @Builder
  MoreChip(count: number, kind: string) {
    Row() {
      Text(`+${count} 种`)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textMuted)
    }
    .height(32)
    .padding({ left: 9, right: 9 })
    .backgroundColor('rgba(255,255,255,0.045)')
    .borderRadius(7)
    .border({ width: 1, color: 'rgba(255,255,255,0.06)' })
    .margin({ right: CHIP_MARGIN, bottom: 6 })
    .onClick(() => {
      this.openSheet(kind, '');
    })
  }

  /** 音轨行尾的最高规格摘要（格式 · 声道；同 iOS topAudioSpec） */
  @Builder
  AudioSpecChip(file: LibraryFileView) {
    if (this.topSpec(file).length > 0) {
      Row() {
        Text(this.topSpec(file))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('rgba(255,255,255,0.8)')
      }
      .height(32)
      .padding({ left: 9, right: 9 })
      .backgroundColor('rgba(255,255,255,0.04)')
      .borderRadius(7)
      .border({ width: 1, color: 'rgba(255,255,255,0.14)' })
      .margin({ right: CHIP_MARGIN, bottom: 6 })
    }
  }

  /** AI 字幕生成入口：非管理员不实例化（按钮内部有 SSE/轮询，不做无用功） */
  @Builder
  GenBadge(file: LibraryFileView) {
    if (this.canGenSubtitles()) {
      TrackSubtitleGenButton({
        fileId: file.id,
        fileName: file.file_name,
        filePath: file.file_path,
        fileMissing: file.missing,
        externalSubtitleNames: this.externalSubtitleNames(file),
        onChanged: (): void => {
          this.onChanged();
        }
      })
        .margin({ right: CHIP_MARGIN, bottom: 6 })
    }
  }
}
