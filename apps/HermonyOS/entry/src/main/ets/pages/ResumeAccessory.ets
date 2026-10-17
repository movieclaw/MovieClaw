import { preferences } from '@kit.ArkData';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { NavStacks } from '../common/ShareLinks';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { MovieClawApi } from '../api/Endpoints';
import { UpNextItemView } from '../api/Models';
import { PlayerParams } from '../player/PlayerPage';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';
import { episodeCode } from '../library/LibraryShared';

/**
 * 悬浮底栏上方的「接着看」条（对应 iOS `ResumeAccessory`）。
 *
 * 语义是「一件还没结束、离开页面也还在的事」：从播放器退出时电影看到一半，这里常驻一条，
 * 点一下原地接着放，不用回媒体库找「继续观看」。内容取「继续观看」的第一条
 * （`/playback/up-next`），但**只认这台设备**播过的（`thisDevice`）——附件说的是
 * 「你刚才在这台手机上看到哪了」，在 Infuse、电视上放的不该顶上来；进度仍按人合并。
 *
 * 右边的 ✕ 把这条叉掉：记下「作品 + 季集 + 最近播放时刻」，再播任何一部（包括同一部）
 * 最近播放时刻都会变，条就自己回来。叉掉的记录存本机偏好，App 重启也不会冒出来。
 */
@ObservedV2
export class ResumeBarStore {
  @Trace private currentItem: UpNextItemView | null = null;
  /** 被叉掉的那条的键：命中就不显示（再看过别的自己回来） */
  private hiddenKey: string = '';
  private store: preferences.Preferences | null = null;
  private static readonly storeName: string = 'movieclaw_resume_bar';
  private static readonly hiddenKeyName: string = 'hiddenKey';

  get visibleItem(): UpNextItemView | null {
    const item: UpNextItemView | null = this.currentItem;
    if (item === null || ResumeBarStore.keyOf(item) === this.hiddenKey) {
      return null;
    }
    return item;
  }

  static keyOf(item: UpNextItemView): string {
    return `${item.media_item_id}|${item.season_number}|${item.episode_number}|${item.last_played_at}`;
  }

  /** 建好偏好存储并读回叉掉的那条（本机显示偏好，重启后仍有效） */
  async init(context: Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    try {
      this.store = await preferences.getPreferences(context, ResumeBarStore.storeName);
      this.hiddenKey = await this.store.get(ResumeBarStore.hiddenKeyName, '') as string;
    } catch (error) {
      this.store = null;
    }
  }

  /** 重新取最近播放的那一条（进主界面、关掉播放器、回到前台时；拉不到就保持原样） */
  async refresh(api: MovieClawApi | null): Promise<void> {
    if (api === null) {
      return;
    }
    try {
      const view = await api.playbackUpNext(1, true);
      this.currentItem = view.items.length > 0 ? view.items[0] : null;
    } catch (error) {
      // 静默：条是锦上添花，不打扰
    }
  }

  hide(): void {
    const item: UpNextItemView | null = this.currentItem;
    if (item === null) {
      return;
    }
    this.hiddenKey = ResumeBarStore.keyOf(item);
    const store: preferences.Preferences | null = this.store;
    if (store !== null) {
      store.put(ResumeBarStore.hiddenKeyName, this.hiddenKey).catch((): void => {
      });
      store.flush().catch((): void => {
      });
    }
  }
}

/** 条本身：剧照缩略图 + 片名 + 看到哪 + 播放键 + ✕（左边整块点了起播） */
@ComponentV2
export struct ResumeBar {
  @Require @Param item: UpNextItemView;
  @Event onHide: () => void = () => {
  };

  private isEpisode(): boolean {
    return this.item.kind === 'tv';
  }

  /** 第二行：剧集是季集 + 看到哪，电影是看到哪 / 下一集（同 iOS） */
  private detail(): string {
    const parts: string[] = [];
    if (this.isEpisode()) {
      parts.push(episodeCode(this.item.season_number, this.item.episode_number));
    }
    if (this.item.position_ms > 0) {
      const percent: number | null = this.item.progress_percent ?? null;
      if (percent !== null) {
        parts.push(`看到 ${percent}%`);
      }
    } else if (this.item.advanced) {
      parts.push('下一集');
    }
    return parts.join(' · ');
  }

  private artUrl(): string {
    let raw: string | null | undefined = this.isEpisode()
      ? (this.item.episode_still_url ?? this.item.backdrop_url) : this.item.backdrop_url;
    if (raw === null || raw === undefined || raw.length === 0) {
      raw = this.item.poster_url;
    }
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), raw, ImageVariant.landscapeCard);
    return resolved ?? '';
  }

  private play(): void {
    const stack: NavPathStack | null = NavStacks.of(NavStacks.currentKey);
    if (stack !== null) {
      stack.pushPathByName('player', new PlayerParams(
        this.item.media_item_id, 0, this.item.season_number, this.item.episode_number,
        this.item.position_ms));
    }
  }

  build() {
    Row() {
      // 左边整块点了起播（左边区域与 ✕ 是并排的两个按钮，按钮里套按钮点击会串）
      Row({ space: 10 }) {
        RemoteImage({
          url: this.artUrl(),
          placeholderSymbol: $r('sys.symbol.play_square')
        })
          .width(52)
          .height(30)
          .borderRadius(6)
          .clip(true)
        Column({ space: 1 }) {
          Text(this.item.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(1)
          if (this.detail().length > 0) {
            Text(this.detail())
              .fontSize(11)
              .fontColor(Theme.textMuted)
              .maxLines(1)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(16)
          .fontColor([Theme.accentStrong])
      }
      .padding({ left: 12, right: 4 })
      .layoutWeight(1)
      .height('100%')
      .onClick(() => {
        this.play();
      })

      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(13)
        .fontColor([Theme.textMuted])
        .padding(10)
        .onClick(() => {
          this.onHide();
        })
    }
    .width('100%')
    .height(56)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .shadow({ radius: 18, color: 'rgba(0,0,0,0.35)', offsetY: 6 })
  }
}
