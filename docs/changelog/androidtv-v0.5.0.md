## Android TV 0.5.0: Ads skip themselves

The player now skips ads by itself and learns which shows you skip the intro on. Back on the remote no longer quits the app by surprise, and the app finds your server on the network more often.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.4.0. Remembering intros needs Server 0.41.0. The app offers this update itself, or download it from https://movieclaw.io/download/androidtv.apk.

### Highlights

#### Ads skip themselves, intros once you've skipped one

Every recognized ad or intro used to wait for you to press skip, episode after episode. Now ads and previews skip on their own, and an **Undo (撤回)** button takes focus for a few seconds: press select to go back, or Back to dismiss it and keep watching. Skip an intro by hand once and that show skips its intro from then on; the screen says so. Undoing a skipped intro forgets the show again.

- Skippable parts are marked in amber on the progress bar. Seeking or dragging into one only shows the skip button.
- Learned shows belong to your account, so the web player and other updated apps skip them too.
- There's no switch to turn automatic skipping off; every skip can be undone.
- Outros and unclassified repeats are never skipped on their own. Share links skip ads but don't learn intros.
- On a server older than 0.41.0, ads still skip but intros stay a manual button.

### More features and improvements

- **Back goes home first**: on the account (**Who's watching (谁在看？)**) and Search tabs, Back returns to Home instead of quitting. On Home, the first press shows **Press Back again to exit (再按一次返回键退出)**; press again within 2 seconds to quit.
- **Finding the server**: the server shows up on the welcome screen even when Jellyfin compatibility is off (Server 0.41.0), and the app keeps the port the server reports. Typing just an address like 192.168.1.10 tries port 3000, then 80, then https.
- **Dolby Vision UHD Blu-ray remuxes**: on a TV with HDR10 but no Dolby Vision, these films (Profile 7) play in HDR10 without transcoding the picture (the server repackages them), even when it has no graphics card. This needs Server 0.41.0.

### Fixed

- On Android 9 and older, such as the XGIMI H3S projector, the large artwork at the top of Home was covered by a near-white layer.
- With Server 0.41.0: on TVs that claim Dolby Digital support but stall on it, such as some Xiaomi TVs, a video could fail at every quality step.

Thanks to @jasonhorga. Full changes: [androidtv-v0.4.0 → androidtv-v0.5.0](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.4.0...androidtv-v0.5.0).

---

## 简体中文

## Android TV 0.5.0：广告自动跳过

播放器现在会自动跳过广告，也会记住你在哪些剧里跳过片头。按遥控器返回键不会再一下子退出 App，App 在局域网里也更容易找到服务器。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.4.0 相同。记住片头需要服务器 0.41.0。App 会自己提示这次更新，也可以从 https://movieclaw.io/download/androidtv.apk 下载。

### 本版亮点

#### 广告自动跳，片头跳过一次就记住

以前认出来的广告和片头都要你一集一集地按「跳过」。现在广告和预告自动跳过，焦点会落到几秒的「撤回」按钮上：按确认键回到原处，按返回键收起它、接着看。在一部剧里手动跳过一次片头，这部剧以后就自动跳片头，屏幕上会提示。撤回一次自动跳过的片头，这部剧就不再自动跳。

- 能跳过的段落在进度条上标成琥珀色。拖动或跳转到这些段落里，只给「跳过」按钮。
- 记住的剧跟着你的账号走，网页和其他更新过的 App 也会照样跳。
- 没有关闭自动跳过的开关；每次自动跳过都可以撤回。
- 片尾和尚未分类的重复段不会自动跳过。分享链接里广告照跳，但不会记片头。
- 服务器早于 0.41.0 时，广告照样自动跳，片头仍是手动按钮。

### 其他新功能与改进

- **返回键先回首页**：在账号（「谁在看？」）和搜索页签按返回键，回到首页而不是退出。在首页按第一下会提示「再按一次返回键退出」，2 秒内再按才退出。
- **找服务器**：服务器关掉 Jellyfin 兼容时，欢迎页也能找到它（需要服务器 0.41.0），并沿用服务器报来的端口。只填 192.168.1.10 这样的地址时，会依次试 3000 端口、80 端口和 https。
- **杜比视界 UHD 原盘 remux**：在支持 HDR10、不支持杜比视界的电视上，这类片子（Profile 7）直接按 HDR10 播放，画面不用转码（由服务器换封装），服务器没有显卡也能播。需要服务器 0.41.0。

### 修好了

- Android 9 及更早的系统上（如极米 H3S 投影），首页顶部大图被一层近白色盖住的问题已修复。
- 搭配服务器 0.41.0：在一些声称支持杜比数字、实际播放会卡住的电视上（如部分小米电视），片子可能每一档画质都播不了的问题已修复。

感谢 @jasonhorga 的贡献。完整改动：[androidtv-v0.4.0 → androidtv-v0.5.0](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.4.0...androidtv-v0.5.0)。
