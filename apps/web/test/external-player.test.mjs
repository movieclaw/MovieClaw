import assert from "node:assert/strict";
import test from "node:test";

import {
  EXTERNAL_PLAYER_KEY,
  buildLaunchUrl,
  canLaunchDirectly,
  currentPlatform,
  detectPlatform,
  loadDefaultPlayer,
  playersFor,
  safeHttpUrl,
  saveDefaultPlayer,
  subtitleLabel,
} from "../lib/external-player.ts";

const STREAM_URL =
  "http://media.example.test:3000/api/v1/playback/files/7/stream/%E6%B5%8B%E8%AF%95.mkv?token=a.b-c_d";
const SUBTITLE_URL =
  "http://media.example.test:3000/api/v1/playback/files/7/subtitles?track=external%3Aa.srt&format=srt&token=a.b-c_d";
const TITLE = "测试剧集 S01E02; #1";

const SAMPLE_LINK = {
  file_id: 7,
  stream_url: STREAM_URL,
  subtitles: [
    {
      track: "external:a.srt",
      label: "简体中文",
      language: "zh",
      format: "srt",
      url: SUBTITLE_URL,
    },
  ],
  title: TITLE,
  file_name: "测试.mkv",
  container: "mkv",
  start_ms: 61500,
  duration_ms: 2700000,
  expires_at: "2026-11-20T23:00:00Z",
};

/** node 环境没有 window：模拟一个内存 localStorage。 */
function withStorage(store) {
  globalThis.window = {
    localStorage: {
      getItem: (k) => (k in store ? store[k] : null),
      setItem: (k, v) => {
        store[k] = String(v);
      },
      removeItem: (k) => {
        delete store[k];
      },
    },
  };
  return () => {
    delete globalThis.window;
  };
}

test("平台识别：覆盖主流桌面、移动、iPadOS、CrOS 与空串", () => {
  const macSafariUa =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
  const winChromeUa =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";
  const iphoneSafariUa =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1";
  const androidChromeUa =
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.6613.88 Mobile Safari/537.36";
  const linuxFirefoxUa =
    "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:129.0) Gecko/20100101 Firefox/129.0";
  const crosUa =
    "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";

  assert.equal(detectPlatform(winChromeUa), "windows");
  assert.equal(detectPlatform(macSafariUa, 0), "macos");
  assert.equal(detectPlatform(macSafariUa, 5), "ios");
  assert.equal(detectPlatform(iphoneSafariUa, 5), "ios");
  assert.equal(detectPlatform(androidChromeUa, 5), "android");
  assert.equal(detectPlatform(linuxFirefoxUa, 0), "linux");
  assert.equal(detectPlatform(crosUa, 0), "other");
  assert.equal(detectPlatform(""), "other");
  assert.equal(typeof currentPlatform(), "string");
});

test("平台播放器有序列表与能力标志严格匹配方案", () => {
  const ids = (platform) => playersFor(platform).map((p) => p.id);

  assert.deepEqual(ids("windows"), ["potplayer", "mpv", "vlc"]);
  assert.deepEqual(ids("macos"), ["iina", "infuse", "vlc", "mpv"]);
  assert.deepEqual(ids("ios"), ["infuse", "vlc"]);
  assert.deepEqual(ids("android"), ["mxplayer", "mxplayerPro", "vlc", "mpv"]);
  assert.deepEqual(ids("linux"), ["mpv", "vlc"]);
  assert.deepEqual(ids("other"), []);

  // 能力字段抽查：needsHandler / jellyfinHint / subtitleParam / startParam
  const byId = (platform, id) => playersFor(platform).find((p) => p.id === id);
  assert.deepEqual(byId("windows", "potplayer"), {
    id: "potplayer",
    name: "PotPlayer",
    subtitleParam: false,
    startParam: false,
    needsHandler: false,
    jellyfinHint: false,
  });
  assert.equal(byId("windows", "vlc").needsHandler, true);
  assert.equal(byId("windows", "mpv").needsHandler, true);
  assert.equal(byId("windows", "mpv").subtitleParam, true);
  assert.equal(byId("macos", "infuse").jellyfinHint, true);
  assert.equal(byId("macos", "infuse").subtitleParam, true);
  assert.equal(byId("macos", "iina").jellyfinHint, false);
  assert.equal(byId("ios", "vlc").subtitleParam, true);
  assert.equal(byId("ios", "vlc").needsHandler, false);
  assert.equal(byId("android", "mxplayer").startParam, true);
  assert.equal(byId("android", "mxplayerPro").startParam, true);
  assert.equal(byId("android", "vlc").startParam, false);
  assert.equal(byId("android", "mpv").subtitleParam, false);
  assert.equal(byId("linux", "mpv").needsHandler, true);
  assert.equal(byId("linux", "vlc").needsHandler, true);
});

