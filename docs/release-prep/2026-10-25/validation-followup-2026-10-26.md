# 发布阻塞修复与复验（2026-10-26）

接续 [首次验证记录](validation.md)。本轮只修代码、测试与本地发布准备；没有打 tag、创建 Release、上传商店、推送镜像或合并 PR。13 个修复 PR（#1029–#1041）及随后的 #1042 均由外部合入主线，本轮没有执行合并。

## 执行约定与基线

- 无人可回答问题，按以下假设执行：各类修复从当时最新 origin/main 建独立分支；未合并修复可以在本地集成用于验证，远程 main 不由本轮改写。release-prep 最后只在本地 rebase，原版本提交的补丁内容不变，验证记录另作提交。
- 原 release-prep 版本提交 `87c926d4b81c383a36daea355603f59351faeeb7` 已在本地 rebase 为 `58127ade0f3006a8385b4f277f888993af4dc173`，基于修复后的 `origin/main=b9a0e04fdbb21425d5382870c5015e922d4a4b33`。前后稳定 patch-id 均为 `01d11bf5d8d798317a50434df06f17c02002ea65`，版本/说明提交补丁内容未变。原用户 stash：1e25b8444c5524431d223568e87652914d42694f，保持未动。
- 2026-10-26 接手续验：再 rebase 到 `origin/main=948acd26c21f334a42ecabc8e4fa3c6d1676d09f`（含 #1042），版本提交为 `1f7fafc7b378b8dcbc6ae4d13a88cff32231fe34`，稳定 patch-id 仍为 `01d11bf5d8d798317a50434df06f17c02002ea65`。下文 Apple 三端与 Android TV 构建均在该提交的独立 worktree 上从零构建（独立 DerivedData、独立 SPM 副本），日志在 `/tmp/mc-release-claude/`。
- 本机 macOS arm64，pnpm 10.32.1；Python 大套件改用 Linux/Python 3.12/非 root 用户；浏览器语言 E2E 用 Linux/Node 22/Chromium；Android 使用 JDK 21。
- 所有日志与临时产物在 `/tmp/movieclaw-release-fixes/`，是本地证据，不是已发布附件。没有用 Windows 桥模拟或软件编码结果冒充实机/GPU 验收。

## 修复结论与验证

