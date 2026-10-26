import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import { headers } from "next/headers";
import { getLocale, getTranslations } from "next-intl/server";
import { LanguageProvider } from "@/lib/i18n/provider";
import { negotiate } from "@/lib/i18n/negotiate";

import { ViewportKeyboard } from "@/components/viewport-keyboard";
import { appleStartupImages } from "@/lib/apple-splash";
import { publicEnv } from "@/lib/env";
import { THEME_CATALOG_CACHE_KEY } from "@/lib/theme-catalog";
import { themeImportMap } from "@/lib/theme-runtime-map";
import { DEFAULT_THEME_ID, PHONE_THEME_QUERY, THEMES } from "@/lib/themes";

// 先引入液态玻璃组件自带的样式，再引入本项目的全局深色主题（后者可覆盖前者）。
import "@/vendor/liquid-glass/styles.css";
import "./globals.css";

// 拉丁字符/数字用 Inter（更克制、专业）；中文由 PingFang SC 等系统字体承接。
// 自托管可变字体（官方 InterVariable.woff2）：构建不再联网拉 Google Fonts，
// 避免代理不稳时构建长时间僵死。
const inter = localFont({
  src: "./fonts/InterVariable.woff2",
  variable: "--font-inter",
  display: "swap",
});

/**
 * 全站标题规范：主页（新任务）就是品牌名本身；子页面用「{页面名} · 品牌名」。
 * 静态子页在各自 page.tsx 里 export metadata（走这里的 template）；
 * 数据驱动的子页（库名/片名/会话名/搜索词）由 lib/use-page-title.ts 在
 * 数据就绪后写 document.title，格式与 template 保持一致。
 */
const metadata: Metadata = {
  title: {
    default: publicEnv.appName,
    template: `%s · ${publicEnv.appName}`,
  },
  /**
   * iOS「添加到主屏幕」的 App 化配置（PWA 清单见 app/manifest.ts）：
   * - capable: 以独立 App 形态运行，去掉 Safari 地址栏与底部工具条；
   * - black-translucent: 状态栏完全透明、页面画到状态栏底下，配合
   *   viewport-fit=cover 与 --safe-top 让顶栏与系统状态栏无缝沉浸；
   * - title: 主屏图标下的名字（不写则取网页 title，可能带后缀）。
   */
  appleWebApp: {
    capable: true,
    statusBarStyle: "black-translucent",
    title: publicEnv.appName,
    // 启动屏：iOS 不用 manifest 合成，必须逐设备给静态图（见 lib/apple-splash.ts）
    startupImage: appleStartupImages,
  },
  // iOS 会把「长得像电话号码」的数字自动变成蓝色 tel 链接，
  // 媒体条目页满屏都是年份/时长/容量数字，关掉自动识别
  formatDetection: {
    telephone: false,
  },
  // 标签页图标：app/favicon.ico 由 Next 自动注入（16/32/48，兼容所有浏览器）；
  // 这里再声明矢量版，支持 SVG 的浏览器优先用它，任意缩放都清晰。
  // （显式写了 icons 后 Next 不再自动拾取 app/icon.*，所以矢量版放在 public/ 并在此声明。）
  // iOS 不读 manifest 里的 icons，主屏图标只认 apple-touch-icon
  icons: {
    icon: [{ url: "/favicon.svg", type: "image/svg+xml" }],
    apple: "/apple-touch-icon.png",
  },
  // Next 的 appleWebApp.capable 只输出新标准 mobile-web-app-capable；
  // 旧版 iOS（< 16.4，不读 manifest 的 display）只认 apple- 前缀，手动补上。
  other: {
    "apple-mobile-web-app-capable": "yes",
  },
};

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations("home.metadata");
  return { ...metadata, description: t("description") };
}

/**
 * 视口规范（移动端适配的地基）：
 * - viewportFit: "cover" —— 让页面铺满刘海屏的整块屏幕，随后由各处的
 *   env(safe-area-inset-*) 把内容从刘海/胶囊/底部指示条里让开（见 globals.css
 *   的 --safe-* 变量）。不写它则 iOS 会自动留出黑边，背景大图铺不满。
 * - 不锁死缩放（不设 maximumScale）：捏合放大是无障碍的基本能力。iOS 上
 *   「聚焦小字号输入框自动放大页面」的问题另行解决——globals.css 在移动端
 *   把输入控件的字号提到 16px，从根上不触发那次自动缩放。
 */
export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#000000",
};

