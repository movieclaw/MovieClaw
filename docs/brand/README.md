# MovieClaw 品牌标志

**A9 极光**：一笔写成的圆角播放三角，笔画是青绿 → 湖蓝 → 紫 → 粉的极光渐变。
字标「MovieClaw」用 Inter 半粗、单色，颜色只由标志承担。

**图标比例**（2026-10-02 定稿「尺寸 B」）：三角外框约占 App 图标 64%，笔画约 11%；视觉面积约 32%，
与 App Store、音乐等同属线条图形的苹果图标一致。

## 颜色

| 用途 | 色值 |
|---|---|
| 极光渐变（左下 → 右上） | `#36E2BD` → `#4C9DFF` → `#9A6BFF` → `#FF7FCF` |
| 深色底 / 图标背景 | `#000000` |
| 深色底上的字标 | `#F3F5F9` |
| 浅色底上的字标 | `#0B0C0F` |

## 本目录

| 文件 | 说明 |
|---|---|
| `mark-aurora-on-dark.svg` | 深色底用：完整极光，带一圈淡淡的外溢光（四周留了外溢光的空间） |
| `mark-aurora-on-light.svg` | 极光，不带外溢光 |
| `mark-aurora-flat.svg` | 纯渐变、无滤镜：浅色底、印刷、设计软件用，兼容性最好 |
| `mark-black.svg` / `mark-white.svg` | 单色 |
| `lockup-{horizontal,stacked}-{on-dark,on-light,black,white}.svg` | 标志 + 字标组合，字标已转路径，不依赖字体 |
| `app-icon-dark.svg` / `app-icon-light.svg` | App 图标（400×400，深色为默认，字形外框约占 64%） |
| `favicon.svg` | 网页标签页图标（字形放大到约占 70%，16px 下也认得出） |
| `masters/mark-1024.png` | 标志母版（透明底，字形占 91%） |
| `masters/mark-ui-1024.png` | 细笔画标志母版（笔画占字形 11.5%）：网页侧栏等界面小尺寸用 |
| `masters/app-icon-1024.png` | App 图标母版（纯黑底、不透明） |
| `masters/favicon-1024.png` | 标签页图标母版 |
| `transcoder/` | macOS 转码器专用三角循环标志：应用图标 SVG / 1024 PNG、透明标志 SVG / PNG、菜单栏单色 SVG |

转码器于 2026-10-06 锁定三角循环版，保持主品牌的极光配色，以回转箭头区分主程序。
应用图标从锁定的 PNG 母版生成，保留色光、光晕和投影；菜单栏使用独立的 18pt 细线模板。

组合规范：标志高 H，字标大写字母高 0.6H，间距 0.3H，四周安全区 0.25H。

**小尺寸换细笔画**：标志在 32px 以下（网页侧栏、菜单栏）改用细笔画版；标准版的粗笔画在小尺寸下会比旁边的文字、图标重一档、显大一号。

## 各端在哪里、怎么更新

| 端 | 位置 | 更新方式 |
|---|---|---|
| 网页 | `apps/web/public/brand/`、`apps/web/app/favicon.ico`、`apps/web/public/favicon.svg`、`apple-touch-icon.png`、`icons/`、`splash/` | `.venv/bin/python scripts/brand/generate_web_assets.py`（启动图的设备清单读 `apps/web/lib/apple-splash.ts`） |
| iOS | `apps/apple/MovieClaw/Assets.xcassets/AppIcon.appiconset/`：默认（不透明）、深色（透明底）、着色（灰阶）三种外观 | 直接替换三张 1024 PNG |
| Apple TV | `apps/apple/MovieClawTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets/`：分层图标（背景 + 标志两层，焦点视差）与 Top Shelf 横幅 | `.venv/bin/python scripts/brand/generate_tvos_assets.py`（macOS，字标经 Quick Look 从横版组合 SVG 取出） |
| Android TV | `apps/android-tv/app/src/main/res/`：不透明 PNG 横幅（16:9，xhdpi 320×180）、方形 PNG 图标（xhdpi 160×160），mdpi 至 xxxhdpi 五档；API 26+ 为 108dp 自适应前景 + 纯黑背景 | `.venv/bin/python scripts/brand/generate_android_tv_assets.py`（macOS / Pillow，复用 tvOS 字标提取方法） |
| macOS 转码器 | `docs/brand/transcoder/`：已锁定的三角循环母版；`BrandMark.swift`：运行时矢量徽标与菜单栏模板；`Resources/AppIcon.icns`：应用图标 | 更新专用母版和运行时轮廓后，在转码器目录运行 `scripts/render-app-icon.sh` |
| 浏览器扩展 | `apps/extension/public/icon/{16,32,48,128}.png`（WXT 自动写进 manifest） | 从 `masters/favicon-1024.png` 缩放 |
| README | 顶部横幅 `docs/images/banner.{zh,en}.jpg`（和官网分享卡片同一版式，2400×1260，自带深色底，GitHub 明暗主题都能用）；`docs/images/logo-dark.png` / `logo-light.png` 是横版组合（宽 720），README 已不再引用 | 换标志后照官网分享卡片的版式重出横幅 |

完整的品牌资产包（含 Icon Composer 分层、各平台全套尺寸、社交头像、分享卡片）由仓库外的
`movieclaw-logo-lab/build_brand_kit.py` 生成，本目录只放仓库里实际要用到的源文件和母版。

Netflix 主题有自己的红色字标（`apps/web/components/brand.tsx`），属于主题皮肤，不跟随本标志。
