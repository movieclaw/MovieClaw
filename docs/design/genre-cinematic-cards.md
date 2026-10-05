# 全幅剧照类型卡（方案 A）

2026-10-05。基于主干 `8fe2d9ab`，实现分支 `codex/genre-cinematic-cards`。
设计来源：[三方案交互 Demo](mockups/genre-directions/index.html)，选择「全幅剧照」。

## 实现

类型入口统一使用全幅剧照、底部深色渐变、卡内类型名称与数量；移除原彩色方卡及卡外「最近入库」片名。数据来源、分类顺序、隐藏设置和筛选墙路由沿用现有实现。

| 项目 | Web / iPhone | Apple TV |
| --- | --- | --- |
| 卡片 | 236 × 150 | 416 × 234 |
| 圆角 | 12 | 20 |
| 类型字号 | 24 | 40 |
| 数量字号 | 11 | 24 |
| 类型左 / 下边距 | 18 / 38 | 30 / 66 |
| 数量左 / 下边距 | 19 / 17 | 32 / 29 |
| 默认剧照饱和度 | 0.76 | 0.76 |
| 交互 | Web 悬停剧照 1.045 倍；iPhone 按压反馈 | 焦点 1.07 倍、3 pt 白边、饱和度恢复 1 |

渐变从底部向顶部为 `#07090def`（0%）、`#080a0c77`（44%）、`#090b1010`（100%）。缺图或加载失败使用中性深灰渐变与胶片符号。数量分别标注「部电影」「部剧集」，无障碍标签包含分类与数量。

Apple 两端共用 `GenreCardFace`。原配色算法已无调用而移除，27 个 TMDB 类型中文名称单独保留，跨端契约测试比对后端完整名称表。

## 实际验收

使用用户提供的 NAS 进行真实登录及片库读取。Web 是本分支新前端反代 NAS；iPhone / Apple TV 是本分支构建安装到 iOS 27 / tvOS 27 模拟器，并直连 NAS。未向 NAS 部署代码。

| 验证 | 结果 |
| --- | --- |
| Web 1440 px / 393 px，电影 / 剧集类型卡 → 真实筛选 API → 返回 → 横向浏览 | 4 / 4 通过 |
| Web 浏览器局部拦截：缺图、图片 404、四字名称、大数量 | 1 / 1 通过 |
| iPhone 电影 / 剧集：首页滚动 → 点击类型 → 正确墙标题 → 返回原位置 | 2 / 2 通过 |
| Apple TV 电影 / 剧集：遥控器下移、左右焦点 → 确认 → 菜单返回恢复焦点 | 2 / 2 通过 |
| Web 首页行与类型名称单元测试 | 26 / 26 通过 |
| Apple HomeRowsTests | 12 / 12 通过 |
| Web 生产构建、改动文件 ESLint / Ruff、差异空白检查 | 通过；全量构建存在原有非阻断 lint 警告 |

同图核对时将 Demo 首卡替换为 NAS 当前首个剧情分类的图片与数量，再分别截取浏览器及原生卡片。卡片尺寸、剧照裁切、遮罩与内容层级一致；字体栅格化、原生连续圆角、箭头仍使用各平台绘制方式，不宣称逐像素完全一致。完整页面保留现有产品布局。

模拟器验收额外发现并修正了两项问题：iPhone 裁切图片的原始尺寸扩大了可访问性点击框；tvOS 默认按钮样式额外叠加玻璃边框与放大。最终分别使用明确的内容点击区域、自定义按钮样式，保留既有导航和焦点恢复。

## 重跑

Web：设置 `MOVIECLAW_API_PROXY_TARGET` 后运行 `pnpm --filter web dev --port 3015`。为测试环境提供 `E2E_WEB_URL`、`MC_TEST_USERNAME`、`MC_TEST_PASSWORD`，可选 `E2E_SHOT_DIR`，执行：

```sh
python -m pytest -m integration tests/e2e/test_genre_cards_browser.py
node --test apps/web/test/genre-labels.test.mjs apps/web/test/home-rows.test.mjs
```

Apple：在 `apps/apple` 执行 `xcodegen generate`，选择已安装模拟器。通过 `TEST_RUNNER_MC_TEST_SERVER`、`TEST_RUNNER_MC_TEST_USERNAME`、`TEST_RUNNER_MC_TEST_PASSWORD` 转发凭据，可选 `TEST_RUNNER_MC_SHOT_DIR` 保存截图。对 `MovieClaw` scheme 运行 `MovieClawUITests/GenreCardsUITests` 和 `MovieClawTests/HomeRowsTests`；对 `MovieClawTV` scheme 运行 `MovieClawTVUITests/TVGenreCardsUITests`。未提供联调环境时新增 UI 用例跳过。测试使用已有电影、剧集及各至少两个类型的片库，不写入服务端偏好或媒体数据。

验收截图与同图比较页保存在本次任务的 `genre-implementation` 可视化附件目录，Xcode 结果包保存在 `/tmp/genre-cinema/`。所有凭据通过临时环境传入，没有写入仓库。
