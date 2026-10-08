/**
 * 「设备」分区的展示口径（docs/design/device-auth.md §7、docs/design/login-devices.md）。
 *
 * 单独成文件而不是留在组件里，是因为这里的措辞是**安全设计的一部分**：
 * 用户批准时看到的那行「将获得」就是唯一的一道人工闸。措辞退化成含糊的
 * 技术名词，闸就没了——所以它需要被测试锁住，而不是散落在 JSX 里随手改。
 */

const DAY_MS = 24 * 60 * 60 * 1000;

/** 客户端形态 → 给人看的说法。内部值不上屏。 */
const CLIENT_TYPE_LABEL: Record<string, string> = {
  worker: "转码器",
  cli: "命令行 / Agent",
  tvos: "Apple TV",
  macos: "Mac",
  manual: "手工令牌",
};

export function clientTypeLabel(type: string): string {
  return CLIENT_TYPE_LABEL[type] ?? "未知类型";
}

export interface GrantSummary {
  title: string;
  body: string;
}

/** 看这一页的人是超管还是成员：「将获得」要按批准者本人的身份说。 */
export type ViewerRole = "admin" | "member";

/**
 * 批准前的权限说明。三条硬要求：
 * - 说人话，不出现 scope 之类的内部名词；
 * - 谁批准，令牌就是谁的（login-devices.md §4）。超管批出来的命令行是完全
 *   权限，必须把含义点破到具体后果（删除媒体文件）；成员批出来的只有成员
 *   自己的权限，照抄超管那段就是把后果说错——用户迟早发现这行字不可信，
 *   闸也就没了；
 * - 不认识的形态按最危险的一档解释；role 缺省也按超管，同样是往重里说。
 */
export function grantSummary(type: string, role: ViewerRole = "admin"): GrantSummary {
  if (type === "worker") {
    return {
      title: "将获得：仅限转码",
      body: "这台机器不能查看或修改你的订阅、媒体库和设置。",
    };
  }
  if (type === "tvos") {
    // Apple TV 扫码登录（docs/design/tvos-app.md §5.1）：等同在这台电视上用你的账号密码登录。
    // 钓鱼的样子是「别人的电视显示一个码、骗你去批」，所以要人核对码就在自己面前的电视上
    return {
      title: role === "member" ? "将获得：这台 Apple TV 以你的身份登录" : "将获得：这台 Apple TV 以你的超级管理员身份登录",
      body:
        "等同你在这台电视上输入账号密码登录：它能看到你能看到的媒体库、记录你的观看进度。" +
        "只批准你面前这台电视上显示的配对码。",
    };
  }
  if (type === "macos") {
    // Mac App 扫码登录：与 Apple TV 同一口径，等同在这台 Mac 上用你的账号密码登录
    return {
      title: role === "member" ? "将获得：这台 Mac 以你的身份登录" : "将获得：这台 Mac 以你的超级管理员身份登录",
      body:
        "等同你在这台 Mac 上输入账号密码登录：它能看到你能看到的媒体库、记录你的观看进度。" +
        "只批准你面前这台 Mac 上显示的配对码。",
    };
  }
  if (role === "member") {
    return {
      title: "将获得：与你相同的权限",
      body:
        "这台机器上的程序将能以你的身份做你在网页上能做的一切，管理员给你开放的能力它都有。" +
        "只在你清楚这台机器上正在运行什么程序时才批准。",
    };
  }
  return {
    title: "将获得：与你相同的完全权限",
    body:
      "这台机器上的程序将能做你在网页上能做的一切，包括删除媒体文件。" +
      "只在你清楚这台机器上正在运行什么程序时才批准。",
  };
}

/**
 * 手工创建令牌前的权限说明（只有超管能创建）。
 *
 * 与审批卡同权，但不能直接复用 `grantSummary`：那段话的收尾是「才批准」，
 * 而手工创建这条路上根本没有批准这个动作——真正要点破的是另外两件事，
 * 令牌不会自动过期，以及它一旦发出去就只能靠注销收回。
 *
 * scope=transcode 给命令行模式（Headless）的转码器用：碰不到订阅、媒体库和
 * 设置，与配对出来的转码器同一档。
 */
