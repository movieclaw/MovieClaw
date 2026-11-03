## Mac 0.12.1: The right address with a VPN on

A system VPN that only proxies your traffic no longer sends MovieClaw to the home address first. Playback of 24p video and disc images is updated from 0.11.0.

> ✅ Works with MovieClaw Server 0.31.0 or later, the same as 0.11.0. Download from https://movieclaw.io/en/download and replace the old app. The direct-download edition updates itself.

### Fixed

- With a system VPN on, MovieClaw used to try the home address before anything had answered, so a proxy VPN looked like a tunnel home and the first requests waited. It now uses the public https address first. The home address is used only after it answers. Under your account at the bottom of the sidebar, **External network (via VPN)** appears only then.
- Turning the VPN on or off, or switching from one VPN to another, picks an address again immediately.
- 24p video stays on the film frame grid.
- Playing a disc image no longer lets prefetch keep using more memory.
- The playback libraries include a fix for a published teletext vulnerability (CVE-2026-110654).

Full changes: [macos-v0.11.0 → macos-v0.12.1](https://github.com/movieclaw/MovieClaw/compare/macos-v0.11.0...macos-v0.12.1).

---

## 简体中文

## Mac 0.12.1：开着 VPN 也走对地址

只做代理的系统 VPN，不再让 MovieClaw 先去连家里的地址。相对 0.11.0，24p 和原盘的播放也更新了。

> ✅ 搭配 MovieClaw 服务器 0.31.0 或更新版本即可使用，与 0.11.0 相同。从 https://movieclaw.io/zh/download 下载，替换旧版 App。官网直装版会自己更新。

### 修好了

- 开着系统 VPN 时，MovieClaw 会在任何地址应答之前就先试家里的地址，出国代理也被当成了回家的隧道，头一批请求一直在等。现在先用 https 外网地址。家里的地址要应答之后才改用它。侧栏底部的账号下面，「外网（经 VPN）」也要到这时才出现。
- 打开或关掉 VPN，或从一条 VPN 换到另一条，会立刻重新选地址。
- 24p 的片子按电影帧格走。
- 播放原盘时，预取不再把内存越占越多。
- 播放所用的库修了一个已公开的图文电视漏洞（CVE-2026-110654）。

完整改动：[macos-v0.11.0 → macos-v0.12.1](https://github.com/movieclaw/MovieClaw/compare/macos-v0.11.0...macos-v0.12.1)。
