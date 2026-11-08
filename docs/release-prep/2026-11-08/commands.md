# 合并后的 tag

只在 rebase-merge 后执行。所有 tag 必须指向这次发版提交，不移动已有 tag，不运行 Apple 打包。

```bash
git fetch origin main
SHA=$(git rev-parse origin/main)
git show -s --oneline "$SHA"

for tag in \
  ios-v0.12.6 \
  macos-v0.12.6 \
  tvos-v0.12.6 \
  android-v0.9.4 \
  androidtv-v0.7.4 \
  windows-v0.1.3
do
  gh api repos/movieclaw/MovieClaw/git/refs \
    -f ref="refs/tags/$tag" \
    -f sha="$SHA"
done
```

确认六个 App Release 已转正、公开且不是 latest：

```bash
for tag in \
  ios-v0.12.6 \
  macos-v0.12.6 \
  tvos-v0.12.6 \
  android-v0.9.4 \
  androidtv-v0.7.4 \
  windows-v0.1.3
do
  gh release view "$tag" --repo movieclaw/MovieClaw \
    --json tagName,isDraft,isPrerelease,name,url
done

gh api repos/movieclaw/MovieClaw/releases/latest --jq .tag_name
```

`releases/latest` 此时仍应是 `v0.49.0`。然后创建服务器 tag：

```bash
gh api repos/movieclaw/MovieClaw/git/refs \
  -f ref="refs/tags/v0.49.1" \
  -f sha="$SHA"
```

核对服务器 Release 与 latest：

```bash
gh release view v0.49.1 --repo movieclaw/MovieClaw \
  --json tagName,isDraft,isPrerelease,name,url
gh api repos/movieclaw/MovieClaw/releases/latest --jq .tag_name
```

预期：`v0.49.1` 公开、不是 prerelease，并且是 latest。Docker 镜像应有 `v0.49.1`、`runtime-25`、`latest`。

## 本轮不打

`transcoder-v*`、`harmony-v*`、NER。HarmonyOS 没有正式签名，不能发布未签名 HAP。

## Apple

本轮只创建 iOS、macOS、tvOS 的 GitHub tag / Release。不在这台机器上打包，不上传 TestFlight，不提交 App Store 审核。
