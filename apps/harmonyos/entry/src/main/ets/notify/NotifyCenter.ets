import { notificationManager } from '@kit.NotificationKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { Context, Want, WantAgent, bundleManager, wantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppModel } from '../common/AppModel';
import { TokenVault } from '../common/TokenVault';
import { SavedServers } from '../common/SavedServers';
import { ServerRoutes } from '../common/ServerRoutes';
import { MovieClawApi } from '../api/Endpoints';
import {
  DownloadTaskListView,
  DownloadTaskView,
  JobListView,
  JobView,
  RecentArrivalView,
  SubscriptionView,
  TodayArrivalView
} from '../api/Models';
import { JsonValue } from '../api/JsonValue';
import { NotifyPrefs, NotifySettingsSnapshot } from './NotifyPrefs';
import { NotifySnapshot, NotifySnapshotState } from './NotifySnapshot';

const NOTIFY_DOMAIN = 0x0000;

/** 一轮差分检查的结果（设置页「立即检查」的回显） */
export class NotifyPollResult {
  /** 没真正跑（没开通知 / 没登录 / 上一轮还在跑） */
  skipped: boolean = false;
  skippedReason: string = '';
  /** 首轮只落基线、不弹（避免刚装上就被轰炸） */
  firstRun: boolean = false;
  /** 弹了几条 */
  posted: number = 0;
}

/**
 * 系统通知中心（纯客户端差分，服务端零改动；照 Android `NotifyWorker` / `Notifier`）。
 *
 * 每轮拉五个现成接口（下载任务 / 后台作业 / 今日预告 / 最近入库 / 订阅表），与本机存的
 * 上一次快照差分，只在「上一次没有、这一次有了」时发本地通知：
 * - 下载：翻到终态（completed=下载完成；error / missing=下载失败）；
 * - 作业：翻到 failed（真失败）/ blocked（要人工处理）；
 * - 入库：最近入库新出现的（一天最多弹 3 条）；
 * - 订阅：今天有可看的（一天最多弹 3 条）。
 *
 * 调度三层：主界面挂着时 10 分钟一轮（`startForegroundTimer`）；退后台由 workScheduler
 * 每 2 小时兜底拉起 Extension 进程（`scheduleBackground`；活跃分组的最小循环间隔）；
 * 实时通知（服务端 IM 推送 / 后续 SSE）送达后这里只更新基线、不重复弹。
 */
export class NotifyCenter {
  private static instance: NotifyCenter | null = null;

  static shared(): NotifyCenter {
    if (NotifyCenter.instance === null) {
      NotifyCenter.instance = new NotifyCenter();
    }
    return NotifyCenter.instance;
  }

  private constructor() {
  }

  /** workScheduler 的任务 id（停止时要对上同一个） */
  private static readonly WORK_ID = 1001;
  /** 前台轮询间隔：10 分钟 */
  private static readonly FOREGROUND_INTERVAL_MS = 10 * 60 * 1000;
  /** workScheduler 循环周期：2 小时（活跃分组的最小循环间隔） */
  private static readonly BACKGROUND_CYCLE_MS = 2 * 60 * 60 * 1000;

  private inFlight: boolean = false;
  private timerId: number = -1;
  private bundleName: string = 'io.movieclaw.HUAWEI';

