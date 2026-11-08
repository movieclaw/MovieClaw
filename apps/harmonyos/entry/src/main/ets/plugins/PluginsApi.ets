import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { ApiClient } from '../api/ApiClient';
import { AppModel } from '../common/AppModel';
import { PackageResultView } from '../api/Models';

/**
 * 插件页的数据接口（对应 Web `lib/api/plugins.ts`）。
 *
 * `api/Endpoints.ets` 是从 iOS 端自动转译的，里面没有插件市场、插件包上传，
 * 插件包的 `dependencies` / `web` / `theme` 这些较新字段也不在生成的类型里；
 * 这一层按服务端真实返回补全，调用走同一个 `ApiClient`。
 */

/** 一条路径授权：`path` 是 movieclaw 视角的别名或绝对路径，`mode` 是 read / rw */
export interface PluginPathGrant {
  path: string;
  mode: string;
}

export interface PluginOperationDetail {
  id: string;
  summary: string;
  dangerous: boolean;
}

export interface PluginPackageDependency {
  name: string;
  version: string;
  native: boolean;
  available: boolean;
  change?: string | null;
  previous_version?: string | null;
  size?: number | null;
}

export interface PluginPackageDependencies {
  lock_digest: string;
  packages: PluginPackageDependency[];
  total_size: number;
  native: string[];
  unavailable: string[];
  removed: string[];
  index: string;
  index_label: string;
  needs_consent: boolean;
}

export interface PluginDependencyProgress {
  phase: string;
  done: number;
  total: number;
  error?: string | null;
}

export interface PluginPackageEvent {
  name: string;
  title: string;
}

export interface PluginPackageNotification {
  event: string;
  title: string;
  body: string;
  audience: string;
  audience_label: string;
  reaches_members: boolean;
  default: boolean;
}

export interface PluginWebEntry {
  label: string;
  path: string;
  icon?: string | null;
  monochrome: boolean;
}

/** 待批准插件包带的网页（批准时单独同意授信运行） */
export interface PluginPendingWeb {
  id: string;
  name: string;
  base: string;
  entries: PluginWebEntry[];
}

/**
 * 一个带网页的插件（`GET /ui/apps`）：主程序用同源 iframe 加载 `base`，
 * 手机上由 `PluginWebPage` 走自定义 scheme 代理后加载。
 */
export interface PluginWebApp {
  id: string;
  name: string;
  /** 用户同意加到侧边栏 */
  nav: boolean;
  /** 网页根地址前缀，以 / 结尾（`/api/v1/plugins/<id>/web/`） */
  base: string;
  entries: PluginWebEntry[];
}

/** 待批准插件包带的网页主题（带外框组件时单独同意） */
export interface PluginPendingTheme {
  label: string;
  description: string;
  layout: string;
  glass: boolean;
  has_code: boolean;
}

/** 已上传、等待批准的插件包 */
export interface PluginPendingPackage {
  id: string;
  title: string;
  version: string;
  description: string;
  /** process：独立进程；inline：主进程里运行（须单独确认） */
  runtime: string;
  operations: string[];
  new_operations: string[];
  operation_details: PluginOperationDetail[];
  paths: PluginPathGrant[];
  new_paths: PluginPathGrant[];
  callbacks: string[];
  new_callbacks: string[];
  events: PluginPackageEvent[];
  notifications: PluginPackageNotification[];
  sensitive_events: string[];
  notifies_members: boolean;
  requires: Record<string, string>;
  installed_version?: string | null;
  replaces_builtin: boolean;
  dependencies?: PluginPackageDependencies | null;
  dependency_progress?: PluginDependencyProgress | null;
  web?: PluginPendingWeb | null;
  theme?: PluginPendingTheme | null;
  entry?: string;
}

/** 已安装的插件包 */
export interface PluginInstalledPackage {
  id: string;
  title: string;
  version: string;
  runtime: string;
  operations: string[];
  operation_details: PluginOperationDetail[];
  paths: PluginPathGrant[];
  callbacks: string[];
  previous_version?: string | null;
  bad_versions: string[];
  state: string;
  error?: string | null;
  watching: boolean;
  replaces_builtin: boolean;
  dependencies?: PluginPackageDependencies | null;
  dependency_progress?: PluginDependencyProgress | null;
}

export interface PluginPackagesOverview {
  installed: PluginInstalledPackage[];
  pending: PluginPendingPackage[];
}

/** 市场索引的来源（签名索引，安装前由服务器下载核对） */
export interface PluginMarketSource {
  url: string;
  repository?: string | null;
  generated_at?: string | null;
  signed: boolean;
  checked_at: string;
  error?: string | null;
}

export interface PluginMarketInstalled {
  version: string;
  /** package：插件包；bundled：随应用提供 */
  source: string;
  state: string;
  previous_version?: string | null;
  yanked?: string | null;
}

export interface PluginMarketVersion {
  version: string;
  prerelease: boolean;
  released_at?: string | null;
  yanked?: string | null;
  notes: string;
  runtime: string;
  web: boolean;
  size?: number | null;
  compatible: boolean;
  incompatible_reason?: string | null;
}

export interface PluginMarketItem {
  id: string;
  name: string;
  summary: string;
  description: string;
  category: string;
  icon_url?: string | null;
  latest?: string | null;
  /** 该装的那一版（能装、没撤回的最新正式版） */
  recommended?: string | null;
  installed?: PluginMarketInstalled | null;
  /** 有更新时是要升到的版本 */
  update?: string | null;
  /** 不能安装的原因 */
  blocked?: string | null;
  versions: PluginMarketVersion[];
}

