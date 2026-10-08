#!/usr/bin/env bash
# 从这个 Release 已上传的实际安装包生成清单。用于转正前终审，以及已发布版本补传附件后刷新。
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:?需要 Release tag}"
repo="${GITHUB_REPOSITORY:-movieclaw/MovieClaw}"
download_dir="$(mktemp -d)"
trap 'rm -rf "$download_dir"' EXIT
gh release view "$tag" --repo "$repo" --json assets \
  --jq '.assets[].name | select(test("^MovieClaw.*-macos-.*\\.zip$|^MovieClaw-Android-.*\\.(apk|json)$|^MovieClaw-AndroidTV\\.(apk|json)$"))' > "$download_dir/assets.txt"
while IFS= read -r asset; do
  gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$download_dir"
done < "$download_dir/assets.txt"
python3 scripts/build-download-manifest.py --tag "$tag" --directory "$download_dir"
gh release upload "$tag" --repo "$repo" --clobber "$download_dir/downloads.json"
