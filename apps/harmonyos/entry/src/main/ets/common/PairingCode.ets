/**
 * 设备登录二维码 / 配对码的解析（对齐 iOS `Shared/Core/Session/PairingQRCode.swift`，
 * 口径同 Web `normalizePairingCode`）。
 *
 * 电视、命令行等发起配对后显示的二维码，内容是服务端给的 `verification_uri_complete`——
 * `http(s)://<服务器>/activate?code=MCLW-XXXX`（旧版服务端是 `/settings/devices?code=…`）；
 * 也接受只编了配对码本身的二维码。
 *
 * 只认这几种：相机对着别的二维码（Wi-Fi、网址、付款码）时不能把人带进批准页，
 * 扫码页据此提示「这不是 MovieClaw 的登录二维码」并继续扫。
 *
 * 地址用字符串手工拆（同 `ShareLinks.slugFromWantUri` 的写法）：不引 `@ohos.url`，
 * 少一层运行时依赖，口径也更好对照。
 */
export class PairingScan {
  /** 规整后的配对码（大写、带 MCLW- 前缀） */
  readonly code: string;
  /** 二维码里的服务器「主机:端口」，用来在查不到时提示「电视连的可能是另一台服务器」；纯配对码时为 null */
  readonly host: string | null;

  private constructor(code: string, host: string | null) {
    this.code = code;
    this.host = host;
  }

  /**
   * 解析一段扫描文本：认「MCLW 前缀的纯码」与「/activate 或 /settings/devices?code=」的网址，
   * 其余返回 null（不把人带去任何地方）。
   */
  static parse(text: string): PairingScan | null {
    const raw: string = text.trim();
    // 纯文本必须带 MCLW 前缀：手输时只打后四位也认，扫码时随便一个四个字母的二维码可不能算
    if (raw.toUpperCase().startsWith('MCLW')) {
      const code: string | null = PairingScan.normalize(raw);
      if (code !== null) {
        return new PairingScan(code, null);
      }
    }
    const lower: string = raw.toLowerCase();
    let rest: string = '';
    if (lower.startsWith('http://')) {
      rest = raw.substring('http://'.length);
    } else if (lower.startsWith('https://')) {
      rest = raw.substring('https://'.length);
    } else {
      return null;
    }
    const slash: number = rest.indexOf('/');
    if (slash <= 0) {
      return null;
    }
    const host: string = rest.substring(0, slash);
    let pathAndQuery: string = rest.substring(slash);
    const hash: number = pathAndQuery.indexOf('#');
    if (hash >= 0) {
      pathAndQuery = pathAndQuery.substring(0, hash);
    }
    const question: number = pathAndQuery.indexOf('?');
    let path: string = question >= 0 ? pathAndQuery.substring(0, question) : pathAndQuery;
    const query: string = question >= 0 ? pathAndQuery.substring(question + 1) : '';
    if (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.endsWith('/activate') && !path.endsWith('/settings/devices')) {
      return null;
    }
    const code: string | null = PairingScan.normalize(PairingScan.queryValue(query, 'code'));
    if (code === null) {
      return null;
    }
    return new PairingScan(code, host);
  }

  /** 从查询串里取一个参数（不依赖 URLSearchParams） */
  private static queryValue(query: string, key: string): string {
    if (query.length === 0) {
      return '';
    }
    for (const pair of query.split('&')) {
      const eq: number = pair.indexOf('=');
      if (eq < 0) {
        continue;
      }
      if (pair.substring(0, eq) === key) {
        return decodeURIComponent(pair.substring(eq + 1));
      }
    }
    return '';
  }

  /**
   * 配对码规整：去掉空格与各种横线、转大写，
   * 「MCLW7F3K」「mclw-7f3k」「7F3K」都认成 MCLW-7F3K；正文必须恰好 4 位字母数字。
   */
  static normalize(raw: string): string | null {
    const separators: string = ' -_－—–\t\n';
    let compact: string = '';
    const upper: string = raw.toUpperCase();
    for (let i: number = 0; i < upper.length; i++) {
      const ch: string = upper.charAt(i);
      if (separators.indexOf(ch) >= 0) {
        continue;
      }
      compact += ch;
    }
    const body: string = compact.length === 8 && compact.startsWith('MCLW')
      ? compact.substring(4) : compact;
    if (body.length !== 4) {
      return null;
    }
    for (let i: number = 0; i < body.length; i++) {
      const code: number = body.charCodeAt(i);
      const isDigit: boolean = code >= 0x30 && code <= 0x39;
      const isUpperLetter: boolean = code >= 0x41 && code <= 0x5A;
      if (!isDigit && !isUpperLetter) {
        return null;
      }
    }
    return `MCLW-${body}`;
  }
}
