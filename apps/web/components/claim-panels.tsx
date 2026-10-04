"use client";

import { useEffect, useState } from "react";

import {
  fetchDiscoveredTitleDetails,
  titleRef,
  type MediaDetailData,
  type MediaSearchItem,
} from "@/lib/api/discover";
import { searchTitles } from "@/lib/api/search";
import { responsiveImage } from "@/lib/image-proxy";

/* —— 人工认领的两块共享面板（库页「待识别」与监听导入清单共用）——
   认领一律走「详情确认面板」：点候选/搜索结果先看海报、简介、季数再
   确认——只看名字不足以在同名双版本之间下判断。候选全不对时走 TMDB
   搜索（按片名检索、支持直接粘 ID），不让用户手抄 TMDB ID。 —— */

/** 进入确认面板的最小信息：来自候选 chip 或搜索结果，详情异步补全。 */
export interface ClaimSeed {
  tmdbId: number;
  title: string;
  year?: number | null;
  posterUrl?: string;
  episodeCount?: number | null;
  reasons?: string[];
}

/** 组名/条目名 → 搜索词：去掉 [tmdbid=…] 等标记块与尾部年份括号。 */
export function searchSeedFromLabel(label: string): string {
  return label
    .replace(/[[{][^\]}]*[\]}]/g, " ")
    .replace(/\((?:18|19|20)\d{2}\)\s*$/, "")
    .replace(/\s+/g, " ")
    .trim();
}

/* —— 认领确认面板：海报 + 简介 + 季数 + 演职员，看清楚是谁再点认领 —— */

