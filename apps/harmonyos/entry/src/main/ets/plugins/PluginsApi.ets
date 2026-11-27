import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { ApiClient } from '../api/ApiClient';
import { AppModel } from '../common/AppModel';
import { PackageResultView } from '../api/Models';

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

export interface PluginPendingWeb {
  id: string;
  name: string;
  base: string;
  entries: PluginWebEntry[];
}

export interface PluginWebApp {
  id: string;
  name: string;
  nav: boolean;
  base: string;
  entries: PluginWebEntry[];
}

export interface PluginPendingTheme {
  label: string;
  description: string;
  layout: string;
  glass: boolean;
  has_code: boolean;
}

export interface PluginPendingPackage {
  id: string;
  title: string;
  version: string;
  description: string;
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
  recommended?: string | null;
  installed?: PluginMarketInstalled | null;
  update?: string | null;
  blocked?: string | null;
  versions: PluginMarketVersion[];
}

export interface PluginMarketOverview {
  source: PluginMarketSource;
  plugins: PluginMarketItem[];
  updates: number;
}

export class PluginApproveBody {
  version: string = '';
  operations: string[] = [];
  paths: PluginPathGrant[] = [];
  allow_inline: boolean = false;
  allow_member_notifications: boolean = false;
  dependencies: string | null = null;
  allow_web: boolean = false;
  web_nav: boolean = false;
  web_members: boolean = false;
  allow_theme: boolean = false;
}

class MarketInstallBody {
  version: string = '';
  constructor(version: string) {
    this.version = version;
  }
}

export class PluginsApi {
  private static client(): ApiClient | null {
    return AppModel.shared.client;
  }

  static async packages(): Promise<PluginPackagesOverview> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      return { installed: [], pending: [] };
    }
    return client.get<PluginPackagesOverview>('/app/plugins/packages');
  }

  static async webApps(): Promise<PluginWebApp[]> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      return [];
    }
    return client.get<PluginWebApp[]>('/ui/apps');
  }

  static async market(): Promise<PluginMarketOverview> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      throw new Error('未连接服务器');
    }
    return client.get<PluginMarketOverview>('/app/plugins/market');
  }

  static async refreshMarket(): Promise<PluginMarketOverview> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      throw new Error('未连接服务器');
    }
    return client.post<PluginMarketOverview>('/app/plugins/market/refresh', null);
  }

  static async installFromMarket(id: string, version: string): Promise<PluginPendingPackage> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      throw new Error('未连接服务器');
    }
    return client.post<PluginPendingPackage>(`/app/plugins/market/${encodeURIComponent(id)}/install`,
      JSON.stringify(new MarketInstallBody(version)));
  }

  static async approve(id: string, body: PluginApproveBody): Promise<PackageResultView> {
    const client: ApiClient | null = PluginsApi.client();
    if (client === null) {
      throw new Error('未连接服务器');
    }
    return client.post<PackageResultView>(`/app/plugins/packages/${encodeURIComponent(id)}/approve`,
      JSON.stringify(body));
  }

  static async pickPackage(context: common.UIAbilityContext): Promise<string> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    const picked: string[] = await documentPicker.select(options);
    return picked.length > 0 ? picked[0] : '';
  }

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
    const req: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await req.request(url, {
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
    } finally {
      req.destroy();
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

  private static fileName(uri: string): string {
    const parts: string[] = uri.split('/');
    const last: string = parts.length > 0 ? parts[parts.length - 1] : 'plugin.mcplugin';
    try {
      return decodeURIComponent(last);
    } catch (_error) {
      return last;
    }
  }

  private static errorMessage(body: string, status: number): string {
    if (body.length > 0) {
      try {
        const payload: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
        const message: Object | undefined = payload['message'];
        if (message !== undefined && message !== null && `${message}`.length > 0) {
          return `${message}`;
        }
      } catch (_error) {
      }
    }
    return `上传失败（${status}）`;
  }
}