/**
 * 防背景闪烁（FOUC）：--backdrop-image 正常由 BackdropProvider 在「挂载 +
 * GET /appearance 返回」之后写入，强刷时首帧会先画出内置默认图再切换、闪一下。
 * 这段内联脚本在首帧绘制前从 localStorage 恢复上次的背景变量（缓存由
 * lib/backdrop.tsx 在每次换图时写入；图片 URL 带版本号且强缓存，恢复是瞬时的）。
 * 只接受站内相对路径，缓存被篡改也注入不了外部地址。
 *
 * 沉浸路由（/sessions/[id]，Agent 对话页）：首帧绘制前给 <html> 打 immersive-route
 * 标记——背景大图的伪元素整个不渲染（也就不会发起图片请求），纯色层免淡入，
 * 强刷时不会闪出背景图。此时也无需恢复背景变量。客户端路由切换后的同步由
 * AppShell 的 effect 负责（见 components/app-shell.tsx）。
 */
const RESTORE_BACKDROP_SCRIPT = `try{if(location.pathname.indexOf("/sessions/")===0){document.documentElement.classList.add("immersive-route")}else{var u=localStorage.getItem("movieclaw.backdrop");if(u&&u.charAt(0)==="/")document.documentElement.style.setProperty("--backdrop-image",'url("'+u+'")')}}catch(e){}`;

/**
 * 主题防闪烁（FOUC）：与 next-themes 的标准做法同构——首帧绘制前读 ui.prefs
 * 的 localStorage 首帧缓存（lib/ui-prefs-cache.ts），把主题 id 写上 <html> 的
 * data-theme 属性。token 层（globals.css 的变量覆盖组）与 Tailwind 圆角换档
 * 都挂在 html[data-theme] 作用域上，属性就位即全站换肤，强刷不会先画银玻璃
 * 再跳成别的主题。白名单由主题注册表生成（DEFAULT_THEME_ID 除外——默认主题 =
 * 无属性，与 ui-prefs 的写入口径一致），缓存被改坏也注入不了任意属性值；
 * 新增主题自动被脚本认识，无需改这里。登录后服务端偏好拉回、以及设置页
 * 切换主题时的后续同步由 lib/ui-prefs.tsx 的 effect 负责（AppShell 只在登录后渲染）。
 *
 * /play/*、/s/[slug] 不套 AppShell，同样吃到这段脚本与 token 层（结构层除外）。
 * 非默认主题命中时顺带把 <meta name="theme-color"> 改成主题声明的颜色——强刷后浏览器地址
 * 栏 / PWA 状态栏不先闪一段银玻璃色（meta 由 viewport 导出注入，head 同步
 * 解析、脚本执行时已在；找不到时静默跳过。默认主题不命中映射，meta 维持
 * layout.tsx viewport 导出的原值，无需恢复动作）。
 *
 * 映射表从主题注册表序列化而来（ THEMES → 「id → themeColor」JSON），本组件是
 * 服务端组件、注册表是纯数据，拼接发生在 SSR 输出里，客户端零开销。
 */
const THEME_COLOR_MAP = JSON.stringify(
  Object.fromEntries(
    THEMES.filter((theme) => theme.id !== DEFAULT_THEME_ID).map((theme) => [theme.id, theme.themeColor]),
  ),
);
/** 停用液态玻璃的主题 id 清单（ThemeMeta.glass = false）：首帧随 data-theme 写 data-glass="off"。 */
const NO_GLASS_THEMES = JSON.stringify(THEMES.filter((theme) => !theme.glass).map((theme) => theme.id));
/**
 * 首帧主题的落位：
 * - 主题按**设备类**解析：手机（含横过来拿，判据 PHONE_THEME_QUERY）优先取
 *   theme_mobile 覆盖、电脑优先 theme_desktop，都没有（老账号 / 未单独设置）回落
 *   theme——与 lib/ui-prefs.tsx 的 resolveThemeId 同一份语义，改一处要看另一处；
 * - 认得的主题才写属性：内置注册表（上面两张表）或已装主题目录的本地快照
 *   （lib/theme-catalog.ts，状态 ok 的）。认不出的（没装、卸载了、首次登录还没拉过目录）
 *   不写，按默认主题画首帧，登录后由 ui-prefs 按服务端目录校正；
 * - 外壳几何（--mobile-topbar-h / --mobile-tabbar-h）由各主题 CSS 在自己的
 *   data-theme 作用域里声明，属性就位即生效，脚本不必认识具体主题的几何；
 * - data-theme / theme-color 只在非默认主题写（默认 = 无属性，与 ui-prefs
 *   的写入口径一致）；停用玻璃的主题同时写 data-glass="off"；
 * - 主题带外框组件时顺带挂 <link rel="modulepreload">：模块与登录态探测并行下载，
 *   外壳的就绪闸门（components/app-shell.tsx 的 ThemeGate）几乎不用等。预加载只下载不执行，
 *   地址仍只认站内 /ui/themes/ 下的（快照不可信）；真正执行要等服务端主题目录确认。
 */
