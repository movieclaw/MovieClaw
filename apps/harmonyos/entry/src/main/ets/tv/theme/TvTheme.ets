/**
 * TV（智慧屏）设计令牌：Apple TV 风格的深色视觉体系。
 *
 * 尺寸换算基准：Apple TV 参考端以 1920×1080 pt 画布设计（TVCards.swift TVMetrics），
 * 智慧屏 vp 画布按 1280×720 计，全部尺寸 ×0.667 等比换算：
 * edge 80→53、poster 266→177、landscape 416→277、library 565→377、
 * rowSpacing 56→37、cardSpacing 32→21、corner 20→13、focusZoom 1.1 保持。
 * 字号同理按 ×0.667 取整。
 *
 * 色板与手机端 theme/AppTheme.ets 同源（纯黑底 + 冷灰文字 + 银白强调），
 * 保证跨端品牌一致；此处独立成类避免 TV 依赖手机主题的实现细节。
 */

/** 布局与卡片度量（单位 vp） */
export class TvMetrics {
  /** 智慧屏画布（1280×720 vp）；居中式布局按它算最大可用宽 */
  static readonly screenWidth: number = 1280;
  static readonly screenHeight: number = 720;
  /** 屏幕四边留白（Apple TV edge 80 × 0.667） */
  static readonly edge: number = 53;
  /** 海报卡宽（poster 266 × 0.667）；2:3 高约 266 */
  static readonly posterWidth: number = 177;
  static readonly posterHeight: number = 266;
  /** 横版剧照卡宽（landscape 416 × 0.667）；16:9 高约 156 */
  static readonly landscapeWidth: number = 277;
  static readonly landscapeHeight: number = 156;
  /** 媒体库大卡宽（library 565 × 0.667） */
  static readonly libraryCardWidth: number = 377;
  static readonly libraryCardHeight: number = 212;
  /** 行间距（rowSpacing 56 × 0.667） */
  static readonly rowGap: number = 37;
  /** 卡片间距（cardSpacing 32 × 0.667） */
  static readonly cardGap: number = 21;
  /** 卡片圆角（cardCorner 20 × 0.667） */
  static readonly cardCorner: number = 13;
  /** 焦点放大系数（Apple TV focusZoom 原值） */
  static readonly focusZoom: number = 1.1;
  /** 焦点位移：放大后的卡片上浮量，避免下缘被裁 */
  static readonly focusLift: number = 6;
  /** 侧边栏收起胶囊宽 */
  static readonly railCollapsed: number = 56;
  /** 侧边栏展开宽（玻璃方片） */
  static readonly railExpanded: number = 300;
  /** 海报墙列数 */
  static readonly wallColumns: number = 5;
  /** 播放器传输条与信息面板距屏边 */
  static readonly playerInset: number = 64;
}

/** 深色色板（与手机端 AppTheme 同源） */
export class TvColors {
  static readonly bg: string = '#000000';
  static readonly surface: string = '#0b0d12';
  static readonly surfaceRaised: string = '#14161d';
  static readonly text: string = '#f3f5f9';
  static readonly textMuted: string = 'rgba(243, 245, 249, 0.62)';
  static readonly textFaint: string = 'rgba(243, 245, 249, 0.36)';
  static readonly line: string = 'rgba(255, 255, 255, 0.08)';
  static readonly lineStrong: string = 'rgba(255, 255, 255, 0.15)';
  /** 焦点亮边：接近白的银色（Apple TV 焦点环是亮白描边，不用品牌色） */
  static readonly focusRing: string = 'rgba(255, 255, 255, 0.92)';
  static readonly glassFill: string = 'rgba(20, 22, 29, 0.72)';
  static readonly glassFillHover: string = 'rgba(32, 35, 45, 0.85)';
  static readonly accent: string = '#cdd6e6';
  static readonly accentSoft: string = 'rgba(205, 214, 230, 0.16)';
  static readonly ok: string = '#4ade80';
  static readonly info: string = '#7fb0ff';
  static readonly warn: string = '#f5c451';
  static readonly danger: string = '#ff6b6b';
  /** 大图区底部亮度渐变的起止色（透明→纯黑） */
  static readonly scrimTop: string = 'rgba(0, 0, 0, 0)';
  static readonly scrimMid: string = 'rgba(0, 0, 0, 0.55)';
  static readonly scrimBottom: string = 'rgba(0, 0, 0, 0.92)';
}

/** 字号阶梯（Apple TV pt × 0.667 取整，单位 fp） */
export class TvType {
  /** 大图区主标题（片名文字版） */
  static readonly heroTitle: number = 40;
  /** 大图区副标题 / 行标题 */
  static readonly rowTitle: number = 24;
  /** 卡片说明文字 */
  static readonly cardCaption: number = 16;
  /** 事实行 / 按钮文字 */
  static readonly body: number = 19;
  /** 次要说明 */
  static readonly footnote: number = 15;
  /** 侧边栏菜单 */
  static readonly railItem: number = 21;
  /** 播放器时间 / 标题 */
  static readonly playerTime: number = 17;
  static readonly playerTitle: number = 26;
  /** 欢迎页大标题 */
  static readonly welcomeTitle: number = 46;
}

/** 动画时长与曲线（毫秒 / 官方曲线枚举名映射在使用处） */
export class TvMotion {
  /** 焦点放大 / 亮边过渡 */
  static readonly focusMs: number = 160;
  /** 大图交叉淡入 */
  static readonly crossfadeMs: number = 360;
  /** 侧边栏展开收起 */
  static readonly railMs: number = 240;
  /** 面板收起 */
  static readonly panelMs: number = 220;
  /** 首页焦点防抖（spec：0.16s） */
  static readonly stageDebounceMs: number = 160;
  /** 大图预告触发延时（spec：焦点停稳 2 秒） */
  static readonly previewDelayMs: number = 2000;
  /** Ken Burns 慢推时长与倍率（spec US9） */
  static readonly kenBurnsMs: number = 40000;
  static readonly kenBurnsScale: number = 1.06;
}

/**
 * TV 图片取图宽度：vp × 密度 3 × 焦点放大，再吸附到 50px 档位提升缓存命中。
 * 对应 Apple TV 端 `api.image(url, width:)` 的 `?w=` 参数约定。
 */
export class TvArt {
  static readonly density: number = 3;

  static pxWidth(vpWidth: number): number {
    const raw: number = Math.round(vpWidth * TvArt.density * TvMetrics.focusZoom);
    return Math.ceil(raw / 50) * 50;
  }
}
