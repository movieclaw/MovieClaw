"use client";

/**
 * 「修正识别结果」弹窗 —— 识别错挂的收口（issue #107）。
 *
 * 为什么是两阶段而不是"点一下重新识别"：识别错挂时机器往往是**高置信地
 * 错**——同一条链、同样的输入，重跑大概率复现同一个错答案。旧的「重新
 * 识别」跑完直接改身份锚、还顺带改写 NFO，用户点了既看不到过程、多半也
 * 没改成。这里把它拆成"先出结论 → 人拍板 → 才落库"：
 *
 *   打开 → 重走识别链（只读，一行台账都不改）
 *        → 按**结论**分组摆出来（一部剧几十集同一个结论只占一行；真分裂成
 *          「38 个归 A、2 个归 B」时也如实摊开）
 *        → 每组三个出口：采用新结论 / 自己搜一个条目 / 标为非独立作品
 *        → 关掉 = 什么都没发生
 *
 * 三条刻意的交互决定：
 * 1. **搜索是一等公民**，不藏在"都不对？"后面。机器高置信错挂时，正确答案
 *    常常压根不在候选里（收敛器验中即早退，不会为了凑候选再搜一轮），
 *    只给候选等于给三个都不对的选项；
 * 2. **「不是独立作品」必须有**。花絮/预告被错挂时，用户要说的不是"改挂到
 *    条目 Y"，而是"它根本不该是个条目"——没有这个出口，界面上最接近的
 *    按钮就成了「删除影片」（那是删磁盘）；
 * 3. 认领一律经 ClaimConfirmPanel 看过海报/简介再落地，与待识别清单同一
 *    套面板：只看名字不足以在同名双版本之间下判断。
 */

import { useCallback, useEffect, useState } from "react";

import {
  ClaimConfirmPanel,
  ClaimSearchPanel,
  type ClaimSeed,
} from "@/components/claim-panels";
import { BrandLoader } from "@/components/brand-loader";
import { useConfirm } from "@/components/feedback";
import { Modal } from "@/components/modal";
import {
  assignLibraryFilesToTitle,
  markLibraryFilesAsExtras,
  previewItemReidentification,
  type ReidentifyGroup,
  type ReidentifyPreview,
} from "@/lib/api/libraries";
import { formatBytes } from "@/lib/format";
import { imageUrl, responsiveImage } from "@/lib/image-proxy";

/** 身份来源 → 中文短语（结论卡上说明"凭什么这么认"）。 */
const SOURCE_LABELS: Record<string, string> = {
  path_tag: "目录名的 tmdbid 标记",
  nfo: "NFO",
  resolved: "名称解析 + TMDB 收敛",
};

/** 没命中的失败分类 → 一句人话（与待识别清单的标签同源，措辞按本场景调整）。 */
const CODE_LABELS: Record<string, string> = {
  tmdb_unreachable: "TMDB 不可达",
  kind_mismatch: "类型与本库不符",
  ambiguous: "候选之间分不出",
  no_match: "TMDB 里没找到匹配",
  unparsable: "从文件名认不出片名",
  unit_unresolved: "认出了作品但定不了第几季",
};

