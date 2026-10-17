import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { AppFooter } from '../common/AppFooter';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  CountryOption,
  FanartKeyPayload,
  FanartStatusView,
  ImageStorageEstimateView,
  LanguageOption,
  MetadataScrapeSetting,
  MetadataScrapeSettingInput,
  ScrapeConfigView
} from '../api/Models';
import { NamingField, NamingToken, NamingTokenGroup, ScrapeNaming } from './ScrapeNaming';

/** 九节（对应 iOS 的九张手风琴卡片） */
class ScrapeCard {
  static readonly language: string = 'language';
  static readonly cert: string = 'cert';
  static readonly sources: string = 'sources';
  static readonly poster: string = 'poster';
  static readonly backdrop: string = 'backdrop';
  static readonly logo: string = 'logo';
  static readonly quality: string = 'quality';
  static readonly naming: string = 'naming';
  static readonly mirror: string = 'mirror';
}

/** 弹层种类：'fanartKey' = Fanart API Key 验证 / 'tier' = 自定义画质档位选择 */
class SheetKind {
  static readonly fanartKey: string = 'fanartKey';
  static readonly tier: string = 'tier';
}

/** 自定义画质的四个档位 */
class TierKind {
  static readonly poster: string = 'poster';
  static readonly backdrop: string = 'backdrop';
  static readonly still: string = 'still';
  static readonly profile: string = 'profile';
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
  profile_size?: string | null;
  image_quality?: string | null;
  logo_language_priority?: string[] | null;
  fanart_enabled?: boolean | null;
  poster_source_order?: string[] | null;
  backdrop_source_order?: string[] | null;
  logo_source_order?: string[] | null;
  season_poster_source_order?: string[] | null;
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

/** 图片来源的四个类别（对应 iOS `SettingsBScrapeImageKind`） */
class SourceKind {
  static readonly poster: string = 'poster';
  static readonly backdrop: string = 'backdrop';
  static readonly logo: string = 'logo';
  static readonly season: string = 'season';
}

/**
 * 设置 → 刮削与整理（对应 iOS `ScrapeSettingsView` / Web `scrape-settings-section`）。
 *
 * 结构与 Web 一致：**四个并列分节**（元数据 / 图片 / 整理与写入），每节若干张
 * **手风琴卡片**——**默认全收起、同时只开一张**，**折叠头直接摊出当前值的人话摘要**。
 *
 * 保存交互照搬 Web：**整页一个草稿，改任意一项即置脏，底部「保存」整体 PUT**。
 *
 * **编辑态用「生效值」起步**：语言优先级跟随环境变量（存的是空列表）时，显示的是
 * **当前生效的语言**；不改就不保存，语义不变。
 *
 * 图片来源卡走独立的 Key 验证接口（`PUT /scrape/fanart`，验证即落库），启用开关与
 * 来源顺序仍在整页草稿里；画质卡的磁盘估算来自 `GET /scrape/storage-estimate`，
 * 拿不到就不显示；命名模板的预览与轻校验在 `ScrapeNaming`（渲染规则镜像后端）。
 *
 * **没做**：「N 个库已覆盖」标记（要拉各库的覆盖情况，回答「在全局改了为什么不生效」）。
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

  /** Fanart.tv Key 状态（独立接口，加载失败不阻塞主流程） */
  @Local private fanartStatus: FanartStatusView | null = null;
  @Local private fanartLoading: boolean = true;
  @Local private fanartError: string = '';

  /** 各画质档的磁盘估算；拿不到就不显示 */
  @Local private estimate: ImageStorageEstimateView | null = null;

  /** 弹层（一个组件只能绑一个 `bindSheet`，Key 验证与档位选择合成单槽位 + 内容切换） */
  @Local private showSheet: boolean = false;
  @Local private sheetMode: string = SheetKind.fanartKey;
  @Local private tierPicking: string = TierKind.poster;
  @Local private keyInput: string = '';
  @Local private keyError: string = '';
  @Local private keySaving: boolean = false;
  /** 从开关进 Key 弹层时记录快照，取消未验证则回滚草稿 */
  private keySheetForEnable: boolean = false;
  private fanartBeforeSheet: boolean = false;
  private dirtyBeforeSheet: boolean = false;

  /** 草稿：编辑态用的是**生效值**起步（见类注释） */
  @Local private languagePriority: string[] = [];
  @Local private certPriority: string[] = [];
  @Local private posterMode: string = '';
  @Local private posterLangPriority: string[] = [];
  @Local private backdropLangPriority: string[] = [];
  @Local private logoLangPriority: string[] = [];
  @Local private posterMinWidth: number = 0;
  @Local private backdropMinWidth: number = 0;
  @Local private fanartEnabled: boolean = false;
  @Local private posterSourceOrder: string[] = [];
  @Local private backdropSourceOrder: string[] = [];
  @Local private logoSourceOrder: string[] = [];
  @Local private seasonSourceOrder: string[] = [];
  @Local private posterSize: string = '';
  @Local private backdropSize: string = '';
  @Local private stillSize: string = '';
  @Local private profileSize: string = '';
  @Local private imageQuality: string = '';
  @Local private namingEntryDir: string = '';
  @Local private namingMovieFile: string = '';
  @Local private namingSeasonDir: string = '';
  @Local private namingEpisodeFile: string = '';
  @Local private mirrorImages: boolean = false;
  @Local private mirrorNfo: boolean = false;
  @Local private mirrorThumbs: boolean = false;

