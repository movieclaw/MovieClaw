/**
 * 车机卡片库（对应 TV 端 tv/components/TvCards.ets 的触屏裁剪版）：
 * - CarPressable 按压基座：触屏无焦点体系，官方 onTouch/onClick 驱动按压缩放反馈
 * - CarContinueCard 继续观看大卡（首页置顶：全幅剧照 + 左信息右内容 + 进度条，一键续播）
 * - CarPosterCard 海报卡（2:3，图下常显「片名 · 年份」——触屏没有获焦浮现，信息常显符合 3 秒注视原则）
 * - CarLandscapeCard 横版大卡（16:9，收藏行/继续观看行；可选底部暗带：▶ 进度 说明）
 * - CarEpisodeCard 分集卡（剧照 + 进度 + 集名 + 首播 + 简介，详情页选集用）
 * - CarLibraryCard 媒体库卡（21:10 货架封面贴顶 + 模糊延伸底 + 库名暗带）
 * - CarGenreCard 类型入口卡（16:9 剧照 + 居中类型名）
 * - CarPersonCard 演职员竖卡（2:3，无照片画姓名首字；姓名 + 作品数）
 * - CarSeeAllCard 「查看全部」尾卡
 * - CarProgressStrip 观看进度条 / CarStateView 空态与错误态
 * - CarFormat 文案工具（剩 N 分钟 / 第 X 季第 Y 集）
 *
 * 图片复用 common/RemoteImage（带设备令牌的取图 + 按账号隔离的内存缓存），
 * URL 由调用方用 ImageUrls.resolve 解析好传入。全部触控目标 ≥48vp（CarMetrics 令牌保证）。
 */
import { RemoteImage } from '../../common/RemoteImage';
import { CarColors } from '../theme/CarTheme';
import { CarMetrics } from '../theme/CarTheme';
import { CarType } from '../theme/CarTheme';
import { CarMotion } from '../theme/CarTheme';

/** 车机文案工具（口径同 TV 端 TvFormat） */
export class CarFormat {
  /** 「剩 23 分钟」「剩 1 小时 5 分」；时长未知返回 null */
  static remaining(positionMs: number, durationMs: number | null): string | null {
    if (durationMs === null || durationMs <= 0) {
      return null;
    }
    const minutes: number = Math.max(1, Math.round((durationMs - positionMs) / 60000));
    if (minutes >= 60) {
      return `剩 ${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`;
    }
    return `剩 ${minutes} 分钟`;
  }

  /** 「42 分钟」「1 小时 58 分」（整部片长） */
  static duration(minutes: number): string {
    const m: number = Math.max(1, Math.round(minutes));
    if (m >= 60) {
      return `${Math.floor(m / 60)} 小时 ${m % 60} 分`;
    }
    return `${m} 分钟`;
  }

  /** 「第 2 季 第 6 集 · 集名」；TMDB 未起名的集不重复写 */
  static episodeLine(season: number, episode: number, name: string | null): string {
    const number: string = `第 ${season} 季 第 ${episode} 集`;
    if (name === null) {
      return number;
    }
    const trimmed: string = name.trim();
    if (trimmed.length === 0 || /^(第\s*\d+\s*集|Episode\s*\d+)$/i.test(trimmed)) {
      return number;
    }
    return `${number} · ${trimmed}`;
  }
}

/** 空内容兜底：@BuilderParam 必须有默认值 */
@Builder
function CarPressableEmpty(): void {
}

/**
 * 车机按压基座（对应 TV TvFocusable 的触屏版）：
 * 按下 = 官方 onTouch 的 Down/Up/Cancel 驱动缩放反馈（CarMotion.pressMs 过渡），
 * 抬起 = onClick 激活回调。滚动接管时系统送 Cancel，按压态自动释放。
 */
@ComponentV2
export struct CarPressable {
  @BuilderParam content: () => void = CarPressableEmpty;
  /** 按下缩放系数；1 = 不缩放 */
  @Param pressScale: number = CarMetrics.pressScale;
  @Param onActivate: (() => void) | null = null;
  /** 按下即触发（海报墙换背景用；与 onClick 的激活不同） */
  @Param onPressed: (() => void) | null = null;

