# 类型卡片设计预览

最初基于 `main` / `8fe2d9ab` 制作，2026-10-05。本目录保留静态高保真设计对比；方案 A 已落地到正式 Web、iPhone、Apple TV 组件，规格与实际验收见[实施说明](../../genre-cinematic-cards.md)。

在仓库根目录运行 `python3 -m http.server 8766 --bind 127.0.0.1`，打开：

http://127.0.0.1:8766/docs/design/mockups/genre-directions/

页面支持三套新方案、现版重绘对照、Web/iPhone/Apple TV 画布、分类弹层、横滑、电视方向键与 Enter/Esc，以及缺图和长名称测试。外围导航与继续观看仅提供视觉上下文。链接的 `design=cinema|shelf|index|current` 和 `device=web|phone|tv` 参数可直达方案。

## 结论与取舍

- **A 全幅剧照（优先建议）**：真实封面占满横向卡；类型、数量、箭头明确分类语义。复用现有单张剧照，无新增接口要求。风险是单张封面仍会联想到单片，且最新入库封面的质量与代表性不稳定。
- **B 海报片架**：通过多海报直接表达集合，收藏感更强。需要扩展每个类型的海报摘要数据（最多三张可用海报）；当前 `KindGenre` 只有单张 `cover_url`。也容易与已有媒体库拼贴卡重复。
- **C 暗色索引**：统一中性深灰、类型大字和数量；无封面依赖，扫读效率高。代价是影视氛围较弱。符号只作装饰，低对比不影响类型文字与数量阅读。

设计判断来自现有纯黑/银色页面与彩色方卡的层级冲突，并非客观可用性研究结论。现版采用代码重绘，材质有近似，不是线上截图。Web 的其他主题没有在此稿复刻；本次以默认中性主题为比较基准。iPhone、Apple TV 均为浏览器模拟，未声称通过真机验证。

## 初始设计的代码依据（改动前）

- `apps/web/components/genre-tile.tsx`：彩色方卡、剧照嵌套、外部片名/最近入库。
- `apps/web/components/library-view.tsx`：Web 200 pt / 窄屏 150 pt；跳往类型海报墙。
- `apps/web/app/globals.css`：纯黑底、冷银强调色。
- `apps/apple/Shared/DesignSystem/GenrePalette.swift`：iOS/tvOS 共用 `GenreCardFace`。
- `apps/apple/MovieClaw/Features/Library/LibraryHomeView.swift`：iPhone 分类行及外部说明。
- `apps/apple/MovieClawTV/DesignSystem/TVCards.swift`：326 pt 方卡、32 pt 间距、20 pt 常规圆角、`#16171c` 页面。
- [Apple Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection/)：焦点系统与焦点态的空间需求。预览中的 1.07× 放大是本次提案参数，不是系统保证值。

## 验证

`verify.mjs` 使用已安装的 Playwright 或 `PLAYWRIGHT_MODULE` 指定的模块运行，不修改项目依赖：

```sh
PLAYWRIGHT_MODULE=/absolute/path/to/playwright-core/index.mjs node docs/design/mockups/genre-directions/verify.mjs
```

覆盖 12 组样式/设备组合：所有图片加载、分类打开/关闭、电视焦点方向键/首尾/Enter、缺图与长名称；另检查 390 px 真实浏览器宽度下无整页溢出、横滑和方案切换。默认截图与报告在 `/tmp/movieclaw-genre-directions`；可用 `DEMO_SHOTS` 指定输出目录。

## 演示素材

数量与片库组合为示例。海报和大部分剧照来自 TMDB 图片 CDN，仅用于本地设计比较；资源与产品取图链路分离。电影对应：Interstellar、Mad Max: Fury Road、The Grand Budapest Hotel、Spirited Away、La La Land、Inception 等。

- [TMDB](https://www.themoviedb.org/)：`assets/p-*.jpg`、space/action/animation/romance/mystery.jpg。
- [Dwell · Behind the Scenes: Grand Budapest Hotel](https://www.dwell.com/article/behind-the-scenes-grand-budapest-hotel-65ab4652)：`assets/comedy.jpg` 的酒店布景图。

所有演示图片保存在同级 assets 中，预览无需请求外网。
