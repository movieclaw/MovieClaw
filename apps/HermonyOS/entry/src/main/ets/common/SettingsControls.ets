import { Theme } from '../theme/AppTheme';

/**
 * 设置页里反复用到的小控件，做成 **V2 组件**（不是 `@Builder`）。
 *
 * **为什么必须是组件**：ArkUI 的 `@Builder` 传参默认**按值传递**——参数变化不会触发 UI 刷新，
 * 于是「点一下换成另一个选项」这类控件点完高亮不动（实测踩过：设备页的范围分段、成员页的
 * 「完全权限 / 仅限转码」分段、各处开关）。`@ComponentV2` 的 `@Param` 是响应式的，能正常跟着状态走。
 *
 * 三个控件都只做「展示 + 回调」，不持有状态：状态仍由页面自己管（单向数据流，页面是唯一事实源）。
 */

/** 一格分段（iOS `.pickerStyle(.segmented)` 的一格）：选中＝强调底 + 深色字 */
@ComponentV2
export struct SettingsSegmentChip {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Event onPick: () => void = (): void => {
  };

  build() {
    Text(this.label)
      .fontSize(14)
      .fontColor(this.selected ? '#0b0d12' : Theme.textMuted)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .padding({ top: 7 })
      .backgroundColor(this.selected ? Theme.accent : Color.Transparent)
      .borderRadius(Theme.cardRadius - 2)
      .onClick((): void => {
        this.onPick();
      })
  }
}

/** 两格分段（全部 / 指定 这类二选一） */
@ComponentV2
export struct SettingsTwoStateSegment {
  @Param leftLabel: string = '';
  @Param rightLabel: string = '';
  /** true = 左边选中 */
  @Param leftSelected: boolean = true;
  @Event onPick: (left: boolean) => void = (left: boolean): void => {
  };

  build() {
    Row() {
      SettingsSegmentChip({
        label: this.leftLabel,
        selected: this.leftSelected,
        onPick: (): void => {
          this.onPick(true);
        }
      })
      SettingsSegmentChip({
        label: this.rightLabel,
        selected: !this.leftSelected,
        onPick: (): void => {
          this.onPick(false);
        }
      })
    }
    .width('100%')
    .padding(3)
    .backgroundColor(Theme.glassFill)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }
}

/** 设置行开关：左标题 + 说明，右开关（`value` 由页面持有，开关只回调） */
@ComponentV2
export struct SettingsSwitchRow {
  @Param title: string = '';
  @Param hint: string = '';
  @Param value: boolean = false;
  @Param disabled: boolean = false;
  @Event onToggle: (on: boolean) => void = (on: boolean): void => {
  };

  build() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(15)
          .fontColor(this.disabled ? Theme.textFaint : Theme.text)
          .width('100%')
          .textAlign(TextAlign.Start)
        if (this.hint.length > 0) {
          Text(this.hint)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .selectedColor(Theme.accent)
        .enabled(!this.disabled)
        .onChange((isOn: boolean): void => {
          this.onToggle(isOn);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
  }
}
