# 2026-11-03 发版准备

检测命令：`python3 scripts/release-status.py --ref origin/main`，再用 `scripts/release-surface-diff.py` 对上一版 tag 看界面文字。盘点时 `origin/main` 为 `263d63ce9`。流程以 `.claude/skills/release/SKILL.md` 为准，这里只记这一轮的取舍。

## 要发

| 产品 | 上一版 | 这一版 | tag（合并后打，本 PR 不打） | 理由 |
|---|---|---|---|---|
| 服务器 / Web / CLI | 0.47.0，runtime 25 | 0.47.1，runtime 仍是 25 | `v0.47.1` | 三处修复：网页转码变慢被当成网速不够；忽略目录里的订阅下载现在会说明无法入库；Netflix 主题的入库预告有横图时铺满，横图失效时回落到海报。没有新功能，走 patch。没有数据库迁移，也没有新的运行时依赖。 |
| iPhone / iPad | 0.12.3 | 0.12.4 | `ios-v0.12.4` | 长按很长的助手回复时，预览保持气泡宽度，高度不超过消息区域的一半。旧服务器上照常用。 |

Apple 三端共用 `MARKETING_VERSION`，所以工程里的版本号是 0.12.4。只打 `ios-v0.12.4`。Mac 与 Apple TV 这一轮不打 tag。

iPhone 不依赖新服务器接口，所以 **先打 App 的 tag，等 Release 转正且不是 latest，再打服务器 tag**。服务器正文末尾的客户端一节是发布当时各 App 的最新 Release。

## 不发

| 产品 | 上次 tag | 代码里现在的版本 | 原因 |
|---|---|---|---|
| Mac | `macos-v0.12.3` | 随工程变为 0.12.4，但不打 tag | 自上次 Mac tag 只有 `apps/apple/scripts/agent-companion-lab.py` 的换行，为了过 ruff。Mac 界面没有改。 |
| Apple TV | `tvos-v0.12.3` | 同上 | 同上。`MovieClawTV` 没有新界面。 |
| Windows | `windows-v0.1.2` | 仍是 0.1.2 | 只有 `Cargo.lock`：rustls 0.23.45 → 0.23.46，以及一处 syn 锁从 3.0.6 改到 2.0.119。没有界面变化。 |
| Android | `android-v0.9.3` | 0.9.3 (30000015) | 0 个文件。 |
| Android TV | `androidtv-v0.7.2` | 0.7.2 (11) | 0 个文件。 |
| Mac 转码器 | `transcoder-v0.33.1` | 0.33.1 | 0 个文件。握手协议仍是 1。 |
| 鸿蒙 | 无 | 1.0.0 / versionCode 1000000 | `5a5de2825` 修了分集列表和角标，但是第一次单独发版。工具链变量和正式签名密钥还没配，不能发未签名 HAP。这一轮不首发。 |
| NER、浏览器扩展 | 不变 | 不变 | 这个区间没有单独产物改动。 |

## CI

发版 PR 会因为改了 `__init__.py` 跑全量检查。`services/playback/`、`ffmpeg_args.py`、`hwprobe.py` 和 ffmpeg 都没动。网页播放器只改了「转码产出速度不算线路带宽」的读数。硬件转码矩阵不作为这一版的门槛。

## 合并之后

见 `commands.md`。不要在这个 PR 合并前打 tag。

## 仍需人工

- 不在这台机器上编译或上传任何 Apple 构建，也不提 App Store 审核。iPhone 的 GitHub Release 只有未签名 IPA。TestFlight 要打包机另行上传，本轮不做。
- 新的入库阻塞提示正文仍写「设置 → 监听导入」。页面现在叫「自动入库」。说明里按已知问题写了，这一轮不改那句文案。
