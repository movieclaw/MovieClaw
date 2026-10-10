import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  RuleSetView,
  SeasonOverview,
  SubscriptionDetailView,
  SubscriptionTrackingStatePayload,
  SubscriptionUpdatePayload,
  UpgradeRunPayload,
  UpgradeRunView
} from '../api/Models';
import { MediaSourceAnnotationParams } from './MediaSourceAnnotationPage';
import { UpgradeReportView } from './UpgradeReportView';
import { RuleSetEditorParams } from './RuleSetEditorPage';
import { upgradeTargetOf } from './RuleSetModel';

/** 洗版页的路由参数（路由参数会被序列化，不要用 instanceof） */
export class UpgradeRunParams {
  readonly subscriptionId: number;

  constructor(subscriptionId: number) {
    this.subscriptionId = subscriptionId;
  }

  static of(param: Object | undefined | null): UpgradeRunParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: UpgradeRunParams = param as UpgradeRunParams;
    const id: number = raw.subscriptionId;
    if (!Number.isFinite(id) || id <= 0) {
      return null;
    }
    return new UpgradeRunParams(Math.floor(id));
  }
}

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function UpgradeRunBuilder() {
  UpgradeRunPage()
}

/**
 * 「洗一轮版」页（对应 iOS `UpgradeRunSheet` / Web `upgrade-run-dialog`）。
 *
 * 两段式：确认段 → 报告段。确认段把既有订阅的三种状态并成一条动线：
 * 规则组未配洗版目标→先选一个带目标的组（含快捷新建）；库里有文件但不在订阅范围的季→列出并入；
 * 订阅已暂停→改为「恢复并触发」。报告段渲染后端体检快照（一次性，不轮询）。
 */
