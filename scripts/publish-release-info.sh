#!/usr/bin/env bash
# 生成并上传这个 Release 的 release.json（官网更新日志、版本邮件的数据来源）。
# 用于转正前终审、changelog 合入后刷新，以及给已发布版本补传。
# 需要完整历史与 tag（actions/checkout 设 fetch-depth: 0）。
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:?需要 Release tag}"
repo="${GITHUB_REPOSITORY:-movieclaw/MovieClaw}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 手动触发的发版在转正时才创建 tag，此前以当前检出的提交为准（与 release-asset-plan.sh 一致）。
target="$tag"
git rev-parse -q --verify "refs/tags/$tag" > /dev/null || target=HEAD
args=(--tag "$tag" --runtime "$(git show "$target:docker/runtime-version")" --releases "$work/releases.jsonl")
if prev="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude "$tag" "$target" 2>/dev/null)"; then
  args+=(--previous-tag "$prev" --previous-runtime "$(git show "$prev:docker/runtime-version")")
fi
[ -f "docs/changelog/$tag.md" ] && args+=(--changelog "docs/changelog/$tag.md")

gh api --paginate "repos/$repo/releases?per_page=100" \
  --jq '.[] | {tag: .tag_name, assets: [.assets[] | {name, digest}]}' > "$work/releases.jsonl"
python3 scripts/build-release-info.py "${args[@]}" > "$work/release.json"
cat "$work/release.json"
gh release upload "$tag" --repo "$repo" --clobber "$work/release.json"
