# changelog 写作指南

`docs/changelog/vX.Y.Z.md` 会原文成为 GitHub Release body，并在应用内「设置 →
更新与维护」一个约 256px 高的滚动框里展示。读者是自己部署 movieclaw 的普通用户，
他们读它来决定「要不要点更新、更新后去试什么」。它是**产品更新说明**，不是变更清单。

下面的规则来自 2026-09 对一批顶级产品真实发布说明的调研（Home Assistant、Jellyfin、
Infuse、Immich、Tailscale、Linear、Raycast、Things、Notion、Dia、Figma、Cursor、
Obsidian、Vercel、Telegram、flomo、滴答清单、Bear），括号里是出处，方便理解
「为什么这么写」。

## 多语言维护

- 每个版本只维护一份 `docs/changelog/<tag>.md`：应用用 `vX.Y.Z.md`，模型用
  `torrent-ner-vN.md`。同一份文件同步到同一个 GitHub Release，不按语言另建 Release。
- **英文在前，完整中文在后**，两段之间用 `---` 和 `## 简体中文` 分隔。使用纯 Markdown，
  不用 HTML 折叠区：GitHub 支持折叠，但当前应用内更新日志不解析 HTML。
- 两种语言讲同一组事实，修改功能、升级要求或已知限制时在同一个 PR 里同步修改两段，
  不把中文缩成摘要。翻译保留版本号、命令、文件名、URL、校验值和贡献者账号。
- 英文统一使用 `Highlights`、`More features and improvements`、`Fixed`、
  `Before you update`；正文沿用下面的场景写法。菜单译名要对应实际入口，必要时附中文名。
- 审核时对照两种语言的 Docker / 客户端升级要求、回退提醒、功能范围、数字与链接。
  `release-notes.yml` 只同步描述；调整语言不改标签、版本号、附件或发布状态。

## 一、先盘点，再取舍

1. **盘点（保证不漏）**：`git log --first-parent 上一个正式版tag..HEAD --oneline`
   （跳过 beta/rc；给已发布的版本补写时把 `HEAD` 换成本版 tag），以合并 PR 为单位
   过一遍区间内全部变更，拿不准的再看 diff。盘点结果只是素材，不是正文。
   **以上一个正式版为基准**：本周期内引入、又在本周期内修掉的问题（例如新功能刚合入
   就修的回归），用户从没遇到过，不写。判断方法：对照上一个正式版 tag 的代码，问题
   在那时存不存在。
2. **取舍（保证好读）**：挑 1～3 件本版最值得说的事当亮点，其余压成一行或一句带过；
   重构、CI、测试、文档这类用户感知不到的改动不写。完整清单交给文末的 compare 链接
   ——所有被调研的产品都是「精选叙事 + 完整清单另放」两层，没有一家把全部修复摊在
   正文里（HA 的 All changes、Jellyfin / Infuse 链到完整 notes、Dia 另设 changelog 页）。

## 二、结构

照这个顺序，没有内容的节直接省略：

```markdown
## vX.Y.Z: Release theme

One or two sentences about what users gain, mentioning the other highlights.

> ⚠️ **Action required**: What to do, where to do it, and what happens otherwise.
> (When unnecessary: ✅ No Docker image update is required. Update from Settings → Update & Maintenance.)

### Highlights

#### A benefit or user question

The situation → what is possible now → where to start, or that it applies automatically.

### More features and improvements

- **Benefit**: One sentence, with the entry point when needed.

(Split Features and Improvements when their combined count exceeds four.)

### Fixed

- The recognizable problem that no longer occurs.

### Before you update

- Database migration and rollback (only when applicable), limitations and replacement entry points.

Thanks to @someone. Full changes: [vA.B.C → vX.Y.Z](https://github.com/movieclaw/movieclaw/compare/vA.B.C...vX.Y.Z).

---

## 简体中文

## vX.Y.Z：本版主题

完整中文说明，保持与英文相同的事实、升级提示、功能范围和链接。
```

**第一屏**（主题标题 + 主题段 + 提示框 + 第一个亮点标题）必须能单独成立：用户只看
这一屏，也知道这版最重要的变化和要不要动手。

## 三、写法规则

1. **一期只推 1～3 个主角**，其余降级成一行。（Linear 每期 1～2 个主题，Notion 一个
   主题，Infuse 博客 3～4 个亮点，Dia 每期一个故事）

2. **给这一版起个名字**：标题写成「版本号：主题短语」，让这版有记忆点。
   （Raycast「v2.5 - 🔌 External Model Providers」，HA「2026.9: There's room on this bus」，
   Notion「3.7: Agent skills for your whole team」）

