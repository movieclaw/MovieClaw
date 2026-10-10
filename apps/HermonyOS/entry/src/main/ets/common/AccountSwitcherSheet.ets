import { display } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { AppModel, AppPhase } from './AppModel';
import { Permissions } from './Permissions';
import { RemoteImage } from './RemoteImage';
import { ImageUrls } from './ImageUrls';
import { TokenVault } from './TokenVault';
import { SavedServer, SavedServers } from './SavedServers';
import { ServerAddress } from './ServerAddress';
import { AccountView, SessionView } from '../api/Models';


/**
 * 切换账号（对应 iOS `Features/Root/AccountSwitcherSheet.swift`）。
 *
 * 入口两处（同 iOS）：**长按底部头像页签**（半屏抽屉，见 `MainTabsPage`）、个人信息页的「切换账号」。
 * 列出本机登录过的全部账号，**可以跨服务器**：每台服务器一个分组（只有一台时不显示服务器名）。
 * 每个账号在本机是一枚设备令牌，切换就是换用它的令牌。
 *
 * - 点其他账号即切换，不用再输密码；换到另一台服务器上的账号也一样。那个账号的登录已失效时，
 *   走 Index 那套：`expiredUsername` + `phase = needsLogin`，欢迎页预填用户名、只输密码；
 * - 行尾 × 移除（从本机去掉，服务端那台设备也注销）；
 * - 底部「添加账号」进欢迎页（`phase = needsServer`，服务器预填当前这台、可以改，改了就是登录另一台）；
 *   「退出全部账号」退出本机所有服务器上的全部账号。
 *
 * 打开时先用本机快照（`AppModel.savedServers`）立即画出来，**再逐台向服务器刷新**（`refreshAccounts`）：
 * 快照可能已经过时（在别的设备上加/删了账号）。取不到的那台照样列出，标「连不上」。
 */
@ComponentV2
export struct AccountSwitcherSheet {
  @Local private model: AppModel = AppModel.shared;
  /** 切换/移除进行中：列表不再响应（同 iOS `.disabled(busy)`） */
  @Local private busy: boolean = false;
  /** 连不上的服务器（origin） */
  @Local private unreachable: string[] = [];
  /** 正在拉取账号列表的服务器（origin）——快照还没回来时给一行转圈（同 iOS freshness = .loading） */
  @Local private loading: string[] = [];
  /** 本机已没有令牌、点了要重新输密码的账号（key 见 `keyOf`） */
  @Local private expired: string[] = [];

  /** 关掉抽屉（长按头像时松手后落在「我的」，同 iOS） */
  @Require @Param onClose: () => void;

  aboutToAppear(): void {
    this.refreshAll().catch((): void => {
      // 刷新失败不影响展示：本机快照照样列
    });
  }

  // MARK: 数据

  private keyOf(origin: string, username: string): string {
    return `${origin}#${username}`;
  }

  /**
   * 要列出的服务器：有账号的，外加当前服务器（快照还没取回来时也要占个位）；**当前服务器排第一**。
   * 同 iOS `servers`。
   */
  private listedServers(): SavedServer[] {
    const current: string = this.model.server !== null ? this.model.server.origin : '';
    const listed: SavedServer[] = [];
    for (const saved of this.effectiveServers()) {
      if (saved.accounts.length > 0 || saved.address.origin === current) {
        listed.push(saved);
      }
    }
    const first: SavedServer[] = [];
    const rest: SavedServer[] = [];
    for (const saved of listed) {
      if (saved.address.origin === current) {
        first.push(saved);
      } else {
        rest.push(saved);
      }
    }
    return first.concat(rest);
  }

  /**
   * 要列出的服务器：本机快照 + **保证当前会话的那个账号一定在列**。
   *
   * 两种情况下快照里会没有它：① 服务器返回的账号列表不包含这台设备的登录
   * （设备登录/配对进来的会话）；② 快照被清过、或刷新把它冲掉了。
   * 无论哪种，用户自己的当前账号都得看得见——否则列表整块空掉，像坏了。
   */
  private effectiveServers(): SavedServer[] {
    const saved: SavedServer[] = this.model.savedServers;
    const address: ServerAddress | null = this.model.server;
    const session: SessionView | null = this.model.session;
    if (address === null || session === null) {
      return saved;
    }
    const snapshot: SavedServer | null = SavedServers.find(saved, address);
    let hasCurrent: boolean = false;
    if (snapshot !== null) {
      for (const account of snapshot.accounts) {
        if (account.username === session.username) {
          hasCurrent = true;
          break;
        }
      }
    }
    if (hasCurrent) {
      return saved;
    }
    const account: AccountView = SavedServers.snapshot(session.username, session.nickname,
      session.avatar_url ?? null, session.role, true);
    return SavedServers.upserting(saved, address, account, Date.now());
  }

