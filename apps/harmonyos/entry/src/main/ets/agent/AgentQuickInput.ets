import { common } from '@kit.AbilityKit';
import { UIContext, window } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { ShellChrome } from '../common/ShellChrome';
import { TabBarStyle } from '../common/TabBarStyle';
import { WindowInsets } from '../common/WindowInsets';
import { NavStacks } from '../common/ShareLinks';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { LlmModelOptionView, SessionMessageAcceptedView, SessionStartPayload, SkillView } from '../api/Models';
import { AgentAIConsent } from './AgentAIConsent';
import { AgentAttachment, AgentAttachments } from './AgentAttachments';
import { AgentCatalog, AgentThinking } from './AgentCatalog';
import { AgentSessionsSignal } from './AgentSessionsSignal';
import { AgentSkillText } from './AgentSkills';
import { ChatParams } from './ChatParams';

/**
 * 「我的」页的 AI 快捷输入（对应 iOS `AgentQuickBar` + `AgentComposer` 新样式）。
 *
 * 管理员仅在「我的」页底部显示输入卡：未聚焦一行入口，聚焦展开完整输入框。
 * 悬浮和经典底栏共用 AgentComposerStore，切换样式不丢草稿。
 * 整屏页（会话页等）压上来时由 ShellChrome 隐藏。
 */

/** 经典贴底栏卡片在页签栏上方再抬起的高度 */
const BAR_LIFT_DOCKED: number = 12;

/** iOS `AgentComposer` 规范：36 控件、8 间距、外圆角 26、控件底色白 9% */
const CONTROL: number = 36;
const CONTROL_FILL: string = 'rgba(255, 255, 255, 0.09)';

/**
 * 折叠态输入行内容高的**估算初值**（TextArea 一行 + 上下 12 内边距）：覆盖层实际高度
 * 跟随输入行的 `onAreaChange` 实测（见 `inputLineHeight`），系统字号放大也不会错位。
 * 覆盖层**不能用 `height('100%')`**：覆盖层在自适应高度的 Stack 里，百分比高会顶到
 * 父容器约束把整块撑到近全屏，输入条被垂直居中悬到页面中部、盖住「会话/下载/服务器」
 * 分段选择器（连带着折叠态的发送按钮也压在「服务器」上吃点击）。
 */
const COLLAPSED_LINE: number = 44;

/**
 * AI 快捷输入的共享状态与动作（对应 iOS `AgentComposer` 的 model 层）。
 * `@ObservedV2` + `@Trace`：迷你条 / 半屏面板 / 经典底栏卡三处视图持有同一单例，
 * 任何一处改动（草稿、附件、模型选择）其余视图当场刷新。
 */
@ObservedV2
export class AgentComposerStore {
  private static instance: AgentComposerStore | null = null;

  static shared(): AgentComposerStore {
    if (AgentComposerStore.instance === null) {
      AgentComposerStore.instance = new AgentComposerStore();
    }
    return AgentComposerStore.instance;
  }

  /** 草稿：发送前一直留着（切页签/换形态不丢，发送成功才清） */
  @Trace draft: string = '';
  @Trace sending: boolean = false;
  @Trace models: LlmModelOptionView[] = [];
  /** 选中的模型 / 档位（''=默认；不传则服务端沿用默认，同会话页「没动过不传」） */
  @Trace modelValue: string = '';
  @Trace thinkingValue: string = '';
  /** 附件（同会话页：一条消息最多 4 张，先上传拿 attachment_id） */
  @Trace attachments: AgentAttachment[] = [];
  @Trace uploading: number = 0;
  @Trace uploadError: string = '';
  @Trace skills: SkillView[] = [];
  /** 面板种类：＋（上传图片/技能）| 模型 | 同意说明（第一次发送前） */
  @Trace sheetKind: string = 'plus';

  private constructor() {
  }

  /** 管理员才可见（同 iOS：快捷输入是管理员入口） */
  isAdmin(): boolean {
    return Permissions.fromSession(AppModel.shared.session).isAdmin;
  }

