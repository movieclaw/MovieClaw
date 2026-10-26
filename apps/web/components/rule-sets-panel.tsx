"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { appTranslator, type AppMessageKey } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";
import { ruleSetLabel } from "@/lib/rule-set-label";


import { useConfirm, useToast } from "@/components/feedback";
import { ErrorBanner } from "@/components/cloud-push-ui";
import { PlusIcon } from "@/components/icons";
import {
  genreOptionsFor,
  regionLabels,
  ScopeEditor,
  useRoutingOptions,
} from "@/components/library-form-dialog";
import { Modal } from "@/components/modal";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsEmpty,
  SettingsMoreMenu,
  SettingsSection,
} from "@/components/settings-ui";
import type { RoutingOptions } from "@/lib/api/libraries";
import {
  createRuleSet,
  deleteRuleSet,
  listRuleSets,
  setDefaultRuleSet,
  updateRuleSet,
  type RuleSet,
  type RuleSetSpec,
  type ScopeRule,
} from "@/lib/api/subscriptions";
import { PLATFORM_OPTIONS, platformLabel } from "@/lib/platforms";
import {
  CODEC_FAMILIES,
  DEFAULT_LADDER,
  ladderOptions,
  mediaSourceOptions,
  mediaSourceLabel,
  upgradeLadderPreview,
  type UpgradeLadderPreview,
} from "@/lib/upgrade-ladder";

/**
 * 规则组管理（设置 → 订阅规则 → 规则组）：Web 端唯一的规则组配置入口。
 *
 * 设计原则：
 * - **表单化，不让用户手写 JSON**——spec 的每个维度铺成对应控件；
 * - **列表顺序即偏好**：分辨率按点击顺序入列（与后端评分语义一致），
 *   选中的芯片上标序号，先选的优先；
 * - **摘要芯片**：清单里把 spec 翻译成人话（"2160p > 1080p · 仅免费"），
 *   看一眼就知道每个组在过滤什么；
 * - **复制微调**：订阅不做 per-订阅 override，"想微调就复制一个规则组"是
 *   既定产品哲学——复制按钮预填原组条件，改名保存即成新组；
 * - **删除保护前置**：默认组与被订阅引用的组直接禁用删除按钮并说明原因，
 *   不让用户点了再吃后端 409。
 *
 * - **适用范围自动选组**（docs/design/rule-set-scope.md）：每个组可声明
 *   「适用于什么作品」（电影/剧集、区域、类型），新订阅按它自动预选；多组命中
 *   时条件多者优先，都不命中用「默认」组。只写电影或剧集 = 该类型的默认组。
 *
 * specSummary 与 RuleSetEditorDialog 导出复用：订阅弹窗（选组时看清内容、
 * 快捷新建）与订阅详情页（换组）共用同一套摘要与编辑器。
 */

/** 编辑器打开参数：ruleSet 有值=编辑；null=新建，template 提供预填（复制场景）。 */
interface EditorTarget {
  ruleSet: RuleSet | null;
  template: { name: string; spec: RuleSetSpec } | null;
}

