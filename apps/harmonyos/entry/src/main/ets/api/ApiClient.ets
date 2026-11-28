import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { ImageLruPolicy } from '../common/ImageLruPolicy';

/**
 * MovieClaw 业务接口统一错误（对应 iOS 端 Core/Networking/APIClient.swift 的 APIError）。
 *
 * 后端的业务错误已经是可读中文（`message` 字段），原样透出给用户；
 * 网络层失败（断网、超时、证书）在这里换成能行动的中文。
 *
 * 注意：ArkTS 的 throw 只接受 Error 子类，因此继承 Error（message 由 Error 提供）。
 */
export class ApiError extends Error {
  /** HTTP 状态码；非 HTTP 失败用负数/0：0=网络错误，-1=超时，-2=解析错误 */
  readonly status: number;
  /** 后端业务错误码（`code` 字段），可能为空串 */
  readonly code: string;

  constructor(status: number, message: string, code: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
  }


  static http(status: number, message: string, code: string): ApiError {
    return new ApiError(status, message, code);
  }

  static network(detail: string): ApiError {
    return new ApiError(0, detail, '');
  }

  static timeout(): ApiError {
    return new ApiError(-1, '服务器响应太慢，请求已取消——请稍后重试', '');
  }

  static decoding(detail: string): ApiError {
    return new ApiError(-2, `服务器返回的数据无法解析（App 与服务器版本可能不一致）：${detail}`, '');
  }

  /** 令牌被注销、密码被改、账号停用都会是 401 */
  get isUnauthorized(): boolean {
    return this.status === 401;
  }
}

/** 查询参数键值对（生成的端点方法用它拼 query string）。 */
export interface QueryPair {
  key: string;
  value: string | number | boolean;
}

/** 查询串构建（对应 iOS 端 URLQueryItem 数组）。 */
export class ApiQuery {
  static build(pairs: QueryPair[]): string {
    if (pairs.length === 0) {
      return '';
    }
    const parts: string[] = [];
    for (const pair of pairs) {
      parts.push(`${encodeURIComponent(pair.key)}=${encodeURIComponent(String(pair.value))}`);
    }
    return '?' + parts.join('&');
  }
}

/**
 * 后端统一响应信封：`success / code / message / data`。
 * 业务失败由非 2xx 状态码承载（对应 iOS 端 perform() 的处理），2xx 时直接取 data。
 */
interface ApiEnvelope<T> {
  success: boolean;
  code?: string;
  message?: string;
  data: T;
}

/** 错误响应体：`success / code / message / details` */
/**
 * 把 FastAPI 的 `detail` 压成一行人话。
 * 它有两种形态：字符串（业务错误），或 `[{loc: [...], msg: "..."}]` 数组（校验错误）。
 */
function describeDetail(body: ApiErrorBody): string {
  const structured: Object[] | undefined = body.details;
  if (structured !== undefined && structured !== null && structured.length > 0) {
    const lines: string[] = [];
    for (const item of structured) {
      const entry = item as Record<string, Object>;
      const loc: Object = entry.location;
      const msg: Object = entry.message;
      const where: string = loc !== undefined && loc !== null ? `${loc}`.replace(/,/g, '.') : '';
      const text: string = msg !== undefined && msg !== null ? `${msg}` : '';
      if (text.length > 0) {
        lines.push(where.length > 0 ? `${where} ${text}` : text);
      }
    }
    if (lines.length > 0) {
      return lines.join('；');
    }
  }
  const detail: string | Object[] | undefined = body.detail;
  if (detail === undefined || detail === null) {
    return '';
  }
  if (typeof detail === 'string') {
    return detail;
  }
  const parts: string[] = [];
  for (const item of detail as Object[]) {
    const entry = item as Record<string, Object>;
    const loc: Object = entry.loc;
    const msg: Object = entry.msg;
    const where: string = loc !== undefined && loc !== null ? `${loc}`.replace(/,/g, '.') : '';
    const text: string = msg !== undefined && msg !== null ? `${msg}` : '';
    if (text.length > 0) {
      parts.push(where.length > 0 ? `${where} ${text}` : text);
    }
  }
  return parts.join('；');
}

