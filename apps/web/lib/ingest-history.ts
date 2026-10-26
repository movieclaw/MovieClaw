import { appTranslator } from "./i18n/translate.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";

import type { JobView } from "@/lib/api/jobs";

export interface IngestHistoryFileGroup {
  label: string;
  files: string[];
}

export interface IngestHistoryDetail {
  summary: string;
  context: string | null;
  fileGroups: IngestHistoryFileGroup[];
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return [
    ...new Set(
      value.filter((item): item is string => typeof item === "string" && item.length > 0),
    ),
  ];
}

function readyFilePaths(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const paths = value.flatMap((item) => {
    if (typeof item === "string") return item.length > 0 ? [item] : [];
    if (item == null || typeof item !== "object") return [];
    const path = (item as Record<string, unknown>).path;
    return typeof path === "string" && path.length > 0 ? [path] : [];
  });
  return [...new Set(paths)];
}

function padEpisode(value: number): string {
  return String(value).padStart(2, "0");
}

function formatEpisodeRanges(episodes: number[], locale: AppLocale): string {
  const ranges: Array<{ start: number; end: number }> = [];
  for (const episode of episodes) {
    const previous = ranges[ranges.length - 1];
    if (previous && episode === previous.end + 1) {
      previous.end = episode;
    } else {
      ranges.push({ start: episode, end: episode });
    }
  }
  return ranges
    .map((range) =>
      range.start === range.end
        ? `E${padEpisode(range.start)}`
        : `E${padEpisode(range.start)}–E${padEpisode(range.end)}`,
    )
    .join(locale === "zh-Hans" ? "、" : ", ");
}

/** 从发布名或文件名提取 SxxEyy，并按季压缩连续集号。 */
function episodeLabel(files: string[], locale: AppLocale): string | null {
  const seasons = new Map<number, Set<number>>();
  for (const file of files) {
    for (const match of file.matchAll(/S(\d{1,3})[\s._-]*E(\d{1,4})/gi)) {
      const season = Number.parseInt(match[1], 10);
      const episode = Number.parseInt(match[2], 10);
      const episodes = seasons.get(season) ?? new Set<number>();
      episodes.add(episode);
      seasons.set(season, episodes);
    }
  }
  if (seasons.size === 0) return null;
  return [...seasons.entries()]
    .sort(([left], [right]) => left - right)
    .map(
      ([season, episodes]) =>
        `S${padEpisode(season)}${formatEpisodeRanges([...episodes].sort((a, b) => a - b), locale)}`,
    )
    .join(" · ");
}

function copiedCount(message: string): number | null {
  const match = message.match(/复制\s*(\d+)\s*个文件/);
  if (!match) return null;
  const count = Number.parseInt(match[1], 10);
  return Number.isFinite(count) ? count : null;
}

function targetLibraryContext(message: string, locale: AppLocale): string | null {
  const match = message.match(/入库到(?:订阅指定的)?[「“"]([^」”"]+)[」”"]/);
  return match ? appTranslator(locale)("activity.ingestHistory.target", { name: match[1] }) : null;
}

/**
 * 历史入库行只陈述本次作业可以证实的结果。新版任务用 imported_files 给出
 * 精确新增文件；旧任务缺少该快照时只展示检查范围，不从候选文件中猜测复制项。
 */
export function buildIngestHistoryDetail(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): IngestHistoryDetail | null {
  if (job.job_type !== "library.ingest") return null;
  const t = appTranslator(locale);

  const message = job.progress.message || "";
  const importedFiles = stringList(job.progress.details.imported_files);
  const alreadyPresentFiles = stringList(job.progress.details.already_present_files);
  const readyFiles = readyFilePaths(job.input_data.ready_files);
  const noMove = /已全部在库|无需搬运|未复制/.test(message);
  const context = targetLibraryContext(message, locale);

  if (importedFiles.length > 0) {
    const addedEpisodes = episodeLabel(importedFiles, locale);
    const summary = addedEpisodes
      ? t("activity.ingestHistory.addedEpisodes", { episodes: addedEpisodes, count: importedFiles.length })
      : t("activity.ingestHistory.addedFiles", { count: importedFiles.length });
    const fileGroups: IngestHistoryFileGroup[] = [
      { label: t("activity.ingestHistory.addedGroup"), files: importedFiles },
    ];
    if (alreadyPresentFiles.length > 0) {
      fileGroups.push({ label: t("activity.ingestHistory.existingGroup"), files: alreadyPresentFiles });
    }
    return { summary, context, fileGroups };
  }

  if (noMove) {
    const existingFiles = alreadyPresentFiles.length > 0 ? alreadyPresentFiles : readyFiles;
    const inspectedEpisodes = episodeLabel(existingFiles, locale);
    const inspected = t("activity.ingestHistory.checked", { scope: inspectedEpisodes ? "episodes" : existingFiles.length > 0 ? "files" : "other", episodes: inspectedEpisodes ?? "", count: existingFiles.length });
    return {
      summary: t("activity.ingestHistory.noCopy", { inspected }),
      context,
      fileGroups:
        existingFiles.length > 0 ? [{ label: t("activity.ingestHistory.existingGroup"), files: existingFiles }] : [],
    };
  }

  const legacyCopiedCount = copiedCount(message);
  if (legacyCopiedCount != null && readyFiles.length > 0) {
    const inspectedEpisodes = episodeLabel(readyFiles, locale);
    const inspected = t("activity.ingestHistory.checked", { scope: inspectedEpisodes ? "episodes" : "files", episodes: inspectedEpisodes ?? "", count: readyFiles.length });
    return {
      summary: t("activity.ingestHistory.legacyCopy", { inspected, count: legacyCopiedCount }),
      context,
      fileGroups: [{ label: t("activity.ingestHistory.checkGroup"), files: readyFiles }],
    };
  }

  return {
    summary: message || (job.status === "cancelled" ? t("activity.tasks.cancelled") : t("activity.tasks.completed")),
    context,
    fileGroups: alreadyPresentFiles.length > 0
      ? [{ label: t("activity.ingestHistory.existingGroup"), files: alreadyPresentFiles }]
      : [],
  };
}
