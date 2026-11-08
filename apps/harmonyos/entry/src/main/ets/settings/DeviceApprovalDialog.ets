import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { DeviceText, GrantText } from '../common/DeviceText';
import { PairingScan } from '../common/PairingCode';
import { Haptics } from '../common/Haptics';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { DeviceRequestView } from '../api/Models';

/**
 * 配对码的格子布局：**8 个字符位 + 中间一个固定的 `-`**（服务端码形 `MCLW-XXXX`）。
 * 8 个字符位都由用户输入（MCLW 也不是预置的，得照设备上显示的敲），
 * 下标 4 是那个分隔符，输入流到那里会自动跳过。
 */
/** 分隔符占的下标 */
const CODE_DASH_CELL: number = 4;
/** 字符位个数（= 8） */
const CODE_CHAR_COUNT: number = 8;
/** 收键盘的隐藏输入框的 key（点格子时用它聚焦） */
const CODE_INPUT_KEY: string = 'pairing-code-input';

/** 批准流程的阶段 */
enum ApprovalPhase {
  /** 等用户输入配对码 */
  entering,
  /** 已发起查询，等结果 */
  looking,
  /** 已经查到请求，等用户看过卡片后决定 */
  reviewing,
  /** 批了 / 拒了 */
  done
}

/**
 * 批准设备登录的**弹窗内容**（对齐 iOS `DeviceApprovalFlow`）。
 *
 * 用**华为原生的自定义弹窗**呈现：宿主 `SettingsSectionPage` 调
 * `UIContext.getPromptAction().openCustomDialog({ builder: …, alignment: Bottom, keyboardAvoidMode })`，
 * 系统负责遮罩、进出场动效、点遮罩关闭，以及**输入法避让**（`keyboardAvoidMode`）。
 * 本组件只画卡片里的东西——不再自绘星空底、不再自己算键盘高度、不再自带关闭圆钮
 * （点遮罩即可关）。批准 / 拒绝**都是一按到底**：不再插一层二次确认，
 * 按「批准登录」直接进结果卡「已批准」，按「拒绝」直接进「已拒绝」。
 *
 * **为什么批准 / 拒绝放在卡片里、不放导航栏**（iOS 的注释说得很清楚，照做）：
 * 导航栏的「取消 / 完成」是编辑类表单的确认；这里是一个**有安全后果的决定**，
 * 所以用卡片里的大按钮——看完信息顺手按。
 *
 * **查到码也不自动批准**：人必须看过卡片再按，这是防钓鱼的那道闸。
 *
 * **本组件是 V1 `@Component`**（宿主是 V2，V1 子组件可嵌入；内部只用 `@State`，
 * 往外回 `onClose`（关弹窗）与 `onRescan`（卡片里点了「扫描二维码」））。
 * **扫码永远不在弹窗存活期间发生**：扫码界面（Scan Kit）盖上来时弹窗保不住，
 * 所以扫描由宿主做——扫完带着结果（`initialCode`）或提示（`initialHint`）重开弹窗。
 */
@Component
export struct DeviceApprovalDialog {
  /** 进来自带的配对码 / 扫到的二维码原文（`/activate?code=…` 网址或 `MCLW-XXXX`；空 = 让人手输） */
  @Prop initialCode: string = '';
  /** 进来就显示的提示（扫了但不是登录二维码 / 相机用不了），写进卡片上的提示行 */
  @Prop initialHint: string = '';
  onClose: () => void = (): void => {
  };
  /** 卡片里点了「扫描二维码」：关掉弹窗、由宿主去拉扫码，扫完带着结果重开弹窗 */
  onRescan: () => void = (): void => {
  };

  @State private phase: ApprovalPhase = ApprovalPhase.entering;
  /** 用户敲进去的 8 个字符（不含 `-`；字母一律大写） */
  @State private chars: string = '';
  /** 查到的/带进来的整串码（`MCLW-XXXX`），只用于「正在查找 X…」这类展示 */
  @State private code: string = '';
  @State private busy: boolean = false;
  @State private errorMessage: string = '';
  @State private request: DeviceRequestView | null = null;
  /** 卡片上的提示（不是登录二维码 / 相机用不了） */
  @State private scanHint: string = '';
  /** 结果说明（批了还是拒了） */
  @State private resultOk: boolean = true;
  @State private resultText: string = '';
  /** 二维码里的服务器（主机:端口），查不到请求时用来提示「设备连的可能是另一台服务器」 */
  private scannedHost: string = '';

