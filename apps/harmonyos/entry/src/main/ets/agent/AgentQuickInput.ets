import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { ShellChrome } from '../common/ShellChrome';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { LlmModelOptionView, SessionMessageAcceptedView, SessionStartPayload, SkillView } from '../api/Models';
import { AgentAIConsent, AgentAIConsentSheet } from './AgentAIConsent';
import { AgentAttachment, AgentAttachments } from './AgentAttachments';
import { AgentCatalog, AgentThinking } from './AgentCatalog';
import { AgentSessionsSignal } from './AgentSessionsSignal';
import { AgentSkillText } from './AgentSkills';
import { ChatParams } from './ChatPage';

/**
 * 「我的」页的 AI 快捷输入（对应 iOS `AgentQuickBar` + `AgentComposer` 新样式）：
 * 管理员在「我的」页签底部常驻一块玻璃输入条；未聚焦时是一行小入口
 * （＋ | 输入 | 发送），聚焦后展开成完整输入框（附件托盘 + 多行输入 +
 * ＋ / 模型胶囊 / 发送）。发送 = 新建会话并进入会话页；第一次发送前先走
 * `AgentAIConsent` 同意弹层（同会话页）。草稿、附件与模型选择留在组件里：
 * 组件常驻（显隐用 `visibility`，不卸载），切页签回来还在。
 * 整屏页（会话页等）压上来时由 `ShellChrome` 隐藏——那些页面有自己的输入框。
 */

/** 「我的」页列表内容要多让出的高度（快捷输入条 + 悬浮页签胶囊已在 `tabBarInset` 里） */
export const AGENT_QUICK_CONTENT_EXTRA: number = 60;

/** 快捷输入条在悬浮页签胶囊上方再抬起的高度（胶囊 48 + 抬起 12 + 呼吸 4） */
const BAR_LIFT: number = 64;

/** iOS `AgentComposer` 规范：36 控件、8 间距、外圆角 26、控件底色白 9% */
const CONTROL: number = 36;
const CONTROL_FILL: string = 'rgba(255, 255, 255, 0.09)';

@ComponentV2
export struct AgentQuickInput {
  @Require @Param navStack: NavPathStack;
  @Local private model: AppModel = AppModel.shared;
  @Local private chrome: ShellChrome = ShellChrome.shared;
  /** 草稿：发送前一直留着（切页签不丢，发送成功才清） */
  @Local private draft: string = '';
  /** 展开成完整输入框（聚焦时展开；键盘收起且没内容时折回一行） */
  @Local private expanded: boolean = false;
  @Local private sending: boolean = false;
  @Local private models: LlmModelOptionView[] = [];
  /** 选中的模型 / 档位（''=默认；不传则服务端沿用默认，同会话页「没动过不传」） */
  @Local private modelValue: string = '';
  @Local private thinkingValue: string = '';
  /** 附件（同会话页：一条消息最多 4 张，先上传拿 attachment_id） */
  @Local private attachments: AgentAttachment[] = [];
  @Local private uploading: number = 0;
  @Local private uploadError: string = '';
  @Local private skills: SkillView[] = [];
  /** 模型面板 / ＋面板共用一个 sheet（一个组件只能挂一个 bindSheet） */
  @Local private showComposerSheet: boolean = false;
  @Local private sheetKind: string = '';
  /** 第一次发送前的同意弹层（同会话页） */
  @Local private showConsent: boolean = false;
  @Local private consentProviders: string[] = [];
  @Local private keyboardInset: number = 0;
  private keyboardWindow: window.Window | null = null;

  aboutToAppear(): void {
    this.loadModels();
    this.observeKeyboard();
    AgentAIConsent.load();
  }

  aboutToDisappear(): void {
    if (this.keyboardWindow !== null) {
      this.keyboardWindow.off('keyboardHeightChange');
      this.keyboardWindow = null;
    }
  }

  /** 管理员才显示；整屏页压上来时隐藏（会话页有自己的输入框） */
  private visible(): boolean {
    if (this.chrome.immersive) {
      return false;
    }
    return Permissions.fromSession(this.model.session).isAdmin;
  }

