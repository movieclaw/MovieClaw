// 网页播放器故障注入实验台的场景（docs/design/web-player.md §14）。
//
// 片源是个人片库里的条目，不入库：用环境变量给播放页地址（要带 ?t= 固定起播点），没给的场景跳过。
//   WEB_FAULTLAB_HLS        视频直通的服务端流（档 1 / 2，换封装或只转音轨），码率越高越好，例如 /play/123?t=600
//   WEB_FAULTLAB_DIRECT     档 0 直出的 MP4（H.264 + AAC），例如 /play/456?t=600
//   WEB_FAULTLAB_DECODE     （可选）会撞上硬解错误的位置，例如 /play/123?t=634
//   WEB_FAULTLAB_TRANSCODE  （可选）网页要整片转码的片子（4K HDR、HEVC 等），例如 /play/789?t=600
//   WEB_FAULTLAB_MP4_REMUX  （可选）音轨浏览器不支持、要换封装的 MP4，量首播
//   WEB_FAULTLAB_TS         （可选）要换封装的 TS，量首播
//   WEB_FAULTLAB_SEEKS      （可选）有片头片尾识别结果的剧集，从头放，量「跳过片头」与远跳，例如 /play/123/s1e1
//   WEB_FAULTLAB_AUDIO      （可选）多音轨条目：<条目 id>:<非默认音轨引用>:<播放页地址>，例如 123:embedded:7:/play/123?t=600
//                           「非默认」要同时避开容器默认轨和默认轨策略会挑的那条（比如日本片的日语原声）：
//                           选到策略本来就会挑的轨，服务端不当它是用户的选择、不记（playback/state.py）
//
// 每个场景的 expect 按 iOS faultlab 的做法自动判定：线路慢不降档、断线原地恢复、一直断落错误页……
// 拿到的是这一场的事件（会话请求 / 响应、界面文字、播放头采样），返回 null = 通过，否则是失败原因。

const env = (name) => process.env[`WEB_FAULTLAB_${name}`] || null;
const cut = (secs) => async ({ proxy }) => proxy.setFault("refuse", { secs, cut: true });
const hang = (secs) => async ({ proxy }) => proxy.setFault("hang", { secs, cut: true });

/** 所有开会话请求都没有带「已失败的档位」：一次都没降档 */
function noStepDown(r) {
  const degraded = r.sessionRequests.find((q) => (q.failed_tiers ?? []).length > 0);
  return degraded ? `降档了：第 ${degraded.t} 秒开会话带 failed_tiers=${JSON.stringify(degraded.failed_tiers)}` : null;
}

/** 最后 10 秒播放头在走 */
function playingAtEnd(r) {
  const tail = r.states.filter((s) => s.t > r.endedAt - 10 && typeof s.ct === "number");
  if (tail.length < 2) return "结尾没有播放头采样";
  return tail[tail.length - 1].ct > tail[0].ct + 3 ? null : `结尾 10 秒播放头没在走（${tail[0].ct} → ${tail[tail.length - 1].ct}）`;
}

function uiShows(r, pattern) {
  return r.uiTexts.some((t) => pattern.test(t)) ? null : `界面没出现 ${pattern}`;
}

function firstUiAt(r, pattern) {
  return r.uiEvents.find((u) => pattern.test(u.texts))?.t ?? null;
}

const all = (...checks) => (r) => checks.map((c) => c(r)).find((x) => x) ?? null;

/** 唤出控制条后在进度条的 fraction 处点一下（触屏 tap / 桌面 click），即一次 scrub 跳转 */
const scrubTo = (fraction) => async ({ page }) => {
  const video = page.locator("video");
  const tap = async (x, y) => ((await page.evaluate(() => "ontouchstart" in window)) ? page.touchscreen.tap(x, y) : page.mouse.click(x, y));
  const box = await video.boundingBox();
  await tap(box.x + box.width / 2, box.y + box.height / 3);
  await page.waitForTimeout(400);
  const bar = await page.locator('input[aria-label="播放进度"]').boundingBox();
  await tap(bar.x + bar.width * fraction, bar.y + bar.height / 2);
};

