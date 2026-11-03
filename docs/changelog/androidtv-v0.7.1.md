## Android TV 0.7.1: A dropped stream retries before the picture

If the stream drops before the first frame, playback tries again instead of opening the error page. The Android TV interface remains Chinese in this release.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.7.0. Install from https://movieclaw.io/download/androidtv.apk

### Fixed

- If the stream drops before the first frame, MovieClaw shows **连接中断，正在重连…** and tries again, instead of opening the error page immediately. Choosing a new address before that retry is still the phone app's behavior; the TV keeps the address it already has.
- After **立即更新**, if the TV's installer has no session confirmation screen, MovieClaw opens the standard install screen for that same APK instead of stopping. You can also start this from **检查更新** at the bottom of **谁在看**.

Full changes: [androidtv-v0.7.0 → androidtv-v0.7.1](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.7.0...androidtv-v0.7.1).

---

## 简体中文

## Android TV 0.7.1：画面出来之前断流会再试

第一帧出来之前断流，播放会再试一次，不再立刻打开错误页。这一版界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.7.0 相同。从 https://movieclaw.io/download/androidtv.apk 安装。

### 修好了

- 第一帧出来之前断流，会显示「连接中断，正在重连…」并再试，不再立刻打开错误页。断流后先重新选地址仍是手机上的行为；电视继续用已经选好的地址。
- 点「立即更新」之后，如果电视的系统安装器没有会话确认页，会改开同一份 APK 的标准安装界面，不再停在装不上。也可以从「谁在看」底部的「检查更新」开始。

完整改动：[androidtv-v0.7.0 → androidtv-v0.7.1](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.7.0...androidtv-v0.7.1)。
