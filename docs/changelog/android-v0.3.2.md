## Android 0.3.2: A cleaner AI chat

AI assistant conversations now read like a chat instead of a log. Reasoning and tool calls fold into a single line, and you can pick the model before you ask. Library title pages also take their colour from the artwork.

> ⚠️ **Needs MovieClaw Server 0.33.0 or later.** Servers 0.31 and 0.32 are refused when you sign in. Download from https://movieclaw.io/download/android.apk and install it over the current app.

### Highlights

#### Long answers no longer bury the reply

One answer used to be spread across a stack of tool rows and raw reasoning. Now the steps before each reply fold into one line that sums them up. Tap it to see the details. While the assistant is working, that line shows what it is doing.

- Tap one of your own questions to copy it or to **Rewrite (改写)** it.
- Rewriting replaces that question and everything after it, then answers again. It isn't offered while a reply is running.
- Skills you call with `/skill:name` appear as a small tag on your question.
- Your questions now sit in a translucent bubble with larger text.
- Known: after you tap Rewrite, the question goes back into the input box with no marker and no cancel; to back out, leave the conversation. A rewrite keeps the original question's images, model and reasoning level, and drops images you add.

#### Pick the model and reasoning level before you ask

The input box on the conversation screen and on the New session screen now has a model button next to the image button. Pick a model there and, for models that support it, a **Reasoning (思维链)** level. Start a new chat from Me → Recent sessions → **New session (新会话)** (administrators only).

- If you never pick a model, the server's default AI model is used. The Default reasoning level lets the model decide how much to think.
- Your choice is remembered. A conversation that used a specific model keeps it; other conversations switch to your remembered model. A remembered reasoning level other than Default applies to every conversation you continue.
- The button only appears when the server has an AI model connected and the model list loads.
- Known: in an existing conversation, switching back to the default model or the Default level doesn't take effect; the conversation keeps its earlier setting. For now, start a new session.

### New features

- **Images in AI chat**: The New session screen can attach images too, and a first message can be images only. Each message takes up to 4 images.
- Known: your questions don't show their images, and a question with only images disappears from the conversation once the reply ends.
- Known: on the conversation screen, the strip of selected images appears twice; × on either one removes the image. Pressing Send on the keyboard while an image is uploading sends the message without it, so wait until "Uploading…" (上传中…) disappears.
- Known: on the New session screen, a failed send or image upload shows no message. Check that your images appear above the input box, that there are no more than 4, and that the server has an AI model connected (web app → Settings → **Model connections (模型接入)**). Then check the connection and tap send again.

### Improvements

- **Title pages in the artwork's colour**: In the library, a title's page now takes its background colour from the artwork, and the header image is taller. Titles without fanart use the poster's colour.
- **Bigger top-bar buttons**: Back, search and the other round buttons at the top are larger and easier to tap.
- **Glass tab bar**: With Me → Display & Appearance → **Glass tab bar (玻璃底栏)** turned on, the selected tab bubble bends the page under it like real glass (Android 13 or later). Top-bar buttons, filter chips and the collapsed tab button get a matching glass look. The switch is off by default.
- Known: with the Glass tab bar on, the selected tab bubble and the collapsed tab button can look darker after you scroll down Discover.
- **Smoother menus**: The source menu and filter panels on Discover now open with an animation instead of popping in.

### Fixed

- With a reasoning model, the model's full reasoning was merged into the reply text once the answer finished, or when you reopened the conversation.
- A question that used a skill showed up as a long block of the skill's instructions.
- Me → Recent sessions didn't update after you started a new session or finished a reply.
- With the Glass tab bar on, its switch played its animation by itself the first time you opened Me after starting the app.

### Before you update

- Servers 0.31.0 to 0.32.x are refused when you sign in or tap **Add account (添加账号)**, with a message asking you to update the server first in the web app under Settings → Update & Maintenance. Accounts already signed in keep working until you sign out or the sign-in expires.
- Servers 0.28 to 0.30 don't report a version, so this check doesn't stop them, but this app isn't supported on them. Older servers show **Server version too old (服务器版本过旧)**.
- Moving a server to the latest version needs a new Docker image; from 0.30 or earlier, even 0.33.0 does. Update & Maintenance tells you when an image update is required.
- Android builds are no longer attached to server releases. Get new versions from https://movieclaw.io/download/android.apk.
- The New session screen no longer has a **Start conversation (开始对话)** button. Send with the send button in the input box.

