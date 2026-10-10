import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { LogContent, LogDay, LogDayList } from '../api/Models';

/** 级别（对应 iOS `SettingsLogEntry.Level`；`CRITICAL` 归到错误） */
class LogLevel {
  static readonly error: string = 'ERROR';
  static readonly warning: string = 'WARNING';
  static readonly info: string = 'INFO';
  static readonly debug: string = 'DEBUG';

  static normalize(raw: string): string {
    if (raw === 'CRITICAL' || raw === 'ERROR' || raw === 'FATAL') {
      return LogLevel.error;
    }
    if (raw === 'WARNING' || raw === 'WARN') {
      return LogLevel.warning;
    }
    if (raw === 'DEBUG' || raw === 'TRACE') {
      return LogLevel.debug;
    }
    return LogLevel.info;
  }

  static color(level: string): string {
    if (level === LogLevel.error) {
      return Theme.danger;
    }
    if (level === LogLevel.warning) {
      return Theme.warn;
    }
    if (level === LogLevel.debug) {
      return Theme.textFaint;
    }
    return Theme.textMuted;
  }

  static label(level: string): string {
    if (level === LogLevel.error) {
      return '错误';
    }
    if (level === LogLevel.warning) {
      return '警告';
    }
    if (level === LogLevel.debug) {
      return '调试';
    }
    return '信息';
  }
}

/** 一条日志（时间只留当天时刻，日期由所选天数隐含） */
class LogEntry {
  readonly index: number;
  readonly time: string;
  readonly level: string;
  readonly module: string;
  message: string;

  constructor(index: number, time: string, level: string, module: string, message: string) {
    this.index = index;
    this.time = time;
    this.level = level;
    this.module = module;
    this.message = message;
  }
}

/** 刷新档（对应 iOS；选择记在本机，只对当天日志生效） */
class RefreshOption {
  readonly label: string;
  readonly ms: number;

  constructor(label: string, ms: number) {
    this.label = label;
    this.ms = ms;
  }
}

const REFRESH_OPTIONS: RefreshOption[] = [
  new RefreshOption('关闭', 0),
  new RefreshOption('3s', 3000),
  new RefreshOption('10s', 10000),
  new RefreshOption('30s', 30000)
];

/**
 * 设置 → 系统日志（对应 iOS `LogsSettingsView` / Web `system-logs-section`）：在线日志查看器。
 *
 * 照 iOS 的四件事：
 * - 按天列表（`logsDays`）+ 内容（`logsRead(day, tail)`，超长默认只取末尾，可「加载全部」）；
 * - 按后端固定格式「**时间 | 级别 | 模块 | 内容**」解析成条目，**异常堆栈等续行归并进上一条**；
 * - 级别筛选（全部 / 错误 / 警告 / 信息 / 调试，**带条数**）+ 关键字搜索；
 * - 自动刷新 关 / 3s / **10s（默认）** / 30s，**只对当天日志生效，看历史日期时暂停**。
 *
 * **没做**：tail -f 式跟随（停在底部自动滚入 + 「N 条新日志」回底）、全屏查看、搜索高亮。
 * 阅读器本身是只读的，先保证「看得到、筛得出、能刷新」。
 */
@ComponentV2
export struct LogsSection {
  @Local private days: LogDay[] = [];
  @Local private activeDay: string = '';
  @Local private entries: LogEntry[] = [];
  @Local private totalLines: number = 0;
  @Local private truncated: boolean = false;
  @Local private levelFilter: string = '';
  @Local private keyword: string = '';
  @Local private loading: boolean = true;
  @Local private loadingAll: boolean = false;
  @Local private errorMessage: string = '';
  @Local private refreshMs: number = 10000;
  @Local private sheetKind: string = '';
  @Local private showSheet: boolean = false;

