import { JsonList, JsonMap, JsonValue, jsonArrayValue, jsonBoolValue, jsonGet, jsonIntValue, jsonObjectValue, jsonStringValue } from '../api/JsonValue';
import { RuleSetView } from '../api/Models';

/**
 * 规则组的领域模型与「人话」翻译（对应 iOS `RuleSetEditorModel.swift` / Web `rule-sets-panel.tsx`）。
 *
 * 后端把 spec 存成自由 JSON（`Record<string, JsonValue>`），这里转成强类型的 `RuleSetSpec`
 * 供编辑器双向绑定；保存时只写用户真的设置过的键，未知键（经 API 写入的预留字段）原样带回。
 *
 * 规则集编辑器、洗一轮版（挑带洗版目标的组）、订阅详情（事实区「规则组 · 洗到 X」）复用这里。
 */

/** 值-标签对 */
export class RuleOption {
  readonly value: string;
  readonly label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

/** 编码族（一族的等价写法一并写进白名单） */
export class CodecFamily {
  readonly label: string;
  readonly values: string[];

  constructor(label: string, values: string[]) {
    this.label = label;
    this.values = values;
  }
}

/** HDR 白 / 黑名单拆分（旧三态换算后的结果） */
export class HdrSplit {
  readonly levels: string[];
  readonly block: string[];

