---
name: release
description: 发布 movieclaw 新版本。当用户要求发版、发布新版本、打 tag、发布 NER 模型、发布 Docker 镜像，或打包上传 iOS App 到 TestFlight / App Store、补传发版附件（IPA、Mac 转码器、Mac 版 App）时使用。涵盖版本号三处同步、应用/模型/镜像/iOS 的完整流程、可选附件失败补救与检查清单。
---

# movieclaw 发布规范

本项目有**三种发布类型**，先判定这次要发的是哪种（机制背景见
`docs/design/in-app-update.md`）：

| 类型 | 什么时候发 | 用户侧感知 |
|------|-----------|-----------|
| 应用 Release（`vX.Y.Z` tag） | 前后端代码变了（最常见） | 设置页一键更新，免拉镜像 |
| 模型 Release（`torrent-ner-vN` tag） | NER 模型重新训练 | 设置页一键更新模型 |
| Docker 镜像 | 随应用 Release 自动发（release.yml 调用 docker-image.yml 推 Docker Hub） | 仅 runtime bump 时用户必须重拉 |

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
   manifest.json，可选 manifest.json.sig）、mclaw 六平台归档 + checksums、
   macOS Worker zip、iOS 未签名 IPA 与 Mac 版 App zip（均为可选附件）——同时发布多架构 Docker 镜像到 Docker Hub
   （movieclaw/movieclaw，正式版打 vX.Y.Z + runtime-N + latest，
   预发布版只打 vX.Y.Z-… 不动 latest）。最后 publish 作业校验产物齐全、
   镜像发布成功后把 draft 转正；此前 Release 对应用内更新和
   install-cli.sh 都不可见。**任何作业失败时 Release 停在 draft，
   修复后到 Actions 重跑整个 release 工作流即可**（上传均带 --clobber，
   安全重入）；仅 Worker / IPA / Mac 版挂了不拦转正，重跑 worker-macos / ios-ipa / mac-app 作业补传即可。
   Worker、IPA 与 Mac 版按改动判断：自上一版以来对应代码没变时不重编，`carry-assets` 作业直接
   沿用上一个 Release 的同名附件（规则见 `scripts/release-asset-plan.sh`）。证书、公证配置
   或打包流程变了而代码没变时，到 Actions → release 手动 Run workflow 勾选 `force_rebuild`
5. changelog：写 docs/changelog/vX.Y.Z.md 合入 main。changelog 先于发版
   合入（推荐，可与发版 PR 同 PR）时，release.yml 建 Release 会直接用它
   当 body；后合入也没关系，release-notes.yml 会自动同步为 Release body
   （应用内更新界面原文展示）。撰写规范见 `changelog-guide.md`。
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
   Apple TV 版加 `--tv`（同一条 App 记录、各自一条构建序列），两端都要发就各跑一次。
3. 上传后 5～30 分钟处理完；可用 ASC API 查 `processingState` / `buildAudienceType`。
   开了自动分发的内部测试组会自动收到；对外测试组按 checklist §5 加构建、提审。
4. 看 Apple 邮件：ITMS-91053 等警告按邮件补隐私清单。

## 七、可选附件失败的补救（worker-macos / ios-ipa / mac-app / carry-assets）

publish 作业不等它们，Release 会照常转正——但 changelog 若写了这些附件就必须补上。
GitHub 只允许整次运行结束后再单独重跑某个作业（`gh run rerun --job <id>`）。

- **ios-ipa 编译失败**：多半是 CI 的 Xcode 比本机旧（见 ios-release.md §5）。先在本机
  `git checkout vX.Y.Z` 后跑 `apps/apple/scripts/build-unsigned-ipa.sh`，再
  `gh release upload vX.Y.Z apps/apple/build-ipa/MovieClaw-iOS-unsigned.ipa --clobber` 补传，
  然后开 PR 修 CI 兼容（PR 上的 `ios` 检查能复现）。
- **mac-app 编译失败**：同上，多半是 CI 的 Xcode 比本机旧（PR 上 `ios` 工作流的 mac 作业能复现）。本机
  `git checkout vX.Y.Z` 后跑 `MOVIECLAW_SIGNING_IDENTITY="Developer ID Application: …" MOVIECLAW_NOTARY_PROFILE=<凭证名>
  apps/apple/scripts/package-mac-app.sh`（签名、公证、打包一条龙），再
  `gh release upload vX.Y.Z apps/apple/build-macapp/MovieClaw-macos-arm64.zip --clobber` 补传。
  公证失败时脚本会打出 Apple 的逐条拒绝原因；密钥类报错同下面 worker-macos。
- **worker-macos 公证失败**，按报错对仓库密钥：
  - `--issuer … must be a valid UUID` → `APPLE_API_ISSUER_ID` 值不对（常见多带空格 / 换行）
  - `HTTP status code: 401` → `APPLE_API_KEY_ID` 与 `APPLE_API_KEY_P8` 不是同一把，或密钥已撤销
  - 「没有 Developer ID Application 证书」→ `.p12` 导出的是别的证书
  `.p8` / `.p12` 属于凭证，由账号持有人自己 `gh secret set`（从本机文件重定向输入，不经聊天）。
  改好后单独重跑 worker-macos（mac-app 用同一套密钥，一并重跑）；可下载产物本机 `spctl -a -vv`
  看到 `Notarized Developer ID` 即成功。

## 八、发版检查清单

- [ ] 版本号三处一致（应用发版）
- [ ] bump 版本号后已跑 `scripts/export-spec.sh`（服务端与 Go CLI 两份 spec）
- [ ] 本次改动是否触碰运行时依赖？触碰了 → `docker/runtime-version` +1（镜像随发版自动发布）
- [ ] 改了 Worker 握手协议（`REMOTE_WORKER_PROTOCOL_VERSION` 与 macOS Worker
      的 `BuildInfo.protocolVersion` 同步 +1）→ 旧 Worker 会被服务端拒绝握手，
      changelog 显著位置写明「需要更新 Mac Worker」；协议版本没变、但新能力只派给新版 Worker
      （按 Worker 自报能力派发）时，同样要在提示框里写明「请下载新版转码器」
- [ ] 数据库迁移向前兼容（alembic 迁移是单向的，用户回退靠自动备份）
- [ ] Release 产物齐全：publish 作业已自动校验（应用三件套 + mclaw 六平台
      归档 `mclaw_{linux,darwin}_{amd64,arm64}.tar.gz`、
      `mclaw_windows_{amd64,arm64}.zip`、`checksums.txt`，启用签名时含
      `.sig`），人工只需确认 release 工作流全绿、Release 已从 draft 转正；
      worker-macos 作业红了 → Worker zip 缺失，重跑该作业补传；
      ios-ipa 作业红了 → `MovieClaw-iOS-unsigned.ipa` 缺失，重跑该作业补传；
      mac-app 作业红了 → `MovieClaw-macos-arm64.zip` 缺失，重跑该作业补传；
      carry-assets 作业红了 → 沿用的附件缺失，重跑该作业补传
- [ ] changelog 已写入 `docs/changelog/vX.Y.Z.md` 并合入 main（release-notes.yml
      自动同步为 Release body，应用内更新界面会原文展示给用户），并按
      `changelog-guide.md` 自检过第一屏
- [ ] 改动了播放/转码 → 第五节的硬件矩阵人工验收已过（CI 覆盖不到）
