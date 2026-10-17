import { display } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ShellChrome } from '../common/ShellChrome';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { SharedCollectionView, SharedCollectionItemView } from '../api/Models';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import { ShareItemView } from './ShareItemView';
import { PlayerParams } from '../player/PlayerPage';

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function SharePageBuilder() {
  SharePage()
}

/** 访客页路由参数 */
export class SharePageParams {
  readonly slug: string;

  constructor(slug: string) {
    this.slug = slug;
  }

  static of(param: Object | undefined | null): SharePageParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: SharePageParams = param as SharePageParams;
    const slug: string = raw.slug;
    return slug !== undefined && slug !== null && slug.length > 0 ? new SharePageParams(slug) : null;
  }
}

/** 访客页的背景色（iOS/Web 同款 #07080C，比主界面的纯黑略亮一点蓝） */
const SHARE_BG: string = '#07080C';

/**
 * 影片分享页（照 iOS `SharePageView`，Web `/s/[slug]`）。
 *
 * 状态机与 Web 一致：
 *
 *     探针 GET /share/{slug}
 *       → 需要密码且未解锁 → 密码卡（密码之前不露片名海报）→ POST /share/{slug}/unlock
 *       → 失效（不存在 / 已取消 / 已过期）→ 整页提示
 *       → 条目分享 → 影片页（ShareItemView）
 *       → 合集分享 → 名单网格 → 点一格进那一部的影片页（同一条链接，?item=）
 *
 * 解锁凭据是服务端种的 Cookie（`movieclaw_share`，ApiClient 的静态 cookie 罐保管），
 * App 内再打开同一条链接不必重输密码。访客页没有任何管理与站内入口。
 */
@ComponentV2
export struct SharePage {
  private navStack: NavPathStack = new NavPathStack();
  @Local private chrome: ShellChrome = ShellChrome.shared;
  @Local private slug: string = '';
  @Local private phase: string = 'loading';
  @Local private unavailableMessage: string = '';
  /** 解锁之后要知道这条链接是「一部片」还是「一个合集」——两者的落地页不一样 */
  @Local private isCollection: boolean = false;
  /** 合集分享点开某一部之后带上的条目 id；条目分享恒为 null */
  @Local private mediaItemId: number | null = null;
  @Local private collectionData: SharedCollectionView | null = null;
  @Local private collectionFailed: boolean = false;
  /** 合集网格列数（iOS LazyVGrid adaptive 104-170 的口径，按屏宽算） */
  private columns: number = 2;
  private started: boolean = false;

  aboutToAppear(): void {
    try {
      const widthVp: number = px2vp(display.getDefaultDisplaySync().width);
      const avail: number = widthVp - Theme.pagePadding * 2;
      // 最大列数 n：n*104 + (n-1)*12 ≤ avail
      this.columns = Math.max(2, Math.floor((avail + 12) / 116));
    } catch (error) {
      this.columns = 2;
    }
  }

  aboutToDisappear(): void {
    this.chrome.pop('share');
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 状态机

  private async probe(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      this.phase = 'unavailable';
      this.unavailableMessage = '还没有连上服务器';
      return;
    }
    this.phase = 'loading';
    try {
      const info = await api.shareProbe(this.slug);
      this.isCollection = info.collection_id !== null && info.collection_id !== undefined;
      this.enterContent(info.requires_password && !info.unlocked ? 'locked' : '');
    } catch (error) {
      this.phase = 'unavailable';
      this.unavailableMessage = SharePage.unavailableMessage(error);
    }
  }

  /** 解锁成功或无需密码：按「合集 / 条目」落进对应内容态 */
  private enterContent(fromGate: string): void {
    if (fromGate === 'locked') {
      this.phase = 'locked';
      return;
    }
    if (this.isCollection) {
      this.phase = 'collection';
      this.loadCollection();
    } else {
      this.mediaItemId = null;
      this.phase = 'item';
    }
  }

