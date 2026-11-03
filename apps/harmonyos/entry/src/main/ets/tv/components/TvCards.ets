/**
 * TV 卡片库（对应参考端 DesignSystem/TVCards.swift）：
 * - TvPosterCard 海报卡（2:3，caption 三档：always 常显 / focused 获焦浮现（不占排版）/ band 底部暗带）
 * - TvLandscapeCard 横版剧照卡（16:9，可选底部 detail 暗带：▶ 进度 剩余时间）
 * - TvEpisodeCard 分集卡（剧照 + 进度 + 集名 + 首播 + 简介，详情页选集用）
 * - TvLibraryCard 媒体库卡（16:9，21:10 封面贴顶 + 模糊延伸底 + 库名暗带）
 * - TvGenreCard 类型入口卡（16:9 剧照 + 居中类型名）
 * - TvPersonCard 演职员竖卡（2:3，无照片画姓名首字）
 * - TvSeeAllCard 「查看全部」尾卡
 * - TvProgressStrip 观看进度条 / TvPillButton 胶囊按钮 / TvStateView 空态与错误态
 * - TvFormat 文案工具（剩 N 分钟 / 第 X 季第 Y 集）
 *
 * 全部交互视觉经由 TvFocusable（悬浮 = 焦点）；图片复用 common/RemoteImage
 * （带设备令牌的取图 + 按账号隔离的内存缓存），URL 由调用方用 ImageUrls.resolve 解析好传入。
 */
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';
import { TvType } from '../theme/TvTheme';
import { TvMotion } from '../theme/TvTheme';
import { TvFocusable } from './TvFocusable';
import { RemoteImage } from '../../common/RemoteImage';

/** 卡片说明文字策略 */
export class TvCardCaption {
  /** 图下常显（默认横卡） */
  static readonly always: string = 'always';
  /** 获焦才浮现在图下（不占排版位置，海报行默认） */
  static readonly focused: string = 'focused';
  /** 获焦才浮现在图底部暗带里（海报墙） */
  static readonly band: string = 'band';
  /** 不显示（库卡自带头衔） */
  static readonly hidden: string = 'hidden';
}

/** TV 文案工具（对应参考端 Formatters.remaining / TVStageInfo.episodeLine） */
export class TvFormat {
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

/** 图片底部的观看进度条 */
@ComponentV2
export struct TvProgressStrip {
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

/** 海报卡（2:3）。海报行 caption 用 focused（划过不闪字），海报墙用 band */
@ComponentV2
export struct TvPosterCard {
  @Param title: string = '';
  @Param subtitle: string | null = null;
  /** 已解析的图片 URL；空串 = 无图（占位显示片名） */
  @Param imageUrl: string = '';
  @Param cardWidth: number = TvMetrics.posterWidth;
  /** 0～1 观看进度；0 不画进度条 */
  @Param progress: number = 0;
  /** 图上角标（「已入库」「在追」） */
  @Param badge: string | null = null;
  @Param caption: string = TvCardCaption.focused;
  /** always 模式下写在副标题下的说明行（搜索命中原因） */
  @Param note: string | null = null;
  @Param defaultFocused: boolean = false;
  /** requestFocus 定位 key（页签锚点；每屏至多一处） */
  @Param focusKey: string = '';
  @Param onActivate: (() => void) | null = null;
  @Param onFocusGained: ((active: boolean) => void) | null = null;

  @Local active: boolean = false;

  private artHeight(): number {
    return this.cardWidth * 1.5;
  }

  private activate(): void {
    const cb = this.onActivate;
    if (cb !== null) {
      cb();
    }
  }

  private handleFocus(active: boolean): void {
    this.active = active;
    const cb = this.onFocusGained;
    if (cb !== null) {
      cb(active);
    }
  }

