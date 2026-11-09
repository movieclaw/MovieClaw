import { describe, it, expect } from '@ohos/hypium';
import { StaleLoadGuard } from '../main/ets/common/StaleLoadGuard';

/**
 * StaleLoadGuard 的代次语义（对应 LibraryKindWallPage.load 的接入方式）。
 *
 * 连点排序 / 筛选会并发多轮 load()：旧轮在每个 await 之后回填前必须能感知自己
 * 已被作废，否则旧请求后到会把新结果盖掉（墙显示旧排序）。
 */
export default function staleLoadGuardTest() {
  describe('StaleLoadGuard', () => {
    it('begin_代次自增_只有最新一轮 isCurrent', 0, () => {
      const guard: StaleLoadGuard = new StaleLoadGuard();
      const first: number = guard.begin();
      const second: number = guard.begin();
      expect(first).assertEqual(1);
      expect(second).assertEqual(2);
      expect(guard.isCurrent(second)).assertTrue();
      expect(guard.isCurrent(first)).assertFalse();
    });

    it('lateRound_旧轮晚醒回填时被丢弃_墙由最后发起的那一轮说了算', 0, () => {
      const guard: StaleLoadGuard = new StaleLoadGuard();
      const slow: number = guard.begin();
      const fast: number = guard.begin();
      expect(guard.isCurrent(slow)).assertFalse();
      expect(guard.isCurrent(fast)).assertTrue();
      // 模拟两轮先后醒来回填：旧轮的 isCurrent 已为 false，调用方直接丢弃
      let applied: string = '';
      if (guard.isCurrent(slow)) {
        applied = 'stale';
      }
      if (guard.isCurrent(fast)) {
        applied = 'fresh';
      }
      expect(applied).assertEqual('fresh');
    });
  });
}
