/**
 * TV 根页面（@Entry）：按 `AppModel.phase` 切 TV 根视图（手机端 `pages/Index` 的 TV 版）。
 *
 * 7 个 phase 的 TV 落点：
 * - launching → 加载态；
 * - unreachable → 「连不上」重试卡（令牌还在，重试即可）；
 * - chooseAccount → TV 账号选择列表（复用 AppModel 账号快照，切号不联网登录）；
 * - needsServer / needsSetup / needsLogin → TvWelcome 欢迎流程（后两者带当前服务器与预填用户名进入）；
 * - ready → TvShell 主外壳（US8 接入）。
 *
 * 返回键统一从 `onBackPress` 进 `TvUiState.handleBack()` 分级（播放器 → 二级页 → 侧边栏 → 退出确认）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { AppModel, AppPhase, SavedAccount } from '../common/AppModel';
import { ServerAddress } from '../common/ServerAddress';
import { TvColors } from './theme/TvTheme';
import { TvType } from './theme/TvTheme';
import { TvMetrics } from './theme/TvTheme';
import { TvFocusable } from './components/TvFocusable';
import { TvUiState } from './model/TvUiState';
import { TvWelcome } from './welcome/TvWelcome';
import { TvShell } from './nav/TvShell';

@Entry
@ComponentV2
struct TvIndex {
  /**
   * V2 关键约束：`@Trace` 字段要经由 `@Local` 持有的 `@ObservedV2` 单例被读才建立订阅，
   * 直接读静态单例不触发重绘（手机端 Index 同款踩坑记录）。
   */
  @Local model: AppModel = AppModel.shared;
  @Local ui: TvUiState = TvUiState.shared;
  /** 退出确认弹窗是否在显示（防返回键重复弹） */
  @Local exitAsking: boolean = false;

  aboutToAppear(): void {
    // TV 侧偏好（墙记忆 / 配对安装标识）先就位
    TvUiState.shared.init(getContext(this));
    // 冷启动：读回本机的服务器与账号快照，再决定落到哪个 phase
    this.model.restore().catch((error: Error): void => {
      hilog.error(0x0000, 'TvBoot', 'restore 抛异常: %{public}s', `${error}`);
      this.model.phase = AppPhase.needsServer;
    });
  }

  /**
   * 返回键分级入口（US8）：
   * 播放器内分级 → 弹二级页 → 首页展开侧边栏 → 侧边栏已展开时出「退出确认」。
   * 欢迎流程等非 ready 阶段交还系统（默认返回行为）。
   */
  onBackPress(): boolean {
    if (this.model.phase !== AppPhase.ready) {
      return false;
    }
    if (!TvUiState.shared.handleBack()) {
      this.confirmExit();
    }
    return true;
  }

  build() {
    Stack() {
      if (this.model.phase === AppPhase.launching) {
        Column({ space: 20 }) {
          LoadingProgress()
            .width(42)
            .height(42)
            .color(TvColors.textMuted)
          Text('MovieClaw')
            .fontSize(TvType.footnote)
            .fontColor(TvColors.textFaint)
        }
      } else if (this.model.phase === AppPhase.unreachable) {
        this.unreachableCard()
      } else if (this.model.phase === AppPhase.chooseAccount) {
        this.accountPicker()
      } else if (this.model.phase === AppPhase.ready) {
        TvShell()
      } else {
        // needsServer / needsSetup / needsLogin 都进欢迎流程；
        // needsLogin/needsSetup 时带着当前服务器与预填用户名直接落到登录表单
        TvWelcome({
          resumeOrigin: this.currentOrigin(),
          resumeUsername: this.model.expiredUsername ?? ''
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
  }

  /** 服务器连不上：令牌还在，恢复后点重试就能进 */
  @Builder
  private unreachableCard(): void {
    Column({ space: 18 }) {
      Text('连不上服务器')
        .fontSize(TvType.heroTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(TvColors.text)
      Text(this.serverLabel())
        .fontSize(TvType.footnote)
        .fontColor(TvColors.textMuted)
      if (this.model.launchError !== null) {
        Text(this.model.launchError)
          .fontSize(TvType.footnote)
          .fontColor(TvColors.textFaint)
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Text('已登录的账号还在这台设备上，服务器恢复后直接重试即可。')
        .fontSize(TvType.footnote)
        .fontColor(TvColors.textFaint)
        .textAlign(TextAlign.Center)
      Row({ space: TvMetrics.cardGap }) {
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.model.reconnect();
          }
        }) {
          Text('重试')
            .fontSize(TvType.body)
            .fontColor(TvColors.text)
            .padding({ left: 32, right: 32, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFillHover)
            .borderRadius(999)
        }
        TvFocusable({
          focusScale: 1.04,
          cornerRadius: 999,
          onActivate: (): void => {
            this.model.phase = AppPhase.needsServer;
          }
        }) {
          Text('换个服务器')
            .fontSize(TvType.body)
            .fontColor(TvColors.textMuted)
            .padding({ left: 28, right: 28, top: 14, bottom: 14 })
            .backgroundColor(TvColors.glassFill)
            .borderRadius(999)
        }
      }
      .margin({ top: 6 })
    }
    .width('100%')
    .height('100%')
    .padding(TvMetrics.edge)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 本机还有别的服务器的账号：列出来让用户挑（chooseAccount）。
   * 点一个就切过去——**切号不联网登录**，本机换一枚令牌即可。
   */
  @Builder
  private accountPicker(): void {
    Column({ space: 14 }) {
      Text('选择账号')
        .fontSize(TvType.welcomeTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(TvColors.text)
      Text('这台设备上登录过的账号')
        .fontSize(TvType.footnote)
        .fontColor(TvColors.textMuted)
      Column({ space: 12 }) {
        ForEach(this.flatAccounts(), (entry: SavedAccount) => {
          TvFocusable({
            focusScale: 1.03,
            cornerRadius: TvMetrics.cardCorner,
            onActivate: (): void => {
              this.switchTo(entry);
            }
          }) {
            Row({ space: 16 }) {
              Text(this.initialOf(entry))
                .fontSize(TvType.body)
                .fontColor(TvColors.text)
                .width(52)
                .height(52)
                .textAlign(TextAlign.Center)
                .backgroundColor(TvColors.surfaceRaised)
                .borderRadius(26)
              Column({ space: 4 }) {
                Text(entry.account.nickname.length > 0 ? entry.account.nickname : entry.account.username)
                  .fontSize(TvType.body)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(TvColors.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(entry.server.hostLabel)
                  .fontSize(TvType.footnote)
                  .fontColor(TvColors.textFaint)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width(480)
            .padding({ left: 18, right: 18, top: 14, bottom: 14 })
            .backgroundColor(TvColors.surfaceRaised)
            .borderRadius(TvMetrics.cardCorner)
          }
        }, (entry: SavedAccount) => entry.key())
      }
      TvFocusable({
        focusScale: 1.04,
        cornerRadius: 999,
        onActivate: (): void => {
          this.model.phase = AppPhase.needsServer;
        }
      }) {
        Text('用其他账号登录')
          .fontSize(TvType.body)
          .fontColor(TvColors.textMuted)
          .padding({ left: 28, right: 28, top: 14, bottom: 14 })
          .backgroundColor(TvColors.glassFill)
          .borderRadius(999)
      }
    }
    .width('100%')
    .height('100%')
    .padding(TvMetrics.edge)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 分级到底（侧边栏已展开再按返回）：退出确认弹窗 */
  private confirmExit(): void {
    if (this.exitAsking) {
      return;
    }
    this.exitAsking = true;
    AlertDialog.show({
      title: '退出 MovieClaw',
      message: '确定要退出应用吗？',
      autoCancel: true,
      onWillDismiss: (): void => {
        this.exitAsking = false;
      },
      primaryButton: {
        value: '取消',
        action: (): void => {
          this.exitAsking = false;
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: TvColors.danger,
        action: (): void => {
          this.exitAsking = false;
          const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
          context.terminateSelf();
        }
      }
    });
  }

  /** 当前服务器的 origin；没有服务器时给空串（TvWelcome 据此走全新发现流程） */
  private currentOrigin(): string {
    const server: ServerAddress | null = AppModel.shared.server;
    return server !== null ? server.origin : '';
  }

  private serverLabel(): string {
    const server: ServerAddress | null = AppModel.shared.server;
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
      // 令牌失效等：提示后回欢迎页让它重新输密码（账号快照还在，用户名会预填）
      this.getUIContext().getPromptAction().showToast({
        message: error.message.length > 0 ? error.message : '切换失败'
      });
      this.model.expiredUsername = entry.account.username;
      this.model.phase = AppPhase.needsLogin;
    });
  }
}
