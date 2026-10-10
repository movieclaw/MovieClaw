import type { SearchQuery } from "@/components/search-results";
import {
  CATEGORY_LABEL,
  type SearchVertical,
  type TorrentCategory,
} from "@/lib/categories";

/**
 * 搜索页的 URL 序列化：一次搜索的全部输入（关键词 + 范围 + 快照）都编码进
 * /search 的查询参数，让结果页可刷新、可分享、可前进后退。
 *
 * 参数表：
 *   q        关键词（缺失时必须有 browse=1，否则视为无效搜索）
 *   also     同搜词（可重复）：与 q 一起搜、结果按站点合并（详情页「搜索资源」带上
 *            英文名/原名）；去重与数量上限由后端定
 *   browse   "1" = 浏览模式：不带关键词，按分类逛各站种子列表页
 *            （关键词非空时不出现——有词就是搜索）
 *   tab      垂直类别："media" = 影视条目（豆瓣）/ "library" = 媒体库；
 *            缺失 = 站点资源（老链接兼容）
 *   label    范围的展示名（分类中文名 / 预设名；缺失 = 「全部」）
 *   cats     逗号分隔的一级分类；缺失 = 不限分类
 *   sites    逗号分隔的站点 id；缺失 = 全部站点
 *   poster   "1" = 结果页默认图览模式
 *   private  "1" = 无痕搜索（不写入服务端搜索历史）
 *   snapshot 历史快照 id：非空时结果页回放快照而非实时搜索
 *
 * tab 只决定落地时展示哪个垂直，不属于「一次种子搜索」的身份——结果页
 * 切换选项卡只改 tab、其余参数原样保留，所以 parseSearchQuery 不解析它
 * （由页面自行读取），避免切换选项卡被误判为新搜索而重新打站点。
 */
export function buildSearchPath(query: SearchQuery, vertical?: SearchVertical): string {
  const params = new URLSearchParams();
  // 关键词为空 = 浏览模式。用显式的 browse=1 标记而不是「q 缺失即浏览」：
  // 后者会让「手改地址删掉 q」这种误操作静默变成一次跨站浏览。
  if (query.keyword) params.set("q", query.keyword);
  else params.set("browse", "1");
  if (query.keyword) for (const word of query.also ?? []) params.append("also", word);
  if (vertical === "media" || vertical === "library") params.set("tab", vertical);
  const { scope } = query;
  if (scope.label) params.set("label", scope.label);
  if (scope.categories.length > 0) params.set("cats", scope.categories.join(","));
  if (scope.siteIds.length > 0) params.set("sites", scope.siteIds.join(","));
  if (scope.posterMode) params.set("poster", "1");
  if (scope.skipHistory) params.set("private", "1");
  if (query.snapshotId != null) params.set("snapshot", String(query.snapshotId));
  return `/search?${params.toString()}`;
}

/**
 * 详情页「搜索资源」的同搜词：英文名 + 原名（主词是中文名），与订阅的召回词同一套
 * （services/subscription/wanted_search.recall_keywords）。空值丢掉，重复的由后端去重。
 */
export function titleSearchAlso(
  englishTitle: string | null | undefined,
  originalTitle: string | null | undefined,
): string[] {
  return [englishTitle, originalTitle].filter((w): w is string => !!w?.trim());
}

/**
 * 从查询参数还原一次搜索/浏览；q 与 browse=1 都没有时返回 null
 * （由页面重定向回首页）。keyword 为空串即浏览模式，下游一路透传到后端。
 */
export function parseSearchQuery(params: URLSearchParams): SearchQuery | null {
  const keyword = params.get("q")?.trim() ?? "";
  if (!keyword && params.get("browse") !== "1") return null;

  // 分类白名单过滤：手改 URL 塞进未知分类时静默丢弃，避免透传给后端报错
  const categories = (params.get("cats") ?? "")
    .split(",")
    .filter((c): c is TorrentCategory => c in CATEGORY_LABEL);
  const siteIds = (params.get("sites") ?? "").split(",").filter(Boolean);

  const also = params.getAll("also").map((w) => w.trim()).filter(Boolean);
  const snapshotRaw = params.get("snapshot");
  const snapshotId =
    snapshotRaw != null && /^\d+$/.test(snapshotRaw) ? Number(snapshotRaw) : undefined;

  return {
    keyword,
    also: keyword && also.length > 0 ? also : undefined,
    scope: {
      label: params.get("label"),
      categories,
      siteIds,
      posterMode: params.get("poster") === "1",
      skipHistory: params.get("private") === "1",
    },
    snapshotId,
  };
}
