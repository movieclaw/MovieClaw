"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { useLocale, useTranslations } from "next-intl";
import { appTranslator } from "@/lib/i18n/translate";
import { formatList } from "@/lib/i18n/format";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";
import { ruleSetLabel } from "@/lib/rule-set-label";

import type { Route } from "next";
import { useRouter } from "next/navigation";

import { BrandLoader } from "@/components/brand-loader";
import { EMPTY_CHOICE, SmartPlanCard, smartChoicePayload, type SmartChoice } from "@/components/smart-plan-card";
import { CheckIcon, ChevronRightIcon, ListIcon, PlusIcon, TrashIcon, UpgradeIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import { PosterImage } from "@/components/poster-image";
import { RuleSetEditorDialog, specSummary, upgradeTargetLabel } from "@/components/rule-sets-panel";
import {
  SheetChoiceRow,
  SheetMenuAction,
  SheetMenuRow,
  SheetNotice,
  SheetRow,
  SheetScaffold,
  SheetSection,
  SheetToggleRow,
  useSheetForm,
} from "@/components/sheet-scaffold";
import { SubscriptionCancelDialog } from "@/components/subscription-cancel-dialog";
import { SeasonCapLine } from "@/components/subscription-episode-cap";
import { UpgradeRunReportView } from "@/components/upgrade-run-dialog";
import { listLibraries, type MediaLibrary } from "@/lib/api/libraries";
import {
  createSubscription,
  deleteSubscriptionPermanently,
  listRuleSets,
  previewSubscriptionDownloadRouting,
  previewSubscriptionTitle,
  runSubscriptionUpgradeRound,
  unsubscribeFromSubscription,
  type DispatchPreview,
  type PrepareResult,
  type ResolveCandidate,
  type RuleSet,
  type SeasonOverview,
  type SubscriptionRemovalOptions,
  type UpgradeRunReport,
} from "@/lib/api/subscriptions";
import { HttpError } from "@/lib/http";
import { imageUrl } from "@/lib/image-proxy";
import type { MediaType } from "@/lib/media-types";
import { usePermissions } from "@/lib/permissions";
import {
  capsPayload,
  effectiveWindow,
  isAiringSeason,
  isLongSeason,
  type CapDraft,
} from "@/lib/subscription-episode-cap";

/**
 * 订阅弹层只传递 Discover 签发的 titleRef；来源识别与 TMDB 锚定由后端负责。
 */
export interface SubscribeTarget {
  titleRef: string;
  kind: MediaType;
  title: string;
  year?: number;
  /**
   * 洗版变体（quality-upgrade.md §13.3，库详情「洗版」入口）：季勾选按媒体库
   * 库存预填、规则组只列带洗版目标的组、自动续订默认关；创建成功后自动触发
   * 一轮洗版并展示体检报告。
   */
  upgradeIntent?: boolean;
}

/** 成员洗版的规则组说明：成员不能选组，洗到哪一档由管理员在规则组里配置。 */
const MEMBER_UPGRADE_RULE_HINT_KEY = "subscription.subscribe.memberUpgradeHint";

/**
 * 订阅弹层：一次点击完成订阅，复杂度沉到默认值。
 *
 * 流程（对应后端 /subscriptions/title-preview 的三态）：
 *   loading → ready（渲染季选择 + 自动续订开关 + 规则组）
 *           → ambiguous（豆瓣收敛歧义：候选墙确认一次后重新 prepare）
 *           → not_found（TMDB 未收录，无法订阅）
 * 已订阅的条目进入管理态：展示状态并提供取消订阅。
 *
 * 默认值策略：剧集默认勾选全部已播出的正季（特别季 0 须手动勾）、
 * 在播剧默认打开「自动续订」；规则组默认选中系统默认组。
 */
export function SubscribeDialog({
  target,
  onClose,
  onChanged,
}: {
  target: SubscribeTarget | null;
  onClose: () => void;
  onChanged?: () => void;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const { canManageSubscriptions, isAdmin } = usePermissions();
  const router = useRouter();
  // 银玻璃手机端走表单弹层（SheetScaffold，对齐 iOS SubscribeSheet）；桌面与 Netflix 保持原弹窗
  const sheetForm = useSheetForm();
  const upgradeMode = !!target?.upgradeIntent;
  const [prepared, setPrepared] = useState<PrepareResult | null>(null);
  // 洗版变体：创建成功后自动触发的一轮洗版报告（非空即进入报告段）
  const [upgradeReport, setUpgradeReport] = useState<UpgradeRunReport | null>(null);
  const [error, setError] = useMessageState();
  const [ruleSets, setRuleSets] = useState<RuleSet[]>([]);
  const [libraries, setLibraries] = useState<MediaLibrary[]>([]);
  const [selectedSeasons, setSelectedSeasons] = useState<Set<number>>(new Set());
  const [followFuture, setFollowFuture] = useState(false);
  // 豆瓣集数多于 TMDB 时（issue #640）：用户确认后按豆瓣集数追，默认不改
  const [useDoubanEpisodes, setUseDoubanEpisodes] = useState(false);
  // 超长的一季先订阅一部分：用户的改动（没动过 = 按默认先订阅一批），见 lib/subscription-episode-cap
  const [capDraft, setCapDraft] = useState<CapDraft>({});
  const [ruleSetId, setRuleSetId] = useState<number | null>(null);
  const [selectionMode, setSelectionMode] = useState<"smart" | "rules">("smart");
  // 智能选择里管理员做的选择（字幕回答、改过的画质与记住的范围），随创建请求提交
  const [smartChoice, setSmartChoice] = useState<SmartChoice>(EMPTY_CHOICE);
  const [smartEditing, setSmartEditing] = useState(false);
  const [optionsOpen, setOptionsOpen] = useState(false);
  const [rangeExpanded, setRangeExpanded] = useState(false);
  // 快捷新建规则组（编辑器叠在本弹窗之上，保存后自动选中新组）
  const [creatingRuleSet, setCreatingRuleSet] = useState(false);
  // 管理员取消订阅：叠一层弹窗选"要不要连种子/媒体库文件一起删"
  const [cancelling, setCancelling] = useState(false);
  const [libraryId, setLibraryId] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  // 投递路由预检：选库即预演"下载会落到哪、能否自动入库"，配置问题当场亮出
  const [dispatchPreview, setDispatchPreview] = useState<DispatchPreview | null>(null);
  // 收藏范围路由的预选结论：打开弹窗时按作品特征算出的默认库 + 中文理由。
  // 规则只决定默认值——用户改选其它库即显式指定，徽标随之消失
  const [routed, setRouted] = useState<{ libraryId: number; reason: string | null } | null>(null);
  // 规则组适用范围的预选结论（docs/design/rule-set-scope.md）：与选库同一次
  // 预检算出，同样只决定默认值——用户改选其它组即显式指定，徽标随之消失
  const [ruleRouted, setRuleRouted] = useState<{ ruleSetId: number; reason: string } | null>(
    null,
  );
  const routingKind = prepared?.media?.kind ?? target?.kind;

  useEffect(() => {
    if (!canManageSubscriptions || !routingKind || libraryId === null) {
      setDispatchPreview(null);
      return;
    }
    let cancelled = false;
    setDispatchPreview(null);
    // 带上条目身份：后端据此渲染条目目录预览（entry_dir），前端不自己拼名字
    previewSubscriptionDownloadRouting(routingKind, libraryId, prepared?.media?.tmdb_id, {
      title: prepared?.media?.title,
      year: prepared?.media?.year,
    })
      .then((p) => {
        if (!cancelled) setDispatchPreview(p);
      })
      .catch(() => {
        /* 预检失败静默：只是提示层，不影响订阅主流程 */
      });
    return () => {
      cancelled = true;
    };
  }, [canManageSubscriptions, routingKind, libraryId, prepared?.media, locale]);

  // Refresh translated previews without reinitializing the user's form choices.
  const previewLocale = useRef(locale);
  useEffect(() => {
    if (previewLocale.current === locale) return;
    if (!target || !prepared?.media) {
      if (!target) previewLocale.current = locale;
      return;
    }
    previewLocale.current = locale;
    const media = prepared.media;
    let cancelled = false;
    Promise.all([
      previewSubscriptionTitle({ title_ref: `tmdb:${media.kind}:${media.tmdb_id}` }),
      canManageSubscriptions
        ? previewSubscriptionDownloadRouting(media.kind, null, media.tmdb_id).catch(() => null)
        : Promise.resolve(null),
    ]).then(([next, routing]) => {
      if (cancelled) return;
      setPrepared((current) => current?.media?.kind === media.kind && current.media.tmdb_id === media.tmdb_id
        ? { ...current, smart: next.smart ?? null } : current);
      setRouted((current) => current && current.libraryId === routing?.library_id
        ? { ...current, reason: routing.route_reason } : current);
      setRuleRouted((current) => current && current.ruleSetId === routing?.rule_set_id && routing.rule_set_reason
        ? { ...current, reason: routing.rule_set_reason } : current);
    }).catch(() => { /* Presentation refresh must not discard a usable form. */ });
    return () => { cancelled = true; };
  }, [locale, target, prepared?.media, canManageSubscriptions]);

  /** 预检并按结果初始化表单默认值（候选确认后会带着 tmdbId 再次进入）。 */
  const runPrepare = useCallback(
    async (candidateTarget: SubscribeTarget) => {
      setSelectionMode(candidateTarget.upgradeIntent ? "rules" : "smart");
      setSmartChoice(EMPTY_CHOICE);
      setSmartEditing(false);
      setOptionsOpen(!!candidateTarget.upgradeIntent);
      setRangeExpanded(false);
      setCapDraft({});
      setPrepared(null);
      setError(null);
      setUpgradeReport(null);
      try {
        // 规则组是超管的配置知识（GET /rule-sets 仅超管）：成员一律不拉列表、
        // 不选组，洗版变体也按订阅当前的规则组洗（后端忽略成员传的 rule_set_id）
        const [result, rules, initialLibs] = await Promise.all([
          previewSubscriptionTitle({ title_ref: candidateTarget.titleRef }),
          canManageSubscriptions ? listRuleSets() : Promise.resolve([]),
          // 媒体库列表与预检并行拉，少等一个往返：TMDB 引用的类型是确定的，
          // 只有豆瓣引用偶尔会被后端收敛成另一类型，那时再按 canonical kind 补拉
          canManageSubscriptions ? listLibraries(candidateTarget.kind) : Promise.resolve([]),
        ]);
        // 豆瓣条目可能没有可靠的前端类型；媒体库和投递路由必须以后端
        // 收敛后的 canonical kind 为准，避免电影/剧集选到错误的库。
        const resolvedKind = result.media?.kind ?? candidateTarget.kind;
        const libs =
          !canManageSubscriptions || resolvedKind === candidateTarget.kind
            ? initialLibs
            : await listLibraries(resolvedKind);
        setRuleSets(rules);
        setLibraries(libs);
        // 默认库 = 收藏范围路由的结论（按作品的类型/区域自动选库，带中文理由）；
        // 预检失败或没有路由结论时回落该类型默认库
        const fallbackId = libs.find((l) => l.is_default)?.id ?? libs[0]?.id ?? null;
        setRouted(null);
        setRuleRouted(null);
        let pickedId = fallbackId;
        let pickedRuleSetId: number | null = null;
        let pickedRuleReason: string | null = null;
        if (canManageSubscriptions && result.status === "ready" && result.media) {
          const p = await previewSubscriptionDownloadRouting(
            resolvedKind,
            null,
            result.media.tmdb_id,
          ).catch(() => null);
          if (p?.library_id != null && libs.some((l) => l.id === p.library_id)) {
            pickedId = p.library_id;
            setRouted({ libraryId: p.library_id, reason: p.route_reason });
          }
          // 同一次预检顺带给出按适用范围选中的规则组（后端与创建时同一套选组逻辑）
          if (p?.rule_set_id != null) {
            pickedRuleSetId = p.rule_set_id;
            pickedRuleReason = p.rule_set_matched ? (p.rule_set_reason ?? null) : null;
          }
        }
        // 规则组预选：适用范围的结论优先；洗版变体只在带洗版目标的组里选
        //（结论组不带目标时退回默认组/第一个候选）
        const candidates = candidateTarget.upgradeIntent
          ? rules.filter((r) => upgradeTargetLabel(r.spec))
          : rules;
        const scoped = candidates.find((r) => r.id === pickedRuleSetId);
        setRuleSetId(
          (scoped ?? candidates.find((r) => r.is_default) ?? candidates[0])?.id ?? null,
        );
        if (scoped && pickedRuleReason) {
          setRuleRouted({ ruleSetId: scoped.id, reason: pickedRuleReason });
        }
        setLibraryId(pickedId);
        setPrepared(result);
        // 默认勾选全部已播出的正季；在播剧默认开启自动续订。
        // 洗版变体（§13.3）：改按媒体库库存预填（用户意图是洗手里有的），
        // 自动续订默认关（洗版场景不追新，可自行打开）
        //
        // 豆瓣季条目例外：用户点进的是「中餐厅 第十季」，要订的就是那一季，
        // 勾上整部剧十季显然不是他的意图。服务端只在条目确实季专属时给出
        // suggested_seasons（普通剧名为空），所以这里直接采信即可
        const suggested = result.suggested_seasons ?? [];
        const defaultSeasons = candidateTarget.upgradeIntent
          ? result.seasons.filter((s) => s.owned_count > 0).map((s) => s.season_number)
          : suggested.length > 0
            ? suggested
            : result.seasons
                .filter((s) => s.season_number > 0 && s.aired_count > 0)
                .map((s) => s.season_number);
        setSelectedSeasons(new Set(defaultSeasons));
        setRangeExpanded(defaultSeasons.length === 0 && result.media?.status !== "Returning Series");
        setFollowFuture(
          !candidateTarget.upgradeIntent &&
            resolvedKind === "tv" &&
            result.media?.status === "Returning Series",
        );
      } catch (e) {
        setError(e instanceof Error ? e.message : { key: "subscription.subscribe.prepareFailed" });
      }
    },
    [canManageSubscriptions, setError],
  );

  useEffect(() => {
    if (target) void runPrepare(target);
  }, [target, runPrepare]);

  const toggleSeason = (n: number) =>
    setSelectedSeasons((prev) => {
      const next = new Set(prev);
      if (next.has(n)) next.delete(n);
      else next.add(n);
      return next;
    });

  const pickCandidate = (candidate: ResolveCandidate) => {
    if (!target) return;
    void runPrepare({ ...target, titleRef: candidate.title_ref });
  };

  // 豆瓣集数提示只对勾选了的那一季（或开着自动续订）有意义
  const doubanEpisodes =
    prepared?.douban_episodes &&
    (selectedSeasons.has(prepared.douban_episodes.season_number) || followFuture)
      ? prepared.douban_episodes
      : null;

  // 勾上的超长季（洗版不涉及）：多出一行「先订阅一部分」。在播的超长季默认订
  // 最新的几集（之后播出的照常进来），完结的从第 1 集订起
  const mediaStatus = prepared?.media?.status ?? null;
  const airingOf = (seasonNumber: number) =>
    isAiringSeason(mediaStatus, prepared?.seasons ?? [], seasonNumber);
  const capSeasons = upgradeMode
    ? []
    : (prepared?.seasons ?? []).filter(
        (season) => selectedSeasons.has(season.season_number) && isLongSeason(season),
      );

  const submit = async () => {
    if (!target || !prepared?.media) return;
    setBusy(true);
    setError(null);
    try {
      const episodeCaps = capsPayload(capSeasons, selectedSeasons, capDraft, mediaStatus);
      // 提交预检已经收敛好的 TMDB 引用，而不是入口的豆瓣引用：豆瓣→TMDB 的
      // 收敛（多路 TMDB 搜索 + 逐候选季表）没有缓存，再传豆瓣引用会让创建接口
      // 把这一整套外网请求重跑一遍。豆瓣身份靠 source_title_ref 原样带回。
      const created = await createSubscription({
        title_ref: `tmdb:${prepared.media.kind}:${prepared.media.tmdb_id}`,
        source_title_ref: target.titleRef.startsWith("douban:") ? target.titleRef : null,
        selected_seasons: [...selectedSeasons].sort((a, b) => a - b),
        follow_future: followFuture,
        rule_set_id: selectionMode === "rules" && canManageSubscriptions ? ruleSetId : null,
        selection_mode: selectionMode,
        ...(selectionMode === "smart" && prepared.smart
          ? { smart_profile_revision: prepared.smart.profile_revision, ...smartChoicePayload(prepared.smart, smartChoice) }
          : {}),
        library_id: canManageSubscriptions ? libraryId : null,
        ...(doubanEpisodes && useDoubanEpisodes
          ? { episode_floors: { [doubanEpisodes.season_number]: doubanEpisodes.douban_count } }
          : {}),
        ...(Object.keys(episodeCaps).length > 0 ? { episode_caps: episodeCaps } : {}),
      });
      onChanged?.();
      if (upgradeMode) {
        // 洗版变体：创建成功即自动接一轮洗版，弹层切到体检报告段（§13.3）。
        // 管理员把所选规则组显式带给 upgrade-runs（创建时已选中，后端跳过同组切换）；
        // 成员不选组，按订阅落定的规则组洗版，不传 rule_set_id。
        // 触发失败时订阅已建好——报错留在弹层里，用户可去订阅详情重试
        try {
          setUpgradeReport(
            await runSubscriptionUpgradeRound(
              created.id,
              canManageSubscriptions ? (ruleSetId ?? undefined) : undefined,
            ),
          );
        } catch (e) {
          setError({ key: e instanceof Error ? "subscription.subscribe.createdUpgradeFailed" : "subscription.subscribe.createdUpgradeRetry", values: e instanceof Error ? { reason: e.message } : undefined });
        }
        return;
      }
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.subscribe.createFailed" });
      // 弹层打开期间别人改了设置或记忆：重新读一遍，按最新的再确认
      if (e instanceof HttpError && e.status === 409) void refreshSmartPlan();
    } finally {
      setBusy(false);
    }
  };

  /** 智能设置保存或记忆冲突后，只刷新智能选择摘要，不动已选的季和库。 */
  const refreshSmartPlan = async () => {
    if (!prepared?.media) return;
    const next = await previewSubscriptionTitle({ title_ref: `tmdb:${prepared.media.kind}:${prepared.media.tmdb_id}` });
    setSmartChoice(EMPTY_CHOICE);
    setPrepared((current) => (current ? { ...current, smart: next.smart ?? null } : current));
  };

  // 管理员的取消订阅先叠一层弹窗问"种子与媒体库资源要不要一起删"（与订阅
  // 详情页同一个组件、同一套文案）；成员只是取消自己的关注，直接执行。
  const unsubscribe = async () => {
    if (!prepared?.existing_subscription_id) return;
    if (isAdmin) {
      setCancelling(true);
      return;
    }
    setBusy(true);
    try {
      await unsubscribeFromSubscription(prepared.existing_subscription_id);
      onChanged?.();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.subscribe.cancelFailed" });
    } finally {
      setBusy(false);
    }
  };

  const confirmRemoval = async (options: SubscriptionRemovalOptions) => {
    if (!prepared?.existing_subscription_id) return;
    setBusy(true);
    try {
      await deleteSubscriptionPermanently(prepared.existing_subscription_id, options);
      setCancelling(false);
      onChanged?.();
      onClose();
    } catch (e) {
      setCancelling(false);
      setError(e instanceof Error ? e.message : { key: "subscription.subscribe.cancelFailed" });
    } finally {
      setBusy(false);
    }
  };

  // 洗版变体的规则组候选：只列带洗版目标的组（洗版目标住在规则组上）
  const selectableRules = useMemo(
    () => (upgradeMode ? ruleSets.filter((r) => upgradeTargetLabel(r.spec)) : ruleSets),
    [upgradeMode, ruleSets],
  );

  const canSubmit = useMemo(() => {
    if (!prepared?.media || busy) return false;
    if (selectionMode === "smart" && (!prepared.smart?.configured || smartEditing)) return false;
    // 洗版变体必须选中一个带洗版目标的组，否则触发一轮洗版会被后端拒绝；
    // 成员不选组（按订阅当前的规则组洗版），不受此约束
    if (
      upgradeMode &&
      canManageSubscriptions &&
      !selectableRules.some((r) => r.id === ruleSetId)
    ) {
      return false;
    }
    if (prepared.media.kind === "movie") return true;
    return selectedSeasons.size > 0 || followFuture;
  }, [
    prepared,
    busy,
    selectedSeasons,
    followFuture,
    upgradeMode,
    canManageSubscriptions,
    selectableRules,
    ruleSetId,
    selectionMode,
    smartEditing,
  ]);

  if (!target) return null;

  const media = prepared?.media;
  const kind = media?.kind ?? target.kind;
  const existingId = prepared?.status === "ready" ? prepared.existing_subscription_id : null;
  const showsForm = prepared?.status === "ready" && !existingId;
  const showsRules = selectionMode === "rules" && canManageSubscriptions;
  const pickedRule = selectableRules.find((r) => r.id === ruleSetId);
  const chips = pickedRule ? specSummary(pickedRule.spec, {}, locale) : [];
  const pickedLibrary = libraries.find((l) => l.id === libraryId);
  const seasonNames = [...selectedSeasons].sort((a, b) => a - b).map((n) => n === 0 ? t("media.season.specials") : t("media.season.title", { number: n }));
  const rangeSummary = seasonNames.length > 3 ? t("subscription.subscribe.selectedSeasons", { count: seasonNames.length }) : formatList(seasonNames, locale);

  const mediaSummary = <div className="flex items-center gap-3.5 px-1">
    <div className="h-[84px] w-14 shrink-0 overflow-hidden rounded-lg bg-white/[0.06] ring-1 ring-inset ring-white/10">
      <PosterImage src={media?.poster_url ? imageUrl(media.poster_url) : undefined} width={56} alt={media?.title ?? target.title} className="size-full object-cover" />
    </div>
    <div className="min-w-0 flex-1">
      <p className="line-clamp-2 text-title-sm font-semibold text-white">{media?.title ?? target.title}</p>
      <p className="mt-1 text-sub text-[var(--text-muted)]">{[media?.year ?? target.year, kind === "movie" ? t("media.kind.movie") : t("media.kind.tv")].filter(Boolean).join(" · ")}</p>
      {showsForm && prepared?.movie_owned && <p className="mt-1.5 flex items-center gap-1 text-caption text-[var(--ok)]">
        <CheckIcon className="size-3.5 shrink-0" />
        {upgradeMode ? t("subscription.subscribe.ownedUpgrade") : t("subscription.subscribe.ownedKeep")}
      </p>}
    </div>
  </div>;

  // 桌面与手机共用同一份订阅信息层级，低频选项只在用户展开时显示。
  const subscriptionForm = <div className="space-y-4">
    {selectionMode === "smart" ? (
      <SmartPlanCard plan={prepared?.smart ?? null} choice={smartChoice} setChoice={setSmartChoice} onSettingsSaved={() => void refreshSmartPlan()} onEditingChange={setSmartEditing} />
    ) : (
      <section className="rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4" aria-label={t("subscription.subscribe.rulesSelection")}>
        <div className="flex items-center justify-between gap-3">
          <h3 className="text-sub text-[var(--text-muted)]">{upgradeMode ? t("subscription.subscribe.upgradeRules") : t("subscription.subscribe.rulesMode")}</h3>
          {canManageSubscriptions && <button type="button" className="min-h-11 -my-2 -mr-2 px-2 text-sub text-[var(--accent)]" onClick={() => setOptionsOpen(true)}>{t("subscription.subscribe.changeRules")}</button>}
        </div>
        <p className="mt-2 text-body font-semibold text-[var(--text)]">{pickedRule ? ruleSetLabel(pickedRule, locale) : t("subscription.subscribe.systemRules")}</p>
        {upgradeMode && <p className="mt-2 text-sub text-[var(--text-muted)]">{pickedRule ? t("subscription.subscribe.upgradeTo", { target: upgradeTargetLabel(pickedRule.spec, locale) ?? "" }) : t(MEMBER_UPGRADE_RULE_HINT_KEY)}</p>}
        {pickedRule && chips.length === 0 && <p className="mt-2 text-sub text-[var(--warn)]">{t("subscription.subscribe.unrestrictedRules")}</p>}
      </section>
    )}

    {kind === "tv" && <section className="overflow-hidden rounded-2xl border border-[var(--line)]" aria-label={t("subscription.subscribe.trackingScope")}>
      <button type="button" aria-expanded={rangeExpanded} onClick={() => setRangeExpanded((value) => !value)} className="flex w-full items-center gap-3 p-4 text-left">
        <span className="min-w-0 flex-1">
          <span className="block text-sub text-[var(--text-muted)]">{t("subscription.subscribe.trackingScope")}</span>
          <span className="mt-1 block text-ui font-medium text-[var(--text)]">{rangeSummary || (followFuture ? t("subscription.subscribe.futureOnly") : t("subscription.subscribe.chooseSeasons"))}</span>
          <span className="mt-1 block text-caption text-[var(--text-muted)]">{followFuture ? t("subscription.subscribe.followDescription") : t("subscription.subscribe.selectedOnly")}</span>
        </span>
        <span className="text-sub text-[var(--text-muted)]">{rangeExpanded ? t("subscription.subscribe.collapse") : t("subscription.subscribe.adjust")}</span>
        <ChevronRightIcon aria-hidden className={`size-3.5 shrink-0 text-[var(--text-faint)] transition-transform ${rangeExpanded ? "rotate-90" : ""}`} />
      </button>
      {capSeasons.length > 0 && <div className="space-y-2 border-t border-[var(--line)] px-4 py-3">
        {capSeasons.map((season) => <SeasonCapLine
          key={season.season_number}
          season={season}
          win={effectiveWindow(season, capDraft, airingOf(season.season_number))}
          airing={airingOf(season.season_number)}
          showName={selectedSeasons.size > 1}
          onChange={(next) => setCapDraft((prev) => ({ ...prev, [season.season_number]: next }))}
        />)}
      </div>}
      {rangeExpanded && <div className="border-t border-[var(--line)]">
        <div className="max-h-64 divide-y divide-white/[0.07] overflow-y-auto">
          {(prepared?.seasons ?? []).map((season) => <SeasonChoiceRow key={season.season_number} season={season} checked={selectedSeasons.has(season.season_number)} onToggle={() => toggleSeason(season.season_number)} />)}
        </div>
        <SheetToggleRow label={t("subscription.subscribe.followFuture")} description={t("subscription.subscribe.followFutureHint")} checked={followFuture} onChange={setFollowFuture} />
      </div>}
      {selectedSeasons.size === 0 && !followFuture && <p className="px-4 pb-3 text-sub text-[var(--warn)]">{t("subscription.subscribe.chooseScope")}</p>}
      {doubanEpisodes && <div className="border-t border-[var(--line)]">
        <SheetToggleRow
          label={t("subscription.subscribe.doubanCount", { count: doubanEpisodes.douban_count })}
          description={t("subscription.subscribe.doubanHint", { season: doubanEpisodes.season_number, count: doubanEpisodes.douban_count, tmdbCount: doubanEpisodes.tmdb_count })}
          checked={useDoubanEpisodes}
          onChange={setUseDoubanEpisodes}
        />
      </div>}
    </section>}

    {(!upgradeMode || canManageSubscriptions) && <section aria-label={t("subscription.subscribe.optionsLabel")}>
      <button type="button" aria-expanded={optionsOpen} onClick={() => setOptionsOpen((value) => !value)} className="flex min-h-11 w-full items-center gap-2 px-1 text-left text-sub text-[var(--text-muted)]">
        <span className="shrink-0">{t("subscription.subscribe.moreOptions")}</span>
        <span className="min-w-0 flex-1 truncate text-right text-caption">{pickedLibrary ? t("subscription.subscribe.storeIn", { name: pickedLibrary.name }) : t("subscription.subscribe.subscriptionMode")}</span>
        <ChevronRightIcon aria-hidden className={`size-3.5 shrink-0 transition-transform ${optionsOpen ? "rotate-90" : ""}`} />
      </button>
      {optionsOpen && <SheetSection footer={
        <>
          {showsRules && ruleRouted && ruleSetId === ruleRouted.ruleSetId && !pickedRule?.is_default && <p>{t("subscription.subscribe.rulesRouting")}</p>}
          {canManageSubscriptions && routed?.reason && libraryId === routed.libraryId && <p>{routed.reason}</p>}
        </>
      }>
        {!upgradeMode && <SheetMenuRow label={t("subscription.subscribe.selectionMode")} value={selectionMode} options={[{ value: "smart", label: t("subscription.subscribe.smartMode") }, { value: "rules", label: t("subscription.subscribe.rulesMode") }]} onChange={(value) => setSelectionMode(value as "smart" | "rules")} />}
        {showsRules && (selectableRules.length === 0 ? <SheetRow icon={<PlusIcon className="size-[18px]" />} label={upgradeMode ? t("subscription.subscribe.newUpgradeRules") : t("subscription.subscribe.newRules")} onClick={() => setCreatingRuleSet(true)} /> : <SheetMenuRow
          label={upgradeMode ? t("subscription.subscribe.upgradeRules") : t("subscription.subscribe.resourceRules")}
          value={ruleSetId === null ? "" : String(ruleSetId)}
          options={selectableRules.map((rule) => ({ value: String(rule.id), label: t("subscription.subscribe.defaultName", { name: ruleSetLabel(rule, locale), isDefault: rule.is_default ? "yes" : "no" }) }))}
          onChange={(value) => setRuleSetId(Number(value))}
          extra={<SheetMenuAction icon={<PlusIcon className="size-4" />} label={t("subscription.subscribe.newRulesMenu")} onSelect={() => setCreatingRuleSet(true)} />}
        >
          {chips.length > 0 && <span className="block text-caption leading-relaxed text-[var(--text-muted)]">{chips.join(" · ")}</span>}
        </SheetMenuRow>)}
        {canManageSubscriptions && libraries.length > 0 && <SheetMenuRow label={t("subscription.subscribe.library")} value={libraryId === null ? "" : String(libraryId)} options={libraries.map((library) => ({ value: String(library.id), label: t("subscription.subscribe.defaultName", { name: library.name, isDefault: library.is_default ? "yes" : "no" }) }))} onChange={(value) => setLibraryId(Number(value))} />}
      </SheetSection>}
    </section>}
    {dispatchPreview && !dispatchPreview.ok && <DispatchPreviewNote preview={dispatchPreview} />}
  </div>;

  // 叠在本弹层之上的二级弹窗（管理员取消订阅、快捷新建规则组）：桌面与手机两套形态共用
  const overlays = (
    <>
      {isAdmin && prepared?.existing_subscription_id && (
        <SubscriptionCancelDialog
          open={cancelling}
          raised
          subscriptionId={prepared.existing_subscription_id}
          title={prepared.media?.title ?? target?.title ?? ""}
          onClose={() => setCancelling(false)}
          onConfirm={confirmRemoval}
        />
      )}

      {canManageSubscriptions && creatingRuleSet && (
        <RuleSetEditorDialog
          ruleSet={null}
          raised
          onClose={() => setCreatingRuleSet(false)}
          onSaved={(saved) => {
            setCreatingRuleSet(false);
            setRuleSets((prev) => [...prev, saved]);
            // 洗版变体只接受带洗版目标的组；新组没配目标就不抢选中
            if (!upgradeMode || upgradeTargetLabel(saved.spec)) setRuleSetId(saved.id);
          }}
        />
      )}
    </>
  );

  if (upgradeReport) {
    return (
      <Modal
        open
        onClose={onClose}
        label={t("subscription.subscribe.dialogLabel", { title: target.title })}
        width="lg"
        panelClassName="max-h-[76dvh]"
      >
        {/* 报告态：自带标题与出口按钮，整体滚动即可 */}
        <div className="scroll-thin min-h-0 flex-1 overflow-y-auto p-6 max-md:p-5">
          <UpgradeRunReportView
            title={target.title}
            isMovie={(prepared?.media?.kind ?? target.kind) === "movie"}
            report={upgradeReport}
            onClose={onClose}
          />
        </div>
      </Modal>
    );
  }

  if (sheetForm) {
    return (
      <>
        <SheetScaffold
          onClose={onClose}
          title={upgradeMode ? t("subscription.subscribe.upgradeTitle") : t("subscription.subscribe.title")}
          label={t("subscription.subscribe.dialogLabel", { title: target.title })}
          confirm={
            showsForm
              ? {
                  label: upgradeMode ? t("subscription.subscribe.confirmUpgrade") : t("subscription.subscribe.confirm"),
                  enabled: canSubmit,
                  busy,
                  onConfirm: () => void submit(),
                }
              : undefined
          }
        >
          {mediaSummary}
          {!prepared && !error && <p className="flex items-center gap-2 text-sub text-[var(--text-muted)]"><BrandLoader className="size-4" />{t("subscription.subscribe.loading")}</p>}

          {error && <SheetNotice tone="error">{error}</SheetNotice>}

          {prepared?.status === "not_found" && (
            <SheetNotice>
              {t("subscription.subscribe.notFound")}
            </SheetNotice>
          )}

          {/* 豆瓣收敛歧义：候选海报墙不套卡片，直接铺在弹层上 */}
          {prepared?.status === "ambiguous" && (
            <section>
              <h3 className="mb-2 px-1 text-caption font-medium text-[var(--text-muted)]">
                {t("subscription.subscribe.ambiguousSheet")}
              </h3>
              <div className="grid grid-cols-3 gap-2.5">
                {prepared.candidates.map((c) => (
                  <button
                    key={c.tmdb_id}
                    type="button"
                    onClick={() => pickCandidate(c)}
                    className="text-left"
                  >
                    <div className="aspect-[2/3] overflow-hidden rounded-lg bg-[var(--poster-placeholder)] ring-1 ring-white/10">
                      <PosterImage
                        src={c.poster_url ? imageUrl(c.poster_url) : undefined}
                        // 三列候选，弹窗内约 140 宽
                        width={140}
                        alt={c.title}
                        className="size-full"
                      />
                    </div>
                    <p className="mt-1.5 truncate text-sub text-white/90">{c.title}</p>
                    <p className="truncate text-caption text-[var(--text-faint)]">
                      {c.year ?? t("subscription.subscribe.unknownYear")}
                    </p>
                  </button>
                ))}
              </div>
            </section>
          )}

          {/* 已订阅：管理态。关闭走左上 ✕；「取消订阅」单独一组红色垫底 */}
          {existingId && (
            <>
              <SheetSection>
                <SheetRow
                  icon={<CheckIcon className="size-[18px] text-[var(--ok)]" />}
                  label={t("subscription.subscribe.existing", { kind })}
                />
              </SheetSection>
              <SheetSection>
                {/* 洗版入口进到已有订阅：并入既有订阅（§13.4），去详情触发一轮 */}
                {upgradeMode && (
                  <SheetRow
                    icon={<UpgradeIcon className="size-[18px]" />}
                    label={t("subscription.subscribe.runUpgrade")}
                    chevron
                    onClick={() => {
                      onClose();
                      router.push(`/subscriptions/${existingId}?upgrade-run=1` as Route);
                    }}
                  />
                )}
                <SheetRow
                  icon={<ListIcon className="size-[18px]" />}
                  label={t("subscription.subscribe.viewDetails")}
                  chevron
                  onClick={() => {
                    onClose();
                    router.push(`/subscriptions/${existingId}` as Route);
                  }}
                />
              </SheetSection>
              <SheetSection>
                <SheetRow
                  destructive
                  icon={<TrashIcon className="size-[18px]" />}
                  label={t("subscription.subscribe.cancelSubscription")}
                  disabled={busy}
                  onClick={() => void unsubscribe()}
                />
              </SheetSection>
            </>
          )}

          {showsForm && subscriptionForm}
        </SheetScaffold>
        {overlays}
      </>
    );
  }

  return (
    <Modal
      open
      onClose={onClose}
      label={t("subscription.subscribe.dialogLabel", { title: target.title })}
      width="lg"
      panelClassName="max-h-[76dvh]"
    >
      {/* 头部常驻：剧集选季 + 规则摘要能滚很长，标题不该跟着走 */}
      <div className="border-b border-white/[0.07] px-6 pb-4 pt-6 max-md:px-5">
        <h2 className="text-title font-bold text-white">
          {upgradeMode ? t("subscription.subscribe.upgradeTitle") : t("subscription.subscribe.title")}
        </h2>
        {upgradeMode && (
          <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
            {t("subscription.subscribe.upgradeDescription")}
          </p>
        )}
      </div>

      <div className="scroll-thin min-h-0 flex-1 overflow-y-auto p-6 max-md:p-5">
          {mediaSummary}
          {/* —— 加载 / 错误 —— */}
          {!prepared && !error && (
            <div className="mt-8 flex items-center justify-center gap-2.5 pb-4 text-ui text-[var(--text-muted)]">
              <BrandLoader className="size-5" />
              {t("subscription.subscribe.loading")}
            </div>
          )}
          {error && (
            <p className="mt-4 rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2.5 text-ui leading-6 text-red-200">
              {error}
            </p>
          )}

          {/* —— 豆瓣收敛：未收录 —— */}
          {prepared?.status === "not_found" && (
            <p className="mt-4 text-ui leading-6 text-[var(--text-muted)]">
              {t("subscription.subscribe.notFound")}
            </p>
          )}

          {/* —— 豆瓣收敛：多候选确认 —— */}
          {prepared?.status === "ambiguous" && (
            <div className="mt-4">
              <p className="text-ui text-[var(--text-muted)]">
                {t("subscription.subscribe.ambiguous")}
              </p>
              <div className="mt-3 grid grid-cols-4 gap-3 max-md:grid-cols-3 max-md:gap-2">
                {prepared.candidates.map((c) => (
                  <button
                    key={c.tmdb_id}
                    type="button"
                    onClick={() => pickCandidate(c)}
                    className="group text-left"
                  >
                    <div className="aspect-[2/3] overflow-hidden rounded-lg bg-[var(--poster-placeholder)] ring-1 ring-white/10 transition group-hover:ring-white/40">
                      <PosterImage
                        src={c.poster_url ? imageUrl(c.poster_url) : undefined}
                        // 三列候选，弹窗内约 140 宽
                        width={140}
                        alt={c.title}
                        className="size-full"
                      />
                    </div>
                    <p className="mt-1.5 truncate text-sub text-white/90">{c.title}</p>
                    <p className="truncate text-caption text-[var(--text-faint)]">
                      {c.year ?? t("subscription.subscribe.unknownYear")}
                    </p>
                  </button>
                ))}
              </div>
            </div>
          )}

          {/* —— 已订阅：管理态 —— */}
          {prepared?.status === "ready" && prepared.existing_subscription_id && (
            <div className="mt-4">
              <p className="flex items-center gap-2 text-ui text-white/85">
                <CheckIcon className="size-4 text-[var(--ok)]" />
                {t("subscription.subscribe.existing", { kind: target.kind })}
              </p>
              <div className={`mt-5 flex justify-end gap-3 ${locale === "en" ? "flex-wrap" : ""}`}>
                <button
                  type="button"
                  onClick={onClose}
                  className="btn-glass h-9 px-4 text-ui font-medium"
                >
                  {t("subscription.subscribe.okay")}
                </button>
                {/* 洗版入口进到已有订阅：并入既有订阅（§13.4），去详情触发一轮 */}
                {upgradeMode && (
                  <button
                    type="button"
                    onClick={() => {
                      const id = prepared.existing_subscription_id;
                      onClose();
                      router.push(`/subscriptions/${id}?upgrade-run=1` as Route);
                    }}
                    className="btn-accent h-9 rounded-full px-4 text-ui font-semibold"
                  >
                    {t("subscription.subscribe.runUpgrade")}
                  </button>
                )}
                <button
                  type="button"
                  disabled={busy}
                  onClick={unsubscribe}
                  className="h-9 rounded-full border border-red-400/30 bg-red-500/10 px-4 text-ui font-medium text-red-200 transition hover:bg-red-500/20 disabled:opacity-50"
                >
                  {t("subscription.subscribe.cancelSubscription")}
                </button>
              </div>
            </div>
          )}

          {showsForm && <div className="mt-5">{subscriptionForm}</div>}
      </div>

      {/* 底栏常驻（仅订阅表单态；管理态的按钮短，留在正文里） */}
      {prepared?.status === "ready" && !prepared.existing_subscription_id && (
        <div className={`flex justify-end gap-3 border-t border-white/[0.07] px-6 py-4 max-md:px-5 ${locale === "en" ? "flex-wrap" : ""}`}>
          <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
            {t("common.cancel")}
          </button>
          <button
            type="button"
            disabled={!canSubmit}
            onClick={submit}
            className={`btn-accent rounded-full px-5 text-ui font-semibold disabled:opacity-50 ${locale === "en" ? "min-h-9 py-2" : "h-9"}`}
          >
            {busy
              ? upgradeMode
                ? t("subscription.subscribe.creatingUpgrade")
                : t("subscription.subscribe.creating")
              : upgradeMode
                ? t("subscription.subscribe.confirmUpgrade")
                : t("subscription.subscribe.confirm")}
          </button>
        </div>
      )}

      {overlays}
    </Modal>
  );
}

/** 季的展示文案：季名、播出进度、库存提示（桌面 SeasonRow 与手机 SeasonChoiceRow 共用）。 */
function seasonTexts(season: SeasonOverview, locale: AppLocale) {
  const t = appTranslator(locale);
  const total = season.episode_count ?? 0;
  const progress =
    season.aired_count >= total && total > 0
      ? t("subscription.subscribe.seasonComplete", { count: total })
      : total > 0
        ? t("subscription.subscribe.seasonProgress", { count: season.aired_count, total })
        : season.aired_count > 0
          ? t("subscription.subscribe.episodesAired", { count: season.aired_count })
          : t("subscription.subscribe.notAired");
  // 库存提示（媒体库联通）：已有的集不会重复下载
  const owned =
    season.owned_count > 0
      ? season.owned_count >= total && total > 0
        ? t("subscription.subscribe.seasonOwned")
        : t("subscription.subscribe.episodesOwned", { count: season.owned_count })
      : null;
  const name = season.season_number === 0 ? t("media.season.specials") : t("media.season.title", { number: season.season_number });
  return { name, progress, owned };
}

/** 季选择行：季名 + 播出进度；未播季弱化显示但可勾（勾了=要整季）。
 *  订阅弹窗与调整订阅弹窗（subscription-adjust-dialog）共用。 */
export function SeasonRow({
  season,
  checked,
  onToggle,
}: {
  season: SeasonOverview;
  checked: boolean;
  onToggle: () => void;
}) {
  const locale = useLocale();
  const { name, progress, owned } = seasonTexts(season, locale);
  return (
    <label
      className={`flex cursor-pointer items-center justify-between rounded-xl border px-4 py-2.5 transition ${
        checked
          ? "border-white/20 bg-white/[0.08]"
          : "border-white/[0.06] bg-white/[0.02] hover:bg-white/[0.05]"
      }`}
    >
      <span className={`flex items-baseline gap-2.5 ${locale === "en" ? "min-w-0 flex-wrap" : ""}`}>
        <span className="text-ui font-medium text-white/90">{name}</span>
        <span className="tnum text-caption text-[var(--text-faint)]">{progress}</span>
        {owned && (
          <span className="tnum text-caption font-medium text-[var(--ok)]/90">{owned}</span>
        )}
      </span>
      <input
        type="checkbox"
        checked={checked}
        onChange={onToggle}
        className="size-4 accent-[var(--accent-2)]"
      />
    </label>
  );
}

/** 手机表单弹层里的季行（对应 iOS SeasonPickRow）：季名 + 进度，右侧对勾表示勾选。
 *  订阅弹层与调整订阅弹层共用。 */
export function SeasonChoiceRow({
  season,
  checked,
  onToggle,
}: {
  season: SeasonOverview;
  checked: boolean;
  onToggle: () => void;
}) {
  const locale = useLocale();
  const { name, progress, owned } = seasonTexts(season, locale);
  return (
    <SheetChoiceRow
      label={name}
      detail={
        <span className="tnum flex flex-wrap gap-x-2">
          <span>{progress}</span>
          {owned && <span className="text-[var(--ok)]/90">{owned}</span>}
        </span>
      }
      selected={checked}
      onSelect={onToggle}
    />
  );
}

/** 入库配置有问题时直接提示，不把下载路径放进日常订阅表单。 */
function DispatchPreviewNote({ preview }: { preview: DispatchPreview }) {
  if (preview.ok || !preview.warning) return null;
  return <p role="alert" className="rounded-lg border border-amber-400/25 bg-amber-500/10 px-3 py-2 text-caption leading-relaxed text-amber-200">{preview.warning}</p>;
}
