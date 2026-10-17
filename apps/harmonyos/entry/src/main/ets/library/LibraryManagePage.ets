import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { ImageUrls } from '../common/ImageUrls';
import { RemoteImage } from '../common/RemoteImage';
import { JsonList, JsonValue, jsonArrayValue, jsonStringValue } from '../api/JsonValue';
import {
  ChapterJobView,
  DuplicateFilesData,
  LastScanView,
  LibraryPayload,
  LibraryReorderPayload,
  LibraryView,
  MetadataRefreshView,
  ScanProgressView,
  ShareView,
  TrashedFilesData
} from '../api/Models';
import { LibraryKindMeta, ScanPhase, libraryBytes, libraryFromNow } from './LibraryShared';
import { RecycleBinContent } from './RecycleBinPage';
import { DuplicatesContent } from './DuplicatesPage';
import { ManageSharesTab } from './ManageSharesTab';
import { LibraryFormSheet } from './LibraryFormSheet';
import { OrganizeSheet } from './OrganizeSheet';
import { IssueParams } from './IssueDrawerPage';
import { LibraryRouteParams } from './LibraryDetailPage';

/**
 * 媒体库管理页（对应 iOS `Features/Library/LibraryManageView.swift`，口径即 Web `library-manage-view.tsx`）。
 *
 * 页面回答的第一个问题是「有没有事要我管」：页头摘要里只挂两枚带色胶囊——在跑任务、
 * 有待处理文件——点即筛选；两样都没有就写「一切正常」。四个页签：
 * - 媒体库：搜索（库名 / 根目录）+ 类型筛选 + 一库一行，所有操作收进行尾 ⋯ 菜单；
 *   手机上没有拖拽，排序走菜单里的「调整顺序」（上下按钮面板，确认后整单提交）；
 * - 回收站 / 重复文件 / 分享：复用各自的内容组件（`RecycleBinContent` 等）。
 *
 * 数据只用 `GET /libraries` 一个接口（随库下发的统计快照与任务进度足够填满状态列）。
 * 轮询节奏同 Web：任务中 3 秒（结束后再快轮询 12 秒）/ 刷新元数据 5 秒 / 入库中 10 秒 / 空闲 30 秒。
 * 页签计数：回收站与分享在别的页签时 30 秒低频轮询，重复文件只在进页与切页签时读一次
 * （结论只在扫描后才变）。鸿蒙没有 SSE，全靠轮询（延续前几批的决定）。
 */

/** 管理页的路由参数（会序列化，不要用 instanceof） */
export class ManageParams {
  /** 初始页签：'' 用默认（媒体库）；只在进页时应用一次 */
  readonly tab: string;

  constructor(tab: string) {
    this.tab = tab;
  }

  static of(param: Object | undefined | null): ManageParams {
    if (param === undefined || param === null) {
      return new ManageParams('');
    }
    const raw: ManageParams = param as ManageParams;
    const tab: string = raw.tab;
    return new ManageParams(typeof tab === 'string' ? tab : '');
  }
}

/** 页签常量（取值与 Web / iOS 的 Tab.rawValue 一致） */
class ManageTab {
  static readonly libraries: string = 'libraries';
  static readonly recycle: string = 'recycle';
  static readonly duplicates: string = 'duplicates';
  static readonly shares: string = 'shares';

  static label(tab: string): string {
    if (tab === ManageTab.libraries) {
      return '媒体库';
    }
    if (tab === ManageTab.recycle) {
      return '回收站';
    }
    if (tab === ManageTab.duplicates) {
      return '重复文件';
    }
    return '分享';
  }
}

/**
 * 一行库的状态归类（iOS `ManageLibraryStatus`）。优先级自上而下取第一个命中：
 * 扫描 → 整理 → 刷新元数据 → 生成章节 → 入库中 → 有缺失 → 有待识别 → 空闲。
 * 前三种长任务互斥（共用一把库级锁）；生成章节是低优先级后台作业，常排在它们后面。
 */
class ManageStatus {
  static readonly idle: string = 'idle';
  static readonly busy: string = 'busy';
  static readonly pending: string = 'pending';
  static readonly missing: string = 'missing';

  readonly tone: string;
  readonly kind: string;
  /** 主文案 */
  readonly title: string;
  /** 补充文案；没有则为空串 */
  readonly detail: string;
  /** 0-100 的进度；分母未知或非进度型状态为 null */
  readonly percent: number | null;

  constructor(tone: string, kind: string, title: string, detail: string, percent: number | null) {
    this.tone = tone;
    this.kind = kind;
    this.title = title;
    this.detail = detail;
    this.percent = percent;
  }

  static of(library: LibraryView): ManageStatus {
    if (library.scanning) {
      const p: ScanProgressView | null = library.scan_progress ?? null;
      const percent: number | null = p === null ? null : ManageStatus.percentOf(p.processed, p.total);
      const label: string = p === null ? '正在扫描' : ScanPhase.label(p.phase);
      const detail: string = p !== null && p.total > 0
        ? `${p.processed} / ${p.total}` : '正在统计待处理的文件数';
      return new ManageStatus(ManageStatus.busy, 'scan',
        percent === null ? label : `${label} ${percent}%`, detail, percent);
    }
    if (library.organizing) {
      const p: ScanProgressView | null = library.organize_progress ?? null;
      const percent: number | null = p === null ? null : ManageStatus.percentOf(p.processed, p.total);
      const detail: string = p !== null && p.total > 0 ? `${p.processed} / ${p.total}` : '';
      return new ManageStatus(ManageStatus.busy, 'organize',
        percent === null ? '正在整理文件名' : `正在整理文件名 ${percent}%`, detail, percent);
    }
    const refresh: MetadataRefreshView | null = library.metadata_refresh ?? null;
    if (refresh !== null && refresh.refreshing) {
      const percent: number | null = ManageStatus.percentOf(refresh.processed, refresh.total);
      const title: string = refresh.stopping
        ? '正在停止刷新' : (percent === null ? '刷新元数据' : `刷新元数据 ${percent}%`);
      const detail: string = refresh.active.length > 0
        ? `正在处理「${refresh.active[0].title}」· ${refresh.active[0].phase}`
        : `${refresh.processed} / ${refresh.total}`;
      return new ManageStatus(ManageStatus.busy, 'refresh', title, detail, percent);
    }
    const job: ChapterJobView | null = library.chapter_job ?? null;
    if (job !== null) {
      const running: boolean = ManageStatus.chapterJobRunning(job);
      let detail: string;
      if (!running) {
        detail = '等前面的任务跑完再开始';
      } else if (job.total > 0) {
        detail = `${job.processed} / ${job.total}` + (job.failed > 0 ? ` · ${job.failed} 个失败` : '');
      } else {
        detail = '正在统计待处理的文件数';
      }
      return new ManageStatus(ManageStatus.busy, 'chapters', ManageStatus.chapterJobLabel(job), detail,
        running ? ManageStatus.percentOf(job.processed, job.total) : null);
    }
    const scan: LastScanView | null = library.last_scan ?? null;
    const deferred: number = scan === null ? 0 : scan.deferred;
    if (deferred > 0) {
      return new ManageStatus(ManageStatus.busy, 'importing',
        `${deferred} 个新文件入库中`, '等文件写完自动补扫', null);
    }
    const unidentified: number = library.stats.unidentified_count;
    const missing: number = library.stats.missing_count;
    if (missing > 0) {
      const title: string = unidentified > 0
        ? `${unidentified} 个待识别 · ${missing} 个缺失` : `${missing} 个缺失`;
      return new ManageStatus(ManageStatus.missing, 'missing', title,
        ManageStatus.lastScanDetail(library), null);
    }
    if (unidentified > 0) {
      return new ManageStatus(ManageStatus.pending, 'unidentified',
        `${unidentified} 个待识别`, ManageStatus.lastScanDetail(library), null);
    }
    // 空闲不是需要看的状态：只留「最近扫描 X 前」这行事实
    return new ManageStatus(ManageStatus.idle, 'idle', '空闲', ManageStatus.lastScanDetail(library), null);
  }