export function RuleSetsPanel({ onPreview }: { onPreview: () => void }) {
  const locale = useLocale();
  const t = useTranslations();
  const confirm = useConfirm();
  const toast = useToast();
  const [ruleSets, setRuleSets] = useState<RuleSet[] | null>(null);
  const [editing, setEditing] = useState<EditorTarget | null>(null);
  const [error, setError] = useMessageState();
  const routingOptions = useRoutingOptions();

  const reload = useCallback(() => {
    void listRuleSets()
      .then((rows) => {
        setRuleSets(rows);
        setError(null);
      })
      .catch(() => setRuleSets([]));
  }, [setError]);

  useEffect(reload, [reload]);

  const makeDefault = async (rs: RuleSet) => {
    try {
      await setDefaultRuleSet(rs.id);
      toast.success(t("subscription.rules.defaultSaved", { name: ruleSetLabel(rs, locale) }));
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.rules.defaultFailed" });
    }
  };

  const remove = async (rs: RuleSet) => {
    if (
      !(await confirm({
        title: t("subscription.rules.deleteTitle", { name: ruleSetLabel(rs, locale) }),
        confirmLabel: t("common.delete"),
        tone: "danger",
      }))
    ) {
      return;
    }
    try {
      await deleteRuleSet(rs.id);
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.rules.deleteFailed" });
    }
  };

  return (
    <SettingsSection
      title={t("subscription.rules.title")}
      description={t("subscription.rules.description")}
      footnote={t("subscription.rules.footnote")}
      action={
        <div className="flex flex-wrap gap-2">
          <button type="button" onClick={onPreview} className={SETTINGS_BUTTON_CLASS}>{t("subscription.rules.preview")}</button>
          <button
            type="button"
            onClick={() => setEditing({ ruleSet: null, template: null })}
            className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1 pl-3`}
          >
            <PlusIcon className="size-4" />
            {t("subscription.rules.create")}
          </button>
        </div>
      }
    >
      {error && (
        <div className="mb-3">
          <ErrorBanner>{error}</ErrorBanner>
        </div>
      )}

      {ruleSets === null ? (
        <p className="css-glass !rounded-xl px-4 py-4 text-ui text-[var(--text-muted)]">
          {t("common.loading")}
        </p>
      ) : ruleSets.length === 0 ? (
        <SettingsEmpty title={t("subscription.rules.empty")} description={t("subscription.rules.emptyHint")} />
      ) : (
        <div
          role="list"
          aria-label={t("subscription.rules.listLabel")}
          className="css-glass divide-y divide-[var(--line)] overflow-hidden !rounded-xl"
        >
          {ruleSets.map((rs) => (
            <RuleSetRow
              key={rs.id}
              ruleSet={rs}
              scope={scopeSummary(rs.match_rules, routingOptions, locale)}
              onEdit={() => setEditing({ ruleSet: rs, template: null })}
              onCopy={() =>
                setEditing({
                  ruleSet: null,
                  template: { name: t("subscription.rules.copyName", { name: ruleSetLabel(rs, locale) }), spec: rs.spec },
                })
              }
              onSetDefault={() => void makeDefault(rs)}
              onDelete={() => void remove(rs)}
            />
          ))}
        </div>
      )}

      <details className="mt-4 text-sub text-[var(--text-muted)]">
        <summary className="cursor-pointer py-2">{t("subscription.rules.helpTitle")}</summary>
        <p className="mt-1 leading-relaxed">{t("subscription.rules.help")}</p>
      </details>

      {editing !== null && (
        <RuleSetEditorDialog
          ruleSet={editing.ruleSet}
          template={editing.template ?? undefined}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            reload();
          }}
        />
      )}
    </SettingsSection>
  );
}

/** 组名旁的小标签（与媒体库管理行的「默认」标同一套样式）。 */
const BADGE =
  "inline-flex shrink-0 items-center rounded-full border border-white/[0.14] bg-white/[0.08] px-1.5 py-px text-micro font-semibold text-white/75";

/**
 * 规则组清单的一行：与媒体库管理行（library-manage-row.tsx）同一套版式——
 * 桌面与手机共用一个结构，不靠断点切两套布局。
 *
 * 此前一行里横排四个按钮，手机上按钮吃掉了大半宽度，组名被挤没、「适用」徽标
 * 截成一个字、摘要芯片竖着折成一列。现在：
 * - 第一行只放组名（点它即编辑）与「默认」标，右侧一个 ··· 菜单收纳全部操作；
 * - 第二行小字：适用范围 · 使用中的订阅数——范围改成小字而非徽标，长了就换行，
 *   不再截断；
 * - 第三行摘要芯片占满整行宽度自由换行。
 * 不能删除的原因直接写在菜单项里（禁用项不可悬停，title 在手机上也看不到）。
 */
function RuleSetRow({
  ruleSet: rs,
  scope,
  onEdit,
  onCopy,
  onSetDefault,
  onDelete,
}: {
  ruleSet: RuleSet;
  /** 适用范围一句话摘要；null = 未声明 */
  scope: string | null;
  onEdit: () => void;
  onCopy: () => void;
  onSetDefault: () => void;
  onDelete: () => void;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const chips = specSummary(rs.spec, {}, locale);
  const deleteBlock = rs.is_default
    ? t("subscription.rules.defaultProtected")
    : rs.reference_count > 0
      ? t("subscription.rules.inUse", { count: rs.reference_count })
      : null;

  return (
    <div role="listitem" className="grid grid-cols-[minmax(0,1fr)_32px] gap-x-3 px-4 py-3">
      <div className="min-w-0">
        <div className="flex min-w-0 items-center gap-2">
          <button
            type="button"
            onClick={onEdit}
            className="truncate text-left text-ui font-semibold text-white hover:underline"
          >
            {ruleSetLabel(rs, locale)}
          </button>
          {rs.is_default && <span className={BADGE}>{t("subscription.rules.defaultBadge")}</span>}
        </div>
        <p className="mt-0.5 text-caption leading-5 text-[var(--text-faint)]">
          <span title={t("subscription.rules.scopeTooltip")}>
            {scope ? (
              <>
                {t.rich("subscription.rules.applies", { value: scope, scope: (chunks) => <span className="text-[var(--text-muted)]">{chunks}</span> })}
              </>
            ) : rs.is_default ? (
              t("subscription.rules.fallbackScope")
            ) : (
              t("subscription.rules.manualScope")
            )}
          </span>
          {rs.reference_count > 0 && (
            <span className="tnum">{t("subscription.rules.usedBy", { count: rs.reference_count })}</span>
          )}
        </p>
      </div>

      <div className="flex justify-end">
        <SettingsMoreMenu
          label={t("subscription.rules.actions", { name: ruleSetLabel(rs, locale) })}
          items={[
            { label: t("subscription.rules.editAction"), onSelect: onEdit },
            { label: t("subscription.rules.copy"), onSelect: onCopy },
            {
              label: rs.is_default ? t("subscription.rules.alreadyDefault") : t("subscription.rules.makeDefault"),
              onSelect: onSetDefault,
              disabled: rs.is_default,
            },
            {
              label: t("common.delete"),
              onSelect: onDelete,
              disabled: deleteBlock !== null,
              danger: true,
              hint: deleteBlock ?? undefined,
            },
          ]}
        />
      </div>

      {/* 摘要芯片跨满整行（含菜单列下方），手机上也能横向铺开 */}
      <div className="col-span-2 mt-2 flex flex-wrap gap-1.5">
        {chips.length === 0 ? (
          <span className="text-caption text-[var(--text-faint)]">
            {t("subscription.rules.unrestricted")}
          </span>
        ) : (
          chips.map((chip) => (
            <span
              key={chip}
              className="rounded-md bg-white/[0.07] px-1.5 py-0.5 text-caption text-white/75"
            >
              {chip}
            </span>
          ))
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// 适用范围：条件 ↔ 表单状态 ↔ 一句话摘要
// ---------------------------------------------------------------------------

type ScopeKind = "movie" | "tv" | null;

/** 适用范围条件 → 表单状态（kind 为 null = 不限电影/剧集）。 */
function parseScope(rules: ScopeRule[]): { kind: ScopeKind; regions: string[]; genres: number[] } {
  const kinds = rules.find((r) => r.field === "kind")?.values ?? [];
  return {
    kind: kinds.length === 1 && (kinds[0] === "movie" || kinds[0] === "tv") ? kinds[0] : null,
    regions: (rules.find((r) => r.field === "origin_countries")?.values ?? []).filter(
      (v): v is string => typeof v === "string",
    ),
    genres: (rules.find((r) => r.field === "genres")?.values ?? []).filter(
      (v): v is number => typeof v === "number",
    ),
  };
}

/** 表单状态 → 适用范围条件（空维度不生成条件；全空 = 不声明）。 */
function buildScope(kind: ScopeKind, regions: string[], genres: number[]): ScopeRule[] {
  const rules: ScopeRule[] = [];
  if (kind) rules.push({ field: "kind", op: "any_of", values: [kind] });
  if (regions.length) rules.push({ field: "origin_countries", op: "any_of", values: regions });
  if (genres.length) rules.push({ field: "genres", op: "any_of", values: genres });
  return rules;
}

/** 适用范围的一句话摘要（如「剧集 · 日韩 · 动画」）；未声明返回 null。 */
function scopeSummary(rules: ScopeRule[], options: RoutingOptions | null, locale: AppLocale): string | null {
  const t = appTranslator(locale);
  if (!rules.length) return null;
  const { kind, regions, genres } = parseScope(rules);
  const parts: string[] = [];
  if (kind) parts.push(kind === "movie" ? t("media.kind.movie") : t("media.kind.tv"));
  if (regions.length) {
    parts.push(options ? regionLabels(regions, options).join("/") : t("subscription.rules.regions", { count: regions.length }));
  }
  if (genres.length) {
    parts.push(
      options
        ? genreOptionsFor(kind, options)
            .filter((g) => genres.includes(g.id))
            .map((g) => g.label)
            .join("/")
        : t("subscription.rules.genres", { count: genres.length }),
    );
  }
  return parts.join(" · ");
}

// ---------------------------------------------------------------------------
// spec → 摘要芯片
// ---------------------------------------------------------------------------

/** 分辨率可选项（词表归一值里的常用档；其余档位罕见，需要时再扩）。 */
const RESOLUTION_OPTIONS = ["2160p", "1080p", "720p"];

// 语言值与 movieclaw_enrich.lang_decl 的 BCP 47 输出对齐；任一命中即过。
// "zh" 前缀匹配简/繁/未标简繁的一切中文声明——日常"要中文字幕"选它就够
function subLangOptions(locale: AppLocale) {
  const t = appTranslator(locale);
  const options: [string, string][] = [
    ["zh", t("subscription.rules.subtitleChinese")],
    ["zh-Hans", t("subscription.rules.subtitleSimplified")],
    ["zh-Hant", t("subscription.rules.subtitleTraditional")],
    ["en", t("subscription.rules.subtitleEnglish")],
  ];
  return options;
}
function audioLangOptions(locale: AppLocale) {
  const t = appTranslator(locale);
  const options: [string, string][] = [
    ["cmn", t("subscription.rules.audioMandarin")],
    ["yue", t("subscription.rules.audioCantonese")],
    ["ja", t("subscription.rules.audioJapanese")],
    ["en", t("subscription.rules.audioEnglish")],
  ];
  return options;
}

/**
 * 洗版目标片源档的三个选项就是全部预设（docs/design/quality-upgrade.md §8.2）
 * ——没有需要照抄的社区配置。目标分辨率缺省取分辨率偏好的第一位。
 */
function upgradeOptions(locale: AppLocale) {
  const t = appTranslator(locale);
  const options: [
    NonNullable<RuleSetSpec["upgrade_source"]> & string,
    string,
  ][] = [
    ["web-dl", t("subscription.rules.upgradeWeb")],
    ["blu-ray", t("subscription.rules.upgradeBluray")],
    ["remux", t("subscription.rules.upgradeRemux")],
  ];
  return options;
}

/**
 * HDR 值域（顺序即编辑器里的芯片顺序）。"SDR" 是哨兵值 = 资源未标注任何
 * HDR 格式——命名惯例里 HDR 属"缺席即否定"的强标记。
 */
const HDR_OPTIONS = ["DV", "HDR10+", "HDR10", "HLG", "SDR"];

/**
 * 只能「排除」的 HDR 项：它不是标题里的记号，而是后端按命名约定与站点标记得出的判定
 * （movieclaw_matcher.formats）。「DV P5」= 只标了 DV、没有 HDR10 兼容层的杜比视界
 * （Profile 5），服务器转码会偏绿偏紫；与「DV」（整类）不同，带 HDR10 兼容层的 P8/P7 不受影响。
 * 「只要 P5」没有意义，所以它不进三态循环，只在「不限 ↔ 排除」之间切。
 */
const HDR_BLOCK_ONLY = ["DV P5"];

/**
 * 旧三态字段 → (白名单, 黑名单)。与后端 models._hdr_from_legacy 同一张表，
 * 属兼容层：存量规则组保存过一次后就带上新键了，旧键退休时这段一起删。
 */
function hdrFromLegacy(spec: RuleSetSpec): { levels: string[]; block: string[] } {
  if (spec.hdr_levels?.length || spec.hdr_block?.length) {
    return { levels: spec.hdr_levels ?? [], block: spec.hdr_block ?? [] };
  }
  const family = HDR_OPTIONS.filter((v) => v !== "SDR");
  if (spec.hdr === "forbid") return { levels: ["SDR"], block: [] };
  if (spec.dv === "require") return { levels: ["DV"], block: [] };
  if (spec.hdr === "require") {
    return spec.dv === "forbid"
      ? { levels: family.filter((v) => v !== "DV"), block: ["DV"] }
      : { levels: family, block: [] };
  }
  if (spec.dv === "forbid") return { levels: [], block: ["DV"] };
  return { levels: [], block: [] };
}

/**
 * HDR 白名单 → 摘要文案。整族与纯 SDR 这两种最常见的配置（也是旧 hdr 三态
 * 换算出来的形态）说人话，避免清单里出现 "HDR DV/HDR10+/HDR10/HLG" 这种
 * 又长又没信息量的芯片。
 */
function hdrChipText(levels: string[], locale: AppLocale): string {
  const t = appTranslator(locale);
  const family = HDR_OPTIONS.filter((v) => v !== "SDR");
  if (levels.length === family.length && family.every((v) => levels.includes(v))) {
    return t("subscription.rules.requireHdr");
  }
  if (levels.length === 1 && levels[0] === "SDR") return t("subscription.rules.excludeHdr");
  return `HDR ${levels.join("/")}`;
}

const sameLadder = (a: string[], b: string[]) =>
  a.length === b.length && a.every((v, i) => v === b[i]);

/** 洗版目标的人话标签（摘要芯片 / 订阅详情页规则组 fact 复用）。 */
export function upgradeTargetLabel(spec: RuleSetSpec, locale: AppLocale = "zh-Hans"): string | null {
  if (!spec.upgrade_source) return null;
  const resolution = spec.cutoff_resolution || spec.resolutions?.[0] || "1080p";
  const parts = [
    `${resolution} ${mediaSourceLabel(spec.upgrade_source, locale)}`,
  ];
  // 与后端 decision.upgrade_target_label 同一口径：只渲染"进了阶梯且配了偏好"
  // 的维度（偏好为空的位后端会自动跳过）
  const ladder = spec.upgrade_ladder ?? DEFAULT_LADDER;
  if (ladder.includes("hdr") && spec.hdr_levels?.length) {
    parts.push(spec.hdr_levels[0]);
  }
  if (ladder.includes("video_codec") && spec.video_codecs?.length) {
    parts.push(spec.video_codecs[0]);
  }
  if (ladder.includes("platform") && spec.platforms?.length) {
    parts.push(platformLabel(spec.platforms[0], locale));
  }
  return parts.join(" · ");
}

/** spec → 人话芯片列表（清单摘要 / 订阅弹窗与详情页复用；空数组=全不限）。
 *  `withoutUpgrade`：编辑器底部把洗版单独渲染成阶梯，那里不再要这枚芯片。 */
export function specSummary(
  spec: RuleSetSpec,
  { withoutUpgrade = false }: { withoutUpgrade?: boolean } = {},
  locale: AppLocale = "zh-Hans",
): string[] {
  const t = appTranslator(locale);
  const chips: string[] = [];
  if (spec.resolutions?.length) chips.push(spec.resolutions.join(" > "));
  if (spec.media_sources?.length) {
    chips.push(spec.media_sources.map(value => mediaSourceLabel(value, locale)).join(" > "));
  }
  const upgradeTarget = withoutUpgrade ? null : upgradeTargetLabel(spec, locale);
  if (upgradeTarget) {
    chips.push(t("subscription.rules.upgradeChip", { target: upgradeTarget, keepOld: spec.upgrade_keep_old ? "yes" : "no" }));
  }
  if (spec.video_codecs?.length) {
    const rest = new Set(spec.video_codecs);
    const labels: string[] = [];
    for (const family of CODEC_FAMILIES) {
      if (family.values.some((v) => rest.has(v))) {
        labels.push(family.label);
        family.values.forEach((v) => rest.delete(v));
      }
    }
    labels.push(...rest);
    chips.push(labels.join("/"));
  }
  if (spec.platforms?.length) {
    chips.push(t("subscription.rules.platformChip", { values: spec.platforms.map(value => platformLabel(value, locale)).join("/") }));
  }
  if (spec.platforms_block?.length) {
    chips.push(t("subscription.rules.blockedPlatforms", { values: spec.platforms_block.map(value => platformLabel(value, locale)).join("/") }));
  }
  const { levels: hdrLevels, block: hdrBlock } = hdrFromLegacy(spec);
  if (hdrLevels.length) chips.push(hdrChipText(hdrLevels, locale));
  if (hdrBlock.length) chips.push(t("subscription.rules.excludeValues", { values: hdrBlock.join("/") }));
  if (spec.subtitle_languages_require?.length)
    chips.push(
      t("subscription.rules.subtitleChip", { values: spec.subtitle_languages_require.map((v) => subLangOptions(locale).find(([code]) => code === v)?.[1] ?? v).join("/") }),
    );
  if (spec.audio_languages_require?.length)
    chips.push(
      t("subscription.rules.audioChip", { values: spec.audio_languages_require.map((v) => audioLangOptions(locale).find(([code]) => code === v)?.[1] ?? v).join("/") }),
    );
  if (spec.free_only) chips.push(t("subscription.rules.freeOnly"));
  if (spec.min_seeders != null) chips.push(t("subscription.rules.seedersChip", { count: spec.min_seeders }));
  if (spec.size_min_mb != null || spec.size_max_mb != null) {
    const min = spec.size_min_mb;
    const max = spec.size_max_mb;
    chips.push(min != null && max != null ? t("subscription.rules.episodeRange", { min, max }) : min != null ? t("subscription.rules.episodeMin", { min }) : t("subscription.rules.episodeMax", { max: max! }));
  }
  if (spec.exclude_hr)
    chips.push(spec.hr_unknown_policy === "strict" ? t("subscription.rules.excludeHrStrict") : t("subscription.rules.excludeHr"));
  if (spec.release_groups_allow?.length)
    chips.push(t("subscription.rules.allowedGroupCount", { count: spec.release_groups_allow.length }));
  if (spec.release_groups_block?.length)
    chips.push(t("subscription.rules.blockedGroupCount", { count: spec.release_groups_block.length }));
  return chips;
}

// ---------------------------------------------------------------------------
// 编辑器弹窗
// ---------------------------------------------------------------------------

export function RuleSetEditorDialog({
  ruleSet,
  template,
  raised = false,
  onClose,
  onSaved,
}: {
  /** null = 新建 */
  ruleSet: RuleSet | null;
  /** 新建时的预填内容（复制场景）；编辑时忽略 */
  template?: { name: string; spec: RuleSetSpec };
  /** 叠在其他弹窗之上时置 true（如订阅弹窗里快捷新建） */
  raised?: boolean;
  onClose: () => void;
  /** 保存成功回调，参数是后端返回的最新规则组（快捷新建场景要选中它） */
  onSaved: (saved: RuleSet) => void;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const spec = useMemo<RuleSetSpec>(
    () => ruleSet?.spec ?? template?.spec ?? {},
    [ruleSet, template],
  );

  const [name, setName] = useState(ruleSet?.name ?? template?.name ?? "");
  // 适用范围（复制场景不带过去：两个组范围一模一样时只有更早的那个会被选中）
  const initialScope = useMemo(() => parseScope(ruleSet?.match_rules ?? []), [ruleSet]);
  const [scopeKind, setScopeKind] = useState<ScopeKind>(initialScope.kind);
  const [scopeRegions, setScopeRegions] = useState<string[]>(initialScope.regions);
  const [scopeGenres, setScopeGenres] = useState<number[]>(initialScope.genres);
  const routingOptions = useRoutingOptions();
  const [resolutions, setResolutions] = useState<string[]>(spec.resolutions ?? []);
  const [codecFamilies, setCodecFamilies] = useState<Set<string>>(
    () =>
      new Set(
        CODEC_FAMILIES.filter((f) =>
          f.values.some((v) => (spec.video_codecs ?? []).includes(v)),
        ).map((f) => f.label),
      ),
  );
  // 平台白/黑名单：界面只维护"常驻选项"部分，其余值走 platformExtras 透传
  const [platformsAllow, setPlatformsAllow] = useState<string[]>(() =>
    (spec.platforms ?? []).filter((v) => PLATFORM_OPTIONS.includes(v)),
  );
  const [platformsBlock, setPlatformsBlock] = useState<string[]>(() =>
    (spec.platforms_block ?? []).filter((v) => PLATFORM_OPTIONS.includes(v)),
  );
  const [mediaSources, setMediaSources] = useState<string[]>(spec.media_sources ?? []);
  const [upgradeLadder, setUpgradeLadder] = useState<string[]>(
    () => spec.upgrade_ladder ?? [...DEFAULT_LADDER],
  );
  const [hdrLevels, setHdrLevels] = useState<string[]>(() => hdrFromLegacy(spec).levels);
  const [hdrBlock, setHdrBlock] = useState<string[]>(() => hdrFromLegacy(spec).block);
  const [subLangs, setSubLangs] = useState<string[]>(
    spec.subtitle_languages_require ?? [],
  );
  const [audioLangs, setAudioLangs] = useState<string[]>(
    spec.audio_languages_require ?? [],
  );
  const [freeOnly, setFreeOnly] = useState(spec.free_only ?? false);
  const [excludeHr, setExcludeHr] = useState(spec.exclude_hr ?? false);
  const [hrStrict, setHrStrict] = useState(spec.hr_unknown_policy === "strict");
  const [minSeeders, setMinSeeders] = useState(spec.min_seeders?.toString() ?? "");
  const [sizeMin, setSizeMin] = useState(spec.size_min_mb?.toString() ?? "");
  const [sizeMax, setSizeMax] = useState(spec.size_max_mb?.toString() ?? "");
  const [groupsAllow, setGroupsAllow] = useState((spec.release_groups_allow ?? []).join(", "));
  const [groupsBlock, setGroupsBlock] = useState((spec.release_groups_block ?? []).join(", "));
  // 洗版目标：""=不洗版（唯一的洗版配置点，docs/design/quality-upgrade.md §8.2）
  const [upgradeSource, setUpgradeSource] = useState<string>(spec.upgrade_source ?? "");
  const [upgradeKeepOld, setUpgradeKeepOld] = useState<boolean>(spec.upgrade_keep_old ?? false);
  const [cutoffResolution, setCutoffResolution] = useState<string>(
    spec.cutoff_resolution ?? "",
  );
  // 洗版优先级默认收起：只想"洗到 Remux"的人不该被维度排序打断，
  // 但也不能藏起来——折叠头直接显示当前顺序，需要时一点就开
  const [ladderOpen, setLadderOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useMessageState();

  // 编码族之外的原有值（手工经 API 写入的自定义编码）：编辑时不丢
  const codecExtras = useMemo(
    () =>
      (spec.video_codecs ?? []).filter(
        (v) => !CODEC_FAMILIES.some((f) => f.values.includes(v)),
      ),
    [spec],
  );

  // 常驻选项之外的既有平台值（经 API 配置的小众平台）：编辑时不丢
  const platformExtras = useMemo(
    () => ({
      allow: (spec.platforms ?? []).filter((v) => !PLATFORM_OPTIONS.includes(v)),
      block: (spec.platforms_block ?? []).filter((v) => !PLATFORM_OPTIONS.includes(v)),
    }),
    [spec],
  );

  const platformState = (value: string): "off" | "include" | "exclude" =>
    platformsAllow.includes(value)
      ? "include"
      : platformsBlock.includes(value)
        ? "exclude"
        : "off";

  /** 三态循环：不限 → 只要 → 排除 → 不限。同一平台因此不可能同时进白/黑名单
   *  （后端读取路径有意保持宽容、不对矛盾配置报错，矛盾在这里从源头消除）。 */
  const cyclePlatform = (value: string) => {
    const state = platformState(value);
    if (state === "off") {
      setPlatformsAllow((prev) => [...prev, value]);
    } else if (state === "include") {
      setPlatformsAllow((prev) => prev.filter((v) => v !== value));
      setPlatformsBlock((prev) => [...prev, value]);
    } else {
      setPlatformsBlock((prev) => prev.filter((v) => v !== value));
    }
  };

  const hdrState = (value: string): "off" | "include" | "exclude" =>
    hdrLevels.includes(value) ? "include" : hdrBlock.includes(value) ? "exclude" : "off";

  const cycleHdr = (value: string) => {
    const state = hdrState(value);
    if (state === "off") {
      setHdrLevels((prev) => [...prev, value]);
    } else if (state === "include") {
      setHdrLevels((prev) => prev.filter((v) => v !== value));
      setHdrBlock((prev) => [...prev, value]);
    } else {
      setHdrBlock((prev) => prev.filter((v) => v !== value));
    }
  };

  const toggleHdrBlock = (value: string) =>
    setHdrBlock((prev) => (prev.includes(value) ? prev.filter((v) => v !== value) : [...prev, value]));

  /** 阶梯维度：交互与分辨率偏好完全一致——点击依次入列，序号即位次。
   *  最后一维不允许移除：空阶梯没有任何一位可比，后端会回落到缺省二元组，
   *  界面上却显示"一个都没选"——不让用户进入这种口径不一致的状态。 */
  const toggleLadderDim = (value: string) =>
    setUpgradeLadder((prev) => {
      if (!prev.includes(value)) return [...prev, value];
      return prev.length > 1 ? prev.filter((v) => v !== value) : prev;
    });

  const labelOf = (options: readonly (readonly [string, string])[], values: string[]) =>
    values.map((v) => options.find(([code]) => code === v)?.[1] ?? v).join("/");

  // 折叠段的实时摘要：不展开也知道里面配了什么，这是长表单能收起来的前提
  const qualitySummary =
    [
      codecFamilies.size ? [...codecFamilies].join("/") : "",
      platformsAllow.length ? platformsAllow.map(value => platformLabel(value, locale)).join("/") : "",
      platformsBlock.length ? t("subscription.rules.excludeValues", { values: platformsBlock.map(value => platformLabel(value, locale)).join("/") }) : "",
      hdrLevels.length ? hdrChipText(hdrLevels, locale) : "",
      hdrBlock.length ? t("subscription.rules.excludeValues", { values: hdrBlock.join("/") }) : "",
      groupsAllow.trim() ? t("subscription.rules.groupSummary", { values: groupsAllow.trim() }) : "",
      groupsBlock.trim() ? t("subscription.rules.blockedGroupsSummary", { values: groupsBlock.trim() }) : "",
    ]
      .filter(Boolean)
      .join(" · ") || t("subscription.rules.unset");

  const limitSummary =
    [
      subLangs.length ? t("subscription.rules.subtitleSummary", { values: labelOf(subLangOptions(locale), subLangs) }) : "",
      audioLangs.length ? t("subscription.rules.audioSummary", { values: labelOf(audioLangOptions(locale), audioLangs) }) : "",
      freeOnly ? t("subscription.rules.freeOnly") : "",
      excludeHr ? t("subscription.rules.excludeHr") : "",
      minSeeders.trim() ? t("subscription.rules.seedersChip", { count: Number(minSeeders) }) : "",
      sizeMin.trim() || sizeMax.trim()
        ? sizeMax.trim() ? t("subscription.rules.sizeSummary", { min: Number(sizeMin) || 0, max: Number(sizeMax) }) : t("subscription.rules.sizeUnbounded", { min: Number(sizeMin) || 0 })
        : "",
    ]
      .filter(Boolean)
      .join(" · ") || t("subscription.rules.unset");

  /** 某维度是否还没配偏好——后端会把这种位直接跳过。 */
  const ladderUnconfigured = (dim: string) =>
    (dim === "hdr" && !hdrLevels.length) ||
    (dim === "video_codec" && !codecFamilies.size && !codecExtras.length) ||
    (dim === "platform" && !platformsAllow.length && !platformExtras.allow.length);

  // 名称维度上浮的告警条件（§14.4）：平台识别率最低，排在前面会截断整条比较。
  // 按**生效**维度判断——被跳过的维度不占位，否则"平台后面跟着一个未配置的
  // 编码位"会误报
  const effectiveLadder = upgradeLadder.filter((dim) => !ladderUnconfigured(dim));
  const ladderText = effectiveLadder
    .map((dim) => ladderOptions(locale).find((o) => o.value === dim)?.label ?? dim)
    .join(" › ");
  const platformIndex = effectiveLadder.indexOf("platform");
  const platformNotLast =
    platformIndex >= 0 && platformIndex < effectiveLadder.length - 1;

  const toggleResolution = (value: string) =>
    setResolutions((prev) =>
      prev.includes(value) ? prev.filter((r) => r !== value) : [...prev, value],
    );

  /** 片源档：交互与分辨率偏好完全一致（点击依次入列，序号即位次）。
   *  收窄白名单时若洗版终点被排除在外，直接把终点清掉——不让用户进入
   *  "保存时才报错"的状态（与平台三态那处"矛盾在源头消除"同一取向）。 */
  const toggleMediaSource = (value: string) =>
    setMediaSources((prev) => {
      const next = prev.includes(value)
        ? prev.filter((v) => v !== value)
        : [...prev, value];
      if (upgradeSource && next.length && !next.includes(upgradeSource)) {
        setUpgradeSource("");
      }
      return next;
    });

  const toggleCodecFamily = (label: string) =>
    setCodecFamilies((prev) => {
      const next = new Set(prev);
      if (next.has(label)) next.delete(label);
      else next.add(label);
      return next;
    });

  /**
   * 表单状态 → spec 的**唯一**构造点：保存与底部"这条规则会这样筛选"共用它，
   * 保证用户看到的摘要就是将要存下去的东西。校验错误随返回值给出——memo 里
   * 不能 setState，也正好把校验变成纯函数。
   */
  const draft = useMemo<{ spec: RuleSetSpec; error: AppMessageKey | null }>(() => {
    const parseInt_ = (text: string): number | undefined => {
      const n = Number.parseInt(text.trim(), 10);
      return Number.isFinite(n) && n >= 0 ? n : undefined;
    };
    const parseGroups = (text: string): string[] =>
      text
        .split(/[,，、\s]+/)
        .map((g) => g.trim())
        .filter(Boolean);

    const next: RuleSetSpec = {};
    if (resolutions.length) next.resolutions = resolutions;
    if (mediaSources.length) next.media_sources = mediaSources;
    const codecs = [
      ...CODEC_FAMILIES.filter((f) => codecFamilies.has(f.label)).flatMap((f) => f.values),
      ...codecExtras,
    ];
    if (codecs.length) next.video_codecs = codecs;
    // 与缺省一致就不写进 spec——spec 只记录用户真的改过的东西
    if (upgradeSource !== "" && !sameLadder(upgradeLadder, DEFAULT_LADDER)) {
      next.upgrade_ladder = upgradeLadder;
    }
    const allowPlatforms = [...platformsAllow, ...platformExtras.allow];
    if (allowPlatforms.length) next.platforms = allowPlatforms;
    const blockPlatforms = [...platformsBlock, ...platformExtras.block];
    if (blockPlatforms.length) next.platforms_block = blockPlatforms;
    // 只写新键：旧的 hdr/dv 由后端在校验层反向回填（回退兼容），前端不掺和
    if (hdrLevels.length) next.hdr_levels = hdrLevels;
    if (hdrBlock.length) next.hdr_block = hdrBlock;
    if (subLangs.length) next.subtitle_languages_require = subLangs;
    if (audioLangs.length) next.audio_languages_require = audioLangs;
    if (freeOnly) next.free_only = true;
    if (excludeHr) {
      next.exclude_hr = true;
      if (hrStrict) next.hr_unknown_policy = "strict";
    }
    const seeders = parseInt_(minSeeders);
    if (seeders !== undefined && seeders > 0) next.min_seeders = seeders;
    const min = parseInt_(sizeMin);
    const max = parseInt_(sizeMax);
    if (min !== undefined && min > 0) next.size_min_mb = min;
    if (max !== undefined && max > 0) next.size_max_mb = max;
    if (min !== undefined && max !== undefined && min > 0 && max > 0 && min > max) {
      return { spec: next, error: "subscription.rules.sizeInvalid" };
    }
    const allow = parseGroups(groupsAllow);
    const block = parseGroups(groupsBlock);
    if (allow.length) next.release_groups_allow = allow;
    if (block.length) next.release_groups_block = block;
    if (upgradeSource) {
      if (mediaSources.length && !mediaSources.includes(upgradeSource)) {
        return { spec: next, error: "subscription.rules.sourceInvalid" };
      }
      next.upgrade_source = upgradeSource as RuleSetSpec["upgrade_source"];
      // 目标分辨率仅在偏离缺省（分辨率偏好首选）时写入；限定了分辨率时
      // 目标必须落在允许范围内（后端同样校验）
      if (cutoffResolution && cutoffResolution !== (resolutions[0] ?? "")) {
        if (resolutions.length && !resolutions.includes(cutoffResolution)) {
          return { spec: next, error: "subscription.rules.resolutionInvalid" };
        }
        next.cutoff_resolution = cutoffResolution;
      }
      if (upgradeKeepOld) next.upgrade_keep_old = true;
    }
    // API 写入的预留字段（站点白名单）编辑时原样保留，不因 UI 保存而丢失
    if (spec.sites?.length) next.sites = spec.sites;
    return { spec: next, error: null };
  }, [
    resolutions,
    mediaSources,
    codecFamilies,
    codecExtras,
    upgradeSource,
    upgradeLadder,
    platformsAllow,
    platformsBlock,
    platformExtras,
    hdrLevels,
    hdrBlock,
    subLangs,
    audioLangs,
    freeOnly,
    excludeHr,
    hrStrict,
    minSeeders,
    sizeMin,
    sizeMax,
    groupsAllow,
    groupsBlock,
    cutoffResolution,
    upgradeKeepOld,
    spec.sites,
  ]);

  // 底部回执分两段：硬性筛选走芯片，洗版走阶梯（洗版开着时芯片里不再重复目标）
  const ladderPreview = useMemo(
    () => upgradeLadderPreview(draft.spec, id => platformLabel(id, locale), locale),
    [draft.spec, locale],
  );
  const draftChips = useMemo(
    () => specSummary(draft.spec, { withoutUpgrade: ladderPreview !== null }, locale),
    [draft.spec, ladderPreview, locale],
  );

  // 切换过电影/剧集时，另一类型独有的类型 ID 不带进保存结果
  const validScopeGenres =
    routingOptions === null
      ? scopeGenres
      : scopeGenres.filter((id) => genreOptionsFor(scopeKind, routingOptions).some((g) => g.id === id));
  const scopeRules = buildScope(scopeKind, scopeRegions, validScopeGenres);
  const scopeText = scopeSummary(scopeRules, routingOptions, locale) ?? t("subscription.rules.unsetScope");

  const submit = async () => {
    if (draft.error) {
      setError({ key: draft.error });
      return;
    }
    const next = draft.spec;
    setBusy(true);
    setError(null);
    try {
      const saved =
        ruleSet === null
          ? await createRuleSet(name.trim(), next, scopeRules)
          : await updateRuleSet(ruleSet.id, name.trim(), next, scopeRules);
      onSaved(saved);
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.rules.saveFailed" });
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open
      onClose={onClose}
      label={ruleSet ? t("subscription.rules.editTitle", { name: ruleSetLabel(ruleSet, locale) }) : t("subscription.rules.create")}
      width="lg"
      raised={raised}
      panelClassName="max-h-[76dvh]"
    >
      {/* 头部常驻：规则组表单比一屏长得多，标题要一直在 */}
      <div className="border-b border-white/[0.07] px-6 pb-4 pt-6 max-md:px-5">
        <h2 className="text-title font-bold text-white">
          {ruleSet ? t("subscription.rules.edit") : t("subscription.rules.create")}
        </h2>
        <p className="mt-1 text-sub text-[var(--text-muted)]">
          {t("subscription.rules.editorHint")}
        </p>
        {ruleSet !== null && ruleSet.reference_count > 0 && (
          <p className="mt-2 rounded-lg border border-amber-400/25 bg-amber-500/10 px-3.5 py-2.5 text-sub leading-6 text-amber-200">
            {t("subscription.rules.referencesWarning", { count: ruleSet.reference_count })}
          </p>
        )}
      </div>

      <div className="scroll-thin min-h-0 flex-1 overflow-y-auto p-6 max-md:p-5">
        <div className="space-y-5">
          <Field label={t("subscription.rules.name")}>
            <input
              type="text"
              value={ruleSet && name === ruleSet.name ? ruleSetLabel(ruleSet, locale) : name}
              onChange={(e) => setName(ruleSet && e.target.value === ruleSetLabel(ruleSet, locale) ? ruleSet.name : e.target.value)}
              placeholder={t("subscription.rules.namePlaceholder")}
              className={`${SETTINGS_INPUT_CLASS} w-full`}
            />
          </Field>

          {/* 适用范围：订阅时自动选组的依据。放在画质条件之前——"这个组给谁用"
              是建组时的第一个问题；折叠头直接显示当前范围 */}
          <Section title={t("subscription.rules.scope")} summary={scopeText}>
            <p className="-mt-1 text-caption leading-relaxed text-[var(--text-faint)]">
              {t("subscription.rules.scopeHint")}
            </p>
            <Field label={t("subscription.rules.kind")}>
              <div className="flex flex-wrap gap-1.5">
                {(
                  [
                    [null, t("subscription.rules.any")],
                    ["movie", t("media.kind.movie")],
                    ["tv", t("media.kind.tv")],
                  ] as const
                ).map(([value, label]) => (
                  <ToggleChip
                    key={label}
                    active={scopeKind === value}
                    onClick={() => setScopeKind(value)}
                  >
                    {label}
                  </ToggleChip>
                ))}
              </div>
            </Field>
            <ScopeEditor
              kind={scopeKind}
              regions={scopeRegions}
              genres={validScopeGenres}
              onRegions={setScopeRegions}
              onGenres={setScopeGenres}
              options={routingOptions}
            />
          </Section>

          <Field
            label={t("subscription.rules.resolution")}
            hint={t("subscription.rules.resolutionHint")}
          >
            <div className="flex flex-wrap gap-1.5">
              {RESOLUTION_OPTIONS.map((option) => {
                const index = resolutions.indexOf(option);
                return (
                  <ToggleChip
                    key={option}
                    active={index >= 0}
                    onClick={() => toggleResolution(option)}
                  >
                    {index >= 0 && resolutions.length > 1 && (
                      <span className="mr-1.5 inline-flex size-4 items-center justify-center rounded-full bg-white/20 text-micro font-semibold">
                        {index + 1}
                      </span>
                    )}
                    {option}
                  </ToggleChip>
                );
              })}
            </div>
          </Field>

          {/* 片源与分辨率是用户谈论"版本好坏"时实际用的两个主轴（§2.2），也是
              仅有的两个偏好序参与候选选优的维度，因此并排放在最外层；它还必须
              排在洗版之前——洗版终点档只能从这个白名单里挑 */}
          <Field
            label={t("subscription.rules.source")}
            hint={t("subscription.rules.sourceHint")}
          >
            <div className="flex flex-wrap gap-1.5">
              {mediaSourceOptions(locale).map((option) => {
                const index = mediaSources.indexOf(option.value);
                return (
                  <ToggleChip
                    key={option.value}
                    active={index >= 0}
                    onClick={() => toggleMediaSource(option.value)}
                  >
                    {index >= 0 && mediaSources.length > 1 && (
                      <span className="mr-1.5 inline-flex size-4 items-center justify-center rounded-full bg-white/20 text-micro font-semibold">
                        {index + 1}
                      </span>
                    )}
                    {option.label}
                  </ToggleChip>
                );
              })}
            </div>
          </Field>

          <Section title={t("subscription.rules.quality")} summary={qualitySummary}>
          <Field label={t("subscription.rules.codec")} hint={t("subscription.rules.codecHint")}>
            <div className="flex flex-wrap gap-1.5">
              {CODEC_FAMILIES.map((family) => (
                <ToggleChip
                  key={family.label}
                  active={codecFamilies.has(family.label)}
                  onClick={() => toggleCodecFamily(family.label)}
                >
                  {family.label}
                </ToggleChip>
              ))}
              {codecExtras.length > 0 && (
                <span className="self-center text-caption text-[var(--text-faint)]">
                  {t("subscription.rules.customValues", { values: codecExtras.join(locale === "en" ? ", " : "、") })}
                </span>
              )}
            </div>
          </Field>

          <Field
            label={t("subscription.rules.platform")}
            hint={t("subscription.rules.platformHint")}
          >
            <div className="flex flex-wrap gap-1.5">
              {PLATFORM_OPTIONS.map((id) => (
                <TriChip
                  key={id}
                  state={platformState(id)}
                  onClick={() => cyclePlatform(id)}
                >
                  {platformLabel(id, locale)}
                </TriChip>
              ))}
            </div>
            {(platformExtras.allow.length > 0 || platformExtras.block.length > 0) && (
              <p className="mt-1.5 text-caption text-[var(--text-faint)]">
                {t("subscription.rules.customValues", { values: [...platformExtras.allow, ...platformExtras.block].map(value => platformLabel(value, locale)).join(locale === "en" ? ", " : "、") })}
              </p>
            )}
          </Field>

          <Field
            label="HDR"
            hint={t("subscription.rules.hdrHint")}
          >
            <div className="flex flex-wrap gap-1.5">
              {HDR_OPTIONS.map((value) => (
                <TriChip key={value} state={hdrState(value)} onClick={() => cycleHdr(value)}>
                  {value}
                </TriChip>
              ))}
              {HDR_BLOCK_ONLY.map((value) => (
                <TriChip
                  key={value}
                  state={hdrBlock.includes(value) ? "exclude" : "off"}
                  onClick={() => toggleHdrBlock(value)}
                >
                  {value}
                </TriChip>
              ))}
            </div>
          </Field>

          <Field
            label={t("subscription.rules.groupsAllow")}
            hint={t("subscription.rules.groupsAllowHint")}
          >
            <input
              type="text"
              value={groupsAllow}
              onChange={(e) => setGroupsAllow(e.target.value)}
              placeholder={t("subscription.rules.blankAny")}
              className={`${SETTINGS_INPUT_CLASS} w-full`}
            />
          </Field>
          <Field label={t("subscription.rules.groupsBlock")} hint={t("subscription.rules.groupsBlockHint")}>
            <input
              type="text"
              value={groupsBlock}
              onChange={(e) => setGroupsBlock(e.target.value)}
              placeholder={t("subscription.rules.blankDisabled")}
              className={`${SETTINGS_INPUT_CLASS} w-full`}
            />
          </Field>
          </Section>

          <Section title={t("subscription.rules.limits")} summary={limitSummary}>
          <Field
            label={t("subscription.rules.subtitleLanguage")}
            hint={t("subscription.rules.subtitleHint")}
          >
            <div className="flex flex-wrap gap-1.5">
              {subLangOptions(locale).map(([value, label]) => (
                <ToggleChip
                  key={value}
                  active={subLangs.includes(value)}
                  onClick={() =>
                    setSubLangs((prev) =>
                      prev.includes(value)
                        ? prev.filter((v) => v !== value)
                        : [...prev, value],
                    )
                  }
                >
                  {label}
                </ToggleChip>
              ))}
            </div>
          </Field>

          <Field
            label={t("subscription.rules.audioLanguage")}
            hint={t("subscription.rules.audioHint")}
          >
            <div className="flex flex-wrap gap-1.5">
              {audioLangOptions(locale).map(([value, label]) => (
                <ToggleChip
                  key={value}
                  active={audioLangs.includes(value)}
                  onClick={() =>
                    setAudioLangs((prev) =>
                      prev.includes(value)
                        ? prev.filter((v) => v !== value)
                        : [...prev, value],
                    )
                  }
                >
                  {label}
                </ToggleChip>
              ))}
            </div>
          </Field>

          <div className="grid grid-cols-2 gap-3 max-md:grid-cols-1">
            <CheckRow
              label={t("subscription.rules.free")}
              hint={t("subscription.rules.freeHint")}
              checked={freeOnly}
              onChange={setFreeOnly}
            />
            <CheckRow
              label={t("subscription.rules.hr")}
              hint={t("subscription.rules.hrHint")}
              checked={excludeHr}
              onChange={setExcludeHr}
            />
          </div>
          {excludeHr && (
            <div className="-mt-2 rounded-xl bg-white/[0.03] px-4 py-2.5">
              <label className="flex cursor-pointer items-center justify-between">
                <span className="text-sub text-[var(--text-muted)]">
                  {t("subscription.rules.hrStrictHint")}
                </span>
                <input
                  type="checkbox"
                  checked={hrStrict}
                  onChange={(e) => setHrStrict(e.target.checked)}
                  className="size-4 accent-[var(--accent-2)]"
                />
              </label>
            </div>
          )}

          <div className="grid grid-cols-3 gap-3 max-md:grid-cols-1">
            <Field label={t("subscription.rules.seeders")}>
              <NumberInput value={minSeeders} onChange={setMinSeeders} placeholder={t("subscription.rules.any")} />
            </Field>
            <Field label={t("subscription.rules.minSize")}>
              <NumberInput value={sizeMin} onChange={setSizeMin} placeholder={t("subscription.rules.any")} />
            </Field>
            <Field label={t("subscription.rules.maxSize")}>
              <NumberInput value={sizeMax} onChange={setSizeMax} placeholder={t("subscription.rules.any")} />
            </Field>
          </div>
          <p className="-mt-3 text-caption leading-relaxed text-[var(--text-faint)]">
            {t("subscription.rules.sizeHint")}
          </p>
          </Section>

          <Field
            label={t("subscription.rules.upgrade")}
            hint={t("subscription.rules.upgradeHint")}
          >
            <div className="flex flex-wrap gap-1.5">
              <ToggleChip active={upgradeSource === ""} onClick={() => setUpgradeSource("")}>
                {t("subscription.rules.upgradeOff")}
              </ToggleChip>
              {upgradeOptions(locale).filter(
                ([value]) => !mediaSources.length || mediaSources.includes(value),
              ).map(([value, label]) => (
                <ToggleChip
                  key={value}
                  active={upgradeSource === value}
                  onClick={() => setUpgradeSource(value)}
                >
                  {label}
                </ToggleChip>
              ))}
            </div>
            {upgradeSource !== "" && (
              <div className="mt-2 rounded-xl bg-white/[0.03] px-4 py-2.5">
                <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1.5">
                  <span className="text-sub text-[var(--text-muted)]">{t("subscription.rules.cutoff")}</span>
                  <div className="flex flex-wrap gap-1.5">
                    {(resolutions.length ? resolutions : RESOLUTION_OPTIONS).map((option) => {
                      const effective = cutoffResolution || resolutions[0] || "1080p";
                      return (
                        <ToggleChip
                          key={option}
                          active={effective === option}
                          onClick={() =>
                            setCutoffResolution(option === (resolutions[0] ?? "") ? "" : option)
                          }
                        >
                          {option}
                        </ToggleChip>
                      );
                    })}
                  </div>
                </div>
                <p className="mt-1.5 text-caption text-[var(--text-faint)]">
                  {resolutions.length > 0
                    ? t("subscription.rules.cutoffHint")
                    : t("subscription.rules.cutoffUnrestricted")}
                </p>
                {/* 旧版本处置（library-file-recycle.md §9）：配置洗版的那一刻
                    就是询问旧版去留的合适时机；保留共存服务收藏家场景 */}
                <label className="mt-2.5 flex cursor-pointer items-center justify-between gap-3 border-t border-white/[0.06] pt-2.5">
                  <span>
                    <span className="block text-sub text-[var(--text-muted)]">
                      {t("subscription.rules.keepOld")}
                    </span>
                    <span className="mt-0.5 block text-caption text-[var(--text-faint)]">
                      {t("subscription.rules.keepOldHint")}
                    </span>
                  </span>
                  <input
                    type="checkbox"
                    checked={upgradeKeepOld}
                    onChange={(e) => setUpgradeKeepOld(e.target.checked)}
                    className="size-4 accent-[var(--accent-2)]"
                  />
                </label>

                {/* 洗版优先级：交互与上方分辨率偏好一致——点击依次入列、序号即
                    位次。多一位就是多一轮潜在的重复下载，所以缺省只有前两位 */}
                <div className="mt-2.5 border-t border-white/[0.06] pt-2.5">
                  <button
                    type="button"
                    onClick={() => setLadderOpen((v) => !v)}
                    className="flex w-full items-center gap-3 text-left"
                  >
                    <span className="shrink-0 text-sub text-[var(--text-muted)]">
                      {t("subscription.rules.priority")}
                    </span>
                    <span className="min-w-0 flex-1 truncate text-right text-caption text-[var(--text-faint)]">
                      {ladderText}
                    </span>
                    <span
                      className={`shrink-0 text-[var(--text-faint)] transition-transform ${
                        ladderOpen ? "rotate-90" : ""
                      }`}
                    >
                      ›
                    </span>
                  </button>
                  {ladderOpen && (
                    <>
                  <div className="mt-2 flex flex-wrap items-center justify-between gap-x-4 gap-y-1.5">
                    <span className="text-caption text-[var(--text-faint)]">{t("subscription.rules.chooseOrder")}</span>
                    <div className="flex flex-wrap gap-1.5">
                      {ladderOptions(locale).map((dim) => {
                        const index = upgradeLadder.indexOf(dim.value);
                        const unconfigured = ladderUnconfigured(dim.value);
                        return (
                          <ToggleChip
                            key={dim.value}
                            active={index >= 0}
                            onClick={() => toggleLadderDim(dim.value)}
                          >
                            {index >= 0 && upgradeLadder.length > 1 && (
                              <span className="mr-1.5 inline-flex size-4 items-center justify-center rounded-full bg-white/20 text-micro font-semibold">
                                {index + 1}
                              </span>
                            )}
                            {dim.label}
                            {index >= 0 && unconfigured && (
                              <span className="ml-1 text-[var(--text-faint)]">{t("subscription.rules.unconfigured")}</span>
                            )}
                          </ToggleChip>
                        );
                      })}
                    </div>
                  </div>
                    <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
                      {t("subscription.rules.priorityHint")}
                    </p>
                    </>
                  )}
                  {platformNotLast && (
                    <p className="mt-1.5 rounded-lg border border-amber-400/25 bg-amber-500/10 px-3 py-2 text-caption leading-relaxed text-amber-200">
                      {t("subscription.rules.platformWarning")}
                    </p>
                  )}
                </div>
              </div>
            )}
          </Field>

          {/* 配完给一句人话回执：新用户最缺的就是"我配的到底是什么"的确认。
              内容来自与保存同一个 draft.spec，不会出现"看到的和存下去的不一样" */}
          <div className="rounded-xl bg-white/[0.03] px-4 py-3">
            <p className="text-caption text-[var(--text-faint)]">
              {ladderPreview ? t("subscription.rules.filterFirst") : t("subscription.rules.filterSummary")}
            </p>
            <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
              {draftChips.length
                ? draftChips.join(" · ")
                : t("subscription.rules.noConditions")}
            </p>
            {ladderPreview && (
              <UpgradeLadderPreviewView preview={ladderPreview} keepOld={upgradeKeepOld} />
            )}
          </div>

          {error && (
            <p className="rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2.5 text-sub leading-6 text-red-200">
              {error}
            </p>
          )}
        </div>
      </div>

      {/* 底栏常驻 */}
      <div className="flex justify-end gap-3 border-t border-white/[0.07] px-6 py-4 max-md:px-5">
        <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
          {t("common.cancel")}
        </button>
        <button
          type="button"
          disabled={busy || !name.trim()}
          onClick={() => void submit()}
          className={SETTINGS_PRIMARY_BUTTON_CLASS}
        >
          {busy ? t("subscription.rules.saving") : t("common.save")}
        </button>
      </div>
    </Modal>
  );
}

/**
 * 洗版阶梯预览：把"洗到哪一档"从一句话摊成一条**看得见的路**。
 *
 * 一句"洗到 1080p 蓝光 · DV"读不出洗版真正的两个后果，而它们恰恰是用户
 * 最该在按下保存之前知道的（docs/design/quality-upgrade.md §2.1 / §14.6）：
 *
 * - **终点之下还有多少档**：每上一档就是一次重复下载，多加一维阶梯的代价
 *   在这里才具体；
 * - **哪些档已经算达标**：分辨率排在第一位时，任意 2160p 资源（哪怕 WEBRip）
 *   都优于 1080p 蓝光，洗版会直接停在那儿——所以"更高档同样算达标"必须写在
 *   展开后的终点卡上，而不是留给用户自己推。
 *
 * **默认折叠**：完整阶梯要占十来行，常驻会把配置本身挤出视野；收起态只留
 * 一行终点（这段里唯一值得常驻的信息），其余进按钮后面。用点击而不是 hover
 * ——这个弹窗在手机上同样要用，触屏没有 hover；且这里是要读几行的解释，
 * 浮层里读长内容不如就地展开。折叠的交互形态与同一弹窗里的「洗版优先级」
 * 「画质与来源」保持一致，不新增第三种。
 *
 * 展开后版式即语义：终点在最上方并高亮（"最好品质"是这条路的目的地），下方
 * 按档位降序排开、每行一个 ↑ 指回终点——从下往上读就是资源逐级被替换的过程。
 */
function UpgradeLadderPreviewView({
  preview,
  keepOld,
}: {
  preview: UpgradeLadderPreview;
  keepOld: boolean;
}) {
  const t = useTranslations();
  const [open, setOpen] = useState(false);
  return (
    <div className="mt-2.5 border-t border-white/[0.06] pt-2.5">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="flex w-full items-center gap-3 text-left"
      >
        <span className="min-w-0 flex-1 text-sub text-[var(--text-muted)]">
          {t.rich("subscription.rules.upgradeTo", { value: preview.target, target: (chunks) => <span className="font-semibold text-white">{chunks}</span> })}
        </span>
        <span className="shrink-0 text-caption text-[var(--text-faint)]">
          {open ? t("subscription.rules.collapse") : t("subscription.rules.showLadder")}
        </span>
        <span
          className={`shrink-0 text-[var(--text-faint)] transition-transform ${
            open ? "rotate-90" : ""
          }`}
        >
          ›
        </span>
      </button>

      {open && (
        <div className="mt-2.5">
          <p className="text-caption leading-relaxed text-[var(--text-faint)]">
            {t("subscription.rules.ladderOrder", { dimensions: preview.dimensions.join(" › ") })}
          </p>

          <div className="mt-2 rounded-lg border border-[var(--accent-2)]/45 bg-[var(--accent-2)]/[0.14] px-3 py-2">
            <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
              <span className="rounded-full bg-[var(--accent-2)]/25 px-2 py-0.5 text-micro font-semibold text-white">
                {t("subscription.rules.target")}
              </span>
              <span className="text-sub font-semibold text-white">{preview.target}</span>
            </div>
            <p className="mt-1 text-caption leading-relaxed text-[var(--text-faint)]">
              {t("subscription.rules.targetStop", { higher: preview.ceiling ? "yes" : "no", ceiling: preview.ceiling ?? "", keepOld: keepOld ? "yes" : "no" })}
            </p>
          </div>

          {preview.below.length > 0 ? (
            <>
              <p className="mt-2.5 text-caption leading-relaxed text-[var(--text-faint)]">
                {t("subscription.rules.belowHint")}
              </p>
              <ol className="mt-1.5 space-y-1">
                {preview.below.map((label) => (
                  <li
                    key={label}
                    className="flex items-center gap-2 text-sub text-[var(--text-muted)]"
                  >
                    <span className="text-[var(--text-faint)]">↑</span>
                    <span>{label}</span>
                  </li>
                ))}
                {preview.moreBelow > 0 && (
                  <li className="flex items-center gap-2 text-caption text-[var(--text-faint)]">
                    <span>↑</span>
                    <span>{t("subscription.rules.moreBelow", { count: preview.moreBelow })}</span>
                  </li>
                )}
              </ol>
            </>
          ) : (
            <p className="mt-2 text-caption text-[var(--text-faint)]">
              {t("subscription.rules.lowestTarget")}
            </p>
          )}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// 表单积木
// ---------------------------------------------------------------------------

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <div>
      <p className="mb-1.5 text-ui font-semibold text-white/85">{label}</p>
      {children}
      {hint && <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">{hint}</p>}
    </div>
  );
}

function ToggleChip({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`rounded-full border px-3 py-1.5 text-sub font-medium transition ${
        active
          ? "border-white/25 bg-white/[0.14] text-white"
          : "border-white/[0.08] bg-white/[0.03] text-[var(--text-muted)] hover:bg-white/[0.07]"
      }`}
    >
      {children}
    </button>
  );
}

/**
 * 可折叠分段：折叠态直接显示该段的**当前摘要**——不展开也知道里面配了什么，
 * 这是这个长表单能收起来的前提（渐进披露，quality-upgrade.md §14.9）。
 */
function Section({
  title,
  summary,
  children,
}: {
  title: string;
  summary: string;
  children: React.ReactNode;
}) {
  const [open, setOpen] = useState(false);
  return (
    <div className="rounded-xl border border-white/[0.07] bg-white/[0.02]">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-center gap-3 px-4 py-3 text-left"
      >
        <span className="shrink-0 text-ui font-semibold text-white/85">{title}</span>
        <span className="min-w-0 flex-1 truncate text-right text-caption text-[var(--text-faint)]">
          {summary}
        </span>
        <span
          className={`shrink-0 text-[var(--text-faint)] transition-transform ${
            open ? "rotate-90" : ""
          }`}
        >
          ›
        </span>
      </button>
      {open && (
        <div className="space-y-5 border-t border-white/[0.06] px-4 pb-4 pt-4">{children}</div>
      )}
    </div>
  );
}

/**
 * 三态芯片：不限 → 只要 → 排除 → 不限。
 *
 * 平台有十几个选项，白/黑名单铺成两组芯片就是三十多个点击目标；三态把它压回
 * 一组，且每个芯片自解释（选中=只要，红色带 ✕=排除）。
 */
function TriChip({
  state,
  onClick,
  children,
}: {
  state: "off" | "include" | "exclude";
  onClick: () => void;
  children: React.ReactNode;
}) {
  const tone =
    state === "include"
      ? "border-white/25 bg-white/[0.14] text-white"
      : state === "exclude"
        ? "border-red-400/35 bg-red-500/12 text-red-200"
        : "border-white/[0.08] bg-white/[0.03] text-[var(--text-muted)] hover:bg-white/[0.07]";
  return (
    <button
      type="button"
      onClick={onClick}
      className={`rounded-full border px-3 py-1.5 text-sub font-medium transition ${tone}`}
    >
      {state === "exclude" && <span className="mr-1">✕</span>}
      {children}
    </button>
  );
}

function CheckRow({
  label,
  hint,
  checked,
  onChange,
}: {
  label: string;
  hint: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <label className="flex cursor-pointer items-center justify-between rounded-xl border border-white/[0.08] bg-white/[0.04] px-4 py-3">
      <span>
        <span className="block text-ui font-medium text-white/90">{label}</span>
        <span className="mt-0.5 block text-caption text-[var(--text-faint)]">{hint}</span>
      </span>
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="size-4 accent-[var(--accent-2)]"
      />
    </label>
  );
}

function NumberInput({
  value,
  onChange,
  placeholder,
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
}) {
  return (
    <input
      type="number"
      min={0}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      className={`${SETTINGS_INPUT_CLASS} w-full`}
    />
  );
}
