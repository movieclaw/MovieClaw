"""同步主干后的公开演示站：真实浏览器、Next、API、数据库与插件装配。"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import httpx
import pytest

from . import test_theme_device_class_browser as theme

pytestmark = pytest.mark.integration
ADMIN = {"username": "admin", "password": "movieclaw"}
MEMBER = {"username": "family", "password": "movieclaw"}
REVIEW = {"username": "review", "password": "review-passw0rd"}


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("demo-sync-e2e")
    data = root / "data"
    data.mkdir()
    accounts = root / "accounts.json"
    accounts.write_text(json.dumps({
        "notice": "演示站只读",
        "accounts": [{**ADMIN, "label": "超级管理员"}, {**MEMBER, "label": "家庭成员"}],
        "members": [{"username": "family", "nickname": "家人"}],
    }, ensure_ascii=False), encoding="utf-8")
    tmdb_log = root / "tmdb.log"
    tmdb_log.touch()
    api_port, web_port = theme._free_port(), theme._free_port()
    api_base, base = f"http://127.0.0.1:{api_port}", f"http://127.0.0.1:{web_port}"
    env = {
        **os.environ,
        "APP_ENV": "local", "APP_RELOAD": "false", "APP_PORT": str(api_port),
        "DATABASE_URL": f"sqlite+aiosqlite:///{data / 'app.db'}",
        "MOVIECLAW_DATA_DIR": str(data), "METADATA_DIR": str(data / "metadata"),
        "LOG_DIR": str(data / "logs"), "SECRET_KEY_FILE": str(data / ".secret_key"),
        "AGENT_SESSIONS_DIR": str(data / "sessions"), "SCHEDULER_ENABLED": "false",
        "MOVIECLAW_DEMO_ACCOUNTS_FILE": str(accounts), "MOVIECLAW_DEMO_MODE": "false",
        "MOVIECLAW_DEMO_SEED_DIR": str(root / "seeds"),
        "MOVIECLAW_DEMO_REVIEW_USERNAME": REVIEW["username"],
        "MOVIECLAW_DEMO_REVIEW_PASSWORD": REVIEW["password"], "E2E_TMDB_LOG": str(tmdb_log),
        "PYTHONPATH": str(theme.REPO / "src"),
    }
    processes = []
    with (root / "api.log").open("w") as api_log, (root / "web.log").open("w") as web_log:
        def start_api():
            api = subprocess.Popen(
                [sys.executable, str(Path(__file__).with_name("_api_launcher.py"))],
                env=env, stdout=api_log, stderr=subprocess.STDOUT, cwd=root,
            )
            processes.append(api)
            theme._wait_http(f"{api_base}/api/v1/auth/bootstrap", 180)
            return api

        try:
            # 和部署流程一致：先建账号，再用相同数据库按演示模式启动。
            api = start_api()
            with httpx.Client(base_url=api_base) as client:
                assert client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
                assert client.post("/api/v1/members", json=MEMBER).status_code == 200
            theme._stop(api)
            api.wait(timeout=20)
            env["MOVIECLAW_DEMO_MODE"] = "true"
            start_api()
            processes.append(subprocess.Popen(
                [theme.PNPM, "dev", "-p", str(web_port)],
                env={**os.environ, "NEXT_DIST_DIR": ".next-e2e",
                     "MOVIECLAW_API_PROXY_TARGET": api_base},
                stdout=web_log, stderr=subprocess.STDOUT, cwd=theme.WEB,
            ))
            theme._wait_http(f"{base}/login", 180)
            yield base
        finally:
            for proc in processes:
                if proc.poll() is None:
                    theme._stop(proc)
            for proc in processes:
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)


browser = theme.browser


def test_demo_login_read_only_and_review_flow(stack, browser):
    from playwright.sync_api import expect

    context = browser.new_context(locale="zh-CN", viewport={"width": 1280, "height": 900})
    context.set_default_timeout(30_000)
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    try:
        page.goto(f"{stack}/login?next=/library", wait_until="domcontentloaded")
        bootstrap = context.request.get(f"{stack}/api/v1/auth/bootstrap").json()["data"]
        assert bootstrap["demo"]["notice"] == "演示站只读"
        assert "android" in bootstrap["native_device_kinds"]
        page.get_by_role("button", name="演示账号 / App", exact=True).click()
        dialog = page.get_by_role("dialog", name="App 登录信息")
        expect(dialog.get_by_role("button", name="复制账号", exact=True)).to_be_visible()
        dialog.get_by_role("button", name="填入网页登录", exact=True).click()
        expect(page.get_by_placeholder("用户名", exact=True)).to_have_value("admin")
        page.get_by_role("button", name="登录", exact=True).last.click()
        page.wait_for_url(f"{stack}/library", wait_until="domcontentloaded")
        assert context.request.get(f"{stack}/api/v1/auth/me").json()["data"]["demo"] is True
        denied = context.request.post(f"{stack}/api/v1/members", data={
            "username": "forbidden", "password": "password123",
        })
        assert denied.status == 403 and denied.json()["code"] == "DEMO_READ_ONLY"
        types = context.request.get(f"{stack}/api/v1/downloaders/types").json()["data"]
        assert any(item["type"] == "demo" and item["title"] == "演示下载器" for item in types)
        page.goto(f"{stack}/settings/profile", wait_until="domcontentloaded")
        expect(page.get_by_text(
            "这是公开演示站：演示账号由所有访客共用，密码不能修改。", exact=True
        )).to_be_visible()
        artifacts = theme.REPO / ".tmp-uidev" / "demo-sync"
        artifacts.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(artifacts / "public-profile.png"), full_page=True)
        page.goto(f"{stack}/settings/app", wait_until="domcontentloaded")
        expect(page.get_by_role("button", name="重启应用", exact=True)).to_have_count(0)
        expect(page.get_by_text("演示站不提供应用内更新", exact=True)).to_be_visible()
        # 真实 Agent 运行与 SSE 回放，随后用另一登录设备确认会话隔离。
        started = context.request.post(f"{stack}/api/v1/sessions", data={"content": "你好"})
        assert started.status == 202, started.text()
        sid = started.json()["data"]["session_id"]
        events = context.request.get(f"{stack}/api/v1/sessions/{sid}/events", timeout=30_000)
        assert events.ok and "agent_done" in events.text(), events.text()
        transcript = context.request.get(f"{stack}/api/v1/sessions/{sid}").json()["data"]
        assert transcript["entries"]
        with browser.new_context(locale="zh-CN") as other:
            assert other.request.post(f"{stack}/api/v1/auth/login", data=ADMIN).ok
            assert other.request.get(f"{stack}/api/v1/sessions/{sid}").status == 404
        # 审核账号走正常权限：可以修改数据，且不能看公开访客的会话。
        with browser.new_context(locale="zh-CN") as review:
            assert review.request.post(f"{stack}/api/v1/auth/login", data=REVIEW).ok
            assert review.request.get(f"{stack}/api/v1/auth/me").json()["data"]["demo"] is False
            assert review.request.put(
                f"{stack}/api/v1/auth/profile", data={"nickname": "审核验证"}
            ).ok
            assert review.request.get(f"{stack}/api/v1/sessions/{sid}").status == 404
        with browser.new_context(
            locale="zh-CN", viewport={"width": 390, "height": 844},
            is_mobile=True, has_touch=True,
        ) as member:
            mobile = member.new_page()
            mobile.goto(f"{stack}/login?next=/library", wait_until="domcontentloaded")
            mobile.get_by_role("button", name="演示账号 / App", exact=True).click()
            info = mobile.get_by_role("dialog", name="App 登录信息")
            info.get_by_role("button", name="家庭成员", exact=True).click()
            info.get_by_role("button", name="填入网页登录", exact=True).click()
            expect(mobile.get_by_placeholder("用户名", exact=True)).to_have_value("family")
            mobile.get_by_role("button", name="登录", exact=True).last.click()
            mobile.wait_for_url(f"{stack}/library", wait_until="domcontentloaded")
            identity = member.request.get(f"{stack}/api/v1/auth/me").json()["data"]
            assert identity["role"] == "member" and identity["demo"] is True
            expect(mobile.get_by_role("status").filter(has_text="全站只读")).to_be_visible()
            mobile.screenshot(path=str(artifacts / "member-mobile.png"), full_page=True)
        assert not errors, errors
    finally:
        context.close()