  static percentOf(processed: number, total: number): number | null {
    if (total <= 0) {
      return null;
    }
    return Math.min(100, Math.round(processed / total * 100));
  }

  /**
   * 「最近扫描 X 前 · 结论」：扫描常毫秒级完成，只写时间的话一个本就最新的库扫完前后长得一模一样，
   * 用户会以为没点上——结论挑用户关心的：新增几个文件、标记几个缺失；都没有就明说「无新文件」
   */
  static lastScanDetail(library: LibraryView): string {
    const scan: LastScanView | null = library.last_scan ?? null;
    if (scan === null) {
      return '尚未扫描';
    }
    const parts: string[] = [`最近扫描 ${libraryFromNow(scan.finished_at)}`];
    if (scan.cancelled) {
      parts.push('手动停止');
    }
    if (scan.scanned > 0) {
      parts.push(`新增 ${scan.scanned} 个文件`);
    }
    if (scan.marked_missing > 0) {
      parts.push(`标记缺失 ${scan.marked_missing}`);
    }
    if (!scan.cancelled && scan.scanned === 0 && scan.marked_missing === 0) {
      parts.push('无新文件');
    }
    return parts.join(' · ');
  }

  static chapterJobRunning(job: ChapterJobView): boolean {
    return job.status === 'running' || job.status === 'cancelling';
  }

  /** 「生成章节」菜单项与状态列共用的一句话：没作业时是动作名，有作业时如实说到哪了 */
  static chapterJobLabel(job: ChapterJobView | null): string {
    if (job === null) {
      return '生成章节';
    }
    if (job.stopping) {
      return '正在停止生成章节';
    }
    if (!ManageStatus.chapterJobRunning(job)) {
      return '生成章节排队中';
    }
    const percent: number | null = ManageStatus.percentOf(job.processed, job.total);
    return percent === null ? '正在生成章节' : `正在生成章节 ${percent}%`;
  }
}

/** 管理页的纯逻辑（iOS `ManageLibraryRules` / Web `lib/library-manage.ts`），改口径请两端一起改 */
class ManageRules {
  static readonly kindOrder: string[] = ['movie', 'tv', 'video', 'photo'];

  /** 是否有长任务在跑（摘要「N 个在跑任务」与筛选用） */
  static isBusy(library: LibraryView): boolean {
    const refresh: MetadataRefreshView | null = library.metadata_refresh ?? null;
    const job: ChapterJobView | null = library.chapter_job ?? null;
    return library.scanning || library.organizing
      || (refresh !== null && refresh.refreshing) || job !== null;
  }

  /** 是否有要你动手的文件（待识别或缺失）。任务在跑或还在入库时状态归进度，不算「待处理」 */
  static needsAttention(library: LibraryView): boolean {
    if (ManageRules.isBusy(library)) {
      return false;
    }
    const scan: LastScanView | null = library.last_scan ?? null;
    if (scan !== null && scan.deferred > 0) {
      return false;
    }
    return library.stats.unidentified_count > 0 || library.stats.missing_count > 0;
  }

  /** 可见范围文案：只说库开放给谁；「你本人在不在浏览范围内」由锁图标表达，不混进文字 */
  static accessLabel(library: LibraryView): string {
    if (library.access_mode === 'everyone') {
      return '全部成员';
    }
    if (library.member_ids.length > 0) {
      return `指定成员 ${library.member_ids.length}`;
    }
    return library.admin_visible ? '仅自己' : '无人可见';
  }

  /** 可见范围偏离默认（对全部成员开放、你自己也能看）才在行内挂胶囊 */
  static accessRestricted(library: LibraryView): boolean {
    return library.access_mode !== 'everyone' || !library.viewer_access;
  }

  /** 库名下的配置备注：只说偏离默认的部分（首页展示、实时监控开是默认，关了才说） */
  static configNotes(library: LibraryView): string[] {
    const notes: string[] = [];
    if (library.exclude_from_home) {
      notes.push('从首页排除');
    }
    if (!library.realtime_watch) {
      notes.push('实时监控关');
    }
    return notes;
  }

  /** 库存主数：影视库按「部」、图片库按「张」、其他库按「个条目」 */
  static inventory(library: LibraryView): string {
    const unit: string = library.kind === 'photo' ? '张' : library.kind === 'video' ? '个条目' : '部';
    return `${library.stats.item_count} ${unit}`;
  }

  /** 把 from 位置的元素挪到 to（其余相对顺序不变）；越界或原地返回 null */
  static move(list: LibraryView[], from: number, to: number): LibraryView[] | null {
    if (from === to || from < 0 || to < 0 || from >= list.length || to >= list.length) {
      return null;
    }
    const next: LibraryView[] = list.slice();
    const item: LibraryView = next[from];
    next.splice(from, 1);
    next.splice(to, 0, item);
    return next;
  }

  /**
   * 同类型两库的收藏范围可能同时命中同一部作品且条件数相同——命中顺序只能靠创建先后。
   * 只读提示（不阻断），并点名给创建更晚的那个库补上它缺的维度（Web `routingOverlapWarnings`）。
   * 值的相等判断用 JSON.stringify（鸿蒙不能给 JsonValue 上 `contains`，数组/对象也不可比）。
   */
  static routingOverlapWarnings(libraries: LibraryView[]): string[] {
    const declared: LibraryView[] =
      libraries.filter((library: LibraryView): boolean => library.match_rules.length > 0);
    const fieldLabels: string[][] = [['genres', '类型'], ['origin_countries', '区域']];
    const warnings: string[] = [];
    for (let i = 0; i < declared.length; i++) {
      for (let j = i + 1; j < declared.length; j++) {
        const a: LibraryView = declared[i];
        const b: LibraryView = declared[j];
        if (a.kind !== b.kind || a.match_rules.length !== b.match_rules.length) {
          continue;
        }
        const compatible: boolean = a.match_rules.every((ra: Record<string, JsonValue>): boolean => {
          const field: string | null = jsonStringValue(ra['field']);
          let rb: Record<string, JsonValue> | undefined = undefined;
          for (const rule of b.match_rules) {
            if (jsonStringValue(rule['field']) === field) {
              rb = rule;
              break;
            }
          }
          if (rb === undefined) {
            return true;
          }
          const valuesA: JsonList | null = jsonArrayValue(ra['values']);
          const valuesB: JsonList | null = jsonArrayValue(rb['values']);
          if (valuesA === null || valuesB === null) {
            return false;
          }
          return valuesA.some((va: JsonValue): boolean =>
            valuesB.some((vb: JsonValue): boolean => JSON.stringify(va) === JSON.stringify(vb)));
        });
        if (!compatible) {
          continue;
        }
        const first: LibraryView = a.id < b.id ? a : b;
        const later: LibraryView = a.id < b.id ? b : a;
        const laterFields: string[] = [];
        for (const rule of later.match_rules) {
          const field: string | null = jsonStringValue(rule['field']);
          if (field !== null) {
            laterFields.push(field);
          }
        }
        const missing: string[] = [];
        for (const pair of fieldLabels) {
          if (laterFields.indexOf(pair[0]) < 0) {
            missing.push(pair[1]);
          }
        }
        const fix: string = missing.length === 0
          ? '两库已声明相同的维度：错开重叠的取值即可消除歧义。'
          : `想让「${later.name}」优先收这类作品：编辑它，补上「${missing.join('」或「')}」条件`
            + '（用「全选」也可以）——条件多的库优先命中；想维持现状则无需改动。';
        warnings.push(`「${a.name}」与「${b.name}」的收藏范围可能同时命中同一部作品且条件数相同，`
          + `届时优先进创建更早的「${first.name}」。${fix}`);
      }
    }
    return warnings;
  }
}