const RESTORE_THEME_SCRIPT = `try{var p=JSON.parse(localStorage.getItem("movieclaw.ui-prefs")||"null");var c=${THEME_COLOR_MAP};var g=${NO_GLASS_THEMES};var phone=window.matchMedia&&matchMedia(${JSON.stringify(PHONE_THEME_QUERY)}).matches;var t=p?(phone?(p.theme_mobile||p.theme):(p.theme_desktop||p.theme)):null;var d=document.documentElement;if(t&&t!=="${DEFAULT_THEME_ID}"){var e=null,k=JSON.parse(localStorage.getItem("${THEME_CATALOG_CACHE_KEY}")||"null");if(k&&k.length)for(var i=0;i<k.length;i++)if(k[i]&&k[i].id===t&&k[i].status==="ok")e=k[i];var col=e?e.theme_color:c[t];if(e||col){d.setAttribute("data-theme",t);if(e?e.glass===false:g.indexOf(t)>=0)d.setAttribute("data-glass","off");var m=document.querySelector('meta[name="theme-color"]');if(m&&col)m.setAttribute("content",col);if(e&&e.script&&e.script.charAt(0)==="/"&&e.script.charAt(1)!=="/"&&e.script.indexOf("/ui/themes/")>0){var l=document.createElement("link");l.rel="modulepreload";l.href=e.script;document.head.appendChild(l)}}}}catch(e){}`;

/**
 * 主题运行时（docs/design/theme-plugins.md §4.3）：
 * - import map：主题模块里的 react / next / @movieclaw/theme-sdk 指到运行时垫片，必须先于
 *   任何模块脚本出现（Next 自己的 chunk 不走原生 ESM，不受影响）；
 * - 聚合样式表：每个已装主题一行 @import（服务端生成，免登录），各自挂在
 *   html[data-theme="<id>"] 作用域下，一起加载互不影响。
 */
const THEME_IMPORT_MAP = JSON.stringify(themeImportMap());
const THEMES_STYLESHEET = `${publicEnv.apiBaseUrl.replace(/\/$/, "")}/ui/themes.css`;

/**
 * iOS 主屏网页必须显式撑满根画布，不能依赖 height:100% 的初始包含块。
 * 只补状态栏以内的视口差额，避免放大 iPad 分屏；固定底栏仍按视口定位。
 * 与 viewport-keyboard.tsx 的 syncViewportOvershoot 保持一致；后者负责
 * 页面挂载、回到前台、旋转及键盘收起后的重新校准。
 */
const SYNC_VIEWPORT_OVERSHOOT_SCRIPT = `try{if((window.matchMedia("(display-mode: standalone)").matches||navigator.standalone===true)&&window.CSS&&CSS.supports("(-webkit-touch-callout: none)")){var d=document.documentElement,s=parseFloat(getComputedStyle(d).getPropertyValue("--safe-top"))||0,v=screen.height-window.innerHeight,g=v>0&&v<=s?v:0;d.style.setProperty("--vp-overshoot",g+"px");d.style.setProperty("--pwa-height",(window.innerHeight+g)+"px");d.setAttribute("data-ios-standalone","")}}catch(e){}`;

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const [locale, requestHeaders] = await Promise.all([getLocale(), headers()]);
  const browserLocale = negotiate(requestHeaders.get("accept-language"));
  return (
    // suppressHydrationWarning：body 最前的内联脚本会在水合前就给 <html> 写上
    // --backdrop-image 内联样式与 data-theme 属性（见上方两个 RESTORE_* 脚本），
    // 服务端首帧 HTML 里没有这些，两边必然不一致。这是「首帧防闪烁」的固有代价，
    // 用它抑制这一处预期内的告警（只作用于 <html> 自身属性，不影响子树里真正的
    // 水合问题被暴露）。
    <html lang={locale} className={inter.variable} suppressHydrationWarning>
      <head>
        <link rel="stylesheet" href={THEMES_STYLESHEET} />
      </head>
      <body>
        <script type="importmap" dangerouslySetInnerHTML={{ __html: THEME_IMPORT_MAP }} />
        {/* 必须是 body 最前的同步内联脚本：解析即执行，赶在首帧绘制之前 */}
        <script dangerouslySetInnerHTML={{ __html: RESTORE_BACKDROP_SCRIPT }} />
        <script dangerouslySetInnerHTML={{ __html: RESTORE_THEME_SCRIPT }} />
        <script dangerouslySetInnerHTML={{ __html: SYNC_VIEWPORT_OVERSHOOT_SCRIPT }} />
        {/* 挂在根布局：登录页等 AppShell 之外的页面也有输入框，同样需要键盘适配 */}
        <ViewportKeyboard />
        <LanguageProvider locale={locale} browserLocale={browserLocale}>
          {children}
        </LanguageProvider>
      </body>
    </html>
  );
}
