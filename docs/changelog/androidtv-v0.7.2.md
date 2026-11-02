## Android TV 0.7.2: Playback speed is in the panel

Press down and **倍速 (Speed)** is the fourth column. A CA installed on the TV is trusted. The Android TV interface remains Chinese in this release.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.7.1. Install from https://movieclaw.io/download/androidtv.apk

### Highlights

#### Speed sits in the fourth column

Press down during playback, or the remote's Menu key. The panel is **字幕 (Subtitles)**, **音轨 (Audio track)**, **画质 (Quality)**, and **倍速 (Speed)**. Menu closes the panel again. The steps are 0.5×, 0.75×, **正常 (Normal)**, 1.25×, 1.5×, and 2×, the same as on the phone. Moving into **倍速** lands on the speed you are using, not on 0.5×. A speed other than **正常** stays as a badge next to the remaining time. The choice is remembered for this title, including the next episode and the next time you open it. Another title starts at **正常**.

### Fixed

- MovieClaw trusts CAs installed on the device, as well as the system CAs. A server that uses a private certificate can be reached after you install that CA.
- A decoder is set aside only when decoding itself is the final failure. An ordinary playback error no longer disables that decoder for later titles.

Full changes: [androidtv-v0.7.1 → androidtv-v0.7.2](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.7.1...androidtv-v0.7.2).

---

## 简体中文

## Android TV 0.7.2：倍速在播放面板里

按下键，第四栏是「倍速」。装在电视上的 CA 会被信任。这一版界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.7.1 相同。从 https://movieclaw.io/download/androidtv.apk 安装。

### 本版亮点

#### 倍速是第四栏

播放时按下键，或遥控器的菜单键。面板是「字幕」「音轨」「画质」「倍速」。菜单键再按一次收起面板。档位是 0.5×、0.75×、「正常」、1.25×、1.5×、2×，和手机相同。移进「倍速」时落在当前档，而不是 0.5×。不是「正常」时，剩余时间旁边会留着这个档位。选择按这部片记住，下一集和再次打开都带着。换一部片从「正常」开始。

### 修好了

- MovieClaw 信任装在设备上的 CA，也信任系统 CA。服务器用私有证书时，装上那张 CA 就能连。
- 只有解码本身是最终失败时，才会停用这个解码器。普通的播放失败不再让后面的片子都避开它。

完整改动：[androidtv-v0.7.1 → androidtv-v0.7.2](https://github.com/movieclaw/MovieClaw/compare/androidtv-v0.7.1...androidtv-v0.7.2)。
