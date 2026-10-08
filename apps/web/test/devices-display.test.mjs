import assert from "node:assert/strict";
import test from "node:test";

import {
  activityLabel,
  deviceLive,
  deviceGlyph,
  identityParts,
  STALE_AFTER_DAYS,
  clientTypeLabel,
  deviceGroupKey,
  envSnippet,
  grantBadge,
  headlessArgs,
  grantSummary,
  groupDevices,
  isLive,
  isStale,
  issuedVerb,
  manualGrantSummary,
  normalizePairingCode,
  relativeTime,
  resolveServerAddress,
  revokeConsequence,
} from "../lib/devices-display.ts";

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
const NOW = Date.parse("2026-08-29T12:00:00Z");
const ago = (ms) => new Date(NOW - ms).toISOString();

test("权限说明说人话，不出现内部权限名", () => {
  for (const type of ["worker", "cli", "manual", "androidtv", "什么鬼"]) {
    for (const role of ["admin", "member"]) {
      const { title, body } = grantSummary(type, role);
      const text = `${title}${body}`;
      for (const jargon of ["scope", "admin", "operate", "transcode", "token"]) {
        assert.ok(!text.includes(jargon), `「将获得」出现了内部名词 ${jargon}：${text}`);
      }
    }
  }
});

test("转码器的说明必须点明它碰不到订阅与媒体库", () => {
  const { title, body } = grantSummary("worker");
  assert.equal(title, "将获得：仅限转码");
  assert.ok(body.includes("订阅") && body.includes("媒体库"));
});

test("超管批准命令行：说明必须点破全权的具体后果", () => {
  // 用户的知情就是唯一的闸（device-auth.md §4.5）：
  // 措辞退化成「完全权限」四个字就等于把闸拆了。
  const { title, body } = grantSummary("cli", "admin");
  assert.ok(title.includes("完全权限"));
  assert.ok(body.includes("删除媒体文件"), "必须写出最坏后果，而不是只说「完全权限」");
});

test("成员批准命令行：令牌只有成员自己的权限，不能照抄超管的说法", () => {
  // 谁批准，令牌就是谁的（login-devices.md §4）
  const { title, body } = grantSummary("cli", "member");
  assert.ok(!title.includes("完全权限"), `成员的命令行不是完全权限：${title}`);
  assert.ok(!body.includes("删除媒体文件"), "成员删不了媒体文件，写上去就是说错");
  assert.ok(body.includes("以你的身份"));
  assert.ok(body.includes("才批准"), "审批卡的收尾仍要落到「想清楚再批准」");
});

test("未知形态、缺省身份都按最危险的一档解释", () => {
  // 新形态还没接上前端时，宁可把警示说重也不能说轻
  assert.deepEqual(grantSummary("未来的新客户端"), grantSummary("cli", "admin"));
  assert.deepEqual(grantSummary("cli"), grantSummary("cli", "admin"));
  assert.equal(grantBadge("未来的新 scope", 0), "完全权限");
});

test("列表标注同样是实话：成员的命令行不是完全权限", () => {
  assert.equal(grantBadge("transcode", 0), "仅转码");
  assert.equal(grantBadge("full", 0), "完全权限");
  assert.equal(grantBadge("full", 7), "成员权限");
});

test("形态名称给人看，未知值不泄漏内部标识", () => {
  assert.equal(clientTypeLabel("worker"), "转码器");
  assert.equal(clientTypeLabel("cli"), "命令行 / Agent");
  assert.equal(clientTypeLabel("manual"), "手工令牌");
  assert.equal(clientTypeLabel("weird"), "未知类型");
});

