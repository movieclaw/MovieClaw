# 合并后的 tag 与验证

只在 PR CI 全绿并 rebase-merge 后执行。所有 tag 必须指向本次合并提交；不移动或删除已有 tag，不运行 Apple 打包。

```bash
git fetch origin main
SHA=$(git rev-parse origin/main)
git show -s --oneline "$SHA"

for tag in \
  ios-v0.13.0 \
  macos-v0.13.0 \
  tvos-v0.13.0 \
  android-v0.10.0 \
  androidtv-v0.8.0
do
  gh api repos/movieclaw/MovieClaw/git/refs \
    -f ref="refs/tags/$tag" \
    -f sha="$SHA"
done
```

从 Actions 列表找到这五个 tag 对应的工作流 run。只用下面的命令轮询，不使用 `gh run watch`：

```bash
gh run view <id> --repo movieclaw/MovieClaw --json status,conclusion
```

确认每个 GitHub Release 已公开、不是 prerelease、不是 latest，并核对对应工作流要求的附件：

```bash
for tag in \
  ios-v0.13.0 \
  macos-v0.13.0 \
  tvos-v0.13.0 \
  android-v0.10.0 \
  androidtv-v0.8.0
do
  gh release view "$tag" --repo movieclaw/MovieClaw \
    --json tagName,isDraft,isPrerelease,name,url,assets
done

gh api repos/movieclaw/MovieClaw/releases/latest --jq .tag_name
```

预期此时 `releases/latest` 仍是 `v0.49.1`。五个 App Release 都转正后，再创建服务器 tag：

```bash
gh api repos/movieclaw/MovieClaw/git/refs \
  -f ref="refs/tags/v0.50.0" \
  -f sha="$SHA"
```

找到 `v0.50.0` 的 release workflow run，继续用 `gh run view <id> --json status,conclusion` 轮询。完成后核对：

```bash
gh release view v0.50.0 --repo movieclaw/MovieClaw \
  --json tagName,isDraft,isPrerelease,isLatest,name,url,assets
gh api repos/movieclaw/MovieClaw/releases/latest --jq .tag_name
```

预期服务器 Release 已公开、不是 prerelease、`isLatest=true`，并带齐应用三件套、mclaw 多平台归档、校验和与 release.json。

## Docker manifest

服务器工作流完成后，等待 Docker Hub 三个标签可见，再读取 registry manifest digest 与平台清单：

```bash
for tag in v0.50.0 latest runtime-25
do
  docker buildx imagetools inspect "movieclaw/movieclaw:$tag"
done
```

预期三个标签的顶层 digest 相同，并且平台清单至少包含正式工作流定义的 `linux/amd64` 与 `linux/arm64`。若标签仍未出现，
等待工作流完成后的 registry 同步；不要手工改写既有 tag。

## 本轮不打

`windows-v*`、`transcoder-v*`、`harmony-v*`、NER。HarmonyOS 没有正式签名与既有 release tag，不能发布未签名 HAP。

## Apple

本轮只创建 iOS、macOS、tvOS 的 GitHub tag / Release。不在这台机器上打包，不上传 TestFlight，不提交 App Store 审核。
