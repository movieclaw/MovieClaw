"use client";

/**
 * 调整订阅弹窗（订阅详情页「调整 ›」入口）：创建后修改季选择 / 入库目标库。
 * 后端 subscriptions.update 支持 diff 重算工单（加季补工单、减季收
 * 未投递工单、已下载/已入库一律保留），此前前端只放开了换规则组——本弹窗
 * 补齐剩余两项，用户不必再"取消订阅重订"（那会丢活动记录）。自动续订是
 * 详情页「更多」里的独立动作，不与批量调整混在一起。
 *
 * 数据源与订阅弹窗同源：季结构走内部 title-preview（幂等，带播出/库存进度），
 * 库选择即时走投递预检。只提交发生变化的字段（PATCH 部分更新语义）。
 *
 * 减季的清理收尾（season-cleanup-dialog.tsx）刻意做成保存**之后**的第二步：
 * ① 保存按钮不该变成破坏性操作——同一个弹窗还能改入库库，调库的人不该撞见
 * 一排删除勾选；② 清理数量必须是实测的，想在保存前给出数量就得把后端的出域
 * 判定复制一份到前端，那是第二份真相源。先保存，再拿真实的 reconcile 结果追问。
 */

import { Fragment, useEffect, useMemo, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { formatList, formatNumber } from "@/lib/i18n/format";
import { useMessageState } from "@/lib/i18n/use-message-state";

import { useToast } from "@/components/feedback";
import { Modal } from "@/components/modal";
import { SeasonCleanupDialog } from "@/components/season-cleanup-dialog";
import {
  SheetMenuRow,
  SheetNotice,
  SheetRow,
  SheetScaffold,
  SheetSection,
  useSheetForm,
} from "@/components/sheet-scaffold";
import { SeasonChoiceRow, SeasonRow } from "@/components/subscribe-dialog";
import { SeasonCapLine } from "@/components/subscription-episode-cap";
import { listLibraries, type MediaLibrary } from "@/lib/api/libraries";
import {
  cleanupSubscriptionSeasons,
  getSubscriptionRemovalPreview,
  previewSubscriptionDownloadRouting,
  previewSubscriptionTitle,
  updateSubscription,
  type DispatchPreview,
  type SeasonOverview,
  type SubscriptionDetail,
  type SubscriptionRemovalOptions,
  type SubscriptionRemovalPreview,
} from "@/lib/api/subscriptions";
import { usePermissions } from "@/lib/permissions";
import {
  canCapSeason,
  capsPayload,
  currentWindows,
  draftFromSeasons,
  effectiveWindow,
  isAiringSeason,
  sameWindows,
  type CapDraft,
} from "@/lib/subscription-episode-cap";

export function SubscriptionAdjustDialog({
  detail,
  onClose,
  onSaved,
}: {
  detail: SubscriptionDetail;
  onClose: () => void;
  /** 保存成功后由调用方刷新详情 */
  onSaved: () => void;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const { canManageSubscriptions } = usePermissions();
  const toast = useToast();
  const sheetForm = useSheetForm();
  const isMovie = detail.media.kind === "movie";
  // null = 加载中；[] 也是有效结果（电影没有季）
  const [seasons, setSeasons] = useState<SeasonOverview[] | null>(isMovie ? [] : null);
  const [libraries, setLibraries] = useState<MediaLibrary[]>([]);
  const [selectedSeasons, setSelectedSeasons] = useState<Set<number>>(
    () => new Set(detail.selected_seasons),
  );
  // 超长的一季先订阅一部分：起点是订阅现在的状态，存量订阅不会被默认值悄悄改成先订阅一批
  const [capDraft, setCapDraft] = useState<CapDraft>(() => draftFromSeasons(detail.episode_seasons));
  const [libraryId, setLibraryId] = useState<number | null>(detail.library_id);
  const [preview, setPreview] = useState<DispatchPreview | null>(null);
  const [error, setError] = useMessageState();
  const [busy, setBusy] = useState(false);
  // 保存成功后的清理追问；null = 不追问（没减季 / 无可清理内容 / 预览失败）
  const [cleanup, setCleanup] = useState<{
    seasons: number[];
    preview: SubscriptionRemovalPreview;
  } | null>(null);

  useEffect(() => {
    let cancelled = false;
    Promise.all([
      isMovie
        ? Promise.resolve(null)
        : previewSubscriptionTitle({
            title_ref: `tmdb:${detail.media.kind}:${detail.media.tmdb_id}`,
          }),
      canManageSubscriptions
        ? listLibraries(detail.media.kind)
        : Promise.resolve([]),
    ])
      .then(([prepared, libs]) => {
        if (cancelled) return;
        if (prepared) setSeasons(prepared.status === "ready" ? prepared.seasons : []);
        setLibraries(libs);
      })
      .catch(() => {
        if (!cancelled) setError({ key: "subscription.adjust.loadFailed" });
      });
    return () => {
      cancelled = true;
    };
  }, [canManageSubscriptions, detail.media.kind, detail.media.tmdb_id, isMovie, locale, setError]);

  // 选库即预演投递落点（与订阅弹窗同一套提示；null=该类型默认库也预演）
  useEffect(() => {
    if (!canManageSubscriptions) {
      setPreview(null);
      return;
    }
    let cancelled = false;
    setPreview(null);
    previewSubscriptionDownloadRouting(detail.media.kind, libraryId, detail.media.tmdb_id)
      .then((p) => {
        if (!cancelled) setPreview(p);
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [canManageSubscriptions, detail.media.kind, detail.media.tmdb_id, libraryId, locale]);

  const toggleSeason = (n: number) =>
    setSelectedSeasons((prev) => {
      const next = new Set(prev);
      if (next.has(n)) next.delete(n);
      else next.add(n);
      return next;
    });

  // 被取消勾选、且已有进度（有工单走到 grabbed 之后）的季：减季不动下载器
  // 任务，但会停止业务关联与换源——把后果讲在保存之前。
  const droppedWithProgress = useMemo(() => {
    if (isMovie) return [];
    const kept = selectedSeasons;
    const progressed = new Set(
      detail.wanted.filter((w) => w.status !== "wanted").map((w) => w.season_number),
    );
    return detail.selected_seasons.filter((s) => !kept.has(s) && progressed.has(s));
  }, [detail, isMovie, selectedSeasons]);

  // 提交的是整份窗口（后端整体替换）；勾上的超长季才有一行「先订阅一部分」。
  // 在播的超长季默认订最新的几集，完结的从第 1 集订起
  const nextCaps = useMemo(
    () => capsPayload(seasons ?? [], selectedSeasons, capDraft, detail.media.status),
    [seasons, selectedSeasons, capDraft, detail.media.status],
  );
  const airingOf = (seasonNumber: number) =>
    isAiringSeason(detail.media.status, seasons ?? [], seasonNumber);
  const setCap = (seasonNumber: number, next: CapDraft[number]) =>
    setCapDraft((prev) => ({ ...prev, [seasonNumber]: next }));

  const changed = useMemo(() => {
    const seasonsChanged =
      !isMovie &&
      JSON.stringify([...selectedSeasons].sort((a, b) => a - b)) !==
        JSON.stringify([...detail.selected_seasons].sort((a, b) => a - b));
    return {
      seasons: seasonsChanged,
      library: canManageSubscriptions && libraryId !== detail.library_id,
      caps:
        !isMovie &&
        seasons !== null &&
        !sameWindows(nextCaps, currentWindows(detail.episode_seasons)),
    };
  }, [canManageSubscriptions, detail, isMovie, libraryId, nextCaps, seasons, selectedSeasons]);
  const dirty = changed.seasons || changed.library || changed.caps;

  const save = async () => {
    setBusy(true);
    setError(null);
    // 本次被移出范围的季——清理追问的范围。保存前算好：保存后季状态已经变了
    const dropped = changed.seasons
      ? detail.selected_seasons.filter((s) => !selectedSeasons.has(s))
      : [];
    try {
      await updateSubscription(detail.id, {
        ...(changed.seasons
          ? { selected_seasons: [...selectedSeasons].sort((a, b) => a - b) }
          : {}),
        // 显式带上 null 即「清除指定库、改回默认库路由」（后端区分未传与 null）
        ...(canManageSubscriptions && changed.library ? { library_id: libraryId } : {}),
        ...(changed.caps ? { episode_caps: nextCaps } : {}),
      });
      toast.success(t("subscription.adjust.saved"));
      if (dropped.length > 0 && canManageSubscriptions) {
        // 数量取自后端保存后的真实出域结果，不在前端推算
        const plan = await getSubscriptionRemovalPreview(detail.id, dropped).catch(() => null);
        if (plan === null) {
          // 预览拿不到就不追问——没数字的勾选框等于让用户盲签。但要明确说出
          // "没做清理"，用户才知道要不要自己去处理
          toast.info(t("subscription.adjust.savedWithoutCleanup"));
        } else if (plan.torrent_count > 0 || plan.library_file_count > 0) {
          setCleanup({ seasons: dropped, preview: plan });
          setBusy(false);
          return; // 等用户在追问弹窗里决定；onSaved() 推迟到那一步
        }
      }
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.adjust.saveFailed" });
      setBusy(false);
    }
  };

  /** 追问弹窗点了「清理」：订阅已经调整完，这里只处理内容清理的成败。 */
  const confirmCleanup = async (options: SubscriptionRemovalOptions) => {
    if (cleanup === null) return;
    try {
      await cleanupSubscriptionSeasons(detail.id, cleanup.seasons, options);
      toast.success(t("subscription.adjust.cleanupStarted"));
    } catch (e) {
      toast.error(e instanceof Error ? e.message : t("subscription.adjust.cleanupFailed"));
    }
    setCleanup(null);
    onSaved();
  };

  // 减季保存成功且有内容可清理：由追问弹窗接手（不叠在本弹窗之上——季已经改完，
  // 让两个弹窗同时在场只会让人以为还能回去改）
  if (cleanup !== null) {
    return (
      <SeasonCleanupDialog
        open
        title={detail.media.title}
        seasons={cleanup.seasons}
        preview={cleanup.preview}
        onClose={() => {
          setCleanup(null);
          onSaved();
        }}
        onConfirm={confirmCleanup}
      />
    );
  }

  // 投递路由预检说明（桌面与手机两套形态共用）
  const previewNote =
    preview &&
    (preview.ok ? (
      <p className="mt-1.5 text-caption leading-relaxed text-[var(--text-faint)]">
        {preview.mode === "watch"
          ? t("subscription.adjust.watchPreview", { path: preview.path ?? "" })
          : // 条目目录由后端按命名模板渲染，前端不自己拼名字
            t("subscription.adjust.libraryPreview", { path: preview.entry_dir ?? preview.path ?? "" })}
      </p>
    ) : (
      <p className="mt-1.5 rounded-lg border border-amber-400/25 bg-amber-500/10 px-3 py-2 text-caption leading-relaxed text-amber-200">
        {preview.warning}
      </p>
    ));
  const saveDisabled = busy || !dirty || (!isMovie && selectedSeasons.size === 0);
  const droppedNote = droppedWithProgress.length > 0 && (
    <>{t("subscription.adjust.droppedNote", { seasons: formatList(droppedWithProgress.map(n => formatNumber(n, undefined, locale)), locale), count: droppedWithProgress.length, canClean: canManageSubscriptions ? "yes" : "no" })}</>
  );

  // 银玻璃手机端：表单弹层（对齐 iOS SubscriptionAdjustSheet）——保存放头部 ✓，
  // 季是对勾行、入库库是菜单行，投递预检写在组下脚注
  if (sheetForm) {
    return (
      <SheetScaffold
        onClose={onClose}
        title={t("subscription.adjust.title")}
        subtitle={
          <>
            {t("subscription.adjust.description", { title: detail.media.title })}
          </>
        }
        confirm={{
          label: t("subscription.adjust.save"),
          enabled: !saveDisabled,
          busy,
          onConfirm: () => void save(),
        }}
      >
        {error && <SheetNotice tone="error">{error}</SheetNotice>}
        {!isMovie && (
          <SheetSection title={t("subscription.adjust.chooseSeasons")} footer={t("subscription.adjust.chooseSeasonsHint")}>
            {seasons === null ? (
              <SheetRow label={<span className="text-[var(--text-muted)]">{t("subscription.adjust.loading")}</span>} />
            ) : (
              seasons.map((s) => (
                <Fragment key={s.season_number}>
                  <SeasonChoiceRow
                    season={s}
                    checked={selectedSeasons.has(s.season_number)}
                    onToggle={() => toggleSeason(s.season_number)}
                  />
                  {selectedSeasons.has(s.season_number) && canCapSeason(s, airingOf(s.season_number)) && (
                    <SeasonCapLine
                      season={s}
                      win={effectiveWindow(s, capDraft, airingOf(s.season_number))}
                      airing={airingOf(s.season_number)}
                      showName={false}
                      onChange={(next) => setCap(s.season_number, next)}
                      className="min-h-11 px-4 py-2.5"
                    />
                  )}
                </Fragment>
              ))
            )}
          </SheetSection>
        )}
        {droppedNote && <SheetNotice tone="warn">{droppedNote}</SheetNotice>}
        {canManageSubscriptions && libraries.length > 0 && (
          <SheetSection footer={previewNote}>
            <SheetMenuRow
              label={t("subscription.subscribe.library")}
              value={libraryId === null ? "route" : String(libraryId)}
              options={[
                // 旧订阅 library_id 可能为 null（按默认库路由）：显式占位项，所见即所存
                { value: "route", label: t("subscription.adjust.defaultRouting") },
                ...libraries.map((l) => ({
                  value: String(l.id),
                  label: t("subscription.subscribe.defaultName", { name: l.name, isDefault: l.is_default ? "yes" : "no" }),
                })),
              ]}
              onChange={(v) => setLibraryId(v === "route" ? null : Number(v))}
            />
          </SheetSection>
        )}
      </SheetScaffold>
    );
  }

  return (
    <Modal open onClose={onClose} label={t("subscription.adjust.title")} width="lg" panelClassName="max-h-[76dvh]">
      {/* 头部常驻 */}
      <div className="border-b border-white/[0.07] px-6 pb-4 pt-6 max-md:px-5">
        <h2 className="text-title font-bold text-white">{t("subscription.adjust.title")}</h2>
        <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
          {t("subscription.adjust.description", { title: detail.media.title })}
        </p>
      </div>

      <div className="scroll-thin min-h-0 flex-1 overflow-y-auto p-6 max-md:p-5">
        {error && (
          <p className="mt-3 rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2.5 text-sub leading-6 text-red-200">
            {error}
          </p>
        )}

        <div className="mt-4 space-y-5">
          {!isMovie && (
            <section>
              <h3 className="mb-2 text-ui font-semibold text-white/85">
                {t("subscription.adjust.chooseSeasons")}
                <span className="ml-2 font-normal text-[var(--text-faint)]">
                  {t("subscription.adjust.chooseSeasonsHint")}
                </span>
              </h3>
              {seasons === null ? (
                <p className="rounded-xl bg-white/[0.03] px-4 py-3 text-sub text-[var(--text-muted)]">
                  {t("subscription.adjust.loading")}
                </p>
              ) : (
                <div className="space-y-1.5">
                  {seasons.map((s) => (
                    <div key={s.season_number}>
                      <SeasonRow
                        season={s}
                        checked={selectedSeasons.has(s.season_number)}
                        onToggle={() => toggleSeason(s.season_number)}
                      />
                      {selectedSeasons.has(s.season_number) && canCapSeason(s, airingOf(s.season_number)) && (
                        <SeasonCapLine
                          season={s}
                          win={effectiveWindow(s, capDraft, airingOf(s.season_number))}
                          airing={airingOf(s.season_number)}
                          showName={false}
                          onChange={(next) => setCap(s.season_number, next)}
                          className="px-4 pb-1 pt-2"
                        />
                      )}
                    </div>
                  ))}
                </div>
              )}
              {droppedNote && (
                <p className="mt-2 rounded-lg border border-amber-400/25 bg-amber-500/10 px-3 py-2 text-caption leading-relaxed text-amber-200">
                  {droppedNote}
                </p>
              )}
            </section>
          )}

          {canManageSubscriptions && libraries.length > 0 && (
            <section>
              <h3 className="mb-2 text-ui font-semibold text-white/85">{t("subscription.subscribe.library")}</h3>
              {/* 旧订阅 library_id 可能为 null（按默认库路由）：给它一个显式占位项，
                  否则浏览器会视觉上选中第一个库、而状态仍是 null（所见非所存） */}
              <select
                aria-label={t("subscription.subscribe.library")}
                value={libraryId === null ? "" : String(libraryId)}
                onChange={(e) =>
                  setLibraryId(e.target.value === "" ? null : Number(e.target.value))
                }
                className="w-full rounded-xl border border-white/[0.08] bg-white/[0.04] px-3.5 py-2.5 text-ui text-white/90 outline-none focus:border-white/25 [&>option]:bg-[#181c28]"
              >
                <option value="">{t("subscription.adjust.defaultRouting")}</option>
                {libraries.map((l) => (
                  <option key={l.id} value={l.id}>
                    {t("subscription.subscribe.defaultName", { name: l.name, isDefault: l.is_default ? "yes" : "no" })}
                  </option>
                ))}
              </select>
              {previewNote}
            </section>
          )}
        </div>
      </div>

      {/* 底栏常驻：季数一多就要滚，保存按钮不能被滚出屏幕 */}
      <div className={`flex justify-end gap-3 border-t border-white/[0.07] px-6 py-4 max-md:px-5 ${locale === "en" ? "flex-wrap" : ""}`}>
        <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
          {t("common.cancel")}
        </button>
        <button
          type="button"
          disabled={saveDisabled}
          onClick={() => void save()}
          className={`btn-accent rounded-full px-5 text-ui font-semibold disabled:opacity-40 ${locale === "en" ? "min-h-9 py-2" : "h-9"}`}
        >
          {busy ? t("subscription.adjust.saving") : t("subscription.adjust.save")}
        </button>
      </div>
    </Modal>
  );
}