  constructor(levels: string[], block: string[]) {
    this.levels = levels;
    this.block = block;
  }
}

// MARK: - 词表（与后端 / Web 同值）

export const RESOLUTIONS: string[] = ['2160p', '1080p', '720p'];

export const MEDIA_SOURCES: RuleOption[] = [
  new RuleOption('remux', 'Remux'),
  new RuleOption('blu-ray', '蓝光'),
  new RuleOption('web-dl', 'WEB-DL'),
  new RuleOption('rip', 'Rip 类'),
  new RuleOption('tv', '电视录制类')
];

export const CODEC_FAMILIES: CodecFamily[] = [
  new CodecFamily('H.265', ['x265', 'H.265', 'HEVC']),
  new CodecFamily('H.264', ['x264', 'H.264', 'AVC']),
  new CodecFamily('AV1', ['AV1'])
];

export const HDR_OPTIONS: string[] = ['DV', 'HDR10+', 'HDR10', 'HLG', 'SDR'];

export const SUBTITLE_LANGUAGES: RuleOption[] = [
  new RuleOption('zh', '中文（不限简繁）'),
  new RuleOption('zh-Hans', '简体中文'),
  new RuleOption('zh-Hant', '繁体中文'),
  new RuleOption('en', '英文')
];

export const AUDIO_LANGUAGES: RuleOption[] = [
  new RuleOption('cmn', '国语'),
  new RuleOption('yue', '粤语'),
  new RuleOption('ja', '日语'),
  new RuleOption('en', '英语')
];

export const UPGRADE_OPTIONS: RuleOption[] = [
  new RuleOption('web-dl', '洗到 WEB-DL'),
  new RuleOption('blu-ray', '洗到蓝光'),
  new RuleOption('remux', '洗到 Remux')
];

export const LADDER_OPTIONS: RuleOption[] = [
  new RuleOption('resolution', '分辨率'),
  new RuleOption('source', '片源'),
  new RuleOption('hdr', 'HDR'),
  new RuleOption('video_codec', '编码'),
  new RuleOption('platform', '平台')
];

export const DEFAULT_LADDER: string[] = ['resolution', 'source'];

export const DEFAULT_RESOLUTION_LADDER: string[] = ['4320p', '2160p', '1440p', '1080p', '720p', '576p', '480p'];

export const PLATFORM_OPTIONS: string[] = [
  'netflix', 'disney_plus', 'amazon', 'hbo_max', 'apple_tv_plus', 'hulu', 'paramount_plus', 'peacock',
  'iqiyi', 'wetv', 'youku', 'mangotv', 'bilibili', 'viu', 'crunchyroll', 'hotstar'
];

export const PLATFORM_LABELS: Record<string, string> = {
  'netflix': 'Netflix', 'amazon': 'Prime Video', 'disney_plus': 'Disney+', 'hbo_max': 'HBO Max',
  'hulu': 'Hulu', 'apple_tv_plus': 'Apple TV+', 'paramount_plus': 'Paramount+', 'peacock': 'Peacock',
  'showtime': 'Showtime', 'starz': 'Starz', 'discovery_plus': 'Discovery+', 'crave': 'Crave', 'stan': 'Stan',
  'roku': 'Roku', 'google_tv': 'Google TV', 'itunes': 'iTunes', 'sony_core': 'Sony Pictures Core',
  'criterion': 'Criterion', 'iqiyi': '爱奇艺', 'wetv': '腾讯视频', 'youku': '优酷', 'mangotv': '芒果 TV',
  'bilibili': '哔哩哔哩', 'viu': 'Viu', 'nowplayer': 'Now player', 'mytv_super': 'myTV SUPER',
  'hami_video': 'Hami Video', 'line_tv': 'LINE TV', 'kktv': 'KKTV', 'tving': 'TVING', 'wavve': 'Wavve',
  'coupang_play': 'Coupang Play', 'kocowa': 'KOCOWA', 'viki': 'Viki', 'unext': 'U-NEXT', 'tver': 'TVer',
  'fod': 'FOD', 'dmm_tv': 'DMM TV', 'hotstar': 'Hotstar', 'crunchyroll': 'Crunchyroll', 'hidive': 'HIDIVE',
  'abema': 'ABEMA', 'adn': 'ADN', 'funimation': 'Funimation', 'vrv': 'VRV', 'wakanim': 'Wakanim',
  'b_global': 'B-Global'
};

export function platformLabel(id: string): string {
  const label: string | undefined = PLATFORM_LABELS[id];
  return label === undefined ? id : label;
}

export function mediaSourceLabel(value: string): string {
  for (const option of MEDIA_SOURCES) {
    if (option.value === value) {
      return option.label;
    }
  }
  return value;
}

export function upgradeSourceLabel(value: string): string {
  const labels: Record<string, string> = { 'web-dl': 'WEB-DL', 'blu-ray': '蓝光', 'remux': 'Remux' };
  const label: string | undefined = labels[value];
  return label === undefined ? value : label;
}

// MARK: - JSON 取值小工具

function rawStrings(raw: JsonMap | null, key: string): string[] {
  const out: string[] = [];
  if (raw === null) {
    return out;
  }
  const list: JsonList | null = jsonArrayValue(raw[key]);
  if (list === null) {
    return out;
  }
  for (const item of list) {
    const value: string | null = jsonStringValue(item);
    if (value !== null) {
      out.push(value);
    }
  }
  return out;
}

function rawInts(raw: JsonMap | null, key: string): number[] {
  const out: number[] = [];
  if (raw === null) {
    return out;
  }
  const list: JsonList | null = jsonArrayValue(raw[key]);
  if (list === null) {
    return out;
  }
  for (const item of list) {
    const value: number | null = jsonIntValue(item);
    if (value !== null) {
      out.push(value);
    }
  }
  return out;
}

function rawInt(raw: JsonMap | null, key: string): number | null {
  if (raw === null) {
    return null;
  }
  const value: JsonValue | undefined = raw[key];
  if (value === undefined || value === null) {
    return null;
  }
  return jsonIntValue(value);
}

function rawStr(raw: JsonMap | null, key: string): string | null {
  if (raw === null) {
    return null;
  }
  const value: JsonValue | undefined = raw[key];
  if (value === undefined || value === null) {
    return null;
  }
  return jsonStringValue(value);
}

function rawBool(raw: JsonMap | null, key: string): boolean {
  if (raw === null) {
    return false;
  }
  const value: JsonValue | undefined = raw[key];
  const parsed: boolean | null = jsonBoolValue(value === undefined ? null : value);
  return parsed === true;
}

function putStrings(out: Record<string, JsonValue>, key: string, values: string[]): void {
  if (values.length === 0) {
    return;
  }
  const list: JsonList = [];
  for (const value of values) {
    list.push(value);
  }
  out[key] = list;
}

// MARK: - spec 强类型

/** 规则组过滤条件（见后端 `RuleSetSpec`）：全部键可缺省 = 不限。 */
export class RuleSetSpec {
  resolutions: string[] = [];
  mediaSources: string[] = [];
  videoCodecs: string[] = [];
  platforms: string[] = [];
  platformsBlock: string[] = [];
  releaseGroupsAllow: string[] = [];
  releaseGroupsBlock: string[] = [];
  hdrLevels: string[] = [];
  hdrBlock: string[] = [];
  /** [兼容层] 旧 HDR / DV 三态：新键为空时后端才消费 */
  legacyHdr: string = '';
  legacyDv: string = '';
  freeOnly: boolean = false;
  minSeeders: number = 0;
  sizeMinMb: number = 0;
  sizeMaxMb: number = 0;
  excludeHr: boolean = false;
  hrUnknownPolicy: string = '';
  subtitleLanguages: string[] = [];
  audioLanguages: string[] = [];
  /** 洗版目标片源档；'' = 不洗版 */
  upgradeSource: string = '';
  cutoffResolution: string = '';
  upgradeKeepOld: boolean = false;
  /** 空数组 = 用缺省阶梯（与 iOS 的 nil 区分：这里额外用 ladderConfigured 记录） */
  upgradeLadder: string[] = [];
  /** 站点白名单：[预留] UI 不编辑，保存时原样带回 */
  sites: string[] = [];

