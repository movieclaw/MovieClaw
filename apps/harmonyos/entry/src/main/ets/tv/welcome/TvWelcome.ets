/**
 * TV 欢迎流程（US1）：局域网发现 / 手动地址 → 登录（密码 / 配对码 + 二维码）→ 记住账号。
 *
 * 发现协议（逐项对齐 Android TV 端 ServerDiscovery.kt / docs/design/lan-discovery.md）：
 * - 后端监听 UDP 7359，收到「who is MovieClawServer?」单播回
 *   `{"type":"movieclaw.discovery","name","addresses":[...]}`；
 * - 兼容旧服务器再问一句「who is JellyfinServer?」（回 `{"Address","Name","Id"}`）；
 * - 逐个单播扫本机所在 /24（Docker 桥接下发广播进不了容器，单播能经端口映射转进去）；
 * - 应答地址不一定可用（容器内网 IP / 公网域名），逐个试 `/api/v1/health`，
 *   第一个 status === 'ok' 的才算 MovieClaw——顺带排除局域网里真正的 Jellyfin。
 *
 * 配对登录：authDeviceAuthorize 取配对码 → 屏显大号配对码 + ScanKit 生成二维码 →
 * 轮询 authDeviceToken 兑换令牌 → authMe 补全身份 → TokenVault 落库 → switchAccount 激活。
 */
