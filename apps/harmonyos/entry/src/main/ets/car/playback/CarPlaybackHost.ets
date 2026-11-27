import { hilog } from '@kit.PerformanceAnalysisKit';
import { SkipSegments } from '@movieclaw/playback';
import { DeviceCapability } from '../../playback/DeviceCapability';
import { PlayRequest } from '../../playback/PlayRequest';
import { TvPlayPhase, TvPlaybackHost } from '../../tv/playback/TvPlaybackHost';

export {
  PlayRequest,
  SkipSegments as CarSkipSegments,
  TvPlayPhase as CarPlayPhase,
  TvPlaybackHost as CarPlaybackHost,
  TvPlaybackHost as CarAvPlayerEngine
};

/**
 * 鸿蒙座舱车机跨页起播协调（playback-first）：
 * 与智慧屏 TV 共用统一双引擎（AVPlayer + libmpv + PGS .sup + 原生 ASS + 双 Vivid），
 * 以 `harmony_car` 客户端身份向服务端上报并支持行车音频锁（隐藏画面不断音）。
 */
export class CarPlayback {
  private static host: TvPlaybackHost | null = null;

  static begin(request: PlayRequest): TvPlaybackHost {
    hilog.info(0x0000, 'MovieClawCar', 'PLAYBACK_BEGIN item=%{public}d', request.itemId);
    CarPlayback.end();
    const host: TvPlaybackHost = new TvPlaybackHost(request, DeviceCapability.carClient);
    CarPlayback.host = host;
    host.prepare().catch((): void => {
    });
    return host;
  }

  static adopt(): TvPlaybackHost | null {
    return CarPlayback.host;
  }

  static end(): void {
    const host: TvPlaybackHost | null = CarPlayback.host;
    CarPlayback.host = null;
    if (host !== null) {
      host.release();
    }
  }
}
