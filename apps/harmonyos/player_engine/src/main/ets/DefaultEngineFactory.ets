import { AVPlayerEngine } from './AVPlayerEngine';
import { EngineFactory, EngineFailure, EngineId, PlayerEngine } from './PlayerEngine';

export class DefaultEngineFactory implements EngineFactory {
  /** mpv 的 CA 信任库路径（空 = 不设 tls-ca-file；宿主从 MpvTrust 注入） */
  private readonly caPath: string;

  constructor(caPath: string = '') {
    this.caPath = caPath;
  }

  async create(id: EngineId): Promise<PlayerEngine> {
    if (id === 'avplayer') { return new AVPlayerEngine(); }
    try {
      const module = await import('./MpvEngine');
      return new module.MpvEngine(this.caPath);
    } catch (error) {
      throw new EngineFailure('unavailable', 0, '此设备的 MPV 内核不可用');
    }
  }
}
