import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 分享访客的本机进度（照 iOS `ShareLocalProgress`，同 Web `lib/player/local-progress.ts`）：
 * 访客没有成员身份，进度不落服务端，只记在这台设备上，按分享 slug 分命名空间。
 *
 * 只存位置（毫秒）；音轨/字幕记忆等播放器有换轨能力时再补。
 */
export class ShareLocalProgress {
  private static store: preferences.Preferences | null = null;
  private static ready: Promise<void> | null = null;

  /** EntryAbility.onCreate 里尽早调用；异步加载，不阻塞首帧 */
  static init(context: Context): void {
    if (ShareLocalProgress.ready === null) {
      ShareLocalProgress.ready = preferences.getPreferences(context, 'movieclaw_share_progress')
        .then((store: preferences.Preferences): void => {
          ShareLocalProgress.store = store;
        });
    }
  }

  private static key(slug: string, mediaItemId: number, season: number, episode: number): string {
    return `progress.${slug}.${mediaItemId}.${season}x${episode}`;
  }

  /** 读上次看到的位置（毫秒）；没有记录返回 0 */
  static async read(slug: string, mediaItemId: number, season: number, episode: number): Promise<number> {
    await ShareLocalProgress.ready;
    const store: preferences.Preferences | null = ShareLocalProgress.store;
    if (store === null) {
      return 0;
    }
    try {
      const raw: string = await store.get(ShareLocalProgress.key(slug, mediaItemId, season, episode), '') as string;
      const value: number = raw.length > 0 ? Number(raw) : 0;
      return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
    } catch (error) {
      return 0;
    }
  }

  /** 记位置（毫秒）；失败静默——进度记录不影响播放 */
  static write(slug: string, mediaItemId: number, season: number, episode: number, positionMs: number): void {
    const save = async (): Promise<void> => {
      await ShareLocalProgress.ready;
      const store: preferences.Preferences | null = ShareLocalProgress.store;
      if (store === null || positionMs <= 0) {
        return;
      }
      try {
        await store.put(ShareLocalProgress.key(slug, mediaItemId, season, episode), `${Math.floor(positionMs)}`);
        await store.flush();
      } catch (error) {
        hilog.warn(0x0000, 'ShareProgress', '写入访客进度失败: %{public}s', `${error}`);
      }
    };
    save();
  }
}
