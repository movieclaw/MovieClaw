"""媒体库剧集详情页「更新日历」（issue #547）的浏览器端到端。

真后端 + 真前端 + 无头 Chromium。库存与订阅直接往 SQLite 播种：一部在播剧
（本周有排期 + 更新预测 + 部分已入库）与一部完结剧。覆盖：

- 在播剧详情页出现「更新日历」，日期条可选、当天列出集号与入库状态；
- 完结剧详情页不出现「更新日历」；
- 桌面与手机各截一张在播剧详情页证据图。

标 integration：要 pnpm 与 Playwright Chromium。
本地：``pytest -m integration tests/e2e/test_series_update_calendar_browser.py``。
"""

from __future__ import annotations

import asyncio
import os
import shutil
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path

import pytest

playwright = pytest.importorskip("playwright.sync_api")

REPO = Path(__file__).resolve().parents[2]
WEB = REPO / "apps" / "web"
ADMIN = {"username": "admin", "password": "e2e-passw0rd"}
_CHROMIUM_CANDIDATES = (os.environ.get("E2E_CHROMIUM"), "/opt/pw-browsers/chromium")
AIRING_TITLE = "在播验证剧"
ENDED_TITLE = "完结验证剧"

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


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("series-calendar-e2e")
    media = root / "media" / "shows"
    media.mkdir(parents=True)
    tmdb_log = root / "tmdb-requests.log"
    tmdb_log.touch()
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
        "E2E_TMDB_LOG": str(tmdb_log),
        "SCHEDULER_ENABLED": "false",
        "SUBSCRIPTION_DISPATCH_DRY_RUN": "true",
    }
    api_log = (root / "api.log").open("w")
    api = subprocess.Popen(  # noqa: S603
        [sys.executable, str(Path(__file__).with_name("_api_launcher.py"))],
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
            "NEXT_DIST_DIR": ".next-calendar-e2e",
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
        },
        stdout=web_log,
        stderr=subprocess.STDOUT,
        cwd=str(WEB),
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 90)
        _wait_http(f"http://127.0.0.1:{web_port}/login", 180)
        yield {
            "base": f"http://127.0.0.1:{web_port}",
            "media": media,
            "database_url": database_url,
            "shots": root / "shots",
            "logs": (root / "api.log", root / "web.log"),
        }
    finally:
        for proc in (web, api):
            proc.terminate()
        for proc in (web, api):
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        api_log.close()
        web_log.close()


def _chromium_kwargs() -> dict:
    for cand in _CHROMIUM_CANDIDATES:
        if cand and Path(cand).exists():
            return {"executable_path": cand}
    return {}


def settled_screenshot(page, path, **options):
    page.wait_for_function("""() => {
      const layers = document.querySelectorAll('div[aria-hidden=true].fixed.inset-0');
      return [...layers].filter(el => el.querySelector('svg')).every(el => {
        const style = getComputedStyle(el);
        return style.opacity === '0' || style.display === 'none';
      });
    }""")
    page.screenshot(path=str(path), **options)


