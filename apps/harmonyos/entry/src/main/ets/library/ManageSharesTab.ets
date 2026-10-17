import { pasteboard } from '@kit.BasicServicesKit';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { Formatters } from '../common/Formatters';
import { ImageUrls } from '../common/ImageUrls';
import { RemoteImage } from '../common/RemoteImage';
import { shareAbsoluteUrl, shareCopyText, shareExpiryHint } from '../common/ShareLinks';
import { LibraryKindMeta } from './LibraryShared';
import { ItemRouteParams } from './LibraryItemDetailPage';
import { CollectionRouteParams } from './CollectionDetailPage';
import { ShareView } from '../api/Models';

/**
 * 媒体库管理页的「分享」页签（对应 iOS `ManageSharesTab` / Web `library-shares.tsx`）。
 *
 * 全部有效分享一行一条——海报、片名、有无密码、形态 / 年份 / 有效期、打开次数与最近打开，
 * 行尾「复制」「取消」。分享多了只有这里能一眼管住；过期 / 已取消的后端不列。
 * 30 秒轮询，列表把条数回报给页签计数。
 */
@ComponentV2
export struct ManageSharesTab {
  @Require @Param navStack: NavPathStack;
  /** 把分享条数回报给宿主（管理页页签计数用） */
  @Param onCountChange: (count: number) => void = (_count: number): void => {
  };

  @Local private shares: ShareView[] | null = null;
  @Local private failed: boolean = false;
  @Local private busyId: number = 0;
  private pollTimer: number = -1;

  aboutToAppear(): void {
    this.load();
    this.schedulePoll();
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private schedulePoll(): void {
    this.stopPoll();
    this.pollTimer = setTimeout((): void => {
      this.pollTimer = -1;
      this.load();
      this.schedulePoll();
    }, 30000);
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败';
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const rows: ShareView[] = await api.sharesList();
      this.failed = false;
      this.shares = rows;
      this.onCountChange(rows.length);
    } catch (error) {
      this.failed = true;
    }
  }

  // MARK: 动作

  /** 复制一段可以直接粘进聊天框的话（同 iOS：链接 + 密码一起给） */
  private copy(share: ShareView): void {
    const link: string = shareAbsoluteUrl(share.url, AppModel.origin());
    const text: string = shareCopyText(share.title, link, share.password ?? '');
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setDataSync(data);
    this.toast(share.password !== null && share.password !== undefined ? '已复制链接和密码' : '已复制链接');
  }

  /** 取消前先确认；确认框按钮是「先不 / 取消分享」，别把两个「取消」混在一起 */
  private confirmRevoke(share: ShareView): void {
    this.getUIContext().showAlertDialog({
      title: `取消《${share.title}》的分享？`,
      message: '链接立即失效，正在播放的访客会在一分钟内中断。',
      primaryButton: {
        value: '先不',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '取消分享',
        fontColor: Theme.danger,
        action: (): void => {
          this.revoke(share);
        }
      }
    });
  }

