#!/usr/bin/env python3
"""给一台全新的 MovieClaw 建好演示站（docs/design/demo-site.md §5）。

按 demo/accounts.json 建超管与成员（几种典型角色），按 demo/content.json 建媒体库、
等扫描与刮削完成、建一个跨库精选合集，接好演示资源站、演示下载器与自动入库
（审核员能真的搜索、下载、订阅那几部留在资源站里的开放授权影片，demo-site.md §10），
最后逐个验证公开账号能登录。

**必须在演示模式关闭、且 Caddy 停止时运行**：演示模式的只读守卫会拒绝建库、建成员；
而非演示模式的实例若经 Caddy 暴露在公网，任何人都能抢注超管。标准流程是
docker compose down → 只以普通模式启动 movieclaw → 跑本脚本 → ./reset.sh snapshot
（打「黄金快照」、以演示模式重启并自检、再启动 Caddy，见 demo/README.md）。

幂等：已存在的库、成员、合集会跳过或按清单更新，失败后可以直接重跑。
只依赖 Python 标准库，在宿主机或 MovieClaw 镜像里都能跑。

用法：
    python3 demo/provision.py --server http://127.0.0.1:3000 --media-root /media \\
        --workspace /workspace
"""

from __future__ import annotations

import argparse
import json
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
API = "/api/v1"
# 这几个状态才算「还在干活」；blocked / waiting 等待人工处理，等下去也不会结束
BUSY_JOB_STATUSES = {"queued", "running", "cancelling", "retry_wait"}
# 演示站的媒体目录只读挂载：刮削结果只进 data/，不往媒体目录写海报与 NFO
READ_ONLY_SCRAPE = {"mirror_images": False, "mirror_nfo": False, "mirror_episode_thumbs": False}
COLLECTION_NAME = "Blender 开放电影"
# 演示资源链路（demo-site.md §10）：只读的媒体目录之外，下载与新入库落在可写的工作目录
DEMO_SITE_ID = "demo"
DOWNLOADER_NAME = "演示下载器"
# 智能订阅偏好：演示片都是 1080p WEB-DL，不等更好的版本，订了马上能看到完整流程
SMART_PREFERENCES = {
    "resolution": "1080p",
    "source": "web-dl",
    "wait_seconds": 0,
    "allow_upgrade": False,
    "strict_resolution": False,
}
# 刷流：给演示下载器一个够用的预算，在池种子只模拟做种、不落盘
BOOST_BUDGET_BYTES = 50 * 1024**3


def log(message: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {message}", flush=True)


def fail(message: str) -> None:
    log(f"错误：{message}")
    sys.exit(1)


class Client:
    """最小的 MovieClaw API 客户端：Bearer 设备令牌 + 统一响应信封解包。

    不用网页会话 Cookie：公网部署开着 SESSION_COOKIE_SECURE，Cookie 带 Secure 标记，
    脚本经 http://127.0.0.1 访问时标准库的 CookieJar 不会回传它。
    """

    def __init__(self, server: str) -> None:
        self.server = server.rstrip("/")
        self.token: str | None = None

    def call(self, method: str, path: str, body: dict | None = None, *, ok_status=(200,)) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"{self.server}{API}{path}", data=data, method=method)
        request.add_header("Accept", "application/json")
        if data is not None:
            request.add_header("Content-Type", "application/json")
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=120) as resp:
                raw = resp.read()
                status = resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            status = exc.code
        payload = json.loads(raw) if raw else {}
        if status not in ok_status:
            message = payload.get("message") if isinstance(payload, dict) else raw[:200]
            raise RuntimeError(f"{method} {path} → {status}：{message}")
        return payload.get("data") if isinstance(payload, dict) else payload

    def device_login(self, username: str, password: str) -> str:
        data = self.call(
            "POST",
            "/auth/device/login",
            {
                "username": username,
                "password": password,
                "client": {
                    "kind": "ios",
                    "installation_id": f"demo-provision-{secrets.token_hex(8)}",
                    "name": "演示站建站脚本",
                },
            },
        )
        return data["token"]


