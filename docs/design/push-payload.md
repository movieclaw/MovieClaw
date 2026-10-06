# 推送密文格式

> 本文是正式版本；云端仓库（movieclaw-cloud）的 `docs/protocol/push-payload.md` 是同步维护的副本，两边改动要同步。

推送内容端到端加密：实例加密，只有登录过这台实例的设备能解密。推送中继和云端从头到尾不接触密钥，只看得到密文。本文规定加密格式、密钥管理、各推送类型的明文结构、`collapse_id` 的生成方法和通知扩展的行为。

中继如何转发见公开仓库 [movieclaw/MovieClaw-Push 的 `docs/protocol.md`](https://github.com/movieclaw/MovieClaw-Push/blob/main/docs/protocol.md)。

## 1. 密钥

- App 为每个**登录设备**（一台实例 + 一个账号）生成一把 256 位随机密钥和一个随机的 `key_id`（8 字节随机数的 base64url，11 个字符）。
- App 把密钥、`key_id`，连同设备令牌、Bundle ID、环境（production / development）、平台（`login_device.kind`：`ios`、`tvos`……）和支持的推送类型一起交给它登录的实例。
- 实例把它们存在 `login_device` 行上（密钥加密存储），退出登录、注销设备时随行一起删除。
- 密钥放在 App Group 共享的钥匙串里，访问级别沿用 TokenVault 的 `AfterFirstUnlockThisDeviceOnly`，锁屏时通知扩展也读得到。
- App 每次启动、每次登录都重新上报令牌和密钥，令牌变化或数据丢失后能自己恢复。
- 退出登录时，App 删除本机密钥：之后那台实例推送的内容解不开，只显示通用文案。

`key_id` 是明文，多服务器、多账号时通知扩展靠它找到对应的密钥；它是随机值，不带任何语义。

## 2. 格式

```
v1.<key_id>.<nonce>.<密文>
```

| 部分 | 内容 |
| --- | --- |
| `v1` | 格式版本 |
| `key_id` | 1 节的随机 `key_id` |
| `nonce` | 12 字节随机数，base64url（无填充） |
| `密文` | AES-256-GCM 加密结果（密文 + 16 字节认证标签），base64url（无填充） |

- 算法：AES-256-GCM。
- 附加认证数据（AAD）：ASCII 字符串 `v1.<key_id>`，防止把一段密文挪到别的 `key_id` 下。
- 每条推送用新的随机 `nonce`，同一把密钥下绝不重复。
- 整串只由 base64url 字符和点组成，满足中继对 `payload` 的检查。

用 `payload` 字段交给中继；`liveactivity` 的 `content-state`、`attributes` 写成 `{"e": "<同样格式的密文>"}`。

## 3. 明文

明文是 UTF-8 JSON，按推送类型分别定义。公共字段：

| 字段 | 说明 |
| --- | --- |
| `v` | 明文结构版本，当前为 `1` |
| `type` | 和推送的 `type` 一致，防止把一种推送的密文挪到另一种里 |
| `sent_at` | 实例生成推送的时间（Unix 秒） |
| `server` | 来自哪台实例：`{"id": "…", "name": "…"}` |
| `account` | 推给这台实例上的哪个账号：`{"id": "…", "name": "…"}` |

通知扩展遇到不认识的字段忽略，遇到更高的 `v` 时尽力显示 `title`、`body`。

### 3.1 `alert`

| 字段 | 说明 |
| --- | --- |
| `title`、`body` | 标题、正文 |
| `subtitle` | 可选，副标题 |
| `image` | 可选，配图地址：带签名的相对路径（相对实例地址，如 `/api/v1/push/images/<签名>`），不需要登录凭证，见第 6 节 |
| `open` | 可选，点开后的页面：网页站内路径（如 `/subscriptions/42`），网页和 App 用同一套路由 |
| `thread` | 可选，分组（设置为通知的 `threadIdentifier`；App 会再按服务器分开，不同服务器的通知不混在一组） |
| `source` | 可选，要不要在手机上标出来源：没有这个字段 = 不标；`server` = 手机连了不止一台服务器时标服务器名；`account` = 同一台服务器上登了不止一个账号时标账号名 |
| `category` | 可选，通知类别（操作按钮、长按展开界面）；剧卡是 `item` |
| `sound` | 可选，`default` 或 App 内置的声音名；被动（`interruption-level: passive`）的推送不带 |
| `actions` | 可选，长按的快捷操作：`[{"id", "title", "open"?, "item"?}]`。`id` 为 `play`（`open` 是 `/play/...` 播放链接）、`open`（`open` 是站内路径）、`mute`（`item` 是要静音的条目）。App 点了按 `id` 处理，标题由内容扩展换上 |
| `grid` | 可选，长按时的集数格子：`{"season": 1, "cells": "sssddww-m"}`，第 1 集起每集一个字符：`s` 看过、`d` 已入库、`w` 下载中、`m` 没找到、`-` 其他；明文超长时先去掉它 |

打扰级别和摘要排序不在明文里：实例填在中继消息的 `aps`（`interruption-level`、`relevance-score`），见推送中继协议 §7。

事件清单（推给谁、什么文案、点开去哪）见 [`cloud-push.md`](cloud-push.md) 第 5 节。

### 3.2 `background`

| 字段 | 说明 |
| --- | --- |
| `refresh` | 要刷新的数据，如 `["continue_watching", "badge"]` |

### 3.3 `liveactivity`

`content-state` 和 `attributes` 的明文结构待原型验证（小组件扩展能否读共享钥匙串并在渲染时解密）后再定。

### 3.4 `widgets`

不带内容。

## 4. 大小

最终发给苹果的 JSON 不超过 4096 字节。`alert` 的通用文案、`aps` 字段和格式头大约占 200 字节，密文按 base64 膨胀 4/3、再加 16 字节认证标签，明文理论上限约 2.9KB。**实例按 2200 字节控制 `alert` 明文**，留足余量；超过时先截短 `body`。

## 5. `collapse_id`

同一个「事件对象」（比如同一个订阅的下载进度）的多条推送，用 `collapse_id` 让手机只保留最新一条。`collapse_id` 对中继和苹果可见，所以必须是不透明值：

```
collapse_id = base64url( HMAC-SHA256(collapse_key, "<对象类型>:<对象 ID>") ) 的前 16 个字符
```

- `collapse_key` 是实例本地的 32 字节随机密钥，第一次用时生成并加密存储，不发给任何人。
- 不能直接写订阅 ID、片名之类的值。

## 6. 通知扩展的行为

1. 从 `userInfo["e"]` 取密文，按 `key_id` 在共享钥匙串里找密钥；
2. 解密、校验 `type`；失败（没有这把密钥、认证失败、格式不对）就保留中继填的通用文案（「MovieClaw」「你有一条新通知」）；
3. 设置标题、副标题、正文、分组（`threadIdentifier`）、类别（`categoryIdentifier`）、声音；按 `source` 决定要不要在副标题标出服务器或账号（内容类不标：点开时 App 会自动切到对应的服务器和账号）；
4. 有 `image` 时从「实例地址 + `image`」下载配图，超时 5 秒，失败就不带图。地址自带签名（只含一张图片地址和过期时间），通知扩展不需要 App 的登录令牌；签名在密文里，中继和苹果看不到。不直接用 TMDB 图床：国内经常连不上，还会把手机 IP 暴露给 TMDB。只开放局域网的实例，手机在外网时收到的通知不带图；
5. 点开时按 `open` 跳转，必要时先切换到对应的服务器和账号。

拿到通知过滤权限（`com.apple.developer.usernotifications.filtering`）后，解不开的通知直接丢弃，不再显示通用文案。

## 7. 测试向量

```
key       = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f（十六进制）
key_id    = k7Qm2xP9Hn4
nonce     = 000102030405060708090a0b（十六进制）
aad       = v1.k7Qm2xP9Hn4
plaintext = {"v":1,"type":"alert","title":"流浪地球 2 已入库","body":"4K · HDR · 已添加到「电影」","image":"/api/push/images/abc123","open":"movieclaw://library/items/123","thread":"library","category":"library.added","sound":"default","server":{"id":"s1","name":"客厅 NAS"},"account":{"id":"u7","name":"爸爸"},"sent_at":1767225600}
```

（明文 341 字节，以上 JSON 原样、无多余空白。向量里的 `image`、`open` 只是示例数据，取值形式以第 3.1 节为准。）

```
payload = v1.k7Qm2xP9Hn4.AAECAwQFBgcICQoL.PCCgOf_U7jn5OOfuk9NaDO-z9UDSV30IUROJ4D9TIlS0kUhJBSSOKJM0_M26p82PXLzlKL9sMPgTtUh2fJrX1NIIjVoRZgYpWAaKrFiv61-KbH7Zk-nzjXVNfUz0Fy04LkXoBSTM6ja8dVPTLxADRZhIA9uK6lXvPpd4pO-HCWvIfWGk1-b5YCrNas5NvyLgDNaOWkN49ingPp9N1f2Fh_Hl_2eQ0KUKwg6u1e6ytZmx7L5K-c4S2Efl4qsYp8WSYTWo1i--t71SMbyUw2Pjpo0XmgRccsPfEPX-oiVqo9gwTKHBggI5BzYi3mnAfQhzhLHKEO9G7Nc1URxR4vhguzaiw7Kx-CZfGrpQPZXIlKg_Ok_tzsrSjQwDTzBpl9U-b3f8csHnp3OwBhgvPbeM8farNjtrru3wEIn6ni8fOMXr5hpE_z8ZnYHaShdr5C9QpizntOFhYLyzgC4ieMqlItk-6ARo
```

`collapse_id`：

```
collapse_key = 202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f（十六进制）
输入          = subscription:42
collapse_id  = QuH-0hNhmLQa5h0c
```

实例（Python `cryptography` 的 `AESGCM`）和 App（CryptoKit 的 `AES.GCM`）都要用这组向量做单元测试：加密结果逐字节一致，解密能还原明文。
