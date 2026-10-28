/**
 * 媒体库首页的「下拉二楼」判定（与 iOS `ReelsFloor`、Android `ReelsFloorState` 同一套，docs/design/reels.md §6）。
 *
 * 手机网页（主屏 PWA）没有系统下拉刷新，刷新也由这里自己触发：
 * - 照常下拉：内容跟着手指往下走（橡皮筋手感按 iOS 实测曲线），拉到 {@link REFRESH_AT} 刷新；
 * - 刷新之后继续拉，胶片入画（+{@link REVEAL_SPAN}），再拉过 {@link ARM_BEYOND} 算过线，松手进片段；
 * - 推回线内再松手只是刷新。只认手指拖着的越界：每次按下重新判断。
 * 距离按 CSS 像素（手机上即点）。
 */

export const REFRESH_AT = 183;
export const REVEAL_SPAN = 20;
export const ARM_BEYOND = 35;

/** 橡皮筋：前 48 跟手，之后越拉越沉 */
export function rubber(drag: number): number {
  if (drag <= 48) return Math.max(0, drag);
  const x = 0.6 * (drag - 48);
  return 48 + (x * 700) / (700 + x);
}

export class ReelsFloorModel {
  /** 手指拉过的原始距离（未经橡皮筋） */
  drag = 0;
  /** 拉过线了，松手就进。只在拖动中更新：松手后回弹途中保持原样 */
  armed = false;
  /** 这一次拖动里刷新是否已触发（记刷新点本身） */
  refreshedAt: number | null = null;
  dragging = false;

  get pull(): number {
    return rubber(this.drag);
  }

  /** 刷新之后胶片入画多少（0～1） */
  get reveal(): number {
    if (this.refreshedAt === null) return 0;
    return clamp01((this.pull - this.refreshedAt) / REVEAL_SPAN);
  }

  /** 从刷新到过线走了多少（0～1）：放映灯随它变亮、首页随它变暗 */
  get progress(): number {
    if (this.refreshedAt === null) return 0;
    return clamp01((this.pull - this.refreshedAt) / ARM_BEYOND);
  }

  /** 手指按下：新一次拖动从头判断，上次松手留下的过线不带过来 */
  begin(): void {
    this.dragging = true;
    this.refreshedAt = null;
    this.armed = false;
  }

  /**
   * 手指拖到离按下处 `distance`（往下为正）；返回 true 表示这一下刚好触发刷新。
   */
  dragTo(distance: number): boolean {
    this.drag = Math.max(0, distance);
    let refreshed = false;
    if (this.refreshedAt === null && this.pull >= REFRESH_AT) {
      this.refreshedAt = REFRESH_AT;
      refreshed = true;
    }
    this.armed = this.refreshedAt !== null && this.pull >= this.refreshedAt + ARM_BEYOND;
    return refreshed;
  }

  /** 手指抬起；返回 true 表示这一下是拉过线后松手 */
  release(): boolean {
    this.dragging = false;
    return this.armed;
  }

  /** 松手后回弹的动画帧（按原始距离） */
  settle(drag: number): void {
    this.drag = Math.max(0, drag);
  }

  reset(): void {
    this.drag = 0;
    this.armed = false;
    this.refreshedAt = null;
    this.dragging = false;
  }
}

function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value));
}
