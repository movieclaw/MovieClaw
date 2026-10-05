#!/usr/bin/env bash
# 判断某个可选发版附件（Mac 转码器、iOS 未签名 IPA、Mac 版 App）这次要重新编译，还是沿用上一版的。
#
# 为什么：转码器和 App 的改动频率远低于服务端，大部分发版里它们一行没变，却每次都在
# macOS runner 上重编、公证一遍，用户还会看到一个内容相同的「新版本」。没改动时直接把
# 上一个 Release 里的同名附件复制过来：文件名不变，latest/download 链接照常可用；
# 包里的版本号也停在真正构建它的那一版，如实反映「这次没更新」。
#
# 上一版取发版提交往前最近的 v* tag（必然是祖先提交，diff 才有意义）。以下任一情况都重编，
# 宁可多编一次也不发错包：
#   - FORCE_REBUILD=true（证书、公证配置或打包作业本身变了，代码 diff 看不出来）
#   - 找不到上一个 tag，或上一版 Release 不存在 / 仍是 draft / 缺这个附件
#   - 上一版到本次提交之间，给定路径有任何改动
#
# 用法：release-asset-plan.sh <附件文件名> <git pathspec>...
# 环境变量：RELEASE_TAG（必填）、TARGET_SHA（默认 HEAD）、GITHUB_REPOSITORY（gh 查哪个仓库）、FORCE_REBUILD
# 输出（stdout，供写进 $GITHUB_OUTPUT）：mode=build|carry 与 from=<上一版 tag>；判断理由打到 stderr
# 需要完整历史与 tag（actions/checkout 设 fetch-depth: 0）。
set -euo pipefail
cd "$(dirname "$0")/.."

asset="$1"
shift
target="${TARGET_SHA:-HEAD}"
: "${RELEASE_TAG:?需要 RELEASE_TAG}"

decide() {
  echo "mode=$1"
  echo "from=${2:-}"
  echo "$asset → $1：$3" >&2
  exit 0
}

[ "${FORCE_REBUILD:-false}" = "true" ] && decide build "" "手动要求全部重编"

# --exclude：tag 推送通道里本次 tag 就指着 target，不能拿自己当上一版
prev="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude "$RELEASE_TAG" "$target" 2>/dev/null)" ||
  decide build "" "找不到上一个 v* tag"

[ -n "${GITHUB_REPOSITORY:-}" ] && export GH_REPO="$GITHUB_REPOSITORY"
info="$(gh release view "$prev" --json isDraft,assets \
  --jq '"\(.isDraft) \(any(.assets[]; .name == "'"$asset"'"))"' 2>/dev/null)" ||
  decide build "" "上一版 $prev 没有 Release"
case "$info" in
  "false true") ;;
  "true "*) decide build "" "上一版 $prev 还是 draft" ;;
  *) decide build "" "上一版 $prev 缺这个附件" ;;
esac

if git diff --quiet "$prev" "$target" -- "$@"; then
  decide carry "$prev" "自 $prev 以来无改动，沿用其附件"
fi
decide build "" "自 $prev 以来有改动（$(git diff --name-only "$prev" "$target" -- "$@" | wc -l | tr -d ' ') 个文件）"
