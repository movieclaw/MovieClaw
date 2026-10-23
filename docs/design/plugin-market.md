# 插件市场

「设置 → 插件 → 插件市场」：从官方插件仓库 [movieclaw-plugins](https://github.com/movieclaw/movieclaw-plugins)
浏览、安装、升级、换回旧版插件。数据源是该仓库 `catalog` Release 上的签名索引（schema 2，格式见该仓库
`index.schema.json`）。代码：`services/plugin_market.py`、`api/routes/plugins.py` 的 `/app/plugins/market*`、
`apps/web/components/plugin-market.tsx`。

## 1. 原则

- **市场只是另一个下载来源。** 核对通过的包交给 `PackageManager.upload`，之后的待批准、批准抽屉、依赖同意、
  宽限期回滚、卸载与上传安装完全相同（plugin-phase3.md §3、plugin-dependencies.md）。市场从不静默安装或升级。
- **只下载索引里登记的地址**，没有「填网址安装」。
- **客户端只问自己的服务器。** 拉索引、README、图标、包都由服务器经统一出口（`egress_transport("github")`）完成，
  国内网络、iOS 都不直连 GitHub。

## 2. 信任链

| 什么 | 怎么核对 |
|---|---|
| `index.json` | 旁边的 `index.json.sig`：Ed25519 签原始字节，公钥随应用发布（`CATALOG_KEYS`，key_id → 公钥）。没签名、签名不对、密钥不认识一律不加载 |
| 包、README、依赖锁文件、图标 | 索引里的 `{url, sha256, size}`；超出声明的字节数立即中止 |
| 包内容 | 解出的清单 `id` / `version` 须与索引一致 |

因为包与图片都按签名索引核对，下载可以走 `UPDATE_DOWNLOAD_MIRROR`（与应用内更新同一个加速镜像设置）。
自建索引可设 `PLUGIN_CATALOG_URL`；没有签名的只在 `PLUGIN_CATALOG_ALLOW_UNSIGNED=true` 时放行，且此时索引只直连
（否则镜像能同时伪造索引和包）。

换密钥：先在 `CATALOG_KEYS` 加新公钥并发版，插件仓库再换 `RELEASE_SIGNING_KEY` 与 `RELEASE_SIGNING_KEY_ID`。

## 3. 缓存

- 索引存 `cache_entry`（namespace `plugin_market`）：30 分钟内直接用；过期回源，回源失败时 7 天内的旧索引照用，
  市场顶部标出失败原因；「检查更新」强制回源，失败报错。
- 取到的索引 `generated_at` 比手里的旧时不采用（镜像缓存或回放不会让列表倒退）。
- README、锁文件、图标核对后按 sha256 永久缓存；插件包不缓存。

## 4. 推荐哪一版

服务端对每个版本算 `compatible`（`sdk`、`[requires]` 契约、宿主操作、平台，与 `check_compat` 同一套规则），
然后：

- 推荐 = 能装、没撤回的最新正式版；**装着测试版**或**一个正式版都没有**时，测试版也算。没有全局「显示测试版」开关：
  测试版照常列出、标「测试版」，详情「版本」页能主动装。
- `update` = 已安装且推荐版本比装着的新。
- 同 id 被内置 / 本地插件占用时 `blocked`；随应用提供的插件（bundled）显示「随应用提供」，市场有更新版本时可替换。
- 撤回的版本（索引 `yanked`）不推荐；装着的版本被撤回时详情页提示原因与建议版本。

## 5. 接口

| 接口 | 用途 |
|---|---|
| `GET /app/plugins/market` | 列表：来源状态、插件、版本兼容性、本机安装状态、更新数 |
| `POST /app/plugins/market/refresh` | 检查更新（强制回源） |
| `GET /app/plugins/market/{id}?version=` | 详情：README、这台服务器要下载的依赖（锁文件 + 本机平台算大小） |
| `GET /app/plugins/market/{id}/icon` | 图标（核对后返回，`?v=<哈希>` 可长缓存；SVG 带 `sandbox` CSP） |
| `GET /app/plugins/market/{id}/screenshots/{index}` | 截图，核对方式与图标相同 |
| `POST /app/plugins/market/{id}/install` `{version}` | 下载核对 → 待批准，返回值与上传相同；升级、降级都走它 |

CLI：`mclaw app plugins market list|show|refresh|install`（图标不生成命令）。

## 6. 网页

插件页两个页签：「已安装」（原有内容）与「插件市场」（`?tab=market`，有更新时页签带数字）。市场页：来源行
（仓库链接、签名状态、检查时间、检查更新）→「可更新」→ 搜索与分类 → 卡片。详情抽屉的第一屏是一行简介、
截图（索引里有才显示）和页脚的安装按钮；这一版的更新说明紧跟在下面。版本、运行方式、许可证收成一行弱化的
说明。再往下仍是「介绍 / 权限 / 版本」。主按钮安装或更新，已安装的有「管理」去插件详情页停用 / 卸载。
安装下载完成后打开与上传共用的批准抽屉（`ReviewDrawer`）。只做网页端（插件界面的既定范围）。

索引里两个可选字段，旧索引没有就当没有，不另加设置：

- `downloads`：累计下载次数，跟在作者或版本旁边（如「1.2万 次下载」）。没有这个数就不显示。
- `feedback_url`：详情里的「反馈问题」，新标签页打开。是官方仓库的 issue 表单时，带上 `plugin_version`
  （装着的版本，否则最新版）和 `movieclaw_version`。没有 `feedback_url`、但 `homepage` 是 GitHub 仓库时，
  打开该仓库的新建 issue。

## 7. 插件仓库侧（movieclaw-plugins #13）

- 每个版本的权限、`sdk`、`[requires]`、依赖锁文件、README、CHANGELOG 小节都从**那一版的 tag** 读，旧版本不会
  被 main 上的新清单改写；分类按 `[requires]` 推断（`store.json` 可覆盖）。
- Release 正文 = 这一版的 CHANGELOG 小节；打 tag 时没有这一节直接失败。
- 只改元数据（简介、图标、撤回、弃用）不用发版：PR 里跑 `generate_index.py --update`，合并后 `catalog.yml` 签名上传。
- 发布索引必须有签名密钥，没有就失败，不会发出应用不认的索引。