@ComponentV2
export struct UpgradeRunPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  private subscriptionId: number = 0;

  @Local private detail: SubscriptionDetailView | null = null;
  @Local private ruleSets: RuleSetView[] | null = null;
  @Local private ruleSetId: number = 0;
  @Local private optedSeasons: number[] = [];
  @Local private busy: boolean = false;
  @Local private errorMessage: string = '';
  @Local private failed: boolean = false;
  @Local private report: UpgradeRunView | null = null;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private picksRule(): boolean {
    return Permissions.fromSession(AppModel.shared.session).isAdmin;
  }

  private isMovie(): boolean {
    return this.detail !== null && this.detail.media.kind === 'movie';
  }

  private paused(): boolean {
    return this.detail !== null && this.detail.status === 'paused';
  }

  private upgradeRules(): RuleSetView[] {
    const list: RuleSetView[] = this.ruleSets ?? [];
    return list.filter((rule: RuleSetView): boolean => upgradeTargetOf(rule).length > 0);
  }

  private currentHasTarget(): boolean {
    const list: RuleSetView[] = this.ruleSets ?? [];
    for (const rule of list) {
      if (rule.id === (this.detail === null ? 0 : this.detail.rule_set_id)) {
        return upgradeTargetOf(rule).length > 0;
      }
    }
    return false;
  }

  private selectedRule(): RuleSetView | null {
    for (const rule of this.upgradeRules()) {
      if (rule.id === this.ruleSetId) {
        return rule;
      }
    }
    return null;
  }

  /** 库里有文件但不在订阅范围内的季（并入会连带补缺下载，是用户决策） */
  private outOfScopeOwned(): SeasonOverview[] {
    const detail: SubscriptionDetailView | null = this.detail;
    if (detail === null || detail.media.kind === 'movie') {
      return [];
    }
    const out: SeasonOverview[] = [];
    for (const season of detail.season_collection) {
      if (season.owned_count > 0 && detail.selected_seasons.indexOf(season.season_number) < 0) {
        out.push(season);
      }
    }
    return out;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError && error.message.length > 0) {
      return error.message;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '操作失败，请稍后重试';
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.detail = await api.subscriptionsGet(this.subscriptionId);
      this.failed = false;
      this.errorMessage = '';
      if (this.picksRule()) {
        await this.loadRules();
      }
    } catch (error) {
      this.failed = true;
      this.errorMessage = this.messageOf(error);
    }
  }

  /** 重新拉规则组清单（从「新建规则组」返回后可能新增了组）：不覆盖用户已选的组 */
  private async refreshRules(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const rules: RuleSetView[] = await api.rulesList();
      this.ruleSets = rules;
      if (this.ruleSetId === 0) {
        const candidates: RuleSetView[] = this.upgradeRules();
        this.ruleSetId = candidates.length === 1 ? candidates[0].id : 0;
      }
    } catch (error) {
      // 拿不到就保持原样
    }
  }

  private async loadRules(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const detail: SubscriptionDetailView | null = this.detail;
    if (api === null || detail === null) {
      return;
    }
    try {
      const rules: RuleSetView[] = await api.rulesList();
      this.ruleSets = rules;
      // 现用组已配洗版目标 → 预选它；否则只有一个可选组时也预选
      let current: RuleSetView | null = null;
      for (const rule of rules) {
        if (rule.id === detail.rule_set_id) {
          current = rule;
        }
      }
      if (current !== null && upgradeTargetOf(current).length > 0) {
        this.ruleSetId = current.id;
      } else {
        const candidates: RuleSetView[] = this.upgradeRules();
        this.ruleSetId = candidates.length === 1 ? candidates[0].id : 0;
      }
    } catch (error) {
      this.errorMessage = '未能加载规则组列表，请稍后重试';
    }
  }

  private async run(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    const detail: SubscriptionDetailView | null = this.detail;
    if (api === null || detail === null || this.busy) {
      return;
    }
    if (this.picksRule() && this.selectedRule() === null) {
      return;
    }
    this.busy = true;
    this.errorMessage = '';
    try {
      if (this.optedSeasons.length > 0) {
        const merged: number[] = detail.selected_seasons.concat(this.optedSeasons);
        merged.sort((a: number, b: number): number => a - b);
        const update: SubscriptionUpdatePayload = { selected_seasons: merged };
        await api.subscriptionsUpdate(detail.id, update);
      }
      if (this.paused()) {
        const body: SubscriptionTrackingStatePayload = { state: 'active' };
        await api.subscriptionsSetTrackingState(detail.id, body);
      }
      let switchTo: number | null = null;
      const selected: RuleSetView | null = this.selectedRule();
      if (selected !== null && selected.id !== detail.rule_set_id) {
        switchTo = selected.id;
      }
      const payload: UpgradeRunPayload = { rule_set_id: switchTo };
      this.report = await api.subscriptionsUpgradeRun(detail.id, payload);
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.busy = false;
    }
  }

  build() {
    NavDestination() {
      Column() {
        PageTopBar({
          title: this.report !== null ? '洗版体检报告' : '洗一轮版',
          onBack: (): void => {
            this.navStack.pop();
          }
        })
        Scroll() {
          Column({ space: 14 }) {
            if (this.failed) {
              Text(this.errorMessage)
                .fontSize(14)
                .fontColor(Theme.danger)
                .padding(16)
                .width('100%')
                .backgroundColor(Theme.surface)
                .borderRadius(Theme.cardRadius)
            } else if (this.detail === null) {
              Row({ space: 8 }) {
                LoadingProgress().width(18).height(18).color(Theme.textMuted)
                Text('正在加载订阅详情…').fontSize(14).fontColor(Theme.textMuted)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 40, bottom: 40 })
            } else if (this.report !== null) {
              UpgradeReportView({
                title: this.detail === null ? '' : (this.detail as SubscriptionDetailView).media.title,
                isMovie: this.isMovie(),
                report: this.report as UpgradeRunView,
                annotatable: true,
                onAnnotate: (season: number): void => {
                  this.openAnnotation(season);
                }
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
                  this.navStack.pop();
                })
            } else {
              this.Confirm(this.detail as SubscriptionDetailView)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 8, bottom: Theme.tabBarInset })
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    // 从「新建规则组」返回时重拉清单（同 iOS 的 sheet onSaved 之后刷新）
    .onShown(() => {
      if (this.started && this.picksRule()) {
        this.refreshRules();
      }
    })
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: UpgradeRunParams | null = UpgradeRunParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.subscriptionId = params.subscriptionId;
        this.load();
      }
    })
  }

  @Builder
  Confirm(detail: SubscriptionDetailView) {
    Column({ space: 14 }) {
      Text(`逐集检查《${detail.media.title}》库里已有的版本，低于洗版目标的立即排入搜索；`
        + '洗到新版本入库并验证通过后，旧文件自动替换。')
        .fontSize(15)
        .fontColor(Theme.textMuted)

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(13)
          .fontColor(Theme.danger)
          .padding(12)
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(12)
      }
      if (this.paused()) {
        Text('该订阅已暂停。触发洗版会先恢复追踪，随后开始搜索。')
          .fontSize(13)
          .fontColor(Theme.warn)
          .padding(12)
          .width('100%')
          .backgroundColor('rgba(245,196,81,0.10)')
          .borderRadius(12)
      }

      // 洗版目标
      Column({ space: 0 }) {
        Text('洗版目标')
          .fontSize(13)
          .fontColor(Theme.textFaint)
          .width('100%')
          .padding({ bottom: 6 })
        Column({ space: 0 }) {
          if (!this.picksRule()) {
            Text('按订阅当前的规则组洗版')
              .fontSize(17)
              .fontColor(Theme.textMuted)
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          } else if (this.ruleSets === null) {
            Row({ space: 8 }) {
              LoadingProgress().width(16).height(16).color(Theme.textMuted)
              Text('正在加载规则组…').fontSize(13).fontColor(Theme.textMuted)
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          } else {
            ForEach(this.upgradeRules(), (rule: RuleSetView, index: number) => {
              Column() {
                Row({ space: 10 }) {
                  Column({ space: 3 }) {
                    Text(rule.name + (rule.id === detail.rule_set_id ? '（当前使用）' : ''))
                      .fontSize(17)
                      .fontColor(Theme.text)
                    Text(`洗到 ${upgradeTargetOf(rule)}`)
                      .fontSize(13)
                      .fontColor('#5eead4')
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  if (rule.id === this.ruleSetId) {
                    SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                      .fontSize(20)
                      .fontColor(['#5eead4'])
                  }
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 11, bottom: 11 })
                .onClick(() => {
                  this.ruleSetId = rule.id;
                })
                if (index < this.upgradeRules().length - 1) {
                  Divider().color(Theme.line).margin({ left: 14, right: 14 })
                }
              }
              .width('100%')
            }, (rule: RuleSetView) => `rule-${rule.id}`)
          }
        }
        .width('100%')
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })

        if (this.ruleSets !== null) {
          // 快捷新建规则组（同 iOS：只有管理员能建；编辑器保存后回到本页会重拉规则组）
          if (this.picksRule()) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.plus'))
                .fontSize(14)
                .fontColor([Theme.accentStrong])
              Text('新建规则组…')
                .fontSize(14)
                .fontColor(Theme.accentStrong)
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .onClick(() => {
              this.navStack.pushPathByName('ruleSetEditor', new RuleSetEditorParams(0));
            })
          }
          if (this.upgradeRules().length === 0) {
            Text('还没有配置洗版目标的规则组。请联系管理员在「设置 → 订阅规则 → 规则组」中配置「洗到哪一档」。')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ top: 6 })
          } else if (!this.currentHasTarget()) {
            Text('当前规则组未配置洗版目标，选一个带洗版目标的组，确认后一并换用。')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .width('100%')
              .padding({ top: 6 })
          }
        }
      }
      .width('100%')

      // 范围外的库存季
      if (this.outOfScopeOwned().length > 0) {
        Column({ space: 0 }) {
          Text('范围外的库存季')
            .fontSize(13)
            .fontColor(Theme.textFaint)
            .width('100%')
            .padding({ bottom: 6 })
          Column({ space: 0 }) {
            ForEach(this.outOfScopeOwned(), (season: SeasonOverview, index: number) => {
              Column() {
                Row({ space: 10 }) {
                  Column({ space: 3 }) {
                    Text(season.season_number === 0 ? '特别篇' : `第 ${season.season_number} 季`)
                      .fontSize(17)
                      .fontColor(Theme.text)
                    Text(this.stockLabel(season))
                      .fontSize(13)
                      .fontColor(Theme.textMuted)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  if (this.optedSeasons.indexOf(season.season_number) >= 0) {
                    SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                      .fontSize(20)
                      .fontColor([Theme.accent])
                  }
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 11, bottom: 11 })
                .onClick(() => {
                  const at: number = this.optedSeasons.indexOf(season.season_number);
                  if (at >= 0) {
                    this.optedSeasons.splice(at, 1);
                  } else {
                    this.optedSeasons.push(season.season_number);
                  }
                })
                if (index < this.outOfScopeOwned().length - 1) {
                  Divider().color(Theme.line).margin({ left: 14, right: 14 })
                }
              }
              .width('100%')
            }, (season: SeasonOverview) => `s-${season.season_number}`)
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius)
          .border({ width: 1, color: Theme.line })
          Text('这些季库里有文件但不在订阅范围内，勾选后并入订阅一起洗版；季内缺集会一并搜索补齐。')
            .fontSize(13)
            .fontColor(Theme.textFaint)
            .width('100%')
            .padding({ top: 6 })
        }
        .width('100%')
      }

      Text(this.busy ? '处理中…' : (this.paused() ? '恢复并触发洗版' : '开始体检并洗版'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.canRun() ? '#0b0d12' : Theme.textFaint)
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 14, bottom: 14 })
        .backgroundColor(this.canRun() ? Theme.accent : Theme.glassFill)
        .borderRadius(Theme.cardRadius)
        .onClick(() => {
          this.run();
        })
    }
    .width('100%')
  }

  private canRun(): boolean {
    if (this.busy || this.ruleSets === null && this.picksRule()) {
      return false;
    }
    return !this.picksRule() || this.selectedRule() !== null;
  }

  private stockLabel(season: SeasonOverview): string {
    const total: number = season.episode_count ?? 0;
    return total > 0 && season.owned_count < total
      ? `库存 ${season.owned_count} / ${total} 集` : `库存 ${season.owned_count} 集`;
  }

  private openAnnotation(season: number): void {
    const detail: SubscriptionDetailView | null = this.detail;
    if (detail === null) {
      return;
    }
    this.navStack.pushPathByName('mediaSourceAnnotation',
      new MediaSourceAnnotationParams(detail.media.media_item_id, season, this.isMovie()));
  }
}