import { connection, socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { generateBarcode, scanCore } from '@kit.ScanKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { AppModel, SignInResult } from '../../common/AppModel';
import { ApiClient } from '../../api/ApiClient';
import { MovieClawApi } from '../../api/Endpoints';
import {
  DeviceAuthorizeRequest,
  DeviceAuthorizeView,
  DeviceTokenRequest,
  DeviceTokenView,
  HealthResponse,
  SessionView
} from '../../api/Models';
import { ServerAddress } from '../../common/ServerAddress';
import { TokenVault } from '../../common/TokenVault';
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';
import { TvType } from '../theme/TvTheme';
import { TvFocusable } from '../components/TvFocusable';
import {
  TvDiscoveredServer,
  TvDiscoveryState,
  TvUiState
} from '../model/TvUiState';

/** 发现应答的原始 JSON 形状（自家协议 + Jellyfin 兼容两个字段集） */
class TvDiscoveryPayload {
  type?: string;
  name?: string;
  addresses?: string[];
  Address?: string;
  Name?: string;
}

/** 一条发现应答（自家协议 native=true 排前） */
class TvDiscoveryReply {
  readonly addresses: string[];
  readonly name: string;
  readonly source: string;
  readonly native: boolean;

  constructor(addresses: string[], name: string, source: string, native: boolean) {
    this.addresses = addresses;
    this.name = name;
    this.source = source;
    this.native = native;
  }
}

/** 局域网发现引擎（纯逻辑，无 UI） */
class TvServerDiscovery {
  static readonly port: number = 7359;
  static readonly defaultPort: number = 3000;
  static readonly query: string = 'who is MovieClawServer?';
  static readonly legacyQuery: string = 'who is JellyfinServer?';
  static readonly maxHosts: number = 1024;

  /** 主入口：扫描 rounds 轮，每确认一台就更新 state.servers；返回全部找到的 */
  static async discover(state: TvDiscoveryState, rounds: number): Promise<TvDiscoveredServer[]> {
    state.scanning = true;
    state.message = '正在扫描局域网…';
    const found: TvDiscoveredServer[] = [];
    try {
      const hosts: number[] = await TvServerDiscovery.localHosts();
      if (hosts.length === 0) {
        state.message = '本机不在局域网里（或拿不到网段），请手动输入服务器地址';
        return found;
      }
      for (let round: number = 0; round < rounds; round++) {
        const replies: TvDiscoveryReply[] = await TvServerDiscovery.sweep(hosts);
        for (const reply of TvServerDiscovery.merged(replies)) {
          const origin: string | null = await TvServerDiscovery.confirm(reply);
          if (origin === null) {
            continue;
          }
          let seen: boolean = false;
          for (const existing of found) {
            if (existing.origin === origin) {
              seen = true;
              break;
            }
          }
          if (!seen) {
            found.push(new TvDiscoveredServer(origin, reply.name));
            state.servers = found.slice();
          }
        }
        if (found.length > 0) {
          break;
        }
        if (round < rounds - 1) {
          await TvServerDiscovery.sleep(1500);
        }
      }
      state.message = found.length > 0 ? null : '局域网里没找到服务器，请手动输入地址';
    } catch (error) {
      state.message = `扫描失败：${error}`;
    } finally {
      state.scanning = false;
    }
    return found;
  }

  /** 手动输入的地址补全协议/端口：没写协议与端口时依次试 http://host:3000、http://host、https://host */
  static async settleManual(input: string): Promise<ServerAddress> {
    const address: ServerAddress = ServerAddress.parse(input);
    const trimmed: string = input.trim();
    if (trimmed.includes('://') || TvServerDiscovery.explicitPort(trimmed) !== null) {
      return address;
    }
    const host: string = address.hostLabel;
    const candidates: string[] = [`http://${host}:${TvServerDiscovery.defaultPort}`, `http://${host}`, `https://${host}`];
    for (const candidate of candidates) {
      if (await TvServerDiscovery.isMovieClaw(candidate)) {
        return ServerAddress.parse(candidate);
      }
    }
    return address;
  }

  /** 解析一条应答报文；不是发现应答返回 null */
  static parseReply(text: string, source: string): TvDiscoveryReply | null {
    let payload: TvDiscoveryPayload;
    try {
      payload = JSON.parse(text) as TvDiscoveryPayload;
    } catch (error) {
      return null;
    }
    if (payload.type === 'movieclaw.discovery') {
      const addresses: string[] = [];
      if (payload.addresses !== undefined && payload.addresses !== null) {
        for (const item of payload.addresses) {
          if (typeof item === 'string' && item.length > 0) {
            addresses.push(item);
          }
        }
      }
      const name: string = typeof payload.name === 'string' && payload.name.length > 0 ? payload.name : 'MovieClaw';
      return new TvDiscoveryReply(addresses, name, source, true);
    }
    if (typeof payload.Address === 'string' && payload.Address.length > 0) {
      const name: string = typeof payload.Name === 'string' && payload.Name.length > 0 ? payload.Name : 'MovieClaw';
      return new TvDiscoveryReply([payload.Address], name, source, false);
    }
    return null;
  }

  /** 同一来源 IP 的应答合并成一条（自家应答的地址与名字在前） */
  static merged(replies: TvDiscoveryReply[]): TvDiscoveryReply[] {
    const order: string[] = [];
    const groups: Map<string, TvDiscoveryReply[]> = new Map<string, TvDiscoveryReply[]>();
    for (const reply of replies) {
      let group: TvDiscoveryReply[] | undefined = groups.get(reply.source);
      if (group === undefined) {
        group = [];
        groups.set(reply.source, group);
        order.push(reply.source);
      }
      group.push(reply);
    }
    const out: TvDiscoveryReply[] = [];
    for (const source of order) {
      const group: TvDiscoveryReply[] = groups.get(source) ?? [];
      const native: TvDiscoveryReply[] = [];
      const legacy: TvDiscoveryReply[] = [];
      for (const reply of group) {
        if (reply.native) {
          native.push(reply);
        } else {
          legacy.push(reply);
        }
      }
      const ordered: TvDiscoveryReply[] = native.concat(legacy);
      const addresses: string[] = [];
      for (const reply of ordered) {
        for (const address of reply.addresses) {
          if (addresses.indexOf(address) < 0) {
            addresses.push(address);
          }
        }
      }
      const first: TvDiscoveryReply | undefined = ordered[0];
      out.push(new TvDiscoveryReply(addresses,
        first === undefined ? 'MovieClaw' : first.name, source, first === undefined ? false : first.native));
    }
    return out;
  }

  /** 本机所在的私有网段（RFC1918）要问的全部主机（最多 1024 个） */
  private static async localHosts(): Promise<number[]> {
    let properties: connection.ConnectionProperties | null = null;
    try {
      const netHandle: connection.NetHandle = await connection.getDefaultNet();
      properties = await connection.getConnectionProperties(netHandle);
    } catch (error) {
      return [];
    }
    if (properties === null) {
      return [];
    }
    const hosts: number[] = [];
    for (const link of properties.linkAddresses) {
      const raw: string = link.address.address;
      const prefix: number = link.prefixLength;
      const ip: number | null = TvServerDiscovery.ipToNumber(raw);
      if (ip === null || !TvServerDiscovery.isPrivate(ip)) {
        continue;
      }
      const subnet: number[] = TvServerDiscovery.subnetHosts(ip, prefix);
      for (const host of subnet) {
        if (hosts.indexOf(host) < 0 && hosts.length < TvServerDiscovery.maxHosts) {
          hosts.push(host);
        }
      }
    }
    return hosts;
  }

  /** 对每个地址发两句询问，收 1.2 秒应答 */
  private static async sweep(hosts: number[]): Promise<TvDiscoveryReply[]> {
    const replies: TvDiscoveryReply[] = [];
    if (hosts.length === 0) {
      return replies;
    }
    const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    try {
      await udp.bind({ address: '0.0.0.0', port: 0 });
      udp.on('message', (info: socket.SocketMessageInfo): void => {
        const text: string = decoder.decodeToString(new Uint8Array(info.message));
        const reply: TvDiscoveryReply | null = TvServerDiscovery.parseReply(text, info.remoteInfo.address);
        if (reply === null) {
          return;
        }
        for (const existing of replies) {
          if (existing.source === reply.source && existing.native === reply.native
            && existing.addresses.length === reply.addresses.length) {
            return;
          }
        }
        replies.push(reply);
      });
      for (let index: number = 0; index < hosts.length; index++) {
        const host: string = TvServerDiscovery.numberToIp(hosts[index]);
        const target: socket.NetAddress = { address: host, port: TvServerDiscovery.port };
        try {
          await udp.send({ data: TvServerDiscovery.query, address: target });
          await udp.send({ data: TvServerDiscovery.legacyQuery, address: target });
        } catch (error) {
          // 主机不可达：单播发不出去就跳过这台
        }
        if (index % 16 === 15) {
          await TvServerDiscovery.sleep(2);
        }
      }
      await TvServerDiscovery.sleep(1200);
    } catch (error) {
      // 整轮失败：按无应答处理
    } finally {
      try {
        udp.off('message');
        await udp.close();
      } catch (error) {
      }
    }
    return replies;
  }

  /** 应答候选里第一个健康检查通过（status=ok）的 origin；都不是返回 null */
  private static async confirm(reply: TvDiscoveryReply): Promise<string | null> {
    const candidates: string[] = [];
    for (const raw of reply.addresses) {
      try {
        const parsed: ServerAddress = ServerAddress.parse(raw);
        if (candidates.indexOf(parsed.origin) < 0) {
          candidates.push(parsed.origin);
        }
      } catch (error) {
        // 应答里的地址不合法（容器内网 IP 等）：靠来源 IP 拼
      }
      const port: number | null = TvServerDiscovery.explicitPort(raw);
      const fromSource: string = `http://${reply.source}:${port === null ? TvServerDiscovery.defaultPort : port}`;
      if (candidates.indexOf(fromSource) < 0) {
        candidates.push(fromSource);
      }
    }
    if (reply.addresses.length === 0) {
      const fallback: string = `http://${reply.source}:${TvServerDiscovery.defaultPort}`;
      candidates.push(fallback);
    }
    for (const candidate of candidates) {
      if (await TvServerDiscovery.isMovieClaw(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  /** `GET /api/v1/health` 短超时探测，status === 'ok' 才算 MovieClaw */
  private static async isMovieClaw(origin: string): Promise<boolean> {
    try {
      const client: ApiClient = new ApiClient(origin, null);
      const health: HealthResponse = await client.rawGet<HealthResponse>('/health', 2500);
      return health.status === 'ok';
    } catch (error) {
      return false;
    }
  }

  /** 地址串里显式写的端口（没写返回 null） */
  static explicitPort(raw: string): number | null {
    const authority: string = raw.includes('://') ? raw.split('://')[1] : raw;
    const hostPort: string = authority.split('/')[0].split('?')[0];
    const parts: string[] = hostPort.split(':');
    if (parts.length < 2) {
      return null;
    }
    const port: number = Number(parts[parts.length - 1]);
    return Number.isInteger(port) && port > 0 && port < 65536 ? port : null;
  }

  /** 点分 IPv4 → 数值；不是合法 IPv4 返回 null */
  static ipToNumber(raw: string): number | null {
    const parts: string[] = raw.split('.');
    if (parts.length !== 4) {
      return null;
    }
    let value: number = 0;
    for (const part of parts) {
      const octet: number = Number(part);
      if (!Number.isInteger(octet) || octet < 0 || octet > 255) {
        return null;
      }
      value = ((value << 8) | octet) >>> 0;
    }
    return value >>> 0;
  }

  static numberToIp(value: number): string {
    return `${(value >>> 24) & 0xFF}.${(value >>> 16) & 0xFF}.${(value >>> 8) & 0xFF}.${value & 0xFF}`;
  }

  /** RFC1918 私有网段 */
  static isPrivate(ip: number): boolean {
    return (ip >>> 24) === 10 || (ip >>> 20) === 0xAC1 || (ip >>> 16) === 0xC0A8;
  }

  /** 某地址所在 /24 里要问的主机（1..254；掩码更宽也只扫本机所在的 /24） */
  static subnetHosts(ip: number, prefixLength: number): number[] {
    const netmask: number = prefixLength <= 0 ? 0 : (0xFFFFFFFF << (32 - Math.min(prefixLength, 32))) >>> 0;
    const mask: number = (netmask | 0xFFFFFF00) >>> 0;
    const network: number = (ip & mask) >>> 0;
    const broadcast: number = (network | ((~mask) >>> 0)) >>> 0;
    const hosts: number[] = [];
    for (let host: number = network + 1; host < broadcast; host++) {
      hosts.push(host);
    }
    return hosts;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: (value: void) => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }
}

/** 欢迎页的子模式 */
class TvWelcomeMode {
  static readonly discover: string = 'discover';
  static readonly manual: string = 'manual';
  static readonly login: string = 'login';
  static readonly pairing: string = 'pairing';
  static readonly setup: string = 'setup';
}

/**
 * 二维码内容 + 配对码。
 * @ObservedV2：字段是在异步回调里陆续填进来的（先切到配对页、再拿码、再生二维码），
 * 普通类字段赋值得不到通知，页面会停在空白配对码/白方块上。
 */
@ObservedV2
class TvPairingDisplay {
  @Trace userCode: string = '';
  @Trace verifyUrl: string = '';
  @Trace qrPixelMap: image.PixelMap | null = null;
  /** idle=还没开始 loading=生成中 ready=有图 failed=本机生成不了（模拟器等） */
  @Trace qrState: string = 'idle';
}

@ComponentV2
export struct TvWelcome {
  /** 非空 = 本机已有当前服务器（needsLogin/needsSetup），跳过发现直接落登录表单 */
  @Param resumeOrigin: string = '';
  /** 登录过期的账号用户名（预填） */
  @Param resumeUsername: string = '';
  @Local mode: string = TvWelcomeMode.discover;
  @Local discovery: TvDiscoveryState = new TvDiscoveryState();
  /** 选中的服务器 */
  @Local origin: string = '';
  @Local serverName: string = '';
  /** 手动输入 */
  @Local manualInput: string = '';
  /** 登录表单 */
  @Local username: string = '';
  @Local password: string = '';
  /** 初始化（needsSetup）表单 */
  @Local setupUsername: string = '';
  @Local setupPassword: string = '';
  /** 配对展示 */
  @Local pairing: TvPairingDisplay = new TvPairingDisplay();
  @Local busy: boolean = false;
  @Local message: string | null = null;
  private deviceCode: string = '';
  private pollTimer: number = -1;
  private pollGeneration: number = 0;

  aboutToAppear(): void {
    if (this.resumeOrigin.length > 0) {
      // 令牌失效 / 服务器已初始化但本机没登录：直接落登录表单，预填用户名
      this.origin = this.resumeOrigin;
      this.serverName = ServerAddress.parse(this.resumeOrigin).hostLabel;
      this.username = this.resumeUsername;
      this.message = this.resumeUsername.length > 0 ? '登录已过期，请重新输入密码' : null;
      this.mode = TvWelcomeMode.login;
      return;
    }
    this.startDiscovery();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  private startDiscovery(): void {
    this.mode = TvWelcomeMode.discover;
    TvServerDiscovery.discover(this.discovery, 3);
  }

  private pickServer(server: TvDiscoveredServer): void {
    this.origin = server.origin;
    this.serverName = server.name;
    this.username = '';
    this.password = '';
    this.message = null;
    this.mode = TvWelcomeMode.login;
  }

  private async connectManual(): Promise<void> {
    if (this.busy || this.manualInput.trim().length === 0) {
      return;
    }
    this.busy = true;
    this.message = '正在连接…';
    try {
      const address: ServerAddress = await TvServerDiscovery.settleManual(this.manualInput);
      this.origin = address.origin;
      this.serverName = address.hostLabel;
      this.username = '';
      this.password = '';
      this.message = null;
      this.mode = TvWelcomeMode.login;
    } catch (error) {
      this.message = `${error}`;
    } finally {
      this.busy = false;
    }
  }

  private async signInWithPassword(): Promise<void> {
    if (this.busy || this.username.length === 0 || this.password.length === 0) {
      return;
    }
    this.busy = true;
    this.message = '正在登录…';
    try {
      const result: string = await AppModel.shared.signIn(this.origin, this.username, this.password);
      if (result === SignInResult.needsSetup) {
        this.setupUsername = this.username;
        this.setupPassword = '';
        this.message = '这是一台全新的服务器，先创建管理员账号';
        this.mode = TvWelcomeMode.setup;
      }
    } catch (error) {
      this.message = `${error}`;
    } finally {
      this.busy = false;
    }
  }

  private async createAdmin(): Promise<void> {
    if (this.busy || this.setupUsername.length === 0 || this.setupPassword.length === 0) {
      return;
    }
    this.busy = true;
    this.message = '正在初始化服务器…';
    try {
      await AppModel.shared.createAdmin(this.origin, this.setupUsername, this.setupPassword);
    } catch (error) {
      this.message = `${error}`;
    } finally {
      this.busy = false;
    }
  }

  /** 进入配对模式：取配对码、生成二维码、开始轮询 */
  private async startPairing(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.message = null;
    this.mode = TvWelcomeMode.pairing;
    try {
      const client: ApiClient = new ApiClient(this.origin, null);
      const installationId: string = await this.ensureInstallationId();
      const request: DeviceAuthorizeRequest = {
        client_type: 'androidtv',
        client_name: `${deviceInfo.productModel}·智慧屏`,
        installation_id: installationId,
        platform: `HarmonyOS ${deviceInfo.osFullName}`,
        client_version: '0.1.0'
      };
      const view: DeviceAuthorizeView = await new MovieClawApi(client).authDeviceAuthorize(request);
      this.deviceCode = view.device_code;
      this.pairing.userCode = view.user_code;
      this.pairing.verifyUrl = view.verification_uri_complete;
      await this.renderQr(view.verification_uri_complete);
      this.schedulePoll(view.interval * 1000, view.expires_in * 1000);
    } catch (error) {
      this.message = `配对请求失败：${error}`;
      this.mode = TvWelcomeMode.login;
    } finally {
      this.busy = false;
    }
  }

  private async ensureInstallationId(): Promise<string> {
    let existing: string = await TvUiState.shared.cachedString('tv.installation_id', '');
    if (existing.length === 0) {
      existing = util.generateRandomUUID(false);
      TvUiState.shared.saveString('tv.installation_id', existing);
    }
    return existing;
  }

  private async renderQr(content: string): Promise<void> {
    this.pairing.qrState = 'loading';
    try {
      this.pairing.qrPixelMap = await generateBarcode.createBarcode(content, {
        scanType: scanCore.ScanType.QR_CODE,
        width: 320,
        height: 320,
        margin: 2
      });
      this.pairing.qrState = this.pairing.qrPixelMap !== null ? 'ready' : 'failed';
    } catch (error) {
      // 模拟器/不支持码图生成的设备会抛错（日志：device type is emulator）。
      // 不再画白方块：交给页面显示「用浏览器打开地址输码」的兜底。
      hilog.warn(0x0000, 'TvPairing', '二维码生成失败：%{public}s', `${error}`);
      this.pairing.qrPixelMap = null;
      this.pairing.qrState = 'failed';
    }
  }

  private schedulePoll(intervalMs: number, expiresMs: number): void {
    this.stopPolling();
    const generation: number = this.pollGeneration;
    this.pollTimer = setTimeout((): void => {
      if (generation !== this.pollGeneration) {
        return;
      }
      this.pollOnce(Math.max(intervalMs, 2000), expiresMs - Math.max(intervalMs, 2000));
    }, Math.max(intervalMs, 2000));
  }

  private async pollOnce(intervalMs: number, remainsMs: number): Promise<void> {
    if (remainsMs <= 0) {
      this.message = '配对码已过期，请重新发起配对';
      this.mode = TvWelcomeMode.login;
      return;
    }
    try {
      const client: ApiClient = new ApiClient(this.origin, null);
      const request: DeviceTokenRequest = { device_code: this.deviceCode };
      const view: DeviceTokenView | null = await new MovieClawApi(client).authDeviceToken(request);
      if (view !== null) {
        await this.adoptPairedToken(view.token);
        return;
      }
    } catch (error) {
      this.message = `配对失败：${error}`;
      this.mode = TvWelcomeMode.login;
      return;
    }
    this.schedulePoll(intervalMs, remainsMs);
  }

  /** 兑换成功：authMe 补全身份 → 令牌落钥匙串 → switchAccount 激活（phase → ready） */
  private async adoptPairedToken(token: string): Promise<void> {
    try {
      const client: ApiClient = new ApiClient(this.origin, token);
      const me: SessionView = await new MovieClawApi(client).authMe();
      await TokenVault.save(token, this.origin, me.username);
      await AppModel.shared.switchAccount(me.username, ServerAddress.trusted(this.origin));
    } catch (error) {
      this.message = `激活配对令牌失败：${error}`;
      this.mode = TvWelcomeMode.login;
    }
  }

  private stopPolling(): void {
    this.pollGeneration += 1;
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private backOneStep(): void {
    this.stopPolling();
    this.message = null;
    if (this.mode === TvWelcomeMode.manual || this.mode === TvWelcomeMode.login
      || this.mode === TvWelcomeMode.setup) {
      this.mode = TvWelcomeMode.discover;
      return;
    }
    if (this.mode === TvWelcomeMode.pairing) {
      this.mode = TvWelcomeMode.login;
    }
  }

  build() {
    Column() {
      if (this.mode === TvWelcomeMode.discover) {
        this.discoverBody()
      } else if (this.mode === TvWelcomeMode.manual) {
        this.manualBody()
      } else if (this.mode === TvWelcomeMode.login) {
        this.loginBody()
      } else if (this.mode === TvWelcomeMode.pairing) {
        this.pairingBody()
      } else {
        this.setupBody()
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(TvColors.bg)
    .padding(TvMetrics.edge)
  }

  @Builder
  private discoverBody(): void {
    Column({ space: TvMetrics.cardGap }) {
      Text('连接到 MovieClaw')
        .fontSize(TvType.welcomeTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(TvColors.text)
      if (this.discovery.scanning) {
        Row({ space: 12 }) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(TvColors.textMuted)
          Text(this.discovery.message ?? '正在扫描局域网…')
            .fontSize(TvType.footnote)
            .fontColor(TvColors.textMuted)
        }
      } else if (this.discovery.message !== null) {
        Text(this.discovery.message)
          .fontSize(TvType.footnote)
          .fontColor(TvColors.textMuted)
      }
      if (this.discovery.servers.length > 0) {
        Column({ space: 12 }) {
          ForEach(this.discovery.servers, (server: TvDiscoveredServer) => {
            TvFocusable({
              focusScale: 1.04,
              cornerRadius: TvMetrics.cardCorner,
              onActivate: (): void => {
                this.pickServer(server);
              }
            }) {
              Column({ space: 4 }) {
                Text(server.name)
                  .fontSize(TvType.body)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(TvColors.text)
                Text(ServerAddress.parse(server.origin).hostLabel)
                  .fontSize(TvType.footnote)
                  .fontColor(TvColors.textMuted)
              }
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 24, right: 24, top: 16, bottom: 16 })
              .backgroundColor(TvColors.surfaceRaised)
              .borderRadius(TvMetrics.cardCorner)
              .constraintSize({ minWidth: 360 })
            }
          }, (server: TvDiscoveredServer): string => server.origin)
        }
      }
      Row({ space: TvMetrics.cardGap }) {
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.manualInput = '';
            this.message = null;
            this.mode = TvWelcomeMode.manual;
          }
        }) {
          Text('手动输入地址')
            .fontSize(TvType.body)
            .fontColor(TvColors.text)
            .padding({ left: 28, right: 28, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFillHover)
            .borderRadius(999)
        }
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.startDiscovery();
          }
        }) {
          Text('重新扫描')
            .fontSize(TvType.body)
            .fontColor(TvColors.textMuted)
            .padding({ left: 28, right: 28, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFill)
            .borderRadius(999)
        }
      }
      this.noticeLine()
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private manualBody(): void {
    Column({ space: TvMetrics.cardGap }) {
      Text('输入服务器地址')
        .fontSize(TvType.heroTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(TvColors.text)
      Text('示例：http://192.168.0.100:3000（只写主机时会自动试 3000 端口）')
        .fontSize(TvType.footnote)
        .fontColor(TvColors.textMuted)
      TextInput({ placeholder: 'http://192.168.0.100:3000', text: this.manualInput })
        .width(520)
        .height(56)
        .fontSize(TvType.body)
        .fontColor(TvColors.text)
        .placeholderColor(TvColors.textFaint)
        .backgroundColor(TvColors.surfaceRaised)
        .borderRadius(TvMetrics.cardCorner)
        .onChange((value: string) => {
          this.manualInput = value;
        })
        .onSubmit(() => {
          this.connectManual();
        })
      Row({ space: TvMetrics.cardGap }) {
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.connectManual();
          }
        }) {
          Text(this.busy ? '连接中…' : '连接')
            .fontSize(TvType.body)
            .fontColor(TvColors.text)
            .padding({ left: 32, right: 32, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFillHover)
            .borderRadius(999)
        }
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.backOneStep();
          }
        }) {
          Text('返回')
            .fontSize(TvType.body)
            .fontColor(TvColors.textMuted)
            .padding({ left: 28, right: 28, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFill)
            .borderRadius(999)
        }
      }
      this.noticeLine()
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private loginBody(): void {
    Column({ space: TvMetrics.cardGap }) {
      Text(this.serverName.length > 0 ? this.serverName : '登录')
        .fontSize(TvType.heroTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(TvColors.text)
      Text(ServerAddress.parse(this.origin).displayString)
        .fontSize(TvType.footnote)
        .fontColor(TvColors.textMuted)
      TextInput({ placeholder: '用户名', text: this.username })
        .width(520)
        .height(56)
        .fontSize(TvType.body)
        .fontColor(TvColors.text)
        .placeholderColor(TvColors.textFaint)
        .backgroundColor(TvColors.surfaceRaised)
        .borderRadius(TvMetrics.cardCorner)
        .onChange((value: string) => {
          this.username = value;
        })
      TextInput({ placeholder: '密码', text: this.password })
        .width(520)
        .height(56)
        .fontSize(TvType.body)
        .fontColor(TvColors.text)
        .placeholderColor(TvColors.textFaint)
        .backgroundColor(TvColors.surfaceRaised)
        .borderRadius(TvMetrics.cardCorner)
        .type(InputType.Password)
        .onChange((value: string) => {
          this.password = value;
        })
        .onSubmit(() => {
          this.signInWithPassword();
        })
      Row({ space: TvMetrics.cardGap }) {
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.signInWithPassword();
          }
        }) {
          Text(this.busy ? '登录中…' : '登录')
            .fontSize(TvType.body)
            .fontColor(TvColors.text)
            .padding({ left: 32, right: 32, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFillHover)
            .borderRadius(999)
        }
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.startPairing();
          }
        }) {
          Text('改用配对码登录')
            .fontSize(TvType.body)
            .fontColor(TvColors.textMuted)
            .padding({ left: 28, right: 28, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFill)
            .borderRadius(999)
        }
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.backOneStep();
          }
        }) {
          Text('返回')
            .fontSize(TvType.body)
            .fontColor(TvColors.textMuted)
            .padding({ left: 28, right: 28, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFill)
            .borderRadius(999)
        }
      }
      this.noticeLine()
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private pairingBody(): void {
    Column({ space: 26 }) {
      Text('设备配对')
        .fontSize(TvType.heroTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(TvColors.text)
      Text(this.pairing.qrState === 'ready'
        ? '用手机浏览器扫码，或在浏览器打开下方地址输入配对码'
        : '用手机或电脑浏览器打开下方地址，输入配对码批准这台电视')
        .fontSize(TvType.body)
        .fontColor(TvColors.textMuted)
        .textAlign(TextAlign.Center)

      Row({ space: 56 }) {
        Column({ space: 20 }) {
          Text(this.pairing.userCode)
            .fontSize(64)
            .fontWeight(FontWeight.Bold)
            .fontColor(TvColors.text)
            .letterSpacing(6)
          Text(this.pairing.verifyUrl)
            .fontSize(TvType.footnote)
            .fontColor(TvColors.textMuted)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 10 }) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color(TvColors.textMuted)
            Text('等待批准中…')
              .fontSize(TvType.footnote)
              .fontColor(TvColors.textFaint)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width(520)

        this.QrPanel()
      }
      .alignItems(VerticalAlign.Center)

      TvFocusable({
        focusScale: 1.04,
        cornerRadius: 999,
        onActivate: (): void => {
          this.backOneStep();
        }
      }) {
        Text('取消配对')
          .fontSize(TvType.body)
          .fontColor(TvColors.textMuted)
          .padding({ left: 28, right: 28, top: 14, bottom: 14 })
          .backgroundColor(TvColors.glassFill)
          .borderRadius(999)
      }
      this.noticeLine()
    }
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 二维码位：ready 出图；loading 出转圈；failed（模拟器等生成不了码图）
   * 出一张说明卡——不要留一个扫码也扫不出来的白方块。
   */
  @Builder
  private QrPanel(): void {
    if (this.pairing.qrState === 'ready' && this.pairing.qrPixelMap !== null) {
      Image(this.pairing.qrPixelMap)
        .width(220)
        .height(220)
        .objectFit(ImageFit.Contain)
        .interpolation(ImageInterpolation.None)
        .backgroundColor(Color.White)
        .padding(8)
        .borderRadius(12)
    } else if (this.pairing.qrState === 'failed') {
      Column({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.qrcode'))
          .fontSize(40)
          .fontColor([TvColors.textMuted])
        Text('本机无法生成二维码')
          .fontSize(TvType.cardCaption)
          .fontWeight(FontWeight.Medium)
          .fontColor(TvColors.text)
        Text('请用浏览器打开左侧地址，输入配对码批准')
          .fontSize(13)
          .fontColor(TvColors.textMuted)
          .textAlign(TextAlign.Center)
          .maxLines(3)
      }
      .width(220)
      .height(220)
      .justifyContent(FlexAlign.Center)
      .padding(16)
      .backgroundColor(TvColors.glassFill)
      .border({ width: 1, color: TvColors.line })
      .borderRadius(12)
    } else {
      Column({ space: 12 }) {
        LoadingProgress()
          .width(32)
          .height(32)
          .color(TvColors.textMuted)
        Text('正在生成二维码…')
          .fontSize(13)
          .fontColor(TvColors.textFaint)
      }
      .width(220)
      .height(220)
      .justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  private setupBody(): void {
    Column({ space: TvMetrics.cardGap }) {
      Text('初始化服务器')
        .fontSize(TvType.heroTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(TvColors.text)
      Text('这台服务器还是全新的，先创建一个管理员账号')
        .fontSize(TvType.footnote)
        .fontColor(TvColors.textMuted)
      TextInput({ placeholder: '管理员用户名', text: this.setupUsername })
        .width(520)
        .height(56)
        .fontSize(TvType.body)
        .fontColor(TvColors.text)
        .placeholderColor(TvColors.textFaint)
        .backgroundColor(TvColors.surfaceRaised)
        .borderRadius(TvMetrics.cardCorner)
        .onChange((value: string) => {
          this.setupUsername = value;
        })
      TextInput({ placeholder: '设置密码', text: this.setupPassword })
        .width(520)
        .height(56)
        .fontSize(TvType.body)
        .fontColor(TvColors.text)
        .placeholderColor(TvColors.textFaint)
        .backgroundColor(TvColors.surfaceRaised)
        .borderRadius(TvMetrics.cardCorner)
        .type(InputType.Password)
        .onChange((value: string) => {
          this.setupPassword = value;
        })
        .onSubmit(() => {
          this.createAdmin();
        })
      Row({ space: TvMetrics.cardGap }) {
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.createAdmin();
          }
        }) {
          Text(this.busy ? '创建中…' : '创建并进入')
            .fontSize(TvType.body)
            .fontColor(TvColors.text)
            .padding({ left: 32, right: 32, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFillHover)
            .borderRadius(999)
        }
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.backOneStep();
          }
        }) {
          Text('返回')
            .fontSize(TvType.body)
            .fontColor(TvColors.textMuted)
            .padding({ left: 28, right: 28, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFill)
            .borderRadius(999)
        }
      }
      this.noticeLine()
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private noticeLine(): void {
    if (this.message !== null) {
      Text(this.message)
        .fontSize(TvType.footnote)
        .fontColor(TvColors.warn)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }
}
