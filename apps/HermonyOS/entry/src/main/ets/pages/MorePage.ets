import { display, promptAction } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { DeviceApprovalDialog } from '../settings/DeviceApprovalDialog';
import { AppModel, AppPhase, SavedAccount } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { AppFooter } from '../common/AppFooter';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import { noticeVisible } from '../notices/NoticeCenterPage';
import { NoticeView } from '../api/Models';
import { MovieClawApi } from '../api/Endpoints';
import { SessionSummary, SessionTranscriptView } from '../api/Models';
import { ChatParams } from '../agent/ChatPage';
import { AgentSessionsSignal } from '../agent/AgentSessionsSignal';

/**
 * 「更多」页（对应 iOS 端 MorePage）：当前账号、本机账号列表（切换/添加/移除）、
 * 服务器信息、设置入口、退出登录 / 退出全部账号。
 *
 * **状态管理 V2**：`@Local` 持有 `AppModel` 单例，直接读它的 `@Trace` 字段
 * （`session` / `savedServers`），账号一变列表自己就更新。
 */
@ComponentV2
export struct MorePage {
  /** 由 MoreNavHost 注入 */
  @Require @Param navStack: NavPathStack;
  /** 宿主工具栏点「扫码」时加一（动作在本页） */
  @Param scanSignal: number = 0;
  @Local private model: AppModel = AppModel.shared;
  /** 待处理事项数（对应 iOS MorePage 提醒组的「待处理」行；管理员、有事才出现） */
  @Local private noticeCount: number = 0;
  private noticeTimer: number = -1;

  // 最近会话（仅管理员，同 iOS MorePage 的「最近会话」组）
  @Local private sessions: SessionSummary[] = [];
  /** 还有更早的会话没取回（上一页取满了一整页） */
  @Local private hasMoreSessions: boolean = false;
  @Local private loadingMoreSessions: boolean = false;
  /** 重命名弹层 */
  @Local private showRename: boolean = false;
  @Local private renameDraft: string = '';
  @Local private renameTargetId: string = '';
  /** 会话列表每页条数（同 Web agent-conversations 的 PAGE_SIZE） */
  private static readonly SESSION_PAGE: number = 20;
  /** 会话集合变化的信号：会话页新建 / 离开时 bump，「最近会话」跟着重拉（本页是压在上面的整屏页回来时不重建） */
  @Local private sessionsSignal: AgentSessionsSignal = AgentSessionsSignal.shared;
  /** 扫码批准的弹窗句柄（顶栏右上角的扫码钮） */
  @Local private approvalDialogId: number = -1;

  @Monitor('sessionsSignal.version')
  private onSessionsChanged(): void {
    this.loadSessions();
  }

  aboutToAppear(): void {
    this.loadNotices();
    this.loadSessions();
    // 与 Web NoticeCenter 同频 30 秒轮询（同 iOS MorePage 的 .polling(every: 30)）
    this.noticeTimer = setInterval((): void => {
      this.loadNotices();
    }, 30000);
  }

  aboutToDisappear(): void {
    if (this.noticeTimer >= 0) {
      clearInterval(this.noticeTimer);
      this.noticeTimer = -1;
    }
  }

  private isAdmin(): boolean {
    return Permissions.fromSession(this.model.session).isAdmin;
  }

  private async loadNotices(): Promise<void> {
    const api: MovieClawApi | null = this.model.api;
    if (api === null || !this.isAdmin()) {
      return;
    }
    // 拉取失败保留上次结果，下一轮自愈（同 iOS）
    try {
      const list: NoticeView[] = await api.noticesList();
      this.noticeCount = noticeVisible(list).length;
    } catch (error) {
      // 忽略：下轮自愈
    }
  }

  // MARK: 最近会话（对应 iOS MorePage 的 sessions 组）

  /** 会话在列表里的标题：标题 → 最近一条用户消息 → 「未命名会话」（同 iOS `title(of:)`） */
  private sessionTitle(item: SessionSummary): string {
    const title: string | null = item.title ?? null;
    if (title !== null && title.length > 0) {
      return title;
    }
    const prompt: string | null = item.last_prompt ?? null;
    if (prompt !== null && prompt.length > 0) {
      return prompt;
    }
    return '未命名会话';
  }

