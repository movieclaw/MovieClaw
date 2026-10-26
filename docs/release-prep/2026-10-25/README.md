# MovieClaw 发布准备（未发布）

2026-10-26 补充：[发布阻塞修复与复验](validation-followup-2026-10-26.md)。14 个修复 PR（#1029–#1042）已进入主线，`release-prep` 已 rebase 到 `948acd26c`，原版本提交补丁内容保持不变。以下表格及首次验证记录保留为历史快照，最新结论以补充记录为准。

基线：2026-10-25 fetch 后的 `origin/main`，`a4559c65d50702497d7d90a022d10c79e15e9ee1`（含 #1027）。本地分支 `release-prep`。
原分支为 main，未跟踪的 `work/` 已保存为 `stash@{0}`，说明为 `release-prep: preserve pre-existing work 2026-10-25`，没有恢复到发布分支，也没有删除。

本次只准备版本、说明与验证记录；没有 push、创建 tag、GitHub Release、触发发布工作流或上传商店。
按 `.claude/skills/release/SKILL.md` 及 `changelog-guide.md` 执行；正式 changelog 英文在前、完整中文在后。以下“当前版本”指同步后的主线、尚未做本次 bump 时的值。

## 发布建议与版本来源

| 组件 | 当前版本 / 最近正式发布 | 建议版本 | 是否发布 | 理由 | 发布前阻塞项 |
|---|---|---|---|---|---|
| 服务端 / NAS 镜像 | 0.42.0 / `v0.42.0`，10-22 | 0.43.0；runtime 24 | 是，完成验收后 | 中英本地化、HEVC、Windows worker 支持、订阅上限、插件入口和修复 | PostCSS 审计仍有 2 高危 / 2 中危；HEVC E2E 夹具失效；GPU 矩阵；双架构镜像和签名清单验证；升级前备份 |
| Web | 无独立版本，随 `v0.42.0` | 随 0.43.0 | 随服务端 | #1027、#1024、#1023、播放器改进 | Web/浏览器验证；Safari HEVC 实机 |
| iOS / iPadOS | 0.10.0 / `ios-v0.10.0`，10-22 | 0.11.0 | 是 | 中英界面、画面模式、旋转字幕、DV P5 选项 | iPhone/iPad 候选版本实机；正式签名；ASC/TestFlight 实际已分发版本和 build number 核对 |
| macOS 播放客户端 | 0.10.0 / `macos-v0.10.0`，10-22 | 0.11.0 | 是 | 中英界面、DMG、Sparkle、全屏修复 | Developer ID / 公证 / Sparkle 签名；英文真机；旧包升级到新包 |
| tvOS | 0.10.0 / `tvos-v0.10.0`，10-22 | 0.11.0 | 是 | 中英界面、共享规则选项 | TV 全页面英文和遥控器实机；签名与 TestFlight（GitHub 工作流只创建说明） |
| Android 手机 / 平板 | 0.7.0 (30000010) / `android-v0.7.0`，10-22 | 0.8.0 (30000011) | 是 | 平板、扫码、离线、内外网切换、预切片段 | 正式签名/完整 native 依赖；Wi-Fi 中断恢复、后台、账号隔离和旧包升级实机 |
| Android TV | 0.6.0 (8) / `androidtv-v0.6.0`，10-22 | 0.7.0 (9) | 是 | 滚动优化、主页深链、焦点、屏保、联网重试 | 签名/完整 native 依赖；电视桌面深链/遥控器/屏保/冷启动实机 |
| Windows 播放客户端 | 0.1.1 / `windows-v0.1.1`，10-20 | 0.1.2 | 是，低优先级 | 仅 catalog 的 DV P5 规则选项变化，不包含 #1014 转码器 | Windows Rust 构建、安装冒烟、release evidence；目前流水线产物未签名 |
| Windows 转码器（独立应用） | 0.1.0；没有独立 tag/Release | 0.1.0 首发 | 需要首发，但暂缓公开发布 | #1014 新增 NVENC Worker、托盘、安装器 | 无独立发布流水线/下载清单支持；Windows 打包、签名策略、真实 NVENC 矩阵 |
| Mac 转码器 | 0.33.1 / `transcoder-v0.33.1`，10-20 | 保持 0.33.1 | 否 | 自上次发布目录零差异；协议仍为 1 | 新服务器搭配旧 Worker 的回归仍要做 |
| CLI `mclaw` | 随 `v0.42.0` 注入版本 | 0.43.0 | 随服务端 | API/spec 与命令树更新；不单独打 tag | 本机 UDP 发现测试失败，须确认多网卡表现；六平台构建记录见验证报告 |
| Netflix 主题插件 | 主线已 1.2.0；v0.42.0 随带 1.0.0 | 保持 1.2.0 | 随服务端 | 英文主题和 UI theme API ^1.3、hero、依赖升级 | 不应向旧服务器单独强推；主题构建/浏览器验证 |
| 浏览器扩展 | 0.1.0；随 v0.42.0 打包，无独立 Release | 保持 0.1.0 | 不单独发；随镜像重建 | 扩展源码零差异，锁文件有构建依赖升级 | Chrome/Firefox zip 构建；本次没有商店上传 |
| HarmonyOS | 1.0.0 / versionCode 1000000，未找到正式 Release | 保持 1.0.0 | 暂不首次公开发 | 仅 DV P5 catalog 有增量；没有已建立的正式发行流程 | DevEco/HarmonyOS 工具链、签名、实机、渠道与首发验收 |
| NER 模型 | `torrent-ner-v3`，08-17 | 保持 v3 | 否 | ml/ 自该 tag 无差异，无新训练产物 | 没有新模型可发 |
| watch-presence 插件 | manifest 1.0.0；无独立 Release | 保持 1.0.0 | 否 | 自 v0.42.0 目录无差异；现有工作流仅提供测试附件 | 若未来首发，另定渠道；不把 CI artifact 当公开 Release |
| 内置下载器 / 消息渠道 / STRM 插件 | 各自 manifest，见下 | 保持主线已定版本 | 随服务端 | #1027 本地化元数据，随 Python 源码分发 | 不在本次建立独立插件发布渠道 |

