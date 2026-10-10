import { preferences } from '@kit.ArkData';
import { AccountView } from '../api/Models';
import { ServerAddress } from './ServerAddress';

/** 一台登录过的服务器（对应 iOS `SavedServer`） */
export class SavedServer {
  readonly address: ServerAddress;
  readonly accounts: AccountView[];
  /** 最近使用时间（毫秒时间戳），列表按它倒序 */
  readonly lastUsed: number;

  constructor(address: ServerAddress, accounts: AccountView[], lastUsed: number) {
    this.address = address;
    this.accounts = accounts;
    this.lastUsed = lastUsed;
  }

  /** 快照里标为「当前」的账号；冷启动发现会话过期时据此预填用户名（对应 iOS `activeAccount`） */
  activeAccount(): AccountView | null {
    for (const account of this.accounts) {
      if (account.active) {
        return account;
      }
    }
    return this.accounts.length > 0 ? this.accounts[0] : null;
  }

  /** 这台服务器上有没有这个账号的快照（用户名不区分大小写） */
  holds(username: string): boolean {
    const wanted: string = username.toLowerCase();
    for (const account of this.accounts) {
      if (account.username.toLowerCase() === wanted) {
        return true;
      }
    }
    return false;
  }
}

/** 落盘用的裸结构（ServerAddress 不好直接序列化） */
interface SavedServerDTO {
  origin: string;
  accounts: AccountView[];
  lastUsed: number;
}

/**
 * 服务器记录的读写与增删（对应 iOS 端 `Core/Session/SavedServers.swift`）。
 *
 * 纯函数部分（`touching` / `replacingAccounts` / `upserting` / `removingAccount` / `snapshot`）
 * 与 iOS 逐条对应，**不碰存储**，便于以后补单测。
 */
export class SavedServers {
  private static readonly storeName: string = 'movieclaw_servers';
  private static readonly key: string = 'savedServers';
  private static store: preferences.Preferences | null = null;
  /**
   * 偏好打开的完成信号。
   * `init` 由 EntryAbility.onCreate 异步触发、不阻塞首帧，而 `load()` 可能在它完成前就被调用——
   * 不等的话 store 还是 null，`load()` 会静默返回空列表（表现是「账号快照莫名其妙丢了」）。
   * 同 AppModel.storeReady 的坑，见 docs/harmonyos-port.md §10。
   */
  private static ready: Promise<void> | null = null;

  /** EntryAbility.onCreate 时调用（同 AppModel.initStore 的时机） */
  static init(context: Context): Promise<void> {
    if (SavedServers.ready === null) {
      SavedServers.ready = SavedServers.open(context);
    }
    return SavedServers.ready;
  }

  private static async open(context: Context): Promise<void> {
    try {
      SavedServers.store = await preferences.getPreferences(context, SavedServers.storeName);
    } catch (error) {
      SavedServers.store = null;
    }
  }

  private static async waitReady(): Promise<void> {
    const signal: Promise<void> | null = SavedServers.ready;
    if (signal !== null) {
      await signal;
    }
  }

  // MARK: 存储

  static async load(): Promise<SavedServer[]> {
    await SavedServers.waitReady();
    const store: preferences.Preferences | null = SavedServers.store;
    if (store === null) {
      return [];
    }
    try {
      const raw: string = await store.get(SavedServers.key, '[]') as string;
      const dtos: SavedServerDTO[] = JSON.parse(raw) as SavedServerDTO[];
      const out: SavedServer[] = [];
      for (const dto of dtos) {
        out.push(new SavedServer(ServerAddress.trusted(dto.origin), dto.accounts, dto.lastUsed));
      }
      return out;
    } catch (error) {
      return [];
    }
  }

  static async save(list: SavedServer[]): Promise<void> {
    await SavedServers.waitReady();
    const store: preferences.Preferences | null = SavedServers.store;
    if (store === null) {
      return;
    }
    const dtos: SavedServerDTO[] = [];
    for (const item of list) {
      dtos.push({ origin: item.address.origin, accounts: item.accounts, lastUsed: item.lastUsed });
    }
    await store.put(SavedServers.key, JSON.stringify(dtos));
    await store.flush();
  }

  static async clearAll(): Promise<void> {
    await SavedServers.waitReady();
    const store: preferences.Preferences | null = SavedServers.store;
    if (store === null) {
      return;
    }
    await store.delete(SavedServers.key);
    await store.flush();
  }

  // MARK: 纯函数（与 iOS 一一对应）

