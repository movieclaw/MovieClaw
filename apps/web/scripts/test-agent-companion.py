#!/usr/bin/env python3
"""网页版小幕：真实浏览器 → API → Agent 工具 → SSE，仅模型使用隔离测试服务。

先运行 apps/apple/scripts/agent-companion-lab.py，然后用独立 Next 服务反代至 18831。
从仓库根目录运行 .venv/bin/python apps/web/scripts/test-agent-companion.py。
"""

import argparse
import asyncio
import json
import time
from pathlib import Path

from playwright.async_api import async_playwright, expect


async def run(base, out):
    out.mkdir(parents=True, exist_ok=True)
    results = []
    async with async_playwright() as browsers:
        for name, engine, options in [
            ("desktop", browsers.chromium, {"viewport": {"width": 1280, "height": 900}}),
            ("iphone-safari", browsers.webkit, {**browsers.devices["iPhone 13"]}),
            (
                "reduced-motion",
                browsers.chromium,
                {**browsers.devices["iPhone 13"], "reduced_motion": "reduce"},
            ),
        ]:
            browser = await engine.launch()
            context = await browser.new_context(**options)
            try:
                login = await context.request.post(
                    base + "/api/v1/auth/login",
                    data={
                        "username": "admin",
                        "password": "moon-test-2026",
                        "remember": True,
                    },
                )
                assert login.ok, f"测试登录失败：{login.status}"
                page = await context.new_page()
                errors = []
                page.on("pageerror", lambda error, errors=errors: errors.append(str(error)))
                await page.goto(base + "/new")
                pet = page.get_by_test_id("agent-companion")
                editor = page.locator('[contenteditable="true"][aria-label="消息输入框"]')
                composer = page.get_by_test_id("agent-composer")
                await expect(pet).to_be_visible(timeout=60000)
                await page.wait_for_function("""() => {
                    const layers = document.querySelectorAll('div[aria-hidden="true"]');
                    return !Array.from(layers).some(el => {
                    const style = getComputedStyle(el);
                    return style.position === 'fixed' && style.zIndex === '100'
                        && Number(style.opacity) > 0.01;
                    });
                }""")
                await expect(pet).to_have_attribute("data-pose", "idle")
                box = await composer.bounding_box()
                await pet.evaluate("el => el.style.display = 'none'")
                assert await composer.bounding_box() == box, "宠物增加了输入区尺寸"
                await pet.evaluate("el => el.style.display = ''")
                style = await pet.evaluate(
                    "el => ({position: getComputedStyle(el).position, "
                    "background: getComputedStyle(el).backgroundColor})"
                )
                assert style == {"position": "absolute", "background": "rgba(0, 0, 0, 0)"}
                pet_box = await pet.bounding_box()
                assert abs(pet_box["y"] + 62 - box["y"]) < 1
                await page.screenshot(path=out / f"{name}-idle.png")

                async def ask(text, *, editor=editor, pet=pet, page=page):
                    await editor.fill(text)
                    await expect(pet).to_have_attribute("data-pose", "attentive")
                    await page.get_by_role("button", name="发送", exact=True).click()
                    await page.wait_for_url("**/sessions/*")

                async def settle(pose, *, pet=pet):
                    await expect(pet).to_have_attribute("data-pose", pose, timeout=30000)
                    await expect(pet).to_have_attribute("data-moving", "false", timeout=8000)
                    await expect(pet).to_have_attribute("data-frame", "0", timeout=2000)

                async def quiet(pose, seconds, *, pet=pet):
                    end = time.monotonic() + seconds
                    box = await pet.bounding_box()
                    while time.monotonic() < end:
                        assert await pet.get_attribute("data-pose") == pose
                        assert await pet.get_attribute("data-moving") == "false", "动作不应持续循环"
                        assert await pet.get_attribute("data-frame") == "0"
                        assert await pet.bounding_box() == box, "等待时身体位置改变"
                        await asyncio.sleep(0.2)

                if name != "reduced-motion":
                    await pet.click()
                    await editor.fill("今晚想看一部轻松的电影，请查一下片库")
                    await settle("attentive")
                    await page.get_by_role("button", name="发送", exact=True).click()
                    await page.wait_for_url("**/sessions/*")
                    await settle("working")
                    await page.screenshot(path=out / f"{name}-working.png")
                    await expect(pet).to_have_attribute("data-pose", "complete", timeout=30000)
                    await page.screenshot(path=out / f"{name}-complete.png")
                    await expect(
                        page.get_by_text("《月夜放映室》", exact=False).last
                    ).to_be_visible()
                    await settle("idle")
                    # 重新进入历史会话不重复庆祝。
                    await page.reload()
                    await settle("idle")
                    await quiet("idle", 2)

                await ask("[pet-stop] 慢慢查询片库")
                await settle("working")
                await quiet("working", 6 if name == "desktop" else 2)
                if name == "desktop":
                    await page.evaluate("""() => {
                        window.__petBlinks = [];
                        window.__petObserver = new MutationObserver(() => {
                            const pet = document.querySelector('[data-testid="agent-companion"]');
                            if (pet.dataset.moving === 'true') {
                                window.__petBlinks.push(Number(pet.dataset.frame));
                            }
                        });
                        const pet = document.querySelector('[data-testid="agent-companion"]');
                        window.__petObserver.observe(pet, {attributes: true});
                    }""")
                    await page.wait_for_function(
                        "window.__petBlinks.length > 0", timeout=26000, polling=50
                    )
                    assert set(await page.evaluate("window.__petBlinks")) == {2}, (
                        "眨眼不应重播整轮啃鱼"
                    )
                    await page.evaluate("window.__petObserver.disconnect()")
                    await settle("working")
                    await quiet("working", 2)
                    # 页面可见性事件：恢复前台后保持抱鱼，不重新出发或啃鱼。
                    await page.evaluate(
                        "Object.defineProperty(document, 'hidden', "
                        "{value: true, configurable: true}); "
                        "document.dispatchEvent(new Event('visibilitychange'))"
                    )
                    await quiet("working", 1)
                    await page.evaluate(
                        "delete document.hidden; "
                        "document.dispatchEvent(new Event('visibilitychange'))"
                    )
                    await quiet("working", 2)
                await page.get_by_role("button", name="停止生成", exact=True).click()
                await settle("idle")

                await ask("[pet-error] 帮我找电影")
                await settle("failed")
                await quiet("failed", 4)
                await page.screenshot(path=out / f"{name}-failed.png")
                await editor.fill("重新查询电影")
                await settle("attentive")
                await quiet("attentive", 2)
                assert not errors, errors
                results.append({"scenario": name, "passed": True})
                print("PASS", name, flush=True)
            except Exception:
                await page.screenshot(path=out / f"{name}-failure.png")
                raise
            finally:
                await context.close()
                await browser.close()
    (out / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="http://127.0.0.1:3093")
    parser.add_argument("--out", type=Path, default=Path("/tmp/movieclaw-web-companion"))
    args = parser.parse_args()
    asyncio.run(run(args.base.rstrip("/"), args.out))
