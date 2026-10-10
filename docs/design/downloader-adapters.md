# 下载器适配器插件化

> 状态：**已实施**（2026-10-10）。判断依据见 `library-boundary.md` §1：下载器是对接外部软件、名单长（qBittorrent、
> Transmission、Deluge、Aria2、群晖 Download Station……）、每人只用一两种 → 官方插件。

## 1. 结论

- 下载器类型不再写死。每种下载器是一个**适配器**（实现 `BaseDownloader`），由插件往注册表
  `downloader-adapters`（`EXPERIMENTAL`）登记；工厂 `create_downloader` 按配置里的类型值查注册表。
- qBittorrent、Transmission 是**随应用提供的官方插件**（`src/movieclaw_plugins/{qbittorrent,transmission}/`），
  与四个 IM 通道同一套：只依赖 SDK 与各自的协议库，能原样打成 `.mcplugin`，装同 id 的插件包即替换，卸载恢复。
- 第三方插件能登记新类型；配置下载器时就能选到，网页的类型列表、地址叫法与示例都由服务端给出。

## 2. 契约（`movieclaw_sdk.downloaders`）

| 名字 | 说明 |
|---|---|
| `BaseDownloader` | 适配器基类：提交、查询、列表、删除、改目录、选文件、恢复、限速、测试连接、关闭 |
| `DownloaderAdapter` | 登记项：`type`（存进下载器配置的类型值，全局唯一）、`title`、`factory(config)`、`url_label`、`url_placeholder`、`needs_username`、`help` |
| `DOWNLOADER_ADAPTERS` | 注册表键 |
| 数据模型与异常 | `DownloaderConfig`、`DownloadRequest`、`TorrentStatus`……、`DownloaderException` 一族 |

下载器配置、连接测试、路径映射、订阅投递、做种同步、删种、刷流都由主程序负责，适配器只管「怎么跟这款软件说话」。

## 3. 数据与接口

- `downloader_client.client_type` 列本来就是字符串，不需迁移；模型、接口里的类型从枚举放开成字符串。
- 新建 / 修改下载器时校验类型要有已登记的适配器，否则 400 并列出可用类型。
- `GET /downloaders/types`（`dl.types.list`）：可用的下载器类型。网页按它渲染类型选择与地址一栏；旧服务端没有这个接口时
  网页回落到内置两种。iOS 生成模型里类型本来就是字符串，旧版 App 遇到新类型照常解码。
- 适配器插件没装 / 没在运行时，用这种类型的下载器报「下载器类型尚未支持」，配置保留，插件回来即恢复。

## 4. 进程外运行

适配器既能在主进程里跑（随带时作为内置条目），也能在独立进程里跑（插件包默认）：

- 子进程把登记项的数据部分发给宿主，适配器本身留在子进程；宿主登记一个 `RemoteDownloader`
  （`services/plugin_downloaders.py`），每个方法经协议（`kind="downloader"`）转给子进程；
- 子进程按（登记 id, 连接配置）缓存适配器实例，复用登录态与连接，`close` 时丢掉；
- 种子字节用 base64 传；下载器异常按类名带回，宿主还原成同一个异常类型，上层的错误处理不分两套；
- 子进程不在运行时报 `DownloaderConnectError`（「下载器插件没在运行，稍后会自动重试」）。

## 5. 启动顺序

随带的下载器插件排在 `downloads` 模块前面（`manifest.with_bundled`）：入库监控等模块启动那一刻就要用下载器。
用插件包替换的版本在内核启动后才装上，期间用到下载器会报不支持、随后自动恢复。
