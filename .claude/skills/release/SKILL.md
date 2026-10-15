---
name: release
description: 发布 movieclaw 新版本。当用户要求发版、发布新版本、打 tag、看看哪些该发，或发布服务器、NER 模型、Docker 镜像、各客户端（iPhone、Apple TV、Mac 版、Mac 转码器、Android、Android TV、Windows），或打包上传 iOS App 到 TestFlight / App Store、补传发版附件时使用。涵盖产品与 tag 总览、改动检查脚本、通用发版流程、各产品要点、changelog、失败补救与检查清单。
---

# movieclaw 发布规范

服务器、模型和每个客户端都**各自单独发 GitHub Release**，互不搭车：发哪个由人决定，一个 tag 只发一个
产品。机制背景见 `docs/design/in-app-update.md`、`docs/design/android-release.md`、`docs/design/ios-release.md`。

## 一、先判定要发什么

### 产品与 tag

| 产品 | tag | 版本号在哪 | 工作流 | Release 标题 | 用户怎么拿到 |
|---|---|---|---|---|---|
| 服务器 | `vX.Y.Z` | `pyproject.toml` + `src/movieclaw_api/__init__.py` | `release.yml` | MovieClaw Server X.Y.Z | 设置页一键更新 / Docker 镜像 |
| iPhone / iPad | `ios-vX.Y.Z` | `apps/apple/project.yml` 的 `MARKETING_VERSION` | `apple-release.yml` | MovieClaw for iPhone and iPad X.Y.Z | TestFlight；未签名 IPA 侧载 |
| Apple TV | `tvos-vX.Y.Z` | 同上 | `apple-release.yml`（只建说明，无附件） | MovieClaw for Apple TV X.Y.Z | TestFlight |
| Mac 版 | `macos-vX.Y.Z` | 同上 | `apple-release.yml` | MovieClaw for Mac X.Y.Z | 官网下载公证 zip |
| Mac 转码器 | `transcoder-vX.Y.Z` | `macos/MovieClawTranscoder/Resources/Info.plist` | `apple-release.yml` | MovieClaw Transcoder X.Y.Z | 官网下载公证 zip |
| Android | `android-vX.Y.Z` | `apps/android/version.properties` | `android-release.yml` | MovieClaw for Android X.Y.Z | `movieclaw.io/download/android.apk` |
| Android TV | `androidtv-vX.Y.Z` | `apps/android-tv/version.properties` | `android-release.yml` | MovieClaw for Android TV X.Y.Z | `movieclaw.io/download/androidtv.apk` |
| Windows | `windows-vX.Y.Z` | `apps/desktop/src-tauri/Cargo.toml` + `apps/desktop/package.json` | `windows-release.yml` | MovieClaw for Windows X.Y.Z | 客户端内检查更新 |
| NER 模型 | `torrent-ner-vN` | 训练产物 | 手动（第五节） | MovieClaw NER Model N | 设置页一键更新模型 |

硬规则：

- **tag 命名**：服务器是主产品，用不带前缀的 `vX.Y.Z`；客户端一律「产品前缀-vX.Y.Z」；模型用整数。
  已部署的服务器只认 `v` 与 `torrent-ner-v` 两种前缀找更新，**这两个前缀不能改**；Windows 更新器只认
  `windows-v` 与 `MovieClaw-Windows-*` 安装包名，要改须先发一版同时认新旧名字。
- **只有服务器 Release 标 latest**：其余一律 `--latest=false`（流水线已带）。install-cli.sh 从
  `releases/latest/download` 取 mclaw，别的 Release 成了 latest 安装立刻 404。
- **tag 必须等于代码里的版本号**，同一版本发过就不能再发（流水线会拦）：代码里的版本已经发过，
  就先递增再发；还没发过（如 Windows 首发 0.1.0）就直接用它。Android 的 `versionCode` 每次 +1
  （上限 2100000000）。
- Apple 三端共用 `MARKETING_VERSION`：同一版本每个平台只能发一次。某个平台要发而它已发过这个版本，
  先递增补丁号，其他平台下次随之用新版本号，跳号无妨。

### 看哪些该发

```bash
python3 scripts/release-status.py --ref origin/main
```

