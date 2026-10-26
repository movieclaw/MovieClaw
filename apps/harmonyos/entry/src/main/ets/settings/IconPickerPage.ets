import { appInfoManager } from '@kit.AppGalleryKit';
import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppFooter } from '../common/AppFooter';
import { AppIconStore, DesktopIcons, DesktopIconState, appLogoResource } from '../common/AppIcon';

/** 应用内图标网格里的一个候选 */
class IconOption {
  /** AppIconStore 的序号；-1 = 默认图标 */
  readonly index: number;
  readonly label: string;

  constructor(index: number, label: string) {
    this.index = index;
    this.label = label;
  }
}

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function IconPickerBuilder() {
  IconPickerPage()
}

/**
 * 图标更换（设置 → 图标）。
 *
 * 两节分开选：
 * - **桌面图标**：AppGallery Kit「图标管理服务」（`appInfoManager`，5.0.3(15) 起）——
 *   候选项从 `queryDynamicIcons()` 拿（AGC 后台上传的动态图标），点选调
 *   `selectDynamicIcon` / `disableDynamicIcon` 真正换掉桌面图标。
 *   硬前提：真机（服务不支持模拟器）+ AGC 后台已为本应用配置动态图标，
 *   不满足时这一节降级成原因说明。
 * - **应用内图标**：默认图标 + 26 款 logo 设计稿，选择存本地偏好，
 *   应用在应用内的展示位（「关于」页 logo）。
 */
@ComponentV2
export struct IconPickerPage {
  private navStack: NavPathStack = new NavPathStack();
  @Local private selected: number = -1;
  @Local private desktop: DesktopIconState = new DesktopIconState();
  @Local private desktopLoaded: boolean = false;
  private desktopBusy: boolean = false;

  private options: IconOption[] = [
    new IconOption(-1, '默认'),
    new IconOption(0, '设计 01'),
    new IconOption(1, '设计 02'),
    new IconOption(2, '设计 03'),
    new IconOption(3, '设计 04'),
    new IconOption(4, '设计 05'),
    new IconOption(5, '设计 06'),
    new IconOption(6, '设计 07'),
    new IconOption(7, '设计 08'),
    new IconOption(8, '设计 09'),
    new IconOption(9, '设计 10'),
    new IconOption(10, '设计 11'),
    new IconOption(11, '设计 12'),
    new IconOption(12, '设计 13'),
    new IconOption(13, '设计 14'),
    new IconOption(14, '设计 15'),
    new IconOption(15, '设计 16'),
    new IconOption(16, '设计 17'),
    new IconOption(17, '设计 18'),
    new IconOption(18, '设计 19'),
    new IconOption(19, '设计 20'),
    new IconOption(20, '设计 21'),
    new IconOption(21, '设计 22'),
    new IconOption(22, '设计 23'),
    new IconOption(23, '设计 24'),
    new IconOption(24, '设计 25'),
    new IconOption(25, '设计 26')
  ];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    await AppIconStore.load();
    this.selected = AppIconStore.selected;
    this.desktop = await DesktopIcons.query();
    this.desktopLoaded = true;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async pick(option: IconOption): Promise<void> {
    this.selected = option.index;
    await AppIconStore.set(option.index);
    this.toast(`已选择「${option.label}」`);
  }

  /** 桌面图标是否在用默认（没有哪个动态图标处于启用态就是默认） */
  private desktopDefaultActive(): boolean {
    for (const icon of this.desktop.icons) {
      if (icon.enabled) {
        return false;
      }
    }
    return true;
  }

  private async pickDesktop(icon: appInfoManager.DynamicIconInfo): Promise<void> {
    if (this.desktopBusy || icon.enabled) {
      return;
    }
    this.desktopBusy = true;
    const ok: boolean = await DesktopIcons.select(icon.iconId);
    this.desktopBusy = false;
    if (!ok) {
      this.toast('桌面图标切换失败（正在使用主题图标时换不了），请稍后再试');
      return;
    }
    this.toast('桌面图标已切换');
    this.desktop = await DesktopIcons.query();
  }

  private async restoreDesktop(): Promise<void> {
    if (this.desktopBusy || this.desktopDefaultActive()) {
      return;
    }
    this.desktopBusy = true;
    const ok: boolean = await DesktopIcons.restoreDefault();
    this.desktopBusy = false;
    if (!ok) {
      this.toast('恢复默认失败，请稍后再试');
      return;
    }
    this.toast('桌面图标已恢复默认');
    this.desktop = await DesktopIcons.query();
  }

