# 合并后的 tag

先确认 main 上就是这个发版 PR 的合并提交，而且之后没有再进别的提交。用下面的 `SHA`，不要用 release-kick，也不要移动已经存在的 tag。

这一轮没有客户端 tag。等确认 main 没有再进别的提交后，直接打服务器 tag。

```bash
git fetch origin main
SHA=$(git rev-parse origin/main)
git show -s --oneline "$SHA"

gh api repos/movieclaw/MovieClaw/git/refs -f ref="refs/tags/v0.47.2" -f sha="$SHA"
```

核对：

```bash
gh release view v0.47.2 --repo movieclaw/MovieClaw --json tagName,isDraft,isLatest,name
```

预期：服务器 `isDraft=false` 且 `isLatest=true`。

Docker 镜像应有 `v0.47.2`、`runtime-25`、`latest`。runtime 这一轮没有 +1。

官网更新日志大约一分钟内出现；通知失败时到 Actions 跑 cloud-sync。

## 这一轮不要打

`ios-v*`、`macos-v*`、`tvos-v*`、`android-v*`、`androidtv-v*`、`windows-v*`、`transcoder-v*`、`harmony-v*`、NER。理由见 `README.md`。
