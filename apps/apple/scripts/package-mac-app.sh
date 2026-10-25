#!/bin/zsh
# 打 Mac 版 App 的发行包，单独发 macos-vX.Y.Z GitHub Release（apple-release.yml；本机手工发版同用）。
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
# 编的是 MovieClawMacDirect 目标（GitHub 直接分发版，带 Sparkle 自动更新）；商店版走 release.sh --mac。
# 更新包签名：SPARKLE_ED_PRIVATE_KEY（EdDSA 私钥，流水线的仓库密钥）；不给就不签（App 不会接受没签的更新包）。
#   本机发版从钥匙串取（generate_keys --account movieclaw 生成时存的）：
#   SPARKLE_ED_PRIVATE_KEY="$(security find-generic-password -s https://sparkle-project.org -a movieclaw -w)"
#   签完用 App 里的公钥（SUPublicEDKey）再验一遍，对不上就失败。
# 产物（文件名固定，官网下载清单按它识别）：
#   $MC_MAC_OUT/MovieClaw-macos-arm64.dmg        给人下载安装：打开是「拖到应用程序」的窗口（布局见 scripts/dmg/），DMG 本身也签名、公证
#   $MC_MAC_OUT/MovieClaw-macos-arm64.zip        给 App 自动更新用的更新包（不用挂载，替换更快）
#   $MC_MAC_OUT/MovieClaw-macos-arm64.zip.edsig  更新包的 EdDSA 签名，随 Release 上传，写进 downloads.json
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "错误：需要 XcodeGen（brew install xcodegen）" >&2; exit 1; }
command -v dmgbuild >/dev/null || { echo "错误：需要 dmgbuild（python3 -m pip install -r scripts/dmg/requirements.txt）" >&2; exit 1; }
scripts/prepare-project.py

out="${MC_MAC_OUT:-build-macapp}"
build="${MC_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
identity="${MOVIECLAW_SIGNING_IDENTITY:--}"
zip_name="MovieClaw-macos-arm64.zip"
dmg_name="MovieClaw-macos-arm64.dmg"
mkdir -p "$out"
echo "编译 Mac 版（构建号 $build，提交 $(git rev-parse --short HEAD)，完整日志：$out/build.log）…"

# ad-hoc 签名编译：不要开发者团队，也不注入调试权限（理由见文件头）。arm64：嵌入的 FFmpeg 等动态库只有 Apple 芯片切片
if ! xcodebuild -project MovieClaw.xcodeproj -scheme MovieClawMacDirect -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$out/DerivedData" \
  -clonedSourcePackagesDirPath "${MC_SPM:-$HOME/workspace/.mc-ios-spm}" -packageAuthorizationProvider netrc -onlyUsePackageVersionsFromResolvedFile \
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
rm -rf "$app" "$out/$zip_name" "$out/$dmg_name"
ditto "$built" "$app"

# App 的权限声明：Mac 版的沙盒与网络进出写在构建设置里（project.yml 的 ENABLE_APP_SANDBOX 等），
# 由 Xcode 在有开发者团队的签名时生成；这里没有团队，照同一份构建设置按 Xcode 的对应关系生成，
# 不另维护一份权限文件。脚本还不认识的权限类设置一旦打开就报错，免得发出去的包悄悄少了权限
entitlements="$out/MovieClaw.entitlements"
settings="$(xcodebuild -project MovieClaw.xcodeproj -scheme MovieClawMacDirect -configuration Release -clonedSourcePackagesDirPath "${MC_SPM:-$HOME/workspace/.mc-ios-spm}" -onlyUsePackageVersionsFromResolvedFile -showBuildSettings 2>/dev/null)"
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
# Sparkle 在沙盒里经它的安装器 XPC 服务替换 App，要能连上它注册的两个服务名（Sparkle 文档「Sandboxing」）
bundle_id="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
plist "Add :com.apple.security.temporary-exception.mach-lookup.global-name array"
plist "Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string $bundle_id-spks"
plist "Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string $bundle_id-spki"
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
# Sparkle 框架里还嵌着 XPC 服务和辅助程序，要先于框架本身各自签名（Sparkle 文档的顺序；Downloader 保留它自带的权限）
sparkle="$frameworks/Sparkle.framework/Versions/B"
if [ -d "$sparkle" ]; then
  codesign "${sign_args[@]}" --sign "$identity" "$sparkle/XPCServices/Installer.xpc"
  codesign "${sign_args[@]}" --sign "$identity" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
  codesign "${sign_args[@]}" --sign "$identity" "$sparkle/Autoupdate"
  codesign "${sign_args[@]}" --sign "$identity" "$sparkle/Updater.app"
fi
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

