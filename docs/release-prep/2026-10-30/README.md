# 2026-10-30 发版准备

检测命令：`python3 scripts/release-status.py --ref origin/main`，再用 `scripts/release-surface-diff.py` 对上一版 tag 看界面文字。本文件写于准备 PR 时的 `origin/main` = `e82d615a`。流程以 `.claude/skills/release/SKILL.md` 为准，这里只记这一轮的取舍。

## 要发

| 产品 | 上一版 | 这一版 | tag（合并后打，本 PR 不打） | 理由 |
|---|---|---|---|---|
| 服务器 / Web / CLI | 0.44.0，runtime 25 | 0.45.0，runtime 仍是 25 | `v0.45.0` | 模型菜单改为向服务商要列表，并合并公共目录参数，是新功能，走 minor。另有活动侧栏、网盘腾空、智能订阅停住、季间空档刷新。两处数据库迁移：模型目录加可空列；删掉藏起来的 `subscription.smart`。没有新的运行时依赖。 |
| iPhone / iPad | 0.12.0 | 0.12.1 | `ios-v0.12.1` | 发现页标题菜单收起后不再滑动（#1090）；系统 VPN 不再先连没验过的内网地址（#1089）。旧服务器上照常用。 |
| Android | 0.9.0 (30000012) | 0.9.1 (30000013) | `android-v0.9.1` | 同上的 VPN 选址（#1089）；播出日历等底部面板下拉不再误关（#1103）。界面仍是中文。 |
| Mac | `macos-v0.11.0` | 0.12.1 | `macos-v0.12.1` | 共用选址修了 VPN（#1089）。自 0.11.0 起播放引擎还带上 24p 帧格、原盘预取内存，以及 libzvbi 的已公开漏洞修复。昨天没发 0.12.0，这一版把这些一起带上。 |
| Apple TV | `tvos-v0.11.0` | 0.12.1 | `tvos-v0.12.1` | 与 Mac 同一份共用代码。GitHub Release 只有说明，安装仍是 TestFlight。 |

Apple 三端共用 `MARKETING_VERSION`，所以工程里的版本号是 0.12.1。`ios-v0.12.0` 已经发过，不能再打。Mac 与 Apple TV 的 0.12.0 没打过 tag，这一轮直接跳到 0.12.1。

客户端都能在旧服务器上继续用，所以 **先打 App 的 tag，等 Release 转正且都不是 latest，再打服务器 tag**。服务器正文末尾的客户端一节是发布当时各 App 的最新 Release。

## 不发

| 产品 | 上次 tag | 代码里现在的版本 | 原因 |
|---|---|---|---|
| Android TV | `androidtv-v0.7.0` | 仍是 0.7.0 (9) | `apps/android-tv` 无改动。`android-core` 里的本机播放只由手机传入，TV 不接。生成模型多了字段，电视界面没有新入口。 |
| Windows | `windows-v0.1.2` | 仍是 0.1.2 | 只有 `Cargo.lock` 里 rustls 0.23.45 → 0.23.46。没有界面变化。 |
| Mac 转码器 | `transcoder-v0.33.1` | 0.33.1 | 0 个文件。握手协议仍是 1。 |
| Windows 转码器 | 无正式 tag | 0.1.0 | 仍无公开渠道。 |
| 鸿蒙 | 无 | 1.0.0 / versionCode 1000000 | 手机端改动很多，`harmony-v1.0.0` 的说明也在。`harmony-release.yml` 要仓库变量 `HARMONY_TOOLS_URL` 与 `HARMONY_TOOLS_SHA256`，当前没有。正式签名还要一套密钥。按 tag 打出去会在校验配置时失败，这一轮不首发。 |
| NER、浏览器扩展 | 不变 | 不变 | 这个区间没有产物改动。 |

## CI

发版 PR 会因为改了 `__init__.py` 跑全量检查。`services/playback/`、`ffmpeg_args.py`、`hwprobe.py` 和 ffmpeg 都没动，硬件转码矩阵不作为这一版的门槛。

## 合并之后

见 `commands.md`。不要在这个 PR 合并前打 tag。

## 仍需人工

- iPhone / iPad、Mac、Apple TV：打包机上分别跑 `apps/apple/scripts/release.sh --upload`、`--mac`、`--tv` 传 TestFlight。本轮不提 App Store 审核，也不在这台机器上上传。
- Android 安装包由 `android-release.yml` 签名上传。密钥沿用仓库里已有的，不要新生成。
- Mac 官网直装包由 `apple-release.yml` 公证。直装版会自己检查更新。
