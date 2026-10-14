# 官网下载清单

GitHub 应用 Release 附件 `downloads.json` 是客户端包版本来源，与服务器更新用的 `manifest.json` 分开。Mac App、转码器和 Android 的版本独立，沿用旧包时不得改成服务器 tag 的版本。

客户端发版工作流在 draft 转正前，从已经上传的 `MovieClaw*-macos-*.zip` / APK 生成清单。`scripts/build-download-manifest.py` 读取 ZIP 内的 Info.plist、主程序 Mach-O，记录产品、版本、构建号、最低 macOS、芯片（arm64 / x86_64 / universal）、文件名、大小和 SHA-256。在 macOS 上验证 Developer ID 签名及 stapled 公证；非 macOS 环境将这两项标为 null（未知）。

Android 的 `MovieClaw-Android-arm64.apk` 也进入此清单，`product` 为 `android`。
Android runner 使用 `aapt2` / `apksigner` 读取真实 APK，生成同名 `.json`，记录
`applicationId`、`version`、`build`（versionCode）、`minimumSdk`、`arch`、
`asset`、`size`、`sha256`、`signed`、`certificateSha256`。汇总时校验 APK 的大小与
SHA-256 和 JSON 一致。沿用 APK 必须同时沿用 JSON；缺失或不一致会阻止发布。
Android TV 的 `MovieClaw-AndroidTV.apk` 同一份契约，`product` 为 `androidtv`、`applicationId` 为
`io.movieclaw.androidtv`；一个包含 64 / 32 位两种 ARM 架构，`arch` 为 `arm`，另有 `abis` 列表。
客户端全部独立发版：Android、Android TV、Mac 版 App、Mac 转码器（`android-v` / `androidtv-v` /
`macos-v` / `transcoder-v` 加 `X.Y.Z`）各自 Release 带一份只含自己一个包的 `downloads.json`；
v0.38.0 起服务器 Release 不再有客户端包，也不再生成 `downloads.json`。官网按发布时间汇总服务器与
各客户端 Release，取每个产品、每种芯片的最新包。iPhone（`ios-v`）的侧载 IPA 不进清单。
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

正常发布与重跑 apple-release / android-release 会自动更新清单。人工补传 ZIP 后也要刷新（在 macOS 上运行可验证签名、公证）：

```bash
bash scripts/publish-download-manifest.sh v0.32.0
```

此脚本从 GitHub 下载该 Release 的所有实际 Mac ZIP、Android APK 及其元数据，生成并补传清单，不需要重新发布服务器。Cloud 在访问时立即返回上次成功同步的缓存；缓存超过 1 小时，在响应发送后异步刷新 GitHub，新清单通过校验并保存后才供后续访问使用，更新下载信息无需重建官网。失败保留持久化的最近成功数据，1 小时后允许重试。首次没有缓存则立即提供 GitHub 发布入口，并安排后台同步，不猜版本或下载地址。

验证：`python3 -m unittest discover -s scripts/tests -p 'test_download_manifest.py'`；Cloud 中运行 `pnpm test:downloads`、`pnpm build && bash scripts/test-download-variants.sh`，以及 `bash scripts/test-download.sh <官网地址>` 核对真实 ZIP 与页面版本。

## 官网怎么读这些数据

GitHub Release 是唯一事实源；官网 api 维护一张派生的发布表（MovieClaw-Cloud 的 `cloud.releases`），官网网页只读这张表。
发版流水线与 release-notes 结束时用 `scripts/notify-cloud.sh` 通知官网（只带 tag，令牌在仓库机密
`CLOUD_RELEASE_SYNC_TOKEN`），官网收到后自己去 GitHub 拉发布记录、`release.json` 与 `downloads.json`，校验后写入；
官网每天全量对账一次，通知丢了也会补上。手动改过 Release 时运行 `cloud-sync` 工作流可立即同步。

## 版本信息清单 release.json

官网更新日志和版本邮件读 `release.json`，不解析 Release 正文。发版流水线在转正前生成，说明格式不对会拦下转正；`docs/changelog/` 合入 main 后，`release-notes.yml` 同步正文并重新生成。

服务器与每个客户端 Release 都有一份。服务器的带 `"product": "server"` 与下例字段；客户端的只有产品、版本与说明：
`{"schema": 1, "release": "android-v0.3.2", "product": "android", "version": "0.3.2", "notes": {...}}`，产品标识为
`iphone`（ios-v）、`appletv`（tvos-v）、`mac`（macos-v）、`transcoder`、`android`、`androidtv`、`windows`。
客户端 changelog 的标题行写 `## <产品名> X.Y.Z: 标题`，拆分规则与服务器相同。

`downloads.json` 里 iPhone（ios-v）记录未签名 IPA 的版本、构建号与最低 iOS（`product: iphone`）；Windows（windows-v）
按 Desktop CI 的 `release-manifest.json` 记录安装版与便携版两个包（`product: windows`，`variant: installer / portable`），
带构建号的 ZIP 不进清单。

```json
{
  "schema": 1,
  "release": "v0.33.0",
  "requiresRuntime": 19,
  "imageUpdate": false,
  "updated": ["server", "iphone", "mac", "transcoder", "android"],
  "notes": {
    "en": { "title": "Easier subscriptions, and another way to watch", "summary": "…", "body": "…" },
    "zh": { "title": "追更少配规则，看片多一种选择", "summary": "…", "body": "…" }
  }
}
```

- `imageUpdate`：`docker/runtime-version` 比上一个 tag 高，旧镜像装不了这一版，要先更新 Docker 镜像。
- `updated`：服务器每版都算；客户端附件（iphone / mac / transcoder / android / androidtv）的 SHA-256 与上一版不同，或上一版没有，才算这一版重新构建。沿用的旧包是原样复制，不算更新。
- `notes`：changelog 拆成英文、中文两段，各取「## vX.Y.Z: 标题」、紧随其后的一段摘要和其余正文。发布时 changelog 还没合入则为 `null`。

已发布版本补传：`bash scripts/publish-release-info.sh v0.33.0`（需要完整历史与 tag）。验证：`python3 -m unittest discover -s scripts/tests -p 'test_release_info.py'`，其中会校验 v0.28.0 起所有 changelog 都能拆开。
