import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Formatters } from '../common/Formatters';
import { ApiError } from '../api/ApiClient';
import { jsonStringValue, jsonIntValue } from '../api/JsonValue';
import { HandoffCenter, runHandoff, handoffMessage } from '../settings/HandoffCenter';
import { ChatParams } from '../agent/ChatPage';
import { SubscriptionParams } from '../subscriptions/SubscriptionDetailPage';
import { SectionParams } from '../settings/SettingsIndexPage';
import { MovieClawApi } from '../api/Endpoints';
import { NoticeView } from '../api/Models';
import { AppFooter } from '../common/AppFooter';

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function NoticeCenterBuilder() {
  NoticeCenterPage()
}

/**
 * 待处理事项中心（对应 iOS `Features/Notices/NoticeCenterView.swift`；Web `notice-center.tsx`）。
 * 「我的」页进入，仅管理员。
 *
 * 产品语义照 iOS：这里只列「需要用户行动才能推进的运行时故障」——正常运行时为空；
 * 问题修好后服务端自动消退，用户不需要「清理通知」。每条事项三个动作，主次分明：
 * - 去处理（主出口）：跳到能修它的页面（订阅详情 / 自动入库 / 下载器 / 站点设置）；
 * - 交给 AI 分析（第二出口，接入了模型才有）：后端带着现场自检组装工单起会话；
 * - 忽略（退路）：乐观移除，失败时下轮刷新会拉回真实状态。
 *
 * 目录级根因告警（payload.group_key）存在时，被它收编的单种子告警（payload.grouped_under）折叠不显示：
 * 用户看到的是一条「这个目录 movieclaw 看不到」，而不是 16 条「《某剧》无法入库」。
 * 刷新：30 秒轮询；拉取失败且已有数据时不打扰（保留上次结果，下轮自愈）。
 */
