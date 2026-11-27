import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { Haptics } from './Haptics';

/** 碰一碰 / 系统分享面板传输的卡片载荷 */
export class KnockSharePayload {
  readonly title: string;
  readonly description: string;
  readonly url: string;

  constructor(title: string, description: string, url: string) {
    this.title = title;
    this.description = description;
    this.url = url;
  }
}

/**
 * 鸿蒙原生分享与「碰一碰」分享桥接（`@kit.ShareKit`）：
 * - `shareLink`：拉起 HarmonyOS 系统分享面板（隔空传送、微信、畅连、跨设备投送）；
 * - `armKnockShare` / `disarmKnockShare`：详情页或播放页驻留时监听 `knockShare`，
 *   两台鸿蒙手机顶部轻碰即可把当前影片链接（公开分享页或 `movieclaw://` 深链）直接投过去。
 */
export class HarmonyShareBridge {
  private static provider: (() => KnockSharePayload | null) | null = null;
  private static listening: boolean = false;

  private static readonly knockCallback: (target: harmonyShare.SharableTarget) => void =
    (target: harmonyShare.SharableTarget): void => {
      const fn: (() => KnockSharePayload | null) | null = HarmonyShareBridge.provider;
      if (fn === null) {
        return;
      }
      const payload: KnockSharePayload | null = fn();
      if (payload === null || payload.url.length === 0) {
        return;
      }
      try {
        const data: systemShare.SharedData = new systemShare.SharedData({
          utd: utd.UniformDataType.HYPERLINK,
          content: payload.url,
          title: payload.title,
          description: payload.description
        });
        Haptics.notifySuccess();
        target.share(data);
      } catch (_err) {
      }
    };

  /** 拉起系统级分享面板 */
  static async shareLink(
    context: common.UIAbilityContext,
    title: string,
    description: string,
    url: string
  ): Promise<boolean> {
    if (url.length === 0) {
      return false;
    }
    try {
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.HYPERLINK,
        content: url,
        title: title,
        description: description
      });
      const controller: systemShare.SharedController = new systemShare.SharedController(data);
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      });
      return true;
    } catch (_err) {
      return false;
    }
  }

  /** 注册当前页面的碰一碰分享源 */
  static armKnockShare(provider: () => KnockSharePayload | null): void {
    HarmonyShareBridge.provider = provider;
    if (HarmonyShareBridge.listening) {
      return;
    }
    try {
      harmonyShare.on('knockShare', HarmonyShareBridge.knockCallback);
      HarmonyShareBridge.listening = true;
    } catch (_err) {
      // TV / 车机 / 旧模拟器不支持碰一碰时静默跳过
    }
  }

  /** 页面离开时解除碰一碰监听 */
  static disarmKnockShare(): void {
    HarmonyShareBridge.provider = null;
    if (!HarmonyShareBridge.listening) {
      return;
    }
    try {
      harmonyShare.off('knockShare', HarmonyShareBridge.knockCallback);
    } catch (_err) {
    }
    HarmonyShareBridge.listening = false;
  }
}
