"""外部播放器真实端到端验收（复用 test_media_share_browser 的 dev stack）。

本地：``pytest -m integration tests/e2e/test_external_player_browser.py``。
"""

from __future__ import annotations

import json
import re
from urllib.parse import unquote

from . import test_media_share_browser as _share_e2e

pytestmark = _share_e2e.pytestmark
stack = _share_e2e.stack

_MAC_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
_ANCHOR_INTERCEPT_JS = (
    "window.__extLaunches=[];"
    "const _c=HTMLAnchorElement.prototype.click;"
    "HTMLAnchorElement.prototype.click=function(...a){"
    "const h=this.getAttribute('href')||'';"
    "if(h&&!/^(https?:|\\/|#)/i.test(h)){window.__extLaunches.push(h);return;}"
    "return _c.apply(this,a);};"
)
_CLIPBOARD_STUB_JS = (
    "()=>{Object.defineProperty(navigator,'clipboard',{value:undefined,configurable:true});"
    "window.__execCopied=[];window.__execReturn=true;"
    "document.execCommand=(cmd)=>{if(cmd!=='copy')return false;"
    "const el=document.activeElement;"
    "const ta=el&&el.tagName==='TEXTAREA'?el:document.querySelector('textarea[readonly]');"
    "window.__execCopied.push(ta?ta.value:'');return window.__execReturn;};}"
)
_DISC_409_MSG = "原盘目录（BDMV / VIDEO_TS）没有单个文件，外部播放器打不开，请用网页或 App 播放"


def _is_ext_link_post(resp) -> bool:
    return resp.url.endswith("/api/v1/playback/external-link") and resp.request.method == "POST"


