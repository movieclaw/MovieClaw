# 模型目录与可选模型发现

| 项 | 内容 |
|---|---|
| 状态 | 一期（后端 + 对话框兼容）已实现；Q-1～Q-4 按建议定案（2026-10-30）；二期 Web 管理界面待做 |
| 日期 | 2026-10-30 |
| 关系 | 扩展 `llm-multi-provider.md`（§3 的「端点上报的模型不进清单」由本文 §6 取代，§4 的引用规则由本文 §7 调整）；思考档位沿用 `agent-thinking-level.md` 的词汇与翻译 |
| 参考 | finx《模型目录与发现方案》v1.0（同一思路在桌面智能体上的落地，本文按服务端形态取舍） |

## 摘要

**问题**：可选模型完全来自手写的 yaml 预设（5 家共 43 条）和用户补录。新模型要等发版；
目录外的模型即使端点能用也选不了；自定义端点必须逐个手填上下文窗口和输出上限才能接入。

**做法**：拆成两件事。

1. **有哪些模型**——问服务商：用实例自己的 `/models` 接口查列表，存在实例上，每天刷新。
2. **每个模型的参数**——查公共目录 [models.dev](https://models.dev/api.json)，再叠加
   我们自己的 yaml 修正和用户补录，按字段合并。

**进菜单的规则**：参数已知、是对话模型、能调工具、没停用。预设收录的模型照常显示；列表里的其它
模型，比预设里最新的还新才默认出现（没有预设的实例取最新 12 个）；用户可以逐个显示/隐藏。
菜单外的模型照常可路由。

**一句话收益**：加了 Key 就有最新、带参数的模型可选；OpenRouter / 硅基流动 / 火山这类
端点不必再手填参数；新增预设只写端点和方言，不再手抄模型表。

## 1. 现状

| 环节 | 现在的做法 | 问题 |
|---|---|---|
| 模型从哪来 | `providers/presets/*.yaml` 手写目录 ∪ 实例 `extra_models`（`provider_catalog`、`LlmRouter._catalog`） | DeepSeek 4 条、Kimi 4 条、GLM 8 条、OpenAI 7 条、百炼 20 条；models.dev 上同五家分别是 4 / 6 / 17 / 51 / 80 条（含少量非对话模型） |
| 是否最新 | 每条 yaml 注释写「核实于 2026-10-13」，人工维护 | 上新、下线、改参数都要发版 |
| 端点列表 | 验证通过后 best-effort 调 `models.list()` 存进 `available_models` | 只当设置页补录提示，**不进清单**（没有参数，选了会让自动压缩和思考菜单失效） |
| 自定义端点 | `openai_compat` 必须手填每个模型的 `context_window` / `max_output_tokens` 才能保存 | 接一个中转要填一堆数字；已有「借用其它预设目录同 id 模型参数」的特例 |
| ChatGPT 订阅 | 验证时把账号模型目录写进 `extra_models` | 和用户补录混在一层，以后账号目录更新会被旧值盖住 |
| 菜单 | `GET /llm/models` 列出所有实例目录的全部模型 | 目录变大后菜单会被撑爆（百炼列表上百个） |

## 2. 目标与非目标

**目标**

- G1 跟官方一致：菜单里是服务商现在真正提供的模型，新模型不等发版。
- G2 参数可靠：上下文窗口、输出上限、思考方言、图片输入、价格有权威来源，并能逐字段修正。
- G3 不打扰：加 Key 即可用；大目录不撑爆菜单；离线/上游挂掉时一切照旧。
- G4 不变量不破：**菜单里的模型一定有参数、一定能路由**（`llm-multi-provider.md` §3 的初衷）。
- G5 安全：Key 只发给实例自己的端点；外来列表与目录一律当不可信数据校验。

**非目标**：不做模型评测/推荐；不自动替换会话正在用的模型；不做按用量计费（价格只存不算，§13）。

## 3. models.dev 实测

2026-10-30 下载 `https://models.dev/api.json`：

- 5.95 MB，Cloudflare 托管，带 `ETag`（`cache-control: max-age=0, must-revalidate`，适合条件请求），
  233 家服务商、8925 条模型；
- 我们五个预设对应：`deepseek`、`openai`、`alibaba-cn`（百炼）、`moonshotai-cn`（Kimi）、`zhipuai`（GLM）。
  每家的 `api` 字段就是我们预设里的 base_url（OpenAI 除外，用 SDK 默认）；
- 国内常见 OpenAI 兼容端点也都有：`siliconflow-cn`、`volcengine`、`stepfun`、`minimax-cn`、
  `openrouter`、`ollama-cloud`……共 194 家声明为 OpenAI 兼容。

模型字段与我们 `ModelInfo` 的对应（只投影下表字段，其余丢弃）：

| models.dev | `ModelInfo` | 说明 |
|---|---|---|
| `limit.context` / `limit.output` / `limit.input` | `context_window` / `max_output_tokens` / `max_input_tokens` | `input` 只有 1717 条有 |
| `tool_call` | `supports_tools` | false → 资格过滤（§6.1） |
| `reasoning_options` | `thinking_control` / `max_thinking_tokens` | 推导规则 §5.3 |
| `interleaved`（`{"field":"reasoning_content"}` 等） | `supports_thinking`；提示 `compat.thinking_field` | 有它才说明思考内容走 API 字段返回，与我们 `supports_thinking` 语义一致（OpenAI 无此字段 → false，和现有 yaml 相同） |
| `temperature: false` | `fixed_sampling: true` | Kimi K3/K2.6 两边一致 |
| `modalities.input` | `modalities`（只保留 text / image / video） | |
| `modalities.output` 不含 text、`type` ∈ embedding/image/video/speech/transcription/reranking/realtime | 资格过滤 | |
| `status: deprecated` | `deprecated`（新增） | alpha / beta 照常 |
| `release_date` | `released`（新增） | 默认显示排序用 |
| `name` | `display_name`（新增） | |
| `cost.input/output/cache_read/cache_write` | `cost`（新增，USD/百万 token） | `tiers`、`context_over_200k` 一期不用 |

**与手写预设的吻合度**（逐条比对重叠的 37 条）：上下文/输出上限在 DeepSeek、GLM、OpenAI、Kimi 上基本
一致；按 §5.3 规则推导出的思考控制有 **26/37 条与 yaml 完全相同**。不一致的 11 条集中在两处：百炼上托管的
第三方模型（DeepSeek/Kimi/GLM 在百炼上的思考方言与官方不同）和 GLM 5.2 / 4.7。这些恰好是 yaml 修正层
该管的事——说明「公共目录兜底 + 少量手写修正」可行。

## 4. 总体设计

```
                  ┌──── 构建时 ────┐
 models.dev ─每周─▶ 同步脚本 → 投影快照（入库，PR 人工审阅）──打包进镜像──┐
                  └───────────────┘                                     ▼
 models.dev ─每天（ETag）─▶ data/cache/llm-catalog/*.json ──────▶ 公共目录（逐家取较新者）
                                                                        │
 实例 /models ─保存、每天、手动─▶ llm_provider.model_listing ──┐          │
                                                              ▼          ▼
                     yaml 修正、实例 extra_models ──────▶ 按字段合并（movieclaw_llm.catalog）
                                                              │
                     llm_provider.model_visibility ──────────▶ 显示规则 → GET /llm/models
                                                              │
                                                              └──▶ LlmProviderConfig.catalog → LlmRouter
```

| 模块 | 职责 | IO |
|---|---|---|
| `movieclaw_llm/catalog.py`（新） | models.dev 投影、思考控制推导、五层合并、资格与默认显示判定 | 无（纯函数，便于测试） |
| `movieclaw_llm/providers/catalog/*.json`（新） | 随包分发的投影快照 | — |
| `movieclaw_api/services/llm_catalog.py`（新） | 拉 models.dev、读写本地缓存、刷新实例列表、每日任务 | 走 `egress_transport("llm")` |
| `services/llm_config.py`（改） | `provider_catalog` / `build_model_options` / `to_domain_config` 改用合并结果 | |
| `LlmRouter`（小改） | `_catalog` 读 `config.catalog`（由应用层注入），不再自己拼 yaml | |
| `scripts/sync_model_catalog.py` + 每周 Action（新） | 生成快照与变化报告 | |

领域库保持无 IO：合并后的完整目录作为 `LlmProviderConfig.catalog` 注入，路由、思考翻译、自动压缩
都只认这一份。`acquire_llm_router` 的配置指纹自然包含目录，目录变化即重建路由（与现在换 Key 一致）。

## 5. 模型的参数

### 5.1 五层来源（按字段合并，上层覆盖下层）

| 顺序 | 来源 | 典型内容 |
|---|---|---|
| 1 | 实例 `extra_models`（用户补录） | 私有模型、用户对某个字段的修正 |
| 2 | 预设 yaml 的模型条目（内置修正） | 公共目录没有的字段（`max_tokens_parameter`、`requires_responses_for_tools`、`default_output_tokens`…）、公共目录不对的值、推荐顺序 |
| 3 | 列表响应自带的参数 | OpenRouter 的 `context_length` / `top_provider.max_completion_tokens` / `pricing`；ChatGPT 账号目录 |
| 4 | 公共目录（实例的 `catalog_id` 那一家） | 大多数字段 |
| 5 | 默认值 | `ModelInfo` 现有默认（上下文/输出为 None） |

- 按字段合并，与现在 `extra_models` 覆盖预设「按 id 整条覆盖」不同：上层只写了 `context_window`，其余字段仍取下层。
  **兼容处理**：现有 `extra_models` 都是整条写的，按字段合并对它们结果相同。
- `known` = 合并后有 `context_window`，或者是预设/补录的模型（策展过的、用户明说的）。下游真正依赖的
  只有上下文窗口（自动压缩），输出上限 Kimi K2 系官方都没公布，不拿它卡；G4 不变量由此成立：只有
  `known` 的模型能进菜单（§6.2）。
- 来源记在 `ModelInfo.sources`（新增，如 `["preset","models.dev"]`），管理界面展示、排查用，不参与逻辑。

### 5.2 实例到公共目录的对应（`catalog_id`）

- 预设新增字段 `catalog_id`：`deepseek→deepseek`、`openai→openai`、`bailian→alibaba-cn`、`kimi→moonshotai-cn`、`glm→zhipuai`。
- `openai_compat` 实例新增列 `llm_provider.catalog_id`（可空）：保存时按 base_url 与 models.dev 各家的 `api`
  归一化比对自动识别（填 `https://api.siliconflow.cn/v1` 即识别为 `siliconflow-cn`），表单里可改为别的家或「不使用」。
- 只在 `catalog_id` 指定的那一家里找，不跨家借用——同一 id 在不同服务商下参数可能不同
  （例：百炼上的 `deepseek-v4-pro` 输出上限 384000，官方 393216）。
- **例外：没有 `catalog_id` 的兼容端点**（自建中转、反代）按 id 在「原厂目录」里借用：`openai`、`anthropic`、
  `google`、`deepseek`、`moonshotai-cn`、`zhipuai`、`alibaba-cn`、`xai`，取第一个精确命中，来源记 `borrowed`。
  这是现有 `_assert_model_configured`「借用其它预设目录同 id 参数」规则的延续，只是借用面从 yaml 扩到原厂目录。

### 5.3 思考控制的推导

models.dev 一个模型可能同时给出多种方式（例：百炼 `qwen3.8-max` 是 toggle + effort + budget_tokens）。
具体发哪种字段取决于**服务商的线协议**，所以由预设声明偏好：

```yaml
# 预设新增
thinking:
  prefer: [effort, toggle]            # 依次取 reasoning_options 里第一个出现的方式
  off_body: {thinking: {type: disabled}}   # 关闭思考的请求体（服务商级默认，模型级 off_body 可覆盖）
```

| 预设 | `prefer` | `off_body` |
|---|---|---|
| deepseek / glm / kimi | effort, toggle | `{thinking: {type: disabled}}` |
| openai | effort | 无（`reasoning_effort: none`） |
| bailian | budget_tokens, effort, toggle | 无（`enable_thinking: false`） |
| openai_compat | effort, budget_tokens, toggle | 无 |

推导：

- **effort**：`kind=effort`，`levels` = values 去掉 `none`（我们的词汇表已含 xhigh/max，原词直用，无需映射）；
  `supports_off` = values 含 `none`，或同时有 toggle 且服务商声明了 `off_body`。
- **budget_tokens**：`kind=budget`，`max_thinking_tokens` = `max`；`supports_off` = 有 toggle 或 `min == 0`。
- **toggle**：`kind=toggle`，`supports_off=true`。
- 都没有：`thinking_control=None`（fail-closed，无菜单，和现在一致）。

yaml 和用户补录写了 `thinking_control` 时以它们为准（§5.1）。上面的 26/37 吻合就是按这张表算的。

### 5.4 价格

- models.dev 价格一律 USD/百万 token，投影时记 `currency: USD`；为 0 视为未知。
- yaml 可写官方人民币价并带 `currency: CNY`；价格与币种必须取自同一层，不混用。
- 一期只存只展示（管理界面），不做费用累计。

## 6. 有哪些模型、哪些进菜单

### 6.1 实例的列表

- **请求**：沿用各协议现有的 `test_connection()`（OpenAI SDK `models.list()`，已走 `llm` 出口），
  结果从 `list[str]` 扩为带可选参数的条目：OpenRouter 解析 `context_length` 等（§5.1 第 3 层）。
  ChatGPT 订阅的账号目录带账号上报的能力与可见性，一期仍写在补录层，不走列表。
- **校验**：单家最多 5000 条；id 必须 1–256 字节可打印、无空白；不合格条目丢弃，其余照收；去重保序。
- **存储**：`llm_provider` 新增 JSON 列 `model_listing`：

  ```json
  {"fetched_at": "2026-10-30T09:12:00", "source": "provider", "error": null,
   "models": [{"id": "deepseek-flash"}, {"id": "x/y", "context_window": 131072}]}
  ```

  `source`：`provider`（列表成功）/ `unsupported`（404/405，端点没有列表接口）/ `none`（从未成功）。
  `available_models` 仍同步写 id 数组，旧客户端不受影响。
- **失败退路**：有旧列表继续用并记 `error`；从没成功过时，可选模型 = 预设 yaml 条目 ∪ `extra_models`（即现状）。
  公共目录**不**替代列表——不知道账号能不能用的模型不进菜单。实例的连接测试模型无论如何都在候选里
  （兼容端点可以只填一个公共目录查得到的测试模型就接入，端点没有列表接口时它也不会消失）。
- **何时刷新**：

  | 时机 | 行为 |
  |---|---|
  | 新增/编辑实例 | 现有验证流程（`verify_llm_provider`）里，对话 ping 通过后拉列表——已有这一步，只是改为写 `model_listing` |
  | 定时任务 `llm_catalog_refresh` | 对每个实例，列表超过 24 小时就刷新；同时最多 4 个；在调度页可见可停 |
  | 手动 | 设置页「刷新列表」→ `POST /llm/providers/{id}/models/refresh` |

### 6.2 资格过滤与默认显示

**资格**（不满足的不进 `GET /llm/models`，管理界面也不列）：models.dev 判定为非对话模型（§3 表）、
或明确 `tool_call: false`、或当前协议调不了工具（现有 `requires_responses_for_tools` 规则）。
公共目录查不到的不过滤，作为「参数未知」列在管理界面。

**候选集合**：列表成功时 = 列表里的模型 ∪ 预设 ∪ `extra_models` ∪ 连接测试模型；否则 = 预设 yaml
条目 ∪ `extra_models` ∪ 连接测试模型。预设 yaml 里有、但成功的列表里没有的模型，标「列表未包含」。

**默认显示**（`shown`）：

1. 补录的模型总是显示；
2. 预设模型：已知、未 `deprecated` 就显示——「列表未包含」也照常显示：各家 `/models` 是否列全还没
   逐家实测（Q-6），列表漏一个就把升级前菜单里的模型藏掉代价太大，真下线的交给 yaml 修正与停用标记；
3. 其余模型（列表里有、预设没收录）：已知、未停用，并且**比预设里最新的模型还新**（新出的模型自动出现，
   老旧型号不刷屏），最多 12 个；没有预设的实例（兼容端点、聚合服务商）取发布日期最新的 12 个。
   排序：预设按 yaml 顺序在前（旗舰在前的约定保留），其余按 `released` 新→旧、同日按 id，无日期垫底。

另外 AI 设定引用的模型**总是显示**（用户隐藏了也显示，否则设置页下拉框里找不到当前值）。

升级实测（旧版建库 → 新版启动）：菜单里只少了百炼上的 `deepseek-v4-flash`，公共目录标它已停用，
`?all=true` 里照常可选。

**用户调整**：`llm_provider.model_visibility` 列存 `{"show": [...], "hide": [...]}`，只存改过的；
最终 = （默认显示 ∪ show）− hide。新出的模型仍按默认规则出现，隐藏过的不会因刷新冒出来。
「参数未知」的模型要显示，必须先补参数（管理界面里直接展开现有的补录表单，预填列表/公共目录已知的字段）——
G4 不变量靠这一步守住，而不是像 finx 那样用 128K 默认值顶上（本地小模型 8K–32K 上下文，顶默认值会让自动压缩失效、请求直接超限）。

### 6.3 菜单外的模型照常能用

列表与显示只影响菜单。路由用的是**完整合并目录**（候选集合 ∪ 预设 ∪ `extra_models`），所以：
会话正在用的模型、AI 设定引用的模型、`实例名/模型id` 显式写的模型，即使隐藏、停用、已从列表消失，都照常解析和调用。
真调用时服务商说模型不存在，按普通请求错误返回（二期加「此时自动刷新这家的列表」）。

## 7. 模型引用的拼写（需要拍板，见 Q-1）

现在的规则：同 id 只在一个实例里有 → 引用是裸 id；多个实例都有 → `实例名/模型id`。目录静态时没问题，
**目录变成动态后会漂移**：比如用户接了 GLM 和百炼，字幕默认存的是裸 `glm-5.3`；某天百炼列表也出现了
`glm-5.3`，裸引用仍能解析，但会按「默认实例优先」路由到百炼——用户什么都没动，字幕就换了服务商。

建议：

- 清单里的 `ref` **一律** `实例名/模型id`；展示文案不变（冲突时才加括号）。客户端把 `ref` 当不透明串，无需改。
- 裸 id 继续接受（API/CLI 兼容），解析规则不变。
- 升级迁移把 AI 设定里存的裸引用改写成限定形式（按当时唯一的归属实例）；每次列表/目录刷新后也跑一遍现有的 `reconcile_defaults`。
- 实例改名时 `reconcile_defaults` 已会改写设定；会话转录里的旧名引用加一条兜底：前缀不是任何实例名时，
  按整串、再按斜杠后半段走裸 id 解析，而不是直接报「找不到实例」。

## 8. 推荐默认与连接测试模型

`recommended_default` 和 `default_model`（连接测试模型）现在取「目录第一个」。改为：候选集合里第一个
出现在预设 yaml 中、未停用的模型（即 yaml 声明的旗舰）；没有就取默认显示排序的第一个。
`openai_compat` 实例保存时的测试模型：`known`（任意一层有参数即可）就不再要求手填参数——这是自定义端点
最大的痛点；查不到参数的仍要求补录（现有校验保留）。

## 9. 公共目录的分发与刷新

### 9.1 随包快照

- `scripts/sync_model_catalog.py`：下载 api.json → 只取需要的家 → 按 §3 表投影 → 写
  `src/movieclaw_llm/providers/catalog/<catalog_id>.json`（键排序、固定格式，diff 可读），外加一份
  全部 233 家的 `{id, name, api}` 索引（供 §5.2 base_url 识别）。
- 收录范围：五个预设的家 + 借用原厂目录 + 常见兼容端点（openrouter、siliconflow-cn、volcengine、
  stepfun、ollama-cloud；minimax-cn 是 Anthropic 协议，不收），按行排版入库约 430 KB（紧凑约 260 KB）。
- 变化报告：新增/删除的模型、变化的参数，以及 **yaml 修正与公共目录一致、可以删掉的字段**和**两者冲突的字段**。
- GitHub Actions 每周一跑一次，有变化就开 PR、正文附报告，人工审阅后合并（上游删模型时标题注明）。

### 9.2 运行时刷新

- 定时任务 `llm_catalog_refresh`（每 6 小时检查一次，距上次超过 24 小时才真刷新，NAS 休眠错过也能补上）的第一步：带上次 `ETag` 请求 api.json，304 只记检查时间；200 时用与同步脚本
  **同一份投影代码**处理需要的家（快照收录的 ∪ 各实例 `catalog_id` 用到的），任一家投影失败整次作废、保留原缓存。
- 限制：只接受 HTTPS、32 MiB 上限、30 秒超时、走 `egress_transport("llm")`（与模型请求同一代理设置）。
- 落盘 `data/cache/llm-catalog/<catalog_id>.json` + `state.json`（ETag、上游时间、检查时间），先写临时文件再 rename。
  缓存可随时删除，只损失时间。
- 用哪一份：每家比较本地缓存与随包快照的上游时间，取较新者——升级后新快照不会被旧缓存盖住。
- 有变化时清掉合并结果的内存缓存，下次 `GET /llm/models` 重算，并对 AI 设定跑 `reconcile_defaults`。
- 不想访问 models.dev 时：配置域 `llm.catalog` 的 `online = false`（默认 true），只用随包快照。实例列表刷新不受影响。

### 9.3 开销

一天一次 6 MB 下载；常驻内存是投影后的几家目录（< 1 MB）；`GET /llm/models` 的合并按实例 + 数据版本缓存。
不碰现有请求路径的热点。

## 10. 接口

全部是**加字段 / 加接口**，旧客户端照常工作；改完要重跑 iOS 与 Android 的 API 生成器（新字段可空）。

| 接口 | 变化 |
|---|---|
| `GET /llm/models` | 默认只返回 `shown` 的模型（旧客户端菜单自动瘦身）；`?all=true` 返回全部合格模型。选项新增可空字段：`shown`、`known`、`deprecated`、`released`、`display_name`、`context_window`、`cost`、`sources` |
| `GET /llm/providers` / `{id}` | `LlmProviderView` 新增 `listing: {source, fetched_at, error, refreshing, total, shown, catalog_updated_at}`、`catalog_id` |
| `POST /llm/providers` / `PUT {id}` | 新增可选 `catalog_id`（仅 `openai_compat`；不传 = 自动识别） |
| `GET /llm/providers/{id}/models`（新） | 管理界面用：本实例全部候选模型及标注（参数未知、已停用、列表未包含、新） |
| `POST /llm/providers/{id}/models/visibility`（新） | `{model_id, shown}`；model_id 可能含斜杠，所以放请求体不放路径；与默认规则相同时从选择里删掉这一项 |
| `POST /llm/providers/{id}/models/refresh`（新） | 立即刷新本实例列表（并顺带检查公共目录），等结果返回，单次最多 30 秒 |
| `GET /llm/catalog/providers`（新） | models.dev 服务商索引（id、名称、api），供兼容端点表单选「模型资料来源」 |

CLI（`mclaw`）由 OpenAPI 生成，新接口自动出现；`refresh` 可加 `x-cli` 别名 `mclaw llm models refresh`。

## 11. 界面（Web 设置页）

- **实例行**：状态改为「已连接 · 显示 8 / 共 23 个模型 · 2 小时前更新」；列表刷新失败显示原因。
- **管理模型**（实例行新操作）：浮层列出候选模型，每行 = 模型 id（下方小字 display_name）、上下文、价格、标注，右侧开关；
  顶部搜索框与「刷新列表」。打开「参数未知」模型的开关 → 原地展开补录表单。
- **兼容端点表单**：「查询模型」结果里已知参数的模型直接可选，不再强制手填；新增「模型资料来源」下拉
  （自动识别 / models.dev 某家 / 不使用）。
- **对话框模型菜单**：不改，只是数据变成 `shown` 的子集。当前会话的模型不在菜单里时，现有回显逻辑照旧显示它。
- iOS / Android 只有 AI 设定与对话框模型菜单，吃的是同一个 `GET /llm/models`，不需要改界面。

## 12. 决策与待定

| 编号 | 问题 | 结论 |
|---|---|---|
| Q-1 | 引用一律限定（§7）？改变 `llm-multi-provider.md` §4「唯一时用裸 id」的约定 | **已定**：一律限定。升级前存的裸 id 读取时改写；网页记住的选择按 model_id 认回 |
| Q-2 | 默认显示数量 | **已定**：12，不做配置项；有预设的实例只补「比预设更新」的新模型（§6.2） |
| Q-3 | 兼容端点没 `catalog_id` 时向原厂目录借参数（§5.2 例外） | **已定**：借 |
| Q-4 | 一期是否删减 yaml 里与 models.dev 重复的字段 | **已定**：不删。yaml 中公共目录会「漏进来」的字段已显式写出（如 `thinking_control: null`），`test_preset_models_unchanged_by_public_catalog` 守住 43 个预设模型行为不变；同步报告逐条提示可删项 |
| Q-5 | models.dev 许可与署名 | 已核实上游仓库 LICENSE 为 MIT（2026-10-30）；快照文件内带版权声明 |
| Q-6 | 各家 `/models` 实际返回什么（百炼是否混入向量模型、GLM 是否提供） | 待用真实 Key 逐家实测；不提供的走 `unsupported` 退路 |
| Q-7 | models.dev 长期不可用或停更 | 随包快照兜底；投影层与上游格式解耦，换来源只改投影 |

## 13. 分期

| 期 | 内容 |
|---|---|
| 一期（后端，已实现） | `catalog.py`（投影、推导、合并、显示规则）+ 快照与同步脚本 + 每周 Action；`model_listing` / `model_visibility` / `catalog_id` 三列迁移（只加可空列，旧版回退忽略）；定时任务与运行时刷新；路由改读注入目录（实例改名后的旧引用按目录归属兜底）；引用限定与裸 id 改写；接口；网页记住的模型选择兼容裸 id |
| 二期（Web） | 实例状态行、管理模型浮层、兼容端点表单的资料来源与免手填 |
| 三期 | 调用报「模型不存在」后自动刷新该实例列表；Ollama 用 `/api/show` 取上下文；分档价格与费用累计；新预设（OpenRouter、硅基流动、火山方舟）——届时只需写端点、方言和 `catalog_id` |

## 14. 测试与验收

**单元**（`tests/llm/unit`，命名避开重名）：投影（固定上游样本 → 快照比对，类型错整份拒绝）；五层按字段合并；
思考推导（用 §3 的 37 条重叠样本断言 26 条与 yaml 一致、其余由 yaml 覆盖后与现状一致）；资格、默认显示、
显示/隐藏合并；列表校验（超量、非法 id）；引用改写与 reconcile。

**接口**：`GET /llm/models` 默认/全部；visibility、refresh；`?all` 与旧客户端字段兼容；列表失败三种退路；
ETag 304；本地缓存与快照取较新者；`online=false` 不发请求。

**端到端**：起一个仿 OpenAI 上游（`/models` 返回 30 个 id，含向量模型、停用模型、未知模型），后端指向它：
接入兼容端点（不手填参数）→ 验证通过 → 对话框菜单只有合格且已知的前 12 个 → 管理界面隐藏一个、显示一个
「参数未知」的（补参数）→ 用新模型发起一轮对话、思考档位菜单正确 → 上游删掉正在用的模型后刷新，旧会话仍能续聊。
Web 侧用浏览器面板走一遍设置页与对话框。

**真实服务**：DeepSeek / Kimi / GLM / 百炼 / OpenAI 各用真实 Key 验列表与参数（需要用户提供 Key 或在 NAS 上验）。
