/**
 * 插件网页的纯逻辑（docs/design/plugin-web-pages.md）：侧边栏项、地址换算、当前高亮。
 *
 * 一个插件 = 一个网页根目录（iframe 实际加载 `base`，即 /api/v1/plugins/<id>/web/）；
 * 主程序地址是 `/apps/<id>/<子路径>`。侧边栏的几项（manifest 的主入口 + shortcuts）
 * 只是指向同一个根目录下的不同落点。
 *
 * 本模块刻意不 import 任何组件或 `@/` 别名，保持能被 node --test 直接单测
 * （见 test/plugin-apps.test.mjs），与 lib/sidebar-nav.ts 同一条约定。
 */

/** `GET /ui/apps` 的一项入口 */
export interface PluginAppEntry {
  /** 侧边栏文字（manifest 的 short_name / name） */
  label: string;
  /** 落点：相对网页根目录的子路径（可带查询串），主入口通常为空串 */
  path: string;
  /** 图标地址；null = 用默认图标 */
  icon: string | null;
  /** manifest 标了 purpose: monochrome：按遮罩用当前文字颜色着色 */
  monochrome: boolean;
}

/** `GET /ui/apps` 的一项：一个带网页的插件 */
export interface PluginApp {
  id: string;
  name: string;
  /** 用户同意加到侧边栏 */
  nav: boolean;
  /** iframe 加载的地址前缀，以 / 结尾 */
  base: string;
  entries: PluginAppEntry[];
}

export interface PluginAppNavItem {
  /** 主导航 id：`app:<插件 id>:<序号>`，与内置项一起参与排序与移出 */
  id: string;
  appId: string;
  label: string;
  href: string;
  icon: string | null;
  monochrome: boolean;
}

export const APP_NAV_PREFIX = "app:";
export const APPS_ROUTE = "/apps/";

export function isAppNavId(id: string): boolean {
  return id.startsWith(APP_NAV_PREFIX);
}

export function appNavId(appId: string, index: number): string {
  return `${APP_NAV_PREFIX}${appId}:${index}`;
}

/** 主程序地址：`/apps/<id>/<子路径>`；主入口不带结尾斜杠（Next 会把它重定向掉） */
export function appHref(appId: string, path = ""): string {
  const sub = path.replace(/^\/+/, "");
  return `${APPS_ROUTE}${encodeURIComponent(appId)}${sub ? `/${sub}` : ""}`;
}

/** 网页根目录的入口文件：iframe 地址落在它上面时，地址栏显示成插件的主入口 */
const INDEX = "index.html";

/** 同意加到侧边栏的插件 → 侧边栏项（主入口在前，shortcuts 依次在后）。 */
export function appNavItems(apps: PluginApp[]): PluginAppNavItem[] {
  return apps
    .filter((app) => app.nav)
    .flatMap((app) =>
      app.entries.map((entry, index) => ({
        id: appNavId(app.id, index),
        appId: app.id,
        label: entry.label,
        href: appHref(app.id, entry.path),
        icon: entry.icon,
        monochrome: entry.monochrome,
      })),
    );
}

/** 把被用户移出侧边栏的项去掉（只认应用项：内置项不能移出）。 */
export function withoutHidden<T extends { id: string }>(items: T[], hidden: string[] | null | undefined): T[] {
  if (!hidden || hidden.length === 0) return items;
  const set = new Set(hidden);
  return items.filter((item) => !(isAppNavId(item.id) && set.has(item.id)));
}

/**
 * 保存导航偏好前清掉已经不存在的插件网页项（卸载了、撤销了、不再加到侧边栏）。
 *
 * `nav.order` 会保留看不见的 id（权限收回再给回来时位置还在），插件项也跟着一直留着；
 * 装装卸卸多了会顶到服务端的上限，而界面偏好是整体保存的——超限会让整份偏好都存不进去。
 * `known` 为 null（插件列表还没拉到）时一项都不删，免得把还在的插件位置清掉。
 */
export function pruneAppNavIds(ids: string[], known: Set<string> | null): string[] {
  if (known === null) return ids;
  return ids.filter((id) => !isAppNavId(id) || known.has(id));
}

/** `/apps/<id>/<子路径>` → `{ appId, sub }`；不是插件网页地址返回 null。 */
export function parseAppPath(pathname: string): { appId: string; sub: string } | null {
  if (!pathname.startsWith(APPS_ROUTE)) return null;
  const rest = pathname.slice(APPS_ROUTE.length);
  const slash = rest.indexOf("/");
  const rawId = slash === -1 ? rest : rest.slice(0, slash);
  if (!rawId) return null;
  let appId: string;
  try {
    appId = decodeURIComponent(rawId);
  } catch {
    return null;
  }
  return { appId, sub: slash === -1 ? "" : rest.slice(slash + 1) };
}

function stripQuery(path: string): string {
  const cut = path.search(/[?#]/);
  return cut === -1 ? path : path.slice(0, cut);
}

/**
 * 当前地址该点亮哪一项：同一插件里取子路径**最长前缀匹配**的那一项（按路径段对齐，
 * `downloads` 不会匹配 `downloads-old`）；都不匹配时点亮主入口。不是插件网页返回 null。
 */
export function activeAppNavId(pathname: string, apps: PluginApp[]): string | null {
  const parsed = parseAppPath(pathname);
  if (!parsed) return null;
  const app = apps.find((a) => a.id === parsed.appId);
  if (!app || app.entries.length === 0) return null;
  const sub = stripQuery(parsed.sub).replace(/\/+$/, "");
  let best = 0;
  let bestLength = -1;
  app.entries.forEach((entry, index) => {
    const path = stripQuery(entry.path).replace(/^\/+|\/+$/g, "");
    const matches = path === "" || sub === path || sub.startsWith(`${path}/`);
    if (matches && path.length > bestLength) {
      best = index;
      bestLength = path.length;
    }
  });
  return appNavId(app.id, best);
}

/** 主程序地址的子路径 + 查询串 + 片段 → iframe 要加载的地址。 */
export function frameSrc(base: string, sub: string, search = "", hash = ""): string {
  return `${base}${sub.replace(/^\/+/, "")}${search}${hash}`;
}

/**
 * iframe 当前地址 → 主程序地址栏该显示的地址；iframe 跳出了网页根目录（比如没写
 * target="_top" 的站内链接）返回 null，由调用方把整页带过去。
 */
export function hostPathFromFrame(
  appId: string,
  base: string,
  frame: { pathname: string; search: string; hash: string },
): string | null {
  const root = base.replace(/\/+$/, "");
  if (frame.pathname !== root && !frame.pathname.startsWith(base)) return null;
  const sub = frame.pathname.startsWith(base) ? frame.pathname.slice(base.length) : "";
  return `${appHref(appId, sub === INDEX ? "" : sub)}${frame.search}${frame.hash}`;
}
