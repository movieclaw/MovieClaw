import { preferences } from '@kit.ArkData';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { NavStacks } from '../common/ShareLinks';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { SpatialMaterial } from '../common/SpatialMaterial';
import { MovieClawApi } from '../api/Endpoints';
import { UpNextItemView } from '../api/Models';
import { PlayerParams } from '../player/PlayerParams';
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
  @Trace private hiddenKey: string = '';
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
  /** 收起态：跟着底栏一起收成一枚圆形按钮（与页签栏的圆钮同高、同一条水平线） */
  @Param compact: boolean = false;
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
      const duration: number | null = this.item.duration_ms ?? null;
      if (duration !== null && duration > this.item.position_ms) {
        parts.push(`剩 ${this.remainingText(duration - this.item.position_ms)}`);
      }
    } else if (this.item.advanced) {
      parts.push('下一集');
    }
    return parts.join(' · ');
  }

  /** 剩余时长：不足 1 小时说分钟，超过说小时+分钟 */
  private remainingText(ms: number): string {
    const minutes: number = Math.max(1, Math.round(ms / 60000));
    if (minutes < 60) {
      return `${minutes} 分`;
    }
    const hours: number = Math.floor(minutes / 60);
    const rest: number = minutes % 60;
    return rest > 0 ? `${hours} 小时 ${rest} 分` : `${hours} 小时`;
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

  private posterUrl(): string {
    const resolved: string | null = ImageUrls.resolve(
      AppModel.origin(), this.item.poster_url, ImageVariant.posterCard);
    return resolved ?? this.artUrl();
  }

  private play(): void {
    const stack: NavPathStack | null = NavStacks.of(NavStacks.currentKey);
    if (stack !== null) {
      stack.pushPathByName('player', new PlayerParams(
        this.item.media_item_id, 0, this.item.season_number, this.item.episode_number,
        this.item.position_ms));
    }
  }

  /** 看到哪的百分比（没有进度数据返回 null，就不画环） */
  private ringPercent(): number | null {
    const raw: number | null | undefined = this.item.progress_percent;
    if (this.item.position_ms <= 0 || raw === null || raw === undefined) {
      return null;
    }
    return Math.max(0, Math.min(100, Math.round(raw)));
  }

  /** 收起态：一枚圆形唱片（封面 + 环形进度），与官方页签栏收起后的圆钮同规格 */
  @Builder
  CompactBar() {
    Stack({ alignContent: Alignment.Center }) {
      // 环绕一圈的进度：已播 = 绿色弧，未播 = 白色 16% 的轨道（没有进度也画空环）
      Progress({ value: this.ringPercent() ?? 0, total: 100, type: ProgressType.Ring })
        .width(56)
        .height(56)
        .color(Theme.ok)
        .backgroundColor('rgba(255, 255, 255, 0.16)')
        .style({ strokeWidth: 3 })
      Column({ space: 0 }) {
        RemoteImage({
          url: this.posterUrl(),
          placeholderSymbol: $r('sys.symbol.play_square')
        })
          .width(30)
          .height(30)
          .borderRadius(7)
          .clip(true)
        if (this.ringPercent() !== null) {
          Text(`${this.ringPercent()}%`)
            .fontSize(9)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .margin({ top: 1 })
        }
      }
      .justifyContent(FlexAlign.Center)
    }
    .width(56)
    .height(56)
    .backgroundColor('rgba(18, 21, 27, 0.94)')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .systemMaterial(SpatialMaterial.floating())
    .borderRadius(28)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.10)' })
    .shadow({ radius: 22, color: 'rgba(0, 0, 0, 0.45)', offsetX: 0, offsetY: 8 })
    .onClick(() => {
      this.play();
    })
  }

  build() {
    if (this.compact) {
      this.CompactBar()
    } else {
    Row() {
      // 左边整块点了起播（左边区域与 ✕ 是并排的两个按钮，按钮里套按钮点击会串）
      Row({ space: 10 }) {
        // 封面 + 环形进度（同华为音乐迷你播放条：Stack 层叠环形进度条）
        Stack({ alignContent: Alignment.Center }) {
          if (this.ringPercent() !== null) {
            Progress({ value: this.ringPercent()!, total: 100, type: ProgressType.Ring })
            .width(44)
            .height(44)
            .color(Theme.text)
            .backgroundColor('rgba(255,255,255,0.14)')
            .style({ strokeWidth: 2.5 })
          }
          RemoteImage({
            url: this.posterUrl(),
            placeholderSymbol: $r('sys.symbol.play_square')
          })
            .width(34)
            .height(34)
            .borderRadius(8)
            .clip(true)
        }
        .width(46)
        .height(46)
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
    /*
     * 和官方悬浮页签栏同一套：深色玻璃底（实色，不再靠空间化材质透出来——列表上方
     * 不在标题栏/页签栏作用域时系统材质不生效，条几乎全透明看不见）、厚模糊、
     * 1px 细描边、胶囊圆角 28。API 26+ 再叠一层空间化材质，能吃到就多一层光感。
     */
    .backgroundColor('rgba(18, 21, 27, 0.94)')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .systemMaterial(SpatialMaterial.floating())
    .borderRadius(28)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.10)' })
    .shadow({ radius: 22, color: 'rgba(0, 0, 0, 0.45)', offsetX: 0, offsetY: 8 })
    }
  }
}
