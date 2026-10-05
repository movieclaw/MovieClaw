#!/bin/zsh
# PR 上的 App 编译检查（.github/workflows/ios.yml）：只编不签不打包。
# 用法：ci-build.sh <scheme> <platform> <configuration>
#   例：ci-build.sh MovieClaw iOS Debug、ci-build.sh MovieClawTV tvOS Release、ci-build.sh MovieClawMac macOS Debug
# 普通 PR 编 Debug（按文件并行编、快）；发版 PR 编 Release，与发版的 ios-ipa 作业同口径。
# 完整日志写到 build-ci/<scheme>.log，失败时打出关键行与日志末尾。
set -euo pipefail
cd "$(dirname "$0")/.."

scheme=$1 platform=$2 config=$3
command -v xcodegen >/dev/null || { echo "错误：需要 XcodeGen（brew install xcodegen）" >&2; exit 1; }
xcodegen generate >/dev/null

mkdir -p build-ci
log="build-ci/$scheme.log"
echo "编译 $scheme（$platform，$config），完整日志：$log …"

# 索引与 dSYM 只给 Xcode 编辑器、崩溃符号化用，检查编译用不上，关掉省时间
if ! xcodebuild -project MovieClaw.xcodeproj -scheme "$scheme" -configuration "$config" \
  -destination "generic/platform=$platform" -derivedDataPath "build-ci/DerivedData-$scheme" \
  -clonedSourcePackagesDirPath "${MC_SPM:-$HOME/workspace/.mc-ios-spm}" -packageAuthorizationProvider netrc \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  COMPILER_INDEX_STORE_ENABLE=NO DEBUG_INFORMATION_FORMAT=dwarf \
  -showBuildTimingSummary \
  build >"$log" 2>&1; then
  # 编译错误之外还有编译器崩溃（Stack dump）、链接失败、构建步骤失败，格式各不相同：关键行 + 日志末尾都打出来
  grep -nE "error:|Stack dump|failed with a nonzero exit code|ld: |The following build commands failed" "$log" | head -80 || true
  echo "----- 日志末尾 -----"
  tail -60 "$log"
  exit 1
fi
# 各阶段耗时（编译、链接、资源处理…），以后要继续提速时先看这里
sed -n '/Build Timing Summary/,$p' "$log" | head -30
echo "✅ $scheme 编译通过"
