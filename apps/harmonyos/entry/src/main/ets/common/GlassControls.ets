import { Theme } from '../theme/AppTheme';

/**
 * 官方 `Button` / `Toggle` 的统一外观：**渐变玻璃**。
 *
 * 为什么用 `AttributeModifier`：`@Extend` 不能跨文件导出，而 Modifier 类可以——
 * 全 App 的按钮只保留这一份渐变/描边/模糊的定义，之后改样式只改这里。
 *
 * 四个色调（都是同一套玻璃质感，只是色相不同）：
 * - Secondary：冷白渐变（白 16% → 5%），纯黑背景上是可辨的浅色玻璃；
 * - Primary：银灰渐变（强调操作 / 选中态），配深色文字；
 * - Strong：更亮一档的白玻璃（选中态但仍然用浅色文字，例如分段控件）；
 * - Danger / Warn / Info：红 / 黄 / 蓝染色玻璃，配白色文字。
 */
export enum GlassTone {
  Secondary = 'secondary',
  Primary = 'primary',
  Strong = 'strong',
  Danger = 'danger',
  Warn = 'warn',
  Info = 'info',
  /** 紫色（复核建议这类「次要强调」） */
  Violet = 'violet',
  /** 深色玻璃：压在视频/海报上的按钮，保持深底白字 */
  Dark = 'dark',
  /** 绿色玻璃：建议/成功一类的正向动作 */
  Success = 'success'
}

export class GlassButtonModifier implements AttributeModifier<ButtonAttribute> {
  private readonly tone: GlassTone;

  constructor(tone: GlassTone = GlassTone.Secondary) {
    this.tone = tone;
  }

  private top(): string {
    if (this.tone === GlassTone.Primary) {
      return '#eef2f8';
    }
    if (this.tone === GlassTone.Strong) {
      return 'rgba(255, 255, 255, 0.34)';
    }
    if (this.tone === GlassTone.Danger) {
      return 'rgba(255, 107, 107, 0.88)';
    }
    if (this.tone === GlassTone.Warn) {
      return 'rgba(245, 196, 81, 0.82)';
    }
    if (this.tone === GlassTone.Info) {
      return 'rgba(127, 176, 255, 0.82)';
    }
    if (this.tone === GlassTone.Violet) {
      return 'rgba(196, 181, 253, 0.34)';
    }
    if (this.tone === GlassTone.Dark) {
      return 'rgba(0, 0, 0, 0.46)';
    }
    if (this.tone === GlassTone.Success) {
      return 'rgba(74, 222, 128, 0.72)';
    }
    return 'rgba(255, 255, 255, 0.16)';
  }

  private bottom(): string {
    if (this.tone === GlassTone.Primary) {
      return '#bcc8da';
    }
    if (this.tone === GlassTone.Strong) {
      return 'rgba(255, 255, 255, 0.14)';
    }
    if (this.tone === GlassTone.Danger) {
      return 'rgba(255, 107, 107, 0.52)';
    }
    if (this.tone === GlassTone.Warn) {
      return 'rgba(245, 196, 81, 0.42)';
    }
    if (this.tone === GlassTone.Info) {
      return 'rgba(127, 176, 255, 0.42)';
    }
    if (this.tone === GlassTone.Violet) {
      return 'rgba(196, 181, 253, 0.12)';
    }
    if (this.tone === GlassTone.Dark) {
      return 'rgba(0, 0, 0, 0.2)';
    }
    if (this.tone === GlassTone.Success) {
      return 'rgba(74, 222, 128, 0.28)';
    }
    return 'rgba(255, 255, 255, 0.05)';
  }

  private edge(): string {
    if (this.tone === GlassTone.Primary) {
      return 'rgba(255, 255, 255, 0.65)';
    }
    if (this.tone === GlassTone.Strong) {
      return 'rgba(255, 255, 255, 0.38)';
    }
    if (this.tone === GlassTone.Danger) {
      return 'rgba(255, 107, 107, 0.72)';
    }
    if (this.tone === GlassTone.Warn) {
      return 'rgba(245, 196, 81, 0.66)';
    }
    if (this.tone === GlassTone.Info) {
      return 'rgba(127, 176, 255, 0.66)';
    }
    if (this.tone === GlassTone.Violet) {
      return 'rgba(196, 181, 253, 0.55)';
    }
    if (this.tone === GlassTone.Dark) {
      return 'rgba(255, 255, 255, 0.35)';
    }
    if (this.tone === GlassTone.Success) {
      return 'rgba(74, 222, 128, 0.6)';
    }
    return 'rgba(255, 255, 255, 0.16)';
  }

  applyNormalAttribute(instance: ButtonAttribute): void {
    instance
      .type(ButtonType.Normal)
      .backgroundColor(Color.Transparent)
      .linearGradient({
        angle: 135,
        colors: [[this.top(), 0], [this.bottom(), 1]]
      })
      .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
      .border({ width: 1, color: this.edge() })
      // 默认不额外加内边距：原按钮自己的 padding 在链上更靠后会覆盖这里
      .padding(0);
  }
}

/**
 * 官方 `Toggle` 开关的统一外观：选中用 App 的银灰强调色、滑块纯白。
 * 开关的「渐变」由系统滑块动效承担，不再自绘，保证各页面观感一致。
 */
export class GlassSwitchModifier implements AttributeModifier<ToggleAttribute> {
  applyNormalAttribute(instance: ToggleAttribute): void {
    instance
      .selectedColor(Theme.accent)
      .switchPointColor('#ffffff');
  }
}
