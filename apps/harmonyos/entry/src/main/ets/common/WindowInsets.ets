/**
 * 窗口避让区（vp）。由 EntryAbility 开窗后写入，页面按它留白。
 *
 * 开了 `setWindowLayoutFullScreen(true)` 之后窗口会铺满整屏（内容压到状态栏和底部导航条下面），
 * 代价是**系统不再替我们避让**：顶部要给状态栏留位置、底部要给「小白条」（导航条）留位置，
 * 否则内容会被压住。这里把两个高度记下来给 `Theme.tabBarInset` 之类的用。
 *
 * 不是 `@ObservedV2`：这些值开窗后就定了，不会变，没必要做成响应式。
 */
export class WindowInsets {
  /** 状态栏高度（vp） */
  static top: number = 0;
  /** 底部导航条（小白条）高度（vp） */
  static bottom: number = 0;
}