3. **亮点段落三拍：痛点 → 现在 → 入口**。
   - 先用一句话说用户以前遇到的处境（HA「What you couldn't see was why.」，
     Infuse「streaming the original file isn't ideal—especially when watching remotely」）。
   - 再说现在能做到什么，讲具体场景而不是讲机制。
   - 最后告诉用户从哪开始：菜单路径、按钮名（Linear「Type /callout to get started.」，
     Notion「Get started at Settings → …」，Infuse 专写「How to use transcoding」）。
     自动生效的就明说「升级后自动生效，不用设置」（HA「nothing changes and there is
     nothing you need to do」）——这句话本身就是在降低升级顾虑。
   - 入口路径要对照前端代码核实真实的菜单名，别凭印象写：设置分区名以
     `apps/web/lib/mock-data.ts` 为准；多套主题下路径不同时，按默认主题（银玻璃）写；
     顺带确认成员账号能不能看到这个入口，只有管理员能用的要注明「管理员」。

4. **标题讲好处或用户问题，不讲功能名**。
   ✅「在外面用 Infuse 看片，调低画质真的有用了」（HA「How full is your network storage?」，
   Things「Repeating To-Dos, Refined」，滴答「书写更简洁：……」）
   ❌「Jellyfin 客户端调低画质时真的会转码」
   例外：主角本身就是用户会在界面上看到的名字（如「Netflix 主题」），标题里要出现
   这个名字，否则用户对不上号——把它和好处写在一起即可（「一键换成 Netflix 的样子」）。

5. **修复写用户能认出来的症状，不写原因**：「在哪、做什么时、出了什么问题」，让遇到过的
   人一眼认出「就是我那个」。（Raycast「Fixed failing requests retrying in the background
   indefinitely during provider outages」，flomo「【修复】点击 Agent 推送返回对话时，
   页面反复跳转的问题。」）只单列用户大概率遇到过的，其余并成「以及 N 处细节修复」。
   ❌「修复若干问题」「优化产品体验」（微信、小红书的反例：什么都没说）
   **放「修好了」还是「体验改进」**：用户会说「坏了」的（报错、打不开、显示不出、
   点了没反应）放「修好了」；原本能用、只是不够好的（慢、糊、不顺手）放「体验改进」。

6. **需要用户动手的事：越危险越靠前，每条都能照做**。写清要执行的命令或菜单路径、
   不做会怎样。（Jellyfin 大版本把升级须知放在最顶部的 TL;DR 编号清单，
   Immich 大版本前置 How to update 并给出命令，Telegram 写全菜单路径）
   需要更新 Docker 镜像 / Mac Worker 放开头提示框；不需要时也写一行 ✅，
   自托管用户最怕的就是「这次要不要动容器」。
   数据库迁移只在**有迁移时**写回退提示；没有迁移时不写，也不要替用户担保
   「回退不用恢复备份」——兼容性判断出错的代价由用户承担。

7. **坦白边界**：已知限制、还没做完的、要下线的，一句话说清。只和某个亮点有关的，
   放在那个亮点段末尾（读者正读到这里）；影响全局的放「升级须知」。坦白反而增加信任。（Cursor「Rollouts does not merge or roll back on its
   own today.」，Infuse 的段末 Note，Dia「Retiring Memory」，Raycast「While there are no
   major new features…」）

8. **纯修复版不硬凑亮点**：主题直说「这是一个稳定性更新」，列 3～5 条用户能感知的修复
   即可，省掉「本版亮点」节。（Raycast v2.4、Bear 3.0 都坦白说明本版没有大功能）

9. **致谢外部贡献者**：区间内有核心维护者以外的人合入 PR，就在文末点名
   「感谢 @xxx 的贡献」。**以 GitHub 上 PR 的作者为准**；`git log --format='%an <%ae>'`
   只用来找线索（`…@users.noreply.github.com` 前的名字通常就是用户名，但用真实邮箱
   提交的外部贡献者会漏掉），拿不到 PR 信息时宁可只写能确认的人。开源项目靠这个留住贡献者。
   （HA 每条带「Thanks, @xxx!」，Immich 列 New Contributors，Dia「Shipped by Alexandra」）

10. **语气**：用「我们 / 你」，平实、具体。人格化点到为止——主题标题、一句结语可以有
    温度，正文保持朴素。（Obsidian 把修复节叫「No longer broken」，本项目对应「修好了」；
    Bear、flomo 都只用一句话建立个性）

## 四、不写什么

- **实现细节**：库名与版本号、runtime 编号、协议 / 容器 / 编码参数（MPEG-TS、AAC、
  `hvc1` 标签之类）、文件路径、配置项内部名、测量值。HEVC、4K、HDR、MKV 这类用户在
  文件名里天天见的词可以用。
- **故障原因分析与修复过程**：用户只关心现在好了没有。
- **空话和样板话**：「修复若干问题」「优化体验」「感谢您的使用，求五星好评」
  （滴答清单每版一字不差的致谢段占了全文一半）。
- **重复上一版的内容**。

## 五、篇幅与自检

- 每种语言分别控制在 50 行以内（含空行）；亮点之外的条目各不超过一行——指
  Markdown 源码一行、中文约 40 个汉字或英文一句话，不用分号硬塞第二件事。
- 写完只读第一屏：能不能让人想更新？知不知道要不要动手？
- 念给一个不写代码的朋友听：有没有哪句需要解释？每个亮点他知不知道去哪儿试？

样板见 `docs/changelog/v0.27.0.md`。
