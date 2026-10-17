import { Theme } from '../theme/AppTheme';
import { Formatters } from '../common/Formatters';
import { RemoteImage } from '../common/RemoteImage';
import { LibraryRecentAdditionView, LibraryView } from '../api/Models';

/**
 * 媒体库模块内共用的小工具与小组件（逐条对齐 iOS 端 Features/Library/LibraryShared.swift
 * 与 DesignSystem/LibraryPosterCell.swift，口径即 Web lib/api/libraries.ts 等同名函数）：
 * 类型文案、扫描阶段、季集摘要、首页统计、海报格、进度环、分区头、空态。
 */

/** 库类型的展示名与图标（Web LIBRARY_KIND_META）。鸿蒙符号库无 tv/photo/square.stack 字形，用最近的等价图标 */
export class LibraryKindMeta {
  static label(kind: string): string {
    if (kind === 'movie') {
      return '电影';
    }
    if (kind === 'tv') {
      return '剧集';
    }
    if (kind === 'video') {
      return '其他';
    }
    if (kind === 'photo') {
      return '图片';
    }
    return kind;
  }

  static symbol(kind: string): Resource {
    if (kind === 'movie') {
      return $r('sys.symbol.film');
    }
    if (kind === 'tv') {
      return $r('sys.symbol.display');
    }
    if (kind === 'video') {
      return $r('sys.symbol.video');
    }
    if (kind === 'photo') {
      return $r('sys.symbol.picture');
    }
    return $r('sys.symbol.rectangle_stack');
  }
}

/**
 * 扫描阶段 → 状态词（Web SCAN_PHASE_LABELS）。扫描内部分阶段，阶段变了进度文案必须跟着变，
 * 否则文件扫完后还在补图，环停在 100% 配「扫描中」看起来就是卡死了。
 */
export class ScanPhase {
  static label(phase: string | null): string {
    const value: string = phase ?? 'ingesting';
    if (value === 'walking') {
      return '正在盘点文件';
    }
    if (value === 'ingesting') {
      return '正在扫描';
    }
    if (value === 'probing') {
      return '正在补探画质与音轨';
    }
    if (value === 'assets') {
      return '正在补齐海报与剧照';
    }
    if (value === 'reidentifying') {
      return '正在重新识别条目';
    }
    if (value === 'organizing') {
      return '正在整理文件名';
    }
    return '扫描中';
  }

  static hint(phase: string | null): string {
    const value: string = phase ?? 'ingesting';
    if (value === 'walking') {
      return '正在统计待处理的文件数';
    }
    if (value === 'ingesting') {
      return '识别到的内容会自动入库';
    }
    if (value === 'probing') {
      return '文件已全部入库，正在读取文件本体的规格';
    }
    if (value === 'assets') {
      return '文件已全部入库，正在下载图片';
    }
    if (value === 'reidentifying') {
      return '完成后条目身份会更新';
    }
    if (value === 'organizing') {
      return '完成后自动刷新';
    }
    return '';
  }
}

/** 「最近添加」的季集摘要（Web formatRecentAddition）：连续区间保留精确集号，零散或跨季改为计数 */
export function formatRecentAddition(addition: LibraryRecentAdditionView): string | null {
  if (addition.episode_count === 0 || addition.season_count === 0) {
    return null;
  }
  if (addition.season_count > 1) {
    return `新增${addition.season_count}季 · ${addition.episode_count}集`;
  }
  const season: number | null = addition.season_number ?? null;
  if (season === null) {
    return null;
  }
  if (addition.complete_season) {
    const seasonText: string = season === 0 ? '特别篇' : `第${season}季`;
    return `${seasonText} · 全${addition.episode_count}集`;
  }
  const start: number | null = addition.first_episode_number ?? null;
  const end: number | null = addition.last_episode_number ?? null;
  if (start === null || end === null) {
    return `S${Formatters.pad2(season)} · 新增${addition.episode_count}集`;
  }
  return start === end
    ? `S${Formatters.pad2(season)}E${Formatters.pad2(start)}`
    : `S${Formatters.pad2(season)}E${Formatters.pad2(start)}–${Formatters.pad2(end)}`;
}

