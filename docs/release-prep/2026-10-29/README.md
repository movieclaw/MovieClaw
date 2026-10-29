# 2026-10-29 发版准备

检测命令：`python3 scripts/release-status.py --ref origin/main`（本文件写于 `origin/main` = `260f5bca`，发版 PR 合入后再跑一次）。流程以 `.claude/skills/release/SKILL.md` 为准，这里只记这一轮的取舍。

## 要发

| 产品 | 上一版 | 这一版 | tag（合并后由维护者打，本 PR 不打） | 理由 |
|---|---|---|---|---|
| 服务器 / Web / CLI | 0.43.0，runtime 24 | 0.44.0，runtime 25（#1079 已把 `docker/runtime-version` 改成 25，本 PR 不再 +1） | `v0.44.0` | 本地语音识别、网页片段、播出日历、从第 N 集起订阅、规则组站点，都是新功能，走 minor。有数据库迁移。 |
| iPhone / iPad | 0.11.0 | 0.12.0 | `ios-v0.12.0` | 下拉片段、播出日历、下载队列、iPhone Duo。能在旧服务器上降级（日历与「从第 N 集起」说明隐藏）。 |
| Android | 0.8.0 (30000011) | 0.9.0 (30000012) | `android-v0.9.0` | 同上，另有离线首页不再自动切入。界面仍是中文。 |

Apple 三端共用 `MARKETING_VERSION`，所以工程里的版本号是 0.12.0。只打 `ios-v0.12.0`。Mac 与 Apple TV 这一轮不打 tag，下次发它们时跳号即可。

客户端都能在旧服务器上继续用，所以 **先打 App 的 tag，等 Release 转正，再打服务器 tag**。服务器正文末尾的客户端一节是发布当时各 App 的最新 Release。

## 不发

| 产品 | 上次 tag | 代码里现在的版本 | 原因 |
|---|---|---|---|
| Mac | `macos-v0.11.0` | 随工程变为 0.12.0，但不打 tag | 唯一的 Mac 文件是调试命令。没有新界面。共用播放引擎有 24p 与远程原盘内存修正，大多数人碰不到。要发的话得先补 `docs/changelog/macos-v0.12.0.md`，再在合并提交上打 `macos-v0.12.0`，且必须赶在下次再改 `MARKETING_VERSION` 之前。 |
| Apple TV | `tvos-v0.11.0` | 同上 | `MovieClawTV` 零文件变化。同上，可选 tag 是 `tvos-v0.12.0`。 |
| Android TV | `androidtv-v0.7.0` | 仍是 0.7.0 (9) | `apps/android-tv` 无改动。`android-core` 的本地播放只接在手机上。 |
| Windows | `windows-v0.1.2` | 仍是 0.1.2 | 只有间接依赖 rustls 0.23.45 → 0.23.46 的锁文件。没有界面变化。那些公告多数要打开 Brotli 或 ECH 才碰得到，这一轮不为此发未签名安装包。 |
| Mac 转码器 | `transcoder-v0.33.1` | 0.33.1 | 0 个文件。握手协议仍是 1。 |
| Windows 转码器 | 无正式 tag | 0.1.0 | 仍无公开渠道。 |
| HarmonyOS | 无 | 1.0.0 / versionCode 1000000 | 没有 release 工作流，也没有 tag 前缀。智慧屏、车机、播放引擎的改动留在 main，不在这一轮首发。 |
| NER、浏览器扩展 | 不变 | 不变 | 这个区间没有产物改动。 |

## CI

发版 PR 会因为改了 `__init__.py` 跑全量检查。`test_due_load_10000_units_100_expired_within_scan_budget` 在 GitHub runner 上三次 process_time 为 30.1s、30.3s、33.5s，卡在原来的 30 秒断言上；同一测试在 #1079 是通过的，调度周期没有改。断言放宽到 40 秒，只吸收 runner 抖动，成倍变慢仍会失败。

## 合并之后

见 `commands.md`。不要在这个 PR 合并前打 tag。

## 仍需人工

- iPhone / iPad：打包机上 `apps/apple/scripts/release.sh --upload` 传 TestFlight。本轮不传 Apple TV、Mac。
- 不替维护者提 App Store 正式审核。
- Android 安装包由 `android-release.yml` 签名上传，官网下载页自己同步。密钥沿用仓库里已有的，不要新生成。
- `services/playback/` 这一轮只动了播放事件与观看记录的来源编号，以及字幕识别；没有改 `ffmpeg_args.py`、`hwprobe.py`，也没有换 ffmpeg。硬件转码矩阵不作为这一版的门槛。换上新镜像后，用一部没有字幕的片子试一次「本地语音识别」即可。