def _seed(database_url: str, library_id: int, media_root: Path) -> dict[str, int]:
    """播种在播剧（本周排期 + 预测）与完结剧；返回标题 → media_item_id。"""
    from movieclaw_api.services.subscription.matching import publish_calendar_date
    from movieclaw_db.engine import Database
    from movieclaw_db.models import (
        FileSource,
        FileState,
        LibraryFile,
        MediaEpisode,
        MediaItem,
        RuleSet,
        Subscription,
        WantedItem,
        WantedStatus,
    )
    from movieclaw_db.models.base import utcnow

    today = publish_calendar_date(utcnow())
    ids: dict[str, int] = {}

    def _file(item_id: int, season: int, episode: int) -> LibraryFile:
        path = media_root / f"S{season:02d}E{episode:02d}.mkv"
        path.write_bytes(b"FAKE-MEDIA" * 32)
        return LibraryFile(
            library_id=library_id,
            media_item_id=item_id,
            season_number=season,
            episode_number=episode,
            file_path=str(path),
            size_bytes=path.stat().st_size,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            duration_seconds=600,
        )

    def _forecast(air_date, hour: int = 14) -> dict:
        predicted = f"{air_date}T{hour:02d}:40:00+08:00"
        return {
            "version": 1,
            "generated_at": predicted,
            "target_air_date": air_date,
            "predicted_at": predicted,
            "window_start": predicted,
            "window_end": predicted,
            "confidence": "stable",
            "sample_count": 3,
            "cadence_days": 1,
            "basis_units": [[1, 1]],
            "basis_torrent_row_ids": [1],
            "sites": [],
            "first": {
                "generated_at": predicted,
                "predicted_at": predicted,
                "window_start": predicted,
                "window_end": predicted,
                "confidence": "stable",
                "sample_count": 3,
            },
        }

    async def _run() -> None:
        db = Database(database_url)
        try:
            async with db.session() as session:
                rule = RuleSet(name="日历验收默认", spec={}, is_default=True)
                session.add(rule)
                await session.flush()

                airing = MediaItem(
                    kind="tv",
                    tmdb_id=96_547,
                    title=AIRING_TITLE,
                    original_title="Airing Calendar Show",
                    year=2026,
                    aliases=[],
                    status="Returning Series",
                )
                ended = MediaItem(
                    kind="tv",
                    tmdb_id=96_548,
                    title=ENDED_TITLE,
                    original_title="Ended Calendar Show",
                    year=2020,
                    aliases=[],
                    status="Ended",
                )
                session.add(airing)
                session.add(ended)
                await session.flush()
                assert airing.id and ended.id
                ids[AIRING_TITLE] = airing.id
                ids[ENDED_TITLE] = ended.id

                # 在播剧：E1–E5 已入库；E5 今天、E6 今天未入库、E7 明天有预测、E8 后天
                schedule = {
                    1: today - timedelta(days=4),
                    2: today - timedelta(days=3),
                    3: today - timedelta(days=2),
                    4: today - timedelta(days=1),
                    5: today,
                    6: today,
                    7: today + timedelta(days=1),
                    8: today + timedelta(days=2),
                }
                for episode, day in schedule.items():
                    session.add(
                        MediaEpisode(
                            media_item_id=airing.id,
                            season_number=1,
                            episode_number=episode,
                            name=f"第 {episode} 集",
                            air_date=day,
                        )
                    )
                    if episode <= 5:
                        session.add(_file(airing.id, 1, episode))

                sub = Subscription(
                    media_item_id=airing.id,
                    kind="tv",
                    selected_seasons=[1],
                    follow_future=True,
                    rule_set_id=rule.id,
                    library_id=library_id,
                )
                session.add(sub)
                await session.flush()
                assert sub.id

                for episode, day in schedule.items():
                    air = day.isoformat()
                    status = WantedStatus.IMPORTED if episode <= 5 else WantedStatus.WANTED
                    session.add(
                        WantedItem(
                            subscription_id=sub.id,
                            media_item_id=airing.id,
                            season_number=1,
                            episode_number=episode,
                            status=status,
                            air_date=day,
                            in_scope=True,
                            release_forecast=_forecast(air) if episode >= 6 else None,
                            imported_at=utcnow() if status == WantedStatus.IMPORTED else None,
                        )
                    )

                # 完结剧：有历史排期但不在窗口内；仍挂订阅（已完成）作对照
                for episode in (1, 2):
                    session.add(
                        MediaEpisode(
                            media_item_id=ended.id,
                            season_number=1,
                            episode_number=episode,
                            name=f"第 {episode} 集",
                            air_date=today - timedelta(days=400 + episode),
                        )
                    )
                    session.add(_file(ended.id, 1, episode))
                ended_sub = Subscription(
                    media_item_id=ended.id,
                    kind="tv",
                    selected_seasons=[1],
                    follow_future=False,
                    rule_set_id=rule.id,
                    library_id=library_id,
                    status="completed",
                )
                session.add(ended_sub)
                await session.flush()
                assert ended_sub.id
                for episode in (1, 2):
                    session.add(
                        WantedItem(
                            subscription_id=ended_sub.id,
                            media_item_id=ended.id,
                            season_number=1,
                            episode_number=episode,
                            status=WantedStatus.IMPORTED,
                            air_date=today - timedelta(days=400 + episode),
                            in_scope=True,
                            imported_at=utcnow(),
                        )
                    )
                await session.commit()
        finally:
            await db.dispose()

    with ThreadPoolExecutor(max_workers=1) as pool:
        pool.submit(asyncio.run, _run()).result()
    return ids


