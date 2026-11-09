# 2026-11-09 发版准备

检测基线为 `origin/main@93a5c0cd3`。先执行 `git fetch --tags origin`，再运行
`scripts/release-status.py --ref origin/main`，并用 `scripts/release-surface-diff.py` 分别对照各产品上一个正式 tag。

## 发布范围

| 组件 | 上一版 | 新版 | tag | 依据 |
|---|---|---|---|---|
| iPhone / iPad | 0.12.6 | 0.12.7 | `ios-v0.12.7` | 首页行与海报墙新增「未看完」，「查看全部」保留观看条件和排序；快速切换时丢弃过期响应。 |
| Apple TV | 0.12.6 | 0.12.7 | `tvos-v0.12.7` | 首页行与电视海报墙新增「未看完」，筛空时说明原因并可清除条件。 |
| Mac | 0.12.6 | 0.12.7 | `macos-v0.12.7` | 资料库筛选菜单与首页行新增「未看完」，「查看全部」保留条件且不修改首页设置。 |
| Android | 0.9.4 / 30000016 | 0.9.5 / 30000017 | `android-v0.9.5` | 新增原生「未看完」与筛空恢复；过期列表响应不再覆盖当前条件；HLS 内封文字字幕和取消压制状态修复。 |
| Android TV | 0.7.4 / 13 | 0.7.5 / 14 | `androidtv-v0.7.5` | 新增电视端「未看完」与筛空恢复；HLS 内封文字字幕和取消压制状态修复。 |
| Windows | 0.1.3 | 0.1.4 | `windows-v0.1.4` | 已保存的 PGS 不再首会话隐式压制；已压入 PGS 的 HLS 替换会话不再反复重协商。 |

Apple 三端共用 `MARKETING_VERSION`，因此一起递增到 0.12.7。各 App 的整体最低服务器版本不变；
「未看完」接口由服务器 0.47.0 提供，六份中相关的五份说明都明确写出这一功能门槛。

## 不发布

- 服务器 / Web / CLI：`v0.49.1` 之后唯一产品代码变化是 #1243 的主片审计锁生命周期修复。它复现并修复的是 pytest
  在多个事件循环间残留模块级锁的问题；生产环境仍是单事件循环，PR 明确说明串行语义不变，没有用户可感知功能或修复。
- Mac 转码器：0 个产品文件变化，握手协议仍是 1。
- HarmonyOS：有「未看完」和字幕相关变化，但正式工具链与签名仍未就绪；不发布未签名 HAP，不创建 `harmony-v*`。
- NER 模型：没有独立产物变化。
- `93a5c0cd3` 只给 PR CI 增加 HarmonyOS 主机逻辑测试，不构成发布理由。

## 说明盘点

| 来源 | 维度 | 用户可感知变化 | 写入或取舍 | 证据 |
|---|---|---|---|---|
| #1205 | 新能力、兼容 | 原生客户端首页行可选「未看完」；首页展开保留观看条件、排序和方向 | 五份原生 App 亮点 | 各端首页行、路由与海报墙实现；服务端能力自 v0.47.0 起存在 |
| #1205 | 默认行为 | 「未看完」与「未看」互斥；原有配置保持原意，不自动改成新条件 | 五份原生 App 说明 | `HomeRows` 合并与各端自定义页 |
| #1205 | 修复 | iOS 与 Android 快速切换条件时，旧请求晚到不再覆盖新列表 | iOS、Android「修好了」 | `LibraryKindWallView.swift`、`LibraryDetailScreen.kt` |
| #1205 | 空状态 | 筛选导致空墙时解释原因，并提供「清除观看筛选」 | iOS、tvOS、Android、Android TV 亮点 | 各端墙页空状态 |
| #1244 / #1248 | 修复 | Android 两端的 HLS 内封文字字幕继续走字幕层；取消压制会明确关闭字幕并记忆 | Android 两份「修好了」 | 共用 `PlaybackController.kt` 与两端菜单文案 |
| #1244 / #1248 | 修复 | Windows 首会话不提前压制内封 PGS；已压入字幕的替换 HLS 不再循环重协商 | Windows「修好了」 | `app.js`、`player.js` |
| surface diff | 拿走 / 改名 | Android 两端「取消压制，播放器本地渲染」消失 | 必写，说明新名称和真实行为 | 两端 `PlayerScreen` / `PlayerPanel` |
| surface diff | 拿走 / 改名 | Android「只显示我没看过的」消失 | 被「全部 / 未看 / 未看完」单选替代，写在亮点 | `LibraryCustomizeScreen.kt` |
| #1243 | 不写 | 跨 pytest 事件循环的锁残留，生产单循环行为不变 | 不发服务器 | PR 说明与 `bluray.py` diff |
| `50a415f79` / `93a5c0cd3` | 不写 / 阻塞 | Harmony 显示修复与 CI 测试 | 无正式签名，不发布 | Harmony release 规范 |

没有数据库迁移、Docker runtime、运行时依赖、最低登录版本或转码器协议变化。播放改动只在客户端字幕路由与状态，
未改服务器 `services/playback/`、ffmpeg 或硬件转码参数，不要求服务器硬件转码矩阵作为本次 tag 门槛。

## 验证与风险

- Homebrew Python 3.14：release status / info / body / downloads manifest 共 35 项通过。系统 Python 3.9
  缺 `hashlib.file_digest`，因此不用它的失败冒充代码失败或通过。
- Windows Node 单测：117 项通过，包含本轮两项 PGS 回归和 release gate。
- 版本与说明机械核对、双语分隔、`git diff --check`：通过。
- 本机没有 Cargo、Android SDK，Rust 与 Android 两端单测 / 构建 / lint 留给 PR CI；最终以 PR CI 全绿为准。
- Android / Android TV 的字幕修复没有真机证据，说明只陈述代码与自动化测试能确定的路由和状态结果，不宣称真机画面验收。
- Apple 本会话只创建 GitHub tag / Release；不打包、不上传 TestFlight、不提交 App Store 审核。

## 合并之后

见 `commands.md`。六个 App tag 都指向本次 rebase-merge 提交。确认每个 GitHub Release 已公开、不是 prerelease、
不是 latest 且附件符合对应工作流后结束。本轮没有服务器 tag；GitHub latest 与 Docker 继续保持服务器 v0.49.1。
