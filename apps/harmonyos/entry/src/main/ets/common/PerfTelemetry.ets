import { hiAppEvent, hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 性能打点统一出口（hiAppEvent BEHAVIOR 事件 + hilog 结构化行 + 供诊断页读的最近值）。
 *
 * 设计约束：
 * - **DFX 不能反过来干扰功能**：所有上报 fire-and-forget，失败静默（一行 warn 留痕）；
 * - 事件名 ≤48 字符、字母数字下划线（hiAppEvent 规格）；耗时一律毫秒；
 * - `end` 只对已有 `begin` 的名字生效——冷启动这类「一次会话只报一次」的指标，
 *   后续重入（再次 restore / 再开播放页）不会重复上报旧计时；
 * - 最近值留在内存 Map 里，AboutPage 的诊断块直接读，不落盘、不驻后台。
 *
 * 事件清单（关键链路全覆盖）：
 * - `cold_start`：EntryAbility.onCreate → 首页 loadContent 完成；
 * - `session_ready`：onCreate → AppModel.restore() 会话就绪（首次同步完成）；
 * - `playback_open`：PlayerPage 打开 → 首次进入播放态。
 */
export class PerfTelemetry {
  /** hiAppEvent 事件域：字母开头、≤32 字符 */
  private static readonly DOMAIN: string = 'movieclaw_perf';
  private static readonly HILOG_DOMAIN: number = 0x0690;
  private static readonly TAG: string = 'MovieClawPerf';

  /** begin 时间戳（Date.now，毫秒） */
  private static readonly marks: Map<string, number> = new Map<string, number>();
  /** 最近一次上报值（诊断页展示） */
  private static readonly lastValues: Map<string, number> = new Map<string, number>();

  /** 开始计时；同名重复 begin 覆盖（以后一次为准）。 */
  static begin(name: string): void {
    PerfTelemetry.marks.set(name, Date.now());
  }

  /**
   * 结束计时并上报；返回耗时 ms。
   * 没有对应 begin（未启动/已消费）返回 -1 且**不上报**——
   * 冷启动类指标因此天然只报首次，重入路径零噪音。
   */
  static end(name: string, detail?: string): number {
    const startedAt: number | undefined = PerfTelemetry.marks.get(name);
    if (startedAt === undefined) {
      return -1;
    }
    PerfTelemetry.marks.delete(name);
    const elapsedMs: number = Date.now() - startedAt;
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