版本事实源：

- 服务端：`pyproject.toml`、`src/movieclaw_api/__init__.py`；镜像依赖契约 `docker/runtime-version`（上一版 23，主线已经 24，本次不重复加一）。
- Apple 三端共用 `apps/apple/project.yml: MARKETING_VERSION`，本次 0.11.0；`CURRENT_PROJECT_VERSION=1` 是工程缺省，商店打包脚本另生成 UTC 时间构建号，不能据此认定下一个 ASC 构建号可用。
- Android 两端：各自 `version.properties`，版本名称和 code 均递增。
- Windows 播放器：`apps/desktop/package.json`、`src-tauri/Cargo.toml`，同步 package-lock.json、Cargo.lock 的本包版本。
- Windows 转码器：`windows/MovieClawTranscoder/movieclaw_transcoder/__init__.py` 与 `app/movieclaw_transcoder_app/__init__.py` 均为 0.1.0；打包脚本读取后者。
- Mac 转码器：`macos/MovieClawTranscoder/Resources/Info.plist`。
- CLI：`cli/.goreleaser.yaml` 将服务器 tag 版本通过 `-X main.version=...` 注入二进制。
- 主题：`plugins/netflix/package.json`、`movieclaw-plugin.toml` 均已是 1.2.0，生成后的 `src/movieclaw_plugins/netflix` 不入 git。
- 扩展：`apps/extension/package.json`；HarmonyOS：`apps/harmonyos/AppScope/app.json5`；NER：独立训练产物与 tag，不取服务端版本。
- 内置插件的 `src/movieclaw_plugins/*/movieclaw-plugin.toml`：discord/feishu/telegram/weixin 1.1.0，qbittorrent/transmission 1.0.0，strm_prefetch 1.0.1。

联网核对的 GitHub Release 版本不等同 App Store / TestFlight / Google Play 的实际分发状态；本次没有读取商店私密凭据或声称完成渠道核验。

## 提交与 PR 归属

完整逐组件路径提交列表、36 个区间 PR 与 SHA 见 [commits.md](commits.md)。共同的服务端变化不等于每个客户端都必须重新打包。

- 服务端/Web：#973/#995 观看历史/状态交换；#982 会话回收；#983 站点代理；#991/#1019/#1023 插件信息与行级深链；#993 VAAPI；#1002/#1003/#1007 下载/订阅/待处理修复；#1000 Windows 认证；#1004 DV P5；#1013 长剧订阅；#1014 Windows worker；#1017/#1021 HEVC；#972/#988/#989/#990/#1012 Web 播放与主题；#984/#1024 依赖更新；#1027 国际化与迁移。
- Apple 共用部分：#1000 模型兼容、#1004 DV P5、#1027 国际化；iOS 额外 #972；Mac 额外 #1005/#1009/#1011/#1015。tvOS 不把 Mac 的 Sparkle、iOS 的画面模式写成自己的功能。
- Android：#1001/#1016 为主要功能，#1004 与 #1027 还改到规则/共享模型；后者不代表 Android 已完整英文化。
- Android TV：#975、#1018、#1020，加 #1004 与 #1027 的共享模型；#1018 实际还包含 `5cbc0bf46` 海报屏保与 `c22d62c23` 焦点修复。
- Windows 播放器：只有 `c8fd296b9`（#1004）两行 catalog 变更。Windows 转码器是 `c58ea3266`（#1014）新目录，`a4559c65d`（#1027）整合了服务端远程转码的本地化文案。
- CLI：`af934b55a`（#991）和 `41a44f6bb`（#983）更新命令守卫，服务端 spec 的变更随构建重新导出。
- #1024 才是本次安全依赖升级（替代 #1010）；#1023 是插件能力深链，#1026 只是 Dependabot 忽略 Next 大版本策略，不能把 #1023/#1026 写成新的安全修复。没有对具体 CVE 作未经验证的声称。
- #981 仅测试体积替身；纯 CI、文档、开发过程中的修正不进入用户更新说明。

