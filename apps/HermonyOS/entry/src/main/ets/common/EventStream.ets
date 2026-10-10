import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { ApiError } from '../api/ApiClient';

/**
 * 一条 Server-Sent Event（对应 iOS 端 Core/Networking/EventStream.swift 的 ServerEvent）。
 *
 * - `id` 为 null 表示这条事件没有 id（注释心跳就没有 id）；
 * - `event` 缺省为 "message"；
 * - `data` 是多行 data 用 "\n" 拼好的载荷文本，消费方自行 JSON.parse。
 */
export class ServerEvent {
  id: string | null;
  event: string;
  data: string;

  constructor(id: string | null, event: string, data: string) {
    this.id = id;
    this.event = event;
    this.data = data;
  }
}

/** 打开一条 SSE 流的回调集合。 */
export interface StreamCallbacks {
  /** 每凑齐一条事件（空行触发）回调一次；注释心跳不回调。 */
  onEvent: (event: ServerEvent) => void;
  /** 非 2xx 或传输层错误。**注意：这里不触发 401 踢会话逻辑**，只把错误交给消费方。 */
  onError: (error: ApiError) => void;
  /** 服务端正常关闭了流（2xx 收尾）。 */
  onEnd: () => void;
}

/** 打开 SSE 流的可选参数。 */
export interface StreamOptions {
  /** path 之外拼上的 query 参数（已值是字符串，由这里 URL 编码）。 */
  query?: Record<string, string>;
  /** Last-Event-ID 请求头（断线续传时带上最后收到的事件 id）。 */
  lastEventId?: string;
}

/**
 * 关闭句柄（对应 iOS 端取消那个 Task）。页面消失、停止任务、切走时调 `close()` 断流。
 * 幂等：重复调 close() 不会重复触发 onError/onEnd。
 */
export class StreamHandle {
  private doClose: () => void;
  private closed: boolean = false;

  constructor(doClose: () => void) {
    this.doClose = doClose;
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.doClose();
  }
}

/**
 * SSE 逐行解析器（逐字节切行，对应 iOS 端 SSELineParser）。
 *
 * **必须按字节切行**，不能用文本行切分：
 * - 只认 LF(0x0A) 为行尾；行尾的 CR(0x0D) 剥掉；
 * - 绝不能把 U+2028 / U+2029 / U+0085 当行尾（后端 JSON 以 ensure_ascii=False 输出，
 *   种子标题、AI 回复里一旦出现这些字符，单条事件会被切断、解码报「数据损坏」）；
 * - 跨 chunk 的多字节 UTF-8 必须先按「完整行」累积字节、凑到 LF 再整行解码，
 *   不能逐 chunk 解码，否则中文会乱码。
 *
 * 解析规则：`:` 开头是注释（心跳）直接忽略；`field:value`（冒号后至多剥一个前导空格）；
 * 字段 event/data/id；多行 data 用 "\n" 拼接；空行触发一条事件派发；
 * `event:` 缺省 "message"；`id:` 记录最后事件号（flush 不清 id）；
 * 流结束时把没有尾随空行的最后一条事件 flush 出来。
 */
class SSELineParser {
  private id: string | null = null;
  private event: string = 'message';
  private data: string[] = [];
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  /**
   * 喂入一行原始字节（不含 LF，可能带 CR）。
   * 空行（长度 0）时把凑齐的事件交出去；其余情况返回 null。
   */
  feedLine(lineBytes: number[]): ServerEvent | null {
    let bytes = lineBytes;
    if (bytes.length > 0 && bytes[bytes.length - 1] === 0x0D) {
      bytes = bytes.slice(0, bytes.length - 1);
    }
    if (bytes.length === 0) {
      return this.flush();
    }
    // 整行才解码：跨 chunk 的多字节 UTF-8 在这里已经是完整一行，不会乱码
    const line: string = this.decoder.decodeToString(new Uint8Array(bytes));
    if (line.startsWith(':')) {
      return null;
    }
    let colon = -1;
    for (let i = 0; i < line.length; i++) {
      if (line.charCodeAt(i) === 0x3A) {
        colon = i;
        break;
      }
    }
    let field: string;
    let value: string;
    if (colon >= 0) {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
    } else {
      field = line;
      value = '';
    }
    if (field === 'event') {
      this.event = value;
    } else if (field === 'data') {
      this.data.push(value);
    } else if (field === 'id') {
      this.id = value;
    }
    return null;
  }

  /** 流结束时把最后一条（没有尾随空行的）事件也交出去；id 不清（记录最后事件号）。 */
  flush(): ServerEvent | null {
    const ev: ServerEvent | null = this.data.length === 0
      ? null
      : new ServerEvent(this.id, this.event, this.data.join('\n'));
    this.event = 'message';
    this.data = [];
    return ev;
  }
}

/** 错误响应体（只取 message；非 2xx 时用来透出后端可读中文）。 */
interface StreamErrorBody {
  message?: string;
  code?: string;
}

/**
 * SSE 客户端（对应 iOS 端 APIClient.events(_:query:lastEventId:)）。
 *
 * 形态：ArkTS 没有 async generator，所以用「打开即返回句柄」的回调式设计——
 * `open(path, opts, callbacks)` 返回 `StreamHandle`，调 `close()` 断流。
 *
 * 用法：页面持有 origin/token（从 `AppModel.shared.client` 取）构造一次，
 * 需要跟随哪条流就 `open()` 一次，把返回的句柄存起来，页面消失/停止任务时 `close()`。
 *
 * **铁律**：流式端点的 401 不调用 ApiClient 的 unauthorizedHandler / sessionExpired
 * （那是一次性请求的踢会话逻辑）。流的 401 只当普通 ApiError.http 交给消费方。
 */
