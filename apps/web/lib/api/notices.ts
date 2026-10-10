import { request } from "@/lib/http";

/** 后端统一响应信封（见 movieclaw_api.schemas.response.ApiResponse） */
interface ApiEnvelope<T> {
  success: boolean;
  code: string;
  message: string;
  data: T;
}

async function unwrap<T>(promise: Promise<ApiEnvelope<T>>): Promise<T> {
  return (await promise).data;
}

// ---------------------------------------------------------------------------
// 待处理事项：状态化告警中心（见 movieclaw_api.api.routes.system_notices）
// 正常运行时列表为空；一旦非空说明有"需要用户行动才能推进"的运行时故障。
// ---------------------------------------------------------------------------

export type NoticeSeverity = "warning" | "error";
export type NoticeSource = "subscription" | "ingest" | "downloader" | "site" | "cloud" | "plugin";

/** 一条待处理事项 */
export interface SystemNotice {
  id: number;
  severity: NoticeSeverity;
  source: NoticeSource;
  title: string;
  message: string;
  /** deep-link 参数：subscription_id / entry_path / downloader_id / site_id */
  payload: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

/** 列出全部活跃的待处理事项（error 在前，新的在前；空数组 = 一切正常） */
export async function fetchActiveNotices(): Promise<SystemNotice[]> {
  return unwrap(request<ApiEnvelope<SystemNotice[]>>("/system/notices"));
}

/** 忽略一条事项（问题仍在也不再提示；问题消失时服务端仍会自动清场） */
export async function dismissNotice(id: number): Promise<void> {
  await request<ApiEnvelope<null>>(`/system/notices/${id}/dismiss`, { method: "POST" });
}

/** 事项的跳转目标：按来源域给出能修它的页面路由 */
export function noticeHref(notice: SystemNotice): string {
  switch (notice.source) {
    case "subscription": {
      const id = notice.payload.subscription_id;
      return typeof id === "number" ? `/subscriptions/${id}` : "/subscriptions";
    }
    case "ingest":
      return "/settings/import-watch";
    case "downloader":
      return "/settings/downloaders";
    case "site":
      return "/settings/sites";
    // 和 MovieClaw Cloud 断开、连不上、版本不受支持（docs/design/cloud-push.md §2.4）
    case "cloud":
      return "/settings/cloud";
    // 某个插件启动失败（docs/design/plugin-kernel.md §9）；插件运行中报告的
    // 降级可以带一个站内路径，指向能修它的地方（docs/design/plugin-phase2b.md §5）
    case "plugin": {
      const href = notice.payload.action_href;
      if (typeof href === "string" && href.startsWith("/") && !href.startsWith("//")) return href;
      // 没带路径：定位到插件页里它那一行（docs/design/plugin-page-tiers.md §4.1）
      const entry = notice.payload.entry_id;
      return typeof entry === "string" && entry
        ? `/settings/plugins?module=${encodeURIComponent(entry)}`
        : "/settings/plugins";
    }
    default:
      return "/settings";
  }
}