  /** 命名模板：占位符插到「最后聚焦的输入框」光标处（默认剧集文件名，同 Web/iOS） */
  @Local private lastFocused: string = 'naming_episode_file';
  private entryDirController: TextInputController = new TextInputController();
  private movieFileController: TextInputController = new TextInputController();
  private seasonDirController: TextInputController = new TextInputController();
  private episodeFileController: TextInputController = new TextInputController();

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
    // 辅助数据（Key 状态 / 磁盘估算）失败不阻塞主流程
    this.loadFanartStatus();
    this.loadEstimate();
  }

  private async loadFanartStatus(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.fanartLoading = true;
    this.fanartError = '';
    try {
      this.fanartStatus = await api.scrapeFanartShow();
    } catch (error) {
      this.fanartError = this.messageOf(error);
    } finally {
      this.fanartLoading = false;
    }
  }

  private async loadEstimate(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.estimate = await api.scrapeStorageEstimate();
    } catch (error) {
      // 估算拿不到就不显示（null），不阻塞
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
    const logoDefault: string[] = ['meta', 'en', 'orig', 'null'];
    this.logoLangPriority = (setting.logo_language_priority ?? logoDefault).slice();
    this.posterMinWidth = setting.poster_min_width;
    this.backdropMinWidth = setting.backdrop_min_width;
    this.fanartEnabled = setting.fanart_enabled === true;
    const tmdbFirst: string[] = ['tmdb', 'fanart'];
    const fanartFirst: string[] = ['fanart', 'tmdb'];
    this.posterSourceOrder = (setting.poster_source_order ?? tmdbFirst).slice();
    this.backdropSourceOrder = (setting.backdrop_source_order ?? tmdbFirst).slice();
    this.logoSourceOrder = (setting.logo_source_order ?? fanartFirst).slice();
    this.seasonSourceOrder = (setting.season_poster_source_order ?? fanartFirst).slice();
    this.posterSize = setting.poster_size;
    this.backdropSize = setting.backdrop_size;
    this.stillSize = setting.still_size;
    this.profileSize = setting.profile_size;
    this.imageQuality = setting.image_quality;
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
    if (!this.namingValid()) {
      this.toast('命名模板有误，请先修正');
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
      body.logo_language_priority = this.logoLangPriority;
      body.poster_min_width = this.posterMinWidth;
      body.backdrop_min_width = this.backdropMinWidth;
      body.fanart_enabled = this.fanartEnabled;
      body.poster_source_order = this.posterSourceOrder;
      body.backdrop_source_order = this.backdropSourceOrder;
      body.logo_source_order = this.logoSourceOrder;
      body.season_poster_source_order = this.seasonSourceOrder;
      body.poster_size = this.posterSize;
      body.backdrop_size = this.backdropSize;
      body.still_size = this.stillSize;
      body.profile_size = this.profileSize;
      body.image_quality = this.imageQuality;
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
      // 画质可能变了，重算磁盘估算
      this.loadEstimate();
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

  /** 图片语言的特殊 token + 常用语种（同 iOS `SettingsBScrapeCatalog.commonImageLangs`） */
  private posterLangOptions(): PickOption[] {
    const out: PickOption[] = [];
    out.push(new PickOption('meta', '跟随元数据主语言'));
    out.push(new PickOption('orig', '原始语言'));
    out.push(new PickOption('en', 'English'));
    out.push(new PickOption('null', '无文字'));
    out.push(new PickOption('ja', '日本語'));
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

  // MARK: 图片来源（Fanart.tv）

  private fanartUsable(): boolean {
    const status: FanartStatusView | null = this.fanartStatus;
    return status !== null && status.configured && !status.key_invalid;
  }

  private fanartConfigured(): boolean {
    const status: FanartStatusView | null = this.fanartStatus;
    return status !== null && status.configured;
  }

  private fanartKeyInvalid(): boolean {
    const status: FanartStatusView | null = this.fanartStatus;
    return status !== null && status.key_invalid;
  }

  private fanartKeyTitle(): string {
    const status: FanartStatusView | null = this.fanartStatus;
    if (status === null) {
      return '配置 API Key';
    }
    return status.key_invalid ? '重新验证 API Key' : status.configured ? '更换 API Key' : '配置 API Key';
  }

  private fanartKeySubtitle(): string {
    const status: FanartStatusView | null = this.fanartStatus;
    if (status === null) {
      return '验证后即可启用 Fanart 选图';
    }
    if (status.key_invalid) {
      return '密钥已失效，Fanart 选图已暂停';
    }
    return status.configured ? `已配置 · ••••${status.key_hint}` : '验证后即可启用 Fanart 选图';
  }

  /** 开关：Key 可用直接翻草稿；不可用先弹 Key 验证（草稿先翻开，取消未验证则回滚） */
  private onFanartToggle(on: boolean): void {
    if (!on) {
      this.fanartEnabled = false;
      this.markDirty();
      return;
    }
    if (this.fanartUsable()) {
      this.fanartEnabled = true;
      this.markDirty();
      return;
    }
    this.keySheetForEnable = true;
    this.fanartBeforeSheet = this.fanartEnabled;
    this.dirtyBeforeSheet = this.dirty;
    this.fanartEnabled = true;
    this.markDirty();
    this.keyInput = '';
    this.keyError = '';
    this.sheetMode = SheetKind.fanartKey;
    this.showSheet = true;
  }

  private cancelKeySheet(): void {
    if (this.keySheetForEnable && !this.fanartUsable() && !this.fanartBeforeSheet) {
      this.fanartEnabled = false;
      this.dirty = this.dirtyBeforeSheet;
    }
    this.keySheetForEnable = false;
    this.keyInput = '';
    this.keyError = '';
    this.showSheet = false;
  }

  private async verifyFanartKey(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.keySaving) {
      return;
    }
    const key: string = this.keyInput.trim();
    if (key.length === 0) {
      this.keyError = '请输入 API Key';
      return;
    }
    this.keySaving = true;
    this.keyError = '';
    try {
      const payload: FanartKeyPayload = { api_key: key };
      const status: FanartStatusView = await api.scrapeFanartSetKey(payload);
      this.fanartStatus = status;
      this.fanartError = '';
      this.fanartEnabled = true;
      this.markDirty();
      this.keySheetForEnable = false;
      this.keyInput = '';
      this.showSheet = false;
      this.toast('Key 已验证，保存后启用 Fanart 选图');
    } catch (error) {
      this.keyError = this.messageOf(error);
    } finally {
      this.keySaving = false;
    }
  }

  private copyFanartSignupLink(): void {
    const data: pasteboard.PasteData =
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, 'https://fanart.tv/get-an-api-key/');
    pasteboard.getSystemPasteboard().setDataSync(data);
    this.toast('已复制申请链接');
  }

  private sourceLabel(id: string): string {
    return id === 'fanart' ? 'Fanart.tv' : 'TMDB';
  }

  private sourceOrderOf(kind: string): string[] {
    if (kind === SourceKind.poster) {
      return this.posterSourceOrder;
    }
    if (kind === SourceKind.backdrop) {
      return this.backdropSourceOrder;
    }
    if (kind === SourceKind.logo) {
      return this.logoSourceOrder;
    }
    return this.seasonSourceOrder;
  }

  private setSourceOrder(kind: string, value: string[]): void {
    if (kind === SourceKind.poster) {
      this.posterSourceOrder = value;
    } else if (kind === SourceKind.backdrop) {
      this.backdropSourceOrder = value;
    } else if (kind === SourceKind.logo) {
      this.logoSourceOrder = value;
    } else {
      this.seasonSourceOrder = value;
    }
  }

  private sourceOrderText(kind: string): string {
    const parts: string[] = [];
    for (const id of this.sourceOrderOf(kind)) {
      parts.push(this.sourceLabel(id));
    }
    return parts.length === 0 ? '未设置' : parts.join(' → ');
  }

  /** 只有两个固定来源，点一下整行交换顺序 */
  private swapSourceOrder(kind: string): void {
    this.setSourceOrder(kind, this.sourceOrderOf(kind).slice().reverse());
    this.markDirty();
  }

  // MARK: 画质与档位

  private selectedQuality(): string {
    if (this.imageQuality.length > 0) {
      return this.imageQuality;
    }
    const config: ScrapeConfigView | null = this.config;
    if (config !== null && config.effective.image_quality.length > 0) {
      return config.effective.image_quality;
    }
    return 'original';
  }

  private qualityName(id: string): string {
    if (id === 'original') {
      return '原图';
    }
    if (id === 'standard') {
      return '标准';
    }
    if (id === 'compact') {
      return '节省空间';
    }
    return '自定义';
  }

  private selectQuality(id: string): void {
    if (this.selectedQuality() === id) {
      return;
    }
    this.imageQuality = id;
    if (id === 'custom') {
      // 切到「自定义」时把还空着的档位填成当前生效值：否则四个档位都是「跟随」，
      // 看不出刚才那一档具体是多大，保存后的行为也跟着环境变量变
      const config: ScrapeConfigView | null = this.config;
      if (config !== null) {
        if (this.posterSize.length === 0) {
          this.posterSize = config.effective.poster_size;
        }
        if (this.backdropSize.length === 0) {
          this.backdropSize = config.effective.backdrop_size;
        }
        if (this.stillSize.length === 0) {
          this.stillSize = config.effective.still_size;
        }
        if (this.profileSize.length === 0) {
          this.profileSize = config.effective.profile_size;
        }
      }
    }
    this.markDirty();
  }

  /** 某一档的估算字节数：预设直接查表；自定义只在它就是当前生效档时有数（档位改了要保存后才重算） */
  private estimatedBytes(id: string): number | null {
    const estimate: ImageStorageEstimateView | null = this.estimate;
    if (estimate === null) {
      return null;
    }
    const preset: number | undefined = estimate.presets[id];
    if (preset !== undefined) {
      return preset;
    }
    if (id === 'custom' && estimate.current_quality === 'custom') {
      return estimate.current_bytes;
    }
    return null;
  }

  /** 「2.6 GB」「850 MB」：估算只是量级参考，GB 保留一位小数、MB 取整 */
  private gigabytes(bytes: number): string {
    const gb: number = bytes / 1073741824;
    if (gb >= 1) {
      return `${gb.toFixed(1)} GB`;
    }
    const mb: number = Math.max(1, Math.round(bytes / 1048576));
    return `${mb} MB`;
  }

  private qualityEstimate(id: string): string {
    const bytes: number | null = this.estimatedBytes(id);
    return bytes === null ? '' : `约 ${this.gigabytes(bytes)}`;
  }

  private tierOptions(kind: string): string[] {
    if (kind === TierKind.poster) {
      return ['w342', 'w500', 'w780', 'original'];
    }
    if (kind === TierKind.backdrop) {
      return ['w780', 'w1280', 'original'];
    }
    if (kind === TierKind.still) {
      return ['w185', 'w300', 'original'];
    }
    return ['w185', 'h632', 'original'];
  }

  private tierValue(kind: string): string {
    if (kind === TierKind.poster) {
      return this.posterSize;
    }
    if (kind === TierKind.backdrop) {
      return this.backdropSize;
    }
    if (kind === TierKind.still) {
      return this.stillSize;
    }
    return this.profileSize;
  }

  private setTierValue(kind: string, value: string): void {
    if (kind === TierKind.poster) {
      this.posterSize = value;
    } else if (kind === TierKind.backdrop) {
      this.backdropSize = value;
    } else if (kind === TierKind.still) {
      this.stillSize = value;
    } else {
      this.profileSize = value;
    }
    this.markDirty();
  }

  private effectiveSizeOf(kind: string): string {
    const config: ScrapeConfigView | null = this.config;
    if (config === null) {
      return '';
    }
    if (kind === TierKind.poster) {
      return config.effective.poster_size;
    }
    if (kind === TierKind.backdrop) {
      return config.effective.backdrop_size;
    }
    if (kind === TierKind.still) {
      return config.effective.still_size;
    }
    return config.effective.profile_size;
  }

  private tierPickerTitle(): string {
    if (this.tierPicking === TierKind.poster) {
      return '海报档位';
    }
    if (this.tierPicking === TierKind.backdrop) {
      return '背景档位';
    }
    if (this.tierPicking === TierKind.still) {
      return '剧照档位';
    }
    return '头像档位';
  }

  private tierOptionLabel(value: string): string {
    if (value.length > 0) {
      return value;
    }
    const fallback: string = this.effectiveSizeOf(this.tierPicking);
    return fallback.length > 0 ? `跟随环境（${fallback}）` : '跟随环境';
  }

  // MARK: 命名模板

  private namingValueOf(key: string): string {
    if (key === 'naming_entry_dir') {
      return this.namingEntryDir;
    }
    if (key === 'naming_movie_file') {
      return this.namingMovieFile;
    }
    if (key === 'naming_season_dir') {
      return this.namingSeasonDir;
    }
    return this.namingEpisodeFile;
  }

  private setNamingValue(key: string, value: string): void {
    if (key === 'naming_entry_dir') {
      this.namingEntryDir = value;
    } else if (key === 'naming_movie_file') {
      this.namingMovieFile = value;
    } else if (key === 'naming_season_dir') {
      this.namingSeasonDir = value;
    } else {
      this.namingEpisodeFile = value;
    }
  }

  private controllerOf(key: string): TextInputController {
    if (key === 'naming_entry_dir') {
      return this.entryDirController;
    }
    if (key === 'naming_movie_file') {
      return this.movieFileController;
    }
    if (key === 'naming_season_dir') {
      return this.seasonDirController;
    }
    return this.episodeFileController;
  }

  private namingErrorOf(key: string): string {
    return ScrapeNaming.errorFor(ScrapeNaming.fieldByKey(key), this.namingValueOf(key)) ?? '';
  }

  private namingValid(): boolean {
    for (const field of ScrapeNaming.fields) {
      if (ScrapeNaming.errorFor(field, this.namingValueOf(field.key)) !== null) {
        return false;
      }
    }
    return true;
  }

  private focusedNamingField(): NamingField {
    return ScrapeNaming.fieldByKey(this.lastFocused);
  }

  private groupTokens(group: NamingTokenGroup): NamingToken[] {
    const field: NamingField = this.focusedNamingField();
    const out: NamingToken[] = [];
    for (const token of group.tokens) {
      if (field.tokens.indexOf(token.key) >= 0) {
        out.push(token);
      }
    }
    return out;
  }

  /** 在最后聚焦的输入框光标处插入占位符；输入框为空时以默认模板为底（同 Web/iOS） */
  private insertToken(token: string): void {
    const field: NamingField = this.focusedNamingField();
    const raw: string = this.namingValueOf(field.key);
    const base: string = raw.length === 0 ? field.fallback : raw;
    const controller: TextInputController = this.controllerOf(field.key);
    const caret: number = controller.getCaretOffset().index;
    const start: number = Math.min(Math.max(caret, 0), base.length);
    const inserted: string = `{${token}}`;
    this.setNamingValue(field.key, base.substring(0, start) + inserted + base.substring(start));
    this.markDirty();
    controller.caretPosition(start + inserted.length);
  }

  private moviePreviewPath(): string {
    const sample: Map<string, string> = ScrapeNaming.movieSample();
    const dir: string = ScrapeNaming.render(
      ScrapeNaming.effective(ScrapeNaming.fieldByKey('naming_entry_dir'), this.namingEntryDir), sample);
    const file: string = ScrapeNaming.render(
      ScrapeNaming.effective(ScrapeNaming.fieldByKey('naming_movie_file'), this.namingMovieFile), sample);
    return `${dir}/${file}.mkv`;
  }

  private episodePreviewPath(): string {
    const sample: Map<string, string> = ScrapeNaming.episodeSample();
    const dir: string = ScrapeNaming.render(
      ScrapeNaming.effective(ScrapeNaming.fieldByKey('naming_entry_dir'), this.namingEntryDir), sample);
    const season: string = ScrapeNaming.render(
      ScrapeNaming.effective(ScrapeNaming.fieldByKey('naming_season_dir'), this.namingSeasonDir), sample);
    const file: string = ScrapeNaming.render(
      ScrapeNaming.effective(ScrapeNaming.fieldByKey('naming_episode_file'), this.namingEpisodeFile), sample);
    return `${dir}/${season}/${file}.mkv`;
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

  private sourcesSummary(): string {
    return this.fanartEnabled ? 'TMDB 与 Fanart.tv' : 'TMDB（Fanart.tv 未启用）';
  }

  private posterSummary(): string {
    if (this.posterMode !== 'language') {
      return 'TMDB 默认';
    }
    return `按语言：${this.labelOf(this.posterLangOptions(), this.posterLangPriority)}`;
  }

  private backdropSummary(): string {
    return this.labelOf(this.posterLangOptions(), this.backdropLangPriority);
  }

  private logoSummary(): string {
    return this.labelOf(this.posterLangOptions(), this.logoLangPriority);
  }

  private allEmpty(values: string[]): boolean {
    for (const value of values) {
      if (value.length > 0) {
        return false;
      }
    }
    return true;
  }

  private qualitySummary(): string {
    const sizes: string[] = [this.posterSize, this.backdropSize, this.stillSize, this.profileSize];
    let quality: string;
    if (this.imageQuality.length > 0 && this.imageQuality !== 'custom') {
      quality = `画质 ${this.qualityName(this.imageQuality)}`;
    } else if (this.imageQuality.length === 0 && this.allEmpty(sizes)) {
      quality = '画质 原图';
    } else {
      const parts: string[] = [];
      for (const size of sizes) {
        parts.push(size.length > 0 ? size : '环境');
      }
      quality = `画质自定义 ${parts.join('/')}`;
    }
    const posterMin: string = this.posterMinWidth > 0 ? `海报 ≥${this.posterMinWidth}px` : '海报不限宽';
    const backdropMin: string = this.backdropMinWidth > 0 ? `背景 ≥${this.backdropMinWidth}px` : '背景不限宽';
    return `${quality} · ${posterMin} · ${backdropMin}`;
  }

  private namingSummary(): string {
    const changed: string[] = [];
    if (this.namingEntryDir.trim().length > 0) {
      changed.push('条目目录');
    }
    if (this.namingMovieFile.trim().length > 0) {
      changed.push('电影文件名');
    }
    if (this.namingSeasonDir.trim().length > 0) {
      changed.push('季目录');
    }
    if (this.namingEpisodeFile.trim().length > 0) {
      changed.push('剧集文件名');
    }
    return changed.length === 0 ? '全部默认模板' : `已改：${changed.join('、')}`;
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
            this.SectionTitle('图片', '图片从哪来、选哪种语言、要多清晰')
            this.Card(ScrapeCard.sources, '图片来源', this.sourcesSummary())
            this.Card(ScrapeCard.poster, '海报', this.posterSummary())
            this.Card(ScrapeCard.backdrop, '背景图', this.backdropSummary())
            this.Card(ScrapeCard.logo, '片名 Logo', this.logoSummary())
            this.Card(ScrapeCard.quality, '图片画质', this.qualitySummary())
            // 三、整理与写入
            this.SectionTitle('整理与写入', '整理文件名时套用的模板与写进目录的内容')
            this.Card(ScrapeCard.naming, '命名模板', this.namingSummary())
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
    // 一个组件只能绑一个 bindSheet：Key 验证与档位选择合成单槽位 + 内容切换
    .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
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
          }, (): void => {
            this.languagePriority = [];
            this.markDirty();
          })
        } else if (key === ScrapeCard.cert) {
          this.MultiPick(this.countryOptions(), this.certPriority, (code: string): void => {
            this.certPriority = this.toggleCode(this.certPriority, code);
            this.markDirty();
          }, (): void => {
            this.certPriority = [];
            this.markDirty();
          })
        } else if (key === ScrapeCard.sources) {
          this.SourceFields()
        } else if (key === ScrapeCard.poster) {
          this.PosterFields()
        } else if (key === ScrapeCard.backdrop) {
          this.BackdropFields()
        } else if (key === ScrapeCard.logo) {
          this.LogoFields()
        } else if (key === ScrapeCard.quality) {
          this.QualityFields()
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
  MultiPick(options: PickOption[], selected: string[], onToggle: (code: string) => void,
    onClear: () => void) {
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
            onClear();
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
      Column({ space: 0 }) {
        this.PosterModeRow('default', 'TMDB 默认',
          '与发现页看到的一致，订阅前后海报不跳变（默认）')
        this.PosterModeRow('language', '按语言优先级挑选',
          '逐级取第一档有候选图的语言，档内按分辨率与票数排序')
      }
      .width('100%')

      // 海报语言优先级：仅「按语言」模式下可编辑；启用 Fanart 时默认海报也按语言比较（同 iOS）
      Column() {
        this.MultiPick(this.posterLangOptions(), this.posterLangPriority,
          (code: string): void => {
            if (this.posterLangPriority.indexOf(code) < 0 && this.posterLangPriority.length >= 4) {
              this.toast('海报语言最多选 4 档');
              return;
            }
            this.posterLangPriority = this.toggleCode(this.posterLangPriority, code);
            this.markDirty();
          },
          (): void => {
            this.posterLangPriority = [];
            this.markDirty();
          })
      }
      .width('100%')
      .enabled(this.posterMode === 'language' || this.fanartEnabled)
      .opacity(this.posterMode === 'language' || this.fanartEnabled ? 1 : 0.45)

      Text('海报和文本一样有语言：中文版、原版、无文字干净版是不同的候选图。手动选定的图始终优先。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /** 海报选图模式的两个档 */
  @Builder
  PosterModeRow(value: string, title: string, desc: string) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor(Theme.text)
        Text(desc)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(16)
        .fontColor([Theme.accent])
        .opacity(this.posterMode === value ? 1 : 0)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      if (this.posterMode !== value) {
        this.posterMode = value;
        this.markDirty();
      }
    })
  }

  @Builder
  BackdropFields() {
    Column({ space: 12 }) {
      this.MultiPick(this.posterLangOptions(), this.backdropLangPriority,
        (code: string): void => {
          if (this.backdropLangPriority.indexOf(code) < 0 && this.backdropLangPriority.length >= 4) {
            this.toast('背景图语言最多选 4 档');
            return;
          }
          this.backdropLangPriority = this.toggleCode(this.backdropLangPriority, code);
          this.markDirty();
        },
        (): void => {
          this.backdropLangPriority = [];
          this.markDirty();
        })
      Text('详情页的背景图按优先级选择。「无文字」排首位即优先选择没有片名的干净背景图。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  LogoFields() {
    Column({ space: 12 }) {
      this.MultiPick(this.posterLangOptions(), this.logoLangPriority,
        (code: string): void => {
          if (this.logoLangPriority.indexOf(code) < 0 && this.logoLangPriority.length >= 4) {
            this.toast('Logo 语言最多选 4 档');
            return;
          }
          this.logoLangPriority = this.toggleCode(this.logoLangPriority, code);
          this.markDirty();
        },
        (): void => {
          this.logoLangPriority = [];
          this.markDirty();
        })
      Text('片名 Logo 按语言优先级选择，所有语言都没有可用图片时不显示 Logo。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  SourceFields() {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        Text('TMDB')
          .fontSize(15)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Text('始终开启')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      this.Switch('Fanart.tv', this.fanartEnabled, (on: boolean): void => {
        this.onFanartToggle(on);
      })

      Divider().color(Theme.line).margin({ left: 16, right: 16 })

      if (this.fanartLoading) {
        Text('正在检查 API Key…')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      } else if (this.fanartError.length > 0) {
        Column({ space: 6 }) {
          Text(this.fanartError)
            .fontSize(12)
            .fontColor(Theme.danger)
            .width('100%')
          Text('重新加载')
            .fontSize(13)
            .fontColor(Theme.accentStrong)
            .onClick(() => {
              this.loadFanartStatus();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      } else {
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(this.fanartKeyTitle())
              .fontSize(14)
              .fontColor(Theme.text)
            Text(this.fanartKeySubtitle())
              .fontSize(12)
              .fontColor(this.fanartKeyInvalid() ? Theme.danger : Theme.textMuted)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          SymbolGlyph(this.fanartKeyInvalid()
            ? $r('sys.symbol.exclamationmark_triangle') : $r('sys.symbol.key'))
            .fontSize(16)
            .fontColor([this.fanartKeyInvalid() ? Theme.danger : Theme.textMuted])
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .onClick(() => {
          this.keySheetForEnable = false;
          this.keyInput = '';
          this.keyError = '';
          this.sheetMode = SheetKind.fanartKey;
          this.showSheet = true;
        })
      }

      Divider().color(Theme.line).margin({ left: 16, right: 16 })

      this.SourceOrderRow('海报', SourceKind.poster)
      this.SourceOrderRow('背景图', SourceKind.backdrop)
      this.SourceOrderRow('片名 Logo', SourceKind.logo)
      this.SourceOrderRow('季海报', SourceKind.season)

      Text('先匹配图片语言，同一语言有多个来源时才按这里的顺序选择。季海报仅用于剧集，语言跟随海报设置。手动选定的图片始终优先。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 一类图片的来源顺序行：两个固定来源，点一下整行交换 */
  @Builder
  SourceOrderRow(title: string, kind: string) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor(Theme.text)
        Text(this.sourceOrderText(kind))
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('交换')
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(12)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .enabled(this.fanartEnabled)
    .opacity(this.fanartEnabled ? 1 : 0.45)
    .onClick(() => {
      this.swapSourceOrder(kind);
    })
  }

  @Builder
  QualityFields() {
    Column({ space: 10 }) {
      Column({ space: 3 }) {
        Text('本地图片画质')
          .fontSize(13)
          .fontColor(Theme.textFaint)
        Text('刮削时下载到本地的图片多大；看图时各设备再按需从本地图缩出合适的尺寸')
          .fontSize(11)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      this.QualityRow('original', '原图（默认）', '所有图存 TMDB 原图，各设备都最清楚')
      this.QualityRow('standard', '标准', '各设备都清楚，头像与海报不存原图，省约四成空间')
      this.QualityRow('compact', '节省空间', '手机和网页够用；电视上剧照、头像会发虚')
      this.QualityRow('custom', '自定义', '分别指定海报、背景、剧照、头像下载到本地的档位')

      if (this.selectedQuality() === 'custom') {
        Column({ space: 0 }) {
          this.TierRow('海报档位', TierKind.poster)
          this.TierRow('背景档位', TierKind.backdrop)
          this.TierRow('剧照档位', TierKind.still)
          this.TierRow('头像档位', TierKind.profile)
        }
        .width('100%')
        .backgroundColor(Theme.glassFill)
        .borderRadius(10)
      }

      Divider().color(Theme.line)

      Column({ space: 8 }) {
        Text('最低分辨率门槛')
          .fontSize(13)
          .fontColor(Theme.textFaint)
        Text('单位为像素，0 表示不限制。低于门槛的候选图不选；候选全部不达标时自动放宽。')
          .fontSize(11)
          .fontColor(Theme.textFaint)
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

      Text('改动后对新刮削生效；已有条目在媒体库执行「刷新元数据」会按新画质重下。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /** 画质一档：名称 + 磁盘估算，下面一句说明，右侧单选勾 */
  @Builder
  QualityRow(id: string, title: string, desc: string) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Row({ space: 8 }) {
          Text(title)
            .fontSize(15)
            .fontColor(Theme.text)
          if (this.qualityEstimate(id).length > 0) {
            Text(this.qualityEstimate(id))
              .fontSize(12)
              .fontColor(Theme.textMuted)
          }
        }
        .alignItems(VerticalAlign.Center)
        Text(desc)
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(16)
        .fontColor([Theme.accent])
        .opacity(this.selectedQuality() === id ? 1 : 0)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .onClick(() => {
      this.selectQuality(id);
    })
  }

  /** 自定义画质的单个档位行：点开弹层选择 */
  @Builder
  TierRow(label: string, kind: string) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(14)
        .fontColor(Theme.textMuted)
        .layoutWeight(1)
      Text(this.tierValue(kind).length > 0 ? this.tierValue(kind) : `跟随环境（${this.effectiveSizeOf(kind)}）`)
        .fontSize(13)
        .fontColor(Theme.text)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .onClick(() => {
      this.tierPicking = kind;
      this.sheetMode = SheetKind.tier;
      this.showSheet = true;
    })
  }

  @Builder
  NamingFields() {
    Column({ space: 12 }) {
      this.NamingFieldRow('naming_entry_dir')
      this.NamingFieldRow('naming_movie_file')
      this.NamingFieldRow('naming_season_dir')
      this.NamingFieldRow('naming_episode_file')

      // 占位符：插到「最后聚焦的输入框」光标处（默认剧集文件名，同 Web/iOS）
      Column({ space: 8 }) {
        Text(`点击把占位符插入「${this.focusedNamingField().label}」`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
        Column({ space: 10 }) {
          ForEach(ScrapeNaming.tokenGroups, (group: NamingTokenGroup) => {
            if (this.groupTokens(group).length > 0) {
              Column({ space: 6 }) {
                Text(group.label)
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
                  .width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.groupTokens(group), (token: NamingToken) => {
                    Text(token.name)
                      .fontSize(12)
                      .fontColor(Theme.textMuted)
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                      .backgroundColor(Theme.glassFill)
                      .borderRadius(13)
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        this.insertToken(token.key);
                      })
                  }, (token: NamingToken) => token.key)
                }
                .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
          }, (group: NamingTokenGroup) => group.label)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // 实时预览：两条样例路径（模板有误时只显示「✕ 模板有误」）
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text('实时预览')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .layoutWeight(1)
          Text(this.namingValid() ? '✓ 模板有效' : '✕ 模板有误')
            .fontSize(12)
            .fontColor(this.namingValid() ? Theme.ok : Theme.danger)
        }
        .width('100%')
        if (this.namingValid()) {
          this.PreviewLine('电影 · 沙丘：第二部（2024）· 2160p DV TrueHD Atmos · BluRay FRDS',
            '/media/电影/', this.moviePreviewPath())
          this.PreviewLine('剧集 · 风筝（2017）第 1 季第 3 集 · 1080p SDR AAC · WEB-DL CHDWEB',
            '/media/剧集/', this.episodePreviewPath())
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(12)
      .backgroundColor(Theme.glassFill)
      .borderRadius(10)

      Text('留空使用默认模板。目录层级固定为「条目目录 / 季目录 / 文件」，不可自定义；缺失字段会连同相邻括号自动收缩。同条目多版本会自动追加版本标签。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /** 一个命名模板字段：标签 + 输入框（带光标控制器）+ 轻校验错误行 */
  @Builder
  NamingFieldRow(key: string) {
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        Text(ScrapeNaming.fieldByKey(key).label)
          .fontSize(13)
          .fontColor(Theme.textFaint)
        if (ScrapeNaming.fieldByKey(key).note.length > 0) {
          Text(ScrapeNaming.fieldByKey(key).note)
            .fontSize(11)
            .fontColor(Theme.textFaint)
        }
      }
      .width('100%')

      TextInput({
        text: this.namingValueOf(key),
        controller: this.controllerOf(key),
        placeholder: ScrapeNaming.fieldByKey(key).fallback
      })
        .width('100%')
        .height(42)
        .fontSize(13)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onFocus(() => {
          this.lastFocused = key;
        })
        .onChange((v: string): void => {
          this.setNamingValue(key, v);
          this.markDirty();
        })

      if (this.namingErrorOf(key).length > 0) {
        Text(this.namingErrorOf(key))
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 预览一行：说明 + 根路径（弱）与渲染路径（强调） */
  @Builder
  PreviewLine(caption: string, root: string, path: string) {
    Column({ space: 3 }) {
      Text(caption)
        .fontSize(11)
        .fontColor(Theme.textFaint)
      Text() {
        Span(root)
          .fontColor(Theme.textFaint)
        Span(path)
          .fontColor(Theme.accent)
      }
      .fontSize(12)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
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
      Text('写进目录后，别的播放器（Infuse、Kodi 等）也能读到这些信息。只增不删除；已存在的 NFO 绝不覆盖。')
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

  // MARK: 弹层

  @Builder
  SheetContent() {
    if (this.sheetMode === SheetKind.fanartKey) {
      this.FanartKeySheet()
    } else {
      this.TierPickerSheet()
    }
  }

  @Builder
  FanartKeySheet() {
    Column({ space: 12 }) {
      Text(this.fanartConfigured() ? '更换 Fanart API Key' : 'Fanart API Key')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')

      if (this.fanartConfigured()) {
        Column({ space: 6 }) {
          Row({ space: 12 }) {
            Text('当前密钥')
              .fontSize(13)
              .fontColor(Theme.textMuted)
              .layoutWeight(1)
            Text(`••••${this.fanartStatus?.key_hint ?? ''}`)
              .fontSize(14)
              .fontColor(Theme.text)
          }
          .width('100%')
          Text(this.fanartKeyInvalid() ? '密钥已失效，需要重新配置' : '已配置，保存在当前服务器。不输入新密钥直接取消会保留原配置。')
            .fontSize(12)
            .fontColor(this.fanartKeyInvalid() ? Theme.danger : Theme.textFaint)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(12)
        .backgroundColor(Theme.glassFill)
        .borderRadius(10)
      }

      TextInput({
        text: this.keyInput,
        placeholder: this.fanartConfigured() ? '输入新的 API Key' : '输入 API Key'
      })
        .width('100%')
        .height(42)
        .type(InputType.Password)
        .showPasswordIcon(true)
        .fontSize(14)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onChange((v: string): void => {
          this.keyInput = v;
          this.keyError = '';
        })

      Text('获取免费 API Key（复制申请链接）')
        .fontSize(13)
        .fontColor(Theme.accentStrong)
        .onClick(() => {
          this.copyFanartSignupLink();
        })

      if (this.keyError.length > 0) {
        Text(this.keyError)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }

      Row({ space: 10 }) {
        Text('取消')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(12)
          .onClick(() => {
            this.cancelKeySheet();
          })
        Text(this.keySaving ? '验证中…' : '验证并启用')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .backgroundColor(Theme.accent)
          .borderRadius(12)
          .onClick(() => {
            this.verifyFanartKey();
          })
      }
      .width('100%')

      Text('验证成功后立即将密钥保存到当前服务器，并启用 Fanart 选图。验证失败不会替换原密钥。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 18, bottom: 24 })
  }

  @Builder
  TierPickerSheet() {
    Column({ space: 4 }) {
      Text(this.tierPickerTitle())
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')
      this.TierOptionRow('')
      ForEach(this.tierOptions(this.tierPicking), (size: string) => {
        this.TierOptionRow(size)
      }, (size: string) => size)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 18, bottom: 24 })
  }

  @Builder
  TierOptionRow(value: string) {
    Row({ space: 12 }) {
      Text(this.tierOptionLabel(value))
        .fontSize(15)
        .fontColor(Theme.text)
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(15)
        .fontColor([Theme.accent])
        .opacity(this.tierValue(this.tierPicking) === value ? 1 : 0)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(() => {
      this.setTierValue(this.tierPicking, value);
      this.showSheet = false;
    })
  }
}
