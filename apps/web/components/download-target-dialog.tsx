"use client";

/**
 * 下载目标选择弹窗（手动下载的保存位置确认）。
 *
 * 点搜索结果的「下载」先弹出本层，让用户明确文件会落到哪，而不是静默
 * 提交后再猜。候选来源分三层：
 *   1. 智能入库（确认了是哪部作品时）：走后端与订阅同源的三级兜底
 *      （监听目录 / 库条目目录），并用 dispatch-preview 预检结论展示
 *      真实归宿与配置警示。种子自己的身份识别不出来（乱码/拼音命名、
 *      没解析出年份）时，后端按用户的搜索词给出 TMDB 候选，弹窗只问一句
 *      「这是哪部作品？」——点一下候选即与自动识别同权，媒体库仍由收藏
 *      范围自动分配（手动识别 ≠ 手动选库）；
 *   2. 下载器已配置的目录：默认保存目录 + 各路径映射的 movieclaw 侧目录，
 *      双视角展示（movieclaw 路径 → 下载器路径），跨容器部署一眼可核对；
 *   3. 下载器默认目录兜底：不指定路径，由下载器自行决定。
 * 底部小字引导去「设置 → 下载器」配置路径映射。
 *
 * 保存位置记忆（docs/design/download-target-memory.md）：按种子分类
 * （TorrentCategory）记住选择，下次点该分类的「下载」先弹确认条
 * （本文件的 DownloadTargetConfirmBar），看得见落点再确认。
 *
 * 记忆的建立由弹窗底部的「记住本次选择」复选框把关（用户反馈 2026-09-08：
 * 第一次选完路径就被悄悄记住，不可接受）。初值 = 该分类是否已有记忆：
 *   - 首次下载该分类：**不勾**——临时下一次不该留下一条以后一直生效的默认，
 *     用户没表达过这个意思；
 *   - 已有记忆（多半是从确认条点「更改」进来的）：**默认勾上**——进来就是为了
 *     改这条默认，不勾等于改了个寂寞，旧的错默认还留在那儿。
 * 不勾选时提交请求里不带 category，后端据此跳过 upsert（见
 * api/routes/downloaders.py 的 _remember_target）。
 *
 * 成员分支（docs/design/member-permissions-v2.md §3.7 U7）：下载器配置、智能入库
 * 预检都是超管接口，手选目录 / 指定下载器 / 智能入库提交时也会被后端 403。成员
 * 弹窗（MemberDialogContent）因此只给两种落点：「下到我能看到的某个媒体库」
 *（library_id，按该库的入库规则推导目录）或「下载器默认目录」，也不读写保存位置记忆
 *（后端只为超管记）。
 */

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { FolderIcon } from "@/components/icons";
import { CATEGORY_LABEL, type TorrentCategory } from "@/lib/categories";
import { formatRelativeTime } from "@/lib/time";
import { Modal } from "@/components/modal";
import { listLibraries, type MediaLibrary } from "@/lib/api/libraries";
import { usePermissions } from "@/lib/permissions";
import { imageUrl, responsiveImage } from "@/lib/image-proxy";
import {
  listDownloaders,
  submitTorrentDownload,
  type ConfiguredDownloader,
  type DownloadSubmitResult,
  type DownloadTargetPref,
  type ManualDownloadTarget,
  type ManualDownloadTargetCandidate,
  type PathMapping,
  resolveManualDownloadTarget,
} from "@/lib/api/downloaders";

/** 弹窗需要的种子身份切片（由搜索结果的 TorrentHit 提炼）。 */
export interface DownloadTargetRequest {
  site_id: string;
  download_url: string;
  /** 站点内种子 ID：随提交锚定，任务中心据此提供「打开种子页」 */
  torrent_id: string;
  /** 解析出的条目身份；三件套不全时为 null（此时只能靠 hint 给候选） */
  identity: { kind: "movie" | "tv"; title: string; year: number } | null;
  subtitle: string | null;
  /**
   * 用户的搜索关键词：种子标题识别失败时拿它检索 TMDB 候选。用户是搜了这个词
   * 才看到这条结果的，乱码命名的种子上它往往比种子标题可靠得多
   */
  hint: string | null;
  /**
   * 种子分类（TorrentHit.category ?? "other"）：记忆的桶键。
   * 用站点声明的一级分类而非 enrich 推断的 media_type/content_type——推断值会
   * null、同一部剧的两条种子可能判得不一致，还会随模型版本漂移，拿它当持久化
   * 偏好的键会让用户的记忆桶在某次升级后悄悄换位置。
   */
  category: string;
}

/* —— 记忆命中后的直接提交 —— */

/**
 * 按记住的目标提交（确认条的「确认下载」），不经完整弹窗。
 *
 * smart 目标存的是**策略不是路径**，每次都要重跑 TMDB 身份确认与投递预检；
 * 未收敛或配置有警示时返回 null，调用方据此展开完整弹窗并说明原因——绝不把
 * 不确定的资源静默放进默认库。
 */
export async function submitRememberedTarget(
  request: DownloadTargetRequest,
  target: DownloadTargetPref,
): Promise<DownloadSubmitResult | null> {
  const identity = request.identity;
  let libraryPart = {};
  if (target.kind === "smart") {
    if (!identity) return null;
    const resolved = await resolveManualDownloadTarget({
      kind: identity.kind,
      title: identity.title,
      year: identity.year,
      subtitle: request.subtitle,
      downloader_id: target.downloader_id,
    }).catch(() => null);
    if (!resolved?.ok || resolved.status !== "ready" || resolved.tmdb_id == null) return null;
    libraryPart = {
      auto_route: true,
      media_kind: identity.kind,
      tmdb_id: resolved.tmdb_id,
      title: identity.title,
      year: identity.year,
      subtitle: request.subtitle,
    };
  }
  return submitTorrentDownload({
    site_id: request.site_id,
    download_url: request.download_url,
    torrent_id: request.torrent_id,
    // 这条路径必然已有记忆、且用户刚在确认条上确认过它，照常带分类续记——
    // 确认条上「上次用过 · N 天前」靠这次刷新才说得准
    category: request.category,
    ...libraryPart,
    ...(target.kind === "dir" ? { save_path: target.save_path } : {}),
    ...(target.downloader_id != null ? { downloader_id: target.downloader_id } : {}),
  });
}

