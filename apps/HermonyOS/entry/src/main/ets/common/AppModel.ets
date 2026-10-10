import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Context } from '@kit.AbilityKit';
import { ApiClient, ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  AccountView,
  BootstrapStatus,
  DeviceLoginRequest,
  DeviceLoginView,
  HealthResponse,
  SessionView
} from '../api/Models';
import { ServerAddress } from './ServerAddress';
import { SavedServer, SavedServers } from './SavedServers';
import { TokenVault } from './TokenVault';

/** 偏好存储键。集中定义避免散落的字符串拼错。 */
class SessionKeys {
  /** 安装标识：同一台设备重新登录时替换旧凭证 */
  static readonly installationId: string = 'movieclaw.installation_id';
  /** 会话快照 JSON：冷启动先渲染它，/auth/me 校验通过后刷新 */
  static readonly sessionJson: string = 'movieclaw.session_json';
  /** 上一次用的服务器 origin（`activate` 时写） */
  static readonly lastServer: string = 'movieclaw.last_server';
  /** 旧格式：单账号时代明文存的服务器地址（迁移用，迁完就删） */
  static readonly legacyOrigin: string = 'movieclaw.origin';
  /** 旧格式：单账号时代明文存的令牌（迁移用，迁完就删） */
  static readonly legacyToken: string = 'movieclaw.token';
  /** 上一次切走的账号（双击头像页签据此切回来），形如 `{"origin":..,"username":..}` */
  static readonly previousAccount: string = 'movieclaw.previous_account';
}

/**
 * 启动阶段（对应 iOS `AppModel.Phase`，7 个）。
 *
 * ArkTS 没有带关联值的枚举，所以「就绪」这一态拆成 `phase === ready` + `session` 字段，
 * 其余与 iOS 一一对应。
 */
export class AppPhase {
  /** 启动时正在恢复上次的服务器与会话 */
  static readonly launching: number = 0;
  /** 本机还没登录过任何服务器 */
  static readonly needsServer: number = 1;
  /** 服务器是全新的，要先创建超级管理员 */
  static readonly needsSetup: number = 2;
  /** 这台服务器上当前账号要重新登录（没令牌 / 令牌失效） */
  static readonly needsLogin: number = 3;
  /** 本机还有别的服务器的账号，让用户挑一个 */
  static readonly chooseAccount: number = 4;
  /** 服务器连不上：令牌还在，恢复后点重试就能进 */
  static readonly unreachable: number = 5;
  /** 已就绪，`session` 有值 */
  static readonly ready: number = 6;
}

/** 跨服务器的账号条目（欢迎页「选择账号」用，对应 iOS `SavedAccount`） */
export class SavedAccount {
  readonly server: ServerAddress;
  readonly account: AccountView;

  constructor(server: ServerAddress, account: AccountView) {
    this.server = server;
    this.account = account;
  }

  key(): string {
    return `${this.server.origin}#${this.account.username}`;
  }
}

/** 登录一步的结果（对应 iOS `SignInResult`） */
export class SignInResult {
  /** 登录成功 */
  static readonly signedIn: string = 'signedIn';
  /** 服务器是全新的，要先创建超级管理员 */
  static readonly needsSetup: string = 'needsSetup';
}

/** 上一个账号（换账号时记下切走的那个），冷启动后照样能双击切回来 */
class PreviousAccount {
  readonly origin: string;
  readonly username: string;

  constructor(origin: string, username: string) {
    this.origin = origin;
    this.username = username;
  }
}

/**
 * 会话外壳（对应 iOS 端 `App/AppModel.swift`）。
 *
 * **多服务器 × 多账号**：令牌按「服务器 + 用户名」存进系统关键资产（`TokenVault`），
 * 服务器与账号快照存偏好（`SavedServers`）。切换账号完全在本机——换一枚令牌即可，
 * 不用联网、没有账号数上限，同一台主机的不同端口也互不覆盖。
 *
 * 冷启动（对应 iOS `restore` + `reconnect`）：
 * 1. 本机没登录过任何服务器 → `needsServer`（欢迎页）；
 * 2. 有当前服务器 → `reconnect()`：服务器没初始化 → `needsSetup`；
 *    本机没有当前账号的令牌 → `needsLogin`（预填快照里的用户名）；
 *    令牌失效（401）→ 删掉那枚令牌 → `needsLogin`；
 *    连不上 → `unreachable`（**不当成要重新登录**，令牌还在）。
 *
 * 本类标了 `@ObservedV2`：`@Trace` 字段一变，读它们的 `@ComponentV2` 界面自动重绘，
 * 不需要「读出来拷进 `@State`」（见 docs/harmonyos-port.md §10）。
 */
