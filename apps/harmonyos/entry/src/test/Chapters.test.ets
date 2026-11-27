import { describe, it, expect } from '@ohos/hypium';
import { Chapters } from '../main/ets/player/Chapters';
import { PlaybackChapterMarkView } from '../main/ets/api/Models';

/**
 * 播放器章节纯逻辑的单测：有无章节的降级判断（available）、
 * 当前位置定位（indexAt）、行文案（label / currentLabel）。
 * 真机上的弹层交互与 seek 要在设备上验证（本地无 DevEco，未构建验证）。
 */
export default function chaptersTest() {
  describe('Chapters', () => {
    const marks: PlaybackChapterMarkView[] = [
      { start_ms: 0, title: '开场' },
      { start_ms: 750000, title: null },
      { start_ms: 1500000, title: '高潮' }
    ];

    it('available_有章节才出入口', 0, () => {
      expect(Chapters.available([])).assertFalse();
      expect(Chapters.available(marks)).assertTrue();
    });

    it('indexAt_最后一个不超位置的章节', 0, () => {
      expect(Chapters.indexAt([], 1000)).assertEqual(-1);
      // 位置在第一章之前（理论上不会出现，兜底 -1）
      expect(Chapters.indexAt([{ start_ms: 5000, title: null }], 1000)).assertEqual(-1);
      expect(Chapters.indexAt(marks, 0)).assertEqual(0);
      expect(Chapters.indexAt(marks, 749999)).assertEqual(0);
      expect(Chapters.indexAt(marks, 750000)).assertEqual(1);
      expect(Chapters.indexAt(marks, 9999999)).assertEqual(2);
    });

    it('label_标题优先无标题退时间', 0, () => {
      expect(Chapters.label(marks[0], '0:00')).assertEqual('开场');
      expect(Chapters.label(marks[1], '12:30')).assertEqual('12:30');
      expect(Chapters.label(marks[1], '')).assertEqual('');
    });

    it('currentLabel_当前章节名无章节空串', 0, () => {
      expect(Chapters.currentLabel(marks, 800000, '12:30')).assertEqual('12:30');
      expect(Chapters.currentLabel(marks, 2000000, '33:20')).assertEqual('高潮');
      expect(Chapters.currentLabel([], 1000, '0:01')).assertEqual('');
    });
  });
}
