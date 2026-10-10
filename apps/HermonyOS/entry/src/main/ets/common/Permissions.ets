import { SessionView } from '../api/Models';

/**
 * 权限快照（对齐 iOS 端 Core/Session/Permissions.swift 与 Web lib/permissions.ts）：
 * 客户端据此裁剪入口，安全边界仍在后端 403。
 *
 * 管理员恒为全开；成员按 capabilities 快照裁剪。
 */
export class Permissions {
  readonly isAdmin: boolean;
  readonly canSubscribe: boolean;
  readonly canSearch: boolean;
  readonly canDirectDownload: boolean;

  private constructor(isAdmin: boolean, canSubscribe: boolean, canSearch: boolean, canDirectDownload: boolean) {
    this.isAdmin = isAdmin;
    this.canSubscribe = canSubscribe;
    this.canSearch = canSearch;
    this.canDirectDownload = canDirectDownload;
  }

  /** 管理员全开、成员按能力开关；会话缺失时全关（只渲染欢迎页，不会走到这里） */
  static fromSession(session: SessionView | null): Permissions {
    if (session === null) {
      return Permissions.none();
    }
    const isAdmin: boolean = session.role === 'admin';
    return new Permissions(
      isAdmin,
      isAdmin || session.capabilities.allow_subscribe,
      isAdmin || session.capabilities.allow_search,
      isAdmin || session.capabilities.allow_direct_download
    );
  }

  static none(): Permissions {
    return new Permissions(false, false, false, false);
  }

  /** 管理媒体库（建库、扫描、成员可见范围等）：仅管理员（同 iOS canManageLibraries） */
  get canManageLibraries(): boolean {
    return this.isAdmin;
  }

  /** 角色标签（同 iOS roleLabel） */
  static roleLabel(session: SessionView): string {
    return session.role === 'admin' ? '超级管理员' : '成员';
  }

  /** 头像徽标字：中文取首字，拉丁字母取前两位大写（同 Web initialsOf） */
  static initialsOf(nickname: string): string {
    const name: string = nickname.trim();
    if (name.length === 0) {
      return '?';
    }
    const first: string = name.charAt(0);
    const code: number = first.charCodeAt(0);
    if (code >= 0x4E00 && code <= 0x9FFF) {
      return first;
    }
    return name.substring(0, 2).toUpperCase();
  }
}
