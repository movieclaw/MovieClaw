---
name: release
description: 发布 movieclaw 新版本。当用户要求发版、发布新版本、打 tag、发布 NER 模型、发布 Docker 镜像、发布各客户端（iPhone、Apple TV、Mac 版、Mac 转码器、Android、Android TV），或打包上传 iOS App 到 TestFlight / App Store、补传发版附件（IPA、Mac 转码器、Mac 版 App）时使用。涵盖版本号三处同步、应用/模型/镜像/iOS 的完整流程、可选附件失败补救与检查清单。
---

# movieclaw 发布规范

本项目有**以下几种发布类型**，先判定这次要发的是哪种（机制背景见
`docs/design/in-app-update.md`）：

| 类型 | 什么时候发 | 用户侧感知 |
|------|-----------|-----------|
| 应用 Release（`vX.Y.Z` tag） | 前后端代码变了（最常见） | 设置页一键更新，免拉镜像 |
| 模型 Release（`torrent-ner-vN` tag） | NER 模型重新训练 | 设置页一键更新模型 |
| Docker 镜像 | 随应用 Release 自动发（release.yml 调用 docker-image.yml 推 Docker Hub） | 仅 runtime bump 时用户必须重拉 |
| 客户端 Release（`ios-v` / `tvos-v` / `macos-v` / `transcoder-v` / `android-v` / `androidtv-v` / `windows-v` 加 `X.Y.Z`） | 某个客户端有变化，各自独立发布（第九、十节） | 各自渠道更新：TestFlight、下载 zip / APK、Windows 客户端内检查更新 |

## 一、应用 Release（日常发版）

### 1. 版本号三处同步（硬约束，构建脚本强制校验）

以下三处必须完全一致，否则 CI 构建直接失败、Release 不会创建：

- `pyproject.toml` 的 `[project] version`
- `src/movieclaw_api/__init__.py` 的 `__version__`
- git tag（去掉 `v` 前缀后的部分）

发版第一步就是把前两处 bump 到目标版本并提交合入主干。

### 2. 发版步骤

```
1. bump 两处版本号 → 提交 PR 合入 main（changelog 可同 PR 一起写，见下）。
   基线 spec（`spec.json`）是构建产物不入 git，镜像、发版脚本、goreleaser
   都在构建期现场导出，不需要也不能手动提交它
2. 以发版 PR 的 CI 全绿为准（平时 CI 按改动路径只跑相关作业，发版 PR 改了
   `__init__.py` 的版本号会触发全量：ruff / pytest / cli / web / Worker 加 iOS 编译），
   无需在本地重跑全量测试——本地跑 pytest 还需先下载 NER 模型，且沙箱
   代理环境会造成与代码无关的误报
3. git tag vX.Y.Z && git push origin vX.Y.Z
   （推不了 tag 的环境——如远程会话，git 凭证只能推分支、也没有
   workflow_dispatch 的 API 权限，两条正门都够不着。走点火通道：
   `git push origin main:refs/heads/release-kick/vX.Y.Z`，
   release-kick.yml 会校验 tag 与 main 的 pyproject 版本一致后，
   以 GITHUB_TOKEN 代为触发 release.yml（在 main HEAD 上创建 tag），
   并自动删除点火分支。人工兜底：到 Actions → release 手动
   Run workflow 输入 tag）
4. release.yml 两段式发布（draft → publish）：先以 draft 创建 Release，
   各作业往上传产物——应用三件套（app-web.tar.gz / app-backend.tar.gz /
   manifest.json，可选 manifest.json.sig）与 mclaw 六平台归档 + checksums
   （客户端一个都不在这里，见第九节）——同时发布多架构 Docker 镜像到 Docker Hub
   （movieclaw/movieclaw，正式版打 vX.Y.Z + runtime-N + latest，
   预发布版只打 vX.Y.Z-… 不动 latest）。最后 publish 作业校验产物齐全、
   镜像发布成功后把 draft 转正；此前 Release 对应用内更新和
   install-cli.sh 都不可见。**任何作业失败时 Release 停在 draft，
   修复后到 Actions 重跑整个 release 工作流即可**（上传均带 --clobber，
   安全重入）
5. changelog：写 docs/changelog/vX.Y.Z.md 合入 main。changelog 先于发版
   合入（推荐，可与发版 PR 同 PR）时，release.yml 建 Release 会直接用它
   当 body；后合入也没关系，release-notes.yml 会自动同步为 Release body
   （应用内更新界面原文展示）。撰写规范见 `changelog-guide.md`。
   正文末尾的「Apps / 客户端」一节由 `scripts/publish-release-body.sh` 自动生成：
   上一个服务器版本以来新发的客户端（带链接），以及发布时每个客户端的最新版本与安装方式。
   changelog 里不要再手写客户端版本号；「需不需要更新某个 App」仍由 changelog 写明
   （必须更新的放开头提示框，某功能需要新版 App 的写在该功能里）
6. 验证：到 GitHub Release 页确认三个产物齐全、body 是 changelog 而非
   自动生成的 PR 清单；有条件的话在一个 Docker 部署实例上走一遍
   「设置 → 应用」端到端更新
```