export class EventStream {
  /** 读超时 3600s（对齐 iOS timeoutInterval = 3600）。 */
  private static readonly READ_TIMEOUT_MS: number = 3600000;
  private static readonly CONNECT_TIMEOUT_MS: number = 15000;
  /** 非 2xx 时读错误体的上限（对齐 iOS 的 64KB）。 */
  private static readonly HEAD_CAP: number = 65536;

  /** 与 ApiClient.userAgent 同形（服务端靠它认出「这是原生鸿蒙 App」）。 */
  private static readonly userAgent: string =
    `MovieClaw-HarmonyOS/0.1.0 (${deviceInfo.productModel}; ${deviceInfo.osFullName}; build 1)`;

  private origin: string;
  private token: string | null;

  constructor(origin: string, token: string | null) {
    this.origin = origin;
    this.token = token;
  }

  /**
   * 打开一条 SSE 流。path 以 `/` 开头、相对 `/api/v1`（与 ApiClient 一致）。
   *
   * 注意：HarmonyOS 的 `requestInStream` 要到流结束才给到状态码，所以在收到第一个 chunk
   * 时无法预先判断是不是 2xx。这里直接按 SSE 解析——非 2xx 的错误体是 JSON 信封，
   * 字段都带引号（`"message": "..."`），不会被当成 `data:`/`event:` 字段，因此不会误派发事件；
   * 等 Promise 落定拿到状态码后再按 2xx/非 2xx 走 onEnd / onError。
   */
  open(path: string, options: StreamOptions, callbacks: StreamCallbacks): StreamHandle {
    const httpRequest: http.HttpRequest = http.createHttp();
    const parser: SSELineParser = new SSELineParser();
    let pending: number[] = [];
    let head: number[] = [];
    let closed: boolean = false;
    let settled: boolean = false;

    const header: Record<string, string> = {
      'Accept': 'text/event-stream',
      'User-Agent': EventStream.userAgent
    };
    if (this.token !== null && this.token.length > 0) {
      header['Authorization'] = `Bearer ${this.token}`;
    }
    if (options.lastEventId !== undefined && options.lastEventId !== null && options.lastEventId.length > 0) {
      header['Last-Event-ID'] = options.lastEventId;
    }

    const reqOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: EventStream.CONNECT_TIMEOUT_MS,
      readTimeout: EventStream.READ_TIMEOUT_MS
    };
    const url: string = this.buildUrl(path, options.query);

    httpRequest.on('dataReceive', (data: ArrayBuffer): void => {
      if (closed) {
        return;
      }
      const bytes: Uint8Array = new Uint8Array(data);
      for (let i = 0; i < bytes.length; i++) {
        const b: number = bytes[i];
        if (head.length < EventStream.HEAD_CAP) {
          head.push(b);
        }
        if (b === 0x0A) {
          const ev: ServerEvent | null = parser.feedLine(pending);
          pending = [];
          if (ev !== null && !closed) {
            callbacks.onEvent(ev);
          }
        } else {
          pending.push(b);
        }
      }
    });

    const handle: StreamHandle = new StreamHandle((): void => {
      closed = true;
      try {
        httpRequest.destroy();
      } catch (e) {
        // 已销毁/已结束时 destroy 可能抛错，忽略
      }
    });

    httpRequest.requestInStream(url, reqOptions).then((status: number): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (closed) {
        return;
      }
      if (status >= 200 && status < 300) {
        // 没有尾随空行的最后一行先喂进去，再 flush 出最后一条事件
        if (pending.length > 0) {
          const ev: ServerEvent | null = parser.feedLine(pending);
          pending = [];
          if (ev !== null) {
            callbacks.onEvent(ev);
          }
        }
        const tail: ServerEvent | null = parser.flush();
        if (tail !== null) {
          callbacks.onEvent(tail);
        }
        callbacks.onEnd();
      } else {
        callbacks.onError(ApiError.http(status, EventStream.readErrorMessage(head), ''));
      }
    }).catch((err: BusinessError): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (closed) {
        return;
      }
      callbacks.onError(EventStream.mapError(err));
    });

    return handle;
  }

  private buildUrl(path: string, query?: Record<string, string>): string {
    let url: string = `${this.origin}/api/v1${path}`;
    if (query !== undefined && query !== null) {
      const keys: string[] = Object.keys(query);
      if (keys.length > 0) {
        const parts: string[] = [];
        for (let i = 0; i < keys.length; i++) {
          const key: string = keys[i];
          parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(query[key])}`);
        }
        url += '?' + parts.join('&');
      }
    }
    return url;
  }

  /** 从流头部字节（错误体）里取后端 message；取不到给通用文案。 */
  private static readErrorMessage(head: number[]): string {
    if (head.length === 0) {
      return '请求失败';
    }
    try {
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(head));
      const body: StreamErrorBody = JSON.parse(text) as StreamErrorBody;
      if (body.message !== undefined && body.message !== null && body.message.length > 0) {
        return body.message;
      }
    } catch (e) {
      // 错误体不是 JSON（反代的 HTML 错误页等）：用通用文案
    }
    return '请求失败';
  }

  /** 传输层错误 → 可行动的中文（与 ApiClient.mapTransportError 同口径）。 */
  private static mapError(error: BusinessError): ApiError {
    // curl 错误码 + 2300000 偏移（鸿蒙 http 模块沿用 curl）
    const curlCode: number = error.code - 2300000;
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
