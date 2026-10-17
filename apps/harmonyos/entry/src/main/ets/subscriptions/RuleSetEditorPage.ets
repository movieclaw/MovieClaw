import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { RuleSetPayload, RuleSetView } from '../api/Models';
import { JsonValue } from '../api/JsonValue';
import {
  AUDIO_LANGUAGES,
  CODEC_FAMILIES,
  CodecFamily,
  DEFAULT_LADDER,
  HDR_OPTIONS,
  LADDER_OPTIONS,
  LibraryRoutingOptions,
  MEDIA_SOURCES,
  PLATFORM_OPTIONS,
  RESOLUTIONS,
  RegionPreset,
  RoutingGenre,
  RoutingOptionsCache,
  RuleOption,
  RuleSetScope,
  RuleSetSpec,
  RuleSetText,
  SUBTITLE_LANGUAGES,
  UPGRADE_OPTIONS,
  UpgradeLadderPreview,
  CountryOption,
  parseIntInput,
  parseGroupList,
  platformLabel
} from './RuleSetModel';

/** 规则集编辑页的路由参数（路由参数会被序列化，不要用 instanceof） */
export class RuleSetEditorParams {
  /** 0 = 新建 */
  readonly ruleSetId: number;

  constructor(ruleSetId: number) {
    this.ruleSetId = ruleSetId;
  }

  static of(param: Object | undefined | null): RuleSetEditorParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: RuleSetEditorParams = param as RuleSetEditorParams;
    const id: number = Number.isFinite(raw.ruleSetId) ? Math.floor(raw.ruleSetId) : 0;
    return new RuleSetEditorParams(id > 0 ? id : 0);
  }
}

/** 表单校验 + 产出的 spec（保存与底部回执共用） */
class DraftResult {
  readonly spec: RuleSetSpec;
  readonly error: string;

  constructor(spec: RuleSetSpec, error: string) {
    this.spec = spec;
    this.error = error;
  }
}

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function RuleSetEditorBuilder() {
  RuleSetEditorPage()
}

/**
 * 规则集编辑器页（对应 iOS `RuleSetEditorSheet` / Web `RuleSetEditorDialog`）。
 *
 * 表单化不手写 JSON；列表顺序即偏好（芯片标序号）；「适用范围 / 画质与来源 / 下载与限制」默认折叠、
 * 折叠头显示当前摘要；底部回执与保存共用同一个 draft（所见即所存）；矛盾在源头消除。
 */
@ComponentV2
export struct RuleSetEditorPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  private ruleSetId: number = 0;

  build() {
    NavDestination() {
      Column() {
        PageTopBar({
          title: this.ruleSetId > 0 ? '编辑规则组' : '新建规则组',
          onBack: (): void => {
            this.navStack.pop();
          }
        })
        RuleSetEditorBody({
          ruleSetId: this.ruleSetId,
          onClose: (): void => {
            this.navStack.pop();
          }
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: RuleSetEditorParams | null = RuleSetEditorParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.ruleSetId = params.ruleSetId;
      }
    })
  }
}

/** 可复用的编辑器正文（路由页与订阅弹层内的快捷新建共用） */
@ComponentV2
export struct RuleSetEditorBody {
  /** 0 = 新建 */
  @Param ruleSetId: number = 0;
  @Event onClose: () => void = (): void => {
  };
  /** 保存成功回调（快捷新建据此选中新组）；路由页挂空实现即可 */
  @Event onSaved: (rule: RuleSetView) => void = (rule: RuleSetView): void => {
  };

  @Local private loaded: boolean = false;
  @Local private original: RuleSetSpec = new RuleSetSpec();
  @Local private name: string = '';
  @Local private scope: RuleSetScope = new RuleSetScope();
  @Local private routingOptions: LibraryRoutingOptions | null = null;
  @Local private referenceCount: number = 0;

  @Local private resolutions: string[] = [];
  @Local private mediaSources: string[] = [];
  @Local private codecFamilies: string[] = [];
  @Local private platformsAllow: string[] = [];
  @Local private platformsBlock: string[] = [];
  @Local private hdrLevels: string[] = [];
  @Local private hdrBlock: string[] = [];
  @Local private subLangs: string[] = [];
  @Local private audioLangs: string[] = [];
  @Local private freeOnly: boolean = false;
  @Local private excludeHr: boolean = false;
  @Local private hrStrict: boolean = false;
  @Local private minSeeders: string = '';
  @Local private sizeMin: string = '';
  @Local private sizeMax: string = '';
  @Local private groupsAllow: string = '';
  @Local private groupsBlock: string = '';
  @Local private upgradeSource: string = '';
  @Local private upgradeKeepOld: boolean = false;
  @Local private cutoffResolution: string = '';
  @Local private upgradeLadder: string[] = DEFAULT_LADDER.slice();