对每个产品列出上次发布的 tag、代码里的版本号、该产品目录下自上次发布改了多少文件（不算 `.md`）和
最近几条提交，结论是以下之一：「无改动，不用发」「有改动，但版本号还没递增」「有改动，版本号已递增，
可以发」「从未单独发布」。脚本只给事实，发不发由人定：

- 只改了打包脚本、注释的「有改动」不一定值得发；
- Apple 三端共用 `apps/apple/Shared` 等目录，改了共用代码三端都会显示有改动；
- 它只看产品自己的目录：服务器接口变化让某个 App 的行为跟着变，脚本看不出来，盘点 changelog 时要人留意。

### 先后顺序

一个功能同时要改服务器和 App 时，看 App 在老服务器上能不能降级（缺接口时隐藏功能、照常可用）：

- **能降级（推荐这样写 App）**：先发 App，再发服务器。服务器正文末尾的客户端一节取发布时各 App 的
  最新 Release，先发 App 才列得出来；服务器 changelog 在该功能里写明「需要 iPhone 0.7.1 或更新版本」。
- **不能降级**：先发服务器，再发 App，并把 App 的最低服务器版本上调到刚发布的服务器版本（iPhone
  `apps/apple/Shared/App/AppModel.swift` 的 `minimumServerVersion`、Android 手机
  `SessionRepository.kt` 的 `MIN_SERVER_VERSION`、Android TV `AppModel.kt` 的 `MIN_SERVER_VERSION`），
  老服务器上 App 会在登录前提示先升级服务器。这种情况下服务器正文的客户端一节列不出这个 App，
  changelog 里写明「需要 iPhone 0.7.1，随后发布」。
- **转码器握手协议**（服务端 `src/movieclaw_api/services/playback/remote_worker.py` 的
  `REMOTE_WORKER_PROTOCOL_VERSION`，转码器 `BuildInfo.swift` 的 `protocolVersion`，同步 +1）：服务端
  对不相等的一律拒绝，**旧转码器连不上新服务器，新转码器也连不上旧服务器**。两个紧挨着发，服务器与
  转码器的 changelog 开头提示框都写明「需要同时更新服务器与 Mac 转码器」。协议没变、只是新能力派给
  新版转码器（按自报能力派发）时，服务器提示框写明需要的转码器版本。

## 二、通用发版流程（所有产品）

1. **改版本号 + 写 changelog**（`docs/changelog/<tag>.md`，第四节），同一个 PR 合入 main。
   Android 的 `versionName` 与 `versionCode` 一起递增；Windows 的 Cargo.toml 与 package.json 一起改。
   **合入前做一次独立核对**：每个要发的产品另起一个子代理，给它上一版 tag、本版代码、
   `changelog-guide.md`、写好的说明和盘点表，按指南第五节「发版前独立核对」的清单对照代码检查。
   核对结果（含「待真机复核」的项）写进发版 PR 描述；发现的缺陷要么修好，要么写进已知问题。
2. **推 tag**：`git fetch origin main && git tag <tag> origin/main && git push origin <tag>`，构建的就是
   tag 所在的提交（可以是 main 上任意一个已合入的提交）。
   推不了 tag 的环境（远程会话的 git 凭证只能推分支）走点火通道
   `git fetch origin main && git push origin origin/main:refs/heads/release-kick/<tag>`：release-kick.yml
   核对 main 上的版本号后触发对应工作流，并删掉点火分支。点火与 Actions 手动触发都在**触发时的 main
   HEAD** 上创建 tag，发版 PR 合入后 main 若又进了别的提交，它们也会被带上，介意就用前一种方式。
   点火支持服务器与所有客户端前缀，不含模型。
3. **流水线**：核对 tag 与版本号 → 建 draft → 构建 / 签名 / 测试 → 校验产物 → 转正。draft 期间对
   应用内更新、官网、install-cli.sh 都不可见。**任何一步失败 Release 停在 draft，修好后重跑整个
   工作流即可**（上传均带 `--clobber`，可安全重入）。
4. **官网同步**：流水线最后一步通知官网（`scripts/notify-cloud.sh`），官网自己去 GitHub 拉这个版本，
   一分钟内出现在官网下载页和更新日志。通知失败只告警、不挡发版，官网每天全量对账一次兜底。
   手动改过 Release（改标题、补传附件、删除）想立刻生效：Actions → cloud-sync 运行（填 tag 或留空全量）。
