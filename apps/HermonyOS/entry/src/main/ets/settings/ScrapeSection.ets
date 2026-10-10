import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { AppFooter } from '../common/AppFooter';
import {
  CountryOption,
  LanguageOption,
  MetadataScrapeSetting,
  MetadataScrapeSettingInput,
  ScrapeConfigView
} from '../api/Models';

/** 四节（对应 iOS 的四张手风琴卡片） */
class ScrapeCard {
  static readonly language: string = 'language';
  static readonly cert: string = 'cert';
  static readonly poster: string = 'poster';
  static readonly sizes: string = 'sizes';
  static readonly naming: string = 'naming';
  static readonly mirror: string = 'mirror';
}

/** `MetadataScrapeSettingInput` 全可选，用类绕开 `arkts-no-untyped-obj-literals` */
class ScrapeBody implements MetadataScrapeSettingInput {
  language_priority?: string[] | null;
  cert_country_priority?: string[] | null;
  poster_mode?: string | null;
  poster_language_priority?: string[] | null;
  backdrop_language_priority?: string[] | null;
  poster_min_width?: number | null;
  backdrop_min_width?: number | null;
  poster_size?: string | null;
  backdrop_size?: string | null;
  still_size?: string | null;
  naming_entry_dir?: string | null;
  naming_movie_file?: string | null;
  naming_season_dir?: string | null;
  naming_episode_file?: string | null;
  mirror_images?: boolean | null;
  mirror_nfo?: boolean | null;
  mirror_episode_thumbs?: boolean | null;
}

/** 一个可多选的选项（语言 / 地区） */
class PickOption {
  readonly code: string;
  readonly label: string;

  constructor(code: string, label: string) {
    this.code = code;
    this.label = label;
  }
}

/**
 * 设置 → 刮削与整理（对应 iOS `ScrapeSettingsView` / Web `scrape-settings-section`）。
 *
 * 结构与 Web 一致：**四个并列分节**（元数据 / 图片 / 命名与整理 / 目录写入），
 * 每节若干张**手风琴卡片**——**默认全收起、同时只开一张**，**折叠头直接摊出当前值的人话摘要**，
 * 一屏扫完全站配置。
 *
 * 保存交互照搬 Web：**整页一个草稿，改任意一项即置脏，底部「保存」整体 PUT**，未改动时保存键禁用。
 *
 * **编辑态用「生效值」起步**：语言优先级跟随环境变量（存的是空列表）时，显示的是**当前生效的语言**；
 * 不改就不保存，语义不变——这条是 iOS 注释里点名的，照做。
 *
 * **没做**：「N 个库已覆盖」标记（要拉各库的覆盖情况，回答「在全局改了为什么不生效」）、
 * 命名模板的实时预览、图片尺寸的候选枚举校验（这里给文本框，后端会校验）。
 */
@ComponentV2
export struct ScrapeSection {
  @Local private config: ScrapeConfigView | null = null;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  @Local private open: string = '';
  @Local private dirty: boolean = false;
  @Local private saving: boolean = false;

  @Local private languages: LanguageOption[] = [];
  @Local private countries: CountryOption[] = [];

