/**
 * 车机端设计令牌：固定深色 + 大触控目标（≥48vp）+ 超宽横屏。
 *
 * 尺寸换算基准：Huawei_Car 模拟器 3402×1620 px @432dpi ≈ 1260×600 vp（2.1:1 超宽）。
 * 与 TV 端（1280×720 vp）同源的深色色板（纯黑底 + 冷灰文字 + 银白强调），
 * 保证跨端品牌一致；布局令牌只定基准值，实际布局全部弹性/百分比/Grid 实现，
 * 不锁死画布（FR-016），真车屏幕差异靠响应式吸收。
 */

/** 布局与卡片度量（单位 vp） */
export class CarMetrics {
  /** 基准画布（1260×600 vp）；布局不锁死，仅作令牌推导参考 */
  static readonly screenWidth: number = 1260;
  static readonly screenHeight: number = 600;
  /** 屏幕四边留白（车机基准边距 48） */
  static readonly edge: number = 48;
  /** 触控目标最小边（车机通则硬指标） */
  static readonly minTouch: number = 48;
  /** 左侧图标导航栏宽 */
  static readonly railWidth: number = 96;
  /** 海报卡宽（2:3 高约 300） */
  static readonly posterWidth: number = 200;
  static readonly posterHeight: number = 300;
  /** 横版剧照卡宽（16:9 高约 113） */
  static readonly landscapeWidth: number = 200;
  static readonly landscapeHeight: number = 113;
  /** 行内大横版卡宽（「接下来继续」/收藏大卡：16:9 高约 149，一屏约 4 张） */
  static readonly landscapeBigWidth: number = 264;
  /** 媒体库卡宽（16:9 高约 180） */
  static readonly libraryCardWidth: number = 320;
  /** 行间距 */
  static readonly rowGap: number = 28;
  /** 卡片间距 */
  static readonly cardGap: number = 20;
  /** 卡片圆角 */
  static readonly cardCorner: number = 14;
  /** 海报墙网格间距 */
  static readonly wallGap: number = 20;
  /** 播放器传输条与信息面板距屏边 */
  static readonly playerInset: number = 56;
  /** 按下反馈缩放 */
  static readonly pressScale: number = 0.97;
}

/** 深色色板（与手机端 AppTheme / TV 端 TvColors 同源） */
export class CarColors {
  static readonly bg: string = '#000000';
  static readonly surface: string = '#0b0d12';
  static readonly surfaceRaised: string = '#14161d';
  static readonly text: string = '#f3f5f9';
  static readonly textMuted: string = 'rgba(243, 245, 249, 0.62)';
  static readonly textFaint: string = 'rgba(243, 245, 249, 0.36)';
  static readonly line: string = 'rgba(255, 255, 255, 0.08)';
  static readonly lineStrong: string = 'rgba(255, 255, 255, 0.15)';
  /** 选中/激活亮边（触屏无焦点环，用亮描边表达选中态） */
  static readonly activeRing: string = 'rgba(255, 255, 255, 0.85)';
  static readonly glassFill: string = 'rgba(20, 22, 29, 0.78)';
  static readonly glassFillHover: string = 'rgba(32, 35, 45, 0.9)';
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

/** 字号阶梯（单位 fp；车机 3 秒注视原则 → 层级少、字号大） */
export class CarType {
  /** 大图区/欢迎页主标题 */
  static readonly heroTitle: number = 36;
  /** 行标题 */
  static readonly rowTitle: number = 22;
  /** 卡片说明文字 */
  static readonly cardCaption: number = 15;
  /** 事实行 / 按钮文字 */
  static readonly body: number = 18;
  /** 次要说明 */
  static readonly footnote: number = 14;
  /** 导航栏图标旁文字（收起时只有图标） */
  static readonly railItem: number = 16;
  /** 播放器时间 / 标题 */
  static readonly playerTime: number = 16;
  static readonly playerTitle: number = 24;
  /** 欢迎页大标题 */
  static readonly welcomeTitle: number = 40;
  /** 配对码（扫码主视图的视觉主角） */
  static readonly pairCode: number = 56;
}

/** 动画时长（毫秒）与交互节奏 */
export class CarMotion {
  /** 按压/选中反馈过渡 */
  static readonly pressMs: number = 130;
  /** 大图交叉淡入 */
  static readonly crossfadeMs: number = 300;
  /** 面板/抽屉收起 */
  static readonly panelMs: number = 220;
  /** 播放器 chrome 自动收起延时 */
  static readonly chromeHideMs: number = 4000;
  /** 搜索防抖 */
  static readonly searchDebounceMs: number = 350;
}

/**
 * 车机图片取图宽度：vp × 密度 2.7（432dpi / 160）→ 吸附到 50px 档位提升缓存命中。
 * 对应服务端 `?w=` 参数约定（同 TV 端 TvArt）。
 */
export class CarArt {
  static readonly density: number = 2.7;

  static pxWidth(vpWidth: number): number {
    const raw: number = Math.round(vpWidth * CarArt.density);
    return Math.ceil(raw / 50) * 50;
  }
}
