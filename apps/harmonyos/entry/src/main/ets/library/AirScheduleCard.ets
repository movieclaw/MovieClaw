/**
 * 剧集详情页的播出日历 UI（issue #547）：分集区里的「季进度条」入口卡 + 按天的日程面板。
 *
 * 只在本季还有今天或以后的播出日期时由宿主页渲染（服务端不给 air_schedule 就整块不画）。
 * 进度条一集一格：已入库 / 缺集 / 今天 / 待播；日程按播出日分组，已播部分折叠成一行汇总，
 * 停更的日子画一条虚线分隔，节奏看得出来。口径与 Web 端 `library-air-schedule.tsx` 对应。
 */
import { Theme } from '../theme/AppTheme';
import { EpisodeView, SearchNowView, SeasonAirScheduleView } from '../api/Models';
import { AppModel } from '../common/AppModel';
import { MovieClawApi } from '../api/Endpoints';
import {
  AirCounts,
  AirDay,
  AirGap,
  AirSegment,
  AirTone,
  ArrivalKind,
  ArrivalState,
  airCounts,
  airDays,
  airSegments,
  arrivalState,
  arrivalText,
  cadenceText,
  daysBetween,
  finaleText,
  formatAirDay,
  formatWeekday,
  gapBetween,
  nextAirDay,
  rangeLabel,
  regionName
} from './AirSchedule';

/** 没拿到日历时的空占位（@Prop 的默认值，正常渲染路径不会用到） */
const AIR_EMPTY_SCHEDULE: SeasonAirScheduleView = {
  today: '',
  weekdays: [],
  missing_episodes: [],
  arrivals: []
};

/** 季进度条色段的颜色（同 Web TONE_CLASS）：灰白=已入库、琥珀=缺集、蓝=今天(订阅)、灰=今天(未订阅)、暗格=待播 */
function toneColor(tone: AirTone): string {
  switch (tone) {
    case AirTone.Owned:
      return '#c3cad6';
    case AirTone.Missing:
      return Theme.warning;
    case AirTone.Today:
      return '#3b82f6';
    case AirTone.TodayFree:
      return '#7c8494';
    case AirTone.Upcoming:
    case AirTone.Absent:
    default:
      return 'rgba(255,255,255,0.14)';
  }
}

/** 入库预告文案的颜色（同 Web arrivalView 的 className 口径） */
export function arrivalColor(state: ArrivalState): string {
  switch (state.kind) {
    case ArrivalKind.InLibrary:
      return Theme.ok;
    case ArrivalKind.NotSubscribed:
    case ArrivalKind.Waiting:
      return Theme.textMuted;
    case ArrivalKind.Downloading:
    case ArrivalKind.Organizing:
    case ArrivalKind.Expected:
    default:
      return Theme.info;
  }
}

/** 季进度条：一集一格，超过 40 集合并同状态色段 */
@Component
struct AirSeasonBar {
  @Prop episodes: EpisodeView[] = [];
  @Prop schedule: SeasonAirScheduleView = AIR_EMPTY_SCHEDULE;
  @Prop barHeight: number = 8;

