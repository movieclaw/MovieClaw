# Android 版本与 GitHub 发版作业

## 版本边界

Android 手机/平板使用独立发行版本，唯一来源是 `apps/android/version.properties`。
首个官方版本为 `0.1.0`，安装版本码为 `30000001`，高于旧开发包的 `YYYYMMDD` 编码。
每次发布有变化的 Android 客户端，递增 `versionName` 和 `versionCode`，例如
`0.1.1 / 30000002`。同一天可以发布多个版本；同一提交重复构建不会自动改版本。
`versionCode` 必须递增且不超过 Android 的 `2100000000` 上限。

服务器继续使用 `vX.Y.Z`，Apple App 继续使用 `apps/apple/project.yml` 中的
`MARKETING_VERSION`。服务器发版只是 Android APK 的分发入口，不能拿服务器 tag
冒充 Android 客户端版本。独立客户端各有自己的 applicationId、版本文件和附件名：
Android TV 见下文「Android TV」；当前不预建尚未实现的产品或构建变体。

## 现有工作流分工

| 工作流 | 入口 | 职责 |
|---|---|---|
| `ci` | PR | Python、Web、CLI、Worker 的改动检查 |
| `ios` | PR | iPhone / TV / Mac 编译与测试，按路径运行 |
| `Android stability` | Android 或发版工作流改动的 PR / main push | 原生生命周期、场景测试、lint、APK，以及临时测试证书的完整 release 打包 |
| `downloads` | 下载元数据、打包脚本或发版工作流的 PR | 清单、签名检查和旧包沿用回归测试 |
| `release` | `v*` tag 或手动输入 tag | 创建 draft、构建/复制附件、发布 Docker、终审后转正 |
| `release-kick` | `release-kick/v*` 分支 | 校验服务器版本并触发 `release`，之后删除点火分支 |
| `docker-image` | `release` 调用或手动 | 多架构镜像及 tag 发布 |
| `release-notes` | changelog 合入 main | 同步对应 Release 的正文 |

`claude*` 和 `runtime-guard` 分别用于协作自动化、运行时兼容检查，不负责打包发布。

`release` 的作业链：

```mermaid
flowchart TD
    A[release-artifacts: 更新包与 draft Release] --> B[cli: 六平台 CLI]
    A --> C[docker-image: 多架构镜像]
    A --> D[asset-plan: 按改动决定重编或沿用]
    D --> E[android-apk: 签名 APK 或复制旧包]
    D --> H[android-tv-apk: TV 签名 APK 或复制旧包]
    D --> F[worker-macos / ios-ipa / mac-app / carry-assets]
    B --> G[publish: 校验附件、生成 downloads.json、转正]
    C --> G
    E --> G
    H --> G
    F --> G
```

Android APK 是必需附件，构建或沿用失败会阻止 draft 转正。原有 Mac / IPA / Worker
仍是可选附件，失败会显示红色作业，可重跑补传。Android 无改动时复制旧 APK 和其 JSON，
版本、签名、SHA-256 均保持旧包真实值；`force_rebuild` 可要求所有客户端附件重编。

## Android 产物与下载地址

当前支持 Android 8.0（API 26）及以上、arm64-v8a 手机/平板。

- `MovieClaw-Android-arm64.apk`：可直接安装的正式签名包，包含 Exo、MPV 及原生依赖。
- `MovieClaw-Android-arm64.json`：由 `aapt2` / `apksigner` 读取 APK 后生成的版本、
  安装版本码、最低 SDK、大小、SHA-256 和签名证书指纹，沿用时与 APK 一起复制。
- `downloads.json`：汇总实际 Mac、Android 与 Android TV 包信息，便于下载页读取各客户端独立版本。

最新版固定入口（首个包含 Android 的正式 Release 发布后生效）：

<https://github.com/movieclaw/MovieClaw/releases/latest/download/MovieClaw-Android-arm64.apk>

指定服务器发行批次（将 `vX.Y.Z` 换成实际 tag）：

