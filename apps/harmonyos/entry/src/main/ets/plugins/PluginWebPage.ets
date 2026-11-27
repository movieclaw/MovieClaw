import { webview, WebNetErrorList } from '@kit.ArkWeb';
import { http } from '@kit.NetworkKit';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { AppNavBar } from '../common/AppNavBar';
import { AppModel } from '../common/AppModel';
import { ShellChrome } from '../common/ShellChrome';
import { Theme } from '../theme/AppTheme';

const SCHEME = 'mclawplugin';
const HOST = 'plugin';

export class PluginWebParams {
  readonly pluginId: string;
  readonly label: string;
  readonly base: string;
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

@Builder
export function PluginWebPageBuilder() {
  PluginWebPage()
}

@ComponentV2
export struct PluginWebPage {
  private controller: webview.WebviewController = new webview.WebviewController();
  private handler: webview.WebSchemeHandler | null = null;
  private params: PluginWebParams | null = null;
  private handlerReady: boolean = false;
  private pageUrl: string = '';

  @Local private title: string = '插件页面';
  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorText: string = '';
  private chrome: ShellChrome = ShellChrome.shared;

  aboutToDisappear(): void {
    this.chrome.pop('pluginWeb');
  }

  build() {
    HdsNavDestination() {
      Stack() {
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
            LoadingProgress().width(24).height(24).color(Theme.textMuted)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        if (this.failed) {
          Column({ space: 10 }) {
            Text('打不开插件网页').fontSize(16).fontColor(Theme.text)
            Text(this.errorText).fontSize(13).fontColor(Theme.textMuted).textAlign(TextAlign.Center)
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

  private static urlOf(params: PluginWebParams): string {
    const base: string = params.base.endsWith('/') ? params.base : `${params.base}/`;
    const sub: string = params.path.startsWith('/') ? params.path.substring(1) : params.path;
    return `${SCHEME}://${HOST}${base}${sub}`;
  }

  private load(): void {
    if (!this.handlerReady || this.pageUrl.length === 0) {
      return;
    }
    this.loading = true;
    try {
      this.controller.loadUrl(this.pageUrl);
    } catch (_error) {
      this.failed = true;
      this.errorText = '无法加载页面';
      this.loading = false;
    }
  }

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
    } catch (_error) {
      this.failed = true;
      this.errorText = '无法注册插件网页协议';
      return;
    }
    this.handler = handler;
    this.handlerReady = true;
    this.load();
  }

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
      } catch (_error) {
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
    } catch (_error) {
      resourceHandler.didFail(WebNetErrorList.ERR_FAILED);
    } finally {
      httpRequest.destroy();
    }
  }

  private static pathOf(url: string): string {
    const marker: string = `${SCHEME}://`;
    let rest: string = url.startsWith(marker) ? url.substring(marker.length) : url;
    const slash: number = rest.indexOf('/');
    rest = slash >= 0 ? rest.substring(slash) : '/';
    return rest.length > 0 ? rest : '/';
  }

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

  private static async readBody(stream: webview.WebHttpBodyStream): Promise<ArrayBuffer | undefined> {
    await stream.initialize();
    const size: number = stream.getSize();
    if (size === 0) { return undefined; }
    if (size > 0) { return stream.read(size); }
    const chunks: ArrayBuffer[] = [];
    let total: number = 0;
    while (!stream.isEof()) {
      const chunk: ArrayBuffer = await stream.read(65536);
      if (chunk.byteLength === 0) { break; }
      chunks.push(chunk);
      total += chunk.byteLength;
    }
    if (total === 0) { return undefined; }
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
    if (upper === 'POST') { return http.RequestMethod.POST; }
    if (upper === 'PUT') { return http.RequestMethod.PUT; }
    if (upper === 'DELETE') { return http.RequestMethod.DELETE; }
    if (upper === 'PATCH') { return http.RequestMethod.PATCH; }
    if (upper === 'HEAD') { return http.RequestMethod.HEAD; }
    return http.RequestMethod.GET;
  }

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

  private static copyResponseHeaders(out: webview.WebSchemeHandlerResponse, header: Object): void {
    const names: string[] = ['cache-control', 'etag', 'last-modified', 'content-disposition'];
    const record: Record<string, Object> = header as Record<string, Object>;
    const keys: string[] = Object.keys(record);
    for (const key of keys) {
      if (names.indexOf(key.toLowerCase()) < 0) { continue; }
      const raw: Object = record[key];
      if (raw !== null && raw !== undefined) {
        out.setHeaderByName(key, `${raw}`, true);
      }
    }
  }
}