# 公证（可选），做法与转码器一致：提交 → 等结果 → 票据钉进去 → 按 Gatekeeper 的口径复核。
# App 和 DMG 各公证一次：App 钉了票据，从更新包（zip）里装出来的才能离线通过；DMG 钉了票据，断网打开安装盘也不会被拦
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
if [ "$notarize" = 1 ] && [ "$identity" = "-" ]; then
  echo "错误：配置了公证凭证，但当前是 ad-hoc 签名。公证要求 Developer ID 签名（MOVIECLAW_SIGNING_IDENTITY）" >&2
  exit 1
fi
notary_dir="$(mktemp -d)"
trap 'rm -rf "$notary_dir"' EXIT

# 提交一个文件（zip 或 dmg）公证并等结果，没通过就打出逐条原因并退出
submit_notary() {
  echo "正在提交 Apple 公证：$(basename "$1")（通常几分钟，最长等 60 分钟）…"
  # 结果为 Invalid 时 --wait 的退出码不一定非零，以 JSON 里的 status 为准
  local result notary_status submission
  result="$(xcrun notarytool submit "$1" "${notary_auth[@]}" \
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
  echo "公证通过（提交 ID：$submission）"
}

if [ "$notarize" = 1 ]; then
  ditto -c -k --keepParent "$app" "$notary_dir/submit.zip"
  submit_notary "$notary_dir/submit.zip"
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose=2 "$app"
  echo "App 已公证并钉入票据"
elif [ "$identity" = "-" ]; then
  echo "⚠️  ad-hoc 签名：只能在本机用，别人下载后会被系统拦下。发行请给 MOVIECLAW_SIGNING_IDENTITY 与公证凭证" >&2
else
  echo "⚠️  已用 Developer ID 签名但没有公证：别人下载后首次打开仍会被系统拦下" >&2
fi

# 必须用 ditto：App Bundle 里有符号链接与扩展属性，普通 zip 解开后可能无法启动
ditto -c -k --keepParent "$app" "$out/$zip_name"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"

# 更新包的 EdDSA 签名（Sparkle 自带的 sign_update，在 Swift 包缓存的 artifacts 里）
sign_update="${MC_SPM:-$HOME/workspace/.mc-ios-spm}/artifacts/sparkle/Sparkle/bin/sign_update"
rm -f "$out/$zip_name.edsig"
signature=""
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  signature="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update" --ed-key-file - -p "$out/$zip_name")"
fi
if [ -n "$signature" ]; then
  public_key="$(plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist")"
  if ! swift scripts/verify-update-signature.swift "$public_key" "$signature" "$out/$zip_name"; then
    echo "错误：更新包签名和 App 里的公钥（SUPublicEDKey）不是一对，检查 SPARKLE_ED_PRIVATE_KEY" >&2
    exit 1
  fi
  printf '%s\n' "$signature" > "$out/$zip_name.edsig"
  echo "更新包已签名并用 App 里的公钥核对通过"
else
  echo "⚠️  没有 EdDSA 私钥：更新包没签名，已装的 App 不会接受这个版本的自动更新" >&2
fi

# 安装盘：dmgbuild 按 scripts/dmg/settings.py 排版（直接写 .DS_Store，流水线上没有 Finder 也行）。
# 背景图 1x / 2x 合成一张多分辨率 TIFF，Retina 屏上不糊
tiffutil -cathidpicheck scripts/dmg/background.png scripts/dmg/background@2x.png -out "$notary_dir/background.tiff" >/dev/null
dmgbuild -s scripts/dmg/settings.py \
  -D app="$app" -D background="$notary_dir/background.tiff" -D icon="$app/Contents/Resources/AppIcon.icns" \
  "MovieClaw $version" "$out/$dmg_name" >"$out/dmg.log" 2>&1 || { cat "$out/dmg.log" >&2; echo "错误：生成 DMG 失败" >&2; exit 1; }
if [ "$identity" != "-" ]; then
  # DMG 只签名不加 Hardened Runtime（那是给可执行文件的）
  dmg_sign=(--force --timestamp --sign "$identity")
  if [ -n "${SIGNING_KEYCHAIN:-}" ]; then dmg_sign+=(--keychain "$SIGNING_KEYCHAIN"); fi
  codesign "${dmg_sign[@]}" "$out/$dmg_name"
  codesign --verify --verbose=2 "$out/$dmg_name"
fi
if [ "$notarize" = 1 ]; then
  submit_notary "$out/$dmg_name"
  xcrun stapler staple "$out/$dmg_name"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$out/$dmg_name"
  echo "DMG 已公证并钉入票据"
fi

echo "✅ 已生成（版本 $version（$build））："
echo "   $out/$dmg_name（$(du -h "$out/$dmg_name" | cut -f1)，给人下载安装）"
echo "   $out/$zip_name（$(du -h "$out/$zip_name" | cut -f1)，自动更新用）"
