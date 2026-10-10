import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { NavStacks } from '../common/ShareLinks';
import { SubscriptionParams } from './SubscriptionDetailPage';
import { RuleSetEditorParams } from './RuleSetEditorPage';
import { RuleSetText, typedSpec, upgradeTargetOf } from './RuleSetModel';
import { UpgradeReportView } from './UpgradeReportView';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  DispatchPreviewView,
  LibraryView,
  PrepareView,
  RuleSetView,
  ResolveCandidateView,
  SeasonOverview,
  SubscriptionCreatePayload,
  SubscriptionCreateView,
  SubscriptionDeleteView,
  SubscriptionTargetPreviewPayload,
  UpgradeRunPayload,
  UpgradeRunView
} from '../api/Models';

/** 预览三态（对应后端 `POST /ui/subscriptions/title-preview` 的 status） */
class PrepareStatus {
  static readonly ready: string = 'ready';
  static readonly ambiguous: string = 'ambiguous';
  static readonly notFound: string = 'not_found';
}

/**
 * 订阅弹层的内容（对应 iOS `SubscribeSheet` / Web `subscribe-dialog`）。
 *
 * 流程照 iOS：先 `uiSubscriptionsPreviewTitle` 预检，按三态分流——
 * - `ready`：剧集勾季（默认取后端的 `suggested_seasons`）+ 自动续订开关 + 确认；
 * - `ambiguous`：豆瓣收敛歧义，候选海报墙选一个后带新引用重新预检；
 * - `not_found`：TMDB 未收录，说明无法订阅。
 *
 * 已订阅的条目（`existing_subscription_id` 有值）进管理态：这里是「已订阅」提示 + 取消订阅入口。
 *
 * **本轮先不做**（iOS 有、鸿蒙还没有）：规则组与入库库的选择、投递路由预检、快捷新建规则组、
 * 洗版变体（`upgrade`）。这些依赖「设置 → 订阅规则」那套界面，等设置分区做了再补。
 */
@ComponentV2
export struct SubscribeSheetContent {
  @Require @Param titleRef: string;
  @Require @Param fallbackTitle: string;
  /** 洗版变体（同 iOS `request.upgrade`）：季按库存预填、自动续订默认关、只列带洗版目标的组、建完立刻体检 */
  @Param upgrade: boolean = false;
  /** 关闭弹层（外壳传进来） */
  @Require @Param onClose: () => void;

  @Local private status: string = '';
  @Local private title: string = '';
  @Local private kind: string = 'movie';
  @Local private posterUrl: string = '';
  @Local private mediaYear: number | null = null;
  @Local private seasons: SeasonOverview[] = [];
  @Local private selected: number[] = [];
  @Local private followFuture: boolean = false;
  @Local private existingId: number = 0;
  /** 媒体库里已有本片（弹层提示「订阅后不会重复下载」，不拦订阅） */
  @Local private movieOwned: boolean = false;
  @Local private candidates: ResolveCandidateView[] = [];
  @Local private loading: boolean = true;
  @Local private busy: boolean = false;
  @Local private errorMessage: string = '';
  @Local private doneMessage: string = '';

  // 规则组与入库库（管理员可改；不改就用后端路由的结论）
  @Local private ruleSets: RuleSetView[] = [];
  @Local private libraries: LibraryView[] = [];
  @Local private libraryId: number = 0;
  @Local private ruleSetId: number = 0;
  /** 后端路由选中的库 / 规则组，以及它选的理由；用户改选后就不再显示理由 */
  @Local private routedLibraryId: number = 0;
  @Local private routedReason: string = '';
  @Local private routedRuleId: number = 0;
  @Local private routedRuleReason: string = '';
  @Local private dispatch: DispatchPreviewView | null = null;
  /** 一个组件只能绑一个 bindSheet，所以两个选择器共用这一个槽位 */
  @Local private pickerKind: string = '';
  @Local private showPicker: boolean = false;
  /** 洗版变体：建完订阅后接一轮体检的报告（同 iOS 在弹层内展示报告） */
  @Local private upgradeReport: UpgradeRunView | null = null;

  private started: boolean = false;

  aboutToAppear(): void {
    this.prepare(this.titleRef);
  }

  /** 洗版变体（同 iOS `upgradeMode`） */
  private upgradeMode(): boolean {
    return this.upgrade;
  }

