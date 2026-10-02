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
| `masters/app-icon-1024.png` | App 图标母版（纯黑底、不透明） |
| `masters/favicon-1024.png` | 标签页图标母版 |

组合规范：标志高 H，字标大写字母高 0.6H，间距 0.3H，四周安全区 0.25H。

## 各端在哪里、怎么更新

| 端 | 位置 | 更新方式 |
|---|---|---|
| 网页 | `apps/web/public/brand/`、`apps/web/app/favicon.ico`、`apps/web/public/favicon.svg`、`apple-touch-icon.png`、`icons/`、`splash/` | `.venv/bin/python scripts/brand/generate_web_assets.py`（启动图的设备清单读 `apps/web/lib/apple-splash.ts`） |
| iOS | `apps/apple/MovieClaw/Assets.xcassets/AppIcon.appiconset/`：默认（不透明）、深色（透明底）、着色（灰阶）三种外观 | 直接替换三张 1024 PNG |
| macOS 转码器 | `macos/MovieClawTranscoder/Sources/MovieClawTranscoder/BrandMark.swift`（矢量轮廓）→ `Resources/AppIcon.icns` | 改 `BrandMark.swift` 后跑 `scripts/render-app-icon.sh` |
| 浏览器扩展 | `apps/extension/public/icon/{16,32,48,128}.png`（WXT 自动写进 manifest） | 从 `masters/favicon-1024.png` 缩放 |
| README | `docs/images/logo-dark.png` / `logo-light.png` | 横版组合，宽 720 |

完整的品牌资产包（含 Icon Composer 分层、各平台全套尺寸、社交头像、分享卡片）由仓库外的
`movieclaw-logo-lab/build_brand_kit.py` 生成，本目录只放仓库里实际要用到的源文件和母版。

Netflix 主题有自己的红色字标（`apps/web/components/brand.tsx`），属于主题皮肤，不跟随本标志。
