import { display } from '@kit.ArkUI';
import { WindowInsets } from '../common/WindowInsets';
/**
 * 全局主题 token（逐值对齐 Web 端 `apps/web/app/globals.css` 的深色冷银主题）。
 *
 * App 全局深色：背景纯黑、文字冷白、强调色是「银玻璃」而非彩色。
 * 状态语义色四档（ok/info/warn/danger）只用于状态点与状态文字，
 * 与 Web 端的判断口径一致：颜色说「系统状态」，只有 danger 说「你该处理」。
 *
 * 全部用十六进制字符串/Resource 而非自造枚举，保证与 CSS 一一对应。
 */
export class Theme {
  /* —— 背景 —— */
  static readonly bg: string = '#000000';
  /** 卡片/面板底：比纯黑略抬一层的深灰（对应 Web --card #0b0d12 一系） */
  static readonly surface: string = '#0b0d12';
  /** 再抬一层：输入框、玻璃行底 */
  static readonly surfaceRaised: string = '#14161d';

  /* —— 文本层级（冷白） —— */
  static readonly text: string = '#f3f5f9';
  static readonly textMuted: string = 'rgba(243, 245, 249, 0.62)';
  static readonly textFaint: string = 'rgba(243, 245, 249, 0.36)';

  /* —— 描边 —— */
  static readonly line: string = 'rgba(255, 255, 255, 0.08)';
  static readonly lineStrong: string = 'rgba(255, 255, 255, 0.15)';

  /* —— 强调：银玻璃 —— */
  static readonly accent: string = '#cdd6e6';
  static readonly accentStrong: string = '#eef2f8';
  static readonly accent2: string = '#9fb0c9';
  static readonly accentSoft: string = 'rgba(205, 214, 230, 0.14)';

  /* —— 行内玻璃填充 —— */
  static readonly glassFill: string = 'rgba(255, 255, 255, 0.04)';
  static readonly glassFillHover: string = 'rgba(255, 255, 255, 0.075)';

  /* —— 状态语义色 —— */
  static readonly ok: string = '#4ade80';
  static readonly info: string = '#7fb0ff';
  static readonly warn: string = '#f5c451';
  static readonly danger: string = '#ff6b6b';
  /** 失败提示条用的黄（对齐 iOS Theme.warning #fbbf24，比 Web 的 warn 更亮） */
  static readonly warning: string = '#fbbf24';

  /* —— 布局与形状（对齐 iOS Theme.swift 的同名常量） —— */
  /** 页面左右统一留白 */
  static readonly pagePadding: number = 16;
  /** 海报圆角 */
  static readonly posterRadius: number = 12;
  /** 卡片圆角 */
  static readonly cardRadius: number = 16;
  /** 海报框默认宽高比 2:3 */
  static readonly posterAspect: number = 2 / 3;
  /**
   * 页签内可滚动内容的底部留白：给悬浮导航栏让位。
   * HdsTabs 开了 barOverlap 之后内容会从页签栏下面穿过去，页面自己不空出这段高度，
   * 最后一行就被胶囊压住（实测首页最后一行海报标题会被盖）。
   * 取值 = 胶囊高度（约 48vp）+ 底部间距（barBottomMargin 12vp）+ 一点呼吸。
   */
  /**
   * 底部内容要让开的高度 = 悬浮页签栏（48 + 12 边距 + 余量）+ **底部导航条（小白条）**。
   *
   * 第二项是开了沉浸式布局之后才需要的：窗口铺满整屏时系统不再替我们避让，
   * 不留的话最后一排内容会被小白条压住。见 common/WindowInsets.ets。
   */
  /**
   * 顶部内容要让开的高度 = 状态栏高度。
   *
   * 开了沉浸式布局（`setWindowLayoutFullScreen(true)`）之后系统不再替我们避让状态栏，
   * **每页自己的顶栏都要加上这个值**，否则标题会压到时间/电量上（实测踩过）。
   * 沉浸大图的页面例外：图铺到状态栏下面，但返回键要往下挪这么多。
   */
  /**
   * 沉浸大图（条目详情、订阅轮播）的高度。
   *
   * **逐值照搬 iOS**：`min(屏宽 × 1.15, 屏高 × 0.62)`
   * （见 `LibraryItemDetailView.hero` 与 `SubscriptionsHomeHero`）。
   * 之前这两处各写了一个固定值（320 / 440），**同一部剧在两个页面里图的取景不一样**，
   * 用户看到的感受就是「订阅轮播的海报位置不对」。
   */
  static get heroHeight(): number {
    const d: display.Display = display.getDefaultDisplaySync();
    const w: number = px2vp(d.width);
    const h: number = px2vp(d.height);
    return Math.min(w * 1.15, h * 0.62);
  }

  /**
   * 顶部要让开的高度：**0**。
   *
   * 页面结构已改成华为官方的「系统避让安全区」（`setWindowLayoutFullScreen(false)`），
   * 内容区就是安全区，不需要页面再自己补——所以这个 token 恒为 0，
   * 所有 `PageTopBar` / 各页顶栏的 `+ Theme.statusBarInset` 自动退化成「不加」，
   * 不用去改二十多个调用点。
   * 沉浸式页面（详情/订阅/发现的大图）例外：它们自己读 `WindowInsets.top` 做偏移。
   */
  /**
   * 海报网格「一行几列」：按屏宽自适应，**恒定落在 2~4 列**。
   *
   * 口径：先扣掉页面左右留白，再按「每格约 118vp（含 12 的间距）」估算，最后夹到 2..4：
   * - 360vp 小屏 → 2 列；440vp 常规手机 → **3 列**（同 iOS 媒体库）；折叠屏 / 平板 → 4 列。
   *
   * 用同一个函数算，保证媒体库、收藏、合集详情这些「海报墙」页面的列数一致，
   * 不会出现有的页面 2 列、有的 3 列。
   */
  static posterColumns(): number {
    const d: display.Display = display.getDefaultDisplaySync();
    const widthVp: number = px2vp(d.width);
    const usable: number = widthVp - Theme.pagePadding * 2;
    const estimated: number = Math.floor((usable + 12) / 118);
    return Math.min(4, Math.max(2, estimated));
  }

  static get statusBarInset(): number {
    return 0;
  }

  static get tabBarInset(): number {
    /*
     * 底部内容要让开的高度 = 悬浮页签胶囊（约 48）+ 底部抬起（`barBottomMargin` 12）+ 一点呼吸
     * = 76，再加**底部安全区**（沉浸式布局下系统不替我们避让，设备有手势条时仍要让）。
     */
    // 胶囊 48 + 底部抬起 12 + 一点呼吸 12（手势条已由系统让开，不再重复加）
    return 72;
  }

  /**
   * 整屏页（会话页、回收站、日志页……：没有悬浮页签栏）底部要让开的高度 = 系统手势条（小白条）。
   *
   * 这些页面底部有**不滚动**的操作条（会话页输入框、回收站批量条、日志页脚注），
   * 沉浸式布局下系统不避让，条子会被小白条压住——实测会话页输入框「说点什么…」下半截被盖。
   * 注意别拿 `tabBarInset` 来顶：那个还额外算了悬浮页签胶囊的高度，用在这儿会多出一条空带。
   */
  static get safeBottomInset(): number {
    return WindowInsets.bottom;
  }
}
