# 界面文字与门槛变化：v0.50.0 → HEAD（src apps/web docker cli）

## 消失的界面文字（6）：删掉的入口、改掉的名字、拿走的功能都在这里

「别处仍有」表示同样的文字还在其他文件里，入口可能只是挪了位置，也可能只剩别的页面有。

- 「修改端点的名称、服务、工具模式或启停状态」  ← src/movieclaw_api/api/routes/mcp.py（全部消失）
- 「试算：给定服务集合会暴露哪些工具、占多少上下文」  ← src/movieclaw_api/api/routes/mcp.py（全部消失）
- 「played、position_ms、is_favorite 至少要给一个」  ← src/movieclaw_api/locales/zh-Hans/errors.json（全部消失）
- 「外部请求巡检某源目录（人工恢复处理后的立即重看）。事件循环线程调用。」  ← src/movieclaw_api/services/library/ingest.py（全部消失）
- 「按单元写回已看 / 续播 / 收藏；compare-and-set，值没变不动版本，不发事件。」  ← src/movieclaw_api/services/playback_sync.py（全部消失）
- 「请求发出前调用；熔断打开且不在探测窗口时抛 CircuitOpenError。」  ← src/movieclaw_net/breaker.py（全部消失）

## 新增的界面文字（43）：新入口、新提示、新限制

- 「已看判定」  ← apps/web/locales/zh-Hans/settings.json
- 「所有设备共用这台服务器的规则。更改后，对之后上报的播放进度生效。」  ← apps/web/locales/zh-Hans/settings.json
- 「完成百分比（%）」  ← apps/web/locales/zh-Hans/settings.json
- 「请输入 80 到 100 之间的百分比。」  ← apps/web/locales/zh-Hans/settings.json
- 「优先按片尾判定」  ← apps/web/locales/zh-Hans/settings.json
- 「有效剧集片尾会替代百分比判定，可能早于或晚于所填比例。仅使用直达结尾的片尾；有后续剧情或彩蛋时仍按百分比判断。」  ← apps/web/locales/zh-Hans/settings.json
- 「片头片尾识别：{enabled}/{total} 个剧集库已开启。开启后还需等待各集识别成功。」  ← apps/web/locales/zh-Hans/settings.json
- 「当前服务器尚不支持这些选项，请先更新服务器。」  ← apps/web/locales/zh-Hans/settings.json
- 「修改端点的名称、服务、工具模式、排除清单或启停状态」  ← src/movieclaw_api/api/routes/mcp.py
- 「试算：给定服务集合与排除清单，会暴露哪些工具、占多少上下文」  ← src/movieclaw_api/api/routes/mcp.py
- 「这些工具不存在：{tools}」  ← src/movieclaw_api/locales/zh-Hans/errors.json
- 「played、position_ms、is_favorite、dismiss_continue 至少要给一个」  ← src/movieclaw_api/locales/zh-Hans/errors.json
- 「排除的工具名：不进 tools/list，直接调用也被拒」  ← src/movieclaw_api/schemas/mcp.py
- 「配置里存在但当前版本已没有的排除项（已忽略）」  ← src/movieclaw_api/schemas/mcp.py
- 「排除的工具名（展开模式的工具名）」  ← src/movieclaw_api/schemas/mcp.py
- 「排除的工具名，与端点配置同款参与试算」  ← src/movieclaw_api/schemas/mcp.py
- 「手动下载的完成巡检失败」  ← src/movieclaw_api/services/download_progress.py
- 「下载完成后请求监听巡检失败：hash=%s 目录=%s」  ← src/movieclaw_api/services/download_progress.py
- 「下载器报告任务完成，请求巡检监听目录：hash=%s 保存目录=%s → %s」  ← src/movieclaw_api/services/download_progress.py
- 「_sweep_dir 的单轮巡检本体；自检续挂由 _sweep_dir 的 finally 统一负责。」  ← src/movieclaw_api/services/library/ingest.py
- 「下载完成的保存目录不在任何监听目录下，不触发巡检：%s」  ← src/movieclaw_api/services/library/ingest.py
- 「（事件循环线程）入队并记下触发原因；同一目录多次入队原因合并。」  ← src/movieclaw_api/services/library/ingest.py
- 「巡检监听目录 %s（触发原因：%s）」  ← src/movieclaw_api/services/library/ingest.py
- 「排除清单按展开模式的工具名匹配，必须是 spec 里真实存在的工具。」  ← src/movieclaw_api/services/mcp_endpoints.py
- 「在线上报与离线观看补传共用的服务端已看判定配置。」  ← src/movieclaw_api/services/playback/completion.py
- 「显式版本不在位时，只信该版本的历史片长，不借用其他版本或刮削片长。」  ← src/movieclaw_api/services/playback/completion.py
- 「「接下来继续」隐藏写到了不是作品当前锚点的那一行：回滚这次写入，按冲突返回。」  ← src/movieclaw_api/services/playback_sync.py
- 「按单元写回已看 / 续播 / 收藏 / 接下来继续隐藏；compare-and-set，值没变不动版本，不发事件。」  ← src/movieclaw_api/services/playback_sync.py
- 「成功但卡片还在」  ← src/movieclaw_api/services/playback_up_next.py
- 「还带着标记」  ← src/movieclaw_api/services/playback_up_next.py
- 「隐藏之后没有新的播放」  ← src/movieclaw_api/services/playback_up_next.py
- 「排除的工具名（展开模式的工具名）：不出现在 tools/list，直接调用也被拒」  ← src/movieclaw_api/settings/mcp.py
- 「按域原子读取、合并、校验、持久化及更新缓存，返回（旧值，新值）。」  ← src/movieclaw_api/settings/store.py
- 「是否从「接下来继续」隐藏（作品级）」  ← src/movieclaw_db/models/playback_state.py
- 「隐藏的服务器时间；只有比它新的播放事实才让作品回来。未隐藏时为 NULL」  ← src/movieclaw_db/models/playback_state.py
- 「工具 {name} 已被管理员从这个端点排除，无法调用」  ← src/movieclaw_mcp/tools.py
- 「命令 {command} 已被管理员从这个端点排除，无法调用」  ← src/movieclaw_mcp/tools.py
- 「请求前检查；探测返回唯一 token，closed 返回 None，不可放行时抛异常。」  ← src/movieclaw_net/breaker.py
- 「仅归还 token 仍匹配的探测槽，保留失败计数与原冷却起点。」  ← src/movieclaw_net/breaker.py
- 「这一集仍是作品的当前锚点」  ← src/movieclaw_playback/state.py
- 「等，等同」  ← src/movieclaw_playback/state.py
- 「这部作品该观看者下带「接下来继续」隐藏标记的行。」  ← src/movieclaw_playback/state.py
- 「任一行带标记」  ← src/movieclaw_playback/state.py

