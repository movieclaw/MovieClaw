# 登录设备：统一的「人 × 设备」凭证——设计

> 状态：已实施（2026-09-27）。
> 关联文档：[device-auth.md](device-auth.md)（配对码流程本身，本文改了它的
> 「谁能批准」「令牌归谁」两处）、[account-switching.md](account-switching.md)
> （网页多账号，本文把袋子里的令牌换成了表内令牌）、
> [member-management.md](member-management.md)（超管 + 成员的双身份体系）。

## 0. 问题

改造前产品里有五套各管各的长期凭证：

| 凭证 | 存在哪 | 绑定到谁 | 能否单独踢下线 |
|---|---|---|---|
| 网页会话 Cookie（原生 App 也借用它） | 不落库，签名令牌 | 超管或成员 | 不能 |
| 命令行 / 转码器令牌 | 设置项里的一段 JSON | **不绑人，一律当超管** | 能 |
| Jellyfin 播放器（Infuse） | `jellyfin_device` 表 | 超管或成员 | 能 |
| 浏览器扩展同步令牌 | 设置项 | 不绑人 | 只能重新生成 |
| 活动页的「播放设备」 | 只在内存里 | — | 网页与 App 的永远不能 |

由此带来的实际问题：

1. **App 最长 30 天必须重新输密码**——会话令牌的过期时间写死、不会续期；
2. **踢不掉一台丢了的手机**——超管的会话不落库，只能改密让所有端一起掉线；
3. **服务端回答不了「谁在哪台设备上登录着我的账号」**；
4. **命令行是「半个超管」**：只有超管能批准，令牌里不记是谁批的；管理权按超管
   算、浏览却只给全员库；成员根本用不了命令行；
5. App 为了在 Cookie 上跑起来，写了钥匙串备份 Cookie、账号袋上限 5 个、同主机
   不同端口互相覆盖等一串绕路代码。

## 1. 核心模型：一行 = 一个人授权给一台客户端

新表 `login_device`（`src/movieclaw_db/models/login_device.py`）。网页浏览器的
登录会话、原生 App、命令行、转码器、网页手工创建的令牌都是它的一行：

| 字段 | 说明 |
|---|---|
| `member_id` | 主人：成员 id，0 = 超管（成员级表的哨兵约定；删除成员时统一清理） |
| `kind` | 客户端类型：`web` / `ios` / `tvos` / `macos` / `android` / `cli` / `worker` / `manual` |
| `name` | 给人看的设备名，可改名 |
| `token_hash` | 令牌明文（`mclaw_` 前缀）的 sha256，唯一索引；明文只在签发时交付一次 |
| `scope` | `full` = 等同本人；`transcode` = 只能转码（转码器凭证的形态上限） |
| `installation_id` | 客户端自报的安装标识：同一个人在同一台设备上重新登录 / 配对时替换旧行 |
| `client_version` / `platform` / `user_agent` | 展示用：版本、系统与机型、最近一次请求的 UA |
| `last_seen_at` / `last_seen_ip` | 最近活跃（进程内节流，同一台 60 秒写一次） |
| `expires_at` | 只有网页会话有（沿用 7 天 / 记住我 30 天）；其余长期有效 |

签发方式各不相同，存储、验证、列表、注销走同一套（`services/login_devices.py`）：

| 签发方式 | 客户端 | 入口 |
|---|---|---|
| 账号密码 | 网页 | `POST /auth/login`（令牌进 HttpOnly Cookie） |
| 账号密码 | iOS / Apple TV / Mac / Android App | `POST /auth/device/login`（令牌进系统钥匙串） |
| 配对码批准 | 命令行、转码器、Apple TV、Mac App | `POST /auth/device/authorize` → 人批准 → `POST /auth/device/token` |
| 手工创建 | 无人值守的脚本、命令行模式的转码器 | `POST /auth/tokens`（超管） |

Jellyfin 播放器的凭证受协议约束多（令牌格式、同设备覆盖语义），暂时仍在
`jellyfin_device` 表，只在「我的设备」上**合并展示**、同一个入口注销
（设备 id 形如 `jf-<n>`；登录设备形如 `ld-<n>`）。并表是后续工作。

## 2. 权限：验签时按主人装配

- 设备令牌验签后产出的 `Principal` 与网页登录**完全同构**：kind 是 `admin` /
  `member`，只多带一个 `device`（`DeviceRef`：id、kind、scope、name）。全站按
  「超管 / 成员」分支的授权代码一行都不用改。
- 主人每次现查：成员被停用立即失效；管理员事后改成员的能力开关，他的 App、
  命令行立刻跟着变。