export function ReidentifyDialog({
  open,
  libraryId,
  mediaItemId,
  onClose,
  onApplied,
}: {
  open: boolean;
  libraryId: number;
  mediaItemId: number;
  onClose: () => void;
  /** 有任何一组落库后回调（父组件据此重拉详情；条目可能已不存在） */
  onApplied: () => void;
}) {
  const [preview, setPreview] = useState<ReidentifyPreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  // 已拍板的组 key → 结论文案。留在界面上而不是直接关窗：分裂成多组时
  // 用户要接着处理剩下的，得看得见哪些已经处理过了
  const [settled, setSettled] = useState<Record<string, string>>({});

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    setPreview(null);
    setError(null);
    setSettled({});
    previewItemReidentification(libraryId, mediaItemId)
      .then((data) => {
        if (!cancelled) setPreview(data);
      })
      .catch((e) => {
        if (!cancelled) setError((e as Error).message);
      });
    return () => {
      cancelled = true;
    };
  }, [open, libraryId, mediaItemId]);

  const settle = useCallback(
    (key: string, message: string) => {
      setSettled((prev) => ({ ...prev, [key]: message }));
      onApplied();
    },
    [onApplied],
  );

  const pending = preview?.groups.filter((g) => !settled[g.key]) ?? [];

  return (
    <Modal open={open} onClose={onClose} label="修正识别结果" width="2xl" panelClassName="flex max-h-[80vh] flex-col">
      <div className="border-b border-white/[0.07] px-5 py-3.5">
        <h2 className="text-body-lg font-semibold text-[var(--text)]">修正识别结果</h2>
        <p className="mt-1 text-caption leading-relaxed text-[var(--text-muted)]">
          已重走识别链。下面是机器给出的结论——
          <span className="text-white/80">采纳、自己搜一个、或标为非独立作品都由你定</span>
          ，关掉这个窗口则不会有任何改动。
        </p>
      </div>

      <div className="min-h-0 flex-1 space-y-3 overflow-y-auto scroll-thin px-5 py-4">
        {error && <p className="text-sub text-red-300">{error}</p>}

        {!preview && !error && (
          <div className="flex items-center justify-center gap-2.5 py-10 text-ui text-[var(--text-muted)]">
            <BrandLoader className="size-5" />
            正在重新识别…
          </div>
        )}

        {preview && (
          <>
            <CurrentIdentity preview={preview} />

            {preview.unreachable && (
              <p className="rounded-lg border border-[var(--warn)]/30 bg-[var(--warn)]/[0.08] px-3 py-2 text-caption leading-relaxed text-[#f5d489]">
                有文件因为 TMDB 不可达没能得出结论——那是网络问题不是识别问题。
                建议先修好网络再来，此刻的结论不足以据此拍板。
              </p>
            )}

            {preview.pinned_identity && (
              <p className="rounded-lg border border-white/[0.1] bg-white/[0.03] px-3 py-2 text-caption leading-relaxed text-[var(--text-muted)]">
                这些文件的身份被<span className="text-white/80">目录名的 tmdbid 标记或 NFO 钉死</span>
                。在这里改挂会记为人工身份、扫描不会再翻案，条目 NFO 里矛盾的
                tmdbid 也会被一并改正；但目录名上的标记需要你自己改，否则下次
                整理/重扫的命名仍会带着旧 id。
              </p>
            )}

            {preview.groups.length === 0 && (
              <p className="py-6 text-center text-ui text-[var(--text-muted)]">
                这个条目在本库没有可参与识别的在位文件。
              </p>
            )}

            {preview.groups.map((group) => (
              <GroupRow
                key={group.key}
                group={group}
                movie={preview.movie}
                searchSeed={preview.search_seed}
                settledMessage={settled[group.key]}
                onSettled={(message) => settle(group.key, message)}
              />
            ))}

            {preview.skipped_missing > 0 && (
              <p className="text-caption text-[var(--text-faint)]">
                另有 {preview.skipped_missing} 个文件已从磁盘消失（缺失清单里那些），
                没有实体可供识别，保持原身份不参与。
              </p>
            )}
          </>
        )}
      </div>

      <div className="flex items-center gap-3 border-t border-white/[0.07] px-5 py-3">
        <span className="text-caption text-[var(--text-faint)]">
          {preview && pending.length === 0 && preview.groups.length > 0
            ? "全部处理完了"
            : "改挂会记为人工身份，之后识别器升级不再自动翻案"}
        </span>
        <span className="flex-1" />
        <button
          type="button"
          onClick={onClose}
          className="btn-glass px-3.5 py-1.5 text-sub font-medium"
        >
          关闭
        </button>
      </div>
    </Modal>
  );
}

/* —— 现身份卡：拍板前先看清"现在挂的是谁" —— */

