## iPhone and iPad 0.9.2: Skip less, watch faster

The player now skips ads by itself and learns which shows you skip the intro on. You can also change the playback speed, and the app finds your server on the network more often. There was no iPhone and iPad 0.9.1.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.9.0. Remembering intros needs Server 0.41.0. Install from TestFlight, or sideload the unsigned IPA from https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.9.2.

### Highlights

#### Ads skip themselves, intros once you've skipped one

Every recognized ad or intro used to wait for you to tap skip, episode after episode. Now ads and previews skip on their own, with **Undo (撤回)** next to the "skipped" notice for a few seconds. Skip an intro by hand once and the player remembers to skip it for the rest of that show; **No thanks (不用)** next to the notice takes that back. Undoing a skipped intro forgets the show too.

- Skippable parts are marked in amber on the progress bar. Seeking or dragging into one only shows the skip button.
- Learned shows belong to your account, so the web player and other updated apps skip them too.
- There's no switch to turn automatic skipping off; every skip can be undone.
- Outros and unclassified repeats are never skipped on their own. Share links skip ads but don't learn intros.
- On a server older than 0.41.0, ads still skip but intros stay a manual button.

#### Watch at your own pace

There was no way to speed up a slow scene or a talk show except holding the screen for 2×. Now tap ⋯ (设置) in the player, then **Speed (倍速)**, and pick from 0.5× to 2×.

- The speed is remembered per title: it stays for the next episode of the same show and goes back to normal for anything else. Share links and clips (片段) don't remember it.
- After holding for 2×, playback returns to the speed you picked.
- If the buffer can't keep up, the player goes back to normal speed and says so.

### More features and improvements

- **A simpler ⋯ menu**: the player's ⋯ menu is now a standard menu, with **Quality (画质)** and **Speed (倍速)** showing their current choice, plus **Playback diagnostics (播放诊断)**.
- **Finding the server**: the server shows up on the sign-in screen even when Jellyfin compatibility is off (Server 0.41.0), and the app keeps the port the server reports. Typing just an address like 192.168.1.10 tries port 3000, then 80, then https.
- **Offline mode**: buttons that need the server, such as the ▶ button (片段) at the top of the library, the library ⋯ menu, search and the quick AI input on Me (administrators), are hidden while offline.
- **Cloud-drive films away from home**: when a film that lives only on a cloud drive fails to stream straight from the drive, the app tries again through your home server. This needs Server 0.40.0 with a cloud drive plugin.

### Fixed

- In torrent search results, flinging to the end bounced back before the bottom, so the last results couldn't be reached.

Full changes: [ios-v0.9.0 → ios-v0.9.2](https://github.com/movieclaw/MovieClaw/compare/ios-v0.9.0...ios-v0.9.2).

---

## 简体中文

## iPhone 与 iPad 0.9.2：少按跳过，想快就快

播放器现在会自动跳过广告，也会记住你在哪些剧里跳过片头。还可以调播放速度，App 在局域网里也更容易找到服务器。iPhone 与 iPad 没有 0.9.1 这一版。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.9.0 相同。记住片头需要服务器 0.41.0。从 TestFlight 安装，或从 https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.9.2 下载未签名 IPA 侧载。

### 本版亮点

#### 广告自动跳，片头跳过一次就记住

以前认出来的广告和片头都要你一集一集地点「跳过」。现在广告和预告自动跳过，提示旁有几秒的「撤回」。在一部剧里手动跳过一次片头，这部剧以后就自动跳，提示旁的「不用」可以反悔；撤回一次自动跳过的片头，这部剧也不再自动跳。

- 能跳过的段落在进度条上标成琥珀色。拖动或跳转到这些段落里，只给「跳过」按钮。
- 记住的剧跟着你的账号走，网页和其他更新过的 App 也会照样跳。
- 没有关闭自动跳过的开关；每次自动跳过都可以撤回。
- 片尾和尚未分类的重复段不会自动跳过。分享链接里广告照跳，但不会记片头。
- 服务器早于 0.41.0 时，广告照样自动跳，片头仍是手动按钮。

#### 想快就快，想慢就慢

以前想快进一段慢戏或综艺，只能按住屏幕 2 倍速。现在在播放器里点 ⋯（设置）→「倍速」，从 0.5× 到 2× 任选。

- 速度按片子记：同一部剧的下一集沿用，换别的片子回到正常速度。分享链接和「片段」里的播放不记。
- 按住 2 倍速松开后，回到你选的速度。
- 缓冲跟不上时自动回到正常速度，并给出提示。

### 其他新功能与改进

- **⋯ 菜单更简洁**：播放器的 ⋯ 菜单换成系统菜单，「画质」「倍速」直接显示当前选择，下面是「播放诊断」。
- **找服务器**：服务器关掉 Jellyfin 兼容时，登录页也能找到它（需要服务器 0.41.0），并沿用服务器报来的端口。只填 192.168.1.10 这样的地址时，会依次试 3000 端口、80 端口和 https。
- **离线模式**：需要服务器的按钮在离线时隐藏，如媒体库顶部的 ▶ 按钮（片段）、媒体库的 ⋯ 菜单、搜索和「我的」页的 AI 快捷输入框（管理员）。
- **在外面看网盘上的片子**：只存在网盘上的片子直连网盘失败时，App 会改走家里的服务器再试一次。需要服务器 0.40.0 和网盘插件。

### 修好了

- 种子搜索结果甩到底时会弹回、最后几条看不到的问题已修复。

完整改动：[ios-v0.9.0 → ios-v0.9.2](https://github.com/movieclaw/MovieClaw/compare/ios-v0.9.0...ios-v0.9.2)。
