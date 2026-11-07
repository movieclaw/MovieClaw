# 2026-11-07 发版准备

检测基线为 `origin/main@7a559390e`。已运行 `scripts/release-status.py --ref origin/main`，并用 `scripts/release-surface-diff.py` 分别对照各产品上一版 tag。只给有用户可见功能或修复的产品递增版本。

昨晚的 #1215 没有合入，且 main 已继续前进。本轮不改写它的分支，而是从今天的 `origin/main` 新建 `chore/release-2026-11-07`，继承服务器 0.49.0 的准备内容并纳入今天新合入的变化。新 PR 打开后，#1215 由它取代。

**本 PR 只准备版本号、更新说明与发版记录；tag 均在合入后创建。** 不运行 Apple 打包，不上传 TestFlight，不提交 App Store 审核。

## 要发

| 产品 | 上一版 | 这一版 | 合并后 tag | 理由 |
|---|---|---|---|---|
| iPhone / iPad | 0.12.4 | 0.12.5 | `ios-v0.12.5` | 返回 AI 会话时输入框会被重新出现的玻璃标签栏盖住，属于用户可见修复，走 patch。最低服务器版本不变。 |
| 服务器 / Web / CLI | 0.48.0，runtime 25 | 0.49.0，runtime 仍是 25 | `v0.49.0` | 继承 #1215 的本地/NFO 条目观看状态同步、默认字幕、插件取流凭据保护等新能力和修复；今天又加入 HDWing 站点适配、网页轮播、渠道重启提示，以及蓝光换盘与错误正片台账的恢复。存在新能力，仍走 minor。没有数据库迁移、运行时依赖或转码器协议变化。 |

客户端能搭配旧服务器，按客户端在前、服务器在后的顺序发布。

## 不发

| 产品 | 当前版本 | 原因 |
|---|---|---|
| Apple TV | 0.12.5（工程共号） | `tvos-v0.12.4` 之后 0 个产品文件变化；不因 iOS 共号重复发布。 |
| Mac | 0.12.5（工程共号） | `macos-v0.12.4` 之后 0 个产品文件变化；不因 iOS 共号重复发布。 |
| Android | 0.9.3 / 30000015 | 主要是生成模型；共享原盘读取性能改动针对 Android TV，已随 `androidtv-v0.7.3` 发布，没有手机端用户症状的验证。 |
| Android TV | 0.7.3 / 12 | 上一版之后 0 个产品文件变化。 |
| Windows | 0.1.2 | 只有 `Cargo.lock` 的 rustls bump，没有用户可见变化。 |
| Mac 转码器 | 0.33.1 | 0 个文件变化，握手协议仍是 1。 |
| HarmonyOS | 1.0.0 / 1000002，无正式 tag | 选集、字幕覆盖层和 4K 10-bit 修复值得后续发布，但正式工具链与签名仍未就绪；不发布未签名 HAP。 |
| NER、浏览器扩展 | 不变 | 本区间没有单独产物变化。 |

## 验证与风险

- 版本应为：服务器 `pyproject.toml` 与 `src/movieclaw_api/__init__.py` 均是 0.49.0；Apple 共用 `MARKETING_VERSION` 是 0.12.5。
- `release-status.py --ref HEAD --offline` 应显示服务器和 iPhone / iPad 可以发；Apple TV 与 Mac 会因为共用的 `MARKETING_VERSION` 机械显示可以发，但它们没有用户可见产品变化，不打 tag。
- iOS 改了返回转场布局。CI 编译和测试之外，仍建议在 iPhone 与 iPad 宽度各检查一次完成/取消返回手势和键盘展开/收起。
- 服务器改了默认字幕、远端取流、跨源跳转和蓝光补探。仍需用真实媒体服务器插件与原盘检查直放、seek / 重连、字幕、转码和启动自愈，并完成 release skill 第七节的硬件矩阵。
- 不运行 Apple 打包，不上传 TestFlight，不提交 App Store 审核。

## 合并之后

见 `commands.md`。先创建 `ios-v0.12.5`，确认 Release 转正且不是 latest；再创建 `v0.49.0`，确认服务器 Release 是 latest，Docker 有 `v0.49.0`、`runtime-25`、`latest`。