  /** 可选规则组：洗版变体只列带洗版目标的组（同 iOS `selectableRules`） */
  private selectableRules(): RuleSetView[] {
    if (!this.upgradeMode()) {
      return this.ruleSets;
    }
    return this.ruleSets.filter((rule: RuleSetView): boolean => upgradeTargetOf(rule).length > 0);
  }

  /** 规则组与库只有管理员能改（同 iOS 的 `canManage`） */
  private canManage(): boolean {
    return Permissions.fromSession(AppModel.shared.session).isAdmin;
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // MARK: 取数

  /** 预检（对应 iOS 的 title-preview） */
  private async prepare(ref: string): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    try {
      const payload: SubscriptionTargetPreviewPayload = { title_ref: ref };
      const view: PrepareView = await api.uiSubscriptionsPreviewTitle(payload);
      this.status = view.status;
      this.title = view.media !== null && view.media !== undefined ? view.media.title : this.fallbackTitle;
      this.kind = view.media !== null && view.media !== undefined ? view.media.kind : 'movie';
      this.mediaYear = view.media !== null && view.media !== undefined ? (view.media.year ?? null) : null;
      this.posterUrl = view.media !== null && view.media !== undefined
        ? (ImageUrls.resolve(AppModel.origin(), view.media.poster_url, ImageVariant.posterCard) ?? '')
        : '';
      this.seasons = view.seasons;
      this.candidates = view.candidates;
      this.existingId = view.existing_subscription_id ?? 0;
      this.movieOwned = view.movie_owned;
      // 默认勾选（同 iOS）：洗版变体按库存预填；豆瓣季条目采信建议；否则全部已播正季
      if (this.upgradeMode()) {
        const owned: number[] = [];
        for (const season of view.seasons) {
          if (season.owned_count > 0) {
            owned.push(season.season_number);
          }
        }
        this.selected = owned;
      } else {
        this.selected = view.suggested_seasons.length > 0
          ? view.suggested_seasons.slice()
          : this.airedSeasons();
      }
      // 自动续订（同 iOS）：洗版变体默认关；否则在播剧默认开
      this.followFuture = !this.upgradeMode() && this.isAiring();
      // 预检成功后拉路由结论（规则组 / 入库库 / 为什么这么选）
      await this.loadRouting();
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  /**
   * 拿后端的**路由结论**：它会按适用范围挑一个规则组、按收藏范围挑一个入库库，
   * 并给出**为什么这么选**。用户不改就用它，改了就不显示理由（同 iOS）。
   */
  private async loadRouting(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      if (this.canManage()) {
        this.ruleSets = await api.rulesList();
        this.libraries = await api.libraryList();
      }
      await this.refreshDispatch();
    } catch (error) {
      // 路由拿不到不影响订阅本身，静默
    }
  }

  /** 重新拉规则组清单（从编辑器返回后可能新增了组） */
  private async refreshRules(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || !this.canManage()) {
      return;
    }
    try {
      this.ruleSets = await api.rulesList();
    } catch (error) {
      // 拿不到就保持原样
    }
  }