export function manualGrantSummary(scope: "full" | "transcode" = "full"): GrantSummary {
  if (scope === "transcode") {
    return {
      title: "将获得：仅限转码",
      body:
        "持有这枚令牌的程序只能领取和执行转码任务，不能查看或修改你的订阅、媒体库和设置。" +
        "令牌不会自动过期，只能在这里注销。",
    };
  }
  return {
    title: "将获得：与你相同的完全权限",
    body:
      "持有这枚令牌的程序将能做你在网页上能做的一切，包括删除媒体文件。" +
      "令牌不会自动过期，只能在这里注销——只把它放进你自己掌握的机器。",
  };
}

/**
 * 设备列表里配对类设备（命令行、转码器、手工令牌）的权限标注，同样是实话：
 * 只能转码的写「仅转码」；其余按主人说——超管的就是完全权限，成员的只有
 * 成员自己的权限（谁批准令牌就是谁的），一律写「完全权限」就说错了。
 * 不认识的 scope 按最危险的一档解释。
 */
export function grantBadge(scope: string, ownerId: number): string {
  if (scope === "transcode") return "仅转码";
  return ownerId === 0 ? "完全权限" : "成员权限";
}

// ---------------------------------------------------------------------------
// 配对码
// ---------------------------------------------------------------------------

/** 配对码的固定前缀（服务端 `_new_user_code`：`MCLW-` + 4 位） */
const PAIRING_PREFIX = "MCLW";

/**
 * 把手输的配对码规范成服务端的写法 `MCLW-XXXX`；认不出返回 null。
 *
 * 大小写不敏感；允许漏掉连字符、用空格或全角横线代替，也允许只输后 4 位——
 * 人照着屏幕抄码时这几种都常见，没必要让他为格式重来一遍。只做格式归一，
 * **不纠正易混字符**（0/O、1/I）：服务端码表本就剔除了它们，替人猜一个字
 * 等于可能替他批准了别人的请求，宁可让他再核对一次。
 */
export function normalizePairingCode(raw: string): string | null {
  const compact = raw.toUpperCase().replace(/[\s\-_－—–]+/g, "");
  const body =
    compact.length === PAIRING_PREFIX.length + 4 && compact.startsWith(PAIRING_PREFIX)
      ? compact.slice(PAIRING_PREFIX.length)
      : compact;
  if (!/^[A-Z0-9]{4}$/.test(body)) return null;
  return `${PAIRING_PREFIX}-${body}`;
}

// ---------------------------------------------------------------------------
// 我的设备列表
// ---------------------------------------------------------------------------

export interface DeviceGroup<T> {
  key: string;
  label: string;
  devices: T[];
}

/**
 * 分组顺序：人直接用的（浏览器、App）在前，程序代为操作的（命令行、转码器、
 * 手工令牌）其次，Jellyfin 播放器最后。组内保持服务端顺序（当前设备置顶，
 * 其余按最近活跃）。
 */
const DEVICE_GROUPS: { key: string; label: string }[] = [
  { key: "browser", label: "浏览器" },
  { key: "app", label: "App" },
  { key: "paired", label: "命令行与转码器" },
  { key: "player", label: "播放器" },
];

/**
 * 设备类型 → 所在分组。不认识的新类型归「命令行与转码器」：服务端对未知
 * 类型同样按「程序代为操作、配对类」处理（login_devices.spec_of），前端跟它
 * 保持同一口径，而不是凭空多出一个「其他」组。
 */
export function deviceGroupKey(kind: string): string {
  if (kind === "web") return "browser";
  if (kind === "ios" || kind === "tvos" || kind === "macos" || kind === "android") return "app";
  if (kind === "jellyfin") return "player";
  return "paired";
}

/** 四类始终保留，让没有在线设备与没有设备记录的状态也有明确归属。 */
export function groupDevices<T extends { kind: string }>(devices: T[]): DeviceGroup<T>[] {
  return DEVICE_GROUPS.map((group) => ({
    ...group,
    devices: devices.filter((device) => deviceGroupKey(device.kind) === group.key),
  }));
}

