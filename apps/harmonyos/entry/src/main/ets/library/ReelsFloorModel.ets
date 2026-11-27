export const REELS_FLOOR_REFRESH_AT: number = 183;
const REVEAL_SPAN: number = 20;
const ARM_BEYOND: number = 35;

/** 二楼下拉状态机（与 UI 解耦，供首页二楼胶片条与单测共用） */
@Observed
export class ReelsFloorState {
  pull: number = 0;
  refreshedAt: number = -1;
  armed: boolean = false;
  dragging: boolean = false;

  reveal(): number {
    if (this.refreshedAt < 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, (this.pull - this.refreshedAt) / REVEAL_SPAN));
  }

  progress(): number {
    if (this.refreshedAt < 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, (this.pull - this.refreshedAt) / ARM_BEYOND));
  }

  private pastLine(): boolean {
    return this.refreshedAt >= 0 && this.pull >= this.refreshedAt + ARM_BEYOND;
  }

  begin(): void {
    this.dragging = true;
    this.pull = 0;
    this.refreshedAt = -1;
    this.armed = false;
  }

  drag(pull: number): void {
    if (!this.dragging) {
      return;
    }
    this.pull = Math.max(0, pull);
    if (this.refreshedAt < 0 && this.pull >= REELS_FLOOR_REFRESH_AT) {
      this.refreshedAt = REELS_FLOOR_REFRESH_AT;
    }
    const past: boolean = this.pastLine();
    if (past !== this.armed) {
      this.armed = past;
    }
  }

  release(): boolean {
    this.dragging = false;
    return this.armed;
  }

  reset(): void {
    this.pull = 0;
    this.refreshedAt = -1;
    this.armed = false;
    this.dragging = false;
  }
}