function CurrentIdentity({ preview }: { preview: ReidentifyPreview }) {
  const { current } = preview;
  return (
    <div className="flex items-center gap-3 rounded-xl border border-white/[0.08] bg-white/[0.03] p-3">
      {current.poster_url ? (
        <img
          {...responsiveImage(imageUrl(current.poster_url), 44)}
          alt={current.title}
          loading="lazy"
          decoding="async"
          className="h-16 w-11 shrink-0 rounded-lg bg-white/[0.05] object-cover"
        />
      ) : (
        <div className="h-16 w-11 shrink-0 rounded-lg bg-white/[0.05]" />
      )}
      <div className="min-w-0 flex-1">
        <p className="text-caption text-[var(--text-faint)]">当前身份</p>
        <p className="truncate text-ui font-semibold text-white/95">
          {current.title}
          {current.year ? (
            <span className="ml-1.5 text-sub font-normal text-[var(--text-muted)]">
              {current.year}
            </span>
          ) : null}
        </p>
        {current.tmdb_id != null && (
          <a
            href={`https://www.themoviedb.org/${preview.movie ? "movie" : "tv"}/${current.tmdb_id}`}
            target="_blank"
            rel="noreferrer"
            className="text-caption text-[var(--text-muted)] underline decoration-white/20 underline-offset-2 transition hover:text-white/80"
          >
            TMDB #{current.tmdb_id} ↗
          </a>
        )}
      </div>
    </div>
  );
}

/* —— 一组结论：文件清单 + 机器结论 + 三个出口 —— */

