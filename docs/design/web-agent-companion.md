# 网页 Agent 小幕（月夜伙伴 C）

网页新会话和已有会话复用 iPhone 的透明小鱼图集。`public/companions/moonlight.png` 与原生图片保持逐字节一致，单元测试检查这一点。

## 行为

- 72px 宠物绝对定位在输入框右上角，位于玻璃裁切层之外；不增加输入区高度，也不铺任何背景或透明遮罩。
- 待机每隔 8～14 秒眨眼；聚焦且有草稿时抬头一次并静止，点击可打招呼。
- 开始任务时出发并啃鱼一轮（啃鱼约 1.2 秒），随后抱鱼静坐；每隔随机 15～25 秒仅眨眼 0.25 秒，不反复啃鱼或移动身体。
- 真实轮次完成后短暂庆祝并回到待机；工具单独报错不会误判整个任务失败。用户主动停止回到待机。
- 错误和中断时低头一次，随后保留静态担忧；重新输入时抬头。重进历史会话不重复庆祝。
- 页面隐藏或系统减少动态效果时保持静态，恢复前台不重播啃鱼。卸载时取消计时器、清理可见性订阅；帧更新关在宠物组件内，不驱动消息列更新。

## 验证

`node --test test/agent-companion.test.mjs test/agent-activity.test.mjs` 检查真实轮次结果映射、运行优先级、模型不可用状态、图集同步与现有会话活跃时间口径。

浏览器测试使用真实网页、API、Agent、bash 工具和 SSE，仅模型使用本地确定性服务。数据库、工具工作目录和账号均属于隔离的验收环境，不连接用户片库。

从仓库根目录启动 API，再从 `apps/web` 启动独立网页服务：

```sh
.venv/bin/python apps/apple/scripts/agent-companion-lab.py
```

```sh
NEXT_DIST_DIR=.next-companion MOVIECLAW_API_PROXY_TARGET=http://127.0.0.1:18831 pnpm exec next dev --port 3093
```

然后从仓库根目录运行：

```sh
.venv/bin/python apps/web/scripts/test-agent-companion.py
```

覆盖桌面 Chromium、iPhone Safari 内核和减少动态效果：发送、工具执行、完成、历史重载、长时间安静等待与低频眨眼、主动停止、错误表情静止、重新输入和可见性恢复。验证有无宠物时输入区尺寸一致，并保存页面截图供人工检查透明边缘、裁切和落脚位置。

2026-10-14 验收结果：8 项相关单元测试、3 个浏览器端到端场景、TypeScript 检查、修改组件 lint 和 Next 生产构建通过。人工检查桌面玻璃输入框和 iPhone Safari 的透明边缘及脚底位置。截图与结果保存于 `/tmp/movieclaw-web-companion/`。本地预览为隔离测试环境，地址 `http://localhost:3093/new`；该预览不连接正式片库或模型。