/** 设备行首的图标。图标已经说明了形态，说明行里就不再重复「iOS App」「浏览器」。 */
export type DeviceGlyph =
  | "phone"
  | "tv"
  | "computer"
  | "browser"
  | "terminal"
  | "transcoder"
  | "player";

export function deviceGlyph(kind: string, scope: string): DeviceGlyph {
  if (kind === "worker" || scope === "transcode") return "transcoder";
  if (kind === "ios" || kind === "android") return "phone";
  if (kind === "tvos") return "tv";
  if (kind === "macos") return "computer";
  if (kind === "web") return "browser";
  if (kind === "jellyfin") return "player";
  return "terminal";
}

/**
 * 设备行的第一行说明：系统、型号、版本，每段单独成块（换行只发生在块与块之间）。
 * 浏览器、带系统信息的 App 由图标说明形态，不再写类型名；命令行、手工令牌、
 * 播放器这类图标说不清的，类型名照写。
 */
export function identityParts(device: {
  kind: string;
  kind_label: string;
  platform: string | null;
  client_version: string | null;
}): string[] {
  const platform = (device.platform ?? "")
    .split(" · ")
    .map((part) => part.trim())
    .filter(Boolean);
  const isApp = deviceGroupKey(device.kind) === "app";
  const parts =
    device.kind === "web" || (isApp && platform.length > 0)
      ? []
      : [device.kind_label];
  parts.push(...platform);
  if (device.client_version) parts.push(`版本 ${device.client_version}`);
  return parts;
}

/** 「清理长期没用的设备」可选的天数，默认 30 天。 */
export const CLEANUP_DAY_OPTIONS = [7, 30, 90] as const;
export const DEFAULT_CLEANUP_DAYS = 30;

/**
 * 多久没活跃算「可能已经不用了」。只是界面上的一行轻提示——服务端不会因此让
 * 凭证失效（login-devices.md §5「长期不用」），要不要注销由人决定。
 */
export const STALE_AFTER_DAYS = 90;

/** 最近活跃（没有就按签发时间）超过 STALE_AFTER_DAYS 天。 */
export function isStale(
  lastSeenAt: string | null,
  createdAt: string,
  now: number = Date.now(),
): boolean {
  const then = Date.parse(lastSeenAt ?? createdAt);
  return !Number.isNaN(then) && now - then > STALE_AFTER_DAYS * DAY_MS;
}

/** 凭证怎么来的就怎么说：手工令牌「创建于」、配对的「配对于」、密码换来的「登录于」。 */
export function issuedVerb(kind: string, family: string): string {
  if (kind === "manual") return "创建于";
  return family === "paired" ? "配对于" : "登录于";
}

/**
 * 注销前的后果说明：按类型说清「注销之后要怎样才能再用」——这才是人决定
 * 按不按下去时真正想知道的。
 */
export function revokeConsequence(kind: string, family: string): string {
  switch (kind) {
    case "cli":
      return "这台机器上的命令行会立即失去访问权限，要再用得重新运行 mclaw login 配对。";
    case "worker":
      return "这台转码器会立即断开，正在进行的转码一并停止；要再用得在转码器里重新配对。";
    case "manual":
      return "持有这枚令牌的程序会立即失去访问权限。令牌无法恢复，只能重新创建。";
    case "jellyfin":
      return "这个播放器会立即退出登录，正在进行的播放一并停止；要再用得在播放器里重新登录。";
    default:
      return family === "paired"
        ? "这台设备会立即失去访问权限，要再用得重新配对。"
        : "这台设备会立即退出登录，正在进行的播放一并停止；要再用得重新输入密码登录。";
  }
}

/**
 * 「刚刚活跃 / 12 分钟前 / 3 天前」。
 *
 * 吊销是这套设计唯一的事后止损手段，用户靠这一列判断「哪台还在用、哪台可以
 * 关掉」，所以宁可粗一点也要读得懂——令牌的活跃时间本身就按分钟粒度落盘，
 * 再精确没有意义。
 */