| 类别 | 根因、修复与 PR | 本地验证 |
|---|---|---|
| CLI UDP 多网卡 | 真 bug：同一服务从不同网卡回复被按源 IP 拆成多台。按 instance_id/Jellyfin Id 合并并保留候选地址，无 ID 保留源地址回退。[#1029](https://github.com/movieclaw/MovieClaw/pull/1029) | 真实 UDP、多网卡两项、完整 Go test/vet、发现 race 通过；六平台 0.43.0 CLI 交叉编译通过 |
| i18n 静态门禁 | unused_keys 为每个词条反复扫描全部源文；改为一次索引引用并保留嵌套引用识别。[#1030](https://github.com/movieclaw/MovieClaw/pull/1030) | 84 项测试；完整门禁 40.832 秒通过，保留 197 项既有警告 |
| Windows worker 进度测试 | 2.5 秒断言混入 Python 冷启动；改为小段进度已读且进程/管道仍存活，检验真实流式交付。[#1031](https://github.com/movieclaw/MovieClaw/pull/1031) | 242 通过、2 项 Windows 注册表测试跳过 |
| HEVC E2E | 夹具引用已删除 remote_worker_available；改用 remote_backends_available，明确快速失败模拟窗口。[#1032](https://github.com/movieclaw/MovieClaw/pull/1032) | HTTP→真实 ffmpeg→分片/回退→ffprobe：7 通过。软件编码代替硬件；额外 Chrome 测试在 Next 冷启动超时，未记通过 |
| Windows 播放器浏览器 | 真 bug：500ms mpv 快照反复重建设置菜单，按钮丢焦点。只在轨道/倍速改变时更新；测试用事件屏障消除操作与状态竞争。[#1033](https://github.com/movieclaw/MovieClaw/pull/1033) | 完整浏览器 125/125，默认 30 秒、无 retries，20.8 分钟；JS 原套件 112 项及新增焦点单测 1 项；另有重复场景验证 |
| 依赖安全/重复锁 | next>postcss 固定 8.5.29，Next 仍 15.5.28；pnpm 10 重生成锁。Web npm 锁无构建消费者，删除并让 Dependabot 仅扫描根 pnpm workspace；桌面 npm 锁保留。[#1034](https://github.com/movieclaw/MovieClaw/pull/1034) | pnpm audit --prod 0；frozen install、生产构建、1,123 Web 单测通过；真实 ARM 生产容器初始化→首页→语言保存/刷新通过，无 JS errors |
| 语言/伪语言浏览器 | 等待真实 hydration 与 HTTP 响应，使用 UI 登出；manifest 使用页面 fetch 发送真实 Accept-Language/cookies。[#1035](https://github.com/movieclaw/MovieClaw/pull/1035) | 两项完整真实浏览器 E2E 通过，41.03 秒，含伪语言、manifest、中英文错误与持久化 |
| 更新三件套构建 | Mac 脚本试图执行 Linux ELF，只有 CPU 架构判断。增加 OS 判断。[#1036](https://github.com/movieclaw/MovieClaw/pull/1036) | Mac 与 Linux 完整构建脚本均通过；Linux 0.43.0 三件套 hash/布局/无 .node 校验、两架构 CLI 实际执行通过 |
| API 取流测试隔离 | 共享 data/metadata 污染，且断言全池连接误把后台连接算成请求泄漏。隔离目录并直接追踪请求事务，保留后台占用作验证。[#1037](https://github.com/movieclaw/MovieClaw/pull/1037) | 两个完整文件 227 通过、1 既有 xfail；真实 HLS 单项及 targeted 通过 |
| 三项发布 CI 不稳定 | 心跳测试定时器与首个快照竞争，改为真实 SSE 事件驱动时钟；TV 夹具缺完整元数据触发后台自愈覆盖 NFO，补齐并初始化隔离 setting store；任务取消是真竞态：旧 RUNNING 读覆盖已释放租约的 BLOCKED，使用 SQLite 写锁后刷新再转状态。[#1038](https://github.com/movieclaw/MovieClaw/pull/1038) | 四个完整文件 83 通过；三项原场景和三个竞态回归共 6 项，10 个独立进程轮次共 60 通过；旧实现确定性复现取消竞态，无 skip/放宽断言 |
| 随带 Web 主题生命周期 | 生产构建包含 Netflix，纯 Web 插件却申报不可热重载；空后端无资源，明确 reloadable=True。[#1039](https://github.com/movieclaw/MovieClaw/pull/1039) | 新断言旧代码失败；主题全套与契约 13 通过，真实 HTTP 禁用/启用/资源/卸载恢复；随后完整大套件的全插件生命周期通过 |
| Android SSE 测试 | 逐帧 delay(10) 依赖调度速率触发背压并拖延排空；改为首帧等待真实响应体关闭再排空。HTTP callEnd 早于 SSE 解析，不能作为屏障。[#1040](https://github.com/movieclaw/MovieClaw/pull/1040) | 修复后完整网络类连续三轮，每轮 17 项通过；0.8.0 手机完整单测 164/164，通过的 Debug APK 含 arm64 FFmpeg JNI 及依赖库；lint 通过（77 warnings、6 hints、0 errors） |
| 离线导出并行隔离 | HEVC 切 H.264 重转用无台账目录，被另一个测试的启动清理误删。隔离 data/metadata/transcodes，并重置会话管理器。[#1041](https://github.com/movieclaw/MovieClaw/pull/1041) | 另一个管理器在 spawn 前清理的定点探针：旧夹具失败，新夹具通过；同一真实 HTTP/ffmpeg/ffprobe 场景独跑通过；合入后 #1042 的 PR CI 上 Python 三分片完整并行套件通过 |

上述每个 PR 的中文描述记录背景、原因、做法、备选方案与验证。#1031、#1032 的远端重跑和合并由用户处理，本轮没有操作。

## 组合回归与最终产物

Python 完整并行套件以主线 CI 为准：#1042（合并提交 948acd26c）的 PR 检查 Python 1/3～3/3、i18n、Android/Android TV 汇总均通过；本机 Linux 大套件没有在最终修复集上重跑。首次 Linux 大套件的 root 权限、缺少 procps/curl/git、系统 FFmpeg 版本不一致是验证环境问题；修正后 6,138 通过、仅离线夹具隔离 1 项失败（7 skipped、6 xfailed）。不能把这轮记为全绿。并行手机/TV 共用 android-core 输出造成过 NoClassDefFoundError，TV 最终改在独立 worktree 中构建，与手机不共享任何项目输出；不据此改产品。

- 生产容器：Linux arm64/amd64 0.43.0 镜像均曾完成构建、11 语言 PGS→SRT OCR 与健康接口验证。最终修复集的 arm64 `2b3b747e8263` 与 amd64 `1ba34f7a7ea0` 再次构建、OCR、健康 200 通过；version=0.43.0、spec_hash=4756cd85941ede0f。ARM 真实浏览器初始化、语言保存与刷新无 pageerror。见 `container-final-health.json`、`container-browser-final.log`、`docker-final-*-ocr.log`。
- Apple TV：完整无签名 Release 编译通过；增量 0.11.0 (1) 候选构建也通过，实际 Info.plist 已核对。接手续验在 `1f7fafc7b` 上从零重编三端 Release 无签名构建（`ci-build.sh`，Xcode 27.1）：iOS（约 70 分钟，主 target 整模块优化占大头）、Mac（约 23 分钟）、tvOS（约 17 分钟）均 BUILD SUCCEEDED、无编译错误，产物 Info.plist 均为 0.11.0 (1)。本机 Xcode 27 编过不等于 CI 的 Xcode 26 能过，以发布 PR 的 Apple CI 为准。
- Android 手机：0.8.0 (30000011) Debug APK 已核对，SHA256 `7bb2ad75fbea523f629102e3d0c06d328fb1e3220f9b640e372a19e56a65fc52`；164 项完整单测无失败。手机完整 Gradle 流程通过（23m20s，lint 77 warnings/6 hints/0 errors）。Android TV 接手续验在 `1f7fafc7b` 上独立跑完 commands.md 的完整 Gradle 流程（JDK 21，12m22s，BUILD SUCCESSFUL）：android-core + TV 单测 258 项 0 失败 0 跳过；lint 0 errors/23 warnings/6 hints；Debug 与无签名 Release APK 均为 0.7.0 (9)，各含 16 个 native .so；SHA256 Debug `46c0dffebda4e30b22f2125317868aa1da4578a8948f98550ce166bf24cb1145`、Release(unsigned) `02b8ec1be73c28b28962500e446d62a7d975d524845a59d9872df84ec99d38d2`。
- 原生 FFmpeg：使用 NDK 27.3/CMake 3.22，arm64-v8a、armeabi-v7a 两套编译通过。上游 configure 不接受含空格 TMPDIR，本地设 TMPDIR=/tmp 后通过；未修改产品脚本掩盖环境问题。
- Rebase 后 Release 说明/状态脚本 15 项通过（`rebased-release-check.log`）；版本状态只说明版本递增，不代替实机/签名门禁。最终镜像构建树与 rebase 后版本提交仅有 Android SSE 测试、离线夹具两个测试文件差异，生产代码和版本完全一致。
- 继承首次验证的通过项：数据库从 0.42.0 迁移并保留 sentinel、完整性检查；Release 说明/状态脚本；Web ESLint（45 warnings）；扩展 ZIP。新大套件再覆盖相应脚本测试。

## 仍需人工完成

- Windows 真机 Rust/NSIS、WebView2/mpv、托盘/注册表、自启、首次 ffmpeg 下载、安装升级卸载与 SmartScreen；本机无 Windows 运行环境。
- NAS/Windows GPU 的 VAAPI/QSV/NVENC HEVC/H.264、IDR/seek/HDR tone map、并发及硬件故障回退；Safari/iPhone 原生 HEVC。
- Apple 正式签名 archive、Developer ID、公证和 Sparkle 签名；Android 正式证书与商店构建号核验。无签名/Debug 包不等同正式发布产物。
- iPhone/iPad/Mac/TV/Android 实机语言、布局、遥控器/焦点、后台与网络恢复、旧正式版覆盖升级。
- 真实数据库备份副本的容量、迁移耗时与恢复演练，新旧服务器/客户端完整组合。
- Windows worker 独立渠道、下载清单与签名配置需要 Windows 产物及维护者渠道配置；不创建未经实机验证的发布工作流。
- 本地镜像未提供正式 TMDB key/update 公钥，不能直接作为正式发布镜像。
