#!/usr/bin/env bash
# 把服务器 Release 的正文更新为 changelog + 自动生成的「客户端」一节（scripts/build-release-body.py）。
# 用于转正前终审与 changelog 合入后同步；没有 changelog 文件时不动正文。
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

gh api --paginate "repos/$repo/releases?per_page=100" \
  --jq '.[] | {tag: .tag_name, draft, prerelease, published_at}' > "$work/releases.jsonl"
python3 scripts/build-release-body.py --tag "$tag" --changelog "$file" \
  --releases "$work/releases.jsonl" --repo "$repo" > "$work/body.md"
gh release edit "$tag" --repo "$repo" --notes-file "$work/body.md"