- 形态上限只有一条：`scope=transcode` 的凭证在 `require_login` 里被默认拒绝，
  只有转码控制面（`resolve_worker_principal`）与「注销自己」放行。守护测试
  遍历全路由验证（`tests/api/test_device_auth.py`）。

## 3. 签发权：按客户端类型，不按登录方式

| 客户端 | 能批准配对 / 创建令牌 | 能管理别的设备 | 能注销自己 |
|---|---|---|---|
| 浏览器、原生 App（人直接操作的第一方客户端） | 能 | 能（自己的；超管能管全体） | 能 |
| 命令行、转码器、手工令牌 | 不能 | 不能 | 能 |
| Agent、MCP 内部令牌 | 不能 | 不能 | — |

- 这道闸防的是「令牌自我复制」：命令行令牌会以环境变量交给 Agent 和脚本，是
  最容易泄露的一类，若能给自己再签一枚，注销原来那枚就止不住损；若能注销别的
  设备，一枚泄露的令牌就能把主人的手机踢下线。
- 判断**按客户端类型、不按登录方式**（`KindSpec.interactive`）：将来扫码登录、
  通行密钥上线，浏览器与 App 照样是「人在操作」，规则不用改。
- Cookie 通道只认 `kind=web` 的行：把命令行令牌塞进 Cookie 不会让它变成浏览器。
- 升级前签发的签名会话 Cookie 只可能来自浏览器，按人在操作处理。
- 依赖：`require_interactive`（成员也可）、`require_admin_session`（超管 + 人在
  操作）、`require_device_principal`（任何设备凭证，含转码器，只用于「自己」）。

## 4. 配对：谁批准，令牌就是谁的

改自 device-auth.md：

1. **成员也能批准自己的命令行**，令牌的身份与权限就是这个成员；
   **转码器只能由超管批准**（转码是整台服务器的资源）。
2. **按配对码批准，不再列出全部待批准请求**。`authorize` 响应多了
   `verification_uri_complete`（`/activate?code=MCLW-XXXX`，独立的批准页；旧地址 `/settings/devices?code=` 会跳过去），设备应
   优先打开它；批准页只显示这一条（`GET /auth/devices/requests/{code}`）。成员
   之间看不到彼此的请求，管理员也不会误批一个成员的命令行、让它拿到超管权限。
   打不开链接的无头机器，人在网页的批准页（`/activate`）或 App 的批准页手动输入配对码；
   iPhone App 在「我的」页右上角（搜索左边）有扫码钮，扫设备上的二维码直达批准页。
3. `authorize` 可选上报 `installation_id` / `platform` / `client_version`：同一台
   机器重新配对时替换旧令牌，批准页与设备列表也能写清楚是哪台机器。
4. 兑换响应的 `granted_by` 是批准者的用户名（「你现在是谁」）。

## 5. 失效联动

| 事件 | 密码换来的（网页、App、Jellyfin 播放器） | 配对 / 手工的（命令行、转码器、手工令牌） |
|---|---|---|
| 本人改密 | 除当前这台外全部下线 | 默认保留；改密对话框勾选「同时注销命令行和转码器」则一并注销 |
| 管理员重置成员密码（多半是忘了密码） | 全部下线 | 保留 |
| 超管离线重置密码（`reset_password`） | 全部下线 | 保留 |
| 成员被停用 / 删除 | 全部下线（行删除，重新启用不复活） | 全部下线 |
| 成员管理页「全部下线」 | 全部下线 | 全部下线 |
| 注销某台设备 | 立即失效，并停掉它在播的流与转码会话、断开转码器连接 | 同左 |
| 长期不用 | 不自动失效（界面可提示）；设备页「清理…」可一次注销 N 天没用过的 | 同左（连着的转码器不清） |

- 配对的默认保留：转码器常年无人值守，改个密码就停转码很难排查；怀疑密码泄露时
  应勾选一并注销。
- 超管改密仍轮换全局签名密钥（升级前的签名会话、在途取流 token 等短时凭证一并
  作废），但**不再连坐成员**——成员的设备与超管的密码无关。
- 退出登录（网页 `/auth/logout`、从浏览器移除账号、App 退出）在服务端作废令牌，
  而不只是删本地 Cookie / 钥匙串。

## 6. 接口

