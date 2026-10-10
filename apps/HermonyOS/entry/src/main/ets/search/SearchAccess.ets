import { Permissions } from '../common/Permissions';
import { MovieClawApi } from '../api/Endpoints';
import { SearchMode } from './SearchResultsPage';

/**
 * 搜索分区权限（对齐 iOS `SearchScope.swift` 的 `SearchAccess`）：
 * - 影视 = `allow_subscribe`（订阅能力与影视搜索同一开关）；
 * - 资源 = `allow_search`；
 * - 媒体库 = 管理员恒开；成员有任一可见库即可（默认成员、儿童账号都能进来搜媒体库）。
 *
 * 由搜索首页在进入时解析一次，模式 chips、提交、历史分区都按它裁剪；
 * 安全部仍在后端 403，这里只管界面裁剪。
 */
export class SearchAccess {
  readonly canMedia: boolean;
  readonly canTorrent: boolean;
  readonly canLibrary: boolean;
  /** 权限是否已核对完成（未核对时页面画加载态，不闪「无权限」） */
  readonly ready: boolean;

  constructor(canMedia: boolean, canTorrent: boolean, canLibrary: boolean, ready: boolean) {
    this.canMedia = canMedia;
    this.canTorrent = canTorrent;
    this.canLibrary = canLibrary;
    this.ready = ready;
  }

  static notReady(): SearchAccess {
    return new SearchAccess(false, false, false, false);
  }

  /** 可用分区，固定顺序：媒体库 → 影视 → 资源（同 iOS `SearchVertical.allCases`） */
  available(): string[] {
    const modes: string[] = [];
    if (this.canLibrary) {
      modes.push(SearchMode.library);
    }
    if (this.canMedia) {
      modes.push(SearchMode.media);
    }
    if (this.canTorrent) {
      modes.push(SearchMode.torrent);
    }
    return modes;
  }

  allows(mode: string): boolean {
    if (mode === SearchMode.library) {
      return this.canLibrary;
    }
    if (mode === SearchMode.media) {
      return this.canMedia;
    }
    if (mode === SearchMode.torrent) {
      return this.canTorrent;
    }
    return false;
  }

  /**
   * 解析当前账号的搜索分区权限（同 iOS `SearchAccess.resolve`）。
   * 成员的媒体库分区要查一次可见库；库列表请求失败按「无库」处理，不阻塞其它分区。
   */
  static async resolve(api: MovieClawApi | null, permissions: Permissions): Promise<SearchAccess> {
    let canLibrary: boolean = permissions.isAdmin;
    if (!permissions.isAdmin && api !== null) {
      try {
        const libraries = await api.libraryList(undefined, 'all');
        canLibrary = libraries.length > 0;
      } catch (error) {
        canLibrary = false;
      }
    }
    return new SearchAccess(permissions.canSubscribe, permissions.canSearch, canLibrary, true);
  }
}