  @Local private openSections: string[] = [];
  @Local private ladderOpen: boolean = false;
  @Local private previewOpen: boolean = false;
  @Local private busy: boolean = false;
  @Local private errorMessage: string = '';
  @Local private failed: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private async load(): Promise<void> {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      if (this.ruleSetId > 0) {
        const rules: RuleSetView[] = await api.rulesList();
        for (const rule of rules) {
          if (rule.id === this.ruleSetId) {
            this.populate(rule);
          }
        }
      } else {
        this.populate(null);
      }
    } catch (error) {
      this.failed = true;
      this.errorMessage = '未能加载规则组，请稍后重试';
      this.populate(null);
    }
    const cached: LibraryRoutingOptions | null = RoutingOptionsCache.get();
    if (cached !== null) {
      this.routingOptions = cached;
    } else {
      try {
        const raw: Record<string, JsonValue> = await api.libraryListRoutingOptions();
        const options: LibraryRoutingOptions = LibraryRoutingOptions.parse(raw);
        RoutingOptionsCache.set(options);
        this.routingOptions = options;
      } catch (error) {
        this.routingOptions = null;
      }
    }
  }

  private populate(rule: RuleSetView | null): void {
    const spec: RuleSetSpec = rule === null ? new RuleSetSpec() : new RuleSetSpec(rule.spec);
    this.original = spec;
    this.name = rule === null ? '' : rule.name;
    this.scope = new RuleSetScope(rule === null ? [] : rule.match_rules);
    this.referenceCount = rule === null ? 0 : rule.reference_count;
    this.resolutions = spec.resolutions.slice();
    this.mediaSources = spec.mediaSources.slice();
    this.codecFamilies = [];
    for (const family of CODEC_FAMILIES) {
      for (const value of spec.videoCodecs) {
        if (family.values.indexOf(value) >= 0 && this.codecFamilies.indexOf(family.label) < 0) {
          this.codecFamilies.push(family.label);
        }
      }
    }
    this.platformsAllow = spec.platforms.filter((id: string): boolean => PLATFORM_OPTIONS.indexOf(id) >= 0);
    this.platformsBlock = spec.platformsBlock.filter((id: string): boolean => PLATFORM_OPTIONS.indexOf(id) >= 0);
    const hdr = spec.effectiveHdr();
    this.hdrLevels = hdr.levels.slice();
    this.hdrBlock = hdr.block.slice();
    this.subLangs = spec.subtitleLanguages.slice();
    this.audioLangs = spec.audioLanguages.slice();
    this.freeOnly = spec.freeOnly;
    this.excludeHr = spec.excludeHr;
    this.hrStrict = spec.hrUnknownPolicy === 'strict';
    this.minSeeders = spec.minSeeders > 0 ? `${spec.minSeeders}` : '';
    this.sizeMin = spec.sizeMinMb > 0 ? `${spec.sizeMinMb}` : '';
    this.sizeMax = spec.sizeMaxMb > 0 ? `${spec.sizeMaxMb}` : '';
    this.groupsAllow = spec.releaseGroupsAllow.join(', ');
    this.groupsBlock = spec.releaseGroupsBlock.join(', ');
    this.upgradeSource = spec.upgradeSource;
    this.upgradeKeepOld = spec.upgradeKeepOld;
    this.cutoffResolution = spec.cutoffResolution;
    this.upgradeLadder = spec.upgradeLadder.length > 0 ? spec.upgradeLadder.slice() : DEFAULT_LADDER.slice();
  }

  // MARK: 派生

  /** 编码族之外的原有值（经 API 写入的自定义编码）：编辑时不丢 */
  private codecExtras(): string[] {
    const out: string[] = [];
    for (const value of this.original.videoCodecs) {
      let known: boolean = false;
      for (const family of CODEC_FAMILIES) {
        if (family.values.indexOf(value) >= 0) {
          known = true;
        }
      }
      if (!known) {
        out.push(value);
      }
    }
    return out;
  }

  /** 常驻选项之外的既有平台值：编辑时不丢 */
  private platformExtras(allow: boolean): string[] {
    const source: string[] = allow ? this.original.platforms : this.original.platformsBlock;
    return source.filter((id: string): boolean => PLATFORM_OPTIONS.indexOf(id) < 0);
  }

  private ladderUnconfigured(dim: string): boolean {
    if (dim === 'hdr') {
      return this.hdrLevels.length === 0;
    }
    if (dim === 'video_codec') {
      return this.codecFamilies.length === 0 && this.codecExtras().length === 0;
    }
    if (dim === 'platform') {
      return this.platformsAllow.length === 0 && this.platformExtras(true).length === 0;
    }
    return false;
  }

  /** 表单状态 → spec 的唯一构造点（保存与回执共用），校验错误随返回值给出 */
  private buildDraft(): DraftResult {
    const next: RuleSetSpec = new RuleSetSpec();
    next.resolutions = this.resolutions.slice();
    next.mediaSources = this.mediaSources.slice();
    const codecs: string[] = [];
    for (const family of CODEC_FAMILIES) {
      if (this.codecFamilies.indexOf(family.label) >= 0) {
        for (const value of family.values) {
          codecs.push(value);
        }
      }
    }
    next.videoCodecs = codecs.concat(this.codecExtras());
    if (this.upgradeSource.length > 0 && !this.ladderEqualsDefault()) {
      next.upgradeLadder = this.upgradeLadder.slice();
    }
    next.platforms = this.platformsAllow.concat(this.platformExtras(true));
    next.platformsBlock = this.platformsBlock.concat(this.platformExtras(false));
    next.hdrLevels = this.hdrLevels.slice();
    next.hdrBlock = this.hdrBlock.slice();
    next.subtitleLanguages = this.subLangs.slice();
    next.audioLanguages = this.audioLangs.slice();
    next.freeOnly = this.freeOnly;
    next.excludeHr = this.excludeHr;
    next.hrUnknownPolicy = this.excludeHr && this.hrStrict ? 'strict' : '';
    const seeders: number | null = parseIntInput(this.minSeeders);
    if (seeders !== null && seeders > 0) {
      next.minSeeders = seeders;
    }
    const min: number | null = parseIntInput(this.sizeMin);
    const max: number | null = parseIntInput(this.sizeMax);
    if (min !== null && min > 0) {
      next.sizeMinMb = min;
    }
    if (max !== null && max > 0) {
      next.sizeMaxMb = max;
    }
    if (min !== null && max !== null && min > 0 && max > 0 && min > max) {
      return new DraftResult(next, '体积下限不能大于上限');
    }
    next.releaseGroupsAllow = parseGroupList(this.groupsAllow);
    next.releaseGroupsBlock = parseGroupList(this.groupsBlock);
    if (this.upgradeSource.length > 0) {
      if (this.mediaSources.length > 0 && this.mediaSources.indexOf(this.upgradeSource) < 0) {
        return new DraftResult(next, '洗版目标片源必须在允许的片源范围内');
      }
      next.upgradeSource = this.upgradeSource;
      const firstResolution: string = this.resolutions.length > 0 ? this.resolutions[0] : '';
      if (this.cutoffResolution.length > 0 && this.cutoffResolution !== firstResolution) {
        if (this.resolutions.length > 0 && this.resolutions.indexOf(this.cutoffResolution) < 0) {
          return new DraftResult(next, '洗版目标分辨率必须在允许的分辨率范围内');
        }
        next.cutoffResolution = this.cutoffResolution;
      }
      next.upgradeKeepOld = this.upgradeKeepOld;
    }
    next.sites = this.original.sites.slice();
    return new DraftResult(next, '');
  }

  private ladderEqualsDefault(): boolean {
    if (this.upgradeLadder.length !== DEFAULT_LADDER.length) {
      return false;
    }
    for (let i = 0; i < DEFAULT_LADDER.length; i++) {
      if (this.upgradeLadder[i] !== DEFAULT_LADDER[i]) {
        return false;
      }
    }
    return true;
  }

  private validScope(): RuleSetScope {
    const result: RuleSetScope = new RuleSetScope();
    result.kind = this.scope.kind;
    result.regions = this.scope.regions.slice();
    result.genres = this.scope.genres.slice();
    if (this.routingOptions !== null) {
      result.genres = this.scope.genres.filter(
        (id: number): boolean => this.hasGenre(id));
    }
    return result;
  }

  private hasGenre(id: number): boolean {
    const options: LibraryRoutingOptions | null = this.routingOptions;
    if (options === null) {
      return true;
    }
    for (const genre of options.genres(this.scope.kind.length > 0 ? this.scope.kind : null)) {
      if (genre.id === id) {
        return true;
      }
    }
    return false;
  }

  private qualitySummary(): string {
    const parts: string[] = [];
    if (this.codecFamilies.length > 0) {
      parts.push(this.codecFamilies.join('/'));
    }
    if (this.platformsAllow.length > 0) {
      parts.push(this.platformsAllow.map((id: string): string => platformLabel(id)).join('/'));
    }
    if (this.platformsBlock.length > 0) {
      parts.push('排除 ' + this.platformsBlock.map((id: string): string => platformLabel(id)).join('/'));
    }
    if (this.hdrLevels.length > 0) {
      parts.push(RuleSetText.hdrChipText(this.hdrLevels));
    }
    if (this.hdrBlock.length > 0) {
      parts.push('排除 ' + this.hdrBlock.join('/'));
    }
    if (this.groupsAllow.trim().length > 0) {
      parts.push('组 ' + this.groupsAllow.trim());
    }
    if (this.groupsBlock.trim().length > 0) {
      parts.push('排除组 ' + this.groupsBlock.trim());
    }
    return parts.length === 0 ? '未设置' : parts.join(' · ');
  }

  private limitSummary(): string {
    const parts: string[] = [];
    if (this.subLangs.length > 0) {
      parts.push('字幕 ' + this.subLangs.map((v: string): string => optionLabelOf(SUBTITLE_LANGUAGES, v)).join('/'));
    }
    if (this.audioLangs.length > 0) {
      parts.push('音轨 ' + this.audioLangs.map((v: string): string => optionLabelOf(AUDIO_LANGUAGES, v)).join('/'));
    }
    if (this.freeOnly) {
      parts.push('仅免费');
    }
    if (this.excludeHr) {
      parts.push('排除 H&R');
    }
    const min: string = this.sizeMin.trim();
    const max: string = this.sizeMax.trim();
    if (this.minSeeders.trim().length > 0) {
      parts.push(`做种 ≥ ${this.minSeeders.trim()}`);
    }
    if (min.length > 0 || max.length > 0) {
      parts.push(`体积 ${min.length === 0 ? '0' : min}–${max.length === 0 ? '∞' : max}MB`);
    }
    return parts.length === 0 ? '未设置' : parts.join(' · ');
  }

  private scopeSummary(): string {
    const summary: string | null = this.validScope().summary(this.routingOptions);
    return summary === null ? '未设置（只能手动选用，或作为默认组兜底）' : summary;
  }

  private toggle(list: string[], value: string): string[] {
    const next: string[] = list.slice();
    const at: number = next.indexOf(value);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(value);
    }
    return next;
  }

  /** 三态循环：不限 → 只要 → 排除 → 不限（同一值不可能同时进白黑名单） */
  private cycle(value: string, allow: boolean): void {
    if (allow) {
      if (this.platformsAllow.indexOf(value) >= 0) {
        this.platformsAllow = this.platformsAllow.filter((v: string): boolean => v !== value);
        this.platformsBlock = this.platformsBlock.concat([value]);
        return;
      }
      this.platformsBlock = this.platformsBlock.filter((v: string): boolean => v !== value);
      this.platformsAllow = this.platformsAllow.concat([value]);
      return;
    }
  }

  private cycleHdr(value: string): void {
    if (this.hdrLevels.indexOf(value) >= 0) {
      this.hdrLevels = this.hdrLevels.filter((v: string): boolean => v !== value);
      this.hdrBlock = this.hdrBlock.concat([value]);
      return;
    }
    if (this.hdrBlock.indexOf(value) >= 0) {
      this.hdrBlock = this.hdrBlock.filter((v: string): boolean => v !== value);
      return;
    }
    this.hdrLevels = this.hdrLevels.concat([value]);
  }

  private cyclePlatform(value: string): void {
    if (this.platformsAllow.indexOf(value) >= 0) {
      this.platformsAllow = this.platformsAllow.filter((v: string): boolean => v !== value);
      this.platformsBlock = this.platformsBlock.concat([value]);
      return;
    }
    if (this.platformsBlock.indexOf(value) >= 0) {
      this.platformsBlock = this.platformsBlock.filter((v: string): boolean => v !== value);
      return;
    }
    this.platformsAllow = this.platformsAllow.concat([value]);
  }

  private isOpen(key: string): boolean {
    return this.openSections.indexOf(key) >= 0;
  }

  private toggleSection(key: string): void {
    const at: number = this.openSections.indexOf(key);
    if (at >= 0) {
      this.openSections.splice(at, 1);
    } else {
      this.openSections.push(key);
    }
  }

  private async submit(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    const draft: DraftResult = this.buildDraft();
    if (draft.error.length > 0) {
      this.errorMessage = draft.error;
      return;
    }
    this.busy = true;
    this.errorMessage = '';
    const payload: RuleSetPayload = {
      name: this.name.trim(),
      spec: draft.spec.toJson(),
      match_rules: this.validScope().toRules()
    };
    try {
      const saved: RuleSetView = this.ruleSetId > 0
        ? await api.rulesUpdate(this.ruleSetId, payload)
        : await api.rulesCreate(payload);
      this.onSaved(saved);
      this.onClose();
    } catch (error) {
      this.errorMessage = error instanceof ApiError && error.message.length > 0
        ? error.message : '保存失败，请稍后重试';
      this.busy = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize(13)
            .fontColor(Theme.danger)
            .padding(12)
            .width('100%')
            .backgroundColor('rgba(255,107,107,0.10)')
            .borderRadius(12)
        }
        if (this.referenceCount > 0) {
          Text(`此组正被 ${this.referenceCount} 个订阅使用，保存后对它们之后的资源评估立即生效（已下载的内容不受影响）。`)
            .fontSize(12)
            .fontColor(Theme.warn)
            .padding(12)
            .width('100%')
            .backgroundColor('rgba(245,196,81,0.10)')
            .borderRadius(12)
        }

        // 名称
        this.FieldLabel('名称')
        TextInput({ text: this.name, placeholder: '如：4K 免费、追剧省流' })
          .height(42)
          .fontSize(15)
          .fontColor(Theme.text)
          .backgroundColor(Theme.surface)
          .borderRadius(10)
          .onChange((value: string): void => {
            this.name = value;
          })

        // 适用范围（折叠）
        this.SectionHeader('适用范围', this.scopeSummary(), 'scope')
        if (this.isOpen('scope')) {
          Text('订阅的作品符合这里的条件时，自动选用本规则组；多个组都符合时条件更多的优先，都不符合时用默认组。只选「电影」或「剧集」即可让本组成为该类型的默认选择。')
            .fontSize(12)
            .fontColor(Theme.textMuted)
          this.FieldLabel('作品类型')
          Row({ space: 8 }) {
            RuleChip({
              label: '不限', active: this.scope.kind.length === 0, onTap: (): void => {
                this.scope.kind = '';
              }
            })
            RuleChip({
              label: '电影', active: this.scope.kind === 'movie', onTap: (): void => {
                this.scope.kind = 'movie';
              }
            })
            RuleChip({
              label: '剧集', active: this.scope.kind === 'tv', onTap: (): void => {
                this.scope.kind = 'tv';
              }
            })
          }
          .width('100%')
          this.ScopeEditor()
        }

        // 分辨率
        this.FieldLabel('分辨率')
        this.ResolutionChips()
        Text('点击依次选择，先选的优先（选中顺序 = 下载偏好）；不选 = 不限。限定分辨率后，无法从种子名识别出分辨率的资源也会被排除，可用「手动选种」兜底')
          .fontSize(12)
          .fontColor(Theme.textMuted)

        // 片源
        this.FieldLabel('片源')
        this.SourceChips()
        Text('点击依次选择，先选的优先；不选 = 不限。Rip 类 = WEBRip/BDRip，电视录制类 = HDTV/DVD。限定片源后，无法从种子名识别出片源的资源也会被排除，可用「手动选种」兜底')
          .fontSize(12)
          .fontColor(Theme.textMuted)

        // 画质与来源（折叠）
        this.SectionHeader('画质与来源', this.qualitySummary(), 'quality')
        if (this.isOpen('quality')) {
          this.FieldLabel('视频编码')
          this.CodecChips()
          if (this.codecExtras().length > 0) {
            Text(`另有自定义值：${this.codecExtras().join('、')}（保留）`)
              .fontSize(11)
              .fontColor(Theme.textFaint)
          }
          this.FieldLabel('流媒体平台')
          this.PlatformChips()
          this.FieldLabel('HDR')
          this.HdrChips()
          this.FieldLabel('制作组白名单')
          this.TextRow('留空不限', this.groupsAllow, (v: string): void => {
            this.groupsAllow = v;
          })
          this.FieldLabel('制作组黑名单')
          this.TextRow('留空不启用', this.groupsBlock, (v: string): void => {
            this.groupsBlock = v;
          })
        }

        // 下载与限制（折叠）
        this.SectionHeader('下载与限制', this.limitSummary(), 'limits')
        if (this.isOpen('limits')) {
          this.FieldLabel('字幕语言')
          this.SubtitleChips()
          this.FieldLabel('音轨语言')
          this.AudioChips()
          RuleToggleRow({
            title: '只要免费资源', hint: '促销状态未知的按非免费处理', value: this.freeOnly,
            onToggle: (on: boolean): void => {
              this.freeOnly = on;
            }
          })
          RuleToggleRow({
            title: '排除 H&R 考核种子', hint: '有做种考核要求的资源不下载', value: this.excludeHr,
            onToggle: (on: boolean): void => {
              this.excludeHr = on;
            }
          })
          if (this.excludeHr) {
            RuleToggleRow({
              title: '站点未提供 H&R 信息时，保守视作有考核而排除', hint: '', value: this.hrStrict,
              onToggle: (on: boolean): void => {
                this.hrStrict = on;
              }
            })
          }
          RuleNumberRow({
            title: '做种数下限', text: this.minSeeders,
            onChange: (v: string): void => {
              this.minSeeders = v;
            }
          })
          RuleNumberRow({
            title: '单集体积下限 (MB)', text: this.sizeMin,
            onChange: (v: string): void => {
              this.sizeMin = v;
            }
          })
          RuleNumberRow({
            title: '单集体积上限 (MB)', text: this.sizeMax,
            onChange: (v: string): void => {
              this.sizeMax = v;
            }
          })
          Text('体积按「每集均摊」评估：整季包用总体积 ÷ 集数比较，整季合集不会被单集上限误杀。')
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }

        // 洗版
        this.UpgradeSection()

        // 回执
        this.Receipt()

        Text(this.busy ? '保存中…' : '保存')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.name.trim().length > 0 && !this.busy ? '#0b0d12' : Theme.textFaint)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 14, bottom: 14 })
          .backgroundColor(this.name.trim().length > 0 && !this.busy ? Theme.accent : Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick(() => {
            this.submit();
          })

        if (this.failed) {
          Text('（规则组清单加载失败，保存可能覆盖不了原有字段，请重试）')
            .fontSize(11)
            .fontColor(Theme.textFaint)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 8, bottom: Theme.tabBarInset })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  FieldLabel(label: string) {
    Text(label)
      .fontSize(15)
      .fontWeight(600)
      .fontColor(Theme.text)
      .width('100%')
      .padding({ top: 4 })
  }

  @Builder
  SectionHeader(title: string, summary: string, key: string) {
    Row({ space: 10 }) {
      Text(title)
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      Blank()
      Text(summary)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(2)
        .textAlign(TextAlign.End)
      SymbolGlyph(this.isOpen(key) ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .onClick(() => {
      this.toggleSection(key);
    })
  }

  @Builder
  ResolutionChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(RESOLUTIONS, (value: string) => {
        RuleChip({
          label: value,
          active: this.resolutions.indexOf(value) >= 0,
          order: this.resolutions.indexOf(value) >= 0 && this.resolutions.length > 1
            ? this.resolutions.indexOf(value) + 1 : 0,
          onTap: (): void => {
            this.resolutions = this.toggle(this.resolutions, value);
          }
        })
      }, (value: string) => value)
    }
    .width('100%')
  }

  @Builder
  SourceChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(MEDIA_SOURCES, (option: RuleOption) => {
        RuleChip({
          label: option.label,
          active: this.mediaSources.indexOf(option.value) >= 0,
          order: this.mediaSources.indexOf(option.value) >= 0 && this.mediaSources.length > 1
            ? this.mediaSources.indexOf(option.value) + 1 : 0,
          onTap: (): void => {
            this.mediaSources = this.toggle(this.mediaSources, option.value);
            // 收窄白名单时洗版终点被排除在外，直接清掉终点
            if (this.upgradeSource.length > 0 && this.mediaSources.length > 0
              && this.mediaSources.indexOf(this.upgradeSource) < 0) {
              this.upgradeSource = '';
            }
          }
        })
      }, (option: RuleOption) => option.value)
    }
    .width('100%')
  }

  @Builder
  CodecChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(CODEC_FAMILIES, (family: CodecFamily) => {
        RuleChip({
          label: family.label,
          active: this.codecFamilies.indexOf(family.label) >= 0,
          onTap: (): void => {
            this.codecFamilies = this.toggle(this.codecFamilies, family.label);
          }
        })
      }, (family: CodecFamily) => family.label)
    }
    .width('100%')
  }

  @Builder
  PlatformChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(PLATFORM_OPTIONS, (value: string) => {
        RuleTriChip({
          label: platformLabel(value),
          state: this.platformsAllow.indexOf(value) >= 0 ? 'include'
            : (this.platformsBlock.indexOf(value) >= 0 ? 'exclude' : 'off'),
          onTap: (): void => {
            this.cyclePlatform(value);
          }
        })
      }, (value: string) => value)
    }
    .width('100%')
  }

  @Builder
  HdrChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(HDR_OPTIONS, (value: string) => {
        RuleTriChip({
          label: value,
          state: this.hdrLevels.indexOf(value) >= 0 ? 'include'
            : (this.hdrBlock.indexOf(value) >= 0 ? 'exclude' : 'off'),
          onTap: (): void => {
            this.cycleHdr(value);
          }
        })
      }, (value: string) => value)
    }
    .width('100%')
  }

  @Builder
  SubtitleChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(SUBTITLE_LANGUAGES, (option: RuleOption) => {
        RuleChip({
          label: option.label,
          active: this.subLangs.indexOf(option.value) >= 0,
          onTap: (): void => {
            this.subLangs = this.toggle(this.subLangs, option.value);
          }
        })
      }, (option: RuleOption) => option.value)
    }
    .width('100%')
  }

  @Builder
  AudioChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(AUDIO_LANGUAGES, (option: RuleOption) => {
        RuleChip({
          label: option.label,
          active: this.audioLangs.indexOf(option.value) >= 0,
          onTap: (): void => {
            this.audioLangs = this.toggle(this.audioLangs, option.value);
          }
        })
      }, (option: RuleOption) => option.value)
    }
    .width('100%')
  }

  @Builder
  TextRow(placeholder: string, text: string, onChange: (value: string) => void) {
    TextInput({ text: text, placeholder: placeholder })
      .height(40)
      .fontSize(14)
      .fontColor(Theme.text)
      .backgroundColor(Theme.surface)
      .borderRadius(10)
      .onChange((value: string): void => {
        onChange(value);
      })
  }

  @Builder
  ScopeEditor() {
    if (this.routingOptions === null) {
      Text('正在加载可选项…')
        .fontSize(13)
        .fontColor(Theme.textFaint)
    } else {
      this.FieldLabel('区域（勾选任一即匹配）')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.countryOptions(), (country: CountryOption) => {
          RuleChip({
            label: country.name,
            active: this.scope.regions.indexOf(country.code) >= 0,
            onTap: (): void => {
              this.scope.regions = this.toggle(this.scope.regions, country.code);
            }
          })
        }, (country: CountryOption) => country.code)
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        Text('快捷组合')
          .fontSize(11)
          .fontColor(Theme.textFaint)
        ForEach(this.presetOptions(), (preset: RegionPreset) => {
          RuleChip({
            label: preset.label,
            active: this.presetActive(preset),
            onTap: (): void => {
              this.togglePreset(preset);
            }
          })
        }, (preset: RegionPreset) => preset.key)
      }
      .width('100%')

      this.FieldLabel('类型（勾选任一即匹配）')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.genreOptions(), (genre: RoutingGenre) => {
          RuleChip({
            label: genre.label,
            active: this.scope.genres.indexOf(genre.id) >= 0,
            onTap: (): void => {
              this.scope.genres = this.toggleInt(this.scope.genres, genre.id);
            }
          })
        }, (genre: RoutingGenre) => `${genre.id}`)
      }
      .width('100%')
    }
  }

  @Builder
  UpgradeSection() {
    Column({ space: 10 }) {
      Text('洗版')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        RuleChip({
          label: '不洗版', active: this.upgradeSource.length === 0, onTap: (): void => {
            this.upgradeSource = '';
          }
        })
        ForEach(UPGRADE_OPTIONS.filter(
          (option: RuleOption): boolean => this.mediaSources.length === 0 || this.mediaSources.indexOf(option.value) >= 0),
          (option: RuleOption) => {
            RuleChip({
              label: option.label, active: this.upgradeSource === option.value, onTap: (): void => {
                this.upgradeSource = option.value;
              }
            })
          }, (option: RuleOption) => option.value)
      }
      .width('100%')

      if (this.upgradeSource.length > 0) {
        this.FieldLabel('目标分辨率')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.resolutions.length > 0 ? this.resolutions : RESOLUTIONS, (value: string) => {
            RuleChip({
              label: value, active: this.effectiveCutoff() === value, onTap: (): void => {
                const first: string = this.resolutions.length > 0 ? this.resolutions[0] : '';
                this.cutoffResolution = value === first ? '' : value;
              }
            })
          }, (value: string) => value)
        }
        .width('100%')
        RuleToggleRow({
          title: '洗到新版本后保留旧版本', hint: '多版本共存（收藏家模式）；关闭 = 旧版本进回收站保留 7 天',
          value: this.upgradeKeepOld, onToggle: (on: boolean): void => {
            this.upgradeKeepOld = on;
          }
        })
        Row({ space: 10 }) {
          Text('洗版优先级')
            .fontSize(14)
            .fontColor(Theme.text)
          Blank()
          Text(this.effectiveLadderLabels())
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph(this.ladderOpen ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([Theme.textFaint])
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
        .onClick(() => {
          this.ladderOpen = !this.ladderOpen;
        })
        if (this.ladderOpen) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(LADDER_OPTIONS, (option: RuleOption) => {
              RuleChip({
                label: option.label,
                active: this.upgradeLadder.indexOf(option.value) >= 0,
                order: this.upgradeLadder.indexOf(option.value) >= 0 && this.upgradeLadder.length > 1
                  ? this.upgradeLadder.indexOf(option.value) + 1 : 0,
                onTap: (): void => {
                  this.toggleLadder(option.value);
                }
              })
            }, (option: RuleOption) => option.value)
          }
          .width('100%')
        }
      } else {
        Text('收齐后继续追更高版本，直到达到目标档位为止；不开启 = 下到即止。')
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  private toggleInt(list: number[], value: number): number[] {
    const next: number[] = list.slice();
    const at: number = next.indexOf(value);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(value);
    }
    return next;
  }

  private countryOptions(): CountryOption[] {
    const options: LibraryRoutingOptions | null = this.routingOptions;
    if (options === null) {
      return [];
    }
    const out: CountryOption[] = options.sortedCountries();
    const known: string[] = out.map((country: CountryOption): string => country.code);
    for (const code of this.scope.regions) {
      if (known.indexOf(code) < 0) {
        out.push(new CountryOption(code, code));
      }
    }
    return out;
  }

  private presetOptions(): RegionPreset[] {
    const options: LibraryRoutingOptions | null = this.routingOptions;
    return options === null ? [] : options.regionPresets;
  }

  private presetActive(preset: RegionPreset): boolean {
    if (preset.countries.length === 0) {
      return false;
    }
    for (const code of preset.countries) {
      if (this.scope.regions.indexOf(code) < 0) {
        return false;
      }
    }
    return true;
  }

  private togglePreset(preset: RegionPreset): void {
    if (this.presetActive(preset)) {
      this.scope.regions = this.scope.regions.filter(
        (code: string): boolean => preset.countries.indexOf(code) < 0);
      return;
    }
    const next: string[] = this.scope.regions.slice();
    for (const code of preset.countries) {
      if (next.indexOf(code) < 0) {
        next.push(code);
      }
    }
    this.scope.regions = next;
  }

  private genreOptions(): RoutingGenre[] {
    const options: LibraryRoutingOptions | null = this.routingOptions;
    if (options === null) {
      return [];
    }
    return options.genres(this.scope.kind.length > 0 ? this.scope.kind : null);
  }

  private effectiveCutoff(): string {
    if (this.cutoffResolution.length > 0) {
      return this.cutoffResolution;
    }
    return this.resolutions.length > 0 ? this.resolutions[0] : '1080p';
  }

  private effectiveLadderLabels(): string {
    const labels: string[] = [];
    for (const dim of this.upgradeLadder) {
      if (!this.ladderUnconfigured(dim)) {
        for (const option of LADDER_OPTIONS) {
          if (option.value === dim) {
            labels.push(option.label);
          }
        }
      }
    }
    return labels.length > 0 ? labels.join(' › ') : '分辨率 › 片源';
  }

  private toggleLadder(dim: string): void {
    const at: number = this.upgradeLadder.indexOf(dim);
    if (at >= 0) {
      if (this.upgradeLadder.length > 1) {
        const next: string[] = this.upgradeLadder.slice();
        next.splice(at, 1);
        this.upgradeLadder = next;
      }
    } else {
      this.upgradeLadder = this.upgradeLadder.concat([dim]);
    }
  }

  private receiptPreview(): UpgradeLadderPreview | null {
    return UpgradeLadderPreview.of(this.buildDraft().spec);
  }

  private receiptTitle(): string {
    return this.receiptPreview() !== null ? '先这样筛掉不要的' : '这条规则会这样筛选';
  }

  private receiptText(): string {
    const preview: UpgradeLadderPreview | null = this.receiptPreview();
    const chips: string[] = RuleSetText.summary(this.buildDraft().spec, preview !== null);
    return chips.length === 0 ? '不限任何条件——身份对得上的资源都接受' : chips.join(' · ');
  }

  @Builder
  Receipt() {
    Column({ space: 8 }) {
      Text(this.receiptTitle())
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
      Text(this.receiptText())
        .fontSize(15)
        .fontColor(Theme.text)
        .width('100%')
      if (this.receiptPreview() !== null) {
        Row({ space: 8 }) {
          Text('再一级级洗到')
            .fontSize(13)
            .fontColor(Theme.textMuted)
          Text((this.receiptPreview() as UpgradeLadderPreview).target)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#5eead4')
          Blank()
          Text(this.previewOpen ? '收起' : '看会经过哪些档')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .width('100%')
        .onClick(() => {
          this.previewOpen = !this.previewOpen;
        })
        if (this.previewOpen) {
          Text(`按「${(this.receiptPreview() as UpgradeLadderPreview).dimensions.join(' › ')}」逐维比较，先分出高低的那一维说了算。`)
            .fontSize(12)
            .fontColor(Theme.textFaint)
          Text(`到手即停，不再洗版。${this.upgradeKeepOld ? '旧版本保留共存。' : '旧版本进回收站保留 7 天。'}`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
          if ((this.receiptPreview() as UpgradeLadderPreview).below.length > 0) {
            Text('到终点之前，先到手的可能是下面任意一档：')
              .fontSize(12)
              .fontColor(Theme.textFaint)
            ForEach((this.receiptPreview() as UpgradeLadderPreview).below, (label: string) => {
              Text(`↑ ${label}`)
                .fontSize(13)
                .fontColor(Theme.textMuted)
            }, (label: string) => label)
          } else {
            Text('终点已是最低档，不会有过渡版本。')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.glassFill)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }
}

function optionLabelOf(options: RuleOption[], value: string): string {
  for (const option of options) {
    if (option.value === value) {
      return option.label;
    }
  }
  return value;
}

/** 已选芯片：强调底 + 深色字；带 order 时左上角标序号（列表顺序即偏好） */
@ComponentV2
struct RuleChip {
  @Param label: string = '';
  @Param active: boolean = false;
  @Param order: number = 0;
  @Event onTap: () => void = (): void => {
  };

  build() {
    Row({ space: 4 }) {
      if (this.order > 0) {
        Text(`${this.order}`)
          .fontSize(10)
          .fontWeight(600)
          .fontColor('#0b0d12')
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .backgroundColor('rgba(0,0,0,0.14)')
          .borderRadius(7)
      }
      Text(this.label)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.active ? '#0b0d12' : Theme.textMuted)
    }
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .backgroundColor(this.active ? Theme.accent : Theme.glassFill)
    .borderRadius(14)
    .border({ width: 1, color: this.active ? Theme.accent : Theme.line })
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 三态芯片：不限（灰）→ 只要（青）→ 排除（红） */
@ComponentV2
struct RuleTriChip {
  /** off / include / exclude */
  @Param state: string = 'off';
  @Param label: string = '';
  @Event onTap: () => void = (): void => {
  };

  private color(): string {
    if (this.state === 'include') {
      return '#5eead4';
    }
    if (this.state === 'exclude') {
      return Theme.danger;
    }
    return Theme.textMuted;
  }

  build() {
    Text(this.label)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.color())
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.state === 'off' ? Theme.glassFill : 'rgba(94,234,212,0.10)')
      .borderRadius(14)
      .border({ width: 1, color: this.state === 'off' ? Theme.line : this.color() })
      .onClick(() => {
        this.onTap();
      })
  }
}

/** 开关行 */
@ComponentV2
struct RuleToggleRow {
  @Param title: string = '';
  @Param hint: string = '';
  @Param value: boolean = false;
  @Event onToggle: (on: boolean) => void = (on: boolean): void => {
  };

  build() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(17)
          .fontColor(Theme.text)
        if (this.hint.length > 0) {
          Text(this.hint)
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .selectedColor(Theme.accent)
        .onChange((isOn: boolean): void => {
          this.onToggle(isOn);
        })
    }
    .width('100%')
  }
}

/** 数字行：左标题、右输入（留空 = 不限） */
@ComponentV2
struct RuleNumberRow {
  @Param title: string = '';
  @Param text: string = '';
  @Event onChange: (value: string) => void = (value: string): void => {
  };

  build() {
    Row({ space: 12 }) {
      Text(this.title)
        .fontSize(17)
        .fontColor(Theme.text)
        .layoutWeight(1)
      TextInput({ text: this.text, placeholder: '不限' })
        .type(InputType.Number)
        .width(120)
        .height(38)
        .fontSize(14)
        .textAlign(TextAlign.End)
        .backgroundColor(Theme.surface)
        .borderRadius(10)
        .onChange((value: string): void => {
          this.onChange(value);
        })
    }
    .width('100%')
  }
}
