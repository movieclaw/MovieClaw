import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  DuplicateFileView,
  DuplicateFilesData,
  DuplicateGroupView,
  DuplicateItemView,
  DuplicateResolveAllPayload,
  DuplicateResolvePayload,
  DuplicateSeasonView,
  DuplicateUnitView,
  DuplicateVersionView,
  TrashedBatchResultView
} from '../api/Models';
import { AppFooter } from '../common/AppFooter';

/**
 * 重复项条目的数据源（LazyForEach 用）。
 *
 * 原来整页 Scroll > Column 里一个圆角容器 ForEach(items) 全量建。改成外层 List，条目行进
 * 一个 ListItemGroup（保留 insetGrouped 圆角容器 + 行间分隔线），LazyForEach 只建可视区附近
 * 的行。展开后的季/单元/文件子列表本就由 `if (expanded.includes(...))` 守卫，按需建，不动。
 */
class DuplicateItemSource implements IDataSource {
  private items: DuplicateItemView[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): DuplicateItemView {
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

  setItems(items: DuplicateItemView[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function DuplicatesBuilder() {
  DuplicatesPage()
}

/**
 * 重复文件（对应 iOS `Features/Library/ManageDuplicateFiles.swift`）。
 *
 * 解决的问题：同一个单元（一集 / 一部电影）在库里有**多份**文件（不同来源、不同画质、
 * 洗版留下的旧版），占着磁盘。
 *
 * **核心 UX 是「后端已经替你挑好了」**：每份文件带 `suggested` 与 `suggest_reason`，
 * 界面要把**推荐的那份标出来并说明为什么**——不然用户面对三份 2160p 只能瞎选。
 *
 * 三种粒度都做（同 iOS）：
 * - **按份**：保留这一份，其余进回收站；
 * - **按季**：这一季都用某个版本（`keep_version`）——同一版本横跨很多集时才不用点几十次；
 * - **全保留**：这一季不做去重（用户就是想都留着）。
 *
 * **所有「保留」操作的后果都是「其余的进回收站」**，不是直接删——所以确认框里写的是
 * 「其余 N 份会进回收站」，而不是「会被删除」。这是回收站那一轮定下的安全设计，这里沿用。
 */
@ComponentV2
export struct DuplicatesPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  private libraryId: number = 0;

  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private data: DuplicateFilesData | null = null;
  /** 当前看的组：`tier` 的 key（空 = 全部） */
  @Local private tier: string = '';
  @Local private busy: boolean = false;
  @Local private expanded: string[] = [];
  /** 重复项行数据源（LazyForEach 只建可视区附近的行） */
  private itemSource: DuplicateItemSource = new DuplicateItemSource();

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
      this.data = await api.libraryDuplicatesList(
        this.tier.length > 0 ? this.tier : undefined,
        undefined, undefined,
        this.libraryId > 0 ? this.libraryId : undefined);
      this.failed = false;
      this.expanded = [];
      this.itemSource.setItems(this.items());
    } catch (error) {
      this.failed = true;
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  private items(): DuplicateItemView[] {
    const view: DuplicateFilesData | null = this.data;
    return view !== null ? view.items : [];
  }

  private groups(): DuplicateGroupView[] {
    const view: DuplicateFilesData | null = this.data;
    if (view === null) {
      return [];
    }
    return view.tiers.concat(view.review_groups);
  }

  private toggle(key: string): void {
    if (this.expanded.includes(key)) {
      this.expanded = this.expanded.filter((value: string): boolean => value !== key);
    } else {
      this.expanded = this.expanded.concat([key]);
    }
  }

  // MARK: 动作

  /** 按份保留：其余进回收站 */
  private confirmKeepFile(item: DuplicateItemView, unit: DuplicateUnitView,
    file: DuplicateFileView): void {
    const others: number = unit.files.length - 1;
    if (others <= 0) {
      this.toast('这个单元只有一份文件');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '保留这一份',
      message: `保留「${file.quality_label}」，`
        + `其余 ${others} 份会**进回收站**（不是直接删除，之后还能恢复）。\n\n`
        + `保留：${file.file_name}`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '保留这一份',
        action: (): void => {
          this.keepFile(item, unit, file);
        }
      }
    });
  }

  private async keepFile(item: DuplicateItemView, unit: DuplicateUnitView,
    file: DuplicateFileView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const payload: DuplicateResolvePayload = {
        media_item_id: item.media_item.id,
        season_number: unit.season_number,
        episode_number: unit.episode_number,
        keep_file_id: file.id
      };
      const result: TrashedBatchResultView = await api.libraryDuplicatesResolve(payload);
      this.report(result, '处理');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  /** 按季保留某个版本：省得同一版本横跨几十集时点几十次 */
  private async keepVersion(item: DuplicateItemView, season: DuplicateSeasonView,
    version: DuplicateVersionView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const payload: DuplicateResolvePayload = {
        media_item_id: item.media_item.id,
        season_number: season.season_number,
        keep_version: version.key
      };
      const result: TrashedBatchResultView = await api.libraryDuplicatesResolve(payload);
      this.report(result, '处理');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  /** 全保留：这一季不做去重 */
  private async keepAll(item: DuplicateItemView, season: DuplicateSeasonView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const payload: DuplicateResolvePayload = {
        media_item_id: item.media_item.id,
        season_number: season.season_number,
        keep_all: true
      };
      await api.libraryDuplicatesResolve(payload);
      this.toast('这一季不再提示去重');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  /** 整组一键处理：全组的推荐份都保留，其余的进回收站 */
  private confirmKeepGroup(group: DuplicateGroupView): void {
    this.getUIContext().showAlertDialog({
      title: `按推荐处理「${group.label}」`,
      message: `这一组有 ${group.files} 个文件（${Formatters.bytes(group.bytes)}）。\n\n`
        + '会**按后端的推荐**每个单元保留一份，其余进回收站。'
        + '推荐是按画质、来源与洗版状态算的，想逐条看过就别用这个。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '按推荐处理',
        action: (): void => {
          this.keepGroup(group);
        }
      }
    });
  }

  private async keepGroup(group: DuplicateGroupView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const payload: DuplicateResolveAllPayload = {
        tier: group.key,
        library_id: this.libraryId > 0 ? this.libraryId : null,
        keep_all: false
      };
      const result: TrashedBatchResultView = await api.libraryDuplicatesResolveAll(payload);
      this.report(result, '处理');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  /** 批量结果分开说：只说「完成」会掩盖「一部分失败了」 */
  private report(result: TrashedBatchResultView, verb: string): void {
    if (result.failed.length === 0) {
      this.toast(`${verb}了 ${result.done} 个，其余的已进回收站`);
      return;
    }
    this.getUIContext().showAlertDialog({
      title: `${verb}部分失败`,
      message: `成功 ${result.done} 个，失败 ${result.failed.length} 个。\n\n`
        + `第一个失败的原因：${result.failed[0].error}`,
      primaryButton: {
        value: '知道了',
        action: (): void => {
        }
      }
    });
  }

  private async scan(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      await api.libraryDuplicatesScan();
      this.toast('已开始扫描，稍后刷新看结果');
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        Row() {
          PageTopBar({ title: '重复文件', onBack: (): void => {
          this.navStack.pop();
        }})
          // 右上角动作（原来挂在原生 menus 上；改自绘顶栏后要自己放）
          this.TopMenus()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
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
    // iOS .navigationTitle("重复文件") + inline：NavDestination 原生标题栏，去掉自绘 TopBar
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      if (!this.started) {
        this.started = true;
        this.load();
      }
    })
  }

  /** 右上角动作：重新扫描（原自绘顶栏右侧按钮，移入原生标题栏） */
  @Builder
  TopMenus() {
    Text(this.busy ? '…' : '重新扫描')
      .fontSize(15)
      .fontColor(Theme.accentStrong)
      .padding({ left: 10, right: 4 })
      .onClick(() => {
        this.scan();
      })
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress().width(24).height(24).color(Theme.textMuted)
      Text('正在统计重复…').fontSize(13).fontColor(Theme.textFaint)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 10 }) {
      Text('读取失败').fontSize(15).fontColor(Theme.text)
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
    // Scroll > Column 全量建改成 List：条目行进 ListItemGroup（保留 insetGrouped 圆角容器
    // + 行间分隔线），LazyForEach 只建可视区附近的行。
    List({ space: 10 }) {
      ListItem() {
        this.Summary()
      }
      ListItem() {
        this.GroupChips()
      }
      if (this.items().length === 0) {
        ListItem() {
          this.EmptyState()
        }
      } else {
        ListItemGroup() {
          LazyForEach(this.itemSource, (item: DuplicateItemView, index: number) => {
            ListItem() {
              this.ItemCard(item)
              if (index < this.items().length - 1) {
                Divider().color(Theme.line).margin({ left: 16, right: 16 })
              }
            }
          }, (item: DuplicateItemView) => `d-${item.media_item.id}`)
        }
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      }
      ListItem() {
        AppFooter()
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .cachedCount(4)
    .alignListItem(ListItemAlign.Start)
    .padding({ left: 16, right: 16, top: 8, bottom: Theme.tabBarInset })
  }

  @Builder
  Summary() {
    if (this.data !== null) {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(`${(this.data as DuplicateFilesData).total_units} 个单元有多份`)
            .fontSize(15)
            .fontColor(Theme.text)
          Text(`· 可省 ${Formatters.bytes((this.data as DuplicateFilesData).total_bytes)}`)
            .fontSize(13)
            .fontColor(Theme.ok)
        }
        .width('100%')
        Text(`${(this.data as DuplicateFilesData).total_files} 个文件 / `
          + `${(this.data as DuplicateFilesData).total_items} 部作品`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
        // 扫描状态：正在扫就把进度说出来，别让用户对着旧数字做决定
        if ((this.data as DuplicateFilesData).scan.status !== null
          && (this.data as DuplicateFilesData).scan.status !== undefined) {
          Text(`扫描${(this.data as DuplicateFilesData).scan.status}`
            + ((this.data as DuplicateFilesData).scan.percent !== null
              && (this.data as DuplicateFilesData).scan.percent !== undefined
              ? ` ${Math.round((this.data as DuplicateFilesData).scan.percent ?? 0)}%` : ''))
            .fontSize(12)
            .fontColor(Theme.info)
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  GroupChips() {
    Scroll() {
      Row({ space: 8 }) {
        Text('全部')
          .fontSize(13)
          .fontColor(this.tier.length === 0 ? '#0b0d12' : Theme.textMuted)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.tier.length === 0 ? Theme.accent : Theme.glassFill)
          .borderRadius(14)
          .onClick(() => {
            this.tier = '';
            this.load();
          })
        ForEach(this.groups(), (group: DuplicateGroupView) => {
          Text(`${group.label} ${group.units}`)
            .fontSize(13)
            .fontColor(this.tier === group.key ? '#0b0d12' : Theme.textMuted)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.tier === group.key ? Theme.accent : Theme.glassFill)
            .borderRadius(14)
            .onClick(() => {
              this.tier = group.key;
              this.load();
            })
            .gesture(LongPressGesture().onAction(() => {
              // 长按组胶囊 = 按推荐整组处理（同 iOS 的 keepGroup）
              this.confirmKeepGroup(group);
            }))
        }, (group: DuplicateGroupView) => group.key)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  @Builder
  EmptyState() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
        .fontSize(28)
        .fontColor([Theme.ok])
      Text('没有重复文件')
        .fontSize(15)
        .fontColor(Theme.textMuted)
      Text('同一个单元只有一份文件，或者你已经处理过了。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .padding({ top: 80, bottom: 40 })
  }

  @Builder
  ItemCard(item: DuplicateItemView) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Column({ space: 3 }) {
          Text(item.media_item.title)
            .fontSize(15)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${item.library.name}`)
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph(this.expanded.includes(`${item.media_item.id}`)
          ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .onClick(() => {
        this.toggle(`${item.media_item.id}`);
      })

      if (this.expanded.includes(`${item.media_item.id}`)) {
        ForEach(item.seasons, (season: DuplicateSeasonView) => {
          this.SeasonBlock(item, season)
        }, (season: DuplicateSeasonView) => `s-${item.media_item.id}-${season.season_number}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
  }

  @Builder
  SeasonBlock(item: DuplicateItemView, season: DuplicateSeasonView) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(season.uniform ? `整季统一` : `第 ${season.season_number} 季`)
          .fontSize(13)
          .fontColor(Theme.textMuted)
        Blank()
        Text('这一季都保留某个版本')
          .fontSize(12)
          .fontColor(Theme.accentStrong)
          .bindMenu(this.VersionMenu(item, season))
        Text('全保留')
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .padding({ left: 8 })
          .onClick(() => {
            this.keepAll(item, season);
          })
      }
      .width('100%')

      ForEach(season.units, (unit: DuplicateUnitView) => {
        this.UnitBlock(item, unit)
      }, (unit: DuplicateUnitView) => `u-${unit.season_number}-${unit.episode_number}-${unit.bucket}`)
    }
    .width('100%')
    .padding({ top: 6 })
  }

  @Builder
  UnitBlock(item: DuplicateItemView, unit: DuplicateUnitView) {
    Column({ space: 6 }) {
      if (unit.episode_number > 0) {
        Text(`第 ${unit.episode_number} 集`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
      ForEach(unit.files, (file: DuplicateFileView) => {
        this.FileRow(item, unit, file)
      }, (file: DuplicateFileView) => `df-${file.id}`)
    }
    .width('100%')
    .padding({ top: 4 })
  }

  /** 一份文件：**推荐的那份高亮 + 说明理由**，这是整个页面的核心 */
  @Builder
  FileRow(item: DuplicateItemView, unit: DuplicateUnitView, file: DuplicateFileView) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        if (file.suggested) {
          Text('推荐')
            .fontSize(10)
            .fontColor('#0b0d12')
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(Theme.ok)
            .borderRadius(5)
        }
        Text(file.quality_label)
          .fontSize(13)
          .fontColor(Theme.text)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(Formatters.bytes(file.size_bytes))
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      Text(this.fileMeta(file))
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 后端的推荐理由：不写的话用户面对三份 2160p 只能瞎选
      if (file.suggested && file.suggest_reason !== null && file.suggest_reason !== undefined
        && file.suggest_reason.length > 0) {
        Text(`为什么推荐它：${file.suggest_reason}`)
          .fontSize(11)
          .fontColor(Theme.ok)
          .width('100%')
      }
      if (file.kept_at !== null && file.kept_at !== undefined && file.kept_at.length > 0) {
        Text('这份是上次选择保留的')
          .fontSize(11)
          .fontColor(Theme.info)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(file.suggested ? 'rgba(74, 222, 128, 0.08)' : Theme.surfaceRaised)
    .borderRadius(8)
    .border({ width: 1, color: file.suggested ? 'rgba(74, 222, 128, 0.35)' : Theme.line })
    .onClick(() => {
      this.confirmKeepFile(item, unit, file);
    })
  }

  private fileMeta(file: DuplicateFileView): string {
    const parts: string[] = [];
    if (file.resolution !== null && file.resolution !== undefined && file.resolution.length > 0) {
      parts.push(file.resolution);
    }
    if (file.video_codec !== null && file.video_codec !== undefined && file.video_codec.length > 0) {
      parts.push(file.video_codec);
    }
    if (file.hdr !== null && file.hdr !== undefined && file.hdr.length > 0) {
      parts.push(file.hdr);
    }
    if (file.audio_label !== null && file.audio_label !== undefined && file.audio_label.length > 0) {
      parts.push(file.audio_label);
    }
    const rate: number | null = file.bit_rate ?? null;
    if (rate !== null && rate > 0) {
      parts.push(`${(rate / 1000000).toFixed(1)} Mbps`);
    }
    parts.push(file.origin.label);
    return parts.join('  ·  ');
  }

  /**
   * 按季选版本：同一版本横跨几十集时，这个入口省得用户点几十次。
   * 用菜单**把每个版本都列出来**——之前这里算了版本名却没用上、永远只弹第 0 个，
   * 是个「编译得过、点了不对」的静默缺陷。
   */
  @Builder
  VersionMenu(item: DuplicateItemView, season: DuplicateSeasonView) {
    Menu() {
      ForEach(season.versions, (version: DuplicateVersionView) => {
        MenuItem({
          content: `${version.quality_label}（${version.episodes.length} 集`
            + `${version.suggested ? '，推荐' : ''}）`
        })
          .onClick(() => {
            this.confirmKeepVersion(item, season, version);
          })
      }, (version: DuplicateVersionView) => `v-${version.key}`)
    }
  }

  private confirmKeepVersion(item: DuplicateItemView, season: DuplicateSeasonView,
    version: DuplicateVersionView): void {
    this.getUIContext().showAlertDialog({
      title: '整季保留这个版本',
      message: `「${version.quality_label}」覆盖 ${version.episodes.length} 集`
        + `（${Formatters.bytes(version.bytes)}）。\n\n`
        + '这一季里不是这个版本的文件会进回收站（不是直接删除，之后还能恢复）。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '就保留它',
        action: (): void => {
          this.keepVersion(item, season, version);
        }
      }
    });
  }
}
