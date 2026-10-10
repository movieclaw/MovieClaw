import { Theme } from '../theme/AppTheme';
import { WindowInsets } from '../common/WindowInsets';
import { AppModel, SignInResult } from '../common/AppModel';
import { DevConfig } from '../common/DevConfig';
import { AppFooter } from '../common/AppFooter';

/** 一句台词：中文（外语片为字幕）+ 原句 + 片名 + 年份（对齐 iOS WelcomeScene，取精简集）。 */
interface WelcomeQuote {
  line: string;
  original: string;
  film: string;
  year: number;
}

function movieclawQuotes(): WelcomeQuote[] {
  return [
    { line: '毕竟，明天又是新的一天。', original: 'After all, tomorrow is another day.', film: '乱世佳人', year: 1939 },
    { line: '我会给他一个无法拒绝的条件。', original: "I'm gonna make him an offer he can't refuse.", film: '教父', year: 1972 },
    { line: '没有什么地方比得上家。', original: "There's no place like home.", film: '绿野仙踪', year: 1939 },
    { line: '我们永远拥有巴黎。', original: "We'll always have Paris.", film: '卡萨布兰卡', year: 1942 },
    { line: '愿原力与你同在。', original: 'May the Force be with you.', film: '星球大战', year: 1977 },
    { line: '爱就是永远不必说抱歉。', original: 'Love means never having to say you\'re sorry.', film: '爱情故事', year: 1970 },
    { line: '是美女杀死了野兽。', original: 'It was Beauty killed the Beast.', film: '金刚', year: 1933 },
    { line: '妈妈说，人生就像一盒巧克力，\n你永远不知道下一块是什么味道。',
      original: 'My mama always said life was like a box of chocolates.\nYou never know what you\'re gonna get.', film: '阿甘正传', year: 1994 },
    { line: '你跳，我也跳。', original: 'You jump, I jump.', film: '泰坦尼克号', year: 1997 },
    { line: '希望是美好的，也许是人间至善，\n而美好的事物永不消逝。',
      original: 'Hope is a good thing, maybe the best of things,\nand no good thing ever dies.', film: '肖申克的救赎', year: 1994 },
    { line: '抓住今天，孩子们，\n让你们的生命超凡脱俗。',
      original: 'Carpe diem. Seize the day, boys.\nMake your lives extraordinary.', film: '死亡诗社', year: 1989 },
    { line: '假如再也见不到你，\n祝你早安、午安、晚安。',
      original: 'In case I don\'t see ya,\ngood afternoon, good evening, and good night!', film: '楚门的世界', year: 1998 },
    { line: '早安，公主！', original: 'Buongiorno, principessa!', film: '美丽人生', year: 1997 },
    { line: '我们唯一能决定的，\n是如何利用被赋予的时间。',
      original: 'All we have to decide is what to do\nwith the time that is given to us.', film: '指环王：护戒使者', year: 2001 },
    { line: '路？我们要去的地方，不需要路。', original: 'Roads? Where we\'re going, we don\'t need roads.', film: '回到未来', year: 1985 },
    { line: '记住你是谁。', original: 'Remember who you are.', film: '狮子王', year: 1994 },
    { line: '飞向宇宙，浩瀚无垠！', original: 'To infinity and beyond!', film: '玩具总动员', year: 1995 },
    { line: '别害怕把梦做得更大一点，亲爱的。', original: 'You mustn\'t be afraid to dream\na little bigger, darling.', film: '盗梦空间', year: 2010 }
  ];
}

/**
 * 欢迎页（对齐 iOS 端 WelcomeView 的鸿蒙版，精简为两态）：
 * - 首页：片名 + 台词轮播 + 底部按钮（未连过服务器叫「连接服务器」，连过叫「登录」）；
 * - 登录卡片：服务器地址 / 用户名 / 密码一步进入（设备令牌登录）。
 *
 * 台词点一下换一句，不点每 9 秒轮换。登录成功后由外壳切进主界面。
 */
@Component
export struct WelcomePage {
  /** 登录成功回调（外壳切页用）；预览态可为空 */
  onSignedIn: () => void = () => {
  };
  /** 是否直接打开登录卡片（登录过期重进时） */
  openFormFirst: boolean = false;
  /** 预填的服务器地址（登录过期时） */
  prefillServer: string = '';
  /** 预填的用户名（登录过期时：只让用户补密码，不用重敲账号） */
  prefillUsername: string = '';

  @State private showForm: boolean = false;
  @State private quotes: WelcomeQuote[] = movieclawQuotes();
  @State private quoteIndex: number = 0;
  @State private addressInput: string = '';
  @State private usernameInput: string = '';
  @State private passwordInput: string = '';
  @State private loggingIn: boolean = false;
  @State private formError: string = '';
  private quoteTimer: number = -1;

