# NAS 服务端性能基线（2026-10）

被测：用户 NAS（群晖，AMD Ryzen Embedded V1500B 4C8T，32 GB，内核 4.4），容器 `movieclaw`
跑 v0.43.0（镜像 runtime 24），库：6.2k 条目 / 1.66 万文件 / 4 个库。全程对线上只读；
压测用库副本在容器 `/tmp` 里跑，不碰正在服务的进程。

## 1. 基线指标与量法

每轮优化前后都按这张表量一遍；「红线」是回归判据，超了就要查。

| 维度 | 指标 | 量法 | 2026-10-27 基线 | 红线 |
|---|---|---|---|---|
| 内存 | 主进程 RSS 常态 / 峰值（VmHWM） | `nas_server_sample.py` | 488 / 586 MB（运行 13 小时） | 常态 > 500 MB |
| 内存 | Next 进程 RSS | 同上 | 152 MB | > 200 MB |
| 内存 | 容器 cgroup rss（不含页缓存） | 同上 | 607～640 MB | > 800 MB |
| 内存 | 页缓存 cache | 同上 | 7.3～7.7 GB | 不设：可回收，`docker stats` 含它，别当泄漏 |
| CPU | 空闲时容器总 CPU（无人播放） | 同上，60 s 窗口 | 6.0～7.5% 单核 | — |
| CPU | 其中主进程 | 同上 | 1.9～2.4% | > 5% |
| CPU | 其中短命子进程（容器总量减常驻进程之和） | 同上 | ≈ 4%，健康探测占 3.7% | — |
| 延迟 | 首页四接口 p50 / p95（线上，客户端并发发出） | `access_log_stats.py` 按天 | up-next 165/200、collections 130/155、favorites 77/95、libraries 61/78 ms | p95 涨 30% |
| 延迟 | 单库海报墙 `/libraries/{id}/items` p50 / p95 | 同上 | 220～290 / 600～1050 ms | — |
| 延迟 | 图片代理 `/images/proxy` p95 | 同上 | 1.0～2.7 s（多为外网回源） | — |
| 事件循环 | 健康接口 > 50 ms 的次数/天 | 同上（它不碰库，慢了就是循环被卡） | 3 | > 20 |
| 接口自身成本 | 首页四接口串行 p50、并发总墙钟 | `bench_home_api.py`（库副本，进程内） | 见 §3 | — |

**负载画像**：两台电视（Android TV 0.6.0、Apple TV 0.3.0）停在首页、每 60 秒各刷一次首页，
夜里也在刷：四个接口各约 2,540 次/天，占全天后端请求处理时间（1,401 s）的 76%。所以线上那几个
p50 主要是「四个请求同时到、排队算完」的完成时间，不是单个接口的成本——单接口成本用压测量。

## 2. 量法细节

```bash
# 资源快照（只读 /proc，不写盘）
ssh nas '/usr/local/bin/docker exec -i movieclaw python3 - 60' < scripts/perf/nas_server_sample.py

# 按天的接口延迟
ssh nas 'cat /volume1/docker_stable/movieclaw/logs/movieclaw-2026-10-26.log' \
  | python3 scripts/perf/access_log_stats.py --top 30

# A/B 压测：库副本 + 两份源码，同机交替跑
#   副本：容器里 sqlite3 backup（源库 ?mode=ro）到 /tmp/mc-bench/bench.db
#   源码：git archive <基线提交> src、以及改动后的 src，分别解到 /tmp/mc-bench/{base,new}
docker exec -w /tmp/mc-bench -e METADATA_DIR=/app/data/metadata -e PYTHONPATH=/tmp/mc-bench/new/src \
  movieclaw /venv/bin/python bench_home_api.py /tmp/mc-bench/bench.db --rounds 30 [--trace]
```

注意事项（都踩过）：

- **压测别用 `dependency_overrides` 换鉴权**：FastAPI 只要有 override，每个请求都对每个子依赖重跑
  `get_dependant`，框架开销被放大好几倍。脚本用副本里插的登录设备令牌走真实鉴权。
