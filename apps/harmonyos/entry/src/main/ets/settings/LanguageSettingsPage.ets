import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { Theme } from '../theme/AppTheme';
import { AppNavBar } from '../common/AppNavBar';
import { AppLanguage, LanguageCode, languageName } from '../common/AppLanguage';

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function LanguageSettingsBuilder() {
  LanguageSettingsPage()
}

/**
 * 设置 → 语言（对应 iOS LanguageSettings 的三选一交互；iOS 是跳系统设置，
 * 鸿蒙这边做应用内切换：三行单选，点了当场生效）。
 *
 * 文案用各语言自称（autonym，语言数据不走词条表），标题走词条表——这一页
 * 也是「切语言当场重建」的最小验证场。
 */
@ComponentV2
export struct LanguageSettingsPage {
  private scroller: Scroller = new Scroller();
  /** 单例：切语言改它，本页与所有读 t() 的页面一起重建 */
  @Local private appLanguage: AppLanguage = AppLanguage.shared();

  build() {
    HdsNavDestination() {
      Scroll(this.scroller) {
        Column({ space: 14 }) {
          Column({ space: 0 }) {
            this.LanguageRow(LanguageCode.zhHans)
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
            this.LanguageRow(LanguageCode.zhHant)
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
            this.LanguageRow(LanguageCode.en)
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: AppNavBar.contentTop + 8, bottom: Theme.tabBarInset })
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar(AppNavBar.subPageTitleBar(this.appLanguage.t('settings.language.title')))
    .bindToScrollable([this.scroller])
    .dynamicHideTitleBar(AppNavBar.dynamicHide())
  }

  /** 一行语言：自称 + 当前语言的勾（同播放引擎卡的行样式） */
  @Builder
  LanguageRow(code: string) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(languageName(code)).fontSize(15).fontColor(Theme.text)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.appLanguage.language === code) {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([Theme.accent])
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(16)
    .onClick((): void => {
      this.appLanguage.setLanguage(code);
    })
  }
}