test("活跃时间按人的读法分档", () => {
  assert.equal(relativeTime(null, NOW), "从未使用");
  assert.equal(relativeTime("不是时间", NOW), "未知");
  assert.equal(relativeTime(ago(30_000), NOW), "刚刚活跃");
  assert.equal(relativeTime(ago(12 * MINUTE), NOW), "12 分钟前");
  assert.equal(relativeTime(ago(59 * MINUTE), NOW), "59 分钟前");
  assert.equal(relativeTime(ago(3 * 60 * MINUTE), NOW), "3 小时前");
  assert.equal(relativeTime(ago(3 * DAY), NOW), "3 天前");
});

test("在线判定用 5 分钟阈值，与令牌活跃时间的落盘粒度匹配", () => {
  assert.equal(isLive(null, NOW), false);
  assert.equal(isLive(ago(4 * MINUTE), NOW), true);
  assert.equal(isLive(ago(6 * MINUTE), NOW), false);
});

// ---------------------------------------------------------------------------
// 配对码
// ---------------------------------------------------------------------------

test("配对码大小写不敏感，漏掉或写错连字符都能认", () => {
  for (const raw of ["MCLW-7F3K", "mclw-7f3k", " mclw 7f3k ", "MCLW7F3K", "mclw－7f3k", "7f3k"]) {
    assert.equal(normalizePairingCode(raw), "MCLW-7F3K", `没认出：${raw}`);
  }
});

test("认不出的配对码返回 null，不替人猜", () => {
  for (const raw of ["", "MCLW-7F3", "MCLW-7F3KX", "7F3", "MCLW-7F3@", "abc-7f3k"]) {
    assert.equal(normalizePairingCode(raw), null, `不该认成配对码：${raw}`);
  }
});

// ---------------------------------------------------------------------------
// 我的设备列表
// ---------------------------------------------------------------------------

test("设备按类型分组：人用的在前，程序代操作的其次，播放器最后", () => {
  const devices = [
    { id: "jf-1", kind: "jellyfin" },
    { id: "ld-1", kind: "web" },
    { id: "ld-2", kind: "cli" },
    { id: "ld-3", kind: "ios" },
    { id: "ld-4", kind: "worker" },
    { id: "ld-5", kind: "manual" },
    { id: "ld-6", kind: "web" },
  ];
  const groups = groupDevices(devices);
  assert.deepEqual(
    groups.map((g) => [g.label, g.devices.map((d) => d.id)]),
    [
      ["浏览器", ["ld-1", "ld-6"]],
      ["App", ["ld-3"]],
      ["命令行与转码器", ["ld-2", "ld-4", "ld-5"]],
      ["播放器", ["jf-1"]],
    ],
  );
});

test("空组保留；不认识的新类型与服务端同口径归入配对类", () => {
  assert.deepEqual(
    groupDevices([{ kind: "web" }]).map((g) => g.label),
    ["浏览器", "App", "命令行与转码器", "播放器"],
  );
  assert.deepEqual(groupDevices([]).map((group) => group.devices.length), [0, 0, 0, 0]);
  assert.equal(deviceGroupKey("android"), "app");
  assert.equal(deviceGroupKey("tvos"), "app");
  assert.equal(deviceGroupKey("androidtv"), "app");
  assert.equal(deviceGroupKey("未来的新客户端"), "paired");
});

test("本机即使缺少活动时间也在线，与 iPhone 口径一致", () => {
  assert.equal(deviceLive({ kind: "web", scope: "full", connected: false, last_seen_at: null, current: true }, NOW), true);
  assert.equal(deviceLive({ kind: "ios", scope: "full", connected: false, last_seen_at: ago(6 * MINUTE), current: false }, NOW), false);
});

test("超过 90 天没活跃才提示，没有活跃记录按签发时间算", () => {
  assert.equal(STALE_AFTER_DAYS, 90);
  const created = ago(400 * DAY);
  assert.equal(isStale(ago(89 * DAY), created, NOW), false);
  assert.equal(isStale(ago(91 * DAY), created, NOW), true);
  assert.equal(isStale(null, ago(10 * DAY), NOW), false);
  assert.equal(isStale(null, created, NOW), true);
  assert.equal(isStale("不是时间", created, NOW), false);
});