export function ClaimConfirmPanel({
  seed,
  movie,
  fileCount,
  busy,
  askSeason = false,
  onConfirm,
  onCancel,
}: {
  seed: ClaimSeed;
  movie: boolean;
  fileCount: number;
  busy: boolean;
  /** 季号解析不出的一组（unit_unresolved）：认领前必须指定第几季 */
  askSeason?: boolean;
  onConfirm: (season?: number) => void;
  onCancel: () => void;
}) {
  const [detail, setDetail] = useState<MediaDetailData | null>(null);
  const [failed, setFailed] = useState(false);
  const [season, setSeason] = useState("");
  const seasonValid = /^\d{1,3}$/.test(season.trim());
  const kind = movie ? "movie" : "tv";

  useEffect(() => {
    const controller = new AbortController();
    setDetail(null);
    setFailed(false);
    fetchDiscoveredTitleDetails(titleRef("tmdb", kind, String(seed.tmdbId)), {
      signal: controller.signal,
    })
      .then((d) => {
        if (!controller.signal.aborted) setDetail(d);
      })
      .catch(() => {
        if (!controller.signal.aborted) setFailed(true);
      });
    return () => controller.abort();
  }, [kind, seed.tmdbId]);

  const item = detail?.item;
  const posterUrl = item?.posterUrl || seed.posterUrl;
  const title = item?.title ?? seed.title;
  const year = item?.year ?? seed.year;
  const credits = detail
    ? [
        detail.info.directors.length > 0 ? `导演 ${detail.info.directors.slice(0, 2).join(" / ")}` : "",
        // cast 是 MediaCastMember 对象数组，取 name 拼接；直接 join 会渲染成 [object Object]
        detail.info.cast.length > 0
          ? `主演 ${detail.info.cast
              .slice(0, 4)
              .map((member) => member.name)
              .join(" / ")}`
          : "",
      ]
        .filter(Boolean)
        .join(" · ")
    : "";

  return (
    <div className="mt-2.5 rounded-xl border border-white/[0.08] bg-white/[0.03] p-3">
      <div className="flex gap-3">
        {posterUrl ? (
          <img
            {...responsiveImage(posterUrl, 70)}
            alt={title}
            loading="lazy"
            decoding="async"
            className="h-[104px] w-[70px] shrink-0 rounded-lg bg-white/[0.05] object-cover"
          />
        ) : (
          <div className="h-[104px] w-[70px] shrink-0 rounded-lg bg-white/[0.05]" />
        )}
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
            <span className="text-ui font-semibold text-white/95">{title}</span>
            {year ? <span className="text-sub text-[var(--text-muted)]">{year}</span> : null}
            {item?.extent ? (
              <span className="text-sub text-[var(--text-muted)]">{item.extent}</span>
            ) : null}
            {seed.episodeCount ? (
              <span className="text-sub text-[var(--text-muted)]">
                对应季 {seed.episodeCount} 集
              </span>
            ) : null}
            {item && item.rating > 0 ? (
              <span className="text-sub text-[var(--warn)]">★ {item.rating.toFixed(1)}</span>
            ) : null}
          </div>
          {seed.reasons && seed.reasons.length > 0 && (
            <p className="mt-0.5 text-caption text-[var(--text-faint)]">
              与本地文件的佐证：{seed.reasons.join("、")}
            </p>
          )}
          {item?.overview ? (
            <p className="mt-1 line-clamp-3 text-caption leading-[1.55] text-[var(--text-muted)]">
              {item.overview}
            </p>
          ) : failed ? (
            <p className="mt-1 text-caption text-[var(--text-faint)]">
              详情加载失败（不影响认领，可打开 TMDB 页面核对）
            </p>
          ) : (
            <p className="mt-1 text-caption text-[var(--text-faint)]">正在加载详情…</p>
          )}
          {credits && (
            <p className="mt-1 truncate text-caption text-[var(--text-faint)]" title={credits}>
              {credits}
            </p>
          )}
        </div>
      </div>
      <div className="mt-2.5 flex items-center gap-3 border-t border-white/[0.06] pt-2.5">
        <a
          href={`https://www.themoviedb.org/${kind}/${seed.tmdbId}`}
          target="_blank"
          rel="noreferrer"
          className="text-caption text-[var(--text-muted)] underline decoration-white/20 underline-offset-2 transition hover:text-white/80"
        >
          在 TMDB 打开核对 ↗
        </a>
        <span className="flex-1" />
        {movie && fileCount > 1 && (
          <span className="text-caption text-[var(--text-faint)]">整组视为同一部片的多个版本</span>
        )}
        {askSeason && (
          <label className="flex items-center gap-1.5 text-caption text-[var(--text-muted)]">
            第
            <input
              value={season}
              onChange={(e) => setSeason(e.target.value)}
              inputMode="numeric"
              placeholder="?"
              aria-label="季号"
              className="w-10 rounded-md bg-white/[0.06] px-1.5 py-1 text-center text-sub text-white outline-none focus:bg-white/[0.1]"
            />
            季
          </label>
        )}
        <button type="button" disabled={busy} onClick={onCancel} className="btn-glass px-3 py-1.5 text-sub font-medium disabled:opacity-40">
          取消
        </button>
        <button
          type="button"
          disabled={busy || (askSeason && !seasonValid)}
          onClick={() => onConfirm(askSeason ? Number(season.trim()) : undefined)}
          className="btn-accent rounded-full px-3.5 py-1.5 text-sub font-semibold disabled:opacity-40"
        >
          认领{fileCount > 1 ? `全部 ${fileCount} 个文件` : ""}
        </button>
      </div>
    </div>
  );
}

/* —— TMDB 搜索面板：候选全不对时按片名自己检索（比手抄 TMDB ID 体面）。
   输入预填从组名剥出的片名；直接粘一串数字则按 ID 认领。 —— */

