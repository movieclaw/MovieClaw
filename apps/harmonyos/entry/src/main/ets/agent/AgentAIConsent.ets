import { preferences } from '@kit.ArkData';
import { Theme } from '../theme/AppTheme';
import { LlmModelOptionView } from '../api/Models';

/**
 * 第一次把消息发给 AI 助手前的说明与同意（对应 iOS `AgentAIConsent`）：
 * App Store 审核条款 5.1.2(i)——个人数据交给第三方 AI 前，要说清楚发到哪里并取得用户同意。
 * 同意记在本机，之后不再询问；取消则这条消息不发，草稿保留。
 */
export class AgentAIConsent {
  private static readonly storeName: string = 'movieclaw_ui';
  private static readonly key: string = 'agent_ai_consent_v1';
  private static store: preferences.Preferences | null = null;
  /**
   * 偏好打开的完成信号（同 AppIconStore.ready 的坑）：
   * init 由 EntryAbility.onCreate 异步触发，读可能发生在它完成前，
   * 不等的话 store 还是 null、读到的永远是默认值。
   */
  private static ready: Promise<void> | null = null;

  static granted: boolean = false;

  /** EntryAbility.onCreate 时调用（同 AppIconStore.init 的时机） */
  static init(context: Context): Promise<void> {
    if (AgentAIConsent.ready === null) {
      AgentAIConsent.ready = AgentAIConsent.open(context);
    }
    return AgentAIConsent.ready;
  }

  private static async open(context: Context): Promise<void> {
    try {
      AgentAIConsent.store = await preferences.getPreferences(context, AgentAIConsent.storeName);
      AgentAIConsent.readGrant();
    } catch (error) {
      AgentAIConsent.store = null;
    }
  }

  private static readGrant(): void {
    const store: preferences.Preferences | null = AgentAIConsent.store;
    if (store === null) {
      return;
    }
    AgentAIConsent.granted = store.getSync(AgentAIConsent.key, false) === true;
  }

  private static async waitReady(): Promise<void> {
    const signal: Promise<void> | null = AgentAIConsent.ready;
    if (signal !== null) {
      await signal;
    }
  }

  /** 读当前状态（await 完成信号后刷新 granted；页面 aboutToAppear 时调） */
  static async load(): Promise<void> {
    await AgentAIConsent.waitReady();
    AgentAIConsent.readGrant();
  }

  static async grant(): Promise<void> {
    AgentAIConsent.granted = true;
    const store: preferences.Preferences | null = AgentAIConsent.store;
    if (store === null) {
      return;
    }
    await store.put(AgentAIConsent.key, true);
    await store.flush();
  }

  /** 说明里点名的服务商：取模型清单里的实例名，去重保序（同 iOS `AgentAIConsent.providers`） */
  static providers(options: LlmModelOptionView[]): string[] {
    const out: string[] = [];
    for (const option of options) {
      const name: string = option.provider_name;
      if (out.indexOf(name) < 0) {
        out.push(name);
      }
    }
    return out;
  }
}

/**
 * 发送前的说明弹层（对应 iOS `AgentAIConsentSheet`）：数据去向、开发者收不到、
 * 在哪里更换服务商。同意后由页面接着发；取消则这条消息不发，草稿保留。
 */
@ComponentV2
export struct AgentAIConsentSheet {
  @Require @Param providers: string[];
  /** 同意（持久化由页面负责）后继续发送 */
  @Require @Param onAgree: () => void;
  /** 取消：这条消息不发 */
  @Require @Param onCancel: () => void;

  private destinationText(): string {
    const current: string = this.providers.length === 0 ? '' : `（当前：${this.providers.join('、')}）`;
    return `你发出的消息和图片，以及助手为了回答而查询的媒体库信息，会由你的 MovieClaw 服务器发送给服务器管理员接入的 AI 模型服务商处理${current}。`;
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          Row({ space: 12 }) {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.wand_and_stars'))
                .fontSize(18)
                .fontColor([Theme.accent])
            }
            .width(32)
            .height(32)
            .backgroundColor(Theme.accentSoft)
            .borderRadius(9)
            Text('使用 AI 助手前')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
          }
          Text(this.destinationText())
            .fontSize(14)
            .fontColor(Theme.text)
            .width('100%')
          Text('MovieClaw 的开发者不会收到这些内容。服务商如何处理数据以其隐私政策为准；服务器管理员可以在「设置 → 模型接入」更换或移除服务商。')
            .fontSize(14)
            .fontColor(Theme.textMuted)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(20)
      }
      .align(Alignment.Top)
      .layoutWeight(1)
      Row({ space: 12 }) {
        Text('取消')
          .fontSize(16)
          .fontColor(Theme.text)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(Theme.cardRadius)
          .onClick(() => {
            this.onCancel();
          })
        Text('同意并发送')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0b0d12')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(Theme.accent)
          .borderRadius(Theme.cardRadius)
          .onClick(() => {
            this.onAgree();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 12 })
    }
    .width('100%')
    .height('100%')
  }
}
