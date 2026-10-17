import { url } from '@kit.ArkTS';

/**
 * 用户输入的「服务器页面地址」→ 规范化后的服务器根地址。
 *
 * 与 iOS 端 `Core/Networking/ServerAddress.swift` 逐条对齐：
 * - 用户最自然的输入是浏览器地址栏里那串，可能带路径（/login、/library/3）、
 *   可能没写协议（192.168.1.10:3000）。这里只保留 协议 + 主机 + 端口，
 *   因为 Web 端不支持子路径部署，服务根就是站点根；
 * - 没写协议时默认 http：自托管最常见的是局域网 http 直连，
 *   公网 https 用户粘贴的地址本来就带 https://；
 * - 显式写了默认端口（http:80 / https:443）时去掉，避免同一台服务器被当成两个地址。
 *
 * 解析只做格式层面，不发网络请求。
 */
export class ServerAddress {
  /** 服务器根地址，形如 `http://192.168.1.10:3000`（无尾斜杠、无路径） */
  readonly origin: string;

  private constructor(origin: string) {
    this.origin = origin;
  }

  /** 受信构造：偏好里存的已是规范化地址（login 时经 parse 落库），直接包装。 */
  static trusted(origin: string): ServerAddress {
    return new ServerAddress(origin);
  }

  /** 简短标签：只有主机和端口（`192.168.1.10:3000`），界面上区分服务器用 */
  get hostLabel(): string {
    return this.origin.replace(/^https?:\/\//, '');
  }

  /** 展示给用户看的完整地址 */
  get displayString(): string {
    return this.origin;
  }

  /** 解析用户输入；格式不对抛 Error（中文文案，直接可展示）。 */
  static parse(raw: string): ServerAddress {
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      throw new Error('请输入服务器地址');
    }
    const withScheme = trimmed.includes('://') ? trimmed : `http://${trimmed}`;
    let parsed: url.URL;
    try {
      parsed = url.URL.parseURL(withScheme);
    } catch (error) {
      throw new Error('地址格式不正确，示例：http://192.168.0.100:3000');
    }
    const scheme = parsed.protocol.replace(':', '').toLowerCase();
    if (scheme !== 'http' && scheme !== 'https') {
      throw new Error('地址格式不正确，示例：http://192.168.0.100:3000');
    }
    const host = parsed.hostname.toLowerCase();
    if (host.length === 0) {
      throw new Error('地址格式不正确，示例：http://192.168.0.100:3000');
    }
    // 显式默认端口去掉：http:80 / https:443
    let port = parsed.port;
    if ((scheme === 'http' && port === '80') || (scheme === 'https' && port === '443')) {
      port = '';
    }
    const origin = `${scheme}://${host}${port.length > 0 ? `:${port}` : ''}`;
    return new ServerAddress(origin);
  }

  /** 把后端返回的站内相对地址（如 /api/v1/images/...）拼成绝对 URL；空返回 null */
  resolve(path: string | null | undefined): string | null {
    if (path === null || path === undefined || path.length === 0) {
      return null;
    }
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    const sep = path.startsWith('/') ? '' : '/';
    return `${this.origin}${sep}${path}`;
  }
}