export const scenarios = {
  // —— 跳转耗时：「跳过片头」（缓冲内）→ 拖到片尾附近（缓冲外）→ 拖回中段，结果看服务端播放记录 ——
  seeks: {
    route: env("SEEKS"),
    durationS: 45,
    steps: [
      { name: "跳过片头", afterPlayingS: 2, run: async ({ page }) => page.locator('[data-testid="skip-segment"]').click() },
      { name: "拖到片尾附近", afterPlayingS: 10, run: scrubTo(0.93) },
      { name: "拖回中段", afterPlayingS: 24, run: scrubTo(0.22) },
    ],
    expect: () => null,
  },

  smoke: { route: env("HLS"), durationS: 30, expect: all(noStepDown, playingAtEnd) },

  // —— 线路慢：不降档，换不换画质由用户定（iOS QualitySuggestion） ——
  // 线路远低于码率：一次等满 8 秒就弹换画质卡；不自动转码
  "slow-big": {
    route: env("HLS"),
    link: { mbps: 8, rttMs: 60 },
    durationS: 60,
    expect: all(noStepDown, (r) => {
      const at = firstUiAt(r, /网速跟不上当前画质/);
      return at === null ? "没弹换画质卡" : at > 40 ? `换画质卡弹得太晚（第 ${at} 秒）` : null;
    }),
  },
  // 弹卡后点「改用」：改走转码（带 max_height）后能流畅放
  "slow-big-accept": {
    route: env("HLS"),
    link: { mbps: 8, rttMs: 60 },
    durationS: 90,
    steps: [
      {
        name: "accept offer",
        whenUi: /网速跟不上当前画质/,
        run: async ({ page }) => page.click('[data-testid="quality-offer-accept"]'),
      },
    ],
    expect: all(
      (r) => (r.sessionRequests.some((q) => q.max_height) ? null : "接受后没有按画质上限重开会话"),
      playingAtEnd,
    ),
  },
  // 线路略低于码率：反复卡，5 分钟内卡 2 次后弹卡
  "slow-hd": {
    route: env("HLS"),
    link: { mbps: 30, rttMs: 30 },
    durationS: 120,
    expect: all(noStepDown, (r) => uiShows(r, /网速跟不上当前画质/)),
  },
  // 直出档线路不够：不再自动改转码，弹卡
  "slow-direct": {
    route: env("DIRECT"),
    link: { mbps: 7, rttMs: 40 },
    durationS: 90,
    expect: all(noStepDown, (r) => uiShows(r, /网速跟不上当前画质/)),
  },

  // 已经在转码、线路装不下：不弹卡，按实测带宽同档重开一次压码率（每集一次）；压过之后线路够用，
  // 不该再弹卡（量到分片码率之前按服务端的转码目标码率比，不拿片源码率）
  "slow-transcode": {
    route: env("TRANSCODE"),
    link: { mbps: 3, rttMs: 60 },
    durationS: 90,
    expect: all(
      noStepDown,
      (r) => (r.sessionRequests.some((q) => q.downlink_bps) ? null : "没有按实测带宽重开转码会话"),
      (r) => {
        const at = firstUiAt(r, /网速跟不上当前画质/);
        return at === null ? null : `压过码率后仍弹换画质卡（第 ${at} 秒）`;
      },
    ),
  },

  // —— 断线：同档原地恢复，不降档 ——
  "cut-hls": {
    route: env("HLS"),
    durationS: 80,
    steps: [{ name: "cut 20s", afterPlayingS: 12, run: cut(20) }],
    expect: all(noStepDown, playingAtEnd),
  },
  "cut-direct": {
    route: env("DIRECT"),
    durationS: 80,
    steps: [{ name: "cut 20s", afterPlayingS: 12, run: cut(20) }],
    expect: all(noStepDown, playingAtEnd),
  },
  // 线路挂起（连接不断、一个字节都不回）
  "hang-direct": {
    route: env("DIRECT"),
    durationS: 110,
    steps: [{ name: "hang 40s", afterPlayingS: 12, run: hang(40) }],
    expect: all(noStepDown, playingAtEnd),
  },
  "hang-hls": {
    route: env("HLS"),
    durationS: 150,
    steps: [{ name: "hang 70s", afterPlayingS: 12, run: hang(70) }],
    expect: all(noStepDown, playingAtEnd),
  },
  // 一直断：约 1 分钟后落「连接中断」错误页，不降档
  "refuse-forever-direct": {
    route: env("DIRECT"),
    durationS: 150,
    steps: [{ name: "refuse forever", afterPlayingS: 12, run: cut(null) }],
    expect: all(noStepDown, (r) => uiShows(r, /连接中断/)),
  },
  "refuse-forever-hls": {
    route: env("HLS"),
    durationS: 200,
    steps: [{ name: "refuse forever", afterPlayingS: 12, run: cut(null) }],
    expect: all(noStepDown, (r) => uiShows(r, /连接中断/)),
  },
  // 直出片源 404：说清「找不到这个文件」，不降档
  "direct-404": {
    route: env("DIRECT"),
    durationS: 60,
    steps: [
      {
        name: "stream 404",
        afterPlayingS: 8,
        run: async ({ proxy }) => proxy.setFault("status", { status: 404, scope: "stream", cut: true }),
      },
    ],
    expect: all(
      noStepDown,
      (r) => uiShows(r, /找不到这个文件/),
      (r) => (r.uiTexts.some((t) => /正在重连/.test(t) && /找不到这个文件/.test(t)) ? "「正在重连」提示和错误页同屏" : null),
    ),
  },

  // —— 解码错误：原位重开一次，同一处再坏降到转码接着放（不再静默卡死） ——
  decode: {
    route: env("DECODE"),
    durationS: 100,
    expect: playingAtEnd,
  },

  // —— 画质按片记、开播提示「已沿用上次的选择」 ——
  // 给这部片记了 720p：开会话带 max_height 720，出画时提示
  "quality-memory": {
    route: env("DIRECT"),
    durationS: 25,
    localStorage: (route) => ({
      "movieclaw.player.quality-by-title": JSON.stringify({ [itemOf(route)]: [720, Date.now()] }),
    }),
    expect: all(
      (r) => (r.sessionRequests[0]?.max_height === 720 ? null : "开会话没带记住的画质上限"),
      (r) => uiShows(r, /已沿用上次的选择：画质 720p/),
    ),
  },
  // 别的片记了画质，这部不受影响；旧版的全局画质键不再沿用
  "quality-memory-other": {
    route: env("HLS"),
    durationS: 20,
    localStorage: () => ({
      "movieclaw.player.quality-by-title": JSON.stringify({ 1: [720, Date.now()] }),
      "movieclaw.player.quality": "720",
    }),
    expect: (r) => (r.sessionRequests[0]?.max_height ? "画质上限串到了别的片 / 沿用了旧版全局值" : null),
  },
  // 服务端记着用户选过的非默认音轨：开播提示
  "audio-memory": {
    route: env("AUDIO")?.split(":").slice(3).join(":") ?? null,
    durationS: 25,
    setup: async ({ context, base }) => {
      const [item, kind, index] = (env("AUDIO") ?? "").split(":");
      await context.request.post(`${base}/api/v1/playback/progress`, {
        data: { media_item_id: Number(item), event: "progress", position_ms: 600000, audio_track: `${kind}:${index}` },
      });
    },
    expect: (r) => uiShows(r, /已沿用上次的选择：.*音轨/),
  },

  // —— 首播（服务端冷缓存时跑：重启后、或别的片没播过） ——
  "first-mp4-remux": {
    route: env("MP4_REMUX"),
    durationS: 30,
    expect: (r) => (r.firstPlayingAt !== null && r.firstPlayingAt < 5 ? null : `首播太慢（${r.firstPlayingAt} 秒）`),
  },
  "first-ts": {
    route: env("TS"),
    durationS: 60,
    expect: (r) => (r.firstPlayingAt !== null && r.firstPlayingAt < 10 ? null : `首播太慢（${r.firstPlayingAt} 秒）`),
  },
};

/** 播放页地址里的条目 id */
export function itemOf(route) {
  return Number(route?.match(/\/play\/(\d+)/)?.[1] ?? 0);
}
