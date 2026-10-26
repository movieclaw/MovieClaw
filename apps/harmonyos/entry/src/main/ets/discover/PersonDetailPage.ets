import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ShellChrome } from '../common/ShellChrome';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { PersonView, PersonCreditView } from '../api/Models';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';

/**
 * 库内影人页路由参数。
 * 同前几页：路由参数会被序列化，**不要用 `instanceof`**，按字段取值。
 */
export class PersonParams {
  readonly tmdbId: number;

  constructor(tmdbId: number) {
    this.tmdbId = tmdbId;
  }

  static of(param: Object | undefined | null): PersonParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: PersonParams = param as PersonParams;
    const id: number = raw.tmdbId;
    if (id === undefined || id === null || !(id > 0)) {
      return null;
    }
    return new PersonParams(id);
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function PersonDetailBuilder() {
  PersonDetailPage()
}

/** 加载失败的原因（对应 iOS `PersonDetailView.Failure`） */
class PersonFailure {
  static readonly none: string = '';
  static readonly missing: string = 'missing';
  static readonly error: string = 'error';
}

/**
 * 库内影人页（对应 iOS 端 Features/Discover/PersonDetailView.swift）。
 *
 * `GET /people/{tmdbPersonId}`，列出他在**我的库里**参演与执导的作品，点作品进库内条目详情。
 * 404 = 库内没有这位影人的作品（给出「刷新元数据」的解释与去媒体库入口）。
 */
@Component
export struct PersonDetailPage {
  private navStack: NavPathStack = new NavPathStack();
  private tmdbId: number = 0;
  private started: boolean = false;

  @State private person: PersonView | null = null;
  @State private failure: string = PersonFailure.none;
  @State private refreshing: boolean = false;

