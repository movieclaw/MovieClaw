import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 折叠态感知（Pura X 阔折叠这类左右折机型）。
 *
 * 折叠 = 应用跑在**外屏**上。Pura X 外屏是 3.5" 方屏（1:1），窗口移过去只是一次
 * 尺寸变化：网格列数、沉浸大图高度本来就跟窗口宽高走（`Theme.posterColumns` /
 * `Theme.heroHeight`），避让区由 `avoidAreaChange` 持续刷新，XComponent 的 surface
 * 重建也有 surfaceGeneration 兜底重绑——主界面与播放面**不需要方屏专用分支**。
 *
 * 必须感知折叠态的是**方向**：内屏上锁了横屏（`AUTO_ROTATION_LANDSCAPE`）再折叠，
 * 横屏偏好会跟着窗口带到方屏外屏，整个界面就横过来了。所以播放器读 `coverActive`
 * 收起「横屏播放」按钮，并在折叠瞬间清掉横屏锁（见 PhonePlaybackHost）。
 *
 * `@ObservedV2` + `@Trace`：V2 页面在 build 里读 `coverActive`，折叠/展开自动重排；
 * 播放器之外的页面无需订阅，纯读即可。
 */
@ObservedV2
export class FoldState {
  private static instance: FoldState | null = null;

  /** 懒建单例（`@ObservedV2` 的类不能用静态字段初始化器，会拿不到订阅） */
  static shared(): FoldState {
    if (FoldState.instance === null) {
      FoldState.instance = new FoldState();
    }
    return FoldState.instance;
  }

  /** 折叠中（= 应用在外屏方屏上跑）；非折叠设备恒 false */
  @Trace coverActive: boolean = false;

  /**
   * EntryAbility 冷启动时调一次：先记初值再挂监听。
   * App 可能直接在外屏上冷启动（折叠着点开），只靠事件会漏掉这个初态。
   */
  init(): void {
    try {
      this.refresh(display.getFoldStatus());
    } catch (error) {
      hilog.warn(0x0000, 'MovieClaw', '读折叠态失败（非折叠设备正常）：%{public}s', `${error}`);
    }
    try {
      display.on('foldStatusChange', (status: display.FoldStatus): void => {
        this.refresh(status);
      });
    } catch (error) {
      hilog.warn(0x0000, 'MovieClaw', '挂 foldStatusChange 失败：%{public}s', `${error}`);
    }
  }

  private refresh(status: display.FoldStatus): void {
    const folded: boolean = status === display.FoldStatus.FOLD_STATUS_FOLDED;
    if (folded !== this.coverActive) {
      this.coverActive = folded;
      hilog.info(0x0000, 'MovieClaw', '折叠态变化：coverActive=%{public}s', `${folded}`);
    }
  }
}
