# 2026-10-31 发版准备

检测命令：`python3 scripts/release-status.py --ref origin/main`，再用 `scripts/release-surface-diff.py` 对上一版 tag 看界面文字。盘点时 `origin/main` 为 `d80caa992`。CI 期间 main 又进了 `fc15b7b01`（电视安装器没有会话确认页时，改用标准安装界面）。发版说明已写上这一条，合并提交会带上它。流程以 `.claude/skills/release/SKILL.md` 为准，这里只记这一轮的取舍。

## 要发

| 产品 | 上一版 | 这一版 | tag（合并后打，本 PR 不打） | 理由 |
|---|---|---|---|---|
| 服务器 / Web / CLI | 0.45.0，runtime 25 | 0.46.0，runtime 仍是 25 | `v0.46.0` | 播出日历从进度条改成两行摘要，是用户看得到的改版，走 minor。另有外部库源钩子和两处数据库迁移。没有新的运行时依赖。 |
| iPhone / iPad | 0.12.1 | 0.12.2 | `ios-v0.12.2` | 同一套播出日历。旧服务器上照常用已有的播出日期。 |
| Android | 0.9.1 (30000013) | 0.9.2 (30000014) | `android-v0.9.2` | 同上的日历；另有首帧前断流重试、断流前重新选地址、详情面板空白处不再拖走面板。安装器没有会话确认页时走和电视相同的退路。界面仍是中文。 |
| Android TV | 0.7.0 (9) | 0.7.1 (10) | `androidtv-v0.7.1` | 共用播放器在首帧前断流会再试。电视不重新选地址。安装器没有会话确认页时改走标准安装界面。 |

Apple 三端共用 `MARKETING_VERSION`，所以工程里的版本号是 0.12.2。只打 `ios-v0.12.2`。Mac 与 Apple TV 这一轮不打 tag。

客户端都能在旧服务器上继续用，所以 **先打 App 的 tag，等 Release 转正且都不是 latest，再打服务器 tag**。服务器正文末尾的客户端一节是发布当时各 App 的最新 Release。

## 不发

| 产品 | 上次 tag | 代码里现在的版本 | 原因 |
|---|---|---|---|
| Mac | `macos-v0.12.1` | 随工程变为 0.12.2，但不打 tag | 只有共用字符串表里播出日历的词条。Mac 界面没有播出日历。 |
| Apple TV | `tvos-v0.12.1` | 同上 | 同上。`MovieClawTV` 没有新界面。 |
| Windows | `windows-v0.1.2` | 仍是 0.1.2 | 只有 `Cargo.lock` 里 rustls 的锁文件。没有界面变化。 |
| Mac 转码器 | `transcoder-v0.33.1` | 0.33.1 | 0 个文件。握手协议仍是 1。 |
| 鸿蒙 | 无 | 1.0.0 / versionCode 1000000 | 没有可用的发布工作流配置。这一轮不首发。 |
| NER、浏览器扩展 | 不变 | 不变 | 这个区间没有产物改动。 |

## CI

发版 PR 会因为改了 `__init__.py` 跑全量检查。`services/playback/`、`ffmpeg_args.py`、`hwprobe.py` 和 ffmpeg 都没动，硬件转码矩阵不作为这一版的门槛。

## 合并之后

见 `commands.md`。不要在这个 PR 合并前打 tag。

## 仍需人工

- 不在这台机器上编译或上传任何 Apple 构建，也不提 App Store 审核。iPhone 的 GitHub Release 只有未签名 IPA。TestFlight 要打包机另行上传，本轮不做。
- Android 与 Android TV 安装包由 `android-release.yml` 签名上传。密钥沿用仓库里已有的，不要新生成。
