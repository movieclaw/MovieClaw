import { AgentTurn } from './AgentTimeline';

/**
 * 小幕陪伴（对应 iOS `AgentCompanion`）：会话输入框右上角的小精灵，
 * 动作来自同一张 4×6 透明图集（`moonlight.png`：列 = 帧 ×4，行 = 姿态 ×6）。
 * 任务状态以会话事件为准（resolve）；等待时静坐偶尔眨眼，点它打招呼。
 * 帧更新只发生在这个小组件里，聊天消息列不跟着动画重建。
 */

/** 小幕的动作状态（同 iOS `AgentCompanionState`；数值 = 图集行号） */
export enum AgentCompanionState {
  idle = 0,
  attentive = 1,
  departing = 2,
  working = 3,
  complete = 4,
  failed = 5
}

/** 状态推导与文案（同 iOS 的 `resolve` / `label` / `frameDuration`） */
export class AgentCompanionLogic {
  static resolve(turn: AgentTurn | null, busy: boolean, unavailable: boolean): AgentCompanionState {
    if (unavailable) {
      return AgentCompanionState.idle;
    }
    if (busy) {
      return AgentCompanionState.working;
    }
    if (turn === null) {
      return AgentCompanionState.idle;
    }
    if (turn.stopped) {
      return AgentCompanionState.idle;
    }
    if (turn.interrupted || turn.status === 'error') {
      return AgentCompanionState.failed;
    }
    return turn.status === 'done' ? AgentCompanionState.complete : AgentCompanionState.idle;
  }

  static label(state: AgentCompanionState): string {
    switch (state) {
      case AgentCompanionState.attentive:
        return '小幕，正在听你说';
      case AgentCompanionState.departing:
        return '小幕，出发了';
      case AgentCompanionState.working:
        return '小幕，正在处理任务';
      case AgentCompanionState.complete:
        return '小幕，任务已完成';
      case AgentCompanionState.failed:
        return '小幕，任务遇到了问题';
      default:
        return '小幕，安静陪伴';
    }
  }

  /** 每帧时长：working 300ms，其余 160ms */
  static frameDuration(state: AgentCompanionState): number {
    return state === AgentCompanionState.working ? 300 : 160;
  }
}

@ComponentV2
export struct AgentCompanion {
  @Require @Param activity: AgentCompanionState;
  /** 正在输入：空闲 / 失败时改摆倾听姿态 */
  @Require @Param attentive: boolean;

  @Local private pose: AgentCompanionState = AgentCompanionState.idle;
  @Local private frame: number = 0;
  /**
   * 动作序列的代际号：输入变化（`@Monitor`）或组件卸载时 +1，
   * 旧的异步序列在下一个 sleep 醒来发现代际不符就自毙（同 iOS `.task(id:)` 的取消）。
   */
  private runToken: number = 0;
  /** 点它打招呼的次数（内部输入；触发重算动作） */
  private greeting: number = 0;
  private observedActivity: AgentCompanionState = AgentCompanionState.idle;
  private observedGreeting: number = 0;

  aboutToAppear(): void {
    this.playback();
  }

  aboutToDisappear(): void {
    this.runToken += 1;
  }

  @Monitor('activity', 'attentive')
  private onPlaybackChanged(): void {
    this.playback();
  }

  /** 一个姿态播 4 帧 */
  private async playOnce(state: AgentCompanionState, token: number): Promise<void> {
    this.pose = state;
    for (let index = 0; index < 4; index++) {
      this.frame = index;
      const alive: boolean = await this.sleep(AgentCompanionLogic.frameDuration(state), token);
      if (!alive) {
        return;
      }
    }
  }

  private sleep(ms: number, token: number): Promise<boolean> {
    return new Promise<boolean>((resolve: (alive: boolean) => void) => {
      setTimeout((): void => {
        resolve(this.runToken === token);
      }, ms);
    });
  }

  /** 动作状态机（直译 iOS `.task(id: playback)` 里的序列） */
  private async playback(): Promise<void> {
    this.runToken += 1;
    const token: number = this.runToken;
    const previous: AgentCompanionState = this.observedActivity;
    const previousPose: AgentCompanionState = this.pose;
    const tapped: boolean = this.greeting !== this.observedGreeting;
    this.observedActivity = this.activity;
    this.observedGreeting = this.greeting;
    this.frame = 0;
    // 重进已结束的历史对话不重复庆祝；只有眼前这轮真的结束才迎接回来
    let next: AgentCompanionState = this.activity;
    if (next === AgentCompanionState.complete && previous !== AgentCompanionState.working) {
      next = AgentCompanionState.idle;
    }
    if ((next === AgentCompanionState.idle || next === AgentCompanionState.failed) && this.attentive) {
      next = AgentCompanionState.attentive;
    }
    this.pose = next;

    if (next === AgentCompanionState.working && previous !== AgentCompanionState.working) {
      await this.playOnce(AgentCompanionState.departing, token);
      if (this.runToken !== token) {
        return;
      }
      await this.playOnce(AgentCompanionState.working, token);
    } else if (next === AgentCompanionState.complete) {
      await this.playOnce(AgentCompanionState.complete, token);
      if (this.runToken !== token) {
        return;
      }
      const still: boolean = await this.sleep(1200, token);
      if (!still) {
        return;
      }
      this.pose = this.attentive ? AgentCompanionState.attentive : AgentCompanionState.idle;
    } else if (next === AgentCompanionState.failed && previous !== AgentCompanionState.failed) {
      await this.playOnce(AgentCompanionState.failed, token);
    } else if (next === AgentCompanionState.attentive
      && (previousPose !== AgentCompanionState.attentive || tapped)) {
      await this.playOnce(AgentCompanionState.attentive, token);
    } else if (tapped && next === AgentCompanionState.idle) {
      await this.playOnce(AgentCompanionState.attentive, token);
      if (this.runToken !== token) {
        return;
      }
      this.pose = AgentCompanionState.idle;
    }
    if (this.runToken !== token) {
      return;
    }
    this.frame = 0;
    // 等待时抱鱼静坐，只偶尔眨眼；错误和倾听停在静态表情，不再循环
    while (this.runToken === token && (this.pose === AgentCompanionState.working || this.pose === AgentCompanionState.idle)) {
      const seconds: number = this.pose === AgentCompanionState.working
        ? 15 + Math.random() * 10 : 8 + Math.random() * 6;
      const awake: boolean = await this.sleep(seconds * 1000, token);
      if (!awake) {
        return;
      }
      this.frame = this.pose === AgentCompanionState.working ? 2 : 1;
      const back: boolean = await this.sleep(250, token);
      if (!back) {
        return;
      }
      this.frame = 0;
    }
  }

  build() {
    Column() {
      // 与 CSS background-position 同理：共享一份位图，只挪图层显示当前格子
      Stack() {
        Image($r('app.media.moonlight'))
          .width(288)
          .height(432)
          .objectFit(ImageFit.Fill)
          .position({ x: -this.frame * 72, y: -(this.pose * 72) })
      }
      .width(72)
      .height(72)
      .clip(true)
      .onClick((): void => {
        this.greeting += 1;
        this.playback();
      })
      .accessibilityText(AgentCompanionLogic.label(this.pose))
    }
    .width(90)
    .height(72)
    .alignItems(HorizontalAlign.End)
    // 出发姿态横向滑出（同 iOS departing 的 offset）
    .offset({
      x: this.pose === AgentCompanionState.departing ? this.frame * 5 : 0,
      y: this.pose === AgentCompanionState.departing ? -(this.frame % 3) * 4 : 0
    })
  }
}