  private lastSessionId(): string {
    return this.sessions.length > 0 ? this.sessions[this.sessions.length - 1].id : '';
  }

  /** 取第一页（进页时）；失败保留上次结果 */
  private async loadSessions(): Promise<void> {
    const api: MovieClawApi | null = this.model.api;
    if (api === null || !this.isAdmin()) {
      return;
    }
    try {
      const first: SessionSummary[] = await api.sessionList(MorePage.SESSION_PAGE);
      this.sessions = first;
      this.hasMoreSessions = first.length >= MorePage.SESSION_PAGE;
    } catch (error) {
      // 同上：失败保留上次结果
    }
  }

  /** 接着取下一页；按 id 去重（翻页期间有新会话插到最前，偏移会错开一条） */
  private async loadMoreSessions(): Promise<void> {
    const api: MovieClawApi | null = this.model.api;
    if (api === null || !this.hasMoreSessions || this.loadingMoreSessions) {
      return;
    }
    this.loadingMoreSessions = true;
    try {
      const page: SessionSummary[] = await api.sessionList(MorePage.SESSION_PAGE, this.sessions.length);
      const known: string[] = [];
      for (const item of this.sessions) {
        known.push(item.id);
      }
      const merged: SessionSummary[] = this.sessions.slice();
      for (const item of page) {
        if (known.indexOf(item.id) < 0) {
          merged.push(item);
        }
      }
      this.sessions = merged;
      this.hasMoreSessions = page.length >= MorePage.SESSION_PAGE;
    } catch (error) {
      this.hasMoreSessions = false;
    } finally {
      this.loadingMoreSessions = false;
    }
  }

  private openSession(item: SessionSummary): void {
    this.navStack.pushPathByName('chat', new ChatParams(item.id));
  }

