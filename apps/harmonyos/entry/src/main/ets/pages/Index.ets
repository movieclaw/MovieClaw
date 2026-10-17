import { hilog } from '@kit.PerformanceAnalysisKit';
import { Theme } from '../theme/AppTheme';
import { AppModel, AppPhase, SavedAccount } from '../common/AppModel';
import { WelcomePage } from './WelcomePage';
import { MainTabsPage } from './MainTabsPage';

/**
 * 应用入口（对应 iOS 端 `RootView` 的职责）：按 `AppModel.phase` 切页。
 *
 * 7 个 phase 与 iOS 一一对应——`launching` 出加载、`unreachable` 出「连不上」重试卡、
 * `needsServer`/`needsSetup`/`needsLogin` 进欢迎页（后两者分别预填用户名、走建管理员流程）、
 * `chooseAccount` 出账号列表、`ready` 进主界面。
 *
 * **状态管理 V2**：本组件是 `@ComponentV2`，直接读 `AppModel.shared` 上的 `@Trace` 字段，
 * phase 一变自动重绘——不再需要 `kickToWelcome` 这种回调把状态手工搬进 `@State`。
 */
@Entry
@ComponentV2
struct Index {
  /**
   * 用 `@Local` **持有**这个 `@ObservedV2` 单例。
   *
   * 这是 V2 的关键约束：`@Trace` 字段要经由 `@Local`/`@Param` 持有的对象被读到才会建立订阅；
   * 直接读一个静态单例（哪怕是 `@ObservedV2`）**不会**触发重绘——实测踩过：
   * `phase` 已经是 `ready` 了，界面还停在启动转圈上。
   */
  @Local private model: AppModel = AppModel.shared;

  aboutToAppear(): void {
    // 冷启动：读回本机的服务器与账号快照，再决定落到哪个 phase
    this.model.restore().catch((error: Error): void => {
      hilog.error(0x0000, 'Boot', 'restore 抛异常: %{public}s', `${error}`);
      // 兜底：不能让启动流程把界面永远留在转圈上
      this.model.phase = AppPhase.needsServer;
    });
  }

  build() {
    Stack() {
      if (this.model.phase === AppPhase.launching) {
        LoadingProgress()
          .width(36)
          .height(36)
          .color(Theme.textMuted)
      } else if (this.model.phase === AppPhase.unreachable) {
        this.UnreachableCard()
      } else if (this.model.phase === AppPhase.chooseAccount) {
        this.AccountPicker()
      } else if (this.model.phase === AppPhase.ready) {
        MainTabsPage()
      } else {
        // needsServer / needsSetup / needsLogin 都进欢迎页
        WelcomePage({
          openFormFirst: this.model.phase === AppPhase.needsLogin,
          prefillServer: this.serverLabel(),
          prefillUsername: this.model.expiredUsername ?? ''
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  /** 服务器连不上：令牌还在，恢复后点重试就能进（对应 iOS 的 unreachable 卡片） */
  @Builder
  UnreachableCard() {
    Column({ space: 14 }) {
      Text('连不上服务器')
        .fontSize(19)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(this.serverLabel())
        .fontSize(15)
        .fontColor(Theme.textMuted)
      if (this.model.launchError !== null) {
        Text(this.model.launchError)
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .textAlign(TextAlign.Center)
      }
      Text('已登录的账号还在这台设备上，服务器恢复后直接重试即可。')
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .textAlign(TextAlign.Center)
      Row({ space: 12 }) {
        Text('重试')
          .fontSize(15)
          .fontWeight(600)
          .fontColor('#0b0d12')
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .backgroundColor(Theme.accent)
          .borderRadius(20)
          .onClick(() => {
            this.model.reconnect();
          })
        Text('换个服务器')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(20)
          .border({ width: 1, color: Theme.lineStrong })
          .onClick(() => {
            this.model.phase = AppPhase.needsServer;
          })
      }
      .margin({ top: 6 })
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 本机还有别的服务器的账号：列出来让用户挑（对应 iOS 的 chooseAccount）。
   * 点一个就切过去——**切号不联网登录**，本机换一枚令牌即可。
   */
  @Builder
  AccountPicker() {
    Column({ space: 10 }) {
      Text('选择账号')
        .fontSize(24)
        .fontWeight(600)
        .fontColor(Theme.text)
        .margin({ bottom: 6 })
      Text('这台设备上登录过的账号')
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .margin({ bottom: 10 })
      ForEach(this.flatAccounts(), (entry: SavedAccount) => {
        Row({ space: 12 }) {
          Text(this.initialOf(entry))
            .fontSize(18)
            .fontColor(Theme.text)
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .backgroundColor(Theme.surface)
            .borderRadius(20)
          Column({ space: 3 }) {
            Text(entry.account.nickname.length > 0 ? entry.account.nickname : entry.account.username)
              .fontSize(16)
              .fontColor(Theme.text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(entry.server.hostLabel)
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(14)
        .onClick(() => {
          this.switchTo(entry);
        })
      }, (entry: SavedAccount) => entry.key())
      Text('用其他账号登录')
        .fontSize(14)
        .fontColor(Theme.accentStrong)
        .margin({ top: 10 })
        .onClick(() => {
          this.model.phase = AppPhase.needsServer;
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
  }

  /** 当前服务器的展示地址（@Builder 里不能声明局部变量，抽成方法） */
  private serverLabel(): string {
    const server = AppModel.shared.server;
    return server !== null ? server.displayString : '';
  }

  private flatAccounts(): SavedAccount[] {
    const out: SavedAccount[] = [];
    for (const saved of this.model.savedServers) {
      for (const account of saved.accounts) {
        out.push(new SavedAccount(saved.address, account));
      }
    }
    return out;
  }

  private initialOf(entry: SavedAccount): string {
    const name: string = entry.account.nickname.length > 0 ? entry.account.nickname : entry.account.username;
    return name.length > 0 ? name.substring(0, 1).toUpperCase() : '?';
  }

  private switchTo(entry: SavedAccount): void {
    this.model.switchAccount(entry.account.username, entry.server).catch((error: Error): void => {
      // 令牌失效等：回欢迎页让它重新输密码（账号快照还在，用户名会预填）
      this.getUIContext().getPromptAction().showToast({
        message: error.message.length > 0 ? error.message : '切换失败'
      });
      this.model.expiredUsername = entry.account.username;
      this.model.phase = AppPhase.needsLogin;
    });
  }
}
