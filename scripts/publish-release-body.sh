#!/usr/bin/env bash
# 把服务器 Release 的正文更新为 changelog + 自动生成的「客户端」一节（scripts/build-release-body.py）。
# 用于转正前终审与 changelog 合入后同步；没有 changelog 文件时不动正文。
# 需要完整历史与 tag（actions/checkout 设 fetch-depth: 0）。
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:?需要 Release tag}"
repo="${GITHUB_REPOSITORY:-movieclaw/MovieClaw}"
file="docs/changelog/$tag.md"
if [ ! -f "$file" ]; then
  echo "没有 $file，正文保持不变"
  exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 手动触发的发版在转正时才创建 tag，此前以当前检出的提交为准（与 publish-release-info.sh 一致）。
target="$tag"
git rev-parse -q --verify "refs/tags/$tag" > /dev/null || target=HEAD
apple="$(git show "$target:apps/apple/project.yml" | sed -n 's/^ *MARKETING_VERSION: *"\([^"]*\)".*/\1/p' | head -1)"
args=(--tag "$tag" --changelog "$file" --releases "$work/releases.jsonl" --repo "$repo" --apple-version "$apple")
if gh release download "$tag" --repo "$repo" --pattern downloads.json --dir "$work" 2> /dev/null; then
  args+=(--downloads "$work/downloads.json")
fi
if gh release download "$tag" --repo "$repo" --pattern release.json --dir "$work" 2> /dev/null; then
  args+=(--release-info "$work/release.json")
fi

gh api --paginate "repos/$repo/releases?per_page=100" \
  --jq '.[] | {tag: .tag_name, draft, prerelease, published_at, assets: [.assets[].name]}' > "$work/releases.jsonl"
python3 scripts/build-release-body.py "${args[@]}" > "$work/body.md"
gh release edit "$tag" --repo "$repo" --notes-file "$work/body.md"