  /**
   * 记一次使用：这台服务器置顶；给了账号列表就一并覆盖快照（`null` 表示只更新时间）。
   * 对应 iOS `touching`。
   */
  static touching(list: SavedServer[], address: ServerAddress, accounts: AccountView[] | null,
    at: number): SavedServer[] {
    const result: SavedServer[] = [];
    let found: boolean = false;
    for (const item of list) {
      if (item.address.origin === address.origin) {
        found = true;
        result.push(new SavedServer(item.address, accounts ?? item.accounts, at));
      } else {
        result.push(item);
      }
    }
    if (!found) {
      result.push(new SavedServer(address, accounts ?? [], at));
    }
    result.sort((a: SavedServer, b: SavedServer): number => b.lastUsed - a.lastUsed);
    return result;
  }

  /** 只覆盖某台服务器的账号快照，不动排序（后台刷新别的服务器时用）。对应 iOS `replacingAccounts` */
  static replacingAccounts(list: SavedServer[], address: ServerAddress, accounts: AccountView[]): SavedServer[] {
    const out: SavedServer[] = [];
    for (const item of list) {
      if (item.address.origin === address.origin) {
        out.push(new SavedServer(item.address, accounts, item.lastUsed));
      } else {
        out.push(item);
      }
    }
    return out;
  }

  /**
   * 登录 / 切换 / 刷新后写入一个账号的快照：同名的替换；
   * `active` 为真时它成为这台服务器的当前账号（排到最前、其余账号取消「当前」）。
   * 对应 iOS `upserting`。
   */
  static upserting(list: SavedServer[], address: ServerAddress, account: AccountView,
    at: number): SavedServer[] {
    const base: SavedServer[] = SavedServers.holds(list, address)
      ? list
      : SavedServers.touching(list, address, null, at);
    const wanted: string = account.username.toLowerCase();
    const out: SavedServer[] = [];
    for (const saved of base) {
      if (saved.address.origin !== address.origin) {
        out.push(saved);
        continue;
      }
      const others: AccountView[] = [];
      for (const existing of saved.accounts) {
        if (existing.username.toLowerCase() !== wanted) {
          others.push(existing);
        }
      }
      if (account.active) {
        const cleared: AccountView[] = [];
        for (const other of others) {
          cleared.push({
            username: other.username,
            nickname: other.nickname,
            avatar_url: other.avatar_url,
            role: other.role,
            active: false
          });
        }
        const head: AccountView[] = [account];
        for (const item of cleared) {
          head.push(item);
        }
        out.push(new SavedServer(saved.address, head, saved.lastUsed));
      } else if (saved.holds(account.username)) {
        // 同名替换（保持原位）
        const next: AccountView[] = [];
        for (const existing of saved.accounts) {
          next.push(existing.username.toLowerCase() === wanted ? account : existing);
        }
        out.push(new SavedServer(saved.address, next, saved.lastUsed));
      } else {
        const next: AccountView[] = others;
        next.push(account);
        out.push(new SavedServer(saved.address, next, saved.lastUsed));
      }
    }
    return out;
  }

  /** 从某台服务器的快照里去掉一个账号。对应 iOS `removingAccount` */
  static removingAccount(list: SavedServer[], username: string, address: ServerAddress): SavedServer[] {
    const out: SavedServer[] = [];
    for (const saved of list) {
      if (saved.address.origin !== address.origin) {
        out.push(saved);
        continue;
      }
      const keep: AccountView[] = [];
      for (const account of saved.accounts) {
        if (account.username !== username) {
          keep.push(account);
        }
      }
      out.push(new SavedServer(saved.address, keep, saved.lastUsed));
    }
    return out;
  }

  /** 这台服务器上有没有记录（对应 iOS `list.contains(where:)`） */
  static holds(list: SavedServer[], address: ServerAddress): boolean {
    for (const item of list) {
      if (item.address.origin === address.origin) {
        return true;
      }
    }
    return false;
  }

  /**
   * 清掉已经一个账号都不剩的服务器，**但保留当前这台**——它还要在界面上充当「当前服务器」，
   * 只是暂时没有可用账号。对应 iOS `pruned`。
   */
  static pruned(list: SavedServer[], current: ServerAddress | null): SavedServer[] {
    const out: SavedServer[] = [];
    for (const item of list) {
      const isCurrent: boolean = current !== null && item.address.origin === current.origin;
      if (item.accounts.length > 0 || isCurrent) {
        out.push(item);
      }
    }
    return out;
  }

  static find(list: SavedServer[], address: ServerAddress): SavedServer | null {
    for (const item of list) {
      if (item.address.origin === address.origin) {
        return item;
      }
    }
    return null;
  }

  /** 会话视图 → 本机账号快照（对应 iOS `snapshot`；头像打不打标记见 RemoteImage 的说明） */
  static snapshot(username: string, nickname: string, avatarUrl: string | null, role: string,
    active: boolean): AccountView {
    return {
      username: username,
      nickname: nickname,
      avatar_url: avatarUrl,
      role: role,
      active: active
    };
  }
}