interface ApiErrorBody {
  success?: boolean;
  code?: string;
  message?: string;
    /**
   * 校验错误的明细。**这个后端的字段名是 `details`（复数）**，
   * 不是 FastAPI 默认的 `detail`——两个都认，免得以后再猜。
   * 形态是 `[{type, location: [...], message, input}]`。
   */
  details?: Object[];
  detail?: string | Object[];
}

/** 401 回调：App 外壳注册它来踢回登录页（对应 iOS 端 `.apiUnauthorized` 通知）。 */
export type UnauthorizedHandler = (origin: string, token: string) => void;

/**
 * 分享访客 cookie（`movieclaw_share`）：后端在 `POST /share/{slug}/unlock` 成功后下发，
 * `Path` 限定在 `/api/v1/share/{slug}` 下，后续访客请求（含图片下载）都要原样带回。
 * 鸿蒙 http 模块不管理 cookie，这里放一个静态小罐子，按 origin+Path 前缀匹配。
 */
interface StoredCookie {
  origin: string;
  path: string;
  /** `name=value`，不带属性 */
  value: string;
}

/** 需要连同信封 message 一起返回的调用结果（清空观看记录等服务端给出反馈文案的接口）。 */
export interface ApiMessageResult<T> {
  data: T;
  /** 信封里的 message（成功提示语）；可能为空串 */
  message: string;
}

/**
 * ETag 协商缓存条目：200 响应的原始 JSON 文本 + 服务端 ETag。
 * 下次同键 GET 带 `If-None-Match`；服务端 304 时直接复用这份文本——
 * 内容没变（ETag 相同才 304），**不存在陈旧风险**，省的是带宽与重复 JSON 生成。
 */
class EtagEntry {
  readonly etag: string;
  readonly body: string;

  constructor(etag: string, body: string) {
    this.etag = etag;
    this.body = body;
  }
}

/**
 * MovieClaw 业务接口客户端（对应 iOS 端 APIClient）。
 *
 * 认证用设备令牌（docs/design/login-devices.md）：`POST /auth/device/login` 换一枚长期
 * 令牌，每个请求带 `Authorization: Bearer`。App 是服务端「我的设备」里的一台。
 *
 * 路径约定：调用方传 `/auth/me` 这种以 `/` 开头、相对 `/api/v1` 的路径，
 * 与 Web 端 `lib/api/*.ts`、iOS 端生成方法逐字一致。
 */
export class ApiClient {
  /** 服务器 origin，如 `https://demo.movieclaw.io`（不带末尾斜杠） */
  readonly origin: string;
  /** 当前路由类别（lan/wan/login，双地址选连）：请求带上 X-MovieClaw-Route；login 不带 */
  routeKind: string = 'login';
  private token: string | null;
  private connectTimeoutMs: number;
  private readTimeoutMs: number;

  /** App 外壳注册的全局 401 处理器 */
  private static unauthorizedHandler: UnauthorizedHandler | null = null;

  /** 分享访客 cookie 罐（见 StoredCookie 说明） */
  private static cookies: StoredCookie[] = [];

  /**
   * ETag 协商缓存（GET 响应文本，按 `origin + token + routeKind + cookie + path` 隔离）。
   * 预算 4MB 文本；条目只在 304 时被复用，200 时整体换新；带 `Cache-Control: no-store` 不落缓存。
   */
  private static readonly ETAG_BUDGET_CHARS: number = 4 * 1024 * 1024;
  private static readonly etagEntries: Map<string, EtagEntry> = new Map<string, EtagEntry>();
  private static readonly etagPolicy: ImageLruPolicy = new ImageLruPolicy();
  /** 失效代次：写请求或账号切换/注销时递增，防止在途旧 GET 晚归后把旧条目写回缓存。 */
  private static etagEpoch: number = 0;

  /** 在途 GET 共享：同键并发请求只发一次网络，跟随者各自解析（同文本不同对象，互不串改）。 */
  private readonly inflightGets: Map<string, Promise<string>> = new Map<string, Promise<string>>();

