# 合并后的 tag 与验证

只在 PR CI 全绿并 rebase-merge 后执行。所有 tag 必须指向本次合并提交；不移动或删除已有 tag，不运行 Apple 打包。

```bash
git fetch origin main
SHA=$(git rev-parse origin/main)
git show -s --oneline "$SHA"

for tag in \
  ios-v0.14.0 \
  macos-v0.14.0 \
  tvos-v0.14.0 \
  android-v0.11.0 \
  androidtv-v0.9.0 \
  windows-v0.2.0
do
  gh api repos/movieclaw/MovieClaw/git/refs \
    -f ref="refs/tags/$tag" \
    -f sha="$SHA"
done
```

从 Actions 列表找到六个 tag 对应的工作流 run。只轮询状态，不使用 `gh run watch`：

```bash
gh run view <id> --repo movieclaw/MovieClaw --json status,conclusion
```

确认每个 GitHub Release 已公开、不是 prerelease、不是 latest，并核对对应工作流要求的附件：

```bash
for tag in \
  ios-v0.14.0 \
  macos-v0.14.0 \
  tvos-v0.14.0 \
  android-v0.11.0 \
  androidtv-v0.9.0 \
  windows-v0.2.0
do
  gh release view "$tag" --repo movieclaw/MovieClaw \
    --json tagName,isDraft,isPrerelease,name,url,assets
done

gh api repos/movieclaw/MovieClaw/releases/latest --jq .tag_name
```

预期 `releases/latest` 仍是 `v0.50.0`。本轮不创建 `v0.51.0`：PR #1263 的硬件转码改动缺少修复后 NAS seek 真机复测。

## Docker 不变验证

本轮没有服务器 tag，不发布新镜像。客户端 Release 完成后只读核对既有三个标签仍指向同一份多架构清单：

```bash
for tag in v0.50.0 latest runtime-25
do
  docker buildx imagetools inspect "movieclaw/movieclaw:$tag"
done
```

预期三个标签的顶层 digest 相同，并至少包含 `linux/amd64` 与 `linux/arm64`。不要手工改写任何 Docker 标签。

## 本轮不打

`v0.51.0`、`transcoder-v*`、`harmony-v*`、NER。server 等 #1263 修复后的 VAAPI seek 真机复测；HarmonyOS
没有正式签名与工具链，不能发布未签名 HAP。

## Apple

本轮只创建 iOS、macOS、tvOS 的 GitHub tag / Release。不在这台机器上打包，不上传 TestFlight，不提交 App Store 审核。