  build() {
    TvFocusable({
      defaultFocused: this.defaultFocused,
      focusKey: this.focusKey,
      onActivate: (): void => {
        this.activate();
      },
      onFocusGained: (active: boolean): void => {
        this.handleFocus(active);
      }
    }) {
      if (this.caption === TvCardCaption.always) {
        Column() {
          this.Art()
          Column({ space: 2 }) {
            Text(this.title)
              .fontSize(TvType.cardCaption)
              .fontWeight(FontWeight.Medium)
              .fontColor(TvColors.text)
              .maxLines(1)
            if (this.subtitle !== null) {
              Text(this.subtitle)
                .fontSize(13)
                .fontColor(TvColors.textMuted)
                .maxLines(1)
            }
            if (this.note !== null) {
              Text(this.note)
                .fontSize(12)
                .fontColor(TvColors.textFaint)
                .maxLines(1)
            }
          }
          .width(this.cardWidth)
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 10 })
        }
        .alignItems(HorizontalAlign.Start)
      } else {
        Stack({ alignContent: Alignment.TopStart }) {
          this.Art()
          if (this.caption === TvCardCaption.focused) {
            this.FocusedCaption()
          }
        }
      }
    }
  }

  /** 图 + 进度条 + band 暗带 + 角标 */
  @Builder
  private Art() {
    Stack({ alignContent: Alignment.Bottom }) {
      Stack() {
        RemoteImage({ url: this.imageUrl, placeholderText: this.title })
      }
      .width(this.cardWidth)
      .height(this.artHeight())
      .borderRadius(TvMetrics.cardCorner)
      .clip(true)

      if (this.progress > 0 && this.caption !== TvCardCaption.band) {
        Row() {
          TvProgressStrip({ value: this.progress })
        }
        .padding({ left: 8, right: 8, bottom: 8 })
        .width(this.cardWidth)
      }
      if (this.caption === TvCardCaption.band) {
        this.FocusBand()
      }
      if (this.badge !== null) {
        Text(this.badge ?? '')
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(TvColors.text)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('rgba(0, 0, 0, 0.6)')
          .borderRadius(9)
          .maxLines(1)
          .position({ x: 8, y: 8 })
      }
    }
    .width(this.cardWidth)
    .height(this.artHeight())
  }

  /** band 模式的底部暗带：片名 · 年份（获焦浮现） */
  @Builder
  private FocusBand() {
    Column() {
      Text() {
        Span(this.title)
        if (this.subtitle !== null) {
          Span(` · ${this.subtitle}`)
            .fontColor('rgba(243, 245, 249, 0.7)')
        }
      }
      .fontSize(15)
      .fontWeight(600)
      .fontColor(TvColors.text)
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 24, bottom: 10 })
    .width(this.cardWidth)
    .linearGradient({
      angle: 180,
      colors: [['rgba(0, 0, 0, 0)', 0], ['rgba(0, 0, 0, 0.85)', 1]]
    })
    .opacity(this.active ? 1 : 0)
    .animation({ duration: TvMotion.focusMs, curve: Curve.EaseOut })
  }

  /** focused 模式的浮动片名：不占排版，画在行间空隙里（获焦浮现） */
  @Builder
  private FocusedCaption() {
    Text() {
      Span(this.title)
      if (this.subtitle !== null) {
        Span(` · ${this.subtitle}`)
          .fontColor(TvColors.textMuted)
      }
    }
    .fontSize(TvType.cardCaption)
    .fontWeight(FontWeight.Medium)
    .fontColor(TvColors.text)
    .maxLines(1)
    .width(this.cardWidth)
    .offset({ x: 0, y: this.artHeight() + 12 })
    .opacity(this.active ? 1 : 0)
    .animation({ duration: TvMotion.focusMs, curve: Curve.EaseOut })
  }
}