  /**
   * RequestMethod 枚举未收录 PATCH（底层 curl 支持；字符串枚举按值比较，
   * 运行期与手写枚举等价）。经 JSON.parse 构造以避免类型断言。
   */
  private static readonly patchMethod: http.RequestMethod = JSON.parse('"PATCH"') as http.RequestMethod;

  /** 所有请求带的 User-Agent，服务端靠它认出「这是原生鸿蒙 App」 */
  private static readonly userAgent: string =
    `MovieClaw-HarmonyOS/0.1.0 (${deviceInfo.productModel}; ${deviceInfo.osFullName}; build 1)`;

  /** 探测类请求（健康检查、启动鉴权）只收紧连接超时，读超时保持默认，慢网下大响应不受影响 */
  constructor(origin: string, token: string | null, connectTimeoutMs?: number, readTimeoutMs?: number) {
    this.origin = origin;
    this.token = token;
    this.connectTimeoutMs = connectTimeoutMs ?? 15000;
    this.readTimeoutMs = readTimeoutMs ?? 60000;
  }

  static setUnauthorizedHandler(handler: UnauthorizedHandler | null): void {
    ApiClient.unauthorizedHandler = handler;
  }

  setToken(token: string | null): void {
    if (this.token !== token) {
      this.token = token;
      this.inflightGets.clear();
      ApiClient.invalidateEtags();
    }
  }

  /** 清空本实例的在途 GET 槽（路由切换/会话退出时避免新请求并入旧在途请求）。 */
  clearInflight(): void {
    this.inflightGets.clear();
  }

  /**
   * 会话隔离清理（切账号/切服务器/注销/401 过期调用）：
   * 立即清空 ETag 协商缓存并推进代次，按需一并清掉访客 cookie 罐。
   */
  static clearSessionCaches(clearCookies: boolean = false): void {
    ApiClient.invalidateEtags();
    if (clearCookies) {
      ApiClient.cookies = [];
    }
  }

  /**
   * 任意 URL 命中的 cookie 串（`name=value; ...`；没有命中返回空）。
   * RemoteImage 下载 `/share/` 图片时用它带上 `movieclaw_share`（密码解锁后的图片也要鉴权）。
   */
  static cookieHeaderFor(url: string): string {
    const parts: string[] = [];
    for (const cookie of ApiClient.cookies) {
      if (url.startsWith(cookie.origin + cookie.path)) {
        parts.push(cookie.value);
      }
    }
    return parts.join('; ');
  }

  /** 从响应头捕获 Set-Cookie（键大小写两种都认；多个 Set-Cookie 可能是数组或逗号拼接串） */
  private static captureCookies(origin: string, header: Object): void {
    const record = header as Record<string, Object>;
    let raw: Object | undefined = record['set-cookie'];
    if (raw === undefined || raw === null) {
      raw = record['Set-Cookie'];
    }
    if (raw === undefined || raw === null) {
      return;
    }
    if (Array.isArray(raw)) {
      for (const item of raw as Object[]) {
        ApiClient.storeCookie(origin, `${item}`);
      }
    } else {
      ApiClient.storeCookie(origin, `${raw}`);
    }
  }

  private static storeCookie(origin: string, setCookie: string): void {
    const firstSemi: number = setCookie.indexOf(';');
    const head: string = (firstSemi >= 0 ? setCookie.substring(0, firstSemi) : setCookie).trim();
    const eq: number = head.indexOf('=');
    if (eq <= 0) {
      return;
    }
    let path: string = '/';
    if (firstSemi >= 0) {
      const attrs: string = setCookie.substring(firstSemi + 1);
      const lower: string = attrs.toLowerCase();
      const pathIndex: number = lower.indexOf('path=');
      if (pathIndex >= 0) {
        let p: string = attrs.substring(pathIndex + 5);
        const end: number = p.indexOf(';');
        if (end >= 0) {
          p = p.substring(0, end);
        }
        p = p.trim();
        if (p.length > 0) {
          path = p;
        }
      }
    }
    // 同 origin 同名 cookie 只留最新一枚
    const name: string = head.substring(0, eq);
    const kept: StoredCookie[] = [];
    for (const cookie of ApiClient.cookies) {
      const oldName: string = cookie.value.substring(0, cookie.value.indexOf('='));
      if (cookie.origin === origin && oldName === name) {
        continue;
      }
      kept.push(cookie);
    }
    kept.push({ origin: origin, path: path, value: head });
    ApiClient.cookies = kept;
  }

