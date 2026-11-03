import { AVPlayerEngine } from './AVPlayerEngine';
import { EngineFactory, EngineFailure, EngineId, PlayerEngine } from './PlayerEngine';

export class DefaultEngineFactory implements EngineFactory {
  async create(id: EngineId): Promise<PlayerEngine> {
    if (id === 'avplayer') { return new AVPlayerEngine(); }
    try {
      const module = await import('./MpvEngine');
      return new module.MpvEngine();
    } catch (error) {
      throw new EngineFailure('unavailable', 0, '此设备的 MPV 内核不可用');
    }
  }
}
