package io.movieclaw.androidtv.ui.shell

/** 主界面上按返回键做什么（播放器开着时由播放器自己处理，不走这里） */
enum class BackAction { CloseSidebar, Pop, GoHome, ArmExit, Exit }

/** 首页根页上连按两次返回键退出的时限：第一次按下后这么久内再按才退出，提示也只显示这么久 */
const val EXIT_WINDOW_MS = 2_000L

/**
 * 主界面返回键（MainShell 的 BackHandler）：
 * - 侧边栏开着：收起它，焦点还给页面；
 * - 当前页签压着二级页：退一层；
 * - 账号 / 搜索页签的根页：回首页页签（左上角「‹ 账号名 / 搜索」胶囊本来就暗示返回有去处，
 *   用户真机上在「谁在看？」按返回直接退出了 App）；
 * - 首页根页：第一次只提示「再按一次返回键退出」，[EXIT_WINDOW_MS] 内再按才退出。Android TV 设计规范
 *   不建议退出时弹确认对话框，所以用不挡操作的「连按两次」代替对话框（国内电视 App 大多也是这个习惯）。
 *
 * [lastBackAtMs] 是上次在首页根页按返回（出提示）的时刻，没有为 null；与 [nowMs] 用同一个时钟。
 */
fun backAction(sidebarOpen: Boolean, stackEmpty: Boolean, tab: MainTab, lastBackAtMs: Long?, nowMs: Long): BackAction = when {
    sidebarOpen -> BackAction.CloseSidebar
    !stackEmpty -> BackAction.Pop
    tab != MainTab.Home -> BackAction.GoHome
    lastBackAtMs != null && nowMs - lastBackAtMs in 0 until EXIT_WINDOW_MS -> BackAction.Exit
    else -> BackAction.ArmExit
}
