export interface PlaybackSegment {
  type: string;
  start_ms: number;
  end_ms: number;
  to_end: boolean;
}

export class SkipSegments {
  /** 离区间尾不足这么多毫秒就不再给「跳过」：按下去只省一两秒 */
  static readonly tailMs: number = 3000;
  /** 自动播下一集的倒计时 8 秒（5 秒来不及反应，用户反馈 2026-10-01） */
  static readonly autoNextMs: number = 8000;
  /** 连续自动播了这么多集、期间没人碰过播放器，就不再自动播 */
  static readonly autoNextMaxStreak: number = 3;

  static active(segments: PlaybackSegment[] | null, positionMs: number): PlaybackSegment | null {
    if (segments === null) {
      return null;
    }
    for (const segment of segments) {
      if (segment.type === 'outro' && segment.to_end) {
        continue;
      }
      if (positionMs >= segment.start_ms && positionMs < segment.end_ms - SkipSegments.tailMs) {
        return segment;
      }
    }
    return null;
  }

  static isInOutro(segments: PlaybackSegment[] | null, positionMs: number): boolean {
    if (segments === null) {
      return false;
    }
    for (const segment of segments) {
      if (segment.type === 'outro' && segment.to_end && positionMs >= segment.start_ms) {
        return true;
      }
    }
    return false;
  }

  /** 卡片要不要倒计时自动播下一集：认出了放到结尾的片尾（进了就开始），或已播完 */
  static autoNextArmed(segments: PlaybackSegment[] | null, positionMs: number,
    streak: number, ended: boolean): boolean {
    return streak < SkipSegments.autoNextMaxStreak
      && (ended || SkipSegments.isInOutro(segments, positionMs));
  }

  /** 「即将播放」卡片的时机：认出了放到结尾的片尾就从片尾起点给，否则播完才给 */
  static shouldShowUpNext(segments: PlaybackSegment[] | null, positionMs: number,
    ended: boolean): boolean {
    if (ended) {
      return true;
    }
    if (SkipSegments.active(segments, positionMs) !== null) {
      return false;
    }
    return SkipSegments.isInOutro(segments, positionMs);
  }
}
