import { hiAppEvent, hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';

/**
 * 性能打点统一出口（hiAppEvent BEHAVIOR 事件 + hilog 结构化行 + 供诊断页读的最近值）。
 *
 * 设计约束：
 * - **DFX 不能反过来干扰功能**：所有上报 fire-and-forget，失败静默（一行 warn 留痕）；
 * - 计时优先使用单调时钟（`systemDateTime.getUptime`），系统回拨墙钟不会产生负数耗时；
 * - 事件名 ≤48 字符、字母数字下划线（hiAppEvent 规格）；耗时一律毫秒且下限为 0；
 * - `end` 只对已有 `begin` 的名字生效，失败/中途退出路径调 `cancel` 撤消未完成标记，
 *   不把失败耗时或残留旧标记误报成成功指标；
 * - 最近值留在内存 Map 里，AboutPage 的诊断块直接读，不落盘、不驻后台。
 *
 * 事件清单（关键链路全覆盖）：
 * - `cold_start`：EntryAbility.onCreate → 首页 loadContent 完成；
 * - `session_ready`：onCreate → AppModel.restore() 真正进入 ready；
 * - `playback_open`：PlayerPage 打开 → 首次进入播放态。
 */
export class PerfTelemetry {
  /** hiAppEvent 事件域：字母开头、≤32 字符 */
  private static readonly DOMAIN: string = 'movieclaw_perf';
  private static readonly HILOG_DOMAIN: number = 0x0690;
  private static readonly TAG: string = 'MovieClawPerf';

  /** begin 单调时间戳（毫秒） */
  private static readonly marks: Map<string, number> = new Map<string, number>();
  /** 最近一次上报值（诊断页展示） */
  private static readonly lastValues: Map<string, number> = new Map<string, number>();

  /** 单调时钟（ms）：NTP 回拨墙钟不倒退；模拟器/异常时退回 Date.now。 */
  private static nowMs(): number {
    try {
      return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
    } catch (error) {
      return Date.now();
    }
  }

  /** 开始计时；同名重复 begin 覆盖（以后一次为准）。 */
  static begin(name: string): void {
    PerfTelemetry.marks.set(name, PerfTelemetry.nowMs());
  }

  /** 撤消未完成的计时标记（失败、未登录、未起播即退出时调用，避免残留旧标记或误报）。 */
  static cancel(name: string): void {
    PerfTelemetry.marks.delete(name);
  }

  /**
   * 结束计时并上报；返回耗时 ms（下限 0）。
   * 没有对应 begin（未启动/已消费/已撤消）返回 -1 且**不上报**——
   * 冷启动类指标因此天然只报首次，重入路径零噪音。
   */
  static end(name: string, detail?: string): number {
    const startedAt: number | undefined = PerfTelemetry.marks.get(name);
    if (startedAt === undefined) {
      return -1;
    }
    PerfTelemetry.marks.delete(name);
    const elapsedMs: number = Math.max(0, Math.round(PerfTelemetry.nowMs() - startedAt));
    PerfTelemetry.report(name, elapsedMs, detail);
    return elapsedMs;
  }

  /** 直接上报一个瞬时值（计数/耗时皆可）；detail 是给聚合分析看的维度串。 */
  static report(name: string, value: number, detail?: string): void {
    PerfTelemetry.lastValues.set(name, value);
    const detailText: string = detail ?? '';
    hilog.info(PerfTelemetry.HILOG_DOMAIN, PerfTelemetry.TAG,
      '%{public}s value=%{public}d detail=%{public}s', name, value, detailText);
    hiAppEvent.write({
      domain: PerfTelemetry.DOMAIN,
      name: name,
      eventType: hiAppEvent.EventType.BEHAVIOR,
      params: {
        'value': value,
        'detail': detailText
      }
    }).catch((error: BusinessError): void => {
      hilog.warn(PerfTelemetry.HILOG_DOMAIN, PerfTelemetry.TAG,
        'hiAppEvent write 失败 name=%{public}s code=%{public}d', name, error.code);
    });
  }

  /** 最近一次上报值（诊断页展示）；没报过返回 -1。 */
  static lastValueOf(name: string): number {
    const value: number | undefined = PerfTelemetry.lastValues.get(name);
    return value ?? -1;
  }
}