  /** 在新会话中继续：带上这段对话的上下文开一个新会话（同 iOS `fork`） */
  private forkSession(item: SessionSummary): void {
    this.getUIContext().showAlertDialog({
      title: `在新会话中继续「${this.sessionTitle(item)}」？`,
      message: '会带上这段对话的上下文开一个新会话接着聊，原会话保留不变。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '创建新会话',
        action: (): void => {
          this.performFork(item);
        }
      }
    });
  }

  private async performFork(item: SessionSummary): Promise<void> {
    const api: MovieClawApi | null = this.model.api;
    if (api === null) {
      return;
    }
    try {
      const forked: SessionTranscriptView = await api.sessionFork(item.id);
      this.navStack.pushPathByName('chat', new ChatParams(forked.session.id));
    } catch (error) {
      this.toast('创建续接会话失败，请重试');
    }
  }

  private openRename(item: SessionSummary): void {
    this.renameTargetId = item.id;
    this.renameDraft = this.sessionTitle(item);
    this.showRename = true;
  }

  /** 重命名：去空白、截 80 字，没变化就不发请求（同 Web / iOS） */
  private async saveRename(): Promise<void> {
    const api: MovieClawApi | null = this.model.api;
    const target: string = this.renameTargetId;
    const name: string = this.renameDraft.trim().substring(0, 80);
    this.showRename = false;
    if (api === null || target.length === 0 || name.length === 0) {
      return;
    }
    try {
      const updated: SessionSummary = await api.sessionRename(target, { title: name });
      const next: SessionSummary[] = [];
      for (const item of this.sessions) {
        next.push(item.id === target ? updated : item);
      }
      this.sessions = next;
    } catch (error) {
      this.toast('重命名失败，请重试');
    }
  }

  private confirmDeleteSession(item: SessionSummary): void {
    this.getUIContext().showAlertDialog({
      title: `彻底删除会话「${this.sessionTitle(item)}」？`,
      message: '服务器上的完整对话记录将一并删除，此操作不可恢复。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '彻底删除',
        fontColor: Theme.danger,
        action: (): void => {
          this.performDeleteSession(item);
        }
      }
    });
  }

  private async performDeleteSession(item: SessionSummary): Promise<void> {
    const api: MovieClawApi | null = this.model.api;
    if (api === null) {
      return;
    }
    try {
      await api.sessionDelete(item.id);
      const next: SessionSummary[] = [];
      for (const row of this.sessions) {
        if (row.id !== item.id) {
          next.push(row);
        }
      }
      this.sessions = next;
    } catch (error) {
      this.toast('删除失败，请重试');
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // MARK: 派生

  private nickname(): string {
    const session = this.model.session;
    return session === null ? '未登录' : session.nickname;
  }

  /**
   * 当前账号的头像完整 URL；没上传过头像返回空串。
   *
   * 对应 iOS `AvatarBadge` 里的 `api.image(avatarUrl ?? session?.avatarUrl, width:)`。
   * **算法必须与底栏 `MainTabsPage.avatarUrl()` 完全一致**——差一点就会出现
   * 「底栏有头像、点进我的页反而变成首字」这种越点越退化的观感。
   */
  private avatarUrl(): string {
    const session = this.model.session;
    if (session === null) {
      return '';
    }
    // origin 走 AppModel.origin()：项目统一的那一处，不在本页再抄一份
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), session.avatar_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  private subtitle(): string {
    const session = this.model.session;
    if (session === null) {
      return '';
    }
    return `${session.username} · ${Permissions.roleLabel(session)}`;
  }

  private hostLabel(): string {
    const server = this.model.server;
    return server === null ? '未连接' : server.hostLabel;
  }

  /** 本机所有账号（跨服务器），当前账号排在由数据本身决定、这里只做标记 */
  private allAccounts(): SavedAccount[] {
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
    if (server === null || session === null) {
      return false;
    }
    return entry.server.origin === server.origin && entry.account.username === session.username;
  }


  private accountCount(): number {
    return this.allAccounts().length;
  }

  // MARK: 动作






  // MARK: 顶栏（自绘：标题与右上角按钮同一行，且整体让开状态栏）

  /** 有没有搜索入口：管理员或任一搜索能力（同 iOS `SearchAccess.canOpenSearch`） */
  private showSearch(): boolean {
    const permissions: Permissions = Permissions.fromSession(this.model.session);
    return permissions.isAdmin || permissions.canSearch || permissions.canDirectDownload;
  }

  @Monitor('scanSignal')
  onScanSignal(): void {
    if (this.scanSignal > 0) {
      this.openScanApproval();
    }
  }

  private openScanApproval(): void {
    const screenWidthVp: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    const options: promptAction.CustomDialogOptions = {
      builder: (): void => {
        this.ApprovalCard();
      },
      width: Math.round(screenWidthVp - 32),
      alignment: DialogAlignment.Bottom,
      keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
      autoCancel: true,
      maskColor: 'rgba(0, 0, 0, 0.6)',
      backgroundColor: Theme.surfaceRaised,
      cornerRadius: Theme.cardRadius
    };
    this.getUIContext().getPromptAction().openCustomDialog(options)
      .then((id: number): void => {
        this.approvalDialogId = id;
      })
      .catch((): void => {
        this.approvalDialogId = -1;
      });
  }

  private closeApproval(): void {
    if (this.approvalDialogId < 0) {
      return;
    }
    this.getUIContext().getPromptAction().closeCustomDialog(this.approvalDialogId);
    this.approvalDialogId = -1;
  }

  @Builder
  ApprovalCard() {
    DeviceApprovalDialog({
      scanFirst: true,
      onClose: (): void => {
        this.closeApproval();
      }
    })
  }


  // MARK: 视图

  build() {
    Column() {
      // 页面结构对齐 iOS MorePage 的 List + Section：账户卡、服务器设置各自一组圆角容器；
      // 用 `List`（不是 Scroll+Column）是因为「最近会话」的行要用**原生左滑操作**（`swipeAction` 只在 ListItem 上）。
      // **顶栏也放进 List 的第一项**：这样整页是一个滚动体——在哪一段都能拖动滚动，
      // 顶部标题与右上角按钮随内容滚走（同 iOS 大标题的手感）。
      List({ space: 12 }) {
        ListItem() {
          this.AccountCard()
        }
        if (this.noticeCount > 0) {
          ListItem() {
            this.NoticeRow()
          }
        }
        ListItem() {
          this.ServerCard()
        }
        if (this.isAdmin()) {
          this.SessionsGroup()
        }
        // 页脚：品牌联合声明，复用全局 AppFooter
        ListItem() {
          AppFooter()
        }
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      // 内容不够一屏时也给点回弹反馈（不然会觉得「不能滑」）
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: 16, right: 16, top: 0, bottom: Theme.tabBarInset })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    .bindSheet($$this.showRename, this.RenameSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 「最近会话」组（仅管理员，同 iOS MorePage）：新会话 + 会话行（左滑续接 / 重命名 / 删除） */
  @Builder
  SessionsGroup() {
    ListItemGroup({ header: this.SessionsHeader() }) {
      ListItem() {
        this.NewSessionRow()
      }
      if (this.sessions.length === 0) {
        ListItem() {
          Text('还没有会话，点上方的「新会话」开始。')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 14 })
        }
      }
      ForEach(this.sessions, (item: SessionSummary) => {
        ListItem() {
          this.SessionRow(item)
        }
        .swipeAction({ end: this.SessionSwipe(item), edgeEffect: SwipeEdgeEffect.None })
        .bindContextMenu(this.SessionMenu(item), ResponseType.LongPress)
        .onAppear(() => {
          // 滑到（或建到）最后一条时接着取下一页（同 iOS 的 `.onAppear` 翻页）
          if (item.id === this.lastSessionId()) {
            this.loadMoreSessions();
          }
        })
      }, (item: SessionSummary) => item.id)
      if (this.loadingMoreSessions) {
        ListItem() {
          Row() {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(Theme.textMuted)
          }
          .width('100%')
          .height(52)
          .justifyContent(FlexAlign.Center)
        }
      }
    }
    .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 16, endMargin: 16 })
    .borderRadius(Theme.cardRadius)
    .backgroundColor(Theme.surface)
    .border({ width: 1, color: Theme.line })
  }

  @Builder
  SessionsHeader() {
    Text('最近会话')
      .fontSize(13)
      .fontColor(Theme.textFaint)
      .width('100%')
      .padding({ left: 4, top: 12, bottom: 6 })
  }

  @Builder
  NewSessionRow() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(18)
        .fontColor([Theme.accentStrong])
        .width(24)
      Text('新会话')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.accentStrong)
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .onClick(() => {
      this.navStack.pushPathByName('chat', new ChatParams(''));
    })
  }

  /** 运行中会话的小蓝点（同 iOS `MoreRunningDot`：信息蓝 + 呼吸） */
  @Builder
  RunningDot() {
    Circle()
      .width(7)
      .height(7)
      .fill(Theme.accent)
  }

  @Builder
  SessionRow(item: SessionSummary) {
    Row({ space: 10 }) {
      if (item.running) {
        this.RunningDot()
      }
      Text(this.sessionTitle(item))
        .fontSize(16)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 默认断行规则把「微信 · o9cq801…@im.wechat」这种长串英文名当一个整词，
        // 一个词放不下就整段丢掉、只剩「微信 · …」。BREAK_ALL = 先尽量填满整行，再在末尾省略。
        .wordBreak(WordBreak.BREAK_ALL)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openSession(item);
    })
  }

  /** 左滑出来的三个图标按钮：续接 / 重命名 / 删除（顺序同 iOS，图标都用系统符号） */
  @Builder
  SessionSwipe(item: SessionSummary) {
    Row() {
      this.SwipeIcon($r('sys.symbol.arrowshape_3_triangle_path'), Theme.accentStrong, (): void => {
        this.forkSession(item);
      })
      this.SwipeIcon($r('sys.symbol.square_and_pencil'), Theme.textMuted, (): void => {
        this.openRename(item);
      })
      this.SwipeIcon($r('sys.symbol.trash'), Theme.danger, (): void => {
        this.confirmDeleteSession(item);
      })
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SwipeIcon(icon: Resource, tint: string, action: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([tint])
    }
    .width(64)
    .height('100%')
    .backgroundColor(Theme.surfaceRaised)
    .onClick(action)
  }

  /** 长按菜单：与左滑同三项、同顺序（同 iOS `contextMenu`） */
  @Builder
  SessionMenu(item: SessionSummary) {
    Menu() {
      MenuItem({ content: '在新会话中继续', startIcon: $r('sys.symbol.arrowshape_3_triangle_path') })
        .onClick(() => {
          this.forkSession(item);
        })
      MenuItem({ content: '重命名', startIcon: $r('sys.symbol.square_and_pencil') })
        .onClick(() => {
          this.openRename(item);
        })
      MenuItem({ content: '删除会话', startIcon: $r('sys.symbol.trash') })
        .contentFontColor(Theme.danger)
        .onClick(() => {
          this.confirmDeleteSession(item);
        })
    }
  }

  /** 重命名弹层（原生弹窗里放一个输入框） */
  @Builder
  RenameSheet() {
    Column({ space: 14 }) {
      Text('重命名会话')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16 })
      TextInput({ text: this.renameDraft, placeholder: '会话标题（最多 80 字）' })
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .maxLength(80)
        .onChange((value: string): void => {
          this.renameDraft = value.length > 80 ? value.substring(0, 80) : value;
        })
      Row({ space: 10 }) {
        Text('取消')
          .fontSize(16)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick(() => {
            this.showRename = false;
          })
        Text('保存')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.accent)
          .borderRadius(Theme.cardRadius)
          .onClick(() => {
            this.saveRename();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
    .backgroundColor(Theme.bg)
  }

  /**
   * 提醒组（对应 iOS MorePage 的「待处理」行）：仅管理员、有事才出现（同 iOS 设置 App
   * 账户卡下的「有可用更新」那一组）。bell 图标 + 危险色 + 红底计数胶囊，点击进通知中心。
   */
  @Builder
  NoticeRow() {
    Row({ space: 14 }) {
      SymbolGlyph($r('sys.symbol.bell'))
        .fontSize(20)
        .fontColor([Theme.danger])
        .width(28)
      Text('待处理')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.danger)
        .layoutWeight(1)
      Text(`${this.noticeCount}`)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#ffffff')
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor(Theme.danger)
        .borderRadius(9)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .onClick(() => {
      this.navStack.pushPathByName('notices', null);
    })
  }

  /** 当前账号卡：头像徽标 + 昵称 + 用户名/角色；点一下展开账号管理 */
  @Builder
  AccountCard() {
    Row({ space: 16 }) {
      Stack() {
        // 底层：渐变圆 + 昵称首字。iOS `AvatarBadge` 同款，也是「没设头像」或「图还没下来」时的样子
        Text(this.model.session !== null ? Permissions.initialsOf(this.nickname()) : '?')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('rgba(0, 0, 0, 0.75)')
        // 上层：有头像就盖上去（iOS 是 `if url != nil { RemoteImage(url:...) }`，这里同义）。
        // 不叠在底层之上的话，上传过头像的账号永远只看到首字——与 iOS 行为不一致。
        if (this.avatarUrl().length > 0) {
          RemoteImage({
            url: this.avatarUrl(),
            placeholderSymbol: $r('sys.symbol.person_crop_circle_fill')
          })
            .width(56)
            .height(56)
            .borderRadius(28)
            .clip(true)
        }
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .linearGradient({
        angle: 180,
        colors: [[Theme.accentStrong, 0], [Theme.accent2, 1]]
      })
      .alignContent(Alignment.Center)

      Column({ space: 4 }) {
        Text(this.nickname())
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitle())
          .fontSize(13)
          .fontColor(Theme.textMuted)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Theme.surface)
    .borderRadius(18)
    .border({ width: 1, color: Theme.line })
    .onClick(() => {
      this.navStack.pushPathByName('profile', null);
    })
  }


  /**
   * 服务器设置行（对应 iOS MorePage 的「服务器设置」Section）：
   * gearshape 图标 + 标题 + **当前服务器地址副标题**（回答「改的是哪台」），点击进设置首页。
   * 是 iOS 那种带副标题的一行，不是不可点卡片。
   */
  @Builder
  ServerCard() {
    Row({ space: 14 }) {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(20)
        .fontColor([Theme.accent2])
        .width(28)
      Column({ space: 2 }) {
        Text('服务器设置')
          .fontSize(15)
          .fontColor(Theme.text)
        Text(this.hostLabel())
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([Theme.textFaint])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .onClick(() => {
      this.navStack.pushPathByName('settings', null);
    })
  }
}