test("URL 构建：每个 (平台, 播放器) 完整期望串与跨平台白名单拒收", () => {
  const encStream = encodeURIComponent(STREAM_URL);
  const encSub = encodeURIComponent(SUBTITLE_URL);
  const encTitle = encodeURIComponent(TITLE);
  const b64Stream = Buffer.from(STREAM_URL, "utf8").toString("base64url");
  const b64Sub = Buffer.from(SUBTITLE_URL, "utf8").toString("base64url");

  // Windows
  assert.equal(buildLaunchUrl("windows", "potplayer", SAMPLE_LINK), `potplayer://${STREAM_URL}`);
  assert.equal(
    buildLaunchUrl("windows", "mpv", SAMPLE_LINK),
    `mpv-handler://play/${b64Stream}/?subfile=${b64Sub}`,
  );
  assert.equal(buildLaunchUrl("windows", "vlc", SAMPLE_LINK), `vlc://${STREAM_URL}`);

  // macOS
  assert.equal(
    buildLaunchUrl("macos", "iina", SAMPLE_LINK),
    `iina://weblink?url=${encStream}`,
  );
  assert.equal(
    buildLaunchUrl("macos", "infuse", SAMPLE_LINK),
    `infuse://x-callback-url/play?url=${encStream}&sub=${encSub}`,
  );
  assert.equal(buildLaunchUrl("macos", "vlc", SAMPLE_LINK), `vlc://${STREAM_URL}`);
  assert.equal(
    buildLaunchUrl("macos", "mpv", SAMPLE_LINK),
    `mpv-handler://play/${b64Stream}/?subfile=${b64Sub}`,
  );

  // iOS
  assert.equal(
    buildLaunchUrl("ios", "infuse", SAMPLE_LINK),
    `infuse://x-callback-url/play?url=${encStream}&sub=${encSub}`,
  );
  assert.equal(
    buildLaunchUrl("ios", "vlc", SAMPLE_LINK),
    `vlc-x-callback://x-callback-url/stream?url=${encStream}&sub=${encSub}`,
  );

  // Android：intent 格式、title 编码（; 和 #）、i.position 仅在 MX 出现
  const androidPrefix =
    "intent://media.example.test:3000/api/v1/playback/files/7/stream/%E6%B5%8B%E8%AF%95.mkv?token=a.b-c_d" +
    "#Intent;scheme=http;type=video/*;";
  const mxUrl = buildLaunchUrl("android", "mxplayer", SAMPLE_LINK);
  assert.equal(
    mxUrl,
    `${androidPrefix}package=com.mxtech.videoplayer.ad;S.title=${encTitle};i.position=61500;end`,
  );
  assert.equal(
    buildLaunchUrl("android", "mxplayerPro", SAMPLE_LINK),
    `${androidPrefix}package=com.mxtech.videoplayer.pro;S.title=${encTitle};i.position=61500;end`,
  );
  assert.equal(
    buildLaunchUrl("android", "vlc", SAMPLE_LINK),
    `${androidPrefix}package=org.videolan.vlc;S.title=${encTitle};end`,
  );
  assert.equal(
    buildLaunchUrl("android", "mpv", SAMPLE_LINK),
    `${androidPrefix}package=is.xyz.mpv;S.title=${encTitle};end`,
  );

  // title 中的 ; 与 # 必须已转义，不能破坏 intent 字段分隔
  assert.ok(mxUrl.includes("%3B"));
  assert.ok(mxUrl.includes("%23"));
  assert.equal(mxUrl.split("#Intent;").length, 2);

  // MX 在 start_ms <= 0 时不附带 i.position；https 时 scheme=https
  assert.equal(
    buildLaunchUrl("android", "mxplayer", {
      ...SAMPLE_LINK,
      start_ms: 0,
      stream_url: "https://media.example.com/v.mkv?token=t1",
    }),
    `intent://media.example.com/v.mkv?token=t1#Intent;scheme=https;type=video/*;package=com.mxtech.videoplayer.ad;S.title=${encTitle};end`,
  );

  // Linux
  assert.equal(
    buildLaunchUrl("linux", "mpv", SAMPLE_LINK),
    `mpv-handler://play/${b64Stream}/?subfile=${b64Sub}`,
  );
  assert.equal(buildLaunchUrl("linux", "vlc", SAMPLE_LINK), `vlc://${STREAM_URL}`);

  // 平台不支持或非白名单播放器返回 null
  assert.equal(buildLaunchUrl("windows", "iina", SAMPLE_LINK), null);
  assert.equal(buildLaunchUrl("macos", "potplayer", SAMPLE_LINK), null);
  assert.equal(buildLaunchUrl("ios", "mpv", SAMPLE_LINK), null);
  assert.equal(buildLaunchUrl("android", "infuse", SAMPLE_LINK), null);
  assert.equal(buildLaunchUrl("linux", "potplayer", SAMPLE_LINK), null);
  assert.equal(buildLaunchUrl("other", "vlc", SAMPLE_LINK), null);
  assert.equal(buildLaunchUrl("windows", "javascript:evil", SAMPLE_LINK), null);
});

