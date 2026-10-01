#!/usr/bin/env node
// 网页播放器的真实浏览器故障注入实验台（docs/design/web-player.md §14；iOS 的对应物是 apps/apple/scripts/faultlab.py）。
//
// 为什么要它：弱网、断线、挂起、片源 404、硬解报错这些现场靠手工很难复现，单测又只覆盖得到纯函数。
// 这里在真 Chrome 与服务端之间放一条「线路」（proxy.mjs：所有连接共享带宽、往返延迟、拒连 / 挂起 /
// 回错误码），按场景的时间表注入故障，采播放器的现场（开会话请求、界面文字、播放头），再按场景的
// expect 自动判定。
//
// 用法（先在本目录 npm install --no-package-lock；本机要装 Google Chrome）：
//   WEB_FAULTLAB_SERVER=http://192.168.1.10:3000 WEB_FAULTLAB_USER=... WEB_FAULTLAB_PASSWORD=... \
//   WEB_FAULTLAB_HLS='/play/123?t=600' WEB_FAULTLAB_DIRECT='/play/456?t=600' \
//     node run.mjs slow-big cut-hls        # 指定场景；all = 全部；--list 列出
// 选项：--port 3911（本机代理端口）--out <目录> --headed（有界面，看现场）
//       --browser webkit：换成 Safari 的内核并模拟 iPhone（UA / 屏幕 / 触摸），走的是 iPhone Safari 同一条
//       hls.js + ManagedMediaSource 路径；先 `npx playwright-core install webkit`。Mac 解 4K 比手机快，
//       绝对数值偏乐观，拿来比「改前 / 改后」
//
// 两个坑：
// - 无头 Chrome 没有真实显示，getVideoPlaybackQuality 的掉帧数虚报约 20%，会让播放器的掉帧看门狗在
//   第 10 秒误判「直通放不动」。这里把掉帧计数清零（可见窗口里真实掉帧近乎为 0）。
// - 测试播放会在服务端留下播放记录与观看进度。记录带 lab_scenario「rig:<场景>」（统计默认排除）；
//   观看进度要自己清（或用专门的测试账号）。
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, devices, webkit } from "playwright-core";

import { createProxy } from "./proxy.mjs";
import { itemOf, scenarios } from "./scenarios.mjs";

const args = process.argv.slice(2);
const opt = (key, fallback) => {
  const i = args.indexOf(`--${key}`);
  return i >= 0 ? args[i + 1] : fallback;
};
const flag = (key) => args.includes(`--${key}`);
const optionValues = new Set(["port", "out", "browser"].map((k) => opt(k, null)).filter(Boolean));
const names = args.filter((a) => !a.startsWith("--") && !optionValues.has(a));

if (flag("list") || names.length === 0) {
  for (const [name, s] of Object.entries(scenarios)) {
    console.log(`${s.route ? "  " : "- "}${name}${s.route ? "" : "（没给片源，跳过）"}`);
  }
  process.exit(0);
}
const server = process.env.WEB_FAULTLAB_SERVER;
const user = process.env.WEB_FAULTLAB_USER;
const password = process.env.WEB_FAULTLAB_PASSWORD;
if (!server || !user || !password) {
  console.error("要设置 WEB_FAULTLAB_SERVER / WEB_FAULTLAB_USER / WEB_FAULTLAB_PASSWORD");
  process.exit(2);
}
const upstream = new URL(server);
const port = Number(opt("port", "3911"));
const outRoot = opt("out", path.join(os.tmpdir(), "mc-web-faultlab"));
const selected = names.includes("all") ? Object.keys(scenarios) : names;
const useWebkit = opt("browser", "chrome") === "webkit";

