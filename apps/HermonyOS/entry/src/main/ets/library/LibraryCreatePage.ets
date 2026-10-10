import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { LibraryPayload, LibraryView, MediaKind } from '../api/Models';
import { pickFolder } from '../common/FolderPicker';
import { AppFooter } from '../common/AppFooter';

/** 类型卡片（对应 iOS `ManageKindCard`）：文案讲清后果，不提识别用的是哪个数据源 */
class KindCard {
  readonly kind: string;
  readonly symbol: string;
  readonly title: string;
  readonly blurb: string;
  readonly traits: string;

  constructor(kind: string, symbol: string, title: string, blurb: string, traits: string) {
    this.kind = kind;
    this.symbol = symbol;
    this.title = title;
    this.blurb = blurb;
    this.traits = traits;
  }
}

const KIND_CARDS: KindCard[] = [
  new KindCard('movie', 'sys.symbol.film', '电影库',
    '自动识别影片，补齐简介、评分、演职员与海报剧照；一部片一个目录。',
    '可订阅 · 可整理文件名'),
  new KindCard('tv', 'sys.symbol.display', '剧集库',
    '自动识别剧集与季集，补齐分集信息与图片；追新订阅按集补齐。',
    '可订阅 · 可整理文件名'),
  new KindCard('video', 'sys.symbol.video', '视频库',
    '不识别、不刮削、不改名的视频：放什么由你定。有 NFO 就读 NFO，否则按文件名展示。',
    '不识别 · 可播放 · 记进度'),
  new KindCard('photo', 'sys.symbol.picture', '相册库',
    '不识别、不刮削，扫描目录里的所有图片，按拍摄时间排成相册墙。',
    '不识别 · 全屏查看')
];

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function LibraryCreateBuilder() {
  LibraryCreatePage()
}

/**
 * 新建媒体库向导（对应 iOS `ManageCreateLibraryForm`）。
 *
 * iOS 的向导极简，**只问必答题**：① 选类型 → ② 名称、根目录、可见范围 →
 * ③（影视库）收藏范围；扫描开关全按推荐值、刮削偏好覆盖是少数人的精调，都放到编辑里。
 * 最后一步「创建并开始扫描」。
 *
 * 本轮做 ① ② 与创建（`POST /libraries`）；**第 ③ 步收藏范围没做**——
 * 它要拉后端的地区/类型选项（`ManageRoutingOptions`），留到「设置 → 刮削」那批一起。
 */
