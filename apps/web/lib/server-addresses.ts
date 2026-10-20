/**
 * 访问地址的展示口径（docs/design/server-addresses.md）。
 *
 * 单独成文件：「这个地址看起来是内网还是外网」的预判与服务端 host_kind 同口径，有单元测试。
 */

export type AddressKind = "lan" | "wan";

const LAN_SUFFIXES = [".local", ".lan", ".home.arpa", ".internal", ".localdomain"];

/** 只看地址猜内网 / 外网，与服务端 host_kind 同口径（预选用，用户可以改）。 */
export function guessKind(raw: string): AddressKind | null {
  let host: string;
  try {
    host = new URL(raw.trim()).hostname.toLowerCase().replace(/^\[|\]$/g, "");
  } catch {
    return null;
  }
  if (!host) return null;
  const v4 = host.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    if (a === 100 && b >= 64 && b <= 127) return "wan"; // Tailscale 一类共享地址：人在外面
    const lan =
      a === 10 ||
      a === 127 ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) ||
      (a === 169 && b === 254);
    return lan ? "lan" : "wan";
  }
  if (host.includes(":")) return /^(fc|fd|fe80|::1$)/.test(host) ? "lan" : "wan";
  if (!host.includes(".") || LAN_SUFFIXES.some((s) => host.endsWith(s))) return "lan";
  return "wan";
}
