#!/usr/bin/env node
// Android TV 播放器故障注入实验台：模拟器里的调试包 App 经本机代理连服务器，代理按场景限速 / 断线 / 挂起 /
// 回错误码，判定读 App 每秒打的 logcat 行（PlaybackProbe）与代理看到的开会话请求。
//
//   ATV_FAULTLAB_SERVER=http://192.168.1.10:3000 ATV_FAULTLAB_USER=… ATV_FAULTLAB_PASSWORD=… \
//   ATV_FAULTLAB_DIRECT=/play/965/s01e01?t=600 ATV_FAULTLAB_HLS=/play/867/s01e05?t=600 \
//   node scripts/perf/androidtv_faultlab/run.mjs cut-direct cut-hls   （all = 全部；--list 列场景）
//
// 模拟器里 10.0.2.2 是宿主机：App 的服务器地址填 http://10.0.2.2:<代理端口>（第一次用密码登录，之后复用凭证）。
// 每场的事件流写在 /tmp/mc-atv-faultlab/<场景>-<时间>/events.jsonl。跑完 App 停在代理地址上，
// 要连回原服务器时用 mc_server 指回去。
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

import { createProxy } from "../web_faultlab/proxy.mjs";
import { scenarios } from "./scenarios.mjs";

const args = process.argv.slice(2);
const opt = (key, fallback) => {
  const i = args.indexOf(`--${key}`);
  return i >= 0 ? args[i + 1] : fallback;
};
const flag = (key) => args.includes(`--${key}`);
const optionValues = new Set(["port", "out"].map((k) => opt(k, null)).filter(Boolean));
const names = args.filter((a) => !a.startsWith("--") && !optionValues.has(a));

if (flag("list") || names.length === 0) {
  for (const [name, s] of Object.entries(scenarios)) console.log(`${s.route ? "  " : "- "}${name}${s.route ? "" : "（没给片源，跳过）"}`);
  process.exit(0);
}
const server = process.env.ATV_FAULTLAB_SERVER;
const user = process.env.ATV_FAULTLAB_USER;
const password = process.env.ATV_FAULTLAB_PASSWORD;
if (!server || !user || !password) {
  console.error("要设置 ATV_FAULTLAB_SERVER / ATV_FAULTLAB_USER / ATV_FAULTLAB_PASSWORD");
  process.exit(2);
}
const ADB = process.env.ADB ?? path.join(os.homedir(), "Library/Android/sdk/platform-tools/adb");
const PKG = "io.movieclaw.androidtv";
const upstream = new URL(server);
const port = Number(opt("port", "3921"));
const outRoot = opt("out", path.join(os.tmpdir(), "mc-atv-faultlab"));
const selected = names.includes("all") ? Object.keys(scenarios) : names;