@ComponentV2
export struct LibraryCreatePage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;

  @Local private step: number = 1;
  @Local private kind: string = '';
  @Local private name: string = '';
  @Local private roots: string[] = [];
  @Local private accessMode: string = 'everyone';
  @Local private busy: boolean = false;
  @Local private errorMessage: string = '';

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  /** 影视库才有第 ③ 步收藏范围（同 iOS 的 `hasScope`） */
  private hasScope(): boolean {
    return this.kind === 'movie' || this.kind === 'tv';
  }

  private totalSteps(): number {
    return 2;
  }

  private ready(): boolean {
    return this.name.trim().length > 0 && this.roots.length > 0;
  }

  private cardOf(kind: string): KindCard {
    for (const card of KIND_CARDS) {
      if (card.kind === kind) {
        return card;
      }
    }
    return KIND_CARDS[0];
  }

  // MARK: 动作

  /** 选根目录：用鸿蒙原生的文件夹选择器（对应 iOS 的 `.fileImporter` 目录模式） */
  private async addRoot(): Promise<void> {
    try {
      const picked: string = await pickFolder();
      if (picked.length === 0) {
        return;
      }
      for (const existing of this.roots) {
        if (existing === picked) {
          this.toast('这个目录已经加过了');
          return;
        }
      }
      this.roots.push(picked);
    } catch (error) {
      this.toast('选择目录失败，请重试');
    }
  }

  private removeRoot(path: string): void {
    const at: number = this.roots.indexOf(path);
    if (at >= 0) {
      this.roots.splice(at, 1);
    }
  }

  private async create(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    if (!this.ready()) {
      this.toast('库名和根目录都要填');
      return;
    }
    this.busy = true;
    this.errorMessage = '';
    try {
      const payload: LibraryPayload = {
        name: this.name.trim(),
        kind: this.kind as MediaKind,
        root_paths: this.roots,
        access_mode: this.accessMode
      };
      const created: LibraryView = await api.libraryCreate(payload);
      this.toast(`已创建「${created.name}」`);
      // iOS 是「创建并开始扫描」——建完立刻触发一轮
      try {
        await api.libraryScanStart(created.id);
      } catch (error) {
        // 扫描没起来不影响创建结果，编辑里还能手动扫
      }
      this.navStack.pop();
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.busy = false;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `创建失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '创建失败';
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        PageTopBar({ title: '添加媒体库', onBack: (): void => {
          this.navStack.pop();
        }})
        Scroll() {
          Column({ space: 14 }) {
            if (this.step === 1) {
              this.KindStep()
            } else {
              this.BasicsStep()
            }
            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .fontSize(13)
                .fontColor(Theme.danger)
                .width('100%')
            }
            AppFooter()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: Theme.tabBarInset })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    // iOS 是 sheet 内 NavigationStack + .navigationTitle("添加媒体库") + inline：
    // 鸿蒙用 NavDestination 原生 inline 标题栏，去掉自绘 TopBar。
    .hideTitleBar(true)
    .onBackPressed(() => {
      // iOS 第 2 步左上是「上一步」而非取消：消费返回手势，退回选类型那一步
      if (this.step > 1) {
        this.step = 1;
        return true;
      }
      return false;
    })
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      this.started = true;
    })
  }

  /**
   * 类型图标按名字静态分派成直接的 `$r(...)`——
   * 不能写 `SymbolGlyph($r(card.symbol))`，那样传变量、运行时才发现名字错（铁律 6）。
   */
  private kindIcon(symbol: string): Resource {
    if (symbol === 'sys.symbol.display') {
      return $r('sys.symbol.display');
    }
    if (symbol === 'sys.symbol.video') {
      return $r('sys.symbol.video');
    }
    if (symbol === 'sys.symbol.picture') {
      return $r('sys.symbol.picture');
    }
    return $r('sys.symbol.film');
  }

  /** 第 1 步：选类型（对应 iOS 的 `kindStep`） */
  @Builder
  KindStep() {
    Column({ space: 12 }) {
      Text('要建哪种库？')
        .fontFamily('serif')
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .width('100%')
        .margin({ top: 6, bottom: 4 })
      // iOS 是 Form 里一个 Section：四种类型同处一个圆角容器、行间分隔线（insetGrouped）
      Column() {
        ForEach(KIND_CARDS, (card: KindCard, index: number) => {
          Row({ space: 14 }) {
            SymbolGlyph(this.kindIcon(card.symbol))
              .fontSize(24)
              .fontColor([Theme.accent])
              .width(34)
            Column({ space: 4 }) {
              Text(card.title)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.text)
              Text(card.blurb)
                .fontSize(13)
                .fontColor(Theme.textMuted)
              Text(card.traits)
                .fontSize(12)
                .fontColor(Theme.textFaint)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            if (this.kind === card.kind) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(18)
                .fontColor([Theme.accent])
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .onClick(() => {
            this.kind = card.kind;
            this.step = 2;
          })
          if (index < KIND_CARDS.length - 1) {
            Divider().color(Theme.line).margin({ left: 50, right: 16 })
          }
        }, (card: KindCard) => card.kind)
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
      Text('类型决定这个库怎么扫、怎么摆、能不能订阅，创建后不可更改。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
    .width('100%')
  }

  /** 第 2 步：名称、根目录、可见范围（对应 iOS 的 `basicsStep`） */
  @Builder
  BasicsStep() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        SymbolGlyph(this.kindIcon(this.cardOf(this.kind).symbol))
          .fontSize(20)
          .fontColor([Theme.accent])
        Text(this.cardOf(this.kind).title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Blank()
      }
      .width('100%')
      .padding({ top: 6 })

      Column({ space: 6 }) {
        Text('库名')
          .fontSize(13)
          .fontColor(Theme.textFaint)
        TextInput({ text: this.name, placeholder: this.cardOf(this.kind).title })
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor(Theme.text)
          .backgroundColor(Theme.surfaceRaised)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((value: string): void => {
            this.name = value;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 6 }) {
        Text(`根目录（${this.roots.length}）`)
          .fontSize(13)
          .fontColor(Theme.textFaint)
        ForEach(this.roots, (path: string) => {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(16)
              .fontColor([Theme.textMuted])
            Text(path)
              .fontSize(13)
              .fontColor(Theme.text)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            SymbolGlyph($r('sys.symbol.minus_circle'))
              .fontSize(18)
              .fontColor([Theme.danger])
              .onClick(() => {
                this.removeRoot(path);
              })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 11, bottom: 11 })
          .backgroundColor(Theme.surface)
          .borderRadius(10)
        }, (path: string) => path)
        Text('+ 添加目录')
          .fontSize(14)
          .fontColor(Theme.accentStrong)
          .padding({ left: 12, right: 12, top: 11, bottom: 11 })
          .width('100%')
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.glassFill)
          .borderRadius(10)
          .border({ width: 1, color: Theme.lineStrong })
          .onClick(() => {
            this.addRoot();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 6 }) {
        Text('谁能看到')
          .fontSize(13)
          .fontColor(Theme.textFaint)
        Row({ space: 8 }) {
          this.AccessChip('everyone', '全部成员')
          this.AccessChip('admin', '仅管理员')
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.hasScope()) {
        Text('收藏范围（地区 / 类型）建好之后在「编辑媒体库」里设。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
      }

      Text(this.busy ? '创建中…' : '创建并开始扫描')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(this.ready() && !this.busy ? '#0b0d12' : Theme.textFaint)
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 14, bottom: 14 })
        .backgroundColor(this.ready() && !this.busy ? Theme.accent : Theme.glassFill)
        .borderRadius(Theme.cardRadius)
        .onClick(() => {
          if (this.ready() && !this.busy) {
            this.create();
          }
        })
    }
    .width('100%')
  }

  @Builder
  AccessChip(mode: string, label: string) {
    Text(label)
      .fontSize(14)
      .fontColor(this.accessMode === mode ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.accessMode === mode ? Theme.accent : Theme.glassFill)
      .borderRadius(16)
      .onClick(() => {
        this.accessMode = mode;
      })
  }
}
