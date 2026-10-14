## Android 0.3.2: Glass surfaces and clearer AI conversations

A more immersive library detail page, glass controls and one AI composer across new and existing conversations.

### Highlights

#### Let the artwork set the scene

Library details now pick their background color from the artwork and blend the hero image into it. Glass tab bubbles and controls share the same material across discovery, library and detail pages. Artwork without a backdrop falls back to the poster for its color.

#### Start and continue conversations with the same controls

New and existing AI conversations share an input bar with image attachments, a model selector, thinking options and Send. You can start a conversation with images alone. Model and thinking choices stay saved between sessions and are reset when the selected option is no longer available.

Thinking and tool steps fold into a single process row, while media cards remain visible. Known skill commands appear as chips. Tap your message bubble to copy or rewrite it; rewriting puts the original message back in the input bar.

### More features and improvements

- **Sessions appear sooner**: A newly created conversation updates the session list immediately, without waiting for the old polling interval.
- **Consistent controls**: Top-bar buttons share their height and alignment; menus use a consistent opening animation.
- **Stable appearance settings**: Opening the Me page no longer makes the glass-tab setting briefly animate from an incorrect initial value.

### Fixed

- Detail pages no longer fall back to the same gray background when artwork uses a server-relative URL, and dark artwork keeps a visible background hue.
- AI reasoning no longer appears mixed into the reply text, and newly created conversations retry briefly if their transcript is not ready yet.

### Before you update

- The glass tab bubble can still appear dark after scrolling; this visual limitation does not prevent navigation.
- The AI attachment menu does not yet include a skill picker or typed `/` quick selection. Existing skill commands can still be used.

Thanks to @anlan-home for the Android improvements.

Full changes: [android-v0.3.1 → android-v0.3.2](https://github.com/movieclaw/MovieClaw/compare/android-v0.3.1...android-v0.3.2).

---

## 简体中文

## Android 0.3.2：玻璃质感，更清楚的 AI 对话

媒体库详情更沉浸，控件采用统一玻璃材质，新建与已有 AI 对话共用同一套输入框。

### 本版亮点

#### 让影片图片决定页面氛围

媒体库详情从图片中取背景色，主视觉渐变融入页面。发现、媒体库和详情页的玻璃标签气泡与控件采用统一材质，没有背景图的影片会从海报取色。

#### 新建对话和继续聊天，用同一套操作

新建与已有 AI 对话共用输入框，包含图片附件、模型选择、思考选项和发送按钮。只发图片也能开始对话。模型与思考选择会在不同会话间保存；选项不再可用时会自动重置。

思考与工具步骤折叠成一条过程记录，媒体卡片仍直接显示。已知的技能命令显示为标签。点自己的消息气泡可复制或改写，改写会把原文放回输入框。

### 其他新功能与改进

- **新会话及时出现**：创建对话后立即更新会话列表，无需等待轮询间隔。
- **控件更一致**：顶部按钮统一高度与对齐，菜单采用一致的展开动画。
- **外观设置更稳定**：首次进入「我的」不再让玻璃标签栏开关从错误的初始状态短暂跳动。

### 修好了

- 图片使用服务器相对地址时，详情页不再一律回落为灰色；较暗的图片也能保留可见的背景色调。
- AI 思考内容不再混进回复正文；新建会话的记录尚未准备好时会短暂重试。

### 升级须知

- 滚动后玻璃标签气泡仍可能偏暗，不影响导航操作。
- AI 附件菜单暂没有技能选择器，输入 `/` 的快捷选择也尚未提供；现有技能命令仍可使用。

感谢 @anlan-home 改进 Android 客户端。

完整改动见 [android-v0.3.1 → android-v0.3.2](https://github.com/movieclaw/MovieClaw/compare/android-v0.3.1...android-v0.3.2)。