  /** 拉模型清单（进主界面时调一次；非管理员不拉） */
  loadModels(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || !this.isAdmin()) {
      return;
    }
    AgentCatalog.modelOptions(api).then((list: LlmModelOptionView[]): void => {
      this.models = list;
    }).catch((): void => {
    });
  }

  /** ＋面板打开时拉一次技能清单（同会话页） */
  loadSkillsForMenu(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    api.skillsList().then((list: SkillView[]): void => {
      this.skills = list;
    }).catch((): void => {
    });
  }

  /** 能不能发（同 iOS：没在发、没有上传中的图、草稿或图片非空） */
  canSend(): boolean {
    if (this.sending || this.uploading > 0) {
      return false;
    }
    return this.draft.trim().length > 0 || this.attachments.length > 0;
  }

  /**
   * 能发就发；第一次发要先同意——用**系统官方 AlertDialog** 弹说明，返回 'consent'。
   * 同意后自己接着发（调用方不用再处理）。
   * 返回：'sent' 已发送并跳会话页 | 'consent' 已弹官方同意说明 | 'empty' 不可发 | 'failed' 发送失败。
   */
  async maybeSend(ui: UIContext): Promise<string> {
    if (this.sending || !this.canSend()) {
      return 'empty';
    }
    if (!AgentAIConsent.granted) {
      const providers: string[] = AgentAIConsent.providers(this.models);
      AgentAIConsent.showPrompt(ui, providers, (): void => {
        AgentAIConsent.grant().catch((): void => {
        });
        this.maybeSend(ui);
      });
      return 'consent';
    }
    const ok: boolean = await this.send();
    return ok ? 'sent' : 'failed';
  }

  /** 发送 = 新建会话并跳进对话页（推到**当前页签**的栈上）；带图时文字可空 */
  async send(): Promise<boolean> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const content: string = this.draft.trim();
    if (api === null || this.sending || (content.length === 0 && this.attachments.length === 0)) {
      return false;
    }
    this.sending = true;
    try {
      const payload: SessionStartPayload = {
        content: content
      };
      if (this.attachments.length > 0) {
        const ids: string[] = [];
        for (const attachment of this.attachments) {
          ids.push(attachment.attachmentId);
        }
        payload.attachments = ids;
      }
      if (this.modelValue.length > 0) {
        payload.model = this.modelValue;
      }
      if (this.thinkingValue.length > 0) {
        payload.thinking_level = this.thinkingValue;
      }
      const accepted: SessionMessageAcceptedView = await api.sessionStart(payload);
      AgentSessionsSignal.shared.bump();
      this.draft = '';
      this.attachments = [];
      this.uploadError = '';
      const stack: NavPathStack | null = NavStacks.of(NavStacks.currentKey);
      if (stack !== null) {
        stack.pushPathByName('chat', new ChatParams(accepted.session_id));
      }
      return true;
    } catch (error) {
      return false;
    } finally {
      this.sending = false;
    }
  }

  /** 还能再加几张（同 iOS：一条消息最多 4 张） */
  canAddImages(): boolean {
    return this.attachments.length + this.uploading < AgentAttachments.MAX_PER_MESSAGE;
  }

  /** 三种来源共用：选 → 压缩 → 上传 → 进托盘（逐张，失败只提示不打断其它） */
  async addImages(source: string, context: common.UIAbilityContext): Promise<void> {
    this.uploadError = '';
    const client = AppModel.shared.client;
    if (client === null) {
      return;
    }
    const room: number = AgentAttachments.MAX_PER_MESSAGE - this.attachments.length - this.uploading;
    if (room <= 0) {
      this.uploadError = `一条消息最多发送 ${AgentAttachments.MAX_PER_MESSAGE} 张图片`;
      return;
    }
    let uris: string[] = [];
    try {
      if (source === 'library') {
        uris = await AgentAttachments.pickFromLibrary(room);
      } else if (source === 'camera') {
        const shot: string = await AgentAttachments.capture(context);
        uris = shot.length > 0 ? [shot] : [];
      } else {
        uris = await AgentAttachments.pickFiles(context, room);
      }
    } catch (error) {
      this.uploadError = '打开选择器失败，请重试';
      return;
    }
    if (uris.length === 0) {
      return;
    }
    if (uris.length > room) {
      this.uploadError = `一条消息最多发送 ${AgentAttachments.MAX_PER_MESSAGE} 张图片`;
      uris = uris.slice(0, room);
    }
    for (const uri of uris) {
      this.uploading += 1;
      try {
        const attachment: AgentAttachment = await AgentAttachments.prepareAndUpload(client, context,
          uri, '');
        this.attachments = this.attachments.concat([attachment]);
      } catch (error) {
        this.uploadError = this.messageOf(error);
      } finally {
        this.uploading -= 1;
      }
    }
  }

  removeAttachment(attachmentId: string): void {
    const kept: AgentAttachment[] = [];
    for (const item of this.attachments) {
      if (item.attachmentId !== attachmentId) {
        kept.push(item);
      }
    }
    this.attachments = kept;
  }

  /** 技能插进草稿（token 形态，服务端发送时展开；同 iOS 的 chip 行） */
  insertSkill(name: string): void {
    const token: string = AgentSkillText.token(name);
    this.draft = this.draft.length === 0 ? token : `${token}${this.draft}`;
  }

  /** 工具行上的模型文案（同会话页：`resolve(...)?.label ?? '模型'`） */
  modelLabel(): string {
    const hit: LlmModelOptionView | null = AgentCatalog.resolve(this.models, this.modelValue);
    return hit !== null ? hit.label : '模型';
  }

  /** 当前生效模型的档位菜单 */
  thinkingStops(): string[] {
    const hit: LlmModelOptionView | null = AgentCatalog.resolve(this.models, this.modelValue);
    return hit === null ? [] : AgentThinking.stops(hit.thinking_levels);
  }

  /** 附件托盘要有内容才占位（同会话页 `tray` 的出现条件） */
  trayVisible(): boolean {
    return this.attachments.length > 0 || this.uploading > 0 || this.uploadError.length > 0;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }
}

