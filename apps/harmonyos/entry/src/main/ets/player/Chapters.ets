import { PlaybackChapterMarkView } from '../api/Models';

/**
 * 播放器章节的纯逻辑（对齐 iOS PlayerControls 的 chapter 部分）：
 * 当前位置定位、行文案、有无章节的降级判断。UI（PhonePlaybackHost / TvPlaybackHost）只管接线。
 */
export class Chapters {
  /** 会话里有章节刻度才出「章节」入口；无章节数据静默降级 */
  static available(marks: PlaybackChapterMarkView[]): boolean {
    return marks.length > 0;
  }

  /** 当前位置落在哪一章的下标（最后一个 start_ms <= 位置）；无章节或在第一章之前 → -1 */
  static indexAt(marks: PlaybackChapterMarkView[], positionMs: number): number {
    let index: number = -1;
    for (let i = 0; i < marks.length; i++) {
      if (marks[i].start_ms <= positionMs) {
        index = i;
      }
    }
    return index;
  }

  /** 章节行的标题：标题优先，无标题退起始时间（clock 由调用方格式化，纯逻辑不碰 UI） */
  static label(mark: PlaybackChapterMarkView, clock: string): string {
    const title: string | null = mark.title ?? null;
    return title !== null && title.length > 0 ? title : clock;
  }

  /** 设置菜单「章节」行的提示：当前章节名；无章节或在第一章之前返回空串 */
  static currentLabel(marks: PlaybackChapterMarkView[], positionMs: number, clock: string): string {
    const index: number = Chapters.indexAt(marks, positionMs);
    return index >= 0 ? Chapters.label(marks[index], clock) : '';
  }

  static activeIndex(marks: PlaybackChapterMarkView[], positionMs: number): number {
    return Chapters.indexAt(marks, positionMs);
  }

  static currentTitle(marks: PlaybackChapterMarkView[], positionMs: number): string {
    return Chapters.currentLabel(marks, positionMs, '');
  }
}