  private loadModels(): void {
    const api: MovieClawApi | null = this.model.api;
    if (api === null || !this.visible()) {
      return;
    }
    AgentCatalog.modelOptions(api).then((list: LlmModelOptionView[]): void => {
      this.models = list;
    }).catch((): void => {
    });
  }

  /** 监听输入法高度：弹出把输入条顶上去；收起且没内容时折回一行 */
  private observeKeyboard(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window): void => {
      this.keyboardWindow = win;
      win.on('keyboardHeightChange', (height: number): void => {
        const inset: number = height > 0 ? px2vp(height) : 0;
        if (inset === 0 && this.draft.trim().length === 0 && this.attachments.length === 0
          && this.uploadError.length === 0) {
          this.expanded = false;
        }
        this.keyboardInset = inset;
      });
    }).catch((): void => {
    });
  }

  // MARK: 动作

  /** 能不能发（同 iOS：没在发、没有上传中的图、草稿或图片非空） */
  private canSend(): boolean {
    if (this.sending || this.uploading > 0) {
      return false;
    }
    return this.draft.trim().length > 0 || this.attachments.length > 0;
  }

  /** 第一次发给 AI 前先说明去向、取得同意（同会话页：没同意过先弹说明，草稿保留） */
  private submit(): void {
    if (!this.canSend()) {
      return;
    }
    if (!AgentAIConsent.granted) {
      this.askConsent();
      return;
    }
    this.send();
  }

  private askConsent(): void {
    let providers: string[] = AgentAIConsent.providers(this.models);
    if (providers.length === 0) {
      // 模型清单还没回来：现拉一次再弹（去向里要点名服务商）
      const api: MovieClawApi | null = this.model.api;
      if (api === null) {
        return;
      }
      AgentCatalog.modelOptions(api).then((list: LlmModelOptionView[]): void => {
        this.models = list;
        this.consentProviders = AgentAIConsent.providers(list);
        this.showConsent = true;
      }).catch((): void => {
      });
      return;
    }
    this.consentProviders = providers;
    this.showConsent = true;
  }

  /** 发送 = 新建会话并进入会话页（会话页自己接事件流看回答）；带图时文字可空 */
  private async send(): Promise<void> {
    const api: MovieClawApi | null = this.model.api;
    const content: string = this.draft.trim();
    if (api === null || this.sending || this.uploading > 0) {
      return;
    }
    if (content.length === 0 && this.attachments.length === 0) {
      return;
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
      this.expanded = false;
      this.navStack.pushPathByName('chat', new ChatParams(accepted.session_id));
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: '发送失败，请重试' });
    } finally {
      this.sending = false;
    }
  }

  /** 还能再加几张（同 iOS：一条消息最多 4 张） */
  private canAddImages(): boolean {
    return this.attachments.length + this.uploading < AgentAttachments.MAX_PER_MESSAGE;
  }

  /** 三种来源共用：选 → 压缩 → 上传 → 进托盘（逐张，失败只提示不打断其它） */
  private async addImages(source: string): Promise<void> {
    this.uploadError = '';
    this.expanded = true;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
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

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  /** ＋ 面板打开时拉一次技能清单（同会话页） */
  private loadSkillsForMenu(): void {
    const api: MovieClawApi | null = this.model.api;
    if (api === null) {
      return;
    }
    api.skillsList().then((list: SkillView[]): void => {
      this.skills = list;
    }).catch((): void => {
    });
  }

  /** 技能插进草稿（token 形态，服务端发送时展开；同 iOS 的 chip 行） */
  private insertSkill(name: string): void {
    const token: string = AgentSkillText.token(name);
    this.draft = this.draft.length === 0 ? token : `${token}${this.draft}`;
    this.expanded = true;
  }

  /** 工具行上的模型文案（同会话页：`resolve(...)?.label ?? '模型'`） */
  private modelLabel(): string {
    const hit: LlmModelOptionView | null = AgentCatalog.resolve(this.models, this.modelValue);
    return hit !== null ? hit.label : '模型';
  }

  /** 当前生效模型的档位菜单 */
  private thinkingStops(): string[] {
    const hit: LlmModelOptionView | null = AgentCatalog.resolve(this.models, this.modelValue);
    return hit === null ? [] : AgentThinking.stops(hit.thinking_levels);
  }

  /** 附件托盘要有内容才占位（同会话页 `tray` 的出现条件） */
  private trayVisible(): boolean {
    return this.attachments.length > 0 || this.uploading > 0 || this.uploadError.length > 0;
  }

  // MARK: 视图

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        // 主体：托盘 + 输入 +（展开时的）工具行。输入框节点不随状态重建（聚焦不丢）
        Column() {
          if (this.trayVisible()) {
            this.Tray()
          }
          TextArea({ text: this.draft, placeholder: '给 AI 助手发消息' })
            .width('100%')
            .fontSize(15)
            .fontColor(Theme.text)
            .placeholderColor(Theme.textMuted)
            .backgroundColor(Color.Transparent)
            .padding({
              left: 14,
              right: this.expanded ? 14 : 52,
              top: this.expanded ? 16 : 12,
              bottom: this.expanded ? 14 : 12
            })
            .maxLines(this.expanded ? 6 : 1)
            .barState(BarState.Off)
            .onChange((value: string): void => {
              this.draft = value;
            })
            .onFocus((): void => {
              this.expanded = true;
            })

          if (this.expanded) {
            Row({ space: 8 }) {
              this.PlusButton()
              if (this.models.length > 0) {
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

        // 折叠态：＋ 和发送叠在输入行两端（空位让触摸穿透到输入框）
        if (!this.expanded) {
          Row() {
            this.PlusButton()
            this.SendButton()
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.SpaceBetween)
          .hitTestBehavior(HitTestMode.Transparent)
        }
      }
      .width('100%')
      .padding(8)
      .bindSheet($$this.showComposerSheet, this.ComposerSheet(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: Theme.bg
      })
    }
    .width('100%')
    .backgroundColor('rgba(255, 255, 255, 0.05)')
    .borderRadius(26)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.07)' })
    .margin({
      left: 12,
      right: 12,
      // 键盘弹出时贴键盘；否则抬到悬浮页签胶囊上方
      bottom: this.keyboardInset > 0 ? 8 : BAR_LIFT
    })
    .visibility(this.visible() ? Visibility.Visible : Visibility.None)
    .bindSheet($$this.showConsent, this.ConsentSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: Theme.bg,
      onDisappear: (): void => {
        this.showConsent = false;
      }
    })
  }

  /** ＋：36 圆、白 9% 底，开「上传图片 / 使用技能」面板（同 iOS `AgentComposer`） */
  @Builder
  PlusButton() {
    Row() {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(18)
        .fontColor([Theme.textMuted])
    }
    .width(CONTROL)
    .height(CONTROL)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(CONTROL_FILL)
    .borderRadius(CONTROL / 2)
    .onClick((): void => {
      this.sheetKind = 'plus';
      this.showComposerSheet = true;
      this.loadSkillsForMenu();
    })
  }

  /** 模型胶囊：高 36、白 9% 底、档位灰字（同 iOS `AgentComposer` 的模型胶囊） */
  @Builder
  ModelCapsule() {
    Row({ space: 6 }) {
      Text(this.modelLabel())
        .fontSize(15)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.thinkingValue.length > 0) {
        Text(AgentThinking.label(this.thinkingValue))
          .fontSize(15)
          .fontColor(Theme.textFaint)
          .maxLines(1)
      }
    }
    .height(CONTROL)
    .padding({ left: 14, right: 14 })
    .backgroundColor(CONTROL_FILL)
    .borderRadius(CONTROL / 2)
    .constraintSize({ maxWidth: 210 })
    .onClick((): void => {
      this.sheetKind = 'model';
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
    .opacity(this.canSend() ? 1 : 0.45)
    .onClick((): void => {
      this.submit();
    })
  }

  /** 附件托盘：缩略图 + 文件名 + 移除；上传中/失败也在这条上交代（同会话页 `Tray`） */
  @Builder
  Tray() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.attachments, (attachment: AgentAttachment) => {
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
              const kept: AgentAttachment[] = [];
              for (const item of this.attachments) {
                if (item.attachmentId !== attachment.attachmentId) {
                  kept.push(item);
                }
              }
              this.attachments = kept;
            })
        }
        .padding(4)
        .backgroundColor('rgba(255, 255, 255, 0.05)')
        .borderRadius(8)
        .border({ width: 1, color: 'rgba(255, 255, 255, 0.06)' })
        .margin({ right: 8, bottom: 4 })
      }, (attachment: AgentAttachment): string => `att-${attachment.attachmentId}`)

      if (this.uploading > 0) {
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
      if (this.uploadError.length > 0) {
        Text(this.uploadError)
          .fontSize(12)
          .fontColor(Theme.danger)
          .height(36)
          .margin({ bottom: 4 })
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 12 })
  }

  /** 弹层内容：模型面板 / ＋面板（一个 sheet 两个形态，同会话页 `ComposerSheet`） */
  @Builder
  ComposerSheet() {
    if (this.sheetKind === 'model') {
      this.ModelSheet()
    } else {
      this.PlusSheet()
    }
  }

  /** 「＋」面板：上传图片 / 使用技能（同会话页 `PlusSheet`） */
  @Builder
  PlusSheet() {
    Column({ space: 8 }) {
      if (this.canAddImages()) {
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
      if (this.skills.length === 0) {
        Text('暂无可用技能')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .padding({ left: 10, bottom: 12 })
      } else {
        List() {
          ForEach(this.skills, (skill: SkillView) => {
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
                this.insertSkill(skill.name);
                this.showComposerSheet = false;
              })
            }
          }, (skill: SkillView): string => `skill-${skill.name}`)
        }
        .width('100%')
        .height(this.skills.length > 5 ? 260 : this.skills.length * 56)
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
      this.addImages(source);
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
        ForEach(this.models, (option: LlmModelOptionView) => {
          ListItem() {
            Row() {
              Text(option.label)
                .fontSize(14)
                .fontColor(this.modelValue === option.ref || (this.modelValue.length === 0 && option.is_default)
                  ? Theme.text : Theme.textMuted)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.modelValue === option.ref || (this.modelValue.length === 0 && option.is_default)) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(13)
                  .fontColor([Theme.text])
              }
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 9, bottom: 9 })
            .onClick((): void => {
              // 选回默认项即「默认」（不传，服务端用默认实例的默认模型）
              this.modelValue = option.is_default ? '' : option.ref;
              // 换模型后旧档位可能不在新菜单里，显式清回默认
              this.thinkingValue = '';
              this.showComposerSheet = false;
            })
          }
        }, (option: LlmModelOptionView): string => `model-${option.ref}`)
      }
      .width('100%')
      .height(this.models.length > 5 ? 240 : this.models.length * 40)
      .scrollBar(BarState.Off)

      Divider().strokeWidth(0.5).color(Theme.line).margin({ left: 10, right: 10, top: 4, bottom: 4 })

      if (this.thinkingStops().length === 0) {
        Text('该模型不支持调节思考强度')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .padding({ left: 10, bottom: 6 })
      } else {
        Text(`思维链强度 · ${AgentThinking.label(this.thinkingValue)}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .padding({ left: 10 })
        Flex({ wrap: FlexWrap.Wrap }) {
          this.ThinkingChip('', '默认')
          ForEach(this.thinkingStops(), (level: string) => {
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
    Text(label)
      .fontSize(13)
      .fontColor(this.thinkingValue === level ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.thinkingValue === level ? Theme.accent : Theme.glassFill)
      .borderRadius(14)
      .margin({ right: 8, top: 8 })
      .onClick((): void => {
        this.thinkingValue = level;
      })
  }

  /** 第一次发给 AI 前的说明与同意（复用会话页的弹层）：同意后接着发，取消草稿保留 */
  @Builder
  ConsentSheet() {
    AgentAIConsentSheet({
      providers: this.consentProviders,
      onAgree: (): void => {
        AgentAIConsent.grant().catch((): void => {
        });
        this.showConsent = false;
        this.send();
      },
      onCancel: (): void => {
        this.showConsent = false;
      }
    })
  }
}
