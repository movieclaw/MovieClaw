# 115 网盘存储后端插件——设计

> 状态：设计稿（2026-10-17），待实施。内核侧见 [cloud-storage.md](cloud-storage.md)，本文只写「怎么跟 115 说话」。
> 插件代码放插件仓库 [movieclaw-plugins](https://github.com/movieclaw/movieclaw-plugins) 的 `plugins/cloud-115/`，
> 不进主仓库（主程序只做通用能力，主仓库用测试内的假后端验证契约）。
> 依赖内核新契约 `storage-backends`，插件仓库 CI 要等含该契约的版本发布、`MOVIECLAW_REF` 升上去才能绿。
>
> **用户决策（2026-10-17）：先走 Cookie 登录**（扫码选登录端 + 浏览器扩展导入），不等开放平台应用资质；
> 开放平台登录以后作为同一个 `115` 后端的第二种登录方式补上。
>
> 参考：p115client（Python，**MIT 许可**，可以依赖或借用）；115 开放平台公开文档；LitePan（`drivers/115_Open/`，
> PolyForm 非商用许可，**代码不能用**，只看思路）；SmartStrm（闭源，只有文档与 issue）。
> 标【待实测】的条目必须先用真账号测过再定。

## 0. 定位

实现内核契约 `StorageBackend`（cloud-storage.md §8）。插件只负责协议：登录、秒传、分片续传上传、核验、取直链、
移动改名删除、容量。账号存储、凭据加密、限速与配额、重试、任务、选源、释放、删除护栏都在宿主。

选 115 做第一个：网盘玩家里占比最高；秒传按 SHA1，正好用上宿主一次读盘算出的指纹。第二个后端（123 云盘，
MD5 秒传）用来验证契约没有被 115 的形状绑死，另起一份文档。

**两种登录方式、一套文件操作**：插件内部把「登录方式」做成可替换的一层（`Session`），秒传、上传、取直链按登录方式
各有一套请求实现；目录、核验、删除、指纹、续传状态、错误分类、能力声明共用。账号凭据里记着登录方式。

**实现依赖**：Cookie 方式的上传初始化与取直链都要做 115 自己的加密 / 签名（ECDH、RSA 变体、`userkey` 签名），
自己实现成本高、115 一改就得跟。插件**依赖 p115client（钉版本）**处理这些，请求经插件自己的 HTTP 客户端发出
（超时、代理、日志脱敏按插件规范）。插件以独立进程运行，依赖与主程序隔离。【待定】若 p115client 依赖树过重，
改为只借用它的加密模块（MIT 允许，保留版权声明）。

## 1. 能力声明

```python
StorageCapabilities(
    writable=True,
    rapid_upload_hashes=("sha1",),      # 外加前 128KB SHA1（preid），见 §3
    range_challenge=True,               # 秒传可能要求回答任意区间的 SHA1（≥ 1 MB 的文件基本都会）
    original_link=True,                 # 直链是原画，不是转码流
    link_needs_ua=True,                 # 直链按取链时的 User-Agent 签发
    single_conn_limit_bytes=None,       # 【待实测】VIP / 非 VIP 单连接是否限速
    read_concurrency=2,                 # 服务器读字节的并发连接上限（LitePan 用 2），【待实测】
    recycle_bin=True,                   # 删除进 115 回收站
    max_file_bytes=None,                # 【待实测】单文件上限
    default_qps=1.2,                    # 宿主限速默认值，用户可改（§8）
    default_daily_budget=8000,          # 每日操作次数预算，用户可改（§8）
)
```

## 2. 登录

### 2.1 Cookie：扫码并选登录端（推荐）

115 每种登录端（网页、安卓、iOS、电视、各小程序……）同一时间只能在线一个，新登录会把同端的旧登录踢下线。
所以扫码前让用户**选一个自己不用的端**，默认推荐「支付宝小程序」，列表里标出常见冲突：

- 「网页端」会和浏览器里的 115 互踢；
- CloudDrive2、OpenList、MoviePilot 等工具如果用了同一个端，也会互踢——说明里写清楚「请选一个别的工具没用的端」。

流程（`login_start` / `login_poll` / `login_complete`）：

1. `GET qrcodeapi.115.com/api/1.0/{端}/1.0/token/` 取二维码（`uid`、`time`、`sign`），宿主在设置页渲染；
2. 轮询 `GET qrcodeapi.115.com/get/status/`：未扫、已扫待确认、已确认、已取消、已过期；
3. 已确认后 `POST qrcodeapi.115.com/app/1.0/{端}/1.0/login/qrcode/` 换出 Cookie（`UID`、`CID`、`SEID`、`KID`）。

凭据只存这四个 Cookie 与登录端，不存别的。Cookie 本身不轮换，失效只能重新扫码。

### 2.2 Cookie：浏览器扩展导入（方便）

用户在已登录 115 的网页上点 MovieClaw 浏览器扩展，扩展把 115 的 Cookie 推给宿主（内核侧见 cloud-storage.md §8.5）。
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
  宿主先落库再用（cloud-storage.md §8.3）；
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

秒传不中时宿主调 `upload(...)`，传入 `UploadSource`（宿主限速的顺序读取器，cloud-storage.md §4.3）、续传状态、
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
（cloud-storage.md §5）。查不到返回 `NotFound`。

## 6. 目录、移动、改名、删除、容量

| 方法 | 说明 |
|---|---|
| `ensure_dir(path)` | 宿主给相对路径（`MovieClaw/电影/片名 (年份)`），插件逐级查找或创建，返回目录 id。已存在同名目录直接用。路径→目录 id 的缓存放插件数据，id 失效（被用户手动删了）时清掉重建 |
| `move(remote_id, dir_id)` / `rename(remote_id, name)` | 条目转移、整理改名时用 |
| `delete(remote_ids)` | **进 115 回收站，不清回收站**。宿主保证只传它自己写进去的文件 id，且有批量阈值（cloud-storage.md §10） |
| `account_info()` | 昵称、会员、容量（总 / 已用），设置页与上传前的空间检查用 |

两种登录方式各有对应接口（Cookie 走网页接口，开放平台走 `/open/folder/add`、`/open/ufile/move`、`/open/ufile/update`、
`/open/ufile/delete`、`/open/user/info`），以 p115client 的实现与 115 开放文档为准。

## 7. 直链

`direct_link(remote_id, user_agent)`，**请求时带播放器的 User-Agent**，返回直链与可复用时长：

| 登录方式 | 接口 |
|---|---|
| Cookie | `POST proapi.115.com/app/chrome/downurl`（载荷 RSA 加密，`pickcode`） |
| 开放平台 | `POST proapi.115.com/open/ufile/downurl`（`pick_code`） |

- 宿主按（账号、文件、UA 类别）缓存、并发合并（同一文件起播时几路连接只取一次），见 cloud-storage.md §6。
- 网页播放器同样适用：浏览器请求我们的取流地址时带着自己的 UA，宿主用它取链再 302，浏览器跟跳转时 UA 一致。
- 服务器自己读字节（探测、转码、字幕）时用插件的默认 UA 取链，与给播放器的链接分开缓存。
- **不要对已删除的文件取链**：会失败，且容易触发风控（p115client 的注释）。宿主只对已核验、未进回收站的副本取链。
- 【待实测】直链时效（LitePan 按 5 分钟缓存，偏保守）、是否绑 IP（社区 302 方案普遍可用，推断不绑）、是否校验
  Referer、单个链接允许的并发连接数、浏览器 `<video>` 跟 302 跨域是否可播、非会员是否限速。

## 8. 配额与风控

- 宿主按账号限速（默认 1.2 次 / 秒）并设每日预算（默认 8000 次），按优先级排队：取直链 > 用户操作 > 后台上传、核验、
  删除（cloud-storage.md §7）。依据：网友经验 115 会员每天约 1～1.5 万次操作、最好不超过 5 次 / 秒；SmartStrm
  默认 2 次 / 秒；LitePan 操作间隔 800 毫秒。今年 2 月开放平台曾大面积限流（SmartStrm #51、#63）；Cookie 接口有
  自己的风控（「访问频繁」），【待实测】阈值。
- 开放平台返回 770004（已达到当前访问上限）、Cookie 接口返回访问频繁类错误 → `RateLimited`，带建议等待时长；
  宿主把该账号的后台操作整体推迟，取直链照常尝试。
- 每个 HTTP 请求都设超时（连接 10 秒、读 30 秒；OSS 分片按大小放宽）——SmartStrm #152 因 115 请求没设超时卡死 4 天。
- Cookie 接口是 115 的非公开接口，**改版会坏**：插件按错误分类上报，宿主把账号标「接口异常」并在设置页提示更新插件；
  插件仓库维护者跟进 p115client 的版本。

## 9. 验证

- **插件仓库**：契约检查（`check_plugin`）+ 包内单测，对一个仿 115 的本地服务（扫码登录各状态、初始化的 2 / 7 分支、
  区间挑战、OSS 单段与分片、续传、凭证过期、限流、登录失效）跑全流程。
- **真账号实测（实施前）**：§3 秒传命中率抽样；§7 直链各项；分片并发与上行吃满时的速度；连续上传一小时是否触发风控；
  扫码选端后浏览器、其他工具是否被踢；扩展导入的网页登录态能用多久。结论回填本文【待实测】处。
- **端到端（实施后）**：真实用户路径——设置页扫码加账号（另测扩展导入）→ 库开启「上传后释放本地」→ 订阅下一集 →
  下载入库 → 上传（秒传与真传各一例）→ 核验 → 本地释放 → 外网 App 播放走 302、网页播放、转码播放 →
  删除条目进 115 回收站。
