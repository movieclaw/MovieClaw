# MovieClaw 云端协议

> 本文是正式版本；云端仓库（movieclaw-cloud）的 `docs/protocol/cloud-protocol.md` 是和云端实现同步维护的副本，两边改动要同步。实例端怎么落地见 [`cloud-push.md`](cloud-push.md)。

本文是 MovieClaw 实例和 MovieClaw 官方服务（以下称「云端」）之间的协议：发现文档、实例认领、权限范围、续签与上报、解绑。只有官方云端用它。

推送中继的协议另见公开仓库 [movieclaw/MovieClaw-Push 的 `docs/protocol.md`](https://github.com/movieclaw/MovieClaw-Push/blob/main/docs/protocol.md)，推送内容的加密格式见 [`push-payload.md`](push-payload.md)。

## 1. 原则

- 只有实例管理员登录云端；家庭成员和 App 永远不登录，App 需要的云端信息都由实例转交。
- App 从不连接云端。
- 推送免费，但实例**必须先认领**才能使用官方中继。**未认领时，实例对云端不发任何请求。**
- 云端不知道实例下载了什么：上报只包含聚合的、和内容无关的信息（第 6 节），协议公开，官网隐私政策里有一节专门讲服务器会发什么、为什么发、能不能关。
- `push` 以外的权限，除了在官网批准，还必须由实例管理员在实例自己的设置页里再确认一次（第 5 节）。

## 2. 地址与发现

| 地址 | 给谁用 |
| --- | --- |
| `https://<域名>` | 管理员的浏览器：登录、批准认领、管理实例 |
| `https://api.<域名>` | 实例：发现文档、认领、续签与上报 |
| `https://push.<域名>` | 实例：推送中继 |

`api.<域名>` 和 `push.<域名>` 写进每个实例版本，**上线后永不更改**。以后迁移服务，靠发现文档给出新地址。

实例支持用环境变量 `MOVIECLAW_CLOUD_URL` 覆盖云端地址（替代 `https://api.<域名>`），用于开发、预发环境和分支版本。

### 2.1 发现文档 `GET /.well-known/movieclaw-cloud`

```json
{
  "api": "https://api.example.com",
  "push_endpoints": [
    {"url": "https://push.example.com", "priority": 1},
    {"url": "https://push2.example.com", "priority": 2}
  ],
  "min_instance_version": "0.30.0",
  "control_endpoint": null,
  "remote_domain": null
}
```

| 字段 | 说明 |
| --- | --- |
| `api` | api 地址。之后的认领、续签都用它 |
| `push_endpoints` | 推送中继地址，按 `priority` 从小到大依次尝试：单个 IP 被墙或域名被污染时，换用下一个。主备中继认同一个实例令牌 |
| `min_instance_version` | 云端还支持的最低实例版本，空串表示不限。低于它的实例续签会被拒绝 |
| `control_endpoint` | 预留：以后实例与云端的长连接地址，本期为 `null` |
| `remote_domain` | 预留：以后远程访问用的独立域名，本期为 `null` |

实例要缓存发现文档（建议每次续签时顺带刷新），拉取失败时用缓存；从没拉到过时用内置的官方地址。响应带 `Cache-Control: max-age=300`。

## 3. 响应格式

| 接口 | 格式 |
| --- | --- |
| 发现文档 | 上面的样子 |
| `/v1/instance/device-code`、`/v1/instance/token` | RFC 8628 的标准响应；错误是 RFC 6749 §5.2 的 `{"error": "…", "error_description": "…"}` |
| 其余（`/v1/instance/renew`、`/v1/instance/unbind`） | 沿用 MovieClaw 的结构，实例可以复用解析代码 |

MovieClaw 结构：

```json
{"success": true, "code": "OK", "message": "success", "data": {…}}
{"success": false, "code": "INSTANCE_REVOKED", "message": "这台实例已经解绑，请在实例的「设置 → MovieClaw Cloud」里重新连接"}
```

`message` 是给人看的中文说明，实例可以原样显示在设置页。

## 4. 实例认领（RFC 8628 设备授权）

不用网页跳转回调：实例地址大多是局域网 IP，官网没法安全地往任意地址回跳。

```
实例设置页「连接」 → POST /v1/instance/device-code → 显示配对码和「去官网批准」
管理员 → <域名>/activate?code=WDJB-MJHT → 登录 → 核对后批准
实例 → 每 5 秒 POST /v1/instance/token → 批准后拿到凭证
```

### 4.1 申请配对码 `POST /v1/instance/device-code`

请求（`application/x-www-form-urlencoded`，也接受 JSON）：

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `instance_name` | 是 | 实例名称，最长 64 个字符，显示在批准页上 |
| `instance_version` | 否 | 实例版本 |
| `scope` | 否 | 申请的权限，本期只能是 `push`（默认） |

响应：

```json
{
  "device_code": "69LfOjzKgWhBHYBDelmabESO5w5QQY204ssSz5ITy2Q",
  "user_code": "WDJB-MJHT",
  "verification_uri": "https://example.com/activate",
  "verification_uri_complete": "https://example.com/activate?code=WDJB-MJHT",
  "expires_in": 600,
  "interval": 5
}
```

- `device_code` 只有实例知道，**不能显示、不能写日志**。
- `user_code` 由 20 个辅音字母组成（`BCDFGHJKLMNPQRSTVWXZ`），8 位，写成 `XXXX-XXXX`，输入时忽略大小写和连字符；只能用一次，10 分钟过期。
- 实例页面显示配对码和「去官网批准」按钮，按钮在新标签页打开 `verification_uri_complete`。
- 同一 IP 每小时最多申请 30 次，超过返回 429 `slow_down`。
- 错误：400 `invalid_request`（缺 `instance_name`）、400 `invalid_scope`。

### 4.2 批准页（官网）

管理员登录后，批准页显示：实例名、版本、申请的权限及说明、发起时间、发起地区，以及「批准后这台服务器将以你的名义使用推送」的提醒。发起地区按发起请求的网络出口估算（离线 IP 库），实例走代理时显示的是代理所在地，页面上写明这一点。

防钓鱼：

- 配对码只能用一次、10 分钟过期；
- 同一账号 10 分钟内输错 5 次、同一 IP 输错 20 次后暂停输入 10 分钟；
- 一个配对码在官网最多被打开 10 次，超过即作废（防止同一个码被群发给很多人）；
- 本期就算被骗批准，攻击者也只是给自己的实例开通了推送，碰不到你的设备。这个理由只对 `push` 成立，其他权限靠第 5 节的「实例本地再确认」兜底。

### 4.3 轮询 `POST /v1/instance/token`

请求（表单或 JSON）：

| 参数 | 说明 |
| --- | --- |
| `grant_type` | 固定为 `urn:ietf:params:oauth:grant-type:device_code` |
| `device_code` | 4.1 拿到的 `device_code` |

未完成时返回 400 和 RFC 8628 的错误码：

| `error` | 含义 | 实例怎么做 |
| --- | --- | --- |
| `authorization_pending` | 管理员还没处理 | 按间隔继续轮询 |
| `slow_down` | 轮询太快 | 间隔加 5 秒（之后一直用新间隔），继续轮询 |
| `access_denied` | 管理员拒绝了 | 停止轮询，页面提示已拒绝 |
| `expired_token` | 配对码过期 | 停止轮询，提示重新发起 |
| `invalid_grant` | `device_code` 不对或已经用过 | 停止轮询，提示重新发起 |

批准后的第一次轮询返回 200，同时生成实例：

```json
{
  "access_token": "eyJhbGciOiJFZERTQSIs…",
  "token_type": "Bearer",
  "expires_in": 86400,
  "scope": "push",
  "instance_id": "7deac17f-022a-449f-bec4-0ab18dc5d27b",
  "instance_secret": "mcs_EKC5PFBFOLKJVCj-7FtO…",
  "scopes": ["push"],
  "limits": {"day": 1000, "device_day": 100},
  "capabilities": ["push"],
  "renew_interval": 3600,
  "account": {"display": "y•••@gmail.com"}
}
```

凭证明文只出现在这一次响应里；`device_code` 随即作废。

`account.display` 是批准这次连接的账号的显示标识，实例设置页用它显示「连在谁的账号下」：邮箱只留首字和域名（`y•••@gmail.com`），没有邮箱时是名字的首字加 `•••`，都没有时是空串。云端不把完整邮箱发给实例，实例的数据库被拿走也泄露不了完整邮箱。

### 4.4 两种凭证

| 凭证 | 有效期 | 存放 | 用途 |
| --- | --- | --- | --- |
| `instance_secret` | 长期，直到解绑 | 实例数据库加密存储（`movieclaw_db.crypto`）；云端只存哈希 | 续签、解绑 |
| `access_token` | 24 小时 | 和 `instance_secret` 一起加密存储（重启时云端恰好连不上，也能用到过期为止） | 调官方推送中继。实例把它当作不透明的字符串，原样放进 `Authorization: Bearer` |

- `instance_secret` 以 `mcs_` 开头，便于识别泄露。实例只把它发给 `api` 地址，**不发给任何中继**。
- `access_token` 只发给内置的官方中继（地址来自发现文档）或管理员配置过的中继。
- 实例重装后需要重新认领。旧实例在官网显示最后活跃时间，由管理员手动解绑。

## 5. 权限范围

- 本期只签发 `push`。以后的控制、远程访问各是一个独立的权限范围；加功能时不需要所有实例重新认领，只需要申请新的范围（重新走一次第 4 节，`scope` 写新范围）。
- `capabilities` 是云端当前提供的能力，实例对比自己已授予的 `scopes`，就知道还能申请什么。
- **实例本地再确认**：`push` 以外的权限，除了在官网批准，还必须由实例管理员在实例自己的设置页里再确认一次。云端下发的每条指令，实例都要按本地已授予的范围核对，并记进实例的操作日志，管理员随时可以收回。这样即使云端被攻破，也碰不到没授权的实例。

## 6. 续签与上报 `POST /v1/instance/renew`

实例每小时调一次（`renew_interval`），用 `instance_secret` 鉴权：

```http
POST /v1/instance/renew
Authorization: Bearer mcs_…
Content-Type: application/json

{
  "report": {
    "instance_version": "0.30.0",
    "runtime_version": "python 3.13.7",
    "os": "linux",
    "arch": "arm64",
    "devices": [
      {"platform": "ios", "app_version": "0.2.0", "count": 2},
      {"platform": "tvos", "app_version": "0.2.0", "count": 1}
    ],
    "relay": {"reachable": true, "checked_at": "2026-10-01T07:12:58Z", "last_success_at": "2026-10-01T07:10:00Z"}
  }
}
```

### 6.1 `report` 字段

`report` 只包含聚合的、和内容无关的信息。云端忽略不认识的字段（也不保存），以后加统计项不用升版本。

| 字段 | 类型 | 用途 | 能否关闭 |
| --- | --- | --- | --- |
| `instance_version` | 字符串 | 判断兼容性，决定 `min_instance_version` | 不能，续签必需 |
| `runtime_version` | 字符串 | 同上（如 `python 3.13.7`） | 不能 |
| `os`、`arch` | 字符串 | 同上（如 `linux`、`arm64`） | 不能 |
| `devices` | 数组 | 可推送设备数，按平台（`ios`、`tvos`）和 App 版本汇总：判断什么时候能停用旧的密文格式；按设备数调整限额；官网实例详情里展示 | 能 |
| `relay` | 对象 | 实例这一侧看到的官方中继连通情况，见下表：中继收不到请求时，只有实例知道自己连不上 | 能 |

`relay` 的字段（时间都是 RFC 3339）：

| 字段 | 说明 |
| --- | --- |
| `reachable` | 最近一次调官方中继（推送或下面的例行检查）有没有收到答复。收到 `401`、`503` 也算连得通 |
| `checked_at` | 最近一次调官方中继的时间 |
| `last_success_at` | 最近一次成功推送的时间，没推送过时省略 |
| `error` | 只在 `reachable` 为 false 时出现：连不上的原因，给人看（如「连接超时（10 秒）」） |
| `failing_since` | 只在 `reachable` 为 false 时出现：从什么时候开始一直连不上 |

- **例行检查**：实例每次续签前，带上 `access_token` 调一次官方中继的 `GET /v1/info`（推送中继协议第 4.1 节），用结果更新 `relay`。这样没有推送的时候，中继也能看到实例每小时来一次，官网的「最近一次连接」以中继记下的为准。
- `relay` 存在实例的数据库里，重启后不丢；从来没调过官方中继时省略。
- 云端只在 `reachable` 为 false 时用它说明「实例连不上推送中继」，连得通时以中继自己的记录为准。老版本实例只上报 `reachable` 和 `last_success_at`，云端照常处理。

推送条数、失败次数不需要上报：中继自己有计数，而且中继的计数才是可信的。

明确**不上报**：

| 信息 | 为什么 |
| --- | --- |
| 事件类型（开始下载、已入库……）、片名、站点、下载器、媒体库规模、订阅数 | 云端会因此掌握各实例的下载活动，连同账号身份就是一份「谁在什么时候下载了什么」的记录。不持有，就没得可交，也没得可泄露 |
| 成员数量、哪个成员收到了推送 | 云端不保存「人 → 手机」的对应关系 |
| 设备名、设备型号、手机 IP | 不需要；按平台和 App 版本汇总就够了 |

让用户能核实：

- 官网隐私政策的「你的服务器会发给我们什么」一节逐项列出上报内容、用途和能不能关；实例「设置 → MovieClaw Cloud」里有链接直达这一节；
- 统计项有开关，默认开；关掉后 `report` 里不带 `devices` 和 `relay`，推送功能不受影响，只是官网少一些展示。例行检查照常进行，它是中继能看到实例在线的依据。开着统计但一台可推送的设备都没有时，`devices` 是空列表 `[]`（官网显示「0 台」），不能省略——省略表示关了统计；
- 中继侧的计数是提供服务（限额）所必需的，不受这个开关控制，在隐私政策里写明。

### 6.2 响应

```json
{
  "success": true, "code": "OK", "message": "success",
  "data": {
    "instance_id": "7deac17f-…",
    "access_token": "eyJ…",
    "token_type": "Bearer",
    "expires_in": 86400,
    "expires_at": "2026-10-02T07:13:00Z",
    "scopes": ["push"],
    "limits": {"day": 1000, "device_day": 100},
    "capabilities": ["push"],
    "renew_interval": 3600,
    "account": {"display": "y•••@gmail.com"},
    "notices": [
      {"id": "instance_version_outdated", "level": "warning",
       "message": "你的实例版本 0.29.0 即将不再受 MovieClaw 官方推送支持，请尽快升级到 0.31.0 或更高版本，否则推送会停止。"}
    ]
  }
}
```

- 令牌有效期 24 小时、每小时续签，所以云端宕机一天以内推送都不受影响。续签失败时按指数退避重试（最长间隔 1 小时），旧令牌在过期前照常使用。
- 续签间隔和退避间隔都要加 ±10% 的随机抖动，云端故障恢复时各实例不会挤在同一时刻续签。
- `account` 同 4.3，每次续签都返回当前的值，实例用它覆盖本地保存的。
- `notices` 是给实例管理员看的服务通知，只在实例设置页显示，不推送到手机。`level` 为 `info` 或 `warning`；实例按 `id` 去重，管理员关掉某条后，同一 `id` 不再显示。
- `limits` 是这台实例当前的限额，只用于在设置页展示；真正执行在中继，以中继每次推送响应里的 `quota` 为准。云端调整限额不用等续签，下一条推送就按新值算，这里的值在下次续签时更新。

### 6.3 错误

| HTTP | `code` | 含义 | 实例怎么做 |
| --- | --- | --- | --- |
| 401 | `UNAUTHORIZED` | `instance_secret` 不对 | 视为未连接，删除本地凭证，提示重新连接 |
| 401 | `INSTANCE_REVOKED` | 实例已在官网或实例设置里解绑 | 同上 |
| 403 | `VERSION_UNSUPPORTED` | 实例版本低于 `min_instance_version` | 显示 `message`，停止推送，提示升级。保留凭证、照常按间隔续签，升级后的第一次续签就恢复，不用重新连接 |
| 400 | `VALIDATION_ERROR` | `report` 格式不对或缺 `instance_version` | 记日志 |
| 5xx | — | 云端故障 | 退避重试 |

## 7. 解绑

- **在实例设置里解绑**：`POST /v1/instance/unbind`，`Authorization: Bearer <instance_secret>`，返回 `{"revoked": true}`，重复调用也成功。之后实例删除本地凭证。
- **在官网解绑**：实例下次续签时收到 `INSTANCE_REVOKED`，设置页显示未连接。
- **删除账号**：名下实例全部解绑；和删除并发认领出来的实例，因为主人已删除，同样当作已解绑。已批准但还没领凭证的配对码领取时返回 `access_denied`，主人已删除的实例续签返回 `INSTANCE_REVOKED`。

官方推送中继每个请求都查实例的状态，所以**解绑后下一条推送就被拒**（`401`）。实例把它当作通道暂时失败，下次续签收到 `INSTANCE_REVOKED` 时才显示未连接。中继不存设备，解绑时没有设备记录需要删除。

## 8. 推送中继的选择

- **内置官方中继**：地址来自发现文档的 `push_endpoints`，凭证是 `access_token`。
- **自建中继**：管理员在实例设置里添加（地址 + 令牌），给自签 App 用。
- 实例按设备上报的 Bundle ID，匹配 `/v1/info` 里 `topics` 声明能推送它的中继；匹配不到就在设置页提示「有 N 台设备用的是 com.xxx 版 App，没有可用的推送通道」。
- 中继在 `/v1/info` 声明 `auth.mode: none` 时，不带凭证直接推送（运营方停运时的退路）。
- 推送失败的处理见推送中继协议第 5.5 节；`rate_limited` 在 `retry_after` 之前不重试，额度紧张时优先发 `alert`。

## 9. 实例端实现要点

- 「设置 → MovieClaw Cloud」：连接、解绑；显示连接到哪个账号、已授予的权限、最近续签时间；「上报给云端的信息」区域和统计开关；云端发来的 `notices`。「设置 → App 推送」：推送通道（官方 + 自建中继）的状态、限额说明和设备覆盖。详见 [`cloud-push.md`](cloud-push.md)。
- 未认领时对云端不发任何请求。
- 请求走实例现有的出网代理配置。
- 中继协议走 HTTP/1.1 即可，加密用已有的 `cryptography`，不新增运行时依赖。

## 10. 预留（本期不实现）

- 发现文档的 `control_endpoint`、`remote_domain`。
- 权限范围：控制、远程访问各是一个独立的 `scope`，需要「实例本地再确认」。
- 会话表的 `reauth_at`：开放控制功能前，官网先上线通行密钥或二次验证，敏感操作前要求重新验证身份。