### 3. changelog 怎么写

**动笔前必读 `changelog-guide.md`**（本目录下）。一句话概括：changelog 是写给自部署
用户的产品更新说明，不是变更清单——先用 `git log` 盘点保证不漏，再挑 1～3 个亮点
按「痛点 → 现在 → 入口」写，修复只写用户能认出的症状，其余交给文末的 compare 链接。
样板见 `docs/changelog/v0.27.0.md`。

### 4. 预发布（beta/rc）

tag 带预发布段（如 `v0.3.0-beta.1`）时，release.yml 会自动标记 GitHub
prerelease，应用内更新的检查逻辑会跳过它——beta 不会被推给全量用户。
预发布数字段按数值比较（`beta.10` > `beta.9`），命名放心递增。

## 二、何时必须发 Docker 镜像（runtime 契约）

`docker/runtime-version` 是运行时依赖集合的版本代号（唯一事实源）。
**凡是改了以下任何一项，必须把它 +1**：

- `pyproject.toml` 的 dependencies
- Node 大版本、Dockerfile 里的系统包（ffmpeg 等）或基础镜像
- `docker/entrypoint.sh` 的行为契约（重启约定码、目录约定等）

CI 守卫（runtime-guard.yml）会拦截漏 bump 的 PR。bump 后发的应用
Release 其 manifest 会声明新的 `requires_runtime`，旧镜像用户在设置页
会看到「需升级 Docker 镜像」的明确提示，而不是坏掉的更新。

镜像发布本身无需额外操作——每次应用 Release 都会自动发布新镜像
（含 runtime-N 标签）。需要在发版之外单独补发镜像时，到 Actions →
docker-image 手动 Run workflow 输入标签即可。本地/离线构建仍可用
`TMDB_API_KEY=xxx ./scripts/build-image.sh`（详见脚本头注释；启用了
清单签名的话记得带 `--build-arg UPDATE_MANIFEST_PUBKEY=<公钥>`）。

## 三、模型 Release

1. 训练产出三件套：`model.int8.onnx`、`tokenizer.json`、`labels.json`
2. 生成更新清单（tag 必须与将要创建的 Release tag 一致，后端会强校验）：
   `./scripts/build-model-manifest.sh <模型目录> torrent-ner-vN`
3. 创建 tag 为 `torrent-ner-vN` 的 GitHub Release（N 递增），**必须带
   `--latest=false`**（如 `gh release create torrent-ner-vN --latest=false …`），
   上传三件套 + `manifest.json`（+ 签名时的 `manifest.json.sig`）
4. 为什么 `--latest=false` 是硬约束：install-cli.sh / install-cli.ps1 从
   `releases/latest/download` 取 mclaw，模型 Release 一旦成为 latest，
   CLI 安装立刻 404。除此之外无需担心其他干扰——应用更新检查按 tag
   正则过滤，模型 Release 不会干扰应用更新
