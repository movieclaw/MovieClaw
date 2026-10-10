"use client";

import { useCallback, useEffect, useMemo, useState } from "react";

import type { Route } from "next";
import { useRouter } from "next/navigation";

import { BrandLoader } from "@/components/brand-loader";
import { SmartProfileCard } from "@/components/smart-subscription-settings";
import type { SmartProfile } from "@/lib/api/subscriptions";
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
import { imageUrl } from "@/lib/image-proxy";
import type { MediaType } from "@/lib/media-types";
import { usePermissions } from "@/lib/permissions";

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
const MEMBER_UPGRADE_RULE_HINT =
  "洗到哪一档由管理员在规则组里配置；若规则组还没有洗版目标，请联系管理员设置。";

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
  const { canManageSubscriptions, isAdmin } = usePermissions();
  const router = useRouter();
  // 银玻璃手机端走表单弹层（SheetScaffold，对齐 iOS SubscribeSheet）；桌面与 Netflix 保持原弹窗
  const sheetForm = useSheetForm();
  const upgradeMode = !!target?.upgradeIntent;
  const [prepared, setPrepared] = useState<PrepareResult | null>(null);
  // 洗版变体：创建成功后自动触发的一轮洗版报告（非空即进入报告段）
  const [upgradeReport, setUpgradeReport] = useState<UpgradeRunReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [ruleSets, setRuleSets] = useState<RuleSet[]>([]);
  const [libraries, setLibraries] = useState<MediaLibrary[]>([]);
  const [selectedSeasons, setSelectedSeasons] = useState<Set<number>>(new Set());
  const [followFuture, setFollowFuture] = useState(false);
  // 豆瓣集数多于 TMDB 时（issue #640）：用户确认后按豆瓣集数追，默认不改
  const [useDoubanEpisodes, setUseDoubanEpisodes] = useState(false);
  const [ruleSetId, setRuleSetId] = useState<number | null>(null);
  const [selectionMode, setSelectionMode] = useState<"smart" | "rules">("smart");
  const [smartProfile, setSmartProfile] = useState<SmartProfile | null>(null);
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
  }, [canManageSubscriptions, routingKind, libraryId, prepared?.media]);

  /** 预检并按结果初始化表单默认值（候选确认后会带着 tmdbId 再次进入）。 */
  const runPrepare = useCallback(
    async (t: SubscribeTarget) => {
      setSelectionMode(t.upgradeIntent ? "rules" : "smart");
      setSmartProfile(null);
      setOptionsOpen(!!t.upgradeIntent);
      setRangeExpanded(false);
      setPrepared(null);
      setError(null);
      setUpgradeReport(null);
      try {
        // 规则组是超管的配置知识（GET /rule-sets 仅超管）：成员一律不拉列表、
        // 不选组，洗版变体也按订阅当前的规则组洗（后端忽略成员传的 rule_set_id）
        const [result, rules, initialLibs] = await Promise.all([
          previewSubscriptionTitle({ title_ref: t.titleRef }),
          canManageSubscriptions ? listRuleSets() : Promise.resolve([]),
          // 媒体库列表与预检并行拉，少等一个往返：TMDB 引用的类型是确定的，
          // 只有豆瓣引用偶尔会被后端收敛成另一类型，那时再按 canonical kind 补拉
          canManageSubscriptions ? listLibraries(t.kind) : Promise.resolve([]),
        ]);
        // 豆瓣条目可能没有可靠的前端类型；媒体库和投递路由必须以后端
        // 收敛后的 canonical kind 为准，避免电影/剧集选到错误的库。
        const resolvedKind = result.media?.kind ?? t.kind;
        const libs =
          !canManageSubscriptions || resolvedKind === t.kind
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
        const candidates = t.upgradeIntent
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
        const defaultSeasons = t.upgradeIntent
          ? result.seasons.filter((s) => s.owned_count > 0).map((s) => s.season_number)
          : suggested.length > 0
            ? suggested
            : result.seasons
                .filter((s) => s.season_number > 0 && s.aired_count > 0)
                .map((s) => s.season_number);
        setSelectedSeasons(new Set(defaultSeasons));
        setRangeExpanded(defaultSeasons.length === 0 && result.media?.status !== "Returning Series");
        setFollowFuture(
          !t.upgradeIntent &&
            resolvedKind === "tv" &&
            result.media?.status === "Returning Series",
        );
      } catch (e) {
        setError(e instanceof Error ? e.message : "预检失败，请稍后重试");
      }
    },
    [canManageSubscriptions],
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

  const submit = async () => {
    if (!target || !prepared?.media) return;
    setBusy(true);
    setError(null);
    try {
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
        smart_profile_revision: selectionMode === "smart" ? smartProfile?.revision : undefined,
        library_id: canManageSubscriptions ? libraryId : null,
        ...(doubanEpisodes && useDoubanEpisodes
          ? { episode_floors: { [doubanEpisodes.season_number]: doubanEpisodes.douban_count } }
          : {}),
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
          setError(
            `订阅已创建，但触发洗版失败：${
              e instanceof Error ? e.message : "请稍后到订阅详情里重试"
            }`,
          );
        }
        return;
      }
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : "订阅失败，请稍后重试");
    } finally {
      setBusy(false);
    }
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
      setError(e instanceof Error ? e.message : "取消订阅失败");
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
      setError(e instanceof Error ? e.message : "取消订阅失败");
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
    if (selectionMode === "smart" && (!smartProfile?.preferences || smartProfile.kind !== prepared.media.kind)) return false;
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
    smartProfile,
  ]);

  if (!target) return null;

  const media = prepared?.media;
  const kind = media?.kind ?? target.kind;
  const existingId = prepared?.status === "ready" ? prepared.existing_subscription_id : null;
  const showsForm = prepared?.status === "ready" && !existingId;
  const showsRules = selectionMode === "rules" && canManageSubscriptions;
  const pickedRule = selectableRules.find((r) => r.id === ruleSetId);
  const chips = pickedRule ? specSummary(pickedRule.spec) : [];
  const pickedLibrary = libraries.find((l) => l.id === libraryId);
  const seasonNames = [...selectedSeasons].sort((a, b) => a - b).map((n) => n === 0 ? "特别篇" : `第 ${n} 季`);
  const rangeSummary = seasonNames.length > 3 ? `已选 ${seasonNames.length} 季` : seasonNames.join("、");

  const mediaSummary = <div className="flex items-center gap-3.5 px-1">
    <div className="h-[84px] w-14 shrink-0 overflow-hidden rounded-lg bg-white/[0.06] ring-1 ring-inset ring-white/10">
      <PosterImage src={media?.poster_url ? imageUrl(media.poster_url) : undefined} width={56} alt={media?.title ?? target.title} className="size-full object-cover" />
    </div>
    <div className="min-w-0 flex-1">
      <p className="line-clamp-2 text-title-sm font-semibold text-white">{media?.title ?? target.title}</p>
      <p className="mt-1 text-sub text-[var(--text-muted)]">{[media?.year ?? target.year, kind === "movie" ? "电影" : "剧集"].filter(Boolean).join(" · ")}</p>
      {showsForm && prepared?.movie_owned && <p className="mt-1.5 flex items-center gap-1 text-caption text-[var(--ok)]">
        <CheckIcon className="size-3.5 shrink-0" />
        {upgradeMode ? "媒体库已有，将按需洗版" : "媒体库已有，不会重复下载"}
      </p>}
    </div>
  </div>;

  // 桌面与手机共用同一份订阅信息层级，低频选项只在用户展开时显示。
  const subscriptionForm = <div className="space-y-4">
    {selectionMode === "smart" ? (
      <SmartProfileCard kind={kind} onSaved={setSmartProfile} compact />
    ) : (
      <section className="rounded-2xl border border-[var(--line)] bg-[var(--surface-inset)] p-4" aria-label="规则选择">
        <div className="flex items-center justify-between gap-3">
          <h3 className="text-sub text-[var(--text-muted)]">{upgradeMode ? "洗版规则" : "规则模式"}</h3>
          {canManageSubscriptions && <button type="button" className="min-h-11 -my-2 -mr-2 px-2 text-sub text-[var(--accent)]" onClick={() => setOptionsOpen(true)}>修改规则</button>}
        </div>
        <p className="mt-2 text-body font-semibold text-[var(--text)]">{pickedRule?.name ?? "按系统规则选择"}</p>
        {upgradeMode && <p className="mt-2 text-sub text-[var(--text-muted)]">{pickedRule ? `洗到 ${upgradeTargetLabel(pickedRule.spec)}` : MEMBER_UPGRADE_RULE_HINT}</p>}
        {pickedRule && chips.length === 0 && <p className="mt-2 text-sub text-[var(--warn)]">当前规则不限品质，可能选到低画质资源。</p>}
      </section>
    )}

    {kind === "tv" && <section className="overflow-hidden rounded-2xl border border-[var(--line)]" aria-label="追踪范围">
      <button type="button" aria-expanded={rangeExpanded} onClick={() => setRangeExpanded((value) => !value)} className="flex w-full items-center gap-3 p-4 text-left">
        <span className="min-w-0 flex-1">
          <span className="block text-sub text-[var(--text-muted)]">追踪范围</span>
          <span className="mt-1 block text-ui font-medium text-[var(--text)]">{rangeSummary || (followFuture ? "仅追新集" : "选择要收录的季")}</span>
          <span className="mt-1 block text-caption text-[var(--text-muted)]">{followFuture ? "自动追踪新集和新季" : "仅收录所选季"}</span>
        </span>
        <span className="text-sub text-[var(--text-muted)]">{rangeExpanded ? "收起" : "调整"}</span>
        <ChevronRightIcon aria-hidden className={`size-3.5 shrink-0 text-[var(--text-faint)] transition-transform ${rangeExpanded ? "rotate-90" : ""}`} />
      </button>
      {rangeExpanded && <div className="border-t border-[var(--line)]">
        <div className="max-h-64 divide-y divide-white/[0.07] overflow-y-auto">
          {(prepared?.seasons ?? []).map((season) => <SeasonChoiceRow key={season.season_number} season={season} checked={selectedSeasons.has(season.season_number)} onToggle={() => toggleSeason(season.season_number)} />)}
        </div>
        <SheetToggleRow label="自动续订" description="新集与新季自动加入追踪" checked={followFuture} onChange={setFollowFuture} />
      </div>}
      {selectedSeasons.size === 0 && !followFuture && <p className="px-4 pb-3 text-sub text-[var(--warn)]">请选择至少一季，或开启自动续订。</p>}
      {doubanEpisodes && <div className="border-t border-[var(--line)]">
        <SheetToggleRow
          label={`按豆瓣集数追（${doubanEpisodes.douban_count} 集）`}
          description={`豆瓣显示第 ${doubanEpisodes.season_number} 季共 ${doubanEpisodes.douban_count} 集，TMDB 只录了 ${doubanEpisodes.tmdb_count} 集；打开后超出部分先占位追踪`}
          checked={useDoubanEpisodes}
          onChange={setUseDoubanEpisodes}
        />
      </div>}
    </section>}

    {(!upgradeMode || canManageSubscriptions) && <section aria-label="更多订阅选项">
      <button type="button" aria-expanded={optionsOpen} onClick={() => setOptionsOpen((value) => !value)} className="flex min-h-11 w-full items-center gap-2 px-1 text-left text-sub text-[var(--text-muted)]">
        <span className="shrink-0">更多选项</span>
        <span className="min-w-0 flex-1 truncate text-right text-caption">{pickedLibrary ? `存入「${pickedLibrary.name}」` : "订阅方式"}</span>
        <ChevronRightIcon aria-hidden className={`size-3.5 shrink-0 transition-transform ${optionsOpen ? "rotate-90" : ""}`} />
      </button>
      {optionsOpen && <SheetSection footer={
        <>
          {showsRules && ruleRouted && ruleSetId === ruleRouted.ruleSetId && !pickedRule?.is_default && <p>按适用范围自动选择规则组</p>}
          {canManageSubscriptions && routed?.reason && libraryId === routed.libraryId && <p>{routed.reason}</p>}
        </>
      }>
        {!upgradeMode && <SheetMenuRow label="选择方式" value={selectionMode} options={[{ value: "smart", label: "智能选择" }, { value: "rules", label: "规则模式" }]} onChange={(value) => setSelectionMode(value as "smart" | "rules")} />}
        {showsRules && (selectableRules.length === 0 ? <SheetRow icon={<PlusIcon className="size-[18px]" />} label={upgradeMode ? "新建带洗版目标的规则组" : "新建规则组"} onClick={() => setCreatingRuleSet(true)} /> : <SheetMenuRow
          label={upgradeMode ? "洗版规则" : "资源规则"}
          value={ruleSetId === null ? "" : String(ruleSetId)}
          options={selectableRules.map((rule) => ({ value: String(rule.id), label: `${rule.name}${rule.is_default ? "（默认）" : ""}` }))}
          onChange={(value) => setRuleSetId(Number(value))}
          extra={<SheetMenuAction icon={<PlusIcon className="size-4" />} label="新建规则组…" onSelect={() => setCreatingRuleSet(true)} />}
        >
          {chips.length > 0 && <span className="block text-caption leading-relaxed text-[var(--text-muted)]">{chips.join(" · ")}</span>}
        </SheetMenuRow>)}
        {canManageSubscriptions && libraries.length > 0 && <SheetMenuRow label="入库到" value={libraryId === null ? "" : String(libraryId)} options={libraries.map((library) => ({ value: String(library.id), label: `${library.name}${library.is_default ? "（默认）" : ""}` }))} onChange={(value) => setLibraryId(Number(value))} />}
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
        label={`订阅《${target.title}》`}
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
          title={upgradeMode ? "订阅并洗版" : "订阅追踪"}
          label={`订阅《${target.title}》`}
          confirm={
            showsForm
              ? {
                  label: upgradeMode ? "订阅并开始洗版" : "确认订阅",
                  enabled: canSubmit,
                  busy,
                  onConfirm: () => void submit(),
                }
              : undefined
          }
        >
          {mediaSummary}
          {!prepared && !error && <p className="flex items-center gap-2 text-sub text-[var(--text-muted)]"><BrandLoader className="size-4" />正在获取条目信息…</p>}

          {error && <SheetNotice tone="error">{error}</SheetNotice>}

          {prepared?.status === "not_found" && (
            <SheetNotice>
              TMDB 未收录该条目，暂时无法订阅。订阅依赖 TMDB
              的别名与季集数据来匹配站点资源，可尝试在 TMDB 搜索入口确认条目后再订阅。
            </SheetNotice>
          )}

          {/* 豆瓣收敛歧义：候选海报墙不套卡片，直接铺在弹层上 */}
          {prepared?.status === "ambiguous" && (
            <section>
              <h3 className="mb-2 px-1 text-caption font-medium text-[var(--text-muted)]">
                找到多个可能的条目，请确认你订阅的是哪一部
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
                      {c.year ?? "年份未知"}
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
                  label={`该${kind === "movie" ? "电影" : "剧集"}已在订阅中，movieclaw 正在持续追踪资源。`}
                />
              </SheetSection>
              <SheetSection>
                {/* 洗版入口进到已有订阅：并入既有订阅（§13.4），去详情触发一轮 */}
                {upgradeMode && (
                  <SheetRow
                    icon={<UpgradeIcon className="size-[18px]" />}
                    label="去洗一轮版"
                    chevron
                    onClick={() => {
                      onClose();
                      router.push(`/subscriptions/${existingId}?upgrade-run=1` as Route);
                    }}
                  />
                )}
                <SheetRow
                  icon={<ListIcon className="size-[18px]" />}
                  label="查看订阅详情"
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
                  label="取消订阅"
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
      label={`订阅《${target.title}》`}
      width="lg"
      panelClassName="max-h-[76dvh]"
    >
      {/* 头部常驻：剧集选季 + 规则摘要能滚很长，标题不该跟着走 */}
      <div className="border-b border-white/[0.07] px-6 pb-4 pt-6 max-md:px-5">
        <h2 className="text-title font-bold text-white">
          {upgradeMode ? "订阅并洗版" : "订阅追踪"}
        </h2>
        {upgradeMode && (
          <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
            洗版通过订阅持续追踪更好的版本：确认后建立订阅并立即体检库里已有的每一集。
          </p>
        )}
      </div>

      <div className="scroll-thin min-h-0 flex-1 overflow-y-auto p-6 max-md:p-5">
          {mediaSummary}
          {/* —— 加载 / 错误 —— */}
          {!prepared && !error && (
            <div className="mt-8 flex items-center justify-center gap-2.5 pb-4 text-ui text-[var(--text-muted)]">
              <BrandLoader className="size-5" />
              正在获取条目信息…
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
              TMDB 未收录该条目，暂时无法订阅。订阅依赖 TMDB
              的别名与季集数据来匹配站点资源，可尝试在 TMDB 搜索入口确认条目后再订阅。
            </p>
          )}

          {/* —— 豆瓣收敛：多候选确认 —— */}
          {prepared?.status === "ambiguous" && (
            <div className="mt-4">
              <p className="text-ui text-[var(--text-muted)]">
                找到多个可能的条目，请确认你订阅的是哪一部：
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
                      {c.year ?? "年份未知"}
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
                该{target.kind === "movie" ? "电影" : "剧集"}已在订阅中，movieclaw
                正在持续追踪资源。
              </p>
              <div className="mt-5 flex justify-end gap-3">
                <button
                  type="button"
                  onClick={onClose}
                  className="btn-glass h-9 px-4 text-ui font-medium"
                >
                  好的
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
                    去洗一轮版
                  </button>
                )}
                <button
                  type="button"
                  disabled={busy}
                  onClick={unsubscribe}
                  className="h-9 rounded-full border border-red-400/30 bg-red-500/10 px-4 text-ui font-medium text-red-200 transition hover:bg-red-500/20 disabled:opacity-50"
                >
                  取消订阅
                </button>
              </div>
            </div>
          )}

          {showsForm && <div className="mt-5">{subscriptionForm}</div>}
      </div>

      {/* 底栏常驻（仅订阅表单态；管理态的按钮短，留在正文里） */}
      {prepared?.status === "ready" && !prepared.existing_subscription_id && (
        <div className="flex justify-end gap-3 border-t border-white/[0.07] px-6 py-4 max-md:px-5">
          <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
            取消
          </button>
          <button
            type="button"
            disabled={!canSubmit}
            onClick={submit}
            className="btn-accent h-9 rounded-full px-5 text-ui font-semibold disabled:opacity-50"
          >
            {busy
              ? upgradeMode
                ? "正在订阅并体检…"
                : "正在订阅…"
              : upgradeMode
                ? "订阅并开始洗版"
                : "确认订阅"}
          </button>
        </div>
      )}

      {overlays}
    </Modal>
  );
}