5. **验证**：Release 页附件齐全、标题对、正文是 changelog 而不是自动生成的 PR 清单、没有被标成 latest
   （服务器除外）；官网 https://movieclaw.io/zh/changelog 出现了这一版。

推荐 changelog 与版本号同一个 PR 合入；来不及也可以先发后补：发版时没有 changelog 的，正文先用
GitHub 自动生成的提交清单（Windows 用一句默认说明），changelog 合入后 release-notes.yml 自动同步成
正文（服务器顺带重新生成 release.json 与客户端一节，Windows 顺带附上验证范围）。

## 三、各产品要点

### 服务器（`vX.Y.Z`）

- **版本号三处一致**（构建脚本强制校验）：`pyproject.toml` 的 version、`src/movieclaw_api/__init__.py`
  的 `__version__`、tag 去掉 `v`。bump 后跑 `scripts/export-spec.sh`（服务端与 Go CLI 两份 spec）；
  基线 `spec.json` 是构建产物，不入 git。
- **以发版 PR 的 CI 全绿为准**：改了 `__init__.py` 的版本号会触发全量检查（ruff / pytest / cli / web /
  Worker 加 iOS 编译），无需本地重跑全量——本地 pytest 要先下载 NER 模型，沙箱代理还会误报。
- **产物**：应用三件套（app-web.tar.gz / app-backend.tar.gz / manifest.json，启用签名时含
  manifest.json.sig）、mclaw 六平台归档 + checksums.txt、release.json（官网更新日志读它），同时
  发布多架构 Docker 镜像（movieclaw/movieclaw：正式版打 vX.Y.Z + runtime-N + latest，预发布只打
  vX.Y.Z-…）。不带任何客户端。
- **正文**：changelog 原文，末尾由 `scripts/publish-release-body.sh` 自动补「Apps / 客户端」一节——
  上一个服务器版本以来新发的 App（带链接），以及每个 App 的最新版本与安装方式。
- **预发布**：tag 带后缀（`v0.3.0-beta.1`）自动标 prerelease，应用内更新跳过它；后缀数字按数值比较。
- **Docker 镜像与 runtime 契约**：`docker/runtime-version` 是运行时依赖集合的版本代号。改了
  `pyproject.toml` 的 dependencies、Node 大版本、Dockerfile 的系统包（ffmpeg 等）或基础镜像、
  `docker/entrypoint.sh` 的行为契约（重启约定码、目录约定），必须 +1（runtime-guard.yml 会拦漏 bump
  的 PR）。之后发的 Release 声明新的 `requires_runtime`，旧镜像用户会看到「需升级 Docker 镜像」。
  镜像随发版自动发布；单独补发到 Actions → docker-image 输入标签；本地构建
  `TMDB_API_KEY=xxx ./scripts/build-image.sh`（启用清单签名时带
  `--build-arg UPDATE_MANIFEST_PUBKEY=<公钥>`）。
- 改了播放/转码 → 发版前做第七节的硬件转码人工验收。

### Apple 平台（`ios-v` / `tvos-v` / `macos-v` / `transcoder-v`）

- 一个工作流 `apple-release.yml` 按 tag 前缀分别构建：iPhone / iPad（同一个包）编未签名 IPA；Apple TV 不构建，只建一条带
  说明的 Release；Mac 版与转码器在 xcode-27 / macos-26 上编译，Developer ID 签名并公证，生成
  `downloads.json` 供官网下载页读取（macOS runner 上复核签名与公证）。
- 转码器版本只在它自己的 `Info.plist`，不跟服务器走。
- TestFlight / App Store 的上传与 GitHub Release 互不依赖，见第六节。用户说「发 iPhone / Apple TV /
  Mac」时，GitHub Release 由流水线完成；要不要同时传 TestFlight 先问一句——上传要用本机的签名与
  App Store Connect 密钥，远程会话做不了，只能请用户在打包机上跑。Apple TV 的 GitHub Release 只是一条
  说明，真正给用户的是 TestFlight 上的 `--tv` 构建。

