/**
 * TV 谁在看页（US7，对齐参考端 Shell/TVAccountViews.swift 的 TVWhoIsWatchingView）：
 * - 深色星空背景 + 大标题「谁在看？」+ 大头像横排：当前账号高亮（页签锚点 tv_tab_anchor 在它身上），
 *   其余压暗，悬浮/获焦放大亮起；按确认切换（切号不联网登录，只换一枚令牌）；
 * - 「＋添加账号」：走欢迎流程的登录表单（当前服务器预选，可返回换服务器）；
 * - 「退出登录」确认弹窗：服务端注销这枚令牌，同服务器还有别的账号会自动切过去；
 * - 底部「关于」入口：版本（bundleManager 读真实值）+ 开源组件 + 数据来源署名（同手机端关于页口径）。
 *
 * 星空背景用系统组件实现（径向渐变 + 定位圆点，固定种子不闪变），不碰 Canvas。
 */
import { bundleManager } from '@kit.AbilityKit';
import { AppModel, AppPhase, SavedAccount } from '../../common/AppModel';
import { ImageUrls } from '../../common/ImageUrls';
import { RemoteImage } from '../../common/RemoteImage';
import { TvFocusable } from '../components/TvFocusable';
import { TvFocus } from '../components/TvFocus';
import { TvTab, TvUiState } from '../model/TvUiState';
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';
import { TvType } from '../theme/TvTheme';

/** 头像直径 */
const AVATAR_SIZE: number = 150;
/** 头像间距（对齐参考端 70 × 0.667） */
const AVATAR_GAP: number = 47;

/** 星空的一颗星（百分比定位 + 尺寸 + 亮度） */
class TvStar {
  readonly xPct: number;
  readonly yPct: number;
  readonly size: number;
  readonly alpha: number;

  constructor(xPct: number, yPct: number, size: number, alpha: number) {
    this.xPct = xPct;
    this.yPct = yPct;
    this.size = size;
    this.alpha = alpha;
  }
}

/** 关于页的一条开源组件 */
class TvOssComponent {
  readonly name: string;
  readonly license: string;
  readonly note: string;

  constructor(name: string, license: string, note: string) {
    this.name = name;
    this.license = license;
    this.note = note;
  }
}

@ComponentV2
export struct TvAccountsPage {
  @Local model: AppModel = AppModel.shared;
  /** 「关于」浮层（开着时主体内容收起，焦点不可达） */
  @Local aboutOpen: boolean = false;
  @Local version: string = '—';
  @Local buildNo: string = '';
  /** 头像横排里谁正被悬浮/聚焦（其余压暗，获焦亮起） */
  @Local focusedKey: string = '';
  private readonly stars: TvStar[] = TvAccountsPage.makeStars();
  private aboutFocusTimer: number = -1;

  aboutToAppear(): void {
    // 返回键分级：浮层开着先收浮层（经 TvUiState.handleBack）
    TvUiState.shared.pageBackHandler = (): boolean => {
      if (this.aboutOpen) {
        this.closeAbout();
        return true;
      }
      return false;
    };
    this.loadVersion();
  }

  aboutToDisappear(): void {
    TvUiState.shared.pageBackHandler = null;
    if (this.aboutFocusTimer >= 0) {
      clearTimeout(this.aboutFocusTimer);
      this.aboutFocusTimer = -1;
    }
  }

