# 2026-11-06 发版准备

检测命令：`python3 scripts/release-status.py --ref origin/main`，再用 `scripts/release-surface-diff.py` 对各产品上一版 tag 盘点界面文字与门槛。`git fetch origin` 后，本轮基线 `HEAD` 与 `origin/main` 同为 `b7db9e5986`。流程以 `.claude/skills/release/SKILL.md` 为准，这里只记这一轮的取舍。

## 要发

| 产品 | 上一版 | 这一版 | tag（合并后打，本 PR 不打） | 理由 |
|---|---|---|---|---|
| 服务器 / Web / CLI | 0.48.0，runtime 25 | 0.49.0，runtime 仍是 25 | `v0.49.0` | 有新能力，走 minor。兼容的媒体服务器插件可以给没有 TMDB / IMDb 编号的本地、只读 NFO 条目同步观看记录与状态，并可显式纳入「其他」库视频。播放首次起播会应用库的默认字幕；带凭据的插件片源跨源跳转时不泄露令牌，ffmpeg 输入也走服务器转发。另修正混合只读账号删除的部分成功、插件停用期间误写、原盘播放列表临时读取、整理计划里的旁车文件消失，以及 AI 上游无数据时长时间停在「思考中」。没有数据库迁移、运行时依赖或转码器协议变化。 |

## 不发

| 产品 | 上次 tag | 代码里现在的版本 | 原因 |
|---|---|---|---|
| iPhone / iPad | `ios-v0.12.4` | 0.12.4 | 上次 tag 后是播出日历共用逻辑抽取、生成模型和同周期的 PGS 共享改动；surface diff 没有 iPhone 入口被删除。相对本轮服务器基线 `v0.48.0` 没有新的 Apple 产品改动，不重复发同号 tag。 |
| Apple TV | `tvos-v0.12.4` | 0.12.4 | 上一版后 0 个产品文件改动，不重复发同号 tag。 |
| Mac | `macos-v0.12.4` | 0.12.4 | 上一版后 0 个产品文件改动，不重复发同号 tag。 |
| Android | `android-v0.9.3` | 0.9.3（30000015） | 主要是生成 API 模型；共享原盘读取性能改动针对 Android TV，已经随 `androidtv-v0.7.3` 发布，而且没有手机真机证据证明修复了用户症状。本轮不为内部/未验收性能改动单独发手机包。 |
| Android TV | `androidtv-v0.7.3` | 0.7.3（versionCode 12） | 上一版已包含共享原盘读取性能改动；之后 0 个产品文件改动，不重复发同号 tag。 |
| Windows | `windows-v0.1.2` | 0.1.2 | 只有 `Cargo.lock` 里的 rustls 依赖 bump，没有用户可见功能或修复。 |
| Mac 转码器 | `transcoder-v0.33.1` | 0.33.1 | 0 个文件改动，握手协议仍是 1。 |
| 鸿蒙 | 无单独发布 | 1.0.0 / versionCode 1000002 | 播放器新增选集和字幕覆盖层，并修正 4K 10-bit 渲染，值得记入后续正式版；但工具链与正式签名仍未就绪，禁止发布未签名 HAP。 |
| NER、浏览器扩展 | 不变 | 不变 | 这个区间没有单独产物改动。 |

Apple 三端共用 `MARKETING_VERSION`，现在都是 0.12.4，三个平台也都已经发过对应 tag，所以本轮不改工程号。

## CI 与验证

发版 PR 因修改 `src/movieclaw_api/__init__.py` 会跑全量检查。服务器版本应在 `pyproject.toml`、`src/movieclaw_api/__init__.py` 和 tag 三处保持 0.49.0。本机已运行 `scripts/export-spec.sh`，但环境没有 FastAPI（`ModuleNotFoundError: No module named 'fastapi'`），因此按 release skill 跳过；spec 是不入库的构建产物，CI / 发版构建会在依赖齐全时现场导出服务端与 Go CLI 两份。

本轮触及 `services/playback/strm_probe.py`、远端取流、重定向凭据和默认字幕选择。按 release skill，CI 之外仍需管理员用实际媒体服务器插件检查直放、拖动、字幕、跨源跳转与转码，并完成硬件转码矩阵和播放器真机走查。Harmony 的 4K 10-bit、字幕覆盖层和选集仍待正式签名链路具备后再验收、发版。

## 合并之后

见 `commands.md`。不要在这个 PR 合并前打 tag。

## 仍需人工

- 媒体服务器插件：同源 / 跨源跳转、直放、seek / 重连、默认字幕和需要 ffmpeg 的片源真机复核。
- release skill 第七节的 Intel / NVIDIA / AMD / 软件兜底硬件矩阵，以及网页、iOS、Safari 播放走查。
- 不在本轮发布 Harmony；不要用未签名 HAP 替代正式产物。
