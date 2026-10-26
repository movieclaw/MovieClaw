import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

/**
 * 页面地址去掉结尾斜杠（原本是 Next 内置的规范化，next.config.ts 里关掉了，在这里做）。
 * 接口一律原样转给后端：插件网页的根地址 /api/v1/plugins/<id>/web/ 必须带着斜杠。
 */
function trailingSlashRedirect(request: NextRequest): NextResponse | null {
  const { pathname } = request.nextUrl;
  if (pathname === "/" || !pathname.endsWith("/") || pathname.startsWith("/api/")) return null;
  // 用原始 URL 改路径：nextUrl.clone() 会按构建配置把结尾斜杠补回来，重定向指回原地
  const url = new URL(request.url);
  url.pathname = pathname.replace(/\/+$/, "") || "/";
  return NextResponse.redirect(url, 308);
}

/** Jellyfin 兼容接口经 Next rewrite 反代时，保留播放器实际连接的外部地址。 */
export function middleware(request: NextRequest) {
  const redirect = trailingSlashRedirect(request);
  if (redirect) return redirect;
  const pathname = request.nextUrl.pathname.toLowerCase();
  const firstSegment = pathname.split("/")[1];
  const jellyfinNamespaces = new Set([
    "system",
    "users",
    "userviews",
    "useritems",
    "userplayeditems",
    "userfavoriteitems",
    "items",
    "videos",
    "shows",
    "playingitems",
    "branding",
    "quickconnect",
    "emby",
  ]);
  const jellyfinSessionPath =
    pathname === "/sessions" ||
    pathname === "/sessions/capabilities" ||
    pathname.startsWith("/sessions/capabilities/") ||
    pathname === "/sessions/playing" ||
    pathname.startsWith("/sessions/playing/");
  if (
    !firstSegment ||
    (!jellyfinNamespaces.has(firstSegment) && !jellyfinSessionPath)
  ) {
    return NextResponse.next();
  }

  const headers = new Headers(request.headers);
  headers.set("X-Forwarded-Host", request.headers.get("Host") ?? request.nextUrl.host);
  headers.set("X-Forwarded-Proto", request.nextUrl.protocol.replace(/:$/, ""));
  return NextResponse.next({ request: { headers } });
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