def test_external_player_full_flow(stack) -> None:
    from playwright.sync_api import expect, sync_playwright

    base = stack["base"]

    def api(ctx, method: str, path: str, **kw):
        kw.setdefault("headers", {"Accept-Language": "zh-Hans"})
        url = path if path.startswith(("http://", "https://")) else f"{base}/api/v1{path}"
        return getattr(ctx.request, method)(url, **kw)

    def api_json(ctx, path: str) -> dict:
        resp = api(ctx, "get", path)
        assert resp.ok, f"{path}: {resp.status} {resp.text()}"
        return resp.json()["data"]

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, **_share_e2e._chromium_kwargs())
        admin_ctx = browser.new_context(
            viewport={"width": 1440, "height": 900}, locale="zh-CN", user_agent=_MAC_UA
        )
        admin_ctx.add_init_script(_ANCHOR_INTERCEPT_JS)
        visitor_ctx = browser.new_context(
            viewport={"width": 1280, "height": 800}, locale="zh-CN", user_agent=_MAC_UA
        )
        page_errors: list[str] = []

        def open_page(ctx, tag: str):
            pg = ctx.new_page()
            pg.set_default_timeout(20_000)
            pg.set_default_navigation_timeout(120_000)
            pg.on("pageerror", lambda e: page_errors.append(f"{tag}: {e}"))
            return pg

        try:
            admin = open_page(admin_ctx, "admin")
            _share_e2e._login(admin, base)

            # 1. 建电影库 + 剧集库并等待真实扫描识别
            def create_lib(name: str, kind: str, root) -> int:
                payload = {"name": name, "kind": kind, "root_paths": [str(root)],
                           "realtime_watch": False}
                return api(admin, "post", "/libraries", data=payload).json()["data"]["id"]

            movie_lib = create_lib("电影", "movie", stack["movie_root"])
            tv_lib = create_lib("剧集", "tv", stack["tv_root"])

            def scanned(lib_id: int, title: str):
                lib = next(x for x in api_json(admin, "/libraries") if x["id"] == lib_id)
                if lib["scanning"] or not lib["last_scan"]:
                    return None
                items = api_json(admin, f"/libraries/{lib_id}/items")
                rows = items if isinstance(items, list) else items.get("items", [])
                return next((r for r in rows if r.get("title") == title), None)

            movie = _share_e2e._wait_for(
                lambda: scanned(movie_lib, "某电影"), timeout=180, what="电影库扫描识别"
            )
            show = _share_e2e._wait_for(
                lambda: scanned(tv_lib, "测试剧集"), timeout=180, what="剧集库扫描识别"
            )
            movie_id, show_id = movie["media_item_id"], show["media_item_id"]

            def close_dialog() -> None:
                admin.keyboard.press("Escape")
                expect(admin.get_by_role("dialog")).to_have_count(0)

            # 2. 电影详情：IINA 拉起（拦截 scheme）、真实外链 + 匿名 Range 206 + 结果面板
            admin.goto(f"{base}/library/{movie_lib}/item/{movie_id}")
            expect(admin.get_by_role("heading", name="某电影")).to_be_visible(timeout=60_000)
            admin.get_by_role("button", name="用外部播放器打开").click()
            with admin.expect_response(_is_ext_link_post) as movie_resp:
                admin.get_by_role("menuitem", name="用 IINA 打开").click()
            assert movie_resp.value.status == 200
            movie_link = movie_resp.value.json()["data"]

            dialog = admin.get_by_role("dialog")
            expect(dialog).to_be_visible()
            expect(dialog.get_by_text("12 小时内有效")).to_be_visible()
            expect(dialog.get_by_text("不同步进度")).to_be_visible()
            launches = admin.evaluate("() => window.__extLaunches.slice()")
            assert len(launches) == 1 and launches[0].startswith("iina://weblink?url="), launches
            decoded_url = unquote(launches[0].removeprefix("iina://weblink?url="))
            assert decoded_url == movie_link["stream_url"]
            assert f"/api/v1/playback/files/{movie_link['file_id']}/stream/" in decoded_url
            assert "token=" in decoded_url
            expect(dialog.get_by_label("视频链接")).to_have_value(decoded_url)

            range_resp = visitor_ctx.request.get(decoded_url, headers={"Range": "bytes=0-1023"})
            assert range_resp.status == 206, range_resp.status
            assert range_resp.headers.get("content-range", "").startswith("bytes 0-1023/")
            assert len(range_resp.body()) == 1024
            close_dialog()

            # 3. 默认偏好刷新后存在
            admin.reload()
            expect(admin.get_by_role("heading", name="某电影")).to_be_visible(timeout=60_000)
            expect(admin.get_by_role("button", name="用 IINA 打开")).to_be_visible()
            pref = admin.evaluate("() => localStorage.getItem('movieclaw.player.external-player')")
            assert pref == "iina"

            # 4. 剧集第二集卡片菜单：签发 S01E02
            admin.goto(f"{base}/library/{tv_lib}/item/{show_id}")
            expect(admin.get_by_role("heading", name="测试剧集")).to_be_visible(timeout=60_000)
            ep2_card = admin.locator('[data-episode-number="2"]')
            expect(ep2_card).to_be_visible()
            admin.evaluate("() => { window.__extLaunches.length = 0; }")
            ep2_card.hover()
            ep2_card.get_by_role("button", name="第 2 集：外部播放器").click()
            with admin.expect_response(_is_ext_link_post) as ep2_resp:
                admin.get_by_role("menuitem", name="用 IINA 打开").click()
            assert ep2_resp.value.status == 200
            ep2_req = ep2_resp.value.request.post_data_json
            assert ep2_req["media_item_id"] == show_id
            assert (ep2_req["season_number"], ep2_req["episode_number"]) == (1, 2)
            ep2_link = ep2_resp.value.json()["data"]
            assert "S01E02" in ep2_link["title"] and "S01E02" in ep2_link["file_name"]
            expect(admin.get_by_role("dialog").get_by_text("S01E02")).to_be_visible()
            close_dialog()

            # 5. page.route 覆盖 409 中文错误；execCommand 降级与完全失败手动复制面板
            err_body = json.dumps(
                {"success": False, "code": "CONFLICT", "message": _DISC_409_MSG, "data": None}
            )
            admin.route(
                "**/api/v1/playback/external-link",
                lambda r: r.fulfill(status=409, content_type="application/json", body=err_body),
            )
            try:
                admin.get_by_role("button", name="用 IINA 打开").click()
                expect(admin.get_by_text(_DISC_409_MSG)).to_be_visible()
                expect(admin.get_by_role("dialog")).to_have_count(0)
            finally:
                admin.unroute("**/api/v1/playback/external-link")

            admin.evaluate(_CLIPBOARD_STUB_JS)
            admin.get_by_role("button", name="用外部播放器打开").click()
            admin.get_by_role("menuitem", name="复制链接").click()
            expect(admin.get_by_text("链接已复制，12 小时内有效")).to_be_visible()
            copied = admin.evaluate("() => window.__execCopied.slice()")
            assert len(copied) == 1 and "/api/v1/playback/files/" in copied[0]
            assert "token=" in copied[0]

            admin.evaluate("() => { window.__execReturn = false; }")
            admin.get_by_role("button", name="用外部播放器打开").click()
            admin.get_by_role("menuitem", name="复制链接").click()
            manual_dialog = admin.get_by_role("dialog")
            expect(manual_dialog.get_by_text("浏览器没有允许写入剪贴板")).to_be_visible()
            expect(manual_dialog.get_by_text("已选中链接")).to_be_visible()
            expect(manual_dialog.get_by_label("视频链接")).to_have_value(
                re.compile(r"/api/v1/playback/files/\d+/stream/.*token=")
            )
            close_dialog()

            # 6. 真实分享访客页：结构隐藏无外部播放器入口，匿名请求外链被拒
            visitor = open_page(visitor_ctx, "visitor")
            share_cfg = {"expires_in_days": 1, "password": None}
            for lib_id, item_id, title in (
                (movie_lib, movie_id, "某电影"),
                (tv_lib, show_id, "测试剧集"),
            ):
                slug = api(
                    admin, "post", f"/libraries/{lib_id}/items/{item_id}/share", data=share_cfg
                ).json()["data"]["slug"]
                visitor.goto(f"{base}/s/{slug}")
                expect(visitor.get_by_role("heading", name=title)).to_be_visible(timeout=60_000)
                expect(visitor.get_by_role("button", name="播放", exact=True)).to_be_visible()
                assert visitor.get_by_role("button", name="用外部播放器打开").count() == 0
                assert visitor.get_by_role("button", name=re.compile("外部播放器")).count() == 0
                assert visitor.get_by_role("button", name=re.compile(r"^用 .+ 打开$")).count() == 0
            anon = api(
                visitor_ctx, "post", "/playback/external-link", data={"media_item_id": movie_id}
            )
            assert anon.status == 401
            assert not page_errors, page_errors
        finally:
            visitor_ctx.close()
            admin_ctx.close()
            browser.close()
