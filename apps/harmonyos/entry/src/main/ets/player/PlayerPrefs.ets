import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';

/**
 * 播放器的本机偏好（对应 iOS `PlayerPreferences` 的两块）：
 * - 画质记忆：按条目记用户选过的画质上限（iOS `QualityMemory`），下次起播沿用；
 * - 字幕样式：自绘字幕（本机外挂轨）的字号 / 位置 / 背景（iOS `SubtitleStyle`）。
 *
 * preferences 落盘；EntryAbility.onCreate 里 init，异步加载不阻塞首帧。
 */
export class PlayerPrefs {
  private static store: preferences.Preferences | null = null;
  private static ready: Promise<void> | null = null;

  /** EntryAbility.onCreate 里尽早调用 */
  static init(context: Context): void {
    if (PlayerPrefs.ready === null) {
      PlayerPrefs.ready = preferences.getPreferences(context, 'movieclaw_player_prefs')
        .then((store: preferences.Preferences): void => {
          PlayerPrefs.store = store;
        });
    }
  }

  /** 读这一集记过的画质上限（0 = 自动 / 原画）；没有记录返回 0 */
  static async quality(mediaItemId: number, season: number, episode: number): Promise<number> {
    await PlayerPrefs.ready;
    const store: preferences.Preferences | null = PlayerPrefs.store;
    if (store === null) {
      return 0;
    }
    try {
      const raw: string = await store.get(`quality.${mediaItemId}.${season}x${episode}`, '') as string;
      const value: number = Number(raw);
      return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
    } catch (error) {
      return 0;
    }
  }

  /** 记画质上限（0 = 自动）；失败静默——记不住不影响播放 */
  static writeQuality(mediaItemId: number, season: number, episode: number, maxHeight: number): void {
    const save = async (): Promise<void> => {
      await PlayerPrefs.ready;
      const store: preferences.Preferences | null = PlayerPrefs.store;
      if (store === null) {
        return;
      }
      try {
        await store.put(`quality.${mediaItemId}.${season}x${episode}`, `${Math.floor(maxHeight)}`);
        await store.flush();
      } catch (error) {
      }
    };
    save();
  }

  /** 读自绘字幕样式；读取失败给 iOS 的默认值（fontScale 5.2%、底部 8%、带背景） */
  static async subtitleStyle(): Promise<SubStyle> {
    const style: SubStyle = new SubStyle();
    await PlayerPrefs.ready;
    const store: preferences.Preferences | null = PlayerPrefs.store;
    if (store === null) {
      return style;
    }
    try {
      const raw: string = await store.get('subtitle.style', '') as string;
      if (raw.length > 0) {
        const parsed: SubStyleRaw = JSON.parse(raw) as SubStyleRaw;
        if (Number.isFinite(parsed.fontScale)) {
          style.fontScale = Math.min(10, Math.max(2, parsed.fontScale));
        }
        if (Number.isFinite(parsed.bottomPercent)) {
          style.bottomPercent = Math.min(40, Math.max(0, parsed.bottomPercent));
        }
        if (parsed.background !== undefined) {
          style.background = parsed.background === true;
        }
      }
    } catch (error) {
      // 坏数据当默认值
    }
    return style;
  }

  /** 记字幕样式；失败静默 */
  static writeSubtitleStyle(style: SubStyle): void {
    const save = async (): Promise<void> => {
      await PlayerPrefs.ready;
      const store: preferences.Preferences | null = PlayerPrefs.store;
      if (store === null) {
        return;
      }
      try {
        const raw: SubStyleRaw = {
          fontScale: style.fontScale,
          bottomPercent: style.bottomPercent,
          background: style.background
        };
        await store.put('subtitle.style', JSON.stringify(raw));
        await store.flush();
      } catch (error) {
      }
    };
    save();
  }
}

/** 自绘字幕样式（iOS `SubtitleStyle`：刻意不设描边——中文字形描边有黑缝） */
export class SubStyle {
  /** 字号 = 屏宽 × fontScale%（2–10，默认 5.2） */
  fontScale: number = 5.2;
  /** 距屏幕底部的高度百分比（0–40，默认 8） */
  bottomPercent: number = 8;
  /** 要不要黑底胶囊 */
  background: boolean = true;
}

/** 落盘的 JSON 形状（ArkTS 不允许对象字面量直接当类型，用接口声明） */
interface SubStyleRaw {
  fontScale: number;
  bottomPercent: number;
  background: boolean;
}
