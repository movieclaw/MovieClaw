# 2026-11-05 发版准备

检测命令：`python3 scripts/release-status.py --ref origin/main`，再用 `scripts/release-surface-diff.py` 对上一版 tag 看界面文字。盘点时 `origin/main` 为 `d68e901e4`。流程以 `.claude/skills/release/SKILL.md` 为准，这里只记这一轮的取舍。

## 要发

| 产品 | 上一版 | 这一版 | tag（合并后打，本 PR 不打） | 理由 |
|---|---|---|---|---|
| 服务器 / Web / CLI | 0.47.2，runtime 25 | 0.48.0，runtime 仍是 25 | `v0.48.0` | 有新功能，走 minor。站点把 TMDB 长季拆成下一季发布时，刷新元数据后能归到正确的集（可空列 `season_mapping`）。网页上 PGS 由播放器绘制，压制进画面改为显式操作。本地 / NFO 库点演员跳到同库按演员筛的海报墙。只读插件目录标「只读」。另外修正主片选错的原盘和 ISO 码率，以及 Kotlin SDK 的 Jellyfin 客户端打不开详情。有数据库迁移。没有新的运行时依赖。 |
| Mac | 0.12.3 | 0.12.4（工程里已经是这个号，本 PR 不再递增） | `macos-v0.12.4` | 详情页播出日历。旧服务器上这条藏起来，还没播的集仍按缺集置灰。最低服务器版本仍是 0.31.0。 |
| Apple TV | 0.12.3 | 0.12.4（同上，不另递增） | `tvos-v0.12.4` | 同一份播出日历，按遥控器排。最低服务器版本仍是 0.28.0。GitHub Release 只有说明。 |
| Android TV | 0.7.2（versionCode 11） | 0.7.3（versionCode 12） | `androidtv-v0.7.3` | 详情页播出日历。界面仍是中文。最低服务器版本仍是 0.28.0。 |

Apple 三端共用 `MARKETING_VERSION`。iPhone 已经发过 `ios-v0.12.4`，Mac 和 Apple TV 还没发过 0.12.4，所以这两个 tag 用现有的 0.12.4，不再把工程号抬到 0.12.5。

这三个 App 都不依赖这一版服务器才有的接口。播出日历要服务器 0.44.0 才出现，更旧的服务器上功能藏起来，登录门槛不变。所以 **先打 App 的 tag，等 Release 转正且不是 latest，再打服务器 tag**。服务器正文末尾的客户端一节是发布当时各 App 的最新 Release。

## 不发

| 产品 | 上次 tag | 代码里现在的版本 | 原因 |
|---|---|---|---|
| iPhone / iPad | `ios-v0.12.4` | 0.12.4 | 播出日历的口径抽到 Shared，界面文字没有增减。新的「首次订阅要先在手机或网页上完成智能设置」只被 Mac、Apple TV、Android TV 用到，iPhone 的日历不调用它。生成模型多了可选字段。用户看不到差别。 |
| Android | `android-v0.9.3` | 0.9.3（30000015） | 只有生成出来的 API 模型。手机界面没有改。 |
| Windows | `windows-v0.1.2` | 仍是 0.1.2 | 只有 `Cargo.lock` 里的 rustls。没有界面变化。 |
| Mac 转码器 | `transcoder-v0.33.1` | 0.33.1 | 0 个文件。握手协议仍是 1。 |
| 鸿蒙 | 无单独发布 | 1.0.0 / versionCode 1000000 | 自上次盘点没有新的产品目录改动。工具链和正式签名还没配，不发未签名 HAP。 |
| NER、浏览器扩展 | 不变 | 不变 | 这个区间没有单独产物改动。 |

## CI

发版 PR 会因为改了 `__init__.py` 跑全量检查。`ffmpeg_args.py`、`hwprobe.py` 和 ffmpeg 都没动。播放改动是「网页 PGS 不再默认烧录」和原盘主片选择，不改转码命令。硬件转码矩阵不作为这一版的门槛。

## 合并之后

见 `commands.md`。不要在这个 PR 合并前打 tag。

## 仍需人工

- 不在这台机器上编译或上传任何 Apple 构建，也不提 App Store 审核。Mac 与 Apple TV 的 TestFlight / 公证由打包机另行处理。
- 原盘主片换回正片、网页原盘 PGS 叠在画面上，这一轮没有在真机上再播一遍。代码和提交里的 NAS 核对是依据。
