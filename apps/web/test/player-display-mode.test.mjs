import assert from "node:assert/strict";
import test from "node:test";
import { DISPLAY_MODES, currentDisplaySelection, displayLayout, nextDisplayMode } from "../lib/player/display-mode.ts";

test("同文件重建保留选择，换集或换文件后再回来也恢复完整显示", () => {
  const selected = { unit: "episode-1", file: 1, mode: "fill" };
  assert.equal(currentDisplaySelection(selected, "episode-1", null), selected);
  assert.equal(currentDisplaySelection(selected, "episode-1", 1), selected);
  for (const [unit, file] of [["episode-2", 1], ["episode-1", 2]]) {
    let selection = currentDisplaySelection(selected, unit, file);
    assert.equal(selection, null);
    selection = currentDisplaySelection(selection, "episode-1", 1);
    assert.equal(selection?.mode ?? "fit", "fit");
  }
});

test("四个模式循环回完整显示", () => {
  let mode = "fit";
  for (let i = 0; i < DISPLAY_MODES.length; i++) mode = nextDisplayMode(mode);
  assert.equal(mode, "fit");
});

test("内置黑边的16:9片源可按宽放大，电影有效画面保持原比例", () => {
  const normal = displayLayout("fit", 1280, 589, 1920, 1080);
  assert.equal(normal.objectFit, "contain");
  const zoom = displayLayout("fitWidth", 1280, 589, 1920, 1080);
  assert.equal(zoom.objectFit, "cover");
  assert.equal(zoom.height, 589);
  // 真实影片有效高度804：放到1280宽时约536高，仍有上下黑边。
  assert.equal(804 * 1280 / 1920, 536);
});

test("宽银幕按宽适配保留左右，铺满才裁左右；4:3和竖屏同理", () => {
  for (const [cw, ch, vw, vh] of [[1280, 589, 1920, 804], [1024, 768, 1920, 1080], [390, 844, 1440, 1080]]) {
    const width = displayLayout("fitWidth", cw, ch, vw, vh);
    assert.equal(width.objectFit, "contain");
    assert.equal(width.height, vh * cw / vw);
    assert.equal(displayLayout("fill", cw, ch, vw, vh).objectFit, "cover");
  }
});

test("缩放字幕仍在可见区域，拉伸不改变视频元素的布局尺寸", () => {
  for (const mode of DISPLAY_MODES) {
    const box = displayLayout(mode.id, 1280, 589, 1440, 1080);
    assert.ok(box.bottomInset >= 0);
    assert.ok(box.height <= 589);
  }
  assert.equal(displayLayout("stretch", 1280, 589, 1440, 1080).objectFit, "fill");
  assert.equal(displayLayout("fill", 1280, 589, 0, 0).objectFit, "contain");
});
