"use client";

import { useEffect, useMemo, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { appTranslator, type AppMessageKey } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";
import { ruleSetLabel } from "@/lib/rule-set-label";

import { MediaSourceAnnotationDialog } from "@/components/media-source-annotation-dialog";
import { PlusIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import { RuleSetEditorDialog, upgradeTargetLabel } from "@/components/rule-sets-panel";
import {
  SheetChoiceRow,
  SheetNotice,
  SheetRow,
  SheetScaffold,
  SheetSection,
  useSheetForm,
} from "@/components/sheet-scaffold";
import {
  listRuleSets,
  runSubscriptionUpgradeRound,
  setSubscriptionTrackingState,
  updateSubscription,
  type RuleSet,
  type SubscriptionDetail,
  type UpgradeRunReport,
  type UpgradeRunUnit,
} from "@/lib/api/subscriptions";
import { seasonsNeedingAnnotation } from "@/lib/media-source-annotation";
import { usePermissions } from "@/lib/permissions";

/**
 * 「洗一轮版」弹层（quality-upgrade.md §13.4/§13.5）：手动洗版的统一确认层。
 *
 * 两段式：确认段 → 报告段。确认段把既有订阅的三种状态并成一条动线：
 *   - 规则组未配洗版目标 → 必须先选一个带洗版目标的组（含快捷新建入口），
 *     「选组 + 触发」由后端 upgrade-runs 的 rule_set_id 参数合成一次调用；
 *   - 库里有文件但不在订阅范围的季 → 如实列出供勾选并入（扩大范围会连带
 *     补缺下载，是用户决策，不静默纳入）；
 *   - 订阅已暂停 → 提示并改为「恢复并触发」。
 * 成员分支：规则组是超管的配置知识（GET /rule-sets 仅超管），成员不拉列表、
 * 不选组，一律按订阅当前的规则组洗版（后端也会忽略成员传来的 rule_set_id）。
 * 报告段渲染后端体检快照（摘要句 + 按季分组的单元徽标），不落库、不轮询——
 * 后续进展看追踪明细的「洗版中」徽标与活动流水。
 */
export function UpgradeRunDialog({
  detail,
  onClose,
  onFinished,
}: {
  detail: SubscriptionDetail;
  onClose: () => void;
  /** 一轮洗版已触发成功（报告已看完关闭弹层）后回调，父组件刷新详情 */
  onFinished: () => void;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const { canManageSubscriptions } = usePermissions();
  const sheetForm = useSheetForm();
  const isMovie = detail.media.kind === "movie";
  const isSmart = detail.selection_mode === "smart";
  const [ruleSets, setRuleSets] = useState<RuleSet[] | null>(null);
  const [ruleSetId, setRuleSetId] = useState<number | null>(null);
  const [creatingRuleSet, setCreatingRuleSet] = useState(false);
  // 范围外但库里有文件的季：默认不勾（并入会连带补缺下载）
  const [optedSeasons, setOptedSeasons] = useState<Set<number>>(new Set());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useMessageState();
  const [report, setReport] = useState<UpgradeRunReport | null>(null);

  useEffect(() => {
    // 成员不拉规则组列表（超管接口），直接按订阅现用组洗版
    if (!canManageSubscriptions || isSmart) return;
    listRuleSets()
      .then((rules) => {
        setRuleSets(rules);
        // 现用组已配洗版目标 → 预选它（主场景零选择）；否则若只有一个可选组也预选
        const current = rules.find((r) => r.id === detail.rule_set_id);
        if (current && upgradeTargetLabel(current.spec)) {
          setRuleSetId(current.id);
        } else {
          const candidates = rules.filter((r) => upgradeTargetLabel(r.spec));
          setRuleSetId(candidates.length === 1 ? candidates[0].id : null);
        }
      })
      .catch(() => setError({ key: "subscription.upgrade.loadFailed" }));
  }, [canManageSubscriptions, detail.rule_set_id, isSmart, setError]);

  const upgradeRules = useMemo(
    () => (ruleSets ?? []).filter((r) => upgradeTargetLabel(r.spec)),
    [ruleSets],
  );
  const currentHasTarget = useMemo(() => {
    const current = (ruleSets ?? []).find((r) => r.id === detail.rule_set_id);
    return !!current && !!upgradeTargetLabel(current.spec);
  }, [ruleSets, detail.rule_set_id]);

  // 库里有文件但不在订阅范围的季（如只订了 S2、库里还有 S1）
  const outOfScopeOwned = useMemo(
    () =>
      isMovie
        ? []
        : detail.season_collection.filter(
            (s) => s.owned_count > 0 && !detail.selected_seasons.includes(s.season_number),
          ),
    [isMovie, detail.season_collection, detail.selected_seasons],
  );

  const paused = detail.status === "paused";
  const selectedRule = upgradeRules.find((r) => r.id === ruleSetId) ?? null;
  // 超管须选定一个带洗版目标的组；成员沿用订阅现用组，无需选择即可触发
  const canRun = isSmart ? !!detail.smart_policy?.allow_upgrade : !canManageSubscriptions || !!selectedRule;

  const run = async () => {
    if (!canRun) return;
    setBusy(true);
    setError(null);
    try {
      // 并入勾选的范围外季（既有 PATCH，后端 diff 生成补缺工单）
      if (optedSeasons.size > 0) {
        await updateSubscription(detail.id, {
          selected_seasons: [...detail.selected_seasons, ...optedSeasons].sort(
            (a, b) => a - b,
          ),
        });
      }
      if (paused) await setSubscriptionTrackingState(detail.id, "active");
      setReport(
        await runSubscriptionUpgradeRound(
          detail.id,
          selectedRule && selectedRule.id !== detail.rule_set_id ? selectedRule.id : undefined,
        ),
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.upgrade.runFailed" });
    } finally {
      setBusy(false);
    }
  };

  // 快捷新建规则组（叠在本弹层之上）：桌面与手机两套形态共用
  const ruleSetEditor = creatingRuleSet && (
    <RuleSetEditorDialog
      ruleSet={null}
      raised
      onClose={() => setCreatingRuleSet(false)}
      onSaved={(saved) => {
        setCreatingRuleSet(false);
        setRuleSets((prev) => [...(prev ?? []), saved]);
        // 新建组带洗版目标时自动选中它（快捷新建的动机就是没得选）
        if (upgradeTargetLabel(saved.spec)) setRuleSetId(saved.id);
      }}
    />
  );

  const toggleOpted = (n: number) =>
    setOptedSeasons((prev) => {
      const next = new Set(prev);
      if (next.has(n)) next.delete(n);
      else next.add(n);
      return next;
    });

  // 银玻璃手机端确认段：表单弹层（对齐 iOS UpgradeRunSheet）——触发放头部 ✓，
  // 规则组是对勾单选行、「新建规则组…」是组内末行，范围外库存季是对勾多选行。
  // 报告段内容长且自带出口，仍走下方原弹窗
  if (sheetForm && !report) {
    return (
      <>
        <SheetScaffold
          onClose={onClose}
          title={t("subscription.upgrade.title")}
          subtitle={t("subscription.upgrade.description", { title: detail.media.title })}
          confirm={{
            label: paused ? t("subscription.upgrade.resume") : t("subscription.upgrade.start"),
            enabled: canRun,
            busy,
            onConfirm: () => void run(),
          }}
        >
          {error && <SheetNotice tone="error">{error}</SheetNotice>}
          {paused && (
            <SheetNotice tone="warn">{t("subscription.upgrade.pausedHint")}</SheetNotice>
          )}
          {isSmart ? (
            <p className="p-3 text-sub text-[var(--text-muted)]">{t("subscription.upgrade.smartDescription", { enabled: detail.smart_policy?.allow_upgrade ? "yes" : "no" })}</p>
          ) : !canManageSubscriptions ? (
            <SheetSection title={t("subscription.upgrade.target")} footer={t(MEMBER_RULE_SET_HINT_KEY)}>
              <SheetRow label={t("subscription.upgrade.currentRules")} />
            </SheetSection>
          ) : (
            <SheetSection
              title={t("subscription.upgrade.target")}
              footer={
                ruleSets === null
                  ? null
                  : upgradeRules.length === 0
                    ? t("subscription.upgrade.noRulesHint")
                    : !currentHasTarget &&
                      t("subscription.upgrade.chooseRulesHint")
              }
            >
              {ruleSets === null ? (
                <SheetRow label={<span className="text-[var(--text-muted)]">{t("subscription.upgrade.loadingRules")}</span>} />
              ) : (
                <>
                  {upgradeRules.map((rs) => (
                    <SheetChoiceRow
                      key={rs.id}
                      label={t("subscription.upgrade.namedRules", { name: ruleSetLabel(rs, locale), current: rs.id === detail.rule_set_id ? "yes" : "no" })}
                      detail={t("subscription.upgrade.upgradeTo", { target: upgradeTargetLabel(rs.spec, locale) ?? "" })}
                      selected={rs.id === ruleSetId}
                      disabled={busy}
                      onSelect={() => setRuleSetId(rs.id)}
                    />
                  ))}
                  <SheetRow
                    icon={<PlusIcon className="size-[18px]" />}
                    label={t("subscription.upgrade.newRules")}
                    onClick={() => setCreatingRuleSet(true)}
                  />
                </>
              )}
            </SheetSection>
          )}
          {outOfScopeOwned.length > 0 && (
            <SheetSection
              title={t("subscription.upgrade.outsideSeasons")}
              footer={t("subscription.upgrade.outsideHint")}
            >
              {outOfScopeOwned.map((s) => (
                <SheetChoiceRow
                  key={s.season_number}
                  label={s.season_number === 0 ? t("media.season.specials") : t("media.season.title", { number: s.season_number })}
                  detail={t("subscription.upgrade.owned", { count: s.owned_count, total: s.episode_count ?? 0, hasTotal: s.episode_count != null && s.owned_count < s.episode_count ? "yes" : "no" })}
                  selected={optedSeasons.has(s.season_number)}
                  disabled={busy}
                  onSelect={() => toggleOpted(s.season_number)}
                />
              ))}
            </SheetSection>
          )}
        </SheetScaffold>
        {ruleSetEditor}
      </>
    );
  }

  return (
    <Modal
      open
      onClose={report ? onFinished : onClose}
      label={t("subscription.upgrade.title")}
      width="lg"
      panelClassName="max-h-[80dvh]"
    >
      {report ? (
        // 报告态：自带标题与出口按钮，整体滚动即可
        <div className="scroll-thin min-h-0 flex-1 overflow-y-auto p-6 max-md:p-5">
          <UpgradeRunReportView
            title={detail.media.title}
            isMovie={isMovie}
            report={report}
            mediaItemId={detail.media.media_item_id}
            onAnnotated={async () => {
              // 标注已刷新快照：重跑一轮体检，报告当场翻新（排期一并完成）
              setReport(await runSubscriptionUpgradeRound(detail.id));
            }}
            onClose={onFinished}
          />
        </div>
      ) : (
        // 触发态：规则组一多就得滚，标题与「开始体检」固定在两头
        <>
          <div className="border-b border-white/[0.07] px-6 pb-4 pt-6 max-md:px-5">
            <h2 className="text-title font-bold text-white">{t("subscription.upgrade.title")}</h2>
            <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
              {t("subscription.upgrade.description", { title: detail.media.title })}
            </p>
          </div>

          <div className="scroll-thin min-h-0 flex-1 overflow-y-auto p-6 max-md:p-5">
            {error && (
              <p className="mt-3 rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2.5 text-sub leading-6 text-red-200">
                {error}
              </p>
            )}

            {paused && (
              <p className="mt-3 rounded-lg border border-amber-300/25 bg-amber-400/10 px-3.5 py-2.5 text-sub leading-6 text-amber-100/90">
                {t("subscription.upgrade.pausedHint")}
              </p>
            )}

            {/* —— 规则组（洗版目标住在规则组上；只列带洗版目标的组）—— */}
            <div className="mt-4">
              <p className="text-sub font-semibold text-white/85">{t("subscription.upgrade.target")}</p>
              {isSmart ? (
            <p className="p-3 text-sub text-[var(--text-muted)]">{t("subscription.upgrade.smartDescription", { enabled: detail.smart_policy?.allow_upgrade ? "yes" : "no" })}</p>
          ) : !canManageSubscriptions ? (
                <div className="mt-2 rounded-xl border border-white/[0.08] bg-white/[0.03] px-4 py-3 text-sub leading-6 text-[var(--text-muted)]">
                  <span className="font-medium text-white/85">{t("subscription.upgrade.currentRulesSentence")}</span>
                  {t(MEMBER_RULE_SET_HINT_KEY)}
                </div>
              ) : ruleSets === null ? (
                <p className="mt-2 text-sub text-[var(--text-muted)]">{t("subscription.upgrade.loadingRules")}</p>
              ) : upgradeRules.length === 0 ? (
                <div className="mt-2 rounded-xl border border-white/[0.08] bg-white/[0.03] px-4 py-3 text-sub leading-6 text-[var(--text-muted)]">
                  {t("subscription.upgrade.noRules")}
                  <button
                    type="button"
                    onClick={() => setCreatingRuleSet(true)}
                    className="ml-1 font-medium text-[var(--accent-2)] hover:underline"
                  >
                    {t("subscription.upgrade.addRules")}
                  </button>
                </div>
              ) : (
                <div className="mt-2 space-y-1.5">
                  {!currentHasTarget && (
                    <p className="mb-2 text-sub leading-6 text-[var(--text-muted)]">
                      {t("subscription.upgrade.chooseRulesHint")}
                    </p>
                  )}
                  {upgradeRules.map((rs) => {
                    const picked = rs.id === ruleSetId;
                    return (
                      <button
                        key={rs.id}
                        type="button"
                        disabled={busy}
                        onClick={() => setRuleSetId(rs.id)}
                        className={`flex w-full items-center gap-2.5 rounded-xl border px-4 py-2.5 text-left transition disabled:opacity-50 ${locale === "en" ? "flex-wrap" : ""} ${
                          picked
                            ? "border-[#2dd4bf]/40 bg-[#2dd4bf]/[0.08]"
                            : "border-white/[0.08] bg-white/[0.03] hover:bg-white/[0.07]"
                        }`}
                      >
                        <span className="min-w-0 flex-1 truncate text-ui font-medium text-white/90">
                          {ruleSetLabel(rs, locale)}
                          {rs.id === detail.rule_set_id && (
                            <span className="ml-2 text-caption font-normal text-[var(--text-faint)]">
                              {t("subscription.upgrade.currentBadge")}
                            </span>
                          )}
                        </span>
                        <span className={`shrink-0 rounded-md bg-[#2dd4bf]/15 px-1.5 py-0.5 text-caption font-medium text-[#2dd4bf] ${locale === "en" ? "basis-full" : ""}`}>
                          {t("subscription.upgrade.upgradeTo", { target: upgradeTargetLabel(rs.spec, locale) ?? "" })}
                        </span>
                      </button>
                    );
                  })}
                  <button
                    type="button"
                    onClick={() => setCreatingRuleSet(true)}
                    className="w-full rounded-xl border border-dashed border-white/[0.14] px-4 py-2 text-left text-sub text-[var(--text-muted)] transition hover:border-white/25 hover:text-white/80"
                  >
                    {t("subscription.upgrade.addRules")}
                  </button>
                </div>
              )}
            </div>

            {/* —— 范围外的库存季：如实展示，勾选才并入（会连带补缺）—— */}
            {outOfScopeOwned.length > 0 && (
              <div className="mt-4">
                <p className="text-sub font-semibold text-white/85">{t("subscription.upgrade.outsideSeasons")}</p>
                <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
                  {t("subscription.upgrade.outsideHint")}
                </p>
                <div className="mt-2 flex flex-wrap gap-1.5">
                  {outOfScopeOwned.map((s) => {
                    const picked = optedSeasons.has(s.season_number);
                    return (
                      <button
                        key={s.season_number}
                        type="button"
                        disabled={busy}
                        aria-pressed={picked}
                        onClick={() => toggleOpted(s.season_number)}
                        className={`rounded-full border px-3 py-1.5 text-sub transition disabled:opacity-50 ${
                          picked
                            ? "border-[#2dd4bf]/40 bg-[#2dd4bf]/[0.12] text-white"
                            : "border-white/[0.1] bg-white/[0.03] text-white/70 hover:bg-white/[0.07]"
                        }`}
                      >
                        {s.season_number === 0 ? t("media.season.specials") : t("media.season.title", { number: s.season_number })}
                        <span className="tnum ml-1.5 text-caption text-[var(--text-faint)]">
                          {t("subscription.upgrade.owned", { count: s.owned_count, total: s.episode_count ?? 0, hasTotal: s.episode_count != null && s.owned_count < s.episode_count ? "yes" : "no" })}
                        </span>
                      </button>
                    );
                  })}
                </div>
              </div>
            )}

          </div>

          <div className={`flex justify-end gap-2 border-t border-white/[0.07] px-6 py-4 max-md:px-5 ${locale === "en" ? "flex-wrap" : ""}`}>
            <button
              type="button"
              onClick={onClose}
              className="btn-glass h-10 px-4 text-ui font-medium"
            >
              {t("subscription.upgrade.back")}
            </button>
            <button
              type="button"
              disabled={busy || !canRun}
              onClick={() => void run()}
              className={`btn-accent inline-flex items-center gap-2 rounded-full px-5 text-ui font-semibold disabled:opacity-40 ${locale === "en" ? "min-h-10 py-2" : "h-10"}`}
            >
              {busy && (
                <span className="size-3.5 animate-spin rounded-full border-2 border-white/30 border-t-white/90" />
              )}
              {paused ? t("subscription.upgrade.resume") : t("subscription.upgrade.start")}
            </button>
          </div>
        </>
      )}

      {ruleSetEditor}
    </Modal>
  );
}

/** 成员洗版时的规则组说明：成员不能选组，目标档位由管理员在规则组里配置。 */
const MEMBER_RULE_SET_HINT_KEY = "subscription.upgrade.memberHint";

/** 单元状态 → 报告徽标（与追踪明细的徽标语言同源）。 */
const UNIT_STATE_META: Record<
  UpgradeRunUnit["state"],
  { labelKey: AppMessageKey; color: string }
> = {
  upgradable: { labelKey: "subscription.upgrade.stateUpgradable", color: "#2dd4bf" },
  in_flight: { labelKey: "subscription.upgrade.stateInFlight", color: "#34d399" },
  at_cutoff: { labelKey: "subscription.upgrade.stateAtCutoff", color: "#4ade80" },
  not_comparable: { labelKey: "subscription.upgrade.stateUnknown", color: "#9ca3af" },
  missing: { labelKey: "subscription.upgrade.stateMissing", color: "#f5c451" },
};

/** 单元状态 → 说明行（标签由后端生成，前端只做排版）。 */
function unitNote(u: UpgradeRunUnit, locale: AppLocale): string {
  const t = appTranslator(locale);
  switch (u.state) {
    case "upgradable":
      return t("subscription.upgrade.upgradableNote", { current: u.current_label ?? t("subscription.upgrade.unknown"), target: u.target_label });
    case "in_flight":
      return t("subscription.upgrade.inFlightNote");
    case "at_cutoff":
      return t("subscription.upgrade.atCutoffNote", { current: u.current_label ?? t("subscription.upgrade.unknown") });
    case "not_comparable":
      return t("subscription.upgrade.unknownNote");
    case "missing":
      return t("subscription.upgrade.missingNote");
  }
}

/**
 * 体检报告段：摘要句 + 按季分组的单元列表。
 * 报告是一次性快照——关闭后看追踪明细的「洗版中」徽标与活动流水跟进。
 * 订阅弹层的洗版变体（场景 B：建订阅后自动接一轮洗版）复用本段展示报告。
 */
export function UpgradeRunReportView({
  title,
  isMovie,
  report,
  mediaItemId,
  onAnnotated,
  onClose,
}: {
  title: string;
  isMovie: boolean;
  report: UpgradeRunReport;
  /** 有值且调用方提供 onAnnotated 时，「无法确认」的季显示「标注片源」入口 */
  mediaItemId?: number;
  /** 片源标注成功后回调（通常重跑一轮体检刷新报告） */
  onAnnotated?: (message: string) => void | Promise<void>;
  onClose: () => void;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const { isAdmin } = usePermissions();
  const [annotateSeason, setAnnotateSeason] = useState<number | null>(null);
  const seasons = new Map<number, UpgradeRunUnit[]>();
  for (const u of report.units) {
    const list = seasons.get(u.season_number) ?? [];
    list.push(u);
    seasons.set(u.season_number, list);
  }
  // 标注是库数据纠错（管理员动作）：入口条件与后端 require_admin 对齐
  const annotatable =
    mediaItemId != null && onAnnotated && isAdmin
      ? seasonsNeedingAnnotation(report.units)
      : new Set<number>();
  return (
    <>
      <h2 className="text-title font-bold text-white">{t("subscription.upgrade.reportTitle")}</h2>
      <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
        {t("subscription.upgrade.reportSubtitle", { title, target: report.target_label })}
      </p>
      <p className="mt-3 rounded-lg border border-[#2dd4bf]/25 bg-[#2dd4bf]/[0.08] px-3.5 py-2.5 text-sub leading-6 text-white/90">
        {report.summary}
      </p>

      <div className="mt-4 space-y-3">
        {[...seasons.entries()]
          .sort(([a], [b]) => a - b)
          .map(([season, units]) => (
            <div
              key={season}
              className="overflow-hidden rounded-xl border border-white/[0.07] bg-white/[0.02]"
            >
              {(!isMovie || annotatable.has(season)) && (
                <p className="flex items-center border-b border-white/[0.06] px-4 py-2 text-sub font-semibold text-white/80">
                  <span className="min-w-0 flex-1">
                    {isMovie ? t("media.kind.feature") : season === 0 ? t("media.season.specials") : t("media.season.title", { number: season })}
                  </span>
                  {annotatable.has(season) && (
                    <button
                      type="button"
                      onClick={() => setAnnotateSeason(season)}
                      className="shrink-0 rounded-md border border-white/[0.12] px-2 py-0.5 text-caption font-medium text-white/75 transition hover:bg-white/[0.07] hover:text-white"
                    >
                      {t("subscription.upgrade.annotateSource")}
                    </button>
                  )}
                </p>
              )}
              <ul className="divide-y divide-white/[0.05]">
                {units.map((u) => {
                  const meta = UNIT_STATE_META[u.state];
                  return (
                    <li
                      key={`${u.season_number}-${u.episode_number}`}
                      className={`flex items-center gap-3 px-4 py-2 max-md:items-start ${locale === "en" ? "flex-wrap" : ""}`}
                    >
                      <span className="tnum w-12 shrink-0 text-sub font-medium text-white/90">
                        {isMovie ? t("media.kind.feature") : `E${String(u.episode_number).padStart(2, "0")}`}
                      </span>
                      <span
                        className="shrink-0 rounded-full px-2 py-0.5 text-micro font-semibold"
                        style={{ backgroundColor: `${meta.color}22`, color: meta.color }}
                      >
                        {t(meta.labelKey)}
                      </span>
                      <span className={`tnum min-w-0 flex-1 text-sub leading-5 text-[var(--text-muted)] ${locale === "en" ? "basis-full [overflow-wrap:anywhere]" : "md:truncate"}`}>
                        {unitNote(u, locale)}
                      </span>
                    </li>
                  );
                })}
              </ul>
            </div>
          ))}
      </div>

      <p className="mt-3 text-caption leading-5 text-[var(--text-faint)]">
        {t("subscription.upgrade.followUp")}
      </p>
      <div className="mt-4 flex justify-end">
        <button
          type="button"
          onClick={onClose}
          className="btn-accent h-10 rounded-full px-5 text-ui font-semibold"
        >
          {t("subscription.upgrade.done")}
        </button>
      </div>

      {annotateSeason !== null && mediaItemId != null && (
        <MediaSourceAnnotationDialog
          mediaItemId={mediaItemId}
          seasonNumber={annotateSeason}
          isMovie={isMovie}
          raised
          onClose={() => setAnnotateSeason(null)}
          onApplied={async (message) => {
            setAnnotateSeason(null);
            await onAnnotated?.(message);
          }}
        />
      )}
    </>
  );
}
