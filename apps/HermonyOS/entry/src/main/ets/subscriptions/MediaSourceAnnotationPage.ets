import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { MediaSourceAnnotationCandidateView, MediaSourceAnnotationPayload } from '../api/Models';
import { JsonValue, jsonGet, jsonIntValue } from '../api/JsonValue';

/** 片源标注页的路由参数（路由参数会被序列化，不要用 instanceof） */
export class MediaSourceAnnotationParams {
  readonly mediaItemId: number;
  /** 电影传 0（后端的电影单元哨兵） */
  readonly seasonNumber: number;
  readonly isMovie: boolean;

  constructor(mediaItemId: number, seasonNumber: number, isMovie: boolean) {
    this.mediaItemId = mediaItemId;
    this.seasonNumber = seasonNumber;
    this.isMovie = isMovie;
  }

  static of(param: Object | undefined | null): MediaSourceAnnotationParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: MediaSourceAnnotationParams = param as MediaSourceAnnotationParams;
    const id: number = raw.mediaItemId;
    if (!Number.isFinite(id) || id <= 0) {
      return null;
    }
    const season: number = Number.isFinite(raw.seasonNumber) ? Math.floor(raw.seasonNumber) : 0;
    return new MediaSourceAnnotationParams(Math.floor(id), season, raw.isMovie === true);
  }
}

/** 片源档位（对应 iOS `MediaSourceAnnotationSheet.options`；user-lowest 是「按最低档」的显式哨兵） */
class AnnotationOption {
  readonly value: string;
  readonly label: string;
  readonly consequence: string;
  readonly destructive: boolean;

  constructor(value: string, label: string, consequence: string, destructive: boolean) {
    this.value = value;
    this.label = label;
    this.consequence = consequence;
    this.destructive = destructive;
  }
}

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function MediaSourceAnnotationBuilder() {
  MediaSourceAnnotationPage()
}

/**
 * 整季片源标注页（对应 iOS `MediaSourceAnnotationSheet` / Web `media-source-annotation-dialog`）。
 *
 * 三段式：待标注文件名列表（扫一眼确认来源）→ 档位单选（每项写明后果，标注必须是知情选择）→ 确认。
 * 只动片源未知与既有人工标注的文件，已从文件名解析出片源的不被批量覆盖。
 */
