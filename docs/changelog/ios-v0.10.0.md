## iPhone and iPad 0.10.0: Subscriptions that remember, addresses that follow you

Smart subscriptions now ask once whether you understand a language and remember how you like your quality. The app also picks your server's home or outside address on its own. Both need MovieClaw Server 0.42.0, released shortly after this app.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.9.2. Smart selection and switching addresses need Server 0.42.0; on an older server the subscribe sheet uses **Rules (规则模式)**. Install from TestFlight, or sideload the unsigned IPA from https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.10.0.

### Highlights

#### Subscriptions that don't grab what you can't watch

Smart selection could download a foreign release with no subtitles you can read. Now, the first time you subscribe to something in a new language, the subscribe sheet asks something like "这是英语片，要中文字幕吗？" and remembers your answer. Tap **Change quality (改画质)** to pick another quality, then choose whether that's for just this title (只这部) or for similar titles from now on. When only an unreadable release exists, the subscription waits for one with subtitles, and its page offers **Download the original this time (这次先下原版)**.

- Only administrators are asked and can change quality. Members see the plan without questions.
- Chinese counts as understood. A release qualifies when its subtitles or its audio are in a language you understand.
- Films and shows now share one set of settings: tap the smart selection summary to open **Smart settings (智能设置)**, which keeps separate waits for films and for each episode.
- The same page lists **Languages I understand (看得懂的语言)** and **Quality habits (画质习惯)**; you can add a language there, or remove one you added and any habit.
- A subscription waiting for subtitles shows 等字幕. After you download the original, administrators are asked whether they understand that language.

#### Your home address at home, your outside address away

The app used only the address you signed in with: sign in with your domain and even at home everything went out and back through it. Now the app picks the home or outside address by itself, and Me (我的) shows which one it's on under the server, such as "家里网络 · 192.168.1.10:3300" or "外网 · movie.example.com". It works on its own once the server is on 0.42.0.

- The server learns its addresses from the ones administrators use. An administrator can also add one on the web under Settings → Network → **Access addresses (访问地址)**.
- With only cellular data, the app doesn't try the home address. Over a VPN the line reads 外网（经 VPN）.
- Your sign-in is sent only to an address that proves it's your server.
- If you leave home during a film, the player may reconnect on the outside address and carry on.
- A download to the device that is interrupted when the address changes starts that file over.
- On older servers the app keeps using the address you signed in with, as before.

Full changes: [ios-v0.9.2 → ios-v0.10.0](https://github.com/movieclaw/MovieClaw/compare/ios-v0.9.2...ios-v0.10.0).

---

## 简体中文

## iPhone 与 iPad 0.10.0：订阅记得你，地址跟着你

智能订阅现在遇到一种语言只问一次看不看得懂，也会记住你的画质习惯。App 还会自己在服务器的家里地址和外网地址之间挑。两项都需要 MovieClaw 服务器 0.42.0，它会在这个 App 之后不久发布。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.9.2 相同。智能选择和自动换地址需要服务器 0.42.0；服务器较旧时，订阅弹层改用「规则模式」。从 TestFlight 安装，或从 https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.10.0 下载未签名 IPA 侧载。

### 本版亮点

#### 订阅不再抓看不懂的生肉

以前智能选择可能下到一个没有你看得懂字幕的外语版本。现在第一次订阅某种语言的作品时，订阅弹层会问一句，比如「这是英语片，要中文字幕吗？」，答过就记住。点「改画质」可以换一种画质，再选只改这一部（只这部）还是以后同类作品都这样。只有看不懂的原版时，订阅会等带字幕的版本，订阅页上有「这次先下原版」。

- 只有管理员会被提问、能改画质；成员只看到订阅方案，不会被提问。
- 中文默认算看得懂。字幕或音轨里有一种你看得懂的语言，这个版本就算合格。
- 电影和剧集现在共用一套设置：点智能选择那一栏进入「智能设置」，电影的等待上限和剧集每集的等待上限分开设。
- 同一页列出「看得懂的语言」和「画质习惯」，可以添加语言，也可以移除加过的语言和任何一条习惯。
- 在等字幕的订阅显示「等字幕」。先下了原版之后，会问管理员看不看得懂这种语言。

#### 在家走家里地址，出门走外网地址

以前 App 只用登录时填的地址：用域名登录的话，在家也要绕外网走一圈。现在 App 自己挑家里地址或外网地址，「我的」页的服务器下面会写出当前用的是哪个，如「家里网络 · 192.168.1.10:3300」或「外网 · movie.example.com」。服务器升级到 0.42.0 后自动生效，不用设置。

- 服务器从管理员用过的地址里自动记下地址。管理员也可以在网页的「设置 → 网络 → 访问地址」里手动添加。
- 只有蜂窝网络时不试家里地址。经 VPN 连回家时显示「外网（经 VPN）」。
- 登录凭据只发给证明了自己是你那台服务器的地址。
- 看片途中出门，播放器可能会改走外网地址重连、接着播。
- 下载到本机的视频如果因为换地址中断，这个文件会从头重下。
- 服务器较旧时，App 照旧只用登录时的地址。

完整改动：[ios-v0.9.2 → ios-v0.10.0](https://github.com/movieclaw/MovieClaw/compare/ios-v0.9.2...ios-v0.10.0)。
