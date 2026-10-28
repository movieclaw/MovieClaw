/**
 * 车机账号页（T021，US8）：轻量账号面板（不做 TV 端「谁在看」头像墙）。
 *
 * - 当前账号卡：头像（无照片画首字）+ 昵称 + 用户名 · 服务器 +「正在使用」；
 * - 已保存账号列表切换（复用 AppModel.switchAccount——切号不联网登录，只换一枚令牌）；
 *   「添加账号」进欢迎流程的登录表单；
 * - 退出登录确认弹窗（AlertDialog）：服务端注销这枚令牌，同服务器还有别的账号自动切过去；
 * - 「关于」折叠区：版本（bundleManager 读真实值）+ 自托管说明与开源许可口径（同手机端关于页）；
 * - 换号/退出前清车机侧路由、播放器与引擎：旧账号的页面与会话不带到新账号去
 *   （引擎收尾必须显式 CarPlayback.end()——车机收起播放器引擎是存活的）。
 */
import { bundleManager } from '@kit.AbilityKit';
import { AppModel, AppPhase, SavedAccount } from '../../common/AppModel';
import { ImageUrls } from '../../common/ImageUrls';
import { RemoteImage } from '../../common/RemoteImage';
import { CarColors } from '../theme/CarTheme';
import { CarMetrics } from '../theme/CarTheme';
import { CarType } from '../theme/CarTheme';
import { CarUiState } from '../model/CarUiState';
import { CarPlayback } from '../player/CarAvPlayerEngine';
import { CarPressable } from '../components/CarCards';

@ComponentV2
export struct CarAccountPage {
  @Local model: AppModel = AppModel.shared;
  /** 「关于」折叠区展开 */
  @Local aboutOpen: boolean = false;
  @Local version: string = '—';
  @Local buildNo: string = '';

  aboutToAppear(): void {
    // 返回键分级（经 CarUiState.handleBack）：关于区开着先收起
    CarUiState.shared.pageBackHandler = (): boolean => {
      if (this.aboutOpen) {
        this.aboutOpen = false;
        return true;
      }
      return false;
    };
    this.loadVersion();
  }

  aboutToDisappear(): void {
    CarUiState.shared.pageBackHandler = null;
  }

