## Android 0.9.3: A private certificate can sign in

A CA you installed on the phone is trusted, and a failed login says which certificate problem it hit. The Android interface remains Chinese in this release.

> ✅ Works with MovieClaw Server 0.33.0 or later, the same as 0.9.2. Install from https://movieclaw.io/download/android.apk

### Fixed

- MovieClaw trusts CAs installed on the device, as well as the system CAs. A server that uses a private certificate can be reached after you install that CA.
- A failed HTTPS login names the problem. The messages are **服务器的 HTTPS 证书已过期：请在服务器上续期证书，并检查设备时间是否正确**, **服务器的 HTTPS 证书与服务器域名不匹配：请使用证书对应的域名，或修正服务器证书**, **服务器的 HTTPS 证书不受信任或证书链不完整：请在系统中安装可信 CA 证书，或在服务器上配置受信任的完整证书链**, and **无法与服务器建立 HTTPS 安全连接：请检查服务器的 HTTPS 配置与证书**. If the first address only refuses the connection and a later address fails the certificate check, the certificate message is the one you see.
- A decoder is set aside only when decoding itself is the final failure. An ordinary playback error no longer disables that decoder for later titles.

Thanks to @o1xhack. Full changes: [android-v0.9.2 → android-v0.9.3](https://github.com/movieclaw/MovieClaw/compare/android-v0.9.2...android-v0.9.3).

---

## 简体中文

## Android 0.9.3：装了私有证书也能登录

装在手机上的 CA 会被信任，登录失败时会写明是哪种证书问题。这一版界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.9.2 相同。从 https://movieclaw.io/download/android.apk 安装。

### 修好了

- MovieClaw 信任装在设备上的 CA，也信任系统 CA。服务器用私有证书时，装上那张 CA 就能连。
- HTTPS 登录失败时会说明原因。原文是「服务器的 HTTPS 证书已过期：请在服务器上续期证书，并检查设备时间是否正确」「服务器的 HTTPS 证书与服务器域名不匹配：请使用证书对应的域名，或修正服务器证书」「服务器的 HTTPS 证书不受信任或证书链不完整：请在系统中安装可信 CA 证书，或在服务器上配置受信任的完整证书链」，以及「无法与服务器建立 HTTPS 安全连接：请检查服务器的 HTTPS 配置与证书」。第一个地址只是拒绝连接、后面的地址才是证书失败时，你会看到证书那一条。
- 只有解码本身是最终失败时，才会停用这个解码器。普通的播放失败不再让后面的片子都避开它。

感谢 @o1xhack。完整改动：[android-v0.9.2 → android-v0.9.3](https://github.com/movieclaw/MovieClaw/compare/android-v0.9.2...android-v0.9.3)。