`https://github.com/movieclaw/MovieClaw/releases/download/vX.Y.Z/MovieClaw-Android-arm64.apk`

## 签名与本地打包

Android 自签名证书由 JDK `keytool` 免费生成，无需 Apple 开发者账号。
正式版本长期使用同一密钥；GitHub Secrets 保存 CI 所需信息，私钥和密码不进入 git。
仓库所需 Secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、
`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。保存离线备份，重配 Secrets 时沿用同一密钥。

本地设置 `ANDROID_HOME`、`JAVA_HOME` 和以下四个环境变量后运行：

```bash
# 密码从本机凭证配置加载，不写进脚本或 shell 历史。
# ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD
bash apps/android/scripts/package-release.sh
```

产物位于 `apps/android/build/release/`。脚本禁用 Gradle 配置缓存，校验正式签名、
版本、架构及 MPV 依赖。原生库下载或校验失败会中止正式打包；开发 debug 构建仍允许 Exo-only。
PR 检查只生成短期测试证书，不接触正式签名密钥。

之前装过其他签名的开发包时，Android 不允许直接覆盖；迁移到官方签名包需要先卸载旧包。
之后官方签名保持一致，递增版本码即可覆盖升级并保留应用数据。

## Android TV

Android TV（`apps/android-tv`，[设计](androidtv-app.md)）是与手机版完全独立的 App，发版沿用同一套口径：

- **版本**：独立，唯一来源 `apps/android-tv/version.properties`，首版 `0.1.0 / 1`；有变化时
  `versionName` 与 `versionCode` 一起递增。不跟手机版或服务器 tag 同步——两个 App 的发布节奏、
  内核与依赖各不相同，共用版本号只会让一边出现内容没变的「新版本」。applicationId
  `io.movieclaw.androidtv` 与手机版并存，`versionCode` 互不影响。
- **签名**：与手机版共用同一把正式密钥（同一组 `ANDROID_KEYSTORE_*` Secrets）。applicationId
  不同，共用密钥不会互相覆盖，只是少保管一把；同样必须长期沿用。
- **附件**：`MovieClaw-AndroidTV.apk` + 同名 `.json`（`product` 为 `androidtv`）。一个包同时带
  arm64-v8a 与 armeabi-v7a（电视盒子仍有大量 32 位机器），`arch` 记 `arm`，`abis` 列出两种架构；
  最低 Android 6.0（API 23）。打包脚本校验两种架构的 FFmpeg 音频解码与 libass 库都在。
- **作业**：`android-tv-apk`，按 `apps/android-tv` 与发版工作流的改动重编或沿用。重编时安装
  NDK / CMake 现编 FFmpeg（`native/ffmpeg/build.sh`，LGPL 共享库），再 `assembleRelease`。
- **目前是可选附件**：TV 版还在种子用户测试，失败或缺失只在 `publish` 告警，不拦 Release 转正；
  重跑 `android-tv-apk` 可补传。稳定后再改成必需附件。

本地打包（同样的四个签名环境变量；首次会编 FFmpeg，`NDK` 默认 `$ANDROID_HOME/ndk/27.3.13750724`）：

```bash
bash apps/android-tv/scripts/package-release.sh   # 产物在 apps/android-tv/build/release/
```

固定入口：<https://github.com/movieclaw/MovieClaw/releases/latest/download/MovieClaw-AndroidTV.apk>

## 发版操作

1. Android / Android TV 有功能/修复变动时，更新各自的 `version.properties`；仅服务器变动时保持不变。
2. 按现有 release 规范更新服务器版本与 changelog，合入 main，触发 `release`。
3. 查看 `asset-plan` 和 `android-apk` 的构建/沿用结果；`publish` 检查 APK、JSON 和其他必需附件。
4. 在 Release 页面下载 APK；`android-apk` 作业摘要也提供本次固定 tag 下载链接。

验证命令：`python3 -m unittest discover -s scripts/tests`。完整打包验证运行上面的脚本，
检查 `aapt2` 包内版本、`apksigner` 签名和 APK → 元数据 → `downloads.json` 链路。