/** 季的展示文案：季名、播出进度、库存提示（桌面 SeasonRow 与手机 SeasonChoiceRow 共用）。 */
function seasonTexts(season: SeasonOverview) {
  const total = season.episode_count ?? 0;
  const progress =
    season.aired_count >= total && total > 0
      ? `全 ${total} 集已播完`
      : total > 0
        ? `已播 ${season.aired_count}/${total} 集`
        : season.aired_count > 0
          ? `已播 ${season.aired_count} 集`
          : "未播出";
  // 库存提示（媒体库联通）：已有的集不会重复下载
  const owned =
    season.owned_count > 0
      ? season.owned_count >= total && total > 0
        ? "整季已在库"
        : `库里已有 ${season.owned_count} 集`
      : null;
  const name = season.season_number === 0 ? "特别篇" : `第 ${season.season_number} 季`;
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
  const { name, progress, owned } = seasonTexts(season);
  return (
    <label
      className={`flex cursor-pointer items-center justify-between rounded-xl border px-4 py-2.5 transition ${
        checked
          ? "border-white/20 bg-white/[0.08]"
          : "border-white/[0.06] bg-white/[0.02] hover:bg-white/[0.05]"
      }`}
    >
      <span className="flex items-baseline gap-2.5">
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
  const { name, progress, owned } = seasonTexts(season);
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