  getToken(): string | null {
    return this.token;
  }

  /** 拆信封的 GET（在途合并 + ETag 协商缓存，见 sharedGetText / fetchText）。 */
  get<T>(path: string): Promise<T> {
    return this.parseEnvelopeText<T>(this.sharedGetText(path));
  }

  post<T>(path: string, bodyText: string | null): Promise<T> {
    return this.send<T>(http.RequestMethod.POST, path, bodyText);
  }

  put<T>(path: string, bodyText: string | null): Promise<T> {
    return this.send<T>(http.RequestMethod.PUT, path, bodyText);
  }

  del<T>(path: string, bodyText: string | null): Promise<T> {
    return this.send<T>(http.RequestMethod.DELETE, path, bodyText);
  }

  patch<T>(path: string, bodyText: string | null): Promise<T> {
    return this.send<T>(ApiClient.patchMethod, path, bodyText);
  }

  /** 不关心 data 的接口（对应 iOS 端 `let _: API.JSONValue? = try await send(...)`） */
  getVoid(path: string): Promise<void> {
    return this.parseEnvelopeText<null>(this.sharedGetText(path)).then((): void => {});
  }

  postVoid(path: string, bodyText?: string | null): Promise<void> {
    return this.sendVoid(http.RequestMethod.POST, path, bodyText ?? null);
  }

  putVoid(path: string, bodyText?: string | null): Promise<void> {
    return this.sendVoid(http.RequestMethod.PUT, path, bodyText ?? null);
  }

  delVoid(path: string, bodyText?: string | null): Promise<void> {
    return this.sendVoid(http.RequestMethod.DELETE, path, bodyText ?? null);
  }

  /**
   * 拆信封同时保留服务端 message 的 DELETE（对应 iOS 端 libraryClearHistory
   * 返回的 (result, message) 元组）：清空观看记录这类接口的成功反馈文案在信封 message 里。
   */
  async delWithMessage<T>(path: string, bodyText: string | null): Promise<ApiMessageResult<T>> {
    this.invalidateBeforeWrite();
    try {
      const envelope: ApiEnvelope<T> | null =
        await this.perform<ApiEnvelope<T>>(http.RequestMethod.DELETE, path, bodyText, false, undefined, false);
      if (envelope === null) {
        throw ApiError.decoding('响应不是有效的 JSON');
      }
      return { data: envelope.data, message: envelope.message ?? '' };
    } finally {
      ApiClient.invalidateEtags();
    }
  }

  patchVoid(path: string, bodyText?: string | null): Promise<void> {
    return this.sendVoid(ApiClient.patchMethod, path, bodyText ?? null);
  }

  /**
   * 不拆信封的 GET（少数接口如 `/health` 直接返回对象，对应 iOS 端 `raw()`）。
   * timeoutMs 供连接测试等场景用短超时，避免填错局域网地址时干等。
   * 探测类请求不参与 ETag 缓存，避免连接探针命中旧缓存或污染协商表。
   */
  rawGet<T>(path: string, timeoutMs?: number): Promise<T> {
    return this.perform<T>(http.RequestMethod.GET, path, null, false, timeoutMs, false);
  }

  /** 写前失效：清空本实例在途 GET 并推进 ETag 代次，防并发 GET 与写后读互相串味。 */
  private invalidateBeforeWrite(): void {
    this.inflightGets.clear();
    ApiClient.invalidateEtags();
  }

  /** 统一入口（写请求）：写前后均失效协商缓存，再发请求 → 非 2xx 抛业务错误 → 2xx 拆信封取 data。 */
  private async send<T>(method: http.RequestMethod, path: string, bodyText: string | null): Promise<T> {
    this.invalidateBeforeWrite();
    try {
      return await this.perform<T>(method, path, bodyText, true, undefined, false);
    } finally {
      ApiClient.invalidateEtags();
    }
  }

