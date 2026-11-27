import { Theme } from '../theme/AppTheme';
import { Haptics } from './Haptics';
import { formatUserStars } from './StarRating';

export { formatUserStars };

@Component
export struct StarRatingBar {
  /** 当前个人评分（1..10；0 表示未评分） */
  @Prop rating: number = 0;
  @Prop busy: boolean = false;
  /** 用户松手或点按提交新评分（0 = 清除，1..10 = 设置） */
  onChange: (nextRating: number) => void = (): void => {};

  /** 拖动中的实时预览分（-1 表示未在拖） */
  @State private previewRating: number = -1;
  private barWidthVp: number = 140;

  private activeRating(): number {
    return this.previewRating >= 0 ? this.previewRating : (this.rating > 0 ? this.rating : 0);
  }

  private starGlyph(starIndex: number): Resource {
    const val: number = this.activeRating();
    const fullThreshold: number = starIndex * 2;
    const halfThreshold: number = fullThreshold - 1;
    if (val >= fullThreshold) {
      return $r('sys.symbol.star_fill');
    }
    if (val >= halfThreshold) {
      return $r('sys.symbol.star_leadinghalf_filled');
    }
    return $r('sys.symbol.star');
  }

  private starLit(starIndex: number): boolean {
    return this.activeRating() >= starIndex * 2 - 1;
  }

  private ratingFromX(localX: number): number {
    if (this.barWidthVp <= 0) {
      return 0;
    }
    const ratio: number = Math.max(0, Math.min(1, localX / this.barWidthVp));
    const step: number = Math.ceil(ratio * 10);
    return Math.max(1, Math.min(10, step));
  }

  build() {
    Row({ space: 10 }) {
      Row({ space: 4 }) {
        ForEach([1, 2, 3, 4, 5], (starIndex: number) => {
          SymbolGlyph(this.starGlyph(starIndex))
            .fontSize(20)
            .fontColor([this.starLit(starIndex) ? '#F5C451' : 'rgba(255,255,255,0.28)'])
        }, (starIndex: number) => `${starIndex}`)
      }
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .backgroundColor('rgba(255,255,255,0.06)')
      .borderRadius(999)
      .border({ width: 1, color: this.activeRating() > 0 ? 'rgba(245,196,81,0.38)' : 'rgba(255,255,255,0.10)' })
      .onAreaChange((_oldVal: Area, newVal: Area): void => {
        const w: number = Number(newVal.width);
        if (w > 20) {
          this.barWidthVp = w;
        }
      })
      .onClick((event: ClickEvent): void => {
        if (this.busy) {
          return;
        }
        const tapped: number = this.ratingFromX(event.x);
        const next: number = tapped === this.rating ? 0 : tapped;
        Haptics.click();
        this.onChange(next);
      })
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: 4 })
          .onActionStart((event: GestureEvent): void => {
            if (this.busy || event.fingerList.length === 0) {
              return;
            }
            const next: number = this.ratingFromX(event.fingerList[0].localX);
            this.previewRating = next;
            Haptics.tick();
          })
          .onActionUpdate((event: GestureEvent): void => {
            if (this.busy || event.fingerList.length === 0) {
              return;
            }
            const next: number = this.ratingFromX(event.fingerList[0].localX);
            if (next !== this.previewRating) {
              this.previewRating = next;
              Haptics.tick();
            }
          })
          .onActionEnd((): void => {
            if (this.previewRating >= 0) {
              const committed: number = this.previewRating;
              this.previewRating = -1;
              Haptics.click();
              if (committed !== this.rating) {
                this.onChange(committed);
              }
            }
          })
          .onActionCancel((): void => {
            this.previewRating = -1;
          })
      )

      if (this.activeRating() > 0) {
        Text(`我的评分 ${formatUserStars(this.activeRating())} ★`)
          .fontSize(13)
          .fontWeight(600)
          .fontColor('#F5C451')
        Text('清除')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .onClick((): void => {
            if (!this.busy) {
              Haptics.click();
              this.onChange(0);
            }
          })
      } else {
        Text('点按或滑动打分')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
    }
    .alignItems(VerticalAlign.Center)
  }
}
