# 2026-11-11 发版准备

检测基线为 `origin/main@b99a3bfaf`。已先执行 `git fetch --tags origin`，再运行
`scripts/release-status.py --ref origin/main`，并用 `scripts/release-surface-diff.py` 分别对照各产品上一个正式 tag。

本 PR 只准备版本号、双语更新说明和发版记录；tag 只在 PR CI 全绿并 rebase-merge 后创建。本会话不运行 Apple 打包，
不上传 TestFlight，不提交 App Store 审核。

## 发布范围

| 组件 | 上一版 | 新版 | tag | 依据 |
|---|---|---|---|---|
| 服务器 / Web / CLI | 0.49.1，runtime 25 | 0.50.0，runtime 仍为 25 | `v0.50.0` | 海报角标、飞书 / Lark 扫码创建应用机器人、五端播放器跨季选集接口都是新能力，走 minor；另有浏览器扩展刷新 Cookie 不再重新启用已停用站点的修复。 |
| iPhone / iPad | 0.12.7 | 0.13.0 | `ios-v0.13.0` | 播放器内选集与跨季切换是新能力，走 minor；另含 iPhone Duo 手势、提示和窄窗口布局修复。 |
| Mac | 0.12.7 | 0.13.0 | `macos-v0.13.0` | 播放器新增可常驻的选集侧栏与 E 快捷键，走 minor。 |
| Apple TV | 0.12.7 | 0.13.0 | `tvos-v0.13.0` | 播放器新增遥控器操作的分集剧照排与换季，走 minor。 |
| Android | 0.9.5 / 30000017 | 0.10.0 / 30000018 | `android-v0.10.0` | 播放器新增选集抽屉并替换原集号宫格，走 minor；`versionCode` +1。 |
| Android TV | 0.7.5 / 14 | 0.8.0 / 15 | `androidtv-v0.8.0` | 播放器新增分集剧照排并替换原全屏集号宫格，走 minor；`versionCode` +1。 |

Apple 三端共用 `MARKETING_VERSION`，本轮三端都有用户可见新能力，因此一起发 0.13.0。五端整体最低登录版本不变；
旧服务器仍能显示当前季，只有播放器内跨季列表需要服务器 0.50.0。客户端可降级，所以合入后先发五个 App，等 Release
全部公开且不是 latest，再发服务器，确保服务器正文末尾的客户端一节能列到这批新版。

## 不发布

- Windows：`windows-v0.1.4` 之后没有产品文件变化；`release-status.py` 与 surface diff 都是零变化。
- Mac 转码器：0 个产品文件变化，握手协议仍为 1。
- HarmonyOS：仓库仍没有 `harmony-v*` 正式 tag，正式签名与工具链未就绪；不发布未签名 HAP，不在这轮做渠道首发。
- NER 模型：没有独立产物变化。
- #1259 只增加 PR 模板；不构成发布理由。

## 说明盘点

