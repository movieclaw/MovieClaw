# 第三方媒体服务器接入：只读的远端存储

> 状态：**已定稿并实施**（2026-11-05，维护者授权「按判断决定、写完就实施」），对应 issue #1180。
> 本文取代 [library-source-providers.md](library-source-providers.md) §4「插件侧要自己做的」与 §7 的飞牛落地清单。
> 关联：[cloud-storage.md](cloud-storage.md)（本文是它的一种用法）、[library-boundary.md](library-boundary.md) §1（底线归宿主）、
> [plugin-extension-model.md](plugin-extension-model.md) §3（宿主操作复用操作目录）、[strm-playback.md](strm-playback.md)（转发规则）。

## 0. 结论

1. **Emby、Plex、飞牛这类服务器上的内容，对 MovieClaw 来说就是「字节在别处的文件」**，走已有的网盘内核
   `drive-backends` 接入，不开放台账写入、不新增 `resolve_stream`、不把 `library.source-providers` 转稳定。
2. 接入分两种（§2）：**本机可见**的就是普通本地库加一个进度同步插件；**只能远程访问**的实现一个只读 `DriveBackend`。
3. 内核要补的很少（§3～§6）：`drive-backends` 1.7（只读语义、取流请求头、复查周期），加片头片尾的读取接口与事件、
   `playback.sync.catalog` 按 TMDB 过滤、`OpsError.message_key`、`net.http_transport(verify=...)`。
4. 主仓库不放任何厂商代码。Emby、Plex、飞牛都是插件仓库里的独立插件包。

## 1. 为什么不开放台账写入