const results = [];
for (const name of selected) {
  const scenario = scenarios[name];
  if (!scenario) {
    console.error(`未知场景 ${name}`);
    continue;
  }
  if (!scenario.route) {
    console.log(`SKIP ${name}（没给片源）`);
    continue;
  }
  const result = await runScenario(name, scenario);
  const failure = scenario.expect ? scenario.expect(result) : null;
  results.push({ name, ok: !failure, failure, out: result.out });
  console.log(`${failure ? "FAIL" : "PASS"} ${name}${failure ? `：${failure}` : ""}  （${result.out}）`);
}
const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} 通过`);
process.exit(failed ? 1 : 0);

async function runScenario(name, scenario) {
  const out = path.join(outRoot, `${name}-${Date.now()}`);
  fs.mkdirSync(out, { recursive: true });
  const log = fs.createWriteStream(path.join(out, "events.jsonl"));
  const t0 = Date.now();
  const now = () => Number(((Date.now() - t0) / 1000).toFixed(2));
  const result = {
    out,
    sessionRequests: [],
    sessions: [],
    uiEvents: [],
    uiTexts: [],
    states: [],
    firstPlayingAt: null,
    endedAt: 0,
  };
  const emit = (event) => log.write(JSON.stringify({ t: now(), ...event }) + "\n");

  const proxy = createProxy({
    port,
    upstreamHost: upstream.hostname,
    upstreamPort: Number(upstream.port || 80),
    log: (e) => log.write(JSON.stringify({ kind: "proxy", ...e }) + "\n"),
  });
  await proxy.listen();
  const base = `http://127.0.0.1:${port}`;
  const browser = useWebkit
    ? await webkit.launch({ headless: !flag("headed") })
    : await chromium.launch({
        channel: "chrome",
        headless: !flag("headed"),
        args: ["--autoplay-policy=no-user-gesture-required", "--disable-background-timer-throttling"],
      });
  try {
    const context = await browser.newContext(
      useWebkit ? { ...devices["iPhone 15 Pro"] } : { viewport: { width: 1280, height: 720 } },
    );
    await context.addInitScript(() => {
      const orig = HTMLVideoElement.prototype.getVideoPlaybackQuality;
      if (!orig) return;
      HTMLVideoElement.prototype.getVideoPlaybackQuality = function () {
        const q = orig.call(this);
        return { creationTime: q.creationTime, totalVideoFrames: q.totalVideoFrames, droppedVideoFrames: 0, corruptedVideoFrames: 0 };
      };
    });
    const seed = { "movieclaw.player.lab": `rig:${name}`, ...(scenario.localStorage?.(scenario.route) ?? {}) };
    await context.addInitScript((entries) => {
      try {
        if (sessionStorage.getItem("__faultlab_seeded")) return;
        for (const [k, v] of Object.entries(entries)) localStorage.setItem(k, v);
        sessionStorage.setItem("__faultlab_seeded", "1");
      } catch {}
    }, seed);
    const login = await context.request.post(`${base}/api/v1/auth/login`, {
      data: { username: user, password, remember: true },
    });
    if (!login.ok()) throw new Error(`登录失败：HTTP ${login.status()}`);
    const page = await context.newPage();
    page.on("request", (req) => {
      if (req.method() !== "POST" || !/\/playback\/sessions$/.test(req.url())) return;
      let body = null;
      try {
        body = JSON.parse(req.postData() ?? "null");
      } catch {}
      const item = {
        t: now(),
        failed_tiers: body?.failed_tiers ?? [],
        max_height: body?.max_height ?? null,
        downlink_bps: body?.downlink_bps ?? null,
        start_ms: body?.start_ms ?? null,
      };
      result.sessionRequests.push(item);
      emit({ kind: "session-req", ...item });
    });
    page.on("response", async (res) => {
      if (res.request().method() !== "POST" || !/\/playback\/sessions$/.test(res.url())) return;
      try {
        const data = (await res.json())?.data;
        const item = { t: now(), tier: data?.decision?.tier, video: data?.decision?.video?.action, timing: res.headers()["server-timing"] ?? null };
        result.sessions.push(item);
        emit({ kind: "session", ...item });
      } catch {}
    });
    page.on("console", (m) => {
      if (m.type() === "error") emit({ kind: "console", text: m.text().slice(0, 300) });
    });
    if (scenario.link) proxy.setLink(scenario.link.mbps, scenario.link.rttMs ?? 0);
    if (scenario.setup) await scenario.setup({ page, context, base, proxy, itemOf });
    await page.goto(`${base}${scenario.route}`, { waitUntil: "domcontentloaded" });

    const steps = (scenario.steps ?? []).map((s) => ({ ...s, done: false }));
    let lastTexts = "";
    while (now() < scenario.durationS) {
      const s = await page
        .evaluate(() => {
          const v = document.querySelector("video");
          const texts = Array.from(document.querySelectorAll("[noautohide]"))
            .map((el) => (el.innerText || "").trim())
            .filter(Boolean)
            .join(" | ");
          if (!v) return { texts };
          let ahead = 0;
          for (let i = 0; i < v.buffered.length; i += 1) {
            if (v.buffered.start(i) <= v.currentTime + 0.05 && v.buffered.end(i) >= v.currentTime) ahead = v.buffered.end(i) - v.currentTime;
          }
          return { ct: Number(v.currentTime.toFixed(2)), paused: v.paused, rs: v.readyState, ahead: Number(ahead.toFixed(1)), err: v.error?.code ?? null, texts };
        })
        .catch(() => null);
      if (s) {
        const state = { t: now(), ...s };
        result.states.push(state);
        emit({ kind: "state", ...state });
        if (s.texts !== lastTexts) {
          lastTexts = s.texts;
          result.uiEvents.push({ t: now(), texts: s.texts });
          if (s.texts) result.uiTexts.push(s.texts);
          emit({ kind: "ui", texts: s.texts });
        }
        const prev = result.states[result.states.length - 2];
        if (result.firstPlayingAt === null && prev && typeof s.ct === "number" && s.ct > prev.ct && !s.paused) {
          result.firstPlayingAt = now();
        }
      }
      for (const step of steps) {
        if (step.done) continue;
        const ready =
          (step.atS !== undefined && now() >= step.atS) ||
          (step.afterPlayingS !== undefined && result.firstPlayingAt !== null && now() - result.firstPlayingAt >= step.afterPlayingS) ||
          (step.whenUi !== undefined && s && step.whenUi.test(s.texts ?? ""));
        if (!ready) continue;
        step.done = true;
        emit({ kind: "step", name: step.name });
        try {
          await step.run({ page, proxy });
        } catch (e) {
          emit({ kind: "step-error", err: String(e) });
        }
      }
      await new Promise((r) => setTimeout(r, 500));
    }
    result.endedAt = now();
    // 收尾：撤掉故障、离开播放页，让播放器把这次播放的记录报上去
    proxy.setLink(null);
    proxy.setFault("pass");
    await page.goto(`${base}/`, { waitUntil: "domcontentloaded", timeout: 15_000 }).catch(() => undefined);
    await new Promise((r) => setTimeout(r, 2_000));
  } finally {
    await browser.close();
    await proxy.close();
    fs.writeFileSync(path.join(out, "result.json"), JSON.stringify(result, null, 2));
    log.end();
  }
  return result;
}
