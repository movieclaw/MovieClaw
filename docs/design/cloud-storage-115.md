# 115 网盘存储后端插件——设计

> 状态：插件第一版已写完（2026-10-18，[movieclaw-plugins#4](https://github.com/movieclaw/movieclaw-plugins/pull/4)，对仿 115 测过），
> 【待实测】各项还没在真账号上跑。内核侧见 [cloud-storage.md](cloud-storage.md)，本文只写「怎么跟 115 说话」。
> 插件代码放插件仓库 [movieclaw-plugins](https://github.com/movieclaw/movieclaw-plugins) 的 `plugins/cloud-115/`，
> 不进主仓库（主程序只做通用能力，主仓库用测试内的假后端验证契约）。
> 依赖内核新契约 `drive-backends`，插件仓库 CI 先钉 main 上带该契约的提交（`MOVIECLAW_DEPS_REF`），发版后并回 `MOVIECLAW_REF`。
>
> **用户决策（2026-10-17）：先走 Cookie 登录**（扫码选登录端 + 浏览器扩展导入），不等开放平台应用资质；
> 开放平台登录以后作为同一个 `115` 后端的第二种登录方式补上。
>
> 参考：p115client（Python，主包 **MIT 许可**；但它拆出去的子包 p115cipher、p115pickcode 等是 GPLv3，见 §0「许可证」）；115 开放平台公开文档；LitePan（`drivers/115_Open/`，
> PolyForm 非商用许可，**代码不能用**，只看思路）；SmartStrm（闭源，只有文档与 issue）。
> 标【待实测】的条目必须先用真账号测过再定。

## 0. 定位

实现内核契约 `DriveBackend`（cloud-storage.md §11）。插件只负责协议：登录、列目录与操作动态（纳管）、秒传、分片续传上传、
核验、取直链、移动改名删除、容量。账号存储、凭据加密、限速与配额、重试、任务、选源、释放、删除护栏都在宿主。

选 115 做第一个：网盘玩家里占比最高；秒传按 SHA1，正好用上宿主一次读盘算出的指纹。第二个后端（123 云盘，
MD5 秒传）用来验证契约没有被 115 的形状绑死，另起一份文档。

**两种登录方式、一套文件操作**：插件内部把「登录方式」做成可替换的一层（`Session`），秒传、上传、取直链按登录方式
各有一套请求实现；目录、核验、删除、指纹、续传状态、错误分类、能力声明共用。账号凭据里记着登录方式。

**实现依赖**：Cookie 方式的上传初始化与取直链都要做 115 自己的加密 / 签名（ECDH、RSA 变体、`userkey` 签名）。插件声明依赖
`p115cipher[full]` 与 `p115pickcode`（提取码换文件 id；pycryptodome、ecdsa、lz4 都有 x86_64 与 aarch64 的预编译轮子），安装时经管理员授权由主程序下载
（[plugin-dependencies.md](plugin-dependencies.md)）。HTTP 用主程序自带的 `httpx`。**不整包依赖 p115client**：它的依赖近 40 个，
安装慢、出问题的面大，插件只需要它的加密部分；接口路径与参数参考 p115client 的实现，按 115 的改版跟进。

**许可证（2026-10-18 核实，维护者已定）**：p115cipher、p115pickcode 的 PyPI 元数据写 MIT，但轮子里的 LICENSE 与源码头都是
**GPLv3**。所以 115 插件以 **GPL-3.0-or-later** 发布（与插件仓库其他插件不同）；这两个包不随插件包分发，由服务器按锁文件下载，
插件在独立进程里经本机 HTTP 与主程序通信，主程序与主仓库不含任何 GPL 代码。插件用到时才导入它们，依赖批准安装前入口模块也能导入。

## 1. 能力声明

```python
StorageCapabilities(
    writable=True,
    rapid_upload_hashes=("sha1",),      # 外加前 128KB SHA1（preid），见 §3
    range_challenge=True,               # 秒传可能要求回答任意区间的 SHA1（≥ 1 MB 的文件基本都会）
    original_link=True,                 # 直链是原画，不是转码流
    link_needs_ua=True,                 # 直链按取链时的 User-Agent 签发
    list_hashes=True,                   # 列目录时带 SHA1：纳管的文件直接有指纹
    change_feed=True,                   # 有操作动态（Cookie 方式），§6.2
    default_read_slots=2,               # 同时播放数：服务器读网盘的连接名额（LitePan 用 2），【待实测】
    recycle_bin=True,                   # 删除进 115 回收站
    max_file_bytes=None,                # 【待实测】单文件上限
    default_qps=1.2,                    # 宿主限速默认值，用户可改（§9）
    default_daily_budget=8000,          # 每日操作次数预算，用户可改（§9）
)
```

## 2. 登录

### 2.1 Cookie：扫码并选登录端（推荐）

115 每种登录端（网页、安卓、iOS、电视、各小程序……）同一时间只能在线一个，新登录会把同端的旧登录踢下线。
所以扫码前让用户**选一个自己不用的端**，默认推荐「支付宝小程序」，列表里标出常见冲突：

- 「网页端」会和浏览器里的 115 互踢；
- CloudDrive2、OpenList、MoviePilot 等工具如果用了同一个端，也会互踢——说明里写清楚「请选一个别的工具没用的端」。

流程（`begin_login` / `login_state` / `cancel_login`）：

1. `GET qrcodeapi.115.com/api/1.0/{端}/1.0/token/` 取二维码（`uid`、`time`、`sign`），宿主在设置页渲染；
2. 轮询 `GET qrcodeapi.115.com/get/status/`：未扫、已扫待确认、已确认、已取消、已过期；
3. 已确认后 `POST qrcodeapi.115.com/app/1.0/{端}/1.0/login/qrcode/` 换出 Cookie（`UID`、`CID`、`SEID`、`KID`）。

凭据只存这四个 Cookie 与登录端，不存别的。Cookie 本身不轮换，失效只能重新扫码。

### 2.2 Cookie：浏览器扩展导入（方便）

用户在已登录 115 的网页上点 MovieClaw 浏览器扩展，扩展把 115 的 Cookie 推给宿主（内核侧见 cloud-storage.md §11.5）。
插件实现 `login_with_cookie(cookie_header)`：从中挑出上面四个 Cookie，调用户信息接口校验，成功即得到凭据。

代价：这是**网页端**的登录态，NAS 与浏览器共用同一个会话。

- 用户在别的电脑上登录 115 网页版，会把它踢下线。扩展开着自动同步时，浏览器重新登录后会把新 Cookie 推过来，
  能自己恢复；在没装扩展的电脑上登录就恢复不了，要回到装扩展的浏览器重新点一次。
- 设置页的账号卡片标明「网页端登录态，与浏览器共用」，并给出「改为扫码登录（更稳定）」的入口。

### 2.3 开放平台（以后补）

设备码 + PKCE：`POST qrcodeapi.115.com/open/authDeviceCode`（AppID + code_challenge）→ 扫码 →
`POST /open/deviceCodeToToken` 换出 `access_token` / `refresh_token`；续期 `POST /open/refreshToken`（只要 refresh_token）。
**只需要 AppID，不需要应用密钥，也就不需要令牌中转服务**；AppID 可以写进开源插件。要点：

- `access_token` 约 2 小时，提前 15 分钟刷新；`refresh_token` **一次性**，刷新后旧的作废——插件把新凭据交回宿主，
  宿主先落库再用（cloud-storage.md §11.3）；
- 同一个 AppID 对同一账号最多同时登录 2～3 处，新的踢掉最早的；
- 刷新返回 40140115 / 40140116 / 40140119 / 40140120 → `AuthExpired`；40140117 / 40140121 → `Transient`。

【待实测】Cookie 方式与开放平台方式看到的文件 id / pick_code 是否同一套（p115client 用同一套下载调用服务两种客户端，
推断是）。是的话用户从 Cookie 换到开放平台**不用重传**，云端副本照常可用。

### 2.4 失效判断

用户信息接口返回未登录 → `AuthExpired`（宿主把账号标成要重新登录）。**只有确认认证失效才这么报**：限流、风控、
网络错误都不算——SmartStrm #45 就是把限流误判成令牌失效，逼用户反复重新授权。

## 3. 秒传

宿主上传任务先调 `rapid_upload(...)`，传入已算好的指纹（全文 SHA1、前 128KB SHA1、大小）和一个**区间读取器**
（`RangeReader.read(offset, length)`，读宿主那份本地文件）。

| 登录方式 | 初始化接口 |
|---|---|
| Cookie | `POST uplb.115.com/4.0/initupload.php`（带 `userid`、`userkey`，请求签名，响应 ECDH 加密） |
| 开放平台 | `POST proapi.115.com/open/upload/init`（`fileid`、`preid`、`target`） |

两者的结论一致：

1. `status == 2`：秒传命中，文件已在目标目录，返回 `RemoteFile`（文件 id、pick_code）。
2. `status` 为 7（以及 6 / 8）：**二次校验**。响应给出 `sign_key` 与 `sign_check`（一个字节区间）；用区间读取器读出这段、
   算 SHA1（大写），带上 `sign_key`、`sign_val` 再初始化一次，再按 2 判断。≥ 1 MB 的文件基本都会要求这一步——
   只有哈希不行，这也是内核要求「本地字节在时才上传」的原因之一。
3. 其他：需要真上传，返回 `None`，把初始化响应（OSS 目标、回调参数、pick_code）放进续传状态交回宿主，
   紧接着的 `upload()` 直接用，不再初始化一次。

秒传只消耗 1～2 次接口调用、不传字节。【待实测】命中率：从 NAS 片库抽样（新近 PT 资源、老资源、原盘 / remux / web-dl
各一批）统计，作为价值评估的输入，不影响实现。

## 4. 分片续传上传

秒传不中时宿主调 `upload(...)`，传入 `UploadSource`（宿主限速的顺序读取器，cloud-storage.md §5.3）、续传状态、
状态回写回调与进度回调。字节都传到阿里云 OSS，两种登录方式只在「怎么拿 OSS 临时凭证」上不同。

1. 拿 OSS 临时凭证（AccessKeyId / Secret / SecurityToken、过期时间、endpoint）：开放平台 `GET /open/upload/get_token`，
   Cookie 方式走对应的网页接口【待实测：以 p115client 的实现为准】。过期前 5 分钟换新；OSS 报凭证错误时强制换新重试一次。
2. **≤ 512 MB**：单次 PUT，带 115 给的回调参数（`callback` / `callback_var`）。
3. **> 512 MB**：OSS 分片上传。分片 20 MB 起，文件越大分片越大（保证不超过 OSS 的 10000 片上限）；
   `InitiateMultipartUpload` → 逐片 `UploadPart`（并发 2～3 片，【待实测】）→ `CompleteMultipartUpload`（带回调）。
4. **断点**：每完成一片就经回调交回续传状态（`bucket`、`object`、`upload_id`、已完成分片号与 ETag、SHA1、pick_code），
   宿主写进任务状态。重启或暂停后：先向 115 续传接口拿回目标，OSS 目标变了就丢掉 `upload_id` 从头传；没变则
   `ListParts` 对一下已完成的分片后续传。
5. **完成**：OSS 回调的响应里有文件 id；回调成功但文件信息短暂查不到时不判失败（交给 §5 核验重试）。

插件不自己限速、不自己重试网络错误：抛 `Transient` / `RateLimited`，由宿主的任务重试（续传状态保证不白传）。

## 5. 核验

`stat(remote_id)`：取文件大小与 SHA1。宿主拿它与本地指纹比对，**对上才把副本标成已核验**，才允许释放本地
（cloud-storage.md §6）。查不到返回 `NotFound`。

## 6. 纳管：列目录与操作动态

### 6.1 列目录

- `list_dir(dir_id)`：目录选择器按需展开，只列子目录（名称、id、文件数）。
- `list_tree(dir_id)`：整棵树的文件，每条给相对路径、大小、SHA1、文件 id、pick_code。用 115 的整树列举（列表接口
  `cur=0` 时返回所有子孙文件，LitePan 的 `ListAllFiles` 同理），分页拉完；目录 id → 路径用一次目录列举建表翻译。
  几千个文件只要几次调用。只返回视频与外挂字幕扩展名的文件；原盘目录（含 `BDMV` / `VIDEO_TS`）与 ISO 单独计数返回，
  宿主写进纳管报告。

### 6.2 操作动态

`changes(cursor)`：拉 115 的操作动态（Cookie 方式可用；开放平台【待实测】），返回自游标之后的事件与新游标：

| 115 事件 | 交给宿主 |
|---|---|
| 上传文件、转存（接收文件）、移动文件 | `added` / `moved`（文件 id、所在目录 id、名称、大小、SHA1） |
| 新建目录、目录改名、复制目录 | `dir_changed`（宿主据此把相关目录列入下次复查） |
| 删除文件 | `removed`（文件 id） |

- 浏览、星标这类不改东西的事件丢掉。
- **盲区**（p115client 的注释）：115 不记「复制文件」「文件改名」，第三方上传可能没有上传事件；从回收站还原不产生事件，
  原来的删除事件会消失。所以宿主另有每周复查（cloud-storage.md §4.3）。
- 网页端登录态只能拉到最近 1 万条，游标落后太多时返回 `cursor_expired`，宿主改做一次复查再从最新开始。

## 7. 目录、移动、改名、删除、容量

| 方法 | 说明 |
|---|---|
| `ensure_dir(path)` | 宿主给相对于库主文件夹的路径（`片名 (年份)`），插件逐级查找或创建，返回目录 id。已存在同名目录直接用。路径→目录 id 的缓存放插件数据，id 失效（被用户手动删了）时清掉重建 |
| `move(remote_id, dir_id)` / `rename(remote_id, name)` | 条目转移、整理改名时用 |
| `delete(remote_ids)` | **进 115 回收站，不清回收站**。宿主只传台账里的文件 id，只在用户确认的删除与回收站清理时调用，且有批量阈值（cloud-storage.md §10） |
| `account_info()` | 昵称、会员、容量（总 / 已用），设置页与上传前的空间检查用 |

两种登录方式各有对应接口（Cookie 走网页接口，开放平台走 `/open/folder/add`、`/open/ufile/move`、`/open/ufile/update`、
`/open/ufile/delete`、`/open/user/info`），以 p115client 的实现与 115 开放文档为准。

## 8. 直链

`direct_link(remote_id, user_agent)`，**请求时带指定的 User-Agent**，返回直链与可复用时长：

| 登录方式 | 接口 |
|---|---|
| Cookie | `POST proapi.115.com/app/chrome/downurl`（载荷 RSA 加密，`pickcode`） |
| 开放平台 | `POST proapi.115.com/open/ufile/downurl`（`pick_code`） |

- 默认取流方式是**家里转发**（cloud-storage.md §7.2）：服务器用插件的默认 UA 取链、自己拉流，播放器不接触直链，UA 与
  跟随跳转的问题都不存在。
- 只有「直连网盘」时才用播放器的 UA 取链再 302；宿主按（账号、文件、UA 类别）另行缓存。
- **不要对已删除的文件取链**：会失败，且容易触发风控（p115client 的注释）。宿主只对已核验、未进回收站的副本取链。
- 【待实测】直链时效（LitePan 按 5 分钟缓存，偏保守）；同一账号、同一文件允许的并发连接数（决定默认同时播放数）；
  单连接速度（会员 / 非会员）；直链是否绑 IP、是否校验 Referer；浏览器 `<video>` 跟 302 跨域是否可播。

## 9. 配额与风控

- 宿主按账号限速（默认 1.2 次 / 秒）并设每日预算（默认 8000 次），按优先级排队：播放 > 用户操作 > 后台（纳管、上传、
  规格补探、动态、复查）（cloud-storage.md §8）。依据：网友经验 115 会员每天约 1～1.5 万次操作、最好不超过 5 次 / 秒；
  SmartStrm 默认 2 次 / 秒；LitePan 操作间隔 800 毫秒。今年 2 月开放平台曾大面积限流（SmartStrm #51、#63）；Cookie 接口
  有自己的风控（「访问频繁」），【待实测】阈值。
- 开放平台返回 770004（已达到当前访问上限）、Cookie 接口返回访问频繁类错误 → `RateLimited`，带建议等待时长；
  宿主把该账号的后台操作整体推迟，播放照常尝试。
- 每个 HTTP 请求都设超时（连接 10 秒、读 30 秒；整树列举与 OSS 分片放宽）——SmartStrm #152 因 115 请求没设超时卡死 4 天。
- Cookie 接口是 115 的非公开接口，**改版会坏**：认不出的响应抛 `ApiChanged`，宿主把账号标「接口异常」并在设置页提示
  更新插件；插件仓库维护者跟进 p115client 的版本。

## 10. 分步交付

| 里程碑 | 插件要做的 |
|---|---|
| 一：115 里的片子能看 | 登录（扫码、Cookie 导入）、账号信息、`list_dir` / `list_tree` / `changes`、`stat`、`direct_link` |
| 二：新片上 115、本地腾空 | `ensure_dir`、秒传、分片续传上传、`move` / `rename` / `delete` |

## 11. 验证

- **插件仓库**：契约检查（`check_plugin`）+ 包内单测，对一个仿 115 的本地服务（扫码登录各状态、整树列举分页、操作动态
  各事件与游标过期、初始化的 2 / 7 分支、区间挑战、OSS 单段与分片、续传、凭证过期、限流、登录失效、接口改版）跑全流程。
- **真账号实测（里程碑一之前）**：§8 直链各项与同时播放数；整树列举几千文件的耗时与调用数；操作动态覆盖哪些操作；
  扫码选端后浏览器、其他工具是否被踢；扩展导入的网页登录态能用多久。
- **真账号实测（里程碑二之前）**：§3 秒传命中率抽样；分片并发与上行吃满时的速度；连续上传一小时是否触发风控。
  结论回填本文【待实测】处。
- **端到端**：里程碑一——扫码加账号（另测扩展导入）→ 建 115 库勾选已有文件夹 → 纳管报告 → 海报墙 → 家里与外面各播一部
  （转发、直连、自动）→ 在 115 App 里转存一部，几分钟后出现在库里。里程碑二——订阅下一集 → 下载入库 → 上传（秒传与
  真传各一例）→ 核验 → 本地腾空 → 删除条目进 115 回收站。
