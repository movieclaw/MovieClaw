## iPhone and iPad 0.12.1: The right address with a VPN on

A system VPN that only proxies your traffic no longer sends MovieClaw to the home address first. The Discover title also stays put when its menu closes.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.12.0. Install the TestFlight build. The unsigned IPA is at https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.12.1

### Fixed

- With a system VPN on, MovieClaw used to try the home address before anything had answered, so a proxy VPN looked like a tunnel home and the first requests waited. It now uses the public https address first. The home address is used only after it answers. On **Me**, the line **External network (via VPN)** appears only then.
- Turning the VPN on or off, or switching from one VPN to another, picks an address again immediately.
- On **Discover**, the large title **Movie** or **Series** stays in place when you close its menu. It no longer shifts right and then slides back.

Full changes: [ios-v0.12.0 → ios-v0.12.1](https://github.com/movieclaw/MovieClaw/compare/ios-v0.12.0...ios-v0.12.1).

---

## 简体中文

## iPhone 与 iPad 0.12.1：开着 VPN 也走对地址

只做代理的系统 VPN，不再让 MovieClaw 先去连家里的地址。发现页的标题在菜单收起后也不再滑动。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.12.0 相同。请安装 TestFlight 构建。未签名 IPA 在 https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.12.1

### 修好了

- 开着系统 VPN 时，MovieClaw 会在任何地址应答之前就先试家里的地址，出国代理也被当成了回家的隧道，头一批请求一直在等。现在先用 https 外网地址。家里的地址要应答之后才改用它。在「我的」里，「外网（经 VPN）」也要到这时才出现。
- 打开或关掉 VPN，或从一条 VPN 换到另一条，会立刻重新选地址。
- 在「发现」里，大标题「电影」或「剧集」在菜单收起后留在原地，不再先偏到右边再滑回来。

完整改动：[ios-v0.12.0 → ios-v0.12.1](https://github.com/movieclaw/MovieClaw/compare/ios-v0.12.0...ios-v0.12.1)。