/** 管理页各处共用的确认文案（Web `lib/library-confirm.ts`）：短导语 + 动作清单，最后一条讲安全边界 */
class ManageConfirmText {
  static bullets(lead: string, items: string[]): string {
    const lines: string[] = [lead];
    for (const item of items) {
      lines.push(`• ${item}`);
    }
    return lines.join('\n');
  }

  static scanText(): string {
    return ManageConfirmText.bullets('本次扫描会检查库文件夹的最新变化：', [
      '找出新增的影片文件，自动识别并加入媒体库',
      '标记已经不在硬盘上的文件（记录保留，文件回来自动恢复）',
      '为新入库的影片补齐简介、海报等信息',
      '首次扫描会读取每个文件的画质与音轨信息，文件多时较慢、可随时停止',
      '不会移动、修改或删除你的任何文件'
    ]);
  }

  static refreshText(): string {
    return ManageConfirmText.bullets('本次刷新会为库里的全部影片：', [
      '重新获取最新的简介、评分、演职员和剧集信息',
      '海报或背景图有更新时重新下载（你手动锁定的不动）',
      '同步更新影片文件夹里的海报和 NFO 信息文件',
      '影片较多时需要一段时间，可随时停止',
      '不会移动、修改或删除你的视频文件'
    ]);
  }

  static rereadNfoText(): string {
    return ManageConfirmText.bullets('本次会为库里的全部视频：', [
      '重新读取视频旁同名的 NFO 文件，标题、简介、系列等以 NFO 为准',
      'NFO 里写了系列（<set>）的，按库设置自动归进系列合集',
      '重新生成封面',
      '不联网，不会修改或删除你的文件'
    ]);
  }

