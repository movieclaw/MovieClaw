#!/bin/zsh
# 打 Mac 版 App 的发行包，随 GitHub Release 发布（release.yml 的 mac-app 作业；本机手工发版同用）。
#
# 与转码器（macos/MovieClawTranscoder/scripts/package-app.sh）同一套签名与公证约定：
#   - MOVIECLAW_SIGNING_IDENTITY：「Developer ID Application: …」；不给则 ad-hoc 签名（只能自己机器上用）
#   - 公证凭证二选一，都不给就不公证：MOVIECLAW_NOTARY_PROFILE（本机 notarytool 存的凭证名），
#     或 MOVIECLAW_NOTARY_KEY_PATH / _KEY_ID / _ISSUER（App Store Connect API 密钥，流水线用）
#   - SIGNING_KEYCHAIN：签名证书所在的钥匙串（流水线的临时钥匙串；本机不用给）
#
# 版本号与 iPhone 版一样是 App 自己的（project.yml 的 MARKETING_VERSION），不跟服务端发版 tag 走；
# 构建号默认 UTC 时间 yyyyMMddHHmm。
#
# 为什么不让 Xcode 直接用 Developer ID 签：自动签名要登录开发者账号，流水线上没有；本机 Release 配置
# 又会用开发证书签并加上调试权限 get-task-allow，公证会拒。所以先用 ad-hoc 身份编出来，再按构建设置
# 生成权限声明（沙盒、网络，不含调试权限），由内向外重签：先签嵌入的框架与动态库，再签主程序，
# 全部带 Hardened Runtime 与可信时间戳——公证要求每个可执行文件都这样签。
#
# 可选环境变量：MC_BUILD_NUMBER（构建号）、MC_MAC_OUT（输出目录，默认 build-macapp，已被 git 忽略）、
#   MC_SPM（共享的 Swift 包缓存目录，同 build-unsigned-ipa.sh）
# 产物：$MC_MAC_OUT/MovieClaw-macos-arm64.zip（文件名固定，Release 的 latest/download 链接长期有效）
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "错误：需要 XcodeGen（brew install xcodegen）" >&2; exit 1; }
xcodegen generate >/dev/null

out="${MC_MAC_OUT:-build-macapp}"
build="${MC_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
identity="${MOVIECLAW_SIGNING_IDENTITY:--}"
zip_name="MovieClaw-macos-arm64.zip"
mkdir -p "$out"
echo "编译 Mac 版（构建号 $build，提交 $(git rev-parse --short HEAD)，完整日志：$out/build.log）…"

# ad-hoc 签名编译：不要开发者团队，也不注入调试权限（理由见文件头）。arm64：嵌入的 FFmpeg 等动态库只有 Apple 芯片切片
if ! xcodebuild -project MovieClaw.xcodeproj -scheme MovieClawMac -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$out/DerivedData" \
  -clonedSourcePackagesDirPath "${MC_SPM:-$HOME/workspace/.mc-ios-spm}" -packageAuthorizationProvider netrc \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CURRENT_PROJECT_VERSION="$build" \
  build >"$out/build.log" 2>&1; then
  grep -E "error:|BUILD FAILED" "$out/build.log" | sort -u | tail -20 >&2
  echo "错误：编译失败，详见 $out/build.log" >&2
  exit 1
fi

built="$out/DerivedData/Build/Products/Release/MovieClaw.app"
app="$out/MovieClaw.app"
rm -rf "$app" "$out/$zip_name"
ditto "$built" "$app"

# App 的权限声明：Mac 版的沙盒与网络进出写在构建设置里（project.yml 的 ENABLE_APP_SANDBOX 等），
# 由 Xcode 在有开发者团队的签名时生成；这里没有团队，照同一份构建设置按 Xcode 的对应关系生成，
# 不另维护一份权限文件。脚本还不认识的权限类设置一旦打开就报错，免得发出去的包悄悄少了权限
entitlements="$out/MovieClaw.entitlements"
settings="$(xcodebuild -project MovieClaw.xcodeproj -scheme MovieClawMac -configuration Release -showBuildSettings 2>/dev/null)"
setting() { awk -F' = ' -v key="$1" '{ sub(/^ +/, "", $1) } $1 == key { print $2; exit }' <<<"$settings"; }
unknown="$(awk -F' = ' '{ sub(/^ +/, "", $1) }
  $1 ~ /^(ENABLE_RESOURCE_ACCESS_|RUNTIME_EXCEPTION_|ENABLE_FILE_ACCESS_|ENABLE_USER_SELECTED_FILES|AUTOMATION_APPLE_EVENTS)/ &&
    $2 != "NO" && $2 != "" { print $1 " = " $2 }
  $1 == "CODE_SIGN_ENTITLEMENTS" && $2 != "" { print $1 " = " $2 }' <<<"$settings")"
if [ -n "$unknown" ]; then
  echo "错误：打包脚本还不会把这些设置换成权限声明，请先补上对应关系：" >&2
  echo "$unknown" >&2
  exit 1