  constructor(raw?: Record<string, JsonValue> | null) {
    if (raw === undefined || raw === null) {
      return;
    }
    const map: JsonMap | null = jsonObjectValue(raw);
    this.resolutions = rawStrings(map, 'resolutions');
    this.mediaSources = rawStrings(map, 'media_sources');
    this.videoCodecs = rawStrings(map, 'video_codecs');
    this.platforms = rawStrings(map, 'platforms');
    this.platformsBlock = rawStrings(map, 'platforms_block');
    this.releaseGroupsAllow = rawStrings(map, 'release_groups_allow');
    this.releaseGroupsBlock = rawStrings(map, 'release_groups_block');
    this.hdrLevels = rawStrings(map, 'hdr_levels');
    this.hdrBlock = rawStrings(map, 'hdr_block');
    this.legacyHdr = rawStr(map, 'hdr') ?? '';
    this.legacyDv = rawStr(map, 'dv') ?? '';
    this.freeOnly = rawBool(map, 'free_only');
    this.minSeeders = rawInt(map, 'min_seeders') ?? 0;
    this.sizeMinMb = rawInt(map, 'size_min_mb') ?? 0;
    this.sizeMaxMb = rawInt(map, 'size_max_mb') ?? 0;
    this.excludeHr = rawBool(map, 'exclude_hr');
    this.hrUnknownPolicy = rawStr(map, 'hr_unknown_policy') ?? '';
    this.subtitleLanguages = rawStrings(map, 'subtitle_languages_require');
    this.audioLanguages = rawStrings(map, 'audio_languages_require');
    this.upgradeSource = rawStr(map, 'upgrade_source') ?? '';
    this.cutoffResolution = rawStr(map, 'cutoff_resolution') ?? '';
    this.upgradeKeepOld = rawBool(map, 'upgrade_keep_old');
    const ladder: string[] = rawStrings(map, 'upgrade_ladder');
    this.upgradeLadder = ladder;
    this.sites = rawStrings(map, 'sites');
  }

  /** 保存用的 JSON：只写设置过的键（与 Web 编辑器 draft.spec 同一口径） */
  toJson(): Record<string, JsonValue> {
    const out: Record<string, JsonValue> = {};
    putStrings(out, 'resolutions', this.resolutions);
    putStrings(out, 'media_sources', this.mediaSources);
    putStrings(out, 'video_codecs', this.videoCodecs);
    putStrings(out, 'upgrade_ladder', this.upgradeLadder);
    putStrings(out, 'platforms', this.platforms);
    putStrings(out, 'platforms_block', this.platformsBlock);
    putStrings(out, 'hdr_levels', this.hdrLevels);
    putStrings(out, 'hdr_block', this.hdrBlock);
    putStrings(out, 'subtitle_languages_require', this.subtitleLanguages);
    putStrings(out, 'audio_languages_require', this.audioLanguages);
    if (this.freeOnly) {
      out['free_only'] = true;
    }
    if (this.excludeHr) {
      out['exclude_hr'] = true;
      if (this.hrUnknownPolicy === 'strict') {
        out['hr_unknown_policy'] = 'strict';
      }
    }
    if (this.minSeeders > 0) {
      out['min_seeders'] = this.minSeeders;
    }
    if (this.sizeMinMb > 0) {
      out['size_min_mb'] = this.sizeMinMb;
    }
    if (this.sizeMaxMb > 0) {
      out['size_max_mb'] = this.sizeMaxMb;
    }
    putStrings(out, 'release_groups_allow', this.releaseGroupsAllow);
    putStrings(out, 'release_groups_block', this.releaseGroupsBlock);
    if (this.upgradeSource.length > 0) {
      out['upgrade_source'] = this.upgradeSource;
      if (this.cutoffResolution.length > 0) {
        out['cutoff_resolution'] = this.cutoffResolution;
      }
      if (this.upgradeKeepOld) {
        out['upgrade_keep_old'] = true;
      }
    }
    putStrings(out, 'sites', this.sites);
    return out;
  }

