import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 触觉反馈（对应 iOS 的 `UINotificationFeedbackGenerator`）。
 *
 * 只做一件事：**短震一下**。用途是「有安全后果的决定落地了」这种时刻——
 * 批准设备登录成功、拒绝设备登录，都震一下让人有实感。
 *
 * **失败一律吞掉**：模拟器、部分平板/车机没有马达，或者用户/系统禁了振动，
 * `startVibration` 会抛错——这种地方报错毫无意义，功能本身也不该被它拖累。
 */
export class Haptics {
  /** 一般提示：短促一下（毫秒） */
  private static readonly SHORT_MS: number = 30;

  /**
   * 成功提示（同 iOS `.success` 的通知反馈）：稍微长一点，跟「普通点击」区分开。
   */
  static notifySuccess(): void {
    Haptics.buzz(2 * Haptics.SHORT_MS);
  }

  /** 普通一下（拒绝等否定性结果用它） */
  static notify(): void {
    Haptics.buzz(Haptics.SHORT_MS);
  }

  /** 震 duration 毫秒；没有马达/没权限/被禁用都静默 */
  static buzz(duration: number): void {
    const effect: vibrator.VibrateEffect = { type: 'time', duration: duration };
    const attribute: vibrator.VibrateAttribute = { id: 0, usage: 'notification' };
    vibrator.startVibration(effect, attribute).catch((error: BusinessError): void => {
      hilog.debug(0x0000, 'Haptics', 'vibrate skipped: %{public}s', error.message);
    });
  }
}