/** 发送/＋/发送三枚控件的公共尺寸字体（迷你条里缩到 32） */

/**
 * 「我的」页输入卡：未聚焦一行小入口（＋ | 输入 | 发送），
 * 聚焦展开成完整输入框（附件托盘 + 多行输入 + ＋ / 模型胶囊 / 发送）。
 */
@ComponentV2
export struct AgentQuickInput {
  @Local private model: AppModel = AppModel.shared;
  @Local private chrome: ShellChrome = ShellChrome.shared;
  @Local private tabBarStyle: TabBarStyle = TabBarStyle.shared();
  @Local private store: AgentComposerStore = AgentComposerStore.shared();
  /** 展开成完整输入框（聚焦时展开；键盘收起且没内容时折回一行）——经典底栏的卡内展开 */
  @Local private expanded: boolean = false;
  @Local private showComposerSheet: boolean = false;
  /** 键盘高度（vp）：弹出把输入卡顶上去 */
  @Local private keyboardInset: number = 0;
  /** 折叠态输入行的实测高：覆盖层（＋/发送）跟着它走，系统字号放大也不错位 */
  @Local private inputLineHeight: number = COLLAPSED_LINE;
  private keyboardWindow: window.Window | null = null;

  aboutToAppear(): void {
    this.observeKeyboard();
  }

  aboutToDisappear(): void {
    if (this.keyboardWindow !== null) {
      this.keyboardWindow.off('keyboardHeightChange');
      this.keyboardWindow = null;
    }
  }

  /** 仅由「我的」导航宿主挂载；整屏页压上来时隐藏。 */
  private visible(): boolean {
    if (this.chrome.immersive) {
      return false;
    }
    return this.store.isAdmin();
  }

