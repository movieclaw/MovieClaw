import { AudioSupportIn, ClientCapabilityIn, VideoSupportIn } from '../api/Models';

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
 * 按端 × 按引擎的能力申报（FR-006）：
 * 编解码 / 容器表是引擎维度，与 MovieClawPlaybackGateway.capability 同源；
 * 端维度只覆盖 client 标识与 is_mobile 口径——TV 与车机都不是移动端。
 */
export class DeviceCapability {
  static readonly tvClient: string = 'harmony_tv';
  static readonly carClient: string = 'harmony_car';

  /** TV 端口径（deviceId 传 TvUiState 的安装标识；空 = 不报 device_id） */
  static tv(deviceId: string): DeviceProfile {
    return new DeviceProfile(DeviceCapability.tvClient, false, deviceId);
  }

  /** 车机端口径（deviceId 传 CarUiState 的安装标识；空 = 不报 device_id） */
  static car(deviceId: string): DeviceProfile {
    return new DeviceProfile(DeviceCapability.carClient, false, deviceId);
  }

  /** 按引擎的能力申报：编解码表与手机网关一致，is_mobile 按端覆盖 */
  static capability(profile: DeviceProfile, engine: string): ClientCapabilityIn {
    const mpv: boolean = engine === 'mpv';
    const video: VideoSupportIn[] = [];
    const audio: AudioSupportIn[] = [];
    const videos: string[] = mpv
      ? ['h264', 'hevc', 'vp8', 'vp9', 'mpeg2video', 'mpeg4', 'vc1'] : ['h264', 'hevc'];
    const audios: string[] = mpv
      ? ['aac', 'mp3', 'ac3', 'eac3', 'dts', 'flac', 'opus', 'vorbis', 'alac', 'truehd', 'mp2',
        'pcm_s16le', 'pcm_s24le', 'pcm_bluray', 'pcm_dvd'] : ['aac', 'mp3'];
    for (const codec of videos) {
      video.push({ codec: codec, max_height: 2160 });
    }
    for (const codec of audios) {
      audio.push({ codec: codec });
    }
    return {
      video: video,
      audio: audio,
      containers: mpv ? ['mp4', 'mkv', 'ts', 'avi', 'mov', 'webm', 'flv'] : ['mp4', 'mkv', 'ts'],
      local_tracks: true, hdr_passthrough: false, mse: 'full', native_hls: true,
      is_mobile: profile.isMobile, universal: false
    };
  }

  /** 能力申报函数（给 MovieClawPlaybackGateway 参数化用）：端口径固定、引擎维度动态 */
  static capabilityOf(profile: DeviceProfile): (engine: string) => ClientCapabilityIn {
    return (engine: string): ClientCapabilityIn => DeviceCapability.capability(profile, engine);
  }
}
