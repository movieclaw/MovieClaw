/**
 * 主题运行时的 import map（docs/design/theme-plugins.md §4.3、§5.4）。纯数据，根布局、
 * 垫片生成脚本（scripts/gen-theme-runtime.mjs）与测试共用。
 *
 * 主题模块里写的裸模块名 → public/_theme-runtime/ 下的垫片；垫片从
 * `globalThis.__mcThemeRuntime.modules[<裸模块名>]` 取主程序的同一份模块实例（lib/theme-runtime.ts 挂上）。
 * 这张表就是主题能 import 的外部模块全集，与 eslint 的 themes/ 限制、主题构建的 external 同一份。
 */
export const THEME_RUNTIME_BASE = "/_theme-runtime";

export const THEME_RUNTIME_MODULES = {
  react: "react.js",
  "react-dom": "react-dom.js",
  "react/jsx-runtime": "react-jsx-runtime.js",
  "next/link": "next-link.js",
  "next/navigation": "next-navigation.js",
  "@movieclaw/theme-sdk": "sdk.js",
} as const;

export function themeImportMap(): { imports: Record<string, string> } {
  return {
    imports: Object.fromEntries(
      Object.entries(THEME_RUNTIME_MODULES).map(([name, file]) => [name, `${THEME_RUNTIME_BASE}/${file}`]),
    ),
  };
}

/**
 * 主题模块只认主程序自己托管的地址（同源、`/ui/themes/` 下）：地址来自服务端主题目录，
 * 这里再守一道——不让被改过的本地缓存或别的来源把任意脚本当主题执行。
 */
export function isThemeModuleUrl(url: string, origin = globalThis.location?.origin ?? ""): boolean {
  try {
    const parsed = new URL(url, origin);
    return parsed.origin === origin && /\/ui\/themes\/[a-z][a-z0-9-]{1,38}[a-z0-9]\/[^?#]+\.m?js$/.test(parsed.pathname);
  } catch {
    return false;
  }
}
