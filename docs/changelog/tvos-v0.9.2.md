## Apple TV 0.9.2: Ads skip themselves

The player now skips ads by itself and learns which shows you skip the intro on. The player panel is easier to find, and the app finds your server on the network more often. There was no Apple TV 0.9.1.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.9.0. Remembering intros needs Server 0.41.0. Install from TestFlight.

### Highlights

#### Ads skip themselves, intros once you've skipped one

Every recognized ad or intro used to wait for you to press skip, episode after episode. Now ads and previews skip on their own, and an **Undo (撤回)** button takes focus for a few seconds: press select to go back, or Back to dismiss it and keep watching. Skip an intro by hand once and that show skips its intro from then on; the screen says so. Undoing a skipped intro forgets the show again.

- Skippable parts are marked in amber on the progress bar. Seeking or dragging into one only shows the skip button.
- Learned shows belong to your account, so the web player and other updated apps skip them too.
- There's no switch to turn automatic skipping off; every skip can be undone.
- Outros and unclassified repeats are never skipped on their own. Share links skip ads but don't learn intros.
- On a server older than 0.41.0, ads still skip but intros stay a manual button.

### More features and improvements

- **Finding the player panel**: when the controls show during playback, a small arrow at the top with the panel's sections, such as "字幕 · 音轨 · 画质", reminds you that pressing down opens the panel. Moving between its columns lands on the option currently in use, so a quick select doesn't change it by mistake.
- **Finding the server**: the server shows up on the welcome screen even when Jellyfin compatibility is off (Server 0.41.0), and the app keeps the port the server reports. Typing just an address like 192.168.1.10 tries port 3000, then 80, then https.
- **Cloud-drive films away from home**: when a film that lives only on a cloud drive fails to stream straight from the drive, the app tries again through your home server. This needs Server 0.40.0 with a cloud drive plugin.

Full changes: [tvos-v0.9.0 → tvos-v0.9.2](https://github.com/movieclaw/MovieClaw/compare/tvos-v0.9.0...tvos-v0.9.2).

---

## 简体中文

## Apple TV 0.9.2：广告自动跳过

播放器现在会自动跳过广告，也会记住你在哪些剧里跳过片头。播放面板更好找，App 在局域网里也更容易找到服务器。Apple TV 没有 0.9.1 这一版。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.9.0 相同。记住片头需要服务器 0.41.0。从 TestFlight 安装。

### 本版亮点

#### 广告自动跳，片头跳过一次就记住

以前认出来的广告和片头都要你一集一集地按「跳过」。现在广告和预告自动跳过，焦点会落到几秒的「撤回」按钮上：按确认键回到原处，按返回键收起它、接着看。在一部剧里手动跳过一次片头，这部剧以后就自动跳片头，屏幕上会提示。撤回一次自动跳过的片头，这部剧就不再自动跳。

- 能跳过的段落在进度条上标成琥珀色。拖动或跳转到这些段落里，只给「跳过」按钮。
- 记住的剧跟着你的账号走，网页和其他更新过的 App 也会照样跳。
- 没有关闭自动跳过的开关；每次自动跳过都可以撤回。
- 片尾和尚未分类的重复段不会自动跳过。分享链接里广告照跳，但不会记片头。
- 服务器早于 0.41.0 时，广告照样自动跳，片头仍是手动按钮。

### 其他新功能与改进

- **播放面板更好找**：播放中控制层出现时，顶部有一个小箭头和面板的几栏名称（如「字幕 · 音轨 · 画质」），提醒按下键能打开面板。在面板的几栏之间左右移动时，落在正在用的那一项上，顺手按确认不会误改。
- **找服务器**：服务器关掉 Jellyfin 兼容时，欢迎页也能找到它（需要服务器 0.41.0），并沿用服务器报来的端口。只填 192.168.1.10 这样的地址时，会依次试 3000 端口、80 端口和 https。
- **在外面看网盘上的片子**：只存在网盘上的片子直连网盘失败时，App 会改走家里的服务器再试一次。需要服务器 0.40.0 和网盘插件。

完整改动：[tvos-v0.9.0 → tvos-v0.9.2](https://github.com/movieclaw/MovieClaw/compare/tvos-v0.9.0...tvos-v0.9.2)。
