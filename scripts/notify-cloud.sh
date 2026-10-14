#!/usr/bin/env bash
# 通知官网（MovieClaw Cloud）同步这些 Release：官网收到后自己去 GitHub 拉发布记录、release.json 与
# downloads.json，写进它的发布表。只带 tag、不带数据——GitHub 是唯一事实源，通知只是让官网早点知道。
#
# 用法：scripts/notify-cloud.sh <tag>…        # 例如 v0.38.0 android-v0.3.2
#       scripts/notify-cloud.sh --all          # 让官网立刻全量对账
# 环境变量：CLOUD_RELEASE_SYNC_TOKEN（仓库 Actions 机密；没配就跳过，如 fork 出去的仓库）、
#           CLOUD_API_URL（默认 https://api.movieclaw.io）
#
# 官网故障不能挡住发版：重试后仍失败只告警、退出码为 0。漏掉的由官网每天一次的全量对账补上。
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "用法：$0 <tag>… | --all" >&2
  exit 2
fi
if [ -z "${CLOUD_RELEASE_SYNC_TOKEN:-}" ]; then
  echo "未配置 CLOUD_RELEASE_SYNC_TOKEN，跳过通知官网"
  exit 0
fi

if [ "$1" = "--all" ]; then
  body='{"all":true}'
else
  body="$(python3 -c 'import json, sys; print(json.dumps({"tags": sys.argv[1:]}))' "$@")"
fi
url="${CLOUD_API_URL:-https://api.movieclaw.io}/v1/releases/sync"

for attempt in 1 2 3; do
  if response="$(curl -sS --fail-with-body -m 60 -X POST "$url" \
      -H "Authorization: Bearer $CLOUD_RELEASE_SYNC_TOKEN" \
      -H "Content-Type: application/json" --data "$body" 2>&1)"; then
    echo "官网已同步：$response"
    exit 0
  fi
  echo "第 $attempt 次通知官网失败：$response"
  [ "$attempt" -lt 3 ] && sleep $((attempt * 10))
done
echo "::warning::通知官网同步失败（$*），官网每天的全量对账会补上；急用可手动运行 cloud-sync 工作流"
exit 0
