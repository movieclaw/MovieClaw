# 合并后的 tag

先确认 main 上就是这个发版 PR 的合并提交，而且之后没有再进别的提交。介意带上后续提交时，用下面的 `SHA`，不要用 release-kick。

```bash
git fetch origin main
SHA=$(git rev-parse origin/main)
git show -s --oneline "$SHA"

git tag ios-v0.12.0 "$SHA"
git tag android-v0.9.0 "$SHA"
git push origin ios-v0.12.0 android-v0.9.0
```

等 `ios-v0.12.0` 与 `android-v0.9.0` 的 Release 都已转正（不再是 draft），再打服务器 tag。客户端 Release 不要标成 latest。

```bash
git tag v0.44.0 "$SHA"
git push origin v0.44.0
```

核对：

```bash
gh release view v0.44.0 --repo movieclaw/MovieClaw --json tagName,isDraft,isLatest,name
gh release view ios-v0.12.0 --repo movieclaw/MovieClaw --json isDraft,isLatest
gh release view android-v0.9.0 --repo movieclaw/MovieClaw --json isDraft,isLatest
```

预期：服务器 `isLatest=true`，两个 App `isLatest=false`，三个都 `isDraft=false`。官网更新日志大约一分钟内出现；通知失败时到 Actions 跑 cloud-sync。

## 推不了 tag 时

点火分支会在**触发时的 main HEAD** 上建 tag。App 的 Release 转正之前不要点服务器，main 上若又进了新提交也会被带上。

```bash
git fetch origin main
git push origin origin/main:refs/heads/release-kick/ios-v0.12.0
git push origin origin/main:refs/heads/release-kick/android-v0.9.0
# 两个 Release 转正之后：
git push origin origin/main:refs/heads/release-kick/v0.44.0
```

## 这一轮不要打

`macos-v0.12.0`、`tvos-v0.12.0`、`androidtv-v0.7.1`、`windows-v0.1.3`、`transcoder-v*`、HarmonyOS、NER。理由见 `README.md`。