  build() {
    Stack() {
      this.Starfield()
      Column({ space: 64 }) {
        Text('谁在看？')
          .fontSize(TvType.welcomeTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(TvColors.text)
        this.Profiles()
        this.Actions()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .visibility(this.aboutOpen ? Visibility.None : Visibility.Visible)

      if (this.aboutOpen) {
        this.AboutScrim()
        this.AboutPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
  }

  /** 深色星空：径向微光打底 + 固定种子的星点（不闪变、不动画，系统组件实现） */
  @Builder
  private Starfield() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['50%', '38%'],
          radius: '80%',
          colors: [['rgba(28, 32, 46, 0.9)', 0], ['rgba(0, 0, 0, 0)', 1]]
        })
      ForEach(this.stars, (star: TvStar, index: number) => {
        Column()
          .width(star.size)
          .height(star.size)
          .borderRadius(star.size / 2)
          .backgroundColor(`rgba(243, 245, 249, ${star.alpha})`)
          .position({ x: `${star.xPct}%`, y: `${star.yPct}%` })
      }, (star: TvStar, index: number) => `${index}`)
    }
    .width('100%')
    .height('100%')
  }

  /** 大头像横排（放不下横向滚动）：本机全部账号 + 「＋添加账号」 */
  @Builder
  private Profiles() {
    List({ space: AVATAR_GAP }) {
      ForEach(this.flatAccounts(), (entry: SavedAccount) => {
        ListItem() {
          this.ProfileTile(entry)
        }
      }, (entry: SavedAccount) => entry.key())
      ListItem() {
        this.AddTile()
      }
    }
    .listDirection(Axis.Horizontal)
    // 宽度贴合内容：整排头像才能在页面里居中（100% 宽会让头像从左边线开始排）；
    // 高度也要定死——横向 List 不定高会吃掉纵向剩余空间，把下面的「关于/退出登录」挤出屏
    .width(this.profilesWidth())
    .height(AVATAR_SIZE + 68)
    .clip(false)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .fadingEdge(false)
  }

  /** 头像排的内容宽：每个头像位 AVATAR_SIZE+44，头像之间 AVATAR_GAP；超出画布则留两端边距 */
  private profilesWidth(): number {
    const count: number = this.flatAccounts().length + 1;
    const tile: number = AVATAR_SIZE + 44;
    const content: number = count * tile + (count - 1) * AVATAR_GAP;
    const max: number = TvMetrics.screenWidth - TvMetrics.edge * 2;
    return content < max ? content : max;
  }