  @Local pressed: boolean = false;

  private setPressed(next: boolean): void {
    if (this.pressed === next) {
      return;
    }
    this.getUIContext().animateTo(
      { duration: CarMotion.pressMs, curve: Curve.EaseOut },
      (): void => {
        this.pressed = next;
      });
  }

  build() {
    Stack() {
      this.content()
    }
    .scale({
      x: this.pressed ? this.pressScale : 1,
      y: this.pressed ? this.pressScale : 1
    })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.setPressed(true);
        const pressCb = this.onPressed;
        if (pressCb !== null) {
          pressCb();
        }
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.setPressed(false);
      }
    })
    .onClick((): void => {
      const cb = this.onActivate;
      if (cb !== null) {
        cb();
      }
    })
  }
}

/** 图片底部的观看进度条 */
@ComponentV2
export struct CarProgressStrip {
  /** 0～1；0 不画 */
  @Param value: number = 0;
  /** 没看的那段：压在亮画面上用半透明黑，压在暗带里用半透明白 */
  @Param trackColor: string = 'rgba(0, 0, 0, 0.45)';

  private pct(): number {
    const v: number = this.value < 0 ? 0 : (this.value > 1 ? 1 : this.value);
    return v * 100;
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .height(4)
        .width('100%')
        .borderRadius(2)
        .backgroundColor(this.trackColor)
      Row()
        .height(4)
        .width(`${this.pct()}%`)
        .borderRadius(2)
        .backgroundColor('#ffffff')
    }
    .width('100%')
    .height(4)
  }
}

/** 继续观看大卡（首页置顶）：全幅剧照 + 左侧压暗（宽屏左信息右内容）+ 标题/集数/进度 + 一键续播 */
@ComponentV2
export struct CarContinueCard {
  @Param title: string = '';
  /** 集数行（「第 2 季 第 6 集 · 集名」；电影为 null） */
  @Param headline: string | null = null;
  /** 事实行（年份 · 类型 · 片长） */
  @Param metaLine: string | null = null;
  /** 已解析的横版剧照 URL；空串 = 无图 */
  @Param imageUrl: string = '';
  /** 0～1 观看进度 */
  @Param progress: number = 0;
  /** 图上角标（「下一集」） */
  @Param badge: string | null = null;
  /** 剩余时间（「剩 23 分钟」；未知为 null） */
  @Param remainingText: string | null = null;
  @Param cardHeight: number = 272;
  @Param onActivate: (() => void) | null = null;

  build() {
    CarPressable({
      onActivate: this.onActivate
    }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Stack() {
          RemoteImage({ url: this.imageUrl, placeholderText: this.title })
        }
        .width('100%')
        .height('100%')

        // 左侧压暗托字（宽屏左信息右内容：左 58% 从黑渐隐到透明）
        Column()
          .width('58%')
          .height('100%')
          .linearGradient({
            angle: 90,
            colors: [['rgba(0, 0, 0, 0.62)', 0], ['rgba(0, 0, 0, 0.28)', 0.55], ['rgba(0, 0, 0, 0)', 1]]
          })

        // 底部整体渐变：信息块压得住
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [['rgba(0, 0, 0, 0)', 0.3], ['rgba(0, 0, 0, 0.35)', 0.6], ['rgba(0, 0, 0, 0.85)', 1]]
          })

