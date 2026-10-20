## Android 0.6.0: Skip less, watch faster

The player now skips ads by itself and learns which shows you skip the intro on. You can also change the playback speed, and the app finds your server on the network more often.

> ✅ Works with MovieClaw Server 0.33.0 or later, the same as 0.5.0. Remembering intros needs Server 0.41.0. The app offers this update itself, or download it from https://movieclaw.io/download/android.apk.

### Highlights

#### Ads skip themselves, intros once you've skipped one

Every recognized ad or intro used to wait for you to tap skip, episode after episode. Now ads and previews skip on their own, with **Undo (撤回)** next to the "skipped" notice for a few seconds. Skip an intro by hand once and the player offers to do it for the rest of that show, with **No thanks (不用)** to decline; undoing a skipped intro forgets the show again.

- Skippable parts are marked in amber on the progress bar, in place of the dot at the end of the intro. Seeking or dragging into one only shows the skip button.
- Learned shows belong to your account, so the web player and other updated apps skip them too.
- There's no switch to turn automatic skipping off; every skip can be undone.
- Outros and unclassified repeats are never skipped on their own. Share links skip ads but don't learn intros.
- On a server older than 0.41.0, ads still skip but intros stay a manual button.

#### Watch at your own pace

There was no way to speed up a slow scene or a talk show except holding the screen for 2×. Now the sliders button (画质) in the player is a ⋮ button (更多) that opens a side panel with **Quality (画质)**, **Speed (倍速)** and **Playback diagnostics (播放诊断)**. Pick a speed from 0.5× to 2×.

- The speed is remembered per title: it stays for the next episode of the same show and goes back to normal for anything else. Share links and clips don't remember it.
- After holding for 2×, playback returns to the speed you picked.
- If the buffer can't keep up, the player goes back to normal speed.

### More features and improvements

- **Finding the server**: the server shows up when signing in even with Jellyfin compatibility off (Server 0.41.0), and the app keeps the port the server reports. Typing just an address like 192.168.1.10 tries port 3000, then 80, then https.

Full changes: [android-v0.5.0 → android-v0.6.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.5.0...android-v0.6.0).

---

## 简体中文

## Android 0.6.0：少按跳过，想快就快

播放器现在会自动跳过广告，也会记住你在哪些剧里跳过片头。还可以调播放速度，App 在局域网里也更容易找到服务器。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.5.0 相同。记住片头需要服务器 0.41.0。App 会自己提示这次更新，也可以从 https://movieclaw.io/download/android.apk 下载。

### 本版亮点

#### 广告自动跳，片头跳过一次就记住

以前认出来的广告和片头都要你一集一集地点「跳过」。现在广告和预告自动跳过，提示旁有几秒的「撤回」。在一部剧里手动跳过一次片头，播放器就提议这部剧以后都自动跳，点「不用」可以拒绝；撤回一次自动跳过的片头，这部剧就不再自动跳。

- 能跳过的片段在进度条上标成琥珀色，取代原来片头结束处的小圆点。拖动或跳转到片段里，只给「跳过」按钮。
- 记住的剧跟着你的账号走，网页和其他更新过的 App 也会照样跳。
- 没有关闭自动跳过的开关；每次自动跳过都可以撤回。
- 片尾和尚未分类的重复段不会自动跳过。分享链接里广告照跳，但不会记片头。
- 服务器早于 0.41.0 时，广告照样自动跳，片头仍是手动按钮。

#### 想快就快，想慢就慢

以前想快进一段慢戏或综艺，只能按住屏幕 2 倍速。现在播放器里的滑块按钮（画质）换成了 ⋮ 按钮（更多），点开侧边面板，里面是「画质」「倍速」和「播放诊断」。倍速从 0.5× 到 2× 任选。

- 速度按片子记：同一部剧的下一集沿用，换别的片子回到正常速度。分享链接和片段不记。
- 按住 2 倍速松开后，回到你选的速度。
- 缓冲跟不上时自动回到正常速度。

### 其他新功能与改进

- **找服务器**：服务器关掉 Jellyfin 兼容时，登录时也能找到它（需要服务器 0.41.0），并沿用服务器报来的端口。只填 192.168.1.10 这样的地址时，会依次试 3000 端口、80 端口和 https。

完整改动：[android-v0.5.0 → android-v0.6.0](https://github.com/movieclaw/MovieClaw/compare/android-v0.5.0...android-v0.6.0)。
