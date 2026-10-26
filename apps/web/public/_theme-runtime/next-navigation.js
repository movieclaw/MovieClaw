// 主题运行时垫片：next/navigation（scripts/gen-theme-runtime.mjs 生成，勿手改）
const m = globalThis.__mcThemeRuntime?.modules?.["next/navigation"];
if (!m) throw new Error("主题运行时未就绪：next/navigation");
export default m.default ?? m;
export const { ReadonlyURLSearchParams, RedirectType, ServerInsertedHTMLContext, forbidden, notFound, permanentRedirect, redirect, unauthorized, unstable_isUnrecognizedActionError, unstable_rethrow, useParams, usePathname, useRouter, useSearchParams, useSelectedLayoutSegment, useSelectedLayoutSegments, useServerInsertedHTML } = m;