/** 收藏层级说明（Web favoriteLevelLabel）：整剧与电影不解释 */
export function favoriteLevelLabel(kind: string, season: number | null, episode: number | null): string | null {
  if (kind !== 'tv' || season === null) {
    return null;
  }
  if (episode !== null) {
    return `收藏了 S${Formatters.pad2(season)}E${Formatters.pad2(episode)}`;
  }
  return season === 0 ? '收藏了特别篇' : `收藏了第 ${season} 季`;
}

/** 字节 → 「19.40 GB」（同 Formatters.bytes 口径） */
export function libraryBytes(bytes: number | null): string {
  return Formatters.bytes(bytes);
}

/** 相对时间：「几秒前」/「18 天前」；空值「从未」 */
export function libraryFromNow(raw: string | null): string {
  const dateMs: number | null = Formatters.date(raw);
  if (dateMs === null) {
    return '从未';
  }
  return Formatters.fromNow(dateMs);
}

/** S01E02 形式的集号 */
export function episodeCode(season: number, episode: number): string {
  return `S${Formatters.pad2(season)}E${Formatters.pad2(episode)}`;
}

/** 媒体库首页摘要（Web libraryStatsSummary）：只聚合库列表随带的统计快照 */
export function libraryStatsSummary(libraries: LibraryView[] | null): string {
  if (libraries === null) {
    return '正在汇总媒体库统计…';
  }
  if (libraries.length === 0) {
    return '还没有媒体库，创建后会在这里显示库存统计';
  }
  let movieCount: number = 0;
  let tvCount: number = 0;
  let videoCount: number = 0;
  let totalSize: number = 0;
  for (const library of libraries) {
    if (library.kind === 'movie') {
      movieCount += library.stats.item_count;
    } else if (library.kind === 'tv') {
      tvCount += library.stats.item_count;
    } else if (library.kind === 'video') {
      videoCount += library.stats.item_count;
    }
    totalSize += library.stats.total_size_bytes;
  }
  const videoPart: string = videoCount > 0 ? ` · ${videoCount} 个其他视频` : '';
  return `${libraries.length} 个媒体库 · ${movieCount} 部电影 · ${tvCount} 部剧集${videoPart}`
    + ` · 共占用 ${libraryBytes(totalSize)} 存储空间`;
}

/** 首页 / 详情页的分区头：标题 + 右侧入口（「查看全部」或 ⋯ 菜单） */
@Component
export struct LibrarySectionHeader {
  title: string = '';
  /** 右侧入口文字（「查看全部」/「全部合集 ›」）；空串 = 没有 */
  trailingText: string = '';
  onTrailing: (() => void) | null = null;
  /** 右侧 ⋯ 菜单的选项（「接下来继续」行的清空观看记录）；空数组 = 不显示 */
  menuItems: MenuElement[] = [];

  build() {
    Row() {
      Text(this.title)
        .fontSize(20)
        .fontWeight(600)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.trailingText.length > 0 && this.onTrailing !== null) {
        Text(this.trailingText)
          .fontSize(15)
          .fontColor(Theme.textFaint)
          .onClick(() => {
            const handler = this.onTrailing;
            if (handler !== null) {
              handler();
            }
          })
      }
      if (this.menuItems.length > 0) {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(17)
          .fontWeight(600)
          .fontColor([Theme.textMuted])
          .width(30)
          .height(30)
          .bindMenu(this.menuItems)
      }
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    .alignItems(VerticalAlign.Bottom)
  }
}

/**
 * 按框比例铺图（对应 iOS 端 LibraryArtwork / Web PosterImage + 「模糊铺底」手法）：
 * 框比例锁死、同一行等高；主图真实比例与框不一致时，用同一张图放大模糊铺底、
 * 中央按真实比例完整显示一张清晰图，而不是裁掉或把格子撑变形。
 */