### Android（`android-v` / `androidtv-v`）

- `android-release.yml` 正式签名构建 APK，附 `.json` 元数据与 `downloads.json`。正式包要求完整原生
  播放器依赖与固定签名证书，禁止用 debug 证书或 Exo-only 包替代。两个 App 共用一组 Secrets：
  `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`；
  已有官方签名密钥必须沿用，不能因构建失败而重新生成；密钥不入 git、不贴聊天。
- 本地验证：配置签名环境变量后 `bash apps/android/scripts/package-release.sh`（TV 为
  `apps/android-tv/scripts/package-release.sh`）。全景见 `docs/design/android-release.md`。

### Windows（`windows-v`）

- `windows-release.yml` 调用 Desktop CI 跑完整测试并打包（单测、浏览器端到端、Rust 测试、安装冒烟），
  再用 `apps/desktop/scripts/check-release-evidence.py --policy ci-verified` 校验安装包就是测试过的那份、
  版本与提交都对得上，然后上传安装包、便携 ZIP、带构建号的两个 ZIP、`SHA256SUMS.txt`、
  `release-manifest.json` 并转正。
- 正文 = `docs/changelog/windows-vX.Y.Z.md` + `apps/desktop/release/ci-verified-scope.md`（说明托管 CI
  覆盖不到的硬件项，带 `ci-verified` 标记，校验脚本要求有它）。changelog 里不用再写这段。
- 安装包未签名：用户更新时会被要求确认；实际签名状态记录在 `release-manifest.json`。

## 四、changelog

**动笔前必读 `changelog-guide.md`**（本目录下）。一句话：changelog 是写给用户的产品更新说明，不是
变更清单——先用 `git log` 盘点保证不漏，再挑 1～3 个亮点按「痛点 → 现在 → 入口」写，修复只写用户能
认出的症状，其余交给文末的 compare 链接。样板见 `docs/changelog/v0.27.0.md`。

- 文件名与 tag 同名：`docs/changelog/<tag>.md`。英文在前、完整中文在后，中间 `---` + `## 简体中文`。
- 服务器标题行写 `## vX.Y.Z: 主题`（release.json 按它解析）；客户端写 `## <产品名> X.Y.Z: 主题`，
  产品名用 `iPhone and iPad`、`Apple TV`、`Mac`、`Mac transcoder`、`Android`、`Android TV`、`Windows`
  （中文段对应 iPhone 与 iPad、Mac 转码器等），只写这个 App 自己的变化。
- 客户端的盘点范围是**同前缀的上一个 tag**到本次（`git log --first-parent android-v0.3.1..HEAD --
  apps/android`），文末对比链接也用同前缀的 tag（`android-v0.3.1...android-v0.3.2`）。基线永远是
  **用户手上的上一版**：第一次单独发版时，用最后一次随服务器发出去的那一版（如 Windows 0.1.0 对照随
  v0.37.0 发的 1.0.4）；只有用户手上从没有过任何版本的产品才算首发。写法见 `changelog-guide.md`
  「客户端」与「首发版本」。
- **服务器 changelog 不罗列各 App 的当前版本**（客户端一节自动生成），但功能需要的 App 最低版本、
  必须更新的 App 要写在正文里。

## 五、NER 模型（`torrent-ner-vN`）

1. 训练产出三件套：`model.int8.onnx`、`tokenizer.json`、`labels.json`
2. 生成更新清单（tag 必须与将要创建的 Release 一致，后端强校验）：
   `./scripts/build-model-manifest.sh <模型目录> torrent-ner-vN`
3. 创建 Release（N 递增），**必须 `--latest=false`**：
   `gh release create torrent-ner-vN --latest=false --title "MovieClaw NER Model N" …`，
   上传三件套 + `manifest.json`（启用签名时含 `manifest.json.sig`），正文用 `docs/changelog/torrent-ner-vN.md`
4. 没带 manifest.json 的模型 Release 无法应用内安装，只能作为镜像构建的 `NER_MODEL_BASE` 来源

## 六、TestFlight / App Store

与 GitHub Release 相互独立；同一个构建既进内部 / 对外 TestFlight 也用于提审。完整说明见
`docs/design/ios-release.md`，账号持有人的一次性准备与对外测试步骤见 `docs/design/ios-release-checklist.md`。

