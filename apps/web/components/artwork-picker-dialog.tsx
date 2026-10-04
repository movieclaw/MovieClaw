"use client";

import { type CSSProperties, useCallback, useEffect, useState } from "react";

import { BrandLoader } from "@/components/brand-loader";
import { Modal } from "@/components/modal";
import {
  type ArtworkCandidate,
  type ArtworkCandidates,
  type ArtworkKind,
  listArtworkCandidates,
  selectArtwork,
} from "@/lib/api/libraries";
import { cachedImageUrl, responsiveImage } from "@/lib/image-proxy";

/** tab 顺序与文案：label 用在 tab 与锁定提示，noun 用在"没有候选"的句子里 */
const TABS: { key: ArtworkKind; label: string; noun: string }[] = [
  { key: "backdrop", label: "背景", noun: "背景图" },
  { key: "poster", label: "海报", noun: "海报" },
  { key: "logo", label: "徽标", noun: "徽标" },
];

/** 徽标是透明底 PNG：铺深色棋盘格衬底，透明区域一眼可见，白字徽标也看得清 */
const CHECKERBOARD: CSSProperties = {
  backgroundColor: "#16181d",
  backgroundImage:
    "linear-gradient(45deg, rgba(255,255,255,0.07) 25%, transparent 25%, transparent 75%, rgba(255,255,255,0.07) 75%), " +
    "linear-gradient(45deg, rgba(255,255,255,0.07) 25%, transparent 25%, transparent 75%, rgba(255,255,255,0.07) 75%)",
  backgroundSize: "16px 16px",
  backgroundPosition: "0 0, 8px 8px",
};

/** 当前 tab 的候选、锁定状态与在用路径 */
function tabData(data: ArtworkCandidates | null, tab: ArtworkKind) {
  if (!data) return { candidates: [] as ArtworkCandidate[], locked: false, current: null };
  if (tab === "poster") {
    return { candidates: data.posters, locked: data.poster_locked, current: data.current_poster };
  }
  if (tab === "logo") {
    return { candidates: data.logos, locked: data.logo_locked, current: data.current_logo };
  }
  return {
    candidates: data.backdrops,
    locked: data.backdrop_locked,
    current: data.current_backdrop,
  };
}

/**
 * 「更换图片」弹层（docs/design/metadata.md 6.3）——自动选图挑不中口味时的
 * 人工通道。
 *
 * 三个 tab（背景 / 海报 / 徽标），网格铺候选缩略图，点选即落盘 + 覆盖媒体目录 +
 * 加锁（此后刷新不再覆盖）。候选顺序与自动选图规则一致，所以**第一张就是
 * 系统默认给的那张**，用户一眼看出"我现在用的是哪张、还有什么可选"。
 * 背景候选里"无文字"的排在前面（干净的图才适合铺全屏）。徽标（片名字标，
 * 透明底 PNG）写进媒体目录为 clearlogo.png 给外部播放器读；缩略图完整显示
 * （不裁切）在棋盘格衬底上。
 */