test("签发时间的说法跟着凭证来源走", () => {
  assert.equal(issuedVerb("web", "login"), "登录于");
  assert.equal(issuedVerb("jellyfin", "login"), "登录于");
  assert.equal(issuedVerb("cli", "paired"), "配对于");
  assert.equal(issuedVerb("manual", "paired"), "创建于");
});

test("注销前说清之后要怎样才能再用", () => {
  assert.ok(revokeConsequence("cli", "paired").includes("mclaw login"));
  assert.ok(revokeConsequence("worker", "paired").includes("重新配对"));
  assert.ok(revokeConsequence("manual", "paired").includes("重新创建"));
  assert.ok(revokeConsequence("ios", "login").includes("重新输入密码"));
  assert.ok(revokeConsequence("jellyfin", "login").includes("播放器里重新登录"));
});

// ---------------------------------------------------------------------------
// 手工令牌：环境变量片段
// ---------------------------------------------------------------------------

test("手工令牌的权限说明与审批卡同权，且点破不过期与只能注销", () => {
  const { title, body } = manualGrantSummary();
  assert.equal(title, grantSummary("manual").title, "手工令牌不能显得比批准出来的权限小");
  assert.ok(body.includes("删除媒体文件"), "全权的含义必须点破到具体后果");
  assert.ok(body.includes("不会自动过期"));
  assert.ok(body.includes("注销"));
  // 这条路上没有「批准」这个动作，照抄审批卡的收尾会指向一个不存在的按钮
  assert.ok(!body.includes("才批准"), `手工创建的说明不该提批准：${body}`);
});

test("仅限转码的手工令牌与配对出来的转码器同一档说法", () => {
  const { title, body } = manualGrantSummary("transcode");
  assert.equal(title, grantSummary("worker").title);
  assert.ok(body.includes("订阅") && body.includes("媒体库"));
  assert.ok(!body.includes("删除媒体文件"), "仅限转码的令牌删不了媒体文件");
  assert.ok(body.includes("不会自动过期"));
});

test("配过对外访问地址时直接用它，并去掉尾斜杠", () => {
  const address = resolveServerAddress("https://movieclaw.example.com/", "http://192.168.1.24:3000");
  assert.deepEqual(address, { url: "https://movieclaw.example.com", configured: true });
});

test("没配对外地址时回落当前地址，但必须标成「不是用户配的」", () => {
  const address = resolveServerAddress("", "http://192.168.1.24:3000");
  assert.deepEqual(address, { url: "http://192.168.1.24:3000", configured: false });
  // configured=false 是界面弹出「这只是猜测」那段警示的唯一依据，不能悄悄当真
});

test("只有空白的对外地址等同没配", () => {
  assert.equal(resolveServerAddress("   ", "http://127.0.0.1:3000").configured, false);
});

test("环境变量片段是可直接粘贴的两行，地址在前令牌在后", () => {
  const snippet = envSnippet("http://192.168.1.10:3000", "mclaw_abc123");
  assert.equal(snippet, "MOVIECLAW_SERVER=http://192.168.1.10:3000\nMOVIECLAW_TOKEN=mclaw_abc123");
  // KEY=value 而非 export：同一份文本要能用在 .env / --env-file / compose / source
  assert.ok(!snippet.includes("export "), "带 export 就不能直接当 .env 用");
  for (const line of snippet.split("\n")) {
    assert.match(line, /^[A-Z_]+=\S+$/, `不是干净的 KEY=value：${line}`);
  }
});

test("仅限转码的令牌给的是转码器命令行模式的一行启动参数", () => {
  // Headless 只认显式参数、不读环境变量；参数名与 macos/MovieClawTranscoder 的
  // WorkerConfiguration.load 一致
  const args = headlessArgs("http://192.168.1.10:3000", "mclaw_abc-123_x");
  assert.equal(args, "--nas-url http://192.168.1.10:3000 --token mclaw_abc-123_x");
  assert.ok(!args.includes("\n"), "只给一行，整行复制就能用");
  assert.ok(!args.includes("MOVIECLAW_"), "转码器不读环境变量");
});

