import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { SubscriptionView } from '../api/Models';
import { SubsHome } from './SubscriptionsHomeModel';

/**
 * 订阅海报卡（首页横滑与海报墙共用，对应 iOS `SubsHomePosterCard`）：
 * 海报 + 状态小签 + 当季收录细线 + 片名 + 第二行 meta +（墙上多一行「规则组 → 媒体库」流向）。
 * 已暂停 / 已收齐在首页横滑里压暗（`dimsResting`），墙上按分段标题分组、保持原色。
 */
@ComponentV2
export struct SubsPosterCard {
  @Param home: SubsHome = new SubsHome([], [], []);
  @Require @Param item: SubscriptionView;
  @Param cardWidth: number = 110;
  /** 墙上才有的第三行；空 = 不画 */
  @Param flow: string = '';
  @Param dimsResting: boolean = true;
  @Event onOpen: (item: SubscriptionView) => void = (item: SubscriptionView): void => {
  };
  /** 长按菜单「查看影片详情」（同 iOS `contextMenu`） */
  @Event onOpenMedia: (item: SubscriptionView) => void = (item: SubscriptionView): void => {
  };

  private dimmed(): boolean {
    return this.dimsResting && this.home.isResting(this.item);
  }

  build() {
    Column({ space: 0 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        RemoteImage({
          url: ImageUrls.resolve(AppModel.origin(), this.item.media.poster_url, ImageVariant.posterCard) ?? ''
        })
          .width('100%')
          .height('100%')
          .opacity(this.dimmed() ? 0.55 : 1)
        if (this.home.standing(this.item).chipText.length > 0) {
          Row({ space: 4 }) {
            Circle()
              .width(5)
              .height(5)
              .fill(this.home.standing(this.item).chipColor)
            Text(this.home.standing(this.item).chipText)
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.home.standing(this.item).chipColor)
              .maxLines(1)
          }
          .padding({ left: 7, right: 7, top: 4, bottom: 4 })
          .backgroundColor('rgba(0,0,0,0.42)')
          .borderRadius(10)
          .margin({ left: 7, top: 7 })
        }
        if (this.home.seasonProgress(this.item) >= 0) {
          Column() {
            Column() {
              Row()
                .width(`${Math.round(this.home.seasonProgress(this.item) * 100)}%`)
                .height(2.5)
                .backgroundColor('rgba(255,255,255,0.92)')
            }
            .width('100%')
            .height(2.5)
            .backgroundColor('rgba(255,255,255,0.2)')
            .justifyContent(FlexAlign.Start)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
        }
      }
      .width('100%')
      .aspectRatio(Theme.posterAspect)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .clip(true)

      Text(this.item.media.title)
        .fontSize(13)
        .fontWeight(600)
        .fontColor(this.dimmed() ? Theme.textMuted : Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 8 })
      Text(this.home.meta(this.item, this.home.standing(this.item).phase))
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 1 })
      if (this.flow.length > 0) {
        Text(this.flow)
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 1 })
      }
    }
    .width(this.cardWidth)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onOpen(this.item);
    })
    .bindContextMenu(this.CardMenu(), ResponseType.LongPress)
  }

  /** 长按菜单（同 iOS `contextMenu`）：查看订阅详情 / 查看影片详情 */
  @Builder
  CardMenu() {
    Menu() {
      MenuItem({ content: '查看订阅详情', startIcon: $r('sys.symbol.rectangle_stack') })
        .onClick(() => {
          this.onOpen(this.item);
        })
      MenuItem({ content: '查看影片详情', startIcon: $r('sys.symbol.film') })
        .onClick(() => {
          this.onOpenMedia(this.item);
        })
    }
  }
}