5. 没带 manifest.json 的模型 Release 无法被应用内安装（会提示用户），
   只能作为镜像构建的 `NER_MODEL_BASE` 来源

## 四、清单签名（可选，防 Release/加速镜像被篡改）

- 首次启用：`./scripts/gen-release-signing-key.sh` 生成密钥对；私钥配成
  仓库 Actions 机密 `RELEASE_SIGNING_KEY`（绝不入库），公钥烧进镜像
  （`UPDATE_MANIFEST_PUBKEY` 构建参数）或让用户配同名环境变量
- 启用后：应用发版自动签名；模型清单脚本在有 `RELEASE_SIGNING_KEY`
  环境变量时也会生成签名
- 注意：部署侧配置了公钥后，**所有**更新清单必须携带有效签名，包括
  模型 Release——启用后发的每个 Release 都不能漏传 `.sig`

## 五、硬件转码矩阵人工验收（改动播放/转码时必做）

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

## 六、iOS App 发布（TestFlight / App Store）

与服务器发版**相互独立**：App 版本号只看 `apps/apple/project.yml` 的 `MARKETING_VERSION`，
不跟服务器 tag 走；只有一个发行版本，同一个构建既进内部 / 对外 TestFlight 也用于提审。
完整说明见 `docs/design/ios-release.md`，账号持有人的一次性准备与对外测试步骤见
`docs/design/ios-release-checklist.md`。

1. 打包机准备（每台新 Mac 一次）：本机签名配置 `Signing.local.xcconfig` 写团队 ID；
   App Store Connect API 密钥**必须「管理」角色**（「App 管理」用不了云端发布证书，
   Xcode 27 的命令行又读不到 Xcode 里登录的账号）；密钥 ID / Issuer ID 放仓库外的本机 env 文件，
   `.p8` 放 `~/.appstoreconnect/private_keys/`，全部不入库、不贴进聊天。
   新证书首次打包前让账号持有人自己执行一次钥匙串分区授权
   （`security set-key-partition-list …`，要输 Mac 登录密码），否则会弹出几十个授权框。
2. 从 main 打包上传：`source <本机 env> && apps/apple/scripts/release.sh --upload`
   （不带 `--upload` 只导出，用于先验证签名）。构建号取 UTC 时间自动递增。
   Apple TV 版加 `--tv`、Mac 版加 `--mac`（同一条 App 记录、各自一条构建序列），几端都要发就各跑一次。
   TestFlight 的审核账号、备注与「Beta 版 App 描述」三端共用，提审前按 `docs/design/ios-release.md` §4 核对；
   各端的「测试内容」只写那一端真有的功能。
3. 上传后 5～30 分钟处理完；可用 ASC API 查 `processingState` / `buildAudienceType`。
   开了自动分发的内部测试组会自动收到；对外测试组按 checklist §5 加构建、提审。
4. 看 Apple 邮件：ITMS-91053 等警告按邮件补隐私清单。

## 七、客户端发版失败的补救

客户端发版失败时 Release 停在 draft，修好后重跑对应工作流即可（上传均带 --clobber）。官网版本通过
各 Release 附件 `downloads.json` 自动同步，规则见 `docs/design/download-manifest.md`；人工补传 Mac 版或
转码器 ZIP 后，在 macOS 上运行 `bash scripts/publish-download-manifest.sh <tag>` 刷新清单。

- **ios-ipa / mac-app 编译失败**：多半是 CI 的 Xcode 比本机旧（见 ios-release.md §5，PR 上的 `ios`
  检查能复现），开 PR 修 CI 兼容后重跑 apple-release。急用时本机 `git checkout <tag>` 后跑
  `apps/apple/scripts/build-unsigned-ipa.sh` 或
  `MOVIECLAW_SIGNING_IDENTITY="Developer ID Application: …" MOVIECLAW_NOTARY_PROFILE=<凭证名> apps/apple/scripts/package-mac-app.sh`，
  再 `gh release upload <tag> <产物> --clobber` 补传，并手动转正（`gh release edit <tag> --draft=false --latest=false`）。
