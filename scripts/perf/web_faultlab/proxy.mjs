// 浏览器与服务端之间的「一条线路」：限速（所有连接共享）、往返延迟、故障注入。
// 与 apps/apple/scripts/faultlab.py 同一套模式，换成 HTTP 反向代理，浏览器的全部请求都经过它。
import http from "node:http";

const STREAM_RE = /\/api\/v1\/playback\/(sessions\/[^/]+\/(seg|init)|files\/\d+\/(stream|disc))/;

/**
 * ``tap``（可选）：{ re, onExchange(method, url, reqBody, resBody, status) }——命中 re 的请求把请求体与
 * 响应体（各最多 64 KB）交给回调。浏览器那边用 Playwright 自己看请求，电视实验台没有，只能在线路上看。
 */
export function createProxy({ port, upstreamHost, upstreamPort, log = () => {}, tap = null }) {
  const t0 = Date.now();
  const state = {
    // 线路：bps = null 不限速
    bps: null,
    rttMs: 0,
    // 故障：pass / refuse / hang / status
    fault: "pass",
    faultScope: "all", // all / stream
    faultStatus: 503,
    faultUntil: null,
    linkFreeAt: 0,
  };
  const inflight = new Set(); // {req, res, upstreamReq, stream}
  const hung = new Set();
  const stats = { requests: 0, bytes: 0, byPath: [] };

  const agent = new http.Agent({ keepAlive: true, maxSockets: 64 });

  function isStream(url) {
    return STREAM_RE.test(url);
  }

  function activeFault(url) {
    if (state.fault === "pass") return "pass";
    if (state.faultUntil !== null && Date.now() > state.faultUntil) {
      state.fault = "pass";
      state.faultUntil = null;
      for (const s of hung) s.destroy();
      hung.clear();
      return "pass";
    }
    if (state.faultScope === "stream" && !isStream(url)) return "pass";
    if (state.faultScope instanceof RegExp && !state.faultScope.test(url)) return "pass";
    return state.fault;
  }

  async function pace(size) {
    if (!state.bps) return;
    const now = Date.now();
    state.linkFreeAt = Math.max(now, state.linkFreeAt) + (size * 8 * 1000) / state.bps;
    const wait = state.linkFreeAt - now;
    if (wait > 1) await new Promise((r) => setTimeout(r, wait));
  }

  const server = http.createServer(async (req, res) => {
    const url = req.url ?? "/";
    const fault = activeFault(url);
    const started = Date.now();
    const short = url.replace(/token=[^&]+/, "token=…").slice(0, 140);
    if (fault === "refuse") {
      log({ t: (started - t0) / 1000, ev: "refuse", url: short });
      req.socket.destroy();
      return;
    }
    if (fault === "hang") {
      log({ t: (started - t0) / 1000, ev: "hang", url: short });
      hung.add(req.socket);
      return;
    }
    if (fault === "status") {
      log({ t: (started - t0) / 1000, ev: "status", code: state.faultStatus, url: short });
      res.writeHead(state.faultStatus, { "content-type": "text/plain", connection: "close" });
      res.end("fault");
      return;
    }
    if (state.rttMs) await new Promise((r) => setTimeout(r, state.rttMs));
    const tapped = tap && tap.re.test(url) ? { req: [], res: [] } : null;
    if (tapped) req.on("data", (c) => tapped.req.push(c));
    const headers = { ...req.headers, host: `${upstreamHost}:${upstreamPort}` };
    if (tapped) delete headers["accept-encoding"]; // 要看明文响应
    const upstreamReq = http.request(
      { host: upstreamHost, port: upstreamPort, method: req.method, path: url, headers, agent },
      async (upstreamRes) => {
        const entry = { req, res, upstreamReq, stream: isStream(url) };
        inflight.add(entry);
        res.writeHead(upstreamRes.statusCode ?? 502, upstreamRes.headers);
        let bytes = 0;
        let firstByteMs = null;
        let aborted = false;
        res.on("close", () => {
          if (!res.writableFinished) aborted = true;
          upstreamRes.destroy();
        });
        try {
          for await (const chunk of upstreamRes) {
            for (let off = 0; off < chunk.length; off += 16384) {
              const piece = chunk.subarray(off, Math.min(chunk.length, off + 16384));
              await pace(piece.length);
              if (res.destroyed) throw new Error("client gone");
              if (firstByteMs === null) firstByteMs = Date.now() - started;
              bytes += piece.length;
              stats.bytes += piece.length;
              if (tapped && bytes <= 65536) tapped.res.push(piece);
              if (!res.write(piece)) await new Promise((r) => res.once("drain", r));
            }
          }
          res.end();
        } catch {
          aborted = true;
          res.destroy();
        } finally {
          if (tapped) {
            const text = (parts) => Buffer.concat(parts).toString("utf8");
            try {
              tap.onExchange(req.method, url, text(tapped.req), text(tapped.res), upstreamRes.statusCode);
            } catch {}
          }
          inflight.delete(entry);
          stats.requests += 1;
          log({
            t: (started - t0) / 1000,
            ev: "req",
            m: req.method,
            url: short,
            st: upstreamRes.statusCode,
            bytes,
            fb: firstByteMs,
            ms: Date.now() - started,
            ab: aborted || undefined,
          });
        }
      },
    );
    upstreamReq.on("error", (err) => {
      log({ t: (started - t0) / 1000, ev: "upstream-error", url: short, err: String(err) });
      if (!res.headersSent) res.writeHead(502);
      res.end();
    });
    req.pipe(upstreamReq);
  });
  server.keepAliveTimeout = 30_000;

  return {
    state,
    stats,
    listen: () => new Promise((r) => server.listen(port, "127.0.0.1", r)),
    close: () =>
      new Promise((r) => {
        if (state.faultTimer) clearTimeout(state.faultTimer);
        for (const s of hung) s.destroy();
        server.closeAllConnections?.();
        server.close(() => r());
      }),
    /** 限速：mbps = null 取消 */
    setLink(mbps, rttMs = 0) {
      state.bps = mbps ? mbps * 1_000_000 : null;
      state.rttMs = rttMs;
      log({ t: (Date.now() - t0) / 1000, ev: "link", mbps, rttMs });
    },
    /** 故障：mode = pass/refuse/hang/status；secs 到点自动恢复；cut = 同时掐断在途 */
    setFault(mode, { scope = "all", secs = null, status = 503, cut = false } = {}) {
      state.fault = mode;
      state.faultScope = scope;
      state.faultStatus = status;
      state.faultUntil = secs ? Date.now() + secs * 1000 : null;
      if (state.faultTimer) clearTimeout(state.faultTimer);
      state.faultTimer = null;
      if (mode === "pass") {
        for (const s of hung) s.destroy();
        hung.clear();
      } else if (secs) {
        // 到点**主动**恢复并断掉挂住的连接：只在下一个请求进来时才检查到期不够——浏览器对同一主机
        // 只开 6 条连接，全被挂住时新请求根本发不出来，「到期」永远等不到（真实线路上挂住的
        // TCP 连接终会超时或被重置，不会这样死锁）
        state.faultTimer = setTimeout(() => {
          state.faultTimer = null;
          state.fault = "pass";
          state.faultUntil = null;
          for (const s of hung) s.destroy();
          hung.clear();
          log({ t: (Date.now() - t0) / 1000, ev: "fault-end", mode });
        }, secs * 1000);
      }
      let cutN = 0;
      if (cut) {
        for (const e of inflight) {
          if (scope === "stream" && !e.stream) continue;
          e.res.destroy();
          e.req.socket.destroy();
          cutN += 1;
        }
      }
      log({ t: (Date.now() - t0) / 1000, ev: "fault", mode, scope, secs, cut: cutN });
    },
  };
}