  private async sendVoid(method: http.RequestMethod, path: string, bodyText: string | null): Promise<void> {
    this.invalidateBeforeWrite();
    try {
      await this.perform<null>(method, path, bodyText, true, undefined, false);
    } finally {
      ApiClient.invalidateEtags();
    }
  }

  /** 发请求 → 拿原始 JSON 文本（304 复用协商缓存；非 2xx 抛业务错误）。解析在 perform / parseEnvelopeText。 */
  private async perform<T>(method: http.RequestMethod, path: string, bodyText: string | null,
    unwrapEnvelope: boolean, timeoutMs?: number, allowEtag: boolean = true): Promise<T> {
    const text: string = await this.fetchText(method, path, bodyText, timeoutMs, allowEtag);
    if (text.length === 0) {
      return null as T;
    }
    if (!unwrapEnvelope) {
      try {
        return JSON.parse(text) as T;
      } catch (error) {
        throw ApiError.decoding('响应不是有效的 JSON');
      }
    }
    let envelope: ApiEnvelope<T>;
    try {
      envelope = JSON.parse(text) as ApiEnvelope<T>;
    } catch (error) {
      throw ApiError.decoding('响应不是有效的 JSON');
    }
    return envelope.data;
  }

  /**
   * 在途 GET 合并：同键（origin + 令牌 + 路由 + cookie + 路径）并发请求只发一次网络。
   * 跟随者拿到同一份原始文本**各自解析**——对象图不共享，调用方改自己的副本互不影响。
   * 请求结束（无论成败）仅清自己这一槽，避免写前旧请求晚归误删写后新槽。
   */
  private sharedGetText(path: string): Promise<string> {
    const fullUrl: string = `${this.origin}/api/v1${path}`;
    const cookie: string = ApiClient.cookieHeaderFor(fullUrl);
    const key: string = this.getCacheKey(path, cookie);
    const existing: Promise<string> | undefined = this.inflightGets.get(key);
    if (existing !== undefined) {
      return existing;
    }
    const text: Promise<string> = this.fetchText(http.RequestMethod.GET, path, null, undefined, true);
    this.inflightGets.set(key, text);
    const cleanup = (): void => {
      if (this.inflightGets.get(key) === text) {
        this.inflightGets.delete(key);
      }
    };
    text.then(cleanup, cleanup);
    return text;
  }

  /** 共享文本 → 拆信封（与 perform 的信封分支同一套语义）。 */
  private async parseEnvelopeText<T>(textPromise: Promise<string>): Promise<T> {
    const text: string = await textPromise;
    if (text.length === 0) {
      return null as T;
    }
    let envelope: ApiEnvelope<T>;
    try {
      envelope = JSON.parse(text) as ApiEnvelope<T>;
    } catch (error) {
      throw ApiError.decoding('响应不是有效的 JSON');
    }
    return envelope.data;
  }

  /** 协商缓存 / 在途合并共用的键：服务器 + 账号令牌 + 路由 + 访客 cookie + 路径。 */
  private getCacheKey(path: string, cookie: string): string {
    return `${this.origin}\u0000${this.token ?? ''}\u0000${this.routeKind}\u0000${cookie}\u0000${path}`;
  }

