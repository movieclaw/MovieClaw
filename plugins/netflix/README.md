# Netflix 主题

MovieClaw 网页的官方主题插件（随应用携带，也可单独打包上传替换）。设计说明见
[docs/design/theme-plugins.md](../../docs/design/theme-plugins.md)。

```
movieclaw-plugin.toml   清单：[theme] 段是主题的静态事实（名称、预览色、版式、玻璃）
src/index.tsx           外框组件（default export 主题定义），只经 @movieclaw/theme-sdk 用内核能力
src/theme.css           外观：全部规则挂 html[data-theme="netflix"]（主题自有类名带 nf- 前缀）
```

构建：在仓库根目录 `pnpm theme:build`，产物进 `src/movieclaw_plugins/netflix/`（随带插件包，不入库）；
`pnpm theme:pack` 另出一份 `netflix-<版本>.mcplugin`，可在「设置 → 插件」上传。

Tailwind 工具类一律带 `nf:` 前缀（`nf:flex`、`nf:md:hidden`）：主题自己的工具类与主程序的同名类不能混在
同一层里（见设计稿 §5.3）。