  /** EntryAbility.onCreate / WorkExtension onWorkStart 里尽早调（wantAgent 要包名） */
  init(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo): void => {
        // BundleInfo 里包名字段叫 name（对应清单里的 bundleName）
        if (info.name.length > 0) {
          this.bundleName = info.name;
        }
      })
      .catch((): void => {
        // 拿不到就用默认包名（签名包名固定）
      });
  }

  // MARK: - 权限

  /** 系统通知开关是否已授权（没授权时 publish 静默无效） */
  static async systemEnabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (error) {
      return false;
    }
  }

  /**
   * 拉起系统授权弹窗（每个应用只弹一次；用户拒绝过就不再弹，只查当前状态）。
   * 返回最终的授权状态。
   */
  static async requestPermission(): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification();
    } catch (error) {
      // 首次弹窗被拒绝（1600004）或已拒绝过：不阻塞，以查询结果为准
    }
    return NotifyCenter.systemEnabled();
  }

  // MARK: - 差分检查

  /** 主界面挂着时的前台轮询（10 分钟一轮；登录与否每轮自查） */
  startForegroundTimer(): void {
    this.stopForegroundTimer();
    this.timerId = setInterval((): void => {
      const api: MovieClawApi | null = AppModel.shared.api;
      if (api === null) {
        return;
      }
      this.pollOnce(api).catch((): void => {
      });
    }, NotifyCenter.FOREGROUND_INTERVAL_MS);
  }

  stopForegroundTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /**
   * 一轮差分检查：拉接口 → 与基线差分 → 弹翻转的通知 → 落新基线。
   * 首轮（基线为空）只落基线不弹；单个接口失败按空处理，不影响其余类别（同 Android runCatching）。
   */
  async pollOnce(api: MovieClawApi): Promise<NotifyPollResult> {
    const result: NotifyPollResult = new NotifyPollResult();
    if (this.inFlight) {
      result.skipped = true;
      result.skippedReason = '上一轮检查还没结束';
      return result;
    }
    this.inFlight = true;
    try {
      const settings: NotifySettingsSnapshot = await NotifyPrefs.load();
      if (!settings.enabled) {
        result.skipped = true;
        result.skippedReason = '系统通知没有开启';
        return result;
      }

      let tasks: DownloadTaskView[] = [];
      let jobs: JobView[] = [];
      let arrivals: TodayArrivalView[] = [];
      let recent: RecentArrivalView[] = [];
      let subs: SubscriptionView[] = [];
      try {
        const view: DownloadTaskListView = await api.dlTasks();
        tasks = view.items;
      } catch (error) {
        // 拉不到按没有下载任务
      }
      try {
        const view: JobListView = await api.jobsList();
        jobs = view.items;
      } catch (error) {
        // 成员身份拉不到活动是正常的
      }
      try {
        arrivals = await api.subscriptionsListTodayArrivals();
      } catch (error) {
      }
      try {
        recent = await api.subscriptionsListRecentArrivals();
      } catch (error) {
      }
      // 订阅表只为拼「直接进那一条」的落点（item/{库}/{条目}）用，拉不到就退回订阅详情
      try {
        subs = await api.subscriptionsList();
      } catch (error) {
      }

      const now: NotifySnapshotState = new NotifySnapshotState();
      for (const task of tasks) {
        if (task.info_hash.length > 0 || task.id.length > 0) {
          now.downloads.set(task.id, task.state);
        }
      }
      for (const job of jobs) {
        now.jobs.set(job.id, job.status);
      }
      for (const arrival of arrivals) {
        if (arrival.days_ahead === 0) {
          now.arrivals.add(`${arrival.subscription_id}:${arrival.season_number}:${arrival.episode_number}`);
        }
      }
      for (const item of recent) {
        now.recent.add(`${item.subscription_id}:${item.season_number}:${item.episode_number}`);
      }

      const before: NotifySnapshotState = NotifySnapshot.decode(settings.baseline);
      result.firstRun = settings.baseline.length === 0;
      if (!result.firstRun) {
        await this.diffDownloads(settings, before, tasks, result);
        await this.diffJobs(settings, before, jobs, result);
        await this.diffRecent(settings, before, now, recent, subs, result);
        await this.diffToday(settings, before, now, arrivals, subs, result);
      }
      await NotifyPrefs.saveBaseline(NotifySnapshot.encode(now));
      return result;
    } finally {
      this.inFlight = false;
    }
  }

  /** workScheduler 拉起的 Extension 进程里界面没跑过：先恢复登录态（已恢复过就是空操作）再轮询 */
  async pollFromExtension(context: Context): Promise<void> {
    this.init();
    NotifyPrefs.init(context);
    const settings: NotifySettingsSnapshot = await NotifyPrefs.load();
    if (!settings.enabled) {
      return;
    }
    AppModel.shared.initStore(context);
    TokenVault.init(context);
    SavedServers.init(context);
    ServerRoutes.init(context);
    if (AppModel.shared.api === null) {
      await AppModel.shared.restore();
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    await this.pollOnce(api);
  }

  // MARK: - 差分 → 通知

  /** 下载任务翻到终态（completed=完成；error / missing=失败） */
  private async diffDownloads(settings: NotifySettingsSnapshot, before: NotifySnapshotState,
    tasks: DownloadTaskView[], result: NotifyPollResult): Promise<void> {
    if (!settings.download && !settings.task) {
      return;
    }
    for (const task of tasks) {
      const was: string | undefined = before.downloads.get(task.id);
      if (was === undefined) {
        continue;
      }
      const state: string = task.state;
      if (was === state) {
        continue;
      }
      const terminal: boolean = state === 'completed' || state === 'error' || state === 'missing';
      if (!terminal) {
        continue;
      }
      const title: string = state === 'completed' ? '下载完成' : '下载失败';
      const text: string = task.media_title ?? task.name ?? '下载任务';
      await this.post(NotifyCenter.javaHash(`dl:${task.id}`), title, text, 'activity', '');
      result.posted = result.posted + 1;
    }
  }

  /** 后台作业翻到 failed（真失败）/ blocked（必须人工处理；服务端语义，都不是「重试中」） */
  private async diffJobs(settings: NotifySettingsSnapshot, before: NotifySnapshotState,
    jobs: JobView[], result: NotifyPollResult): Promise<void> {
    if (!settings.task) {
      return;
    }
    for (const job of jobs) {
      const was: string | undefined = before.jobs.get(job.id);
      if (was === undefined) {
        continue;
      }
      const status: string = job.status;
      if (was === status) {
        continue;
      }
      const bad: boolean = status === 'failed' || status === 'blocked';
      if (!bad) {
        continue;
      }
      const pieces: string[] = [];
      const subject: string = job.subject ?? '';
      if (subject.length > 0) {
        pieces.push(subject);
      }
      const label: string = job.job_type_label ?? '';
      if (label.length > 0) {
        pieces.push(label);
      }
      const error: Record<string, JsonValue> | null | undefined = job.error;
      if (error !== null && error !== undefined) {
        const message: JsonValue | undefined = error['message'];
        if (message !== undefined && message !== null) {
          pieces.push(`${message}`);
        }
      }
      const body: string = pieces.length > 0 ? pieces.join(' · ') : '在活动页查看详情';
      const title: string = status === 'failed' ? '后台任务失败' : '后台任务需要处理';
      await this.post(NotifyCenter.javaHash(`job:${job.id}`), title, body, 'activity', '');
      result.posted = result.posted + 1;
    }
  }

  /** 最近入库新出现的（一轮最多 3 条） */
  private async diffRecent(settings: NotifySettingsSnapshot, before: NotifySnapshotState,
    now: NotifySnapshotState, recent: RecentArrivalView[], subs: SubscriptionView[],
    result: NotifyPollResult): Promise<void> {
    if (!settings.arrival) {
      return;
    }
    const added: string[] = [];
    now.recent.forEach((key: string): void => {
      if (!before.recent.has(key)) {
        added.push(key);
      }
    });
    const count: number = Math.min(3, added.length);
    for (let index: number = 0; index < count; index++) {
      const key: string = added[index];
      const id: number = NotifyCenter.subscriptionIdOf(key);
      if (id <= 0) {
        continue;
      }
      let title: string = '新内容入库';
      for (const item of recent) {
        if (item.subscription_id === id) {
          title = item.media.title;
          break;
        }
      }
      await this.post(NotifyCenter.javaHash(`arr:${key}`), '已入库', title, 'activity',
        this.routeFor(id, subs));
      result.posted = result.posted + 1;
    }
  }

  /** 今天有可看的（一轮最多 3 条） */
  private async diffToday(settings: NotifySettingsSnapshot, before: NotifySnapshotState,
    now: NotifySnapshotState, arrivals: TodayArrivalView[], subs: SubscriptionView[],
    result: NotifyPollResult): Promise<void> {
    if (!settings.subscription) {
      return;
    }
    const added: string[] = [];
    now.arrivals.forEach((key: string): void => {
      if (!before.arrivals.has(key)) {
        added.push(key);
      }
    });
    const count: number = Math.min(3, added.length);
    for (let index: number = 0; index < count; index++) {
      const key: string = added[index];
      const id: number = NotifyCenter.subscriptionIdOf(key);
      if (id <= 0) {
        continue;
      }
      let title: string = '今天更新';
      for (const arrival of arrivals) {
        if (arrival.subscription_id === id) {
          title = arrival.media_title;
          break;
        }
      }
      await this.post(NotifyCenter.javaHash(`today:${key}`), '今天有可看的', title, 'subscriptions',
        this.routeFor(id, subs));
      result.posted = result.posted + 1;
    }
  }

  /** 有具体作品就落到条目详情（item/{库}/{条目}），否则退回订阅详情（subscription/{订阅id}） */
  private routeFor(subscriptionId: number, subs: SubscriptionView[]): string {
    for (const sub of subs) {
      if (sub.id === subscriptionId) {
        const libraryId: number = sub.library_id ?? 0;
        const mediaItemId: number = sub.media.media_item_id;
        if (libraryId > 0 && mediaItemId > 0) {
          return `item/${libraryId}/${mediaItemId}`;
        }
        break;
      }
    }
    return `subscription/${subscriptionId}`;
  }

  /** `订阅id:季:集` → 订阅 id（解析不出来返回 0） */
  private static subscriptionIdOf(key: string): number {
    const index: number = key.indexOf(':');
    if (index <= 0) {
      return 0;
    }
    const id: number = Number(key.substring(0, index));
    return Number.isFinite(id) && id > 0 ? Math.floor(id) : 0;
  }

  // MARK: - 投递

  /**
   * 发一条本地通知：点按带着 tab / route 参数拉起 EntryAbility（onCreate / onNewWant
   * 解析后交给 NotifyRouter）；`tapDismissed` 默认 true，点过自动消失。
   * 通知 id 用键的 Java 风格哈希（同一条任务再次翻转时替换旧通知，不叠罗汉）。
   */
  private async post(id: number, title: string, text: string, tab: string, route: string): Promise<void> {
    try {
      const granted: boolean = await NotifyCenter.systemEnabled();
      if (!granted) {
        return;
      }
      const want: Want = {
        bundleName: this.bundleName,
        abilityName: 'EntryAbility',
        parameters: { 'mcTab': tab, 'mcRoute': route }
      };
      const agent: WantAgent = await wantAgent.getWantAgent({
        wants: [want],
        operationType: wantAgent.OperationType.START_ABILITIES,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      const request: notificationManager.NotificationRequest = {
        id: id,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text
          }
        },
        wantAgent: agent
      };
      await notificationManager.publish(request);
    } catch (error) {
      hilog.warn(NOTIFY_DOMAIN, 'MovieClaw', '系统通知发布失败：%{public}s', `${error}`);
    }
  }

  // MARK: - workScheduler 兜底

  /** 注册 2 小时循环的延迟任务（开启通知时调；isPersisted 重启后仍生效，重复注册覆盖同 id） */
  scheduleBackground(): void {
    try {
      const work: workScheduler.WorkInfo = {
        workId: NotifyCenter.WORK_ID,
        bundleName: this.bundleName,
        abilityName: 'WorkNotifyExtensionAbility',
        networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
        isRepeat: true,
        repeatCycleTime: NotifyCenter.BACKGROUND_CYCLE_MS,
        isPersisted: true
      };
      workScheduler.startWork(work);
    } catch (error) {
      hilog.warn(NOTIFY_DOMAIN, 'MovieClaw', '注册延迟任务失败：%{public}s', `${error}`);
    }
  }

  /** 取消延迟任务（关闭通知时调） */
  cancelBackground(): void {
    try {
      const work: workScheduler.WorkInfo = {
        workId: NotifyCenter.WORK_ID,
        bundleName: this.bundleName,
        abilityName: 'WorkNotifyExtensionAbility'
      };
      workScheduler.stopWork(work, true);
    } catch (error) {
      // 没注册过就停，忽略
    }
  }

  /** Java 的 String.hashCode（Android 通知 id 的算法原样搬，保证同一键在同一槽位） */
  private static javaHash(value: string): number {
    let hash: number = 0;
    for (let index: number = 0; index < value.length; index++) {
      hash = (hash * 31 + value.charCodeAt(index)) | 0;
    }
    return Math.abs(hash);
  }
}