test("mpv base64url：无 + / =，解码回原 URL，无字幕时不带 subfile", () => {
  const withSub = buildLaunchUrl("linux", "mpv", SAMPLE_LINK);
  assert.ok(withSub);
  const match = withSub.match(/^mpv-handler:\/\/play\/([^/]+)\/\?subfile=([^&]+)$/);
  assert.ok(match);
  const [, encodedStream, encodedSub] = match;
  assert.equal(/[+/=]/.test(encodedStream), false);
  assert.equal(/[+/=]/.test(encodedSub), false);
  assert.equal(Buffer.from(encodedStream, "base64url").toString("utf8"), STREAM_URL);
  assert.equal(Buffer.from(encodedSub, "base64url").toString("utf8"), SUBTITLE_URL);

  const withoutSub = buildLaunchUrl("linux", "mpv", { ...SAMPLE_LINK, subtitles: [] });
  assert.ok(withoutSub);
  assert.equal(withoutSub.includes("subfile="), false);
  assert.equal(withoutSub, `mpv-handler://play/${encodedStream}/`);
});

test("Infuse / VLC iOS 字幕处理：无字幕不带 sub=，自动跳过非法首条字幕", () => {
  const noSubLink = { ...SAMPLE_LINK, subtitles: [] };
  const infuseNoSub = buildLaunchUrl("ios", "infuse", noSubLink);
  const vlcNoSub = buildLaunchUrl("ios", "vlc", noSubLink);
  assert.equal(infuseNoSub, `infuse://x-callback-url/play?url=${encodeURIComponent(STREAM_URL)}`);
  assert.equal(
    vlcNoSub,
    `vlc-x-callback://x-callback-url/stream?url=${encodeURIComponent(STREAM_URL)}`,
  );

  const fallbackSubLink = {
    ...SAMPLE_LINK,
    subtitles: [
      {
        track: "external:bad.srt",
        label: "Bad",
        language: null,
        format: "srt",
        url: "javascript:alert(1)",
      },
      {
        track: "external:good.srt",
        label: "Good",
        language: "en",
        format: "srt",
        url: SUBTITLE_URL,
      },
    ],
  };
  assert.equal(
    buildLaunchUrl("ios", "infuse", fallbackSubLink),
    `infuse://x-callback-url/play?url=${encodeURIComponent(STREAM_URL)}&sub=${encodeURIComponent(SUBTITLE_URL)}`,
  );
  assert.equal(
    buildLaunchUrl("ios", "vlc", fallbackSubLink),
    `vlc-x-callback://x-callback-url/stream?url=${encodeURIComponent(STREAM_URL)}&sub=${encodeURIComponent(SUBTITLE_URL)}`,
  );
});