@Component
export struct LibraryArtwork {
  /** 图片 URL；空串 = 无图（印兜底文字或占位底色） */
  url: string = '';
  /** 主图真实宽高比；null 视为与框一致 */
  imageAspect: number | null = null;
  /** 框的宽高比 */
  frameAspect: number = Theme.posterAspect;
  placeholderSymbol: Resource = $r('sys.symbol.film');
  /** 无图时在占位底上印的字（例如集号、片名） */
  fallbackText: string | null = null;

  build() {
    Stack() {
      if (this.url.length === 0 && this.fallbackText !== null) {
        Text(this.fallbackText)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('rgba(255, 255, 255, 0.25)')
          .textAlign(TextAlign.Center)
          .padding(12)
      } else if (this.imageAspect !== null && Math.abs(this.imageAspect - this.frameAspect) > 0.05) {
        RemoteImage({ url: this.url, placeholderSymbol: this.placeholderSymbol })
          .scale({ x: 1.25, y: 1.25 })
          .blur(18)
          .opacity(0.45)
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.25)')
        RemoteImage({ url: this.url, fit: true, placeholderSymbol: this.placeholderSymbol })
          .aspectRatio(this.imageAspect)
      } else {
        RemoteImage({ url: this.url, placeholderSymbol: this.placeholderSymbol })
      }
    }
    .width('100%')
    .aspectRatio(this.frameAspect)
    .clip(true)
  }
}

/**
 * 媒体库海报格（对应 iOS 端 LibraryPosterCell / Web InventoryCell + PosterCardVisual）：
 * 海报 + 片名 + 年份（副行可附加评分等「正在比较的指标」）。
 * 文件缺失是需要常显的异常，作为唯一例外在片名下单独点灯；
 * 文件全部缺失的「死条目」海报置灰；后台正在处理这一格时描边点亮并写出阶段。
 */
@Component
export struct LibraryPosterCell {
  title: string = '';
  year: number | null = null;
  /** 副行附加信息（按评分排序时的「★ 8.1」等） */
  extent: string | null = null;
  url: string = '';
  imageAspect: number | null = null;
  frameAspect: number = Theme.posterAspect;
  /** 右上角收藏心 */
  favorite: boolean = false;
  /** 右上角已看对勾 */
  played: boolean = false;
  /** 死条目：文件全部缺失 */
  dead: boolean = false;
  /** 片名下方的异常提示（如「2 个文件缺失」） */
  abnormal: string | null = null;
  /** 后台正在处理这一格的阶段文案 */
  working: string | null = null;
  /** 海报左上角的角标（例如收藏层级、季集摘要） */
  cornerLabel: string | null = null;
  /** 只压暗海报图、不压暗片名（合集里库中还没有的那几部） */
  artworkOpacity: number = 1;
  /** 无图时的占位符号（按条目类型区分，例如剧集/影片） */
  placeholderSymbol: Resource = $r('sys.symbol.film');

  private subLabel(): string {
    const parts: string[] = [];
    if (this.year !== null) {
      parts.push(`${this.year}`);
    }
    if (this.extent !== null) {
      parts.push(this.extent);
    }
    return parts.length === 0 ? ' ' : parts.join(' · ');
  }