  private async revoke(share: ShareView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busyId !== 0) {
      return;
    }
    this.busyId = share.id;
    try {
      await api.sharesRevoke(share.id);
      this.toast('分享已取消');
      await this.load();
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busyId = 0;
    }
  }

  /** 点海报 / 片名进条目（或合集）详情 */
  private openItem(share: ShareView): void {
    const libraryId: number | null = share.library_id ?? null;
    const itemId: number | null = share.media_item_id ?? null;
    const collectionId: number | null = share.collection_id ?? null;
    if (libraryId !== null && itemId !== null) {
      this.navStack.pushPathByName('libraryItem', new ItemRouteParams(libraryId, itemId));
    } else if (collectionId !== null && libraryId !== null) {
      this.navStack.pushPathByName('collectionDetail', new CollectionRouteParams(collectionId, libraryId));
    }
  }

  /** 「形态 · 年份 · N 天后失效（绝对时间）」；合集分享没有形态，写它此刻有几部 */
  private facts(share: ShareView): string {
    const parts: string[] = [];
    if (share.collection_id !== null && share.collection_id !== undefined) {
      parts.push(`合集 · ${share.item_count ?? 0} 部`);
    } else if (share.kind !== null && share.kind !== undefined) {
      parts.push(LibraryKindMeta.label(share.kind));
    }
    if (share.year !== null && share.year !== undefined) {
      parts.push(`${share.year}`);
    }
    parts.push(`${shareExpiryHint(share.expires_at)}（${Formatters.dateTime(share.expires_at)}）`);
    return parts.join(' · ');
  }

  private accessLine(share: ShareView): string {
    const opened: string = share.view_count > 0 ? `已打开 ${share.view_count} 次` : '还没有人打开';
    const last: string | null = share.last_accessed_at ?? null;
    return last !== null && last.length > 0 ? `${opened} · 最近 ${Formatters.relative(last)}` : opened;
  }

  // MARK: 视图

  build() {
    Column() {
      if (this.shares === null) {
        if (this.failed) {
          this.ErrorState()
        } else {
          this.LoadingState()
        }
      } else if ((this.shares as ShareView[]).length === 0) {
        this.EmptyState()
      } else {
        this.Body()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress().width(24).height(24).color(Theme.textMuted)
      Text('正在读取分享…').fontSize(13).fontColor(Theme.textFaint)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 10 }) {
      Text('分享列表加载失败').fontSize(15).fontColor(Theme.text)
      Text('重试').fontSize(14).fontColor(Theme.accentStrong).onClick(() => {
        this.load();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyState() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.link'))
        .fontSize(28)
        .fontColor([Theme.textFaint])
      Text('还没有分享任何影片')
        .fontSize(15)
        .fontColor(Theme.textMuted)
      Text('在影片详情页的 ⋯ 菜单里可以创建分享：拿到链接的人不用登录就能看这一部影片。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ left: 40, right: 40, top: 60, bottom: 40 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  Body() {
    Scroll() {
      Column({ space: 10 }) {
        if (this.failed) {
          // 通信失败但手里还有上一轮数据：如实说，下面照常展示旧数据
          Text('与后端通信失败，正在自动重试；下方显示的是最近一次成功加载的数据')
            .fontSize(12)
            .fontColor(Theme.warn)
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .backgroundColor('rgba(245, 196, 81, 0.08)')
            .borderRadius(12)
            .border({ width: 1, color: 'rgba(245, 196, 81, 0.25)' })
        }
        ForEach(this.shares as ShareView[], (share: ShareView) => {
          this.Row(share)
        }, (share: ShareView) => `s-${share.id}`)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: Theme.tabBarInset })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  /** 一条分享：海报 + 片名/密码 + 事实行 + 打开统计 + 行尾复制/取消 */
  @Builder
  Row(share: ShareView) {
    Column({ space: 10 }) {
      Row({ space: 14 }) {
        RemoteImage({
          url: ImageUrls.resolve(AppModel.origin(), share.poster_url ?? null, null) ?? '',
          placeholderSymbol: $r('sys.symbol.film')
        })
          .width(44)
          .height(66)
          .borderRadius(8)
          .clip(true)
          .onClick(() => {
            this.openItem(share);
          })
        Column({ space: 3 }) {
          Row({ space: 8 }) {
            Text(share.title)
              .fontSize(15)
              .fontWeight(600)
              .fontColor(Theme.text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => {
                this.openItem(share);
              })
            if (share.password !== null && share.password !== undefined) {
              Row({ space: 3 }) {
                SymbolGlyph($r('sys.symbol.lock_fill'))
                  .fontSize(10)
                  .fontColor([Theme.textFaint])
                Text('密码')
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
              }
            }
          }
          .width('100%')
          Text(this.facts(share))
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.accessLine(share))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 8 }) {
        Blank()
        Text('复制')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(15)
          .border({ width: 1, color: Theme.line })
          .onClick(() => {
            this.copy(share);
          })
        Text(this.busyId === share.id ? '取消中…' : '取消')
          .fontSize(13)
          .fontColor(Theme.danger)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(15)
          .border({ width: 1, color: Theme.line })
          .onClick(() => {
            if (this.busyId !== share.id) {
              this.confirmRevoke(share);
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }
}
