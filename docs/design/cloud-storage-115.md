# 115 网盘存储后端插件——设计

> 状态：设计稿（2026-10-17），待实施。内核侧见 [cloud-storage.md](cloud-storage.md)，本文只写「怎么跟 115 说话」。
> 插件代码放插件仓库 [movieclaw-plugins](https://github.com/movieclaw/movieclaw-plugins) 的 `plugins/cloud-115/`，
> 不进主仓库（主程序只做通用能力，主仓库用测试内的假后端验证契约）。
> 依赖内核新契约 `storage-backends`，插件仓库 CI 要等含该契约的版本发布、`MOVIECLAW_REF` 升上去才能绿。
>
> 参考资料：115 开放平台公开文档；同类项目 LitePan（`drivers/115_Open/`，PolyForm 非商用许可）、SmartStrm
> （闭源，只有文档与 issue）。**两者的代码都不能拿来用**，下文的接口与常数来自阅读与公开文档，实现时以 115 文档为准。
> 标【待实测】的条目必须先用真账号测过再定。

## 0. 定位

实现内核契约 `StorageBackend`（cloud-storage.md §8）。插件只负责协议：登录与令牌续期、秒传、分片续传上传、
核验、取直链、移动改名删除、容量。账号存储、凭据加密、限速与配额、重试、任务、选源、淘汰、删除护栏都在宿主。

选 115 做第一个：网盘玩家里占比最高；开放平台是官方接口（不逆向）；秒传按 SHA1，正好用上宿主一次读盘算出的指纹。
第二个后端（123 云盘，MD5 秒传）用来验证契约没有被 115 的形状绑死，另起一份文档。

## 1. 能力声明

```python
StorageCapabilities(
    writable=True,
    rapid_upload_hashes=("sha1",),      # 外加前 128KB SHA1（preid），见 §3
    range_challenge=True,               # 秒传可能要求回答任意区间的 SHA1
    original_link=True,                 # 直链是原画，不是转码流
    link_needs_ua=True,                 # 直链按取链时的 User-Agent 签发
    single_conn_limit_bytes=None,       # 【待实测】VIP / 非 VIP 单连接是否限速
    recycle_bin=True,                   # 删除进 115 回收站
    max_file_bytes=None,                # 【待实测】单文件上限
    default_qps=1.2,                    # 宿主限速默认值，用户可改（§7）
    default_daily_budget=8000,          # 每日操作次数预算，用户可改（§7）
)
```

## 2. 登录与令牌

- **授权方式**：开放平台扫码授权（设备码 + PKCE）。插件实现内核的扫码登录流程：`login_start()` 返回二维码内容，
  宿主在设置页渲染；`login_poll()` 等用户扫码确认，成功后交回凭据（`access_token`、`refresh_token`、过期时间、用户 id）。
  【待定】开放平台应用资质（AppID、是否需要服务端密钥、是否要自建令牌中转服务）另行研究；契约同时支持「扫码」与
  「跳转授权 + 回调」两种，不影响本文其余部分。
- **续期**：`access_token` 约 2 小时有效，提前 15 分钟刷新。**`refresh_token` 每刷新一次就换新**：插件把新凭据作为
  返回值交给宿主，宿主先落库再继续使用（cloud-storage.md §8.3）；进程崩在两步之间时，下次用旧的会失败，按认证失效处理。
- **不能与别的程序共用同一组令牌**（OpenList、CloudDrive2、其他工具）：谁先刷新谁就让另一方的失效。设置页的添加
  账号说明里写清楚，并建议为 MovieClaw 单独授权一次。
- **错误分类**（契约要求，cloud-storage.md §8.4）：刷新返回 40140115 / 40140116 / 40140119 / 40140120 →
  `AuthExpired`（要重新扫码）；40140117 / 40140121 → `Transient`（稍后重试）。**只有确认认证失效才要求重新登录**——
  SmartStrm #45 就是把限流误判成令牌失效，逼用户反复重新授权。

## 3. 秒传

宿主上传任务先调 `rapid_upload(...)`，传入已算好的指纹（全文 SHA1、前 128KB SHA1、大小）和一个**区间读取器**
（`RangeReader`：`read(offset, length)`，读宿主那份本地文件）。

1. `POST /open/upload/init`：`file_name`、`file_size`、`target`（目录）、`fileid`（全文 SHA1，大写）、`preid`（前 128KB SHA1）。
2. 返回 `status == 2`：秒传命中，文件已在目标目录，拿到 `file_id`、`pick_code`，返回 `RemoteFile`。
3. 返回 `status` 为 6 / 7 / 8：**二次校验**。响应里有 `sign_key` 与 `sign_check`（形如 `起-止` 的字节区间）。
   用区间读取器读出这一段、算 SHA1（大写），带着 `sign_key`、`sign_val` 再调一次 init，再按 2 判断。
   这一步证明「你手里真有这个文件」，只有哈希不行——这也是内核要求「本地字节在时才上传」的原因之一。
4. 其他状态（需要真上传）：返回 `None`，并把 init 的响应（OSS 目标、回调参数、`pick_code`）放进续传状态交回宿主，
   紧接着的 `upload()` 直接用，不再 init 一次。

秒传不读整个文件、不传字节，只消耗 1～2 次接口调用。命中率是这套玩法的价值所在：【待实测】从 NAS 片库抽样
（新近 PT 资源、老资源、原盘 / remux / web-dl 各一批）统计命中率，作为设计验收的输入，不影响实现。

## 4. 分片续传上传

秒传不中时宿主调 `upload(...)`，传入 `UploadSource`（宿主限速的顺序读取器，cloud-storage.md §7）、续传状态、
状态回写回调与进度回调。

1. `GET /open/upload/get_token`：拿阿里云 OSS 的临时凭证（AccessKeyId / Secret / SecurityToken、过期时间、endpoint）。
   临时凭证过期前 5 分钟换新；OSS 返回凭证类错误时强制换新后重试一次。
2. **≤ 512 MB**：单次 PUT，带 115 给的回调参数（`callback` / `callback_var`）。
3. **> 512 MB**：OSS 分片上传。分片 20 MB 起，文件越大分片越大（保证分片数不超过 OSS 的 10000 上限）；
   `InitiateMultipartUpload` → 逐片 `UploadPart`（并发 2～3 片，【待实测】）→ `CompleteMultipartUpload`（带回调）。
4. **断点**：每片完成就通过回调交回续传状态（`bucket`、`object`、`upload_id`、已完成分片号与 ETag、文件 SHA1、
   `pick_code`），宿主写进任务状态。重启或暂停后从状态继续：先 `POST /open/upload/resume` 拿回目标，若 OSS 目标变了
   就丢掉 `upload_id` 从头传；没变则 `ListParts` 对一下已完成的分片后续传。
5. **完成**：OSS 回调的响应里有 `file_id`；回调成功但文件信息短暂查不到时不判失败（交给 §5 核验重试）。

插件不自己限速、不自己重试网络错误：抛 `Transient` / `RateLimited`，由宿主的任务重试（续传状态保证不白传）。

## 5. 核验

`stat(remote_id)`：`GET /open/folder/get_info`（文件也走这个接口）取大小与 SHA1。宿主拿它与本地指纹比对，
**对上才把副本标成已核验**，才允许淘汰本地（cloud-storage.md §5）。查不到返回 `NotFound`。

## 6. 目录、移动、改名、删除、容量

| 方法 | 接口 | 说明 |
|---|---|---|
| `ensure_dir(path)` | `/open/folder/add`（逐级） | 宿主给相对路径（`MovieClaw/电影/片名 (年份)`），插件逐级查找或创建，返回目录 id。已存在同名目录直接用。路径→目录 id 的缓存放插件数据，id 失效（被用户手动删了）时清掉重建 |
| `move(remote_id, dir_id)` | `/open/ufile/move` | 条目转移、整理改名时用 |
| `rename(remote_id, name)` | `/open/ufile/update` | 同上 |
| `delete(remote_ids)` | `/open/ufile/delete` | **进 115 回收站，不清回收站**。宿主保证只传它自己写进去的文件 id，且有批量阈值（cloud-storage.md §10） |
| `account_info()` | `/open/user/info` | 昵称、会员、容量（总 / 已用），设置页与上传前的空间检查用 |

## 7. 直链

`direct_link(remote_id, user_agent)`：`POST /open/ufile/downurl`（`pick_code`），**请求头带播放器的 User-Agent**，
返回直链与可复用时长。

- 宿主按（账号、文件、UA 类别）缓存、并发合并（同一文件起播时几路连接只取一次），见 cloud-storage.md §6。
- 网页播放器同样适用：浏览器请求我们的取流地址时带着自己的 UA，宿主用它取链再 302，浏览器跟跳转时 UA 一致。
- 服务器自己读字节（探测、转码、字幕）时用插件的默认 UA 取链，与给播放器的链接分开缓存。
- 【待实测】直链时效（LitePan 按 5 分钟缓存，偏保守）、是否绑 IP（社区 302 方案普遍可用，推断不绑）、是否校验
  Referer、单个链接允许的并发连接数、浏览器 `<video>` 跟 302 跨域是否可播、非会员是否限速。

## 8. 配额与风控

- 宿主按账号限速（默认 1.2 次 / 秒）并设每日预算（默认 8000 次），按优先级排队：取直链 > 用户操作 > 后台上传、核验、
  删除（cloud-storage.md §7）。依据：网友经验 115 会员每天约 1～1.5 万次操作、最好不超过 5 次 / 秒；SmartStrm
  默认 2 次 / 秒；LitePan 操作间隔 800 毫秒。今年 2 月开放平台曾大面积限流（SmartStrm #51、#63）。
- 返回码 770004（已达到当前访问上限）→ `RateLimited`，带建议等待时长；宿主把该账号的后台操作整体推迟，取直链不受影响
  直到同样被限。
- 每个 HTTP 请求都设超时（连接 10 秒、读 30 秒；OSS 分片按大小放宽）——SmartStrm #152 因 115 请求没设超时卡死 4 天。

## 9. 验证

- **插件仓库**：契约检查（`check_plugin`）+ 包内单测，对一个仿 115 的本地服务（init 的 2 / 6 / 7 / 8 分支、区间挑战、
  OSS 单段与分片、续传、凭证过期、770004、令牌刷新错误码）跑全流程。
- **真账号实测（实施前）**：§3 秒传命中率抽样；§7 直链各项；分片并发与上行吃满时的速度；连续上传一小时是否触发风控。
  结论回填本文【待实测】处。
- **端到端（实施后）**：真实用户路径——设置页扫码加账号 → 库开启「上传后释放本地」→ 订阅下一集 → 下载入库 →
  上传（秒传与真传各一例）→ 核验 → 本地释放 → 外网 App 播放走 302、网页播放、转码播放 → 删除条目进 115 回收站。