const adb = (...a) => execFileSync(ADB, a, { encoding: "utf8" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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
  // App 崩了一切判定都没意义，直接判失败
  const failure = result.crashedAt != null ? `App 崩溃（第 ${result.crashedAt} 秒）` : scenario.expect ? scenario.expect(result) : null;
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
  let t0 = Date.now();
  const now = () => Number(((Date.now() - t0) / 1000).toFixed(2));
  const result = { out, sessionRequests: [], sessions: [], uiEvents: [], uiTexts: [], states: [], stepsAt: {}, firstPlayingAt: null, endedAt: 0 };
  const emit = (event) => log.write(JSON.stringify({ t: now(), ...event }) + "\n");

  const proxy = createProxy({
    port,
    upstreamHost: upstream.hostname,
    upstreamPort: Number(upstream.port || 80),
    log: (e) => log.write(JSON.stringify({ kind: "proxy", ...e }) + "\n"),
    tap: {
      re: /\/api\/v1\/playback\/sessions(\?|$)/,
      onExchange(method, _url, reqBody, resBody, status) {
        if (method !== "POST") return;
        let body = null;
        let data = null;
        try {
          body = JSON.parse(reqBody || "null");
        } catch {}
        try {
          data = JSON.parse(resBody || "null")?.data;
        } catch {}
        const req = {
          t: now(),
          attempt_id: body?.attempt_id ?? null,
          failed_tiers: body?.failed_tiers ?? [],
          max_height: body?.max_height ?? null,
          downlink_bps: body?.downlink_bps ?? null,
          start_ms: body?.start_ms ?? null,
        };
        result.sessionRequests.push(req);
        emit({ kind: "session-req", ...req });
        const res = { t: now(), status, tier: data?.decision?.tier ?? null, id: data?.session_id ?? null };
        result.sessions.push(res);
        emit({ kind: "session", ...res });
      },
    },
  });
  await proxy.listen();

  // 冷启动 App：先按返回让上一场的播放器正常收尾（会 DELETE 会话），再杀进程
  adb("shell", "input", "keyevent", "KEYCODE_BACK");
  await sleep(2500);
  adb("shell", "am", "force-stop", PKG);
  await sleep(3000);
  adb("logcat", "-c");
  // 时间用设备端的打点时刻（-v epoch）：logcat 送到宿主机会攒批，宿主机收到的时刻不可信
  const logcat = spawn(ADB, ["logcat", "-v", "epoch", "-s", "PlaybackProbe:I", "Playback:V", "AndroidRuntime:E"]);
  const lines = readline.createInterface({ input: logcat.stdout });
  let lastUi = "";
  lines.on("line", (line) => {
    const m = line.match(/^\s*(\d+\.\d+)\s+\d+\s+\d+\s+[A-Z]\s+(\S+?)\s*:\s(.*)$/);
    if (!m) return;
    const at = Number((Number(m[1]) - t0 / 1000).toFixed(2));
    if (m[2] !== "PlaybackProbe") {
      if (m[2] === "AndroidRuntime" && /FATAL EXCEPTION/.test(m[3])) result.crashedAt ??= at;
      log.write(JSON.stringify({ t: at, kind: m[2] === "AndroidRuntime" ? "crash" : "app", text: m[3] }) + "\n");
      return;
    }
    let s;
    try {
      s = JSON.parse(m[3]);
    } catch {
      return;
    }
    const state = { t: at, ...s };
    result.states.push(state);
    log.write(JSON.stringify({ kind: "state", ...state }) + "\n");
    const ui = [s.err, s.notice, s.offer ? "换画质卡片" : null].filter(Boolean).join(" | ");
    if (ui !== lastUi) {
      lastUi = ui;
      result.uiEvents.push({ t: at, text: ui });
      if (ui) result.uiTexts.push(ui);
      log.write(JSON.stringify({ t: at, kind: "ui", text: ui }) + "\n");
    }
    const prev = result.states[result.states.length - 2];
    if (result.firstPlayingAt === null && prev && s.playing && s.pos > prev.pos) result.firstPlayingAt = at;
  });

  if (scenario.link) proxy.setLink(scenario.link.mbps, scenario.link.rttMs ?? 0);
  t0 = Date.now();
  adb(
    "shell", "am", "start", "-n", `${PKG}/.MainActivity`,
    "--es", "mc_server", `http://10.0.2.2:${port}`,
    "--es", "mc_user", user,
    "--es", "mc_pass", password,
    "--es", "mc_route", `'${scenario.route}'`,
    "--es", "mc_lab", `rig:${name}`,
  );
  const key = async (code) => adb("shell", "input", "keyevent", code);
  // 调试包的实验台入口：让正在放的播放器跳到文件时间（毫秒）
  const seekTo = async (ms) => adb("shell", "am", "start", "-n", `${PKG}/.MainActivity`, "--el", "mc_seek_ms", String(Math.round(ms)));
  const position = () => result.states[result.states.length - 1]?.pos ?? 0;
  const adbStart = async (extra, value) => adb("shell", "am", "start", "-n", `${PKG}/.MainActivity`, "--es", extra, value);
  const steps = (scenario.steps ?? []).map((s) => ({ ...s, done: false }));
  // 时长从出画算起（起播耗时不计入）；60 秒还没出画就按超时收场
  while (true) {
    const elapsed = result.firstPlayingAt === null ? null : now() - result.firstPlayingAt;
    if (elapsed === null && now() > 60) break;
    if (elapsed !== null && elapsed >= scenario.durationS) break;
    for (const step of steps) {
      if (step.done || elapsed === null || elapsed < step.afterPlayingS) continue;
      step.done = true;
      result.stepsAt[step.name] = now();
      emit({ kind: "step", name: step.name });
      try {
        await step.run({ proxy, key, seekTo, position, adbStart, result });
      } catch (e) {
        emit({ kind: "step-error", err: String(e) });
      }
    }
    await sleep(500);
  }
  result.endedAt = now();
  proxy.setLink(null);
  proxy.setFault("pass");
  try {
    fs.writeFileSync(path.join(out, "end.png"), execFileSync(ADB, ["exec-out", "screencap", "-p"], { maxBuffer: 64 << 20 }));
  } catch {}
  // 让播放器在代理还开着时正常结束会话（离开时上报播放记录）
  adb("shell", "input", "keyevent", "KEYCODE_BACK");
  await sleep(4000);
  if (scenario.records) result.records = await fetchRecords(result.sessionRequests.map((q) => q.attempt_id));
  logcat.kill();
  await proxy.close();
  log.end();
  fs.writeFileSync(
    path.join(out, "summary.json"),
    JSON.stringify({ firstPlayingAt: result.firstPlayingAt, stepsAt: result.stepsAt, sessions: result.sessions, sessionRequests: result.sessionRequests, ui: result.uiEvents }, null, 1),
  );
  return result;
}

/** 按播放编号取服务端存下的播放记录（管理员接口，与真实使用同一套口径） */
async function fetchRecords(ids) {
  const unique = [...new Set(ids.filter(Boolean))];
  if (!unique.length) return [];
  const login = await fetch(`${server}/api/v1/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ username: user, password, remember: false }),
  });
  const cookie = (login.headers.getSetCookie?.() ?? []).map((c) => c.split(";")[0]).join("; ");
  const out = [];
  for (const id of unique) {
    for (let i = 0; i < 5; i += 1) {
      const res = await fetch(`${server}/api/v1/playback/attempts/${id}`, { headers: { cookie } });
      if (res.ok) {
        const data = (await res.json()).data;
        if (data?.status !== "started") {
          out.push(data);
          break;
        }
      }
      await sleep(1500);
    }
  }
  return out;
}
