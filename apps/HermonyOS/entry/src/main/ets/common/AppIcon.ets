import { preferences } from '@kit.ArkData';
import { appInfoManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 应用内图标选择的本地偏好。
 *
 * 桌面图标**可以**换了：HarmonyOS 5.0.3(15) 起 AppGallery Kit 提供「图标管理服务」
 * （`appInfoManager`，见下方 `DesktopIcons`），但有两个硬前提——
 * 真机（服务不支持模拟器）+ 在 AppGallery Connect 后台为本应用开通图标管理服务
 * 并上传动态图标。前提不满足时服务查询失败，桌面图标退回静态的
 * `module.json5` 图标，这里保存的序号只影响**应用内**的展示位（「关于」页 logo）。
 */
export class AppIconStore {
  private static readonly storeName: string = 'movieclaw_ui';
  private static readonly key: string = 'app_logo_index';
  private static store: preferences.Preferences | null = null;
  /**
   * 偏好打开的完成信号（同 SavedServers.ready 的坑）：
   * init 由 EntryAbility.onCreate 异步触发，load 可能在它完成前被调，
   * 不等的话 store 还是 null、读到的永远是默认值。
   */
  private static ready: Promise<void> | null = null;

  /** 当前选中的图标序号；-1 = 默认图标（随包的 startIcon）。load 完成前也是它 */
  static selected: number = -1;

  /** EntryAbility.onCreate 时调用（同 SavedServers.init 的时机） */
  static init(context: Context): Promise<void> {
    if (AppIconStore.ready === null) {
      AppIconStore.ready = AppIconStore.open(context);
    }
    return AppIconStore.ready;
  }

  private static async open(context: Context): Promise<void> {
    try {
      AppIconStore.store = await preferences.getPreferences(context, AppIconStore.storeName);
      AppIconStore.readSelection();
    } catch (error) {
      AppIconStore.store = null;
    }
  }

  private static async waitReady(): Promise<void> {
    const signal: Promise<void> | null = AppIconStore.ready;
    if (signal !== null) {
      await signal;
    }
  }

  private static readSelection(): void {
    const store: preferences.Preferences | null = AppIconStore.store;
    if (store === null) {
      return;
    }
    const value: preferences.ValueType = store.getSync(AppIconStore.key, -1);
    AppIconStore.selected = typeof value === 'number' ? Math.floor(value) : -1;
  }

  /** 读当前选择（await 完成信号后刷新 selected；页面 aboutToAppear 时调） */
  static async load(): Promise<void> {
    await AppIconStore.waitReady();
    AppIconStore.readSelection();
  }

  static async set(index: number): Promise<void> {
    const store: preferences.Preferences | null = AppIconStore.store;
    if (store === null) {
      return;
    }
    AppIconStore.selected = index;
    await store.put(AppIconStore.key, index);
    await store.flush();
  }
}

/**
 * 序号 → 图标资源。`$r()` 不接受变量名（编译期要能校验资源存在），
 * 只能显式列出全部映射（同 SettingsIndexPage.iconFor 的做法）。
 * -1（或超界）= 默认图标。
 */
export function appLogoResource(index: number): Resource {
  if (index === 0) {
    return $r('app.media.app_logo_00');
  }
  if (index === 1) {
    return $r('app.media.app_logo_01');
  }
  if (index === 2) {
    return $r('app.media.app_logo_02');
  }
  if (index === 3) {
    return $r('app.media.app_logo_03');
  }
  if (index === 4) {
    return $r('app.media.app_logo_04');
  }
  if (index === 5) {
    return $r('app.media.app_logo_05');
  }
  if (index === 6) {
    return $r('app.media.app_logo_06');
  }
  if (index === 7) {
    return $r('app.media.app_logo_07');
  }
  if (index === 8) {
    return $r('app.media.app_logo_08');
  }
  if (index === 9) {
    return $r('app.media.app_logo_09');
  }
  if (index === 10) {
    return $r('app.media.app_logo_10');
  }
  if (index === 11) {
    return $r('app.media.app_logo_11');
  }
  if (index === 12) {
    return $r('app.media.app_logo_12');
  }
  if (index === 13) {
    return $r('app.media.app_logo_13');
  }
  if (index === 14) {
    return $r('app.media.app_logo_14');
  }
  if (index === 15) {
    return $r('app.media.app_logo_15');
  }
  if (index === 16) {
    return $r('app.media.app_logo_16');
  }
  if (index === 17) {
    return $r('app.media.app_logo_17');
  }
  if (index === 18) {
    return $r('app.media.app_logo_18');
  }
  if (index === 19) {
    return $r('app.media.app_logo_19');
  }
  if (index === 20) {
    return $r('app.media.app_logo_20');
  }
  if (index === 21) {
    return $r('app.media.app_logo_21');
  }
  if (index === 22) {
    return $r('app.media.app_logo_22');
  }
  if (index === 23) {
    return $r('app.media.app_logo_23');
  }
  if (index === 24) {
    return $r('app.media.app_logo_24');
  }
  if (index === 25) {
    return $r('app.media.app_logo_25');
  }
  return $r('app.media.startIcon');
}

/** 桌面动态图标（AGC 图标管理服务）的查询结果 */
export class DesktopIconState {
  /** 服务可用且已配好动态图标：能真的换桌面图标 */
  available: boolean = false;
  icons: appInfoManager.DynamicIconInfo[] = [];
  /** 不可用时的说明（页面原样展示给用户） */
  message: string = '';
}

/**
 * 桌面动态图标（AppGallery Kit「图标管理服务」，API 5.0.3(15) 起）：
 * 查询 / 切换 / 恢复默认。对应 iOS `setAlternateIconName` 的鸿蒙等价物。
 *
 * 两个硬前提：**真机**（服务不支持模拟器）+ 在 AppGallery Connect 后台为本应用
 * 开通图标管理服务并上传动态图标。前提不满足时 query 返回 available=false
 * 与给用户看的原因，页面据此降级成只说明、不给选。
 */
export class DesktopIcons {
  static async query(): Promise<DesktopIconState> {
    const state: DesktopIconState = new DesktopIconState();
    if (!canIUse('SystemCapability.AppGalleryService.AppInfoManager')) {
      state.message = '这台设备的系统不支持应用图标管理服务，桌面图标更换不可用。';
      return state;
    }
    try {
      const icons: appInfoManager.DynamicIconInfo[] = await appInfoManager.queryDynamicIcons();
      if (icons.length === 0) {
        state.message = '还没有配置动态图标：在 AppGallery Connect 后台开通图标管理服务并上传图标后，这里就能更换桌面图标。';
        return state;
      }
      state.available = true;
      state.icons = icons;
      return state;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      if (err.code === 1006800010) {
        // 服务在、数据没有：AGC 后台没配动态图标
        state.message = '还没有配置动态图标：在 AppGallery Connect 后台上传并发布动态图标后，这里就能更换桌面图标。';
      } else {
        // 1006800001（服务连接失败）：模拟器 / 没有 AG 服务的设备都走这里
        state.message = '图标管理服务连不上：请用真机（服务不支持模拟器），并在 AppGallery Connect 后台为本应用开通图标管理服务。';
      }
      return state;
    }
  }

  /** 切换桌面图标；成功返回 true（1006800013＝正在用主题图标等场景为失败） */
  static async select(iconId: string): Promise<boolean> {
    try {
      await appInfoManager.selectDynamicIcon(iconId);
      return true;
    } catch (error) {
      return false;
    }
  }

  /** 恢复默认桌面图标 */
  static async restoreDefault(): Promise<boolean> {
    try {
      await appInfoManager.disableDynamicIcon();
      return true;
    } catch (error) {
      return false;
    }
  }
}
