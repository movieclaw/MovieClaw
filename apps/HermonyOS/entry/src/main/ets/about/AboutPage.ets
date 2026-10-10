import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Theme } from '../theme/AppTheme';
import { AppFooter } from '../common/AppFooter';

/** 一条开源组件 */
class OssComponent {
  readonly name: string;
  readonly license: string;
  readonly note: string;

  constructor(name: string, license: string, note: string = '') {
    this.name = name;
    this.license = license;
    this.note = note;
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function AboutBuilder() {
  AboutPage()
}

/**
 * 关于（对应 iOS `Features/About/AboutView.swift`）。
 *
 * **不照抄 iOS 的组件清单**：iOS 那份列的是 AetherEngine / FFmpeg / Nuke 这些
 * **Apple 端专有**的依赖（`apps/apple/Shared/About/OpenSourceComponent.swift`）。
 * 鸿蒙端是纯 ArkTS、只用系统 Kit 与 HDS 设计套件，**没有随包分发的第三方库**，
 * 所以如实写「无第三方组件」——照抄一份不属于这个平台的清单是错的。
 *
 * 版本号从 `bundleManager` 读真实值，**不写死**（「我的」页那行原先硬编码了「版本 0.1.0」）。
 */
@ComponentV2
export struct AboutPage {
  private navStack: NavPathStack = new NavPathStack();
  @Local private version: string = '—';
  @Local private buildNo: string = '';

  private list: OssComponent[] = [
    new OssComponent('OpenHarmony / HarmonyOS SDK', 'Apache-2.0',
      '系统能力与 ArkUI 框架，随设备系统提供'),
    new OssComponent('HarmonyOS Design（HDS）组件', '随 HarmonyOS SDK',
      '悬浮页签栏、沉浸材质等原生控件'),
    new OssComponent('思源黑体（HarmonyOS Sans 回退）', 'SIL Open Font License 1.1',
      '随系统提供，App 不分发字体文件')
  ];

  /**
   * 读真实版本号（以前「我的」页那行是硬编码的「版本 0.1.0」）。
   *
   * 先试**同步**接口：异步的 `getBundleInfoForSelf` 在这里实测拿不到值
   * （屏幕上一直显示 `—`，而 ArkCompiler 的日志里明明写着 `entry|entry|1.0.0`）。
   * 两个都失败才显示 `—`，**绝不编一个数**。
   */
  private loadVersion(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.version = info.versionName;
      const code: number = info.versionCode;
      this.buildNo = Number.isFinite(code) ? `${code}` : '';
      return;
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(0x0000, 'AboutPage', 'sync failed code=%{public}d msg=%{public}s',
        e.code ?? -1, e.message ?? '');
    }
    // 兜底：`ApplicationInfo` 上没有版本字段（版本在 `BundleInfo` 上），所以这里只能放弃
    this.version = '—';
  }

  private openUrl(url: string): void {
    const context = getContext() as common.UIAbilityContext;
    context.openLink(url).catch((error: BusinessError): void => {
      this.getUIContext().getPromptAction().showToast({ message: `打不开链接（${error.code}）` });
    });
  }

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下会画进状态栏（实测「关于」压住时钟）
        this.TopBar()
        Scroll() {
          Column({ space: 16 }) {
            this.BasicSection()
            this.OssSection()
            this.DataSourceSection()
            AppFooter()
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: Theme.tabBarInset })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    /*
     * **不用原生标题栏**：沉浸式布局下它不避让状态栏，「关于」会和左上角时钟叠在一起
     * （实测 y=17..32vp，状态栏高度约 38vp）。和媒体库详情页同样的修法：自绘顶栏。
     */
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      this.loadVersion();
    })
  }

  /** 自绘顶栏：返回 + 标题，高度把状态栏算进去 */
  @Builder
  TopBar() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([Theme.text])
        .width(38)
        .height(38)
        .onClick(() => {
          this.navStack.pop();
        })
      Text('关于')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Blank()
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: Theme.statusBarInset + 6, bottom: 6 })
  }

  @Builder
  BasicSection() {
    Column({ space: 0 }) {
      this.Line('版本', this.buildNo.length > 0 ? `${this.version}（${this.buildNo}）` : this.version)
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      this.LinkLine('项目主页（开源）', (): void => {
        this.openUrl('https://github.com/movieclaw/movieclaw');
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      this.LinkLine('隐私政策', (): void => {
        this.openUrl('https://github.com/movieclaw/movieclaw/blob/main/docs/privacy-policy.md');
      })
      Divider().color(Theme.line).margin({ left: 16, right: 16 })
      Text('MovieClaw 是自托管服务的客户端：你的媒体、账号与观看记录都在你自己部署的服务器上，'
        + 'App 不向开发者或任何第三方上传数据。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 12 })
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  OssSection() {
    Column({ space: 0 }) {
      Text('开源组件')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
        .padding({ left: 4, bottom: 6 })
      Column({ space: 0 }) {
        ForEach(this.list, (component: OssComponent, index: number) => {
          Column({ space: 0 }) {
            Column({ space: 2 }) {
              Text(component.name)
                .fontSize(15)
                .fontColor(Theme.text)
                .width('100%')
              Text(component.license)
                .fontSize(12)
                .fontColor(Theme.textMuted)
                .width('100%')
              if (component.note.length > 0) {
                Text(component.note)
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 16, right: 16, top: 11, bottom: 11 })
            if (index < this.list.length - 1) {
              Divider().color(Theme.line).margin({ left: 16, right: 16 })
            }
          }
          .width('100%')
        }, (component: OssComponent) => component.name)
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
        Text('鸿蒙端是纯 ArkTS 实现，只用系统 Kit 与 HDS 设计套件，'
          + '没有随包分发的第三方库——所以这里没有 Apple 端那份 AetherEngine / FFmpeg / Nuke 清单。'
          + '播放交给系统 `AVPlayer`，解码能力以设备为准。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 12 })
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
  }

  @Builder
  DataSourceSection() {
    Column({ space: 0 }) {
      Text('数据来源')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
        .padding({ left: 4, bottom: 6 })
      Column({ space: 0 }) {
        /*
         * 用 TMDB 真实 logo（`base/media/TMDB.png`，256×256 原图显示为 20vp）。
         * iOS 这行是系统 SF Symbol `film.stack`——它那边没有品牌图，是拿通用图标凑的；
         * 鸿蒙这边放真实 logo 更贴合「数据来源」这一节的署名意图，不算分叉。
         */
        this.LinkLine('The Movie Database (TMDB)', (): void => {
          this.openUrl('https://www.themoviedb.org');
        }, $r('app.media.TMDB'))
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
        Text('影视资料与图片由你的服务器从 TMDB 等来源获取。'
          + '本产品使用 TMDB API，但未经 TMDB 认可或认证。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 12 })
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
  }

  @Builder
  Line(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontSize(15).fontColor(Theme.text)
      Blank()
      Text(value).fontSize(14).fontColor(Theme.textMuted)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
  }

  /**
   * 一行可点链接。`icon` 是可选的：只有需要品牌标识的行才传（现在只有数据来源的 TMDB）。
   *
   * 图标固定 20vp、`flexShrink(0)`——`Row` 里有 `Blank()`，不给它锁住会被长标题挤变形。
   */
  @Builder
  LinkLine(label: string, onTap: () => void, icon?: Resource) {
    Row({ space: 8 }) {
      if (icon !== undefined) {
        Image(icon)
          .width(20)
          .height(20)
          .borderRadius(4)
          .flexShrink(0)
      }
      Text(label).fontSize(15).fontColor(Theme.accentStrong)
      Blank()
      SymbolGlyph($r('sys.symbol.arrow_up_right'))
        .fontSize(14)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .onClick(() => {
      onTap();
    })
  }
}