@ComponentV2
export struct MediaSourceAnnotationPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  private mediaItemId: number = 0;
  private seasonNumber: number = 0;
  private isMovie: boolean = false;

  @Local private candidates: MediaSourceAnnotationCandidateView[] | null = null;
  @Local private picked: string = '';
  @Local private busy: boolean = false;
  @Local private errorMessage: string = '';
  @Local private failed: boolean = false;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private options(): AnnotationOption[] {
    return [
      new AnnotationOption('Remux', 'Remux', '原盘无损重封装，可标注的最高档；达到任何洗版目标，停止洗版', false),
      new AnnotationOption('Blu-ray', '蓝光重编码', '蓝光碟压制；高于 WEB-DL 目标，仅低于 Remux 目标', false),
      new AnnotationOption('WEB-DL', 'WEB-DL', '流媒体原流；洗版目标为 WEB-DL 时即达标停洗', false),
      new AnnotationOption('WEBRip', 'WEBRip', '流媒体二压；低于 WEB-DL 及以上目标，会自动洗版替换', false),
      new AnnotationOption('HDTV', 'TV 录制', '电视录制；低于洗版目标，会自动洗版替换', false),
      new AnnotationOption('user-lowest', '不确定（按最低档）', '按最差处理：整季会重新下载，替换为可证明达标的版本', true)
    ];
  }

  private labelOf(value: string): string {
    for (const option of this.options()) {
      if (option.value === value) {
        return option.label;
      }
    }
    return value;
  }

  private scopeLabel(): string {
    return this.isMovie ? '正片' : `第 ${this.seasonNumber} 季`;
  }

  private sourceDisplay(value: string | null): string {
    if (value === null || value.length === 0) {
      return '';
    }
    if (value === 'user-lowest') {
      return '最低档（人工标注）';
    }
    if (value === 'Disc') {
      return '原盘';
    }
    return value;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.failed = false;
    this.errorMessage = '';
    try {
      this.candidates = await api.libraryItemsListMediaSourceAnnotationCandidates(this.mediaItemId, this.seasonNumber);
    } catch (error) {
      this.failed = true;
      this.errorMessage = error instanceof ApiError && error.message.length > 0
        ? error.message : '未能加载待标注文件列表，请稍后重试';
    }
  }

  private async apply(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy || this.picked.length === 0) {
      return;
    }
    this.busy = true;
    this.errorMessage = '';
    try {
      const payload: MediaSourceAnnotationPayload = {
        media_item_id: this.mediaItemId,
        season_number: this.seasonNumber,
        media_source: this.picked
      };
      const result: Record<string, JsonValue> = await api.libraryItemsAnnotateMediaSource(payload);
      const rawCount: JsonValue | null = jsonGet(result, 'files');
      const files: number = jsonIntValue(rawCount) ?? (this.candidates === null ? 0 : this.candidates.length);
      this.toast(`已将 ${this.scopeLabel()}的 ${files} 个文件片源标注为「${this.labelOf(this.picked)}」`);
      this.navStack.pop();
    } catch (error) {
      this.errorMessage = error instanceof ApiError && error.message.length > 0
        ? error.message : '标注失败，请稍后重试';
    } finally {
      this.busy = false;
    }
  }

  build() {
    NavDestination() {
      Column() {
        PageTopBar({
          title: `标注${this.scopeLabel()}的片源`,
          onBack: (): void => {
            this.navStack.pop();
          }
        })
        Scroll() {
          Column({ space: 14 }) {
            Text('这些文件的文件名里没有可识别的片源标记，系统无法确认它们是否低于洗版目标。看一眼文件名，'
              + '把你知道的来源告诉系统——标注一次，之后整季自动参与洗版判定。')
              .fontSize(13)
              .fontColor(Theme.textMuted)

            if (this.failed) {
              Text(this.errorMessage)
                .fontSize(13)
                .fontColor(Theme.danger)
            } else if (this.candidates === null) {
              Row({ space: 8 }) {
                LoadingProgress().width(18).height(18).color(Theme.textMuted)
                Text('正在加载文件列表…').fontSize(13).fontColor(Theme.textMuted)
              }
              .width('100%')
              .padding({ top: 20, bottom: 20 })
            } else if (this.candidates.length === 0) {
              Text(`${this.scopeLabel()}没有片源未知的文件——已从文件名解析出片源的文件不会被批量覆盖。`)
                .fontSize(13)
                .fontColor(Theme.textMuted)
                .padding(14)
                .width('100%')
                .backgroundColor(Theme.surface)
                .borderRadius(Theme.cardRadius)
                .border({ width: 1, color: Theme.line })
            } else {
              this.FileList(this.candidates)
            }

            this.Options()

            Text(this.busy ? '标注中…' : '确认标注')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.canApply() ? '#0b0d12' : Theme.textFaint)
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding({ top: 14, bottom: 14 })
              .backgroundColor(this.canApply() ? Theme.accent : Theme.glassFill)
              .borderRadius(Theme.cardRadius)
              .onClick(() => {
                this.apply();
              })

            if (this.errorMessage.length > 0 && !this.failed) {
              Text(this.errorMessage)
                .fontSize(13)
                .fontColor(Theme.danger)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 8, bottom: Theme.tabBarInset })
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: MediaSourceAnnotationParams | null =
        MediaSourceAnnotationParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.mediaItemId = params.mediaItemId;
        this.seasonNumber = params.seasonNumber;
        this.isMovie = params.isMovie;
        this.load();
      }
    })
  }

  private canApply(): boolean {
    return !this.busy && this.picked.length > 0 && this.candidates !== null
      && this.candidates.length > 0 && !this.failed;
  }

  @Builder
  FileList(list: MediaSourceAnnotationCandidateView[]) {
    Column({ space: 0 }) {
      Text('待标注文件')
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ bottom: 6 })
      Column({ space: 0 }) {
        ForEach(list, (file: MediaSourceAnnotationCandidateView, index: number) => {
          Column() {
            Row({ space: 8 }) {
              Text(file.file_name)
                .fontSize(15)
                .fontColor(Theme.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (file.media_source_manual && this.sourceDisplay(file.media_source ?? null).length > 0) {
                Text(`现为 ${this.sourceDisplay(file.media_source ?? null)}`)
                  .fontSize(11)
                  .fontColor(Theme.accent2)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .backgroundColor(Theme.glassFill)
                  .borderRadius(8)
              }
              Text(Formatters.bytes(file.size_bytes))
                .fontSize(13)
                .fontColor(Theme.textMuted)
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 11, bottom: 11 })
            if (index < list.length - 1) {
              Divider().color(Theme.line).margin({ left: 14, right: 14 })
            }
          }
          .width('100%')
        }, (file: MediaSourceAnnotationCandidateView) => `${file.file_id}`)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
      Text(`共 ${list.length} 个文件将被统一标注`)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ top: 6 })
    }
    .width('100%')
  }

  @Builder
  Options() {
    Column({ space: 0 }) {
      Text('片源档位')
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ bottom: 6 })
      Column({ space: 0 }) {
        ForEach(this.options(), (option: AnnotationOption, index: number) => {
          Column() {
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text(option.label)
                  .fontSize(17)
                  .fontColor(Theme.text)
                Text(option.consequence)
                  .fontSize(13)
                  .fontColor(option.destructive ? Theme.warn : Theme.textMuted)
                  .maxLines(3)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              if (this.picked === option.value) {
                SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                  .fontSize(20)
                  .fontColor([option.destructive ? Theme.warn : '#5eead4'])
              }
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 11, bottom: 11 })
            .onClick(() => {
              if (!this.busy && this.candidates !== null && this.candidates.length > 0) {
                this.picked = option.value;
              }
            })
            if (index < this.options().length - 1) {
              Divider().color(Theme.line).margin({ left: 14, right: 14 })
            }
          }
          .width('100%')
        }, (option: AnnotationOption) => option.value)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
  }
}