1. 打包机准备（每台新 Mac 一次）：本机签名配置 `Signing.local.xcconfig` 写团队 ID；
   App Store Connect API 密钥**必须「管理」角色**（「App 管理」用不了云端发布证书，
   Xcode 27 的命令行又读不到 Xcode 里登录的账号）；密钥 ID / Issuer ID 放仓库外的本机 env 文件，
   `.p8` 放 `~/.appstoreconnect/private_keys/`，全部不入库、不贴进聊天。
   新证书首次打包前让账号持有人自己执行一次钥匙串分区授权
   （`security set-key-partition-list …`，要输 Mac 登录密码），否则会弹出几十个授权框。
2. 从 main 打包上传：`source <本机 env> && apps/apple/scripts/release.sh --upload`
   （不带 `--upload` 只导出，用于先验证签名）。构建号取 UTC 时间自动递增。
   Apple TV 版加 `--tv`、Mac 版加 `--mac`（同一条 App 记录、各自一条构建序列），几端都要发就各跑一次。
   iPad 不用另打包：默认那个 iOS 构建同时是 iPhone 与 iPad 版（`release.sh` 归档后会核对包里声明了 iPad）。
   TestFlight 的审核账号、备注与「Beta 版 App 描述」三端共用，提审前按 `docs/design/ios-release.md` §4 核对；
   各端的「测试内容」只写那一端真有的功能，iOS 构建的测试内容同时写 iPad 上的入口差异（同备注）。
   提审正式版时 iPad 也要截图（13 英寸），Vision Pro 的分发开关见 ios-release.md §4。
3. 上传后 5～30 分钟处理完；可用 ASC API 查 `processingState` / `buildAudienceType`。
   开了自动分发的内部测试组会自动收到；对外测试组按 checklist §5 加构建、提审。
4. 看 Apple 邮件：ITMS-91053 等警告按邮件补隐私清单。

## 七、硬件转码矩阵人工验收（改动播放/转码时必做）

CI 里没有显卡，`-m "not integration"` 的门禁**完全覆盖不到硬件转码**——
装配参数有单测、软件转码有集成测试，但「这块显卡上真能不能转」只有人能验。
凡是改了 `services/playback/`（尤其 `ffmpeg_args.py` / `hwprobe.py`）或换了
ffmpeg 版本，发版前按下表逐项过一遍。

每种硬件重复这几步：

1. 打开「设置 → 播放 → 查看检测详情」，确认该后端显示为可用；若不可用，
   照它给的中文提示改配置后按「重新检测」——这条提示本身也是被验收对象。
2. 播一部 **HEVC + DTS 的 MKV**（走档 2 音频单转）与一部 **4K HDR**
   （走档 3 硬件转码 + 色调映射），各拖几次进度条。
3. 记录「播放诊断」面板里的档位、是否硬件加速、掉帧数。
4. 播放中在宿主机确认 GPU 真的在动（`intel_gpu_top` / `nvidia-smi` /
   `radeontop`），别被「软件转码也能出画」骗过去。

| 硬件 | 自检可用 | 档 2 直通 | 档 3 转码 | HDR 转 SDR | 掉帧 <1% |
|---|---|---|---|---|---|
| Intel 核显（VAAPI/QSV） | ☐ | ☐ | ☐ | ☐ | ☐ |
| NVIDIA（NVENC） | ☐ | ☐ | ☐ | ☐ | ☐ |
| AMD（VAAPI） | ☐ | ☐ | ☐ | ☐ | ☐ |
| 无显卡（软件兜底） | — | ☐ | ☐ | 应明确拒绝 | ☐ |

另外三项与硬件无关但同样只能人验：

- [ ] **播放器真机走查**：内封 ASS 番剧（字体、特效、时间轴微调）、内封 SRT、
      外挂字幕、切下一集、续播点、进度条缩略图预览
- [ ] **iOS**：同局域网 iPhone 打开播放页，确认走原生 HLS 且全屏可用
- [ ] **Safari**：HEVC 直通不黑屏（`hvc1` 标签那条陷阱只有 Safari 能验）

## 八、失败补救