  /** 旧三态 → (白名单, 黑名单)，与后端 `_hdr_from_legacy` 同一张表 */
  effectiveHdr(): HdrSplit {
    if (this.hdrLevels.length > 0 || this.hdrBlock.length > 0) {
      return new HdrSplit(this.hdrLevels, this.hdrBlock);
    }
    const family: string[] = HDR_OPTIONS.filter((value: string): boolean => value !== 'SDR');
    if (this.legacyHdr === 'forbid') {
      return new HdrSplit(['SDR'], []);
    }
    if (this.legacyDv === 'require') {
      return new HdrSplit(['DV'], []);
    }
    if (this.legacyHdr === 'require') {
      return this.legacyDv === 'forbid'
        ? new HdrSplit(family.filter((value: string): boolean => value !== 'DV'), ['DV'])
        : new HdrSplit(family, []);
    }
    if (this.legacyDv === 'forbid') {
      return new HdrSplit([], ['DV']);
    }
    return new HdrSplit([], []);
  }
}

/** `RuleSetView` → 强类型 spec 的扩展（用函数而非原型扩展，ArkTS 同款） */
export function typedSpec(rule: RuleSetView): RuleSetSpec {
  return new RuleSetSpec(rule.spec);
}

/** 洗版目标人话标签；'' = 本组不洗版 */
export function upgradeTargetOf(rule: RuleSetView): string {
  return RuleSetText.upgradeTargetLabel(typedSpec(rule)) ?? '';
}

// MARK: - spec → 人话

export class RuleSetText {
  static hdrChipText(levels: string[]): string {
    const family: string[] = HDR_OPTIONS.filter((value: string): boolean => value !== 'SDR');
    let hasAll: boolean = family.length > 0;
    for (const value of family) {
      if (levels.indexOf(value) < 0) {
        hasAll = false;
      }
    }
    if (levels.length === family.length && hasAll) {
      return '必须 HDR';
    }
    if (levels.length === 1 && levels[0] === 'SDR') {
      return '排除 HDR';
    }
    return `HDR ${levels.join('/')}`;
  }

  /** 洗版目标的人话标签（「1080p WEB-DL · DV」）；未开洗版返回 null */
  static upgradeTargetLabel(spec: RuleSetSpec): string | null {
    if (spec.upgradeSource.length === 0) {
      return null;
    }
    const resolution: string = spec.cutoffResolution.length > 0
      ? spec.cutoffResolution
      : (spec.resolutions.length > 0 ? spec.resolutions[0] : '1080p');
    const parts: string[] = [`${resolution} ${upgradeSourceLabel(spec.upgradeSource)}`];
    const ladder: string[] = spec.upgradeLadder.length > 0 ? spec.upgradeLadder : DEFAULT_LADDER;
    if (ladder.indexOf('hdr') >= 0 && spec.hdrLevels.length > 0) {
      parts.push(spec.hdrLevels[0]);
    }
    if (ladder.indexOf('video_codec') >= 0 && spec.videoCodecs.length > 0) {
      parts.push(spec.videoCodecs[0]);
    }
    if (ladder.indexOf('platform') >= 0 && spec.platforms.length > 0) {
      parts.push(platformLabel(spec.platforms[0]));
    }
    return parts.join(' · ');
  }