  /**
   * 取响应文本：构建请求头（鉴权/路由/cookie/If-None-Match）→ 发送 → 304 复用协商缓存
   * → 非 2xx 抛业务错误 → 2xx（GET 且带 ETag 且非 no-store）落协商缓存 → 返回原始 JSON 文本。
   */
  private async fetchText(method: http.RequestMethod, path: string, bodyText: string | null,
    timeoutMs?: number, allowEtag: boolean = true): Promise<string> {
    const fullUrl = `${this.origin}/api/v1${path}`;
    const httpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Accept': 'application/json',
        'User-Agent': ApiClient.userAgent
      };
      if (bodyText !== null) {
        header['Content-Type'] = 'application/json';
      }
      if (this.token !== null && this.token.length > 0) {
        header['Authorization'] = `Bearer ${this.token}`;
      }
      // 内外双地址选连（同 iOS X-MovieClaw-Route）：服务端按它区分本次请求走的哪条路
      if (this.routeKind.length > 0 && this.routeKind !== 'login') {
        header['X-MovieClaw-Route'] = this.routeKind;
      }
      const cookie: string = ApiClient.cookieHeaderFor(fullUrl);
      if (cookie.length > 0) {
        header['Cookie'] = cookie;
      }
      // ETag 协商：GET 有缓存条目就带上 If-None-Match；服务端内容未变会回 304
      const isEtagGet: boolean = allowEtag && method === http.RequestMethod.GET;
      const cacheKey: string = this.getCacheKey(path, cookie);
      const startEpoch: number = ApiClient.etagEpoch;
      const etagHit: EtagEntry | undefined = isEtagGet ? ApiClient.etagEntries.get(cacheKey) : undefined;
      if (etagHit !== undefined) {
        header['If-None-Match'] = etagHit.etag;
      }
      const options: http.HttpRequestOptions = {
        method: method,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: timeoutMs ?? this.connectTimeoutMs,
        readTimeout: timeoutMs ?? this.readTimeoutMs
      };
      if (bodyText !== null) {
        options.extraData = bodyText;
      }
      const resp = await httpRequest.request(fullUrl, options);
      const text = resp.result as string;
      ApiClient.captureCookies(this.origin, resp.header);

      const cacheControl: string = ApiClient.readHeader(resp.header, 'cache-control');
      const noStore: boolean = ApiClient.hasCacheDirective(cacheControl, 'no-store');

      // 304 Not Modified：内容已与服务端当面确认未变，直接复用缓存文本并续命 LRU
      if (resp.responseCode === 304 && etagHit !== undefined) {
        if (noStore) {
          ApiClient.removeEtag(cacheKey);
        } else if (ApiClient.etagEpoch === startEpoch) {
          const updatedEtag: string = ApiClient.readHeader(resp.header, 'etag');
          if (updatedEtag.length > 0 && updatedEtag !== etagHit.etag) {
            ApiClient.storeEtag(cacheKey, updatedEtag, etagHit.body);
          } else {
            ApiClient.etagPolicy.touch(cacheKey);
          }
        }
        return etagHit.body;
      }