/** 与后端 translate_save_path 同规则的前端版（仅用于展示下载器视角）。 */
function toRemoteView(path: string, mappings: PathMapping[] | null): string {
  if (!mappings) return path;
  let best: PathMapping | null = null;
  for (const m of mappings) {
    const local = m.local.replace(/\/+$/, "");
    if (
      (path === local || path.startsWith(local + "/")) &&
      (best === null || local.length > best.local.replace(/\/+$/, "").length)
    ) {
      best = m;
    }
  }
  if (!best) return path;
  const local = best.local.replace(/\/+$/, "");
  return best.remote.replace(/\/+$/, "") + path.slice(local.length);
}

/** 候选身份按（类型, TMDB ID）确定：电影与剧集的 ID 各自编号，会撞号。 */
type CandidateKey = Pick<ManualDownloadTargetCandidate, "kind" | "tmdb_id">;

/** 预检的识别线索：种子身份（有则带）+ 搜索词。 */
function resolveClues(request: DownloadTargetRequest, hint: string | null) {
  return { ...(request.identity ?? {}), subtitle: request.subtitle, hint };
}

const KIND_LABEL = { movie: "电影", tv: "剧集" } as const;

/** 一个可选的保存目标。 */
interface TargetOption {
  key: string;
  kind: "smart" | "dir" | "default";
  /** 提交时的 save_path（smart/default 为 null，走各自的后端语义） */
  savePath: string | null;
  label: string;
  /** 次级说明（路径、双视角、警示等） */
  detail: string | null;
  warning: string | null;
}

export function DownloadTargetDialog({
  request,
  remembered = null,
  reason = null,
  onClose,
  onSubmitted,
  topmost = false,
}: {
  /** null = 关闭 */
  request: DownloadTargetRequest | null;
  /** 该分类已有的记忆：用于预选中对应项；null = 没有记忆，按默认规则挑 */
  remembered?: DownloadTargetPref | null;
  /** 记忆失效时的中文原因，显示在弹窗顶部；静默回落是原实现最让人困惑的地方 */
  reason?: string | null;
  onClose: () => void;
  onSubmitted: (result: DownloadSubmitResult) => void;
  /** 触发按钮长在灯箱这类高层浮层里时置位，弹窗抬到最高层（见 Modal 的层级约定） */
  topmost?: boolean;
}) {
  const { isAdmin } = usePermissions();
  if (!request) return null;
  if (!isAdmin) {
    return (
      <MemberDialogContent
        key={`${request.site_id}:${request.download_url}`}
        request={request}
        topmost={topmost}
        onClose={onClose}
        onSubmitted={onSubmitted}
      />
    );
  }
  // 以 request 为 key 强制内容组件重新挂载：每次打开都从全新状态开始，
  // 避免默认选中 effect 读到上一次的旧数据抢先选中错误项。
  return (
    <DialogContent
      key={`${request.site_id}:${request.download_url}`}
      request={request}
      remembered={remembered}
      reason={reason}
      topmost={topmost}
      onClose={onClose}
      onSubmitted={onSubmitted}
    />
  );
}

