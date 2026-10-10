import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';

/**
 * 设备令牌的**关键资产**存储（对应 iOS 端 `Core/Networking/TokenVault.swift`）。
 *
 * iOS 用钥匙串存令牌，鸿蒙这边用系统的关键资产存储（`@ohos.security.asset`），语义一一对应：
 * - 令牌按「服务器 + 用户名」一枚一条：多账号完全在本机，切换账号就是换一枚令牌，
 *   不用联网、没有账号数上限，**同一台主机的不同端口也互不覆盖**（origin 里带端口）；
 * - `Accessibility.DEVICE_FIRST_UNLOCKED` 对应 iOS 的 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：
 *   开机首次解锁后即可读取、不进云备份——令牌代表的是「这台设备」；
 * - 令牌失效（被注销、改了密码）时只删这一条，**账号快照保留**，用户点它只需重新输密码。
 *
 * **不要退回用 Preferences 存令牌**。之前的实现就是明文放在 Preferences 里，
 * 见 docs/harmonyos-port.md §10。
 *
 * 关键资产没有「按前缀列举」的接口，所以另用一个 Preferences 存**别名索引**，
 * 只为「退出全部账号」时能枚举出所有条目；令牌本身只存在关键资产里。
 */
export class TokenVault {
  private static readonly indexStoreName: string = 'movieclaw_token_index';
  private static readonly indexKey: string = 'aliases';

  private static indexStore: preferences.Preferences | null = null;
  /** 索引偏好打开的完成信号（同 SavedServers.ready 的坑） */
  private static ready: Promise<void> | null = null;
  private static encoder: util.TextEncoder = new util.TextEncoder();
  private static decoder: util.TextDecoder = new util.TextDecoder();

  /** EntryAbility.onCreate 时调用（同 AppModel.initStore 的时机） */
  static init(context: Context): Promise<void> {
    if (TokenVault.ready === null) {
      TokenVault.ready = TokenVault.openIndex(context);
    }
    return TokenVault.ready;
  }

  private static async openIndex(context: Context): Promise<void> {
    try {
      TokenVault.indexStore = await preferences.getPreferences(context, TokenVault.indexStoreName);
    } catch (error) {
      TokenVault.indexStore = null;
    }
  }

  private static async waitReady(): Promise<void> {
    const signal: Promise<void> | null = TokenVault.ready;
    if (signal !== null) {
      await signal;
    }
  }

  /** 别名 = 「服务器 origin#用户名小写」（同 iOS 的 kSecAttrAccount 拼法） */
  private static aliasOf(origin: string, username: string): string {
    return `${origin}#${username.toLowerCase()}`;
  }

  private static bytes(text: string): Uint8Array {
    return TokenVault.encoder.encodeInto(text);
  }

  private static text(value: asset.Value | undefined): string {
    if (value === undefined || value === null) {
      return '';
    }
    return TokenVault.decoder.decodeToString(value as Uint8Array);
  }

  private static queryOf(alias: string): asset.AssetMap {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, TokenVault.bytes(alias));
    return query;
  }

  /** 存一枚令牌：先删同名的再加（对应 iOS 的 delete + add），并登记到索引 */
  static async save(token: string, origin: string, username: string): Promise<void> {
    const alias: string = TokenVault.aliasOf(origin, username);
    await TokenVault.deleteRaw(alias);
    const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attrs.set(asset.Tag.ALIAS, TokenVault.bytes(alias));
    attrs.set(asset.Tag.SECRET, TokenVault.bytes(token));
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    // 设备没设锁屏时也要能存：令牌代表这台设备，不要求用户必须先设密码
    attrs.set(asset.Tag.REQUIRE_PASSWORD_SET, false);
    await asset.add(attrs);
    await TokenVault.rememberAlias(alias);
  }

  /** 取令牌；没有返回空串 */
  static async token(origin: string, username: string): Promise<string> {
    const alias: string = TokenVault.aliasOf(origin, username);
    try {
      const query: asset.AssetMap = TokenVault.queryOf(alias);
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const found: Array<asset.AssetMap> = await asset.query(query);
      if (found.length === 0) {
        return '';
      }
      return TokenVault.text(found[0].get(asset.Tag.SECRET));
    } catch (error) {
      // 没找到（24000002）或本机不支持：都当作没有令牌
      return '';
    }
  }

  /** 这台服务器上有没有存过某个账号的令牌（欢迎页据此决定「免密进入」还是「要输密码」） */
  static async has(origin: string, username: string): Promise<boolean> {
    const found: string = await TokenVault.token(origin, username);
    return found.length > 0;
  }

  /** 删一枚令牌（令牌被注销/改密码时用；账号快照不删） */
  static async delete(origin: string, username: string): Promise<void> {
    const alias: string = TokenVault.aliasOf(origin, username);
    await TokenVault.deleteRaw(alias);
    await TokenVault.forgetAlias(alias);
  }

  /** 清空全部令牌（「退出全部账号」用） */
  static async clearAll(): Promise<void> {
    const aliases: string[] = await TokenVault.aliases();
    for (const alias of aliases) {
      await TokenVault.deleteRaw(alias);
    }
    await TokenVault.writeAliases([]);
  }

  private static async deleteRaw(alias: string): Promise<void> {
    try {
      await asset.remove(TokenVault.queryOf(alias));
    } catch (error) {
      // 本来就不存在：正常（24000002）
    }
  }

  // MARK: 别名索引

  private static async aliases(): Promise<string[]> {
    await TokenVault.waitReady();
    const store: preferences.Preferences | null = TokenVault.indexStore;
    if (store === null) {
      return [];
    }
    try {
      const raw: string = await store.get(TokenVault.indexKey, '[]') as string;
      return JSON.parse(raw) as string[];
    } catch (error) {
      return [];
    }
  }

  private static async writeAliases(list: string[]): Promise<void> {
    const store: preferences.Preferences | null = TokenVault.indexStore;
    if (store === null) {
      return;
    }
    await store.put(TokenVault.indexKey, JSON.stringify(list));
    await store.flush();
  }

  private static async rememberAlias(alias: string): Promise<void> {
    const list: string[] = await TokenVault.aliases();
    if (list.indexOf(alias) >= 0) {
      return;
    }
    list.push(alias);
    await TokenVault.writeAliases(list);
  }

  private static async forgetAlias(alias: string): Promise<void> {
    const list: string[] = await TokenVault.aliases();
    const at: number = list.indexOf(alias);
    if (at < 0) {
      return;
    }
    list.splice(at, 1);
    await TokenVault.writeAliases(list);
  }
}
