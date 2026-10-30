# 合并后的 tag

先确认 main 上就是这个发版 PR 的合并提交，而且之后没有再进别的提交。用下面的 `SHA`，不要用 release-kick，也不要移动已经存在的 tag。

客户端 tag 用 GitHub API 建在这个提交上。等四个 App 的 Release 都已转正（不再是 draft），并且都不是 latest，再打服务器 tag。

```bash
git fetch origin main
SHA=$(git rev-parse origin/main)
git show -s --oneline "$SHA"

for tag in ios-v0.12.1 android-v0.9.1 macos-v0.12.1 tvos-v0.12.1; do
  gh api repos/movieclaw/MovieClaw/git/refs -f ref="refs/tags/$tag" -f sha="$SHA"
done
```

等 `ios-v0.12.1`、`android-v0.9.1`、`macos-v0.12.1`、`tvos-v0.12.1` 的 Release 都已转正，再打服务器 tag：

```bash
gh api repos/movieclaw/MovieClaw/git/refs -f ref="refs/tags/v0.45.0" -f sha="$SHA"
```

核对：

```bash
gh release view v0.45.0 --repo movieclaw/MovieClaw --json tagName,isDraft,isLatest,name
gh release view ios-v0.12.1 --repo movieclaw/MovieClaw --json isDraft,isLatest
gh release view android-v0.9.1 --repo movieclaw/MovieClaw --json isDraft,isLatest
gh release view macos-v0.12.1 --repo movieclaw/MovieClaw --json isDraft,isLatest
gh release view tvos-v0.12.1 --repo movieclaw/MovieClaw --json isDraft,isLatest
```

预期：服务器 `isLatest=true`，四个 App `isLatest=false`，五个都 `isDraft=false`。

Docker 镜像应有 `v0.45.0`、`runtime-25`、`latest`。runtime 这一轮没有 +1。

官网更新日志大约一分钟内出现；通知失败时到 Actions 跑 cloud-sync。

## 这一轮不要打

`androidtv-v*`、`windows-v*`、`transcoder-v*`、`harmony-v*`、NER。理由见 `README.md`。
