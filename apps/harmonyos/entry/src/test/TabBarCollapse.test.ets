import { describe, it, expect } from '@ohos/hypium';
import { TabBarCollapse } from '../main/ets/common/TabBarCollapse';

export default function tabBarCollapseTest(): void {
  describe('TabBarCollapse', () => {
    it('slow_scroll_accumulates_below_per_frame_threshold', 0, () => {
      const state = new TabBarCollapse();
      for (let top = 0; top <= 40; top += 2) { state.onScroll(top, false); }
      expect(state.collapsed).assertTrue();
      for (let top = 38; top >= 28; top -= 2) { state.onScroll(top, false); }
      expect(state.collapsed).assertFalse();
    });
    it('small_direction_changes_do_not_expand_collapsed_bar', 0, () => {
      const state = new TabBarCollapse(); state.onScroll(0, false); state.onScroll(80, false);
      for (let index = 0; index < 8; index++) { state.onScroll(77, false); state.onScroll(80, false); }
      expect(state.collapsed).assertTrue();
      state.onScroll(68, false); expect(state.collapsed).assertFalse();
    });
    it('top_and_explicit_expand_reset_scroll_history', 0, () => {
      const state = new TabBarCollapse(); state.onScroll(0, false); state.onScroll(80, false);
      state.onScroll(8, false); expect(state.collapsed).assertFalse();
      state.onScroll(80, false); expect(state.collapsed).assertTrue();
      state.expand(); state.onScroll(400, false); expect(state.collapsed).assertFalse();
      state.onScroll(408, false); expect(state.collapsed).assertTrue();
    });
    it('reaching_content_end_expands_and_near_end_zone_blocks_collapse', 0, () => {
      const state = new TabBarCollapse(); state.onScroll(0, false); state.onScroll(80, false);
      // 到内容最底：放回整条，且记住最底位置
      state.onScroll(1200, true); expect(state.collapsed).assertFalse();
      // 底部附近（距最底 1200 不足 480）下滑不收起
      state.onScroll(1000, false); expect(state.collapsed).assertFalse();
      state.onScroll(1150, false); expect(state.collapsed).assertFalse();
      // 上滑离开底部带（top < 720）后，下滑恢复常规收起
      state.onScroll(600, false); expect(state.collapsed).assertFalse();
      state.onScroll(640, false); expect(state.collapsed).assertTrue();
    });
  });
}