| 接口 | 鉴权 | 说明 |
|---|---|---|
| `POST /auth/device/login` | 公开（限速同网页登录） | App 登录：`{username, password, client: {kind, installation_id, name?, platform?, client_version?}}` → `{token, device, session}` |
| `GET /auth/devices?all=` | 人在操作 | 我的设备（当前设备置顶）；`all=true` 仅超管，带主人 |
| `GET /auth/devices/current` | 任何设备凭证 | 当前这台（`mclaw status` 用） |
| `DELETE /auth/devices/current` | 任何设备凭证 | 注销自己（`mclaw logout`、App 退出、转码器断开配对） |
| `PATCH /auth/devices/{id}` | 人在操作 | 改名（Jellyfin 播放器不可改名） |
| `DELETE /auth/devices/{id}` | 人在操作 | 注销（自己的；超管可注销任何人的） |
| `POST /auth/devices/cleanup` | 人在操作（`all` 仅超管） | 清理：`{inactive_days, all?, dry_run?}`，注销最近活跃（没有就按签发时间）早于 N 天的设备与 Jellyfin 播放器；本机、此刻连着的转码器不清。`dry_run` 只列名单给确认框用 |
| `GET /auth/devices/requests/{code}` | 人在操作 | 按配对码查看一条待批准请求（含 `requires_admin`） |
| `POST /auth/devices/requests/{code}/approve\|deny` | 人在操作（转码器需超管） | 批准 / 拒绝 |
| `POST /auth/tokens` | 超管 + 人在操作 | 手工令牌：`{name, scope: full\|transcode}` |
| `POST /members/{id}/sign-out` | 超管 + 人在操作 | 让成员在全部设备上下线 |
| `PUT /auth/password` | 登录 | 新增 `sign_out_paired` |

`GET /auth/me` 的 `SessionView` 新增 `device`（当前设备 id / 类型 / 名字）；成员
视图新增 `device_count`。设备视图带 `connected`：此刻有没有活着的转码控制连接——转码器
只在握手时验一次凭证、之后靠心跳在线，列表上的在线状态以它为准（其余设备没有长连接，
按 `last_seen_at` 最近 5 分钟判断）；转码器的每条控制消息也会刷新 `last_seen_at`。删除了 `GET/DELETE /auth/tokens`、`GET /auth/devices/requests`
（被上表取代）。

## 7. 活动页

用设备令牌（新的网页会话、App）发起的播放，设备标识就是登录设备的 `ld-<n>`
（`web_device_id(..., login_device_id=)`），不再用客户端自报的浏览器 id。于是活动页
「注销此设备」对网页和 App 也生效：注销即删凭证、结束实时会话、停取流与转码。
升级前的签名会话与分享访客仍用 `web-<成员>-<浏览器 id>`，不可注销。

## 8. 客户端

- **网页**：「设置 → 设备」对所有人开放——按配对码批准（链接带 `?code=` 时预填）、
  我的设备列表（当前设备、改名、注销）；超管另有「全部成员」视图与手工令牌。
  改密卡片多一个「同时注销命令行和转码器（N 台）」。成员管理页显示设备数、可「全部下线」。
- **iOS App**：`POST /auth/device/login` 换令牌，存钥匙串（`ThisDeviceOnly`），
  每个请求（接口、图片、事件流）带 `Authorization: Bearer`，彻底关掉 Cookie。
  多账号完全在本机：钥匙串里按「服务器 + 账号」存令牌，切换不联网。安装标识存
  钥匙串，同时作为播放上报的设备标识。退出登录调 `DELETE /auth/devices/current`。
- **命令行**：`authorize` 上报安装标识（存配置目录）、主机名、系统架构、版本；打印
  带码链接；`mclaw logout` 先在服务端注销自己；`mclaw status` 显示身份与设备。
- **转码器**：`authorize` 上报安装标识、系统、版本，打开带码链接。

## 9. 迁移与回退

- 迁移 `5b8e2c4f9a17`：建表，把配置域 `auth.api_tokens` 里的命令行 / 转码器 / 手工令牌
  原样搬进来（哈希不变，**不用重新配对**；归属超管——改造前只有超管能批准），搬完删掉
  旧配置域。
- 网页会话不迁移：升级前的签名 Cookie 仍被接受直至自然过期（最长 30 天），新登录一律
  发表内令牌。
- 回退：跨过本迁移的回退由回退选择器自动恢复升级前的数据库备份
  （in-app-update.md「多版本回退与数据兼容」）。
- iOS App 未公开发布，升级后重新登录一次，不做「旧 Cookie 换令牌」的过渡接口。

## 10. 不做 / 后续

- **Jellyfin 设备并表**：先合并展示；并表后令牌改存哈希，Infuse 不用重登。
- **浏览器扩展同步令牌**：仍是独立密钥体系，候选纳入。
- 不做令牌自动续期 / 刷新令牌、不做 OAuth Provider（理由同 device-auth.md §12）。
