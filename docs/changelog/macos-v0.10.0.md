## Mac 0.10.0: Your home address at home, your outside address away

The app now picks your server's home or outside address on its own, so a laptop that leaves the house keeps working without signing in again. It needs MovieClaw Server 0.42.0, released shortly after this app.

> ✅ Works with MovieClaw Server 0.31.0 or later, the same as 0.9.2. Switching addresses needs Server 0.42.0; on older servers the app keeps using the address you signed in with. Download from https://movieclaw.io/en/download and replace the old app.

### Highlights

#### The right address wherever you open your laptop

The app used only the address you signed in with: sign in with your domain and even at home everything went out and back through it; sign in with a home address and nothing worked once you left. Now the app picks the home or outside address by itself. Click your account at the bottom of the sidebar to see which one it's on, such as "家里网络 · 192.168.1.10:3300" or "外网 · movie.example.com". It works on its own once the server is on 0.42.0.

- The server learns its addresses from the ones administrators use. An administrator can also add one on the web under Settings → Network → **Access addresses (访问地址)**.
- The app checks again when the network changes and when the Mac wakes from sleep. Over a VPN the line reads 外网（经 VPN）.
- Your sign-in is sent only to an address that proves it's your server.
- If the network changes during a film, the player may reconnect on the other address and carry on.

Full changes: [macos-v0.9.2 → macos-v0.10.0](https://github.com/movieclaw/MovieClaw/compare/macos-v0.9.2...macos-v0.10.0).

---

## 简体中文

## Mac 0.10.0：在家走家里地址，出门走外网地址

App 现在会自己在服务器的家里地址和外网地址之间挑，笔记本带出门也照常能用，不用重新登录。需要 MovieClaw 服务器 0.42.0，它会在这个 App 之后不久发布。

> ✅ 搭配 MovieClaw 服务器 0.31.0 或更新版本即可使用，与 0.9.2 相同。自动换地址需要服务器 0.42.0；服务器较旧时，App 照旧只用登录时的地址。从 https://movieclaw.io/zh/download 下载，替换旧版 App。

### 本版亮点

#### 笔记本在哪打开，都连对地址

以前 App 只用登录时填的地址：用域名登录的话，在家也要绕外网走一圈；用家里地址登录的话，出了门就连不上。现在 App 自己挑家里地址或外网地址。点侧边栏最底下的账号，可以看到当前用的是哪个，如「家里网络 · 192.168.1.10:3300」或「外网 · movie.example.com」。服务器升级到 0.42.0 后自动生效，不用设置。

- 服务器从管理员用过的地址里自动记下地址。管理员也可以在网页的「设置 → 网络 → 访问地址」里手动添加。
- 网络变化、Mac 从睡眠中唤醒时，App 会重新判断一次。经 VPN 连回家时显示「外网（经 VPN）」。
- 登录凭据只发给证明了自己是你那台服务器的地址。
- 看片途中换了网络，播放器可能会改走另一个地址重连、接着播。

完整改动：[macos-v0.9.2 → macos-v0.10.0](https://github.com/movieclaw/MovieClaw/compare/macos-v0.9.2...macos-v0.10.0)。