  private multipleServers(): boolean {
    return this.listedServers().length > 1;
  }

  private isUnreachable(saved: SavedServer): boolean {
    return this.unreachable.indexOf(saved.address.origin) >= 0;
  }

  private isLoading(saved: SavedServer): boolean {
    return this.loading.indexOf(saved.address.origin) >= 0;
  }

  private isExpired(saved: SavedServer, account: AccountView): boolean {
    return this.expired.indexOf(this.keyOf(saved.address.origin, account.username)) >= 0;
  }

  private isCurrent(saved: SavedServer, account: AccountView): boolean {
    return this.model.server !== null
      && this.model.server.origin === saved.address.origin
      && this.model.session !== null
      && this.model.session.username === account.username;
  }

  /** 账号行的小头像：头像地址是**那台服务器**上的相对路径，按那台服务器解析（同 iOS 换 `APIClient`） */
  private avatarUrlOf(saved: SavedServer, account: AccountView): string {
    const resolved: string | null = ImageUrls.resolve(saved.address.origin, account.avatar_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  /** 本机账号总数（退出全部的确认文案要用） */
  private accountCount(): number {
    let count: number = 0;
    for (const saved of this.effectiveServers()) {
      count += saved.accounts.length;
    }
    return count;
  }

  private serverCount(): number {
    let count: number = 0;
    for (const saved of this.effectiveServers()) {
      if (saved.accounts.length > 0) {
        count += 1;
      }
    }
    return count;
  }

  // MARK: 刷新

  /**
   * 逐台刷新账号列表：**各台并行**——连不上的那台要等超时，不能拖住其他台（同 iOS `refreshAll`）。
   * 刷完再过一遍本机令牌，标出「登录已失效」的账号。
   */
  private async refreshAll(): Promise<void> {
    const servers: SavedServer[] = this.listedServers();
    const tasks: Promise<string | null>[] = [];
    const pending: string[] = [];
    for (const saved of servers) {
      pending.push(saved.address.origin);
    }
    this.loading = pending;
    for (const saved of servers) {
      tasks.push(this.refreshOne(saved));
    }
    const failed: (string | null)[] = await Promise.all(tasks);
    const out: string[] = [];
    for (const item of failed) {
      if (item !== null) {
        out.push(item);
      }
    }
    this.unreachable = out;
    this.loading = [];
    await this.refreshTokenState();
  }

  /** 刷一台；失败返回它的 origin（列表照样列出，只是标「连不上」） */
  private async refreshOne(saved: SavedServer): Promise<string | null> {
    try {
      await this.model.refreshAccounts(saved.address);
      return null;
    } catch (error) {
      return saved.address.origin;
    }
  }

  private async refreshTokenState(): Promise<void> {
    const out: string[] = [];
    for (const saved of this.model.savedServers) {
      for (const account of saved.accounts) {
        const has: boolean = await TokenVault.has(saved.address.origin, account.username);
        if (!has) {
          out.push(this.keyOf(saved.address.origin, account.username));
        }
      }
    }
    this.expired = out;
  }

  // MARK: 动作

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async switchTo(saved: SavedServer, account: AccountView): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await this.model.switchAccount(account.username, saved.address);
      this.onClose();
    } catch (error) {
      const err = error as Error;
      // 令牌已失效（AppModel 会把它删掉）：回欢迎页预填用户名、只输密码——同 Index.switchTo 的处理
      if (err.message.indexOf('重新输密码') >= 0) {
        this.model.expiredUsername = account.username;
        this.model.phase = AppPhase.needsLogin;
        this.onClose();
        return;
      }
      this.toast(err.message.length > 0 ? err.message : '切换失败');
    }
    this.busy = false;
  }