export function ArtworkPickerDialog({
  open,
  libraryId,
  mediaItemId,
  onClose,
  onChanged,
}: {
  open: boolean;
  libraryId: number;
  mediaItemId: number;
  onClose: () => void;
  /** 选定/恢复后回调：调用方重拉详情呈现新图 */
  onChanged: () => void;
}) {
  const [tab, setTab] = useState<ArtworkKind>("backdrop");
  const [data, setData] = useState<ArtworkCandidates | null>(null);
  const [failed, setFailed] = useState(false);
  // 正在应用的候选 file_path（"" 表示正在恢复自动）；null = 空闲
  const [applying, setApplying] = useState<string | null>(null);

  const load = useCallback(() => {
    setFailed(false);
    setData(null);
    listArtworkCandidates(libraryId, mediaItemId)
      .then(setData)
      .catch(() => setFailed(true));
  }, [libraryId, mediaItemId]);

  useEffect(() => {
    if (open) load();
  }, [open, load]);

  const apply = async (filePath: string | null) => {
    setApplying(filePath ?? "");
    try {
      await selectArtwork(libraryId, mediaItemId, tab, filePath);
      onChanged();
      load();
    } catch {
      setFailed(true);
    } finally {
      setApplying(null);
    }
  };

  // 「当前」按**实际在用的路径**比对（后端给），不能用"列表第一张"——
  // 策略升级前刮的条目、锁定的条目、TMDB 新增更高票的图都会对不上
  const { candidates, locked, current } = tabData(data, tab);
  const tabInfo = TABS.find((t) => t.key === tab) ?? TABS[0];

  return (
    <Modal
      open={open}
      onClose={applying === null ? onClose : () => {}}
      label="更换图片"
      width="2xl"
      panelClassName="flex max-h-[80dvh] flex-col"
    >
      <div className="flex items-center justify-between gap-4 border-b border-white/[0.08] px-6 py-4 max-md:flex-col max-md:items-stretch max-md:gap-3 max-md:px-5 max-md:py-3.5">
        <div className="min-w-0">
          <h3 className="text-title-sm font-semibold text-[var(--text)]">更换图片</h3>
          <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">
            选中即生效，并同步写入媒体目录；此后刷新元数据不会覆盖你选的图
          </p>
        </div>
        <div className="flex shrink-0 gap-1 self-start rounded-full bg-white/[0.06] p-1">
          {TABS.map(({ key, label }) => (
            <button
              key={key}
              type="button"
              onClick={() => setTab(key)}
              className={`rounded-full px-3.5 py-1.5 text-sub font-medium transition ${
                tab === key ? "bg-white/[0.14] text-white" : "text-white/60 hover:text-white/85"
              }`}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      {locked && (
        <div className="flex items-center justify-between gap-3 border-b border-white/[0.08] bg-[var(--info)]/[0.07] px-6 py-2.5 max-md:px-5">
          <span className="text-sub text-[var(--info)]">
            当前{tabInfo.label}由你手动选定，刷新元数据不会覆盖
          </span>
          <button
            type="button"
            disabled={applying !== null}
            onClick={() => void apply(null)}
            className="shrink-0 text-sub font-medium text-[var(--accent-2)] hover:underline disabled:opacity-50"
          >
            恢复自动选图
          </button>
        </div>
      )}

      <div className="scroll-thin flex-1 overflow-y-auto p-6">
        {failed && (
          <p className="py-10 text-center text-ui text-[#ff9f9f]">
            候选图加载失败（TMDB 可能不可达），
            <button type="button" onClick={load} className="ml-1 underline">
              重试
            </button>
          </p>
        )}
        {!failed && data === null && (
          <div className="flex items-center justify-center gap-2 py-14 text-ui text-[var(--text-muted)]">
            <BrandLoader className="size-5" />
            正在拉取候选图…
          </div>
        )}
        {data !== null && candidates.length === 0 && (
          <p className="py-14 text-center text-ui text-[var(--text-muted)]">
            TMDB 上没有这个条目的{tabInfo.noun}
          </p>
        )}
        {tab === "logo" && candidates.length > 0 && (
          <p className="mb-3 text-sub leading-5 text-[var(--text-muted)]">
            徽标是透明底的片名字标，会写入媒体目录为 clearlogo.png，供 Kodi / Jellyfin 等播放器读取
          </p>
        )}
        {candidates.length > 0 && (
          <div
            className={`grid gap-3 ${
              tab === "poster"
                ? "[grid-template-columns:repeat(auto-fill,minmax(116px,1fr))]"
                : tab === "logo"
                  ? "[grid-template-columns:repeat(auto-fill,minmax(200px,1fr))]"
                  : "[grid-template-columns:repeat(auto-fill,minmax(220px,1fr))]"
            }`}
          >
            {candidates.map((c) => (
              <button
                key={c.file_path}
                type="button"
                disabled={applying !== null}
                onClick={() => void apply(c.file_path)}
                className={`group relative overflow-hidden rounded-lg ring-1 transition disabled:opacity-60 ${
                  c.file_path === current
                    ? "ring-2 ring-[var(--accent-2)]"
                    : "ring-white/10 hover:ring-[var(--accent-2)]"
                }`}
              >
                <img
                  // 格子宽：海报 minmax(116px) 约 160、徽标 minmax(200px) 约 240、背景 minmax(220px) 约 300
                  {...responsiveImage(
                    cachedImageUrl(c.preview_url),
                    tab === "poster" ? 160 : tab === "logo" ? 240 : 300,
                  )}
                  alt=""
                  loading="lazy"
                  referrerPolicy="no-referrer"
                  style={tab === "logo" ? CHECKERBOARD : undefined}
                  className={`w-full ${
                    tab === "poster"
                      ? "aspect-[2/3] object-cover"
                      : tab === "logo"
                        ? "aspect-[5/2] object-contain px-3 pb-6 pt-3"
                        : "aspect-video object-cover"
                  }`}
                />
                {/* 标出正在用的那张，消除"我现在用的是哪张"的疑问 */}
                {c.file_path === current && (
                  <span className="absolute left-1.5 top-1.5 rounded bg-[var(--accent-2)] px-1.5 py-0.5 text-micro font-semibold text-black/85">
                    当前
                  </span>
                )}
                {tab === "backdrop" && c.language === null && (
                  <span className="absolute right-1.5 top-1.5 rounded bg-black/70 px-1.5 py-0.5 text-micro text-white/85">
                    无文字
                  </span>
                )}
                <span className="tnum absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/80 to-transparent px-1.5 pb-1 pt-4 text-left text-micro text-white/75">
                  {c.width}×{c.height}
                  {c.language ? ` · ${c.language}` : ""}
                </span>
                {applying === c.file_path && (
                  <span className="absolute inset-0 flex items-center justify-center bg-black/55">
                    <BrandLoader className="size-6" />
                  </span>
                )}
              </button>
            ))}
          </div>
        )}
      </div>

      <div className="flex justify-end border-t border-white/[0.08] px-6 py-3.5">
        <button
          type="button"
          onClick={onClose}
          disabled={applying !== null}
          className="btn-glass px-4 py-2 text-ui font-medium disabled:opacity-50"
        >
          完成
        </button>
      </div>
    </Modal>
  );
}