def test_series_update_calendar_on_library_detail(stack) -> None:
    from playwright.sync_api import expect, sync_playwright

    base = stack["base"]
    media: Path = stack["media"]
    shots: Path = stack["shots"]
    shots.mkdir(exist_ok=True)

    with sync_playwright() as pw:
        options = (
            {"channel": "chrome"}
            if Path("/Applications/Google Chrome.app").exists()
            else _chromium_kwargs()
        )
        browser = pw.chromium.launch(headless=True, **options)
        context = browser.new_context(viewport={"width": 1440, "height": 1100})
        page = context.new_page()
        page.set_default_timeout(20_000)
        page.set_default_navigation_timeout(120_000)
        errors: list[str] = []
        page.on("pageerror", lambda error: errors.append(str(error)))

        # 首次引导 + 登录（与 favorites 等库详情 e2e 同口径）
        page.goto(f"{base}/")
        page.wait_for_url(lambda u: "/setup" in u or "/login" in u)
        if "/setup" in page.url:
            page.locator("input[type=text]").fill(ADMIN["username"])
            page.locator("input[type=password]").nth(0).fill(ADMIN["password"])
            page.locator("input[type=password]").nth(1).fill(ADMIN["password"])
            page.locator("button[type=submit]").click()
            page.wait_for_url(lambda u: "/setup" not in u)
        page.goto(f"{base}/login")
        page.wait_for_load_state("networkidle")
        if "/login" in page.url:
            page.locator("input[type=text]").fill(ADMIN["username"])
            page.locator("input[type=password]").first.fill(ADMIN["password"])
            page.locator("button[type=submit]").click()
            page.wait_for_url(lambda u: "/login" not in u)

        created = page.request.post(
            f"{base}/api/v1/libraries",
            data={"name": "剧集库", "kind": "tv", "root_paths": [str(media)]},
        )
        assert created.ok, created.text()
        library_id = created.json()["data"]["id"]
        ids = _seed(stack["database_url"], library_id, media)

        # —— 在播剧：应出现更新日历 ——
        page.goto(
            f"{base}/library/{library_id}/item/{ids[AIRING_TITLE]}",
            wait_until="networkidle",
        )
        calendar = page.get_by_role("heading", name="更新日历")
        expect(calendar).to_be_visible(timeout=20_000)
        expect(page.get_by_role("tablist", name="更新日历")).to_be_visible()
        # 今天有两集（E05 已入库、E06 待播）
        expect(page.get_by_text("E05", exact=True)).to_be_visible()
        expect(page.get_by_text("已入库", exact=False).first).to_be_visible()
        settled_screenshot(page, shots / "airing-desktop.png", full_page=True)

        # 点明天：应看到 E07 预计入库
        tomorrow = page.get_by_role("tab").nth(1)
        tomorrow.click()
        expect(page.get_by_text("E07", exact=True)).to_be_visible()
        expect(page.get_by_text("预计入库").first).to_be_visible()
        settled_screenshot(page, shots / "airing-tomorrow.png", full_page=True)

        # —— 完结剧：不出现更新日历 ——
        page.goto(
            f"{base}/library/{library_id}/item/{ids[ENDED_TITLE]}",
            wait_until="networkidle",
        )
        expect(page.get_by_role("heading", name=ENDED_TITLE)).to_be_visible(timeout=20_000)
        expect(page.get_by_role("heading", name="更新日历")).to_have_count(0)
        settled_screenshot(page, shots / "ended-hidden.png", full_page=True)

        # —— 手机视口 ——
        page.set_viewport_size({"width": 390, "height": 844})
        page.goto(
            f"{base}/library/{library_id}/item/{ids[AIRING_TITLE]}",
            wait_until="networkidle",
        )
        expect(page.get_by_role("heading", name="更新日历")).to_be_visible(timeout=20_000)
        settled_screenshot(page, shots / "airing-mobile.png", full_page=True)

        assert not errors, f"页面 JS 报错：{errors}"
        browser.close()

        # 把证据图拷到 artifacts，供 PR 引用
        artifacts = Path("/opt/cursor/artifacts/screenshots")
        artifacts.mkdir(parents=True, exist_ok=True)
        for name in (
            "airing-desktop.png",
            "airing-tomorrow.png",
            "ended-hidden.png",
            "airing-mobile.png",
        ):
            src = shots / name
            if src.exists():
                shutil.copy2(src, artifacts / f"series-update-calendar-{name}")
