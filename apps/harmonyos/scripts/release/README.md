# 鸿蒙独立发布

版本源为 `AppScope/app.json5` 的 `versionName` / `versionCode`，新版分别递增；tag 为
`harmony-vX.Y.Z`。更新日志位于 `docs/changelog/harmony-vX.Y.Z.md`，不跟随服务器或 Android 发版。

## 尚待配置

GitHub Actions 的 `harmony-release` 使用 Ubuntu 24.04 托管 runner，无需常开本机。
先配置仓库 Variables：

- `HARMONY_TOOLS_URL`：华为官方 Linux x86_64 Command Line Tools ZIP 的下载地址。
- `HARMONY_TOOLS_SHA256`：该原始 ZIP 的 SHA-256。URL 与摘要必须固定到同一工具链版本；
  不使用 `latest` 或未经核验的第三方重打包。

工具链必须含 HarmonyOS SDK（包括 HDS / UIDesignKit），不能以通用 OpenHarmony SDK 替代。
当前项目本机验证的编译 SDK 为 `26.0.0.105`，目标/最低版本为 HarmonyOS 6.1.1(API 24)。
本机 `release` 构建已成功；Linux 下载、安装与编译仍须配置上述变量后在 Actions 实跑验收，
本地成功不代表已经验证 GitHub 托管 runner。

正式签名需要仓库 Secrets（目前均待配置）：

- `HARMONY_KEYSTORE_BASE64`：长期保存的发布私钥库（P12）。
- `HARMONY_KEYSTORE_PASSWORD`、`HARMONY_KEY_ALIAS`、`HARMONY_KEY_PASSWORD`。
- `HARMONY_CERT_BASE64`：华为开发者账号对应的发布证书。
- `HARMONY_PROFILE_BASE64`：同 bundleName 的、已签名且有效的 release Profile。

不把开发自动签名证书、SDK 内置 OpenHarmony 证书或绑定调试设备的 debug Profile 当作正式签名。
签名文件仅在 runner 临时目录还原，结束即删除；不会上传到日志或 Release。

## 验证和发布

1. Actions → harmony-release → 输入 tag，保持 `build_only=true`。此模式不需要签名密钥，
   会构建 release 模式的未签名 HAP 并检查包内版本、关闭 debug、携带 ARM64 播放器库。
   Actions artifact 名称为 `harmony-unsigned-build-validation`，只用于验证，保留 7 天。
2. 补齐正式签名 Secrets，并确认签名 Profile 的分发类型适合目标用户。
3. 推送 `harmony-vX.Y.Z` tag、推送 `release-kick/harmony-vX.Y.Z` 点火分支，或手动选择
   `build_only=false`。缺少任意签名配置将失败停止，已有 Release 草稿不会转正。
4. 工作流构建、签名、验签，检查 Profile 的类型、bundleName 和有效期，生成绑定实际 HAP
   的版本/大小/SHA-256/证书摘要元数据，再上传到草稿、生成 downloads.json 与 release.json。
   全部成功后才公开 Release，始终 `latest=false`。失败可重跑草稿；已发布版本需要递增版本。

Release 附件为 `MovieClaw-HarmonyOS.hap`、`MovieClaw-HarmonyOS.json`、`downloads.json`
和 `release.json`。官网下载服务对 `product=harmony` 的 UI/分发支持仍需消费方验收。
GitHub 发布不等于华为应用市场上架：HAP 的安装受 Profile 的授权范围约束，普通用户的公开
分发需走华为认可的渠道。当前流水线不执行 AppGallery Connect 上传或商店审核提交。

本地验证（DevEco 路径仅作示例，Linux 使用解压后的 command-line-tools 根目录）：

```bash
export HARMONY_TOOLS_HOME=/Applications/DevEco-Studio.app/Contents
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
bash apps/harmonyos/scripts/release/package.sh
```

脚本使用官方 hvigorw / ohpm。正式签名由 `metadata.py sign` 调用 SDK 的 hap-sign-tool 执行，
正式签名和真实设备安装的完整链路仍待上述证书配置后验证。不要公开发布未签名构建产物。

参考：[华为命令行构建](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-hvigor-commandline)。
