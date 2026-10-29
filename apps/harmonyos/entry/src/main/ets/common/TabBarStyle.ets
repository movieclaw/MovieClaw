import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { WindowInsets } from './WindowInsets';

/**
 * 底部页签栏样式的本机偏好：**悬浮胶囊**（华为视频风，默认）与**经典贴底栏**
 * （通用的整宽底栏）两套并存，设置里一个开关即时切换。
 *
 * `@ObservedV2` + `@Trace`：MainTabsPage 与设置页开关持有同一单例，改了内存值
 * 两边当场重建，不用重启。preferences 落盘（复用 `movieclaw_ui` 偏好文件，同
 * AppIconStore / AgentAIConsent），重启后保留。
 */
@ObservedV2
export class TabBarStyle {
  private static instance: TabBarStyle | null = null;
  private static readonly storeName: string = 'movieclaw_ui';
  private static readonly key: string = 'tab_bar_floating';
  /** 偏好打开的完成信号（同 AppIconStore.ready 的坑：不等它读到的是默认值） */
  private static ready: Promise<void> | null = null;

  private store: preferences.Preferences | null = null;

  /** true = 悬浮胶囊（当前默认）；false = 经典贴底栏 */
  @Trace floating: boolean = true;

  private constructor() {
  }

  static shared(): TabBarStyle {
    if (TabBarStyle.instance === null) {
      TabBarStyle.instance = new TabBarStyle();
    }
    return TabBarStyle.instance;
  }

  /** EntryAbility.onCreate 里尽早调用（同 AppIconStore.init 的时机）；异步读盘不阻塞首帧 */
  static init(context: Context): void {
    if (TabBarStyle.ready === null) {
      TabBarStyle.ready = preferences.getPreferences(context, TabBarStyle.storeName)
        .then((store: preferences.Preferences): void => {
          const self: TabBarStyle = TabBarStyle.shared();
          self.store = store;
          const value: preferences.ValueType = store.getSync(TabBarStyle.key, true);
          self.floating = typeof value === 'boolean' ? value : true;
        })
        .catch((): void => {
        });
    }
  }

  /** 切换样式并落盘；落盘失败静默——内存值本次会话内仍然生效 */
  setFloating(floating: boolean): void {
    this.floating = floating;
    // 观测不到 `@Trace` 的 V1 页面（媒体库详情、全部合集）靠版本号重排底部留白
    WindowInsets.bumpRevision();
    const save = async (): Promise<void> => {
      const signal: Promise<void> | null = TabBarStyle.ready;
      if (signal !== null) {
        await signal;
      }
      const store: preferences.Preferences | null = TabBarStyle.shared().store;
      if (store === null) {
        return;
      }
      try {
        await store.put(TabBarStyle.key, floating);
        await store.flush();
      } catch (error) {
      }
    };
    save();
  }
}