  /** 一个账号：大圆头像（无照片画首字）+ 昵称 + 说明行；当前账号高亮，其余压暗 */
  @Builder
  private ProfileTile(entry: SavedAccount) {
    TvFocusable({
      focusScale: 1.06,
      cornerRadius: AVATAR_SIZE / 2,
      defaultFocused: this.isCurrent(entry),
      focusKey: this.isCurrent(entry) ? 'tv_tab_anchor' : '',
      onActivate: (): void => {
        this.pick(entry);
      },
      onFocusGained: (active: boolean): void => {
        this.focusedKey = active ? entry.key() : '';
      }
    }) {
      Column({ space: 14 }) {
        Stack() {
          Column()
            .width(AVATAR_SIZE)
            .height(AVATAR_SIZE)
            .borderRadius(AVATAR_SIZE / 2)
            .backgroundColor(TvColors.surfaceRaised)
          if (this.avatarUrlOf(entry).length > 0) {
            Stack() {
              RemoteImage({ url: this.avatarUrlOf(entry), placeholderText: '' })
            }
            .width(AVATAR_SIZE)
            .height(AVATAR_SIZE)
            .borderRadius(AVATAR_SIZE / 2)
            .clip(true)
          } else {
            Text(this.initialOf(entry))
              .fontSize(56)
              .fontWeight(600)
              .fontColor('rgba(243, 245, 249, 0.7)')
          }
          if (this.isCurrent(entry)) {
            Column()
              .width(AVATAR_SIZE)
              .height(AVATAR_SIZE)
              .borderRadius(AVATAR_SIZE / 2)
              .border({ width: 3, color: 'rgba(243, 245, 249, 0.85)' })
          }
        }
        .width(AVATAR_SIZE)
        .height(AVATAR_SIZE)

        Text(entry.account.nickname.length > 0 ? entry.account.nickname : entry.account.username)
          .fontSize(TvType.body)
          .fontWeight(this.isCurrent(entry) ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(TvColors.text)
          .maxLines(1)
        Text(this.captionOf(entry))
          .fontSize(TvType.footnote)
          .fontColor(TvColors.textFaint)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Center)
      .width(AVATAR_SIZE + 44)
      .opacity(this.isCurrent(entry) || this.focusedKey === entry.key() ? 1 : 0.6)
    }
  }

  /** 「＋添加账号」：与头像同大小的一块，按确认进欢迎流程的登录表单 */
  @Builder
  private AddTile() {
    TvFocusable({
      focusScale: 1.06,
      cornerRadius: AVATAR_SIZE / 2,
      onActivate: (): void => {
        this.addAccount();
      },
      onFocusGained: (active: boolean): void => {
        this.focusedKey = active ? '__add' : '';
      }
    }) {
      Column({ space: 14 }) {
        Stack() {
          Column()
            .width(AVATAR_SIZE)
            .height(AVATAR_SIZE)
            .borderRadius(AVATAR_SIZE / 2)
            .backgroundColor('rgba(255, 255, 255, 0.08)')
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(52)
            .fontColor([TvColors.textMuted])
        }
        .width(AVATAR_SIZE)
        .height(AVATAR_SIZE)

        Text('添加账号')
          .fontSize(TvType.body)
          .fontColor(TvColors.text)
          .maxLines(1)
        Text(' ')
          .fontSize(TvType.footnote)
      }
      .alignItems(HorizontalAlign.Center)
      .width(AVATAR_SIZE + 44)
      .opacity(this.focusedKey === '__add' ? 1 : 0.75)
    }
  }

  /** 次要操作行：小一号、靠下，不和选人抢视线 */
  @Builder
  private Actions() {
    Row({ space: 44 }) {
      TvFocusable({
        focusScale: 1.05,
        cornerRadius: 999,
        onActivate: (): void => {
          this.openAbout();
        }
      }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(16)
            .fontColor([TvColors.textMuted])
          Text('关于')
            .fontSize(TvType.footnote)
            .fontColor(TvColors.textMuted)
        }
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .backgroundColor(TvColors.glassFill)
        .borderRadius(999)
      }
      TvFocusable({
        focusScale: 1.05,
        cornerRadius: 999,
        onActivate: (): void => {
          this.confirmLogout();
        }
      }) {
        Text('退出登录')
          .fontSize(TvType.footnote)
          .fontColor(TvColors.danger)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .backgroundColor(TvColors.glassFill)
          .borderRadius(999)
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  // MARK: - 「关于」浮层

  @Builder
  private AboutScrim() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0, 0, 0, 0.55)')
      .onClick((): void => {
        this.closeAbout();
      })
  }

  /** 关于浮层：版本 + 开源组件 + 数据来源（同手机端 AboutPage 口径，不照抄 Apple 端清单） */
  @Builder
  private AboutPanel() {
    Column({ space: 20 }) {
      Row() {
        Text('关于 MovieClaw')
          .fontSize(TvType.playerTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(TvColors.text)
          .layoutWeight(1)
        TvFocusable({
          focusScale: 1.05,
          cornerRadius: 999,
          focusKey: 'tv_about_close',
          onActivate: (): void => {
            this.closeAbout();
          }
        }) {
          Text('关闭')
            .fontSize(TvType.footnote)
            .fontColor(TvColors.textMuted)
            .padding({ left: 20, right: 20, top: 9, bottom: 9 })
            .backgroundColor(TvColors.glassFill)
            .borderRadius(999)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 22 }) {
          Text(`版本 ${this.versionText()}`)
            .fontSize(TvType.body)
            .fontColor(TvColors.text)
          Text('MovieClaw 是自托管服务的客户端：你的媒体、账号与观看记录都在你自己部署的服务器上，'
            + 'App 不向开发者或任何第三方上传数据。项目主页：github.com/movieclaw/movieclaw')
            .fontSize(TvType.footnote)
            .fontColor(TvColors.textMuted)
            .lineHeight(24)

          Column({ space: 10 }) {
            Text('开源组件')
              .fontSize(TvType.body)
              .fontWeight(600)
              .fontColor(TvColors.text)
            ForEach(this.ossComponents(), (component: TvOssComponent) => {
              Column({ space: 2 }) {
                Text(component.name)
                  .fontSize(TvType.footnote)
                  .fontColor(TvColors.text)
                Text(component.license)
                  .fontSize(13)
                  .fontColor(TvColors.textMuted)
                if (component.note.length > 0) {
                  Text(component.note)
                    .fontSize(13)
                    .fontColor(TvColors.textFaint)
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }, (component: TvOssComponent) => component.name)
            Text('鸿蒙端是纯 ArkTS 实现，只用系统 Kit 与设计套件，没有随包分发的第三方库。'
              + '播放交给系统 AVPlayer，解码能力以设备为准。')
              .fontSize(13)
              .fontColor(TvColors.textFaint)
              .lineHeight(20)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Column({ space: 8 }) {
            Text('数据来源')
              .fontSize(TvType.body)
              .fontWeight(600)
              .fontColor(TvColors.text)
            Text('影视资料与图片由你的服务器从 TMDB（themoviedb.org）等来源获取。'
              + '本产品使用 TMDB API，但未经 TMDB 认可或认证。')
              .fontSize(TvType.footnote)
              .fontColor(TvColors.textMuted)
              .lineHeight(24)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .fadingEdge(false)
      .align(Alignment.Top)
    }
    .width(760)
    .height(560)
    .padding({ left: 36, right: 36, top: 32, bottom: 28 })
    .borderRadius(24)
    .backgroundColor('rgba(14, 16, 22, 0.95)')
    .border({ width: 1, color: TvColors.line })
  }

  // MARK: - 动作

  /** 选自己回首页；选别人换一枚令牌（切号不联网登录），整树按新账号重建 */
  private pick(entry: SavedAccount): void {
    if (this.isCurrent(entry)) {
      TvUiState.shared.selectTab(TvTab.home);
      return;
    }
    this.resetUi();
    this.model.switchAccount(entry.account.username, entry.server)
      .catch((error: Error): void => {
        this.getUIContext().getPromptAction().showToast({
          message: error.message.length > 0 ? error.message : '切换失败'
        });
        // 令牌失效等：回欢迎页让它重新输密码（账号快照还在，用户名会预填）
        this.model.expiredUsername = entry.account.username;
        this.model.phase = AppPhase.needsLogin;
      });
  }

  private addAccount(): void {
    this.model.expiredUsername = null;
    this.model.phase = AppPhase.needsServer;
  }

  private confirmLogout(): void {
    const nickname: string = this.currentNickname();
    AlertDialog.show({
      title: '退出登录？',
      message: `「${nickname}」在这台电视上的登录会在服务器上一并注销。`
        + '同一台服务器上还有别的账号时会自动切过去。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: TvColors.danger,
        action: (): void => {
          this.logout();
        }
      }
    });
  }

  private async logout(): Promise<void> {
    this.resetUi();
    try {
      await this.model.logout();
    } catch (error) {
      const err = error as Error;
      this.getUIContext().getPromptAction().showToast({
        message: err.message.length > 0 ? err.message : '退出失败'
      });
    }
  }

  /** 换账号/退出前清 TV 侧路由与播放器：旧账号的二级页不带到新账号去 */
  private resetUi(): void {
    const ui: TvUiState = TvUiState.shared;
    ui.routes = [];
    ui.closePlayer();
    ui.railExpanded = false;
  }

  private openAbout(): void {
    this.aboutOpen = true;
    if (this.aboutFocusTimer >= 0) {
      clearTimeout(this.aboutFocusTimer);
    }
    this.aboutFocusTimer = setTimeout((): void => {
      this.aboutFocusTimer = -1;
      TvFocus.request(this.getUIContext(), 'tv_about_close');
    }, 80);
  }

  private closeAbout(): void {
    this.aboutOpen = false;
    if (this.aboutFocusTimer >= 0) {
      clearTimeout(this.aboutFocusTimer);
    }
    this.aboutFocusTimer = setTimeout((): void => {
      this.aboutFocusTimer = -1;
      TvFocus.request(this.getUIContext(), 'tv_tab_anchor');
    }, 60);
  }

  // MARK: - 数据与文案

  private flatAccounts(): SavedAccount[] {
    const out: SavedAccount[] = [];
    for (const saved of this.model.savedServers) {
      for (const account of saved.accounts) {
        out.push(new SavedAccount(saved.address, account));
      }
    }
    return out;
  }

  private isCurrent(entry: SavedAccount): boolean {
    const server = this.model.server;
    const session = this.model.session;
    return server !== null && session !== null
      && server.origin === entry.server.origin
      && session.username === entry.account.username;
  }

  private avatarUrlOf(entry: SavedAccount): string {
    const resolved: string | null = ImageUrls.resolve(
      entry.server.origin, entry.account.avatar_url ?? null, null);
    return resolved ?? '';
  }

  private initialOf(entry: SavedAccount): string {
    const name: string = entry.account.nickname.length > 0
      ? entry.account.nickname : entry.account.username;
    return name.length > 0 ? name.substring(0, 1).toUpperCase() : '?';
  }

  /** 头像下的说明行：当前账号写「正在使用」，跨服务器的写服务器名，其余留空占位 */
  private captionOf(entry: SavedAccount): string {
    if (this.isCurrent(entry)) {
      return '正在使用';
    }
    const server = this.model.server;
    if (server === null || server.origin !== entry.server.origin) {
      return entry.server.hostLabel;
    }
    return ' ';
  }

  private currentNickname(): string {
    const session = this.model.session;
    if (session === null) {
      return '';
    }
    return session.nickname.length > 0 ? session.nickname : session.username;
  }

  /** 读真实版本号（同步接口；两处都拿不到就如实显示「—」，绝不编数） */
  private loadVersion(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.version = info.versionName;
      const code: number = info.versionCode;
      this.buildNo = Number.isFinite(code) ? `${code}` : '';
    } catch (error) {
      this.version = '—';
      this.buildNo = '';
    }
  }

  private versionText(): string {
    return this.buildNo.length > 0 ? `${this.version}（${this.buildNo}）` : this.version;
  }

  /** 开源组件清单（同手机端 AboutPage：如实列本平台依赖，不照抄 Apple 端那份） */
  private ossComponents(): TvOssComponent[] {
    return [
      new TvOssComponent('OpenHarmony / HarmonyOS SDK', 'Apache-2.0',
        '系统能力与 ArkUI 框架，随设备系统提供'),
      new TvOssComponent('HarmonyOS Design 组件', '随 HarmonyOS SDK',
        '原生设计套件控件'),
      new TvOssComponent('思源黑体（HarmonyOS Sans 回退）', 'SIL Open Font License 1.1',
        '随系统提供，App 不分发字体文件')
    ];
  }

  /** 固定种子的星空点（LCG 伪随机：每次进页同一片天，不闪变） */
  private static makeStars(): TvStar[] {
    const out: TvStar[] = [];
    let seed: number = 20261027;
    for (let i: number = 0; i < 90; i++) {
      seed = (seed * 1664525 + 1013904223) % 4294967296;
      const x: number = seed % 10000 / 100;
      seed = (seed * 1664525 + 1013904223) % 4294967296;
      const y: number = seed % 10000 / 100;
      seed = (seed * 1664525 + 1013904223) % 4294967296;
      const size: number = 2 + seed % 3;
      seed = (seed * 1664525 + 1013904223) % 4294967296;
      const alpha: number = 0.12 + seed % 100 / 100 * 0.5;
      out.push(new TvStar(x, y, size, alpha));
    }
    return out;
  }
}