  /** spec → 人话芯片（空 = 全不限） */
  static summary(spec: RuleSetSpec, withoutUpgrade: boolean = false): string[] {
    const chips: string[] = [];
    if (spec.resolutions.length > 0) {
      chips.push(spec.resolutions.join(' > '));
    }
    if (spec.mediaSources.length > 0) {
      chips.push(spec.mediaSources.map((value: string): string => mediaSourceLabel(value)).join(' > '));
    }
    if (!withoutUpgrade) {
      const target: string | null = RuleSetText.upgradeTargetLabel(spec);
      if (target !== null) {
        chips.push(`洗到 ${target}${spec.upgradeKeepOld ? '（保留旧版）' : ''}`);
      }
    }
    if (spec.videoCodecs.length > 0) {
      let rest: string[] = spec.videoCodecs.slice();
      const labels: string[] = [];
      for (const family of CODEC_FAMILIES) {
        let hit: boolean = false;
        for (const value of rest) {
          if (family.values.indexOf(value) >= 0) {
            hit = true;
          }
        }
        if (hit) {
          labels.push(family.label);
          rest = rest.filter((value: string): boolean => family.values.indexOf(value) < 0);
        }
      }
      for (const value of rest) {
        labels.push(value);
      }
      chips.push(labels.join('/'));
    }
    if (spec.platforms.length > 0) {
      chips.push(`平台: ${spec.platforms.map((value: string): string => platformLabel(value)).join('/')}`);
    }
    if (spec.platformsBlock.length > 0) {
      chips.push(`排除平台: ${spec.platformsBlock.map((value: string): string => platformLabel(value)).join('/')}`);
    }
    const hdr: HdrSplit = spec.effectiveHdr();
    if (hdr.levels.length > 0) {
      chips.push(RuleSetText.hdrChipText(hdr.levels));
    }
    if (hdr.block.length > 0) {
      chips.push(`排除 ${hdr.block.join('/')}`);
    }
    if (spec.subtitleLanguages.length > 0) {
      chips.push('字幕: ' + spec.subtitleLanguages.map((value: string): string => optionLabel(SUBTITLE_LANGUAGES, value)).join('/'));
    }
    if (spec.audioLanguages.length > 0) {
      chips.push('音轨: ' + spec.audioLanguages.map((value: string): string => optionLabel(AUDIO_LANGUAGES, value)).join('/'));
    }
    if (spec.freeOnly) {
      chips.push('仅免费');
    }
    if (spec.minSeeders > 0) {
      chips.push(`做种 ≥ ${spec.minSeeders}`);
    }
    if (spec.sizeMinMb > 0 || spec.sizeMaxMb > 0) {
      const min: string = spec.sizeMinMb > 0 ? `${spec.sizeMinMb}` : '';
      const max: string = spec.sizeMaxMb > 0 ? `${spec.sizeMaxMb}` : '';
      if (min.length > 0 && max.length > 0) {
        chips.push(`单集 ${min}–${max}MB`);
      } else if (min.length > 0) {
        chips.push(`单集 ≥ ${min}MB`);
      } else {
        chips.push(`单集 ≤ ${max}MB`);
      }
    }
    if (spec.excludeHr) {
      chips.push(spec.hrUnknownPolicy === 'strict' ? '排除 H&R（未知也排）' : '排除 H&R');
    }
    if (spec.releaseGroupsAllow.length > 0) {
      chips.push(`制作组白名单 ${spec.releaseGroupsAllow.length} 个`);
    }
    if (spec.releaseGroupsBlock.length > 0) {
      chips.push(`制作组黑名单 ${spec.releaseGroupsBlock.length} 个`);
    }
    return chips;
  }
}

function optionLabel(options: RuleOption[], value: string): string {
  for (const option of options) {
    if (option.value === value) {
      return option.label;
    }
  }
  return value;
}

// MARK: - 洗版阶梯预览

/** 把洗版配置摊成「从终点往下数」的档位清单：终点、更高也算达标的顶档、终点之下的过渡档 */
export class UpgradeLadderPreview {
  readonly dimensions: string[];
  readonly target: string;
  readonly ceiling: string;
  readonly below: string[];
  readonly moreBelow: number;

  private constructor(dimensions: string[], target: string, ceiling: string, below: string[], moreBelow: number) {
    this.dimensions = dimensions;
    this.target = target;
    this.ceiling = ceiling;
    this.below = below;
    this.moreBelow = moreBelow;
  }