  build() {
    Scroll() {
      Column({ space: 26 }) {
        Text('账号')
          .fontSize(CarType.heroTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(CarColors.text)
        this.currentCard()
        this.savedSection()
        this.logoutButton()
        this.aboutSection()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: CarMetrics.edge, right: CarMetrics.edge, top: 30, bottom: 40 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .fadingEdge(false)
    .align(Alignment.Top)
    .backgroundColor(CarColors.bg)
  }

  // MARK: - 当前账号卡

  @Builder
  private currentCard(): void {
    Row({ space: 22 }) {
      Stack() {
        if (this.currentAvatar().length > 0) {
          Stack() {
            RemoteImage({ url: this.currentAvatar(), placeholderText: '' })
          }
          .width(88)
          .height(88)
          .borderRadius(44)
          .clip(true)
        } else {
          Text(this.currentInitial())
            .fontSize(40)
            .fontWeight(FontWeight.Medium)
            .fontColor(CarColors.textMuted)
        }
      }
      .width(88)
      .height(88)
      .borderRadius(44)
      .backgroundColor(CarColors.surfaceRaised)

      Column({ space: 6 }) {
        Text(this.currentNickname())
          .fontSize(CarType.rowTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(CarColors.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.currentMetaLine())
          .fontSize(CarType.footnote)
          .fontColor(CarColors.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('正在使用')
        .fontSize(CarType.footnote)
        .fontColor(CarColors.accent)
        .padding({ left: 20, right: 20, top: 8, bottom: 8 })
        .backgroundColor(CarColors.accentSoft)
        .borderRadius(999)
    }
    .width('100%')
    .padding(26)
    .backgroundColor(CarColors.surface)
    .borderRadius(CarMetrics.cardCorner)
    .border({ width: 1, color: CarColors.line })
    .alignItems(VerticalAlign.Center)
  }

  // MARK: - 已保存账号

  @Builder
  private savedSection(): void {
    Column({ space: 14 }) {
      Text('已保存账号')
        .fontSize(CarType.rowTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(CarColors.text)
      if (this.otherAccounts().length === 0) {
        Text('没有其他已保存账号，可点下方「添加账号」。')
          .fontSize(CarType.footnote)
          .fontColor(CarColors.textMuted)
      } else {
        ForEach(this.otherAccounts(), (entry: SavedAccount) => {
          this.accountRow(entry)
        }, (entry: SavedAccount) => entry.key())
      }
      this.addAccountRow()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 一个已保存账号行（触控目标 ≥48vp，本例 64）：头像 + 名称/服务器 + 「切换」 */
  @Builder
  private accountRow(entry: SavedAccount): void {
    CarPressable({
      onActivate: (): void => {
        this.pick(entry);
      }
    }) {
      Row({ space: 16 }) {
        Stack() {
          if (this.avatarOf(entry).length > 0) {
            Stack() {
              RemoteImage({ url: this.avatarOf(entry), placeholderText: '' })
            }
            .width(48)
            .height(48)
            .borderRadius(24)
            .clip(true)
          } else {
            Text(this.initialOf(entry))
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .fontColor(CarColors.textMuted)
          }
        }
        .width(48)
        .height(48)
        .borderRadius(24)
        .backgroundColor(CarColors.surfaceRaised)

        Column({ space: 3 }) {
          Text(entry.account.nickname.length > 0 ? entry.account.nickname : entry.account.username)
            .fontSize(CarType.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(CarColors.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.captionOf(entry))
            .fontSize(CarType.footnote)
            .fontColor(CarColors.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('切换')
          .fontSize(CarType.body)
          .fontColor(CarColors.accent)
      }
      .width('100%')
      .constraintSize({ minHeight: 64 })
      .padding({ left: 20, right: 24 })
      .backgroundColor(CarColors.surface)
      .borderRadius(CarMetrics.cardCorner)
      .border({ width: 1, color: CarColors.line })
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 「＋添加账号」：进欢迎流程的登录表单（当前服务器预选，可返回换服务器） */
  @Builder
  private addAccountRow(): void {
    CarPressable({
      onActivate: (): void => {
        this.addAccount();
      }
    }) {
      Row({ space: 14 }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(22)
          .fontColor([CarColors.textMuted])
        Text('添加账号')
          .fontSize(CarType.body)
          .fontColor(CarColors.textMuted)
        Blank()
      }
      .width('100%')
      .constraintSize({ minHeight: 64 })
      .padding({ left: 22, right: 24 })
      .backgroundColor(Color.Transparent)
      .borderRadius(CarMetrics.cardCorner)
      .border({ width: 1, color: CarColors.lineStrong })
      .alignItems(VerticalAlign.Center)
    }
  }

  // MARK: - 退出登录

  @Builder
  private logoutButton(): void {
    CarPressable({
      onActivate: (): void => {
        this.confirmLogout();
      }
    }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.person_xmark'))
          .fontSize(20)
          .fontColor([CarColors.warn])
        Text('退出登录')
          .fontSize(CarType.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(CarColors.warn)
      }
      .width('100%')
      .constraintSize({ minHeight: CarMetrics.minTouch })
      .justifyContent(FlexAlign.Center)
      .backgroundColor(CarColors.surface)
      .borderRadius(CarMetrics.cardCorner)
      .border({ width: 1, color: CarColors.line })
      .alignItems(VerticalAlign.Center)
    }
  }

  // MARK: - 关于（折叠区）

  @Builder
  private aboutSection(): void {
    Column() {
      CarPressable({
        onActivate: (): void => {
          this.aboutOpen = !this.aboutOpen;
        }
      }) {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(22)
            .fontColor([CarColors.textMuted])
          Text('关于 MovieClaw')
            .fontSize(CarType.body)
            .fontColor(CarColors.text)
          Blank()
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(18)
            .fontColor([CarColors.textMuted])
            .rotate({ angle: this.aboutOpen ? 180 : 0 })
        }
        .width('100%')
        .constraintSize({ minHeight: CarMetrics.minTouch })
        .alignItems(VerticalAlign.Center)
      }

      if (this.aboutOpen) {
        Column({ space: 14 }) {
          Text(`版本 ${this.versionText()}`)
            .fontSize(CarType.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(CarColors.text)
          Text('MovieClaw 是自托管服务的客户端：你的媒体、账号与观看记录都在你自己部署的服务器上，'
            + 'App 不向开发者或任何第三方上传数据。项目主页：github.com/movieclaw/movieclaw')
            .fontSize(CarType.footnote)
            .fontColor(CarColors.textMuted)
            .lineHeight(24)
          Text('鸿蒙端是纯 ArkTS 实现，只用系统 Kit 与设计套件，没有随包分发的第三方库；'
            + '播放交给系统 AVPlayer，解码能力以设备为准。影视资料与图片由你的服务器从 '
            + 'TMDB（themoviedb.org）等来源获取；本产品使用 TMDB API，但未经 TMDB 认可或认证。')
            .fontSize(CarType.footnote)
            .fontColor(CarColors.textFaint)
            .lineHeight(22)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 34, right: 12, top: 4, bottom: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 动作

  /** 切换账号（切号不联网登录，只换一枚令牌），整树按新账号重建 */
  private pick(entry: SavedAccount): void {
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
    AlertDialog.show({
      title: '退出登录？',
      message: `「${this.currentNickname()}」在这台车机上的登录会在服务器上一并注销。`
        + '同一台服务器上还有别的账号时会自动切过去。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: CarColors.warn,
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

  /** 换账号/退出前清车机侧路由与播放器：旧账号的二级页、引擎与播控条不带到新账号去 */
  private resetUi(): void {
    const ui: CarUiState = CarUiState.shared;
    ui.routes = [];
    ui.closePlayer();
    CarPlayback.end();
  }

  // MARK: - 数据与文案

  /** 本机全部账号（跨服务器拍平） */
  private flatAccounts(): SavedAccount[] {
    const out: SavedAccount[] = [];
    for (const saved of this.model.savedServers) {
      for (const account of saved.accounts) {
        out.push(new SavedAccount(saved.address, account));
      }
    }
    return out;
  }

  /** 除当前账号外的已保存账号 */
  private otherAccounts(): SavedAccount[] {
    const out: SavedAccount[] = [];
    for (const entry of this.flatAccounts()) {
      if (!this.isCurrent(entry)) {
        out.push(entry);
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

  private avatarOf(entry: SavedAccount): string {
    const resolved: string | null = ImageUrls.resolve(
      entry.server.origin, entry.account.avatar_url ?? null, null);
    return resolved ?? '';
  }

  private currentAvatar(): string {
    const server = this.model.server;
    const session = this.model.session;
    if (server === null || session === null) {
      return '';
    }
    const resolved: string | null = ImageUrls.resolve(
      server.origin, session.avatar_url ?? null, null);
    return resolved ?? '';
  }

  private initialOf(entry: SavedAccount): string {
    const name: string = entry.account.nickname.length > 0
      ? entry.account.nickname : entry.account.username;
    return name.length > 0 ? name.substring(0, 1).toUpperCase() : '?';
  }

  private currentInitial(): string {
    const nickname: string = this.currentNickname();
    const session = this.model.session;
    const name: string = nickname.length > 0 ? nickname : (session !== null ? session.username : '');
    return name.length > 0 ? name.substring(0, 1).toUpperCase() : '?';
  }

  private currentNickname(): string {
    const session = this.model.session;
    if (session === null) {
      return '';
    }
    return session.nickname.length > 0 ? session.nickname : session.username;
  }

  /** 当前账号卡说明行：「用户名 · 服务器」 */
  private currentMetaLine(): string {
    const session = this.model.session;
    const server = this.model.server;
    const username: string = session !== null ? session.username : '';
    const host: string = server !== null ? server.hostLabel : '';
    if (username.length === 0) {
      return host;
    }
    return host.length === 0 ? username : `${username} · ${host}`;
  }

  /** 已保存账号行说明行：跨服务器写服务器名，同服务器留空占位 */
  private captionOf(entry: SavedAccount): string {
    const server = this.model.server;
    if (server === null || server.origin !== entry.server.origin) {
      return entry.server.hostLabel;
    }
    return ' ';
  }

  /** 读真实版本号（同步接口；拿不到就如实显示「—」，绝不编数） */
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
}
