import { webview, WebNetErrorList } from '@kit.ArkWeb';
import { http } from '@kit.NetworkKit';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { AppNavBar } from '../common/AppNavBar';
import { AppModel } from '../common/AppModel';
import { ShellChrome } from '../common/ShellChrome';
import { Theme } from '../theme/AppTheme';

/**
 * 插件网页（对应 Web `app/(app)/apps/[plugin]` 里的同源 iframe）。
 *
 * 为什么不用现成的 http(s) 地址直接加载：插件网页的每个请求（HTML、脚本、接口）都要求登录，
 * 而 App 用的是 **设备令牌（Bearer）**，Web 组件默认不带这个头，也不共享 ApiClient 的令牌。
 * 这里把页面放在自定义 scheme `mclawplugin://` 下，用 `WebSchemeHandler` 逐请求代理到真实
 * 服务器：补 `Authorization`，把响应（含二进制）原样交还给 Web 内核。页面自身发起的
 * 相对地址与 `/api/v1/...` 绝对路径都落在同一个 scheme 下，走同一条代理，POST 体也支持。
 *
 * 自定义 scheme 必须在任何 Web 组件创建前注册（见 `EntryAbility.onCreate` 的
 * `customizeSchemes`）。
 */

const SCHEME = 'mclawplugin';
/** 伪域名：只用来满足 URL 解析，真正访问的地址由代理拼回来 */
const HOST = 'plugin';

/** 路由参数：插件网页入口 */
export class PluginWebParams {
  readonly pluginId: string;
  readonly label: string;
  /** 网页根地址前缀（服务端给的 `/api/v1/plugins/<id>/web/`） */
  readonly base: string;
  /** 入口子路径（manifest 的 shortcuts，主入口为空串） */
  readonly path: string;

  constructor(pluginId: string, label: string, base: string, path: string) {
    this.pluginId = pluginId;
    this.label = label;
    this.base = base;
    this.path = path;
  }

  static of(param: Object | undefined): PluginWebParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    if (param instanceof PluginWebParams) {
      return param as PluginWebParams;
    }
    const record: Record<string, Object> = param as Record<string, Object>;
    const pluginId: Object | undefined = record['pluginId'];
    const label: Object | undefined = record['label'];
    const base: Object | undefined = record['base'];
    const path: Object | undefined = record['path'];
    if (pluginId === undefined || label === undefined || base === undefined) {
      return null;
    }
    return new PluginWebParams(`${pluginId}`, `${label}`, `${base}`,
      path === undefined ? '' : `${path}`);
  }
}

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function PluginWebPageBuilder() {
  PluginWebPage()
}

@ComponentV2
export struct PluginWebPage {
  private controller: webview.WebviewController = new webview.WebviewController();
  private handler: webview.WebSchemeHandler | null = null;
  private params: PluginWebParams | null = null;
  /** 代理已注册 + 参数已到：两个条件都满足才发起首次加载 */
  private handlerReady: boolean = false;
  private pageUrl: string = '';

  @Local private title: string = '插件页面';
  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorText: string = '';
  private chrome: ShellChrome = ShellChrome.shared;

  aboutToDisappear(): void {
    // 整屏页标记：退出时把底栏与「我的」页的快捷输入放回来
    this.chrome.pop('pluginWeb');
  }

