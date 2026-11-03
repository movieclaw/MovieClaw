/**
 * 窗口避让区（vp）。由 EntryAbility 开窗后写入，页面按它留白。
 *
 * 开了 `setWindowLayoutFullScreen(true)` 之后窗口会铺满整屏（内容压到状态栏和底部导航条下面），
 * 代价是**系统不再替我们避让**：顶部要给状态栏留位置、底部要给「小白条」（导航条）留位置，
 * 否则内容会被压住。这里把两个高度记下来给 `Theme.tabBarInset` 之类的用。
 *
 * `@ObservedV2` + `@Trace`：转横屏（状态栏收起、挖孔转到侧面）、折叠屏展开、2in1 自由窗口
 * 都会改变避让区，EntryAbility 的 `avoidAreaChange` 监听写进来后，V2 页面自动重排。
 *
 * V1（`@Component`）页面观测不到 `@Trace`：它们声明
 * `@StorageProp('shellLayoutRevision')` 拿到 `ShellLayoutRevision` 的版本号，
 * 版本一变整页重算，build 里读到的就是新的避让区。版本号由下面两个入口负责自增：
 * 避让区变化（本文件）与底栏样式切换（`common/TabBarStyle`）。
 */
export const SHELL_LAYOUT_REVISION_KEY: string = 'shellLayoutRevision';

@ObservedV2
export class WindowInsets {
  private static instance: WindowInsets | null = null;

  /** 懒建单例（`@ObservedV2` 的类不能用静态字段初始化器，会拿不到订阅） */
  static shared(): WindowInsets {
    if (WindowInsets.instance === null) {
      WindowInsets.instance = new WindowInsets();
    }
    return WindowInsets.instance;
  }

  /** 状态栏高度（vp） */
  @Trace top: number = 0;
  /** 底部导航条（小白条）高度（vp） */
  @Trace bottom: number = 0;
  /** 挖孔/刘海贴在窗口左缘的宽（vp；竖屏恒 0，横屏时画面两侧挖孔的那一侧非 0） */
  @Trace cutoutLeft: number = 0;
  /** 挖孔/刘海贴在窗口右缘的宽（vp） */
  @Trace cutoutRight: number = 0;

  /** 避让区有变化时调用：自增版本号，通知观测不到 `@Trace` 的 V1 页面重排 */
  static bumpRevision(): void {
    const current: number = AppStorage.get<number>(SHELL_LAYOUT_REVISION_KEY) ?? 0;
    AppStorage.setOrCreate<number>(SHELL_LAYOUT_REVISION_KEY, current + 1);
  }
}
