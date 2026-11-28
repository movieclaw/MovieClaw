import { describe, it, expect } from '@ohos/hypium';
import {
  shouldPaginateOnReachEnd,
  shouldPrefetchOnScrollIndex
} from '../main/ets/discover/DiscoverPrefetchGuard';

export default function discoverPrefetchGuardTest(): void {
  describe('DiscoverPrefetchGuard', () => {
    it('blocks_scroll_and_reach_end_when_error_active', 0, () => {
      expect(shouldPrefetchOnScrollIndex(10, 10, 1, 3, true, false, true, false)).assertFalse();
      expect(shouldPaginateOnReachEnd(10, true, false, true, false)).assertFalse();
    });
    it('blocks_when_list_empty_even_if_last_non_negative', 0, () => {
      expect(shouldPrefetchOnScrollIndex(0, 0, 1, 3, true, false, false, false)).assertFalse();
      expect(shouldPrefetchOnScrollIndex(0, 2, 2, 3, true, false, false, false)).assertFalse();
      expect(shouldPaginateOnReachEnd(0, true, false, false, false)).assertFalse();
    });
    it('accounts_for_leading_header_items', 0, () => {
      // 10 rows at List indices 2..11 (2 leading items): row 6 (index 8) is 4 from end, row 7 (index 9) is 3 from end
      expect(shouldPrefetchOnScrollIndex(10, 8, 2, 3, true, false, false, false)).assertFalse();
      expect(shouldPrefetchOnScrollIndex(10, 9, 2, 3, true, false, false, false)).assertTrue();
    });
    it('blocks_when_loading_no_more_or_blocked', 0, () => {
      expect(shouldPrefetchOnScrollIndex(10, 10, 1, 3, true, true, false, false)).assertFalse();
      expect(shouldPrefetchOnScrollIndex(10, 10, 1, 3, false, false, false, false)).assertFalse();
      expect(shouldPrefetchOnScrollIndex(10, 10, 1, 3, true, false, false, true)).assertFalse();
    });
  });
}