  /** 监听输入法高度：弹出把输入卡顶上去；收起且没内容时折回一行 */
  private observeKeyboard(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window): void => {
      this.keyboardWindow = win;
      win.on('keyboardHeightChange', (height: number): void => {
        const inset: number = height > 0 ? px2vp(height) : 0;
        if (inset === 0 && this.store.draft.trim().length === 0 && this.store.attachments.length === 0
          && this.store.uploadError.length === 0) {
          this.expanded = false;
        }
        this.keyboardInset = inset;
      });
    }).catch((): void => {
    });
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private vpOf(len: Length): number {
    if (typeof len === 'number') {
      return len;
    }
    if (typeof len === 'string' && len.length > 0) {
      return Number(len);
    }
    return 0;
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        // 主体：托盘 + 输入 +（展开时的）工具行。输入框节点不随状态重建（聚焦不丢）
        Column() {
          if (this.store.trayVisible()) {
            this.Tray()
          }
          TextArea({ text: this.store.draft, placeholder: '给 AI 助手发消息' })
            .width('100%')
            .fontSize(15)
            .fontColor(Theme.text)
            .placeholderColor(Theme.textMuted)
            .backgroundColor(Color.Transparent)
            .padding({
              // 折叠态左右各留 52：两端被 ＋/发送覆盖层各占 36 + 8 空隙，不给位文字会压在＋上
              left: this.expanded ? 14 : 52,
              right: this.expanded ? 14 : 52,
              top: this.expanded ? 16 : 12,
              bottom: this.expanded ? 14 : 12
            })
            .maxLines(this.expanded ? 6 : 1)
            .barState(BarState.Off)
            .onChange((value: string): void => {
              this.store.draft = value;
            })
            .onFocus((): void => {
              this.expanded = true;
            })

          if (this.expanded) {
            Row({ space: 8 }) {
              this.PlusButton()
              if (this.store.models.length > 0) {
                this.ModelCapsule()
              }
              Blank()
              this.SendButton()
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
        }
        .width('100%')
        .onAreaChange((_old: Area, area: Area): void => {
          // 只记折叠态的行高：展开态含托盘/工具行，不能拿来定位折叠覆盖层
          if (!this.expanded) {
            const h: number = this.vpOf(area.height);
            if (h > 0) {
              this.inputLineHeight = h;
            }
          }
        })

        // 折叠态：＋ 和发送叠在输入行两端（空位让触摸穿透到输入框）。
        // 定高而非 100%——否则把外层 Stack 撑到整页高，见 COLLAPSED_LINE 的注释。
        if (!this.expanded) {
          Row() {
            this.PlusButton()
            this.SendButton()
          }
          .width('100%')
          .height(this.inputLineHeight)
          .justifyContent(FlexAlign.SpaceBetween)
          .hitTestBehavior(HitTestMode.Transparent)
        }
      }
      .width('100%')
      .padding(8)
      .bindSheet($$this.showComposerSheet, this.PanelSheet(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: Theme.bg
      })
    }
    .width('calc(100% - 32vp)')
    .backgroundColor('rgba(18, 21, 27, 0.96)')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .borderRadius(26)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.07)' })
    .margin({
      /*
       * 键盘弹出时贴键盘；否则抬到官方贴底页签栏上方：栏高 56 + 手势区，再留 12 呼吸。
       */
      bottom: this.keyboardInset > 0 ? 8 : BAR_LIFT_DOCKED + 56 + (this.tabBarStyle.floating ? 12 : 0) + WindowInsets.shared().bottom
    })
    .id('app-more-ai-input')
    .visibility(this.visible() ? Visibility.Visible : Visibility.None)
  }

  /** ＋：36 圆、白 9% 底，开「上传图片 / 使用技能」面板（同 iOS `AgentComposer`） */
  @Builder
  PlusButton() {
    Button() {
      Row() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
      }
      .width(CONTROL)
      .height(CONTROL)
      .justifyContent(FlexAlign.Center)
    }
    .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
    .padding(0)
    .clip(true)
    .borderRadius(CONTROL / 2)
    .onClick((): void => {
      this.store.sheetKind = 'plus';
      this.showComposerSheet = true;
      this.store.loadSkillsForMenu();
    })
  }

  /** 模型胶囊：高 36、白 9% 底、档位灰字（同 iOS `AgentComposer` 的模型胶囊） */
  @Builder
  ModelCapsule() {
    Button() {
      Row({ space: 6 }) {
        Text(this.store.modelLabel())
          .fontSize(15)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.store.thinkingValue.length > 0) {
          Text(AgentThinking.label(this.store.thinkingValue))
            .fontSize(15)
            .fontColor(Theme.textFaint)
            .maxLines(1)
        }
      }
      .height(CONTROL)
      .padding({ left: 14, right: 14 })
      .constraintSize({ maxWidth: 210 })
    }
    .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
    .padding(0)
    .clip(true)
    .borderRadius(CONTROL / 2)
    .onClick((): void => {
      this.store.sheetKind = 'model';
      this.showComposerSheet = true;
    })
  }

  /** 发送：36 圆、蓝紫渐变（iOS userFill）、上箭头，不可发时压暗（同 iOS） */
  @Builder
  SendButton() {
    Row() {
      SymbolGlyph($r('sys.symbol.arrow_up'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor([Color.White])
    }
    .width(CONTROL)
    .height(CONTROL)
    .justifyContent(FlexAlign.Center)
    .linearGradient({ angle: 135, colors: [['#2F6BD8', 0], ['#6A4BD8', 1]] })
    .borderRadius(CONTROL / 2)
    .opacity(this.store.canSend() ? 1 : 0.45)
    .onClick((): void => {
      this.submitFromCard();
    })
  }

  /** 卡上发送：可发即发；第一次发送由官方 AlertDialog 征求同意（同意后自动接着发） */
  private submitFromCard(): void {
    this.store.maybeSend(this.getUIContext()).then((result: string): void => {
      if (result === 'consent') {
        this.showComposerSheet = true;
      } else if (result === 'failed') {
        this.toast('发送失败，请重试');
      }
      // 'sent'：已跳会话页；'empty'：不可发（按钮本来就压暗）
    });
  }

  /** 附件托盘：缩略图 + 文件名 + 移除；上传中/失败也在这条上交代（同会话页 `Tray`） */
  @Builder
  Tray() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.store.attachments, (attachment: AgentAttachment) => {
        Row({ space: 8 }) {
          Image(attachment.uri)
            .width(28)
            .height(28)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
            .backgroundColor('rgba(255, 255, 255, 0.08)')
          Text(attachment.name)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 110 })
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(11)
            .fontColor([Theme.textFaint])
            .onClick((): void => {
              this.store.removeAttachment(attachment.attachmentId);
            })
        }
        .padding(4)
        .backgroundColor('rgba(255, 255, 255, 0.05)')
        .borderRadius(8)
        .border({ width: 1, color: 'rgba(255, 255, 255, 0.06)' })
        .margin({ right: 8, bottom: 4 })
      }, (attachment: AgentAttachment): string => `att-${attachment.attachmentId}`)

      if (this.store.uploading > 0) {
        Row({ space: 6 }) {
          LoadingProgress().width(14).height(14).color(Theme.textFaint)
          Text('上传中…').fontSize(12).fontColor(Theme.textFaint)
        }
        .height(36)
        .padding({ left: 10, right: 10 })
        .backgroundColor('rgba(255, 255, 255, 0.05)')
        .borderRadius(8)
        .margin({ right: 8, bottom: 4 })
      }
      if (this.store.uploadError.length > 0) {
        Text(this.store.uploadError)
          .fontSize(12)
          .fontColor(Theme.danger)
          .height(36)
          .margin({ bottom: 4 })
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 12 })
  }

  /** 弹层内容：模型面板 / ＋面板（单槽位轮换；同意说明改由官方 AlertDialog 呈现） */
  @Builder
  PanelSheet() {
    if (this.store.sheetKind === 'model') {
      this.ModelSheet()
    } else {
      this.PlusSheet()
    }
  }

  /** 「＋」面板：上传图片 / 使用技能（同会话页 `PlusSheet`） */
  @Builder
  PlusSheet() {
    Column({ space: 8 }) {
      if (this.store.canAddImages()) {
        Text('上传图片')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 10, top: 4 })
        this.PlusRow('照片图库', 'sys.symbol.ohos_photo', 'library')
        this.PlusRow('拍照', 'sys.symbol.camera', 'camera')
        this.PlusRow('选取文件', 'sys.symbol.folder', 'files')
        Divider().strokeWidth(0.5).color(Theme.line).margin({ left: 10, right: 10, top: 4 })
      }
      Text('使用技能')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 10, top: 4 })
      if (this.store.skills.length === 0) {
        Text('暂无可用技能')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .padding({ left: 10, bottom: 12 })
      } else {
        List() {
          ForEach(this.store.skills, (skill: SkillView) => {
            ListItem() {
              Column({ space: 2 }) {
                Text(skill.name)
                  .fontSize(14)
                  .fontColor(Theme.text)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                if (skill.description.length > 0) {
                  Text(skill.description)
                    .fontSize(12)
                    .fontColor(Theme.textFaint)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .onClick((): void => {
                this.store.insertSkill(skill.name);
                this.showComposerSheet = false;
              })
            }
          }, (skill: SkillView): string => `skill-${skill.name}`)
        }
        .width('100%')
        .height(this.store.skills.length > 5 ? 260 : this.store.skills.length * 56)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, bottom: 16 })
    .backgroundColor(Theme.bg)
  }

  /** 「＋」面板里的一行（上传图片来源；同会话页 `PlusRow`） */
  @Builder
  PlusRow(title: string, symbol: string, source: string) {
    Row({ space: 10 }) {
      SymbolGlyph($r(symbol))
        .fontSize(16)
        .fontColor([Theme.textMuted])
      Text(title)
        .fontSize(14)
        .fontColor(Theme.text)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .onClick((): void => {
      this.showComposerSheet = false;
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.store.addImages(source, context);
    })
  }

  /** 模型 + 思维链档位快选（同会话页 `ModelSheet`：选模型收起，调档位不收起） */
  @Builder
  ModelSheet() {
    Column({ space: 8 }) {
      Text('模型')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 10, top: 4 })
      List() {
        ForEach(this.store.models, (option: LlmModelOptionView) => {
          ListItem() {
            Row() {
              Text(option.label)
                .fontSize(14)
                .fontColor(this.store.modelValue === option.ref ||
                (this.store.modelValue.length === 0 && option.is_default)
                  ? Theme.text : Theme.textMuted)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.store.modelValue === option.ref ||
                (this.store.modelValue.length === 0 && option.is_default)) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(13)
                  .fontColor([Theme.text])
              }
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 9, bottom: 9 })
            .onClick((): void => {
              // 选回默认项即「默认」（不传，服务端用默认实例的默认模型）
              this.store.modelValue = option.is_default ? '' : option.ref;
              // 换模型后旧档位可能不在新菜单里，显式清回默认
              this.store.thinkingValue = '';
              this.showComposerSheet = false;
            })
          }
        }, (option: LlmModelOptionView): string => `model-${option.ref}`)
      }
      .width('100%')
      .height(this.store.models.length > 5 ? 240 : this.store.models.length * 40)
      .scrollBar(BarState.Off)

      Divider().strokeWidth(0.5).color(Theme.line).margin({ left: 10, right: 10, top: 4, bottom: 4 })

      if (this.store.thinkingStops().length === 0) {
        Text('该模型不支持调节思考强度')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .padding({ left: 10, bottom: 6 })
      } else {
        Text(`思维链强度 · ${AgentThinking.label(this.store.thinkingValue)}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .padding({ left: 10 })
        Flex({ wrap: FlexWrap.Wrap }) {
          this.ThinkingChip('', '默认')
          ForEach(this.store.thinkingStops(), (level: string) => {
            this.ThinkingChip(level, AgentThinking.label(level))
          }, (level: string): string => `stop-${level}`)
        }
        .width('100%')
        .padding({ left: 10, right: 10, bottom: 8 })
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, bottom: 16 })
    .backgroundColor(Theme.bg)
  }

  @Builder
  ThinkingChip(level: string, label: string) {
    Button() {
      Text(label)
        .fontSize(13)
        .fontColor(this.store.thinkingValue === level ? '#0b0d12' : Theme.textMuted)
    }
    .attributeModifier(new GlassButtonModifier(this.store.thinkingValue === level ? GlassTone.Primary : GlassTone.Secondary))
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .borderRadius(14)
    .margin({ right: 8, top: 8 })
    .onClick((): void => {
      this.store.thinkingValue = level;
    })
  }

}

/**
 * **悬浮胶囊模式**嵌在页签胶囊里的迷你条（`HdsTabsFloatingStyle.miniBar` 的内容，
 * 同华为音乐迷你播放条）：＋ | 草稿/提示文案 | 发送，一行占满胶囊高度。
 * 点整条打开半屏输入面板；有草稿时发送键可直接发。背景来自页签栏的沉浸光感材质，
 * 这里只画内容（透明）。
 */
@ComponentV2
export struct AgentMiniBar {
  /** 打开半屏输入面板（宿主把 showAgentComposer 置 true） */
  @Require @Param onOpen: () => void;
  @Local private store: AgentComposerStore = AgentComposerStore.shared();

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 迷你条上的发送：有内容直接发（要同意就开面板展示），没内容开面板去输入 */
  private sendOrOpen(): void {
    this.store.maybeSend(this.getUIContext()).then((result: string): void => {
      if (result === 'sent' || result === 'consent') {
        return;
      }
      this.onOpen();
      if (result === 'failed') {
        this.toast('发送失败，请重试');
      }
    });
  }

  build() {
    Row({ space: 10 }) {
      Button() {
        Row() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(16)
            .fontColor([Theme.textMuted])
        }
        .width(32)
        .height(32)
        .justifyContent(FlexAlign.Center)
      }
      .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
      .padding(0)
      .clip(true)
      .borderRadius(16)
      .onClick((): void => {
        this.onOpen();
      })

      Text(this.store.draft.length > 0 ? this.store.draft : '给 AI 助手发消息')
        .fontSize(15)
        .fontColor(this.store.draft.length > 0 ? Theme.text : Theme.textMuted)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .onClick((): void => {
          this.onOpen();
        })

      Row() {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor([Color.White])
      }
      .width(32)
      .height(32)
      .justifyContent(FlexAlign.Center)
      .linearGradient({ angle: 135, colors: [['#2F6BD8', 0], ['#6A4BD8', 1]] })
      .borderRadius(16)
      .opacity(this.store.canSend() ? 1 : 0.45)
      .onClick((): void => {
        this.sendOrOpen();
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12 })
    .onClick((): void => {
      this.onOpen();
    })
  }
}

/**
 * **悬浮胶囊模式**的半屏输入面板（迷你条点开的完整输入界面）：
 * 多行输入 + 附件托盘 + ＋ / 模型胶囊 / 发送；第一次发送前内联同意说明。
 * 发送成功直接跳进对话页（`AgentComposerStore.send` 推当前页签的栈）。
 *
 * **不用 bindSheet**：全屏布局窗口下 sheet 的键盘避让（TRANSLATE/RESIZE/NONE）全部
 * 不够准——默认模式工具行被键盘压掉一半，NONE + 手动 padding 又双重避让悬空。
 * 这里改成主窗口内的自绘浮层（遮罩 + 底部卡片），键盘避让走和底栏卡同一套
 * `keyboardHeightChange` 手动抬升，几何完全可控（像素级验证过）。
 */
@ComponentV2
export struct AgentComposerPanel {
  /** 关闭半屏面板（发送成功 / 用户收起） */
  @Require @Param onClose: () => void;
  @Local private store: AgentComposerStore = AgentComposerStore.shared();
  @Local private tabBarStyle: TabBarStyle = TabBarStyle.shared();
  /** ＋ / 模型子面板（嵌在面板内容根上，编辑器不被顶掉） */
  @Local private showPanel: boolean = false;
  @Local private panelKind: string = 'plus';
  /** 键盘高度（vp）：弹出把面板顶到键盘上面（同底栏卡的手动避让） */
  @Local private keyboardInset: number = 0;
  private keyboardWindow: window.Window | null = null;

  aboutToAppear(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window): void => {
      this.keyboardWindow = win;
      win.on('keyboardHeightChange', (height: number): void => {
        this.keyboardInset = height > 0 ? px2vp(height) : 0;
      });
    }).catch((): void => {
    });
  }

  aboutToDisappear(): void {
    if (this.keyboardWindow !== null) {
      this.keyboardWindow.off('keyboardHeightChange');
      this.keyboardWindow = null;
    }
  }

  /** 面板卡底边要让开的高度：迷你条胶囊（两行 112 + 抬起 12 + 呼吸 8）或贴底栏。
   * 键盘避让交给窗口的 OFFSET 模式（聚焦输入框时系统把窗口内容抬到键盘上面）——
   * 工具行放在输入框**上方**，跟着输入框一起被抬上去，这里不再手动加键盘高度
   * （手动 + 系统会双重避让，实测面板悬到屏幕顶部）。 */
  private panelBottom(): number {
    // 全屏铺满后根容器不再让底部安全区：这里自己把「手势区」算进去
    const bottom: number = WindowInsets.shared().bottom;
    return this.tabBarStyle.floating ? 132 + bottom : 76 + bottom;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 遮罩：点一下收起面板
      Button() {
        Column()
        .width('100%')
        .height('100%')
      }
      .attributeModifier(new GlassButtonModifier(GlassTone.Dark))
      .padding(0)
      .clip(true)
      .onClick((): void => {
        this.onClose();
      })

      // 面板卡：贴着迷你条胶囊上方，键盘弹出时整体上抬
      Column() {
          if (this.store.trayVisible()) {
            this.Tray()
          }

          Row({ space: 8 }) {
            Button() {
              Row() {
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(18)
                  .fontColor([Theme.textMuted])
              }
              .width(CONTROL)
              .height(CONTROL)
              .justifyContent(FlexAlign.Center)
            }
            .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
            .padding(0)
            .clip(true)
            .borderRadius(CONTROL / 2)
            .onClick((): void => {
              this.panelKind = 'plus';
              this.store.loadSkillsForMenu();
              this.showPanel = true;
            })

            if (this.store.models.length > 0) {
              Button() {
                Row({ space: 6 }) {
                  Text(this.store.modelLabel())
                    .fontSize(15)
                    .fontColor(Theme.text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.store.thinkingValue.length > 0) {
                    Text(AgentThinking.label(this.store.thinkingValue))
                      .fontSize(15)
                      .fontColor(Theme.textFaint)
                      .maxLines(1)
                  }
                }
                .height(CONTROL)
                .padding({ left: 14, right: 14 })
                .constraintSize({ maxWidth: 210 })
              }
              .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
              .padding(0)
              .clip(true)
              .borderRadius(CONTROL / 2)
              .onClick((): void => {
                this.panelKind = 'model';
                this.showPanel = true;
              })
            }

            Blank()

            Row() {
              SymbolGlyph($r('sys.symbol.arrow_up'))
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor([Color.White])
            }
            .width(CONTROL)
            .height(CONTROL)
            .justifyContent(FlexAlign.Center)
            .linearGradient({ angle: 135, colors: [['#2F6BD8', 0], ['#6A4BD8', 1]] })
            .borderRadius(CONTROL / 2)
            .opacity(this.store.canSend() ? 1 : 0.45)
            .onClick((): void => {
              this.store.maybeSend(this.getUIContext()).then((result: string): void => {
                if (result === 'sent') {
                  this.onClose();
                } else if (result === 'failed') {
                  this.toast('发送失败，请重试');
                }
                // 'consent'：已弹官方同意说明，同意后自动接着发
              });
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          TextArea({ text: this.store.draft, placeholder: '给 AI 助手发消息' })
            .width('100%')
            .fontSize(15)
            .fontColor(Theme.text)
            .placeholderColor(Theme.textMuted)
            .backgroundColor(Color.Transparent)
            .padding({ left: 6, right: 6, top: 8, bottom: 8 })
            .maxLines(6)
            .barState(BarState.Off)
            .defaultFocus(true)
            .onChange((value: string): void => {
              this.store.draft = value;
            })
      }
      .width('100%')
      .constraintSize({ maxHeight: '58%' })
        .backgroundColor(Theme.bg)
        .borderRadius({ topLeft: 24, topRight: 24 })
        .padding({ left: 14, right: 14, top: 10, bottom: 16 })
        // 底边让开迷你条胶囊/贴底栏，键盘弹出时再让开键盘高度
        .margin({ bottom: this.panelBottom() })
        .bindSheet($$this.showPanel, this.PanelSheet(), {
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          showClose: false,
          backgroundColor: Theme.bg
        })
      }
      .width('100%')
      .height('100%')
  }

  /** 附件托盘（同会话页 `Tray`） */
  @Builder
  Tray() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.store.attachments, (attachment: AgentAttachment) => {
        Row({ space: 8 }) {
          Image(attachment.uri)
            .width(28)
            .height(28)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
            .backgroundColor('rgba(255, 255, 255, 0.08)')
          Text(attachment.name)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 110 })
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(11)
            .fontColor([Theme.textFaint])
            .onClick((): void => {
              this.store.removeAttachment(attachment.attachmentId);
            })
        }
        .padding(4)
        .backgroundColor('rgba(255, 255, 255, 0.05)')
        .borderRadius(8)
        .border({ width: 1, color: 'rgba(255, 255, 255, 0.06)' })
        .margin({ right: 8, bottom: 4 })
      }, (attachment: AgentAttachment): string => `att-${attachment.attachmentId}`)

      if (this.store.uploading > 0) {
        Row({ space: 6 }) {
          LoadingProgress().width(14).height(14).color(Theme.textFaint)
          Text('上传中…').fontSize(12).fontColor(Theme.textFaint)
        }
        .height(36)
        .padding({ left: 10, right: 10 })
        .backgroundColor('rgba(255, 255, 255, 0.05)')
        .borderRadius(8)
        .margin({ right: 8, bottom: 4 })
      }
      if (this.store.uploadError.length > 0) {
        Text(this.store.uploadError)
          .fontSize(12)
          .fontColor(Theme.danger)
          .height(36)
          .margin({ bottom: 4 })
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 12 })
  }

  /** 子面板：＋（上传/技能）| 模型（单槽位轮换，同卡片） */
  @Builder
  PanelSheet() {
    if (this.panelKind === 'model') {
      this.ModelPanel()
    } else {
      this.PlusPanel()
    }
  }

  @Builder
  PlusPanel() {
    Column({ space: 8 }) {
      if (this.store.canAddImages()) {
        Text('上传图片')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ left: 10, top: 4 })
        this.PanelRow('照片图库', 'sys.symbol.ohos_photo', 'library')
        this.PanelRow('拍照', 'sys.symbol.camera', 'camera')
        this.PanelRow('选取文件', 'sys.symbol.folder', 'files')
        Divider().strokeWidth(0.5).color(Theme.line).margin({ left: 10, right: 10, top: 4 })
      }
      Text('使用技能')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 10, top: 4 })
      if (this.store.skills.length === 0) {
        Text('暂无可用技能')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .padding({ left: 10, bottom: 12 })
      } else {
        List() {
          ForEach(this.store.skills, (skill: SkillView) => {
            ListItem() {
              Column({ space: 2 }) {
                Text(skill.name)
                  .fontSize(14)
                  .fontColor(Theme.text)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                if (skill.description.length > 0) {
                  Text(skill.description)
                    .fontSize(12)
                    .fontColor(Theme.textFaint)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .onClick((): void => {
                this.store.insertSkill(skill.name);
                this.showPanel = false;
              })
            }
          }, (skill: SkillView): string => `skill-${skill.name}`)
        }
        .width('100%')
        .height(this.store.skills.length > 5 ? 260 : this.store.skills.length * 56)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, bottom: 16 })
    .backgroundColor(Theme.bg)
  }

  @Builder
  PanelRow(title: string, symbol: string, source: string) {
    Row({ space: 10 }) {
      SymbolGlyph($r(symbol))
        .fontSize(16)
        .fontColor([Theme.textMuted])
      Text(title)
        .fontSize(14)
        .fontColor(Theme.text)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .onClick((): void => {
      this.showPanel = false;
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.store.addImages(source, context);
    })
  }

  @Builder
  ModelPanel() {
    Column({ space: 8 }) {
      Text('模型')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: 10, top: 4 })
      List() {
        ForEach(this.store.models, (option: LlmModelOptionView) => {
          ListItem() {
            Row() {
              Text(option.label)
                .fontSize(14)
                .fontColor(this.store.modelValue === option.ref ||
                (this.store.modelValue.length === 0 && option.is_default)
                  ? Theme.text : Theme.textMuted)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.store.modelValue === option.ref ||
                (this.store.modelValue.length === 0 && option.is_default)) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(13)
                  .fontColor([Theme.text])
              }
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 9, bottom: 9 })
            .onClick((): void => {
              this.store.modelValue = option.is_default ? '' : option.ref;
              this.store.thinkingValue = '';
              this.showPanel = false;
            })
          }
        }, (option: LlmModelOptionView): string => `model-${option.ref}`)
      }
      .width('100%')
      .height(this.store.models.length > 5 ? 240 : this.store.models.length * 40)
      .scrollBar(BarState.Off)

      Divider().strokeWidth(0.5).color(Theme.line).margin({ left: 10, right: 10, top: 4, bottom: 4 })

      if (this.store.thinkingStops().length === 0) {
        Text('该模型不支持调节思考强度')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .padding({ left: 10, bottom: 6 })
      } else {
        Text(`思维链强度 · ${AgentThinking.label(this.store.thinkingValue)}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .padding({ left: 10 })
        Flex({ wrap: FlexWrap.Wrap }) {
          Button() {
            Text('默认')
              .fontSize(13)
              .fontColor(this.store.thinkingValue === '' ? '#0b0d12' : Theme.textMuted)
          }
          .attributeModifier(new GlassButtonModifier(this.store.thinkingValue === '' ? GlassTone.Primary : GlassTone.Secondary))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .margin({ right: 8, top: 8 })
          .onClick((): void => {
            this.store.thinkingValue = '';
          })
          ForEach(this.store.thinkingStops(), (level: string) => {
            Button() {
              Text(AgentThinking.label(level))
                .fontSize(13)
                .fontColor(this.store.thinkingValue === level ? '#0b0d12' : Theme.textMuted)
            }
            .attributeModifier(new GlassButtonModifier(this.store.thinkingValue === level ? GlassTone.Primary : GlassTone.Secondary))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .margin({ right: 8, top: 8 })
            .onClick((): void => {
              this.store.thinkingValue = level;
            })
          }, (level: string): string => `stop-${level}`)
        }
        .width('100%')
        .padding({ left: 10, right: 10, bottom: 8 })
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, bottom: 16 })
    .backgroundColor(Theme.bg)
  }
}