[#1179](https://github.com/movieclaw/MovieClaw/pull/1179) 的做法是插件自己写 `library_file`，所以 #1180 最初提议开放
`library.files.upsert / mark_missing` 和 `resolve_stream`。不这样做的理由：

- **这不是新的身份来源。** `Library.source` 的定义是「谁负责识别与刮削」（`services/library/profile.py`）。飞牛档案是
  `scraped=True`，身份全走 TMDB，来源就是 TMDB；它不一样的只是**字节在哪**。字节位置已经有专门的模型：
  `library_file.local_bytes` 加 `library_file_replica`。把位置塞进来源，等于为一个不存在的维度冻结 `LibraryProfile`。
- **判缺失是底线，归宿主。** 实现者的真实事故：一个季的分集接口超时，下一轮对账把整季 120 多集标成缺失。给插件一个
  `mark_missing(complete=...)` 只是把判断交给每个插件各写一遍。走列表对账时插件根本没有这个入口：`list_tree` 抛错，
  这一轮这个文件夹就不对账；返回了就是完整列表（`services/library/cloud.py` 的 `collect` / `finish`）。
- **字节不在本地的影响面已经处理过。** [cloud-storage.md](cloud-storage.md) §14 列了几十处（转码、字幕、Jellyfin、回收站、
  缓存指纹……），`.strm` 占位文件那条路要在这些地方重做一遍，还要为占位文件写特例。
- **插件代码量。** #1179 的 `align.py` 和约 50 处内部 import（`movieclaw_db`、仓储、`MediaLibraryService`）都是写台账带来的，
  走这条路全部不需要，`test_bundled_packages_only_depend_on_the_sdk` 这类边界也自然满足。

这推翻 `library-source-providers.md` §6 的「不提供同步引擎」：当时担心不同服务器的条目结构差异太大。实际需要的最大公约数
只有三样：文件 id、路径、大小，纳管流程早就按这三样跑。

2026-11-05 用临时测试验证过（未改内核）：一个假的只读媒体服务器，主进程与独立进程都能挂成库、按服务器给的 TMDB 编号入账、
剧集季集正确，列表拉取失败时一条缺失都不标，拉全后才标。

## 2. 两种接入形态

### 2.1 本机可见：普通本地库 + 进度同步插件

服务器的片库目录挂进了 MovieClaw 容器（飞牛最常见的部署）。这时不需要任何新机制：

- 建库：`library.create`，根目录写挂载路径，`scrape_overrides` 关掉 `mirror_images` / `mirror_nfo` / `mirror_episode_thumbs`，
  不往对方的目录写文件；
- 入账：主线扫描真实文件，规格、字幕、抓帧、本地直出都是原生能力，对方挂了照常播；
- 身份：主线识别；认不出的插件可按对方给的 TMDB 编号调 `library.identification.assign-files-to-title` 认领；
- 进度与片头片尾：见 §6，只按（TMDB 编号, 季, 集）对应，和文件在哪无关。

库根不能嵌套（`errors.library.rootOverlapsLibrary`）：对方把父目录和子目录挂进同一个库时，插件要自己按「父目录优先」去重。

### 2.2 只能远程访问：只读 `DriveBackend`

```python
from movieclaw_sdk import net, plugin
from movieclaw_sdk.drives import (
    DRIVE_BACKENDS, AccountInfo, Capabilities, DirectLink, DriveBackend, Login, LoginResult,
    RemoteDir, RemoteFile, RemoteTree, Transient,
)

class Server(DriveBackend):
    type = "emby"
    title = "Emby"
    capabilities = Capabilities(
        writable=False,            # 只读：不能当主根，不会被删文件（§4）
        recheck_hours=1,           # 每轮定期对账（6 小时）都整树列一遍（§3）
        default_qps=20.0, default_daily_budget=1_000_000, default_read_slots=8,
    )
    login = Login(form=Credentials)  # 地址 + 令牌；令牌用 SecretStr，主程序加密存

    async def list_dir(self, account, dir_id):
        # 根目录列对方的库；库下面不再分层，建库向导的目录选择器直接可用
        ...

    async def list_tree(self, account, dir_id):
        # 必须完整：拉不全就抛 Transient，这一轮不对账。不要吞掉单页、单季的失败
        ...
        return RemoteTree(files=tuple(
            RemoteFile(
                remote_id=item["Id"],
                name=name,
                size=size,                  # 不知道就填 0
                # 身份写进路径：[tmdbid=N] 是现成的显式标记（Emby/Jellyfin/TMM 通行写法）
                rel_path=f"{title} ({year}) [tmdbid={tmdb_id}]/Season {s:02d}/S{s:02d}E{e:02d}{ext}",
            ) for ...
        ))

    async def direct_link(self, account, remote_id, user_agent):
        # 长期凭据放请求头，不要放地址里：带请求头的直链一律由家里转发，不会 302 给播放器
        return DirectLink(url=f"{base}/Videos/{remote_id}/stream?static=true",
                          headers={"X-Emby-Token": token}, expires_in=3600)
```

插件只做「怎么跟这家服务器说话」。账号与凭据加密、限速、纳管、识别、对账、取流、转码、Jellyfin 兼容都是现成的。

**身份不加新字段**：`[tmdbid=N]` 是识别链最高优先级的显式声明，还要过 `_pinned_mismatch` 的证据校验，比插件直接写台账更稳。
没有 TMDB 编号的条目不写标记，退回文件名识别，认不出就进待识别清单。剧集的编号写**剧**的，不是集的。

**不做「本机可见 + 远程兜底」的混合模式**：同一批文件要么建本地库，要么挂远端目录。

## 3. 契约：`drive-backends` 1.7（都是加法）

| 变化 | 说明 |
|---|---|
| `Capabilities.writable=False` 真正可用 | 之前文档写「只读网盘不支持」，实际没有任何把关。语义见 §4 |
| `Capabilities.recheck_hours: int = 168` | 多久整树复查一次（小时）。之前写死一周，是按 115 的接口预算定的；内网服务器可以很频繁。定期对账每 6 小时一轮，到点的才列，想每轮都列就写 1 |
| `DirectLink.headers: dict[str, str] = {}` | 服务器读这条直链时带的请求头。转发、转码、探规格、抽字幕都带上（`StrmLink.headers` 早就贯通）；头名与值的规则与 strm 相同（防注入） |
| `list_tree` 的完整性约定写进文档 | 返回值就是完整列表，没出现的文件标缺失；拉不全必须抛异常 |

只读后端要实现的方法：登录一族、`account_info`、`list_dir`、`list_tree`、`direct_link`。`changes` 可选，
`stat` / 上传 / `delete` 都不会被调用。

## 4. 只读语义（`writable=False`）

宿主保证**绝不调用写方法**，判断在宿主，不靠插件抛错：

| 场景 | 行为 |
|---|---|
| 设为主根（`validate_folders`） | 拒绝，`library.cloud.readOnlyPrimary`。新片落在库的本地主根 |
| 用户删条目、删文件（`delete_cloud_copies`） | 不调插件，返回 `errors.drives.readOnly`（「到对方那里删，下次同步会跟着消失」）；台账不动。同一次里混着可写网盘时整批拒绝，可写那边也不会先删。混着本地文件的条目整件不做，与「网盘没删掉就整件事不做」同一语义 |
| 删除预览（`delete-preview`） | `cloud.read_only=true`；网页的删除对话框只说明原因，不出现「永久删除」的确认流程 |
| 自动进回收站（洗版替换、取消订阅清理、重复清理） | `recycle_file` 返回新结局 `read_only`，**行不动**。洗版等于「保留共存」；重复清理计入失败并写明原因 |
| 从库里拿掉目录、删库 | 只删台账（现状） |
| 文件在对方被删 | 列表里没了就标缺失（现状）；回来了认回来 |

插件被停用时确认不了写能力，不当作可写：删除直接拒绝（`errors.driveLogin.backendUnavailable`），自动进回收站同样返回 `read_only`、行不动，也不能新设成主根。本来就是主根的，插件临时不在时仍可原样保存。写方法（上传、删除）在真正调用前再看一次 `writable`。

## 5. 取流

全部沿用网盘那一套（[cloud-storage.md](cloud-storage.md) §7），只补一处真实缺口。

**缺口**（实测）：`stream_target` 只看设置与设备，外网的自家 App 会被 302 到插件给的直链，例如
`http://192.168.1.10:8096/stream/1?token=t`：内网地址在外面连不上，还把令牌交给了播放器。

**改法**：取到直链后复用 strm 的判据 `strm_needs_relay(url, headers)`，内网地址、带请求头、地址里带账号密码的，
无论什么设置都由家里转发，占同时播放数。这也让「总是直连」对这类直链失效，是有意的。

插件的约定：长期凭据放 `headers`，不放地址。地址里带令牌又是公网地址的，宿主分辨不出，会照常 302。

服务器跟直链的 302 时按源逐跳看：下一跳换了源（协议、主机或端口）就先去掉厂商令牌头（`X-Emby-Token`、`X-Plex-Token`、`Authorization`、`Cookie` 一类），再请求。转发、按区间读、交给 ffmpeg 之前同一条规则。同源跳转仍带着这些头。

**不做**：`local_first` 之类的偏好（§2.2 已说明）；服务器读直链时的自签证书（§6.4）。

## 6. 其他小补

### 6.1 片头片尾的读取（#1180 第 6 项）

插件之前只能直接读 `media_segment` 表。新增：

- `GET /libraries/{id}/items/{mid}/segments?season=`（`library.items.segments`，管理员）：每个在位文件一行
  `{file_id, season, episode, duration_seconds, segments}`，内容与播放器拿到的一样（`segments_for_file`）。
  不算代表值：飞牛按季取中位数、Emby 按集存，由插件决定；
- 事件 `library.segments.updated`（`{media, season, file_ids}`，可靠投递）：一季识别写回后发，结果可能没变，插件自己比对。

**不做 `markers.push`**：写回对方是插件的事，内核不认识对方的配置。

### 6.2 进度同步（#1180 第 5 项）

能力基本是现成的：播放事件的 `member_id` 必填（超管为 0），`playback.sync.state` 接受 `member_id` 并做 compare-and-set，
成员停用或不存在时返回 404（`errors.playbackSync.memberInactive`）。**「成员 ↔ 对方账号」的映射留在插件**（`plugin-data`），未映射的成员跳过；
内核不认识任何对方的账号体系。

唯一缺口：对方报来进度时，插件要拿到本地状态的 `updated_at` 才能 compare-and-set，之前只能分页翻整个目录或直接读表。
`playback.sync.catalog` 加可选参数 `tmdb_id`，只返回这部作品的单元。

### 6.3 区分建库失败的原因（#1180 第 2 项）

`library.create` 早就在操作目录里（还支持 `cloud_folders`），错误响应也带 `message_key` 和 `params`，只是
`OpsError` 没透出来，插件只能按文案猜。`OpsError` 加 `message_key` / `params`。网盘目录冲突的报错也改成带键的。

插件能据此分辨 `errors.library.nameInUse`、`errors.library.rootOverlapsLibrary`、`errors.library.rootOverlapsWatch`、
`errors.library.rootOverlapsTarget`、`library.cloud.overlapLibrary`。同一目录重复挂载有唯一索引兜底
（`uq_library_cloud_folder_remote`），不另加 `dedupe_key`。

### 6.4 TLS（#1180 第 11 项）

`net.http_transport(service, verify=True)`：`True` 校验，`False` 不校验（只应由用户显式开启），字符串是 CA 文件路径。

**不做域名白名单**：`network = true` 现在只是批准页上的声明，插件进程能直接开套接字，白名单挡不住，还会让人以为有隔离。

**自签证书只覆盖插件自己的接口客户端。** 宿主读直链（`RemoteRelayResponse`、`RemoteRangeFile`）仍校验证书，一期要求直链走 HTTP 内网地址或受信证书。
真有用户卡在这里再把 `verify` 贯通到 `StrmLink`。

## 7. #1180 逐项对照

| # | 能力 | 结论 |
|---|---|---|
| 1 | 注册库来源 | 不转稳定。保持 `EXPERIMENTAL`，本文的接入方式用不到它。真有番号、Bangumi 这类新身份来源时，连同识别与刮削契约一起设计 |
| 2 | 创建媒体库 | 已有；§6.3 |
| 3 | 写台账 | 不开放；§1 |
| 4 | 建档 / 识别 / 扫描 | 已有：`library.scan.start`（支持 `paths` / `cloud_paths`）、`library.identification.assign-file(s)-to-title` |
| 5 | 双向进度 | 基本已有；§6.2 |
| 6 | 片头片尾 | 新增读取与事件；§6.1 |
| 7 | 插件网页 | 不动。独立插件包不需要 #1179 对 `plugin_web.py` 的改动 |
| 8 | 任务去重 | 已有：`jobs.create(dedupe_key=...)` 返回 `created`；`jobs.show` / `jobs.list` 查状态 |
| 9 | 敏感字段 | 已有：`SecretStr` 或 `json_schema_extra={"secret": True}`，SecretBox 加密存储、界面不回显。不加 `sensitive`。走 §2.2 时凭据在 `drive_account`，同样加密 |
| 10 | 远程播放 | `direct_link` 就是这个能力；§5 |
| 11 | 网络与 TLS | 只做 TLS；§6.4 |

## 8. 飞牛的远程模式（一期内核不支持）

飞牛 mediasrv 0.8.x 对本地文件只给带会话凭据的 HLS 转码流，没有原画直出（#1179 `trim_api.py` 的注释）。而宿主读字节全部假设 Range：
探规格能过（ffprobe 认 m3u8），转发、抽字幕、读索引都不成立。这是这批需求里唯一逼内核加新协议的场景，而且转码流本来就做不到「和内置库齐平」。

**决定**：飞牛一期只做本机可见（§2.1）。主线不加 HLS 协议。

以后要做时，插件的 `direct_link` 返回自己的签名路由（`routes.sign(..., expires_in=...)`，务必带有效期；#1179 写进 `.strm` 的签名是不过期的），
声明 `original_link=False`，形态与现在 `.strm` 里写的一样，只是不再落占位文件。各端能否播放要实测。

Emby、Plex 能给支持 Range 的原文件地址（按接口文档判断，待真实服务器验证），不受此影响。

## 9. 明确不做

- 台账写入接口、同步令牌、`complete` 标志（§1）；
- `library.source-providers` 转稳定（§7 第 1 项）；
- `resolve_stream`、HLS 协议（§5、§8）；
- 内核里的成员映射表、`markers.push`、建库数量限制（操作授权本身就是用户批准）；
- `RemoteFile` 上的身份字段（路径标记够用，§2.2）；
- 直接用对方的元数据和图片（一期全走 TMDB；要用时另行设计）；
- 把设置页的「网盘」分区改名：先按现状，插件名照常显示在账号卡片与目录选择器上。

## 10. 兼容

| 组合 | 结果 |
|---|---|
| 新服务器 × 已发布客户端 | 接口只加可空字段（`DeleteCloudView.read_only`）与可选参数。App 删只读文件时收到写明原因的失败提示 |
| 新服务器 × 已装插件（`cloud-115`） | 它声明了 `writable=True`，行为不变。`recheck_hours` 默认 168，与原来相同 |
| 新插件 × 旧服务器 | 清单写 `"drive-backends" = "^1.7"`，旧服务器拒绝加载并说明缺少契约 |
| 没有网盘插件 | 整体休眠（[cloud-storage.md](cloud-storage.md) §11.8），无影响 |

无数据库迁移，可以回退。

## 11. 验证

- `tests/api/test_media_server_plugin.py`：真实 HTTP 的假媒体服务器（令牌校验、Range）+ 真实走 `net.http_transport` 的插件，主进程与独立进程各跑一遍：
  填表登录、目录选择、建库、身份、缺失对账（含拉取失败）、取流（令牌只在服务器一侧，外网也不 302）、ffprobe 探规格、只读规则、插件自动建库与错误键；
- 片头片尾接口与事件、`catalog` 过滤、`http_transport(verify=...)`（真实自签 HTTPS）各有用例；
- 网页：`tests/e2e/test_media_server_browser.py`（真实 Next + API + 进程外插件）走填表连接、建库挂目录、「只读」标记、删除只给原因；
- 真实 Emby、Plex 留给插件仓库的第一个插件验证。

## 12. 实施

一个 PR，按提交拆开，各自可回滚：

1. 设计稿；
2. 内核：`drive-backends` 1.7（只读语义、取流请求头与转发判据、复查周期），片头片尾读取与事件、`catalog` 过滤、
   `OpsError.message_key`、`http_transport(verify=...)`；
3. 网页：只读目录与删除提示；
4. 插件开发技能同步。

Emby、Plex、飞牛的插件在插件仓库另做，依赖这个版本发布后的契约。