  private confirmRemove(saved: SavedServer, account: AccountView): void {
    if (this.busy) {
      return;
    }
    const isCurrent: boolean = this.isCurrent(saved, account);
    const message: string = isCurrent
      ? '这是当前账号。退出后本机不再保留它的登录状态，会自动切到其他账号；再回来需要重新输入密码。'
      : '本机将不再保留它的登录状态，再回来需要重新输入密码。账号本身不受影响。';
    this.getUIContext().showAlertDialog({
      title: `退出「${account.nickname}」？`,
      message: message,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: Theme.danger,
        action: (): void => {
          this.remove(saved, account, isCurrent);
        }
      }
    });
  }

  private remove(saved: SavedServer, account: AccountView, isCurrent: boolean): void {
    this.busy = true;
    this.model.removeAccount(account.username, saved.address).then((): void => {
      this.busy = false;
      // 退出的是当前账号时 AppModel 已自动切走，抽屉留着没意义（同 iOS `if isCurrent { dismiss() }`）
      if (isCurrent) {
        this.onClose();
      }
    }).catch((error: Error): void => {
      this.busy = false;
      this.toast(error.message.length > 0 ? error.message : '移除失败，请重试');
    });
  }

  private confirmLogoutEverywhere(): void {
    const count: number = this.accountCount();
    const servers: number = this.serverCount();
    const scope: string = servers > 1
      ? `本机登录过的 ${count} 个账号（${servers} 台服务器）`
      : `本机里的 ${count} 个账号`;
    this.getUIContext().showAlertDialog({
      title: '退出全部账号？',
      message: `${scope}都会退出登录，再回来需要逐个重新输入密码。共用设备时建议这样做。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '全部退出',
        fontColor: Theme.danger,
        action: (): void => {
          this.onClose();
          this.model.logoutEverywhere();
        }
      }
    });
  }

  /** 添加账号：进欢迎页，服务器预填当前这台、可以改（同 iOS `.addAccount(server:)`） */
  private addAccount(): void {
    this.model.expiredUsername = null;
    this.model.phase = AppPhase.needsServer;
    this.onClose();
  }

  // MARK: 视图

  build() {
    /*
     * 自绘卡片（与「批准设备登录」同一套）：自己的标题栏 + 内容，
     * 圆角与底色由外层 `openCustomDialog` 给（`backgroundColor: Theme.surfaceRaised` + `cornerRadius`）。
     * **不再套 ArkUI 高级组件 `CustomContentDialogV2`**：它的面板底色（#2b2d30）和弹窗背景不是一层，
     * 底部会露出一条颜色不一致的窄边。
     */
    Column({ space: 0 }) {
      this.TitleBar()
      this.DialogBody()
    }
    .width('100%')
  }

  /** 标题栏：标题 + 关闭（同 iOS 的导航栏「切换账号 / 关闭」） */
  @Builder
  TitleBar() {
    Row() {
      Text('切换账号')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Blank()
      Text('关闭')
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .padding({ left: 12, right: 4, top: 8, bottom: 8 })
        .onClick(() => {
          this.onClose();
        })
    }
    .width('100%')
    .padding({ left: 20, right: 12, top: 10, bottom: 0 })
  }

  /** 正文：说明一行 + 服务器分组 + 底部动作（三套样式共用） */
  @Builder
  DialogBody() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.accountCount() > 0) {
          Text('本机已登录的账号，点击即可切换，不用再输密码。')
            .fontSize(13)
            .fontColor(Theme.textFaint)
            .width('100%')
            .padding({ left: 4, right: 4 })
        }
        ForEach(this.listedServers(), (saved: SavedServer) => {
          this.ServerGroup(saved)
        }, (saved: SavedServer) => saved.address.origin)
        this.Actions()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 24 })
    }
    .width('100%')
    // 高度跟随内容（账号少就矮、多就高），到屏幕 60% 封顶后内部滚动
    .constraintSize({ maxHeight: this.listMaxHeight() })
    .scrollBar(BarState.Off)
  }

  /** 列表高度上限：屏幕的 60%（vp）——弹窗高度因此随账号多少自适应，又不会顶满屏 */
  private listMaxHeight(): number {
    const screenVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().height);
    return Math.round(screenVp * 0.6);
  }

  @Builder
  ServerGroup(saved: SavedServer) {
    Column({ space: 8 }) {
      // 这台还没取回账号（快照里也没有）：转圈占位，别让用户以为没有账号（同 iOS `freshness == .loading`）
      if (saved.accounts.length === 0 && this.isLoading(saved)) {
        Row() {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(Theme.textMuted)
        }
        .width('100%')
        .height(56)
        .justifyContent(FlexAlign.Center)
      }
      if (this.multipleServers()) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.externaldrive'))
            .fontSize(12)
            .fontColor([Theme.textMuted])
          Text(saved.address.hostLabel)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textMuted)
          if (this.isUnreachable(saved)) {
            Text('· 连不上')
              .fontSize(12)
              .fontColor(Theme.warn)
          }
        }
        .width('100%')
        .padding({ left: 4 })
      }
      Column({ space: 0 }) {
        ForEach(saved.accounts, (account: AccountView, index: number) => {
          Column() {
            this.AccountRow(saved, account)
            if (index < saved.accounts.length - 1) {
              Divider().color(Theme.line).margin({ left: 62, right: 16 })
            }
          }
        }, (account: AccountView) => account.username)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
  }

  /**
   * 账号行：头像 40 + 昵称 + @用户名·角色 + （失效时）重新输密码提示 + （当前）✓ 当前 + 行尾 ×。
   * 同 iOS：当前账号**可点但不切换**（不置灰，Web 当前行是高亮而不是禁用色）。
   */
  @Builder
  AccountRow(saved: SavedServer, account: AccountView) {
    this.ClassicAccountRow(saved, account)
  }

  @Builder
  ClassicAccountRow(saved: SavedServer, account: AccountView) {
    Row({ space: 12 }) {
      Row({ space: 12 }) {
        Stack() {
          Text(Permissions.initialsOf(account.nickname))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('rgba(0, 0, 0, 0.75)')
          if (this.avatarUrlOf(saved, account).length > 0) {
            RemoteImage({
              url: this.avatarUrlOf(saved, account),
              placeholderSymbol: $r('sys.symbol.person_crop_circle_fill')
            })
              .width(40)
              .height(40)
              .borderRadius(20)
              .clip(true)
          }
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(Theme.accent2)
        .alignContent(Alignment.Center)

        Column({ space: 2 }) {
          Text(account.nickname.length > 0 ? account.nickname : account.username)
            .fontSize(15)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 角色标签口径同 `Permissions.roleLabel`（那边的入参是 SessionView，这里只有 AccountView）
          Text(`@${account.username} · ${account.role === 'admin' ? '超级管理员' : '成员'}`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!this.isCurrent(saved, account) && this.isExpired(saved, account)) {
            Text('登录已失效，点一下重新输入密码')
              .fontSize(12)
              .fontColor(Theme.warn)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.isCurrent(saved, account)) {
          Row({ space: 3 }) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(11)
              .fontColor([Theme.accent])
            Text('当前')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.accent)
          }
        }
      }
      .layoutWeight(1)
      .onClick(() => {
        if (!this.isCurrent(saved, account)) {
          this.switchTo(saved, account);
        }
      })

      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(13)
        .fontColor([Theme.textFaint])
        .width(28)
        .height(28)
        .onClick(() => {
          this.confirmRemove(saved, account);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 10, top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
  }

  /** 底部：添加账号 / 退出全部账号（同 iOS 最后一组 + footer 说明） */
  @Builder
  Actions() {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(16)
          .fontColor([Theme.accentStrong])
          .width(24)
        Text('添加账号')
          .fontSize(15)
          .fontColor(Theme.accentStrong)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 13, bottom: 13 })
      .onClick(() => {
        this.addAccount();
      })

      Divider().color(Theme.line).margin({ left: 16, right: 16 })

      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.arrow_right'))
          .fontSize(16)
          .fontColor([Theme.danger])
          .width(24)
        Text('退出全部账号')
          .fontSize(15)
          .fontColor(Theme.danger)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 13, bottom: 13 })
      .onClick(() => {
        this.confirmLogoutEverywhere();
      })

      Text('添加账号时改一下服务器地址，就能登录到另一台 MovieClaw。')
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
}
