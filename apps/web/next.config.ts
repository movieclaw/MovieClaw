import type { NextConfig } from "next";

function trimTrailingSlash(value: string): string {
  return value !== "/" && value.endsWith("/") ? value.slice(0, -1) : value;
}

const apiBaseUrl = trimTrailingSlash(process.env.NEXT_PUBLIC_API_BASE_URL?.trim() || "/api/v1");
const proxyTarget = trimTrailingSlash(process.env.MOVIECLAW_API_PROXY_TARGET?.trim() || "http://127.0.0.1:8000");

const nextConfig: NextConfig = {
  // 构建目录可用环境变量覆盖：并行的第二个 dev server（如会话内浏览器预览）
  // 必须使用独立目录，两个 next dev 同写 .next 会互相损坏 chunk。
  distDir: process.env.NEXT_DIST_DIR?.trim() || ".next",
  // Docker 部署用 standalone 输出：只带被引用到的依赖，镜像里无需完整 node_modules。
  output: "standalone",
  // 关闭 Next 图片优化：站内 next/image 只用于静态 logo，优化收益为零；
  // 关闭后 standalone 产物不再依赖 sharp 原生模块，前端构建产物跨 CPU 架构通用
  // （Docker 交叉构建时前端可在宿主架构原生编译，不必走 QEMU 模拟）。
  images: { unoptimized: true },
  // 构建并发上限（仅 Docker 构建设置此变量）：Next 默认按 CPU 核数开静态生成
  // worker，而 Docker 虚拟机往往是「核多内存少」（如 12 核 / 8G）。页面数量
  // 长上来后 worker 一起吃内存，构建会静默挂死——日志停在 "Creating an
  // optimized production build"、CPU 掉到接近 0。限并发是这个现象的根治手段。
  ...(process.env.NEXT_BUILD_CPUS
    ? { experimental: { cpus: Number(process.env.NEXT_BUILD_CPUS) } }
    : {}),
  reactStrictMode: true,
  typedRoutes: true,
  // 关闭左下角 Next.js 开发指示器（dev tools 浮动按钮）
  devIndicators: false,
  async headers() {
    // 页面侧安全头。后端另有一份（src/movieclaw_api/middleware.py）：容器内
    // nginx 把 /api/v1 与 Jellyfin 命名空间直接转给后端，不经过 Next，
    // 两边都设才没有缺口。
    //
    // CSP 这里**刻意只写 frame-ancestors / object-src / base-uri 三条**，
    // 不写 default-src 或 script-src：
    // - Next 的注水脚本与 app/layout.tsx 里恢复背景图的内联脚本都需要
    //   'unsafe-inline'，真要收紧得先给 Next 铺一套 nonce，属于另一件事；
    // - 预告片弹窗内嵌 YouTube iframe，一旦写了 default-src 就会连带把
    //   frame-src 收死，预告片直接放不出来。
    // 当前这三条解决的是「管理后台被第三方页面 iframe 套住做点击劫持」，
    // 也就是本次真正要堵的洞。
    const securityHeaders = [
      { key: "X-Frame-Options", value: "SAMEORIGIN" },
      {
        key: "Content-Security-Policy",
        value: "frame-ancestors 'self'; object-src 'none'; base-uri 'self'",
      },
      { key: "X-Content-Type-Options", value: "nosniff" },
      { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
      // 只关本应用完全用不到的三项。autoplay / encrypted-media / fullscreen /
      // picture-in-picture 等必须留着——顶层策略一旦拒绝，iframe 上的 allow
      // 属性也再授不回来，预告片与播放器会一起坏掉。
      { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
    ];
    return [{ source: "/:path*", headers: securityHeaders }];
  },
  async rewrites() {
    // API 走同源路径时，由 Next 服务器反代到后端。开发和生产（单容器部署，
    // 前端进程反代到同容器内 127.0.0.1:8000 的后端）都依赖这条规则，
    // 因此不再按 NODE_ENV 区分。反代目标在构建时通过 MOVIECLAW_API_PROXY_TARGET 固化。
    if (!apiBaseUrl.startsWith("/")) {
      return [];
    }

    // Jellyfin 兼容播放接口的命名空间（docs/design/jellyfin-compat.md 8.3）：
    // 播放器直连本前端端口，这些前缀反代到后端根路径。协议原始大小写和
    // 小写形态都显式注册，后端另有归一化中间件兜底。
    const jellyfinNamespaces = [
      "System",
      "Users",
      "UserViews",
      "UserItems",
      "UserPlayedItems",
      "UserFavoriteItems",
      "Items",
      "Videos",
      "Shows",
      "PlayingItems",
      "Branding",
      "QuickConnect",
      "Plugins",
      "DisplayPreferences",
      "emby",
    ];
    const jellyfinRewrites = [
      ...new Set(jellyfinNamespaces.flatMap((ns) => [ns, ns.toLowerCase()])),
    ].map((ns) => ({
      source: `/${ns}/:path*`,
      destination: `${proxyTarget}/${ns}/:path*`,
    }));
    // Sessions 不能整段通配：Next rewrite 匹配大小写不敏感，通配规则会把
    // 控制台的 /sessions/[id] 会话页误判成 Jellyfin API，导致页面请求被代理
    // 到后端并返回 500。兼容层在该命名空间实际只实现根路径、Capabilities
    // 和 Playing 三组接口，因此只代理这些明确路径。
    jellyfinRewrites.push({
      source: "/Sessions",
      destination: `${proxyTarget}/Sessions`,
    });
    for (const sub of ["Capabilities", "Playing"]) {
      jellyfinRewrites.push(
        {
          source: `/Sessions/${sub}`,
          destination: `${proxyTarget}/Sessions/${sub}`,
        },
        {
          source: `/Sessions/${sub}/:path*`,
          destination: `${proxyTarget}/Sessions/${sub}/:path*`,
        },
      );
    }
    // Library 命名空间不能整段通配（issue #124）：Next 的 rewrite source 匹配
    // 大小写**不敏感**，且 afterFiles rewrites 在动态路由之前求值——
    // `/Library/:path*` 会连带劫持本应用自己的媒体库详情页 /library/[id]。
    // 只反代真 Jellyfin 在该命名空间下的字面 API 子路径
    // （LibraryController.cs / LibraryStructureController.cs），
    // 与页面的数字 id 段互不相交。
    for (const sub of ["VirtualFolders", "MediaFolders", "PhysicalPaths", "Refresh"]) {
      jellyfinRewrites.push(
        {
          source: `/Library/${sub}/:path*`,
          destination: `${proxyTarget}/Library/${sub}/:path*`,
        },
        {
          source: `/Library/${sub}`,
          destination: `${proxyTarget}/Library/${sub}`,
        },
      );
    }

    return [
      {
        source: `${apiBaseUrl}/:path*`,
        destination: `${proxyTarget}${apiBaseUrl}/:path*`,
      },
      // MCP 协议端点挂后端根路径 /mcp/<slug>：Docker 部署由容器内 nginx 放行，
      // 裸机开发不经 nginx，由这里反代——两边路由清单保持一致
      // （docker/nginx.conf.template）
      {
        source: "/mcp/:path*",
        destination: `${proxyTarget}/mcp/:path*`,
      },
      ...jellyfinRewrites,
    ];
  },
};

export default nextConfig;