fi
# 用 PlistBuddy 而不是 plutil：权限键名里有点号，plutil 会当成层级路径
plist() { /usr/libexec/PlistBuddy -c "$1" "$entitlements" >/dev/null; }
rm -f "$entitlements"
plist "Clear dict"
[ "$(setting ENABLE_APP_SANDBOX)" = YES ] && plist "Add :com.apple.security.app-sandbox bool true"
[ "$(setting ENABLE_OUTGOING_NETWORK_CONNECTIONS)" = YES ] && plist "Add :com.apple.security.network.client bool true"
[ "$(setting ENABLE_INCOMING_NETWORK_CONNECTIONS)" = YES ] && plist "Add :com.apple.security.network.server bool true"
for key in com.apple.security.app-sandbox com.apple.security.network.client; do
  if [ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" 2>/dev/null)" != "true" ]; then
    echo "错误：权限声明里缺少 $key（沙盒 App 连不上服务器），检查 project.yml 的 Mac 构建设置" >&2
    exit 1
  fi
done

sign_args=(--force --options runtime)
if [ "$identity" = "-" ]; then
  sign_args+=(--timestamp=none)   # ad-hoc 签名用不了可信时间戳
else
  sign_args+=(--timestamp)        # 公证要求可信时间戳
fi
if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
  sign_args+=(--keychain "$SIGNING_KEYCHAIN")
fi

# 由内向外：先签框架里的动态库与框架本身，再签主程序（不用 --deep，理由同转码器的脚本）
frameworks="$app/Contents/Frameworks"
if [ -d "$frameworks" ]; then
  find "$frameworks" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' lib; do
    codesign "${sign_args[@]}" --sign "$identity" "$lib"
  done
  find "$frameworks" -maxdepth 1 -name '*.framework' -print0 | while IFS= read -r -d '' framework; do
    codesign "${sign_args[@]}" --sign "$identity" "$framework"
  done
fi
codesign "${sign_args[@]}" --sign "$identity" --entitlements "$entitlements" "$app"
codesign --verify --strict --deep --verbose=2 "$app"
echo "已签名：$app（$( [ "$identity" = "-" ] && echo "ad-hoc" || echo "$identity" )）"

# 公证（可选），做法与转码器一致：提交 zip → 等结果 → 票据钉进 .app → 按 Gatekeeper 的口径复核
notarize=0
if [ -n "${MOVIECLAW_NOTARY_PROFILE:-}" ]; then
  notarize=1
  notary_auth=(--keychain-profile "$MOVIECLAW_NOTARY_PROFILE")
elif [ -n "${MOVIECLAW_NOTARY_KEY_PATH:-}" ]; then
  notarize=1
  notary_auth=(--key "$MOVIECLAW_NOTARY_KEY_PATH"
    --key-id "${MOVIECLAW_NOTARY_KEY_ID:?配置了 MOVIECLAW_NOTARY_KEY_PATH 但缺少 MOVIECLAW_NOTARY_KEY_ID}"
    --issuer "${MOVIECLAW_NOTARY_ISSUER:?配置了 MOVIECLAW_NOTARY_KEY_PATH 但缺少 MOVIECLAW_NOTARY_ISSUER}")
fi
if [ "$notarize" = 1 ]; then
  if [ "$identity" = "-" ]; then
    echo "错误：配置了公证凭证，但当前是 ad-hoc 签名。公证要求 Developer ID 签名（MOVIECLAW_SIGNING_IDENTITY）" >&2
    exit 1
  fi
  notary_dir="$(mktemp -d)"
  trap 'rm -rf "$notary_dir"' EXIT
  ditto -c -k --keepParent "$app" "$notary_dir/submit.zip"
  echo "正在提交 Apple 公证（通常几分钟，最长等 60 分钟）…"
  # 结果为 Invalid 时 --wait 的退出码不一定非零，以 JSON 里的 status 为准
  result="$(xcrun notarytool submit "$notary_dir/submit.zip" "${notary_auth[@]}" \
    --wait --timeout 60m --output-format json 2>"$notary_dir/stderr")" || true
  notary_status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
  submission="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
  if [ "$notary_status" != "Accepted" ]; then
    echo "错误：Apple 公证没有通过（状态：${notary_status:-提交失败}）。" >&2
    cat "$notary_dir/stderr" >&2
    [ -n "$result" ] && echo "$result" >&2
    if [ -n "$submission" ]; then
      echo "公证日志（逐条列出被拒的文件与原因）：" >&2
      xcrun notarytool log "$submission" "${notary_auth[@]}" >&2 || true
    fi
    exit 1
  fi
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose=2 "$app"
  echo "已公证并钉入票据（提交 ID：$submission）"
elif [ "$identity" = "-" ]; then
  echo "⚠️  ad-hoc 签名：只能在本机用，别人下载后会被系统拦下。发行请给 MOVIECLAW_SIGNING_IDENTITY 与公证凭证" >&2
else
  echo "⚠️  已用 Developer ID 签名但没有公证：别人下载后首次打开仍会被系统拦下" >&2
fi

# 必须用 ditto：App Bundle 里有符号链接与扩展属性，普通 zip 解开后可能无法启动
ditto -c -k --keepParent "$app" "$out/$zip_name"
echo "✅ 已生成 $out/$zip_name（$(du -h "$out/$zip_name" | cut -f1)，版本 $(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")（$build））"
