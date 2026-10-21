// 主题运行时垫片：react-dom（scripts/gen-theme-runtime.mjs 生成，勿手改）
const m = globalThis.__mcThemeRuntime?.modules?.["react-dom"];
if (!m) throw new Error("主题运行时未就绪：react-dom");
export default m.default ?? m;
export const { createPortal, flushSync, preconnect, prefetchDNS, preinit, preinitModule, preload, preloadModule, requestFormReset, unstable_batchedUpdates, useFormState, useFormStatus, version } = m;
