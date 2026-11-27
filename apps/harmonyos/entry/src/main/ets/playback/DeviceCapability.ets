import { ClientCapabilityIn } from '../api/Models';
import { MovieClawPlaybackGateway } from './MovieClawPlaybackGateway';

/** 端口径：客户端标识 + 是否移动端 + 本机安装标识（device_id；空 = 不报） */
export class DeviceProfile {
  readonly client: string;
  readonly isMobile: boolean;
  readonly deviceId: string;

  constructor(client: string, isMobile: boolean, deviceId: string) {
    this.client = client;
    this.isMobile = isMobile;
    this.deviceId = deviceId;
  }
}

/**
 * 按端 × 按引擎的能力申报：
 * 编解码 / 容器 / HDR Vivid / Audio Vivid 能力与 MovieClawPlaybackGateway 同源；
 * TV 与车机覆盖 client 标识与 is_mobile=false，并开放多声道环绕声直通。
 */
export class DeviceCapability {
  static readonly tvClient: string = 'harmony_tv';
  static readonly carClient: string = 'harmony_car';

  static tv(deviceId: string): DeviceProfile {
    return new DeviceProfile(DeviceCapability.tvClient, false, deviceId);
  }

  static car(deviceId: string): DeviceProfile {
    return new DeviceProfile(DeviceCapability.carClient, false, deviceId);
  }

  static forProfile(profile: DeviceProfile, engine: string, pgsOverlay: boolean = false): ClientCapabilityIn {
    const cap: ClientCapabilityIn = MovieClawPlaybackGateway.capability(engine, pgsOverlay, profile.isMobile);
    if (profile.deviceId.length > 0) {
      cap.device_id = profile.deviceId;
    }
    return cap;
  }
}
