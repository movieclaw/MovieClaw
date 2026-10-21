import { fetchThemes } from "@/lib/api/ui";
import { setThemeCatalog } from "@/lib/theme-catalog";

/**
 * 从服务端重拉已装主题的目录（docs/design/theme-plugins.md §4.3）：页面启动、打开外观设置、
 * 插件装卸 / 停用 / 恢复之后各拉一次，主题卡与可用性跟着服务端走。失败时沿用手上那份。
 */
export async function refreshThemeCatalog(): Promise<void> {
  setThemeCatalog(await fetchThemes());
}