  aboutToAppear(): void {
    if (this.initialCode.length > 0) {
      // 站内链接 / 扫码结果带进来的整串码：解析出配对码填进格子、带上二维码里的服务器
      const parsed: PairingScan | null = PairingScan.parse(this.initialCode);
      this.chars = parsed !== null ? parsed.code.replace('-', '') : '';
      this.code = parsed !== null ? parsed.code : this.initialCode;
      if (parsed !== null && parsed.host !== null) {
        this.scannedHost = parsed.host;
      }
      this.lookup();
      return;
    }
    if (this.initialHint.length > 0) {
      this.scanHint = this.initialHint;
    }
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private isAdmin(): boolean {
    return Permissions.fromSession(AppModel.shared.session).isAdmin;
  }

  /** 「以谁的身份批准」：批准的后果是设备登录成这个账号，必须写明 */
  private accountName(): string {
    const session = AppModel.shared.session;
    if (session === null) {
      return '当前账号';
    }
    return session.nickname.length > 0 ? session.nickname : session.username;
  }

  /** 只留字母数字（字母转大写，数字原样），最多八位 */
  private sanitize(value: string): string {
    let out: string = '';
    const upper: string = value.toUpperCase();
    for (let i: number = 0; i < upper.length; i++) {
      if (out.length >= CODE_CHAR_COUNT) {
        break;
      }
      const code: number = upper.charCodeAt(i);
      const isDigit: boolean = code >= 0x30 && code <= 0x39;
      const isLetter: boolean = code >= 0x41 && code <= 0x5A;
      if (isDigit || isLetter) {
        out += upper.charAt(i);
      }
    }
    return out;
  }

  /** 某个格子要显示的字符：第 4 格是固定的 `-`，其余按「跳过它」的下标取 */
  private cellChar(cellIndex: number): string {
    if (cellIndex === CODE_DASH_CELL) {
      return '-';
    }
    const at: number = cellIndex < CODE_DASH_CELL ? cellIndex : cellIndex - 1;
    return at < this.chars.length ? this.chars.charAt(at) : '';
  }

  /** 当前该输的格子（输入流到第 4 格时自动跳到第 5 格） */
  private caretCell(): number {
    return this.chars.length < CODE_DASH_CELL ? this.chars.length : this.chars.length + 1;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  // MARK: 动作

  /**
   * 查这条配对请求。码形必须先合法（同 iOS `lookUp`）：形如 MCLW-7F3K，
   * 不合法就地把话说清楚，不发无谓的请求。
   */
  private async lookup(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    // 八位齐全才去查（少一位时 normalize 出来的是别的码，不如就地把话说清楚）
    const target: string | null = this.chars.length === CODE_CHAR_COUNT
      ? PairingScan.normalize(this.chars) : null;
    if (target === null) {
      this.errorMessage = '配对码形如 MCLW-7F3K，请对照设备上显示的重新输入。';
      this.phase = ApprovalPhase.entering;
      return;
    }
    this.code = target;
    this.errorMessage = '';
    this.phase = ApprovalPhase.looking;
    this.busy = true;
    try {
      this.request = await api.authDevicesRequest(target);
      this.phase = ApprovalPhase.reviewing;
    } catch (error) {
      this.errorMessage = this.messageOf(error) + this.serverMismatchHint();
      this.phase = ApprovalPhase.entering;
    } finally {
      this.busy = false;
    }
  }

  /** 二维码来自另一台服务器时补一句：电视连的是 A，手机当前账号在 B，在 B 上当然查不到 */
  private serverMismatchHint(): string {
    const host: string = this.scannedHost;
    if (host.length === 0) {
      return '';
    }
    const client = AppModel.shared.client;
    if (client === null) {
      return '';
    }
    const mine: string = client.origin.replace('https://', '').replace('http://', '').replace('/', '');
    if (mine.toLowerCase() === host.toLowerCase()) {
      return '';
    }
    return `二维码来自 ${host}，而当前账号连的是 ${mine}；`
      + '如果那台设备连的是另一台服务器，请先在「我的」页切换到那台服务器上的账号。';
  }

  private async decide(approve: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const view: DeviceRequestView | null = this.request;
    if (api === null || view === null || this.busy) {
      return;
    }
    this.busy = true;
    this.errorMessage = '';
    try {
      if (approve) {
        await api.authDevicesApprove(view.user_code);
        // 有安全后果的决定落地了：震一下给个实感（同 iOS 的 .success 通知反馈）
        Haptics.notifySuccess();
        this.resultOk = true;
        this.resultText = `「${view.client_name}」会在几秒内自动登录，回到那台设备上继续就好。`;
      } else {
        await api.authDevicesDeny(view.user_code);
        Haptics.notify();
        this.resultOk = false;
        this.resultText = `这台设备不会登录（${view.client_name}）。`
          + '如果它其实是你的，让它重新发起配对即可。';
      }
    } catch (error) {
      this.resultOk = false;
      this.resultText = this.messageOf(error);
    } finally {
      this.busy = false;
      this.phase = ApprovalPhase.done;
    }
  }

  // MARK: 视图

  build() {
    Column({ space: 20 }) {
      if (this.phase === ApprovalPhase.looking) {
        this.LookingContent()
      } else if (this.phase === ApprovalPhase.reviewing) {
        this.RequestContent()
      } else if (this.phase === ApprovalPhase.done) {
        this.ResultContent()
      } else {
        this.InputContent()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(24)
  }

  /** 输入配对码（对应 iOS `inputContent`） */
  @Builder
  InputContent() {
    Column({ space: 6 }) {
      Text('批准设备登录')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.text)
      Text('输入 Apple TV、Mac、命令行或转码器上显示的配对码，或者扫它旁边的二维码。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)

    Column({ space: 8 }) {
      /*
       * 配对码拆成格子：`M C L W -` 五格固定灰显 + 后四格可输。
       * 上面铺一个**透明的真输入框**收键盘——不要用四个 TextInput（中文输入法会先出候选词，
       * 一格一字符的焦点跳转在这种输入法下很难做稳）；这样退格、粘贴、英文键盘都还是系统行为。
       */
      Stack() {
        /*
         * 九格**写死，不用 ForEach**：ForEach 按 key 缓存条目，键不变就不会重建，
         * 而这里每格显示的是组件状态（`chars`）——实测用 ForEach 时输入后格子一直是空的。
         */
        Row({ space: 4 }) {
          CodeCell({ ch: this.cellChar(0), isDash: false, caret: this.caretCell() === 0 })
          CodeCell({ ch: this.cellChar(1), isDash: false, caret: this.caretCell() === 1 })
          CodeCell({ ch: this.cellChar(2), isDash: false, caret: this.caretCell() === 2 })
          CodeCell({ ch: this.cellChar(3), isDash: false, caret: this.caretCell() === 3 })
          CodeCell({ ch: '-', isDash: true, caret: false })
          CodeCell({ ch: this.cellChar(5), isDash: false, caret: this.caretCell() === 5 })
          CodeCell({ ch: this.cellChar(6), isDash: false, caret: this.caretCell() === 6 })
          CodeCell({ ch: this.cellChar(7), isDash: false, caret: this.caretCell() === 7 })
          CodeCell({ ch: this.cellChar(8), isDash: false, caret: this.caretCell() === 8 })
        }
        .width('100%')
        .height(52)
        .justifyContent(FlexAlign.Center)

        TextInput({ text: this.chars })
          .key(CODE_INPUT_KEY)
          .width('100%')
          .height('100%')
          // 不能是 0：opacity(0) 在部分版本上不参与命中，点上去拿不到焦点（实测）
          .opacity(0.01)
          .maxLength(CODE_CHAR_COUNT)
          .enterKeyType(EnterKeyType.Go)
          .onChange((value: string): void => {
            this.chars = this.sanitize(value);
            this.errorMessage = '';
          })
          .onSubmit(() => {
            this.lookup();
          })
      }
      .width('100%')
      .height(52)
      .onClick(() => {
        focusControl.requestFocus(CODE_INPUT_KEY);
      })
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }
      if (this.scanHint.length > 0) {
        Text(this.scanHint)
          .fontSize(12)
          .fontColor(Theme.warning)
          .width('100%')
      }
    }
    .width('100%')

    Column({ space: 10 }) {
      Button() {
        Text(this.busy ? '正在查…' : '继续')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.chars.length === 0 ? Theme.textFaint : '#0b0d12')
          .textAlign(TextAlign.Center)
      }
      .attributeModifier(new GlassButtonModifier(this.chars.length === 0 ? GlassTone.Secondary : GlassTone.Primary))
      .width('100%')
      .padding({ top: 15, bottom: 15 })
      .borderRadius(18)
      .onClick(() => {
        if (this.chars.length > 0) {
          this.lookup();
        }
      })
      Button() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.qrcode'))
            .fontSize(18)
            .fontColor([Theme.text])
          Text('扫描二维码')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
        }
        .width('100%')
        .height(50)
        .justifyContent(FlexAlign.Center)
      }
      .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
      .padding(0)
      .clip(true)
      .borderRadius(18)
      .onClick(() => {
        // 弹窗在扫码界面盖上来时保不住：交给宿主关掉弹窗、拉扫码、扫完再重开
        this.onRescan();
      })
    }
    .width('100%')

    this.AccountLine()
  }

  /** 查询中（对应 iOS `lookingContent`） */
  @Builder
  LookingContent() {
    Row({ space: 14 }) {
      LoadingProgress()
        .width(22)
        .height(22)
        .color(Theme.textMuted)
      Text(`正在查找 ${this.code} 的请求…`)
        .fontSize(15)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .height(80)
    .justifyContent(FlexAlign.Center)
  }

  /** 审批卡（对应 iOS `requestContent`） */
  @Builder
  RequestContent() {
    if (this.request !== null) {
      // 设备：图标 + 名字 + 平台
      Row({ space: 14 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph(DeviceText.symbol((this.request as DeviceRequestView).client_type))
            .fontSize(24)
            .fontColor([Theme.text])
        }
        .width(52)
        .height(52)
        .backgroundColor('rgba(255,255,255,0.10)')
        .borderRadius(26)
        Column({ space: 2 }) {
          Text((this.request as DeviceRequestView).client_name)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text((this.request as DeviceRequestView).platform
            ?? DeviceText.clientType((this.request as DeviceRequestView).client_type))
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      // 配对码是这张卡真正的安全控制：大号等宽字，让人真的去和设备屏幕逐字比对
      Column({ space: 4 }) {
        Text((this.request as DeviceRequestView).user_code)
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontFamily('monospace')
          .fontColor(Theme.accentStrong)
        Text('先核对与设备屏幕上显示的配对码完全一致')
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      this.GrantBlock((this.request as DeviceRequestView).client_type,
        this.isAdmin())

      // 来源地址认得出时才写；桥接网络的容器只看得到网桥网关，那时不如不写，判断依据就是配对码
      if ((this.request as DeviceRequestView).source_ip.length > 0) {
        Text(`来源 ${(this.request as DeviceRequestView).source_ip}`)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(Theme.textFaint)
          .width('100%')
      }

      if (this.blocked()) {
        Text('转码器只能由管理员批准：请把这个配对码告诉管理员，让他在网页或 App 的批准页输入。')
          .fontSize(12)
          .fontColor(Theme.warning)
          .width('100%')
      }
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }

      Column({ space: 10 }) {
        if (!this.blocked()) {
          Button() {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(17)
                .fontColor([this.busy ? Theme.textFaint : '#0b0d12'])
              Text(this.busy ? '正在处理…' : '批准登录')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.busy ? Theme.textFaint : '#0b0d12')
            }
            .width('100%')
            .height(52)
            .justifyContent(FlexAlign.Center)
          }
          .attributeModifier(new GlassButtonModifier(this.busy ? GlassTone.Secondary : GlassTone.Primary))
          .padding(0)
          .clip(true)
          .borderRadius(18)
          .onClick(() => {
            if (!this.busy) {
              this.decide(true);
            }
          })
        }
        Button() {
          Text('拒绝')
            .fontSize(16)
            .fontColor(Theme.danger)
            .textAlign(TextAlign.Center)
        }
        .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
        .width('100%')
        .padding({ top: 15, bottom: 15 })
        .borderRadius(18)
        .opacity(this.busy ? 0.5 : 1)
        .onClick(() => {
          if (!this.busy) {
            this.decide(false);
          }
        })
      }
      .width('100%')

      this.AccountLine()
    }
  }

  /** 转码器只能由超管批准（转码占用的是整台服务器的资源）：成员看到时说清原因、不给批准按钮 */
  private blocked(): boolean {
    const view: DeviceRequestView | null = this.request;
    return view !== null && view.requires_admin && !this.isAdmin();
  }

  /** 「将获得什么」：标题 + 说明（同 iOS `DeviceText.grant`） */
  @Builder
  GrantBlock(clientType: string, isAdmin: boolean) {
    Column({ space: 4 }) {
      Text(DeviceText.grant(clientType, isAdmin).title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Text(DeviceText.grant(clientType, isAdmin).body)
        .fontSize(12)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 结果（对应 iOS `resultContent`） */
  @Builder
  ResultContent() {
    Column({ space: 12 }) {
      SymbolGlyph(this.resultOk ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.xmark_circle_fill'))
        .fontSize(48)
        .fontColor([this.resultOk ? Theme.ok : Theme.danger])
      Text(this.resultOk ? '已批准' : '已拒绝')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.text)
      Text(this.resultText)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 8 })

    Button() {
      Text('完成')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0b0d12')
        .textAlign(TextAlign.Center)
    }
    .attributeModifier(new GlassButtonModifier(GlassTone.Primary))
    .width('100%')
    .padding({ top: 15, bottom: 15 })
    .borderRadius(18)
    .onClick(() => {
      this.onClose();
    })
  }

  /** 「以谁的身份批准」：批准的后果是设备登录成这个账号，必须写明 */
  @Builder
  AccountLine() {
    Text(`以「${this.accountName()}」的身份批准 · 换账号请先在「我的」页切换`)
      .fontSize(11)
      .fontColor(Theme.textMuted)
      .textAlign(TextAlign.Center)
      .width('100%')
  }
}

/**
 * 配对码的一格。
 *
 * **必须是一个独立的 `@Component`、用 `@Prop` 收参**，不能写成 `@Builder`：
 * ArkUI 的 `@Builder` 方法**按值传参会把值冻住**——父组件状态变了，格子里的字符不会跟着更新
 * （实测：输入框里已经有 `AB12`，格子还是空的）。`@Prop` 才会随父组件重渲染刷新。
 */
@Component
struct CodeCell {
  @Prop ch: string = '';
  /** 中间那个固定的 `-`：不画框 */
  @Prop isDash: boolean = false;
  /** 当前该输的那一格：描一圈高亮边框 */
  @Prop caret: boolean = false;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.ch)
        .fontSize(this.isDash ? 18 : 20)
        .fontFamily('monospace')
        .fontWeight(this.isDash ? FontWeight.Normal : FontWeight.Medium)
        .fontColor(this.isDash ? Theme.textFaint : Theme.text)
    }
    .width(this.isDash ? 10 : 34)
    .height(48)
    .backgroundColor(this.isDash
      ? Color.Transparent
      : (this.ch.length > 0 ? Theme.surfaceRaised : 'rgba(255,255,255,0.10)'))
    .borderRadius(12)
    .border(this.isDash
      ? { width: 0 }
      : {
        width: this.caret ? 1.5 : 1,
        color: this.caret ? Theme.accent : 'rgba(255,255,255,0.10)'
      })
  }
}