export function relativeTime(iso: string | null, now: number = Date.now()): string {
  if (!iso) return "从未使用";
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return "未知";
  const minutes = Math.floor((now - then) / 60000);
  if (minutes < 1) return "刚刚活跃";
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} 小时前`;
  return `${Math.floor(hours / 24)} 天前`;
}

/** 最近 5 分钟内用过就算在线——落盘粒度是分钟，阈值再小就是假精度。 */
export function isLive(iso: string | null, now: number = Date.now()): boolean {
  if (!iso) return false;
  const then = Date.parse(iso);
  return !Number.isNaN(then) && now - then < 5 * 60 * 1000;
}

/** 列表行判断在线要用到的几个字段 */
export interface LivenessFields {
  kind: string;
  scope: string;
  connected: boolean;
  last_seen_at: string | null;
  current?: boolean;
}

/** 是不是靠长连接在线的转码器（配对来的 worker，或「仅限转码」的手工令牌） */
function isTranscoder(device: LivenessFields): boolean {
  return device.kind === "worker" || device.scope === "transcode";
}

/**
 * 列表上的绿点：转码器看此刻连没连着（它只在握手时验一次凭证、之后靠心跳在线，
 * 按最近验签时间判断的话，连着的转码器 5 分钟后就会变灰）；其余设备没有长连接，
 * 仍按最近 5 分钟有没有用过。
 */
export function deviceLive(device: LivenessFields, now: number = Date.now()): boolean {
  if (device.current) return true;
  if (isTranscoder(device)) return device.connected;
  return isLive(device.last_seen_at, now);
}

/** 活跃那一栏的第一段：连着的转码器写「已连接」，其余写最近活跃的相对时间。 */
export function activityLabel(device: LivenessFields, now: number = Date.now()): string {
  if (isTranscoder(device) && device.connected) return "已连接";
  return relativeTime(device.last_seen_at, now);
}

// ---------------------------------------------------------------------------
// 手工令牌：给无人值守环境的环境变量片段
// ---------------------------------------------------------------------------

/** 解析出的注入地址，以及它是不是用户明确配过的。 */
export interface ServerAddress {
  url: string;
  /** true = 取自「设置 → 网络与维护」的对外访问地址；false = 拿当前浏览器地址猜的 */
  configured: boolean;
}

/**
 * 决定环境变量片段里那行地址填什么。
 *
 * 优先用「对外访问地址」——那是用户明确声明的、从网络上访问得到本应用的地址。
 * 没配时回落到当前浏览器地址，但必须把 `configured: false` 传出去让界面说破：
 * 浏览器能打开不等于目标机器连得到（NAS 的定时任务、另一个网段的 CI 都可能不通），
 * 悄悄给一个可能不通的地址，用户只会看到 mclaw 连接超时而查不到原因。
 */
export function resolveServerAddress(externalUrl: string, origin: string): ServerAddress {
  const configured = externalUrl.trim().replace(/\/+$/, "");
  if (configured) return { url: configured, configured: true };
  return { url: origin.replace(/\/+$/, ""), configured: false };
}

/**
 * 可直接粘贴的两行环境变量。
 *
 * 用 `KEY=value` 而不是 `export KEY=...`：同一份文本能同时用在 `.env`、
 * `docker --env-file`、compose 的 `env_file` 和 shell 的 `source`，覆盖面最广。
 * 顺序也不是随意的——地址在前、令牌在后，与 CLI 报错里的排查顺序一致。
 */
export function envSnippet(server: string, token: string): string {
  return `MOVIECLAW_SERVER=${server}\nMOVIECLAW_TOKEN=${token}`;
}

/**
 * 「仅限转码」手工令牌给命令行模式（Headless）转码器的一行启动参数。
 *
 * 不给环境变量：Headless 只认显式命令行参数、不读环境变量
 * （macos/MovieClawTranscoder 的 README「Headless 排障模式」与 Models.swift 的
 * `WorkerConfiguration.load`），照抄两行 MOVIECLAW_* 它根本连不上。参数名以那边
 * 为准；--worker-id、--ffmpeg 等可选参数不在这里替人决定。令牌是 URL 安全字符
 * （`mclaw_` + base64url），地址是裸 URL，都不含需要 shell 转义的字符，不加引号。
 */
export function headlessArgs(server: string, token: string): string {
  return `--nas-url ${server} --token ${token}`;
}
