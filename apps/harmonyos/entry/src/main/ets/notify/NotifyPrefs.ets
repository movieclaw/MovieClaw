import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';

/** 系统通知的本机设置快照（总开关 + 四类开关 + 差分基线；键名自用，不进服务端） */
export class NotifySettingsSnapshot {
  enabled: boolean = false;
  download: boolean = true;
  arrival: boolean = true;
  subscription: boolean = true;
  task: boolean = true;
  /** 上一次抓到的状态（差分基线）：空 = 还没跑过第一轮 */
  baseline: string = '';
}

/**
 * 系统通知的本机偏好（照 Android `NotifyPrefs` 的 DataStore；这里走 preferences）。
 *
 * 独立偏好文件 `movieclaw_notify_prefs`；EntryAbility.onCreate 与 WorkSchedulerExtension
 * 各自进程里 init（workScheduler 的回调跑在单独的 Extension 进程，不共享主进程内存）。
 */
export class NotifyPrefs {
  private static store: preferences.Preferences | null = null;
  /** 恒为 Promise（未 init 时是已完成的空 Promise），await 处不用判空 */
  private static ready: Promise<void> = Promise.resolve();

  /** EntryAbility.onCreate / WorkExtension onWorkStart 里尽早调用 */
  static init(context: Context): void {
    if (NotifyPrefs.store === null) {
      NotifyPrefs.ready = preferences.getPreferences(context, 'movieclaw_notify_prefs')
        .then((store: preferences.Preferences): void => {
          NotifyPrefs.store = store;
        })
        .catch((): void => {
          // 偏好读写失败不致命：通知按默认关闭处理
          NotifyPrefs.store = null;
        });
    }
  }

  /** 读全部设置（等待 init 完成；没 init 过也能读，只是拿到默认值） */
  static async load(): Promise<NotifySettingsSnapshot> {
    const snapshot: NotifySettingsSnapshot = new NotifySettingsSnapshot();
    await NotifyPrefs.ready;
    const store: preferences.Preferences | null = NotifyPrefs.store;
    if (store === null) {
      return snapshot;
    }
    try {
      snapshot.enabled = await store.get('enabled', false) as boolean;
      snapshot.download = await store.get('channel_download', true) as boolean;
      snapshot.arrival = await store.get('channel_arrival', true) as boolean;
      snapshot.subscription = await store.get('channel_subscription', true) as boolean;
      snapshot.task = await store.get('channel_task', true) as boolean;
      snapshot.baseline = await store.get('baseline', '') as string;
    } catch (error) {
      // 读不到按默认值
    }
    return snapshot;
  }

  static async setEnabled(on: boolean): Promise<void> {
    await NotifyPrefs.put('enabled', on);
  }

  static async setChannel(download: boolean, arrival: boolean, subscription: boolean, task: boolean): Promise<void> {
    await NotifyPrefs.put('channel_download', download);
    await NotifyPrefs.put('channel_arrival', arrival);
    await NotifyPrefs.put('channel_subscription', subscription);
    await NotifyPrefs.put('channel_task', task);
  }

  /** 落差分基线（每轮差分检查的最后一步） */
  static async saveBaseline(value: string): Promise<void> {
    await NotifyPrefs.put('baseline', value);
  }

  private static async put(key: string, value: boolean | string): Promise<void> {
    await NotifyPrefs.ready;
    const store: preferences.Preferences | null = NotifyPrefs.store;
    if (store === null) {
      return;
    }
    try {
      await store.put(key, value);
      await store.flush();
    } catch (error) {
      // 写不进就算了（下次再说）；不抛出去打断轮询
    }
  }
}
