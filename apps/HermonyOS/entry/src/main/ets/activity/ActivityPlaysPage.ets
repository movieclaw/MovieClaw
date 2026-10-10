import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { AppFooter } from '../common/AppFooter';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { MemberView, MediaActivityTarget, PlaybackHistoryView, PlaybackLogEntryView } from '../api/Models';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function ActivityPlaysBuilder() {
  ActivityPlaysPage()
}

/** 单页条数（对应 iOS PlaybackHistoryList.pageSize） */
const PAGE_SIZE: number = 30;

/** 一天的播放记录：日期标签 + 当天的记录 */
class PlayDayGroup {
  readonly label: string;
  readonly entries: PlaybackLogEntryView[];

  constructor(label: string, entries: PlaybackLogEntryView[]) {
    this.label = label;
    this.entries = entries;
  }
}

/**
 * 最近播放二级页（对齐 iOS `ActivityPages.ActivityWatchPage` + `PlaybackHistoryList`）。
 *
 * - 服务端游标翻页（`before=next_cursor`，30 条一页），滚到底自动续载 + 按钮兜底；
 * - 按本地日期分组（今天早些时候 / 昨天 / N月N日，组题带场数）；
 * - 右上角筛选：成员（全部成员 / 超级管理员 / 成员列表）+ 浏览范围（我的浏览范围 / 全部含隐藏库）；
 * - 行内容：时刻、小海报、片名 + 季集、成员·客户端·设备、右侧状态（播放中 / 看完✓ / 看到N% / 播放过）+ 时长；
 *   条目在可浏览范围内时整行可点进条目详情（对应 iOS detailRoute 的 `libraryId != nil && browsable`）。
 */
@ComponentV2
export struct ActivityPlaysPage {
  private navStack: NavPathStack = new NavPathStack();
  @Local private entries: PlaybackLogEntryView[] = [];
  @Local private loading: boolean = true;
  @Local private loadingMore: boolean = false;
  @Local private errorMessage: string = '';
  @Local private nextCursor: number | null = null;
  @Local private hasMore: boolean = false;
  @Local private hiddenCount: number = 0;
  /** 筛选：-1 全部成员；0 超级管理员；>0 指定成员 */
  @Local private memberId: number = -1;
  /** visible = 我的浏览范围（默认）；all = 全部含隐藏库（管控口径） */
  @Local private scope: string = 'visible';
  @Local private members: MemberView[] = [];
  /** 请求代次：切筛选后旧响应一律丢弃（对应 iOS generation） */
  private generation: number = 0;
  private started: boolean = false;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 取数

