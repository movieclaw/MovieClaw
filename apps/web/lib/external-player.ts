import type {
  PlaybackExternalLink,
  PlaybackExternalSubtitle,
} from "@/lib/api/playback";

export type DevicePlatform = "windows" | "macos" | "ios" | "android" | "linux" | "other";

export type ExternalPlayerId =
  | "potplayer"
  | "iina"
  | "infuse"
  | "vlc"
  | "mpv"
  | "mxplayer"
  | "mxplayerPro";

export interface ExternalPlayerSpec {
  id: ExternalPlayerId;
  /** Brand name (untranslated). */
  name: string;
  /** Whether the launch URL carries the first valid subtitle link. */
  subtitleParam: boolean;
  /** Whether the launch URL carries the resume position. */
  startParam: boolean;
  /** Whether the user needs an extra OS protocol handler (desktop VLC / mpv-handler). */
  needsHandler: boolean;
  /** Infuse-only hint suggesting Jellyfin server mode for progress sync. */
  jellyfinHint: boolean;
}

export const EXTERNAL_PLAYER_KEY = "movieclaw.player.external-player";

// Scheme prefixes and player parameters: 依据 external-player.md §4.2，待实机核对。
const SCHEME_POTPLAYER = "potplayer://";
const SCHEME_IINA = "iina://weblink?url=";
const SCHEME_INFUSE = "infuse://x-callback-url/play?url=";
const SCHEME_VLC_DESKTOP = "vlc://";
const SCHEME_VLC_IOS = "vlc-x-callback://x-callback-url/stream?url=";
const SCHEME_MPV_HANDLER = "mpv-handler://play/";

const ANDROID_PACKAGE_VLC = "org.videolan.vlc";
const ANDROID_PACKAGE_MPV = "is.xyz.mpv";
const ANDROID_PACKAGE_MX = "com.mxtech.videoplayer.ad";
const ANDROID_PACKAGE_MX_PRO = "com.mxtech.videoplayer.pro";

const UNSAFE_URL_CHARS_RE = /[\s\u0000-\u001f\u007f]/;

const ALL_PLAYER_IDS: ReadonlySet<string> = new Set<ExternalPlayerId>([
  "potplayer",
  "iina",
  "infuse",
  "vlc",
  "mpv",
  "mxplayer",
  "mxplayerPro",
]);

// Platform -> ordered player capability specs: 依据 external-player.md §4.2，待实机核对。
const PLAYERS_BY_PLATFORM: Record<DevicePlatform, readonly ExternalPlayerSpec[]> = {
  windows: [
    {
      id: "potplayer",
      name: "PotPlayer",
      subtitleParam: false,
      startParam: false,
      needsHandler: false,
      jellyfinHint: false,
    },
    {
      id: "mpv",
      name: "MPV",
      subtitleParam: true,
      startParam: false,
      needsHandler: true,
      jellyfinHint: false,
    },
    {
      id: "vlc",
      name: "VLC",
      subtitleParam: false,
      startParam: false,
      needsHandler: true,
      jellyfinHint: false,
    },
  ],
  macos: [
    {
      id: "iina",
      name: "IINA",
      subtitleParam: false,
      startParam: false,
      needsHandler: false,
      jellyfinHint: false,
    },
    {
      id: "infuse",
      name: "Infuse",
      subtitleParam: true,
      startParam: false,
      needsHandler: false,
      jellyfinHint: true,
    },
    {
      id: "vlc",
      name: "VLC",
      subtitleParam: false,
      startParam: false,
      needsHandler: true,
      jellyfinHint: false,
    },
    {
      id: "mpv",
      name: "MPV",
      subtitleParam: true,
      startParam: false,
      needsHandler: true,
      jellyfinHint: false,
    },
  ],
  ios: [
    {
      id: "infuse",
      name: "Infuse",
      subtitleParam: true,
      startParam: false,
      needsHandler: false,
      jellyfinHint: true,
    },
    {
      id: "vlc",
      name: "VLC",
      subtitleParam: true,
      startParam: false,
      needsHandler: false,
      jellyfinHint: false,
    },
  ],
  android: [
    {
      id: "mxplayer",
      name: "MX Player",
      subtitleParam: false,
      startParam: true,
      needsHandler: false,
      jellyfinHint: false,
    },
    {
      id: "mxplayerPro",
      name: "MX Player Pro",
      subtitleParam: false,
      startParam: true,
      needsHandler: false,
      jellyfinHint: false,
    },
    {
      id: "vlc",
      name: "VLC",
      subtitleParam: false,
      startParam: false,
      needsHandler: false,
      jellyfinHint: false,
    },
    {
      id: "mpv",
      name: "MPV",
      subtitleParam: false,
      startParam: false,
      needsHandler: false,
      jellyfinHint: false,
    },
  ],
  linux: [
    {
      id: "mpv",
      name: "MPV",
      subtitleParam: true,
      startParam: false,
      needsHandler: true,
      jellyfinHint: false,
    },
    {
      id: "vlc",
      name: "VLC",
      subtitleParam: false,
      startParam: false,
      needsHandler: true,
      jellyfinHint: false,
    },
  ],
  other: [],
};

/**
 * 仅从 User-Agent 与触控点数识别平台，不依赖 navigator.userAgentData。
 * 顺序敏感：Android 先于 Linux；iPadOS 桌面 UA 通过 Macintosh + maxTouchPoints > 1 归为 ios；CrOS 归为 other。
 */
