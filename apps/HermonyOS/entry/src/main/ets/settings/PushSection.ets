import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { AppFooter } from '../common/AppFooter';
import { ImageUrls } from '../common/ImageUrls';
import { SettingsSwitchRow } from '../common/SettingsControls';
import { RemoteImage } from '../common/RemoteImage';
import {
  ChannelPushConfigView,
  FeishuBindPayload,
  ImAccountView,
  ImBindTokenPayload,
  ImBindingView,
  PushTestPayload,
  WeixinAccountView,
  WeixinBindingStartView,
  WeixinBindingStatusView
} from '../api/Models';

/** 一个可接入的通道（对应 iOS `SettingsBPushChannel`：平台文案集中在这里） */
class ImChannel {
  readonly id: string;
  readonly label: string;
  /** 「新增通道」里的一句话说明 */
  readonly summary: string;
  /** 绑定弹层顶部的做法说明 */
  readonly howTo: string;
  /** 需要 bot token 的通道才有 */
  readonly tokenHint: string;
  readonly unbindMessage: string;
  readonly boundToast: string;

  constructor(id: string, label: string, summary: string, howTo: string, tokenHint: string,
    unbindMessage: string, boundToast: string) {
    this.id = id;
    this.label = label;
    this.summary = summary;
    this.howTo = howTo;
    this.tokenHint = tokenHint;
    this.unbindMessage = unbindMessage;
    this.boundToast = boundToast;
  }
}

const CHANNELS: ImChannel[] = [
  new ImChannel('weixin', '微信', '手机扫码绑定，无需自建机器人',
    '打开手机微信扫描下方二维码。扫码人即唯一可对话的用户，同时也是推送目标。', '',
    '解绑后需重新扫码才能使用。', '微信 已接入，现在就可以给它发消息试试'),
  new ImChannel('telegram', 'Telegram', '接入你用 @BotFather 创建的 bot',
    '在 Telegram 搜索 @BotFather 创建 bot 并复制 token；国内网络请先在「设置 → 网络」为 Telegram 开启代理。',
    '从 @BotFather 创建 bot 后获得的 token',
    '解绑将删除 bot 凭据并停止通道，需重新配对才能使用。', 'Telegram 已接入，现在就可以给它发消息试试'),
  new ImChannel('discord', 'Discord', '接入你在开发者后台创建的 bot',
    '在 discord.com/developers 创建应用 → Bot → Reset Token 复制；国内网络请先在「设置 → 网络」为 Discord 开启代理。',
    'Discord 开发者后台 Bot 页面的 token',
    '解绑将删除 bot 凭据并停止通道，需重新配对才能使用。', 'Discord 已接入，现在就可以给它发消息试试'),
  new ImChannel('feishu', '飞书', '粘贴群机器人 Webhook 地址，即绑即用',
    '在飞书群聊「设置 → 群机器人 → 添加机器人」里添加「自定义机器人」，把复制的 Webhook 地址粘贴到下面即可。'
      + '安全设置建议选「签名校验」，并把密钥一并填入。', '',
    '解绑后群机器人不再收到推送，需重新粘贴 Webhook 地址。', '飞书 已接入，去飞书群里看看欢迎消息吧')
];

function channelOf(id: string): ImChannel {
  for (const channel of CHANNELS) {
    if (channel.id === id) {
      return channel;
    }
  }
  return CHANNELS[0];
}

/** 归一后的账号信息：微信与 IM 的视图字段一样，但 ArkTS 是标称类型，统一拷成自己的形状 */
class PushAccount {
  readonly accountId: string;
  readonly boundUserId: string;
  readonly status: string;
  readonly running: boolean;
  readonly lastError: string;
  readonly boundAt: string;

  constructor(accountId: string, boundUserId: string, status: string, running: boolean,
    lastError: string, boundAt: string) {
    this.accountId = accountId;
    this.boundUserId = boundUserId;
    this.status = status;
    this.running = running;
    this.lastError = lastError;
    this.boundAt = boundAt;
  }

  static ofIm(account: ImAccountView): PushAccount {
    return new PushAccount(account.account_id, account.bound_user_id ?? '', account.status,
      account.running, account.last_error ?? '', account.bound_at);
  }

  static ofWeixin(account: WeixinAccountView): PushAccount {
    return new PushAccount(account.account_id, account.bound_user_id ?? '', account.status,
      account.running, account.last_error ?? '', account.bound_at);
  }
}