- **cProfile 不适合测协程**：每次 resume 都算一次调用，累计时间对不上。看热点用 py-spy 采样
  （`pip install --target /tmp/pyspy py-spy`，不动 venv），并且**跳过预热**：首个请求要为 713 条
  路由构建有效上下文，几秒钟的采样会被它淹没。
- 要设 `METADATA_DIR=/app/data/metadata`，否则图片版本戳的 stat 全部失败走异常分支，测出来的不是线上路径。
- 进程是 V1500B 上的单个事件循环：同一份代码本机（M 系列）比 NAS 快约 5 倍，结论要在 NAS 上量。

## 3. 第一轮（2026-10-27）

NAS 压测，库副本、真实令牌鉴权，30 轮串行 p50（ms）：

| 接口 | 改动前 | 改动后 | 说明 |
|---|---|---|---|
| `/playback/up-next` | 72.8（SQL 46.2） | 34.8（SQL 11.6） | 行值 IN 走索引 |
| `/collections` | 53.2 | 46.3 | `asset_version` 去 pathlib |
| `/playback/favorites` | 26.5 | 24.5 | 同上 |
| `/libraries` | 18.6 | 16.8 | 同上 |
| 四个并发总墙钟 | 145.9 | 122.5 | |

1. **行值 IN 在镜像 SQLite 上整表扫描**（PR：`perf(db): 行值 IN 补首列条件走索引`）。镜像是 Debian
   bookworm 的 SQLite 3.40.1，`(a,b,c) IN ((…),(…))` 不用复合索引：7 个三元组查 media_episode
   10 ms、library_file 16 ms。本机 3.54 走索引只要 0.06 ms，所以开发时看不出来。
   `movieclaw_db.rowvalues.tuple_in` 补一条首列 `IN`，老版本按首列索引查找（0.2 ms）。
   up-next、活动页、同步目录、海报墙落点、Jellyfin 叶子单元全部换掉。
2. **`asset_version` 的 pathlib 开销**（同一 PR）：每张卡片调好几次，合集列表一次约 170 次；
   NAS 上单次 35 µs → 8 µs。
3. **健康探测每次起解释器**（PR：`perf(docker): 健康探测改用 curl`）：看门狗每 10 秒起两个 Python
   （每个约 167 ms CPU），Docker HEALTHCHECK 每 30 秒起一个 node（约 118 ms），常驻 3.7% 单核，
   是后端空闲 CPU 的两倍；curl 每次约 7 ms。属镜像层改动，换镜像后才生效，向后兼容不 bump runtime。

## 4. 发现与下一轮候选

按「用户能感到的 × 改动风险」排序：

1. **电视剧海报墙** `/libraries/20/items?limit=60`：压测 p50 162 ms、p90 368 ms（电影库 41 ms）。
   最慢两条 SQL 27 ms（文件明细 json_group_array）与 13 ms（分集 `media_item_id IN` 60 个）。
2. **开发 / 生产环境偏斜**：镜像 SQLite 3.40.1 对本机 3.54；镜像按 pyproject 版本范围现场解析依赖
   （没有锁文件），线上 FastAPI 0.162.0、本机 0.142.2。第 1 条这类问题只在线上出现，
   值得让 CI 在镜像同版本 SQLite 上跑一遍查询计划守卫，或在镜像里带新版 SQLite。
3. **电视熄屏仍每分钟刷首页**：Android TV 首页可见时每 60 秒 `store.reload()`，BRAVIA 熄屏时
   App 仍在前台，一夜照刷。服务端可以给首页接口加 ETag/304，客户端可以在熄屏/无操作 N 分钟后停刷。
4. **FastAPI 路由匹配是线性扫描**：713 条路由 / 93 个子路由，`/api/v1/*` 每次匹配 0.7～1 ms，
   Jellyfin 路径（`/Items/...`）约 2.5 ms，404 约 3 ms（0.142 与 0.162 一样）。Infuse 等客户端
   请求多，值得看看路由挂载顺序。
5. **合集列表剩余的 Python 开销**：SQL 18 ms 之外还有约 28 ms，主要是逐合集 `json.loads` 规则、
   响应序列化（`_serialize_datetimes` 递归）。
6. **图片代理 p95 1～2.7 s**：多为外网回源，先确认命中率再说。
