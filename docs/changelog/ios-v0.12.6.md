## iPhone and iPad 0.12.6: Back navigation keeps the composer clear on device

The composer now really stays above the glass tab bar during an edge-swipe back on iPhone. Playback also gains fixes for long sessions, image subtitles, picture-in-picture, and AirPlay seeking.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.12.5. This build is the unsigned IPA at https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.12.6. It is not on TestFlight.

### Fixed

- The composer lift shipped in 0.12.5 did not take effect during the real-device transition. It now moves the composer itself, so an edge-swipe back from an AI conversation or the new-conversation page keeps the composer above the returning tab bar. Cancelling the gesture puts it back without moving the message list.
- Leaving playback after a long session is less likely to pause the interface, rewinding no longer drops image subtitles in affected streams, picture-in-picture is more reliable on software-decoded video, and AirPlay audio recovers correctly after seeking.

Full changes: [ios-v0.12.5 → ios-v0.12.6](https://github.com/movieclaw/MovieClaw/compare/ios-v0.12.5...ios-v0.12.6).

---

## 简体中文

## iPhone 与 iPad 0.12.6：真机返回时，输入框会真正让开标签栏

iPhone 沿屏幕边缘滑回时，输入框现在会真正留在玻璃标签栏上方。播放也修正了长时间观看、图形字幕、画中画和 AirPlay 拖动后的问题。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.12.5 相同。这一版是未签名 IPA：https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.12.6。没有上传到 TestFlight。

### 修好了

- 0.12.5 的输入框抬升在真机返回转场里没有生效。现在会直接移动输入框；从 AI 会话或新会话页沿屏幕边缘滑回时，输入框会留在重新出现的标签栏上方。取消手势后会回到原位，消息列表不会跟着跳。
- 长时间观看后退出播放器时，界面卡顿的情况会减少；受影响的片源往回拖动时不会再丢图形字幕；软件解码视频的画中画更可靠；AirPlay 拖动进度后也能恢复声音。

完整改动：[ios-v0.12.5 → ios-v0.12.6](https://github.com/movieclaw/MovieClaw/compare/ios-v0.12.5...ios-v0.12.6)。
