"""搜索页手动下载「识别失败 → 确认是哪部 → 自动入库」的浏览器端到端（issue #503）。

真后端（uvicorn 子进程，_download_launcher.py 换掉 TMDB/站点/下载器）+ 真前端
（``pnpm dev``）+ 无头 Chromium。场景是 issue 里最典型的一条：

- 种子名是拼音 ``Fan.Hua.S01...``，enrich 还把它误判成了电影——按种子身份自动识别
  必然 not_found；用户是搜「繁花」才看到它的；
- 两个剧集库：默认「剧集库」与收藏范围 = 产地 CN 的「国产剧」，监听导入规则
  把下载目录接到「国产剧」。

验收链路：
1. 点「下载」→ 弹窗直接问「这是哪部作品？」，候选来自搜索词（剧、电影混排），
   目录收在「其他保存位置」里、确认键不可点（不会被默认选中的目录带跑）；
2. 点《繁花》→ 自动预演出「自动入库到『国产剧』」并选中（库由收藏范围分配，不是
   用户选的），确认键变成「下载到『国产剧』」；
3. 提交：下载器收到的保存目录 = 监听目录；按 infohash 写下身份锚（tv 500 → 国产剧）；
4. 下载"完成"（拼音文件落进监听目录）→ 监听导入按锚直接入库《繁花》，
   全程没有进待认领清单；
5. 种子连身份都没解析出来时，同样出现候选（不再直接跳过识别）。

标 integration：要 pnpm（apps/web 已 install）与 Playwright Chromium，CI 不跑。
本地：``pytest -m integration tests/e2e/test_manual_download_identity_browser.py``。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

playwright = pytest.importorskip("playwright.sync_api")

REPO = Path(__file__).resolve().parents[2]
WEB = REPO / "apps" / "web"
ADMIN = {"username": "admin", "password": "e2e-passw0rd"}
_CHROMIUM_CANDIDATES = (os.environ.get("E2E_CHROMIUM"), "/opt/pw-browsers/chromium")
# 与 _download_launcher.py 的假下载器一致
TORRENT_NAME = "Fan.Hua.S01.2160p.WEB-DL.H265-XYZ"
INFO_HASH = "b" * 40

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(shutil.which("pnpm") is None, reason="需要 pnpm 启动前端 dev server"),
    pytest.mark.skipif(
        not (WEB / "node_modules").is_dir(), reason="apps/web 未安装依赖（pnpm install）"
    ),
]


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_http(url: str, timeout: float) -> None:
    import urllib.request

    deadline = time.time() + timeout
    last: Exception | None = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:  # noqa: S310
                if resp.status < 500:
                    return
        except Exception as exc:  # noqa: BLE001
            last = exc
        time.sleep(1)
    raise RuntimeError(f"服务未就绪：{url}（{last}）")


def _wait_for(read, *, timeout: float, what: str, interval: float = 1.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = read()
        if value:
            return value
        time.sleep(interval)
    raise AssertionError(f"等了 {timeout} 秒仍未满足：{what}")


def _run_db(database_url: str, work):
    """在独立事件循环里对 SQLite 跑一段异步读写（测试进程不共享服务端的循环）。"""
    from movieclaw_db.engine import Database

    async def _run():
        db = Database(database_url)
        try:
            async with db.session() as session:
                return await work(session)
        finally:
            await db.dispose()

    with ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, _run()).result()


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    """拉起后端 + 前端；模块结束时收掉子进程。"""
    root = tmp_path_factory.mktemp("manual-download-e2e")
    dirs = {name: root / name for name in ("shows", "cn_shows", "watch")}
    for path in dirs.values():
        path.mkdir(parents=True)
    dl_log = root / "downloader.jsonl"
    dl_log.touch()
    api_port, web_port = _free_port(), _free_port()
    data = root / "data"
    data.mkdir()
    database_url = f"sqlite+aiosqlite:///{data / 'app.db'}"
    env = {
        **os.environ,
        "APP_ENV": "local",
        "APP_RELOAD": "false",
        "APP_PORT": str(api_port),
        "DATABASE_URL": database_url,
        "METADATA_DIR": str(data / "metadata"),
        "LOG_DIR": str(data / "logs"),
        "SECRET_KEY_FILE": str(data / ".secret_key"),
        "E2E_DL_LOG": str(dl_log),
    }
    api_log = (root / "api.log").open("w")
    api = subprocess.Popen(  # noqa: S603
        [sys.executable, str(Path(__file__).with_name("_download_launcher.py"))],
        env=env,
        stdout=api_log,
        stderr=subprocess.STDOUT,
        cwd=str(REPO),
    )
    web_log = (root / "web.log").open("w")
    web = subprocess.Popen(  # noqa: S603
        ["pnpm", "dev", "-p", str(web_port)],
        env={
            **os.environ,
            "NEXT_DIST_DIR": ".next-e2e",
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
        },
        stdout=web_log,
        stderr=subprocess.STDOUT,
        cwd=str(WEB),
        # 独立进程组：pnpm 拉起的 next-server 是孙进程，只 terminate pnpm 会留下
        # 每轮一个 1 GB+ 的孤儿进程，跑几轮就把内存吃光、浏览器页面崩溃
        start_new_session=True,
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 90)
        _wait_http(f"http://127.0.0.1:{web_port}/login", 180)
        yield {
            "base": f"http://127.0.0.1:{web_port}",
            "dirs": dirs,
            "dl_log": dl_log,
            "database_url": database_url,
            "shots": root / "shots",
        }
    finally:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(web.pid, signal.SIGTERM)
        api.terminate()
        for proc in (web, api):
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                if proc is web:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(web.pid, signal.SIGKILL)
                else:
                    proc.kill()
        api_log.close()
        web_log.close()


def _chromium_kwargs() -> dict:
    for cand in _CHROMIUM_CANDIDATES:
        if cand and Path(cand).exists():
            return {"executable_path": cand}
    return {}


def _hit(torrent_id: str, title: str, attrs: dict | None, seeders: int) -> dict:
    from movieclaw_api.schemas.search import TorrentHit

    return TorrentHit.model_validate(
        {
            "torrent_id": torrent_id,
            "title": title,
            "category": "tv",
            "size": "20.5 GB",
            "size_bytes": 22_000_000_000,
            "seeders": seeders,
            "site_id": "e2e",
            "site_name": "测试站",
            "detail_url": f"https://pt.example/details.php?id={torrent_id}",
            "download_url": f"https://pt.example/download.php?id={torrent_id}",
            "attrs": attrs,
        }
    ).model_dump(mode="json")


def _seed_snapshot(database_url: str) -> int:
    """播种一条「繁花」的资源搜索历史快照，返回 history id（结果页据此秒开，不碰站点）。

    第一条：拼音种子名 + enrich 误判成电影（身份三件套齐但全错）；
    第二条：连身份都没解析出来（attrs 为空）。
    """
    from datetime import UTC, datetime

    from movieclaw_db.models import SearchHistory

    items = [
        _hit(
            "1001",
            TORRENT_NAME,
            {"media_type": "movie", "titles_en": ["Fan Hua"], "year": 2023},
            seeders=50,
        ),
        _hit("1002", "FH.E01-E03.WEB-DL.mkv", None, seeders=5),
    ]
    snapshot = {
        "total": len(items),
        "elapsed_ms": 120,
        "items": items,
        "sites": [{"site_id": "e2e", "site_name": "测试站", "count": len(items)}],
    }

    async def work(session) -> int:
        row = SearchHistory(
            member_id=0,
            keyword="繁花",
            vertical="torrent",
            snapshot_json=json.dumps(snapshot, ensure_ascii=False),
            snapshot_at=datetime.now(UTC).replace(tzinfo=None),
        )
        session.add(row)
        await session.commit()
        await session.refresh(row)
        assert row.id is not None
        return row.id

    return _run_db(database_url, work)


def _intent(database_url: str) -> dict | None:
    from sqlmodel import select

    from movieclaw_db.models import ManualDownloadIntent, MediaItem

    async def work(session):
        row = (
            await session.execute(
                select(ManualDownloadIntent, MediaItem)
                .join(MediaItem, MediaItem.id == ManualDownloadIntent.media_item_id)
                .where(ManualDownloadIntent.info_hash == INFO_HASH)
            )
        ).first()
        if row is None:
            return None
        intent, item = row
        return {
            "library_id": intent.library_id,
            "kind": item.kind,
            "tmdb_id": item.tmdb_id,
            "title": item.title,
            "save_path": intent.save_path,
        }

    return _run_db(database_url, work)


def test_unidentified_torrent_confirm_then_auto_import(stack) -> None:  # noqa: PLR0915
    from playwright.sync_api import expect, sync_playwright

    base = stack["base"]
    dirs: dict[str, Path] = stack["dirs"]
    shots: Path = stack["shots"]
    shots.mkdir(exist_ok=True)

    def api(page, method: str, path: str, **kwargs) -> dict:
        resp = getattr(page.request, method)(f"{base}/api/v1{path}", **kwargs)
        assert resp.ok, f"{method} {path}: {resp.status} {resp.text()}"
        return resp.json()

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, **_chromium_kwargs())
        context = browser.new_context(viewport={"width": 1440, "height": 900}, locale="zh-CN")
        page = context.new_page()
        page.set_default_timeout(20_000)
        page.set_default_navigation_timeout(120_000)
        page_errors: list[str] = []
        page.on("pageerror", lambda e: page_errors.append(str(e)))

        # ---- 建超管 + 登录：走接口（与网页同一套 cookie），引导页的交互不是本用例的关注点 ----
        bootstrap = page.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)
        assert bootstrap.ok or bootstrap.status == 409, bootstrap.text()
        api(page, "post", "/auth/login", data={**ADMIN, "remember": True})

        # ---- 配置：两个剧集库（默认库 + 产地 CN 收藏范围）、下载器、监听导入 ----
        api(
            page,
            "post",
            "/libraries",
            data={"name": "剧集库", "kind": "tv", "root_paths": [str(dirs["shows"])]},
        )
        cn = api(
            page,
            "post",
            "/libraries",
            data={
                "name": "国产剧",
                "kind": "tv",
                "root_paths": [str(dirs["cn_shows"])],
                "match_rules": [{"field": "origin_countries", "op": "any_of", "values": ["CN"]}],
            },
        )["data"]
        api(
            page,
            "post",
            "/downloaders",
            data={
                "name": "家里的 qBittorrent",
                "client_type": "qbittorrent",
                "url": "http://192.168.1.10:8080",
                "save_path": str(dirs["watch"]),
            },
        )
        rule = api(
            page,
            "post",
            "/import-watch",
            data={"source_path": str(dirs["watch"]), "strategy": "copy", "library_id": cn["id"]},
        )["data"]
        history_id = _seed_snapshot(stack["database_url"])

        # ---- 结果页：点拼音种子的「下载」 ----
        page.goto(f"{base}/search?q={'繁花'}&snapshot={history_id}")
        # 结果行展示的是解析名（「Fan Hua」），原始种子名在悬停提示里
        row = page.get_by_role("listitem").filter(has_text="Fan Hua")
        expect(row).to_be_visible(timeout=60_000)
        page.screenshot(path=str(shots / "00-results.png"))
        # 桌面端操作键悬停行时才浮出（平时位置让给统计列）
        row.hover()
        row.get_by_role("button", name="下载", exact=True).click()

        dialog = page.get_by_role("dialog")
        expect(dialog.get_by_text("这是哪部作品？")).to_be_visible()
        fanhua = dialog.get_by_role("button", name="繁花 (2023) 剧集")
        expect(fanhua).to_be_visible()
        # 同名干扰电影也在候选里：种子被误判成电影，候选必须两种类型都给
        expect(dialog.get_by_role("button", name="繁花似锦 (2021) 电影")).to_be_visible()
        # 目录收着、确认键不可点：没回答「这是哪部」之前不会被默认目录带跑
        expect(dialog.get_by_role("button", name="其他保存位置")).to_be_visible()
        confirm = dialog.get_by_role("button", name="确认下载")
        expect(confirm).to_be_disabled()
        page.screenshot(path=str(shots / "01-picker.png"))

        # ---- 点《繁花》：自动预演 + 自动选中「自动入库」（库由收藏范围分配） ----
        fanhua.click()
        expect(fanhua).to_have_attribute("data-active", "true")
        smart = dialog.get_by_role("button", name="自动入库到「国产剧」")
        expect(smart).to_be_visible()
        expect(smart).to_have_attribute("data-active", "true")
        expect(smart).to_contain_text("命中「国产剧」")
        submit = dialog.get_by_role("button", name="下载到「国产剧」")
        expect(submit).to_be_enabled()
        page.screenshot(path=str(shots / "02-confirmed.png"))

        # 窄屏同一状态（手机上的布局不能挤爆）
        page.set_viewport_size({"width": 390, "height": 844})
        page.screenshot(path=str(shots / "02b-confirmed-mobile.png"))
        page.set_viewport_size({"width": 1440, "height": 900})

        submit.click()
        expect(dialog).to_have_count(0)
        expect(row.get_by_role("button", name="已提交")).to_be_visible()

        # ---- 服务端：投监听目录 + 按 infohash 锚定身份 ----
        submits = [json.loads(line) for line in stack["dl_log"].read_text().splitlines()]
        assert [s["save_path"] for s in submits] == [str(dirs["watch"])]
        intent = _intent(stack["database_url"])
        assert intent is not None, "提交成功后应写入身份锚"
        assert (intent["kind"], intent["tmdb_id"], intent["library_id"]) == ("tv", 500, cn["id"])
        assert intent["title"] == "繁花"

        # ---- 下载"完成"：拼音命名的文件落进监听目录 → 按锚直接入库，不进待认领 ----
        entry = dirs["watch"] / TORRENT_NAME
        entry.mkdir()
        (entry / "Fan.Hua.S01E01.2160p.WEB-DL.H265-XYZ.mkv").write_bytes(b"FAKE-MEDIA" * 4096)

        def imported():
            lib = next(x for x in api(page, "get", "/libraries")["data"] if x["id"] == cn["id"])
            return lib if lib["stats"]["item_count"] == 1 else None

        _wait_for(imported, timeout=120, what="监听导入按身份锚把《繁花》收进国产剧", interval=2)
        items = api(page, "get", f"/libraries/{cn['id']}/items")["data"]
        assert [i["title"] for i in items] == ["繁花"]

        # 条目行由入库当场提交，监听导入台账要到作业收尾才写：等它落下再断言
        def ledger():
            data = api(page, "get", f"/import-watch/{rule['id']}/entries")["data"]
            return data if data["counts"].get("imported") else None

        entries = _wait_for(ledger, timeout=30, what="监听导入台账记下入库结论", interval=1)
        assert entries["counts"].get("imported") == 1, entries
        assert not entries["counts"].get("pending"), entries
        assert list(dirs["cn_shows"].rglob("*.mkv")), "文件应已整理进国产剧目录"
        page.goto(f"{base}/library/{cn['id']}")
        # next dev 首次打开这一页要现编译，默认 5 秒偶尔不够
        expect(page.locator("[data-library-item-id]")).to_have_count(1, timeout=30_000)
        page.screenshot(path=str(shots / "03-imported.png"))

        # ---- 连身份都没解析出来的种子：同样按搜索词给候选 ----
        page.goto(f"{base}/search?q={'繁花'}&snapshot={history_id}")
        row = page.get_by_role("listitem").filter(has_text="FH.E01-E03.WEB-DL.mkv")
        expect(row).to_be_visible(timeout=60_000)
        row.hover()
        row.get_by_role("button", name="下载", exact=True).click()
        dialog = page.get_by_role("dialog")
        expect(dialog.get_by_text("这是哪部作品？")).to_be_visible()
        expect(dialog.get_by_role("button", name="繁花 (2023) 剧集")).to_be_visible()
        # 「换个词搜」：搜不到时就地提示，不清空弹窗
        dialog.get_by_role("textbox", name="按片名搜索作品").fill("不存在的片名")
        dialog.get_by_role("button", name="搜索", exact=True).click()
        expect(dialog.get_by_text("没找到与「不存在的片名」匹配的作品")).to_be_visible()
        page.screenshot(path=str(shots / "04-no-identity-search-miss.png"))
        dialog.get_by_role("button", name="取消").click()
        expect(dialog).to_have_count(0)

        # ---- 连搜索词都没有（浏览模式）：弹窗给空搜索框，输入片名后出候选 ----
        page.goto(f"{base}/search?browse=1&snapshot={history_id}")
        row = page.get_by_role("listitem").filter(has_text="FH.E01-E03.WEB-DL.mkv")
        expect(row).to_be_visible(timeout=60_000)
        row.hover()
        row.get_by_role("button", name="下载", exact=True).click()
        dialog = page.get_by_role("dialog")
        expect(dialog.get_by_text("这是哪部作品？")).to_be_visible()
        field = dialog.get_by_role("textbox", name="按片名搜索作品")
        expect(field).to_have_value("")
        field.fill("繁花")
        dialog.get_by_role("button", name="搜索", exact=True).click()
        fanhua = dialog.get_by_role("button", name="繁花 (2023) 剧集")
        expect(fanhua).to_be_visible()
        fanhua.click()
        expect(dialog.get_by_role("button", name="下载到「国产剧」")).to_be_enabled()
        page.screenshot(path=str(shots / "05-browse-typed-search.png"))

        assert not page_errors, page_errors
        browser.close()
