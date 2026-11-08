import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { PairingScan } from './PairingCode';

/** Scan Kit：用户自己在扫码界面点了取消（不是失败，不该弹提示） */
const SCAN_USER_CANCEL: number = 1000500002;

/** 一次扫码的结果分类 */
export enum ScanOutcomeKind {
  /** 认出是 MovieClaw 的登录二维码（配对码已解析出来） */
  recognized,
  /** 扫到了码，但不是 MovieClaw 的登录二维码 */
  unrecognized,
  /** 这台设备上用不了相机扫码（模拟器、没装扫码服务等） */
  unavailable,
  /** 用户自己在扫码界面点了取消 */
  cancelled
}

/** 一次扫码的结果：只带事实，不做任何 UI（弹窗开不开、提示写什么由调用方决定） */
export class ScanOutcome {
  readonly kind: ScanOutcomeKind;
  /** 扫到的原始文本（recognized / unrecognized 时有值） */
  readonly text: string;
  /** recognized 时解析出的配对码（`MCLW-XXXX`） */
  readonly code: string | null;
  /** recognized 且二维码是网址时，网址里的服务器（`主机:端口`） */
  readonly host: string | null;

  constructor(kind: ScanOutcomeKind, text: string, code: string | null, host: string | null) {
    this.kind = kind;
    this.text = text;
    this.code = code;
    this.host = host;
  }
}

/**
 * 拉起系统扫码界面（Scan Kit 默认 UI）扫 MovieClaw 的登录二维码。
 *
 * **为什么扫完再开弹窗、而不是先开弹窗再扫**：弹窗（promptAction 自定义弹窗）在
 * Scan Kit 的扫码界面盖上来后保不住——扫完回到页面，弹窗已经没了，看起来就是
 * 「扫了没反应」。所以调用方（MorePage / SettingsSectionPage）都是先调这里扫，
 * 拿到结果再开配对码弹窗；弹窗存活期间永远没有扫码界面盖在上面。
 */
export class PairingScanner {
  /** 拉起系统扫码界面；识别 / 取消 / 相机不可用都体现在返回值里 */
  static async scan(): Promise<ScanOutcome> {
    try {
      const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
      const options: scanBarcode.ScanOptions = { scanTypes: [scanCore.ScanType.QR_CODE] };
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(context, options);
      const raw: string = result.originalValue;
      const parsed: PairingScan | null = PairingScan.parse(raw);
      if (parsed === null) {
        // 相机对着 Wi-Fi、网址、付款码：不能把人带进批准页
        return new ScanOutcome(ScanOutcomeKind.unrecognized, raw, null, null);
      }
      return new ScanOutcome(ScanOutcomeKind.recognized, raw, parsed.code, parsed.host);
    } catch (error) {
      const err = error as BusinessError;
      if (err.code === SCAN_USER_CANCEL) {
        // 用户自己在扫码界面点了取消：什么都不说，别把「取消」写成「失败」
        return new ScanOutcome(ScanOutcomeKind.cancelled, '', null, null);
      }
      // 模拟器没有可用相机、或设备没装扫码服务：指回手输
      return new ScanOutcome(ScanOutcomeKind.unavailable, '', null, null);
    }
  }
}
