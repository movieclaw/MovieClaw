import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { LibraryPayload, LibraryView } from '../api/Models';

/** 分区（对应 iOS `LibraryFormSheet` 编辑态的分层：按用途分区折叠，同时只开一个） */
class FormSection {
  static readonly basic: string = 'basic';
  static readonly scan: string = 'scan';
  static readonly access: string = 'access';
}

/**
 * 媒体库编辑表单（对应 iOS `ManageEditLibraryForm`）。
 *
 * iOS 的设计要点是**分层**：按用途分区折叠（基本信息 / 封面 / 扫描与监控 / 收藏范围 /
 * 刮削设置 / 可见范围），**默认全收起、同时只开一个**；折叠态的摘要行先回答
 * 「这个库配成了什么样」，改哪项点哪项。类型创建后不可改，只读展示。
 *
 * 本轮做三个分区（基本信息 / 扫描与监控 / 可见范围），够覆盖日常改动；
 * 封面、收藏范围、刮削设置留待后续。
 */
@ComponentV2
export struct LibraryFormSheet {
  @Require @Param libraryId: number;
  /** 保存成功回调（宿主用来刷新列表） */
  @Require @Param onSaved: (view: LibraryView) => void;
  /** 关闭弹层 */
  @Require @Param onClose: () => void;

  @Local private library: LibraryView | null = null;
  @Local private open: string = FormSection.basic;
  @Local private busy: boolean = false;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';

  // 可编辑字段
  @Local private name: string = '';
  @Local private realtimeWatch: boolean = false;
  @Local private autoClearMissing: boolean = false;
  @Local private generateThumbnails: boolean = false;
  @Local private extractChapterImages: boolean = false;
  @Local private detectSegments: boolean = false;
  @Local private excludeFromHome: boolean = false;
  @Local private autoSeriesCollections: boolean = false;
  @Local private accessMode: string = 'all';

