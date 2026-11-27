import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 华为 X 轴线性马达富触感引擎（全面超越 iOS 的 9 处反馈）：
 *
 * 优先走系统级高清预置触感（`VibratePreset`：微刻度棘轮、清脆点按、重击过线、成功/告警），
 * 不支持预置波形的设备（旧平板、模拟器、车机）自动回落到毫秒脉冲，彻底静默吞错。
 */
export class Haptics {
  private static readonly TICK_MS: number = 8;
  private static readonly CLICK_MS: number = 14;
  private static readonly SHORT_MS: number = 30;
  private static readonly HEAVY_MS: number = 36;

  /**
   * 微棘轮刻度感（对标并超越 iOS `.selection`）：
   * 用于半星滑动打分、35mm 胶片走格、A-Z 字母索引条滑动、播放器章节吸附点。
   */
  static tick(): void {
    Haptics.preset('haptic.clock.timer', Haptics.TICK_MS, 'touch');
  }

  /**
   * 清脆机械点按（对标 iOS `UIImpactFeedbackGenerator(.light/.medium)`）：
   * 用于收藏红心点亮、已看切换、长按 2 倍速起振、底栏页签切换、倍速药丸切换。
   */
  static click(): void {
    Haptics.preset('haptic.common.click', Haptics.CLICK_MS, 'touch');
  }

  /**
   * 刚性重锤激发（对标 iOS `.impact(flexibility: .rigid, intensity: 1)`）：
   * 用于下拉二楼过线锁定、双击头像秒切账号、长按调出菜单。
   */
  static heavy(): void {
    Haptics.preset('haptic.longPress.heavy', Haptics.HEAVY_MS, 'touch');
  }

  /** 正向完成通知（批准设备登录、订阅成功、保存完成） */
  static notifySuccess(): void {
    Haptics.preset('haptic.notice.success', 2 * Haptics.SHORT_MS, 'notification');
  }

  /** 警示 / 拒绝通知 */
  static notify(): void {
    Haptics.preset('haptic.notice.warning', Haptics.SHORT_MS, 'notification');
  }

  /** 兼容直调毫秒脉冲 */
  static buzz(duration: number): void {
    const effect: vibrator.VibrateEffect = { type: 'time', duration: duration };
    const attribute: vibrator.VibrateAttribute = { id: 0, usage: 'notification' };
    vibrator.startVibration(effect, attribute).catch((error: BusinessError): void => {
      hilog.debug(0x0000, 'Haptics', 'vibrate skipped: %{public}s', error.message);
    });
  }

  private static preset(effectId: string, fallbackMs: number, usage: vibrator.Usage): void {
    try {
      const presetEffect: vibrator.VibrateEffect = { type: 'preset', effectId: effectId, count: 1 };
      const attribute: vibrator.VibrateAttribute = { id: 0, usage: usage };
      vibrator.startVibration(presetEffect, attribute).catch((): void => {
        const timeEffect: vibrator.VibrateEffect = { type: 'time', duration: fallbackMs };
        vibrator.startVibration(timeEffect, attribute).catch((err: BusinessError): void => {
          hilog.debug(0x0000, 'Haptics', 'fallback vibrate skipped: %{public}s', err.message);
        });
      });
    } catch (error) {
      Haptics.buzz(fallbackMs);
    }
  }
}