  private timer: number = -1;
  private started: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.stopPoll();
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
    this.loading = true;
    try {
      const list: LogDayList = await api.logsDays();
      this.days = list.days;
      if (this.days.length > 0 && this.activeDay.length === 0) {
        this.activeDay = this.days[0].day;
      }
      this.errorMessage = '';
      if (this.activeDay.length > 0) {
        await this.loadDay(false);
      }
      this.schedulePoll();
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  private async loadDay(loadAll: boolean): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.activeDay.length === 0) {
      return;
    }
    if (loadAll) {
      this.loadingAll = true;
    }
    try {
      const content: LogContent = await api.logsRead(this.activeDay, loadAll ? 0 : 2000);
      this.entries = LogsSection.parse(content.lines);
      this.totalLines = content.total_lines;
      this.truncated = content.truncated;
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loadingAll = false;
    }
  }

  /**
   * 行流 → 条目（对应 iOS `SettingsLogModel.parse`）。
   *
   * 匹配固定格式的行开一条新的；**匹配不上的行当作上一条的续行**（异常堆栈就是这么来的）；
   * 文件开头就是续行时（tail 把堆栈拦腰截断）单独成条兜底，不把内容丢掉。
   */
  private static parse(lines: string[]): LogEntry[] {
    const out: LogEntry[] = [];
    for (const line of lines) {
      // 后端格式：2026-10-02 23:12:59.024 | INFO | module | message
      const match: RegExpMatchArray | null =
        line.match(/^\d{4}-\d{2}-\d{2} (\d{2}:\d{2}:\d{2})\S* \| ([A-Z]+) \| (\S+) \| (.*)$/);
      if (match !== null) {
        out.push(new LogEntry(out.length, match[1], LogLevel.normalize(match[2]), match[3], match[4]));
      } else if (out.length > 0) {
        out[out.length - 1].message += `\n${line}`;
      } else if (line.trim().length > 0) {
        out.push(new LogEntry(0, '', LogLevel.info, '', line));
      }
    }
    return out;
  }

  /** 自动刷新：**只对当天日志生效**，看历史日期时暂停（同 iOS） */
  private schedulePoll(): void {
    this.stopPoll();
    if (this.refreshMs <= 0 || this.days.length === 0 || this.activeDay !== this.days[0].day) {
      return;
    }
    this.timer = setInterval((): void => {
      this.loadDay(false);
    }, this.refreshMs);
  }

  private stopPoll(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 派生

  private filtered(): LogEntry[] {
    const key: string = this.keyword.trim().toLowerCase();
    const out: LogEntry[] = [];
    for (const entry of this.entries) {
      if (this.levelFilter.length > 0 && entry.level !== this.levelFilter) {
        continue;
      }
      if (key.length > 0 && entry.message.toLowerCase().indexOf(key) < 0
        && entry.module.toLowerCase().indexOf(key) < 0) {
        continue;
      }
      out.push(entry);
    }
    return out;
  }

  /** 某个级别的条数（筛选胶囊上的数字） */
  private countOf(level: string): number {
    let count: number = 0;
    for (const entry of this.entries) {
      if (level.length === 0 || entry.level === level) {
        count++;
      }
    }
    return count;
  }

  private isLatestDay(): boolean {
    return this.days.length > 0 && this.activeDay === this.days[0].day;
  }

  private refreshLabel(): string {
    for (const option of REFRESH_OPTIONS) {
      if (option.ms === this.refreshMs) {
        return option.label;
      }
    }
    return '10s';
  }

  // MARK: 动作

  private pickDay(day: string): void {
    this.activeDay = day;
    this.showSheet = false;
    this.loadDay(false).then((): void => {
      // 换天之后刷新策略要跟着变（历史日期暂停）
      this.schedulePoll();
    });
  }

  private pickRefresh(ms: number): void {
    this.refreshMs = ms;
    this.showSheet = false;
    this.schedulePoll();
  }

  // MARK: 视图

  build() {
    Column({ space: 0 }) {
      this.Toolbar()
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(13)
          .fontColor(Theme.danger)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }
      this.Window()
      this.Footer()
    }
    .width('100%')
    .height('100%')
    /*
       * **一个组件只能绑一个 `bindSheet`**（后绑的覆盖前面的）。这里原本绑了两个，
       * 所以其中一个弹层一直打不开——合成单槽位 + 内容切换。
       */
      .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 工具栏：日期 + 刷新档 + 级别（带条数）+ 搜索 */
  @Builder
  Toolbar() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.calendar'))
            .fontSize(13)
            .fontColor([Theme.textMuted])
          Text(this.activeDay.length > 0 ? this.activeDay : '选择日期')
            .fontSize(13)
            .fontColor(Theme.text)
        }
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(16)
        .border({ width: 1, color: Theme.line })
        .onClick(() => {
          this.sheetKind = 'day';
    this.showSheet = true;
        })

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(13)
            .fontColor([this.isLatestDay() && this.refreshMs > 0 ? Theme.accent : Theme.textMuted])
          Text(this.refreshLabel())
            .fontSize(13)
            .fontColor(Theme.text)
        }
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(16)
        .border({ width: 1, color: Theme.line })
        .onClick(() => {
          this.sheetKind = 'refresh';
    this.showSheet = true;
        })
        Blank()
      }
      .width('100%')

      // 级别筛选（带条数）
      Row({ space: 6 }) {
        this.LevelChip('', '全部')
        this.LevelChip(LogLevel.error, '错误')
        this.LevelChip(LogLevel.warning, '警告')
        this.LevelChip(LogLevel.info, '信息')
        this.LevelChip(LogLevel.debug, '调试')
      }
      .width('100%')

      Search({ value: this.keyword, placeholder: '搜关键字或模块…' })
        .width('100%')
        .height(38)
        .placeholderColor(Theme.textFaint)
        .placeholderFont({ size: 14 })
        .textFont({ size: 14 })
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(19)
        .onChange((value: string): void => {
          this.keyword = value;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 10 })
  }

  @Builder
  LevelChip(level: string, label: string) {
    Text(`${label} ${this.countOf(level)}`)
      .fontSize(12)
      .fontColor(this.levelFilter === level ? '#0b0d12' : Theme.textMuted)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor(this.levelFilter === level ? Theme.accent : Theme.glassFill)
      .borderRadius(12)
      .onClick(() => {
        this.levelFilter = level;
      })
  }

  /** 日志窗口：时间 / 级别 / 模块 / 内容；续行已在解析时并进上一条 */
  @Builder
  Window() {
    if (this.loading) {
      Column({ space: 10 }) {
        LoadingProgress().width(24).height(24).color(Theme.textMuted)
        Text('正在加载日志…').fontSize(13).fontColor(Theme.textFaint)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.filtered().length === 0) {
      Column({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.externaldrive'))
          .fontSize(28)
          .fontColor([Theme.textFaint])
        Text(this.entries.length === 0 ? '这天没有日志' : '没有匹配的日志')
          .fontSize(15)
          .fontColor(Theme.textMuted)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      List() {
        ForEach(this.filtered(), (entry: LogEntry) => {
          ListItem() {
            Column({ space: 3 }) {
              Row({ space: 8 }) {
                Text(entry.time)
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
                Text(LogLevel.label(entry.level))
                  .fontSize(10)
                  .fontColor(LogLevel.color(entry.level))
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                  .backgroundColor(Theme.glassFill)
                  .borderRadius(5)
                Text(entry.module)
                  .fontSize(11)
                  .fontColor(Theme.textMuted)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              Text(entry.message)
                .fontSize(12)
                .fontColor(entry.level === LogLevel.error ? Theme.danger : Theme.text)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          }
        }, (entry: LogEntry) => `${entry.index}`)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .divider({ strokeWidth: 1, color: Theme.line, startMargin: 16, endMargin: 16 })
    }
  }

  /** 底部：说明 + 「加载全部」 */
  @Builder
  Footer() {
    Column({ space: 6 }) {
      if (this.truncated) {
        Text(this.loadingAll ? '正在加载全部…' : `只显示了末尾（共 ${this.totalLines} 行），点这里加载全部`)
          .fontSize(13)
          .fontColor(Theme.accentStrong)
          .width('100%')
          .onClick(() => {
            if (!this.loadingAll) {
              this.loadDay(true);
            }
          })
      }
      Text('日志按天存档在服务端，超过保留天数的旧日志会自动清理；保留天数与目录位置可用 '
        + 'LOG_RETENTION_DAYS、LOG_DIR 环境变量调整。')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .width('100%')
      if (!this.isLatestDay() && this.refreshMs > 0) {
        Text('正在查看历史日志，自动刷新已暂停')
          .fontSize(11)
          .fontColor(Theme.warn)
          .width('100%')
      }
    }
    .width('100%')
    // 页脚在整屏页最底部，要让开系统手势条，否则最后一行说明被小白条压住
    .padding({ left: 16, right: 16, top: 8, bottom: 8 + Theme.safeBottomInset })
  }

  /** 唯一的弹层内容：按 sheetKind 切换 */
  @Builder
  SheetContent() {
    if (this.sheetKind === 'day') {
      this.DaySheet()
    } else {
      this.RefreshSheet()
    }
  }

  @Builder
  DaySheet() {
    Column() {
      Text('选择日期')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16, bottom: 10 })
      List() {
        ForEach(this.days, (day: LogDay) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(day.day)
                .fontSize(16)
                .fontColor(Theme.text)
                .layoutWeight(1)
              Text(this.sizeLabel(day.size_bytes))
                .fontSize(12)
                .fontColor(Theme.textFaint)
              if (day.day === this.activeDay) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(16)
                  .fontColor([Theme.accent])
              }
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 13, bottom: 13 })
            .onClick(() => {
              this.pickDay(day.day);
            })
          }
        }, (day: LogDay) => day.day)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  private sizeLabel(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${Math.round(bytes / 1024)} KB`;
    }
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }

  @Builder
  RefreshSheet() {
    Column() {
      Text('自动刷新')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16, bottom: 6 })
      Text('只对当天日志生效；看历史日期时会自动暂停。')
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .padding({ bottom: 10 })
      ForEach(REFRESH_OPTIONS, (option: RefreshOption) => {
        Row({ space: 10 }) {
          Text(option.label)
            .fontSize(16)
            .fontColor(Theme.text)
            .layoutWeight(1)
          if (option.ms === this.refreshMs) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([Theme.accent])
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 13, bottom: 13 })
        .onClick(() => {
          this.pickRefresh(option.ms);
        })
      }, (option: RefreshOption) => `${option.ms}`)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