## 默认值、门槛、权限相关的改动行（15）
逐条判断：是否改变了用户的默认体验、使用前提或权限。

- + apps/web/locales/de/settings.json: "archiveHint": "Logs werden täglich im Verzeichnis data/logs des Servers archiviert. Bei Docker-Installationen musst du das data-Volume einbinden, um sie zu beh
- + apps/web/locales/de/settings.json: "capabilities": "Fähigkeiten des Plugins",
- + apps/web/locales/de/settings.json: "capabilities": "Berechtigungen und Fähigkeiten",
- + apps/web/locales/de/settings.json: "capabilityPush": "Offizieller Push",
- + apps/web/locales/de/settings.json: "capabilityRemote": "Fernzugriff",
- + apps/web/locales/de/settings.json: "capabilityControl": "Fernsteuerung"
- + apps/web/locales/de/subscription.json: "minimumRequirements": "Auswahl und Mindestanforderungen",
- + src/movieclaw_api/schemas/playback.py: played_threshold_percent: float | None = Field(default=90, ge=80, le=100)
- + src/movieclaw_api/schemas/playback.py: played_threshold_percent: float | None = Field(default=None, ge=80, le=100)
- + src/movieclaw_api/settings/playback.py: played_threshold_percent: float = Field(default=90, ge=80, le=100)
- + src/movieclaw_db/models/playback_state.py: default=False,
- + src/movieclaw_db/models/playback_state.py: sa_column_kwargs={"server_default": "0"},
- + src/movieclaw_db/models/playback_state.py: default=None,
- - src/movieclaw_playback/progress.py: if runtime_ms < MIN_RESUME_DURATION_MS:
- + src/movieclaw_playback/progress.py: runtime_ms < MIN_RESUME_DURATION_MS
