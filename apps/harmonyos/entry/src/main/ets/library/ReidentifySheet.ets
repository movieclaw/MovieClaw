import { Theme } from '../theme/AppTheme';
import { Formatters } from '../common/Formatters';
import { AppModel } from '../common/AppModel';
import { MovieClawApi } from '../api/Endpoints';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls } from '../common/ImageUrls';
import {
  ClaimBatchPayload,
  DetachPayload,
  ReidentifyGroupView,
  ReidentifyOutcomeView,
  ReidentifyPreviewView,
  ReviewItemView,
  UnidentifiedCandidateView
} from '../api/Models';
import { IssueClaimSeed, IssueClaimConfirmPanel, IssueClaimSearchPanel } from './IssueDrawerPage';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';

/**
 * 「修正识别结果」（iOS ReidentifySheet.swift，Web components/reidentify-dialog.tsx）。
 *
 * 为什么是两阶段而不是「点一下重新识别」：识别错挂时机器往往是**高置信地错**——
 * 同样的输入重跑大概率复现同一个错答案。这里把它拆成「先出结论 → 人拍板 → 才落库」：
 *
 *   打开 → 重走识别链（只读预览，一行台账都不改）
 *        → 按**结论**分组摆出来（一部剧几十集同一个结论只占一行；真分裂成
 *          「38 个归 A、2 个归 B」时也如实摊开）
 *        → 每组三个出口：采用新结论 / 自己搜一个条目 / 标为非独立作品
 *        → 关掉 = 什么都没发生
 *
 * 三条刻意的交互决定（同 iOS/Web）：
 * 1. 搜索是一等公民，不藏在「都不对？」后面——正确答案常常压根不在候选里；
 * 2. 「不是独立作品」必须有——花絮/预告被错挂时用户要说的是「它根本不该是个条目」，
 *    没有这个出口，最接近的按钮就成了「删除影片」（那是删磁盘）；
 * 3. 认领一律经确认面板看过海报/简介再落地，与待识别清单同一套面板
 *    （IssueDrawerPage 的 IssueClaimConfirmPanel / IssueClaimSearchPanel）。
 */

/** 身份来源 → 中文短语（结论卡上说明「凭什么这么认」） */
const REIDENTIFY_SOURCE_LABELS: Record<string, string> = {
  'path_tag': '目录名的 tmdbid 标记',
  'nfo': 'NFO',
  'resolved': '名称解析 + TMDB 收敛'
};

/** 没命中的失败分类 → 一句人话（与待识别清单的标签同源，措辞按本场景调整） */
const REIDENTIFY_CODE_LABELS: Record<string, string> = {
  'tmdb_unreachable': 'TMDB 不可达',
  'kind_mismatch': '类型与本库不符',
  'ambiguous': '候选之间分不出',
  'no_match': 'TMDB 里没找到匹配',
  'unparsable': '从文件名认不出片名'
};

@Component
export struct ReidentifySheet {
  @Prop libraryId: number = 0;
  @Prop mediaItemId: number = 0;
  onClose: () => void = (): void => {
  };
  /** 有一组拍板落库时回调：调用方刷新条目（身份可能已经变了） */
  onApplied: () => void = (): void => {
  };

