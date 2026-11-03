# 2026-11-02 发版准备

检测命令：`python3 scripts/release-status.py --ref origin/main`，再用 `scripts/release-surface-diff.py` 对上一版 tag 看界面文字。盘点时 `origin/main` 为 `99572a2a9`。流程以 `.claude/skills/release/SKILL.md` 为准，这里只记这一轮的取舍。

## 要发

| 产品 | 上一版 | 这一版 | tag（合并后打，本 PR 不打） | 理由 |
|---|---|---|---|---|
| 服务器 / Web / CLI | 0.46.0，runtime 25 | 0.47.0，runtime 仍是 25 | `v0.47.0` | 媒体库、类型墙和首页行可以筛「未看完」，是新功能，走 minor。没有数据库迁移，也没有新的运行时依赖。 |
| iPhone / iPad | 0.12.2 | 0.12.3 | `ios-v0.12.3` | 电影或本季最后一集放完后关掉播放器，回到这部片。旧服务器上照常用。 |
| Mac | `macos-v0.12.1` | 0.12.3 | `macos-v0.12.3` | 方向键跳转不再唤出控制栏；没有下一集时同样关掉播放器。0.12.2 没打过 Mac tag，工程版本随 iPhone 跳到 0.12.3。 |
| Apple TV | `tvos-v0.12.1` | 0.12.3 | `tvos-v0.12.3` | 播放面板增加倍速栏；没有下一集时关掉播放器。GitHub Release 只有说明。 |
| Android | 0.9.2 (30000014) | 0.9.3 (30000015) | `android-v0.9.3` | 信任用户安装的 CA，登录失败写明证书原因；普通播放失败不再停用解码器。界面仍是中文。 |
| Android TV | 0.7.1 (10) | 0.7.2 (11) | `androidtv-v0.7.2` | 播放面板增加倍速栏，菜单键开关面板；信任用户 CA；解码器只在最终解码失败时停用。 |

Apple 三端共用 `MARKETING_VERSION`。`ios-v0.12.2` 已经发过，Mac 与 Apple TV 的 0.12.2 没打过，这一轮三端一起用 0.12.3。

客户端都能在旧服务器上继续用，所以 **先打 App 的 tag，等 Release 转正且都不是 latest，再打服务器 tag**。服务器正文末尾的客户端一节是发布当时各 App 的最新 Release。

## 不发

| 产品 | 上次 tag | 代码里现在的版本 | 原因 |
|---|---|---|---|
| Windows | `windows-v0.1.2` | 仍是 0.1.2 | 只有 `Cargo.lock` 里 rustls 的锁文件。没有界面变化。 |
| Mac 转码器 | `transcoder-v0.33.1` | 0.33.1 | 0 个文件。握手协议仍是 1。 |
| 鸿蒙 | 无 | 1.0.0 / versionCode 1000000 | 没有可用的发布工作流配置。这一轮不首发。 |
| NER、浏览器扩展 | 不变 | 不变 | 这个区间没有单独产物改动。 |

`node-forge` 1.4.2 只在网页锁文件里，仓库源码没有引用。它跟着服务器发出去，不单独构成发版理由。

## CI

发版 PR 会因为改了 `__init__.py` 跑全量检查。`ffmpeg_args.py` 和 `hwprobe.py` 这一轮有改动：VAAPI 的 HDR 色调映射改成自检通过才启用，并等自检写完再给播放用。这台环境没有显卡，硬件矩阵没有跑。说明按代码写了规则，没有写某块显卡实测通过。合并不依赖这块真机结果；换上新镜像后，用一部 HDR 片在 VAAPI 上看一次「播放诊断」仍建议做。

## 合并之后

见 `commands.md`。不要在这个 PR 合并前打 tag。

## 仍需人工

- 不在这台机器上编译或上传任何 Apple 构建，也不提 App Store 审核。iPhone 的 GitHub Release 只有未签名 IPA。Mac 由 `apple-release.yml` 公证。Apple TV 的 GitHub Release 只有说明，TestFlight 要打包机另行上传，本轮不做。
- Android 与 Android TV 安装包由 `android-release.yml` 签名上传。密钥沿用仓库里已有的，不要新生成。
