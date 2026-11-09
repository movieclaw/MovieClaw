# 合并后的 tag

只在 PR CI 全绿并 rebase-merge 后执行。所有 tag 必须指向本次合并提交；不移动或删除已有 tag，不运行 Apple 打包。

```bash
git fetch origin main
SHA=$(git rev-parse origin/main)
git show -s --oneline "$SHA"

for tag in \
  ios-v0.12.7 \
  macos-v0.12.7 \
  tvos-v0.12.7 \
  android-v0.9.5 \
  androidtv-v0.7.5 \
  windows-v0.1.4
do
  gh api repos/movieclaw/MovieClaw/git/refs \
    -f ref="refs/tags/$tag" \
    -f sha="$SHA"
done
```

轮询对应 tag 工作流，确认每个 Release 已转正且不是 latest：

```bash
for tag in \
  ios-v0.12.7 \
  macos-v0.12.7 \
  tvos-v0.12.7 \
  android-v0.9.5 \
  androidtv-v0.7.5 \
  windows-v0.1.4
do
  gh release view "$tag" --repo movieclaw/MovieClaw \
    --json tagName,isDraft,isPrerelease,name,url
done

gh api repos/movieclaw/MovieClaw/releases/latest --jq .tag_name
```

预期 `releases/latest` 仍是 `v0.49.1`。本轮没有服务器 tag，也不发布新 Docker 镜像；现有
`v0.49.1`、`runtime-25`、`latest` 应保持可用且不变。

## 本轮不打

`v*`、`transcoder-v*`、`harmony-v*`、NER。HarmonyOS 没有正式签名，不能发布未签名 HAP。

## Apple

本轮只创建 iOS、macOS、tvOS 的 GitHub tag / Release。不在这台机器上打包，不上传 TestFlight，不提交 App Store 审核。