/** 已接入账号（跨平台归一成一个形状，列表不再关心来源差异，同 iOS `SettingsBPushAccountRow`） */
class PushAccountRow {
  readonly channel: ImChannel;
  readonly account: PushAccount;

  constructor(channel: ImChannel, account: PushAccount) {
    this.channel = channel;
    this.account = account;
  }

  key(): string {
    return `${this.channel.id}:${this.account.accountId}`;
  }
}

/** 两个页签：接入通道 / 推送内容（iOS 用分段标签分开，因为它们回答两个完全不同的问题） */
class PushTab {
  static readonly channels: string = 'channels';
  static readonly content: string = 'content';
}

/** `ChannelPushConfigView` 是同构的，但直接写对象字面量会被 ArkTS 拒，用类 */
class PushConfig implements ChannelPushConfigView {
  push_dispatch: boolean = false;
  push_imported: boolean = false;
}

/**
 * 设置 → 消息推送（对应 iOS `PushSettingsView` / Web `im-push-section`）。
 *
 * iOS 把两类设定**按分段标签分开**，因为它们回答的是两个完全不同的问题：
 * - **接入通道**：我接了哪些账号？——跨平台统一列表 +「新增通道」，绑定流程收进弹层；
 * - **推送内容**：什么事件会推给我？——事件开关（逐项即时保存）+ 一键测试推送。
 *
 * 切换标签时另一侧卸载，回来重新拉取（同 iOS）。
 *
 * **本轮先不做**：微信的扫码绑定与飞书的专属绑定流程（这两家有各自的挑战流程与二维码，
 * 而 Telegram / Discord 走的是通用配对码）；绑定成功后的自动轮询（先用「我已完成，刷新」手动确认）。
 */
@ComponentV2
export struct PushSection {
  @Local private tab: string = PushTab.channels;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';

  // 接入通道（跨平台一张列表，同 iOS）
  @Local private rows: PushAccountRow[] = [];
  @Local private busyId: string = '';
  /** 正在绑定的通道（点过「新增通道」里的某一项） */
  @Local private channel: string = 'telegram';
  /** 「新增通道」平台选择面板 */
  @Local private showPicker: boolean = false;

  // 微信扫码绑定
  @Local private weixinQr: string = '';
  @Local private weixinStatus: string = '';
  @Local private weixinCode: string = '';
  @Local private weixinChallenge: string = '';
  private weixinTimer: number = -1;

  // 飞书 Webhook 绑定
  @Local private feishuWebhook: string = '';
  @Local private feishuSecret: string = '';

  // 绑定流程
  @Local private showBind: boolean = false;
  @Local private bindValue: ImBindingView | null = null;
  @Local private bindLoading: boolean = false;
  @Local private bindError: string = '';

  // 推送内容
  @Local private config: ChannelPushConfigView | null = null;
  @Local private testing: boolean = false;

  private started: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private async load(): Promise<void> {
    if (this.tab === PushTab.channels) {
      await this.loadAccounts();
    } else {
      await this.loadConfig();
    }
  }

  private async loadConfig(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.config = await api.channelsImPushConfigGet();
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  /** 各平台同源同后端：任一失败都视作整体失败（与其半张列表让用户以为某通道掉了，不如让他重试），同 iOS */
  private async loadAccounts(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const weixin: WeixinAccountView[] = await api.channelsWeixinAccountsList();
      const telegram: ImAccountView[] = await api.channelsImAccountsList('telegram');
      const discord: ImAccountView[] = await api.channelsImAccountsList('discord');
      const feishu: ImAccountView[] = await api.channelsImAccountsList('feishu');
      const rows: PushAccountRow[] = [];
      for (const account of weixin) {
        rows.push(new PushAccountRow(channelOf('weixin'), PushAccount.ofWeixin(account)));
      }
      for (const account of telegram) {
        rows.push(new PushAccountRow(channelOf('telegram'), PushAccount.ofIm(account)));
      }
      for (const account of discord) {
        rows.push(new PushAccountRow(channelOf('discord'), PushAccount.ofIm(account)));
      }
      for (const account of feishu) {
        rows.push(new PushAccountRow(channelOf('feishu'), PushAccount.ofIm(account)));
      }
      this.rows = rows;
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
      this.rows = [];
    } finally {
      this.loading = false;
    }
  }

