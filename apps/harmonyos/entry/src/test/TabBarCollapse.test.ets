import { describe, it, expect } from '@ohos/hypium';
import { TabBarCollapse } from '../main/ets/common/TabBarCollapse';

export default function tabBarCollapseTest(): void {
  describe('TabBarCollapse', () => {
    it('slow_scroll_accumulates_below_per_frame_threshold', 0, () => {
      const state = new TabBarCollapse();
      for (let top = 0; top <= 40; top += 2) { state.onScroll(top); }
      expect(state.collapsed).assertTrue();
      for (let top = 38; top >= 28; top -= 2) { state.onScroll(top); }
      expect(state.collapsed).assertFalse();
    });
    it('small_direction_changes_do_not_expand_collapsed_bar', 0, () => {
      const state = new TabBarCollapse(); state.onScroll(0); state.onScroll(80);
      for (let index = 0; index < 8; index++) { state.onScroll(77); state.onScroll(80); }
      expect(state.collapsed).assertTrue();
      state.onScroll(68); expect(state.collapsed).assertFalse();
    });
    it('top_and_explicit_expand_reset_scroll_history', 0, () => {
      const state = new TabBarCollapse(); state.onScroll(0); state.onScroll(80);
      state.onScroll(8); expect(state.collapsed).assertFalse();
      state.onScroll(80); expect(state.collapsed).assertTrue();
      state.expand(); state.onScroll(400); expect(state.collapsed).assertFalse();
      state.onScroll(408); expect(state.collapsed).assertTrue();
    });
  });
}