        this.InfoBlock()
      }
      .width('100%')
      .height(this.cardHeight)
      .borderRadius(CarMetrics.cardCorner)
      .clip(true)
    }
  }

  /** 左下信息块：角标 → 标题 → 集数 → 续播胶囊 + 剩余 → 进度条 */
  @Builder
  private InfoBlock() {
    Column({ space: 10 }) {
      if (this.badge !== null) {
        Text(this.badge ?? '')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(CarColors.text)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor('rgba(0, 0, 0, 0.6)')
          .borderRadius(12)
          .maxLines(1)
      }
      Text(this.title)
        .fontSize(CarType.heroTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(CarColors.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.headline !== null) {
        Text(this.headline)
          .fontSize(CarType.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(CarColors.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Row({ space: 16 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(18)
            .fontColor([CarColors.bg])
          Text(this.progress > 0 ? '继续播放' : '播放')
            .fontSize(CarType.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(CarColors.bg)
        }
        .alignItems(VerticalAlign.Center)
        .height(CarMetrics.minTouch)
        .padding({ left: 26, right: 26 })
        .backgroundColor(CarColors.text)
        .borderRadius(999)

        Column({ space: 6 }) {
          if (this.metaLine !== null) {
            Text(this.metaLine)
              .fontSize(CarType.footnote)
              .fontColor(CarColors.textMuted)
              .maxLines(1)
          }
          if (this.remainingText !== null) {
            Text(this.remainingText)
              .fontSize(CarType.footnote)
              .fontColor(CarColors.textFaint)
              .maxLines(1)
          }
        }
        .alignItems(HorizontalAlign.Start)
      }
      .alignItems(VerticalAlign.Center)

      if (this.progress > 0) {
        Row() {
          CarProgressStrip({ value: this.progress, trackColor: 'rgba(255, 255, 255, 0.3)' })
        }
        .width(320)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CarMetrics.edge, right: 24, bottom: 24 })
    .width('100%')
  }
}

/** 海报卡（2:3）：图下常显「片名 · 年份」（触屏没有获焦浮现，信息常显） */
@ComponentV2
export struct CarPosterCard {
  @Param title: string = '';
  @Param subtitle: string | null = null;
  @Param imageUrl: string = '';
  @Param cardWidth: number = CarMetrics.posterWidth;
  /** 0～1 观看进度；0 不画进度条 */
  @Param progress: number = 0;
  @Param badge: string | null = null;
  /** always 常显副标题下的说明行（搜索命中原因） */
  @Param note: string | null = null;
  @Param onActivate: (() => void) | null = null;
  /** 按下即触发（海报墙换背景用） */
  @Param onPressed: (() => void) | null = null;

  private artHeight(): number {
    return this.cardWidth * 1.5;
  }

  build() {
    CarPressable({
      onActivate: this.onActivate,
      onPressed: this.onPressed
    }) {
      Column() {
        Stack({ alignContent: Alignment.Bottom }) {
          Stack() {
            RemoteImage({ url: this.imageUrl, placeholderText: this.title })
          }
          .width(this.cardWidth)
          .height(this.artHeight())
          .borderRadius(CarMetrics.cardCorner)
          .clip(true)

          if (this.progress > 0) {
            Row() {
              CarProgressStrip({ value: this.progress })
            }
            .padding({ left: 8, right: 8, bottom: 8 })
            .width(this.cardWidth)
          }
          if (this.badge !== null) {
            Text(this.badge ?? '')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor(CarColors.text)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor('rgba(0, 0, 0, 0.6)')
              .borderRadius(9)
              .maxLines(1)
              .position({ x: 8, y: 8 })
          }
        }
        .width(this.cardWidth)
        .height(this.artHeight())

        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(CarType.cardCaption)
            .fontWeight(FontWeight.Medium)
            .fontColor(CarColors.text)
            .maxLines(1)
          if (this.subtitle !== null) {
            Text(this.subtitle)
              .fontSize(12)
              .fontColor(CarColors.textMuted)
              .maxLines(1)
          }
          if (this.note !== null) {
            Text(this.note)
              .fontSize(12)
              .fontColor(CarColors.textFaint)
              .maxLines(1)
          }
        }
        .width(this.cardWidth)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 10 })
      }
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/** 横版大卡（16:9）：「接下来继续」剩余项、收藏大卡行。给了 detail 时进度条与说明收进底部暗带 */
@ComponentV2
export struct CarLandscapeCard {
  @Param title: string = '';
  @Param subtitle: string | null = null;
  @Param imageUrl: string = '';
  @Param cardWidth: number = CarMetrics.landscapeBigWidth;
  /** 0～1 观看进度 */
  @Param progress: number = 0;
  @Param badge: string | null = null;
  /** 压在图片底部暗带里的一行说明（「S2 E6 · 剩 18 分钟」） */
  @Param detail: string | null = null;
  @Param onActivate: (() => void) | null = null;

  private artHeight(): number {
    return this.cardWidth * 9 / 16;
  }

  build() {
    CarPressable({
      onActivate: this.onActivate
    }) {
      Column() {
        Stack({ alignContent: Alignment.Bottom }) {
          Stack() {
            RemoteImage({ url: this.imageUrl, placeholderText: this.title })
          }
          .width(this.cardWidth)
          .height(this.artHeight())
          .borderRadius(CarMetrics.cardCorner)
          .clip(true)

          if (this.detail !== null) {
            this.DetailBand()
          } else if (this.progress > 0) {
            Row() {
              CarProgressStrip({ value: this.progress })
            }
            .padding({ left: 10, right: 10, bottom: 10 })
            .width(this.cardWidth)
          }
          if (this.badge !== null) {
            Text(this.badge ?? '')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor(CarColors.text)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor('rgba(0, 0, 0, 0.6)')
              .borderRadius(9)
              .maxLines(1)
              .position({ x: 8, y: 8 })
          }
        }
        .width(this.cardWidth)
        .height(this.artHeight())

        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(CarType.cardCaption)
            .fontWeight(FontWeight.Medium)
            .fontColor(CarColors.text)
            .maxLines(1)
          if (this.subtitle !== null) {
            Text(this.subtitle)
              .fontSize(12)
              .fontColor(CarColors.textMuted)
              .maxLines(1)
          }
        }
        .width(this.cardWidth)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 10 })
      }
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 图片底部暗带：▶ 进度条 · 说明一行 */
  @Builder
  private DetailBand() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(12)
        .fontColor([CarColors.text])
      if (this.progress > 0) {
        Row() {
          CarProgressStrip({ value: this.progress, trackColor: 'rgba(255, 255, 255, 0.3)' })
        }
        .width(40)
      }
      Text(this.detail ?? '')
        .fontSize(12)
        .fontWeight(600)
        .fontColor(CarColors.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Center)
    .padding({ left: 12, right: 12, top: 20, bottom: 10 })
    .width(this.cardWidth)
    .linearGradient({
      angle: 180,
      colors: [['rgba(0, 0, 0, 0)', 0], ['rgba(0, 0, 0, 0.75)', 1]]
    })
  }
}

/** 分集卡（详情页选集横排）：剧照 + 进度 + 集名 + 首播日期 + 两行简介 */
@ComponentV2
export struct CarEpisodeCard {
  /** 「第 1 集 · 冬湖」 */
  @Param epTitle: string = '';
  @Param imageUrl: string = '';
  @Param cardWidth: number = CarMetrics.landscapeBigWidth;
  /** 0～1 观看进度 */
  @Param progress: number = 0;
  /** 图上角标（「已看」「缺集」） */
  @Param badge: string | null = null;
  @Param airDate: string | null = null;
  @Param overview: string | null = null;
  @Param onActivate: (() => void) | null = null;

  private artHeight(): number {
    return this.cardWidth * 9 / 16;
  }

  build() {
    CarPressable({
      onActivate: this.onActivate
    }) {
      Column() {
        Stack({ alignContent: Alignment.Bottom }) {
          Stack() {
            RemoteImage({ url: this.imageUrl, placeholderText: this.epTitle })
          }
          .width(this.cardWidth)
          .height(this.artHeight())
          .borderRadius(CarMetrics.cardCorner)
          .clip(true)

          if (this.progress > 0) {
            Row() {
              CarProgressStrip({ value: this.progress })
            }
            .padding({ left: 10, right: 10, bottom: 10 })
            .width(this.cardWidth)
          }
          if (this.badge !== null) {
            Text(this.badge ?? '')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor(CarColors.text)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor('rgba(0, 0, 0, 0.6)')
              .borderRadius(9)
              .maxLines(1)
              .position({ x: 8, y: 8 })
          }
        }
        .width(this.cardWidth)
        .height(this.artHeight())

        Row({ space: 8 }) {
          Text(this.epTitle)
            .fontSize(15)
            .fontWeight(600)
            .fontColor(CarColors.text)
            .maxLines(1)
            .layoutWeight(1)
          if (this.airDate !== null) {
            Text(this.airDate)
              .fontSize(12)
              .fontColor(CarColors.textFaint)
              .maxLines(1)
          }
        }
        .width(this.cardWidth)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 8 })

        if (this.overview !== null) {
          Text(this.overview)
            .fontSize(12)
            .fontColor(CarColors.textMuted)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(this.cardWidth)
            .margin({ top: 3 })
        }
      }
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/** 「我的媒体库」行的库卡 / 合集卡：16:9，21:10 货架封面贴顶，底部库名暗带 */
@ComponentV2
export struct CarLibraryCard {
  @Param name: string = '';
  @Param count: number = 0;
  @Param imageUrl: string = '';
  @Param collection: boolean = false;
  @Param cardWidth: number = CarMetrics.libraryCardWidth;
  @Param onActivate: (() => void) | null = null;

  private cardHeight(): number {
    return this.cardWidth * 9 / 16;
  }

  /** 服务端按 21:10 拼的货架封面 */
  private coverHeight(): number {
    return this.cardWidth * 10 / 21;
  }

  build() {
    CarPressable({
      onActivate: this.onActivate
    }) {
      Stack({ alignContent: Alignment.Bottom }) {
        // 底：同一张封面放大模糊铺满 + 压暗
        Stack({ alignContent: Alignment.TopStart }) {
          Stack() {
            RemoteImage({
              url: this.imageUrl,
              placeholderSymbol: this.collection
                ? $r('sys.symbol.rectangle_stack') : $r('sys.symbol.film'),
              placeholderText: ''
            })
          }
          .width(this.cardWidth)
          .height(this.cardHeight())
          .blur(14)
          Column()
            .width(this.cardWidth)
            .height(this.cardHeight())
            .backgroundColor('rgba(0, 0, 0, 0.35)')
          // 21:10 封面贴顶完整显示
          Stack() {
            RemoteImage({
              url: this.imageUrl,
              placeholderSymbol: this.collection
                ? $r('sys.symbol.rectangle_stack') : $r('sys.symbol.film'),
              placeholderText: ''
            })
          }
          .width(this.cardWidth)
          .height(this.coverHeight())
          // 封面下沿渐隐接进模糊底
          Column()
            .width(this.cardWidth)
            .height(28)
            .position({ x: 0, y: this.coverHeight() - 28 })
            .linearGradient({
              angle: 180,
              colors: [['rgba(0, 0, 0, 0)', 0], ['rgba(0, 0, 0, 0.6)', 1]]
            })
        }
        .width(this.cardWidth)
        .height(this.cardHeight())

        // 库名暗带（合集挂「合集」玻璃标签）
        Row({ space: 10 }) {
          Text(this.name)
            .fontSize(24)
            .fontWeight(600)
            .fontColor(CarColors.text)
            .maxLines(1)
            .minFontSize(18)
            .maxFontSize(24)
            .layoutWeight(1)
          if (this.collection) {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.rectangle_stack'))
                .fontSize(12)
                .fontColor(['rgba(243, 245, 249, 0.88)'])
              Text('合集')
                .fontSize(12)
                .fontWeight(600)
                .fontColor('rgba(243, 245, 249, 0.88)')
            }
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor('rgba(255, 255, 255, 0.12)')
            .borderRadius(11)
          }
          Text(`${this.count} 部`)
            .fontSize(13)
            .fontColor('rgba(243, 245, 249, 0.75)')
            .maxLines(1)
        }
        .alignItems(VerticalAlign.Center)
        .padding({ left: 18, right: 18, top: 32, bottom: 12 })
        .width(this.cardWidth)
        .linearGradient({
          angle: 180,
          colors: [['rgba(0, 0, 0, 0)', 0], ['rgba(0, 0, 0, 0.82)', 1]]
        })
      }
      .width(this.cardWidth)
      .height(this.cardHeight())
      .borderRadius(CarMetrics.cardCorner)
      .clip(true)
    }
  }
}

/** 全幅剧照类型入口：16:9 剧照 + 居中类型名与数量 */
@ComponentV2
export struct CarGenreCard {
  @Param label: string = '';
  @Param count: number = 0;
  /** movie / tv */
  @Param mediaKind: string = 'movie';
  @Param imageUrl: string = '';
  @Param cardWidth: number = CarMetrics.landscapeBigWidth;
  @Param onActivate: (() => void) | null = null;

  private artHeight(): number {
    return this.cardWidth * 9 / 16;
  }

  private kindText(): string {
    return this.mediaKind === 'tv' ? '剧集' : '电影';
  }

  build() {
    CarPressable({
      onActivate: this.onActivate
    }) {
      Stack() {
        Stack() {
          RemoteImage({ url: this.imageUrl, placeholderText: this.label })
        }
        .width(this.cardWidth)
        .height(this.artHeight())

        Column()
          .width(this.cardWidth)
          .height(this.artHeight())
          .backgroundColor('rgba(0, 0, 0, 0.45)')

        Column({ space: 4 }) {
          Text(this.label)
            .fontSize(20)
            .fontWeight(600)
            .fontColor(CarColors.text)
            .maxLines(1)
          Text(`${this.count} 部${this.kindText()}`)
            .fontSize(13)
            .fontColor('rgba(243, 245, 249, 0.75)')
        }
        .alignItems(HorizontalAlign.Center)
      }
      .width(this.cardWidth)
      .height(this.artHeight())
      .borderRadius(CarMetrics.cardCorner)
      .clip(true)
    }
  }
}

/** 演职员竖卡：2:3 照片，下常显姓名与作品数；没有照片画姓名首字 */
@ComponentV2
export struct CarPersonCard {
  @Param name: string = '';
  @Param role: string | null = null;
  @Param imageUrl: string = '';
  /** 作品数（PersonView.credits 数量） */
  @Param worksCount: number = 0;
  @Param cardWidth: number = 160;
  @Param onActivate: (() => void) | null = null;

  private artHeight(): number {
    return this.cardWidth * 1.5;
  }

  private initial(): string {
    return this.name.length > 0 ? this.name.charAt(0) : '·';
  }

  build() {
    CarPressable({
      onActivate: this.onActivate
    }) {
      Column() {
        Stack() {
          Column()
            .width(this.cardWidth)
            .height(this.artHeight())
            .linearGradient({
              angle: 180,
              colors: [['rgba(110, 115, 125, 0.45)', 0], ['rgba(45, 48, 56, 0.6)', 1]]
            })
          Text(this.initial())
            .fontSize(40)
            .fontWeight(600)
            .fontColor('rgba(243, 245, 249, 0.35)')
          if (this.imageUrl !== '') {
            Stack() {
              RemoteImage({ url: this.imageUrl, placeholderText: '' })
            }
            .width(this.cardWidth)
            .height(this.artHeight())
          }
        }
        .width(this.cardWidth)
        .height(this.artHeight())
        .borderRadius(CarMetrics.cardCorner)
        .clip(true)

        Column({ space: 2 }) {
          Text(this.name)
            .fontSize(15)
            .fontWeight(600)
            .fontColor(CarColors.text)
            .maxLines(1)
          if (this.role !== null) {
            Text(this.role)
              .fontSize(12)
              .fontColor(CarColors.textMuted)
              .maxLines(1)
          }
          if (this.worksCount > 0) {
            Text(`${this.worksCount} 部作品`)
              .fontSize(12)
              .fontColor(CarColors.textFaint)
              .maxLines(1)
          }
        }
        .width(this.cardWidth)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })
      }
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/** 一行末尾的「查看全部」尾卡：与该行卡片同大小的一块，点按进完整墙 */
@ComponentV2
export struct CarSeeAllCard {
  /** 总数（知道才写） */
  @Param total: number | null = null;
  @Param cardWidth: number = CarMetrics.posterWidth;
  /** 高度比：海报行 1.5，横版行 9/16 */
  @Param heightRatio: number = 1.5;
  @Param onActivate: (() => void) | null = null;

  private artHeight(): number {
    return this.cardWidth * this.heightRatio;
  }

  build() {
    CarPressable({
      onActivate: this.onActivate
    }) {
      Column({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.square_grid_2x2'))
          .fontSize(28)
          .fontColor([CarColors.text])
        Text('查看全部')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(CarColors.text)
        if (this.total !== null) {
          Text(`${this.total} 部`)
            .fontSize(13)
            .fontColor(CarColors.textMuted)
        }
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width(this.cardWidth)
      .height(this.artHeight())
      .backgroundColor('rgba(255, 255, 255, 0.08)')
      .borderRadius(CarMetrics.cardCorner)
      .border({ width: 1, color: 'rgba(255, 255, 255, 0.14)' })
    }
  }
}

/** 页面级空态 / 错误态（大字号、行动按钮触控目标 ≥48vp） */
@ComponentV2
export struct CarStateView {
  @Param symbol: Resource = $r('sys.symbol.film');
  @Param title: string = '';
  @Param message: string | null = null;
  @Param actionTitle: string | null = null;
  @Param onAction: (() => void) | null = null;

  build() {
    Column({ space: 14 }) {
      SymbolGlyph(this.symbol)
        .fontSize(48)
        .fontColor([CarColors.textFaint])
      Text(this.title)
        .fontSize(22)
        .fontWeight(600)
        .fontColor(CarColors.text)
        .textAlign(TextAlign.Center)
        .maxLines(2)
      if (this.message !== null) {
        Text(this.message)
          .fontSize(17)
          .fontColor(CarColors.textMuted)
          .textAlign(TextAlign.Center)
          .maxLines(4)
      }
      if (this.actionTitle !== null) {
        Row({ space: 8 }) {
          SymbolGlyph(this.symbol)
            .fontSize(16)
            .fontColor([CarColors.bg])
          Text(this.actionTitle)
            .fontSize(CarType.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(CarColors.bg)
        }
        .alignItems(VerticalAlign.Center)
        .height(CarMetrics.minTouch)
        .padding({ left: 30, right: 30 })
        .backgroundColor(CarColors.text)
        .borderRadius(999)
        .margin({ top: 8 })
        .onClick((): void => {
          const cb = this.onAction;
          if (cb !== null) {
            cb();
          }
        })
      }
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .width('100%')
    .height('100%')
    .padding(CarMetrics.edge)
  }
}

/** 通用胶囊按钮（触控目标 ≥48vp）：filled = 亮底黑字主操作；默认暗底亮字次操作；disabled = 置灰不可点 */
@ComponentV2
export struct CarPillButton {
  @Param label: string = '';
  @Param symbol: Resource | null = null;
  @Param filled: boolean = false;
  @Param disabled: boolean = false;
  @Param onActivate: (() => void) | null = null;

  build() {
    CarPressable({
      onActivate: (): void => {
        if (this.disabled) {
          return;
        }
        const cb = this.onActivate;
        if (cb !== null) {
          cb();
        }
      }
    }) {
      Row({ space: 8 }) {
        if (this.symbol !== null) {
          SymbolGlyph(this.symbol)
            .fontSize(17)
            .fontColor([this.filled ? CarColors.bg : CarColors.text])
        }
        Text(this.label)
          .fontSize(CarType.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.filled ? CarColors.bg : CarColors.text)
          .maxLines(1)
      }
      .alignItems(VerticalAlign.Center)
      .height(CarMetrics.minTouch)
      .padding({ left: 24, right: 24 })
      .backgroundColor(this.filled ? CarColors.text : CarColors.surfaceRaised)
      .borderRadius(999)
      .border({ width: this.filled ? 0 : 1, color: CarColors.line })
      .opacity(this.disabled ? 0.4 : 1)
    }
  }
}
