// 单库页（LibraryDetailPage）的路由参数，单独成文件：库墙与条目详情页（演员卡进同库墙）都要用它，
// 放在页面文件里会让两个页面互相 import，ArkTS 有循环依赖的风险。
import { LibraryFilter } from './LibraryWall';

/** 单库页路由参数 */
export class LibraryRouteParams {
  readonly libraryId: number;
  readonly watch: string | null;
  readonly sort: string | null;
  readonly reversed: boolean;
  /** 进页即按这个演员名筛墙（详情页里没有影人 id 的演员卡带过来；null = 不筛） */
  readonly actor: string | null;

  constructor(libraryId: number, watch: string | null = null, sort: string | null = null, reversed: boolean = false,
    actor: string | null = null) {
    this.libraryId = libraryId;
    this.watch = watch;
    this.sort = sort;
    this.reversed = reversed;
    this.actor = actor;
  }

  /** 演员卡进同库墙：只带库 id 与演员名 */
  static forActor(libraryId: number, actor: string): LibraryRouteParams {
    return new LibraryRouteParams(libraryId, null, null, false, actor);
  }

  /**
   * 从 NavDestination 的路由参数里取出库 id；取不到返回 0。
   *
   * **不要用 `param instanceof LibraryRouteParams` 判断**：`pushPathByName` 传过来的参数
   * 会被序列化，到 `onReady` 时已经是个普通对象（真机/模拟器实测 `{"libraryId":1}`，
   * `instanceof` 恒为 false）。用它判断的话判断永远不成立、`start()` 永远不跑，
   * 页面就一直是「正在加载媒体库…」——这正是电影库/剧集库点进去没反应的原因。
   * 所以按字段取值并校验，不依赖原型链。
   */
  static idOf(param: Object | undefined | null): number {
    if (param === undefined || param === null) {
      return 0;
    }
    const raw: number = (param as LibraryRouteParams).libraryId;
    return Number.isFinite(raw) && raw > 0 ? Math.floor(raw) : 0;
  }

  /** 同 idOf 按字段取：路由带来的演员名（去首尾空白，空串 / 非字符串 = 不筛） */
  static actorOf(param: Object | undefined | null): string | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: string | null | undefined = (param as LibraryRouteParams).actor;
    return typeof raw === 'string' ? LibraryFilter.normalizeActor(raw) : null;
  }
}