export function ClaimSearchPanel({
  movie,
  initialQuery,
  onPick,
}: {
  movie: boolean;
  initialQuery: string;
  onPick: (seed: ClaimSeed) => void;
}) {
  const [query, setQuery] = useState(initialQuery);
  const [results, setResults] = useState<MediaSearchItem[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const kind = movie ? "movie" : "tv";
  const idOnly = /^\d{1,10}$/.test(query.trim());

  const search = () => {
    const q = query.trim();
    if (!q || searching || idOnly) return;
    setSearching(true);
    setError(null);
    searchTitles(q, { provider: "tmdb" })
      // multi 搜索混排两种类型，认领只关心本库的类型
      .then(({ items }) => setResults(items.filter((it) => it.type === kind)))
      .catch((e) => {
        setResults(null);
        setError((e as Error).message);
      })
      .finally(() => setSearching(false));
  };

  return (
    <div className="mt-2.5 rounded-xl border border-white/[0.08] bg-white/[0.03] p-3">
      <div className="flex items-center gap-2">
        <input
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") search();
          }}
          placeholder="片名关键词，或直接粘 TMDB ID"
          autoFocus
          className="min-w-0 flex-1 rounded-lg border border-white/[0.08] bg-white/[0.04] px-3 py-1.5 text-sub text-[var(--text)] outline-none placeholder:text-white/30 focus:border-[var(--accent)]/60"
        />
        {idOnly ? (
          <button
            type="button"
            onClick={() => onPick({ tmdbId: Number(query.trim()), title: `TMDB #${query.trim()}` })}
            className="btn-accent shrink-0 rounded-full px-3.5 py-1.5 text-sub font-semibold"
          >
            查看该 ID
          </button>
        ) : (
          <button
            type="button"
            disabled={searching || !query.trim()}
            onClick={search}
            className="btn-glass shrink-0 px-3.5 py-1.5 text-sub font-medium disabled:opacity-40"
          >
            {searching ? "搜索中…" : "搜索"}
          </button>
        )}
      </div>

      {error && <p className="mt-2 text-caption text-red-300">{error}</p>}
      {results !== null && results.length === 0 && !error && (
        <p className="mt-2 text-caption leading-relaxed text-[var(--text-muted)]">
          没有找到{movie ? "电影" : "剧集"}结果，换个关键词试试（TMDB 对中文名支持有限时可试英文/原名）。
          确认 TMDB 没收录的话，可以
          <a
            href={`https://www.themoviedb.org/${movie ? "movie" : "tv"}/new`}
            target="_blank"
            rel="noreferrer"
            className="underline decoration-white/20 underline-offset-2 transition hover:text-white/80"
          >
            去 TMDB 补录该条目 ↗
          </a>
          ——它是维基式社区库，收录后回来搜索或粘 ID 即可认领
        </p>
      )}
      {results !== null && results.length > 0 && (
        <ul className="mt-2 max-h-72 space-y-1 overflow-y-auto scroll-thin">
          {results.map((it) => (
            <li key={it.id}>
              <button
                type="button"
                onClick={() =>
                  onPick({
                    tmdbId: Number(it.id),
                    title: it.title,
                    year: it.year ?? null,
                    posterUrl: it.posterUrl || undefined,
                  })
                }
                className="flex w-full items-center gap-2.5 rounded-lg px-2 py-1.5 text-left transition hover:bg-white/[0.06]"
              >
                {it.posterUrl ? (
                  <img
                    {...responsiveImage(it.posterUrl, 32)}
                    alt={it.title}
                    loading="lazy"
                    decoding="async"
                    className="h-12 w-8 shrink-0 rounded bg-white/[0.05] object-cover"
                  />
                ) : (
                  <div className="h-12 w-8 shrink-0 rounded bg-white/[0.05]" />
                )}
                <span className="min-w-0 flex-1 truncate text-sub text-white/90">
                  {it.title}
                  {it.year ? (
                    <span className="ml-1.5 text-caption text-[var(--text-muted)]">{it.year}</span>
                  ) : null}
                </span>
                {it.rating > 0 && (
                  <span className="shrink-0 text-caption text-[var(--text-faint)]">
                    ★ {it.rating.toFixed(1)}
                  </span>
                )}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