  static chaptersText(): string {
    return ManageConfirmText.bullets('后台低优先级执行，可在任务中心观察或取消：', [
      '只处理章节图还缺的文件（含上次没抓完、图丢了的），已经齐的不动',
      '每个文件按章节数定位读取若干次，网络挂载的库会有读取流量',
      '不会移动、修改或删除你的视频文件'
    ]) + '\n\n选「已有的章节也重新生成」会按当前章节与合成策略全部重新生成，你手动选定的图不会被覆盖。';
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function ManageBuilder() {
  LibraryManagePage()
}

@ComponentV2
struct LibraryManagePage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  private shownOnce: boolean = false;
  private permissions: Permissions = Permissions.none();
  private mainTimer: number = -1;
  private countTimer: number = -1;
  private reloadSeq: number = 0;

  @Local private tab: string = ManageTab.libraries;
  @Local private libraries: LibraryView[] | null = null;
  @Local private failed: boolean = false;
  /** 页签计数（-1 = 还不知道，不显示数字） */
  @Local private recycleCount: number = -1;
  @Local private duplicateCount: number = -1;
  @Local private shareCount: number = -1;
  /** 扫描/整理结束后的 12 秒快轮询窗口（ms 时间戳） */
  @Local private busyUntil: number = 0;
  /** 库列表筛选：搜索词 / 类型 / 页头摘要胶囊（busy / attention） */
  @Local private query: string = '';
  @Local private kindFilter: string = '';
  @Local private focus: string = '';

  /** 弹层槽位：空串=关，edit=编辑库，organize=整理文件名，reorder=调整顺序，chapters=生成章节 */
  @Local private sheetKind: string = '';
  @Local private showSheet: boolean = false;
  @Local private sheetTargetId: number = 0;
  @Local private sheetTargetName: string = '';
  /** 排序面板的顺序草稿（面板内持有，取消不影响列表） */
  @Local private reorderDraft: LibraryView[] = [];

  aboutToAppear(): void {
    this.permissions = Permissions.fromSession(AppModel.shared.session);
  }

  aboutToDisappear(): void {
    this.stopMainPoll();
    this.stopCountPoll();
  }

  private stopMainPoll(): void {
    if (this.mainTimer >= 0) {
      clearTimeout(this.mainTimer);
      this.mainTimer = -1;
    }
  }

  private stopCountPoll(): void {
    if (this.countTimer >= 0) {
      clearTimeout(this.countTimer);
      this.countTimer = -1;
    }
  }

  /** 主轮询：节奏自适应（任务中 3 秒 / 刷新元数据 5 秒 / 入库中 10 秒 / 空闲 30 秒） */
  private scheduleMainPoll(): void {
    this.stopMainPoll();
    this.mainTimer = setTimeout((): void => {
      this.mainTimer = -1;
      this.reload();
    }, this.pollInterval() * 1000);
  }

  private pollInterval(): number {
    const all: LibraryView[] = this.libraries ?? [];
    for (const item of all) {
      if (item.scanning || item.organizing) {
        return 3;
      }
    }
    if (Date.now() < this.busyUntil) {
      return 3;
    }
    for (const item of all) {
      const refresh: MetadataRefreshView | null = item.metadata_refresh ?? null;
      if (refresh !== null && refresh.refreshing) {
        return 5;
      }
    }
    for (const item of all) {
      const scan: LastScanView | null = item.last_scan ?? null;
      if (!item.scanning && !item.organizing && scan !== null && scan.deferred > 0) {
        return 10;
      }
    }
    return 30;
  }

  /** 计数轮询：回收站与分享在别的页签时 30 秒低频拉一次（激活的页签由内容组件自己回报） */
  private startCountPoll(): void {
    this.stopCountPoll();
    this.countTimer = setTimeout((): void => {
      this.countTimer = -1;
      if (this.tab !== ManageTab.recycle) {
        this.reloadRecycleCount();
      }
      if (this.tab !== ManageTab.shares) {
        this.reloadShareCount();
      }
      this.startCountPoll();
    }, 30000);
  }

  // MARK: 派生

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private libraryCount(): number {
    return this.libraries === null ? -1 : this.libraries.length;
  }

  private summaryFacts(): string {
    const all: LibraryView[] = this.libraries ?? [];
    if (all.length === 0) {
      return '还没有媒体库';
    }
    let items: number = 0;
    let bytes: number = 0;
    for (const library of all) {
      items += library.stats.item_count;
      bytes += library.stats.total_size_bytes;
    }
    return `${all.length} 个媒体库 · ${items} 个条目 · ${libraryBytes(bytes)}`;
  }

  private busyCount(): number {
    const all: LibraryView[] = this.libraries ?? [];
    let count: number = 0;
    for (const library of all) {
      if (ManageRules.isBusy(library)) {
        count += 1;
      }
    }
    return count;
  }

  private attentionCount(): number {
    const all: LibraryView[] = this.libraries ?? [];
    let count: number = 0;
    for (const library of all) {
      if (ManageRules.needsAttention(library)) {
        count += 1;
      }
    }
    return count;
  }

  private attentionMissing(): boolean {
    const all: LibraryView[] = this.libraries ?? [];
    for (const library of all) {
      if (ManageRules.needsAttention(library) && library.stats.missing_count > 0) {
        return true;
      }
    }
    return false;
  }

  private kindCount(kind: string): number {
    const all: LibraryView[] = this.libraries ?? [];
    let count: number = 0;
    for (const library of all) {
      if (kind.length === 0 || library.kind === kind) {
        count += 1;
      }
    }
    return count;
  }

  /** 客户端筛选：库的规模在几十以内，一次全拉后本地过滤即可；搜索匹配库名或任一根目录 */
  private visibleLibraries(): LibraryView[] {
    const all: LibraryView[] = this.libraries ?? [];
    const q: string = this.query.trim().toLowerCase();
    const result: LibraryView[] = [];
    for (const library of all) {
      if (this.kindFilter.length > 0 && library.kind !== this.kindFilter) {
        continue;
      }
      if (this.focus === 'busy' && !ManageRules.isBusy(library)) {
        continue;
      }
      if (this.focus === 'attention' && !ManageRules.needsAttention(library)) {
        continue;
      }
      if (q.length === 0) {
        result.push(library);
        continue;
      }
      if (library.name.toLowerCase().includes(q)) {
        result.push(library);
        continue;
      }
      let hit: boolean = false;
      for (const root of library.root_paths) {
        if (root.toLowerCase().includes(q)) {
          hit = true;
          break;
        }
      }
      if (hit) {
        result.push(library);
      }
    }
    return result;
  }

  private warnings(): string[] {
    const all: LibraryView[] | null = this.libraries;
    return all === null ? [] : ManageRules.routingOverlapWarnings(all);
  }

  private coverUrl(library: LibraryView): string {
    return ImageUrls.resolve(AppModel.origin(),
      `/libraries/${library.id}/cover?v=${library.updated_at}`, null) ?? '';
  }

  private secondLine(library: LibraryView): string {
    const parts: string[] = [LibraryKindMeta.label(library.kind), ManageRules.inventory(library)];
    for (const note of ManageRules.configNotes(library)) {
      parts.push(note);
    }
    return parts.join(' · ');
  }

  private statusTone(library: LibraryView): string {
    return ManageStatus.of(library).tone;
  }

  private statusTitle(library: LibraryView): string {
    return ManageStatus.of(library).title;
  }

  private statusDetail(library: LibraryView): string {
    return ManageStatus.of(library).detail;
  }

  private statusPercent(library: LibraryView): number | null {
    return ManageStatus.of(library).percent;
  }

  private statusColor(library: LibraryView): string {
    return ManageStatus.of(library).tone === 'missing' ? Theme.danger : Theme.warning;
  }

  private statusSoftBg(library: LibraryView): string {
    return ManageStatus.of(library).tone === 'missing'
      ? 'rgba(255, 107, 107, 0.10)' : 'rgba(251, 191, 36, 0.10)';
  }

  private statusBorder(library: LibraryView): string {
    return ManageStatus.of(library).tone === 'missing'
      ? 'rgba(255, 107, 107, 0.35)' : 'rgba(251, 191, 36, 0.35)';
  }

  // MARK: ⋯ 菜单标签与可用性（是否可用由行内按当前状态判定，同 iOS）

  private scanMenuLabel(library: LibraryView): string {
    if (!library.scanning) {
      return '扫描库';
    }
    const progress: ScanProgressView | null = library.scan_progress ?? null;
    if (progress !== null && progress.phase === 'reidentifying') {
      return `${ScanPhase.label(progress.phase)}…`;
    }
    const percent: number | null = progress === null
      ? null : ManageStatus.percentOf(progress.processed, progress.total);
    return percent === null ? '停止扫描' : `停止扫描 ${percent}%`;
  }

  private scanMenuEnabled(library: LibraryView): boolean {
    if (library.scanning) {
      // 重识别占同一把库级锁但不接受中途停止（后端会拒绝），入口置灰并如实标出
      const progress: ScanProgressView | null = library.scan_progress ?? null;
      return progress !== null && progress.phase !== 'reidentifying';
    }
    const refresh: MetadataRefreshView | null = library.metadata_refresh ?? null;
    return !library.organizing && !(refresh !== null && refresh.refreshing);
  }

  private pendingMenuLabel(library: LibraryView): string {
    // 库快照只有文件级计数（待识别 + 缺失）；单位写明，免得与单库页按分组数的「待处理 N」混为一谈
    const count: number = library.stats.unidentified_count + library.stats.missing_count;
    return count > 0 ? `待处理 · ${count} 个文件` : '待处理';
  }

  private organizeMenuLabel(library: LibraryView): string {
    if (!library.organizing) {
      return '整理文件名';
    }
    const p: ScanProgressView | null = library.organize_progress ?? null;
    const percent: number | null = p === null ? null : ManageStatus.percentOf(p.processed, p.total);
    return percent === null ? '整理中…' : `整理中… ${percent}%`;
  }

  private organizeMenuEnabled(library: LibraryView): boolean {
    const refresh: MetadataRefreshView | null = library.metadata_refresh ?? null;
    const busy: boolean = library.scanning || library.organizing
      || (refresh !== null && refresh.refreshing);
    return !busy || library.organizing;
  }

  private refreshMenuLabel(library: LibraryView): string {
    const refresh: MetadataRefreshView | null = library.metadata_refresh ?? null;
    if (refresh !== null && refresh.refreshing) {
      const percent: number | null = ManageStatus.percentOf(refresh.processed, refresh.total);
      return percent === null ? '停止刷新' : `停止刷新 ${percent}%`;
    }
    return library.capabilities.scraped ? '刷新元数据'
      : library.capabilities.playable ? '重新读取 NFO 与封面' : '重新生成封面';
  }

  private refreshMenuEnabled(library: LibraryView): boolean {
    const refresh: MetadataRefreshView | null = library.metadata_refresh ?? null;
    const refreshing: boolean = refresh !== null && refresh.refreshing;
    const busy: boolean = library.scanning || library.organizing || refreshing;
    return !busy || refreshing;
  }

  private chaptersMenuLabel(library: LibraryView): string {
    return ManageStatus.chapterJobLabel(library.chapter_job ?? null);
  }

  private chaptersMenuEnabled(library: LibraryView): boolean {
    const refresh: MetadataRefreshView | null = library.metadata_refresh ?? null;
    const busy: boolean = library.scanning || library.organizing
      || (refresh !== null && refresh.refreshing);
    return !busy && (library.chapter_job ?? null) === null;
  }

  // MARK: 行动作

  /** 动作统一收口：成功后立刻拉一次列表（可选给一句回执），失败用 Toast 报后端的中文错误 */
  private async run(done: string | null, action: () => Promise<void>): Promise<void> {
    try {
      await action();
      await this.reload();
      if (done !== null) {
        this.toast(done);
      }
    } catch (error) {
      this.toast(this.messageOf(error));
    }
  }

  /** 页头摘要胶囊即筛选：再点一次取消 */
  private toggleFocus(focus: string): void {
    this.focus = this.focus === focus ? '' : focus;
    this.tab = ManageTab.libraries;
  }

  private clearFilter(): void {
    this.query = '';
    this.kindFilter = '';
    this.focus = '';
  }

  private applyTab(tab: string): void {
    if (this.tab === tab) {
      return;
    }
    this.tab = tab;
    // 重复文件的结论只在扫描后才变：进页与切页签时读一次即可，不做常驻轮询
    this.reloadDuplicateCount();
  }

  private openLibrary(library: LibraryView): void {
    this.navStack.pushPathByName('libraryDetail', new LibraryRouteParams(library.id));
  }

  /** 打开待处理清单：落点按缺失 → 待识别由实际计数决定（只有待识别的库不会落到空页签） */
  private openPending(library: LibraryView): void {
    const tab: string = library.stats.missing_count > 0 ? 'missing' : 'unidentified';
    this.navStack.pushPathByName('issueDrawer',
      new IssueParams(library.id, tab, library.kind === 'movie'));
  }

  /** 重操作先确认；停止不确认——停止本身就是在纠正。开始给一句回执：扫描毫秒级就结束时行内只有时间在变 */
  private toggleScan(library: LibraryView): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    if (library.scanning) {
      this.run(null, (): Promise<void> => api.libraryScanStop(library.id).then((): void => {
      }));
      return;
    }
    this.getUIContext().showAlertDialog({
      title: `扫描「${library.name}」？`,
      message: ManageConfirmText.scanText(),
      primaryButton: {
        value: '开始扫描',
        fontColor: Theme.accentStrong,
        action: (): void => {
          this.run(`已开始扫描「${library.name}」`, (): Promise<void> =>
            api.libraryScanStart(library.id).then((): void => {
            }));
        }
      },
      secondaryButton: {
        value: '取消',
        action: (): void => {
        }
      }
    });
  }

