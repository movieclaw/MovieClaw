# 合并后的 tag

在 rebase-merge 产生的 main 提交上先发客户端，再发服务器。不要移动已有 tag，也不要运行 Apple 打包。

```bash
git fetch origin main
SHA=$(git rev-parse origin/main)
git show -s --oneline "$SHA"

gh api repos/movieclaw/MovieClaw/git/refs \
  -f ref="refs/tags/ios-v0.12.5" \
  -f sha="$SHA"
```

确认 `ios-v0.12.5` 的 Release 已转正、公开且不是 latest 后：

```bash
gh api repos/movieclaw/MovieClaw/git/refs \
  -f ref="refs/tags/v0.49.0" \
  -f sha="$SHA"
```

核对：

```bash
gh release view ios-v0.12.5 --repo movieclaw/MovieClaw --json tagName,isDraft,isPrerelease,name,url
gh release view v0.49.0 --repo movieclaw/MovieClaw --json tagName,isDraft,isPrerelease,name,url
gh api repos/movieclaw/MovieClaw/releases/latest --jq .tag_name
```

预期：`ios-v0.12.5` 公开且不是 latest；`v0.49.0` 公开且是 latest。Docker 镜像应有 `v0.49.0`、`runtime-25`、`latest`。

## 不打

`tvos-v*`、`macos-v*`、`android-v*`、`androidtv-v*`、`windows-v*`、`transcoder-v*`、`harmony-v*`、NER。
