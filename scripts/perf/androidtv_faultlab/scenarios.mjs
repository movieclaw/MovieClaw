// Android TV 播放器故障注入实验台的场景（docs/design/androidtv-app.md §10.5）。
//
// 与网页实验台（../web_faultlab）同一套代理与判定口径（iOS faultlab 的预期：线路慢不降档、断线原地恢复、
// 一直断落错误页……），信号换成调试包播放器每秒打的 logcat 行（PlaybackProbe）。
//
// 片源是个人片库里的条目，不入库，用环境变量给路由（同 App 的 mc_route，要带 ?t= 固定起播点）：
//   ATV_FAULTLAB_DIRECT       模拟器上直放原文件（档 0）的片子，例如 /play/965/s01e01?t=600
//   ATV_FAULTLAB_HLS          走服务端流（档 1 / 2）的片子，码率越高越好，例如 /play/867/s01e05?t=600
//   ATV_FAULTLAB_DIRECT_BIG   （可选）码率高的直放片子（> 10 Mbps），量线路慢
//   ATV_FAULTLAB_SERIES       （可选）有下一集的剧集，从片中起，量「服务端重启」不误跳下一集
//   ATV_FAULTLAB_SEEKS        （可选）量跳转耗时的片子，「名字=路由」逗号分隔，要从 600 秒起，
//                             例如 mp4=/play/965/s01e01?t=600,bdiso=/play/6295?t=600 → 场景 seeks:mp4、seeks:bdiso
//   ATV_FAULTLAB_SWITCHES     （可选）量换轨耗时：「名字=路由|轨,轨…」分号分隔，轨写 audio:embedded:1 / subtitle:off，
//                             例如 got=/play/6998/s01e01?t=600|audio:embedded:1,audio:embedded:0,subtitle:embedded:2,subtitle:off

const env = (name) => process.env[`ATV_FAULTLAB_${name}`] || null;
const cut = (secs) => async ({ proxy }) => proxy.setFault("refuse", { secs, cut: true });
const hang = (secs) => async ({ proxy }) => proxy.setFault("hang", { secs, cut: true });

/** 所有开会话请求都没有带「已失败的档位」：一次都没降档 */
function noStepDown(r) {
  const degraded = r.sessionRequests.find((q) => (q.failed_tiers ?? []).length > 0);
  return degraded ? `降档了：第 ${degraded.t} 秒开会话带 failed_tiers=${JSON.stringify(degraded.failed_tiers)}` : null;
}

/** 最后 10 秒播放头在走（文件时间，毫秒） */
function playingAtEnd(r) {
  const tail = r.states.filter((s) => s.t > r.endedAt - 10);
  if (tail.length < 2) return "结尾没有播放头采样";
  const moved = tail[tail.length - 1].pos - tail[0].pos;
  return moved > 3000 ? null : `结尾 10 秒播放头没在走（${tail[0].pos} → ${tail[tail.length - 1].pos}，${tail[tail.length - 1].ph}）`;
}

/** 界面（提示条、错误页、换画质卡片）出现过 */
function uiShows(r, pattern) {
  return r.uiTexts.some((t) => pattern.test(t)) ? null : `界面没出现 ${pattern}（出现过：${[...new Set(r.uiTexts)].join(" / ") || "无"}）`;
}

function firstUiAt(r, pattern) {
  return r.uiEvents.find((u) => pattern.test(u.text))?.t ?? null;
}

/** 一直在放同一个单元（没被误判成播完换到下一集） */
function sameUnit(r) {
  const units = [...new Set(r.states.map((s) => s.unit))];
  return units.length <= 1 ? null : `中途换了单元：${units.join(" → ")}`;
}

/** 卡住时进度没有空跑：断流期间播放头最多放完断流那一刻已缓冲的部分（iOS 断粮时进度空跑到 211 秒） */
function noPhantomProgress(fromS, toS) {
  return (r) => {
    const window = r.states.filter((s) => s.t >= fromS && s.t <= toS);
    if (window.length < 5) return "断流期间没有采样";
    // 已经在路上的数据断流后还会落进缓冲（实测多 2 秒）：以断流期间缓冲到过的最远处为准
    const bufferedAtCut = Math.max(...window.map((s) => s.buf ?? 0), window[0].pos);
    const last = window[window.length - 1];
    if (last.pos > bufferedAtCut + 1500) {
      return `断流期间播放头走到 ${Math.round(last.pos / 1000)} 秒，超过断流时的缓冲末尾 ${Math.round(bufferedAtCut / 1000)} 秒`;
    }
    return last.ph === "Playing" && last.playing ? "断流、缓冲见底了还报「在播」" : null;
  };
}

