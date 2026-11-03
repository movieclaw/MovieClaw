import { UpNextItemView } from '../api/Models';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { RemoteImage } from '../common/RemoteImage';
import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { episodeCode } from './LibraryShared';

/**
 * 首页大图轮播（对应华为视频推荐页区域 1 的 Banner 图）：
 * 全宽剧照轮播 + 底部渐变压黑 + 片名 / 元信息 / 简介 / 进度条 / 播放·详情按钮 +
 * 右下角胶囊指示点（当前页拉长为胶囊）。数据来自「接下来继续」，自动轮播 5s。
 */
@ComponentV2
export struct HeroBanner {
  @Require @Param items: UpNextItemView[];
  @Param origin: string = '';
  /** 点卡片进条目详情（宿主压栈） */
  @Param onOpen: (item: UpNextItemView) => void = (fallback: UpNextItemView): void => {
  };
  /** 播放键直接开播（宿主压栈） */
  @Param onPlay: (item: UpNextItemView) => void = (fallback: UpNextItemView): void => {
  };
  /** 当前页下标（驱动指示点；onChange 由 Swiper 回写） */
  @Local private current: number = 0;

  /**
   * 轮播页数封顶（同华为视频 Banner 只放少量精选）：
   * 「接下来继续」可能有几十条，全部进轮播指示点会挤成一排，取前 6 条。
   */
  private pages(): UpNextItemView[] {
    return this.items.slice(0, 6);
  }

  private artUrl(item: UpNextItemView): string {
    const raw: string | null | undefined = item.kind === 'tv'
      ? (item.episode_still_original_url ?? item.episode_still_url ?? item.backdrop_url)
      : item.backdrop_url;
    // Banner 占满屏宽：横卡的 480 放大发虚，用 720p 的 reel-still
    return ImageUrls.resolve(this.origin, raw, ImageVariant.reelStill) ?? '';
  }

  /** 元信息行：年份 / 类型（最多 3 个）/ 季集 / 还有 N 集 */
  private meta(item: UpNextItemView): string {
    const parts: string[] = [];
    if (item.year !== null && item.year !== undefined) {
      parts.push(`${item.year}`);
    }
    const genres: string[] | null | undefined = item.genres;
    if (genres !== null && genres !== undefined && genres.length > 0) {
      parts.push(genres.slice(0, 3).join(' / '));
    }
    if (item.kind === 'tv') {
      parts.push(episodeCode(item.season_number, item.episode_number));
    }
    if (item.unwatched_ahead_count > 0) {
      parts.push(`还有 ${item.unwatched_ahead_count} 集`);
    }
    return parts.join(' · ');
  }

  private progressPercent(item: UpNextItemView): number | null {
    if (item.position_ms <= 0) {
      return null;
    }
    const raw: number | null | undefined = item.progress_percent;
    if (raw === null || raw === undefined) {
      return null;
    }
    return Math.max(0, Math.min(100, Math.round(raw)));
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Swiper() {
        ForEach(this.pages(), (item: UpNextItemView) => {
          this.BannerPage(item)
        }, (item: UpNextItemView) => `${item.media_item_id}`)
      }
      .autoPlay(this.pages().length > 1)
      .interval(5000)
      .loop(this.pages().length > 1)
      .indicator(false)
      .cachedCount(2)
      .curve(Curve.EaseOut)
      .duration(420)
      .onChange((index: number) => {
        this.current = index;
      })
      .width('100%')
      .height(236)

      // 右下角胶囊指示点（华为视频同款：当前页拉长）
      Row({ space: 5 }) {
        ForEach(this.pages(), (_dot: UpNextItemView, dotIndex: number) => {
          Row()
            .width(dotIndex === this.current ? 14 : 6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(dotIndex === this.current ? Theme.text : Theme.textFaint)
            .animation({ duration: 220, curve: Curve.EaseOut })
        }, (_dotKey: UpNextItemView, dotKeyIndex: number) => `dot-${dotKeyIndex}`)
      }
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 14, bottom: 12 })
      .backgroundColor('rgba(0, 0, 0, 0.35)')
      .borderRadius(10)
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
  }

  @Builder
  BannerPage(item: UpNextItemView) {
    Stack({ alignContent: Alignment.BottomStart }) {
      RemoteImage({
        url: this.artUrl(item),
        placeholderSymbol: $r('sys.symbol.play_square')
      })
        .width('100%')
        .height('100%')

      // 底部渐变压黑：文字可读，上缘自然融入
      Column()
        .width('100%')
        .height(150)
        .linearGradient({
          angle: 180,
          colors: [['rgba(0,0,0,0)', 0.0], ['rgba(0,0,0,0.55)', 0.45], ['rgba(0,0,0,0.92)', 1.0]]
        })

      // 整卡点击进详情：垫在内容列下面的透明命中层——点内容列的文字/空白落到这里，
      // 点播放/详情按钮被上层按钮吃掉（本 SDK 的 ClickEvent 没有 stopPropagation）
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.onOpen(item);
        })

      Column({ space: 7 }) {
        Text(item.title)
          .fontSize(23)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.meta(item).length > 0) {
          Text(this.meta(item))
            .fontSize(11)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        if (item.overview !== null && item.overview !== undefined && item.overview.length > 0) {
          Text(item.overview)
            .fontSize(12)
            .fontColor('rgba(243, 245, 249, 0.78)')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .lineHeight(17)
        }
        if (this.progressPercent(item) !== null) {
          // 细进度条（华为视频 Banner 的观看进度线）
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(3)
              .borderRadius(1.5)
              .backgroundColor('rgba(255,255,255,0.18)')
            Row()
              .width(`${this.progressPercent(item)}%`)
              .height(3)
              .borderRadius(1.5)
              .backgroundColor(Theme.text)
          }
          .width(150)
          .margin({ top: 2 })
        }
        Row({ space: 10 }) {
          Button() {
            Text(this.progressLabel(item))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#000000')
          }
          .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(18)
          .onClick(() => {
            this.onPlay(item);
          })
          Button() {
            Row({ space: 5 }) {
              SymbolGlyph($r('sys.symbol.play_square'))
                .fontSize(13)
                .fontColor(['#000000'])
              Text('详情')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.text)
            }
            .padding({ left: 13, right: 13, top: 7, bottom: 7 })
          }
          .attributeModifier(new GlassButtonModifier(GlassTone.Dark))
          .padding(0)
          .clip(true)
          .borderRadius(17)
          .onClick(() => {
            this.onOpen(item);
          })
        }
        .margin({ top: 3 })
      }
      .padding({ left: 16, right: 16, bottom: 14 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(236)
    .borderRadius(Theme.cardRadius)
    .clip(true)
  }

  /** 主按钮文案：看了一半是「继续播放」，全新是「播放」（进度条同步展示） */
  private progressLabel(item: UpNextItemView): string {
    const percent: number | null = this.progressPercent(item);
    if (percent !== null) {
      return `继续播放 · ${percent}%`;
    }
    return item.position_ms > 0 ? '继续播放' : '播放';
  }
}