  private toggleRefresh(library: LibraryView): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const refresh: MetadataRefreshView | null = library.metadata_refresh ?? null;
    if (refresh !== null && refresh.refreshing) {
      this.run(null, (): Promise<void> =>
        api.libraryMetadataStopRefresh(library.id).then((): void => {
        }));
      return;
    }
    const caps = library.capabilities;
    const nfo: boolean = !caps.scraped && caps.playable;
    this.getUIContext().showAlertDialog({
      title: nfo ? `重新读取「${library.name}」的 NFO 与封面？` : `刷新「${library.name}」的元数据？`,
      message: nfo ? ManageConfirmText.rereadNfoText() : ManageConfirmText.refreshText(),
      primaryButton: {
        value: nfo ? '开始读取' : '开始刷新',
        fontColor: Theme.accentStrong,
        action: (): void => {
          this.run(null, (): Promise<void> =>
            api.libraryMetadataRefreshLibrary(library.id).then((): void => {
            }));
        }
      },
      secondaryButton: {
        value: '取消',
        action: (): void => {
        }
      }
    });
  }

  private setDefault(library: LibraryView): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.run(`已将「${library.name}」设为默认库`, (): Promise<void> =>
      api.librarySetDefault(library.id).then((): void => {
      }));
  }

  /** 首页显示开关：只改这一个字段——payload 里没传的字段后端按「不改动」处理（同 Web） */
  private toggleHome(library: LibraryView): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const payload: LibraryPayload = {
      name: library.name,
      kind: library.kind,
      exclude_from_home: !library.exclude_from_home,
      root_paths: library.root_paths
    };
    const done: string = library.exclude_from_home
      ? `「${library.name}」已在首页展示` : `「${library.name}」已从首页排除`;
    this.run(done, (): Promise<void> => api.libraryUpdate(library.id, payload).then((): void => {
    }));
  }

  private deleteLibrary(library: LibraryView): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: `删除媒体库「${library.name}」？`,
      message: '磁盘文件不受影响，挂在它上面的订阅将回落到该类型的默认库。',
      primaryButton: {
        value: '先不',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除库',
        fontColor: Theme.danger,
        action: (): void => {
          this.run(`已删除媒体库「${library.name}」`, (): Promise<void> =>
            api.libraryDelete(library.id).then((): void => {
            }));
        }
      }
    });
  }

  private startChapters(force: boolean): void {
    const id: number = this.sheetTargetId;
    const name: string = this.sheetTargetName;
    const api: MovieClawApi | null = AppModel.shared.api;
    this.showSheet = false;
    this.sheetKind = '';
    if (api === null) {
      return;
    }
    api.libraryChapterImagesGenerate(id, force).then((): void => {
      this.toast(force
        ? `已开始为「${name}」重新生成章节，可在任务中心查看进度`
        : `已开始为「${name}」生成章节，可在任务中心查看进度`);
      this.reload();
    }).catch((error: Error): void => {
      this.toast(this.messageOf(error));
    });
  }

  // MARK: 弹层

  private openSheet(kind: string, library: LibraryView | null): void {
    this.sheetTargetId = library === null ? 0 : library.id;
    this.sheetTargetName = library === null ? '' : library.name;
    this.sheetKind = kind;
    this.showSheet = true;
  }

  private openReorder(): void {
    this.reorderDraft = (this.libraries ?? []).slice();
    this.openSheet('reorder', null);
  }

  private moveDraft(from: number, to: number): void {
    const next: LibraryView[] | null = ManageRules.move(this.reorderDraft, from, to);
    if (next !== null) {
      this.reorderDraft = next;
    }
  }

  private orderChanged(): boolean {
    const all: LibraryView[] = this.libraries ?? [];
    if (all.length !== this.reorderDraft.length) {
      return false;
    }
    for (let i = 0; i < all.length; i++) {
      if (all[i].id !== this.reorderDraft[i].id) {
        return false;
      }
    }
    return true;
  }

  /** 提交新顺序：先乐观换位，失败回滚。全量 id 一次提交（后端接口要求） */
  private commitOrder(): void {
    const next: LibraryView[] = this.reorderDraft.slice();
    const previous: LibraryView[] = this.libraries ?? [];
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.libraries = next;
    const payload: LibraryReorderPayload = {
      ordered_ids: next.map((library: LibraryView): number => library.id)
    };
    api.libraryReorder(payload).then((): void => {
      this.toast('顺序已更新，首页「我的媒体库」同步生效');
      this.reload();
    }).catch((error: Error): void => {
      this.libraries = previous;
      this.toast(this.messageOf(error));
    });
  }

  // MARK: 加载

  private start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.reload();
    this.reloadRecycleCount();
    this.reloadShareCount();
    this.reloadDuplicateCount();
    this.startCountPoll();
  }

  private async reload(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    // 轮询乱序守卫：扫描期间慢响应可能晚于下一轮到达
    this.reloadSeq += 1;
    const seq: number = this.reloadSeq;
    try {
      const libs: LibraryView[] = await api.libraryList(undefined, 'all');
      if (seq !== this.reloadSeq) {
        return;
      }
      this.failed = false;
      this.libraries = libs;
      let busy: boolean = false;
      for (const item of libs) {
        if (item.scanning || item.organizing) {
          busy = true;
          break;
        }
      }
      if (busy) {
        this.busyUntil = Date.now() + 12000;
      }
    } catch (error) {
      if (seq === this.reloadSeq) {
        this.failed = true;
      }
    }
    this.scheduleMainPoll();
  }

  /** 回收站计数：一次 limit=1 的列表请求只为拿 total_files */
  private async reloadRecycleCount(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      const data: TrashedFilesData = await api.libraryRecycleList(undefined, undefined, undefined, 1, 0);
      this.recycleCount = data.total_files;
    } catch (error) {
      // 拿不到就先不显示计数，下一轮再试
    }
  }

  /** 重复文件计数：读上一轮扫描落库的结论（limit=0 只要摘要） */
  private async reloadDuplicateCount(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      const data: DuplicateFilesData = await api.libraryDuplicatesList(
        undefined, undefined, undefined, undefined, undefined, 0, 0);
      this.duplicateCount = data.total_files;
    } catch (error) {
      // 拿不到就先不显示计数，下一轮再试
    }
  }

  private async reloadShareCount(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      const rows: ShareView[] = await api.sharesList();
      this.shareCount = rows.length;
    } catch (error) {
      // 拿不到就先不显示计数，下一轮再试
    }
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        PageTopBar({ title: '媒体库管理', onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.permissions.canManageLibraries) {
          this.PageContent()
        } else {
          this.DeniedState()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      if (!this.started) {
        const params: ManageParams = ManageParams.of(ctx.pathInfo.param as Object | undefined);
        if (params.tab === ManageTab.recycle || params.tab === ManageTab.duplicates
          || params.tab === ManageTab.shares) {
          this.tab = params.tab;
        }
        this.start();
      }
    })
    // 从建库页/单库页返回时刷新列表（首次显示由 onReady 的 start() 负责）
    .onShown(() => {
      if (!this.shownOnce) {
        this.shownOnce = true;
        return;
      }
      if (this.started) {
        this.reload();
      }
    })
    // **一个组件只能绑一个 bindSheet**（实测：绑两次只有后一个生效），所以合成单槽位 + 内容切换
    .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 唯一的弹层内容：按 sheetKind 切换 */
  @Builder
  SheetContent() {
    if (this.sheetKind === 'organize') {
      OrganizeSheet({
        libraryId: this.sheetTargetId,
        onStarted: (): void => {
          this.reload();
        },
        onClose: (): void => {
          this.showSheet = false;
        }
      })
    } else if (this.sheetKind === 'edit') {
      LibraryFormSheet({
        libraryId: this.sheetTargetId,
        onSaved: (view: LibraryView): void => {
          this.reload();
        },
        onClose: (): void => {
          this.showSheet = false;
        }
      })
    } else if (this.sheetKind === 'reorder') {
      this.ReorderSheet()
    } else if (this.sheetKind === 'chapters') {
      this.ChaptersSheet()
    }
  }

  /** 没有管理权限：这页整套动作都不可用，如实说并送回浏览 */
  @Builder
  DeniedState() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.lock_fill'))
        .fontSize(30)
        .fontColor([Theme.textFaint])
      Text('没有管理权限')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text('媒体库的创建、扫描与排序由管理员负责；你可以回到媒体库继续浏览。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Text('返回媒体库')
        .fontSize(14)
        .fontWeight(500)
        .fontColor(Theme.accentStrong)
        .padding({ left: 18, right: 18, top: 9, bottom: 9 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(17)
        .border({ width: 1, color: Theme.line })
        .margin({ top: 4 })
        .onClick(() => {
          this.navStack.pop();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 40, right: 40 })
  }

  @Builder
  PageContent() {
    Column() {
      this.Header()
      this.TabBar()
      Column() {
        if (this.tab === ManageTab.libraries) {
          this.LibrariesTab()
        } else if (this.tab === ManageTab.recycle) {
          RecycleBinContent({
            libraryId: 0,
            onCountChange: (count: number): void => {
              this.recycleCount = count;
            }
          })
        } else if (this.tab === ManageTab.duplicates) {
          DuplicatesContent({
            onCountChange: (count: number): void => {
              this.duplicateCount = count;
            }
          })
        } else {
          ManageSharesTab({
            navStack: this.navStack,
            onCountChange: (count: number): void => {
              this.shareCount = count;
            }
          })
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  /** 页头：大标题 + 「创建媒体库」，下一行是活的摘要（规模事实 + 在跑任务 / 待处理两枚胶囊） */
  @Builder
  Header() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Text('媒体库管理')
          .fontSize(22)
          .fontWeight(700)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(14)
            .fontColor([Theme.text])
          Text('创建媒体库')
            .fontSize(14)
            .fontWeight(500)
            .fontColor(Theme.text)
        }
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor(Theme.glassFillHover)
        .borderRadius(17)
        .border({ width: 1, color: Theme.lineStrong })
        .onClick(() => {
          this.navStack.pushPathByName('libraryCreate', null);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        Text(this.libraries === null ? '正在汇总媒体库…' : this.summaryFacts())
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .margin({ right: 8 })
        if (this.libraries !== null && this.busyCount() > 0) {
          this.FocusChip('busy', `${this.busyCount()} 个在跑任务`, Theme.info)
        }
        if (this.libraries !== null && this.attentionCount() > 0) {
          this.FocusChip('attention', `${this.attentionCount()} 个库有待处理文件`,
            this.attentionMissing() ? Theme.danger : Theme.warning)
        }
        if (this.libraries !== null && this.libraryCount() > 0
          && this.busyCount() === 0 && this.attentionCount() === 0) {
          Text('一切正常')
            .fontSize(13)
            .fontColor(Theme.textFaint)
        }
      }
      .width('100%')
    }
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 6 })
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 页头摘要的胶囊筛选：可带状态圆点，激活态提亮 */
  @Builder
  FocusChip(focus: string, title: string, color: string) {
    Row({ space: 6 }) {
      Row()
        .width(6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(color)
      Text(title)
        .fontSize(12)
        .fontColor(this.focus === focus ? Theme.text : Theme.textMuted)
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .borderRadius(14)
    .backgroundColor(this.focus === focus ? 'rgba(255, 255, 255, 0.14)' : Color.Transparent)
    .border({ width: 1, color: this.focus === focus ? 'rgba(255, 255, 255, 0.20)' : 'rgba(255, 255, 255, 0.10)' })
    .margin({ right: 8 })
    .onClick(() => {
      this.toggleFocus(focus);
    })
  }

  /** 页签条：计数未知或为 0 时标签照常渲染（入口要被看见），只是不带数字 */
  @Builder
  TabBar() {
    Scroll() {
      Row({ space: 6 }) {
        this.TabChip(ManageTab.libraries, this.libraryCount())
        this.TabChip(ManageTab.recycle, this.recycleCount)
        this.TabChip(ManageTab.duplicates, this.duplicateCount)
        this.TabChip(ManageTab.shares, this.shareCount)
      }
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: 12 })
  }

  @Builder
  TabChip(tab: string, count: number) {
    Row({ space: 6 }) {
      Text(ManageTab.label(tab))
        .fontSize(14)
        .fontWeight(this.tab === tab ? 600 : 400)
        .fontColor(this.tab === tab ? Theme.text : Theme.textMuted)
      if (count > 0) {
        Text(`${count}`)
          .fontSize(12)
          .fontColor(this.tab === tab ? 'rgba(255, 255, 255, 0.7)' : Theme.textFaint)
      }
    }
    .padding({ left: 14, right: 14, top: 7, bottom: 7 })
    .borderRadius(17)
    .backgroundColor(this.tab === tab ? 'rgba(255, 255, 255, 0.14)' : Color.Transparent)
    .border({ width: 1, color: this.tab === tab ? 'rgba(255, 255, 255, 0.18)' : Theme.line })
    .onClick(() => {
      this.applyTab(tab);
    })
  }

  // MARK: 媒体库页签

  @Builder
  LibrariesTab() {
    Scroll() {
      Column() {
        if (this.failed && this.libraries !== null) {
          this.Banner('与后端通信失败，正在自动重试；下方显示的是最近一次成功加载的数据')
        }
        if (this.libraries === null) {
          if (this.failed) {
            Column({ space: 12 }) {
              Text('媒体库加载失败')
                .fontSize(14)
                .fontColor(Theme.textMuted)
              Text('重试')
                .fontSize(14)
                .fontColor(Theme.accentStrong)
                .onClick(() => {
                  this.reload();
                })
            }
            .width('100%')
            .padding({ top: 60 })
          } else {
            Row({ space: 10 }) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color(Theme.textMuted)
              Text('正在加载媒体库…')
                .fontSize(14)
                .fontColor(Theme.textMuted)
            }
            .width('100%')
            .padding({ top: 60 })
            .justifyContent(FlexAlign.Center)
          }
        } else if (this.libraryCount() === 0) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.rectangle_stack'))
              .fontSize(28)
              .fontColor([Theme.textFaint])
            Text('为收藏准备一个家')
              .fontSize(16)
              .fontWeight(600)
              .fontColor(Theme.text)
            Text('创建电影库或剧集库，选好根目录后，订阅完成的内容会自动整理到这里。')
              .fontSize(13)
              .fontColor(Theme.textMuted)
              .textAlign(TextAlign.Center)
            Text('创建第一个媒体库')
              .fontSize(14)
              .fontWeight(500)
              .fontColor(Theme.accentStrong)
              .padding({ left: 18, right: 18, top: 9, bottom: 9 })
              .backgroundColor(Theme.glassFill)
              .borderRadius(17)
              .border({ width: 1, color: Theme.line })
              .margin({ top: 4 })
              .onClick(() => {
                this.navStack.pushPathByName('libraryCreate', null);
              })
          }
          .width('100%')
          .padding({ left: 40, right: 40, top: 50 })
        } else {
          // 工具栏：搜索 / 类型筛选（状态筛选在页头摘要的胶囊上）
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(15)
              .fontColor([Theme.textMuted])
            TextInput({
              placeholder: '按库名或根目录搜索',
              text: this.query
            })
              .layoutWeight(1)
              .backgroundColor(Color.Transparent)
              .padding(0)
              .height(36)
              .fontSize(14)
              .fontColor(Theme.text)
              .caretColor(Theme.accentStrong)
              .placeholderColor(Theme.textFaint)
              .placeholderFont({ size: 14 })
              .onChange((value: string) => {
                this.query = value;
              })
            if (this.query.length > 0) {
              SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                .fontSize(15)
                .fontColor([Theme.textFaint])
                .onClick(() => {
                  this.query = '';
                })
            }
          }
          .padding({ left: 12, right: 12 })
          .height(38)
          .borderRadius(19)
          .backgroundColor(Theme.glassFill)
          .border({ width: 1, color: Theme.line })
          .width('100%')
          .margin({ top: 14 })

          Scroll() {
            Row({ space: 6 }) {
              if (this.kindCount('') > 0) {
                this.KindChip('')
              }
              ForEach(ManageRules.kindOrder, (kind: string) => {
                if (this.kindCount(kind) > 0) {
                  this.KindChip(kind)
                }
              }, (kind: string) => `kind-${kind}`)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .margin({ top: 10 })

          // 收藏范围重叠提示：只读不阻断
          ForEach(this.warnings(), (warning: string) => {
            this.Banner(warning)
          }, (warning: string) => warning)

          ForEach(this.visibleLibraries(), (library: LibraryView) => {
            this.LibraryRow(library)
          }, (library: LibraryView) => `lib-${library.id}`)

          if (this.visibleLibraries().length === 0) {
            Column({ space: 10 }) {
              Text('没有符合条件的媒体库')
                .fontSize(14)
                .fontColor(Theme.textMuted)
              Text('清除筛选')
                .fontSize(14)
                .fontColor(Theme.info)
                .onClick(() => {
                  this.clearFilter();
                })
            }
            .width('100%')
            .padding({ top: 36, bottom: 36 })
          }

          Text('顺序即首页「我的媒体库」的展示顺序，在 ··· 菜单里「调整顺序」')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
            .margin({ top: 12 })
        }
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: Theme.tabBarInset })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  /** 类型筛选芯片（'' = 全部） */
  @Builder
  KindChip(kind: string) {
    Row({ space: 4 }) {
      Text(kind.length === 0 ? '全部' : LibraryKindMeta.label(kind))
        .fontSize(12)
        .fontColor(this.kindFilter === kind ? Theme.text : Theme.textMuted)
      Text(`${this.kindCount(kind)}`)
        .fontSize(11)
        .fontColor(this.kindFilter === kind ? 'rgba(255, 255, 255, 0.6)' : Theme.textFaint)
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .borderRadius(14)
    .backgroundColor(this.kindFilter === kind ? 'rgba(255, 255, 255, 0.14)' : Color.Transparent)
    .border({ width: 1, color: this.kindFilter === kind ? 'rgba(255, 255, 255, 0.20)' : 'rgba(255, 255, 255, 0.10)' })
    .onClick(() => {
      this.kindFilter = this.kindFilter === kind ? '' : kind;
    })
  }

  /** 琥珀色提示条（通信失败 / 收藏范围重叠） */
  @Builder
  Banner(message: string) {
    Text(message)
      .fontSize(13)
      .fontColor('rgba(251, 191, 36, 0.92)')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .width('100%')
      .backgroundColor('rgba(245, 196, 81, 0.08)')
      .borderRadius(12)
      .border({ width: 1, color: 'rgba(245, 196, 81, 0.25)' })
      .margin({ top: 12 })
  }

  /**
   * 一行库（iOS `ManageLibraryRow` 的手机卡片形态）。一行只有两个视觉重心：库名（白色、加粗）
   * 与状态（有事才带色）；根目录独占一行；所有操作收进右上的单一 ⋯ 菜单——唯一的例外是
   * 「待识别 / 缺失」胶囊本身可点：它是这页真正要你动手的信号，点它直达待处理清单。
   */
  @Builder
  LibraryRow(library: LibraryView) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        // 缩略图：服务端封面（自定义图或拼贴，与首页卡片同源），空库 / 你不在浏览范围内退回类型图标或锁
        Stack() {
          if (library.viewer_access && (library.custom_cover || library.stats.item_count > 0)) {
            RemoteImage({
              url: this.coverUrl(library),
              placeholderSymbol: LibraryKindMeta.symbol(library.kind)
            })
          } else {
            SymbolGlyph(library.viewer_access
              ? LibraryKindMeta.symbol(library.kind) : $r('sys.symbol.lock_fill'))
              .fontSize(14)
              .fontColor([Theme.textFaint])
          }
        }
        .width(72)
        .height(44)
        .borderRadius(8)
        .clip(true)
        .backgroundColor(Theme.surfaceRaised)
        .border({ width: 1, color: Theme.line })

        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(library.name)
              .fontSize(15)
              .fontWeight(600)
              .fontColor(Theme.text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .onClick(() => {
                this.openLibrary(library);
              })
            if (library.is_default) {
              this.Pill('默认', false)
            }
            if (ManageRules.accessRestricted(library)) {
              this.Pill(ManageRules.accessLabel(library), !library.viewer_access)
            }
          }
          .width('100%')

          // 第二行小字：类型 · 库存 · 需要留意的配置
          Text(this.secondLine(library))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row() {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(15)
            .fontColor([Theme.textMuted])
        }
        .width(32)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .borderRadius(16)
        .backgroundColor(Theme.glassFill)
        .border({ width: 1, color: Theme.line })
        .bindMenu(this.RowMenu(library))
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 根目录：主根（等宽）+ 多根时「+N 个根目录」
      Row({ space: 6 }) {
        Text(library.root_paths.length > 0 ? library.root_paths[0] : '—')
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (library.root_paths.length > 1) {
          Text(`+${library.root_paths.length - 1} 个根目录`)
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
      }
      .width('100%')

      this.StatusArea(library)
    }
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .borderRadius(Theme.cardRadius)
    .backgroundColor(Theme.surface)
    .border({ width: 1, color: Theme.line })
    .width('100%')
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 库名旁的小标签：「默认」与可见范围胶囊共用；你本人不在浏览范围内时前面带一把锁 */
  @Builder
  Pill(label: string, locked: boolean) {
    Row({ space: 3 }) {
      if (locked) {
        SymbolGlyph($r('sys.symbol.lock_fill'))
          .fontSize(9)
          .fontColor(['rgba(243, 245, 249, 0.55)'])
      }
      Text(label)
        .fontSize(10)
        .fontColor('rgba(243, 245, 249, 0.75)')
    }
    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
    .borderRadius(8)
    .backgroundColor('rgba(255, 255, 255, 0.08)')
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.14)' })
  }

  /**
   * 状态列三种形态：空闲只写「最近扫描 X 前」；任务中蓝点 + 百分比 + 进度条；
   * 待识别 / 缺失是带色胶囊（可点，直达待处理清单）。
   */
  @Builder
  StatusArea(library: LibraryView) {
    if (this.statusTone(library) === 'idle') {
      Text(this.statusDetail(library))
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .width('100%')
    } else if (this.statusTone(library) === 'busy') {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Row()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(Theme.info)
          Text(this.statusTitle(library))
            .fontSize(13)
            .fontColor('rgba(243, 245, 249, 0.9)')
            .maxLines(1)
            .layoutWeight(1)
        }
        .width('100%')
        if (this.statusPercent(library) !== null) {
          Progress({
            value: this.statusPercent(library) ?? 0,
            total: 100,
            type: ProgressType.Linear
          })
            .color(Theme.info)
            .backgroundColor('rgba(255, 255, 255, 0.10)')
            .height(3)
            .borderRadius(2)
            .width('100%')
        }
        if (this.statusDetail(library).length > 0) {
          Text(this.statusDetail(library))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else {
      Row({ space: 10 }) {
        Row({ space: 6 }) {
          Row()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.statusColor(library))
          Text(this.statusTitle(library))
            .fontSize(12)
            .fontWeight(500)
            .fontColor(this.statusColor(library))
            .maxLines(1)
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(12)
        .backgroundColor(this.statusSoftBg(library))
        .border({ width: 1, color: this.statusBorder(library) })
        .onClick(() => {
          // 待处理清单只有刮削型库才有（与 ⋯ 菜单里「待处理」的显隐同一条件）
          if (library.capabilities.scraped) {
            this.openPending(library);
          }
        })
        Text(this.statusDetail(library))
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .layoutWeight(1)
      }
      .width('100%')
    }
  }

  /** 行尾 ⋯ 菜单：首页卡片菜单与单库页菜单的并集，不新增功能（同 Web RowMenu） */
  @Builder
  RowMenu(library: LibraryView) {
    Menu() {
      MenuItemGroup() {
        MenuItem({ content: this.scanMenuLabel(library), startIcon: $r('sys.symbol.arrowshape_3_triangle_path') })
          .enabled(this.scanMenuEnabled(library))
          .onClick(() => {
            this.toggleScan(library);
          })
        if (library.capabilities.scraped) {
          // 待处理常驻：计数为 0 也可进（已忽略清单只有这里能到）
          MenuItem({ content: this.pendingMenuLabel(library), startIcon: $r('sys.symbol.exclamationmark_circle') })
            .onClick(() => {
              this.openPending(library);
            })
        }
        if (library.capabilities.naming) {
          MenuItem({ content: this.organizeMenuLabel(library), startIcon: $r('sys.symbol.folder_badge_ellipsis') })
            .enabled(this.organizeMenuEnabled(library))
            .onClick(() => {
              this.openSheet('organize', library);
            })
        }
        MenuItem({ content: this.refreshMenuLabel(library), startIcon: $r('sys.symbol.arrow_clockwise') })
          .enabled(this.refreshMenuEnabled(library))
          .onClick(() => {
            this.toggleRefresh(library);
          })
        if (library.extract_chapter_images) {
          // 作业排队 / 进行中时置灰并如实写状态（后端同库只跑一份）
          MenuItem({ content: this.chaptersMenuLabel(library), startIcon: $r('sys.symbol.line_3_horizontal') })
            .enabled(this.chaptersMenuEnabled(library))
            .onClick(() => {
              this.openSheet('chapters', library);
            })
        }
      }
      MenuItemGroup() {
        // 扫描 / 整理正按当前根路径读写台账，期间不允许改库配置
        MenuItem({ content: '编辑库', startIcon: $r('sys.symbol.square_and_pencil') })
          .enabled(!library.scanning && !library.organizing)
          .onClick(() => {
            this.openSheet('edit', library);
          })
        MenuItem({ content: library.is_default ? '已是默认库' : '设为默认库', startIcon: $r('sys.symbol.star_fill') })
          .enabled(!library.is_default)
          .onClick(() => {
            this.setDefault(library);
          })
        MenuItem({ content: library.exclude_from_home ? '在首页展示' : '从首页排除', startIcon: $r('sys.symbol.house') })
          .onClick(() => {
            this.toggleHome(library);
          })
        MenuItem({ content: '调整顺序', startIcon: $r('sys.symbol.arrow_up') })
          .onClick(() => {
            this.openReorder();
          })
      }
      MenuItemGroup() {
        MenuItem({ content: '删除库（不动磁盘）', startIcon: $r('sys.symbol.trash') })
          .contentFontColor(Theme.danger)
          .enabled(!library.scanning && !library.organizing)
          .onClick(() => {
            this.deleteLibrary(library);
          })
      }
    }
  }

  // MARK: 排序面板（手机端没有拖拽）

  @Builder
  ReorderSheet() {
    Column({ space: 14 }) {
      Text('调整顺序')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
        .width('100%')
      Text('这也是首页「我的媒体库」的展示顺序。')
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')
      Scroll() {
        Column() {
          ForEach(this.reorderDraft, (library: LibraryView, index: number) => {
            this.ReorderRow(library, index)
          }, (library: LibraryView) => `ro-${library.id}`)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      Row({ space: 10 }) {
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(14)
          .border({ width: 1, color: Theme.line })
          .onClick(() => {
            this.showSheet = false;
          })
        Text('保存顺序')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(this.orderChanged() ? Theme.text : Theme.textFaint)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(14)
          .border({ width: 1, color: this.orderChanged() ? Theme.lineStrong : Theme.line })
          .onClick(() => {
            this.commitOrder();
            this.showSheet = false;
          })
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }

  @Builder
  ReorderRow(library: LibraryView, index: number) {
    Row({ space: 12 }) {
      Text(`${index + 1}`)
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width(20)
      Text(library.name)
        .fontSize(15)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_up'))
        .fontSize(14)
        .fontColor([index === 0 ? Theme.textFaint : Theme.textMuted])
        .width(30)
        .height(30)
        .onClick(() => {
          this.moveDraft(index, index - 1);
        })
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(14)
        .fontColor([index === this.reorderDraft.length - 1 ? Theme.textFaint : Theme.textMuted])
        .width(30)
        .height(30)
        .onClick(() => {
          this.moveDraft(index, index + 1);
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  /** 生成章节的确认面板（iOS 是三键弹窗，这里用半屏面板承载同款文案与三选） */
  @Builder
  ChaptersSheet() {
    Column({ space: 14 }) {
      Text(`为「${this.sheetTargetName}」生成章节？`)
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
        .width('100%')
      Text(ManageConfirmText.chaptersText())
        .fontSize(14)
        .fontColor(Theme.textMuted)
        .lineHeight(20)
        .width('100%')
      Text('开始生成')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.accentStrong)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 14 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(14)
        .border({ width: 1, color: Theme.lineStrong })
        .onClick(() => {
          this.startChapters(false);
        })
      Text('已有的章节也重新生成')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 14 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(14)
        .border({ width: 1, color: Theme.line })
        .onClick(() => {
          this.startChapters(true);
        })
      Text('取消')
        .fontSize(16)
        .fontColor(Theme.textMuted)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.showSheet = false;
        })
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }
}
