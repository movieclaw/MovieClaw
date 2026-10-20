## Mac 0.9.2: Skip less, watch faster

The player now skips ads by itself and learns which shows you skip the intro on. You can also change the playback speed, and the app finds your server on the network more often.

> ✅ Works with MovieClaw Server 0.31.0 or later, the same as 0.9.1. Remembering intros needs Server 0.41.0. Download from https://movieclaw.io/en/download and replace the old app.

### Highlights

#### Ads skip themselves, intros once you've skipped one

Every recognized ad or intro used to wait for you to click skip, episode after episode. Now ads and previews skip on their own, with **Undo (撤回)** next to the "skipped" notice for a few seconds. Skip an intro by hand once and the player remembers to skip it for the rest of that show; **No thanks (不用)** next to the notice takes that back. Undoing a skipped intro forgets the show too.

- Skippable parts are marked in amber on the progress bar. Seeking or dragging into one only shows the skip button.
- Learned shows belong to your account, so the web player and other updated apps skip them too.
- There's no switch to turn automatic skipping off; every skip can be undone.
- Outros and unclassified repeats are never skipped on their own. Share links skip ads but don't learn intros.
- On a server older than 0.41.0, ads still skip but intros stay a manual button.

#### Watch at your own pace

There was no way to speed up a slow scene or a talk show. Now the quality badge in the player's controls is a ⋯ button (更多): it holds **Quality (画质)** and **Speed (倍速)**, each showing the current choice. Pick from 0.5× to 2×, or press [ and ] to step the speed down and up.

- The speed is remembered per title: it stays for the next episode of the same show and goes back to normal for anything else. Share links and clips (片段) don't remember it.
- If the buffer can't keep up, the player goes back to normal speed and says so.

### More features and improvements

- **Finding the server**: the server shows up on the welcome screen even when Jellyfin compatibility is off (Server 0.41.0), and the app keeps the port the server reports. Typing just an address like 192.168.1.10 tries port 3000, then 80, then https.

Full changes: [macos-v0.9.1 → macos-v0.9.2](https://github.com/movieclaw/MovieClaw/compare/macos-v0.9.1...macos-v0.9.2).

---

## 简体中文

## Mac 0.9.2：少按跳过，想快就快

播放器现在会自动跳过广告，也会记住你在哪些剧里跳过片头。还可以调播放速度，App 在局域网里也更容易找到服务器。

> ✅ 搭配 MovieClaw 服务器 0.31.0 或更新版本即可使用，与 0.9.1 相同。记住片头需要服务器 0.41.0。从 https://movieclaw.io/zh/download 下载，替换旧版 App。

### 本版亮点

#### 广告自动跳，片头跳过一次就记住

以前认出来的广告和片头都要你一集一集地点「跳过」。现在广告和预告自动跳过，提示旁有几秒的「撤回」。在一部剧里手动跳过一次片头，这部剧以后就自动跳，提示旁的「不用」可以反悔；撤回一次自动跳过的片头，这部剧也不再自动跳。

- 能跳过的段落在进度条上标成琥珀色。拖动或跳转到这些段落里，只给「跳过」按钮。
- 记住的剧跟着你的账号走，网页和其他更新过的 App 也会照样跳。
- 没有关闭自动跳过的开关；每次自动跳过都可以撤回。
- 片尾和尚未分类的重复段不会自动跳过。分享链接里广告照跳，但不会记片头。
- 服务器早于 0.41.0 时，广告照样自动跳，片头仍是手动按钮。

#### 想快就快，想慢就慢

以前没法加速看一段慢戏或综艺。现在播放器控制条上的画质标签换成了 ⋯ 按钮（更多），里面是「画质」和「倍速」，各自显示当前选择。从 0.5× 到 2× 任选，也可以按 [ 和 ] 减慢、加快。

- 速度按片子记：同一部剧的下一集沿用，换别的片子回到正常速度。分享链接和「片段」里的播放不记。
- 缓冲跟不上时自动回到正常速度，并给出提示。

### 其他新功能与改进

- **找服务器**：服务器关掉 Jellyfin 兼容时，欢迎页也能找到它（需要服务器 0.41.0），并沿用服务器报来的端口。只填 192.168.1.10 这样的地址时，会依次试 3000 端口、80 端口和 https。

完整改动：[macos-v0.9.1 → macos-v0.9.2](https://github.com/movieclaw/MovieClaw/compare/macos-v0.9.1...macos-v0.9.2)。
