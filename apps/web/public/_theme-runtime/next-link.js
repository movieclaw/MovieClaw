// 主题运行时垫片：next/link（scripts/gen-theme-runtime.mjs 生成，勿手改）
const m = globalThis.__mcThemeRuntime?.modules?.["next/link"];
if (!m) throw new Error("主题运行时未就绪：next/link");
export default m.default ?? m;
export const { useLinkStatus } = m;