@ObservedV2
export class AppModel {
  /**
   * 当前服务器的 origin（图片地址、流地址都要拼它）。
   *
   * **统一放在这里**：之前 12 个页面各写了一份一模一样的 `private origin()`，
   * 属于「同一个东西抄 12 遍」——改一处（比如以后支持多地址回退）要改 12 个地方。
   */
  static origin(): string {
    const client: ApiClient | null = AppModel.shared.client;
    return client !== null ? client.origin : '';
  }

  private static instance: AppModel | null = null;

  /**
   * **惰性单例，不要写成 `static readonly shared = new AppModel()`。**
   *
   * 静态字段初始化器在**类定义阶段**就执行，早于 `@ObservedV2` 装饰器生效——
   * 那样建出来的实例没装上观察钩子，`@Trace` 字段变化不会通知任何组件
   * （实测：`phase` 已经是 ready，界面还停在启动转圈上）。
   */
  static get shared(): AppModel {
    if (AppModel.instance === null) {
      AppModel.instance = new AppModel();
    }
    return AppModel.instance;
  }

  private store: preferences.Preferences | null = null;
  /**
   * 偏好打开的完成信号。
   * `initStore` 由 EntryAbility.onCreate 异步触发、不阻塞首帧，而首页的 bootstrap 会立刻
   * 调 `restore()`——不等它的话 store 还是 null，restore 会把「还没打开」误判成
   * 「没登录过」直接回欢迎页（表现就是登录态像随机丢失，慢设备上几乎必现）。
   */
  private storeReady: Promise<void> | null = null;

  @Trace phase: number = AppPhase.launching;
  /** 当前服务器；为空表示本机还没登录过任何服务器 */
  @Trace server: ServerAddress | null = null;
  /** 当前账号的设备令牌；为空表示当前服务器上没有可用的登录 */
  @Trace token: string | null = null;
  /** 本机登录过的服务器，最近用过的在前 */
  @Trace savedServers: SavedServer[] = [];
  /** 连不上服务器的原因：「连不上」卡片与登录卡片顶部的提示 */
  @Trace launchError: string | null = null;
  /** 登录过期的账号：欢迎页据此预填用户名、提示「登录已过期」 */
  @Trace expiredUsername: string | null = null;
  /**
   * 自动换了账号时要告诉用户的一句话（「已退出 A，已切换到 B」）。
   * 换账号后主界面整棵重建，提示条也跟着重建，当场弹的提示会丢，所以先存在这里，
   * 新的主界面出现时取走弹出来（对应 iOS `pendingNotice`）。
   */
  @Trace pendingNotice: string | null = null;

  @Trace session: SessionView | null = null;
  @Trace client: ApiClient | null = null;
  @Trace api: MovieClawApi | null = null;

  private constructor() {
  }

  /** EntryAbility onCreate 时调用；偏好加载是异步的，不阻塞首帧。 */
  initStore(context: Context): Promise<void> {
    if (this.storeReady === null) {
      this.storeReady = this.openStore(context);
    }
    return this.storeReady;
  }