export interface PluginMarketOverview {
  source: PluginMarketSource;
  plugins: PluginMarketItem[];
  updates: number;
}

/** 批准请求体（比生成模型多了依赖锁、网页与主题的同意字段） */
export class PluginApproveBody {
  version: string = '';
  operations: string[] = [];
  paths: PluginPathGrant[] = [];
  allow_inline: boolean = false;
  allow_member_notifications: boolean = false;
  /** 依赖锁文件哈希：原样交回表示同意这一份依赖 */
  dependencies: string | null = null;
  allow_web: boolean = false;
  web_nav: boolean = false;
  web_members: boolean = false;
  allow_theme: boolean = false;
}

/** 插件页数据接口 */
export class PluginsApi {
  private static client(): ApiClient | null {
    return AppModel.shared.client;
  }

  /** 已安装 / 待批准的插件包 */
  static async packages(): Promise<PluginPackagesOverview> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      return { installed: [], pending: [] };
    }
    return client.get<PluginPackagesOverview>('/app/plugins/packages');
  }

  /** 当前账号可见的插件网页（带网页的插件 + 侧边栏入口） */
  static async webApps(): Promise<PluginWebApp[]> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      return [];
    }
    return client.get<PluginWebApp[]>('/ui/apps');
  }

  /** 插件市场索引（服务器缓存，可能不是最新的） */
  static async market(): Promise<PluginMarketOverview> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      throw new Error('未连接服务器');
    }
    return client.get<PluginMarketOverview>('/app/plugins/market');
  }

  /** 立刻重新拉取市场索引（GitHub 连不上时抛错） */
  static async refreshMarket(): Promise<PluginMarketOverview> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      throw new Error('未连接服务器');
    }
    return client.post<PluginMarketOverview>('/app/plugins/market/refresh', null);
  }

  /** 从市场安装：服务器下载核对后放进待批准，返回待批准的包 */
  static async installFromMarket(id: string, version: string): Promise<PluginPendingPackage> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      throw new Error('未连接服务器');
    }
    return client.post<PluginPendingPackage>(`/app/plugins/market/${encodeURIComponent(id)}/install`,
      JSON.stringify(new MarketInstallBody(version)));
  }

  /** 批准并安装插件包：按申请授予宿主操作，当场加载 */
  static async approve(id: string, body: PluginApproveBody): Promise<PackageResultView> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      throw new Error('未连接服务器');
    }
    return client.post<PackageResultView>(`/app/plugins/packages/${encodeURIComponent(id)}/approve`,
      JSON.stringify(body));
  }

  /** 选一个插件包文件（不设后缀过滤：手机文件选择器不认识 .mcplugin，格式由服务端校验） */
  static async pickPackage(context: common.UIAbilityContext): Promise<string> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    const picked: string[] = await documentPicker.select(options);
    return picked.length > 0 ? picked[0] : '';
  }

  /**
   * 上传插件包（multipart，字段名 `file`）。
   * 上传代理读不到响应体，所以顺手解析返回的 `data.id`；解析失败也不影响——列表刷新后会看到待批准行。
   */
  static async upload(uri: string): Promise<void> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      throw new Error('未连接服务器');
    }
    const bytes: ArrayBuffer = PluginsApi.readFile(uri);
    const name: string = PluginsApi.fileName(uri);
    const url: string = `${client.origin}/api/v1/app/plugins/packages`;
    const header: Record<string, string> = {
      'Accept': 'application/json',
      'Content-Type': 'multipart/form-data'
    };
    const token: string | null = client.getToken();
    if (token !== null && token.length > 0) {
      header['Authorization'] = `Bearer ${token}`;
    }
    const cookie: string = ApiClient.cookieHeaderFor(url);
    if (cookie.length > 0) {
      header['Cookie'] = cookie;
    }
    const form: http.MultiFormData[] = [{
      name: 'file',
      contentType: 'application/octet-stream',
      remoteFileName: name,
      data: bytes
    }];
    const response: http.HttpResponse = await http.createHttp().request(url, {
      method: http.RequestMethod.POST,
      header: header,
      multiFormDataList: form,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 30000,
      readTimeout: 120000
    });
    if (response.responseCode < 200 || response.responseCode >= 300) {
      const body: string = typeof response.result === 'string' ? response.result : '';
      throw new Error(PluginsApi.errorMessage(body, response.responseCode));
    }
  }

  private static readFile(uri: string): ArrayBuffer {
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const read: number = fileIo.readSync(file.fd, buffer);
      return read >= stat.size ? buffer : buffer.slice(0, read);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 文件选择器给的 uri 最后一段就是文件名 */
  private static fileName(uri: string): string {
    const parts: string[] = uri.split('/');
    const last: string = parts.length > 0 ? parts[parts.length - 1] : 'plugin.mcplugin';
    try {
      return decodeURIComponent(last);
    } catch (error) {
      return last;
    }
  }

  /** 非 2xx 的响应体是标准信封：取 message，取不到给通用文案 */
  private static errorMessage(body: string, status: number): string {
    if (body.length > 0) {
      try {
        const payload: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
        const message: Object | undefined = payload['message'];
        if (message !== undefined && message !== null && `${message}`.length > 0) {
          return `${message}`;
        }
      } catch (error) {
        // 不是 JSON：用通用文案
      }
    }
    return `上传失败（${status}）`;
  }
}

/** 市场安装请求体 */
class MarketInstallBody {
  version: string = '';

  constructor(version: string) {
    this.version = version;
  }
}