function DialogContent({
  request,
  remembered,
  reason,
  onClose,
  onSubmitted,
  topmost,
}: {
  request: DownloadTargetRequest;
  remembered: DownloadTargetPref | null;
  reason: string | null;
  onClose: () => void;
  onSubmitted: (result: DownloadSubmitResult) => void;
  topmost: boolean;
}) {
  // 记忆是「智能入库」时不必展开目录列表——预选的就是它
  const rememberedTarget = remembered;
  // 既没身份也没搜索词才一开始就摊开目录；有线索时先让用户回答「这是哪部」，
  // 目录收在「其他保存位置」里——摊开的目录会被默认选中，用户一点确认就又
  // 下进了不会自动入库的目录，正是本弹窗要避免的结局
  const canResolve = request.identity !== null || !!request.hint;
  const revealOtherInitially =
    !canResolve || (rememberedTarget !== null && rememberedTarget.kind !== "smart");
  // 可用（启用 + 验证通过）的全部下载器：≥2 台时出现下载器选择
  const [downloaders, setDownloaders] = useState<ConfiguredDownloader[]>([]);
  const [downloaderId, setDownloaderId] = useState<number | null>(
    rememberedTarget?.kind === "smart" ? rememberedTarget.downloader_id : null,
  );
  const [manualTarget, setManualTarget] = useState<ManualDownloadTarget | null>(null);
  // 「这是哪部作品？」：自动识别没收敛（或种子没身份）时进入确认模式，此后
  // 候选与搜索框常驻，确认后仍可改选
  const [picking, setPicking] = useState(!request.identity);
  // 候选单独留一份：点候选重跑预检期间不清空，避免整排候选闪没再出现
  const [candidates, setCandidates] = useState<ManualDownloadTargetCandidate[]>([]);
  const [selectedCandidate, setSelectedCandidate] = useState<CandidateKey | null>(null);
  // 当前生效的搜索词（换个词搜后更新）与输入框草稿
  const [hint, setHint] = useState<string | null>(request.hint);
  const [hintDraft, setHintDraft] = useState(request.hint ?? "");
  const [showOtherTargets, setShowOtherTargets] = useState(revealOtherInitially);
  const [downloadersLoaded, setDownloadersLoaded] = useState(false);
  const [loadingDownloaders, setLoadingDownloaders] = useState(false);
  const [loadingTarget, setLoadingTarget] = useState(canResolve);
  const [selected, setSelected] = useState<string | null>(null);
  // 「记住本次选择」：已有记忆时默认勾上（从确认条「更改」进来就是要改它），
  // 首次下载该分类默认不勾（见文件头注释）
  const [remember, setRemember] = useState(rememberedTarget !== null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 下载器切换/候选确认都可能重发预检，只允许最后一次请求更新界面。
  const targetRequestId = useRef(0);

  // 默认路径只做智能预检，不拉下载器配置；只有用户展开“其他保存位置”或
  // 智能识别失败时才加载下载器与路径映射，减少每次点下载的固定请求成本。
  useEffect(() => {
    let cancelled = false;
    const requestId = ++targetRequestId.current;
    setSelectedCandidate(null);
    if (!request.identity && !request.hint) {
      setLoadingTarget(false);
      setShowOtherTargets(true);
      return () => {
        cancelled = true;
        targetRequestId.current += 1;
      };
    }

    setLoadingTarget(true);
    void resolveManualDownloadTarget({
      ...resolveClues(request, request.hint),
      downloader_id: rememberedTarget?.kind === "smart" ? rememberedTarget.downloader_id : null,
    })
      .then((target) => {
        if (cancelled || requestId !== targetRequestId.current) return;
        setManualTarget(target);
        setCandidates(target.candidates);
        if (target.status !== "ready") setPicking(true);
        // 有候选可点时目录继续收着（等用户回答「这是哪部」）；找不到/配置
        // 不能自动入库时才摊开目录作兜底
        if (target.status === "not_found" || (target.status === "ready" && !target.ok)) {
          setShowOtherTargets(true);
        }
      })
      .catch(() => {
        if (cancelled || requestId !== targetRequestId.current) return;
        setManualTarget(null);
        setShowOtherTargets(true);
      })
      .finally(() => {
        if (!cancelled && requestId === targetRequestId.current) setLoadingTarget(false);
      });
    return () => {
      cancelled = true;
      targetRequestId.current += 1;
    };
  }, [rememberedTarget, request]);

  /** 用当前下载器、搜索词和（如有）用户确认的候选重跑预检。 */
  const reloadManualTarget = useCallback(
    (nextDownloaderId: number | null, candidate: CandidateKey | null, nextHint: string | null) => {
      if (!request.identity && !nextHint) return;
      const requestId = ++targetRequestId.current;
      setLoadingTarget(true);
      setManualTarget(null);
      void resolveManualDownloadTarget({
        ...resolveClues(request, nextHint),
        downloader_id: nextDownloaderId,
        selected_tmdb_id: candidate?.tmdb_id ?? null,
        selected_kind: candidate?.kind ?? null,
      })
        .then((target) => {
          if (requestId !== targetRequestId.current) return;
          setManualTarget(target);
          setCandidates(target.candidates);
          if (target.status === "not_found") setShowOtherTargets(true);
          // 用户刚点选了条目：直接选中随之出现的「自动入库」——不然选中项还停在
          // 先前默认的目录上，用户以为已确认入库，实际下进了普通目录
          if (candidate && target.status === "ready" && target.ok) setSelected("smart");
        })
        .catch(() => {
          if (requestId === targetRequestId.current) setManualTarget(null);
        })
        .finally(() => {
          if (requestId === targetRequestId.current) setLoadingTarget(false);
        });
    },
    [request],
  );

  // “其他保存位置”展开后才读取下载器配置；加载完成后若最终选中的不是
  // 初始预检使用的下载器，再补一次预检以保持路径映射口径一致。
  useEffect(() => {
    if (!showOtherTargets || downloadersLoaded) return;
    let cancelled = false;
    setLoadingDownloaders(true);
    void listDownloaders()
      .then((rows) => rows.filter((d) => d.usable))
      .catch(() => [] as ConfiguredDownloader[])
      .then((usable) => {
        if (cancelled) return;
        const current = usable.find((d) => d.id === downloaderId);
        const remembered =
          rememberedTarget?.downloader_id != null
            ? usable.find((d) => d.id === rememberedTarget.downloader_id)
            : undefined;
        const selectedDownloader =
          current ?? remembered ?? usable.find((d) => d.is_default) ?? usable[0] ?? null;
        const selectedDownloaderId = selectedDownloader?.id ?? null;
        const preflightDownloaderId =
          selectedDownloader && !selectedDownloader.is_default ? selectedDownloader.id : null;
        setDownloaders(usable);
        setDownloaderId(selectedDownloaderId);
        setDownloadersLoaded(true);
        setLoadingDownloaders(false);
        if (canResolve && preflightDownloaderId !== downloaderId) {
          reloadManualTarget(preflightDownloaderId, selectedCandidate, hint);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [
    canResolve,
    downloaderId,
    downloadersLoaded,
    hint,
    reloadManualTarget,
    rememberedTarget,
    selectedCandidate,
    showOtherTargets,
  ]);

  const downloader = useMemo(
    () => downloaders.find((d) => d.id === downloaderId) ?? null,
    [downloaders, downloaderId],
  );

  const options = useMemo<TargetOption[]>(() => {
    const result: TargetOption[] = [];
    if (
      manualTarget?.status === "ready" &&
      manualTarget.tmdb_id != null &&
      manualTarget.library_id != null &&
      manualTarget.ok
    ) {
      // 条目目录由后端按命名模板渲染（entry_dir），前端不再自己拼名字——
      // 模板可全局/按库自定义，自己拼出来的预览会与真实落点不符
      const entryDir = manualTarget.entry_dir ?? manualTarget.path;
      const detail =
        manualTarget.mode === "watch"
          ? manualTarget.staging_path
            ? `${manualTarget.route_reason ?? ""}；投递到自动入库的监听目录 ${manualTarget.path}，完成后整理到 ${manualTarget.staging_path}（外部流转回库根后入账）`
            : `${manualTarget.route_reason ?? ""}；投递到自动入库的监听目录 ${manualTarget.path}，完成后自动整理入库`
          : manualTarget.mode === "inplace"
            ? `${manualTarget.route_reason ?? ""}；直接下载到 ${entryDir?.replace(/\/+$/, "")}，完成后自动入账`
            : null;
      result.push({
        key: "smart",
        kind: "smart",
        savePath: null,
        label: `自动入库到「${manualTarget.library_name}」`,
        detail,
        warning: null,
      });
    }
    if (showOtherTargets) {
      const seen = new Set<string>();
      const dirs: { path: string; source: string }[] = [];
      if (downloader?.save_path) {
        dirs.push({ path: downloader.save_path, source: "默认保存目录" });
      }
      for (const m of downloader?.path_mappings ?? []) {
        if (!seen.has(m.local) && m.local !== downloader?.save_path) {
          dirs.push({ path: m.local, source: "路径映射" });
        }
        seen.add(m.local);
      }
      for (const dir of dirs) {
        const remote = toRemoteView(dir.path, downloader?.path_mappings ?? null);
        result.push({
          key: `dir:${dir.path}`,
          kind: "dir",
          savePath: dir.path,
          label: dir.path,
          detail: remote !== dir.path ? `下载器视角：${remote}（${dir.source}）` : dir.source,
          warning: null,
        });
      }
      result.push({
        key: "default",
        kind: "default",
        savePath: null,
        label: "下载器默认目录",
        detail: "不指定路径，由下载器按自身设置决定；movieclaw 不会自动整理入库",
        warning: null,
      });
    }
    return result;
  }, [manualTarget, downloader, showOtherTargets]);

  // 换下载器后目录候选整组换血：选中的目录项若已不存在，退回未选中让下方
  // 默认选中逻辑重新挑一个
  useEffect(() => {
    setSelected((prev) => (prev && options.some((o) => o.key === prev) ? prev : null));
  }, [options]);

  // 默认选中：已记住的目标 > 智能入库可用且预检通过 > 第一个目录 > 下载器默认
  useEffect(() => {
    if (options.length === 0 || selected !== null) return;
    if (rememberedTarget) {
      const match = options.find((o) =>
        rememberedTarget.kind === "dir"
          ? o.kind === "dir" && o.savePath === rememberedTarget.save_path
          : o.kind === rememberedTarget.kind,
      );
      if (match) {
        setSelected(match.key);
        return;
      }
    }
    // 没有记忆时等两边都返回再自动选择，避免目录先到就抢选、随后智能结果
    // 出现却无法成为默认；等待期间用户仍可手动点已显示的目录立即提交。
    if (loadingTarget || (showOtherTargets && !downloadersLoaded)) return;
    const smart = options.find((o) => o.kind === "smart");
    if (smart && !smart.warning) setSelected(smart.key);
    // 智能入库不可用或有警示时，回落到第一个非智能项（目录 > 下载器默认）
    else setSelected((options.find((o) => o.kind !== "smart") ?? options[0]).key);
  }, [downloadersLoaded, loadingTarget, options, selected, rememberedTarget, showOtherTargets]);

  const submit = () => {
    const option = options.find((o) => o.key === selected);
    if (!option || busy) return;
    setBusy(true);
    setError(null);
    // 只在非默认下载器时显式带 downloader_id：默认台走后端原有语义
    const pickedDownloaderId = downloader
      ? downloader.is_default
        ? null
        : downloader.id
      : downloaderId;
    void submitTorrentDownload({
      site_id: request.site_id,
      download_url: request.download_url,
      torrent_id: request.torrent_id,
      // 只有勾了「记住本次选择」才带分类：后端拿不到分类就不写记忆
      ...(remember ? { category: request.category } : {}),
      // 身份一律取预检确认的结论（类型可能与种子解析的不同，标题是 TMDB
      // 标题——它会进条目别名，不能拿乱码的种子标题去污染）
      ...(option.kind === "smart" &&
      manualTarget?.tmdb_id != null &&
      manualTarget.kind &&
      manualTarget.title
        ? {
            auto_route: true,
            media_kind: manualTarget.kind,
            tmdb_id: manualTarget.tmdb_id,
            title: manualTarget.title,
            year: manualTarget.year,
            subtitle: request.subtitle,
          }
        : {}),
      ...(option.kind === "dir" ? { save_path: option.savePath } : {}),
      ...(pickedDownloaderId != null ? { downloader_id: pickedDownloaderId } : {}),
    })
      .then((result) => {
        onSubmitted(result);
        onClose();
      })
      .catch((e) => setError(e instanceof Error ? e.message : "提交失败，请重试"))
      .finally(() => setBusy(false));
  };

  return (
    <Modal open topmost={topmost} onClose={onClose} label="选择保存位置">
      {/* 头部常驻：目录一多就得滚，标题不跟着滚走才知道自己在选什么 */}
      <div className="border-b border-white/[0.07] px-6 pb-4 pt-6">
        <h2 className="text-title font-bold text-white">选择保存位置</h2>
      </div>

      <div className="scroll-thin min-h-0 flex-1 space-y-4 overflow-y-auto px-6 py-4">
        {reason && (
          <p className="rounded-xl border border-[var(--warn-line,rgba(245,196,81,.28))] bg-[rgba(245,196,81,.09)] px-3 py-2 text-sub leading-relaxed text-[#f6dfab]">
            {reason}
          </p>
        )}
          {error && (
            <p className="rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2.5 text-ui leading-6 text-red-200">
              {error}
            </p>
          )}

          <div className="space-y-2">
              {picking && (
                <CandidatePicker
                  status={manualTarget?.status ?? null}
                  busy={loadingTarget}
                  hint={hint}
                  candidates={candidates}
                  selected={selectedCandidate}
                  draft={hintDraft}
                  onDraftChange={setHintDraft}
                  onPick={(candidate) => {
                    const key = { kind: candidate.kind, tmdb_id: candidate.tmdb_id };
                    setSelectedCandidate(key);
                    reloadManualTarget(downloaderId, key, hint);
                  }}
                  onSearch={(q) => {
                    setHint(q);
                    setSelectedCandidate(null);
                    reloadManualTarget(downloaderId, null, q);
                  }}
                />
              )}
              {loadingTarget && (
                <div className="flex h-[52px] items-center rounded-xl border border-white/[0.06] bg-white/[0.03] px-3.5 text-caption text-[var(--text-faint)]">
                  {selectedCandidate ? "正在预演自动入库…" : "正在识别影视条目并预演智能入库…"}
                </div>
              )}
              {!loadingTarget && canResolve && manualTarget === null && (
                <p className="rounded-lg border border-amber-400/20 bg-amber-500/10 px-3.5 py-2.5 text-caption leading-relaxed text-amber-100">
                  自动识别暂不可用；为避免投错库请手选保存目录后再下载。
                </p>
              )}
              {!loadingTarget && manualTarget?.status === "ready" && !manualTarget.ok && (
                <p className="rounded-lg border border-amber-400/20 bg-amber-500/10 px-3.5 py-2.5 text-caption leading-relaxed text-amber-100">
                  已识别资源，但当前不能自动入库：{manualTarget.warning ?? "请检查媒体库和自动入库配置。"}
                </p>
              )}
              {showOtherTargets && loadingDownloaders && (
                <div className="h-[52px] animate-pulse rounded-xl bg-white/[0.04]" />
              )}
              {options.map((option) => (
                <button
                  key={option.key}
                  type="button"
                  onClick={() => setSelected(option.key)}
                  data-active={selected === option.key}
                  className="flex w-full items-start gap-2.5 rounded-xl border border-white/[0.08] bg-white/[0.04] px-3.5 py-2.5 text-left transition-colors hover:border-[var(--accent)]/50 data-[active=true]:border-[var(--accent)]/70 data-[active=true]:bg-[var(--accent-soft)]"
                >
                  <FolderIcon className="mt-0.5 size-4 shrink-0 text-[var(--accent)]/80" />
                  <span className="min-w-0 flex-1">
                    <span className="block truncate font-mono text-ui font-medium text-[var(--text)]">
                      {option.label}
                    </span>
                    {option.detail && (
                      <span className="mt-0.5 block text-caption leading-relaxed text-[var(--text-faint)]">
                        {option.detail}
                      </span>
                    )}
                    {option.warning && (
                      <span className="mt-1 block rounded-md bg-amber-500/10 px-2 py-1 text-caption leading-relaxed text-amber-200">
                        {option.warning}
                      </span>
                    )}
                  </span>
                </button>
              ))}
              {/* 收在自动入库选项之后：点完候选，视线从条目直接落到入库结论 */}
              {!showOtherTargets && (
                <button
                  type="button"
                  onClick={() => setShowOtherTargets(true)}
                  className="w-full rounded-xl border border-dashed border-white/[0.1] px-3.5 py-2.5 text-left text-ui text-[var(--text-muted)] transition-colors hover:border-white/20 hover:bg-white/[0.03] hover:text-white/90"
                >
                  其他保存位置
                </button>
              )}
            </div>

          {/* 下载器分流：≥2 台可用才出现（单台用户界面零变化），默认预选默认台 */}
          {showOtherTargets && downloaders.length >= 2 && (
            <div className="flex items-center gap-2.5">
              <span className="shrink-0 text-sub text-[var(--text-muted)]">下载器</span>
              <select
                value={downloaderId ?? undefined}
                onChange={(e) => {
                  const nextDownloaderId = Number(e.target.value);
                  setDownloaderId(nextDownloaderId);
                  reloadManualTarget(nextDownloaderId, selectedCandidate, hint);
                }}
                className="min-w-0 flex-1 rounded-lg border border-white/[0.08] bg-white/[0.04] px-3 py-1.5 text-sub text-white/90 outline-none focus:border-white/25 [&>option]:bg-[#181c28]"
              >
                {downloaders.map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.name}
                    {d.is_default ? "（默认）" : ""}
                  </option>
                ))}
              </select>
            </div>
          )}

          {/* 记住与否由用户自己定：勾了才写记忆，不勾就只作用于这一次下载。
              勾选态下的副行说明「记住之后会发生什么」，免得用户以为一勾上
              以后就自动提交了——实际是先弹确认条给他看落点 */}
          <label className="flex cursor-pointer items-start gap-2.5 rounded-xl border border-white/[0.08] bg-white/[0.03] px-3.5 py-2.5">
            <input
              type="checkbox"
              checked={remember}
              onChange={(e) => setRemember(e.target.checked)}
              className="mt-0.5 size-4 shrink-0 cursor-pointer accent-[var(--accent)]"
            />
            <span className="min-w-0 flex-1">
              <span className="block text-ui text-[var(--text)]">
                记住本次选择，作为「
                {CATEGORY_LABEL[request.category as TorrentCategory] ?? request.category}
                」的默认位置
              </span>
              <span className="mt-0.5 block text-caption leading-relaxed text-[var(--text-faint)]">
                {remember
                  ? "之后点「下载」先给你确认一次落点，随时可以改，或在确认条上「不再记住」。"
                  : "不勾选就只对这一次下载生效，不会留下默认位置。"}
              </span>
            </span>
          </label>

          {showOtherTargets && (
            <p className="text-caption leading-relaxed text-[var(--text-faint)]">
              movieclaw 与下载器不在同一容器/主机、看到的路径不同？到
              <Link
                href="/settings/downloaders"
                className="mx-0.5 text-[var(--accent)] hover:underline"
              >
                设置 → 下载器
              </Link>
              配置路径映射，提交时会自动翻译成下载器视角。
            </p>
          )}
      </div>

      {/* 底栏常驻：确认按钮永远在屏幕上，不必先把长列表滚到底才找得到 */}
      <div className="flex justify-end gap-3 border-t border-white/[0.07] px-6 py-4">
        <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
          取消
        </button>
        <button
          type="button"
          onClick={submit}
          disabled={busy || selected === null}
          className="btn-accent h-9 rounded-full px-5 text-ui font-semibold disabled:opacity-40"
        >
          {busy
            ? "提交中…"
            : selected === "smart" && manualTarget?.library_name
              ? `下载到「${manualTarget.library_name}」`
              : "确认下载"}
        </button>
      </div>
    </Modal>
  );
}

/** 成员弹窗里「下载器默认目录」选项的 key（库选项用库 id 的字符串）。 */
const MEMBER_DEFAULT_KEY = "default";

/**
 * 成员版保存位置弹窗：不碰任何下载器配置接口，只列成员可见的媒体库 + 下载器默认目录。
 *
 * 选库时提交 library_id（后端校验该库对成员可见，再按库的入库规则推导保存目录：
 * 有监听导入规则走规则源目录，否则落到「主根/标题 (年份)」），种子解析出的
 * 片名年份随之带上用于推导条目子目录；不选库就交给下载器默认目录，不会自动入库。
 * 默认选中：种子类型对得上的默认库 > 同类型第一个库 > 下载器默认目录。
 */
function MemberDialogContent({
  request,
  onClose,
  onSubmitted,
  topmost,
}: {
  request: DownloadTargetRequest;
  onClose: () => void;
  onSubmitted: (result: DownloadSubmitResult) => void;
  topmost: boolean;
}) {
  // null = 加载中；拉失败按空列表处理，仍可选下载器默认目录
  const [libraries, setLibraries] = useState<MediaLibrary[] | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const kind = request.identity?.kind ?? null;

  useEffect(() => {
    let cancelled = false;
    void listLibraries()
      .catch(() => [] as MediaLibrary[])
      .then((all) => {
        if (cancelled) return;
        // 照片库不收视频下载；与种子类型一致的库排前面，其余保持原顺序
        const rows = all.filter((l) => l.kind !== "photo");
        const sorted = kind
          ? [...rows.filter((l) => l.kind === kind), ...rows.filter((l) => l.kind !== kind)]
          : rows;
        setLibraries(sorted);
        const sameKind = kind ? rows.filter((l) => l.kind === kind) : [];
        const preferred = sameKind.find((l) => l.is_default) ?? sameKind[0] ?? null;
        setSelected(preferred ? String(preferred.id) : MEMBER_DEFAULT_KEY);
      });
    return () => {
      cancelled = true;
    };
  }, [kind]);

  const submit = () => {
    if (selected === null || busy) return;
    const libraryId = selected === MEMBER_DEFAULT_KEY ? null : Number(selected);
    setBusy(true);
    setError(null);
    void submitTorrentDownload({
      site_id: request.site_id,
      download_url: request.download_url,
      torrent_id: request.torrent_id,
      ...(libraryId !== null
        ? {
            library_id: libraryId,
            // 片名年份只在种子身份三件套齐全时带：推导条目子目录用，猜错会进错目录
            title: request.identity?.title ?? null,
            year: request.identity?.year ?? null,
            subtitle: request.subtitle,
          }
        : {}),
    })
      .then((result) => {
        onSubmitted(result);
        onClose();
      })
      .catch((e) => setError(e instanceof Error ? e.message : "提交失败，请重试"))
      .finally(() => setBusy(false));
  };

  const picked =
    selected !== null && selected !== MEMBER_DEFAULT_KEY
      ? (libraries?.find((l) => String(l.id) === selected) ?? null)
      : null;
  const optionClass =
    "flex w-full items-start gap-2.5 rounded-xl border border-white/[0.08] bg-white/[0.04] px-3.5 py-2.5 text-left transition-colors hover:border-[var(--accent)]/50 data-[active=true]:border-[var(--accent)]/70 data-[active=true]:bg-[var(--accent-soft)]";

  return (
    <Modal open topmost={topmost} onClose={onClose} label="选择保存位置">
      <div className="border-b border-white/[0.07] px-6 pb-4 pt-6">
        <h2 className="text-title font-bold text-white">选择保存位置</h2>
      </div>

      <div className="scroll-thin min-h-0 flex-1 space-y-2 overflow-y-auto px-6 py-4">
        {error && (
          <p className="rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2.5 text-ui leading-6 text-red-200">
            {error}
          </p>
        )}
        {libraries === null ? (
          <div className="h-[52px] animate-pulse rounded-xl bg-white/[0.04]" />
        ) : (
          <>
            {libraries.map((library) => (
              <button
                key={library.id}
                type="button"
                onClick={() => setSelected(String(library.id))}
                data-active={selected === String(library.id)}
                className={optionClass}
              >
                <FolderIcon className="mt-0.5 size-4 shrink-0 text-[var(--accent)]/80" />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-ui font-medium text-[var(--text)]">
                    下载到「{library.name}」
                  </span>
                  <span className="mt-0.5 block text-caption leading-relaxed text-[var(--text-faint)]">
                    {library.kind === kind || !kind
                      ? "按该库的入库规则保存，下载完成后自动整理入库"
                      : `该库是${LIBRARY_KIND_LABEL[library.kind] ?? "其他"}库，与这条资源的类型不一致`}
                  </span>
                </span>
              </button>
            ))}
            <button
              type="button"
              onClick={() => setSelected(MEMBER_DEFAULT_KEY)}
              data-active={selected === MEMBER_DEFAULT_KEY}
              className={optionClass}
            >
              <FolderIcon className="mt-0.5 size-4 shrink-0 text-[var(--accent)]/80" />
              <span className="min-w-0 flex-1">
                <span className="block truncate text-ui font-medium text-[var(--text)]">
                  下载器默认目录
                </span>
                <span className="mt-0.5 block text-caption leading-relaxed text-[var(--text-faint)]">
                  不指定位置，由下载器按自身设置决定；不会自动整理入库
                </span>
              </span>
            </button>
          </>
        )}
      </div>

      <div className="flex justify-end gap-3 border-t border-white/[0.07] px-6 py-4">
        <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
          取消
        </button>
        <button
          type="button"
          onClick={submit}
          disabled={busy || selected === null}
          className="btn-accent h-9 rounded-full px-5 text-ui font-semibold disabled:opacity-40"
        >
          {busy ? "提交中…" : picked ? `下载到「${picked.name}」` : "确认下载"}
        </button>
      </div>
    </Modal>
  );
}

const LIBRARY_KIND_LABEL: Partial<Record<MediaLibrary["kind"], string>> = {
  movie: "电影",
  tv: "剧集",
  video: "视频",
};

/**
 * 「这是哪部作品？」：自动识别没收敛时的条目确认区。
 *
 * 候选来自种子标题的歧义结果 + 用户搜索词的 TMDB 检索，点一下即确认，随后
 * 自动预演入库；候选都不对时就地换个词搜——不跳页、不手抄 TMDB ID。
 */
function CandidatePicker({
  status,
  busy,
  hint,
  candidates,
  selected,
  draft,
  onDraftChange,
  onPick,
  onSearch,
}: {
  /** 最近一次预检的状态；null = 还没有结论（进行中，或既无身份也无搜索词） */
  status: ManualDownloadTarget["status"] | null;
  busy: boolean;
  hint: string | null;
  candidates: ManualDownloadTargetCandidate[];
  selected: CandidateKey | null;
  draft: string;
  onDraftChange: (value: string) => void;
  onPick: (candidate: ManualDownloadTargetCandidate) => void;
  onSearch: (q: string) => void;
}) {
  const caption =
    !busy && status === "not_found"
      ? hint
        ? `没找到与「${hint}」匹配的作品，换个片名试试（中文名搜不到时可试英文/原名）。`
        : "输入片名搜索，确认后会自动分配媒体库。"
      : candidates.length > 0
        ? "没能自动认出这条资源。点选正确的作品，媒体库会按收藏范围自动分配。"
        : "输入片名搜索，确认后会自动分配媒体库。";
  const submitSearch = () => {
    const q = draft.trim();
    if (q) onSearch(q);
  };
  return (
    <div className="space-y-2.5 rounded-xl border border-amber-400/20 bg-amber-500/[0.06] px-3.5 py-3">
      <div>
        <p className="text-ui font-medium text-[var(--text)]">这是哪部作品？</p>
        <p className="mt-0.5 text-caption leading-relaxed text-[var(--text-faint)]">{caption}</p>
      </div>
      {candidates.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {candidates.map((candidate) => {
            const active =
              selected?.kind === candidate.kind && selected.tmdb_id === candidate.tmdb_id;
            return (
              <button
                key={`${candidate.kind}:${candidate.tmdb_id}`}
                type="button"
                onClick={() => onPick(candidate)}
                data-active={active}
                className="flex max-w-full items-center gap-2 rounded-lg border border-white/[0.1] bg-white/[0.04] py-1 pl-1 pr-3 text-left transition-colors hover:border-[var(--accent)]/50 data-[active=true]:border-[var(--accent)]/70 data-[active=true]:bg-[var(--accent-soft)]"
              >
                {candidate.poster_url ? (
                  <img
                    {...responsiveImage(imageUrl(candidate.poster_url), 24)}
                    alt=""
                    loading="lazy"
                    decoding="async"
                    // 图床不通时别露破图标，留空底色占位即可
                    onError={(e) => {
                      e.currentTarget.style.visibility = "hidden";
                    }}
                    className="h-9 w-6 shrink-0 rounded bg-white/[0.05] object-cover"
                  />
                ) : (
                  <span className="h-9 w-6 shrink-0 rounded bg-white/[0.05]" />
                )}
                <span className="min-w-0">
                  <span className="block truncate text-caption text-[var(--text)]">
                    {candidate.title}
                    {candidate.year ? ` (${candidate.year})` : ""}
                  </span>
                  <span className="block text-caption text-[var(--text-faint)]">
                    {KIND_LABEL[candidate.kind]}
                    {candidate.episode_count ? ` · ${candidate.episode_count} 集` : ""}
                  </span>
                </span>
              </button>
            );
          })}
        </div>
      )}
      <div className="flex items-center gap-2">
        <input
          type="text"
          value={draft}
          onChange={(e) => onDraftChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") submitSearch();
          }}
          placeholder={candidates.length > 0 ? "都不对？换个片名搜" : "输入片名"}
          aria-label="按片名搜索作品"
          className="min-w-0 flex-1 rounded-lg border border-white/[0.08] bg-white/[0.04] px-3 py-1.5 text-sub text-[var(--text)] outline-none placeholder:text-white/30 focus:border-[var(--accent)]/60"
        />
        <button
          type="button"
          disabled={!draft.trim() || busy}
          onClick={submitSearch}
          className="btn-glass shrink-0 px-3.5 py-1.5 text-sub font-medium disabled:opacity-40"
        >
          搜索
        </button>
      </div>
    </div>
  );
}