  static of(spec: RuleSetSpec): UpgradeLadderPreview | null {
    if (spec.upgradeSource.length === 0) {
      return null;
    }
    const known: string[] = LADDER_OPTIONS.map((option: RuleOption): string => option.value);
    const rawLadder: string[] = spec.upgradeLadder.length > 0 ? spec.upgradeLadder : DEFAULT_LADDER;
    let dims: string[] = rawLadder.filter((dim: string): boolean => {
      if (known.indexOf(dim) < 0) {
        return false;
      }
      if (dim === 'hdr' && spec.hdrLevels.length === 0) {
        return false;
      }
      if (dim === 'video_codec' && spec.videoCodecs.length === 0) {
        return false;
      }
      if (dim === 'platform' && spec.platforms.length === 0) {
        return false;
      }
      return true;
    });
    if (dims.length === 0) {
      dims = DEFAULT_LADDER;
    }

    const axes: string[][] = [];
    for (const dim of dims) {
      axes.push(axisOf(spec, dim));
    }
    const digits: number[] = [];
    for (let index = 0; index < dims.length; index++) {
      const dim: string = dims[index];
      const axis: string[] = axes[index];
      if (dim === 'resolution') {
        const target: string = spec.cutoffResolution.length > 0
          ? spec.cutoffResolution
          : (spec.resolutions.length > 0 ? spec.resolutions[0] : '1080p');
        digits.push(axis.indexOf(target));
      } else if (dim === 'source') {
        digits.push(axis.indexOf(mediaSourceLabel(spec.upgradeSource)));
      } else {
        digits.push(0);
      }
    }
    for (const digit of digits) {
      if (digit < 0) {
        return null;
      }
    }
    for (const axis of axes) {
      if (axis.length === 0) {
        return null;
      }
    }

    let total: number = 1;
    for (const axis of axes) {
      total *= axis.length;
    }
    let ordinal: number = 0;
    for (let index = 0; index < axes.length; index++) {
      ordinal = ordinal * axes[index].length + digits[index];
    }
    const belowCount: number = total - 1 - ordinal;
    const shown: number = Math.min(belowCount, 5);
    const below: string[] = [];
    for (let step = 1; step <= shown; step++) {
      below.push(labelOf(axes, decode(axes, ordinal + step)));
    }
    const labelDims: string[] = dims.map((dim: string): string => optionLabel(LADDER_OPTIONS, dim));
    const ceiling: string = ordinal > 0 ? labelOf(axes, decode(axes, 0)) : '';
    return new UpgradeLadderPreview(labelDims, labelOf(axes, digits), ceiling, below, belowCount - shown);
  }
}

function axisOf(spec: RuleSetSpec, dim: string): string[] {
  if (dim === 'resolution') {
    return spec.resolutions.length > 0 ? spec.resolutions : DEFAULT_RESOLUTION_LADDER;
  }
  if (dim === 'source') {
    const chosen: string[] = spec.mediaSources.length > 0
      ? spec.mediaSources
      : MEDIA_SOURCES.map((option: RuleOption): string => option.value);
    return chosen.map((value: string): string => mediaSourceLabel(value));
  }
  if (dim === 'hdr') {
    return spec.hdrLevels;
  }
  if (dim === 'video_codec') {
    const result: string[] = [];
    for (const value of spec.videoCodecs) {
      let familyLabel: string = value;
      for (const family of CODEC_FAMILIES) {
        let hit: boolean = false;
        for (const candidate of family.values) {
          if (candidate.toLowerCase() === value.toLowerCase()) {
            hit = true;
          }
        }
        if (hit) {
          familyLabel = family.label;
        }
      }
      if (result.indexOf(familyLabel) < 0) {
        result.push(familyLabel);
      }
    }
    return result;
  }
  return spec.platforms.map((value: string): string => platformLabel(value));
}

function decode(axes: string[][], value: number): number[] {
  const combo: number[] = [];
  for (let index = 0; index < axes.length; index++) {
    combo.push(0);
  }
  let rest: number = value;
  for (let index = axes.length - 1; index >= 0; index--) {
    combo[index] = rest % axes[index].length;
    rest = Math.floor(rest / axes[index].length);
  }
  return combo;
}

function labelOf(axes: string[][], combo: number[]): string {
  const parts: string[] = [];
  for (let index = 0; index < combo.length; index++) {
    parts.push(axes[index][combo[index]]);
  }
  return parts.join(' · ');
}

// MARK: - 适用范围（match_rules）

/** 规则组适用范围的表单态：kind '' = 不限电影/剧集 */
@ObservedV2
export class RuleSetScope {
  @Trace kind: string = '';
  @Trace regions: string[] = [];
  @Trace genres: number[] = [];

  constructor(rules?: Record<string, JsonValue>[]) {
    if (rules === undefined || rules === null) {
      return;
    }
    const kinds: string[] = scopeValues(rules, 'kind');
    this.kind = kinds.length === 1 && (kinds[0] === 'movie' || kinds[0] === 'tv') ? kinds[0] : '';
    this.regions = scopeValues(rules, 'origin_countries');
    this.genres = scopeIntValues(rules, 'genres');
  }

  /** 表单态 → 条件（空维度不生成条件；全空 = 不声明） */
  toRules(): Record<string, JsonValue>[] {
    const out: Record<string, JsonValue>[] = [];
    if (this.kind.length > 0) {
      out.push(scopeRule('kind', stringsToJson([this.kind])));
    }
    if (this.regions.length > 0) {
      out.push(scopeRule('origin_countries', stringsToJson(this.regions)));
    }
    if (this.genres.length > 0) {
      out.push(scopeRule('genres', intsToJson(this.genres)));
    }
    return out;
  }