  /** 草稿：编辑态用的是**生效值**起步（见类注释） */
  @Local private languagePriority: string[] = [];
  @Local private certPriority: string[] = [];
  @Local private posterMode: string = '';
  @Local private posterLangPriority: string[] = [];
  @Local private backdropLangPriority: string[] = [];
  @Local private posterMinWidth: number = 0;
  @Local private backdropMinWidth: number = 0;
  @Local private posterSize: string = '';
  @Local private backdropSize: string = '';
  @Local private stillSize: string = '';
  @Local private namingEntryDir: string = '';
  @Local private namingMovieFile: string = '';
  @Local private namingSeasonDir: string = '';
  @Local private namingEpisodeFile: string = '';
  @Local private mirrorImages: boolean = false;
  @Local private mirrorNfo: boolean = false;
  @Local private mirrorThumbs: boolean = false;

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
      const view: ScrapeConfigView = await api.scrapeShow();
      this.config = view;
      this.fill(view.setting, view);
      this.languages = await api.scrapeLanguages();
      this.countries = await api.scrapeCountries();
      this.dirty = false;
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  /** 用设置填充草稿；语言优先级为空时用生效值（跟随环境变量） */
  private fill(setting: MetadataScrapeSetting, view: ScrapeConfigView): void {
    this.languagePriority = (setting.language_priority ?? []).length > 0
      ? (setting.language_priority ?? []).slice()
      : view.effective.language_priority.slice();
    this.certPriority = (setting.cert_country_priority ?? []).length > 0
      ? (setting.cert_country_priority ?? []).slice()
      : view.effective.cert_country_priority.slice();
    this.posterMode = setting.poster_mode;
    this.posterLangPriority = (setting.poster_language_priority ?? []).slice();
    this.backdropLangPriority = (setting.backdrop_language_priority ?? []).slice();
    this.posterMinWidth = setting.poster_min_width;
    this.backdropMinWidth = setting.backdrop_min_width;
    this.posterSize = setting.poster_size;
    this.backdropSize = setting.backdrop_size;
    this.stillSize = setting.still_size;
    this.namingEntryDir = setting.naming_entry_dir;
    this.namingMovieFile = setting.naming_movie_file;
    this.namingSeasonDir = setting.naming_season_dir;
    this.namingEpisodeFile = setting.naming_episode_file;
    this.mirrorImages = setting.mirror_images;
    this.mirrorNfo = setting.mirror_nfo;
    this.mirrorThumbs = setting.mirror_episode_thumbs;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private async save(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.saving || !this.dirty) {
      return;
    }
    this.saving = true;
    try {
      const body: ScrapeBody = new ScrapeBody();
      body.language_priority = this.languagePriority;
      body.cert_country_priority = this.certPriority;
      body.poster_mode = this.posterMode;
      body.poster_language_priority = this.posterLangPriority;
      body.backdrop_language_priority = this.backdropLangPriority;
      body.poster_min_width = this.posterMinWidth;
      body.backdrop_min_width = this.backdropMinWidth;
      body.poster_size = this.posterSize;
      body.backdrop_size = this.backdropSize;
      body.still_size = this.stillSize;
      body.naming_entry_dir = this.namingEntryDir;
      body.naming_movie_file = this.namingMovieFile;
      body.naming_season_dir = this.namingSeasonDir;
      body.naming_episode_file = this.namingEpisodeFile;
      body.mirror_images = this.mirrorImages;
      body.mirror_nfo = this.mirrorNfo;
      body.mirror_episode_thumbs = this.mirrorThumbs;
      this.config = await api.scrapeSet(body);
      this.dirty = false;
      this.toast('已保存');
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.saving = false;
    }
  }

  private markDirty(): void {
    this.dirty = true;
  }

  // MARK: 多选

  private codesOf(options: PickOption[]): string[] {
    const out: string[] = [];
    for (const option of options) {
      out.push(option.code);
    }
    return out;
  }

  private languageOptions(): PickOption[] {
    const out: PickOption[] = [];
    for (const item of this.languages) {
      out.push(new PickOption(item.code, item.name));
    }
    return out;
  }

  private countryOptions(): PickOption[] {
    const out: PickOption[] = [];
    for (const item of this.countries) {
      out.push(new PickOption(item.code, item.name));
    }
    return out;
  }

  private labelOf(options: PickOption[], codes: string[]): string {
    const labels: string[] = [];
    for (const code of codes) {
      for (const option of options) {
        if (option.code === code) {
          labels.push(option.label);
          break;
        }
      }
    }
    return labels.length === 0 ? '未设置' : labels.join('、');
  }