/** 横版剧照卡（16:9）：「接下来继续」、搜索结果、合集成员。给了 detail 时进度条与说明收进底部暗带 */
@ComponentV2
export struct TvLandscapeCard {
  @Param title: string = '';
  @Param subtitle: string | null = null;
  @Param imageUrl: string = '';
  @Param cardWidth: number = TvMetrics.landscapeWidth;
  @Param progress: number = 0;
  @Param badge: string | null = null;
  /** 压在图片底部暗带里的一行说明（「第 2 季 第 6 集 · 剩 18 分钟」） */
  @Param detail: string | null = null;
  @Param caption: string = TvCardCaption.always;
  @Param defaultFocused: boolean = false;
  /** requestFocus 定位 key（页签锚点；每屏至多一处） */
  @Param focusKey: string = '';
  @Param onActivate: (() => void) | null = null;
  @Param onFocusGained: ((active: boolean) => void) | null = null;

  @Local active: boolean = false;

  private artHeight(): number {
    return this.cardWidth * 9 / 16;
  }

  private activate(): void {
    const cb = this.onActivate;
    if (cb !== null) {
      cb();
    }
  }

  private handleFocus(active: boolean): void {
    this.active = active;
    const cb = this.onFocusGained;
    if (cb !== null) {
      cb(active);
    }
  }

  build() {
    TvFocusable({
      defaultFocused: this.defaultFocused,
      focusKey: this.focusKey,
      onActivate: (): void => {
        this.activate();
      },
      onFocusGained: (active: boolean): void => {
        this.handleFocus(active);
      }
    }) {
      if (this.caption === TvCardCaption.always) {
        Column() {
          this.Art()
          Column({ space: 2 }) {
            Text(this.title)
              .fontSize(TvType.cardCaption)
              .fontWeight(FontWeight.Medium)
              .fontColor(TvColors.text)
              .maxLines(1)
            if (this.subtitle !== null) {
              Text(this.subtitle)
                .fontSize(13)
                .fontColor(TvColors.textMuted)
                .maxLines(1)
            }
          }
          .width(this.cardWidth)
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 10 })
        }
        .alignItems(HorizontalAlign.Start)
      } else {
        Stack({ alignContent: Alignment.TopStart }) {
          this.Art()
        }
      }
    }
  }

  @Builder
  private Art() {
    Stack({ alignContent: Alignment.Bottom }) {
      Stack() {
        RemoteImage({ url: this.imageUrl, placeholderText: this.title })
      }
      .width(this.cardWidth)
      .height(this.artHeight())
      .borderRadius(TvMetrics.cardCorner)
      .clip(true)

      if (this.detail !== null) {
        this.DetailBand()
      } else if (this.progress > 0) {
        Row() {
          TvProgressStrip({ value: this.progress })
        }
        .padding({ left: 10, right: 10, bottom: 10 })
        .width(this.cardWidth)
      }
      if (this.badge !== null) {
        Text(this.badge ?? '')
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(TvColors.text)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('rgba(0, 0, 0, 0.6)')
          .borderRadius(9)
          .maxLines(1)
          .position({ x: 8, y: 8 })
      }
    }
    .width(this.cardWidth)
    .height(this.artHeight())
  }

  /** 图片底部暗带：▶ 进度条 · 说明一行（同系统 Apple TV App「继续观看」卡） */
  @Builder
  private DetailBand() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(12)
        .fontColor([TvColors.text])
      if (this.progress > 0) {
        Row() {
          TvProgressStrip({ value: this.progress, trackColor: 'rgba(255, 255, 255, 0.3)' })
        }
        .width(40)
      }
      Text(this.detail ?? '')
        .fontSize(12)
        .fontWeight(600)
        .fontColor(TvColors.text)
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
export struct TvEpisodeCard {
  /** 「第 1 集 · 冬湖」 */
  @Param epTitle: string = '';
  @Param imageUrl: string = '';
  @Param cardWidth: number = TvMetrics.landscapeWidth;
  @Param progress: number = 0;
  /** 图上角标（「已看」「缺集」） */
  @Param badge: string | null = null;
  @Param airDate: string | null = null;
  @Param overview: string | null = null;
  @Param defaultFocused: boolean = false;
  @Param onActivate: (() => void) | null = null;
  @Param onFocusGained: ((active: boolean) => void) | null = null;