  /** 一句话摘要（「剧集 · 日韩 · 动画」）；未声明返回 null */
  summary(options: LibraryRoutingOptions | null): string | null {
    if (this.kind.length === 0 && this.regions.length === 0 && this.genres.length === 0) {
      return null;
    }
    const parts: string[] = [];
    if (this.kind.length > 0) {
      parts.push(this.kind === 'movie' ? '电影' : '剧集');
    }
    if (this.regions.length > 0) {
      parts.push(options === null
        ? `${this.regions.length} 个区域`
        : options.regionLabels(this.regions).join('/'));
    }
    if (this.genres.length > 0) {
      parts.push(options === null
        ? `${this.genres.length} 个类型`
        : options.genres(this.kind.length > 0 ? this.kind : null)
          .filter((genre: RoutingGenre): boolean => this.genres.indexOf(genre.id) >= 0)
          .map((genre: RoutingGenre): string => genre.label)
          .join('/'));
    }
    return parts.join(' · ');
  }
}

function scopeValues(rules: Record<string, JsonValue>[], field: string): string[] {
  for (const rule of rules) {
    const map: JsonMap | null = jsonObjectValue(rule);
    if (map !== null && rawStr(map, 'field') === field) {
      return rawStrings(map, 'values');
    }
  }
  return [];
}

function scopeIntValues(rules: Record<string, JsonValue>[], field: string): number[] {
  for (const rule of rules) {
    const map: JsonMap | null = jsonObjectValue(rule);
    if (map !== null && rawStr(map, 'field') === field) {
      return rawInts(map, 'values');
    }
  }
  return [];
}

function stringsToJson(values: string[]): JsonList {
  const list: JsonList = [];
  for (const value of values) {
    list.push(value);
  }
  return list;
}

function intsToJson(values: number[]): JsonList {
  const list: JsonList = [];
  for (const value of values) {
    list.push(value);
  }
  return list;
}

function scopeRule(field: string, values: JsonList): Record<string, JsonValue> {
  const rule: Record<string, JsonValue> = {};
  rule['field'] = field;
  rule['op'] = 'any_of';
  rule['values'] = values;
  return rule;
}

// MARK: - 收藏范围可选项

export class RoutingGenre {
  readonly id: number;
  readonly label: string;

  constructor(id: number, label: string) {
    this.id = id;
    this.label = label;
  }
}

export class RegionPreset {
  readonly key: string;
  readonly label: string;
  readonly countries: string[];

  constructor(key: string, label: string, countries: string[]) {
    this.key = key;
    this.label = label;
    this.countries = countries;
  }
}

export class CountryOption {
  readonly code: string;
  readonly name: string;

  constructor(code: string, name: string) {
    this.code = code;
    this.name = name;
  }
}

/** 收藏范围可选项（`GET /libraries/routing-options`，自由 JSON 解成强类型） */
export class LibraryRoutingOptions {
  readonly movieGenres: RoutingGenre[];
  readonly tvGenres: RoutingGenre[];
  readonly regionPresets: RegionPreset[];
  readonly countryNames: Record<string, string>;

  constructor(movieGenres: RoutingGenre[], tvGenres: RoutingGenre[], regionPresets: RegionPreset[],
    countryNames: Record<string, string>) {
    this.movieGenres = movieGenres;
    this.tvGenres = tvGenres;
    this.regionPresets = regionPresets;
    this.countryNames = countryNames;
  }

  static parse(raw: Record<string, JsonValue>): LibraryRoutingOptions {
    const map: JsonMap | null = jsonObjectValue(raw);
    const movieGenres: RoutingGenre[] = parseGenres(jsonArrayValue(map === null ? null : map['movie_genres']));
    const tvGenres: RoutingGenre[] = parseGenres(jsonArrayValue(map === null ? null : map['tv_genres']));
    const presets: RegionPreset[] = [];
    const presetList: JsonList | null = jsonArrayValue(map === null ? null : map['region_presets']);
    if (presetList !== null) {
      for (const item of presetList) {
        const presetMap: JsonMap | null = jsonObjectValue(item);
        if (presetMap === null) {
          continue;
        }
        presets.push(new RegionPreset(rawStr(presetMap, 'key') ?? '', rawStr(presetMap, 'label') ?? '',
          rawStrings(presetMap, 'countries')));
      }
    }
    const names: Record<string, string> = {};
    const nameMap: JsonMap | null = jsonObjectValue(map === null ? null : map['country_names']);
    if (nameMap !== null) {
      for (const code of Object.keys(nameMap)) {
        const name: string | null = jsonStringValue(nameMap[code]);
        if (name !== null) {
          names[code] = name;
        }
      }
    }
    return new LibraryRoutingOptions(movieGenres, tvGenres, presets, names);
  }