  private async openStore(context: Context): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, 'movieclaw_session');
    } catch (error) {
      // 偏好读写失败不致命：内存态照常工作，重启后要重新登录
      this.store = null;
    }
    // 401 → 删掉那枚令牌并回登录页（对应 iOS 端 .apiUnauthorized 通知）
    ApiClient.setUnauthorizedHandler((origin: string, token: string) => {
      this.sessionExpired(origin, token);
    });
  }

  private async ready(): Promise<void> {
    const signal: Promise<void> | null = this.storeReady;
    if (signal !== null) {
      await signal;
    }
  }

  // MARK: - 冷启动

  /** 冷启动恢复：读出本机的服务器与账号快照，再决定落到哪个 phase（对应 iOS `restore`） */
  async restore(): Promise<void> {
    await this.ready();
    this.savedServers = await SavedServers.load();
    const lastOrigin: string = await this.readString(SessionKeys.lastServer, '');
    if (lastOrigin.length > 0) {
      this.server = ServerAddress.trusted(lastOrigin);
    } else if (this.savedServers.length > 0) {
      // 没有「上次用的服务器」就退回最近用过的那台
      this.server = this.savedServers[0].address;
    }
    // 从「单账号」版本升级上来的：把旧的那一枚令牌搬进关键资产，别让用户白重登一次
    if (this.server === null && await this.migrateLegacySession()) {
      return;
    }
    if (this.server === null) {
      this.phase = AppPhase.needsServer;
      return;
    }
    await this.reconnect();
  }

  /**
   * 旧格式迁移：单账号时代把 origin/token 明文存在偏好里（`movieclaw.origin` / `movieclaw.token`）。
   * 启动时若发现本机还没有新格式的记录、但旧键还在，就用旧令牌问一次服务器：
   * 认得就把账号补进关键资产与快照（用户无感升级），认不得就清掉旧键让他重新登录。
   */
  private async migrateLegacySession(): Promise<boolean> {
    const origin: string = await this.readString(SessionKeys.legacyOrigin, '');
    const token: string = await this.readString(SessionKeys.legacyToken, '');
    if (origin.length === 0 || token.length === 0) {
      return false;
    }
    const address: ServerAddress = ServerAddress.trusted(origin);
    try {
      const session: SessionView = await new MovieClawApi(new ApiClient(origin, token)).authMe();
      await TokenVault.save(token, origin, session.username);
      this.server = address;
      this.activate(address, session, token);
      await this.clearLegacySession();
      return true;
    } catch (error) {
      // 令牌已经不作数了：把旧键清掉，走正常的未登录流程
      await this.clearLegacySession();
      return false;
    }
  }

  private async clearLegacySession(): Promise<void> {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return;
    }
    await store.delete(SessionKeys.legacyOrigin);
    await store.delete(SessionKeys.legacyToken);
    await store.flush();
  }

  /**
   * 连当前服务器、恢复它上面的会话：冷启动与「连不上」卡片的「重试」共用（对应 iOS `reconnect`）。
   */
  async reconnect(): Promise<void> {
    const address: ServerAddress | null = this.server;
    if (address === null) {
      this.phase = AppPhase.needsServer;
      return;
    }
    // 当前服务器上的「当前账号」是谁：快照里标了 active 的那个
    const snapshot: SavedServer | null = SavedServers.find(this.savedServers, address);
    const active: AccountView | null = snapshot === null ? null : snapshot.activeAccount();
    const username: string = active === null ? '' : active.username;
    const savedToken: string = username.length > 0 ? await TokenVault.token(address.origin, username) : '';

    const probeClient: ApiClient = new ApiClient(address.origin, savedToken.length > 0 ? savedToken : null);
    const probeApi: MovieClawApi = new MovieClawApi(probeClient);
    try {
      const health: HealthResponse = await probeApi.healthCheck();
      if (health.status !== 'ok') {
        this.launchError = `服务器状态异常：${health.status}`;
        this.phase = AppPhase.unreachable;
        return;
      }
      const status: BootstrapStatus = await probeApi.authBootstrapStatus();
      if (!status.initialized) {
        this.phase = AppPhase.needsSetup;
        return;
      }
      if (savedToken.length === 0) {
        // 本机没有这台服务器当前账号的令牌：输一次密码
        this.launchError = null;
        this.expiredUsername = username.length > 0 ? username : null;
        this.phase = AppPhase.needsLogin;
        return;
      }
      const session: SessionView = await probeApi.authMe();
      this.activate(address, session, savedToken);
    } catch (error) {
      if (error instanceof ApiError && error.isUnauthorized) {
        // 当前账号的令牌失效了：预填快照里它的用户名，让用户只输密码
        if (username.length > 0) {
          await TokenVault.delete(address.origin, username);
        }
        this.forgetCurrentToken();
        this.launchError = null;
        this.expiredUsername = username.length > 0 ? username : null;
        this.phase = this.otherAccounts().length > 0 ? AppPhase.chooseAccount : AppPhase.needsLogin;
        return;
      }
      // 服务器连不上：不当成「要重新登录」——令牌还在，恢复后点重试就能进
      this.launchError = this.messageOf(error);
      this.phase = AppPhase.unreachable;
    }
  }

  /**
   * 冷启动用快照进了主界面之后，在后台向服务器确认身份。
   * 401 由 `sessionExpired` 打回登录页；连不上时什么也不做（对应 iOS `revalidate`）。
   */
  async revalidate(): Promise<void> {
    const api: MovieClawApi | null = this.api;
    const current: SessionView | null = this.session;
    if (api === null || current === null) {
      return;
    }
    try {
      const fresh: SessionView = await api.authMe();
      if (fresh.username !== current.username) {
        return;
      }
      this.update(fresh);
    } catch (error) {
      if (error instanceof ApiError && error.isUnauthorized) {
        this.sessionExpired(null, null);
      }
    }
  }

  // MARK: - 登录

  /**
   * 欢迎页与「添加账号」的登录：测通服务器后用账号密码换设备令牌（对应 iOS `signIn`）。
   * 可以是另一台服务器——登录成功它就成为当前服务器，原来那台的账号照样留在本机。
   */
  async signIn(rawOrigin: string, username: string, password: string): Promise<string> {
    const address: ServerAddress = ServerAddress.parse(rawOrigin);
    const probeApi: MovieClawApi = new MovieClawApi(new ApiClient(address.origin, null));
    const health: HealthResponse = await probeApi.healthCheck();
    if (health.status !== 'ok') {
      throw new Error(`服务器状态异常：${health.status}`);
    }
    const status: BootstrapStatus = await probeApi.authBootstrapStatus();
    if (!status.initialized) {
      // 全新服务器：交给界面确认后调 createAdmin
      return SignInResult.needsSetup;
    }
    await this.deviceLogin(address, username, password);
    return SignInResult.signedIn;
  }

  /** 全新服务器：用欢迎页填的账号创建超级管理员并直接进入（对应 iOS `createAdmin`） */
  async createAdmin(rawOrigin: string, username: string, password: string): Promise<void> {
    const address: ServerAddress = ServerAddress.parse(rawOrigin);
    const bootApi: MovieClawApi = new MovieClawApi(new ApiClient(address.origin, null));
    await bootApi.authBootstrapCreate({ username: username, password: password });
    await this.deviceLogin(address, username, password);
  }

  /**
   * 用账号密码换设备令牌并落库（对应 iOS `deviceLogin`）。
   *
   * `kind` 借 `android` 位：鸿蒙不在后端枚举 `Literal["ios","tvos","android"]` 里，
   * 见 docs/harmonyos-port.md §4（改后端是另一件事，本次不动）。
   */
  private async deviceLogin(address: ServerAddress, username: string, password: string): Promise<void> {
    const installationId: string = await this.ensureInstallationId();
    const bootApi: MovieClawApi = new MovieClawApi(new ApiClient(address.origin, null));
    const request: DeviceLoginRequest = {
      username: username,
      password: password,
      client: {
        kind: 'android',
        installation_id: installationId,
        name: deviceInfo.productModel,
        platform: `HarmonyOS ${deviceInfo.osFullName}`,
        client_version: '0.1.0'
      }
    };
    const view: DeviceLoginView = await bootApi.authDeviceLogin(request);
    await TokenVault.save(view.token, address.origin, view.session.username);
    this.activate(address, view.session, view.token);
  }

  // MARK: - 账号切换

  /**
   * 向某台服务器刷新它的账号列表（对应 iOS `refreshAccounts(on:)`）。
   *
   * 切换账号抽屉打开时逐台调一次：本机快照可能已经过时（在别的设备上加了或删了账号），
   * 打开时现取一次才跟服务器一致。**取不到就保持快照原样**——抽屉照样列出这台，
   * 只是拿不到最新列表（iOS 同理，标「连不上」后仍照列）。
   *
   * 用这台服务器当前激活账号的令牌去取；没有令牌就不刷（没必要，也刷不动）。
   */
  async refreshAccounts(address: ServerAddress): Promise<void> {
    const snapshot: SavedServer | null = SavedServers.find(this.savedServers, address);
    const active: AccountView | null = snapshot === null ? null : snapshot.activeAccount();
    if (active === null) {
      return;
    }
    const token: string = await TokenVault.token(address.origin, active.username);
    if (token.length === 0) {
      return;
    }
    const list: AccountView[] =
      await new MovieClawApi(new ApiClient(address.origin, token)).authAccountsList();
    const next: SavedServer[] = SavedServers.replacingAccounts(this.savedServers, address, list);
    this.savedServers = next;
    await SavedServers.save(next);
  }

  /**
   * 切到本机已存令牌的某个账号（对应 iOS `switchAccount`）。
   * **切号不联网登录**：只是换一枚令牌，再向服务器确认一次身份。
   */
  async switchAccount(username: string, address: ServerAddress): Promise<void> {
    const saved: string = await TokenVault.token(address.origin, username);
    if (saved.length === 0) {
      throw new Error('这台服务器上没有这个账号的登录，需要重新输密码');
    }
    try {
      const session: SessionView = await new MovieClawApi(new ApiClient(address.origin, saved)).authMe();
      const changesServer: boolean = this.server === null || this.server.origin !== address.origin;
      this.pendingNotice = `已切换到「${session.nickname}」` + (changesServer ? ` · ${address.hostLabel}` : '');
      this.activate(address, session, saved);
    } catch (error) {
      if (error instanceof ApiError && error.isUnauthorized) {
        // 令牌已失效：删掉它，让用户重新输密码（账号快照保留）
        await TokenVault.delete(address.origin, username);
        throw new Error('这个账号的登录已失效，需要重新输密码');
      }
      throw error as Error;
    }
  }

  /**
   * 双击头像页签：切回上一个账号（跨服务器也算）——在最近用的两个账号之间来回切，结果可预期。
   * 上一个账号已不在本机时改切本机另一个还能用的账号；本机只有当前这一个账号时返回 false。
   */
  async switchToPreviousAccount(): Promise<boolean> {
    const others: SavedAccount[] = this.otherAccounts();
    if (others.length === 0) {
      return false;
    }
    const previous: PreviousAccount | null = await this.readPrevious();
    let target: SavedAccount | null = null;
    if (previous !== null) {
      for (const candidate of others) {
        if (candidate.server.origin === previous.origin
          && candidate.account.username === previous.username) {
          target = candidate;
          break;
        }
      }
    }
    if (target === null) {
      for (const candidate of others) {
        if (await TokenVault.has(candidate.server.origin, candidate.account.username)) {
          target = candidate;
          break;
        }
      }
    }
    if (target === null) {
      target = others[0];
    }
    await this.switchAccount(target.account.username, target.server);
    return true;
  }

  /** 本机除当前账号以外的所有账号（跨服务器） */
  private otherAccounts(): SavedAccount[] {
    const currentServer: string = this.server === null ? '' : this.server.origin;
    const currentUser: string = this.session === null ? '' : this.session.username;
    const out: SavedAccount[] = [];
    for (const saved of this.savedServers) {
      for (const account of saved.accounts) {
        if (saved.address.origin === currentServer && account.username === currentUser) {
          continue;
        }
        out.push(new SavedAccount(saved.address, account));
      }
    }
    return out;
  }

  /**
   * 从本机移除一个账号：服务端注销这台设备上它的登录，再删本机的令牌与快照。
   * 移除的是当前账号时处理同「退出登录」（对应 iOS `removeAccount`）。
   */
  async removeAccount(username: string, address: ServerAddress): Promise<void> {
    const isCurrent: boolean = this.server !== null && this.server.origin === address.origin
      && this.session !== null && this.session.username === username;
    if (isCurrent) {
      await this.logout();
      return;
    }
    const saved: string = await TokenVault.token(address.origin, username);
    if (saved.length > 0) {
      await AppModel.revokeDevice(address.origin, saved);
    }
    await TokenVault.delete(address.origin, username);
    let list: SavedServer[] = SavedServers.removingAccount(this.savedServers, username, address);
    list = SavedServers.pruned(list, this.server);
    this.savedServers = list;
    await SavedServers.save(list);
  }

  /**
   * 退出当前账号（对应 iOS `logout`）：服务端注销这枚令牌，本机删掉它与快照；
   * 这台服务器上还有别的可用账号就自动切过去，否则离开当前服务器。
   */
  async logout(): Promise<void> {
    const address: ServerAddress | null = this.server;
    const current: SessionView | null = this.session;
    const token: string | null = this.token;
    if (address === null || current === null) {
      return;
    }
    if (token !== null) {
      await AppModel.revokeDevice(address.origin, token);
    }
    await TokenVault.delete(address.origin, current.username);
    this.forgetCurrentToken();
    let list: SavedServer[] = SavedServers.removingAccount(this.savedServers, current.username, address);
    this.savedServers = list;
    await SavedServers.save(list);

    const next: SessionView | null = await this.switchToAnotherAccount(address);
    if (next !== null) {
      // 退出后人还在 App 里，很容易以为没退成：明确说出现在换成了谁
      this.pendingNotice = `已退出「${current.nickname}」，已切换到「${next.nickname}」`;
      return;
    }
    await this.leaveCurrentServer();
  }

  /** 退出本机全部账号（所有服务器上的），共用设备交还前用（对应 iOS `logoutEverywhere`） */
  async logoutEverywhere(): Promise<void> {
    const targets: string[] = [];
    for (const saved of this.savedServers) {
      for (const account of saved.accounts) {
        const token: string = await TokenVault.token(saved.address.origin, account.username);
        if (token.length > 0) {
          targets.push(`${saved.address.origin}\u0000${token}`);
        }
      }
    }
    await TokenVault.clearAll();
    this.forgetCurrentToken();
    const emptied: SavedServer[] = [];
    for (const saved of this.savedServers) {
      emptied.push(new SavedServer(saved.address, [], saved.lastUsed));
    }
    this.savedServers = SavedServers.pruned(emptied, this.server);
    await SavedServers.save(this.savedServers);
    this.expiredUsername = null;
    this.phase = AppPhase.needsLogin;
    // 服务端的注销在后台尽力而为：连不上也能在本机退干净
    for (const target of targets) {
      const parts: string[] = target.split('\u0000');
      AppModel.revokeDevice(parts[0], parts[1]);
    }
  }

  /** 同一台服务器上找一个本机还能用的账号切过去（退出/移除当前账号后）；没有返回 null */
  private async switchToAnotherAccount(address: ServerAddress): Promise<SessionView | null> {
    const snapshot: SavedServer | null = SavedServers.find(this.savedServers, address);
    if (snapshot === null) {
      return null;
    }
    for (const account of snapshot.accounts) {
      const saved: string = await TokenVault.token(address.origin, account.username);
      if (saved.length === 0) {
        continue;
      }
      try {
        const session: SessionView = await new MovieClawApi(new ApiClient(address.origin, saved)).authMe();
        this.activate(address, session, saved);
        return session;
      } catch (error) {
        if (error instanceof ApiError && error.isUnauthorized) {
          await TokenVault.delete(address.origin, account.username);
        } else {
          return null;
        }
      }
    }
    return null;
  }

  /** 当前服务器上已经没有能用的账号：清空它的快照，回欢迎页（对应 iOS `leaveCurrentServer`） */
  private async leaveCurrentServer(): Promise<void> {
    const address: ServerAddress | null = this.server;
    if (address === null) {
      this.phase = AppPhase.needsLogin;
      return;
    }
    const snapshot: SavedServer | null = SavedServers.find(this.savedServers, address);
    if (snapshot !== null) {
      for (const account of snapshot.accounts) {
        await TokenVault.delete(address.origin, account.username);
      }
    }
    const list: SavedServer[] = SavedServers.replacingAccounts(this.savedServers, address, []);
    this.savedServers = list;
    await SavedServers.save(list);
    this.expiredUsername = null;
    this.phase = this.otherAccounts().length > 0 ? AppPhase.chooseAccount : AppPhase.needsLogin;
  }

  // MARK: - 内部

  /** 进入某台服务器上的某个账号：记下服务器与令牌、更新本机快照（对应 iOS `activate`） */
  private activate(address: ServerAddress, session: SessionView, token: string): void {
    // 换了账号（含换到另一台服务器）：记下切走的那个，双击头像页签据此切回来
    const from: ServerAddress | null = this.server;
    const current: SessionView | null = this.session;
    if (from !== null && current !== null
      && (from.origin !== address.origin || current.username !== session.username)) {
      this.writePrevious(new PreviousAccount(from.origin, current.username));
    }
    this.server = address;
    this.token = token;
    this.client = new ApiClient(address.origin, token);
    this.api = new MovieClawApi(this.client);
    this.session = session;
    this.launchError = null;
    this.expiredUsername = null;
    // 置顶这台、把这个账号标为它上面的当前账号；顺手清掉已经一个账号都不剩的旧服务器
    let list: SavedServer[] = SavedServers.touching(this.savedServers, address, null, Date.now());
    list = SavedServers.upserting(list, address,
      SavedServers.snapshot(session.username, session.nickname, session.avatar_url ?? null,
        session.role, true), Date.now());
    list = SavedServers.pruned(list, address);
    this.savedServers = list;
    SavedServers.save(list);
    this.writeString(SessionKeys.lastServer, address.origin);
    this.writeString(SessionKeys.sessionJson, JSON.stringify(session));
    this.phase = AppPhase.ready;
  }

  /** 更新会话快照（对应 iOS `update(session:)`） */
  update(session: SessionView): void {
    this.session = session;
    this.writeString(SessionKeys.sessionJson, JSON.stringify(session));
  }

  private forgetCurrentToken(): void {
    this.token = null;
    this.client = null;
    this.api = null;
    this.session = null;
  }

  /**
   * 当前令牌收到 401（被注销、改了密码、账号停用）：删掉这枚没用的令牌，回登录页并预填用户名。
   * 带着别的令牌的 401（刚退出的旧令牌还有请求在路上、切号时问别的账号）不算。
   * 对应 iOS `sessionExpired`。
   */
  private sessionExpired(origin: string | null, rejected: string | null): void {
    if (this.phase !== AppPhase.ready) {
      return;
    }
    if (origin !== null && (this.server === null || origin !== this.server.origin)) {
      return;
    }
    if (rejected !== null && rejected !== this.token) {
      return;
    }
    const address: ServerAddress | null = this.server;
    const current: SessionView | null = this.session;
    if (address !== null && current !== null) {
      TokenVault.delete(address.origin, current.username);
      this.expiredUsername = current.username;
    }
    this.forgetCurrentToken();
    this.phase = AppPhase.needsLogin;
  }

  /** 服务端注销这枚令牌（尽力而为，5 秒超时；对应 iOS `revokeDevice`） */
  private static async revokeDevice(origin: string, token: string): Promise<void> {
    try {
      await new MovieClawApi(new ApiClient(origin, token)).authDevicesRevokeCurrent();
    } catch (error) {
      // 连不上就算了：本机照样退干净
    }
  }

  takeNotice(): string | null {
    const notice: string | null = this.pendingNotice;
    this.pendingNotice = null;
    return notice;
  }

  /** 安装标识：首次生成 UUID 后固化，同一台设备重新登录时替换服务端旧凭证。 */
  private async ensureInstallationId(): Promise<string> {
    if (this.store === null) {
      return util.generateRandomUUID(false);
    }
    let existing: string = await this.store.get(SessionKeys.installationId, '') as string;
    if (existing.length === 0) {
      existing = util.generateRandomUUID(false);
      await this.store.put(SessionKeys.installationId, existing);
      await this.store.flush();
    }
    return existing;
  }

  private async readString(key: string, fallback: string): Promise<string> {
    if (this.store === null) {
      return fallback;
    }
    return await this.store.get(key, fallback) as string;
  }

  private writeString(key: string, value: string): void {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      return;
    }
    store.put(key, value).then((): void => {
      store.flush();
    });
  }

  private async readPrevious(): Promise<PreviousAccount | null> {
    const raw: string = await this.readString(SessionKeys.previousAccount, '');
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as PreviousAccount;
    } catch (error) {
      return null;
    }
  }

  private writePrevious(value: PreviousAccount): void {
    this.writeString(SessionKeys.previousAccount, JSON.stringify(value));
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '连不上服务器';
  }
}
