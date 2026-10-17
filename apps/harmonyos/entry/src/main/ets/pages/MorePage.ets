import { display, promptAction } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { DeviceApprovalDialog } from '../settings/DeviceApprovalDialog';
import { AppModel, AppPhase, SavedAccount } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import { Formatters } from '../common/Formatters';
import { noticeVisible } from '../notices/NoticeCenterPage';
import { NoticeView } from '../api/Models';
import { MovieClawApi } from '../api/Endpoints';
import { SessionSummary, SessionTranscriptView } from '../api/Models';
import { ChatParams } from '../agent/ChatPage';
import { AGENT_QUICK_CONTENT_EXTRA } from '../agent/AgentQuickInput';
import { AgentSessionsSignal } from '../agent/AgentSessionsSignal';
import { OfflineStore } from '../offline/OfflineStore';
import {
  OfflineCapacityCard,
  OfflineDownloadedSection,
  OfflineDownloadingSection,
  OfflineOtherOwnersSection,
  OfflineWatchedCard
} from '../offline/OfflineStoragePage';

/**
 * 「我的」页（对应 iOS 端 MorePage 重构版）：居中个人信息 + 会话 / 下载 / 服务器胶囊切换。
 * 会话保持单行标题、时间、分页、左滑和长按操作；下载管理直接内嵌在页签中（复用
 * OfflineStoragePage 的五个分区组件）；服务器段是当前服务器地址卡 + 服务器设置行 +
 * 管理员的「待处理」瓷砖；有待处理时胶囊上打红点。旧版的「新会话」行不再保留
 * （同 iOS：新会话改由页底的快捷输入进入）。
 *
 * **状态管理 V2**：`@Local` 持有 `AppModel` / `OfflineStore` 单例，直接读它们的
 * `@Trace` 字段，账号、下载一变页面自己就更新。
 */

/** 「我的」页的三个胶囊段（同 iOS MorePageSection） */
enum MoreSection {
  conversations,
  downloads,
  server
}

/** 会话按用户当地自然日分组（同 iOS MoreConversationPeriod）：跨午夜不按固定 24 小时倒推 */
enum MorePeriod {
  today,
  yesterday,
  earlier
}

@ComponentV2
export struct MorePage {
  /** 由 MoreNavHost 注入 */
  @Require @Param navStack: NavPathStack;
  /** 宿主工具栏点「扫码」时加一（动作在本页） */
  @Param scanSignal: number = 0;
  @Local private model: AppModel = AppModel.shared;
  /** 待处理事项数（管理员；服务器段的「待处理」瓷砖与胶囊红点用） */
  @Local private noticeCount: number = 0;
  private noticeTimer: number = -1;
  /** 当前选中的胶囊段；不在可用列表里时回退到第一个可用段 */
  @Local private selectedSection: MoreSection = MoreSection.conversations;

  // 最近会话（仅管理员，同 iOS MorePage 的会话段）
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
  /** 会话集合变化的信号：会话页新建 / 离开时 bump，会话列表跟着重拉（本页是压在上面的整屏页回来时不重建） */
  @Local private sessionsSignal: AgentSessionsSignal = AgentSessionsSignal.shared;
  /** 扫码批准的弹窗句柄（顶栏右上角的扫码钮） */
  @Local private approvalDialogId: number = -1;
  /** 本机下载（下载段可见性、内嵌分区用） */
  @Local private store: OfflineStore = OfflineStore.shared;

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

  // MARK: 会话数据（对应 iOS MorePage 的 sessions 段）

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