@ComponentV2
export struct NoticeCenterPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  private timer: number = -1;

  @Local private notices: NoticeView[] = [];
  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  /** 有没有接入模型：没接入就不渲染「交给 AI 分析」（同 iOS） */
  @Local private handoffAvailable: boolean = false;
  @Local private handoffBusyId: number = -1;

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 取数

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const list: NoticeView[] = await api.noticesList();
      this.notices = noticeVisible(list);
      this.failed = false;
      this.errorMessage = '';
    } catch (error) {
      // 已有数据时不打扰：保留上次结果，下轮自愈（同 iOS）
      if (this.notices.length === 0) {
        this.failed = true;
        this.errorMessage = this.messageOf(error);
      }
    } finally {
      this.loading = false;
    }
  }

  private startPoll(): void {
    if (this.timer >= 0) {
      return;
    }
    this.timer = setInterval((): void => {
      this.load();
    }, 30000);
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 动作

  /** 事项的跳转目标：按来源域给出能修它的页面（对应 iOS `NoticeCenterView.href` → Web `noticeHref`） */
  private goto(notice: NoticeView): void {
    if (notice.source === 'subscription') {
      const id: number | null = jsonIntValue(notice.payload['subscription_id']);
      if (id !== null && id > 0) {
        this.navStack.pushPathByName('subscriptionDetail', new SubscriptionParams(id));
        return;
      }
      // 没带订阅 id：iOS 会切到订阅标签根页；这里在「我的」栈里没有那个标签可切，如实提示
      this.toast('请到「订阅」页签查看');
      return;
    }
    // ingest / downloader / site / cloud 这些分区 iOS 端也是「请在网页端管理」
    // （availableInApp == false，分区页显示网页端引导）——鸿蒙走同一个设置分区页
    const section: string = notice.source === 'ingest' ? 'import-watch'
      : notice.source === 'downloader' ? 'downloaders'
        : notice.source === 'site' ? 'sites'
          : notice.source === 'cloud' ? 'cloud' : '';
    if (section.length > 0) {
      this.navStack.pushPathByName('settingsSection', new SectionParams(section));
      return;
    }
    this.navStack.pushPathByName('settings', null);
  }

  /** 忽略：乐观移除，dismiss 幂等且失败无害，失败时下轮刷新拉回真实状态（同 iOS） */
  private async dismiss(notice: NoticeView): Promise<void> {
    const kept: NoticeView[] = [];
    for (const item of this.notices) {
      if (item.id !== notice.id) {
        kept.push(item);
      }
    }
    this.notices = kept;
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      await api.noticesDismiss(notice.id);
    } catch (error) {
      await this.load();
    }
  }

  /** 交给 AI 分析（对应 iOS 卡片里的 `ActivityHandoffButton`）：工单 → 起会话 → 直达会话页 */
  private async handoff(notice: NoticeView): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.handoffBusyId >= 0) {
      return;
    }
    this.handoffBusyId = notice.id;
    try {
      const result = await runHandoff(api, 'notice', `${notice.id}`);
      this.toast(`已建会话「${result.title}」`);
      this.navStack.pushPathByName('chat', new ChatParams(result.sessionId));
    } catch (error) {
      this.toast(handoffMessage(error));
    } finally {
      this.handoffBusyId = -1;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        Row() {
          PageTopBar({ title: '待处理事项', onBack: (): void => {
          this.navStack.pop();
        }})
          // 右上角计数胶囊（对应 iOS toolbar 的 notices-count）
          if (this.notices.length > 0) {
            Text(`${this.notices.length}`)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textMuted)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .margin({ top: Theme.statusBarInset + 10 })
              .backgroundColor('rgba(255,255,255,0.07)')
              .borderRadius(10)
          }
        }
        .width('100%')

        if (this.loading) {
          this.LoadingBody()
        } else if (this.failed) {
          this.FailedBody()
        } else if (this.notices.length === 0) {
          this.EmptyBody()
        } else {
          this.ListBody()
        }
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
        this.startPoll();
        const api: MovieClawApi | null = this.api();
        if (api !== null) {
          HandoffCenter.ensureChecked(api).then((ok: boolean): void => {
            this.handoffAvailable = ok;
          });
        }
      }
    })
  }

  @Builder
  LoadingBody() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(24)
        .height(24)
        .color(Theme.textMuted)
      Text('正在加载…')
        .fontSize(13)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  FailedBody() {
    Column({ space: 12 }) {
      Text('待处理事项加载失败')
        .fontSize(15)
        .fontColor(Theme.text)
      Text(this.errorMessage)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Text('重试')
        .fontSize(14)
        .fontWeight(600)
        .fontColor(Theme.accentStrong)
        .padding({ left: 20, right: 20, top: 9, bottom: 9 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(18)
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /** 空态（对应 iOS EmptyState：暂无待处理事项） */
  @Builder
  EmptyBody() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle'))
        .fontSize(30)
        .fontColor([Theme.ok])
      Text('暂无待处理事项')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text('这里只列需要你处理的运行时问题，修复后会自动消失。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ListBody() {
    Scroll() {
      Column({ space: 10 }) {
        ForEach(this.notices, (notice: NoticeView) => {
          this.NoticeCard(notice)
        }, (notice: NoticeView) => `${notice.id}`)
        Text('这里只列需要你处理的运行时问题，修复后会自动消失。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .margin({ top: 6 })
        AppFooter()
      }
      .width('100%')
      .padding({
        left: Theme.pagePadding,
        right: Theme.pagePadding,
        top: 12,
        bottom: Theme.tabBarInset
      })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  /**
   * 一条待处理事项（对应 iOS `NoticeCard`）：严重度圆点自成左栏，标题与正文对齐；
   * 时间贴右；操作条与正文以发丝线分开。
   */
  @Builder
  NoticeCard(notice: NoticeView) {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        // 严重度圆点：warning 用黄，其余（error）用红（同 iOS）
        Circle()
          .width(8)
          .height(8)
          .fill(notice.severity === 'warning' ? Theme.warning : Theme.danger)
          .margin({ top: 6 })
        Column({ space: 4 }) {
          Row({ space: 10 }) {
            Text(notice.title)
              .fontSize(15)
              .fontWeight(600)
              .fontColor(Theme.text)
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(Formatters.relative(notice.updated_at))
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          Text(notice.message)
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .lineHeight(19)
            .copyOption(CopyOptions.LocalDevice)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Divider().color('rgba(255,255,255,0.05)')

      Row({ space: 8 }) {
        Blank()
        Text('忽略')
          .fontSize(14)
          .fontColor(Theme.textFaint)
          .padding({ left: 6, right: 6, top: 6, bottom: 6 })
          .onClick(() => {
            this.dismiss(notice);
          })
        if (this.handoffAvailable) {
          Text(this.handoffBusyId === notice.id ? '分析中…' : '交给 AI 分析')
            .fontSize(14)
            .fontColor(this.handoffBusyId === notice.id ? Theme.textFaint : Theme.accentStrong)
            .padding({ left: 6, right: 6, top: 6, bottom: 6 })
            .onClick(() => {
              if (this.handoffBusyId < 0) {
                this.handoff(notice);
              }
            })
        }
        Row({ space: 3 }) {
          Text('去处理')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.accentStrong)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(12)
            .fontColor([Theme.accentStrong])
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(Theme.accentSoft)
        .borderRadius(16)
        .onClick(() => {
          this.goto(notice);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .padding(14)
    .backgroundColor(Theme.glassFill)
    .borderRadius(14)
    .border({ width: 1, color: Theme.line })
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 折叠被目录级根因收编的告警（对应 iOS `NoticeCenterView.visible`）：
 * 存在 group_key 的根因告警时，grouped_under 指向它的单种子告警不显示。
 * 「我的」页的入口计数也用同一份口径。
 */
export function noticeVisible(notices: NoticeView[]): NoticeView[] {
  const groupKeys: Set<string> = new Set<string>();
  for (const notice of notices) {
    const key: string | null = jsonStringValue(notice.payload['group_key']);
    if (key !== null && key.length > 0) {
      groupKeys.add(key);
    }
  }
  const out: NoticeView[] = [];
  for (const notice of notices) {
    const parent: string | null = jsonStringValue(notice.payload['grouped_under']);
    if (parent === null || parent.length === 0) {
      out.push(notice);
      continue;
    }
    if (!groupKeys.has(parent)) {
      out.push(notice);
    }
  }
  return out;
}