def wait_until_healthy(client: Client, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    while True:
        try:
            client.call("GET", "/health")
            return
        except (RuntimeError, urllib.error.URLError, ConnectionError, TimeoutError, OSError):
            if time.monotonic() > deadline:
                fail(f"服务在 {timeout} 秒内没有就绪：{client.server}")
            time.sleep(5)


def refuse_if_caddy_running() -> None:
    """建站期间 Caddy 必须是停着的。

    建站时服务以非演示模式运行、超管密码又是公开的：此时若 Caddy 在跑，公网上的
    任何人都能抢先注册超管（尚未初始化时），或用公开密码登录一个没有只读守卫的
    超管。只在宿主机上能调 docker 命令时检查；在镜像里跑本脚本时没有 docker，
    只能靠 README 的步骤保证。
    """
    docker = shutil.which("docker")
    if docker is None:
        return
    try:
        running = subprocess.run(
            [docker, "ps", "-q", "--filter", "name=^movieclaw-demo-caddy$"],
            capture_output=True,
            text=True,
            timeout=30,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return  # docker 命令不可用（没权限等）：跳过这项检查
    if running:
        fail(
            "Caddy（movieclaw-demo-caddy）正在运行，非演示模式的实例会经它暴露在公网，"
            "任何人都能抢注超管或用公开密码登录。请先执行 docker compose down，"
            "再 MOVIECLAW_DEMO_MODE=false docker compose up -d movieclaw 后重跑本脚本"
        )


def ensure_admin(client: Client, admin: dict, nickname: str) -> None:
    status = client.call("GET", "/auth/bootstrap")
    if status.get("demo") is not None:
        fail("服务正以演示模式运行，建站会被只读守卫拒绝。请先去掉 MOVIECLAW_DEMO_MODE 重启再跑")
    if not status["initialized"]:
        credentials = {"username": admin["username"], "password": admin["password"]}
        client.call("POST", "/auth/bootstrap", credentials)
        log(f"已创建超级管理员 {admin['username']}")
    client.token = client.device_login(admin["username"], admin["password"])
    client.call("PUT", "/auth/profile", {"nickname": nickname})


def resource_site_libraries(content: dict) -> set[str]:
    """留在演示资源站里的影片所属的库：这些库要多一个可写的主根，新入库落在那里。"""
    return {film["library"] for film in content["films"] if film.get("resource_site")}


def ensure_libraries(
    client: Client, content: dict, media_root: str, workspace: str
) -> dict[str, dict]:
    existing = {lib["name"]: lib for lib in client.call("GET", "/libraries")}
    writable = resource_site_libraries(content)
    for spec in content["libraries"]:
        if spec["name"] in existing:
            log(f"媒体库「{spec['name']}」已存在，跳过")
            continue
        kind = spec["kind"]
        roots = [f"{media_root.rstrip('/')}/{spec['dir']}"]
        if spec["name"] in writable:
            # 主根（第一个）是新入库的落点：收下载入库的库把可写的工作目录放在最前面
            roots.insert(0, f"{workspace.rstrip('/')}/library/{spec['dir']}")
        body = {
            "name": spec["name"],
            "kind": kind,
            "source": "local" if kind in ("photo", "video") else "tmdb",
            "root_paths": roots,
            "exclude_from_home": bool(spec.get("exclude_from_home", False)),
            # 演示站的片子不会变：不需要实时监控，省掉 inotify 资源
            "realtime_watch": False,
            "scrape_overrides": READ_ONLY_SCRAPE,
        }
        created = client.call("POST", "/libraries", body)
        existing[spec["name"]] = created
        log(f"已创建媒体库「{spec['name']}」（{kind}），首次扫描已排队")
    return existing


def wait_for_background_work(client: Client, names: list[str], timeout: int) -> None:
    """等扫描、刮削、缩略图等后台任务都跑完——黄金快照要包含完整的海报与预览图。"""
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        libraries = [lib for lib in client.call("GET", "/libraries") if lib["name"] in names]
        scanning = [lib["name"] for lib in libraries if lib.get("scanning")]
        jobs = client.call("GET", "/jobs?active_only=true&limit=200")
        items = jobs.get("items", []) if isinstance(jobs, dict) else jobs
        busy = [job for job in items if job["status"] in BUSY_JOB_STATUSES]
        summary = f"扫描中的库 {scanning or '无'}；进行中的后台任务 {len(busy)} 个"
        if summary != last:
            details = "".join(
                f"\n    · {job['job_type']}：{job['progress']['message']}" for job in busy[:5]
            )
            log(summary + details)
            last = summary
        if not scanning and not busy:
            stuck = [job for job in items if job["status"] not in BUSY_JOB_STATUSES]
            for job in stuck:
                message = job["progress"]["message"]
                log(f"注意：任务 {job['job_type']} 处于 {job['status']}：{message}")
            return
        time.sleep(10)
    fail("等待后台任务超时；可以稍后重跑本脚本（已完成的步骤会跳过）")


def expected_counts(content: dict) -> dict[str, int]:
    expected: dict[str, int] = {}
    for film in content["films"]:
        if film.get("resource_site"):
            continue
        expected[film["library"]] = expected.get(film["library"], 0) + 1
    expected[content["photos"]["library"]] = len(content["photos"]["items"])
    return expected


def settle_library_counts(client: Client, content: dict, timeout: int) -> dict[str, dict]:
    """核对每个库的条目数，不齐就重扫，直到齐了或超时。

    扫描器把 mtime 在 5 分钟内的新文件当作「可能还在写入」暂缓入账
    （services/library/scan.py 的 NEW_FILE_QUIET_SECONDS），刚跑完 fetch_content.py
    就建站时会少片；这里每分钟重扫一次不齐的库，直到文件过了静默窗口被收进来。
    """
    expected = expected_counts(content)
    names = list(expected)
    started = time.monotonic()
    deadline = started + max(timeout, 420)
    previous: dict[str, int] | None = None
    while True:
        libraries = {lib["name"]: lib for lib in client.call("GET", "/libraries")}
        counts = {n: libraries[n]["stats"]["item_count"] for n in names}
        short = [n for n, count in expected.items() if counts[n] < count]
        # 过了静默窗口（5 分钟 + 余量）重扫仍没有变化：缺的片子不是暂缓，别空等
        stalled = previous == counts and time.monotonic() - started > 400
        if not short or stalled or time.monotonic() > deadline:
            break
        previous = counts
        log(f"{'、'.join(short)} 的条目还不齐（新文件有 5 分钟静默期），1 分钟后重扫")
        time.sleep(60)
        for name in short:
            client.call("POST", f"/libraries/{libraries[name]['id']}/scan", ok_status=(200, 202))
        wait_for_background_work(client, names, timeout=timeout)
    mismatched = []
    for name, count in expected.items():
        stats = libraries[name].get("stats", {})
        got = stats.get("item_count", 0)
        pending = stats.get("unidentified_count", 0)
        mark = "✓" if got == count else "✗"
        log(f"{mark} 「{name}」已识别 {got} / 期望 {count}（待识别 {pending}）")
        if got != count:
            mismatched.append(name)
    if mismatched:
        # 条目不齐的站不能打成黄金快照：之后每天都会还原成这个缺片的样子
        fail(
            f"{'、'.join(mismatched)} 的条目数与清单不符，建站未完成，不要打黄金快照。"
            "多半是 TMDB 访问失败或媒体目录没准备好，修好后重跑本脚本即可（已完成的步骤会跳过）"
        )
    return libraries


def ensure_members(client: Client, accounts: dict, libraries: dict[str, dict]) -> None:
    passwords = {a["username"]: a["password"] for a in accounts["accounts"]}
    existing = {m["username"]: m for m in client.call("GET", "/members")}
    for spec in accounts["members"]:
        username = spec["username"]
        password = spec.get("password") or passwords.get(username)
        if not password:
            fail(f"成员 {username} 没有密码（accounts 与 members 里都没写）")
        member = existing.get(username)
        if member is None:
            member = client.call(
                "POST",
                "/members",
                {"username": username, "password": password, "nickname": spec.get("nickname", "")},
            )
            log(f"已创建成员 {username}（{spec.get('nickname', '')}）")
        update: dict = {
            "nickname": spec.get("nickname", ""),
            "allow_subscribe": spec.get("allow_subscribe", False),
            "allow_search": spec.get("allow_search", False),
            "allow_direct_download": spec.get("allow_direct_download", False),
        }
        if spec.get("libraries"):
            update["all_libraries"] = False
            update["library_ids"] = [libraries[name]["id"] for name in spec["libraries"]]
        else:
            update["all_libraries"] = True
        if "content_age_limit" in spec:
            update["content_age_limit"] = spec["content_age_limit"]
            update["allow_unrated"] = spec.get("allow_unrated", False)
        client.call("PUT", f"/members/{member['id']}", update)
        enabled = spec.get("enabled", True)
        client.call("PUT", f"/members/{member['id']}/status", {"enabled": enabled})
        scope = "、".join(spec["libraries"]) if spec.get("libraries") else "全部库"
        log(
            f"成员 {username}：可见 {scope}；订阅{'开' if update['allow_subscribe'] else '关'}"
            f"{'；已停用' if not enabled else ''}"
        )


def ensure_collection(client: Client, content: dict, libraries: dict[str, dict]) -> None:
    """跨库精选合集：收录全部影片。已存在时把新入库的片补进去（重跑时用）。"""
    item_ids: list[int] = []
    for name in sorted({film["library"] for film in content["films"]}):
        for item in client.call("GET", f"/libraries/{libraries[name]['id']}/items"):
            item_ids.append(item["media_item_id"])
    if not item_ids:
        log("没有可放进合集的影片，跳过建合集")
        return
    existing = next(
        (c for c in client.call("GET", "/collections") if c["name"] == COLLECTION_NAME), None
    )
    if existing is None:
        client.call(
            "POST",
            "/collections",
            {"name": COLLECTION_NAME, "item_ids": item_ids, "visibility": "household"},
        )
        log(f"已创建合集「{COLLECTION_NAME}」（{len(item_ids)} 部）")
    else:
        # 只追加缺的片（已在名单里的会被跳过）；不用 PUT 整体替换名单
        client.call("POST", f"/collections/{existing['id']}/items", {"media_item_ids": item_ids})
        log(f"已补齐合集「{COLLECTION_NAME}」（{len(item_ids)} 部）")


def ensure_resource_pipeline(
    client: Client, content: dict, libraries: dict[str, dict], workspace: str
) -> None:
    """接好演示资源站 → 演示下载器 → 自动入库，并设好智能订阅偏好与刷流（demo-site.md §10）。"""
    target_names = resource_site_libraries(content)
    if not target_names:
        log("content.json 里没有留在资源站的影片，跳过演示资源链路")
        return
    if len(target_names) > 1:
        fail(f"留在资源站的影片只能属于同一个库，现在分散在：{sorted(target_names)}")
    library = libraries[next(iter(target_names))]
    downloads = f"{workspace.rstrip('/')}/downloads"

    sites = {site["site_id"]: site for site in client.call("GET", "/sites")}
    if DEMO_SITE_ID not in sites:
        client.call(
            "POST",
            "/sites",
            {"site_id": DEMO_SITE_ID, "auth_type": "apikey", "api_key": "demo", "enabled": True},
        )
        log("已接入演示资源站")
    deadline = time.monotonic() + 120
    while (status := client.call("GET", f"/sites/{DEMO_SITE_ID}")["status"]) != "active":
        if status == "failed" or time.monotonic() > deadline:
            fail(f"演示资源站验证没有通过（状态 {status}），检查镜像是否为 feat/demo 构建")
        time.sleep(2)

    downloaders = {d["name"]: d for d in client.call("GET", "/downloaders")}
    downloader = downloaders.get(DOWNLOADER_NAME)
    if downloader is None:
        downloader = client.call(
            "POST",
            "/downloaders",
            {
                "name": DOWNLOADER_NAME,
                "client_type": "demo",
                "url": "http://demo-downloader.local",
                "save_path": downloads,
                "enabled": True,
            },
        )
        log(f"已添加演示下载器（保存到 {downloads}）")
    client.call("POST", f"/downloaders/{downloader['id']}/verify")
    client.call("POST", f"/downloaders/{downloader['id']}/default")

    rules = client.call("GET", "/import-watch")
    if not any(rule["source_path"].rstrip("/") == downloads for rule in rules):
        client.call(
            "POST",
            "/import-watch",
            {
                "source_path": downloads,
                "strategy": "copy",
                "library_id": library["id"],
                "process_existing": False,
            },
        )
        log(f"已添加自动入库规则：{downloads} → 媒体库「{library['name']}」")

    for kind in ("movie", "tv"):
        current = client.call("GET", f"/subscriptions/smart-profiles/{kind}")
        if current.get("preferences") != SMART_PREFERENCES:
            client.call(
                "PUT",
                f"/subscriptions/smart-profiles/{kind}",
                {"revision": current["revision"], "preferences": SMART_PREFERENCES},
            )
    log("智能订阅偏好：1080p WEB-DL，不额外等待")

    client.call(
        "PATCH",
        f"/sites/{DEMO_SITE_ID}/ratio-boost",
        {
            "enabled": True,
            "budget_bytes": BOOST_BUDGET_BYTES,
            "hold_days": 1,
            "downloader_id": downloader["id"],
        },
    )
    log("演示资源站已开启刷流（免费种只模拟做种，不占磁盘）")


def verify_public_accounts(server: str, accounts: dict) -> None:
    """用每个公开账号实际登录一次，确认登录页上写的账号密码都能用；随即注销这台「设备」。"""
    for account in accounts["accounts"]:
        probe = Client(server)
        probe.token = probe.device_login(account["username"], account["password"])
        me = probe.call("GET", "/auth/me")
        probe.call("DELETE", "/auth/devices/current")
        log(f"✓ {account['label']} {account['username']} 可以登录（角色 {me['role']}）")


def main() -> None:
    parser = argparse.ArgumentParser(description="给全新的 MovieClaw 建好演示站")
    parser.add_argument("--server", default="http://127.0.0.1:3000")
    parser.add_argument("--media-root", default="/media", help="媒体根目录在容器里的路径")
    parser.add_argument(
        "--workspace", default="/workspace", help="可写工作目录在容器里的路径（下载与新入库）"
    )
    parser.add_argument("--accounts", type=Path, default=HERE / "accounts.json")
    parser.add_argument("--content", type=Path, default=HERE / "content.json")
    parser.add_argument("--timeout", type=int, default=3600, help="等待后台任务的上限（秒）")
    args = parser.parse_args()

    accounts = json.loads(args.accounts.read_text("utf-8"))
    content = json.loads(args.content.read_text("utf-8"))
    admin = next((a for a in accounts["accounts"] if a.get("role") == "admin"), None)
    if admin is None:
        fail("accounts.json 里没有 role=admin 的账号")

    refuse_if_caddy_running()
    client = Client(args.server)
    log(f"等待服务就绪：{args.server}")
    wait_until_healthy(client, timeout=600)
    ensure_admin(client, admin, accounts.get("admin", {}).get("nickname", admin["username"]))
    ensure_libraries(client, content, args.media_root, args.workspace)
    wait_for_background_work(
        client, [lib["name"] for lib in content["libraries"]], timeout=args.timeout
    )
    libraries = settle_library_counts(client, content, timeout=args.timeout)
    ensure_members(client, accounts, libraries)
    ensure_collection(client, content, libraries)
    ensure_resource_pipeline(client, content, libraries, args.workspace)
    # 建合集会触发封面拼贴等后台任务，等它们也跑完再打快照
    wait_for_background_work(
        client, [lib["name"] for lib in content["libraries"]], timeout=args.timeout
    )
    client.call("DELETE", "/auth/devices/current")
    verify_public_accounts(args.server, accounts)
    log("建站完成。下一步：./reset.sh snapshot（打快照、以演示模式重启并启动 Caddy，见 README）")


if __name__ == "__main__":
    main()
