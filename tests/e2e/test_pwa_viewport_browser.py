"""WebKit 页面验收；注入 iOS standalone 的几何差异，不冒充真机 PWA。"""

# ruff: noqa: F811
import pytest
from tests.e2e.test_smart_subscription_browser import (
    pw,
    settled_screenshot,
    smart_stack,  # noqa: F401
)

pytestmark = pytest.mark.integration


PWA_METRICS = """() => {
  window.__pwaMetrics = {height: 912, visualHeight: 912};
  Object.defineProperty(navigator, 'standalone', {value: true});
  Object.defineProperty(window, 'innerHeight', {get: () => window.__pwaMetrics.height});
  Object.defineProperty(screen, 'height', {get: () => window.__pwaMetrics.height});
  Object.defineProperty(visualViewport, 'height', {get: () => window.__pwaMetrics.visualHeight});
  const supports = CSS.supports.bind(CSS);
  CSS.supports = (...args) => args[0] === '(-webkit-touch-callout: none)' || supports(...args);
  const computed = window.getComputedStyle.bind(window);
  window.getComputedStyle = (...args) => {
    const style = computed(...args);
    return new Proxy(style, {get(target, key) {
      if (key === 'getPropertyValue') return name =>
        name === '--safe-top' ? '68px' : target.getPropertyValue(name);
      const value = Reflect.get(target, key, target);
      return typeof value === 'function' ? value.bind(target) : value;
    }});
  };
  const original = Object.getOwnPropertyDescriptor(Element.prototype, 'clientHeight');
  Object.defineProperty(Element.prototype, 'clientHeight', {get() {
    return this === document.documentElement
      ? window.__pwaMetrics.height - 68 : original.get.call(this);
  }});
}"""


def test_webkit_pwa_canvas_recovery_and_normal_browser(smart_stack):
    base, api, root = smart_stack
    with pw.sync_playwright() as playwright:
        browser = playwright.webkit.launch(headless=True)
        context = browser.new_context(
            viewport={"width": 420, "height": 912}, is_mobile=True, has_touch=True
        )
        assert (
            context.request.post(
                f"{base}/api/v1/auth/bootstrap",
                data={"username": "pwa-admin", "password": "isolated-pwa-test"},
            ).status
            == 200
        )
        assert context.request.post(f"{api}/__lab/subscription-order").status == 200
        normal = context.new_page()
        normal.goto(f"{base}/library")
        normal.locator(".app-shell").wait_for()
        assert normal.locator("html[data-ios-standalone]").count() == 0
        assert normal.locator(".app-shell").bounding_box()["height"] == 912
        normal.close()
        context.add_init_script(f"({PWA_METRICS})()")
        page = context.new_page()
        page.goto(f"{base}/library")
        page.get_by_role("heading", name="媒体库", exact=True).wait_for()
        for route in ("library", "subscriptions"):
            if route == "subscriptions":
                page.locator('.glass-tabbar a[href="/subscriptions"]').click()
                page.wait_for_url(f"{base}/subscriptions")
            page.locator(".app-shell").wait_for()
            page.wait_for_function(
                "document.documentElement.style.getPropertyValue('--pwa-height') === '912px'"
            )
            for selector in ("html", "body", ".app-shell"):
                assert page.locator(selector).bounding_box()["height"] == 912, selector
            # 内容最下方仍有可命中的页面，不是空白文档；底栏保留原 fixed 定位。
            assert page.evaluate("document.elementFromPoint(210, 910) !== document.documentElement")
            tab = page.locator(".glass-tabbar").bounding_box()
            assert 0 < tab["y"] < tab["y"] + tab["height"] <= 912
            settled_screenshot(page, root / f"pwa-{route}.png")
            assert page.evaluate(
                "document.elementFromPoint(210, 910)?.closest('.app-shell') !== null"
            )
        # 输入时只有内容区收缩，根画布不缩；失焦后恢复满屏。
        page.evaluate("""() => {
          const input = document.createElement('input'); input.id = 'pwa-keyboard';
          document.body.append(input); input.focus();
          window.__pwaMetrics.visualHeight = 500;
          visualViewport.dispatchEvent(new Event('resize'));
        }""")
        page.wait_for_function(
            "document.querySelector('.app-shell').getBoundingClientRect().height === 500"
        )
        assert page.locator("body").bounding_box()["height"] == 912
        page.evaluate("""() => {
          document.getElementById('pwa-keyboard').blur();
          window.__pwaMetrics.visualHeight = 912;
          window.dispatchEvent(new Event('pageshow'));
        }""")
        page.wait_for_function(
            "document.querySelector('.app-shell').getBoundingClientRect().height === 912"
        )
        page.set_viewport_size({"width": 912, "height": 420})
        page.evaluate("""() => {
          window.__pwaMetrics.height = window.__pwaMetrics.visualHeight = 420;
          document.dispatchEvent(new Event('visibilitychange'));
        }""")
        page.wait_for_function("document.body.getBoundingClientRect().height === 420")
        assert page.locator(".app-shell").bounding_box()["height"] == 420
        browser.close()