const all = (...checks) => (r) => checks.map((c) => c(r)).find((x) => x) ?? null;

export const scenarios = {
  "smoke-direct": { route: env("DIRECT"), durationS: 30, expect: all(noStepDown, playingAtEnd) },
  "smoke-hls": { route: env("HLS"), durationS: 30, expect: all(noStepDown, playingAtEnd) },

  // —— 断线：同档原地恢复，不降档 ——
  "cut-direct": {
    route: env("DIRECT"),
    durationS: 80,
    steps: [{ name: "cut 20s", afterPlayingS: 12, run: cut(20) }],
    expect: all(noStepDown, playingAtEnd),
  },
  "cut-hls": {
    route: env("HLS"),
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
  // 服务端持续 503 一分半：照样原地恢复
  "503-long-hls": {
    route: env("HLS"),
    durationS: 150,
    steps: [
      {
        name: "503 90s",
        afterPlayingS: 12,
        run: async ({ proxy }) => proxy.setFault("status", { status: 503, secs: 90, cut: true }),
      },
    ],
    expect: all(noStepDown, playingAtEnd),
  },
  // 一直断：约 1 分钟后落「连接中断」错误页，不降档
  "refuse-forever-direct": {
    route: env("DIRECT"),
    durationS: 150,
    steps: [{ name: "refuse forever", afterPlayingS: 12, run: cut(null) }],
    expect: all(noStepDown, (r) => uiShows(r, /连接中断|连不上/)),
  },
  "refuse-forever-hls": {
    route: env("HLS"),
    durationS: 200,
    steps: [{ name: "refuse forever", afterPlayingS: 12, run: cut(null) }],
    expect: all(noStepDown, (r) => uiShows(r, /连接中断|连不上/)),
  },
  // 直出片源 404：说清「找不到这个文件」，不降档。播放器默认往前缓冲约 50 秒，要放完缓冲、真去取数据才撞上 404
  "direct-404": {
    route: env("DIRECT"),
    durationS: 110,
    steps: [
      {
        name: "stream 404",
        afterPlayingS: 8,
        run: async ({ proxy }) => proxy.setFault("status", { status: 404, scope: "stream", cut: true }),
      },
    ],
    expect: all(noStepDown, (r) => uiShows(r, /找不到这个文件/)),
  },
  // 服务端重启：停机 20 秒（全部拒连），回来后旧会话没了（它的分片、心跳一律 404）。
  // 要原地重开，不能把「流断了」当「播完了」换到下一集（iOS 踩过：PrematureEndGuard）
  restart: {
    route: env("SERIES") ?? env("HLS"),
    durationS: 100,
    steps: [
      { name: "down 20s", afterPlayingS: 12, run: cut(20) },
      {
        name: "old session gone",
        afterPlayingS: 12,
        run: async ({ proxy, result }) => {
          const id = result.sessions[result.sessions.length - 1]?.id;
          if (!id) return;
          // 停机那 20 秒后接着生效：旧会话的一切请求 404（新开的会话照常）
          setTimeout(() => proxy.setFault("status", { status: 404, scope: new RegExp(`/playback/sessions/${id}`) }), 20_500);
        },
      },
    ],
    expect: all(noStepDown, sameUnit, playingAtEnd),
  },
  // 暂停超过服务端 180 秒的空闲回收：回来按播放要原地重开、接着放
  "pause-long": {
    route: env("HLS"),
    durationS: 250,
    steps: [
      { name: "pause", afterPlayingS: 10, run: async ({ key }) => key("KEYCODE_MEDIA_PAUSE") },
      { name: "resume", afterPlayingS: 225, run: async ({ key }) => key("KEYCODE_MEDIA_PLAY") },
    ],
    expect: all(noStepDown, playingAtEnd, (r) => {
      const err = r.states.find((s) => s.err);
      return err ? `落了错误页：${err.err}` : null;
    }),
  },

  // —— 线路慢：不降档，换不换画质由用户定 ——
  "slow-direct": {
    route: env("DIRECT_BIG"),
    link: { mbps: 7, rttMs: 40 },
    durationS: 90,
    expect: all(noStepDown, (r) => (r.states.some((s) => s.offer) ? null : "没弹换画质卡")),
  },
  "slow-hls": {
    route: env("HLS"),
    link: { mbps: 5, rttMs: 60 },
    durationS: 90,
    expect: all(noStepDown, (r) => {
      const at = r.states.find((s) => s.offer)?.t ?? null;
      return at === null ? "没弹换画质卡" : at > 60 ? `换画质卡弹得太晚（第 ${at} 秒）` : null;
    }),
  },
  // 断流时进度不空跑：挂起 90 秒（播放器默认缓冲 50 秒，要挂得比它久才见底），播放头最多走完缓冲
  "stall-no-phantom": {
    route: env("DIRECT"),
    durationS: 130,
    steps: [{ name: "hang 90s", afterPlayingS: 10, run: hang(90) }],
    expect: (r) => {
      const step = r.stepsAt["hang 90s"];
      return step === undefined ? "没执行到挂起" : noPhantomProgress(step + 1, step + 88)(r);
    },
  },
};

export { firstUiAt };

// —— 跳转耗时（Apple 端 player-engine.md §8.4.2 同一串）：600 秒起播 → +10（按键）→ +600（缓冲外）→ −10（按键，
// 缓冲内）→ 跳回 300 → 连按两下 +10。耗时与结局读服务端存下的播放记录（与真实使用同一口径），门槛按北极星的
// 打扰线：落地 > 1.5 秒算打扰；没落地（被取代 / 放弃 / 失败）也算 ——
const SEEK_DISTURB_MS = 1500;

function seekVerdict(r) {
  const record = r.records?.[r.records.length - 1];
  if (!record) return "服务端没有这次播放的记录";
  const seeks = record.detail?.seeks ?? [];
  r.seekTable = seeks.map((s) => `${s.source}${s.restart ? "(换会话)" : ""} ${Math.round(s.from_ms / 1000)}→${Math.round(s.to_ms / 1000)}s ${s.buffered ? "缓冲内" : "缓冲外"} ${s.outcome} ${s.ms ?? "-"}ms`);
  console.log(r.seekTable.map((l) => `    ${l}`).join("\n"));
  if (seeks.length < 4) return `只记到 ${seeks.length} 次跳转`;
  const bad = seeks.filter((s) => (s.outcome !== "landed" && s.outcome !== "superseded") || (s.ms ?? 0) > SEEK_DISTURB_MS);
  return bad.length ? `${bad.length} 次跳转慢于 ${SEEK_DISTURB_MS} 毫秒或没落地` : null;
}

for (const pair of (env("SEEKS") ?? "").split(",").filter(Boolean)) {
  const cut = pair.indexOf("=");
  const label = pair.slice(0, cut);
  const route = pair.slice(cut + 1); // 路由里的 ?t= 也有等号：只按第一个切
  scenarios[`seeks:${label}`] = {
    route,
    durationS: 52,
    records: true,
    steps: [
      { name: "+10 按键", afterPlayingS: 5, run: async ({ key }) => key("KEYCODE_DPAD_RIGHT") },
      { name: "+600", afterPlayingS: 13, run: async ({ seekTo, position }) => seekTo(position() + 600_000) },
      { name: "-10 按键", afterPlayingS: 23, run: async ({ key }) => key("KEYCODE_DPAD_LEFT") },
      { name: "回到 300", afterPlayingS: 31, run: async ({ seekTo }) => seekTo(300_000) },
      { name: "+10 连按两下", afterPlayingS: 41, run: async ({ key }) => { await key("KEYCODE_DPAD_RIGHT"); await key("KEYCODE_DPAD_RIGHT"); } },
    ],
    expect: all(seekVerdict, noStepDown),
  };
}

// —— 换音轨 / 字幕耗时（QoE 目标 ≤ 0.5 秒；15 秒没结果的记录里留空 = 失败）——
function switchVerdict(r) {
  const record = r.records?.[r.records.length - 1];
  if (!record) return "服务端没有这次播放的记录";
  const switches = record.detail?.switches ?? [];
  console.log(switches.map((w) => `    ${w.kind} ${w.from ?? "-"} → ${w.to ?? "-"} ${w.ms ?? "超时"}ms`).join("\n"));
  if (switches.length === 0) return "一次换轨都没记到";
  const stuck = switches.filter((w) => w.ms == null);
  return stuck.length ? `${stuck.length} 次换轨 15 秒内没有结果` : null;
}

for (const spec of (env("SWITCHES") ?? "").split(";").filter(Boolean)) {
  const [head, list] = spec.split("|");
  const cut = head.indexOf("=");
  const label = head.slice(0, cut);
  const route = head.slice(cut + 1);
  const tracks = (list ?? "").split(",").filter(Boolean);
  scenarios[`switch:${label}`] = {
    route,
    durationS: 8 + tracks.length * 10,
    records: true,
    steps: tracks.map((t, i) => {
      const [kind, ...ref] = t.split(":");
      return {
        name: `切 ${t}`,
        afterPlayingS: 6 + i * 10,
        run: async ({ adbStart }) => adbStart(kind === "audio" ? "mc_audio" : "mc_subtitle", ref.join(":")),
      };
    }),
    expect: all(switchVerdict, noStepDown),
  };
}
