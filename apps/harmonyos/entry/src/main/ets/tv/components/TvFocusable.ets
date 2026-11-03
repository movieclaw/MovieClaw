/**
 * TV 双态交互基座：焦点态 = 悬浮态（Apple TV 交互铁律）。
 *
 * 同一套视觉由三种输入统一驱动：
 * - 遥控器/键盘方向键移动焦点（onFocus / onBlur）
 * - 灵犀指针遥控悬停（onHover）
 * - 确认键 / 指针点击（onClick，系统会把焦点组件上的 OK 键翻译成 click）
 *
 * 激活视觉 = scale 放大 1.1× + 圆角亮边 + 阴影抬升，全部走官方 animateTo 过渡。
 * 业务卡片一律经由本组件包裹，禁止各自为政另写一套焦点样式。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';
import { TvMotion } from '../theme/TvTheme';

/** 空内容兜底：@BuilderParam 必须有默认值 */
@Builder
function TvFocusableEmpty(): void {
}

@ComponentV2
export struct TvFocusable {
  /** 包裹的业务内容 */
  @BuilderParam content: () => void = TvFocusableEmpty;
  /** 焦点放大系数；0 = 不放大（纯描边态，如侧边栏项） */
  @Param focusScale: number = TvMetrics.focusZoom;
  /** 亮边圆角；与卡片圆角一致 */
  @Param cornerRadius: number = TvMetrics.cardCorner;
  /** 是否抢默认焦点（每屏至多一处 true） */
  @Param defaultFocused: boolean = false;
  /** 供 FocusController.requestFocus 定位的 key（每屏至多一处非空，如页签锚点） */
  @Param focusKey: string = '';
  /** 激活回调（点击 / 确认键） */
  @Param onActivate: (() => void) | null = null;
  /** 焦点态变化回调（true = 激活；行高亮、大图联动靠它） */
  @Param onFocusGained: ((active: boolean) => void) | null = null;

  @Local hovered: boolean = false;
  @Local focused: boolean = false;

  /** 激活态整体变化时透传一次给业务（hover 与 focus 叠加时只发边沿） */
  private reportEdge(wasActive: boolean): void {
    const cb = this.onFocusGained;
    if (cb !== null && wasActive !== this.activeNow()) {
      cb(this.activeNow());
    }
  }

  private activeNow(): boolean {
    return this.hovered || this.focused;
  }

  build() {
    Stack() {
      this.content()
    }
    .scale({
      x: this.activeNow() && this.focusScale > 0 ? this.focusScale : 1,
      y: this.activeNow() && this.focusScale > 0 ? this.focusScale : 1
    })
    .border({
      width: this.activeNow() ? 3 : 0,
      color: TvColors.focusRing,
      radius: this.cornerRadius
    })
    .shadow({
      radius: this.activeNow() ? 28 : 0,
      color: 'rgba(0, 0, 0, 0.65)',
      offsetY: this.activeNow() ? 10 : 0
    })
    .focusable(true)
    .defaultFocus(this.defaultFocused)
    .key(this.focusKey)
    .onTouch((event: TouchEvent): void => {
      hilog.info(0x0000, 'DbgTouch', 'FOCUSABLE_TOUCH key=%{public}s type=%{public}s', this.focusKey, event.type.toString());
    })
    .onFocus(() => {
      const was: boolean = this.activeNow();
      this.getUIContext().animateTo(
        { duration: TvMotion.focusMs, curve: Curve.EaseOut },
        (): void => {
          this.focused = true;
          this.reportEdge(was);
        });
    })
    .onBlur(() => {
      const was: boolean = this.activeNow();
      this.getUIContext().animateTo(
        { duration: TvMotion.focusMs, curve: Curve.EaseOut },
        (): void => {
          this.focused = false;
          this.reportEdge(was);
        });
    })
    .onHover((isHover: boolean) => {
      const was: boolean = this.activeNow();
      this.getUIContext().animateTo(
        { duration: TvMotion.focusMs, curve: Curve.EaseOut },
        (): void => {
          this.hovered = isHover;
          this.reportEdge(was);
        });
    })
    .onClick(() => {
      hilog.info(0x0000, 'DbgTap', 'FOCUSABLE_CLICK key=%{public}s', this.focusKey);
      const cb = this.onActivate;
      if (cb !== null) {
        cb();
      }
    })
  }
}
