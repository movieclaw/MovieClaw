#!/bin/zsh
# 打包 iPhone / Apple TV App（Release 归档 → 导出），可选直接上传到 App Store Connect。
# 只有一个发行版本：同一个构建既进内部 / 对外 TestFlight，也用于提审。发版流程与上架清单见
# docs/design/ios-release.md。
# 两端共用同一条 App Store 记录（同一个 Bundle ID）、各自一条构建序列，按需分别打包上传。
#
# 用法：
#   scripts/release.sh                只在本机导出 iPhone 版 .ipa，不上传（验证签名与打包）
#   scripts/release.sh --upload       导出并上传 iPhone 版到 App Store Connect
#   scripts/release.sh --tv [--upload] 同上，打的是 Apple TV 版
#
# 认证（二选一）：
#   - App Store Connect API 密钥（推荐，无人值守/CI 都能用；角色须为「管理」，「App 管理」用不了云端发布证书）：
#       MC_ASC_KEY_ID     密钥 ID
#       MC_ASC_ISSUER_ID  Issuer ID
#       MC_ASC_KEY_PATH   .p8 路径（默认 ~/.appstoreconnect/private_keys/AuthKey_<密钥 ID>.p8）
#   - 不给密钥时用 Xcode「设置 → 账户」里登录的 Apple ID（Xcode 27 的命令行读不到，报 No Accounts）。
# 其他可选环境变量：
#   MC_BUILD_NUMBER  构建号（默认 UTC 时间 yyyyMMddHHmm：同一营销版本下每次上传必须递增）
#   MC_DERIVED       DerivedData 目录（默认 build-release/DerivedData）
#   MC_SPM           共享的 Swift 包缓存目录（默认 ~/workspace/.mc-ios-spm，同 build.sh）
set -euo pipefail
cd "$(dirname "$0")/.."

upload=0
scheme=MovieClaw platform=iOS
for arg in "$@"; do
  case $arg in
    --upload) upload=1 ;;
    --tv) scheme=MovieClawTV platform=tvOS ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg（用 --help 看用法）" >&2; exit 64 ;;
  esac
done

auth=()
if [[ -n "${MC_ASC_KEY_ID:-}" ]]; then
  key_path="${MC_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${MC_ASC_KEY_ID}.p8}"
  if [[ ! -f $key_path ]]; then
    echo "错误：找不到 App Store Connect API 密钥文件：$key_path" >&2
    exit 1
  fi
  auth=(-authenticationKeyPath "$key_path"
        -authenticationKeyID "$MC_ASC_KEY_ID"
        -authenticationKeyIssuerID "${MC_ASC_ISSUER_ID:?配置了 MC_ASC_KEY_ID 但缺少 MC_ASC_ISSUER_ID}")
fi

command -v xcodegen >/dev/null || { echo "错误：需要 XcodeGen（brew install xcodegen）" >&2; exit 1; }
# 每次都按 project.yml 重新生成，保证打包用的工程与仓库里的定义一致
scripts/prepare-project.py

settings="$(xcodebuild -project MovieClaw.xcodeproj -scheme "$scheme" -configuration Release \
  -clonedSourcePackagesDirPath "${MC_SPM:-$HOME/workspace/.mc-ios-spm}" -onlyUsePackageVersionsFromResolvedFile -showBuildSettings 2>/dev/null)"
setting() { awk -v k="$1" '$1 == k && $2 == "=" { $1 = ""; $2 = ""; sub(/^ +/, ""); print; exit }' <<<"$settings"; }
team="$(setting DEVELOPMENT_TEAM)"
bundle_id="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
version="$(setting MARKETING_VERSION)"
if [[ -z $team ]]; then
  echo "错误：没有配置开发者团队。在 XcodeConfig/Signing.local.xcconfig 写一行 DEVELOPMENT_TEAM = 你的团队 ID" >&2
  exit 1
fi

build="${MC_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

commit="$(git rev-parse --short HEAD)"
if [[ -n "$(git status --porcelain -- .)" ]]; then
  echo "⚠️  apps/apple 下有未提交的改动，打进包里的代码与提交 $commit 不完全一致" >&2
fi

out="build-release"
name="${scheme}-${version}-${build}"
archive="$out/$name.xcarchive"
mkdir -p "$out"
echo "打包 $platform 版 $bundle_id $version（$build），团队 $team，提交 $commit"

# 归档。-allowProvisioningUpdates 让自动签名按需创建/更新发布证书与描述文件
echo "归档中（完整日志：$out/$name-archive.log）…"
if ! xcodebuild -project MovieClaw.xcodeproj -scheme "$scheme" -configuration Release \
  -destination "generic/platform=$platform" -archivePath "$archive" \
  -derivedDataPath "${MC_DERIVED:-$out/DerivedData}" \
  -clonedSourcePackagesDirPath "${MC_SPM:-$HOME/workspace/.mc-ios-spm}" -packageAuthorizationProvider netrc -onlyUsePackageVersionsFromResolvedFile \
  -allowProvisioningUpdates "${auth[@]}" \
  CURRENT_PROJECT_VERSION="$build" \
  archive >"$out/$name-archive.log" 2>&1; then
  grep -E "error:|BUILD FAILED|ARCHIVE FAILED" "$out/$name-archive.log" | sort -u | tail -20 >&2
  echo "错误：归档失败，详见 $out/$name-archive.log" >&2
  exit 1
fi

# 导出选项
export_options="$out/$name-ExportOptions.plist"
cat >"$export_options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$([[ $upload == 1 ]] && echo upload || echo export)</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

echo "$([[ $upload == 1 ]] && echo "导出并上传到 App Store Connect" || echo "导出 .ipa")中（完整日志：$out/$name-export.log）…"
if ! xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/$name" \
  -exportOptionsPlist "$export_options" -allowProvisioningUpdates "${auth[@]}" \
  >"$out/$name-export.log" 2>&1; then
  grep -E "error:|Error|EXPORT FAILED" "$out/$name-export.log" | sort -u | tail -20 >&2
  echo "错误：导出失败，详见 $out/$name-export.log" >&2
  exit 1
fi

if [[ $upload == 1 ]]; then
  echo "✅ 已上传 $platform 版 $version（$build）。App Store Connect 处理完（通常 5～30 分钟）后会出现在 TestFlight 里。"
else
  echo "✅ 已导出：$out/$name/"
fi