  private artHeight(): number {
    return this.cardWidth * 9 / 16;
  }

  private activate(): void {
    const cb = this.onActivate;
    if (cb !== null) {
      cb();
    }
  }

  private handleFocus(active: boolean): void {
    const cb = this.onFocusGained;
    if (cb !== null) {
      cb(active);
    }
  }

  build() {
    TvFocusable({
      defaultFocused: this.defaultFocused,
      onActivate: (): void => {
        this.activate();
      },
      onFocusGained: (active: boolean): void => {
        this.handleFocus(active);
      }
    }) {
      Column() {
        Stack({ alignContent: Alignment.Bottom }) {
          Stack() {
            RemoteImage({ url: this.imageUrl, placeholderText: this.epTitle })
          }
          .width(this.cardWidth)
          .height(this.artHeight())
          .borderRadius(TvMetrics.cardCorner)
          .clip(true)

          if (this.progress > 0) {
            Row() {
              TvProgressStrip({ value: this.progress })
            }
            .padding({ left: 10, right: 10, bottom: 10 })
            .width(this.cardWidth)
          }
          if (this.badge !== null) {
            Text(this.badge ?? '')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor(TvColors.text)
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
            .fontColor(TvColors.text)
            .maxLines(1)
            .layoutWeight(1)
          if (this.airDate !== null) {
            Text(this.airDate)
              .fontSize(12)
              .fontColor(TvColors.textFaint)
              .maxLines(1)
          }
        }
        .width(this.cardWidth)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 8 })

        if (this.overview !== null) {
          Text(this.overview)
            .fontSize(12)
            .fontColor(TvColors.textMuted)
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

/** 首页「我的媒体库」行的库卡 / 合集卡：16:9，21:10 货架封面贴顶，底部库名暗带 */
@ComponentV2
export struct TvLibraryCard {
  @Param name: string = '';
  @Param count: number = 0;
  @Param imageUrl: string = '';
  @Param collection: boolean = false;
  @Param cardWidth: number = TvMetrics.libraryCardWidth;
  @Param defaultFocused: boolean = false;
  /** requestFocus 定位 key（页签锚点；每屏至多一处） */
  @Param focusKey: string = '';
  @Param onActivate: (() => void) | null = null;
  @Param onFocusGained: ((active: boolean) => void) | null = null;

  private cardHeight(): number {
    return this.cardWidth * 9 / 16;
  }

  /** 服务端按 21:10 拼的货架封面 */
  private coverHeight(): number {
    return this.cardWidth * 10 / 21;
  }

  private activate(): void {
    const cb = this.onActivate;
    if (cb !== null) {
      cb();
    }
  }

  private handleFocus(active: boolean): void {
    const cb = this.onFocusGained;
    if (cb !== null) {
      cb(active);
    }
  }

  build() {
    TvFocusable({
      defaultFocused: this.defaultFocused,
      focusKey: this.focusKey,
      onActivate: (): void => {
        this.activate();
      },
      onFocusGained: (active: boolean): void => {
        this.handleFocus(active);
      }
    }) {
      Stack({ alignContent: Alignment.Bottom }) {
        // 底：同一张封面放大模糊铺满 + 压暗（封面下沿接缝处有渐隐）
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
            .fontColor(TvColors.text)
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
      .borderRadius(TvMetrics.cardCorner)
      .clip(true)
    }
  }
}

/** 全幅剧照类型入口：16:9 剧照 + 居中类型名与数量 */
@ComponentV2
export struct TvGenreCard {
  @Param label: string = '';
  @Param count: number = 0;
  /** movie / tv */
  @Param mediaKind: string = 'movie';
  @Param imageUrl: string = '';
  @Param cardWidth: number = TvMetrics.landscapeWidth;
  @Param defaultFocused: boolean = false;
  /** requestFocus 定位 key（页签锚点；每屏至多一处） */
  @Param focusKey: string = '';
  @Param onActivate: (() => void) | null = null;
  @Param onFocusGained: ((active: boolean) => void) | null = null;

  private artHeight(): number {
    return this.cardWidth * 9 / 16;
  }

  private kindText(): string {
    return this.mediaKind === 'tv' ? '剧集' : '电影';
  }

  private activate(): void {
    const cb = this.onActivate;
    if (cb !== null) {
      cb();
    }
  }

  private handleFocus(active: boolean): void {
    const cb = this.onFocusGained;
    if (cb !== null) {
      cb(active);
    }
  }

  build() {
    TvFocusable({
      defaultFocused: this.defaultFocused,
      focusKey: this.focusKey,
      onActivate: (): void => {
        this.activate();
      },
      onFocusGained: (active: boolean): void => {
        this.handleFocus(active);
      }
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
            .fontColor(TvColors.text)
            .maxLines(1)
          Text(`${this.count} 部${this.kindText()}`)
            .fontSize(13)
            .fontColor('rgba(243, 245, 249, 0.75)')
        }
        .alignItems(HorizontalAlign.Center)
      }
      .width(this.cardWidth)
      .height(this.artHeight())
      .borderRadius(TvMetrics.cardCorner)
      .clip(true)
    }
  }
}

/** 演职员竖版长卡：2:3 照片，下常显姓名与角色；没有照片画姓名首字 */
@ComponentV2
export struct TvPersonCard {
  @Param name: string = '';
  @Param role: string | null = null;
  @Param imageUrl: string = '';
  /** 比海报小一档：人物是辅助信息，一排多放一两位 */
  @Param cardWidth: number = 133;
  @Param defaultFocused: boolean = false;
  @Param onActivate: (() => void) | null = null;
  @Param onFocusGained: ((active: boolean) => void) | null = null;

  private artHeight(): number {
    return this.cardWidth * 1.5;
  }

  private initial(): string {
    return this.name.length > 0 ? this.name.charAt(0) : '·';
  }

  private activate(): void {
    const cb = this.onActivate;
    if (cb !== null) {
      cb();
    }
  }

  private handleFocus(active: boolean): void {
    const cb = this.onFocusGained;
    if (cb !== null) {
      cb(active);
    }
  }

  build() {
    TvFocusable({
      defaultFocused: this.defaultFocused,
      onActivate: (): void => {
        this.activate();
      },
      onFocusGained: (active: boolean): void => {
        this.handleFocus(active);
      }
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
        .borderRadius(TvMetrics.cardCorner)
        .clip(true)

        Column({ space: 2 }) {
          Text(this.name)
            .fontSize(15)
            .fontWeight(600)
            .fontColor(TvColors.text)
            .maxLines(1)
          if (this.role !== null) {
            Text(this.role)
              .fontSize(12)
              .fontColor(TvColors.textMuted)
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

/** 一行末尾的「查看全部」尾卡：与该行海报同大小的一块，按确认进完整墙 */
@ComponentV2
export struct TvSeeAllCard {
  /** 总数（知道才写） */
  @Param total: number | null = null;
  @Param cardWidth: number = TvMetrics.posterWidth;
  /** 高度比：海报行 1.5，横版行 9/16 */
  @Param heightRatio: number = 1.5;
  @Param defaultFocused: boolean = false;
  @Param onActivate: (() => void) | null = null;
  @Param onFocusGained: ((active: boolean) => void) | null = null;

  private artHeight(): number {
    return this.cardWidth * this.heightRatio;
  }

  private activate(): void {
    const cb = this.onActivate;
    if (cb !== null) {
      cb();
    }
  }

  private handleFocus(active: boolean): void {
    const cb = this.onFocusGained;
    if (cb !== null) {
      cb(active);
    }
  }

  build() {
    TvFocusable({
      defaultFocused: this.defaultFocused,
      onActivate: (): void => {
        this.activate();
      },
      onFocusGained: (active: boolean): void => {
        this.handleFocus(active);
      }
    }) {
      Column({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.square_grid_2x2'))
          .fontSize(28)
          .fontColor([TvColors.text])
        Text('查看全部')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(TvColors.text)
        if (this.total !== null) {
          Text(`${this.total} 部`)
            .fontSize(13)
            .fontColor(TvColors.textMuted)
        }
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width(this.cardWidth)
      .height(this.artHeight())
      .backgroundColor('rgba(255, 255, 255, 0.08)')
      .borderRadius(TvMetrics.cardCorner)
      .border({ width: 1, color: 'rgba(255, 255, 255, 0.14)' })
    }
  }
}

/** 胶囊按钮（大图区操作行 / 空态重试 / 播放器按钮共用） */
@ComponentV2
export struct TvPillButton {
  @Param label: string = '';
  /** true = 实心浅底黑字（主操作），false = 玻璃底白字 */
  @Param prominent: boolean = false;
  @Param icon: Resource | null = null;
  @Param defaultFocused: boolean = false;
  /** requestFocus 定位 key（页面收面板后回焦点等） */
  @Param focusKey: string = '';
  @Param onActivate: (() => void) | null = null;
  @Param onFocusGained: ((active: boolean) => void) | null = null;

  private iconValue(): Resource {
    return this.icon ?? $r('sys.symbol.film');
  }

  private activate(): void {
    const cb = this.onActivate;
    if (cb !== null) {
      cb();
    }
  }

  private handleFocus(active: boolean): void {
    const cb = this.onFocusGained;
    if (cb !== null) {
      cb(active);
    }
  }

  build() {
    TvFocusable({
      focusScale: 1.06,
      cornerRadius: 22,
      defaultFocused: this.defaultFocused,
      focusKey: this.focusKey,
      onActivate: (): void => {
        this.activate();
      },
      onFocusGained: (active: boolean): void => {
        this.handleFocus(active);
      }
    }) {
      Row({ space: 7 }) {
        if (this.icon !== null) {
          SymbolGlyph(this.iconValue())
            .fontSize(15)
            .fontColor([this.prominent ? '#0b0d12' : TvColors.text])
        }
        Text(this.label)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.prominent ? '#0b0d12' : TvColors.text)
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 22, right: 22, top: 10, bottom: 10 })
      .backgroundColor(this.prominent ? '#f3f5f9' : 'rgba(255, 255, 255, 0.14)')
      .borderRadius(22)
    }
  }
}

/** 页面级空态 / 错误态（大字号、按钮可聚焦）。没有按钮时整块可聚焦，避免方向键落空 */
@ComponentV2
export struct TvStateView {
  @Param symbol: Resource = $r('sys.symbol.film');
  @Param title: string = '';
  @Param message: string | null = null;
  @Param actionTitle: string | null = null;
  @Param defaultFocusAction: boolean = false;
  @Param onAction: (() => void) | null = null;

  build() {
    Column({ space: 12 }) {
      SymbolGlyph(this.symbol)
        .fontSize(48)
        .fontColor([TvColors.textFaint])
      Text(this.title)
        .fontSize(22)
        .fontWeight(600)
        .fontColor(TvColors.text)
        .textAlign(TextAlign.Center)
        .maxLines(2)
      if (this.message !== null) {
        Text(this.message)
          .fontSize(17)
          .fontColor(TvColors.textMuted)
          .textAlign(TextAlign.Center)
          .maxLines(4)
      }
      if (this.actionTitle !== null) {
        TvPillButton({
          label: this.actionTitle,
          prominent: true,
          defaultFocused: this.defaultFocusAction,
          onActivate: (): void => {
            const cb = this.onAction;
            if (cb !== null) {
              cb();
            }
          }
        })
      }
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .width('100%')
    .height('100%')
    .padding(TvMetrics.edge)
    .focusable(this.actionTitle === null)
  }
}