新增能力采用现有 0.x 的 minor 发布习惯；只有 Windows 播放器的小修订取 patch。新 Windows 转码器用已有 0.1.0，不跳增；尚无既定前缀，建议 `windows-transcoder-v0.1.0`，这只是提案。

## 迁移与兼容

- 相对 `v0.42.0` 新增 17 个迁移；基线头 `d7a2e4f9c615`，新头 `c6f14d3a9b72`，包含观看记录、订阅上限、语言偏好与历史说明引用。隔离升级结果见 [validation.md](validation.md)。
- runtime 24 已加入 Babel/ICU Python 依赖；runtime 23 镜像不能仅靠覆盖层升级。停容器后备份完整数据目录，再换 `v0.43.0` 镜像；本路径不应声称有应用内自动备份。回退应恢复旧镜像及对应数据备份。
- 远程 Worker 协议仍为 1（服务器、Mac 和 Windows 一致），没有必须强制同时升级 Mac Worker 的协议变更。HEVC 是否选用取决于客户端与硬件能力，不承诺所有设备都出 HEVC。
- Apple 的最低服务器常量仍为 iOS/tvOS 0.28.0、macOS 0.31.0；Android 0.33.0、Android TV 0.28.0。它们是现有登录门槛，不是本次新功能的充分条件。没有为了发布准备擅自抬高这些常量；旧服务器兼容未全部实测，作为放行条件。
- 完整服务端语言提示、DV P5、新 Windows worker 的配套体验按服务器 0.43.0 验收；Android 地址切换的服务器能力从 0.42.0 提供。
- #1027 PR 自报仍未完成 Mac 英文实机、TV 除首页/详情外的英文走查；本次不把既有模拟器记录视为这些项目已完成。

## 中文 release notes 草稿

每个拟发布产品均有中文正文（同时维护英文）：

- [服务器 / Web / CLI 0.43.0](../../changelog/v0.43.0.md)
- [iPhone / iPad 0.11.0](../../changelog/ios-v0.11.0.md)
- [Mac 0.11.0](../../changelog/macos-v0.11.0.md)
- [Apple TV 0.11.0](../../changelog/tvos-v0.11.0.md)
- [Android 0.8.0](../../changelog/android-v0.8.0.md)
- [Android TV 0.7.0](../../changelog/androidtv-v0.7.0.md)
- [Windows 播放器 0.1.2](../../changelog/windows-v0.1.2.md)
- [Windows 转码器 0.1.0 首发草稿](windows-transcoder-0.1.0.md)

随带组件的补充草稿（不建独立 Release）：

- **CLI 0.43.0**：命令目录与新版服务器接口同步，覆盖站点代理和插件市场接口分类；与服务器一同提供六平台安装包。
- **Netflix 主题 1.2.0**：主题导航与订阅页支持英语，随网页语言切换；改进媒体库首屏的渐变与文案布局。需要提供 UI theme API 1.3 的新版服务器。
- **内置消息渠道等插件**：增加英文名称、说明与通知展示，保留已有配置；实际第三方内容与日志不保证翻译。

所有草稿以验证放行为前提；Windows 转码器尚无可公开下载版本，服务器正文中的对应功能段必须与其渠道上线协调，不能留下“支持但用户无处下载”的最终说明。

## 本地改动与恢复

只修改 9 个版本文件（含两个 Windows 锁文件），新增 7 份 changelog 和 5 份准备文档；共 21 个文件；没有修改产品功能、迁移、流水线或最低版本常量。OpenAPI 两份 spec 已重新导出，是忽略的构建产物。构建临时改写的 next-env.d.ts 已恢复，不包含在改动中。依赖安装更新了本机 `.venv`、node_modules 和构建缓存，不是提交内容。

保留 stash，不自动 pop 进发布分支。以后回到原分支恢复：

```bash
git switch main
git stash list
# 确认仍是本次保存的条目；用 apply 保留备份，不用 pop。
git stash apply 'stash@{0}'
```

发布顺序和可复制命令见 [commands.md](commands.md)。测试状态见 [validation.md](validation.md)。
