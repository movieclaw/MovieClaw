import assert from "node:assert/strict";
import test from "node:test";
import { DISPLAY_MODES, currentDisplaySelection, displayLayout, subtitleCanvasTransform } from "../lib/player/display-mode.ts";

test("三种模式；同剧换集/换版本保留，换影片清除且不复活旧选择", () => {
  assert.deepEqual(DISPLAY_MODES.map(m => m.id), ["fit", "fill", "stretch"]);
  const selected = { mediaItemId: 7, mode: "fill" };
  // 连播、手动选集、换版本和重建会话都保持 mediaItemId。
  assert.equal(currentDisplaySelection(selected, 7), selected);
  const changed = currentDisplaySelection(selected, 8);
  assert.equal(changed, null);
  assert.equal(currentDisplaySelection(changed, 7), null);
});

test("内嵌上下黑边的16:9视频等比例铺满后左右贴边", () => {
  assert.equal(displayLayout("fit", 1280, 589, 1920, 1080).objectFit, "contain");
  const zoom = displayLayout("fill", 1280, 589, 1920, 1080);
  assert.equal(zoom.objectFit, "cover");
  assert.equal(zoom.height, 589);
  assert.equal(804 * 1280 / 1920, 536);
});

test("普通16:9、宽银幕、4:3和竖屏：字幕使用可见画面", () => {
  for (const [cw, ch, vw, vh] of [[1280, 589, 1920, 804], [1024, 768, 1920, 1080], [390, 844, 1440, 1080]]) {
    for (const mode of DISPLAY_MODES) {
      const box = displayLayout(mode.id, cw, ch, vw, vh);
      assert.ok(box.bottomInset >= 0 && box.height <= ch);
    }
    assert.equal(displayLayout("fill", cw, ch, vw, vh).objectFit, "cover");
  }
  assert.equal(displayLayout("stretch", 1280, 589, 1440, 1080).objectFit, "fill");
  assert.equal(displayLayout("fill", 1280, 589, 0, 0).objectFit, "contain");
});

test("ASS定位画布跟随视频：铺满等比例，拉伸分别缩放，回默认不变", () => {
  const zoom = 1280 / (1920 * 589 / 1080);
  assert.equal(subtitleCanvasTransform("fill", 1280, 589, 1920, 1080), `scale(${zoom}, ${zoom})`);
  assert.equal(subtitleCanvasTransform("stretch", 1280, 589, 1920, 1080), `scale(${zoom}, 1)`);
  assert.equal(subtitleCanvasTransform("fit", 1280, 589, 1920, 1080), "none");
  assert.equal(subtitleCanvasTransform("fill", 1280, 589, 0, 0), "none");
});
