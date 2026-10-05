import assert from "node:assert/strict";
import test from "node:test";

import {
  WIDTH_LADDER,
  coverWidth,
  imageSizes,
  imageSrcSet,
  responsiveImage,
  screenImageWidth,
  snapWidth,
  withImageWidth,
} from "../lib/image-width.ts";

test("阶梯与后端一致：向上取整，超过最大档取最大档", () => {
  assert.deepEqual([...WIDTH_LADDER], [160, 240, 360, 480, 720, 960, 1280, 1920, 2560, 3840]);
  assert.equal(snapWidth(1), 160);
  assert.equal(snapWidth(160), 160);
  assert.equal(snapWidth(161), 240);
  assert.equal(snapWidth(348), 360);
  assert.equal(snapWidth(2410), 2560);
  assert.equal(snapWidth(3840), 3840);
  assert.equal(snapWidth(9999), 3840);
  // 非法输入按最小档，不拼出 w=NaN
  assert.equal(snapWidth(0), 160);
  assert.equal(snapWidth(Number.NaN), 160);
});

test("铺满的有效宽：竖框铺横图要按高算", () => {
  // 手机详情页 393×452 的框铺 16:9 剧照（设计稿 §6 的例子）
  assert.equal(Math.round(coverWidth(393, 452, 16 / 9)), 804);
  // 2:3 海报铺 2:3 框：就是框宽
  assert.equal(coverWidth(164, 246, 2 / 3), 164);
});

test("withImageWidth 只动查询串：追加、替换旧 w / variant，不碰代理里编码的远端地址", () => {
  assert.equal(withImageWidth("/api/images/assets/5/poster.jpg", 300), "/api/images/assets/5/poster.jpg?w=360");
  assert.equal(
    withImageWidth("/api/libraries/1/cover?v=42", 200),
    "/api/libraries/1/cover?v=42&w=240",
  );
  assert.equal(
    withImageWidth("/api/images/assets/5/poster.jpg?variant=poster-card&w=160", 700),
    "/api/images/assets/5/poster.jpg?w=720",
  );
  const proxied = `/api/images/proxy?url=${encodeURIComponent("https://img.example/a.jpg?w=10&x=1")}`;
  assert.equal(withImageWidth(proxied, 1000), `${proxied}&w=1280`);
  assert.equal(withImageWidth("/a.jpg#frag", 100), "/a.jpg?w=160#frag");
});

test("withImageWidth 不碰空串与本地 data: / blob: 地址", () => {
  assert.equal(withImageWidth("", 300), "");
  assert.equal(withImageWidth("data:image/png;base64,AAAA", 300), "data:image/png;base64,AAAA");
  assert.equal(withImageWidth("blob:http://x/1", 300), "blob:http://x/1");
});

test("srcset 列出 1x/2x/3x 对应档位并去重，sizes 计入放大系数", () => {
  // 海报卡 220 × 悬停 1.06：233 / 466 / 700 → 240 / 480 / 720
  assert.equal(
    imageSrcSet("/p.jpg", 220, 1.06),
    "/p.jpg?w=240 240w, /p.jpg?w=480 480w, /p.jpg?w=720 720w",
  );
  assert.equal(imageSizes(220, 1.06), "234px");
  // 28 宽的小图：三档都落在 160，只剩一项
  assert.equal(imageSrcSet("/p.jpg", 28), "/p.jpg?w=160 160w");
});

test("responsiveImage：src 兜底取 2x 档；非服务端地址只回 src", () => {
  assert.deepEqual(responsiveImage("/p.jpg", 100), {
    src: "/p.jpg?w=240",
    srcSet: "/p.jpg?w=160 160w, /p.jpg?w=240 240w, /p.jpg?w=360 360w",
    sizes: "100px",
  });
  assert.deepEqual(responsiveImage("blob:http://x/1", 100), { src: "blob:http://x/1" });
});

test("screenImageWidth 按给定倍率算并取档", () => {
  assert.equal(screenImageWidth(420, 1, 2), 960);
  assert.equal(screenImageWidth(1920, 1.1, 1), 2560);
  assert.equal(screenImageWidth(240, 1, 3), 720);
});