Thanks to @anlan-home. Full changes: [android-v0.3.1 → android-v0.3.2](https://github.com/movieclaw/MovieClaw/compare/android-v0.3.1...android-v0.3.2).

---

## 简体中文

## Android 0.3.2：AI 对话更清爽

AI 助手的对话读起来像聊天，不再像日志：推理和工具调用折成一行，提问前还能挑模型。媒体库的影片详情页也会换成剧照的颜色。

> ⚠️ **需要 MovieClaw 服务器 0.33.0 或更新版本。** 0.31、0.32 的服务器登录时会被拒绝。从 https://movieclaw.io/download/android.apk 下载，覆盖安装当前 App。

### 本版亮点

#### 长回答不再把回复淹没

以前一次回答会摊开一串工具行和原始推理。现在每条回复之前的步骤折成一行总结，点开能看细节。助手干活时，这一行会显示它正在做什么。

- 点自己的提问，可以复制，也可以**改写**。
- 改写会替换这条提问及其之后的全部对话，然后重新回答。回复进行中不提供改写。
- 用 `/skill:名字` 调用的技能，会以小标签显示在提问上。
- 你的提问改成半透明气泡，字也更大。
- 已知：点「改写」后，原提问会放回输入框，但没有改写标记，也没有取消键；想放弃，退出这个对话即可。改写会沿用原提问的图片、模型和思维链档位，改写时新加的图片会被丢掉。

#### 提问前挑模型和思维链档位

对话页和新会话页的输入框里，图片键旁边多了模型按钮。在这里选模型；模型支持时，还能选**思维链**档位。新对话从「我的 → 最近会话 → **新会话**」开始（仅管理员）。

- 没选过模型时，用服务器设定的默认 AI 模型。思维链档位选「默认」时，思考多少由模型自己决定。
- 选择会被记住。指定过模型的对话继续用那个模型，其余对话改用你记住的模型；记住的思维链档位只要不是「默认」，继续任何对话时都会用它。
- 服务器接入了 AI 模型、并且模型列表加载成功时，才会出现这个按钮。
- 已知：在已有的对话里改回默认模型或「默认」档位不会生效，对话仍沿用之前的设置。暂时可以新开一个会话。

### 新功能

- **AI 对话里的图片**：新会话页现在也能附图片，第一条消息可以只发图片。每条消息最多 4 张。
- 已知：提问气泡里不显示图片；只发了图片的提问，回复结束后会从对话里消失。
- 已知：对话页的已选图片条会显示两遍，点任意一条的 × 都能移除。图片还在上传时按键盘上的「发送」，消息会不带这张图发出，等「上传中…」消失再发。
- 已知：新会话页发送失败或图片上传失败时没有提示。请确认图片已出现在输入框上方、不超过 4 张，并且服务器已接入 AI 模型（网页「设置 → **模型接入**」），再检查网络后点发送。

### 体验改进

- **详情页换成剧照的颜色**：媒体库里影片的详情页，底色取自剧照，顶部大图也更高了。没有剧照的影片按海报取色。
- **顶栏按钮变大**：顶部的返回、搜索等圆形按钮更大，更好点。
- **玻璃底栏**：在「我的 → 显示与外观」打开**玻璃底栏**后，选中页签的气泡会像真玻璃一样折射下面的画面（需要 Android 13 或更新版本）。顶栏按钮、筛选胶囊和底栏收起后的圆钮也换成同一套玻璃质感。这个开关默认关闭。
- 已知：打开玻璃底栏时，在发现页往下滚动后，选中页签的气泡和收起后的圆钮可能看着偏暗。
- **菜单弹出更顺**：发现页的来源菜单和筛选面板改为带动画弹出，不再一下子闪出来。

### 修好了

- 使用会思考的模型时，回答结束后或重新打开对话时，整段推理混进回复正文的问题已修复。
- 用了技能的提问显示成一大段技能说明原文的问题已修复。
- 新建会话或聊完一轮后，「我的 → 最近会话」不更新的问题已修复。
- 开着玻璃底栏时，打开 App 后第一次进「我的」，开关会自己播一遍切换动画。这个问题已修复。

### 升级须知

- 0.31.0～0.32.x 的服务器在登录或**添加账号**时会被拒绝，并提示先在网页「设置 → 更新与维护」里升级服务器。已经登录的账号可以继续用，直到退出或登录过期。
- 0.28～0.30 的服务器不报版本号，这项检查拦不住，但本 App 不支持在上面使用；更早的服务器登录时会提示「服务器版本过旧」。
- 把服务器升到最新版需要更新 Docker 镜像；从 0.30 或更早升级，哪怕只升到 0.33.0 也要换。需要换镜像时，「更新与维护」会提示。
- Android 安装包不再随服务器版本一起发布。以后到 https://movieclaw.io/download/android.apk 下载新版。
- 新会话页不再有**开始对话**按钮；改用输入框里的发送键。

感谢 @anlan-home 的贡献。完整改动：[android-v0.3.1 → android-v0.3.2](https://github.com/movieclaw/MovieClaw/compare/android-v0.3.1...android-v0.3.2)。