  build() {
    NavDestination() {
      Column() {
        PageTopBar({ title: '图标', onBack: (): void => {
          this.navStack.pop();
        }})
        // —— 桌面图标：真换桌面图标的这一节（AGC 图标管理服务）——
        Column({ space: 10 }) {
          Text('桌面图标')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .width('100%')
          if (!this.desktopLoaded) {
            Row({ space: 8 }) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color(Theme.textFaint)
              Text('正在查询可用的动态图标…')
                .fontSize(12)
                .fontColor(Theme.textFaint)
            }
          } else if (this.desktop.available) {
            Scroll() {
              Row({ space: 12 }) {
                this.DesktopDefaultTile()
                ForEach(this.desktop.icons, (icon: appInfoManager.DynamicIconInfo, index: number) => {
                  this.DesktopIconTile(icon, index)
                }, (icon: appInfoManager.DynamicIconInfo) => icon.iconId)
              }
              .padding({ bottom: 2 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
            .align(Alignment.Start)
          } else {
            Text(this.desktop.message)
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(14)
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
        .margin({ left: 16, right: 16, top: 8 })

        // —— 应用内图标 ——
        Text('应用内图标')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .width('100%')
          .padding({ left: 16, top: 16 })
        Text('用在「关于」页等应用内的图标展示位')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 16 })

        Grid() {
          ForEach(this.options, (option: IconOption) => {
            GridItem() {
              this.IconCell(option)
            }
          }, (option: IconOption) => `opt-${option.index}`)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(14)
        .rowsGap(16)
        .padding({ left: 16, right: 16, top: 14, bottom: 16 })
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        AppFooter({ topSpace: 0 })
          .padding({ left: 16, right: 16, bottom: Theme.tabBarInset })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg'))
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
    })
  }

  /** 桌面图标候选：恢复默认（startIcon） */
  @Builder
  DesktopDefaultTile() {
    Column({ space: 7 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Image($r('app.media.startIcon'))
          .width(72)
          .height(72)
          .borderRadius(17)
          .border({
            width: this.desktopDefaultActive() ? 2.5 : 0.5,
            color: this.desktopDefaultActive() ? Theme.accent : 'transparent'
          })
          .clip(true)
        if (this.desktopDefaultActive()) {
          Stack() {
            Circle({ width: 21, height: 21 }).fill(Theme.accent)
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(12)
              .fontColor(['#ffffff'])
          }
          .offset({ x: 5, y: -5 })
        }
      }
      .width(72)
      .height(72)

      Text('默认')
        .fontSize(11)
        .fontColor(this.desktopDefaultActive() ? Theme.accent : Theme.textMuted)
        .maxLines(1)
    }
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.restoreDesktop();
    })
  }

  /** 桌面图标候选：一个 AGC 动态图标（iconUrl 由后台配置，选中调 selectDynamicIcon） */
  @Builder
  DesktopIconTile(icon: appInfoManager.DynamicIconInfo, index: number) {
    Column({ space: 7 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Image(icon.iconUrl)
          .width(72)
          .height(72)
          .borderRadius(17)
          .border({
            width: icon.enabled ? 2.5 : 0.5,
            color: icon.enabled ? Theme.accent : 'transparent'
          })
          .clip(true)
          .alt($r('app.media.startIcon'))
        if (icon.enabled) {
          Stack() {
            Circle({ width: 21, height: 21 }).fill(Theme.accent)
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(12)
              .fontColor(['#ffffff'])
          }
          .offset({ x: 5, y: -5 })
        }
      }
      .width(72)
      .height(72)

      Text(`图标 ${index + 1}`)
        .fontSize(11)
        .fontColor(icon.enabled ? Theme.accent : Theme.textMuted)
        .maxLines(1)
    }
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.pickDesktop(icon);
    })
  }

  /** 应用内图标候选格子：圆角图标 + 底下名字；选中的描一圈强调色并打勾 */
  @Builder
  IconCell(option: IconOption) {
    Column({ space: 7 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Image(appLogoResource(option.index))
          .width(78)
          .height(78)
          .borderRadius(19)
          .border({
            width: this.selected === option.index ? 2.5 : 0.5,
            color: this.selected === option.index ? Theme.accent : 'transparent'
          })
          .clip(true)
        if (this.selected === option.index) {
          Stack() {
            Circle({ width: 21, height: 21 }).fill(Theme.accent)
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(12)
              .fontColor(['#ffffff'])
          }
          .offset({ x: 5, y: -5 })
        }
      }
      .width(78)
      .height(78)

      Text(option.label)
        .fontSize(11)
        .fontColor(this.selected === option.index ? Theme.accent : Theme.textMuted)
        .maxLines(1)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.pick(option);
    })
  }
}