  build() {
    Row({ space: 2 }) {
      ForEach(airSegments(this.episodes, this.schedule), (segment: AirSegment) => {
        Column()
          .height(this.barHeight)
          .layoutWeight(segment.count)
          .backgroundColor(toneColor(segment.tone))
          .borderRadius(2)
      }, (segment: AirSegment, index: number) => `${index}-${segment.tone}-${segment.count}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}

/**
 * 分集区里的入口卡：更新规律、季进度条、下次更新与入库状态、汇总。
 * 点开由宿主页弹日程面板（`AirScheduleSheet`）。
 */
@Component
export struct AirScheduleCard {
  @Prop episodes: EpisodeView[] = [];
  @Prop schedule: SeasonAirScheduleView = AIR_EMPTY_SCHEDULE;
  onOpen: () => void = (): void => {
  };

  build() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.calendar'))
          .fontSize(15)
          .fontColor([Theme.accentStrong])
        Text('播出日历')
          .fontSize(14)
          .fontWeight(600)
          .fontColor(Theme.text)
        Blank()
        Text(this.metaText())
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '58%' })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontWeight(600)
          .fontColor([Theme.textFaint])
      }
      .width('100%')

      AirSeasonBar({
        episodes: this.episodes,
        schedule: this.schedule,
        barHeight: 8
      })

      Row({ space: 8 }) {
        Text(this.headline())
          .fontSize(14)
          .fontWeight(600)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.noteText())
          .fontSize(12)
          .fontColor(this.noteColor())
          .maxLines(1)
      }
      .width('100%')

      Row({ space: 10 }) {
        Text(`已入库 ${this.counts().owned}`)
          .fontSize(12)
          .fontColor(Theme.textMuted)
        if (this.counts().missing === 1) {
          Text(`缺第 ${this.schedule.missing_episodes[0]} 集`)
            .fontSize(12)
            .fontColor(Theme.warning)
        } else if (this.counts().missing > 1) {
          Text(`缺 ${this.counts().missing} 集`)
            .fontSize(12)
            .fontColor(Theme.warning)
        }
        if (this.counts().upcoming > 0) {
          Text(`还有 ${this.counts().upcoming} 集待播`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor('rgba(30,33,43,0.74)')
    .borderRadius(16)
    .border({ width: 1, color: Theme.line })
    .onClick(() => {
      this.onOpen();
    })
  }

  private counts(): AirCounts {
    return airCounts(this.episodes, this.schedule);
  }

  /** 卡头右侧的元信息：「每周三更新 · 10月30日 完结」 */
  private metaText(): string {
    const parts: string[] = [];
    const cadence: string | null = cadenceText(this.schedule);
    if (cadence !== null) {
      parts.push(cadence);
    }
    const finale: string | null = finaleText(this.schedule);
    if (finale !== null) {
      parts.push(finale);
    }
    return parts.join(' · ');
  }

  private nextDay(): AirDay | null {
    return nextAirDay(airDays(this.episodes, this.schedule));
  }

  /** 主句：「今天更新 第 4 集 / 今天大结局 第 12 集 / 下次 10月30日 周五（美国） · 第 5 集」 */
  private headline(): string {
    const next: AirDay | null = this.nextDay();
    if (next === null) {
      return '';
    }
    const range: string = rangeLabel(next.episodes);
    if (next.today) {
      return next.finale ? `今天大结局 ${range}` : `今天更新 ${range}`;
    }
    return `下次 ${this.dayLabel(next.date)} · ${range}`;
  }

  /** 「10月28日 周三」，海外首播带地区括注（同 Web dayLabel） */
  private dayLabel(day: string): string {
    const date: string = `${formatAirDay(day)} ${formatWeekday(day)}`;
    const region: string = this.schedule.region ?? '';
    return region.length > 0 ? `${date}（${regionName(region)}）` : date;
  }

  /** 主句右侧的注：今天的入库预告 / 明天 / N 天后 */
  private noteText(): string {
    const next: AirDay | null = this.nextDay();
    if (next === null) {
      return '';
    }
    if (next.today) {
      const state: ArrivalState | null = arrivalState(next.episodes, this.schedule);
      return state === null ? '' : arrivalText(state);
    }
    const offset: number = daysBetween(this.schedule.today, next.date);
    return offset === 1 ? '明天' : `${offset} 天后`;
  }

  private noteColor(): string {
    const next: AirDay | null = this.nextDay();
    if (next !== null && next.today) {
      const state: ArrivalState | null = arrivalState(next.episodes, this.schedule);
      return state === null ? Theme.textMuted : arrivalColor(state);
    }
    return Theme.textMuted;
  }
}

/**
 * 播出日历的日程面板：进度条 + 图例，已播折叠成一行汇总，之后每个播出日一行；
 * 停更画虚线分隔（周更剧的正常周末间隔不画），今天高亮，未订阅底部给「订阅追更」。
 * 宿主页用 bindSheet 弹。
 */
@Component
export struct AirScheduleSheet {
  @Prop episodes: EpisodeView[] = [];
  @Prop schedule: SeasonAirScheduleView = AIR_EMPTY_SCHEDULE;
  @Prop title: string = '';
  @Prop seasonLabel: string = '';
  /** 有订阅权限且条目有 TMDB id（订阅靠 TMDB 匹配站点资源）才给「订阅追更」 */
  canSubscribe: boolean = false;
  onSubscribe: () => void = (): void => {
  };
  onClose: () => void = (): void => {
  };
  /** 已播折叠展开 */
  @State private pastOpen: boolean = false;
  /** 补搜在途 */
  @State private searching: boolean = false;

  build() {
    Column() {
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('播出日历')
            .fontSize(16)
            .fontWeight(600)
            .fontColor(Theme.text)
          Text(this.headerSub())
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('完成')
          .fontSize(14)
          .fontWeight(500)
          .fontColor(Theme.textMuted)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16 })

      Column({ space: 8 }) {
        AirSeasonBar({
          episodes: this.episodes,
          schedule: this.schedule,
          barHeight: 10
        })
        this.LegendRow()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 20, right: 20, top: 14 })

      Scroll() {
        Column({ space: 6 }) {
          if (this.pastDays().length > 0) {
            this.PastHeader()
          }
          if (this.pastOpen) {
            this.DayRows(this.pastDays())
          }
          this.DayRows(this.comingDays())
          if ((this.schedule.region ?? '').length > 0) {
            Text(`播出日期为${regionName(this.schedule.region ?? '')}当地日期`)
              .fontSize(10)
              .fontColor(Theme.textMuted)
              .margin({ top: 6 })
          }
          if ((this.schedule.subscription_id ?? null) !== null) {
            Text('播出日期来自 TMDB · 入库时间是订阅按站点发布规律推算的')
              .fontSize(10)
              .fontColor(Theme.textMuted)
              .margin({ top: 4 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Start)

      if ((this.schedule.subscription_id ?? null) === null && this.canSubscribe) {
        Divider()
          .color(Theme.line)
          .margin({ left: 20, right: 20 })
        Column({ space: 8 }) {
          Text('订阅追更')
            .fontSize(15)
            .fontWeight(600)
            .fontColor('#0b0d12')
            .width('100%')
            .height(44)
            .textAlign(TextAlign.Center)
            .backgroundColor(Color.White)
            .borderRadius(22)
            .onClick(() => {
              this.onSubscribe();
            })
          Text('之后每一集播出后都会自动下载入库')
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 12, bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  private headerSub(): string {
    const parts: string[] = [];
    if (this.title.length > 0) {
      parts.push(this.title);
    }
    if (this.seasonLabel.length > 0) {
      parts.push(this.seasonLabel);
    }
    const cadence: string | null = cadenceText(this.schedule);
    if (cadence !== null) {
      parts.push(cadence);
    }
    return parts.join(' · ');
  }

  private days(): AirDay[] {
    return airDays(this.episodes, this.schedule);
  }

  private pastDays(): AirDay[] {
    const out: AirDay[] = [];
    for (const day of this.days()) {
      if (day.past) {
        out.push(day);
      }
    }
    return out;
  }

  private comingDays(): AirDay[] {
    const out: AirDay[] = [];
    for (const day of this.days()) {
      if (!day.past) {
        out.push(day);
      }
    }
    return out;
  }

  private counts(): AirCounts {
    return airCounts(this.episodes, this.schedule);
  }

  /** 周更剧：唯一的更新星期（其正常间隔不画分隔，只留真停更） */
  private isWeekly(): boolean {
    const seen: number[] = [];
    for (const weekday of this.schedule.weekdays) {
      if (seen.indexOf(weekday) < 0) {
        seen.push(weekday);
      }
    }
    return seen.length === 1;
  }

  /** 周更剧的非停更间隔不画（头部已写「每周四更新」） */
  private gapText(previous: string, next: string): string | null {
    const gap: AirGap | null = gapBetween(previous, next);
    if (gap === null) {
      return null;
    }
    if (this.isWeekly() && !gap.isBreak) {
      return null;
    }
    return gap.text;
  }

  /** 「补 N 集」可见：有订阅权限、有订阅、确有缺集（同 Web canFind） */
  private canFind(): boolean {
    return this.canSubscribe
      && (this.schedule.subscription_id ?? null) !== null
      && this.schedule.missing_episodes.length > 0;
  }

  private findLabel(): string {
    const count: number = this.schedule.missing_episodes.length;
    return count === 1 ? `补第 ${this.schedule.missing_episodes[0]} 集` : `补 ${count} 集`;
  }

  /** 重新排队订阅的缺口工单（同 Web findMissing）：跳过冷却立即搜一轮 */
  private async findMissing(): Promise<void> {
    const subscriptionId: number = this.schedule.subscription_id ?? 0;
    const api: MovieClawApi | null = AppModel.shared.api;
    if (this.searching || subscriptionId <= 0 || api === null) {
      return;
    }
    this.searching = true;
    try {
      const result: SearchNowView = await api.subscriptionsSearchMissingResources(subscriptionId);
      this.toast(`${result.reset_count} 个缺口已重新排队，正在搜索`);
    } catch (error) {
      this.toast('搜索失败，请重试');
    } finally {
      this.searching = false;
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  /** 已播折叠头：一行汇总（集数/已入库/缺集）+ 展开箭头 + 「补 N 集」 */
  @Builder
  PastHeader() {
    Row({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontWeight(600)
          .fontColor([Theme.textMuted])
          .rotate({ angle: this.pastOpen ? 90 : 0 })
        Column({ space: 2 }) {
          Text(this.pastLabel())
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.text)
          Text(this.pastSummary())
            .fontSize(12)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .layoutWeight(1)
      .onClick(() => {
        this.pastOpen = !this.pastOpen;
      })

      if (this.canFind()) {
        Text(this.searching ? '搜索中…' : this.findLabel())
          .fontSize(12)
          .fontWeight(600)
          .fontColor(Theme.warning)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(14)
          .border({ width: 1, color: 'rgba(251,191,36,0.55)' })
          .backgroundColor('rgba(251,191,36,0.1)')
          .onClick(() => {
            this.findMissing();
          })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 8, top: 8, bottom: 8 })
    .backgroundColor(Theme.glassFill)
    .borderRadius(12)
  }

  private pastLabel(): string {
    const past: AirDay[] = this.pastDays();
    if (past.length === 0) {
      return '';
    }
    if (past.length === 1) {
      return `已播出 · ${formatAirDay(past[0].date)}`;
    }
    return `已播出 · ${formatAirDay(past[0].date)}–${formatAirDay(past[past.length - 1].date)}`;
  }

  private pastSummary(): string {
    const past: AirDay[] = this.pastDays();
    let total: number = 0;
    let owned: number = 0;
    let missing: number = 0;
    for (const day of past) {
      for (const episode of day.episodes) {
        total += 1;
        if (episode.owned) {
          owned += 1;
        } else if (this.schedule.missing_episodes.indexOf(episode.episode_number) >= 0) {
          missing += 1;
        }
      }
    }
    const parts: string[] = [`${total} 集`, `已入库 ${owned}`];
    if (missing === 1) {
      parts.push(`缺第 ${this.schedule.missing_episodes[0]} 集`);
    } else if (missing > 1) {
      parts.push(`缺 ${missing} 集`);
    }
    return parts.join(' · ');
  }

  /** 播出日列表：相邻日之间画停更分隔 */
  @Builder
  DayRows(list: AirDay[]) {
    ForEach(list, (day: AirDay, index: number) => {
      if (index > 0) {
        this.GapRow(list[index - 1].date, day.date)
      }
      this.DayRow(day)
    }, (day: AirDay) => day.date)
  }

  /** 停更分隔：虚线夹说明（「周四不更新 / 周四至周五不更新 / 停更 12 天」） */
  @Builder
  GapRow(previous: string, next: string) {
    if (this.gapText(previous, next) !== null) {
      Row({ space: 10 }) {
        Row()
          .layoutWeight(1)
          .height(1)
          .border({ width: { top: 1 }, style: BorderStyle.Dashed, color: 'rgba(255,255,255,0.2)' })
        Text(this.gapText(previous, next) as string)
          .fontSize(10)
          .fontColor(Theme.textMuted)
        Row()
          .layoutWeight(1)
          .height(1)
          .border({ width: { top: 1 }, style: BorderStyle.Dashed, color: 'rgba(255,255,255,0.2)' })
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
    }
  }

  /** 一个播出日：左日期块，中间集号范围（+大结局标、缺集说明），右状态槽 */
  @Builder
  DayRow(day: AirDay) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(day.today ? '今天' : formatWeekday(day.date))
          .fontSize(10)
          .fontWeight(day.today ? 700 : 400)
          .fontColor(day.today ? Theme.info : Theme.textMuted)
        Text(formatAirDay(day.date))
          .fontSize(14)
          .fontWeight(700)
          .fontColor(Theme.text)
      }
      .width(60)
      .alignItems(HorizontalAlign.Center)

      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(rangeLabel(day.episodes))
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.text)
          if (day.finale) {
            Text('大结局')
              .fontSize(10)
              .fontWeight(700)
              .fontColor(Theme.text)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor('rgba(255,255,255,0.14)')
              .borderRadius(8)
          }
        }
        if (this.dayMissingText(day) !== null) {
          Text(this.dayMissingText(day) as string)
            .fontSize(12)
            .fontColor(Theme.warning)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (day.today && this.dayStatusText(day).length > 0) {
        Text(this.dayStatusText(day))
          .fontSize(12)
          .fontWeight(600)
          .fontColor(this.dayStatusColor(day))
          .maxLines(2)
          .constraintSize({ maxWidth: '42%' })
          .textAlign(TextAlign.End)
      } else if (day.past && this.dayAllOwned(day)) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(12)
            .fontWeight(700)
            .fontColor([Theme.ok])
          Text('已入库')
            .fontSize(12)
            .fontColor(Theme.ok)
        }
      } else if (day.past && this.dayMissingCount(day) === 0) {
        Text('库里没有')
          .fontSize(12)
          .fontColor(Theme.textMuted)
      } else if (day.past && this.canFind()) {
        Text(this.searching ? '搜索中…' : '补这一集')
          .fontSize(12)
          .fontWeight(600)
          .fontColor(Theme.warning)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(14)
          .border({ width: 1, color: 'rgba(251,191,36,0.55)' })
          .onClick(() => {
            this.findMissing();
          })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 12, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor(day.today ? 'rgba(59,130,246,0.12)' : Theme.glassFill)
    .border({ width: day.today ? 1 : 0, color: 'rgba(59,130,246,0.5)' })
  }

  private dayMissingEpisodes(day: AirDay): EpisodeView[] {
    const out: EpisodeView[] = [];
    if (!day.past) {
      return out;
    }
    for (const episode of day.episodes) {
      if (this.schedule.missing_episodes.indexOf(episode.episode_number) >= 0) {
        out.push(episode);
      }
    }
    return out;
  }

  private dayMissingText(day: AirDay): string | null {
    const missing: EpisodeView[] = this.dayMissingEpisodes(day);
    if (missing.length === 0) {
      return null;
    }
    if (missing.length === 1) {
      return `缺第 ${missing[0].episode_number} 集`;
    }
    return `缺 ${missing.length} 集`;
  }

  private dayMissingCount(day: AirDay): number {
    return this.dayMissingEpisodes(day).length;
  }

  private dayAllOwned(day: AirDay): boolean {
    for (const episode of day.episodes) {
      if (!episode.owned) {
        return false;
      }
    }
    return true;
  }

  private dayStatusText(day: AirDay): string {
    const state: ArrivalState | null = arrivalState(day.episodes, this.schedule);
    return state === null ? '' : arrivalText(state);
  }

  private dayStatusColor(day: AirDay): string {
    const state: ArrivalState | null = arrivalState(day.episodes, this.schedule);
    return state === null ? Theme.textMuted : arrivalColor(state);
  }

  /** 图例：已入库 / 缺集 / 今天 / 待播，右侧完结日 */
  @Builder
  LegendRow() {
    Row({ space: 14 }) {
      this.LegendItem(toneColor(AirTone.Owned), `已入库 ${this.counts().owned}`)
      if (this.counts().missing > 0) {
        this.LegendItem(toneColor(AirTone.Missing), `缺集 ${this.counts().missing}`)
      }
      if (this.todayLegendCount() >= 0) {
        this.LegendItem(this.todayLegendColor(), `今天 ${this.todayLegendCount()}`)
      }
      this.LegendItem(toneColor(AirTone.Upcoming), `待播 ${this.counts().upcoming}`)
      Blank()
      if (this.finaleLabelText() !== null) {
        Text(this.finaleLabelText() as string)
          .fontSize(10)
          .fontColor(Theme.textMuted)
      }
    }
    .width('100%')
  }

  /** 今天图例的格数；-1 = 今天没有集播出，不显示 */
  private todayLegendCount(): number {
    const coming: AirDay[] = this.comingDays();
    if (coming.length === 0 || !coming[0].today) {
      return -1;
    }
    let count: number = 0;
    for (const episode of coming[0].episodes) {
      if (!episode.owned) {
        count += 1;
      }
    }
    return count;
  }

  private todayLegendColor(): string {
    return toneColor((this.schedule.subscription_id ?? null) !== null ? AirTone.Today : AirTone.TodayFree);
  }

  private finaleLabelText(): string | null {
    return finaleText(this.schedule);
  }

  @Builder
  LegendItem(color: string, label: string) {
    Row({ space: 5 }) {
      Column()
        .width(8)
        .height(8)
        .borderRadius(2)
        .backgroundColor(color)
      Text(label)
        .fontSize(10)
        .fontColor(Theme.textMuted)
    }
  }
}