test("安全校验：非法 URL 一律被 safeHttpUrl 与 buildLaunchUrl 拒绝", () => {
  assert.ok(safeHttpUrl(STREAM_URL) instanceof URL);
  assert.ok(safeHttpUrl("https://example.com/a.mp4?token=1") instanceof URL);

  const badInputs = [
    "javascript:alert(1)",
    "file:///etc/passwd",
    "data:text/html,x",
    "http://u:p@h/x",
    "http://h/x#frag",
    "http://h/x#",
    "http://h/x y",
    "http://h/\nx",
    "http://h/\tx",
    "",
    null,
    42,
    "potplayer://x",
  ];

  for (const input of badInputs) {
    assert.equal(safeHttpUrl(input), null, `expected safeHttpUrl to reject: ${String(input)}`);
    assert.equal(
      buildLaunchUrl("windows", "potplayer", {
        ...SAMPLE_LINK,
        stream_url: input,
      }),
      null,
      `expected buildLaunchUrl to reject: ${String(input)}`,
    );
  }
});

test("默认播放器存储：仅存 id、跨平台校验、非法值与存储异常安全降级", () => {
  // 无 window（SSR）
  assert.equal(loadDefaultPlayer("macos"), null);
  saveDefaultPlayer("iina");

  // 正常读写 + 跨平台过滤
  const store = {};
  let restore = withStorage(store);
  try {
    saveDefaultPlayer("iina");
    assert.equal(store[EXTERNAL_PLAYER_KEY], "iina");
    assert.equal(Object.keys(store).length, 1);
    assert.equal(loadDefaultPlayer("macos"), "iina");
    assert.equal(loadDefaultPlayer("windows"), null);
    assert.equal(loadDefaultPlayer("other"), null);

    // 拒绝写入非白名单值
    saveDefaultPlayer("not-a-player");
    assert.equal(store[EXTERNAL_PLAYER_KEY], "iina");
  } finally {
    restore();
  }

  // 存储里被写入脏值时读回 null
  restore = withStorage({ [EXTERNAL_PLAYER_KEY]: "potplayer://http://evil" });
  try {
    assert.equal(loadDefaultPlayer("windows"), null);
  } finally {
    restore();
  }

  // getItem / setItem 抛错时不向外抛
  globalThis.window = {
    localStorage: {
      getItem: () => {
        throw new Error("storage blocked");
      },
      setItem: () => {
        throw new Error("quota exceeded");
      },
    },
  };
  try {
    assert.equal(loadDefaultPlayer("macos"), null);
    assert.doesNotThrow(() => saveDefaultPlayer("iina"));
  } finally {
    delete globalThis.window;
  }
});

test("canLaunchDirectly：手势激活判定与旧浏览器耗时 fallback", () => {
  assert.equal(canLaunchDirectly({ isActive: true }, 0), true);
  assert.equal(canLaunchDirectly({ isActive: true }, 5000), true);
  assert.equal(canLaunchDirectly({ isActive: false }, 0), false);
  assert.equal(canLaunchDirectly({ isActive: false }, 200), false);
  assert.equal(canLaunchDirectly(undefined, 200), true);
  assert.equal(canLaunchDirectly(undefined, 1000), false);
  assert.equal(canLaunchDirectly(undefined, 1500), false);
});

test("subtitleLabel：按 label -> language -> track 顺序回落", () => {
  assert.equal(subtitleLabel({ label: "中英双语", language: "zh", track: "external:a.srt" }), "中英双语");
  assert.equal(subtitleLabel({ label: null, language: "zh", track: "external:a.srt" }), "zh");
  assert.equal(subtitleLabel({ label: "", language: "en", track: "external:a.srt" }), "en");
  assert.equal(subtitleLabel({ label: null, language: null, track: "external:a.srt" }), "external:a.srt");
});