test("转码器的绿点看此刻连没连着，不看最近验签时间", () => {
  const now = Date.parse("2026-09-27T12:00:00Z");
  const handshakeAnHourAgo = "2026-09-27T11:00:00Z";
  // 连着：凭证只在一小时前握手时验过，也照样是绿点、写「已连接」
  const connected = { kind: "worker", scope: "transcode", connected: true, last_seen_at: handshakeAnHourAgo };
  assert.equal(deviceLive(connected, now), true);
  assert.equal(activityLabel(connected, now), "已连接");
  // 断开：哪怕刚刚还活跃过，也不是绿点（它有长连接，断了就是断了）
  const dropped = { kind: "worker", scope: "transcode", connected: false, last_seen_at: "2026-09-27T11:59:30Z" };
  assert.equal(deviceLive(dropped, now), false);
  assert.equal(activityLabel(dropped, now), "刚刚活跃");
  // 「仅限转码」的手工令牌（命令行模式的转码器）同样按连接判断
  const headless = { kind: "manual", scope: "transcode", connected: true, last_seen_at: null };
  assert.equal(deviceLive(headless, now), true);
});

test("没有长连接的设备仍按最近 5 分钟有没有用过", () => {
  const now = Date.parse("2026-09-27T12:00:00Z");
  const phone = { kind: "ios", scope: "full", connected: false, last_seen_at: "2026-09-27T11:57:00Z" };
  assert.equal(deviceLive(phone, now), true);
  assert.equal(activityLabel(phone, now), "3 分钟前");
  const cli = { kind: "cli", scope: "full", connected: false, last_seen_at: "2026-09-27T10:00:00Z" };
  assert.equal(deviceLive(cli, now), false);
});

test("设备图标按形态挑，转码凭证一律是转码器", () => {
  assert.equal(deviceGlyph("ios", "full"), "phone");
  assert.equal(deviceGlyph("tvos", "full"), "tv");
  assert.equal(deviceGlyph("androidtv", "full"), "tv");
  assert.equal(deviceGlyph("web", "full"), "browser");
  assert.equal(deviceGlyph("worker", "transcode"), "transcoder");
  assert.equal(deviceGlyph("manual", "transcode"), "transcoder");
  assert.equal(deviceGlyph("manual", "full"), "terminal");
  assert.equal(deviceGlyph("jellyfin", "full"), "player");
  assert.equal(deviceGlyph("something-new", "full"), "terminal");
});

test("设备说明：图标说得清的不再写类型名，系统信息拆成整块", () => {
  const app = {
    kind: "ios",
    kind_label: "iOS App",
    platform: "iOS 26.6.2 · iPhone18,4",
    client_version: "0.4.0",
  };
  assert.deepEqual(identityParts(app), [
    "iOS 26.6.2",
    "iPhone18,4",
    "版本 0.4.0",
  ]);
  // 没报系统信息的 App：类型名留着，否则这一行什么都不剩
  assert.deepEqual(
    identityParts({ ...app, platform: null, client_version: null }),
    ["iOS App"],
  );
  // 浏览器的名字就是「Safari · iPhone」，再写「浏览器」是重复
  assert.deepEqual(
    identityParts({
      kind: "web",
      kind_label: "浏览器",
      platform: null,
      client_version: null,
    }),
    [],
  );
  assert.deepEqual(
    identityParts({
      kind: "manual",
      kind_label: "手工令牌",
      platform: null,
      client_version: null,
    }),
    ["手工令牌"],
  );
  assert.deepEqual(
    identityParts({
      kind: "jellyfin",
      kind_label: "Infuse",
      platform: null,
      client_version: "8.1",
    }),
    ["Infuse", "版本 8.1"],
  );
});