  private started: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = true;
    try {
      const view: LibraryView = await api.libraryGet(this.libraryId);
      this.library = view;
      this.name = view.name;
      this.realtimeWatch = view.realtime_watch;
      this.autoClearMissing = view.auto_clear_missing;
      this.generateThumbnails = view.generate_thumbnails;
      this.extractChapterImages = view.extract_chapter_images;
      this.detectSegments = view.detect_media_segments;
      this.excludeFromHome = view.exclude_from_home;
      this.autoSeriesCollections = view.auto_series_collections;
      this.accessMode = view.access_mode;
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 保存

  /**
   * 保存：**只提交表单里有的字段**（其余传 null 让后端保持原值）。
   * 类型（kind）创建后不可改，所以原样回传。
   */
  private async save(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: LibraryView | null = this.library;
    if (api === null || view === null || this.busy) {
      return;
    }
    const trimmed: string = this.name.trim();
    if (trimmed.length === 0) {
      this.toast('库名不能为空');
      return;
    }
    this.busy = true;
    try {
      const payload: LibraryPayload = {
        name: trimmed,
        kind: view.kind,
        root_paths: view.root_paths,
        realtime_watch: this.realtimeWatch,
        auto_clear_missing: this.autoClearMissing,
        generate_thumbnails: this.generateThumbnails,
        extract_chapter_images: this.extractChapterImages,
        detect_media_segments: this.detectSegments,
        exclude_from_home: this.excludeFromHome,
        auto_series_collections: this.autoSeriesCollections,
        access_mode: this.accessMode
      };
      const saved: LibraryView = await api.libraryUpdate(this.libraryId, payload);
      this.toast(`已保存「${saved.name}」`);
      this.onSaved(saved);
      this.onClose();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  // MARK: 文案

  private kindLabel(kind: string): string {
    if (kind === 'movie') {
      return '电影库';
    }
    if (kind === 'tv') {
      return '剧集库';
    }
    if (kind === 'video') {
      return '视频库';
    }
    if (kind === 'photo') {
      return '相册库';
    }
    return kind;
  }

  private canScrape(): boolean {
    const view: LibraryView | null = this.library;
    return view !== null && (view.kind === 'movie' || view.kind === 'tv');
  }

  private basicSummary(): string {
    const view: LibraryView | null = this.library;
    if (view === null) {
      return '';
    }
    return `${this.kindLabel(view.kind)}  ·  ${view.root_paths.length} 个根目录`;
  }

  /** 折叠态摘要行：先回答「这个库配成了什么样」（iOS 的设计要点） */
  private scanSummary(): string {
    const on: string[] = [];
    if (this.realtimeWatch) {
      on.push('实时监控');
    }
    if (this.autoClearMissing) {
      on.push('自动清缺失');
    }
    if (this.generateThumbnails) {
      on.push('缩略图');
    }
    return on.length === 0 ? '全部关闭' : on.join('  ·  ');
  }

  private accessSummary(): string {
    const parts: string[] = [this.accessLabel(this.accessMode)];
    if (this.excludeFromHome) {
      parts.push('首页不显示');
    }
    return parts.join('  ·  ');
  }

  private accessLabel(mode: string): string {
    // 后端实际用的枚举是 `everyone`（不是 `all`/`public`）——漏了它会把原始值直接显示给用户
    if (mode === 'everyone' || mode === 'all' || mode === 'public') {
      return '全部成员可见';
    }
    if (mode === 'admin' || mode === 'admins') {
      return '仅管理员可见';
    }
    if (mode === 'members') {
      return '指定成员可见';
    }
    return mode;
  }

  private toggleOpen(section: string): void {
    this.open = this.open === section ? '' : section;
  }

  // MARK: 视图

  build() {
    Column() {
      this.SheetBar()
      if (this.loading) {
        this.LoadingState()
      } else if (this.library === null) {
        this.ErrorState()
      } else {
        Scroll() {
          Column({ space: 12 }) {
            this.Section(FormSection.basic, '基本信息', this.basicSummary())
            this.Section(FormSection.scan, '扫描与监控', this.scanSummary())
            this.Section(FormSection.access, '可见范围', this.accessSummary())
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
  }

  /** 顶栏：左上 ✕ 关闭、右上「保存」（对应 iOS 的 sheet 工具条） */
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
      Text('编辑媒体库')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Blank()
      Text(this.busy ? '保存中…' : '保存')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.busy ? Theme.textFaint : Theme.accentStrong)
        .padding({ left: 8, right: 8 })
        .height(40)
        .onClick(() => {
          this.save();
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
      Text('正在加载媒体库…')
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
      Text('媒体库加载失败')
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

  /** 一个分区：头行（标题 + 摘要 + 箭头）+ 展开后的内容 */
  @Builder
  Section(section: string, title: string, summary: string) {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text(title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
          if (this.open !== section) {
            Text(summary)
              .fontSize(13)
              .fontColor(Theme.textMuted)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph(this.open === section ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(13)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .onClick(() => {
        this.toggleOpen(section);
      })

      if (this.open === section) {
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
        if (section === FormSection.basic) {
          this.BasicFields()
        } else if (section === FormSection.scan) {
          this.ScanFields()
        } else {
          this.AccessFields()
        }
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 基本信息：名称可改；**类型创建后不可改**，只读展示（同 iOS）；根目录只读列出 */
  @Builder
  BasicFields() {
    Column({ space: 0 }) {
      this.FieldLabel('名称')
      TextInput({ text: this.name })
        .width('100%')
        .height(42)
        .fontSize(15)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .margin({ bottom: 14 })
        .onChange((value: string): void => {
          this.name = value;
        })

      this.FieldLabel('类型')
      Text(this.library !== null ? this.kindLabel(this.library.kind) : '')
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .margin({ bottom: 6 })
      Text('类型创建后不可更改。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .margin({ bottom: 14 })

      this.FieldLabel(`根目录（${this.library !== null ? this.library.root_paths.length : 0}）`)
      ForEach(this.library !== null ? this.library.root_paths : [], (path: string) => {
        Text(path)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
          .padding({ top: 8, bottom: 8 })
      }, (path: string) => path)
      Text('根目录的增删在「管理媒体库」里做。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .padding({ bottom: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
  }

  /** 扫描与监控：各开关 + 一句说明 */
  @Builder
  ScanFields() {
    Column({ space: 0 }) {
      this.SwitchRow('实时监控', '目录里有新文件时自动扫描', this.realtimeWatch, (on: boolean): void => {
        this.realtimeWatch = on;
      })
      this.SwitchRow('自动清理缺失', '文件不在了就自动从库里移除记录', this.autoClearMissing, (on: boolean): void => {
        this.autoClearMissing = on;
      })
      this.SwitchRow('生成缩略图', '为每个视频生成预览图', this.generateThumbnails, (on: boolean): void => {
        this.generateThumbnails = on;
      })
      if (this.canScrape()) {
        this.SwitchRow('提取章节图', '从章节标记处抓帧当剧照', this.extractChapterImages, (on: boolean): void => {
          this.extractChapterImages = on;
        })
        this.SwitchRow('检测媒体片段', '识别片头片尾，跳过时用', this.detectSegments, (on: boolean): void => {
          this.detectSegments = on;
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 6, bottom: 10 })
  }

  /** 可见范围 */
  @Builder
  AccessFields() {
    Column({ space: 0 }) {
      this.FieldLabel('谁能看到')
      Row({ space: 8 }) {
        this.AccessChip('all', '全部成员')
        this.AccessChip('admin', '仅管理员')
        this.AccessChip('members', '指定成员')
      }
      .width('100%')
      .margin({ bottom: 14 })

      this.SwitchRow('首页不显示', '这个库不出现在「我的媒体库」里', this.excludeFromHome, (on: boolean): void => {
        this.excludeFromHome = on;
      })
      if (this.canScrape()) {
        this.SwitchRow('自动系列合集', '同系列的作品自动归成一个合集', this.autoSeriesCollections, (on: boolean): void => {
          this.autoSeriesCollections = on;
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 14, bottom: 10 })
  }

  @Builder
  AccessChip(mode: string, label: string) {
    Text(label)
      .fontSize(14)
      .fontColor(this.accessMode === mode ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.accessMode === mode ? Theme.accent : Theme.glassFill)
      .borderRadius(16)
      .onClick(() => {
        this.accessMode = mode;
      })
  }

  @Builder
  FieldLabel(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor(Theme.textFaint)
      .margin({ bottom: 6 })
  }

  @Builder
  SwitchRow(title: string, hint: string, value: boolean, onChange: (on: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor(Theme.text)
        Text(hint)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .maxLines(2)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(Theme.accent)
        .onChange((isOn: boolean): void => {
          onChange(isOn);
        })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }
}
