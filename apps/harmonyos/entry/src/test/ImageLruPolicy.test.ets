import { describe, it, expect } from '@ohos/hypium';
import { ImageLruPolicy } from '../main/ets/common/ImageLruPolicy';

export default function imageLruPolicyTest(): void {
  describe('ImageLruPolicy', () => {
    it('touch_renews_lru_order', 0, () => {
      const policy = new ImageLruPolicy();
      policy.insert('a', 10);
      policy.insert('b', 10);
      policy.touch('a');
      const keys: string[] = policy.keysSnapshot();
      expect(keys.length).assertEqual(2);
      expect(keys[0]).assertEqual('b');
      expect(keys[1]).assertEqual('a');
    });
    it('evict_pops_oldest_first_until_within_budget', 0, () => {
      const policy = new ImageLruPolicy();
      policy.insert('a', 30);
      policy.insert('b', 30);
      policy.insert('c', 30);
      const evicted: string[] = policy.evictOverBudget(70);
      expect(evicted.length).assertEqual(1);
      expect(evicted[0]).assertEqual('a');
      expect(policy.size()).assertEqual(2);
      expect(policy.has('a')).assertFalse();
      expect(policy.has('c')).assertTrue();
    });
    it('touch_affects_eviction_order', 0, () => {
      const policy = new ImageLruPolicy();
      policy.insert('a', 10);
      policy.insert('b', 10);
      policy.touch('a');
      const evicted: string[] = policy.evictOverBudget(15);
      expect(evicted.length).assertEqual(1);
      expect(evicted[0]).assertEqual('b');
    });
    it('remove_adjusts_budget_and_order', 0, () => {
      const policy = new ImageLruPolicy();
      policy.insert('a', 40);
      policy.insert('b', 40);
      policy.remove('a');
      expect(policy.budget()).assertEqual(40);
      expect(policy.has('a')).assertFalse();
      const evicted: string[] = policy.evictOverBudget(40);
      expect(evicted.length).assertEqual(0);
    });
    it('insert_updates_cost_of_existing_key', 0, () => {
      const policy = new ImageLruPolicy();
      policy.insert('a', 100);
      policy.insert('a', 30);
      expect(policy.budget()).assertEqual(30);
      expect(policy.size()).assertEqual(1);
    });
    it('nonpositive_budget_disables_eviction', 0, () => {
      const policy = new ImageLruPolicy();
      policy.insert('a', 10);
      policy.insert('b', 10);
      const evicted: string[] = policy.evictOverBudget(0);
      expect(evicted.length).assertEqual(0);
      expect(policy.size()).assertEqual(2);
    });
    it('unknown_touch_and_remove_are_noop', 0, () => {
      const policy = new ImageLruPolicy();
      policy.insert('a', 10);
      policy.touch('missing');
      policy.remove('missing');
      expect(policy.size()).assertEqual(1);
      expect(policy.budget()).assertEqual(10);
    });
    it('clearAll_resets_keys_and_budget', 0, () => {
      const policy = new ImageLruPolicy();
      policy.insert('a', 10);
      policy.insert('b', 20);
      policy.clearAll();
      expect(policy.size()).assertEqual(0);
      expect(policy.budget()).assertEqual(0);
      expect(policy.has('a')).assertFalse();
      expect(policy.keysSnapshot().length).assertEqual(0);
      // 清空后可继续正常使用
      policy.insert('c', 5);
      expect(policy.has('c')).assertTrue();
      expect(policy.budget()).assertEqual(5);
    });
  });
}