  build() {
    HdsNavDestination() {
      Stack() {
        /*
         * 让开官方标题栏：插件页面自带顶栏，压在 App 标题栏下面会叠字。
         * 用「Column + layoutWeight」而不是给 Web 加 margin：Web 是独立渲染层，
         * 在 Stack 里给百分比高度 + 外边距会被居中挤出窗口（实测顶到状态栏上）。
         * 顶部内边距要给 `contentTop`（状态栏 + 标题栏）而不是标题栏高度：
         * Web 面层按窗口顶算位置，给 HEIGHT 只能让开一半（实测卡在标题栏中间）。
         */
        Column() {
          Web({ src: '', controller: this.controller })
            .width('100%')
            .layoutWeight(1)
            .backgroundColor(Theme.bg)
            .onControllerAttached((): void => {
              this.registerHandler();
            })
            .onPageBegin((): void => {
              this.loading = true;
            })
            .onPageEnd((): void => {
              this.loading = false;
            })
            .onErrorReceive((event: OnErrorReceiveEvent): void => {
              if (event.error.getErrorCode() === -1) {
                return;
              }
              this.failed = true;
              this.errorText = `页面加载失败（${event.error.getErrorCode()}）`;
              this.loading = false;
            })
        }
        .width('100%')
        .height('100%')
        .padding({ top: AppNavBar.contentTop })

        if (this.loading && !this.failed) {
          Column() {
            LoadingProgress()
              .width(24)
              .height(24)
              .color(Theme.textMuted)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        if (this.failed) {
          Column({ space: 10 }) {
            Text('打不开插件网页').fontSize(16).fontColor(Theme.text)
            Text(this.errorText)
              .fontSize(13)
              .fontColor(Theme.textMuted)
              .textAlign(TextAlign.Center)
            Text('重试')
              .fontSize(14)
              .fontColor(Theme.accentStrong)
              .onClick((): void => {
                this.failed = false;
                this.load();
              })
          }
          .width('100%')
          .height('100%')
          .padding(24)
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    /*
     * 插件网页自带完整界面（含自己的导航），标题栏只用来看当前是哪个插件页面；
     * 返回键由 HdsNavDestination 负责（退出页面，不接管网页内部历史）。
     */
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar(AppNavBar.subPageTitleBar(this.title))
    .onReady((ctx: NavDestinationContext): void => {
      this.chrome.push('pluginWeb');
      const params: PluginWebParams | null = PluginWebParams.of(ctx.pathInfo.param as Object | undefined);
      if (params === null) {
        return;
      }
      this.params = params;
      this.title = params.label;
      this.pageUrl = PluginWebPage.urlOf(params);
      this.load();
    })
  }

  /** 自定义 scheme 下的入口地址：`mclawplugin://plugin` + 服务端给的 base + 子路径 */
  private static urlOf(params: PluginWebParams): string {
    const base: string = params.base.endsWith('/') ? params.base : `${params.base}/`;
    const sub: string = params.path.startsWith('/') ? params.path.substring(1) : params.path;
    return `${SCHEME}://${HOST}${base}${sub}`;
  }

  /** 首次加载：等代理注册好再 loadUrl（先于注册的导航不会被拦截） */
  private load(): void {
    if (!this.handlerReady || this.pageUrl.length === 0) {
      return;
    }
    this.loading = true;
    try {
      this.controller.loadUrl(this.pageUrl);
    } catch (error) {
      this.failed = true;
      this.errorText = '无法加载页面';
      this.loading = false;
    }
  }

  /** 注册自定义 scheme 的代理；所有请求都走 `proxy` */
  private registerHandler(): void {
    if (this.handler !== null) {
      return;
    }
    const handler: webview.WebSchemeHandler = new webview.WebSchemeHandler();
    handler.onRequestStart((request: webview.WebSchemeHandlerRequest,
      resourceHandler: webview.WebResourceHandler): boolean => {
      this.proxy(request, resourceHandler);
      return true;
    });
    try {
      this.controller.setWebSchemeHandler(SCHEME, handler);
    } catch (error) {
      this.failed = true;
      this.errorText = '无法注册插件网页协议';
      return;
    }
    this.handler = handler;
    this.handlerReady = true;
    this.load();
  }

  /**
   * 单个请求的代理：`mclawplugin://plugin/api/v1/...` → `<server>/api/v1/...`，
   * 补上设备令牌。响应整包取回后一次性交给 Web 内核（插件网页都是普通资源，不需要流式）。
   */
  private async proxy(request: webview.WebSchemeHandlerRequest,
    resourceHandler: webview.WebResourceHandler): Promise<void> {
    const client = AppModel.shared.client;
    if (client === null) {
      resourceHandler.didFail(WebNetErrorList.ERR_FAILED);
      return;
    }
    const url: string = request.getRequestUrl();
    const path: string = PluginWebPage.pathOf(url);
    const target: string = `${AppModel.origin()}${path}`;
    const header: Record<string, string> = PluginWebPage.headersOf(request);
    const token: string | null = client.getToken();
    if (token !== null && token.length > 0) {
      header['Authorization'] = `Bearer ${token}`;
    }
    let body: ArrayBuffer | undefined = undefined;
    const stream: webview.WebHttpBodyStream | null = request.getHttpBodyStream();
    if (stream !== null) {
      try {
        body = await PluginWebPage.readBody(stream);
      } catch (error) {
        resourceHandler.didFail(WebNetErrorList.ERR_FAILED);
        return;
      }
    }
    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await httpRequest.request(target, {
        method: PluginWebPage.methodOf(request.getRequestMethod()),
        header: header,
        extraData: body,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 60000
      });
      const out: webview.WebSchemeHandlerResponse = new webview.WebSchemeHandlerResponse();
      out.setNetErrorCode(WebNetErrorList.NET_OK);
      out.setStatus(response.responseCode);
      out.setStatusText(response.responseCode >= 200 && response.responseCode < 300 ? 'OK' : 'Error');
      const contentType: string = PluginWebPage.responseHeader(response.header, 'content-type');
      out.setMimeType(contentType.length > 0 ? contentType.split(';')[0] : 'application/octet-stream');
      if (PluginWebPage.isText(contentType)) {
        out.setEncoding('utf-8');
      }
      PluginWebPage.copyResponseHeaders(out, response.header);
      resourceHandler.didReceiveResponse(out);
      const result: string | Object | ArrayBuffer = response.result;
      if (result instanceof ArrayBuffer && result.byteLength > 0) {
        resourceHandler.didReceiveResponseBody(result);
      }
      resourceHandler.didFinish();
    } catch (error) {
      resourceHandler.didFail(WebNetErrorList.ERR_FAILED);
    } finally {
      httpRequest.destroy();
    }
  }

  /** `mclawplugin://plugin/<path>` → `/<path>` */
  private static pathOf(url: string): string {
    const marker: string = `${SCHEME}://`;
    let rest: string = url.startsWith(marker) ? url.substring(marker.length) : url;
    const slash: number = rest.indexOf('/');
    rest = slash >= 0 ? rest.substring(slash) : '/';
    return rest.length > 0 ? rest : '/';
  }

  /** 浏览器请求头 → 代理请求头：去掉会干扰代理的几项 */
  private static headersOf(request: webview.WebSchemeHandlerRequest): Record<string, string> {
    const header: Record<string, string> = {};
    const list: webview.WebHeader[] = request.getHeader();
    for (const item of list) {
      const key: string = item.headerKey.toLowerCase();
      if (key === 'authorization' || key === 'host' || key === 'cookie' || key === 'origin'
        || key === 'referer' || key === 'content-length' || key === 'connection'
        || key === 'accept-encoding' || key === 'if-none-match' || key === 'if-modified-since') {
        continue;
      }
      header[item.headerKey] = item.headerValue;
    }
    header['Accept-Encoding'] = 'identity';
    return header;
  }

  /** POST/PUT 的请求体（`onInterceptRequest` 拿不到，scheme handler 可以） */
  private static async readBody(stream: webview.WebHttpBodyStream): Promise<ArrayBuffer | undefined> {
    await stream.initialize();
    const size: number = stream.getSize();
    if (size === 0) {
      return undefined;
    }
    if (size > 0) {
      return stream.read(size);
    }
    const chunks: ArrayBuffer[] = [];
    let total: number = 0;
    while (!stream.isEof()) {
      const chunk: ArrayBuffer = await stream.read(65536);
      if (chunk.byteLength === 0) {
        break;
      }
      chunks.push(chunk);
      total += chunk.byteLength;
    }
    if (total === 0) {
      return undefined;
    }
    const joined: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (const chunk of chunks) {
      joined.set(new Uint8Array(chunk), offset);
      offset += chunk.byteLength;
    }
    return joined.buffer;
  }

  private static methodOf(method: string): http.RequestMethod {
    const upper: string = method.toUpperCase();
    if (upper === 'POST') {
      return http.RequestMethod.POST;
    }
    if (upper === 'PUT') {
      return http.RequestMethod.PUT;
    }
    if (upper === 'DELETE') {
      return http.RequestMethod.DELETE;
    }
    if (upper === 'PATCH') {
      return http.RequestMethod.PATCH;
    }
    if (upper === 'HEAD') {
      return http.RequestMethod.HEAD;
    }
    return http.RequestMethod.GET;
  }

  /** 响应头（大小写不敏感） */
  private static responseHeader(header: Object, name: string): string {
    const record: Record<string, Object> = header as Record<string, Object>;
    const keys: string[] = Object.keys(record);
    for (const key of keys) {
      if (key.toLowerCase() === name) {
        const raw: Object = record[key];
        return raw === null || raw === undefined ? '' : `${raw}`;
      }
    }
    return '';
  }

  private static isText(contentType: string): boolean {
    const lower: string = contentType.toLowerCase();
    return lower.startsWith('text/') || lower.includes('json')
      || lower.includes('javascript') || lower.includes('xml');
  }

  /** 只透传缓存与内容相关的响应头；CSP / 框架限制留着会让自定义 scheme 下的页面被挡 */
  private static copyResponseHeaders(out: webview.WebSchemeHandlerResponse, header: Object): void {
    const names: string[] = ['cache-control', 'etag', 'last-modified', 'content-disposition'];
    const record: Record<string, Object> = header as Record<string, Object>;
    const keys: string[] = Object.keys(record);
    for (const key of keys) {
      if (names.indexOf(key.toLowerCase()) < 0) {
        continue;
      }
      const raw: Object = record[key];
      if (raw !== null && raw !== undefined) {
        out.setHeaderByName(key, `${raw}`, true);
      }
    }
  }
}
