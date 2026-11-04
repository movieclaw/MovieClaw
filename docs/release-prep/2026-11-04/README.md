# 2026-11-04 发版准备

检测命令：`python3 scripts/release-status.py --ref origin/main`，再用 `scripts/release-surface-diff.py` 对上一版 tag 看界面文字。盘点时 `origin/main` 为 `a429f7e0d`。流程以 `.claude/skills/release/SKILL.md` 为准，这里只记这一轮的取舍。

## 要发

| 产品 | 上一版 | 这一版 | tag（合并后打，本 PR 不打） | 理由 |
|---|---|---|---|---|
| 服务器 / Web / CLI | 0.47.1，runtime 25 | 0.47.2，runtime 仍是 25 | `v0.47.2` | 三处修复：剧集改名归并后季集停在 0，下次扫描按新文件名或分集 NFO 补上，已卡住的要点一次「扫描库」；「其他」库的 NFO 演员头像在「演职员」里显示；指到「设置 → 监听导入」的说明改成「设置 → 自动入库」。没有新功能，走 patch。没有数据库迁移，也没有新的运行时依赖。 |

这一轮没有要发的客户端。服务器 tag 直接打在合并提交上。

## 不发

| 产品 | 上次 tag | 代码里现在的版本 | 原因 |
|---|---|---|---|
| iPhone / iPad | `ios-v0.12.4` | 0.12.4 | 自上次 tag 0 个文件。 |
| Mac | `macos-v0.12.3` | 0.12.4（随上一轮 iPhone 共用版本号，但不打 tag） | 自 `macos-v0.12.3` 只有 `project.yml` 的版本号，以及 `apps/apple/scripts/agent-companion-lab.py` 的换行。Mac 界面没有改。 |
| Apple TV | `tvos-v0.12.3` | 同上 | `MovieClawTV` 没有新界面。同一份脚本。 |
| Windows | `windows-v0.1.2` | 仍是 0.1.2 | 只有 `Cargo.lock`：rustls 间接依赖。没有界面变化。 |
| Android | `android-v0.9.3` | 0.9.3 | 0 个文件。 |
| Android TV | `androidtv-v0.7.2` | 0.7.2 | 0 个文件。 |
| Mac 转码器 | `transcoder-v0.33.1` | 0.33.1 | 0 个文件。握手协议仍是 1。 |
| 鸿蒙 | 无 | 1.0.0 / versionCode 1000000 | 自上次盘点没有新的产品目录改动。工具链和正式签名还没配，不发未签名 HAP。 |
| NER、浏览器扩展 | 不变 | 不变 | 这个区间没有单独产物改动。 |

## CI

发版 PR 会因为改了 `__init__.py` 跑全量检查。`services/playback/`、`ffmpeg_args.py`、`hwprobe.py` 和 ffmpeg 都没动。硬件转码矩阵不作为这一版的门槛。

## 合并之后

见 `commands.md`。不要在这个 PR 合并前打 tag。

## 仍需人工

- 不在这台机器上编译或上传任何 Apple 构建，也不提 App Store 审核。这一轮没有 Apple tag。