| 来源 | 维度 | 用户可感知变化 | 写入或取舍 | 证据 |
|---|---|---|---|---|
| #1250 | 新能力 / 默认 | 海报墙可显示评分、年份、分辨率、HDR / 杜比视界 / 全景声、播出状态、中文字幕、未看集数和观看进度；全部默认关闭，只影响当前账号 | 服务器第一亮点 | `poster-badge-settings.tsx`、`settings/schemas.py`、海报墙浏览器 E2E |
| #1250 | 前提 / 成本 | 后端只计算客户端请求的角标分组；不开角标时不新增墙面查询负担 | 正文只写默认关闭；实现细节不写 | `api/deps.py`、`services/library/items.py` 固定查询数测试 |
| #1251 | 新能力 | 飞书 / Lark 可扫码创建自建应用机器人，默认推给扫码人，也可填群目标；卡片失败回退纯文本 | 服务器第二亮点 | `channel-bind-dialog.tsx`、`feishu_channel/binding.py`、`card.py` |
| #1251 | 前提 / 已知限制 | 新应用需要发消息权限并发布；未完成凭据内存保留 30 分钟，重启即失效；真实飞书租户未做端到端验证 | 服务器亮点限制 + PR 待复核 | 绑定提示、定时清理代码；PR #1251 验证说明 |
| surface diff | 拿走 / 改名 | 原来只讲群 Webhook 的飞书说明消失，被 Webhook 与应用机器人两种接入说明替代 | 写入飞书亮点 | `feishu_channel/driver.py` |
| #1257 | 修复 | 浏览器扩展刷新 Cookie 时，已停用站点不会被重新启用，也不会排队验证 | 服务器「修好了」 | `routes/extension.py`、`credential_repo.py` 回归测试 |
| #1258 | 新能力 / 兼容 | iPhone、Mac、Apple TV、Android、Android TV 均可在播放器内选集；缺集不可点，换季只换列表；旧服务器只少跨季菜单 | 五份 App 亮点 + 服务器改进 | 五端播放器实现；`GET /playback/items/{id}` 的可选 `seasons` 字段 |
| Android surface diff | 拿走 / 改名 | 手机原来的集号宫格与旧季集标题替换为侧边选集抽屉；「尚未连接服务器」只从播放器重构点消失，别处仍有 | 前者写入 Android 说明；后者属代码搬动不写 | `PlayerEpisodeDrawer.kt`、`PlayerScreen.kt` |
| Android TV surface diff | 拿走 / 改名 | 原全屏集号宫格及「按确认播放这一集」提示被播放器内剧照排替代 | 写入 Android TV 说明 | `EpisodeShelf.kt`、`PlayerOverlays.kt` |
| #1255 / #1256 | 修复 | iPhone Duo 头像手势、提示位置、操作文字和窄 regular-width 详情布局修复 | iPhone「修好了」 | `TabBarAccountGestures.swift`、`LibraryItemDetailView.swift` |
| `16118e592` | 布局适配 | iPhone Duo 选集沿用内屏左右折叠布局 | 并入 iPhone 亮点 | `PlayerFold.swift`、布局测试 |
| `b99a3bfaf` | 不写 | 只登记本轮播放器控件词条的 source hash | 不构成发布理由 | `Localization.meta.json` |

没有数据库迁移、Docker runtime、运行时依赖、最低登录版本或转码器协议变化。服务器播放改动只增加条目信息字段，
没有修改 ffmpeg、硬件探测或转码参数，因此不触发硬件转码矩阵。

## 验证与风险

- `python3 scripts/release-status.py --ref HEAD --offline`：六个发布组件均显示版本已递增，可以发；Windows 与转码器无改动，Harmony 仍无正式 tag。
- `scripts/tests`：51 项通过，覆盖 release status / info / body、下载清单、CLI、Android、Android TV 与 Harmony 发布门禁。
- `scripts/export-spec.sh`：服务端与 CLI OpenAPI spec 同步导出，hash `518097d60426091d`；两份完整 SHA-256 均为 `ba61cfe972682c180c8a0b9e0c61dc53da0a1681949372191b1c6fc05fb65714`（构建产物不入 git）。
- 六份 changelog 的双语格式检查与 `git diff --check` 通过。
- 以发版 PR 的全量 CI 全绿为最终门槛。只对 `test_entrypoint_supervision` 或 Harmony HAP inspect 这类已知 flaky 作业重跑一次；仍失败就停止。
- #1250 已有真实 Next + API + SQLite 的海报角标浏览器 E2E；#1258 已有 iPhone / Apple TV 模拟器 E2E、Android Compose / Robolectric 测试与 Mac 调试驱动走查。
- 待真机复核：Android 两端真实播放中的 SurfaceView 让位动画与剧照加载；Apple 三端真实设备手感；Mac 换季系统菜单。
- 待外部复核：#1251 没有在真实飞书 / Lark 租户完成扫码创建、权限发布与消息投递端到端，只做了 mock HTTP。
- 本会话不做 Apple 打包、TestFlight 上传或 App Store review。

## 合并之后

见 `commands.md`。五个 App tag 和服务器 tag 都必须指向本次 rebase-merge 提交。应用 Release 全部公开且
`latest=false` 后，才创建服务器 tag。服务器 Release 公开并成为 latest 后，再核对 Docker 的 `v0.50.0`、
`latest`、`runtime-25` 三个 manifest digest。
