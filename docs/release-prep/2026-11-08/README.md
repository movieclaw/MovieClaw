# 2026-11-08 发版准备

检测基线为 `origin/main@b322bdebf`。已运行 `scripts/release-status.py --ref origin/main --offline`，并用 `scripts/release-surface-diff.py` 分别对照各产品上一版 tag。只给有用户可见功能或修复的产品递增版本。

本 PR 只准备版本号、更新说明与发版记录；tag 均在合入后创建。不运行 Apple 打包，不上传 TestFlight，不提交 App Store 审核。

## 要发

| 产品 | 上一版 | 这一版 | 合并后 tag | 理由 |
|---|---|---|---|---|
| 服务器 / Web / CLI | 0.49.0，runtime 25 | 0.49.1，runtime 仍是 25 | `v0.49.1` | 长篇动画连续绝对集号归一、刷新种子的订阅候选重评、字幕失败交接与提示、双语超读速统计、局部更新 LLM 默认模型都是用户可见修复。只有修复，走 patch。有一次数据库迁移。 |
| iPhone / iPad | 0.12.5 | 0.12.6 | `ios-v0.12.6` | 0.12.5 的返回转场抬升在真机没有生效；这一版直接移动输入框并已做真机核对。共享播放器升级也带来用户可见修复。 |
| Apple TV | 0.12.4 | 0.12.6 | `tvos-v0.12.6` | 截断简介可聚焦并打开「完整简介」，分集长按也能看全文；共享播放器有修复。Apple 三端共号，随 iOS 使用 0.12.6，跳过未发布的 0.12.5。 |
| Mac | 0.12.4 | 0.12.6 | `macos-v0.12.6` | 「播放时置顶」在用户暂停后回到普通层级，继续播放再置顶；共享播放器有修复。三端共号，同样跳到 0.12.6。 |
| Android | 0.9.3 / 30000015 | 0.9.4 / 30000016 | `android-v0.9.4` | 直放与蓝光片段由播放器本地绘制 PGS；不能显示时才明确提供服务端压制。走 patch，versionCode +1。 |
| Android TV | 0.7.3 / 12 | 0.7.4 / 13 | `androidtv-v0.7.4` | 完整简介页与焦点往返；分集长按菜单；PGS 本地绘制与显式压制。走 patch，versionCode +1。 |
| Windows | 0.1.2 | 0.1.3 | `windows-v0.1.3` | 内置 mpv 首个会话保留已选 PGS；直放使用原文件内封轨，不能旁挂时改走服务端压制。 |

各 App 的最低服务器版本没有上调。App 能搭配旧服务器，按 App 在前、服务器在后的顺序发布。

## 不发

| 产品 | 当前版本 | 原因 |
|---|---|---|
| Mac 转码器 | 0.33.1 | 上一版之后 0 个产品文件变化，握手协议仍是 1。 |
| HarmonyOS | 1.0.0 / 1000002，无正式 tag | PGS 播放改动有用户价值，但正式工具链与签名仍未就绪；不发布未签名 HAP。 |
| NER、浏览器扩展 | 不变 | 本区间没有单独产物变化。 |

## 特别判断

- #1221 在 GitHub 上合入的是 `cursor/pr1205-unfinished-base-c9b1`，合并提交 `4d4c98ccd` 不是 `origin/main` 的祖先。这一轮不能把手机 / Harmony 库墙过期响应修复写进说明或 tag；等它真正进入 main 后再判断。
- #1236 随 Apple 三端发布。已知两个非阻塞 P1 review finding：fork 的 keyframe snap 没有遵守精确 seek；`ReelPlayer` 的 `core.seek` 没传 `exact: true`。影响是部分跳转可能落在附近关键帧，不是崩溃或播放中断；本轮不阻塞，但在最终报告继续保留。
- #1222 的最终代码比首个提交保守：Android / Android TV 只在已知可本地绘制的直放与原盘片段申报 PGS；Windows 的 HLS 等通路重新协商服务端压制。说明按最终代码写，没有沿用中间提交里「所有通路本地画」的说法。

## 说明盘点

| 来源 | 用户可感知变化 | 写入 |
|---|---|---|
| #1230 | 只改一个默认模型时不再重置另一个 | 服务器「修好了」 |
| #1231 | 站点旧种刷新后重新评估；一次迁移 | 服务器改进、升级须知 |
| #1232 | 长诊断工单能交给 Agent；熔断提示按真实原因分流 | 服务器「修好了」 |
| #1233 | 跨季连续绝对集号贯穿匹配、核验、入库与扫描 | 服务器亮点 |
| #1235 | 双语超读速只统计译文行 | 服务器「修好了」 |
| #1236 | Apple 长播退出、PGS 回拖、画中画、AirPlay 等播放修复 | 三份 Apple 说明；P1 精度问题只写发版报告 |
| #1237 | Mac 暂停后不再置顶 | Mac「修好了」 |
| #1239 | iOS 真机返回转场直接移动输入框 | iOS「修好了」 |
| #1240 | tvOS / Android TV 截断简介聚焦、完整简介页和分集长按菜单 | 两份电视端亮点 |
| #1222 | Android、Android TV、Windows 的 PGS 本地绘制与显式压制 | 三份客户端说明 |

`release-surface-diff.py` 没发现 Apple 三端消失的界面文字。Android 新增 5 条 PGS 提示；Android TV 新增同类提示和「完整简介」「标为未看」；服务器新增的文字主要是绝对集号拒绝原因、诊断裁剪和重评任务说明，均已归入上表。Windows 改的是播放协议与行为，没有新增可见文字。

## 验证与风险

- 版本应为：服务器两处 0.49.1；Apple 共用 0.12.6；Android 0.9.4 / 30000016；Android TV 0.7.4 / 13；Windows 四处 0.1.3。
- `release-status.py --ref HEAD --offline` 应显示七个发布组件均有改动且版本递增；转码器无改动。
- 运行 release metadata / changelog 测试、Android release 测试、Windows 单测与 Rust 检查；端到端由 PR CI 完整覆盖。
- 服务器迁移只增加站点种子的待重评字段与索引；runtime 仍是 25，依赖和转码器协议没有变化。
- #1236 换了 Apple 播放内核，仍建议真机复核长播退出、PGS 回拖、画中画、AirPlay seek 和跳过片头落点。
- #1240 的完整简介已在 tvOS 与 Android TV 模拟器走过端到端，未在电视真机核对。
- #1222 未在 Android TV 真机核对 PGS 位置与切换；Windows Release 的 CI 会覆盖安装与播放回归，但不覆盖真实 GPU / 显示设备。
- 不运行 Apple 打包，不上传 TestFlight，不提交 App Store 审核。

## 合并之后

见 `commands.md`。在同一个 rebase-merge 后的 main 提交上先创建六个 App tag。确认六个 GitHub Release 都公开、非草稿、非预发布，并且不是 latest 后，再创建 `v0.49.1`。最后确认服务器 Release 是 latest，Docker 有 `v0.49.1`、`runtime-25`、`latest`。