- **mac-app / transcoder 公证失败**，按报错对仓库密钥：
  - `--issuer … must be a valid UUID` → `APPLE_API_ISSUER_ID` 值不对（常见多带空格 / 换行）
  - `HTTP status code: 401` → `APPLE_API_KEY_ID` 与 `APPLE_API_KEY_P8` 不是同一把，或密钥已撤销
  - 「没有 Developer ID Application 证书」→ `.p12` 导出的是别的证书
  `.p8` / `.p12` 属于凭证，由账号持有人自己 `gh secret set`（从本机文件重定向输入，不经聊天）。
  改好后重跑 apple-release；可下载产物本机 `spctl -a -vv` 看到 `Notarized Developer ID` 即成功。
- **Android 构建失败**：见第九节与 `docs/design/android-release.md`；不以无签名包或 Exo-only 包绕过。

## 八、发版检查清单

- [ ] 版本号三处一致（应用发版）
- [ ] 本版新功能需要新版客户端时，对应的客户端 Release 已先发布（第九节），changelog 里写明了所需版本
- [ ] bump 版本号后已跑 `scripts/export-spec.sh`（服务端与 Go CLI 两份 spec）
- [ ] 本次改动是否触碰运行时依赖？触碰了 → `docker/runtime-version` +1（镜像随发版自动发布）
- [ ] 改了 Worker 握手协议（`REMOTE_WORKER_PROTOCOL_VERSION` 与 macOS Worker
      的 `BuildInfo.protocolVersion` 同步 +1）→ 旧 Worker 会被服务端拒绝握手，
      changelog 显著位置写明「需要更新 Mac 转码器」，并先发新版转码器（transcoder-v）；协议版本没变、
      但新能力只派给新版转码器（按自报能力派发）时，同样要在提示框里写明需要的转码器版本
- [ ] 数据库迁移向前兼容（alembic 迁移是单向的，用户回退靠自动备份）
- [ ] Release 产物齐全：publish 作业已自动校验（应用三件套 + mclaw 六平台
      归档 `mclaw_cli_{linux,darwin}_{amd64,arm64}.tar.gz`、
      `mclaw_cli_windows_{amd64,arm64}.zip`、`checksums.txt`，启用签名时含
      `.sig`），人工只需确认 release 工作流全绿、Release 已从 draft 转正，
      正文末尾的「客户端」一节列出了各客户端的最新版本
- [ ] changelog 已写入 `docs/changelog/vX.Y.Z.md` 并合入 main（release-notes.yml
      自动同步为 Release body，应用内更新界面会原文展示给用户），并按
      `changelog-guide.md` 自检过第一屏
- [ ] 改动了播放/转码 → 第五节的硬件矩阵人工验收已过（CI 覆盖不到）

## 九、客户端独立发版

所有客户端都不随服务器 Release 分发，各自单独发 Release，**始终 `--latest=false`**（latest 只能是
服务器版本：install-cli.sh 从 `releases/latest/download` 取 mclaw）。tag 版本必须等于 App 自己的版本，
同一版本发过就不能再发，发新版先递增版本号。

| 客户端 | tag | 版本来源 | 工作流 | 附件 | Release 标题 |
|---|---|---|---|---|---|
| iPhone / iPad | `ios-vX.Y.Z` | `apps/apple/project.yml` 的 `MARKETING_VERSION` | `apple-release.yml` | 未签名 IPA（侧载） | MovieClaw for iPhone and iPad X.Y.Z |
| Apple TV | `tvos-vX.Y.Z` | 同上 | `apple-release.yml` | 无（只走 TestFlight，Release 只放说明） | MovieClaw for Apple TV X.Y.Z |
| Mac 版 App | `macos-vX.Y.Z` | 同上 | `apple-release.yml` | 签名公证 zip + `downloads.json` | MovieClaw for Mac X.Y.Z |
| Mac 转码器 | `transcoder-vX.Y.Z` | `macos/MovieClawTranscoder/Resources/Info.plist` 的 `CFBundleShortVersionString` | `apple-release.yml` | 签名公证 zip + `downloads.json` | MovieClaw Transcoder X.Y.Z |
| Android 手机/平板 | `android-vX.Y.Z` | `apps/android/version.properties` | `android-release.yml` | APK + JSON + `downloads.json` | MovieClaw for Android X.Y.Z |
| Android TV | `androidtv-vX.Y.Z` | `apps/android-tv/version.properties` | `android-release.yml` | APK + JSON + `downloads.json` | MovieClaw for Android TV X.Y.Z |
| Windows | `windows-vX.Y.Z` | `apps/desktop/src-tauri/Cargo.toml`（与 `package.json` 同步） | Desktop CI 产物，手动发（第十节） | 安装包 | MovieClaw for Windows X.Y.Z |