  private toggleCode(codes: string[], code: string): string[] {
    const next: string[] = codes.slice();
    const at: number = next.indexOf(code);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(code);
    }
    return next;
  }

  // MARK: 摘要（折叠头的人话）

  private languageSummary(): string {
    // 空 = 跟随环境变量；此时显示的是生效值（见类注释里 iOS 的做法）。
    // 生效值也拿不到才写「跟随环境变量」，别让用户以为没配就没生效。
    if (this.languagePriority.length === 0) {
      return '元数据语言：跟随环境变量';
    }
    return `元数据语言：${this.labelOf(this.languageOptions(), this.languagePriority)}`;
  }

  private certSummary(): string {
    return `分级地区：${this.labelOf(this.countryOptions(), this.certPriority)}`;
  }

  private posterSummary(): string {
    const mode: string = this.posterMode.length > 0 ? this.posterMode : '默认';
    return `海报 ${mode}  ·  最小宽 ${this.posterMinWidth}px`;
  }

  private sizesSummary(): string {
    // 后端可能返回空串（表示用默认档），直接拼会显示成「海报 · 背景 · 剧照」这种没有值的摘要
    const dash = (v: string): string => v.length > 0 ? v : '默认';
    return `海报 ${dash(this.posterSize)}  ·  背景 ${dash(this.backdropSize)}  ·  剧照 ${dash(this.stillSize)}`;
  }

  private namingSummary(): string {
    return this.namingMovieFile.length > 0 ? `电影文件：${this.namingMovieFile}` : '命名模板未设置';
  }

  private mirrorSummary(): string {
    const on: string[] = [];
    if (this.mirrorImages) {
      on.push('图片');
    }
    if (this.mirrorNfo) {
      on.push('NFO');
    }
    if (this.mirrorThumbs) {
      on.push('剧集缩略图');
    }
    return on.length === 0 ? '不写入目录' : `写入：${on.join(' / ')}`;
  }

  // MARK: 视图

  build() {
    Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在加载刮削设置…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.config === null) {
        Column({ space: 10 }) {
          Text('刮削设置加载失败').fontSize(15).fontColor(Theme.text)
          Text(this.errorMessage).fontSize(13).fontColor(Theme.textMuted)
          Text('重试').fontSize(14).fontColor(Theme.accentStrong).onClick(() => {
            this.load();
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 20 }) {
            if (this.errorMessage.length > 0) {
              Text(this.errorMessage).fontSize(13).fontColor(Theme.danger).width('100%')
            }
            // 一、元数据
            this.SectionTitle('元数据', '刮削时优先取哪种语言的简介、标题与分级')
            this.Card(ScrapeCard.language, '语言优先级', this.languageSummary())
            this.Card(ScrapeCard.cert, '分级地区', this.certSummary())
            // 二、图片
            this.SectionTitle('图片', '海报与背景图从哪来、要多清晰')
            this.Card(ScrapeCard.poster, '海报与背景', this.posterSummary())
            this.Card(ScrapeCard.sizes, '图片尺寸档', this.sizesSummary())
            // 三、命名与整理
            this.SectionTitle('命名与整理', '整理文件名时套用的模板')
            this.Card(ScrapeCard.naming, '命名模板', this.namingSummary())
            // 四、目录写入
            this.SectionTitle('目录写入', '把哪些附属文件写进媒体目录')
            this.Card(ScrapeCard.mirror, '写入文件', this.mirrorSummary())
            AppFooter()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 90 })
        }
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }

      // 底部保存条：未改动时禁用（同 Web）
      Row({ space: 12 }) {
        Text(this.dirty ? '有未保存的改动' : '没有改动')
          .fontSize(12)
          .fontColor(this.dirty ? Theme.warn : Theme.textFaint)
          .layoutWeight(1)
        Text(this.saving ? '保存中…' : '保存')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.dirty && !this.saving ? '#0b0d12' : Theme.textFaint)
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .backgroundColor(this.dirty && !this.saving ? Theme.accent : Theme.glassFill)
          .borderRadius(18)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor(Theme.surface)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SectionTitle(title: string, hint: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(hint)
        .fontSize(12)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 4 })
  }

  /** 手风琴卡片：收起时折叠头就是当前值的人话摘要（同 iOS） */
  @Builder
  Card(key: string, title: string, summary: string) {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text(title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
          if (this.open !== key) {
            Text(summary)
              .fontSize(12)
              .fontColor(Theme.textMuted)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph(this.open === key ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(13)
          .fontColor([Theme.textFaint])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .onClick(() => {
        this.open = this.open === key ? '' : key;
      })

      if (this.open === key) {
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
        if (key === ScrapeCard.language) {
          this.MultiPick(this.languageOptions(), this.languagePriority, (code: string): void => {
            this.languagePriority = this.toggleCode(this.languagePriority, code);
            this.markDirty();
          })
        } else if (key === ScrapeCard.cert) {
          this.MultiPick(this.countryOptions(), this.certPriority, (code: string): void => {
            this.certPriority = this.toggleCode(this.certPriority, code);
            this.markDirty();
          })
        } else if (key === ScrapeCard.poster) {
          this.PosterFields()
        } else if (key === ScrapeCard.sizes) {
          this.SizeFields()
        } else if (key === ScrapeCard.naming) {
          this.NamingFields()
        } else {
          this.MirrorFields()
        }
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 多选：按顺序选中，点一下加/减 */
  @Builder
  MultiPick(options: PickOption[], selected: string[], onToggle: (code: string) => void) {
    Column({ space: 8 }) {
      Text(`已选 ${selected.length} 项（顺序即优先级）`)
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(options, (option: PickOption) => {
          Text(option.label)
            .fontSize(13)
            .fontColor(selected.indexOf(option.code) >= 0 ? '#0b0d12' : Theme.textMuted)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(selected.indexOf(option.code) >= 0 ? Theme.accent : Theme.glassFill)
            .borderRadius(15)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              onToggle(option.code);
            })
        }, (option: PickOption) => option.code)
      }
      .width('100%')
      if (selected.length > 0) {
        Text('清空')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .onClick(() => {
            if (options.length > 0 && options[0].code === 'zh') {
              this.languagePriority = [];
            } else {
              this.certPriority = [];
            }
            this.markDirty();
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  PosterFields() {
    Column({ space: 12 }) {
      Column({ space: 6 }) {
        Text('海报来源')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .width('100%')
        Row({ space: 8 }) {
          this.ModeChip('auto', '自动挑')
          this.ModeChip('textless', '优先无字版')
          this.ModeChip('original', '优先原版')
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      this.NumberField('海报最小宽度（px）', this.posterMinWidth, (v: number): void => {
        this.posterMinWidth = v;
        this.markDirty();
      })
      this.NumberField('背景最小宽度（px）', this.backdropMinWidth, (v: number): void => {
        this.backdropMinWidth = v;
        this.markDirty();
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  ModeChip(value: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.posterMode === value ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(this.posterMode === value ? Theme.accent : Theme.glassFill)
      .borderRadius(15)
      .onClick(() => {
        this.posterMode = value;
        this.markDirty();
      })
  }

  @Builder
  SizeFields() {
    Column({ space: 12 }) {
      this.TextField('海报尺寸档', this.posterSize, 'w500', (v: string): void => {
        this.posterSize = v;
        this.markDirty();
      })
      this.TextField('背景尺寸档', this.backdropSize, 'w1280', (v: string): void => {
        this.backdropSize = v;
        this.markDirty();
      })
      this.TextField('剧照尺寸档', this.stillSize, 'w300', (v: string): void => {
        this.stillSize = v;
        this.markDirty();
      })
      Text('尺寸档决定拉多大的图；越大越清晰也越占带宽。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  NamingFields() {
    Column({ space: 12 }) {
      this.TextField('影片目录', this.namingEntryDir, '例如 {title} ({year})', (v: string): void => {
        this.namingEntryDir = v;
        this.markDirty();
      })
      this.TextField('影片文件', this.namingMovieFile, '例如 {title} ({year})', (v: string): void => {
        this.namingMovieFile = v;
        this.markDirty();
      })
      this.TextField('季目录', this.namingSeasonDir, '例如 Season {season:00}', (v: string): void => {
        this.namingSeasonDir = v;
        this.markDirty();
      })
      this.TextField('剧集文件', this.namingEpisodeFile, '例如 S{season:00}E{episode:00}',
        (v: string): void => {
          this.namingEpisodeFile = v;
          this.markDirty();
        })
      Text('花括号里是占位符，整理文件名时会被替换。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  MirrorFields() {
    Column({ space: 0 }) {
      this.Switch('把图片写进媒体目录', this.mirrorImages, (on: boolean): void => {
        this.mirrorImages = on;
        this.markDirty();
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      this.Switch('把 NFO 写进媒体目录', this.mirrorNfo, (on: boolean): void => {
        this.mirrorNfo = on;
        this.markDirty();
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      this.Switch('把剧集缩略图写进媒体目录', this.mirrorThumbs, (on: boolean): void => {
        this.mirrorThumbs = on;
        this.markDirty();
      })
      Text('写进目录后，别的播放器（Infuse、Kodi 等）也能读到这些信息。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  Switch(label: string, value: boolean, onChange: (on: boolean) => void) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(15)
        .fontColor(Theme.text)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(Theme.accent)
        .onChange((on: boolean): void => {
          onChange(on);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
  }

  @Builder
  TextField(label: string, value: string, hint: string, onChange: (v: string) => void) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
      TextInput({ text: value, placeholder: hint })
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onChange((v: string): void => {
          onChange(v);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  NumberField(label: string, value: number, onChange: (v: number) => void) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
      TextInput({ text: `${value}`, placeholder: '0' })
        .width('100%')
        .height(40)
        .type(InputType.Number)
        .fontSize(14)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onChange((v: string): void => {
          const parsed: number = Number.parseInt(v, 10);
          onChange(Number.isFinite(parsed) ? parsed : 0);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
