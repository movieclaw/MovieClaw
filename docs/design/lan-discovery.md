# 局域网自动发现协议

各端 App 首次连接时在局域网里找 MovieClaw 服务器。服务端实现在
`src/movieclaw_api/services/lan_discovery.py`，监听 **UDP 7359**。

## 为什么不用 mDNS / Bonjour

最常见的部署是 Docker 桥接网络：组播出不了容器，`-p` 映射不了组播，群晖上 5353
还被系统的 avahi 占着；就算发出去了，容器播报的也是 172.x 内网地址。mDNS 只对
host 网络 / 裸机有用，而这两种部署下现有的 7359 单播本来就好用。所以沿用 7359，
只是把它从「Jellyfin 兼容」里独立出来，换成自家的询问与应答格式。

## 询问

客户端对本机所在网段（最多一个 /24）**逐个单播**，每个地址发两条：

| 询问 | 谁应答 |
|---|---|
| `who is MovieClawServer?` | 自家协议。核心功能，不受「Jellyfin 兼容」开关影响 |
| `who is JellyfinServer?` | Jellyfin 兼容，只在兼容开关打开时应答 |

两条都发，是为了兼容 v0.40.0 及更早的服务器（只认 Jellyfin 的询问）。服务端按
大小写不敏感的包含关系匹配。逐个单播而不广播：iOS 发广播要单独申请组播权限；
桥接部署下广播进不了容器，发给宿主 IP 的单播却能经 `-p 7359:7359/udp` 转进去。

## 应答

自家应答（UTF-8 JSON，单播回询问的来源端口）：

```json
{
  "type": "movieclaw.discovery",
  "version": 1,
  "instance_id": "9f2c…",
  "name": "MovieClaw",
  "server_version": "0.41.0",
  "addresses": ["http://192.168.1.10:3300", "https://movie.example.com"]
}
```

- `type` 固定为 `movieclaw.discovery`，客户端靠它区分自家应答与 Jellyfin 应答；
  `version` 是协议版本，加字段不升版本，客户端忽略不认识的字段。
- `instance_id` 与 `GET /api/v1/health` 的 `instance_id` 是同一个值，可用来给同一台
  服务器的多条应答去重。
- `addresses` 按可信度排序，**可以为空**：
  1. `published_server_url`（高级配置）；
  2. 服务端探测出的出口 IP + 对外端口（host 网络 / 裸机时）；
  3. 最近有人用局域网 IP 访问本服务时浏览器地址栏里的地址（服务端从请求头 Host
     学来，只认私有网段 IPv4 字面量）——Docker 桥接部署靠它拿到宿主 IP 与映射端口；
  4. 「设置 → 网络 → 外部访问地址」。

  桥接部署下探测出的容器内网地址不放进来（客户端反正连不上）。
- `endpoints`：同一组地址再加上访问地址簿（`server-addresses.md` §3），每项 `{url, kind}`，`kind` 为
  `lan`（内网）/ `wan`（外网）。新客户端用它，旧客户端照旧读 `addresses`。

Jellyfin 应答保持与真 Jellyfin 一致：`{"Address", "Id", "Name", "EndpointAddress": null}`，
`Address` 取上面列表的第一个，列表为空时退回容器内网地址并在服务端日志告警。

## 客户端怎么用应答

应答里的地址只是候选。对每台应答的服务器按下面的顺序拼候选地址（去重），并发
请求 `GET /api/v1/health`，按顺序取第一个返回 `status: "ok"` 的：

1. 自家应答的 `addresses`（Jellyfin 应答的 `Address`）；
2. 应答报文的来源 IP + 上面地址里出现过的每个端口；
3. 来源 IP + 3000（docker-compose 的默认端口）。

同一台服务器的自家应答与 Jellyfin 应答合并成一份候选（自家的在前）。健康检查也顺带
排除了局域网里真正的 Jellyfin。

## 手动输入地址

用户只填了主机（如 `192.168.1.10`，没写协议也没写端口）时，客户端依次试
`http://主机:3000`、`http://主机`、`https://主机` 的健康检查，用第一个通过的；都不通过就按
`http://主机` 继续，让后面的登录步骤报出连不上的原因。