发版步骤：

1. 递增版本号（Android 的 `versionName` 与 `versionCode` 一起递增），写
   `docs/changelog/<tag>.md`（与服务器相同的中英双语结构，标题行写 `## <产品名> X.Y.Z: 主题`，
   只写这个 App 自己的变化），合入 main。
2. 推 tag：`git tag <tag> && git push origin <tag>`。推不了 tag 的环境走点火通道
   `git push origin main:refs/heads/release-kick/<tag>`，或到 Actions 手动输入 tag。
3. 工作流核对版本 → 建 draft → 构建 / 签名 / 公证 → 上传附件与 `downloads.json` → 转正（不标 latest）。
4. 服务器新功能依赖新版 App 时，先发 App 再发服务器：服务器正文的「客户端」一节取发布时各 App 的
   最新 Release。App 依赖新服务器接口时，上调 App 里的最低服务器版本（iPhone `AppModel.minimumServerVersion`、
   Android 手机 `SessionRepository` 的 `MIN_SERVER_VERSION`、Android TV `AppModel.MIN_SERVER_VERSION`）。

Apple 三端共用 `MARKETING_VERSION`：每个平台对同一个版本只能发一次。某个平台要发而这个版本它已经发过，
就先递增补丁号；其他平台下次随之用新版本号，跳号无妨。TestFlight / App Store 的上传见第六节，与 GitHub
Release 互不依赖。

Android 正式构建要求完整原生播放器依赖和固定签名证书，禁止用 debug 证书替代；两个 App 共用一组 Secrets：
`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。
已有官方签名密钥必须沿用，不能因构建失败而重新生成；密钥不入 git、不贴聊天。版本与流水线全景见
`docs/design/android-release.md`。

最新版固定地址：Android `https://movieclaw.io/download/android.apk`、Android TV
`https://movieclaw.io/download/androidtv.apk`；Mac 版与转码器到官网下载页。不要用
`releases/latest/download/...`：latest 是服务器 Release，里面已没有客户端。

## 十、Windows 客户端（独立 Release）

Windows 客户端（`apps/desktop`）单独发 `windows-vX.Y.Z` Release。版本在
`apps/desktop/src-tauri/Cargo.toml`，与 `apps/desktop/package.json` 一起改；2026-10 从 0.1.0 重新起步
（此前的 1.0.x 已作废）。安装包由 Desktop CI 构建并上传为工作流产物 `desktop-packages-<sha>`，发版时把
其中全部文件挂到新 Release 上。

- **标题写「MovieClaw for Windows X.Y.Z」**，安装包名 `MovieClaw-Windows-{版本}-Setup-x64.exe` /
  `-portable-x64.zip`，程序名 `MovieClaw`。
- **必须带 `--latest=false`**：latest 必须始终是服务器的 `vX.Y.Z`。
- 未做实体机验收、只凭 CI 发布时，正文须含 `<!-- desktop-release-policy: ci-verified -->`
  并写明验证范围（`check-release-evidence.py` 校验）。

客户端内的更新器只认 `windows-v` tag 与上面的安装包名（`updater.rs`、`updater/verified.rs`）；改其中任何一项，
须先发一版让更新器同时认新旧两种名字，大部分用户升上去之后再切换。