  aboutToAppear(): void {
    if (this.openFormFirst) {
      this.showForm = true;
      this.addressInput = this.prefillServer;
      // 登录过期：把用户名也填上（对应 iOS expiredUsername 预填）
      this.usernameInput = this.prefillUsername;
    }
    this.quoteTimer = setInterval(() => {
      this.nextQuote();
    }, 9000);
  }

  aboutToDisappear(): void {
    if (this.quoteTimer >= 0) {
      clearInterval(this.quoteTimer);
      this.quoteTimer = -1;
    }
  }

  private nextQuote(): void {
    this.quoteIndex = (this.quoteIndex + 1) % this.quotes.length;
  }

  /** 开发期快捷登录：一键填入 .env 配置并提交（仅 debug 构建可见） */
  private quickLogin(useLan: boolean): void {
    this.addressInput = useLan ? DevConfig.lanServer : DevConfig.wanServer;
    this.usernameInput = useLan ? DevConfig.lanUsername : DevConfig.wanUsername;
    this.passwordInput = useLan ? DevConfig.lanPassword : DevConfig.wanPassword;
    this.submitLogin();
  }

  private async submitLogin(): Promise<void> {
    if (this.loggingIn) {
      return;
    }
    const address: string = this.addressInput.trim();
    const username: string = this.usernameInput.trim();
    if (address.length === 0 || username.length === 0 || this.passwordInput.length === 0) {
      this.formError = '请填写服务器地址、用户名和密码';
      return;
    }
    this.loggingIn = true;
    this.formError = '';
    try {
      const result: string = await AppModel.shared.signIn(address, username, this.passwordInput);
      if (result === SignInResult.needsSetup) {
        // 全新服务器：先确认一次，再用这组账号密码创建超级管理员（对应 iOS 的 needsSetup 分支）
        this.loggingIn = false;
        this.confirmCreateAdmin(address, username);
        return;
      }
      this.onSignedIn();
    } catch (error) {
      const err = error as Error;
      this.formError = err.message.length > 0 ? err.message : '登录失败，请重试';
    } finally {
      this.loggingIn = false;
    }
  }

