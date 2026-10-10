import { Theme } from '../theme/AppTheme';
import { Permissions } from '../common/Permissions';
import { AppModel } from '../common/AppModel';
import { UpgradeRunUnitView, UpgradeRunView } from '../api/Models';

/**
 * 体检报告段（对应 iOS `UpgradeRunReportView`）：摘要句 + 按季分组的单元列表（一次性快照）。
 * 洗版页与订阅弹层的洗版变体共用；「完成」按钮由宿主自己给（iOS 的脚手架提供）。
 */

/** 一个单元的体检结果分组（按季） */
export class UnitGroup {
  readonly season: number;
  readonly units: UpgradeRunUnitView[];

  constructor(season: number, units: UpgradeRunUnitView[]) {
    this.season = season;
    this.units = units;
  }
}

/** 状态 → (人话, 颜色)（对应 iOS `stateMeta`） */
export class StateMeta {
  readonly label: string;
  readonly color: string;

  constructor(label: string, color: string) {
    this.label = label;
    this.color = color;
  }
}

export function stateMeta(state: string): StateMeta {
  if (state === 'upgradable') {
    return new StateMeta('已排洗版', '#5eead4');
  }
  if (state === 'in_flight') {
    return new StateMeta('洗版中', '#7dd3fc');
  }
  if (state === 'at_cutoff') {
    return new StateMeta('已达目标', Theme.ok);
  }
  if (state === 'not_comparable') {
    return new StateMeta('无法确认', Theme.textFaint);
  }
  return new StateMeta('缺失', Theme.warn);
}

/** 单元说明（对应 iOS `note`） */
export function unitNote(unit: UpgradeRunUnitView): string {
  const current: string = unit.current_label !== null && unit.current_label !== undefined
    && unit.current_label.length > 0 ? unit.current_label : '未知';
  if (unit.state === 'upgradable') {
    return `当前 ${current} → 目标 ${unit.target_label}，已排入立即搜索`;
  }
  if (unit.state === 'in_flight') {
    return '已投递新版本，等待入库验证';
  }
  if (unit.state === 'at_cutoff') {
    return `当前 ${current}，已达洗版目标`;
  }
  if (unit.state === 'not_comparable') {
    return '无法确认当前版本是否低于目标，不自动洗；可「标注片源」告知系统，或用「手动选种」直接替换';
  }
  return '库里没有该单元，将照常搜索下载补齐';
}

@ComponentV2
export struct UpgradeReportView {
  @Param title: string = '';
  @Param isMovie: boolean = false;
  @Require @Param report: UpgradeRunView;
  /** true（且为管理员）时「无法确认」的季显示「标注片源」入口（同 iOS 的可选 `onAnnotate`） */
  @Param annotatable: boolean = false;
  @Event onAnnotate: (season: number) => void = (season: number): void => {
  };

  private unitGroups(): UnitGroup[] {
    const report: UpgradeRunView = this.report;
    const seen: number[] = [];
    for (const unit of report.units) {
      if (seen.indexOf(unit.season_number) < 0) {
        seen.push(unit.season_number);
      }
    }
    seen.sort((a: number, b: number): number => a - b);
    const out: UnitGroup[] = [];
    for (const season of seen) {
      out.push(new UnitGroup(season, report.units
        .filter((unit: UpgradeRunUnitView): boolean => unit.season_number === season)));
    }
    return out;
  }

  private canAnnotate(season: number): boolean {
    if (!this.annotatable || !Permissions.fromSession(AppModel.shared.session).isAdmin) {
      return false;
    }
    for (const unit of this.report.units) {
      if (unit.season_number === season && unit.state === 'not_comparable') {
        return true;
      }
    }
    return false;
  }

  build() {
    Column({ space: 14 }) {
      Text(this.report.summary)
        .fontSize(15)
        .fontColor(Theme.text)
        .padding(14)
        .width('100%')
        .backgroundColor('rgba(94,234,212,0.10)')
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: 'rgba(94,234,212,0.35)' })

      Text(`《${this.title}》· 目标 ${this.report.target_label}`)
        .fontSize(13)
        .fontColor(Theme.textFaint)
        .width('100%')

      ForEach(this.unitGroups(), (group: UnitGroup) => {
        Column({ space: 0 }) {
          Row({ space: 8 }) {
            Text(this.isMovie ? '正片' : (group.season === 0 ? '特别篇' : `第 ${group.season} 季`))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
            Blank()
            if (this.canAnnotate(group.season)) {
              Text('标注片源')
                .fontSize(12)
                .fontColor(Theme.accentStrong)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor(Theme.glassFill)
                .borderRadius(8)
                .border({ width: 1, color: Theme.line })
                .onClick(() => {
                  this.onAnnotate(group.season);
                })
            }
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 11, bottom: 8 })

          ForEach(group.units, (unit: UpgradeRunUnitView, index: number) => {
            Column() {
              Row({ space: 10 }) {
                Text(this.isMovie ? '正片' : `E${unit.episode_number < 10 ? '0' : ''}${unit.episode_number}`)
                  .fontSize(15)
                  .fontColor(Theme.text)
                  .width(44)
                Column({ space: 4 }) {
                  Text(stateMeta(unit.state).label)
                    .fontSize(11)
                    .fontColor(stateMeta(unit.state).color)
                    .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                    .backgroundColor('rgba(255,255,255,0.06)')
                    .borderRadius(8)
                  Text(unitNote(unit))
                    .fontSize(13)
                    .fontColor(Theme.textMuted)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 9, bottom: 9 })
              if (index < group.units.length - 1) {
                Divider().color(Theme.line).margin({ left: 14, right: 14 })
              }
            }
            .width('100%')
          }, (unit: UpgradeRunUnitView) => `u-${unit.season_number}-${unit.episode_number}`)
        }
        .width('100%')
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      }, (group: UnitGroup) => `g-${group.season}`)

      Text('后续进展在订阅详情的「追踪明细」里跟进：洗版中的单元带青色徽标，换版成功会记入活动记录。')
        .fontSize(13)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
