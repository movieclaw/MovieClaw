## Android 0.9.1: The right address with a VPN on

A system VPN that only proxies your traffic no longer sends MovieClaw to the home address first. Pulling down inside a few bottom sheets no longer closes them. The Android interface remains Chinese in this release.

> ✅ Works with MovieClaw Server 0.33.0 or later, the same as 0.9.0. Install from https://movieclaw.io/download/android.apk

### Fixed

- With a system VPN on, MovieClaw used to try the home address before anything had answered, so a proxy VPN looked like a tunnel home and the first requests waited. It now uses the public https address first. The home address is used only after it answers.
- Turning the VPN on or off, or switching from one VPN to another, picks an address again immediately.
- Pulling down inside **播出日历 (Air schedule)**, **全部分集 (All episodes)**, the option list in **刮削设置 (Scrape settings)**, or **清理设备 (Clean up device)** no longer closes the sheet or makes the list jump when it is already at the top. Drag the sheet header, tap the dimmed area, or press back to close it.

Full changes: [android-v0.9.0 → android-v0.9.1](https://github.com/movieclaw/MovieClaw/compare/android-v0.9.0...android-v0.9.1).

---

## 简体中文

## Android 0.9.1：开着 VPN 也走对地址

只做代理的系统 VPN，不再让 MovieClaw 先去连家里的地址。几张底部面板里往下拉，也不再把面板关掉。这一版界面仍是中文。

> ✅ 搭配 MovieClaw 服务器 0.33.0 或更新版本即可使用，与 0.9.0 相同。从 https://movieclaw.io/download/android.apk 安装。

### 修好了

- 开着系统 VPN 时，MovieClaw 会在任何地址应答之前就先试家里的地址，出国代理也被当成了回家的隧道，头一批请求一直在等。现在先用 https 外网地址。家里的地址要应答之后才改用它。
- 打开或关掉 VPN，或从一条 VPN 换到另一条，会立刻重新选地址。
- 在「播出日历」「全部分集」「刮削设置」的选项列表或「清理设备」里，列表已经到顶时再往下拉，不再把底部面板拖走，列表也不再上下跳。要关掉，拖面板头部、点外面的遮罩，或按返回键。

完整改动：[android-v0.9.0 → android-v0.9.1](https://github.com/movieclaw/MovieClaw/compare/android-v0.9.0...android-v0.9.1)。
