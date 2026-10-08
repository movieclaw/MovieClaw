# 官网下载清单

GitHub 应用 Release 附件 `downloads.json` 是客户端包版本来源，与服务器更新用的 `manifest.json` 分开。Mac App、转码器和 Android 的版本独立，沿用旧包时不得改成服务器 tag 的版本。

`release.yml` 在 draft 转正前，从已经上传的所有 `MovieClaw*-macos-*.zip` 生成清单。`scripts/build-download-manifest.py` 读取 ZIP 内的 Info.plist、主程序 Mach-O，记录产品、版本、构建号、最低 macOS、芯片（arm64 / x86_64 / universal）、文件名、大小和 SHA-256。在 macOS 上验证 Developer ID 签名及 stapled 公证；非 macOS 环境将这两项标为 null（未知）。

Android 的 `MovieClaw-Android-arm64.apk` 也进入此清单，`product` 为 `android`。
Android runner 使用 `aapt2` / `apksigner` 读取真实 APK，生成同名 `.json`，记录
`applicationId`、`version`、`build`（versionCode）、`minimumSdk`、`arch`、
`asset`、`size`、`sha256`、`signed`、`certificateSha256`。汇总时校验 APK 的大小与
SHA-256 和 JSON 一致。沿用 APK 必须同时沿用 JSON；缺失或不一致会阻止发布。
Android TV 的 `MovieClaw-AndroidTV.apk` 同一份契约，`product` 为 `androidtv`、`applicationId` 为
`io.movieclaw.androidtv`；一个包含 64 / 32 位两种 ARM 架构，`arch` 为 `arm`，另有 `abis` 列表。
Android 下载入口和工作流见 [Android 发版说明](android-release.md)。

```json
{
  "schema": 1,
  "release": "v0.32.0",
  "packages": [{
    "product": "mac",
    "version": "0.5.0",
    "build": "202610051644",
    "arch": "arm64",
    "minimumSystemVersion": "26.0",
    "asset": "MovieClaw-macos-arm64.zip",
    "size": 18013647,
    "sha256": "a4bbc83ef60b799fc5fc6b4490857fdeaf739df05de1d662ee17fe3870337149",
    "signed": true,
    "notarized": true
  }]
}
```

Cloud 分页读取正式应用 Release，忽略 draft、预发布和模型 Release。只展示每个产品、每种芯片的最新可用包，校验附件确实存在、大小一致及 GitHub 提供的 SHA-256 一致，再生成固定 tag 的链接。不同芯片可以对应不同版本；不存在的芯片不提供选项。只有签名、公证都为 true 才显示公证提示。

正常发布与补跑 mac-app / worker-macos / carry-assets 会自动更新清单。人工补传 ZIP 后也要刷新（在 macOS 上运行可验证签名、公证）：

```bash
bash scripts/publish-download-manifest.sh v0.32.0
```

此脚本从 GitHub 下载该 Release 的所有实际 Mac ZIP、Android APK 及其元数据，生成并补传清单，不需要重新发布服务器。Cloud 在访问时立即返回上次成功同步的缓存；缓存超过 1 小时，在响应发送后异步刷新 GitHub，新清单通过校验并保存后才供后续访问使用，更新下载信息无需重建官网。失败保留持久化的最近成功数据，1 小时后允许重试。首次没有缓存则立即提供 GitHub 发布入口，并安排后台同步，不猜版本或下载地址。

验证：`python3 -m unittest discover -s scripts/tests -p 'test_download_manifest.py'`；Cloud 中运行 `pnpm test:downloads`、`pnpm build && bash scripts/test-download-variants.sh`，以及 `bash scripts/test-download.sh <官网地址>` 核对真实 ZIP 与页面版本。