  private async loadCollection(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      this.collectionFailed = true;
      return;
    }
    this.collectionFailed = false;
    try {
      this.collectionData = await api.shareCollection(this.slug);
    } catch (error) {
      this.collectionFailed = true;
    }
  }

  /** 探针失败 → 访客看得懂的一句话（后端 message 已是中文，直接用） */
  private static unavailableMessage(error: Object): string {
    if (error instanceof ApiError) {
      if (error.status === 404) {
        return error.message.length > 0 ? error.message : '分享不存在或已取消';
      }
      if (error.status !== 0) {
        return error.message.length > 0 ? error.message : '暂时无法打开这条分享，请稍后再试';
      }
    }
    return '无法连接到服务器，请检查网络后重试';
  }

  // MARK: 布局

  build() {
    NavDestination() {
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(SHARE_BG)
        if (this.phase === 'loading') {
          this.LoadingView('正在打开分享…')
        } else if (this.phase === 'locked') {
          Stack() {
            this.BackButton()
            ShareGate({
              slug: this.slug,
              onUnlocked: (): void => {
                this.enterContent('');
              }
            })
          }
          .width('100%')
          .height('100%')
        } else if (this.phase === 'unavailable') {
          Stack() {
            this.BackButton()
            this.UnavailableCard()
          }
          .width('100%')
          .height('100%')
        } else if (this.phase === 'collection') {
          this.CollectionView()
        } else {
          ShareItemView({
            slug: this.slug,
            mediaItemId: this.mediaItemId,
            fromCollection: this.isCollection,
            onPlay: (mediaItemId: number, season: number, episode: number, startMs: number): void => {
              this.navStack.pushPathByName('player',
                new PlayerParams(mediaItemId, 0, season, episode, startMs, this.slug));
            },
            onBack: (): void => {
              this.phase = 'collection';
            },
            onClose: (): void => {
              this.navStack.pop();
            }
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(SHARE_BG)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      // 整屏页：收起底部标签栏（iOS 同款行为）
      this.chrome.push('share');
      if (!this.started) {
        const params: SharePageParams | null = SharePageParams.of(ctx.pathInfo.param as Object | undefined);
        if (params !== null) {
          this.started = true;
          this.slug = params.slug;
          this.probe();
        }
      }
    })
  }

  /** 居中的加载态（iOS 的 ProgressView + 一行字） */
  @Builder
  LoadingView(text: string) {
    Row({ space: 10 }) {
      LoadingProgress()
        .width(20)
        .height(20)
        .color('rgba(255,255,255,0.6)')
      Text(text)
        .fontSize(15)
        .fontColor('rgba(255,255,255,0.6)')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /** 左上角返回（页签栈出栈；模拟器边缘手势不可靠，页内自带返回更稳） */
  @Builder
  BackButton() {
    Stack() {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor(['rgba(255,255,255,0.85)'])
    }
    .width(40)
    .height(40)
    .backgroundColor('rgba(255,255,255,0.08)')
    .borderRadius(20)
    .position({ x: Theme.pagePadding, y: Theme.statusBarInset + 8 })
    .onClick(() => {
      this.navStack.pop();
    })
  }

  /** 居中卡片外壳的骨架（字标 + 标题 + 副标题），内容各页自己接 */
  @Builder
  CardHead(title: string, subtitle: string) {
    Text('MOVIECLAW')
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor('rgba(255,255,255,0.7)')
      .letterSpacing(3)
    Column({ space: 6 }) {
      Text(title)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#ffffff')
      Text(subtitle)
        .fontSize(15)
        .fontColor('rgba(255,255,255,0.6)')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 失效整页提示（不存在 / 已取消 / 已过期） */
  @Builder
  UnavailableCard() {
    Scroll() {
      Column() {
        Column({ space: 18 }) {
          this.CardHead(this.unavailableMessage, '请向分享者确认链接是否仍然有效。')
          Text('分享链接有有效期，到期或被取消后就无法再打开。')
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.4)')
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .padding(24)
        .constraintSize({ maxWidth: 420 })
        .backgroundColor('rgba(255,255,255,0.04)')
        .borderRadius(24)
        .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 20, right: 20, top: 80, bottom: 40 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  /** 合集名单：名字 + N 部 + 自适应海报网格；成员由服务端每次现算（规则合集会自己长） */
  @Builder
  CollectionView() {
    Column() {
      this.BackButton()
      if (this.collectionFailed) {
        Text('这条分享暂时打不开，请稍后再试。')
          .fontSize(15)
          .fontColor('rgba(255,255,255,0.6)')
          .padding({ top: 120, left: Theme.pagePadding, right: Theme.pagePadding })
          .width('100%')
          .textAlign(TextAlign.Center)
      } else if (this.collectionData !== null) {
        Scroll() {
          Column({ space: 4 }) {
            Text(this.collectionData.name)
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .fontColor('#ffffff')
              .padding({ top: Theme.statusBarInset + 52 })
            Text(`${this.collectionData.item_count} 部`)
              .fontSize(15)
              .fontColor('rgba(255,255,255,0.5)')
            if (this.collectionData.items.length === 0) {
              Text('这个合集现在一部都没有。')
                .fontSize(15)
                .fontColor('rgba(255,255,255,0.5)')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 60 })
            } else {
              this.CollectionGrid(this.collectionData.items)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 0, bottom: 120 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      } else {
        this.LoadingView('正在打开分享…')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 海报网格：手工分行 + 行内 layoutWeight 等宽（同全部合集页的手法） */
  @Builder
  CollectionGrid(items: SharedCollectionItemView[]) {
    Column({ space: 18 }) {
      ForEach(this.chunked(items), (row: SharedCollectionItemView[]) => {
        Row({ space: 12 }) {
          ForEach(row, (item: SharedCollectionItemView) => {
            this.CollectionCell(item)
          }, (item: SharedCollectionItemView) => `${item.media_item_id}`)
          ForEach(this.emptySlots(row.length), (slot: number) => {
            Column()
              .layoutWeight(1)
          }, (slot: number) => `${slot}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (row: SharedCollectionItemView[]) => row.map((item: SharedCollectionItemView): string => `${item.media_item_id}`).join('-'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 16 })
  }

  /** 一格：2:3 海报 + 一行片名 + 年份；点开进那一部的影片页（?item=） */
  @Builder
  CollectionCell(item: SharedCollectionItemView) {
    Column({ space: 4 }) {
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(255,255,255,0.04)')
        if (item.poster_url !== null && item.poster_url !== undefined) {
          RemoteImage({ url: this.posterUrl(item) })
            .width('100%')
            .height('100%')
        } else {
          Text('暂无海报')
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.3)')
        }
      }
      .width('100%')
      .aspectRatio(2 / 3)
      .borderRadius(12)
      .clip(true)
      .border({ width: 1, color: 'rgba(255,255,255,0.06)' })
      Text(item.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#ffffff')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (item.year !== null && item.year !== undefined) {
        Text(`${item.year}`)
          .fontSize(12)
          .fontColor('rgba(255,255,255,0.4)')
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.mediaItemId = item.media_item_id;
      this.phase = 'item';
    })
  }

  private posterUrl(item: SharedCollectionItemView): string {
    const origin: string = AppModel.shared.client !== null ? AppModel.shared.client.origin : '';
    const resolved: string | null = ImageUrls.resolve(origin, item.poster_url ?? null, null);
    return resolved !== null ? resolved : '';
  }

  private chunked(items: SharedCollectionItemView[]): SharedCollectionItemView[][] {
    const rows: SharedCollectionItemView[][] = [];
    for (let i: number = 0; i < items.length; i += this.columns) {
      rows.push(items.slice(i, i + this.columns));
    }
    return rows;
  }

  private emptySlots(count: number): number[] {
    const slots: number[] = [];
    for (let i: number = count; i < this.columns; i++) {
      slots.push(i);
    }
    return slots;
  }
}

/**
 * 密码卡（iOS ShareGateView）：与登录页同一种外壳，但没有任何站内入口；
 * 标题与海报在解锁前一律不露。
 */
@ComponentV2
struct ShareGate {
  @Require @Param slug: string;
  @Require @Param onUnlocked: () => void;
  @Local private password: string = '';
  @Local private error: string = '';
  @Local private busy: boolean = false;

  private empty(): boolean {
    return this.password.trim().length === 0;
  }

  private async submit(): Promise<void> {
    const value: string = this.password.trim();
    if (value.length === 0 || this.busy) {
      return;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      this.error = '还没有连上服务器';
      return;
    }
    this.busy = true;
    this.error = '';
    try {
      await api.shareUnlock(this.slug, { password: value });
      this.onUnlocked();
    } catch (err) {
      if (err instanceof ApiError && err.status !== 0) {
        this.error = err.message.length > 0 ? err.message : '密码不对，请重新输入';
      } else {
        this.error = '无法连接到服务器，请检查网络后重试';
      }
    } finally {
      this.busy = false;
    }
  }

  build() {
    Scroll() {
      Column() {
        Column({ space: 18 }) {
          Text('MOVIECLAW')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('rgba(255,255,255,0.7)')
            .letterSpacing(3)
          Column({ space: 6 }) {
            Text('需要密码')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#ffffff')
            Text('这是一条受密码保护的分享，输入密码后即可观看。')
              .fontSize(15)
              .fontColor('rgba(255,255,255,0.6)')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          Column({ space: 14 }) {
            Column({ space: 6 }) {
              Text('密码')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('rgba(255,255,255,0.7)')
              TextInput({ text: this.password, placeholder: '' })
                .type(InputType.Password)
                .enterKeyType(EnterKeyType.Go)
                .fontSize(16)
                .fontColor('#ffffff')
                .height(44)
                .padding({ left: 12, right: 12 })
                .backgroundColor('rgba(255,255,255,0.06)')
                .borderRadius(12)
                .border({ width: 1, color: 'rgba(255,255,255,0.1)' })
                .onChange((value: string) => {
                  this.password = value;
                })
                .onSubmit(() => {
                  this.submit();
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            if (this.error.length > 0) {
              Text(this.error)
                .fontSize(13)
                .fontColor('rgba(255,192,192,1)')
                .padding(10)
                .width('100%')
                .backgroundColor('rgba(255,83,83,0.1)')
                .borderRadius(10)
            }
            Text(this.busy ? '正在验证…' : '打开')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#000000')
              .width('100%')
              .height(44)
              .textAlign(TextAlign.Center)
              .backgroundColor('#ffffff')
              .borderRadius(12)
              .opacity(this.busy || this.empty() ? 0.5 : 1)
              .onClick(() => {
                this.submit();
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
        .padding(24)
        .constraintSize({ maxWidth: 420 })
        .backgroundColor('rgba(255,255,255,0.04)')
        .borderRadius(24)
        .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 20, right: 20, top: 80, bottom: 40 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }
}