export function detectPlatform(ua: string, maxTouchPoints = 0): DevicePlatform {
  if (/Android/i.test(ua)) return "android";
  if (/iPhone|iPad|iPod/.test(ua)) return "ios";
  if (/Macintosh/.test(ua) && maxTouchPoints > 1) return "ios";
  if (/Macintosh|Mac OS X/.test(ua)) return "macos";
  if (/Windows/.test(ua)) return "windows";
  if (/CrOS/.test(ua)) return "other";
  if (/Linux|X11/.test(ua)) return "linux";
  return "other";
}

export function currentPlatform(): DevicePlatform {
  if (typeof navigator === "undefined") return "other";
  return detectPlatform(navigator.userAgent ?? "", navigator.maxTouchPoints ?? 0);
}

export function playersFor(platform: DevicePlatform): ExternalPlayerSpec[] {
  const list = PLAYERS_BY_PLATFORM[platform];
  return list ? list.slice() : [];
}

/**
 * 校验外部流/字幕地址：只接受无空白/控制字符、无 userinfo、无 hash 片段、含 hostname 的 http(s) URL。
 */
export function safeHttpUrl(value: unknown): URL | null {
  if (typeof value !== "string" || value.length === 0) return null;
  if (UNSAFE_URL_CHARS_RE.test(value)) return null;
  if (value.includes("#")) return null;

  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return null;
  }

  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
  if (parsed.username !== "" || parsed.password !== "") return null;
  if (parsed.hash !== "") return null;
  if (parsed.hostname === "") return null;

  return parsed;
}

function toBase64Url(input: string): string {
  const bytes = new TextEncoder().encode(input);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function firstValidSubtitleUrl(
  subtitles: readonly PlaybackExternalSubtitle[] | undefined,
): string | null {
  if (!Array.isArray(subtitles)) return null;
  for (const sub of subtitles) {
    if (sub && safeHttpUrl(sub.url)) {
      return sub.url;
    }
  }
  return null;
}

function buildAndroidIntent(
  parsedUrl: URL,
  pkg: string,
  title: string,
  positionMs: number | null,
): string {
  const scheme = parsedUrl.protocol.slice(0, -1);
  const safeTitle = encodeURIComponent(title);
  const pos =
    positionMs !== null && Number.isFinite(positionMs) ? Math.floor(positionMs) : 0;
  const positionExtra = pos > 0 ? `;i.position=${pos}` : "";
  return (
    `intent://${parsedUrl.host}${parsedUrl.pathname}${parsedUrl.search}` +
    `#Intent;scheme=${scheme};type=video/*;package=${pkg};S.title=${safeTitle}${positionExtra};end`
  );
}

/**
 * 构造自定义协议拉起地址。
 * 播放器必须在当前平台白名单内且主地址通过 safeHttpUrl；不合法时返回 null。
 */
export function buildLaunchUrl(
  platform: DevicePlatform,
  playerId: ExternalPlayerId,
  link: PlaybackExternalLink,
): string | null {
  const supported = playersFor(platform).some((spec) => spec.id === playerId);
  if (!supported) return null;

  const parsedStream = safeHttpUrl(link.stream_url);
  if (!parsedStream) return null;

  const streamUrl = link.stream_url;
  const subUrl = firstValidSubtitleUrl(link.subtitles);

  if (platform === "android") {
    switch (playerId) {
      case "mxplayer":
        return buildAndroidIntent(parsedStream, ANDROID_PACKAGE_MX, link.title, link.start_ms);
      case "mxplayerPro":
        return buildAndroidIntent(parsedStream, ANDROID_PACKAGE_MX_PRO, link.title, link.start_ms);
      case "vlc":
        return buildAndroidIntent(parsedStream, ANDROID_PACKAGE_VLC, link.title, null);
      case "mpv":
        return buildAndroidIntent(parsedStream, ANDROID_PACKAGE_MPV, link.title, null);
      default:
        return null;
    }
  }

  switch (playerId) {
    case "potplayer":
      return `${SCHEME_POTPLAYER}${streamUrl}`;
    case "iina":
      return `${SCHEME_IINA}${encodeURIComponent(streamUrl)}`;
    case "infuse": {
      const base = `${SCHEME_INFUSE}${encodeURIComponent(streamUrl)}`;
      return subUrl ? `${base}&sub=${encodeURIComponent(subUrl)}` : base;
    }
    case "vlc":
      if (platform === "ios") {
        const base = `${SCHEME_VLC_IOS}${encodeURIComponent(streamUrl)}`;
        return subUrl ? `${base}&sub=${encodeURIComponent(subUrl)}` : base;
      }
      return `${SCHEME_VLC_DESKTOP}${streamUrl}`;
    case "mpv": {
      const base = `${SCHEME_MPV_HANDLER}${toBase64Url(streamUrl)}/`;
      return subUrl ? `${base}?subfile=${toBase64Url(subUrl)}` : base;
    }
    default:
      return null;
  }
}

export function loadDefaultPlayer(platform: DevicePlatform): ExternalPlayerId | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(EXTERNAL_PLAYER_KEY);
    if (!raw) return null;
    return playersFor(platform).some((spec) => spec.id === raw)
      ? (raw as ExternalPlayerId)
      : null;
  } catch {
    return null;
  }
}

export function saveDefaultPlayer(id: ExternalPlayerId): void {
  if (typeof window === "undefined") return;
  if (!ALL_PLAYER_IDS.has(id)) return;
  try {
    window.localStorage.setItem(EXTERNAL_PLAYER_KEY, id);
  } catch {
    // 存储不可用时静默降级
  }
}

export function canLaunchDirectly(
  activation: { isActive: boolean } | null | undefined,
  elapsedMs: number,
): boolean {
  return activation ? activation.isActive : elapsedMs < 1000;
}

export function subtitleLabel(
  subtitle: Pick<PlaybackExternalSubtitle, "label" | "language" | "track">,
): string {
  return subtitle.label || subtitle.language || subtitle.track;
}