  /** 「新增通道」：选平台后开对应的绑定弹层（iOS 是菜单，这里用一张面板） */
  private pickChannel(id: string): void {
    this.channel = id;
    this.showPicker = false;
    this.startBind();
  }

  /** 开始绑定：按通道分派（微信二维码 / 飞书 Webhook / 其余走 bot token 配对码） */
  private async startBind(): Promise<void> {
    this.bindValue = null;
    this.bindError = '';
    this.weixinQr = '';
    this.weixinCode = '';
    this.weixinStatus = '';
    this.weixinChallenge = '';
    this.feishuWebhook = '';
    this.feishuSecret = '';
    this.bindLoading = true;
    this.showBind = true;
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      this.bindLoading = false;
      return;
    }
    try {
      if (this.channel === 'weixin') {
        const started: WeixinBindingStartView = await api.channelsWeixinBindingsStart();
        this.weixinChallenge = started.challenge_id;
        this.weixinQr = ImageUrls.resolve(AppModel.origin(), started.qrcode_url, null) ?? '';
        this.weixinStatus = 'pending';
        this.startWeixinPoll();
      } else if (this.channel === 'feishu') {
        this.bindLoading = false; // 飞书是填表，不需要先起挑战
      } else {
        // `token` 是必填——后端用它区分「同一账号重复发起」的同一次挑战
        const body: ImBindTokenPayload = { token: `harmony-${Date.now()}` };
        this.bindValue = await api.channelsImBindingsStart(this.channel, body);
      }
    } catch (error) {
      this.bindError = this.messageOf(error);
    } finally {
      this.bindLoading = false;
    }
  }

  /** 微信：每 1.5 秒查一次挑战状态（扫码 / 待验证码 / 已确认 / 过期） */
  private startWeixinPoll(): void {
    this.stopWeixinPoll();
    this.weixinTimer = setInterval((): void => {
      this.pollWeixin();
    }, 1500);
  }

  private stopWeixinPoll(): void {
    if (this.weixinTimer >= 0) {
      clearInterval(this.weixinTimer);
      this.weixinTimer = -1;
    }
  }

  private async pollWeixin(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.weixinChallenge.length === 0) {
      return;
    }
    try {
      const status: WeixinBindingStatusView = await api.channelsWeixinBindingsStatus(this.weixinChallenge);
      this.weixinStatus = status.status;
      if (status.status === 'confirmed' || status.status === 'already_bound') {
        this.stopWeixinPoll();
        this.showBind = false;
        this.toast(channelOf('weixin').boundToast);
        await this.loadAccounts();
      } else if (status.status === 'expired' || status.status === 'failed') {
        this.stopWeixinPoll();
      }
    } catch (error) {
      this.stopWeixinPoll();
      this.bindError = this.messageOf(error);
    }
  }

  /** 微信：扫码后微信要求输验证码（挑战转入 need_verify_code） */
  private async submitWeixinCode(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const code: string = this.weixinCode.trim();
    if (api === null || code.length === 0 || this.weixinChallenge.length === 0) {
      return;
    }
    try {
      await api.channelsWeixinBindingsVerify(this.weixinChallenge, { code: code });
      this.weixinCode = '';
      this.startWeixinPoll();
    } catch (error) {
      this.bindError = this.messageOf(error);
    }
  }

  /** 飞书：Webhook 即绑即用 */
  private async bindFeishu(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const url: string = this.feishuWebhook.trim();
    if (api === null || url.length === 0) {
      this.bindError = '请先粘贴群机器人 Webhook 地址';
      return;
    }
    this.bindLoading = true;
    this.bindError = '';
    try {
      const body: FeishuBindPayload = { webhook_url: url };
      if (this.feishuSecret.trim().length > 0) {
        body.secret = this.feishuSecret.trim();
      }
      await api.channelsImFeishuBind(body);
      this.showBind = false;
      this.toast(channelOf('feishu').boundToast);
      await this.loadAccounts();
    } catch (error) {
      this.bindError = this.messageOf(error);
    } finally {
      this.bindLoading = false;
    }
  }

  /** 通用配对码：手动确认绑定结果 */
  private async refreshBind(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const value: ImBindingView | null = this.bindValue;
    if (api === null || value === null) {
      return;
    }
    this.bindLoading = true;
    try {
      const updated: ImBindingView = await api.channelsImBindingsStatus(this.channel, value.challenge_id);
      this.bindValue = updated;
      if (updated.account !== null && updated.account !== undefined) {
        this.showBind = false;
        this.toast(channelOf(this.channel).boundToast);
        await this.loadAccounts();
      } else {
        this.toast('还没收到，稍等一下再试');
      }
    } catch (error) {
      this.bindError = this.messageOf(error);
    } finally {
      this.bindLoading = false;
    }
  }

  /** 切页签：另一侧卸载，回来重新拉（同 iOS/Web） */
  private switchTab(tab: string): void {
    if (tab === this.tab) {
      return;
    }
    this.tab = tab;
    this.loading = true;
    this.errorMessage = '';
    this.rows = [];
    this.config = null;
    this.load();
  }

  private confirmUnbind(row: PushAccountRow): void {
    this.getUIContext().showAlertDialog({
      title: `解绑该 ${row.channel.label} 账号？`,
      message: row.channel.unbindMessage,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '解绑',
        fontColor: Theme.danger,
        action: (): void => {
          this.unbind(row);
        }
      }
    });
  }

  private async unbind(row: PushAccountRow): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.busyId = row.account.accountId;
    try {
      if (row.channel.id === 'weixin') {
        await api.channelsWeixinAccountsUnbind(row.account.accountId);
      } else {
        await api.channelsImAccountsUnbind(row.channel.id, row.account.accountId);
      }
      this.toast('已解绑');
      await this.loadAccounts();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = '';
    }
  }

  /** 事件开关：**逐项即时保存**（同 iOS） */
  private async toggleEvent(dispatch: boolean, on: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: ChannelPushConfigView | null = this.config;
    if (api === null || view === null) {
      return;
    }
    const next: PushConfig = new PushConfig();
    next.push_dispatch = dispatch ? on : view.push_dispatch;
    next.push_imported = dispatch ? view.push_imported : on;
    this.config = next;
    try {
      this.config = await api.channelsImPushConfigUpdate(next);
    } catch (error) {
      this.config = view;
      this.toast(this.messageOf(error));
    }
  }

  private async sendTest(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.testing) {
      return;
    }
    this.testing = true;
    try {
      const body: PushTestPayload = { text: '这是一条来自 MovieClaw 鸿蒙端的测试推送。' };
      await api.channelsImPushTest(body);
      this.toast('已发出测试推送');
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.testing = false;
    }
  }

  private accountLabel(account: ImAccountView): string {
    const user: string | null = account.bound_user_id ?? null;
    return user !== null && user.length > 0 ? user : account.account_id;
  }

  private accountStatus(account: ImAccountView): string {
    if (account.last_error !== null && account.last_error !== undefined
      && account.last_error.length > 0) {
      return account.last_error;
    }
    return account.running ? '运行中' : account.status;
  }

  // MARK: 视图

  build() {
    Column() {
      this.TabBar()
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(24).height(24).color(Theme.textMuted)
          Text('正在加载…').fontSize(13).fontColor(Theme.textFaint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.tab === PushTab.channels) {
        this.ChannelsBody()
      } else {
        this.ContentBody()
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showBind, this.BindSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
    .bindSheet($$this.showPicker, this.ChannelPickerSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 分段标签（对应 iOS 的分段控件） */
  @Builder
  TabBar() {
    Row({ space: 8 }) {
      this.TabChip(PushTab.channels, '接入通道')
      this.TabChip(PushTab.content, '推送内容')
      Blank()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 10 })
  }

  @Builder
  TabChip(tab: string, label: string) {
    Text(label)
      .fontSize(14)
      .fontColor(this.tab === tab ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.tab === tab ? Theme.accent : Theme.glassFill)
      .borderRadius(17)
      .onClick(() => {
        this.switchTab(tab);
      })
  }

  // MARK: 接入通道（对应 iOS `SettingsBPushChannelsSections`）

  @Builder
  ChannelsBody() {
    Scroll() {
      Column({ space: 12 }) {
        // 简介：接入的通道都是推送目标；微信 / Telegram / Discord 里还能直接和 AI 对话
        Text() {
          Span('接入的通道都是推送目标；微信 / Telegram / Discord 里还能直接和 AI 助手对话：发消息即可搜片、订阅、查进度。发送')
          Span(' /reset ').fontFamily('monospace').fontColor(Theme.text)
          Span('重置会话，')
          Span(' /stop ').fontFamily('monospace').fontColor(Theme.text)
          Span('取消正在进行的处理。')
        }
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .width('100%')
        .padding(14)
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })

        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize(13)
            .fontColor(Theme.danger)
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .border({ width: 1, color: 'rgba(255, 107, 107, 0.3)' })
        }

        // 头行：「已接入 N 个账号。」+「＋ 新增通道」
        Row() {
          Text(this.rows.length === 0 ? '还没有接入任何通道。' : `已接入 ${this.rows.length} 个账号。`)
            .fontSize(13)
            .fontColor(Theme.textFaint)
            .layoutWeight(1)
          if (this.rows.length > 0) {
            Text('＋ 新增通道')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(Theme.glassFill)
              .borderRadius(12)
              .onClick((): void => {
                this.showPicker = true;
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.rows.length === 0) {
          this.EmptyChannels()
        } else {
          Column() {
            ForEach(this.rows, (row: PushAccountRow, index: number) => {
              this.AccountRow(row, index < this.rows.length - 1)
            }, (row: PushAccountRow) => row.key())
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
        }

        AppFooter()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: Theme.tabBarInset })
    }
    .layoutWeight(1)
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  /** 空态（对应 iOS `emptyState`） */
  @Builder
  EmptyChannels() {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.message'))
          .fontSize(24)
          .fontColor([Theme.textMuted])
      }
      .width(48)
      .height(48)
      .backgroundColor('rgba(255, 255, 255, 0.06)')
      .borderRadius(14)
      Text('还没有接入任何通道')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Text('点击「新增通道」，支持微信、Telegram、Discord 和飞书。')
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Text('接入通道')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0b0d12')
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 14, bottom: 14 })
        .backgroundColor(Theme.accent)
        .borderRadius(Theme.cardRadius)
        .onClick((): void => {
          this.showPicker = true;
        })
    }
    .width('100%')
    .padding({ top: 24, bottom: 24 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 一行已接入账号：图标 + 平台名 + 状态胶囊 + 绑定人/失效原因 + 解绑（同 iOS `accountRow`） */
  @Builder
  AccountRow(row: PushAccountRow, separator: boolean) {
    Column() {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(18)
            .fontColor([Theme.textMuted])
        }
        .width(38)
        .height(38)
        .backgroundColor('rgba(255, 255, 255, 0.06)')
        .borderRadius(11)

        Column({ space: 3 }) {
          Row({ space: 8 }) {
            Text(row.channel.label)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
              .maxLines(1)
            this.StatusBadge(row)
          }
          .width('100%')
          Text(this.accountDetail(row))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.busyId === row.account.accountId ? '…' : '解绑')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.danger)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(12)
          .onClick((): void => {
            if (this.busyId.length === 0) {
              this.confirmUnbind(row);
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 12, top: 12, bottom: 12 })

      if (separator) {
        Divider().color(Theme.line).margin({ left: 64, right: 14 })
      }
    }
    .width('100%')
  }

  /** 状态胶囊：需重新绑定（红）/ 运行中（绿）/ 未运行（灰） */
  @Builder
  StatusBadge(row: PushAccountRow) {
    Row({ space: 5 }) {
      Circle()
        .width(6)
        .height(6)
        .fill(this.badgeTone(row))
      Text(this.badgeText(row))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.badgeTone(row) === Theme.textMuted ? Theme.text : this.badgeTone(row))
    }
    .padding({ left: 7, right: 7, top: 2, bottom: 2 })
    .backgroundColor(this.badgeTone(row) === Theme.textMuted
      ? Theme.glassFill : 'rgba(255, 255, 255, 0.12)')
    .borderRadius(12)
  }

  private badgeTone(row: PushAccountRow): string {
    if (row.account.status === 'stale') {
      return Theme.danger;
    }
    return row.account.running ? Theme.ok : Theme.textMuted;
  }

  private badgeText(row: PushAccountRow): string {
    if (row.account.status === 'stale') {
      return '需重新绑定';
    }
    return row.account.running ? '运行中' : '未运行';
  }

  private accountDetail(row: PushAccountRow): string {
    const lastError: string = row.account.lastError;
    if (row.account.status === 'stale') {
      return lastError.length > 0 ? lastError : '凭据已失效，请重新绑定';
    }
    const boundAt: string = `绑定于 ${Formatters.relative(row.account.boundAt)}`;
    if (row.channel.id === 'feishu') {
      return `群机器人 · ${boundAt}`;
    }
    const user: string = row.account.boundUserId;
    const who: string = user.length > 0 ? user : row.account.accountId;
    return `${who} · ${boundAt}`;
  }

  /** 「新增通道」面板：四个平台各一行（平台名 + 一句话说明），点选即开绑定弹层 */
  @Builder
  ChannelPickerSheet() {
    Column({ space: 8 }) {
      Text('新增通道')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 10, top: 4 })
      ForEach(CHANNELS, (channel: ImChannel) => {
        Column({ space: 2 }) {
          Text(channel.label)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .width('100%')
          Text(channel.summary)
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 10, right: 10, top: 10, bottom: 10 })
        .onClick((): void => {
          this.pickChannel(channel.id);
        })
      }, (channel: ImChannel) => `pick-${channel.id}`)
    }
    .width('100%')
    .padding({ left: 6, right: 6, bottom: 16 })
    .backgroundColor(Theme.bg)
  }

  // MARK: 推送内容（对应 iOS `SettingsBPushContentSections`）

  @Builder
  ContentBody() {
    Scroll() {
      Column({ space: 12 }) {
        Text('这里的开关对所有已接入通道统一生效——关掉某个事件，任何通道都不会再收到它。')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })

        if (this.errorMessage.length > 0) {
          Text(this.errorMessage).fontSize(13).fontColor(Theme.danger).width('100%')
        }

        if (this.config !== null) {
          Column({ space: 0 }) {
            SettingsSwitchRow({
              title: '开始下载', hint: '订阅命中资源并提交下载器时',
              value: (this.config as ChannelPushConfigView).push_dispatch,
              onToggle: (on: boolean): void => {
                this.toggleEvent(true, on);
              }
            })
            Divider().color(Theme.line).margin({ left: 16, right: 16 })
            SettingsSwitchRow({
              title: '入库完成', hint: '下载完成整理进媒体库时',
              value: (this.config as ChannelPushConfigView).push_imported,
              onToggle: (on: boolean): void => {
                this.toggleEvent(false, on);
              }
            })
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
        } else {
          Column({ space: 8 }) {
            Text('推送开关加载失败').fontSize(14).fontColor(Theme.textMuted)
            Text('重试')
              .fontSize(14)
              .fontColor(Theme.accentStrong)
              .onClick(() => {
                this.load();
              })
          }
          .width('100%')
          .padding({ top: 30 })
          .justifyContent(FlexAlign.Center)
        }

        // 测试推送：向所有已接入通道发一条
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text('测试推送')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
            Text('向所有已接入通道发送一条测试消息')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text(this.testing ? '…' : '发送测试')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(14)
            .onClick((): void => {
              if (!this.testing) {
                this.sendTest();
              }
            })
        }
        .width('100%')
        .padding(14)
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })

        AppFooter()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: Theme.tabBarInset })
    }
    .layoutWeight(1)
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  @Builder

  // MARK: 绑定弹层（按通道分派：微信扫码 / 飞书 Webhook / 其余配对码）

  @Builder
  BindSheet() {
    Column({ space: 14 }) {
      Row() {
        Text(`绑定 ${channelOf(this.channel).label}`)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
          .width(40)
          .height(40)
          .onClick((): void => {
            this.stopWeixinPoll();
            this.showBind = false;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 12 }) {
          Text(channelOf(this.channel).howTo)
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .width('100%')

          if (this.bindError.length > 0) {
            Text(this.bindError).fontSize(13).fontColor(Theme.danger).width('100%')
          }

          if (this.channel === 'weixin') {
            this.WeixinBindBody()
          } else if (this.channel === 'feishu') {
            this.FeishuBindBody()
          } else if (this.bindLoading && this.bindValue === null) {
            Column({ space: 10 }) {
              LoadingProgress().width(24).height(24).color(Theme.textMuted)
              Text('正在获取配对码…').fontSize(13).fontColor(Theme.textFaint)
            }
            .width('100%')
            .padding({ top: 30 })
            .justifyContent(FlexAlign.Center)
          } else {
            this.TokenBindBody()
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 + Theme.safeBottomInset })
    .backgroundColor(Theme.bg)
  }

  /** 微信：二维码 + 轮询状态（扫码 / 待验证码 / 已确认 / 过期） */
  @Builder
  WeixinBindBody() {
    Column({ space: 12 }) {
      if (this.weixinQr.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          RemoteImage({ url: this.weixinQr, fit: true, placeholderSymbol: $r('sys.symbol.qrcode') })
            .width(200)
            .height(200)
            .backgroundColor('#ffffff')
            .borderRadius(12)
        }
        .width('100%')
        .alignContent(Alignment.Center)
      } else if (this.bindLoading) {
        LoadingProgress().width(24).height(24).color(Theme.textMuted)
      }

      Text(this.weixinStatusText())
        .fontSize(13)
        .fontColor(this.weixinStatus === 'expired' || this.weixinStatus === 'failed'
          ? Theme.danger : Theme.textMuted)
        .textAlign(TextAlign.Center)
        .width('100%')

      if (this.weixinStatus === 'need_verify_code') {
        TextInput({ text: this.weixinCode, placeholder: '微信里显示的验证码' })
          .width('100%')
          .height(46)
          .fontSize(17)
          .fontColor(Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((v: string): void => {
            this.weixinCode = v;
          })
        Text('确认')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.weixinCode.trim().length === 0 ? Theme.textFaint : '#0b0d12')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(this.weixinCode.trim().length === 0 ? Theme.glassFill : Theme.accent)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            this.submitWeixinCode();
          })
      }

      if (this.weixinStatus === 'expired' || this.weixinStatus === 'failed') {
        Text('重新生成二维码')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.accent)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            this.startBind();
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  private weixinStatusText(): string {
    if (this.weixinStatus === 'scanned') {
      return '已扫码，请在手机上确认';
    }
    if (this.weixinStatus === 'need_verify_code') {
      return '微信要求输入验证码，填在下面';
    }
    if (this.weixinStatus === 'expired') {
      return '二维码已过期，重新生成一个';
    }
    if (this.weixinStatus === 'failed') {
      return '绑定失败，重新生成二维码再试';
    }
    return '用手机微信扫描上方二维码';
  }

  /** 飞书：Webhook（+ 可选签名密钥）即绑即用 */
  @Builder
  FeishuBindBody() {
    Column({ space: 12 }) {
      Column({ space: 5 }) {
        Text('Webhook 地址')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .width('100%')
        TextInput({ text: this.feishuWebhook, placeholder: 'https://open.feishu.cn/open-apis/bot/v2/hook/…' })
          .width('100%')
          .height(46)
          .fontSize(14)
          .fontColor(Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((v: string): void => {
            this.feishuWebhook = v;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 5 }) {
        Text('签名密钥（可选）')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .width('100%')
        TextInput({ text: this.feishuSecret, placeholder: '安全设置选了「签名校验」时填' })
          .width('100%')
          .height(46)
          .fontSize(14)
          .fontColor(Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((v: string): void => {
            this.feishuSecret = v;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Text(this.bindLoading ? '接入中…' : '完成接入')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.feishuWebhook.trim().length === 0 || this.bindLoading
          ? Theme.textFaint : '#0b0d12')
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 13, bottom: 13 })
        .backgroundColor(this.feishuWebhook.trim().length === 0 || this.bindLoading
          ? Theme.glassFill : Theme.accent)
        .borderRadius(Theme.cardRadius)
        .onClick((): void => {
          if (!this.bindLoading) {
            this.bindFeishu();
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** Telegram / Discord：配对码 */
  @Builder
  TokenBindBody() {
    Column({ space: 12 }) {
      if (this.bindValue !== null) {
        if ((this.bindValue as ImBindingView).message.length > 0) {
          Text((this.bindValue as ImBindingView).message)
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        Text((this.bindValue as ImBindingView).pair_code)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.accentStrong)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 14, bottom: 14 })
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(12)
        Text(`把这段配对码发给 ${(this.bindValue as ImBindingView).bot_name}`)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
          .width('100%')
        Text(this.bindLoading ? '查询中…' : '我已完成，刷新')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.accent)
          .borderRadius(Theme.cardRadius)
          .onClick((): void => {
            if (!this.bindLoading) {
              this.refreshBind();
            }
          })
      } else {
        Column({ space: 8 }) {
          Text('还没拿到配对码')
            .fontSize(14)
            .fontColor(Theme.textMuted)
          Text('重新发起')
            .fontSize(14)
            .fontColor(Theme.accentStrong)
            .onClick((): void => {
              this.startBind();
            })
        }
        .width('100%')
        .padding({ top: 24 })
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