  private async loadMembers(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.members = await api.membersList();
    } catch (error) {
      this.members = [];
    }
  }

  /** 首屏：清空重拉（切筛选后调用） */
  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.generation += 1;
    const request: number = this.generation;
    this.loading = true;
    this.errorMessage = '';
    try {
      const view: PlaybackHistoryView = await api.playbackHistory(PAGE_SIZE, undefined, undefined,
        this.memberId >= 0 ? this.memberId : undefined, this.scope);
      if (request !== this.generation) {
        return;
      }
      this.entries = view.entries;
      this.hiddenCount = view.hidden_count;
      this.nextCursor = view.next_cursor ?? null;
      this.hasMore = view.has_more;
    } catch (error) {
      if (request !== this.generation) {
        return;
      }
      this.entries = [];
      this.hiddenCount = 0;
      this.nextCursor = null;
      this.hasMore = false;
      this.errorMessage = this.messageOf(error);
    } finally {
      if (request === this.generation) {
        this.loading = false;
      }
    }
  }

  /** 续页：有游标才请求，追加到末尾 */
  private async loadMore(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const cursor: number | null = this.nextCursor;
    if (api === null || cursor === null || this.loadingMore || this.loading) {
      return;
    }
    const request: number = this.generation;
    this.loadingMore = true;
    try {
      const view: PlaybackHistoryView = await api.playbackHistory(PAGE_SIZE, cursor, undefined,
        this.memberId >= 0 ? this.memberId : undefined, this.scope);
      if (request !== this.generation) {
        return;
      }
      this.entries = this.entries.concat(view.entries);
      this.nextCursor = view.next_cursor ?? null;
      this.hasMore = view.has_more;
    } catch (error) {
      if (request === this.generation) {
        this.getUIContext().getPromptAction().showToast({ message: this.messageOf(error) });
      }
    } finally {
      if (request === this.generation) {
        this.loadingMore = false;
      }
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '播放记录加载失败';
  }

  // MARK: 派生

  /** 按本地日期分组（今天早些时候 / 昨天 / N月N日，对应 iOS ActivityFormat.dayLabel） */
  private dayGroups(): PlayDayGroup[] {
    const groups: PlayDayGroup[] = [];
    const labels: string[] = [];
    const buckets: PlaybackLogEntryView[][] = [];
    const now: Date = new Date();
    const today: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const yesterday: Date = new Date(today.getTime() - 86400000);
    for (const entry of this.entries) {
      const date: Date = new Date(entry.started_at);
      if (Number.isNaN(date.getTime())) {
        continue;
      }
      const local: Date = new Date(date.getFullYear(), date.getMonth(), date.getDate());
      let label: string = '';
      if (local.getTime() === today.getTime()) {
        label = '今天早些时候';
      } else if (local.getTime() === yesterday.getTime()) {
        label = '昨天';
      } else {
        label = `${local.getMonth() + 1}月${local.getDate()}日`;
      }
      const at: number = labels.indexOf(label);
      if (at < 0) {
        labels.push(label);
        buckets.push([entry]);
      } else {
        buckets[at].push(entry);
      }
    }
    for (let i: number = 0; i < labels.length; i++) {
      groups.push(new PlayDayGroup(labels[i], buckets[i]));
    }
    return groups;
  }

  /** 时刻（HH:MM） */
  private clockOf(entry: PlaybackLogEntryView): string {
    const date: Date = new Date(entry.started_at);
    if (Number.isNaN(date.getTime())) {
      return '';
    }
    const h: number = date.getHours();
    const m: number = date.getMinutes();
    return `${h < 10 ? `0${h}` : h}:${m < 10 ? `0${m}` : m}`;
  }

  /** 片名 + 季集（剧集才带 SxxEyy，对应 iOS WatchFormat.titleLine） */
  private titleLine(entry: PlaybackLogEntryView): string {
    const media: MediaActivityTarget = entry.media;
    if (media.season_number > 0 || media.episode_number > 0) {
      const s: string = media.season_number > 0 ? `S${media.season_number < 10 ? '0' : ''}${media.season_number}` : '';
      const e: string = media.episode_number > 0 ? `E${media.episode_number < 10 ? '0' : ''}${media.episode_number}` : '';
      return `${media.title} ${s}${e}`;
    }
    return media.title;
  }

  /** 成员 · 客户端 · 设备 */
  private deviceLine(entry: PlaybackLogEntryView): string {
    const parts: string[] = [];
    if (entry.member_name.length > 0) {
      parts.push(entry.member_name);
    }
    const device: string = entry.device_name.length > 0 ? entry.device_name : entry.client;
    if (device.length > 0) {
      parts.push(device);
    }
    return parts.join('  ·  ');
  }

  /** 右侧状态：播放中(绿) / 看完✓ / 看到N% / 播放过 */
  private statusLine(entry: PlaybackLogEntryView): string {
    if ((entry.ended_at ?? '') === '') {
      return '播放中';
    }
    if (entry.completed) {
      return '看完 ✓';
    }
    const percent: number | null = entry.progress_percent ?? null;
    if (percent !== null && percent > 0) {
      return `看到 ${Math.round(percent)}%`;
    }
    return '播放过';
  }

  private statusColor(entry: PlaybackLogEntryView): string {
    if ((entry.ended_at ?? '') === '') {
      return Theme.ok;
    }
    if (entry.completed) {
      return Theme.ok;
    }
    return Theme.textFaint;
  }

  /** 观看时长（分钟） */
  private watchedText(entry: PlaybackLogEntryView): string {
    if (entry.watched_ms <= 0) {
      return '';
    }
    const minutes: number = Math.max(1, Math.round(entry.watched_ms / 60000));
    return `看了 ${minutes} 分钟`;
  }

  /** 整行可点的条件（对应 iOS detailRoute：libraryId 有值且 browsable） */
  private canOpen(entry: PlaybackLogEntryView): boolean {
    const media: MediaActivityTarget = entry.media;
    const libraryId: number | null = media.library_id ?? null;
    return media.browsable && libraryId !== null && libraryId > 0;
  }

  private openEntry(entry: PlaybackLogEntryView): void {
    const media: MediaActivityTarget = entry.media;
    this.navStack.pushPathByName('libraryItem',
      new ItemRouteParams(media.library_id ?? 0, media.media_item_id));
  }

  // MARK: 筛选

  private memberLabel(): string {
    if (this.memberId === -1) {
      return '全部成员';
    }
    if (this.memberId === 0) {
      return '超级管理员';
    }
    for (const member of this.members) {
      if (member.id === this.memberId) {
        return member.nickname.length > 0 ? member.nickname : member.username;
      }
    }
    return '成员';
  }

  private scopeLabel(): string {
    return this.scope === 'all' ? '全部含隐藏库' : '我的浏览范围';
  }

  private pickMember(id: number): void {
    if (this.memberId === id) {
      return;
    }
    this.memberId = id;
    this.load();
  }

  private pickScope(scope: string): void {
    if (this.scope === scope) {
      return;
    }
    this.scope = scope;
    this.load();
  }

  private memberName(id: number): string {
    if (id === -1) {
      return '全部成员';
    }
    if (id === 0) {
      return '超级管理员';
    }
    for (const member of this.members) {
      if (member.id === id) {
        return member.nickname.length > 0 ? member.nickname : member.username;
      }
    }
    return '';
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        this.Body()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      if (!this.started) {
        this.started = true;
        this.load();
        this.loadMembers();
      }
    })
  }

  @Builder
  TopBar() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([Theme.text])
        .width(38)
        .height(38)
        .onClick(() => {
          this.navStack.pop();
        })
      Text('最近播放')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
      Blank()
      // 筛选菜单（对应 iOS filterMenu：成员 + 浏览范围）
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontSize(16)
          .fontColor([Theme.textMuted])
        Text(`${this.memberLabel()} · ${this.scopeLabel()}`)
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(1)
          .constraintSize({ maxWidth: 150 })
      }
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .backgroundColor(Theme.glassFill)
      .borderRadius(16)
      .border({ width: 1, color: Theme.line })
      .bindMenu(this.FilterMenu())
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: Theme.statusBarInset + 6, bottom: 6 })
  }

  @Builder
  FilterMenu() {
    Menu() {
      MenuItemGroup({ header: this.MenuHeader('成员') }) {
        MenuItem({ content: '全部成员' })
          .onClick(() => {
            this.pickMember(-1);
          })
        MenuItem({ content: '超级管理员' })
          .onClick(() => {
            this.pickMember(0);
          })
        ForEach(this.members, (member: MemberView) => {
          MenuItem({ content: member.nickname.length > 0 ? member.nickname : member.username })
            .onClick(() => {
              this.pickMember(member.id);
            })
        }, (member: MemberView) => `${member.id}`)
      }
      MenuItemGroup({ header: this.MenuHeader('浏览范围') }) {
        MenuItem({ content: '我的浏览范围' })
          .onClick(() => {
            this.pickScope('visible');
          })
        MenuItem({ content: '全部含隐藏库' })
          .onClick(() => {
            this.pickScope('all');
          })
      }
    }
  }

  @Builder
  MenuHeader(label: string) {
    Text(label)
      .fontSize(11)
      .fontColor(Theme.textFaint)
      .padding({ left: 16, top: 6, bottom: 2 })
  }

  @Builder
  Body() {
    if (this.loading && this.entries.length === 0) {
      Column() {
        LoadingProgress()
          .width(26)
          .height(26)
          .color(Theme.textMuted)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.errorMessage.length > 0 && this.entries.length === 0) {
      Column({ space: 10 }) {
        Text('播放记录加载失败')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text(this.errorMessage)
          .fontSize(13)
          .fontColor(Theme.textMuted)
        Text('重试')
          .fontSize(14)
          .fontWeight(600)
          .fontColor(Theme.accentStrong)
          .padding({ left: 20, right: 20, top: 9, bottom: 9 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(18)
          .border({ width: 1, color: Theme.lineStrong })
          .onClick(() => {
            this.load();
          })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.entries.length === 0 && this.hiddenCount > 0) {
      // 全部在浏览范围外（对应 iOS「这些播放都在你的浏览范围外」）
      Column({ space: 10 }) {
        Text('这些播放都在你的浏览范围外')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text(`有 ${this.hiddenCount} 条记录不在你可见的库里。`)
          .fontSize(13)
          .fontColor(Theme.textMuted)
        Text('显示全部')
          .fontSize(14)
          .fontWeight(600)
          .fontColor(Theme.accentStrong)
          .padding({ left: 20, right: 20, top: 9, bottom: 9 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(18)
          .border({ width: 1, color: Theme.lineStrong })
          .margin({ top: 6 })
          .onClick(() => {
            this.pickScope('all');
          })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 24, right: 24 })
    } else if (this.entries.length === 0) {
      Column({ space: 10 }) {
        Text(`${this.memberName(this.memberId).length > 0 ? this.memberName(this.memberId) : '这个成员'}还没有播放记录`)
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        if (this.memberId !== -1) {
          Text('查看全部成员')
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.accentStrong)
            .padding({ left: 20, right: 20, top: 9, bottom: 9 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(18)
            .border({ width: 1, color: Theme.lineStrong })
            .margin({ top: 6 })
            .onClick(() => {
              this.pickMember(-1);
            })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 24, right: 24 })
    } else {
      this.HistoryList()
    }
  }

  @Builder
  HistoryList() {
    List() {
      ForEach(this.dayGroups(), (group: PlayDayGroup) => {
        ListItemGroup({ header: this.GroupHeader(group.label, group.entries.length) }) {
          ForEach(group.entries, (entry: PlaybackLogEntryView) => {
            this.PlayRow(entry)
          }, (entry: PlaybackLogEntryView) => `${entry.id}`)
        }
      }, (group: PlayDayGroup) => group.label)
      // 范围外的条数（对应 iOS HiddenCountRow）
      if (this.hiddenCount > 0) {
        ListItem() {
          Text(this.scope === 'all' ? '已显示全部含隐藏库的记录'
            : `另有 ${this.hiddenCount} 条不在你的浏览范围内`)
            .fontSize(11)
            .fontColor(Theme.textFaint)
            .width('100%')
            .padding({ top: 6, bottom: 6 })
        }
      }
      if (this.hasMore) {
        // 哨兵行：进入可视区自动续页（对应 iOS onScrollVisibilityChange）
        ListItem() {
          Text(this.loadingMore ? '正在加载…' : '加载更多')
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.textMuted)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 14, bottom: 14 })
            .onClick(() => {
              this.loadMore();
            })
            .onAppear(() => {
              this.loadMore();
            })
        }
      } else {
        ListItem() {
          Text('已经到最早的记录了')
            .fontSize(11)
            .fontColor(Theme.textFaint)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 10, bottom: 6 })
        }
      }
      ListItem() {
        AppFooter({ topSpace: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .cachedCount(6)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: Theme.tabBarInset })
  }

  @Builder
  GroupHeader(label: string, count: number) {
    Row({ space: 6 }) {
      Text(label)
        .fontSize(13)
        .fontWeight(600)
        .fontColor(Theme.textMuted)
      Text(`${count} 场`)
        .fontSize(12)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .padding({ top: 14, bottom: 6, left: 4 })
  }

  /** 一场播放：时刻 + 小海报 + 片名/设备 + 右侧状态（对应 iOS PlaybackHistoryRow） */
  @Builder
  PlayRow(entry: PlaybackLogEntryView) {
    ListItem() {
      Row({ space: 10 }) {
        Text(this.clockOf(entry))
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .width(34)
        RemoteImage({
          url: ImageUrls.resolve(AppModel.origin(), entry.media.poster_url ?? null,
            ImageVariant.posterCard) ?? ''
        })
          .width(28)
          .height(42)
          .backgroundColor(Theme.surface)
          .borderRadius(6)
          .clip(true)
        Column({ space: 3 }) {
          Text(this.titleLine(entry))
            .fontSize(14)
            .fontWeight(500)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.deviceLine(entry))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Column({ space: 2 }) {
          Text(this.statusLine(entry))
            .fontSize(12)
            .fontColor(this.statusColor(entry))
          Text(this.watchedText(entry))
            .fontSize(11)
            .fontColor(Theme.textFaint)
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .margin({ bottom: 6 })
      .onClick(() => {
        if (this.canOpen(entry)) {
          this.openEntry(entry);
        }
      })
    }
  }
}