  /** 投递预检：改了入库库就要重拉（对应 iOS 的 `.task(id:)` 依赖 [prepared.media, libraryId]） */
  private async refreshDispatch(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const view: DispatchPreviewView = await api.subscriptionsPreviewDownloadRouting(
        this.kind, this.libraryId > 0 ? this.libraryId : undefined);
      this.dispatch = view;
      // 首次拿到路由结论时采纳它（用户没改过才采纳）
      if (this.libraryId === 0 && view.library_id !== null && view.library_id !== undefined) {
        this.libraryId = view.library_id;
        this.routedLibraryId = view.library_id;
        this.routedReason = view.route_reason ?? '';
      }
      if (this.ruleSetId === 0 && view.rule_set_id !== null && view.rule_set_id !== undefined) {
        this.ruleSetId = view.rule_set_id;
        this.routedRuleId = view.rule_set_id;
        this.routedRuleReason = view.rule_set_name !== null && view.rule_set_name !== undefined
          ? `按适用范围选中「${view.rule_set_name}」` : '';
      }
    } catch (error) {
      this.dispatch = null;
    }
  }

  /** 入库库的名字与选择理由 */
  private libraryLabel(): string {
    for (const library of this.libraries) {
      if (library.id === this.libraryId) {
        return library.name;
      }
    }
    const view: DispatchPreviewView | null = this.dispatch;
    const name: string | null = view !== null ? (view.library_name ?? null) : null;
    return name !== null && name.length > 0 ? name : '自动选择';
  }

  /** 选中规则组的名字：洗版变体只认带洗版目标的组，没有就写「未选择」（同 iOS `pickedRule?.name ?? "未选择"`） */
  private pickedRuleLabel(): string {
    if (!this.upgradeMode()) {
      return this.ruleSetLabel();
    }
    const rule: RuleSetView | null = this.pickedUpgradeRule();
    return rule === null ? '未选择' : rule.name;
  }

  /** 选中规则组的品质摘要（空 = 全不限，另有警示文案） */
  private pickedRuleSummary(): string {
    for (const rule of this.ruleSets) {
      if (rule.id === this.ruleSetId) {
        return RuleSetText.summary(typedSpec(rule)).join(' · ');
      }
    }
    return '';
  }

  private ruleSetLabel(): string {
    for (const rule of this.ruleSets) {
      if (rule.id === this.ruleSetId) {
        return rule.name;
      }
    }
    const view: DispatchPreviewView | null = this.dispatch;
    const name: string | null = view !== null ? (view.rule_set_name ?? null) : null;
    return name !== null && name.length > 0 ? name : '自动选择';
  }

  /** 已播出的季（`aired_count > 0`） */
  private airedSeasons(): number[] {
    const out: number[] = [];
    for (const season of this.seasons) {
      if (season.aired_count > 0) {
        out.push(season.season_number);
      }
    }
    return out;
  }

  /** 是否在播：最新一季还没播完（对应 iOS 的「在播剧开自动续订」） */
  private isAiring(): boolean {
    if (this.seasons.length === 0) {
      return false;
    }
    let latest: SeasonOverview = this.seasons[0];
    for (const season of this.seasons) {
      if (season.season_number > latest.season_number) {
        latest = season;
      }
    }
    const total: number = latest.episode_count ?? 0;
    return total > 0 && latest.aired_count < total;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '预览失败';
  }

  // MARK: 动作

  private toggleSeason(seasonNumber: number): void {
    const at: number = this.selected.indexOf(seasonNumber);
    if (at >= 0) {
      this.selected.splice(at, 1);
    } else {
      this.selected.push(seasonNumber);
    }
  }

  private isSelected(seasonNumber: number): boolean {
    return this.selected.indexOf(seasonNumber) >= 0;
  }

  /** 歧义收敛：选一个候选，带它的引用重新预检（对应 iOS 的 ambiguous 分支） */
  private pickCandidate(candidate: ResolveCandidateView): void {
    this.prepare(candidate.title_ref);
  }

  /** 确认订阅（对应 iOS 的 ✓） */
  private async confirm(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    if (this.kind === 'tv' && this.selected.length === 0 && !this.followFuture) {
      this.toast('至少选一季，或打开自动续订');
      return;
    }
    this.busy = true;
    try {
      const payload: SubscriptionCreatePayload = {
        title_ref: this.titleRef,
        selected_seasons: this.kind === 'tv' ? this.selected : null,
        follow_future: this.kind === 'tv' ? this.followFuture : null,
        // 没改过就传路由结论；改过就传用户选的
        library_id: this.libraryId > 0 ? this.libraryId : null,
        rule_set_id: this.canManage() && this.ruleSetId > 0 ? this.ruleSetId : null
      };
      const view: SubscriptionCreateView = await api.subscriptionsCreate(payload);
      if (this.upgradeMode()) {
        // 洗版变体：创建成功即接一轮洗版，报告留在弹层里（同 iOS）
        try {
          const runBody: UpgradeRunPayload = { rule_set_id: this.canManage() ? this.ruleSetId : null };
          this.upgradeReport = await api.subscriptionsUpgradeRun(view.subscription.id, runBody);
        } catch (error) {
          this.errorMessage = '订阅已创建，但触发洗版失败：请稍后到订阅详情里重试';
        }
        return;
      }
      this.doneMessage = `已订阅「${view.subscription.media.title}」`;
      this.toast(this.doneMessage);
      setTimeout((): void => {
        this.onClose();
      }, 700);
    } catch (error) {
      this.toast(this.messageOf(error));
    } finally {
      this.busy = false;
    }
  }

  /** 已订阅时「查看订阅详情」：关掉弹层并压栈到订阅详情（走当前页签的栈，同 iOS `router.push(.subscription)`） */
  private openExistingDetail(): void {
    const stack: NavPathStack | null = NavStacks.of(NavStacks.currentKey);
    if (stack !== null && this.existingId > 0) {
      stack.pushPathByName('subscriptionDetail', new SubscriptionParams(this.existingId));
    }
    this.onClose();
  }

  /** 取消订阅（已订阅时的管理态）：文案照 iOS 成员路径（取消键「先不」） */
  private confirmUnsubscribe(): void {
    this.getUIContext().showAlertDialog({
      title: `取消订阅《${this.title}》？`,
      message: '将取消你的订阅关注；已经下载或入库的文件不会被删除。',
      primaryButton: {
        value: '先不',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '取消订阅',
        fontColor: Theme.danger,
        action: (): void => {
          this.unsubscribe();
        }
      }
    });
  }

  private async unsubscribe(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.existingId <= 0) {
      return;
    }
    this.busy = true;
    try {
      const result: SubscriptionDeleteView = await api.subscriptionsDelete(this.existingId);
      const jobId: string | null = result.cleanup_job_id ?? null;
      this.toast(jobId !== null && jobId.length > 0
        ? '已取消订阅，正在后台清理关联内容（可在任务中心查看进度）'
        : '已取消订阅');
      setTimeout((): void => {
        this.onClose();
      }, 600);
    } catch (error) {
      this.toast('取消失败，请稍后再试');
    } finally {
      this.busy = false;
    }
  }

  // MARK: 视图

  build() {
    Column() {
      this.SheetBar()
      if (this.upgradeReport !== null) {
        // 洗版变体：报告态（同 iOS：报告在弹层内展示，「完成」关闭）
        Scroll() {
          Column({ space: 14 }) {
            UpgradeReportView({
              title: this.title,
              isMovie: this.kind === 'movie',
              report: this.upgradeReport as UpgradeRunView
            })
            Text('完成')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#0b0d12')
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding({ top: 14, bottom: 14 })
              .backgroundColor(Theme.accent)
              .borderRadius(Theme.cardRadius)
              .onClick(() => {
                this.onClose();
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 8, bottom: Theme.tabBarInset })
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .width('100%')
      } else if (this.loading) {
        this.LoadingState()
      } else if (this.errorMessage.length > 0) {
        this.ErrorState()
      } else if (this.existingId > 0) {
        this.ExistingState()
      } else if (this.status === PrepareStatus.notFound) {
        this.NotFoundState()
      } else if (this.status === PrepareStatus.ambiguous) {
        this.AmbiguousState()
      } else {
        this.ReadyState()
      }
    }
    .width('100%')
    .backgroundColor(Theme.bg)
    .bindSheet($$this.showPicker, this.PickerSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 弹层顶栏：左上 ✕ 关闭、右上 ✓ 确认（对应 iOS 的 form sheet） */
  @Builder
  SheetBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(18)
        .fontColor([Theme.textMuted])
        .width(40)
        .height(40)
        .onClick(() => {
          this.onClose();
        })
      Blank()
      // 标题同 iOS：洗版变体叫「订阅并洗版」
      Text(this.upgradeMode() ? '订阅并洗版' : '订阅')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Blank()
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(18)
        .fontColor([this.canSubmit() ? Theme.accent : Theme.textFaint])
        .width(40)
        .height(40)
        .onClick(() => {
          if (this.canSubmit()) {
            this.confirm();
          }
        })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
  }

  /** 能不能提交（对应 iOS `canSubmit`）：电影随时可订；剧集至少要一季或开了自动续订 */
  private canSubmit(): boolean {
    if (this.busy || this.status === PrepareStatus.notFound || this.existingId > 0) {
      return false;
    }
    if (this.status !== PrepareStatus.ready) {
      return false;
    }
    // 洗版变体（管理员）：必须选到一个带洗版目标的组（同 iOS `canSubmit`）
    if (this.upgradeMode() && this.canManage() && this.pickedUpgradeRule() === null) {
      return false;
    }
    if (this.kind !== 'tv') {
      return true;
    }
    return this.selected.length > 0 || this.followFuture;
  }

  /** 洗版变体里当前选中的、带洗版目标的规则组 */
  private pickedUpgradeRule(): RuleSetView | null {
    for (const rule of this.selectableRules()) {
      if (rule.id === this.ruleSetId && upgradeTargetOf(rule).length > 0) {
        return rule;
      }
    }
    return null;
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(26)
        .height(26)
        .color(Theme.textMuted)
      Text('正在获取条目信息…')
        .fontSize(14)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .height(220)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 10 }) {
      Text('订阅预览失败')
        .fontSize(16)
        .fontWeight(600)
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
          this.prepare(this.titleRef);
        })
    }
    .width('100%')
    .height(220)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  /** 已订阅：管理态（对应 iOS 的 already-subscribed） */
  @Builder
  ExistingState() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
        .fontSize(34)
        .fontColor([Theme.ok])
      Text(`该${this.kind === 'movie' ? '电影' : '剧集'}已在订阅中，movieclaw 正在持续追踪资源。`)
        .fontSize(14)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Text('查看订阅详情')
        .fontSize(15)
        .fontColor(Theme.text)
        .padding({ left: 22, right: 22, top: 10, bottom: 10 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(20)
        .border({ width: 1, color: Theme.line })
        .margin({ top: 6 })
        .onClick(() => {
          this.openExistingDetail();
        })
      Text('取消订阅')
        .fontSize(15)
        .fontColor(Theme.danger)
        .padding({ left: 22, right: 22, top: 10, bottom: 10 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(20)
        .border({ width: 1, color: Theme.line })
        .onClick(() => {
          this.confirmUnsubscribe();
        })
    }
    .width('100%')
    .height(260)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  /** TMDB 未收录（对应 iOS 的 not_found） */
  @Builder
  NotFoundState() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
        .fontSize(30)
        .fontColor([Theme.warn])
      Text('没有找到这部作品')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text('TMDB 未收录该条目，暂时无法订阅。订阅依赖 TMDB 的别名与季集数据来匹配站点资源，可尝试在 TMDB 搜索入口确认条目后再订阅。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height(220)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  /** 歧义：豆瓣收敛，先选一个（对应 iOS 的 ambiguous 候选海报墙） */
  @Builder
  AmbiguousState() {
    Column({ space: 12 }) {
      Text('找到多个可能的条目，请确认你订阅的是哪一部')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
        .textAlign(TextAlign.Center)
      List() {
        ForEach(this.candidates, (candidate: ResolveCandidateView) => {
          ListItem() {
            Row({ space: 14 }) {
              RemoteImage({
                url: ImageUrls.resolve(AppModel.origin(), candidate.poster_url, ImageVariant.posterCard) ?? ''
              })
                .width(48)
                .aspectRatio(Theme.posterAspect)
                .backgroundColor(Theme.surface)
                .borderRadius(6)
                .clip(true)
              Column({ space: 2 }) {
                Text(candidate.title)
                  .fontSize(16)
                  .fontColor(Theme.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.candidateSubtitle(candidate))
                  .fontSize(14)
                  .fontColor(Theme.textMuted)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .onClick(() => {
              this.pickCandidate(candidate);
            })
          }
        }, (candidate: ResolveCandidateView) => candidate.title_ref)
      }
      .width('100%')
      .height(280)
      .scrollBar(BarState.Off)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  private candidateSubtitle(candidate: ResolveCandidateView): string {
    const parts: string[] = [];
    const year: number | null = candidate.year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    if (candidate.original_title.length > 0 && candidate.original_title !== candidate.title) {
      parts.push(candidate.original_title);
    }
    return parts.join('  ·  ');
  }

  /** 入库库与订阅规则：不改就用后端路由的结论，改了要把理由藏起来（同 iOS） */
  @Builder
  RoutingSection() {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('入库媒体库')
            .fontSize(15)
            .fontColor(Theme.text)
          Text(this.libraryId === this.routedLibraryId && this.routedReason.length > 0
            ? this.routedReason
            : (this.canManage() ? '存到哪个库' : '由管理员配置的规则决定'))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.canManage()) {
          Text(this.libraryLabel())
            .fontSize(14)
            .fontColor(Theme.accentStrong)
            .maxLines(1)
            .onClick(() => {
              this.pickerKind = 'library';
              this.showPicker = true;
            })
        } else {
          Text(this.libraryLabel())
            .fontSize(14)
            .fontColor(Theme.textMuted)
            .maxLines(1)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      if (this.canManage()) {
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            // 洗版变体这一行叫「洗版规则」（同 iOS `ruleRow` 的 title）
            Text(this.upgradeMode() ? '洗版规则' : '订阅规则')
              .fontSize(15)
              .fontColor(Theme.text)
            Text(this.ruleSetId === this.routedRuleId && this.routedRuleReason.length > 0
              ? this.routedRuleReason : '用哪套规则去搜资源')
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .maxLines(2)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text(this.pickedRuleLabel())
            .fontSize(14)
            .fontColor(Theme.accentStrong)
            .maxLines(1)
            .onClick(() => {
              this.pickerKind = 'rule';
              this.showPicker = true;
              this.refreshRules();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        // 洗版变体没有可选组时给出指引（同 iOS `ruleRow` 的空态文案）
        if (this.upgradeMode() && this.selectableRules().length === 0) {
          Text('还没有配置洗版目标的规则组——新建一个，在编辑器里选择「洗到哪一档」即可。')
            .fontSize(12)
            .fontColor(Theme.warn)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 12 })
        } else if (this.ruleSetId > 0) {
          // 品质摘要放在行内：行底比脚注背后的毛玻璃实，字才看得清（同 iOS `pickedRule` 摘要）
          Text(this.pickedRuleSummary().length > 0
            ? this.pickedRuleSummary()
            : '该规则组不限任何条件——可能抓到低画质或无人做种的资源，建议在「设置 → 订阅规则 → 规则组」里加上分辨率与做种数限制')
            .fontSize(12)
            .fontColor(this.pickedRuleSummary().length > 0 ? Theme.textMuted : Theme.warn)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 12 })
        }
      }

      // 投递预检：落到哪个目录（只在拿得到时显示）
      if (this.dispatch !== null
        && (this.dispatch as DispatchPreviewView).path !== null
        && (this.dispatch as DispatchPreviewView).path !== undefined) {
        Divider().color(Theme.line).margin({ left: 16, right: 16 })
        Row({ space: 8 }) {
          Text('将存到')
            .fontSize(12)
            .fontColor(Theme.textFaint)
          Text((this.dispatch as DispatchPreviewView).path ?? '')
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 12 })
      }
    }
    .width('100%')
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .margin({ left: 16, right: 16, bottom: 12 })
  }

  /** 选择器：库与规则组共用（按 pickerKind 切换数据源） */
  @Builder
  PickerSheet() {
    Column() {
      Text(this.pickerKind === 'library' ? '选入库媒体库' : '选订阅规则')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16, bottom: 10 })
      List() {
        if (this.pickerKind === 'library') {
          ForEach(this.libraries, (library: LibraryView) => {
            ListItem() {
              this.PickerRow(library.name, `${library.stats.item_count} 部`, library.id === this.libraryId,
                (): void => {
                  this.libraryId = library.id;
                  this.showPicker = false;
                  // 改了库就要重拉投递预检（对应 iOS 的依赖变化）
                  this.refreshDispatch();
                })
            }
          }, (library: LibraryView) => `lib-${library.id}`)
        } else {
          // 洗版变体只列带洗版目标的组（同 iOS `selectableRules`）
          ForEach(this.selectableRules(), (rule: RuleSetView) => {
            ListItem() {
              this.PickerRow(this.upgradeMode() ? `${rule.name} · 洗到 ${upgradeTargetOf(rule)}` : rule.name,
                rule.is_default ? '默认规则组' : `被 ${rule.reference_count} 个订阅用着`,
                rule.id === this.ruleSetId, (): void => {
                  this.ruleSetId = rule.id;
                  this.showPicker = false;
                })
            }
          }, (rule: RuleSetView) => `rule-${rule.id}`)
          ListItem() {
            this.PickerRow('新建规则组…', '配洗版目标 / 画质条件', false, (): void => {
              this.showPicker = false;
              const stack: NavPathStack | null = NavStacks.of(NavStacks.currentKey);
              if (stack !== null) {
                stack.pushPathByName('ruleSetEditor', new RuleSetEditorParams(0));
              }
            })
          }
        }
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .divider({ strokeWidth: 1, color: Theme.line, startMargin: 20, endMargin: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  PickerRow(title: string, subtitle: string, selected: boolean, onTap: () => void) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(16)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(subtitle)
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(16)
          .fontColor([Theme.accent])
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 13, bottom: 13 })
    .onClick(() => {
      onTap();
    })
  }

  /** 就绪：剧集勾季 + 自动续订（对应 iOS 的 ready 分支） */
  @Builder
  ReadyState() {
    Column({ space: 12 }) {
      // 条目卡：海报 + 片名 + 年份/类型（对应 iOS 的 header）
      Row({ space: 14 }) {
        RemoteImage({ url: this.posterUrl })
          .width(56)
          .aspectRatio(Theme.posterAspect)
          .backgroundColor(Theme.surface)
          .borderRadius(8)
          .border({ width: 1, color: 'rgba(255,255,255,0.1)' })
          .clip(true)
        Column({ space: 4 }) {
          Text(this.title)
            .fontSize(20)
            .fontWeight(600)
            .fontColor(Theme.text)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.headerMeta())
            .fontSize(15)
            .fontColor(Theme.textMuted)
          if (this.movieOwned && this.existingId === 0) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(13)
                .fontColor([Theme.ok])
              // 洗版变体的说法不同（同 iOS：将体检现有版本并按需洗版）
              Text(this.upgradeMode() ? '媒体库已有，将体检现有版本并按需洗版' : '媒体库已有，订阅后不会重复下载')
                .fontSize(13)
                .fontColor(Theme.ok)
            }
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })

      // 洗版变体的说明（同 iOS header Section 的 footer）
      if (this.upgradeMode()) {
        Text('洗版通过订阅持续追踪更好的版本：确认后建立订阅并立即体检库里已有的每一集。')
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 4 })
      }

      this.RoutingSection()

      if (this.kind === 'tv') {
        Column({ space: 0 }) {
          Text('选择要收录的季')
            .fontSize(13)
            .fontColor(Theme.textFaint)
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 6 })
          ForEach(this.seasons, (season: SeasonOverview) => {
            Row({ space: 12 }) {
              SymbolGlyph(this.isSelected(season.season_number)
                ? $r('sys.symbol.checkmark_square_fill') : $r('sys.symbol.square'))
                .fontSize(20)
                .fontColor([this.isSelected(season.season_number) ? Theme.accent : Theme.textFaint])
              Column({ space: 2 }) {
                Text(season.name.length > 0 ? season.name : `第 ${season.season_number} 季`)
                  .fontSize(17)
                  .fontColor(Theme.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.seasonSubtitle(season))
                  .fontSize(13)
                  .fontColor(Theme.textMuted)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .onClick(() => {
              this.toggleSeason(season.season_number);
            })
          }, (season: SeasonOverview) => `${season.season_number}`)

          Text('勾选即要整季（含未播集）')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 10 })

          Divider().color(Theme.line).margin({ left: 16, right: 16 })
          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text('自动续订')
                .fontSize(16)
                .fontColor(Theme.text)
              Text('之后播出的新集、新一季自动加入追踪')
                .fontSize(13)
                .fontColor(Theme.textMuted)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.followFuture })
              .selectedColor(Theme.accent)
              .onChange((isOn: boolean): void => {
                this.followFuture = isOn;
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        }
        .width('100%')
        .margin({ left: 16, right: 16, bottom: 4 })
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      } else {
        Text('订阅后会自动搜索资源，下好并整理入库。')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
          .padding(16)
          .margin({ left: 16, right: 16, bottom: 4 })
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
      }
    }
    .width('100%')
    .padding({ bottom: 8 })
  }

  /** 头部位行：「2026 · 剧集」；年份未知只写类型 */
  private headerMeta(): string {
    const parts: string[] = [];
    if (this.mediaYear !== null && this.mediaYear > 0) {
      parts.push(`${this.mediaYear}`);
    }
    parts.push(this.kind === 'tv' ? '剧集' : '电影');
    return parts.join(' · ');
  }

  /** 季副标题：已播 / 总数 + 已入库（同 iOS 的季行） */
  private seasonSubtitle(season: SeasonOverview): string {
    const parts: string[] = [];
    const total: number = season.episode_count ?? 0;
    parts.push(total > 0 ? `已播 ${season.aired_count}/${total} 集` : `已播 ${season.aired_count} 集`);
    if (season.owned_count > 0) {
      parts.push(`已入库 ${season.owned_count}`);
    }
    return parts.join('  ·  ');
  }
}
