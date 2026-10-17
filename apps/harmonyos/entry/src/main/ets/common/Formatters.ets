/**
 * 展示格式化工具（逐条对齐 iOS 端 DesignSystem/Theme.swift 的 Formatters，
 * 口径即 Web 端 dayjs zh-cn 与 lib/format.ts）。
 *
 * 时间解析：后端 ISO8601 串可能不带时区（库内是 UTC），不带时区的补 Z 按 UTC 解析。
 * fromNow 是全 App 唯一的「多久之前」算法，复刻 dayjs relativeTime 插件的默认阈值。
 */
export class Formatters {
  /** 两位数字补零（S01E02、集号等） */
  static pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** 字节 → 「19.40 GB」（Web formatBytes 口径：1024 进制、保留两位，≥100 或 B 取整） */
  static bytes(value: number | null): string {
    if (value === null || value < 0) {
      return '—';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    let v: number = value;
    let i: number = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    const rounded: number = Math.round(v * 100) / 100;
    if (rounded >= 100 || i === 0) {
      return `${Math.round(rounded)} ${units[i]}`;
    }
    return `${rounded.toFixed(2)} ${units[i]}`;
  }

  /** 秒 → 「1:52:18」/「53:55」；空/负/非有限值 → 「--:--」 */
  static clock(seconds: number | null): string {
    if (seconds === null || !Number.isFinite(seconds) || seconds < 0) {
      return '--:--';
    }
    const total: number = Math.floor(seconds);
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    return h > 0 ? `${h}:${Formatters.pad2(m)}:${Formatters.pad2(s)}` : `${m}:${Formatters.pad2(s)}`;
  }

  /** 分钟 → 「1 小时 52 分」 */
  static duration(minutes: number | null): string {
    if (minutes === null || minutes <= 0) {
      return '';
    }
    const h: number = Math.floor(minutes / 60);
    const m: number = minutes % 60;
    if (h === 0) {
      return `${m} 分钟`;
    }
    return m === 0 ? `${h} 小时` : `${h} 小时 ${m} 分`;
  }

  /**
   * 解析后端时间字符串 → epoch 毫秒；空串/解析失败返回 null。
   * 带时区标记（Z 或 ±hh:mm）按原样解析；不带时区的补 Z 按 UTC 解析（后端库内是 UTC）。
   */
  static date(raw: string | null): number | null {
    if (raw === null || raw.length === 0) {
      return null;
    }
    const hasZone: boolean = raw.endsWith('Z') || raw.endsWith('z') || /[+-]\d{2}:?\d{2}$/.test(raw);
    const normalized: string = hasZone ? raw : `${raw}Z`;
    const parsed: number = Date.parse(normalized);
    return Number.isNaN(parsed) ? null : parsed;
  }

  /** 相对时间：「几秒前」「3 分钟前」；空值返回空串（调用方各自给占位） */
  static relative(raw: string | null): string {
    const dateMs: number | null = Formatters.date(raw);
    if (dateMs === null) {
      return '';
    }
    return Formatters.fromNow(dateMs);
  }

  /**
   * 全 App 唯一的「多久之前」算法，复刻 dayjs relativeTime（默认阈值 + zh-cn 措辞）：
   * 每一档先把差值换算成该档单位并四舍五入，再与阈值比较——
   * ≤44 秒「几秒」、≤89 秒「1 分钟」、≤44 分「N 分钟」、≤89 分「1 小时」、≤21 时「N 小时」、
   * ≤35 时「1 天」、≤25 天「N 天」、≤45 天「1 个月」、≤10 月「N 个月」、≤17 月「1 年」、再往后「N 年」；
   * 过去加「前」，将来加「内」。
   */
  static fromNow(dateMs: number, nowMs: number = Date.now()): string {
    const delta: number = (nowMs - dateMs) / 1000;
    const seconds: number = Math.abs(delta);
    let text: string;
    if (Math.round(seconds) <= 44) {
      text = '几秒';
    } else if (Math.round(seconds) <= 89) {
      text = '1 分钟';
    } else if (Math.round(seconds / 60) <= 44) {
      text = `${Math.max(1, Math.round(seconds / 60))} 分钟`;
    } else if (Math.round(seconds / 60) <= 89) {
      text = '1 小时';
    } else if (Math.round(seconds / 3600) <= 21) {
      text = `${Math.max(1, Math.round(seconds / 3600))} 小时`;
    } else if (Math.round(seconds / 3600) <= 35) {
      text = '1 天';
    } else if (Math.round(seconds / 86400) <= 25) {
      text = `${Math.max(1, Math.round(seconds / 86400))} 天`;
    } else if (Math.round(seconds / 86400) <= 45) {
      text = '1 个月';
    } else {
      const months: number = Formatters.monthDiff(Math.min(dateMs, nowMs), Math.max(dateMs, nowMs));
      if (Math.round(months) <= 10) {
        text = `${Math.max(1, Math.round(months))} 个月`;
      } else if (Math.round(months) <= 17) {
        text = '1 年';
      } else {
        text = `${Math.max(1, Math.round(months / 12))} 年`;
      }
    }
    return delta >= 0 ? `${text}前` : `${text}内`;
  }

  /** 两个时刻相差的月数（带小数，同 dayjs monthDiff：整月数 + 余下部分占下一个整月的比例） */
  private static monthDiff(startMs: number, endMs: number): number {
    const start: Date = new Date(startMs);
    const end: Date = new Date(endMs);
    const whole: number =
      (end.getUTCFullYear() - start.getUTCFullYear()) * 12 + (end.getUTCMonth() - start.getUTCMonth());
    const anchor: number = Date.UTC(
      start.getUTCFullYear(), start.getUTCMonth() + whole, start.getUTCDate(),
      start.getUTCHours(), start.getUTCMinutes(), start.getUTCSeconds(), start.getUTCMilliseconds());
    const next: number = Date.UTC(
      start.getUTCFullYear(), start.getUTCMonth() + whole + 1, start.getUTCDate(),
      start.getUTCHours(), start.getUTCMinutes(), start.getUTCSeconds(), start.getUTCMilliseconds());
    if (next <= anchor) {
      return whole;
    }
    return whole + (endMs - anchor) / (next - anchor);
  }

  /** 「2026-09-25 17:03」（本地时区） */
  static dateTime(raw: string | null): string {
    const dateMs: number | null = Formatters.date(raw);
    if (dateMs === null) {
      return raw ?? '';
    }
    const d: Date = new Date(dateMs);
    const month: string = Formatters.pad2(d.getMonth() + 1);
    const day: string = Formatters.pad2(d.getDate());
    const hour: string = Formatters.pad2(d.getHours());
    const minute: string = Formatters.pad2(d.getMinutes());
    return `${d.getFullYear()}-${month}-${day} ${hour}:${minute}`;
  }
}