  build() {
    Column() {
      Stack() {
        LibraryArtwork({ url: this.url, imageAspect: this.imageAspect, frameAspect: this.frameAspect,
          placeholderSymbol: this.placeholderSymbol })
          .borderRadius(Theme.posterRadius)
          .clip(true)
          .border({ width: 1, color: Theme.line, radius: Theme.posterRadius })
          .saturate(this.dead ? 0 : 1)
          .opacity(this.dead ? 0.5 : this.artworkOpacity)

        Row({ space: 4 }) {
          if (this.played) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor([Theme.ok])
              .width(22)
              .height(22)
              .backgroundColor('rgba(74, 222, 128, 0.85)')
              .borderRadius(11)
          }
          if (this.favorite) {
            SymbolGlyph($r('sys.symbol.heart_fill'))
              .fontSize(13)
              .fontWeight(600)
              .fontColor([Theme.danger])
              .width(26)
              .height(22)
              .backgroundColor('rgba(0, 0, 0, 0.55)')
              .borderRadius(7)
          }
        }
        .padding(7)
        .alignSelf(ItemAlign.End)

        if (this.cornerLabel !== null) {
          Text(this.cornerLabel ?? '')
            .fontSize(11)
            .fontWeight(600)
            .fontColor('rgba(255, 255, 255, 0.9)')
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor('rgba(0, 0, 0, 0.6)')
            .borderRadius(10)
            .padding(7)
            .alignSelf(ItemAlign.Start)
        }

        if (this.working !== null) {
          Column() {
            Row({ space: 6 }) {
              LoadingProgress()
                .width(12)
                .height(12)
                .color(Theme.info)
              Text(this.working ?? '')
                .fontSize(11)
                .fontWeight(500)
                .fontColor(Theme.info)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .width('100%')
            .backgroundColor('rgba(7, 12, 20, 0.92)')
            .borderRadius({ bottomLeft: Theme.posterRadius, bottomRight: Theme.posterRadius })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .border({ width: 2, color: Theme.info, radius: Theme.posterRadius })
        }
      }
      .width('100%')
      .aspectRatio(this.frameAspect)

      Text(this.title)
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ top: 8 })
      Text(this.subLabel())
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ top: 1 })
      if (this.abnormal !== null) {
        Row({ space: 5 }) {
          Circle()
            .width(5)
            .height(5)
            .fill(this.dead ? 'rgba(255, 255, 255, 0.3)' : Theme.warning)
          Text(this.abnormal ?? '')
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .padding({ top: 3 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 扫描 / 整理 / 元数据刷新共用的进度环（三者进度都是 已处理/总数；没有分母时转圈） */
@Component
export struct LibraryProgressRing {
  processed: number | null = null;
  total: number | null = null;
  ringSize: number = 72;

  private fraction(): number | null {
    if (this.processed === null || this.total === null || this.total <= 0) {
      return null;
    }
    return Math.min(1, this.processed / this.total);
  }

  build() {
    Stack() {
      if (this.fraction() !== null) {
        Progress({ value: this.processed ?? 0, total: this.total ?? 1, type: ProgressType.Ring })
          .style({ strokeWidth: this.ringSize * 0.07 })
          .color('#ffffff')
          .backgroundColor('rgba(255, 255, 255, 0.2)')
          .width(this.ringSize)
          .height(this.ringSize)
        Text(`${Math.round((this.fraction() ?? 0) * 100)}%`)
          .fontSize(this.ringSize * 0.2)
          .fontWeight(600)
          .fontColor('#ffffff')
      } else {
        LoadingProgress()
          .color('#ffffff')
          .width(this.ringSize * 0.55)
          .height(this.ringSize * 0.55)
      }
    }
    .width(this.ringSize)
    .height(this.ringSize)
  }
}

/** 空态（对应 iOS 端 EmptyState / ContentUnavailableView）：图标 + 标题 + 说明 + 可选动作 */
@Component
export struct EmptyState {
  systemImage: Resource = $r('sys.symbol.film');
  title: string = '';
  message: string | null = null;
  actionTitle: string | null = null;
  onAction: (() => void) | null = null;

  build() {
    Column({ space: 10 }) {
      SymbolGlyph(this.systemImage)
        .fontSize(44)
        .fontColor([Theme.textFaint])
      Text(this.title)
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
        .textAlign(TextAlign.Center)
      if (this.message !== null) {
        Text(this.message)
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
          .lineHeight(20)
      }
      if (this.actionTitle !== null && this.onAction !== null) {
        Text(this.actionTitle)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.accentStrong)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(20)
          .border({ width: 1, color: Theme.lineStrong })
          .margin({ top: 6 })
          .onClick(() => {
            const handler = this.onAction;
            if (handler !== null) {
              handler();
            }
          })
      }
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 32, right: 32 })
  }
}