  /** kind '' = 电影与剧集类型合并去重 */
  genres(kind: string | null): RoutingGenre[] {
    if (kind === 'movie') {
      return this.movieGenres;
    }
    if (kind !== null && kind.length > 0) {
      return this.tvGenres;
    }
    const seen: number[] = [];
    const out: RoutingGenre[] = [];
    for (const genre of this.movieGenres.concat(this.tvGenres)) {
      if (seen.indexOf(genre.id) < 0) {
        seen.push(genre.id);
        out.push(genre);
      }
    }
    return out;
  }

  /** 区域国家码折叠成展示名：整组命中折叠成预设组名（如「日韩」） */
  regionLabels(regions: string[]): string[] {
    const parts: string[] = [];
    let rest: string[] = regions.slice();
    for (const preset of this.regionPresets) {
      let all: boolean = true;
      for (const code of preset.countries) {
        if (rest.indexOf(code) < 0) {
          all = false;
        }
      }
      if (all) {
        parts.push(preset.label);
        rest = rest.filter((code: string): boolean => preset.countries.indexOf(code) < 0);
      }
    }
    for (const code of rest) {
      const name: string | undefined = this.countryNames[code];
      parts.push(name === undefined ? code : name);
    }
    return parts;
  }

  /** 国家列表：预设组顺序在前（大陆、港台、日韩…），其余按中文名排序 */
  sortedCountries(): CountryOption[] {
    const ordered: string[] = [];
    for (const preset of this.regionPresets) {
      for (const code of preset.countries) {
        if (this.countryNames[code] !== undefined && ordered.indexOf(code) < 0) {
          ordered.push(code);
        }
      }
    }
    const rest: string[] = Object.keys(this.countryNames)
      .filter((code: string): boolean => ordered.indexOf(code) < 0)
      .sort((a: string, b: string): number => this.nameOf(a).localeCompare(this.nameOf(b)));
    const out: CountryOption[] = [];
    for (const code of ordered.concat(rest)) {
      out.push(new CountryOption(code, this.nameOf(code)));
    }
    return out;
  }

  private nameOf(code: string): string {
    const name: string | undefined = this.countryNames[code];
    return name === undefined ? code : name;
  }
}

function parseGenres(list: JsonList | null): RoutingGenre[] {
  const out: RoutingGenre[] = [];
  if (list === null) {
    return out;
  }
  for (const item of list) {
    const map: JsonMap | null = jsonObjectValue(item);
    if (map === null) {
      continue;
    }
    const id: number | null = rawInt(map, 'id');
    if (id !== null) {
      out.push(new RoutingGenre(id, rawStr(map, 'label') ?? `${id}`));
    }
  }
  return out;
}

/** 收藏范围可选项进程内缓存（静态常量，拉一次即可） */
export class RoutingOptionsCache {
  private static value: LibraryRoutingOptions | null = null;

  static get(): LibraryRoutingOptions | null {
    return RoutingOptionsCache.value;
  }

  static set(options: LibraryRoutingOptions): void {
    RoutingOptionsCache.value = options;
  }
}

/** 集合是否包含某值（供编辑器三态循环等复用） */
export function listToggle(list: string[], value: string): string[] {
  const next: string[] = list.slice();
  const at: number = next.indexOf(value);
  if (at >= 0) {
    next.splice(at, 1);
  } else {
    next.push(value);
  }
  return next;
}

/** 解析数字输入：仅非负整数（空 = null） */
export function parseIntInput(text: string): number | null {
  const trimmed: string = text.trim();
  if (trimmed.length === 0) {
    return null;
  }
  const value: number = Number(trimmed);
  if (Number.isNaN(value) || !Number.isFinite(value) || value < 0 || Math.floor(value) !== value) {
    return null;
  }
  return value;
}

/** 解析逗号/空格分隔的组名 */
export function parseGroupList(text: string): string[] {
  const out: string[] = [];
  const parts: string[] = text.split(/[,，、\s]+/);
  for (const part of parts) {
    if (part.length > 0) {
      out.push(part);
    }
  }
  return out;
}
