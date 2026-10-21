// 主题运行时垫片：react/jsx-runtime（scripts/gen-theme-runtime.mjs 生成，勿手改）
const m = globalThis.__mcThemeRuntime?.modules?.["react/jsx-runtime"];
if (!m) throw new Error("主题运行时未就绪：react/jsx-runtime");
export default m.default ?? m;
export const { Fragment, jsx, jsxs } = m;