      // 非 2xx：解析错误体，透出后端的可读中文
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        let message = `请求失败（HTTP ${resp.responseCode}）`;
        let code = '';
        if (text.length > 0) {
          try {
            const errBody = JSON.parse(text) as ApiErrorBody;
            if (errBody.message !== undefined && errBody.message !== null) {
              message = errBody.message;
            }
            if (errBody.code !== undefined && errBody.code !== null) {
              code = errBody.code;
            }
            /*
             * 后端的校验错误（422）把「哪个字段不对」放在 `detail` 里，
             * `message` 只是一句笼统的「request validation failed」。
             * **不带上 detail 的话，每个 422 都是死胡同**——只能靠猜。
             */
            const detail: string = describeDetail(errBody);
            if (detail.length > 0) {
              message = `${message}：${detail}`;
            }
          } catch (error) {
            // 错误体不是 JSON（反向代理的 HTML 错误页等），用通用文案
          }
        }
        // 401 且不是登录/分享接口 → 会话失效，通知外壳踢回登录页。
        // 登录/初始化的 401 是「密码错误」，分享的 401 是「需要/错密码」，都不能踢会话。
        if (resp.responseCode === 401 && !ApiClient.isAuthEndpoint(path)) {
          const handler = ApiClient.unauthorizedHandler;
          if (handler !== null && this.token !== null) {
            handler(this.origin, this.token);
          }
        }
        throw ApiError.http(resp.responseCode, message, code);
      }

      // 2xx + GET：遵循 Cache-Control: no-store 与代次守卫；无 ETag 或超预算时移除旧条目
      if (isEtagGet) {
        if (noStore) {
          ApiClient.removeEtag(cacheKey);
        } else if (ApiClient.etagEpoch === startEpoch) {
          const etag: string = ApiClient.readHeader(resp.header, 'etag');
          if (etag.length > 0 && text.length <= ApiClient.ETAG_BUDGET_CHARS) {
            ApiClient.storeEtag(cacheKey, etag, text);
          } else {
            ApiClient.removeEtag(cacheKey);
          }
        }
      }
      return text;
    } catch (error) {
      if (error instanceof ApiError) {
        throw error;
      }
      throw ApiClient.mapTransportError(error as BusinessError);
    } finally {
      httpRequest.destroy();
    }
  }

  /** 写请求/切换账号让协商缓存整仓失效并推进代次：确定性不命中，防在途旧响应回写。 */
  private static invalidateEtags(): void {
    ApiClient.etagEpoch++;
    ApiClient.etagEntries.clear();
    ApiClient.etagPolicy.clearAll();
  }

  private static removeEtag(key: string): void {
    ApiClient.etagEntries.delete(key);
    ApiClient.etagPolicy.remove(key);
  }

  private static storeEtag(key: string, etag: string, body: string): void {
    if (body.length > ApiClient.ETAG_BUDGET_CHARS) {
      ApiClient.removeEtag(key);
      return;
    }
    ApiClient.etagEntries.set(key, new EtagEntry(etag, body));
    ApiClient.etagPolicy.insert(key, body.length);
    const evicted: string[] = ApiClient.etagPolicy.evictOverBudget(ApiClient.ETAG_BUDGET_CHARS);
    for (const evictedKey of evicted) {
      ApiClient.etagEntries.delete(evictedKey);
    }
  }

  /** 大小写无关读响应头（支持字符串与字符串数组；不存在返回空串）。 */
  private static readHeader(header: Object | undefined | null, lowerName: string): string {
    if (header === undefined || header === null) {
      return '';
    }
    const record: Record<string, Object> = header as Record<string, Object>;
    const keys: string[] = Object.keys(record);
    for (let index = 0; index < keys.length; index++) {
      const key: string = keys[index];
      if (key.toLowerCase() !== lowerName) {
        continue;
      }
      const raw: Object | undefined = record[key];
      if (raw === undefined || raw === null) {
        return '';
      }
      if (Array.isArray(raw)) {
        const parts: string[] = [];
        const list: Object[] = raw as Object[];
        for (let i = 0; i < list.length; i++) {
          parts.push(`${list[i]}`);
        }
        return parts.join(', ').trim();
      }
      return `${raw}`.trim();
    }
    return '';
  }

  /** 判断 Cache-Control 是否含指定指令（如 no-store）。 */
  private static hasCacheDirective(cacheControl: string, directive: string): boolean {
    if (cacheControl.length === 0) {
      return false;
    }
    const parts: string[] = cacheControl.toLowerCase().split(',');
    for (let index = 0; index < parts.length; index++) {
      const token: string = parts[index].trim();
      if (token === directive || token.startsWith(`${directive}=`)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 这些接口的 401 不是「会话过期」，不能把用户踢回登录页（与 iOS 端逐字一致）：
   * - 登录 / 初始化本身：401 = 密码错误；
   * - 访客分享 `/share/*`（含分享播放）：401 = 需要分享密码或密码错误。
   */
  private static isAuthEndpoint(path: string): boolean {
    return path === '/auth/login' || path === '/auth/device/login' || path === '/auth/bootstrap'
      || path.startsWith('/share/');
  }

  /** 传输层错误 → 可行动的中文（与 iOS 端 networkMessage 对齐）。 */
  private static mapTransportError(error: BusinessError): ApiError {
    // curl 错误码 + 2300000 偏移（鸿蒙 http 模块沿用 curl）
    const curlCode = error.code - 2300000;
    if (curlCode === 28) {
      return ApiError.timeout();
    }
    if (curlCode === 6) {
      return ApiError.network('找不到该服务器，请检查地址是否正确');
    }
    if (curlCode === 7) {
      return ApiError.network('无法连接到服务器：地址或端口不对，或服务器未启动');
    }
    if (curlCode === 35 || curlCode === 51 || curlCode === 60 || curlCode === 90 || curlCode === 91) {
      return ApiError.network('HTTPS 证书校验失败，请检查服务器证书，或改用 http 地址');
    }
    return ApiError.network(`网络中断或请求失败，请检查连接后重试（${error.code}）`);
  }
}
