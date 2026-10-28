import { http, connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { MovieClawApi } from '../api/Endpoints';
import { ServerAddressesView } from '../api/Models';
import { DevConfig } from './DevConfig';

/**
 * 内外双地址自动选连（对应 iOS `ServerRoutes`，docs/design/server-addresses.md）：
 * 登录地址只是这台服务器在这台设备上的**身份锚点**，真正发请求的地址按网络现场选。
 *
 * - 地址簿来自 `GET /server/addresses`（登录后拉一次，按登录地址缓存；旧服务器没有就只有登录地址）。
 * - 身份锚 = 登录地址的 `/api/v1/health` 实例号：每个候选地址探活时必须回报**同一个实例号**
 *   才算同一台服务器（iOS 还有 Ed25519 proof，鸿蒙版用实例号匹配，够拦地址簿里的错地址）。
 * - 内网先探、外网晚 250ms，先通过校验的先用。
 * - 只有蜂窝时不试内网（省流量的同时避免运营商 NAT 里探内网地址）。
 * - 选过的结论落盘：冷启动先用上次的地址，后台再核实（iOS 同款）。
 *
 * 选路结果通过 `onRouteChange` 通知 AppModel 重建客户端（令牌不变，只换 origin）；
 * 图片与流地址由 `AppModel.origin()` 统一取当前路由，调用方不用关心。
 */
@ObservedV2
export class ServerRoutes {
  private static instance: ServerRoutes | null = null;
  private static readonly storeName: string = 'movieclaw_routes';
  /** 探活超时：内网地址不可达时 2.5 秒足够判死（iOS 同量级） */
  private static readonly probeTimeoutMs: number = 2500;
  /** 外网候选比内网晚这么多毫秒才起跑（iOS 同款） */
  private static readonly wanDelayMs: number = 250;

  static shared(): ServerRoutes {
    if (ServerRoutes.instance === null) {
      ServerRoutes.instance = new ServerRoutes();
    }
    return ServerRoutes.instance;
  }

  /** 登录地址（身份锚点；地址簿里没有可用项时也永远是兜底） */
  @Trace loginOrigin: string = '';
  /** 当前路由（空 = 未配置/还在探，用登录地址） */
  @Trace current: string = '';
  /** 当前路由类别：lan / wan / login（请求头 X-MovieClaw-Route 用，同 iOS） */
  @Trace kind: string = 'login';
  /** 「我的」页展示用：内网 · 主机 / 外网 · 主机（空 = 未配置） */
  @Trace routeLabel: string = '';

  /** 候选地址（lan 在前）；来自服务端地址簿 + 登录地址兜底 */
  private lanOrigins: string[] = [];
  private wanOrigins: string[] = [];
  /** 身份锚：登录地址的实例号；候选探活回报的实例号必须与它一致 */
  private instanceId: string = '';
  private store: preferences.Preferences | null = null;
  private probing: boolean = false;
  private netConnection: connection.NetConnection | null = null;
  /** 当前 ApiClient 实际使用的 origin（configure 时=登录地址；选路后=胜者） */
  private clientOrigin: string = '';
  /** 当前 ApiClient 实际使用的路由类别（请求头 X-MovieClaw-Route） */
  private clientKind: string = 'login';
  /** configure 是否已跑过：init() 的异步回填不能覆盖它设好的状态 */
  private configured: boolean = false;

  private constructor() {
  }

  /** EntryAbility.onCreate：读回上次的选路结论（冷启动不用等探测） */
  static init(context: Context): void {
    preferences.getPreferences(context, ServerRoutes.storeName)
      .then((store: preferences.Preferences): void => {
        const self: ServerRoutes = ServerRoutes.shared();
        self.store = store;
        // configure() 已经设过状态：只接管 store，不用偏好覆盖现场结论
        if (self.configured) {
          return;
        }
        self.loginOrigin = store.getSync('loginOrigin', '') as string;
        self.current = store.getSync('current', '') as string;
        const kind: string = store.getSync('kind', '') as string;
        self.kind = kind.length > 0 ? kind : 'login';
        self.routeLabel = self.labelOf(self.kind);
      })
      .catch((): void => {
      });
  }

  /**
   * 登录/恢复会话后配置并选路：拉地址簿 → 记身份锚 → 并发探活选一个。
   * 失败静默（选不出来就继续用登录地址，行为与旧版一致）。
   */
  configure(loginOrigin: string, api: MovieClawApi | null): void {
    // 换了一台服务器：上一台的结论（current/kind）必须清掉，否则选路全失败时会继续用旧地址
    if (this.loginOrigin.length > 0 && this.loginOrigin !== loginOrigin) {
      this.current = '';
      this.kind = 'login';
      this.routeLabel = '';
      if (this.store !== null) {
        this.store.delete('current').catch((): void => {
        });
        this.store.delete('kind').catch((): void => {
        });
      }
    }
    this.loginOrigin = loginOrigin;
    // 调用方刚用登录地址建好 ApiClient：比较基准是它，不是偏好里恢复的 current
    this.clientOrigin = loginOrigin;
    this.clientKind = 'login';
    this.configured = true;
    this.persist('loginOrigin', loginOrigin);
    this.observeNetwork();
    const run = async (): Promise<void> => {
      // 身份锚：登录地址的实例号（探不通就用空串——所有候选的实例校验会放行，退化为纯可达性选路）
      this.instanceId = await this.probeInstance(loginOrigin) ?? '';
      let loginKind: string = '';
      let book: ServerAddressesView | null = null;
      if (api !== null) {
        try {
          book = await api.serverAddresses();
          this.instanceId = this.instanceId.length > 0 ? this.instanceId : book.instance_id;
        } catch (error) {
          // 旧服务器没有地址簿：只有登录地址可用
        }
      }
      this.lanOrigins = [];
      this.wanOrigins = [];
      let loginInBook: boolean = false;
      if (book !== null) {
        for (const item of book.addresses) {
          if (item.url === loginOrigin) {
            loginKind = item.kind;
            loginInBook = true;
            continue;
          }
          if (item.kind === 'lan') {
            if (!this.lanOrigins.includes(item.url)) {
              this.lanOrigins.push(item.url);
            }
          } else if (!this.wanOrigins.includes(item.url)) {
            this.wanOrigins.push(item.url);
          }
        }
      }
      // 登录地址按地址簿的 kind 归类；地址簿没登记时用私网地址判断兜底（公网域名不能再当 lan）
      const loginIsLan: boolean = loginInBook ? loginKind === 'lan' : this.isPrivateHost(loginOrigin);
      if (loginIsLan) {
        this.lanOrigins.unshift(loginOrigin);
      } else if (!this.wanOrigins.includes(loginOrigin)) {
        this.wanOrigins.push(loginOrigin);
      }
      // 地址簿没登记外网地址时，用 .env 的 WAN_SERVER 兜底（release 空桩不注入）
      const devWan: string = DevConfig.wanServer;
      if (devWan.length > 0 && devWan !== loginOrigin && !this.wanOrigins.includes(devWan)) {
        this.wanOrigins.push(devWan);
      }
      await this.pick();
    };
    run();
  }

  /** 登录地址是不是私网（10/8、172.16/12、192.168/16）：地址簿没登记时兜底归类 */
  private isPrivateHost(origin: string): boolean {
    let rest: string = origin;
    const scheme: number = rest.indexOf('://');
    if (scheme >= 0) {
      rest = rest.substring(scheme + 3);
    }
    const slash: number = rest.indexOf('/');
    if (slash >= 0) {
      rest = rest.substring(0, slash);
    }
    const colon: number = rest.indexOf(':');
    const host: string = colon >= 0 ? rest.substring(0, colon) : rest;
    const parts: string[] = host.split('.');
    if (parts.length !== 4) {
      return false;
    }
    const a: number = Number(parts[0]);
    const b: number = Number(parts[1]);
    if (Number.isNaN(a) || Number.isNaN(b)) {
      return false;
    }
    return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
  }

  /** 退出登录：清结论（下一次登录重新配） */
  reset(): void {
    if (this.netConnection !== null) {
      this.netConnection.unregister((error: BusinessError): void => {
        if (error) {
          console.warn('ServerRoutes: netConnection.unregister failed: ' + error.code + ' ' + error.message);
        }
      });
      this.netConnection = null;
    }
    this.loginOrigin = '';
    this.current = '';
    this.kind = 'login';
    this.routeLabel = '';
    this.lanOrigins = [];
    this.wanOrigins = [];
    this.instanceId = '';
    this.clientOrigin = '';
    this.clientKind = 'login';
    this.configured = false;
    if (this.store !== null) {
      this.store.delete('current').catch((): void => {
      });
      this.store.delete('kind').catch((): void => {
      });
    }
  }

  /** 静态便捷（AppModel/PlayerPage 等处少写 .shared()） */
  static currentOrigin(): string {
    return ServerRoutes.shared().currentOriginImpl();
  }

  /** 当前生效地址（未配置/还在探 = 登录地址） */
  currentOriginImpl(): string {
    if (this.current.length > 0) {
      return this.current;
    }
    return this.loginOrigin;
  }

  /** 网络变了 / 回前台核实：重新探一遍（节流：正在探就不重叠） */
  reevaluate(): void {
    if (this.loginOrigin.length > 0) {
      this.pick();
    }
  }

  /** 监听网络变化：换了网络（Wi-Fi ↔ 蜂窝）就重选 */
  private observeNetwork(): void {
    if (this.netConnection !== null) {
      return;
    }
    this.netConnection = connection.createNetConnection();
    // 鸿蒙 NetConnection 必须先 register，on('netAvailable') 回调才会派发；
    // 只 on 不 register 的话，Wi-Fi/蜂窝切换不会触发重选路（只能等回前台 reevaluate 兜底）。
    this.netConnection.register((error: BusinessError): void => {
      if (error) {
        console.warn('ServerRoutes: netConnection.register failed: ' + error.code + ' ' + error.message);
      }
    });
    this.netConnection.on('netAvailable', (): void => {
      this.pick();
    });
  }

  /** 只有蜂窝时不试内网（iOS 同款） */
  private cellularOnly(): boolean {
    try {
      const netHandle: connection.NetHandle | null = connection.getDefaultNetSync();
      if (netHandle === null || netHandle.netId === 0) {
        return false;
      }
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(netHandle);
      const bearers: number[] = caps.bearerTypes ?? [];
      const hasLan: boolean = bearers.includes(connection.NetBearType.BEARER_WIFI)
        || bearers.includes(connection.NetBearType.BEARER_ETHERNET);
      return !hasLan && bearers.includes(connection.NetBearType.BEARER_CELLULAR);
    } catch (error) {
      return false;
    }
  }

  /**
   * 并发探活选路：内网候选先起跑，外网候选晚 `wanDelayMs`；
   * 每个候选探 `/api/v1/health`，实例号对得上才算过；第一个过的赢。
   * 探完全失败保持原路由不动（可能只是暂时断网）。
   */
  private async pick(): Promise<void> {
    if (this.probing) {
      return;
    }
    this.probing = true;
    try {
      const lanSkip: boolean = this.cellularOnly();
      const races: Promise<string | null>[] = [];
      if (!lanSkip && this.lanOrigins.length > 0) {
        for (const origin of this.lanOrigins) {
          races.push(this.race(origin, 'lan'));
        }
      }
      if (this.wanOrigins.length > 0) {
        const wanRaces: Promise<string | null>[] = [];
        for (const origin of this.wanOrigins) {
          wanRaces.push(this.race(origin, 'wan'));
        }
        const wanGroup: Promise<string | null> = new Promise((resolve): void => {
          setTimeout((): void => {
            this.firstSuccess(wanRaces).then(resolve);
          }, ServerRoutes.wanDelayMs);
        });
        races.push(wanGroup);
      }
      if (races.length === 0) {
        // 没有候选：回到登录地址
        this.apply(this.loginOrigin, 'login');
        return;
      }
      // 第一个成功通过身份校验的候选胜出；全部失败才 null（保持原路由）
      const winner: string | null = await this.firstSuccess(races);
      if (winner === null) {
        return;
      }
      const kind: string = this.kindOf(winner);
      this.apply(winner, kind);
    } finally {
      this.probing = false;
    }
  }

  /** Promise.any 语义：第一个非 null 的胜出；全部失败才 resolve(null) */
  private firstSuccess(promises: Promise<string | null>[]): Promise<string | null> {
    return new Promise((resolve): void => {
      let pending: number = promises.length;
      let settled: boolean = false;
      if (pending === 0) {
        resolve(null);
        return;
      }
      for (const promise of promises) {
        promise.then((value: string | null): void => {
          if (settled) {
            return;
          }
          if (value !== null) {
            settled = true;
            resolve(value);
            return;
          }
          pending -= 1;
          if (pending === 0) {
            settled = true;
            resolve(null);
          }
        }).catch((): void => {
          if (settled) {
            return;
          }
          pending -= 1;
          if (pending === 0) {
            settled = true;
            resolve(null);
          }
        });
      }
    });
  }

  /** 单个候选的探活竞赛：过身份校验 resolve(origin)，失败 resolve(null) */
  private async race(origin: string, kind: string): Promise<string | null> {
    const instance: string | null = await this.probeInstance(origin);
    if (instance === null) {
      return null;
    }
    if (this.instanceId.length > 0 && instance !== this.instanceId) {
      return null;
    }
    return origin;
  }

  /** 探 `/api/v1/health`：可达且 status ok 时返回 instance_id，否则 null */
  private probeInstance(origin: string): Promise<string | null> {
    return new Promise((resolve): void => {
      try {
        const req = http.createHttp();
        const finish = (value: string | null): void => {
          req.destroy();
          resolve(value);
        };
        req.requestInStream(`${origin}/api/v1/health`, {
          method: http.RequestMethod.GET,
          connectTimeout: ServerRoutes.probeTimeoutMs,
          readTimeout: ServerRoutes.probeTimeoutMs,
          usingCache: false
        }).then((code: number): void => {
          if (code !== 200) {
            finish(null);
            return;
          }
          // requestInStream 只给状态码；实例号再拉一次正文（小响应，代价可忽略）
          const body = http.createHttp();
          body.request(`${origin}/api/v1/health`, {
            method: http.RequestMethod.GET,
            connectTimeout: ServerRoutes.probeTimeoutMs,
            readTimeout: ServerRoutes.probeTimeoutMs,
            usingCache: false
          }).then((resp: http.HttpResponse): void => {
            body.destroy();
            try {
              const parsed: HealthProbe = JSON.parse(`${resp.result}`) as HealthProbe;
              finish(parsed.status === 'ok' ? parsed.instance_id : null);
            } catch (error) {
              finish(null);
            }
          }).catch((): void => {
            body.destroy();
            finish(null);
          });
        }).catch((): void => {
          finish(null);
        });
      } catch (error) {
        resolve(null);
      }
    });
  }

  /** 应用选路结论：通知 AppModel 重建客户端（令牌不变，只换 origin） */
  private apply(origin: string, kind: string): void {
    // 比较基准是 ApiClient 实际在用的地址，不是偏好里恢复的 current：
    // 冷启动/切账号时 activate() 用登录地址新建了客户端，选出的地址即使等于上次结论也必须通知
    if (origin === this.clientOrigin && kind === this.clientKind
      && origin === this.current && kind === this.kind) {
      return;
    }
    this.current = origin;
    this.kind = kind;
    this.routeLabel = this.labelOf(kind);
    this.persist('current', origin);
    this.persist('kind', kind);
    if (origin !== this.clientOrigin || kind !== this.clientKind) {
      this.clientOrigin = origin;
      this.clientKind = kind;
      if (this.onRouteChange !== null) {
        this.onRouteChange(origin, kind);
      }
    }
  }

  /** AppModel 注册：路由切换时重建 ApiClient（同令牌换 origin） */
  onRouteChange: ((origin: string, kind: string) => void) | null = null;

  private kindOf(origin: string): string {
    if (this.lanOrigins.includes(origin)) {
      return 'lan';
    }
    if (this.wanOrigins.includes(origin)) {
      return 'wan';
    }
    return 'login';
  }

  private labelOf(kind: string): string {
    if (kind === 'lan') {
      return '家里网络';
    }
    if (kind === 'wan') {
      return '外网';
    }
    return '';
  }

  private persist(key: string, value: string): void {
    if (this.store === null) {
      return;
    }
    this.store.put(key, value).then((): void => {
      this.store!.flush().catch((): void => {
      });
    }).catch((): void => {
    });
  }
}

/** /api/v1/health 的探活正文（无 envelope） */
interface HealthProbe {
  status: string;
  instance_id: string;
}
