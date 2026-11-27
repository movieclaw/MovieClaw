/**
 * TV 双态与灵犀指向交互基座：焦点态 = 悬浮态 + 灵犀指向 3D 光影视差。
 *
 * 同一套视觉由三种输入统一驱动：
 * - 遥控器/键盘方向键移动焦点（onFocus / onBlur）
 * - 灵犀指向遥控悬停与微移（onHover + onMouse 实时驱动 3D 倾角与高光追随）
 * - 确认键 / 指针点击（onClick）与菜单键 / 长按（onMenu）
 *
 * 激活视觉 = scale 放大 1.1× + 上浮 TvMetrics.focusLift + 圆角亮边 + 阴影抬升 + 灵犀镜面高光。
 */
import { KeyCode } from '@kit.InputKit';
import { TvColors, TvMetrics, TvMotion } from '../theme/TvTheme';

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
  /** 菜单键 / 长按回调（卡片快捷菜单） */
  @Param onMenu: (() => void) | null = null;
  /** 焦点态变化回调（true = 激活；行高亮、大图联动靠它） */
  @Param onFocusGained: ((active: boolean) => void) | null = null;

  @Local hovered: boolean = false;
  @Local focused: boolean = false;
  /** 灵犀指向遥控悬停微移驱动的 3D 倾角与镜面高光中心 */
  @Local tiltX: number = 0;
  @Local tiltY: number = 0;
  @Local glareX: number = 50;
  @Local glareY: number = 25;
  @Local pointerInside: boolean = false;
  @Local boxW: number = 0;
  @Local boxH: number = 0;

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

  private tiltAngle(): number {
    if (!this.activeNow() || this.focusScale <= 0) {
      return 0;
    }
    const mag: number = Math.sqrt(this.tiltX * this.tiltX + this.tiltY * this.tiltY);
    return Math.min(8.5, mag);
  }

  private resetTilt(): void {
    this.tiltX = 0;
    this.tiltY = 0;
    this.pointerInside = false;
  }

  build() {
    Stack() {
      this.content()
      if (this.pointerInside && this.activeNow() && this.focusScale > 0 && this.boxW > 24 && this.boxH > 24) {
        Column()
          .width(this.boxW)
          .height(this.boxH)
          .borderRadius(this.cornerRadius)
          .radialGradient({
            center: [`${this.glareX}%`, `${this.glareY}%`],
            radius: '78%',
            colors: [['rgba(255, 255, 255, 0.20)', 0], ['rgba(255, 255, 255, 0.0)', 1]]
          })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .scale({
      x: this.activeNow() && this.focusScale > 0 ? this.focusScale : 1,
      y: this.activeNow() && this.focusScale > 0 ? this.focusScale : 1
    })
    .translate({
      y: this.activeNow() && this.focusScale > 0 ? -TvMetrics.focusLift : 0
    })
    .rotate({
      x: this.tiltX !== 0 || this.tiltY !== 0 ? this.tiltX : 0,
      y: this.tiltX !== 0 || this.tiltY !== 0 ? this.tiltY : 1,
      z: 0,
      angle: this.tiltAngle(),
      perspective: 900
    })
    .border({
      width: this.activeNow() ? 3 : 0,
      color: TvColors.focusRing,
      radius: this.cornerRadius
    })
    .shadow({
      radius: this.activeNow() ? 32 : 0,
      color: 'rgba(0, 0, 0, 0.72)',
      offsetY: this.activeNow() ? 12 : 0
    })
    .focusable(true)
    .defaultFocus(this.defaultFocused)
    .key(this.focusKey)
    .onAreaChange((_old: Area, area: Area): void => {
      const w: number = Number(area.width);
      const h: number = Number(area.height);
      if (w > 0 && h > 0) {
        this.boxW = w;
        this.boxH = h;
      }
    })
    .onMouse((event: MouseEvent): void => {
      if (this.focusScale <= 0 || this.boxW <= 24 || this.boxH <= 24) {
        return;
      }
      if (event.action === MouseAction.Move) {
        const nx: number = Math.max(-0.5, Math.min(0.5, event.x / this.boxW - 0.5));
        const ny: number = Math.max(-0.5, Math.min(0.5, event.y / this.boxH - 0.5));
        this.tiltX = -ny * 10;
        this.tiltY = nx * 10;
        this.glareX = Math.round((nx + 0.5) * 100);
        this.glareY = Math.round((ny + 0.5) * 100);
        this.pointerInside = true;
      } else if (event.action === MouseAction.Press && event.button === MouseButton.Right) {
        const menuCb = this.onMenu;
        if (menuCb !== null) {
          menuCb();
        }
      }
    })
    .onKeyEvent((event: KeyEvent): boolean => {
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_MENU) {
        const menuCb = this.onMenu;
        if (menuCb !== null) {
          menuCb();
          return true;
        }
      }
      return false;
    })
    .gesture(LongPressGesture({ repeat: false, duration: 520 })
      .onAction((): void => {
        const menuCb = this.onMenu;
        if (menuCb !== null) {
          menuCb();
        }
      }))
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
          if (!this.hovered) {
            this.resetTilt();
          }
          this.reportEdge(was);
        });
    })
    .onHover((isHover: boolean) => {
      const was: boolean = this.activeNow();
      this.getUIContext().animateTo(
        { duration: TvMotion.focusMs, curve: Curve.EaseOut },
        (): void => {
          this.hovered = isHover;
          if (!isHover) {
            this.resetTilt();
          }
          this.reportEdge(was);
        });
    })
    .onClick(() => {
      const cb = this.onActivate;
      if (cb !== null) {
        cb();
      }
    })
  }
}