  /** 全新服务器：确认后创建超级管理员并直接进入（全生命周期仅一次） */
  private confirmCreateAdmin(address: string, username: string): void {
    this.getUIContext().showAlertDialog({
      title: '这台服务器还没有初始化',
      message: `要用「${username}」创建超级管理员吗？这台服务器是全新的，创建后这个账号就是管理员。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '创建并进入',
        action: (): void => {
          this.createAdmin(address, username);
        }
      }
    });
  }

  private async createAdmin(address: string, username: string): Promise<void> {
    this.loggingIn = true;
    this.formError = '';
    try {
      await AppModel.shared.createAdmin(address, username, this.passwordInput);
      this.onSignedIn();
    } catch (error) {
      const err = error as Error;
      this.formError = err.message.length > 0 ? err.message : '创建管理员失败，请重试';
    } finally {
      this.loggingIn = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 背景：纯黑 + 顶部一点冷银渐晕，呼应「深空」但不自绘星空
      // expandSafeArea 让渐晕一直铺到状态栏下面（窗口默认避让状态栏，不铺会有黑边）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['rgba(120, 140, 175, 0.16)', 0], [Theme.bg, 0.45]]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column({ space: 0 }) {
        this.Masthead()

        Column() {
          Blank()

          if (this.showForm) {
            this.SignInCard()
          } else {
            this.QuoteBlock()
            Blank()
            this.StartButton()
          }
        }
        .width('100%')
        .layoutWeight(1)

        // 页脚：品牌联合声明（MovieClaw × AI × 鸿蒙 携手），复用全局 AppFooter
        AppFooter({ topSpace: 24 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 28, right: 28, top: '18%', bottom: WindowInsets.bottom })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 片名：MovieClaw（Claw 斜体）+ 一道细线 + 副题 */
  @Builder
  Masthead() {
    Column({ space: 14 }) {
      Row() {
        Text('Movie')
          .fontFamily('serif')
          .fontSize(42)
          .fontWeight(FontWeight.Lighter)
          .fontColor(Theme.accentStrong)
        Text('Claw')
          .fontFamily('serif')
          .fontSize(42)
          .fontWeight(FontWeight.Lighter)
          .fontStyle(FontStyle.Italic)
          .fontColor(Theme.accentStrong)
      }

      Divider()
        .color(Theme.textFaint)
        .width(28)
        .strokeWidth(0.5)

      Text('智能影音服务器')
        .fontFamily('serif')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .letterSpacing(8)
    }
    .alignItems(HorizontalAlign.Center)
  }

  /** 台词：中文大字 + 原句斜体 + 出处；点一下换一句 */
  @Builder
  QuoteBlock() {
    Column({ space: 10 }) {
      Text(this.quotes[this.quoteIndex].line)
        .fontFamily('serif')
        .fontSize(18)
        .fontColor(Theme.text)
        .lineHeight(30)
        .textAlign(TextAlign.Center)
      Text(this.quotes[this.quoteIndex].original)
        .fontFamily('serif')
        .fontSize(13)
        .fontStyle(FontStyle.Italic)
        .fontColor(Theme.textMuted)
        .lineHeight(20)
        .textAlign(TextAlign.Center)
      Text(`——《${this.quotes[this.quoteIndex].film}》${this.quotes[this.quoteIndex].year}`)
        .fontFamily('serif')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .letterSpacing(2)
        .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .onClick(() => this.nextQuote())
  }

  @Builder
  StartButton() {
    Button() {
      Text(this.addressInput.length > 0 ? '登录' : '连接服务器')
        .fontFamily('serif')
        .fontSize(17)
        .letterSpacing(4)
        .fontColor(Theme.text)
    }
    .height(48)
    .padding({ left: 28, right: 28 })
    .backgroundColor(Theme.accentSoft)
    .borderRadius(24)
    .onClick(() => {
      this.showForm = true;
    })
  }

  /** 登录卡片：地址 / 用户名 / 密码 + 提交 */
  @Builder
  SignInCard() {
    Column({ space: 16 }) {
      Row() {
        Blank()
        Text('×')
          .fontSize(22)
          .fontColor(Theme.textMuted)
          .padding(8)
          .onClick(() => {
            this.showForm = false;
            this.formError = '';
          })
      }
      .width('100%')

      Text('连接你的服务器')
        .fontFamily('serif')
        .fontSize(22)
        .fontColor(Theme.text)
        .margin({ bottom: 4 })

      if (DevConfig.isDev) {
        Row({ space: 8 }) {
          Button('内网直连')
            .layoutWeight(1)
            .height(34)
            .fontSize(13)
            .fontColor(Theme.accent)
            .backgroundColor(Theme.surfaceRaised)
            .borderRadius(10)
            .enabled(!this.loggingIn)
            .onClick(() => {
              this.quickLogin(true);
            })
          Button('外网穿透')
            .layoutWeight(1)
            .height(34)
            .fontSize(13)
            .fontColor(Theme.accent)
            .backgroundColor(Theme.surfaceRaised)
            .borderRadius(10)
            .enabled(!this.loggingIn)
            .onClick(() => {
              this.quickLogin(false);
            })
        }
        .width('100%')
      }

      TextInput({ placeholder: '服务器地址，如 http://192.168.0.100:3000', text: this.addressInput })
        .height(48)
        .fontSize(15)
        .fontColor(Theme.text)
        .placeholderColor(Theme.textFaint)
        .caretColor(Theme.accent)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(12)
        .onChange((value: string) => {
          this.addressInput = value;
        })

      TextInput({ placeholder: '用户名', text: this.usernameInput })
        .height(48)
        .fontSize(15)
        .fontColor(Theme.text)
        .placeholderColor(Theme.textFaint)
        .caretColor(Theme.accent)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(12)
        .onChange((value: string) => {
          this.usernameInput = value;
        })

      TextInput({ placeholder: '密码', text: this.passwordInput })
        .type(InputType.Password)
        .height(48)
        .fontSize(15)
        .fontColor(Theme.text)
        .placeholderColor(Theme.textFaint)
        .caretColor(Theme.accent)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(12)
        .enterKeyType(EnterKeyType.Done)
        .onChange((value: string) => {
          this.passwordInput = value;
        })
        .onSubmit(() => {
          this.submitLogin();
        })

      if (this.formError.length > 0) {
        Text(this.formError)
          .fontSize(13)
          .fontColor(Theme.danger)
          .width('100%')
      }

      Button(this.loggingIn ? '正在登录…' : '进入')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor('#0b0d12')
        .backgroundColor(Theme.accent)
        .borderRadius(12)
        .enabled(!this.loggingIn)
        .onClick(() => {
          this.submitLogin();
        })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(Theme.surface)
    .borderRadius(20)
    .border({ width: 1, color: Theme.line })
  }
}

@Preview
@Component
struct WelcomePagePreview {
  build() {
    WelcomePage()
  }
}
