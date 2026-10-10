import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 播放器的**系统合规壳**：后台播放、音频焦点、系统媒体控制。
 *
 * 这三件事 iOS 由 `AVAudioSession` + `MPNowPlayingInfoCenter` 一起包掉，
 * 鸿蒙这边要**分别**做，而且**漏一个功能就废**（§5.5）：
 *
 * 1. **后台播放**：必须 `AVSession`（type `'video'`）**加** `BackgroundTasks Kit` 的
 *    长时任务，**两者缺一不可**——不建 AVSession，退到后台会被系统直接停止播放。
 *    且**暂停时必须取消长时任务、恢复播放要重新申请**（一直挂着会被系统判为滥用）。
 * 2. **音频焦点**：必须显式处理 `on('audioInterrupt')`，否则来电 / 别的应用播放时行为不可控。
 *    中断时暂停并记住「是被打断的」，中断结束再恢复——而不是让用户回来发现自己在静音播放。
 * 3. **系统媒体控制**：AVSession 的 play / pause 命令要接上播放器，否则锁屏与通知栏的按钮是死的。
 */
export class PlaybackGuard {
  private context: common.UIAbilityContext;
  private session: avSession.AVSession | null = null;
  private running: boolean = false;
  private background: boolean = false;
  /** 是不是被外部打断而暂停的（中断结束后据此决定要不要自动恢复） */
  private interrupted: boolean = false;
  private onPlayCommand: () => void;
  private onPauseCommand: () => void;

  constructor(context: common.UIAbilityContext, onPlay: () => void, onPause: () => void) {
    this.context = context;
    this.onPlayCommand = onPlay;
    this.onPauseCommand = onPause;
  }

  /** 起播时调：建会话 + 申请长时任务 + 声明在播 */
  async start(title: string): Promise<void> {
    await this.ensureSession(title);
    await this.acquireBackground();
    this.running = true;
  }

  /** 暂停时调：**释放长时任务**（留着会被判滥用），但保留会话 */
  async pause(): Promise<void> {
    this.running = false;
    await this.releaseBackground();
  }

  /** 恢复播放：重新申请长时任务 */
  async resume(): Promise<void> {
    await this.acquireBackground();
    this.running = true;
  }

  /** 退出播放页时调：全部收掉 */
  async stop(): Promise<void> {
    this.running = false;
    await this.releaseBackground();
    const session: avSession.AVSession | null = this.session;
    this.session = null;
    if (session !== null) {
      try {
        await session.deactivate();
        await session.destroy();
      } catch (error) {
        // 会话可能已被系统回收，忽略
      }
    }
  }

  /**
   * 音频焦点：来电 / 别的应用抢焦点时暂停；中断结束再恢复。
   * **只在「我们本来在播」时才自动恢复**——用户自己按的暂停不该被这次中断翻回来。
   */
  handleInterrupt(event: audio.InterruptEvent): void {
    // 字段名是 `hintType`（不是 interruptHint），值是 `audio.InterruptHint`
    const hint: audio.InterruptHint = event.hintType;
    if (hint === audio.InterruptHint.INTERRUPT_HINT_PAUSE
      || hint === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      if (this.running) {
        this.interrupted = true;
        this.onPauseCommand();
      }
      return;
    }
    if (hint === audio.InterruptHint.INTERRUPT_HINT_RESUME && this.interrupted) {
      this.interrupted = false;
      this.onPlayCommand();
    }
  }

  /** 更新系统媒体控制里显示的信息（标题 / 时长 / 进度） */
  async updateMetadata(title: string, durationMs: number): Promise<void> {
    const session: avSession.AVSession | null = this.session;
    if (session === null) {
      return;
    }
    try {
      const metadata: avSession.AVMetadata = {
        assetId: 'movieclaw',
        title: title,
        // `duration` 是 number（秒），不是字符串
        duration: Math.floor(durationMs / 1000)
      };
      await session.setAVMetadata(metadata);
    } catch (error) {
      // 元数据只是锦上添花，失败不该影响播放
    }
  }

  private async ensureSession(title: string): Promise<void> {
    if (this.session !== null) {
      await this.updateMetadata(title, 0);
      return;
    }
    try {
      const session: avSession.AVSession =
        await avSession.createAVSession(this.context, 'movieclaw-player', 'video');
      this.session = session;
      await session.setAVMetadata({ assetId: 'movieclaw', title: title });
      await session.activate();
      // 锁屏 / 通知栏的按钮要接上播放器，否则是死的
      session.on('play', (): void => {
        this.onPlayCommand();
      });
      session.on('pause', (): void => {
        this.onPauseCommand();
      });
      session.on('stop', (): void => {
        this.onPauseCommand();
      });
    } catch (error) {
      hilog.error(0x0000, 'PlaybackGuard', 'createAVSession failed: %{public}s', `${error}`);
    }
  }

  /**
   * 申请长时任务。**没有 AVSession 时不该申请**——系统会拒，
   * 而且那说明壳没搭好，先把会话建起来。
   */
  private async acquireBackground(): Promise<void> {
    if (this.background || this.session === null) {
      return;
    }
    try {
      const agent: WantAgent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(this.context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.background = true;
    } catch (error) {
      // 错误对象直接 `${error}` 只会打印 [object Object]，要显式取 code/message
      const e = error as BusinessError;
      hilog.error(0x0000, 'PlaybackGuard', 'startBackgroundRunning failed code=%{public}d msg=%{public}s',
        e.code ?? -1, e.message ?? '');
    }
  }

  private async releaseBackground(): Promise<void> {
    if (!this.background) {
      return;
    }
    this.background = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(0x0000, 'PlaybackGuard', 'stopBackgroundRunning failed code=%{public}d msg=%{public}s',
        e.code ?? -1, e.message ?? '');
    }
  }
}