  /** 账户卡的身份小字：昵称和用户名不同时带上「@用户名」（相同就不重复），再带角色（同 iOS `identityLine`） */
  private identityLine(): string {
    const session = this.model.session;
    if (session === null) {
      return '';
    }
    return session.nickname !== session.username
      ? `@${session.username} · ${Permissions.roleLabel(session)}`
      : Permissions.roleLabel(session);
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

  // MARK: 胶囊段（同 iOS MorePageSection.available）

  /** 只有当前账号可用的内容才进入切换栏；旧服务器没有下载能力时也不显示空入口 */
  private availableSections(): MoreSection[] {
    const out: MoreSection[] = [];
    const permissions: Permissions = Permissions.fromSession(this.model.session);
    // 鸿蒙没有 ServerReachability：拿「已登录」近似 iOS 的 !isOffline
    const online: boolean = this.model.api !== null;
    if (permissions.isAdmin && online) {
      out.push(MoreSection.conversations);
    }
    if (permissions.canDownloadVideo || this.store.items.size > 0) {
      out.push(MoreSection.downloads);
    }
    if (online) {
      out.push(MoreSection.server);
    }
    return out;
  }

  /** 选中的段不在可用列表里时回退到第一个可用段（同 iOS `visibleSection`） */
  private visibleSection(): MoreSection {
    const sections: MoreSection[] = this.availableSections();
    for (const section of sections) {
      if (section === this.selectedSection) {
        return section;
      }
    }
    return sections.length > 0 ? sections[0] : MoreSection.server;
  }

  private sectionTitle(section: MoreSection): string {
    if (section === MoreSection.conversations) {
      return '会话';
    }
    if (section === MoreSection.downloads) {
      return '下载';
    }
    return '服务器';
  }

  private sectionIcon(section: MoreSection): Resource {
    if (section === MoreSection.conversations) {
      return $r('sys.symbol.message_on_message');
    }
    if (section === MoreSection.downloads) {
      return $r('sys.symbol.arrow_down_to_line');
    }
    return $r('sys.symbol.externaldrive');
  }

  // MARK: 会话按自然日分组（同 iOS MoreConversationPeriod）

  private periods(): MorePeriod[] {
    return [MorePeriod.today, MorePeriod.yesterday, MorePeriod.earlier];
  }

  private periodLabel(period: MorePeriod): string {
    if (period === MorePeriod.today) {
      return '今天';
    }
    if (period === MorePeriod.yesterday) {
      return '昨天';
    }
    return '更早';
  }

  private sameLocalDay(a: Date, b: Date): boolean {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  }

  private periodOfMs(ms: number, now: Date): MorePeriod {
    const date: Date = new Date(ms);
    if (this.sameLocalDay(date, now)) {
      return MorePeriod.today;
    }
    const yesterday: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
    if (this.sameLocalDay(date, yesterday)) {
      return MorePeriod.yesterday;
    }
    return MorePeriod.earlier;
  }

  private sessionsOfPeriod(period: MorePeriod): SessionSummary[] {
    const now: Date = new Date();
    const out: SessionSummary[] = [];
    for (const item of this.sessions) {
      const ms: number | null = Formatters.date(item.updated_at);
      if (ms !== null && this.periodOfMs(ms, now) === period) {
        out.push(item);
      }
    }
    return out;
  }

  /** 行右侧时间：今天 / 昨天 → HH:mm；更早 → 当年「M月D日」、跨年「Y/M/D」（同 iOS `AgentTimeline.listTime`） */
  private rowTime(item: SessionSummary): string {
    const ms: number | null = Formatters.date(item.updated_at);
    if (ms === null) {
      return '';
    }
    const now: Date = new Date();
    if (this.periodOfMs(ms, now) === MorePeriod.earlier) {
      const date: Date = new Date(ms);
      if (date.getFullYear() === now.getFullYear()) {
        return `${date.getMonth() + 1}月${date.getDate()}日`;
      }
      return `${date.getFullYear()}/${date.getMonth() + 1}/${date.getDate()}`;
    }
    const date: Date = new Date(ms);
    return `${Formatters.pad2(date.getHours())}:${Formatters.pad2(date.getMinutes())}`;
  }

  // MARK: 扫码批准（宿主工具栏的扫码钮）

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
      // 同 iOS：一个 List。首项是居中个人信息 + 胶囊切换，之后按选中段渲染。
      // 用 `List`（不是 Scroll+Column）是因为会话行要用**原生左滑操作**（`swipeAction` 只在 ListItem 上）。
      List({ space: 12 }) {
        ListItem() {
          Column({ space: 22 }) {
            this.ProfileCard()
            if (this.availableSections().length > 1) {
              this.SectionPicker()
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 8, bottom: 4 })
        }
        if (this.visibleSection() === MoreSection.conversations) {
          this.ConversationsSection()
        } else if (this.visibleSection() === MoreSection.downloads) {
          OfflineDownloadingSection({ navStack: this.navStack })
          OfflineWatchedCard()
          OfflineDownloadedSection({ navStack: this.navStack })
          OfflineOtherOwnersSection()
          OfflineCapacityCard()
        } else {
          this.ServerSectionItem()
        }
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      // 内容不够一屏时也给点回弹反馈（不然会觉得「不能滑」）
      .edgeEffect(EdgeEffect.Spring)
      // 点 / 滑列表收起快捷输入条的键盘（同 iOS scrollDismissesKeyboard：不吞点按，行照常响应）
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.getUIContext().getFocusController().clearFocus();
        }
      })
      // 管理员底部有常驻快捷输入条（AgentQuickInput）：末项多让出它的高度
      .padding({ left: 16, right: 16, top: 0, bottom: Theme.tabBarInset + (this.isAdmin() ? AGENT_QUICK_CONTENT_EXTRA : 0) })
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

  /** 居中个人信息卡：80 号头像 + 铅笔角标 + 昵称 + 身份小字；点一下进个人信息（同 iOS `profile`） */
  @Builder
  ProfileCard() {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Stack() {
          // 底层：渐变圆 + 昵称首字。iOS `AvatarBadge` 同款，也是「没设头像」或「图还没下来」时的样子
          Text(Permissions.initialsOf(this.nickname()))
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor('rgba(0, 0, 0, 0.75)')
          // 上层：有头像就盖上去（同 iOS：`AvatarBadge` 里 RemoteImage 叠加）
          if (this.avatarUrl().length > 0) {
            RemoteImage({
              url: this.avatarUrl(),
              placeholderSymbol: $r('sys.symbol.person_crop_circle_fill')
            })
              .width(80)
              .height(80)
              .borderRadius(40)
              .clip(true)
          }
        }
        .width(80)
        .height(80)
        .borderRadius(40)
        .linearGradient({
          angle: 180,
          colors: [[Theme.accentStrong, 0], [Theme.accent2, 1]]
        })
        .alignContent(Alignment.Center)
        // 铅笔角标：点个人信息改昵称 / 头像（同 iOS 80 号头像右下角的 pencil 徽标）
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(13)
            .fontColor([Theme.text])
        }
        .width(28)
        .height(28)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(14)
        .border({ width: 3, color: Theme.bg })
        .offset({ x: 6, y: 4 })
      }
      .width(80)
      .height(80)
      Text(this.nickname())
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.text)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
      Text(this.identityLine())
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .maxLines(2)
        .textAlign(TextAlign.Center)
    }
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.navStack.pushPathByName('profile', null);
    })
  }

  /** 胶囊三段切换（同 iOS `sectionPicker`）：选中段白底 9%，服务器段有待处理时打红点 */
  @Builder
  SectionPicker() {
    Row({ space: 4 }) {
      ForEach(this.availableSections(), (section: MoreSection) => {
        Row({ space: 7 }) {
          Stack({ alignContent: Alignment.TopEnd }) {
            SymbolGlyph(this.sectionIcon(section))
              .fontSize(16)
              .fontColor([this.visibleSection() === section ? Theme.text : Theme.textMuted])
            if (section === MoreSection.server && this.isAdmin() && this.noticeCount > 0) {
              Circle()
                .width(6)
                .height(6)
                .fill(Theme.danger)
                .offset({ x: 4, y: -3 })
            }
          }
          Text(this.sectionTitle(section))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.visibleSection() === section ? Theme.text : Theme.textMuted)
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .padding({ left: 6, right: 6 })
        .constraintSize({ minHeight: 44 })
        .backgroundColor(this.visibleSection() === section ? 'rgba(255, 255, 255, 0.09)' : Color.Transparent)
        .borderRadius(22)
        .onClick(() => {
          this.selectedSection = section;
        })
      }, (section: MoreSection) => `${section}`)
    }
    .width('100%')
    .padding(5)
    .backgroundColor(Theme.surface)
    .borderRadius(27)
    .border({ width: 1, color: Theme.line })
  }

  /** 会话段（仅管理员）：空态 → 今天 / 昨天 / 更早分组 → 翻页指示（同 iOS `conversations`） */
  @Builder
  ConversationsSection() {
    if (this.sessions.length === 0) {
      ListItem() {
        Column({ space: 6 }) {
          Text('还没有会话')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
          Text('在下方输入框里问点什么吧。')
            .fontSize(14)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 8, bottom: 8 })
      }
    }
    ForEach(this.periods(), (period: MorePeriod) => {
      if (this.sessionsOfPeriod(period).length > 0) {
        ListItemGroup({ header: this.PeriodHeader(this.periodLabel(period)) }) {
          ForEach(this.sessionsOfPeriod(period), (item: SessionSummary) => {
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
        }
      }
    }, (period: MorePeriod) => `${period}`)
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

  @Builder
  PeriodHeader(label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.textMuted)
      .width('100%')
      .padding({ left: 16, top: 8, bottom: 4 })
  }

  /**
   * 会话行（同 iOS `sessionRow`）：单行标题 + 右侧最近活动时间；运行中时右侧换成
   * 「进行中」胶囊 + 呼吸点。左滑三个纯图标按钮（续接 / 重命名 / 删除），长按同项菜单。
   */
  @Builder
  SessionRow(item: SessionSummary) {
    Row() {
      Text(this.sessionTitle(item))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 默认断行规则把「微信 · o9cq801…@im.wechat」这种长串英文名当一个整词，
        // 一个词放不下就整段丢掉、只剩「微信 · …」。BREAK_ALL = 先尽量填满整行，再在末尾省略。
        .wordBreak(WordBreak.BREAK_ALL)
        .layoutWeight(1)
      if (item.running) {
        Row({ space: 5 }) {
          Circle()
            .width(7)
            .height(7)
            .fill(Theme.info)
          Text('进行中')
            .fontSize(12)
            .fontColor(Theme.info)
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor('rgba(127, 176, 255, 0.12)')
        .borderRadius(11)
      } else if (this.rowTime(item).length > 0) {
        Text(this.rowTime(item))
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 44 })
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
   * 服务器段（同 iOS `server`）：当前服务器地址卡（内嵌「服务器设置」行）+
   * 管理员的「待处理」瓷砖（有待处理才出现）。iOS 还有「可用更新」瓷砖——
   * 鸿蒙没有 ShellBadges 的版本对比数据源，不移植。
   */
  @Builder
  ServerSectionItem() {
    ListItem() {
      Column({ space: 12 }) {
        Column({ space: 10 }) {
          Text('当前服务器')
            .fontSize(12)
            .fontColor(Theme.textMuted)
          Text(this.hostLabel())
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.text)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Text('服务器设置')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
              .layoutWeight(1)
              .constraintSize({ minHeight: 44 })
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(13)
              .fontColor([Theme.textFaint])
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.navStack.pushPathByName('settings', null);
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .backgroundColor(Theme.surface)
        .borderRadius(16)
        .border({ width: 1, color: Theme.line })

        if (this.isAdmin() && this.noticeCount > 0) {
          Column({ space: 10 }) {
            Text('待处理')
              .fontSize(12)
              .fontColor(Theme.textMuted)
            Text(`${this.noticeCount} 项`)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.danger)
            Text('查看提醒')
              .fontSize(12)
              .fontColor(Theme.textMuted)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .constraintSize({ minHeight: 88 })
          .padding(16)
          .backgroundColor(Theme.surface)
          .borderRadius(16)
          .border({ width: 1, color: Theme.line })
          .onClick(() => {
            this.navStack.pushPathByName('notices', null);
          })
        }
      }
      .width('100%')
      .padding({ top: 4 })
    }
  }
}