  private start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.load();
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      const person: PersonView = await api.peopleShow(this.tmdbId);
      this.person = person;
      this.failure = PersonFailure.none;
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) {
        this.failure = PersonFailure.missing;
      } else {
        this.failure = PersonFailure.error;
      }
    }
  }

  // MARK: 派生

  private title(): string {
    const person: PersonView | null = this.person;
    return person !== null ? person.name : '';
  }

  /** 原名（与姓名不同才显示，同 iOS subtitle） */
  private originalName(): string {
    const person: PersonView | null = this.person;
    if (person === null) {
      return '';
    }
    const original: string | null = person.original_name ?? null;
    if (original === null || original === person.name) {
      return '';
    }
    return original;
  }

  private cast(): PersonCreditView[] {
    const person: PersonView | null = this.person;
    if (person === null) {
      return [];
    }
    return person.credits.filter((credit: PersonCreditView): boolean => credit.department === 'cast');
  }

  private directed(): PersonCreditView[] {
    const person: PersonView | null = this.person;
    if (person === null) {
      return [];
    }
    return person.credits.filter((credit: PersonCreditView): boolean => credit.department === 'director');
  }

  private summary(): string {
    const person: PersonView | null = this.person;
    if (person === null) {
      return '';
    }
    const castCount: number = this.cast().length;
    const directedCount: number = this.directed().length;
    let text: string = `库内 ${person.credits.length} 部`;
    if (castCount > 0 && directedCount > 0) {
      text += `（参演 ${castCount} · 执导 ${directedCount}）`;
    }
    return text;
  }

  /** 手机三列（同 iOS DiscoverGrid.columns：adaptive 104–170），按行切块渲染 */
  private rowsOf(credits: PersonCreditView[]): PersonCreditView[][] {
    const rows: PersonCreditView[][] = [];
    for (let i: number = 0; i < credits.length; i += 3) {
      const end: number = Math.min(i + 3, credits.length);
      const row: PersonCreditView[] = [];
      for (let j: number = i; j < end; j++) {
        row.push(credits[j]);
      }
      rows.push(row);
    }
    return rows;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        PageTopBar({ title: this.title(), onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.failure !== PersonFailure.none) {
          this.FallbackState()
        } else if (this.person === null) {
          this.LoadingState()
        } else {
          this.Content(this.person as PersonView)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: PersonParams | null = PersonParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null) {
        this.tmdbId = params.tmdbId;
        this.start();
      }
    })
  }

  @Builder
  LoadingState() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(28)
        .height(28)
        .color(Theme.textMuted)
      Text('正在读取影人档案…')
        .fontSize(15)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  FallbackState() {
    Column({ space: 14 }) {
      SymbolGlyph(this.failure === PersonFailure.missing
        ? $r('sys.symbol.person') : $r('sys.symbol.exclamationmark_triangle'))
        .fontSize(34)
        .fontColor([Theme.textMuted])
      if (this.failure === PersonFailure.missing) {
        Text('库内没有这位影人的作品')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text('可能是他参演的片都已从库里移除；也可能这个库是早前扫描的——影人档案随入库刮削一并建立，对它执行一次「刷新元数据」即可补齐，之后这里就会列出他在库内的全部作品。')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
          .lineHeight(22)
          .constraintSize({ maxWidth: 300 })
        Text('去媒体库')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(20)
          .border({ width: 1, color: Theme.lineStrong })
          .margin({ top: 4 })
          .onClick(() => {
            ShellChrome.openTab('library');
          })
      } else {
        Text('未能加载影人档案')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text('请稍后重试；若持续失败，请查看系统日志。')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
        Text('重试')
          .fontSize(15)
          .fontWeight(600)
          .fontColor('#0b0d12')
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .backgroundColor(Theme.accent)
          .borderRadius(20)
          .margin({ top: 4 })
          .onClick(() => {
            this.load();
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  @Builder
  Content(person: PersonView) {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column({ space: 24 }) {
          PersonHeaderCard({
            name: person.name,
            avatarUrl: ImageUrls.resolve(AppModel.origin(), person.avatar_url ?? null,
              ImageVariant.photoTile) ?? '',
            eyebrow: '影人',
            subtitle: this.originalName(),
            summary: this.summary()
          })
          this.CreditSection('参演', this.cast(), true)
          this.CreditSection('执导', this.directed(), false)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 40 })
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')
    }
    .onRefreshing(() => {
      this.load().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .height('100%')
  }

  @Builder
  CreditSection(title: string, credits: PersonCreditView[], showCharacter: boolean) {
    if (credits.length > 0) {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Text(title)
            .fontSize(20)
            .fontWeight(600)
            .fontColor(Theme.text)
          Text(`${credits.length}`)
            .fontSize(15)
            .fontColor(Theme.textFaint)
        }
        .alignItems(VerticalAlign.Bottom)
        ForEach(this.rowsOf(credits), (row: PersonCreditView[]) => {
          Row({ space: 12 }) {
            ForEach(row, (credit: PersonCreditView) => {
              this.CreditCard(credit, showCharacter)
            }, (credit: PersonCreditView) => `${credit.media_item_id}-${credit.title}`)
            // 不满一行补空位，让卡片保持整行宽度（同 iOS adaptive 网格左对齐）
            if (row.length < 3) {
              ForEach(this.fillers(row.length), (key: number) => {
                Column()
                  .layoutWeight(1)
              }, (key: number) => `${key}`)
            }
          }
          .width('100%')
        }, (row: PersonCreditView[], index: number) => `${index}-${row.length}`)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }

  private fillers(count: number): number[] {
    const out: number[] = [];
    for (let i: number = 0; i < 3 - count; i++) {
      out.push(i);
    }
    return out;
  }

  @Builder
  CreditCard(credit: PersonCreditView, showCharacter: boolean) {
    Column({ space: 2 }) {
      Stack() {
        if (ImageUrls.resolve(AppModel.origin(), credit.poster_url ?? null,
          ImageVariant.posterCard) !== null) {
          RemoteImage({
            url: ImageUrls.resolve(AppModel.origin(), credit.poster_url ?? null,
              ImageVariant.posterCard) ?? ''
          })
            .width('100%')
            .height('100%')
        } else {
          SymbolGlyph($r('sys.symbol.film'))
            .fontSize(30)
            .fontColor([Theme.textFaint])
        }
      }
      .width('100%')
      .aspectRatio(Theme.posterAspect)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .clip(true)
      .margin({ bottom: 4 })
      Text(credit.title)
        .fontSize(14)
        .fontWeight(500)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.creditCaption(credit, showCharacter))
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .onClick(() => {
      const libraryId: number | null = credit.library_id ?? null;
      if (libraryId !== null && libraryId > 0) {
        this.navStack.pushPathByName('libraryItem',
          new ItemRouteParams(libraryId, credit.media_item_id));
      }
    })
  }

  /** 饰角色（cast 且有角色）或年份；都没有时占位空行，保持卡片等高（同 iOS） */
  private creditCaption(credit: PersonCreditView, showCharacter: boolean): string {
    const character: string | null = credit.character ?? null;
    if (showCharacter && character !== null && character.length > 0) {
      return `饰 ${character}`;
    }
    const year: number | null = credit.year ?? null;
    if (year !== null && year > 0) {
      return `${year}`;
    }
    return ' ';
  }
}

/**
 * 影人页头部：头像（缺图显示首字）+ 眉题 + 姓名 + 原名 + 作品统计
 * （对应 iOS `PersonHeader`，库内影人页与 TMDB 影人页共用）。
 */
@Component
export struct PersonHeaderCard {
  name: string = '';
  avatarUrl: string = '';
  eyebrow: string = '';
  subtitle: string = '';
  summary: string = '';

  build() {
    Row({ space: 16 }) {
      Stack() {
        Text(this.firstGlyph())
          .fontSize(34)
          .fontWeight(600)
          .fontColor('rgba(255,255,255,0.30)')
        if (this.avatarUrl.length > 0) {
          RemoteImage({ url: this.avatarUrl })
            .width(92)
            .height(138)
        }
      }
      .width(92)
      .height(138)
      .backgroundColor('rgba(255,255,255,0.06)')
      .borderRadius(12)
      .clip(true)
      .shadow({ radius: 20, color: 'rgba(0,0,0,0.50)', offsetY: 12 })

      Column({ space: 4 }) {
        Text(this.eyebrow)
          .fontSize(12)
          .fontWeight(600)
          .fontColor(Theme.accent2)
          .letterSpacing(2.5)
        Text(this.name)
          .fontSize(22)
          .fontWeight(700)
          .fontColor('#ffffff')
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(15)
            .fontColor('rgba(255,255,255,0.55)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(this.summary)
          .fontSize(15)
          .fontColor('rgba(255,255,255,0.70)')
          .padding({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding({ bottom: 4 })
    }
    .alignItems(VerticalAlign.Bottom)
    .width('100%')
    .padding({ top: 8 })
  }

  private firstGlyph(): string {
    const trimmed: string = this.name.trim();
    return trimmed.length > 0 ? trimmed.substring(0, 1) : '?';
  }
}
