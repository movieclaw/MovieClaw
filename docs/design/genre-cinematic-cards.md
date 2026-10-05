# 全幅剧照类型卡（方案 A）

2026-10-05。基于主干 `8fe2d9ab`，实现分支 `codex/genre-cinematic-cards`。
设计来源：[三方案交互 Demo](mockups/genre-directions/index.html)，选择「全幅剧照」。

## 实现

类型入口统一使用全幅剧照、底部深色渐变、卡内类型名称与数量；移除原彩色方卡及卡外「最近入库」片名。数据来源、分类顺序、隐藏设置和筛选墙路由沿用现有实现。

| 项目 | Web 桌面 | iPhone / Web 手机 / macOS | Apple TV |
| --- | --- | --- | --- |
| 卡片 | 240 × 152.5（约 153），保留 236:150 | 196 × 124.6，保留 236:150 | 416 × 234，16:9 |
| 圆角 | 12 × 240/236 ≈ 12.2 | 12 × 196/236 ≈ 10 | 20 |
| 类型字号 | 24 × 240/236 ≈ 24.4 | 24 × 196/236 ≈ 19.9 | 40 |
| 数量字号 | 12 | 11 | 24 |
| 类型左 / 下边距 | 18 / 38，各乘 240/236 | 18 / 38，各乘 196/236 | 30 / 66 |
| 数量左 / 下边距 | 18 / 17，各乘 240/236 | 18 / 17，各乘 196/236 | 30 / 29 |
| 交互 | 悬停剧照 1.045 倍 | Mac 悬停剧照 1.045 倍；iPhone 按压反馈 | 焦点 1.07 倍、3 pt 白边、饱和度从 0.76 恢复 1 |

2026-10-05 跨端同步：`codex/mobile-genre-cards` 合入远程 main `88703bff`，统一自然通透处理。用户复核并参考 Apple tvOS 网格及文字易读性指南后，确认 Web 桌面约 240 × 153、Apple TV 416 × 234；Web 手机、iPhone、macOS 保留紧凑尺寸。电视四张卡与三个 32 pt 间距刚好占满 1760 pt 安全区，数量保持 24 pt；Web 桌面数量增至 12 px。Web 在 768 px 断点切换尺寸。

自然通透参数各端共用：下方图片局部饱和度乘 1.2，不再额外压低亮度；全宽底部遮罩最大透明度 0.28、跨度 0.54；左下椭圆暗区最大透明度 0.5、直径为卡片宽 1.56 倍 / 高 1.44 倍，中心在横向 12%、底部。黑色遮罩使用 smoothstep 色标，避免可见分界。标题字距 0.2，黑色阴影透明度 0.32、半径 4；内高光为 0.5 pt，顶边白色透明度 0.12 向下淡至 0.025。

缺图或加载失败使用中性深灰渐变与胶片符号。数量分别标注「部电影」「部剧集」，无障碍标签包含分类与数量。Mac 悬停只放大剧照、外框保持紧凑尺寸；滚动中不响应悬停；点一格进按这个类型筛好的跨库海报墙。

Apple 三端共用 `GenreCardFace`。原配色算法已无调用而移除，27 个 TMDB 类型中文名称单独保留，跨端契约测试比对后端完整名称表。

## 本次跨端同步验收

使用真实 NAS 登录和片库读取，未向 NAS 部署代码。最新尺寸复核重跑 Web（11 个端到端案例、26 项单元测试、生产构建）和本机 MC Genre TV 模拟器（2 个端到端案例）；iPhone / Mac 沿用上一版验收结果，本次未修改。

| 验证 | 结果 |
| --- | --- |
| Web 1440 / 768 / 767 / 393 / 320 px，电影 / 剧集 → 筛选墙 → 返回 → 横向浏览 | 10 / 10 通过 |
| Web 缺图、404、四字名称、大数量 | 1 / 1 通过 |
| iPhone 电影 / 剧集 → 筛选墙 → 返回 → 横向浏览 | 2 / 2 通过 |
| Apple TV 电影 / 剧集，尺寸、左右焦点 → 筛选墙 → 返回恢复焦点 | 2 / 2 通过 |
| Web 类型名称与首页行测试 | 26 / 26 通过 |
| iPhone HomeRowsTests | 12 / 12 通过 |
| macOS 构建与既有单元测试 | 通过（12 项） |
| macOS 缺图、长名称与大数量下的实际 SwiftUI 卡片布局 | 通过 |
| macOS 真实窗口悬停、点击、返回、横向滚动 | 应用访问权限待授权 |
| Web 生产构建、改动文件 ESLint / Ruff、差异检查 | 通过；构建含原有非阻断警告 |

Mac 布局测试使用 `NSHostingView` 测实际视图尺寸，允许 AppKit 不到一点评估取整误差。TV 从上行下移可能落到同一横坐标的第二张卡，验收先向左回到首张再检查尺寸，不改变产品焦点逻辑。

## 初版实际验收（历史）

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

Web：设置 `MOVIECLAW_API_PROXY_TARGET` 后运行 `pnpm --filter web dev --port 3019`。为测试环境提供 `E2E_WEB_URL`、`MC_TEST_USERNAME`、`MC_TEST_PASSWORD`，可选 `E2E_SHOT_DIR`，执行：

```sh
python -m pytest -m integration tests/e2e/test_genre_cards_browser.py
node --test apps/web/test/genre-labels.test.mjs apps/web/test/home-rows.test.mjs
```

Apple：在 `apps/apple` 执行 `xcodegen generate`，选择已安装模拟器。通过 `TEST_RUNNER_MC_TEST_SERVER`、`TEST_RUNNER_MC_TEST_USERNAME`、`TEST_RUNNER_MC_TEST_PASSWORD` 转发凭据，可选 `TEST_RUNNER_MC_SHOT_DIR` 保存截图。对 `MovieClaw` scheme 运行 `MovieClawUITests/GenreCardsUITests` 和 `MovieClawTests/HomeRowsTests`；对 `MovieClawTV` scheme 运行 `MovieClawTVUITests/TVGenreCardsUITests`。未提供联调环境时新增 UI 用例跳过。测试使用已有电影、剧集及各至少两个类型的片库，不写入服务端偏好或媒体数据。

验收截图与同图比较页保存在本次任务的 `genre-implementation` 可视化附件目录，Xcode 结果包保存在 `/tmp/genre-cinema/`。所有凭据通过临时环境传入，没有写入仓库。

Mac：对 `MovieClawMac` scheme 运行单元测试（含 `GenreCardLayoutTests`），再在测试 App 中直连片库检查两种类型入口、悬停、筛选墙、返回和横向滚动。