function GroupRow({
  group,
  movie,
  searchSeed,
  settledMessage,
  onSettled,
}: {
  group: ReidentifyGroup;
  movie: boolean;
  searchSeed: string;
  settledMessage?: string;
  onSettled: (message: string) => void;
}) {
  const confirm = useConfirm();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 同时只开一个内联面板：确认（看详情再定）或搜索
  const [panel, setPanel] = useState<
    { view: "confirm"; seed: ClaimSeed } | { view: "search" } | null
  >(null);

  const { outcome } = group;
  const selectedId = panel?.view === "confirm" ? panel.seed.tmdbId : null;

  const act = (fn: () => Promise<unknown>, message: string) => {
    setBusy(true);
    setError(null);
    void fn()
      .then(() => {
        setPanel(null);
        onSettled(message);
      })
      .catch((e) => setError((e as Error).message))
      .finally(() => setBusy(false));
  };

  const detach = async () => {
    if (
      !(await confirm({
        title: `把这 ${group.file_count} 个文件标为「非独立作品」？`,
        description:
          "它们会摘掉身份、不再占用库存，之后扫描也不再过问。适合花絮、预告、片段这类本就不该单独成条目的内容。" +
          "磁盘文件一个字节都不会动，随时可以在「已忽略」清单里恢复。",
        confirmLabel: "标为非独立作品",
        tone: "danger",
      }))
    )
      return;
    act(
      () => markLibraryFilesAsExtras(group.file_ids),
      `${group.file_count} 个文件已标为非独立作品`,
    );
  };

  if (settledMessage) {
    return (
      <div className="rounded-xl border border-[var(--accent)]/25 bg-[var(--accent)]/[0.08] px-3.5 py-2.5 text-sub text-white/85">
        ✓ {settledMessage}
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-white/[0.08] bg-white/[0.03] px-3.5 py-3">
      {/* 是哪些文件——分裂成多组时这行是唯一的辨认依据 */}
      <div className="flex items-baseline gap-2">
        <span className="text-ui font-medium text-white/85">
          {group.file_count} 个文件
        </span>
        <span className="text-caption text-[var(--text-faint)]">
          {formatBytes(group.total_size_bytes)}
        </span>
      </div>
      <p
        className="mt-0.5 truncate font-mono text-caption text-[var(--text-faint)]"
        title={group.sample_names.join("\n")}
      >
        {group.sample_names.join("、")}
        {group.file_count > group.sample_names.length ? " …" : ""}
      </p>

      {/* 机器结论 */}
      <div className="mt-2.5 border-t border-white/[0.06] pt-2.5">
        {outcome.media_item_id != null ? (
          <div className="flex items-center gap-3">
            {outcome.poster_url ? (
              <img
                {...responsiveImage(imageUrl(outcome.poster_url), 40)}
                alt={outcome.title ?? ""}
                loading="lazy"
                decoding="async"
                className="h-14 w-10 shrink-0 rounded bg-white/[0.05] object-cover"
              />
            ) : (
              <div className="h-14 w-10 shrink-0 rounded bg-white/[0.05]" />
            )}
            <div className="min-w-0 flex-1">
              <p className="text-caption text-[var(--text-faint)]">
                {outcome.same_as_current ? "重新识别的结论：与当前一致" : "重新识别的结论"}
              </p>
              <p className="truncate text-ui font-semibold text-white/95">
                {outcome.title}
                {outcome.year ? (
                  <span className="ml-1.5 text-sub font-normal text-[var(--text-muted)]">
                    {outcome.year}
                  </span>
                ) : null}
              </p>
              {outcome.source && (
                <p className="text-caption text-[var(--text-faint)]">
                  依据：{SOURCE_LABELS[outcome.source] ?? outcome.source}
                </p>
              )}
            </div>
            {!outcome.same_as_current && outcome.tmdb_id != null && (
              <button
                type="button"
                disabled={busy}
                onClick={() =>
                  setPanel({
                    view: "confirm",
                    seed: {
                      tmdbId: outcome.tmdb_id as number,
                      title: outcome.title ?? "",
                      year: outcome.year,
                      posterUrl: outcome.poster_url ?? undefined,
                    },
                  })
                }
                className="btn-accent shrink-0 rounded-full px-3 py-1.5 text-sub font-semibold disabled:opacity-40"
              >
                改挂到这里
              </button>
            )}
          </div>
        ) : (
          <p className="text-sub leading-relaxed text-[var(--text-muted)]">
            没能认出来
            {outcome.code ? `（${CODE_LABELS[outcome.code] ?? outcome.code}）` : ""}
            {outcome.reason ? `：${outcome.reason}` : "。"}
          </p>
        )}
      </div>

      {/* 候选：机器拿不定主意时留下的可能匹配，点一下先看详情 */}
      {outcome.candidates.length > 0 && (
        <div className="mt-2 flex flex-wrap gap-1.5">
          {outcome.candidates.map((c) => (
            <button
              key={c.tmdb_id}
              type="button"
              disabled={busy}
              onClick={() =>
                setPanel(
                  selectedId === c.tmdb_id
                    ? null
                    : {
                        view: "confirm",
                        seed: {
                          tmdbId: c.tmdb_id,
                          title: c.title,
                          year: c.year,
                          episodeCount: c.episode_count,
                          reasons: c.reasons,
                        },
                      },
                )
              }
              className={`rounded-lg border px-2.5 py-1 text-sub transition disabled:opacity-40 ${
                selectedId === c.tmdb_id
                  ? "border-[var(--accent)] bg-[var(--accent)]/[0.28] text-white"
                  : "border-[var(--accent)]/40 bg-[var(--accent)]/[0.12] text-white/90 hover:bg-[var(--accent)]/[0.24]"
              }`}
            >
              {c.title}
              {c.year ? ` (${c.year})` : ""}
            </button>
          ))}
        </div>
      )}

      {/* 两个常驻出口。搜索**不藏在二级**：机器高置信错挂时正确答案常常
          压根不在候选里，"都不对"才是常态 */}
      <div className="mt-2.5 flex items-center gap-2">
        <button
          type="button"
          disabled={busy}
          onClick={() => setPanel((p) => (p?.view === "search" ? null : { view: "search" }))}
          className={`rounded-full px-3 py-1.5 text-sub font-medium transition disabled:opacity-40 ${
            panel?.view === "search" ? "bg-white/[0.14] text-white" : "btn-glass"
          }`}
        >
          都不对，自己搜…
        </button>
        <span className="flex-1" />
        <button
          type="button"
          disabled={busy}
          onClick={() => void detach()}
          className="btn-glass px-3 py-1.5 text-sub font-medium text-[#ffb4b4] disabled:opacity-40"
        >
          不是独立作品
        </button>
      </div>

      {error && <p className="mt-1.5 text-caption text-red-300">{error}</p>}

      {panel?.view === "search" && (
        <ClaimSearchPanel
          movie={movie}
          initialQuery={searchSeed}
          onPick={(seed) => setPanel({ view: "confirm", seed })}
        />
      )}
      {panel?.view === "confirm" && (
        <ClaimConfirmPanel
          key={panel.seed.tmdbId}
          seed={panel.seed}
          movie={movie}
          fileCount={group.file_count}
          busy={busy}
          onConfirm={() =>
            act(
              () =>
                assignLibraryFilesToTitle(
                  group.file_ids,
                  `tmdb:${movie ? "movie" : "tv"}:${panel.seed.tmdbId}`,
                ),
              `${group.file_count} 个文件已改挂为《${panel.seed.title}》`,
            )
          }
          onCancel={() => setPanel(null)}
        />
      )}
    </div>
  );
}
