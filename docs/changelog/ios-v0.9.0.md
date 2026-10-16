## iPhone and iPad 0.9.0: A real iPad app

MovieClaw now runs as a proper iPad app instead of an enlarged iPhone app, with a sidebar, larger title pages and free rotation. On iPhone, the Me tab is reorganized, and the AI chat lets you pick a model, search the web and keep you company while it works.

> ✅ Works with MovieClaw Server 0.28.0 or later, the same as 0.8.0. ChatGPT plan models and web search need Server 0.39.0 or later, which requires a Docker image update; on older servers they don't appear. Install from TestFlight, or sideload the unsigned IPA from https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.9.0.

### Highlights

#### Your library, laid out for the bigger screen

On iPad the app used to run in iPhone compatibility mode: a narrow window with phone-sized posters. Now it fills the screen and works in any orientation, Split View and Stage Manager. Update and open it on your iPad.

- A sidebar lists Home, Favorites, Subscriptions, Discover, Activity and Me, plus every library and your home collections. Each keeps its own place as you switch.
- Title pages use the Mac layout: a full-width backdrop with the title, details and actions at the bottom left and the cast at the bottom right.
- Posters have one width across home rows and walls, and sheets open as centered panels.
- The player follows how you hold the iPad. There is no rotate button, and Back always leaves the player.
- To switch accounts on iPad, use the people button (切换账号) at the top right of Me.
- In Split View or a narrow window, pages fall back to the iPhone layout.

#### Pick a model before you ask

Starting a chat from the Me tab used whatever model you last picked on the new-conversation page, with no way to change it there. Now administrators can tap the small input box on Me to expand it: a model button below it lets you choose the model and its **Thinking strength (思维链强度)** for the new conversation, and your choice is remembered. If the server has a ChatGPT plan connected, its models are listed too.

- ChatGPT plans are connected on the web; on iPhone they show as read-only under **Model Providers (模型接入)**.
- Administrators can connect web search from Me → Server → Server settings → AI Settings → **Web search (网页搜索)**: choose Tavily, Exa or Brave Search, paste the key and tap the ✓ button (验证并保存).

### More features and improvements

- **A reorganized Me tab**: Switch between **Conversations (会话)**, **Downloads (下载)** and **Server (服务器)** at the top; each appears only when it applies to your account. Downloads are managed right there, and conversations are grouped into Today, Yesterday and Earlier. **Server settings (服务器设置)** and pending notices now live under Server, and the download settings gear sits next to **Downloaded (已下载)**.
- **Xiaomu (小幕)**: a small moonlit cat sits by the chat box (administrators) and reacts while a task runs. It stays still with Reduce Motion on.
- **Smoother chats**: Long conversations no longer jump around when the keyboard opens or closes, and the typing and progress animations use less power.

### Fixed

- Some films marked Dolby Vision but carrying an HDR10 picture (often "DV HDR10+ Hybrid" releases) played with a purple or green tint. They now play in correct HDR10 colors, including original-quality downloads. Playing at a lower quality, or smaller-quality downloads, needs Server 0.39.0; copies converted by an older server keep the tint, so download them again after updating the server.

Thanks to @o1xhack. Full changes: [ios-v0.8.0 → ios-v0.9.0](https://github.com/movieclaw/MovieClaw/compare/ios-v0.8.0...ios-v0.9.0).

---

## 简体中文

## iPhone 与 iPad 0.9.0：真正的 iPad 版来了

MovieClaw 现在是一个真正的 iPad App，不再是放大的 iPhone App：有侧边栏、更大的详情页，横竖屏随意转。iPhone 上「我的」页重新整理，AI 对话可以选模型、上网搜索，还多了个陪伴的小家伙。

> ✅ 搭配 MovieClaw 服务器 0.28.0 或更新版本即可使用，与 0.8.0 相同。ChatGPT 订阅的模型和网页搜索需要服务器 0.39.0 或更新版本（这个服务器版本需要更新 Docker 镜像）；旧服务器上不会出现这些入口。从 TestFlight 安装，或从 https://github.com/movieclaw/MovieClaw/releases/tag/ios-v0.9.0 下载未签名 IPA 侧载。

### 本版亮点

#### 片库在大屏上铺开了

以前 iPad 上跑的是 iPhone 兼容模式：窗口窄，海报还是手机尺寸。现在铺满整个屏幕，横竖屏、分屏和台前调度都能用。更新后在 iPad 上打开即可。

- 侧边栏列出首页、我的收藏、订阅、发现、活动和我的，以及每个媒体库和首页合集；来回切换时各自停在原来的位置。
- 详情页用 Mac 版的布局：背景图铺满，片名、信息和操作在左下，演职员在右下。
- 首页各行和海报墙的海报一样宽；弹层改为居中的面板。
- 播放器跟随你拿 iPad 的方向，没有旋转按钮，点返回直接退出播放。
- iPad 上切换账号，用「我的」页右上角的人像按钮（切换账号）。
- 分屏或窗口较窄时，页面会退回 iPhone 版式。

#### 提问前先选好模型

以前从「我的」页发起对话，只能沿用新会话页上次选的模型，没法当场换。现在管理员点一下「我的」页的小输入框展开，下方有模型按钮，可以为这次新对话选模型和「思维链强度」，选择会记住。服务器接入了 ChatGPT 订阅时，它的模型也会列出来。

- ChatGPT 订阅在网页上接入；iPhone 的「模型接入」里只能查看，不能修改。
- 管理员可以在「我的 → 服务器 → 服务器设置 → AI 设定 → 网页搜索」接入搜索：选 Tavily、Exa 或 Brave Search，粘贴 Key，点 ✓（验证并保存）。

### 其他新功能与改进

- **「我的」页重新整理**：顶部在「会话」「下载」「服务器」之间切换，只显示你这个账号用得上的。下载直接在这里管理，会话按今天、昨天、更早分组。「服务器设置」和待处理提醒移到了「服务器」里，下载设置的齿轮在「已下载」标题旁。
- **小幕**：对话框旁多了一只月夜小猫（管理员），任务进行时会有动作。系统开启「减少动态效果」时它保持静止。
- **对话更顺**：长对话在键盘弹出、收起时不会再上下跳，输入中和进度动画也更省电。

### 修好了

- 部分标着杜比视界、实际是 HDR10 画面的片子（常见于「DV HDR10+ Hybrid」版本）播放时整片偏紫或偏绿的问题已修复，现在按正确的 HDR10 颜色播放，已下载的原画副本也一样。调低画质播放和低画质下载需要服务器 0.39.0；旧服务器转出的副本仍偏色，升级服务器后重新下载即可。

感谢 @o1xhack 的贡献。完整改动：[ios-v0.8.0 → ios-v0.9.0](https://github.com/movieclaw/MovieClaw/compare/ios-v0.8.0...ios-v0.9.0)。
