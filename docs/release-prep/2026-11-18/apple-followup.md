# 服务器成功后的 Apple / TestFlight 交接

这是用户后来明确授权的**依赖阶段**。必须先完成服务器 GitHub 正式 Release、正确 tag / SHA、必需附件与双架构 Docker 验收；主助手再另起 Codex Apple 任务。当前技术会话不上传、不改 Apple 凭据或协议。

## 已知 GitHub 基线与变化线索

截至服务器准备基线 `9dd11c106ddb76f2e711deef26494c89167ec4f4`：

| 平台 | 最新正式 GitHub tag | tag / Release target SHA | 已合入产品变化 | 后续决策 |
|---|---|---|---|---|
| iOS / iPadOS | `ios-v0.14.0` | `9b23196fc880f9ffdc1943aab9cdfdb491cfe98c` | `9dd11c106` 修复「我的」页左滑删除会话闪退；新增 PersonalSpace UI 回归。另有 Shared 生成模型字段 | 若实际对外 TF 基线还未含该修复，应发 iOS；通常拟 0.14.1，但须先核已上传版本 / build，不能复用已有版本构建号 |
| tvOS | `tvos-v0.14.0` | 同上 | GitHub 基线后只有 Shared 生成模型的已看策略可选字段，无对应新交互 / 运行逻辑 | 不因模型生成变化顺带上传；实际 TF 可能早于 GitHub tag，先比对实际 build 来源再决定 |
| macOS App | `macos-v0.14.0` | 同上 | 与 tvOS 一样，仅 Shared 生成模型字段 | 同上。Mac GitHub 公证 DMG 不等于 TF 构建已上传 |

三端共用 `apps/apple/project.yml` 的 `MARKETING_VERSION`，当前仍为 `0.14.0`。本次服务器 PR 没有修改 Apple 版本。

**实际 TestFlight 基线未核实。** GitHub Release 不能替代用户实际拿到的 TF build；后续任务必须用原有授权的 App Store Connect 入口只读核对每个平台最新上传 / 已处理 / 实际对外构建的版本号、build number、来源 commit。若构建 provenance 不足，明确证据缺口，不能猜 SHA。

## 后续 Codex 任务的精确职责

1. 接收服务器正式 release 链接、tag / SHA 与成功验收证据；fetch 最新 main，核独立 worktree 的真实起点，不覆盖其他会话。
2. 阅读 `.claude/skills/release/SKILL.md`、`docs/design/ios-release.md` 与 checklist；核对每个平台 GitHub tag **以及实际 TF build**。从真实对外基线到拟打包 commit 逐平台比产品与共享代码，不以“同一个 MARKETING_VERSION”推断三个平台都该发。
3. 固定有变化平台、精确 marketing version / 唯一 build number / commit 与独立双语日志 `docs/changelog/ios-vX.Y.Z.md`、`tvos-vX.Y.Z.md`、`macos-vX.Y.Z.md`。未发平台不改说明、不重复上传；如须递增共享版本，其余平台下次可以跳号。
4. 版本 / 日志若需要提交，走 PR 与对应检查；不得把未合入 Apple PR 写成已修。确认最终打包 SHA 与日志逐项一致，特别覆盖 iPhone / iPad 会话删除路径。
5. 使用已有签名配置、证书与 ASC 密钥，不新建或替换凭据，不输出秘密，不改转码协议。先构建 / 导出并核签名、bundle ID、平台、版本 / build、entitlements、归档与导出日志；随后才执行仓库既有上传流程。
6. 仓库脚本入口是 `apps/apple/scripts/release.sh --upload`（iOS）、加 `--tv`（tvOS）或 `--mac`（macOS）。只执行已确认有变化的平台；这些是后续入口，**当前没有执行**。脚本按 UTC 时间生成构建号，仍需与 ASC 现存构建核对。
7. 上传成功返回不算完成：逐平台跟踪 ASC processing 结果，核平台 / 版本 / build / 来源 SHA 与已签名导出物对应；处理失败读取诊断后修复，不盲目重复上传同一构建号。
8. 最终交付每个平台的版本 / build、commit、签名与导出校验、上传结果、processing 状态及可查的 ASC 构建记录。若还需要对外分发而缺授权，单独说明，不能自行扩展。

## 授权边界

- 用户授权后续有变化 Apple 平台打包、签名验证、上传 TestFlight，并跟进 processing。
- 不授权 App Store 正式审核、外部 TestFlight 审核、扩大 tester / group 分发；不擅自提交或更改这些设置。
- 不在服务器发布前并行上传，不用 Apple 工作替代服务器门禁或宣布服务器已完成。