- **服务器**：cli 或镜像作业失败时 Release 停在 draft，修好后到 Actions 重跑 release 工作流。
- **ios-ipa / mac-app 编译失败**：多半是 CI 的 Xcode 比本机旧（见 ios-release.md §5，PR 上的 `ios`
  检查能复现），开 PR 修 CI 兼容后重跑 apple-release。急用时本机 `git checkout <tag>` 后跑
  `apps/apple/scripts/build-unsigned-ipa.sh` 或
  `MOVIECLAW_SIGNING_IDENTITY="Developer ID Application: …" MOVIECLAW_NOTARY_PROFILE=<凭证名> apps/apple/scripts/package-mac-app.sh`，
  再 `gh release upload <tag> <产物> --clobber` 补传，并手动转正（`gh release edit <tag> --draft=false --latest=false`）。
  人工补传 Mac 版或转码器 ZIP 后，在 macOS 上运行 `bash scripts/publish-download-manifest.sh <tag>` 刷新官网清单。
- **mac-app / transcoder 公证失败**，按报错对仓库密钥：
  - `--issuer … must be a valid UUID` → `APPLE_API_ISSUER_ID` 值不对（常见多带空格 / 换行）
  - `HTTP status code: 401` → `APPLE_API_KEY_ID` 与 `APPLE_API_KEY_P8` 不是同一把，或密钥已撤销
  - 「没有 Developer ID Application 证书」→ `.p12` 导出的是别的证书
  `.p8` / `.p12` 属于凭证，由账号持有人自己 `gh secret set`（从本机文件重定向输入，不经聊天）。
  改好后重跑 apple-release；可下载产物本机 `spctl -a -vv` 看到 `Notarized Developer ID` 即成功。
- **Android 构建失败**：见 `docs/design/android-release.md`；不以无签名包或 Exo-only 包绕过。
- **Windows**：Desktop CI 失败就先修 CI（PR 上的 Desktop CI 能复现）；校验失败说明安装包与测试过的不是
  同一份、或版本 / 提交对不上，重跑整个 windows-release，不要手动拼附件。

## 九、清单签名（可选，防 Release/加速镜像被篡改）

- 首次启用：`./scripts/gen-release-signing-key.sh` 生成密钥对；私钥配成
  仓库 Actions 机密 `RELEASE_SIGNING_KEY`（绝不入库），公钥烧进镜像
  （`UPDATE_MANIFEST_PUBKEY` 构建参数）或让用户配同名环境变量
- 启用后：服务器发版自动签名；模型清单脚本在有 `RELEASE_SIGNING_KEY`
  环境变量时也会生成签名
- 注意：部署侧配置了公钥后，**所有**更新清单必须携带有效签名，包括
  模型 Release——启用后发的每个 Release 都不能漏传 `.sig`

## 十、发版检查清单

服务器：

- [ ] 版本号三处一致，已跑 `scripts/export-spec.sh`
- [ ] 需要配合新版 App 的功能：按「先后顺序」一节定好谁先发，changelog 写明了所需 App 版本
- [ ] 触碰运行时依赖 → `docker/runtime-version` +1
- [ ] 改了转码器握手协议 → 转码器与服务器紧挨着发，两边提示框都写明要同时更新
- [ ] 数据库迁移向前兼容（alembic 迁移是单向的，用户回退靠自动备份）
- [ ] release 工作流全绿、Release 已转正且是 latest，正文末尾的客户端一节版本正确
- [ ] changelog 已按 `changelog-guide.md` 自检过第一屏（应用内更新界面原文展示）
- [ ] 改动了播放/转码 → 第七节的硬件矩阵人工验收已过

客户端：

- [ ] `python3 scripts/release-status.py` 看过，版本号已递增
- [ ] App 依赖新服务器接口且不能降级 → 服务器已先发，App 的最低服务器版本已上调到它
- [ ] 对应工作流全绿，Release 已转正、没有标成 latest，附件齐全
- [ ] Mac 版 / 转码器 / Android：官网下载页显示了新版本（缓存最多 1 小时）
- [ ] iOS 构建（iPhone 与 iPad 同一个包）：改了导航或页面布局时，iPhone 和 iPad 各装一次 TestFlight 看过
