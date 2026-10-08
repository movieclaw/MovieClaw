#!/bin/zsh
# 打未签名的 IPA，随 GitHub Release 发布，给不走 App Store / TestFlight 的用户侧载：
# 用户用 AltStore / SideStore / Sideloadly 等工具以自己的 Apple ID 重签后安装
# （免费 Apple ID 签的包 7 天过期，工具可自动续签；付费开发者账号 1 年）。
#
# 与商店版是同一份代码、同一个发行版本（docs/design/ios-release.md §1），只是不签名：
# 侧载工具会给主程序和 Frameworks/ 下的每个框架统一重签，这里签了也会被覆盖。
# 商店版的推送与 App Group 权限只在签名时写进包里，这里不签名，包里一个权限都没有；推送的通知扩展
# 打包时去掉（见下）。所以和以前一样，免费 Apple ID 也能签，只占 1 个 App ID。
#
# 本机与 CI（.github/workflows/release.yml 的 ios-ipa 作业）共用。可选环境变量：
#   MC_BUILD_NUMBER  构建号（默认 UTC 时间 yyyyMMddHHmm）
#   MC_IPA_OUT       输出目录（默认 build-ipa，已被 git 忽略）
#   MC_SPM           共享的 Swift 包缓存目录（默认 ~/workspace/.mc-ios-spm，同 build.sh）
# 产物：$MC_IPA_OUT/MovieClaw-iOS-unsigned.ipa（文件名固定，Release 的 latest/download 链接长期有效）
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "错误：需要 XcodeGen（brew install xcodegen）" >&2; exit 1; }
scripts/prepare-project.py

out="${MC_IPA_OUT:-build-ipa}"
build="${MC_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
ipa="MovieClaw-iOS-unsigned.ipa"
mkdir -p "$out"
echo "编译未签名 IPA（构建号 $build，提交 $(git rev-parse --short HEAD)，完整日志：$out/build.log）…"

# CODE_SIGNING_ALLOWED=NO：不签名、也不要求开发者团队（CI 与 fork 仓库都没有团队 ID）
if ! xcodebuild -project MovieClaw.xcodeproj -scheme MovieClaw -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath "$out/DerivedData" \
  -clonedSourcePackagesDirPath "${MC_SPM:-$HOME/workspace/.mc-ios-spm}" -packageAuthorizationProvider netrc -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="$build" \
  build >"$out/build.log" 2>&1; then
  grep -E "error:|BUILD FAILED" "$out/build.log" | sort -u | tail -20 >&2
  echo "错误：编译失败，详见 $out/build.log" >&2
  exit 1
fi

# IPA 就是 Payload/<App>.app 的 zip。用 ditto 复制保留符号链接与扩展属性
app="$out/DerivedData/Build/Products/Release-iphoneos/MovieClaw.app"
rm -rf "$out/Payload" "$out/$ipa"
mkdir -p "$out/Payload"
ditto "$app" "$out/Payload/MovieClaw.app"
# 去掉推送的两个通知扩展（解密、长按展开）：侧载包收不到推送——侧载工具重签时换了 Bundle ID，官方推送只发给
# App Store 版的 Bundle ID，免费 Apple ID 也开不了推送权限。留着它们只会多占 App ID（免费 Apple ID 每 7 天最多 10 个）。
# App 发现包里没有解密扩展就不弹通知权限（PushCenter.hasNotificationService）
rm -rf "$out/Payload/MovieClaw.app/PlugIns/MovieClawNotificationService.appex"
rm -rf "$out/Payload/MovieClaw.app/PlugIns/MovieClawNotificationContent.appex"
rmdir "$out/Payload/MovieClaw.app/PlugIns" 2>/dev/null || true
(cd "$out" && zip -qry "$ipa" Payload)
rm -rf "$out/Payload"
echo "✅ 已生成 $out/$ipa（$(du -h "$out/$ipa" | cut -f1)）"