  @State private preview: ReidentifyPreviewView | null = null;
  @State private loadFailed: boolean = false;
  /** 已拍板的组（key → 结语文案）。留在界面上而不是直接关窗：分裂成多组时
   * 用户要接着处理剩下的，得看得见哪些已经处理过了 */
  @State private settled: SettledEntry[] = [];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      this.loadFailed = true;
      return;
    }
    this.preview = null;
    this.loadFailed = false;
    this.settled = [];
    try {
      this.preview = await api.libraryItemsPreviewReidentification(this.libraryId, this.mediaItemId);
    } catch (error) {
      this.loadFailed = true;
    }
  }

  /** 还没拍板的组数 */
  private pendingCount(): number {
    const preview: ReidentifyPreviewView | null = this.preview;
    if (preview === null) {
      return 0;
    }
    let count: number = 0;
    for (const group of preview.groups) {
      if (this.settledMessage(group.key) === null) {
        count += 1;
      }
    }
    return count;
  }

  /** 某组的拍板结论（null = 还没处理） */
  private settledMessage(key: string): string | null {
    for (const entry of this.settled) {
      if (entry.key === key) {
        return entry.message;
      }
    }
    return null;
  }

  private markSettled(key: string, message: string): void {
    const next: SettledEntry[] = [];
    for (const entry of this.settled) {
      if (entry.key !== key) {
        next.push(entry);
      }
    }
    next.push(new SettledEntry(key, message));
    this.settled = next;
    this.onApplied();
  }

  build() {
    Column({ space: 0 }) {
      Row() {
        Text('修正识别结果')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Text('关闭')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 16, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          if (this.preview === null) {
            this.LoadingContent()
          } else {
            this.PreviewContent(this.preview)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 4, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .width('100%')

      // 底部提示：全部拍板完 / 改挂的代价
      Text(this.pendingCount() === 0 && this.preview !== null
        && (this.preview as ReidentifyPreviewView).groups.length > 0
        ? '全部处理完了'
        : '改挂会记为人工身份，之后识别器升级不再自动翻案')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 10, bottom: 14 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  LoadingContent() {
    Column({ space: 12 }) {
      if (this.loadFailed) {
        Text('预览加载失败')
          .fontSize(14)
          .fontColor(Theme.textMuted)
        Text('重试')
          .fontSize(14)
          .fontColor(Theme.accentStrong)
          .onClick(() => {
            this.load();
          })
      } else {
        LoadingProgress().width(22).height(22).color(Theme.textMuted)
        Text('正在重新识别…')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      }
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  PreviewContent(preview: ReidentifyPreviewView) {
    Text('已重走识别链。下面是机器给出的结论——采纳、自己搜一个、或标为非独立作品都由你定，'
      + '关掉这个窗口则不会有任何改动。')
      .fontSize(12)
      .fontColor(Theme.textMuted)
      .width('100%')
      .lineHeight(18)

    // 现身份卡：拍板前先看清「现在挂的是谁」
    this.CurrentCard(preview.current, preview.movie)

    if (preview.unreachable) {
      Text('有文件因为 TMDB 不可达没能得出结论——那是网络问题不是识别问题。'
        + '建议先修好网络再来，此刻的结论不足以据此拍板。')
        .fontSize(12)
        .fontColor('#F5D489')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .width('100%')
        .backgroundColor('rgba(245,212,137,0.08)')
        .borderRadius(10)
        .border({ width: 1, color: 'rgba(245,212,137,0.3)' })
    }

    if (preview.pinned_identity) {
      Text('这些文件的身份被目录名的 tmdbid 标记或 NFO 钉死。在这里改挂会记为人工身份、'
        + '扫描不会再翻案，条目 NFO 里矛盾的 tmdbid 也会被一并改正；但目录名上的标记需要你自己改，'
        + '否则下次整理/重扫的命名仍会带着旧 id。')
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .width('100%')
        .backgroundColor('rgba(255,255,255,0.03)')
        .borderRadius(10)
        .border({ width: 1, color: 'rgba(255,255,255,0.1)' })
    }

    if (preview.groups.length === 0) {
      Text('这个条目在本库没有可参与识别的在位文件。')
        .fontSize(14)
        .fontColor(Theme.textMuted)
        .width('100%')
        .padding({ top: 24, bottom: 24 })
    }

    ForEach(preview.groups, (group: ReidentifyGroupView) => {
      ReidentifyGroupRow({
        group: group,
        movie: preview.movie,
        searchSeed: preview.search_seed,
        settledMessage: this.settledMessage(group.key) ?? '',
        onSettled: (message: string): void => {
          this.markSettled(group.key, message);
        }
      })
    }, (group: ReidentifyGroupView) => group.key)

    if (preview.skipped_missing > 0) {
      Text(`另有 ${preview.skipped_missing} 个文件已从磁盘消失（缺失清单里那些），`
        + '没有实体可供识别，保持原身份不参与。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .width('100%')
    }
  }

  /** 现身份卡（iOS ReidentifyCurrentCard） */
  @Builder
  CurrentCard(current: ReviewItemView, movie: boolean) {
    Row({ space: 12 }) {
      RemoteImage({ url: this.currentPosterUrl(current) })
        .width(44)
        .height(64)
        .borderRadius(8)
        .clip(true)
      Column({ space: 2 }) {
        Text('当前身份')
          .fontSize(12)
          .fontColor(Theme.textFaint)
        Row({ space: 6 }) {
          Text(current.title)
            .fontSize(15)
            .fontWeight(600)
            .fontColor('rgba(255,255,255,0.95)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (current.year !== null && current.year !== undefined) {
            Text(`${current.year}`)
              .fontSize(15)
              .fontColor(Theme.textMuted)
          }
        }
        .width('100%')
        if (current.tmdb_id !== null && current.tmdb_id !== undefined) {
          Text(`TMDB #${current.tmdb_id} ↗`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .decoration({ type: TextDecorationType.Underline })
            .onClick(() => {
              this.openUrl(`https://www.themoviedb.org/${movie ? 'movie' : 'tv'}/${current.tmdb_id}`);
            })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(12)
    .backgroundColor('rgba(255,255,255,0.03)')
    .borderRadius(12)
    .border({ width: 1, color: Theme.line })
  }

  private currentPosterUrl(current: ReviewItemView): string {
    return ImageUrls.resolve(AppModel.origin(), current.poster_url ?? null, null) ?? '';
  }

  private openUrl(url: string): void {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    context.openLink(url).catch((): void => {
      this.getUIContext().getPromptAction().showToast({ message: '打不开链接' });
    });
  }
}

/**
 * 一组结论（iOS ReidentifyGroupRow）：文件清单 + 机器结论 + 三个出口。
 * 状态（busy/内联面板）跟着组走，所以独立成组件。
 */
@Component
struct ReidentifyGroupRow {
  @Prop group: ReidentifyGroupView;
  @Prop movie: boolean = false;
  /** 「自己搜」的预填词（后端解析出的片名） */
  @Prop searchSeed: string = '';
  /** 已拍板的结论文案；空串 = 还没处理 */
  @Prop settledMessage: string = '';
  onSettled: (message: string) => void = (): void => {
  };

  /** 内联面板：none / search / confirm（同一时间只开一个） */
  @State private panelKind: string = 'none';
  @State private panelSeed: IssueClaimSeed | null = null;
  @State private busy: boolean = false;
  @State private errorMessage: string = '';

  private outcome(): ReidentifyOutcomeView {
    return this.group.outcome;
  }

  private outcomePosterUrl(): string {
    return ImageUrls.resolve(AppModel.origin(), this.outcome().poster_url ?? null, null) ?? '';
  }

  private sourceLabel(source: string): string {
    const mapped: string | undefined = REIDENTIFY_SOURCE_LABELS[source];
    return mapped !== undefined ? mapped : source;
  }

  private codeLabel(code: string): string {
    const mapped: string | undefined = REIDENTIFY_CODE_LABELS[code];
    return mapped !== undefined ? mapped : code;
  }

  build() {
    if (this.settledMessage.length > 0) {
      Text(`✓ ${this.settledMessage}`)
        .fontSize(14)
        .fontColor('rgba(255,255,255,0.85)')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .width('100%')
        .backgroundColor('rgba(122,162,247,0.08)')
        .borderRadius(12)
        .border({ width: 1, color: 'rgba(122,162,247,0.25)' })
    } else {
      this.Card()
    }
  }

  @Builder
  Card() {
    Column({ space: 8 }) {
      // 是哪些文件——分裂成多组时这行是唯一的辨认依据
      Column({ space: 2 }) {
        Row({ space: 8 }) {
          Text(`${this.group.file_count} 个文件`)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('rgba(255,255,255,0.85)')
          Text(Formatters.bytes(this.group.total_size_bytes))
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        .width('100%')
        Text(this.group.sample_names.join('、')
          + (this.group.file_count > this.group.sample_names.length ? ' …' : ''))
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Divider().color(Theme.line)

      this.OutcomeView()

      // 候选：机器拿不定主意时留下的可能匹配，点一下先看详情
      if (this.outcome().candidates.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
          ForEach(this.outcome().candidates, (candidate: UnidentifiedCandidateView) => {
            Text(candidate.title + (candidate.year !== null && candidate.year !== undefined
              ? ` (${candidate.year})` : ''))
              .fontSize(14)
              .fontColor(this.panelSeed !== null && this.panelSeed.tmdbId === candidate.tmdb_id
                ? Theme.text : 'rgba(255,255,255,0.9)')
              .maxLines(1)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(this.panelSeed !== null && this.panelSeed.tmdbId === candidate.tmdb_id
                ? 'rgba(122,162,247,0.28)' : 'rgba(122,162,247,0.12)')
              .borderRadius(8)
              .border({
                width: 1,
                color: this.panelSeed !== null && this.panelSeed.tmdbId === candidate.tmdb_id
                  ? Theme.accent : 'rgba(122,162,247,0.4)'
              })
              .onClick(() => {
                if (this.panelSeed !== null && this.panelSeed.tmdbId === candidate.tmdb_id) {
                  this.panelSeed = null;
                  this.panelKind = 'none';
                } else {
                  this.panelSeed = IssueClaimSeed.fromCandidate(candidate);
                  this.panelKind = 'confirm';
                }
              })
          }, (candidate: UnidentifiedCandidateView) => `${candidate.tmdb_id}`)
        }
        .width('100%')
      }

      // 两个常驻出口。搜索不藏在二级：机器高置信错挂时正确答案常常压根不在候选里
      Row({ space: 8 }) {
        Text('都不对，自己搜…')
          .fontSize(13)
          .fontColor(this.panelKind === 'search' ? Theme.accentStrong : Theme.text)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(14)
          .onClick(() => {
            if (this.busy) {
              return;
            }
            if (this.panelKind === 'search') {
              this.panelKind = 'none';
            } else {
              this.panelSeed = null;
              this.panelKind = 'search';
            }
          })
        Blank()
        Text('不是独立作品')
          .fontSize(13)
          .fontColor('#FFB4B4')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(14)
          .onClick(() => {
            this.confirmDetach();
          })
      }
      .width('100%')

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
      }

      if (this.panelKind === 'search') {
        IssueClaimSearchPanel({
          movie: this.movie,
          initialQuery: this.searchSeed,
          onPick: (seed: IssueClaimSeed): void => {
            this.panelSeed = seed;
            this.panelKind = 'confirm';
          }
        })
      } else if (this.panelKind === 'confirm' && this.panelSeed !== null) {
        IssueClaimConfirmPanel({
          seed: this.panelSeed,
          movie: this.movie,
          fileCount: this.group.file_count,
          busy: this.busy,
          onConfirm: (): void => {
            this.assign(this.panelSeed as IssueClaimSeed);
          },
          onCancel: (): void => {
            this.panelKind = 'none';
            this.panelSeed = null;
          }
        })
      }
    }
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor('rgba(255,255,255,0.03)')
    .borderRadius(12)
    .border({ width: 1, color: Theme.line })
  }

  /** 机器结论：命中给海报片名与依据（不同于现身份时给「改挂到这里」），没命中给原因 */
  @Builder
  OutcomeView() {
    if (this.outcome().media_item_id !== null && this.outcome().media_item_id !== undefined) {
      Row({ space: 12 }) {
        RemoteImage({ url: this.outcomePosterUrl() })
          .width(40)
          .height(56)
          .borderRadius(4)
          .clip(true)
        Column({ space: 2 }) {
          Text(this.outcome().same_as_current ? '重新识别的结论：与当前一致' : '重新识别的结论')
            .fontSize(12)
            .fontColor(Theme.textFaint)
          Row({ space: 6 }) {
            Text(this.outcome().title ?? '')
              .fontSize(14)
              .fontWeight(600)
              .fontColor('rgba(255,255,255,0.95)')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.outcome().year !== null && this.outcome().year !== undefined) {
              Text(`${this.outcome().year}`)
                .fontSize(14)
                .fontColor(Theme.textMuted)
            }
          }
          .width('100%')
          if (this.outcome().source !== null && this.outcome().source !== undefined) {
            Text(`依据：${this.sourceLabel(this.outcome().source as string)}`)
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (!this.outcome().same_as_current && this.outcome().tmdb_id !== null
          && this.outcome().tmdb_id !== undefined) {
          Text('改挂到这里')
            .fontSize(13)
            .fontWeight(600)
            .fontColor(Theme.text)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(Theme.accent)
            .borderRadius(14)
            .onClick(() => {
              if (this.busy) {
                return;
              }
              this.panelSeed = new IssueClaimSeed(this.outcome().tmdb_id as number,
                this.outcome().title ?? '', this.outcome().year ?? null,
                this.outcome().poster_url ?? null);
              this.panelKind = 'confirm';
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else {
      Text(`没能认出来${this.outcome().code !== null && this.outcome().code !== undefined
        ? `（${this.codeLabel(this.outcome().code as string)}）` : ''}`
        + (this.outcome().reason !== null && this.outcome().reason !== undefined
          ? `：${this.outcome().reason}` : '。'))
        .fontSize(14)
        .fontColor(Theme.textMuted)
        .width('100%')
    }
  }

  /** 认领：把这组文件改挂到 seed 指的 TMDB 条目 */
  private async assign(seed: IssueClaimSeed): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    this.errorMessage = '';
    try {
      const ref: string = `tmdb:${this.movie ? 'movie' : 'tv'}:${seed.tmdbId}`;
      const payload: ClaimBatchPayload = { file_ids: this.group.file_ids, title_ref: ref };
      await api.libraryIdentificationAssignFilesToTitle(payload);
      this.panelKind = 'none';
      this.panelSeed = null;
      this.onSettled(`${this.group.file_count} 个文件已改挂为《${seed.title}》`);
    } catch (error) {
      this.errorMessage = ReidentifyGroupRow.describe(error);
    } finally {
      this.busy = false;
    }
  }

  /** 标为非独立作品：先确认（适合花絮/预告/片段），再摘掉身份 */
  private confirmDetach(): void {
    if (this.busy) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: `把这 ${this.group.file_count} 个文件标为「非独立作品」？`,
      message: '它们会摘掉身份、不再占用库存，之后扫描也不再过问。'
        + '适合花絮、预告、片段这类本就不该单独成条目的内容。'
        + '磁盘文件一个字节都不会动，随时可以在「已忽略」清单里恢复。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '标为非独立作品',
        action: (): void => {
          this.detach();
        }
      }
    });
  }

  private async detach(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    this.errorMessage = '';
    try {
      const payload: DetachPayload = { file_ids: this.group.file_ids };
      await api.libraryIdentificationMarkFilesAsExtras(payload);
      this.onSettled(`${this.group.file_count} 个文件已标为非独立作品`);
    } catch (error) {
      this.errorMessage = ReidentifyGroupRow.describe(error);
    } finally {
      this.busy = false;
    }
  }

  private static describe(error: Object): string {
    const err = error as BusinessError;
    return err.message !== undefined && err.message.length > 0 ? err.message : '操作失败';
  }
}

/** 已拍板的一组（key → 结论文案） */
class SettledEntry {
  readonly key: string;
  readonly message: string;

  constructor(key: string, message: string) {
    this.key = key;
    this.message = message;
  }
}