/* —— 确认条：命中记忆时代替静默提交 —— */

/** 记忆里存的目标翻译成人话（确认条主行）。 */
function targetHeadline(target: DownloadTargetPref, resolvedPath: string | null): string | null {
  if (target.kind === "dir") return target.save_path;
  if (target.kind === "default") return "下载器的默认目录";
  return resolvedPath; // smart：要等预检算出来
}

/**
 * 保存位置确认条。命中记忆时点「下载」弹它，而不是直接提交。
 *
 * 为什么不沿用原来的静默快速通道：那样点下去种子就已经进了下载器，记忆不对
 * 只能事后补救。这里多一次点击，换来的是**提交前就看得见落点**——批量下载的
 * 代价从「1 次点击 + 不知道去哪」变成「2 次点击 + 全程可见」。
 *
 * 也不做 split button（结果行内主按钮 + 下拉箭头）：移动端那一行已经很挤。
 * 确认条是横向浮层，窄屏纵向堆成三行，不占结果行的横向空间。
 */
export function DownloadTargetConfirmBar({
  request,
  target,
  topmost = false,
  onConfirm,
  onChange,
  onForget,
  onClose,
}: {
  request: DownloadTargetRequest;
  target: DownloadTargetPref;
  /**
   * 触发按钮长在灯箱（z-70）这类高层浮层里时必须置位，与完整弹窗同一口径。
   * 漏传的后果不是"样式不好看"而是**看起来点了没反应**：确认条按普通弹窗
   * 的 z-50 渲染，整条被灯箱那层不透明底盖住，用户什么也看不见。
   */
  topmost?: boolean;
  onConfirm: () => void;
  onChange: () => void;
  /** 「不再记住」：清除该分类记忆后展开完整弹窗重选 */
  onForget: () => void;
  onClose: () => void;
}) {
  // smart 目标存的是策略不是路径，得重跑预检才知道这次落到哪
  const [resolvedPath, setResolvedPath] = useState<string | null>(null);
  const [preflighting, setPreflighting] = useState(target.kind === "smart");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const identity = request.identity;
    if (target.kind !== "smart" || !identity) return;
    let cancelled = false;
    setPreflighting(true);
    void resolveManualDownloadTarget({
      kind: identity.kind,
      title: identity.title,
      year: identity.year,
      subtitle: request.subtitle,
      downloader_id: target.downloader_id,
    })
      .then((t) => {
        if (!cancelled) setResolvedPath(t.entry_dir ?? t.path ?? null);
      })
      .catch(() => {
        if (!cancelled) setResolvedPath(null);
      })
      .finally(() => {
        if (!cancelled) setPreflighting(false);
      });
    return () => {
      cancelled = true;
    };
  }, [request, target]);

  const label = CATEGORY_LABEL[request.category as TorrentCategory] ?? request.category;
  const headline = targetHeadline(target, resolvedPath);

  return (
    <Modal open topmost={topmost} onClose={onClose} label="确认保存位置">
      <div className="flex items-start gap-3 px-5 pb-3 pt-5">
        <span className="mt-0.5 grid size-8 shrink-0 place-items-center rounded-[9px] bg-[var(--accent-soft)]">
          <FolderIcon className="size-4 text-[var(--accent)]" />
        </span>
        <div className="min-w-0 flex-1">
          <div className="text-caption uppercase tracking-[0.09em] text-[var(--text-faint)]">
            保存到
          </div>
          <div className="mt-0.5 flex flex-wrap items-center gap-2">
            <b className="text-body font-semibold text-white">{label}</b>
            <span className="size-[3px] rounded-full bg-[var(--text-faint)]" />
            <span className="text-sub text-[var(--text-muted)]">
              {target.kind === "smart"
                ? "智能入库"
                : (target.downloader_name ?? "默认下载器")}
            </span>
          </div>
          {/* 预检未回来时占位骨架：先让用户看到「在确认什么」，比整条延迟出现
              少一次视觉跳变 */}
          {preflighting ? (
            <div className="mt-1.5 space-y-1.5" aria-label="正在确认归宿">
              <div className="h-2.5 w-3/4 animate-pulse rounded bg-white/10" />
              <div className="h-2.5 w-2/5 animate-pulse rounded bg-white/10" />
            </div>
          ) : (
            <p className="mt-1 break-all font-mono text-caption leading-relaxed text-white">
              {headline ?? "由下载器决定"}
            </p>
          )}
        </div>
      </div>

      <div className="flex flex-col gap-2.5 border-t border-white/[0.07] px-5 py-3 sm:flex-row sm:items-center sm:justify-between">
        <span className="text-center text-caption text-[var(--text-faint)] sm:text-left">
          上次用过 · {formatRelativeTime(target.updated_at)} ·{" "}
          <button
            type="button"
            onClick={onForget}
            className="text-[var(--accent-2)] underline underline-offset-2 hover:text-[var(--accent)]"
          >
            不再记住
          </button>
        </span>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={onChange}
            className="btn-glass h-9 flex-1 px-4 text-ui font-medium sm:flex-none"
          >
            更改
          </button>
          <button
            type="button"
            disabled={busy || preflighting}
            onClick={() => {
              setBusy(true);
              onConfirm();
            }}
            className="btn-accent h-9 flex-1 rounded-full px-5 text-ui font-semibold disabled:opacity-40 sm:flex-none"
          >
            {busy ? "提交中…" : "确认下载"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
