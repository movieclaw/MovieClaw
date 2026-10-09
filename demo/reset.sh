#!/usr/bin/env bash
# =============================================================================
# 演示站的黄金快照与每日还原（docs/design/demo-site.md §5）
#
#   ./reset.sh snapshot   建站完成后执行一次：停服务 → 把 data/ 打成 golden-data.tar.gz
#                         → 以演示模式启动并自检 → 启动 Caddy
#   ./reset.sh restore    每天由 cron 执行：停服务 → 用快照整体替换 data/
#                         → 以演示模式启动并自检 → 启动 Caddy
#
# 演示模式下访客能留下的只有播放进度、收藏 / 已看、登录设备这些，每天整体还原
# 一次，第二天的访客看到的永远是同一个干净的演示站。
#
# 安全要点：公网上绝不能出现非演示模式的实例（超管密码是公开的，非演示模式下
# 等于把服务器交出去）。所以本脚本：
#   - 一律以 MOVIECLAW_DEMO_MODE=true 执行 `docker compose up -d`，而不是
#     `docker compose start`（start 会沿用容器创建时的环境，建站时容器是以
#     演示模式关闭创建的）；
#   - 启动后自检：已完成初始化、且登录页接口带演示账号，才启动 Caddy；
#     自检不过就把 movieclaw 与 Caddy 都停掉并报错退出，宁可不开也不开错；
#   - 打包 / 解包 / 换目录中途失败，也按演示模式把服务拉起来（data/ 缺失时不拉）。
#
# 用 root 执行（data/ 里的文件属于容器内的 root）。crontab 示例（cron 按宿主机
# 时区计时，见 README「每天还原」）：
#   17 4 * * * cd /srv/movieclaw-demo && ./reset.sh restore >> reset.log 2>&1
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# 读 .env 里的反代模式与端口（DEMO_PROXY、DEMO_HTTP_PORT），与 compose 用同一份配置
if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi
# 本脚本里所有 docker compose 调用都按演示模式创建容器（放在读 .env 之后，
# .env 里哪怕写了 MOVIECLAW_DEMO_MODE=false 也会被这里盖掉）
export MOVIECLAW_DEMO_MODE=true
# caddy：本目录的 Caddy 负责 HTTPS；external：服务器上已有的 nginx 负责（不启动 Caddy）
DEMO_PROXY="${DEMO_PROXY:-caddy}"

SNAPSHOT="golden-data.tar.gz"
BOOTSTRAP_URL="http://127.0.0.1:${DEMO_HTTP_PORT:-3000}/api/v1/auth/bootstrap"
CHECK_TIMEOUT=180
stamp() { date '+%F %T'; }

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsS --max-time 5 "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO- -T 5 "$1"; }
else
    echo "$(stamp) 错误：本机没有 curl 也没有 wget，无法在启动后自检演示模式。\
请先安装 curl（Debian / Ubuntu：apt install -y curl）" >&2
    exit 1
fi

# 清空可写工作目录（demo-site.md §10）：演示下载器下好的数据与新入库的影片。
# 库目录本身（workspace/library/<库名>/）留着，它是媒体库的主根；只删里面的条目。
reset_workspace() {
    mkdir -p workspace/downloads workspace/library
    find workspace/downloads -mindepth 1 -delete
    find workspace/library -mindepth 2 -maxdepth 2 -exec rm -rf {} +
}

# 以演示模式启动 movieclaw → 自检 → 启动 Caddy。自检不过就全部停掉并报错退出。
start_demo() {
    docker compose up -d movieclaw
    local deadline=$((SECONDS + CHECK_TIMEOUT)) body=""
    while ((SECONDS < deadline)); do
        body="$(fetch "$BOOTSTRAP_URL" 2>/dev/null || true)"
        # 期望 data 里 initialized 为 true、demo 是对象；demo 为 null 说明没在演示模式
        if grep -Eq '"initialized"[[:space:]]*:[[:space:]]*true' <<<"$body" &&
            grep -Eq '"demo"[[:space:]]*:[[:space:]]*\{' <<<"$body"; then
            if [[ "$DEMO_PROXY" == "caddy" ]]; then
                docker compose up -d caddy
            fi
            return 0
        fi
        sleep 5
    done
    docker compose --profile caddy stop movieclaw caddy || true
    echo "$(stamp) 错误：movieclaw 启动 ${CHECK_TIMEOUT} 秒后仍未确认处于演示模式\
（要求已完成初始化、且登录页接口带演示账号）。为防止非演示实例暴露在公网，\
已停掉 movieclaw 与 Caddy。排查：docker compose logs --tail 100 movieclaw；\
接口最后一次返回：${body:0:300}" >&2
    exit 1
}

# 打包 / 解包 / 换目录中途失败时的兜底：服务已经停了，按演示模式重新拉起来
SERVICE_STOPPED=0
on_exit() {
    local status=$?
    if ((status == 0 || SERVICE_STOPPED == 0)); then
        return
    fi
    SERVICE_STOPPED=0
    # 还原到一半（旧 data/ 已挪开、新的还没放进来）：先把旧数据放回原位
    if [[ ! -d data && -d data.previous ]]; then
        mv data.previous data
        echo "$(stamp) 已把原来的 data/ 放回原位" >&2
    fi
    if [[ -d data ]]; then
        echo "$(stamp) 操作中途失败（退出码 $status），按演示模式重新启动服务" >&2
        start_demo
    else
        echo "$(stamp) 操作中途失败且 data/ 不存在，不启动服务；请人工检查演示站目录" >&2
    fi
}
trap on_exit EXIT

case "${1:-}" in
    snapshot)
        [[ -d data ]] || { echo "当前目录下没有 data/，先完成建站" >&2; exit 1; }
        SERVICE_STOPPED=1
        docker compose stop movieclaw
        # 快照里的数据库没有任何下载与新入库记录，工作目录也要对齐成空的
        reset_workspace
        tar -czf "$SNAPSHOT.tmp" data
        mv "$SNAPSHOT.tmp" "$SNAPSHOT"
        SERVICE_STOPPED=0
        start_demo
        echo "$(stamp) 黄金快照已更新：$SNAPSHOT（$(du -h "$SNAPSHOT" | cut -f1)），演示站已启动"
        ;;
    restore)
        [[ -f "$SNAPSHOT" ]] || { echo "找不到 $SNAPSHOT，先执行 ./reset.sh snapshot" >&2; exit 1; }
        # 先解到旁边再换，解压失败时现有 data/ 原封不动
        rm -rf data.restoring
        mkdir data.restoring
        tar -xzf "$SNAPSHOT" -C data.restoring
        SERVICE_STOPPED=1
        docker compose stop movieclaw
        rm -rf data.previous
        mv data data.previous
        mv data.restoring/data data
        rmdir data.restoring
        reset_workspace
        SERVICE_STOPPED=0
        start_demo
        rm -rf data.previous
        echo "$(stamp) 已还原到黄金快照，演示站已启动"
        ;;
    *)
        echo "用法：$0 snapshot|restore" >&2
        exit 2
        ;;
esac
